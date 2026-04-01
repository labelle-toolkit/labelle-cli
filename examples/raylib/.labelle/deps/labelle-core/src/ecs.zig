const std = @import("std");

/// Comptime ECS trait — defines the operations any ECS backend must support.
/// The assembler fills this slot; engine and plugins are ECS-agnostic.
pub fn Ecs(comptime Backend: type) type {
    comptime {
        if (!@hasDecl(Backend, "Entity"))
            @compileError("ECS backend must define Entity type, found: " ++ @typeName(Backend));
        const required = .{ "createEntity", "destroyEntity", "entityExists", "entityCount", "view", "query" };
        if (!@hasDecl(Backend, "View"))
            @compileError("ECS backend must define View type, found: " ++ @typeName(Backend));
        for (required) |name| {
            if (!@hasDecl(Backend, name))
                @compileError("ECS backend must implement " ++ name);
        }
    }

    return struct {
        pub const Entity = Backend.Entity;
        backend: *Backend,

        const Self = @This();

        pub fn createEntity(self: Self) Entity {
            return self.backend.createEntity();
        }

        pub fn destroyEntity(self: Self, entity: Entity) void {
            self.backend.destroyEntity(entity);
        }

        pub fn entityExists(self: Self, entity: Entity) bool {
            return self.backend.entityExists(entity);
        }

        pub fn entityCount(self: Self) usize {
            return self.backend.entityCount();
        }

        pub fn add(self: Self, entity: Entity, component: anytype) void {
            self.backend.addComponent(entity, component);
        }

        pub fn get(self: Self, entity: Entity, comptime T: type) ?*T {
            return self.backend.getComponent(entity, T);
        }

        pub fn has(self: Self, entity: Entity, comptime T: type) bool {
            return self.backend.hasComponent(entity, T);
        }

        pub fn remove(self: Self, entity: Entity, comptime T: type) void {
            self.backend.removeComponent(entity, T);
        }

        /// Iterate entities that have all included components.
        /// Returns an iterator with a `next() ?Entity` method and `deinit()` for cleanup.
        pub fn view(self: Self, comptime includes: anytype) Backend.View(includes, .{}) {
            comptime validateComponentTupleLabeled(includes, "view() includes");
            return self.backend.view(includes, .{});
        }

        /// Iterate entities that have all included components but none of the excluded.
        /// Returns an iterator with a `next() ?Entity` method and `deinit()` for cleanup.
        pub fn viewExcluding(self: Self, comptime includes: anytype, comptime excludes: anytype) Backend.View(includes, excludes) {
            comptime validateComponentTupleLabeled(includes, "viewExcluding() includes");
            comptime validateComponentTupleLabeled(excludes, "viewExcluding() excludes");
            return self.backend.view(includes, excludes);
        }

        /// Query entities with direct component access.
        /// Returns an iterator yielding .{ .entity, .comp_0, .comp_1, ... } tuples
        /// where each comp field is a mutable pointer to the component.
        pub fn query(self: Self, comptime components: anytype) Backend.QueryIterator(components) {
            return self.backend.query(components);
        }
    };
}

/// Validates that `components` is a tuple of types.
pub fn validateComponentTuple(comptime components: anytype) void {
    const info = @typeInfo(@TypeOf(components));
    if (info != .@"struct" or !info.@"struct".is_tuple)
        @compileError("query() expects a tuple of component types, e.g. .{Pos, Vel}");
    inline for (info.@"struct".fields) |field| {
        if (field.type != type)
            @compileError("query() tuple elements must be types, got: " ++ @typeName(field.type));
    }
}

/// Result struct returned by QueryIterator.next().
/// Has .entity plus .comp_0, .comp_1, ... as mutable pointers.
pub fn QueryResult(comptime EntityType: type, comptime components: anytype) type {
    comptime validateComponentTuple(components);
    const fields_info = @typeInfo(@TypeOf(components)).@"struct".fields;
    var fields: [fields_info.len + 1]std.builtin.Type.StructField = undefined;
    fields[0] = .{
        .name = "entity",
        .type = EntityType,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(EntityType),
    };
    for (fields_info, 0..) |_, i| {
        const T = components[i];
        const name = std.fmt.comptimePrint("comp_{d}", .{i});
        fields[i + 1] = .{
            .name = name,
            .type = *T,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(*T),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

/// Generic QueryIterator — works for any backend that implements getComponent.
/// Takes a backend pointer type and a tuple of component types.
pub fn GenericQueryIterator(comptime BackendPtr: type, comptime EntityType: type, comptime components: anytype) type {
    comptime validateComponentTuple(components);
    return struct {
        backend: BackendPtr,
        entities: std.ArrayListUnmanaged(EntityType),
        index: usize,
        allocator: std.mem.Allocator,

        const QI = @This();
        pub const Result = QueryResult(EntityType, components);

        pub fn next(self: *QI) ?Result {
            while (self.index < self.entities.items.len) {
                const entity = self.entities.items[self.index];
                self.index += 1;

                var has_all = true;
                inline for (@typeInfo(@TypeOf(components)).@"struct".fields, 0..) |_, i| {
                    const T = components[i];
                    if (self.backend.getComponent(entity, T) == null) {
                        has_all = false;
                        break;
                    }
                }
                if (!has_all) continue;

                var result: Result = undefined;
                result.entity = entity;
                inline for (@typeInfo(@TypeOf(components)).@"struct".fields, 0..) |_, i| {
                    const T = components[i];
                    @field(result, std.fmt.comptimePrint("comp_{d}", .{i})) = self.backend.getComponent(entity, T).?;
                }
                return result;
            }
            return null;
        }

        pub fn deinit(self: *QI) void {
            self.entities.deinit(self.allocator);
        }
    };
}

/// Validate that a comptime argument is a tuple of types (e.g., .{Pos, Vel}).
fn validateComponentTupleLabeled(comptime tuple: anytype, comptime label: []const u8) void {
    const T = @TypeOf(tuple);
    const info = @typeInfo(T);
    if (info != .@"struct" or !info.@"struct".is_tuple)
        @compileError(label ++ " must be a tuple of component types, e.g. .{Pos, Vel}");
    inline for (info.@"struct".fields) |field| {
        if (field.type != type)
            @compileError(label ++ " must contain types, found value of type " ++ @typeName(field.type));
    }
}

/// Mock ECS backend for testing — satisfies the Ecs trait with in-memory storage.
pub fn MockEcsBackend(comptime EntityType: type) type {
    return struct {
        pub const Entity = EntityType;

        const CleanupFn = *const fn (*Self) void;

        next_id: EntityType = 1,
        alive: std.AutoHashMap(EntityType, void),
        storages: std.AutoHashMap(usize, *anyopaque),
        cleanups: std.ArrayListUnmanaged(CleanupFn) = .{},
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .alive = std.AutoHashMap(EntityType, void).init(allocator),
                .storages = std.AutoHashMap(usize, *anyopaque).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.cleanups.items) |cleanup| {
                cleanup(self);
            }
            self.cleanups.deinit(self.allocator);
            self.storages.deinit();
            self.alive.deinit();
        }

        pub fn createEntity(self: *Self) EntityType {
            const id = self.next_id;
            self.next_id += 1;
            self.alive.put(id, {}) catch @panic("OOM");
            return id;
        }

        pub fn destroyEntity(self: *Self, entity: EntityType) void {
            _ = self.alive.remove(entity);
        }

        pub fn entityExists(self: *Self, entity: EntityType) bool {
            return self.alive.contains(entity);
        }

        pub fn entityCount(self: *Self) usize {
            return self.alive.count();
        }

        pub fn addComponent(self: *Self, entity: EntityType, component: anytype) void {
            const T = @TypeOf(component);
            const storage = self.getOrCreateStorage(T);
            storage.put(entity, component) catch @panic("OOM");
        }

        pub fn getComponent(self: *Self, entity: EntityType, comptime T: type) ?*T {
            const storage = self.getStorage(T) orelse return null;
            return storage.getPtr(entity);
        }

        pub fn hasComponent(self: *Self, entity: EntityType, comptime T: type) bool {
            const storage = self.getStorage(T) orelse return false;
            return storage.contains(entity);
        }

        pub fn removeComponent(self: *Self, entity: EntityType, comptime T: type) void {
            const storage = self.getStorage(T) orelse return;
            _ = storage.remove(entity);
        }

        /// View type — iterates entities matching include/exclude component filters.
        pub fn View(comptime _includes: anytype, comptime _excludes: anytype) type {
            return struct {
                entities: []const EntityType,
                index: usize = 0,
                allocator: std.mem.Allocator,

                const ViewSelf = @This();
                const includes = _includes;
                const excludes = _excludes;

                pub fn next(self: *ViewSelf) ?EntityType {
                    if (self.index < self.entities.len) {
                        const entity = self.entities[self.index];
                        self.index += 1;
                        return entity;
                    }
                    return null;
                }

                pub fn deinit(self: *ViewSelf) void {
                    self.allocator.free(self.entities);
                }
            };
        }

        /// Create a view iterating entities with the given include/exclude filters.
        pub fn view(self: *Self, comptime includes: anytype, comptime excludes: anytype) View(includes, excludes) {
            var result: std.ArrayListUnmanaged(EntityType) = .{};
            var it = self.alive.keyIterator();
            while (it.next()) |key_ptr| {
                const entity = key_ptr.*;
                if (self.matchesAll(entity, includes, excludes)) {
                    result.append(self.allocator, entity) catch @panic("OOM");
                }
            }
            return .{
                .entities = result.toOwnedSlice(self.allocator) catch @panic("OOM"),
                .allocator = self.allocator,
            };
        }

        fn matchesAll(self: *Self, entity: EntityType, comptime includes: anytype, comptime excludes: anytype) bool {
            inline for (includes) |T| {
                if (!self.hasComponent(entity, T)) return false;
            }
            inline for (excludes) |T| {
                if (self.hasComponent(entity, T)) return false;
            }
            return true;
        }

        /// QueryIterator type for this backend.
        pub fn QueryIterator(comptime components: anytype) type {
            return GenericQueryIterator(*Self, EntityType, components);
        }

        /// Query entities with direct component access.
        pub fn query(self: *Self, comptime components: anytype) QueryIterator(components) {
            var entities = std.ArrayListUnmanaged(EntityType){};
            var it = self.alive.keyIterator();
            while (it.next()) |key| {
                entities.append(self.allocator, key.*) catch @panic("OOM");
            }
            return .{
                .backend = self,
                .entities = entities,
                .index = 0,
                .allocator = self.allocator,
            };
        }

        fn getOrCreateStorage(self: *Self, comptime T: type) *std.AutoHashMap(EntityType, T) {
            const tid = typeId(T);
            if (self.storages.get(tid)) |raw| {
                return @ptrCast(@alignCast(raw));
            }
            const storage = self.allocator.create(std.AutoHashMap(EntityType, T)) catch @panic("OOM");
            storage.* = std.AutoHashMap(EntityType, T).init(self.allocator);
            self.storages.put(tid, @ptrCast(storage)) catch @panic("OOM");

            self.cleanups.append(self.allocator, &struct {
                fn cleanup(s: *Self) void {
                    const id = typeId(T);
                    if (s.storages.get(id)) |raw| {
                        const typed: *std.AutoHashMap(EntityType, T) = @ptrCast(@alignCast(raw));
                        typed.deinit();
                        s.allocator.destroy(typed);
                    }
                }
            }.cleanup) catch @panic("OOM");

            return storage;
        }

        fn getStorage(self: *Self, comptime T: type) ?*std.AutoHashMap(EntityType, T) {
            const tid = typeId(T);
            const raw = self.storages.get(tid) orelse return null;
            return @ptrCast(@alignCast(raw));
        }

        fn typeId(comptime T: type) usize {
            return @intFromPtr(&struct {
                comptime {
                    _ = T;
                }
                var x: u8 = 0;
            }.x);
        }
    };
}
