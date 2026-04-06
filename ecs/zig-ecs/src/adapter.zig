/// zig-ecs adapter — satisfies the labelle-core Ecs(Impl) contract.
/// Wraps prime31/zig-ecs (EnTT port) with the required interface.
const std = @import("std");
const builtin = @import("builtin");
const zig_ecs = @import("zig-ecs");

const is_debug = builtin.mode == .Debug;

/// External entity type — plain u32 for engine compatibility.
pub const Entity = u32;

/// Internal zig-ecs entity type (packed struct, 32 bits).
const InternalEntity = zig_ecs.Entity;

const Self = @This();

/// Debug-only: panic with a clear message when an invalid entity
/// is passed to a mutating ECS method. In release builds this is
/// a no-op — the underlying zig-ecs asserts are stripped anyway.
fn assertValid(self: *Self, entity: Entity, comptime operation: []const u8) void {
    if (comptime is_debug) {
        if (!self.inner.valid(toInternal(entity))) {
            std.debug.print("{s} on invalid entity {d}\n", .{ operation, entity });
            @panic(operation ++ " on invalid entity");
        }
    }
}

inner: zig_ecs.Registry,
entity_count: usize,
alive_entities: std.ArrayListUnmanaged(Entity),
alloc: std.mem.Allocator,

fn toInternal(entity: Entity) InternalEntity {
    return @bitCast(entity);
}

fn toExternal(entity: InternalEntity) Entity {
    return @bitCast(entity);
}

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .inner = zig_ecs.Registry.init(allocator),
        .entity_count = 0,
        .alive_entities = .{},
        .alloc = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.alive_entities.deinit(self.alloc);
    self.inner.deinit();
}

pub fn createEntity(self: *Self) Entity {
    const entity = self.inner.create();
    self.entity_count += 1;
    const ext = toExternal(entity);
    self.alive_entities.append(self.alloc, ext) catch @panic("OOM");
    return ext;
}

pub fn destroyEntity(self: *Self, entity: Entity) void {
    self.assertValid(entity, "destroyEntity");
    const ie = toInternal(entity);
    if (!self.inner.valid(ie)) return;
    self.inner.destroy(ie);
    self.entity_count -= 1;
    for (self.alive_entities.items, 0..) |e, idx| {
        if (e == entity) {
            _ = self.alive_entities.swapRemove(idx);
            break;
        }
    }
}

pub fn entityExists(self: *Self, entity: Entity) bool {
    return self.inner.valid(toInternal(entity));
}

pub fn entityCount(self: *Self) usize {
    return self.entity_count;
}

pub fn addComponent(self: *Self, entity: Entity, component: anytype) void {
    self.assertValid(entity, "addComponent(" ++ @typeName(@TypeOf(component)) ++ ")");
    self.inner.addOrReplace(toInternal(entity), component);
}

pub fn getComponent(self: *Self, entity: Entity, comptime T: type) ?*T {
    return self.inner.tryGet(T, toInternal(entity));
}

pub fn hasComponent(self: *Self, entity: Entity, comptime T: type) bool {
    return self.inner.tryGet(T, toInternal(entity)) != null;
}

pub fn removeComponent(self: *Self, entity: Entity, comptime T: type) void {
    self.assertValid(entity, "removeComponent(" ++ @typeName(T) ++ ")");
    self.inner.remove(T, toInternal(entity));
}

/// View type — iterates matching entities, converting to external Entity.
/// Materializes results into a buffer to avoid dangling pointers from
/// stack-local zig-ecs views and to provide a consistent deinit() interface.
pub fn View(comptime _includes: anytype, comptime _excludes: anytype) type {
    return struct {
        entities: []const Entity,
        index: usize = 0,
        allocator: std.mem.Allocator,

        const ViewSelf = @This();
        const includes = _includes;
        const excludes = _excludes;

        pub fn next(self: *ViewSelf) ?Entity {
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
    var result: std.ArrayListUnmanaged(Entity) = .{};

    if (includes.len == 1 and excludes.len == 0) {
        const basic = self.inner.basicView(includes[0]);
        var iter = basic.entityIterator();
        while (iter.next()) |internal| {
            result.append(self.inner.allocator, toExternal(internal)) catch @panic("OOM");
        }
    } else {
        var multi = self.inner.view(includes, excludes);
        var iter = multi.entityIterator();
        while (iter.next()) |internal| {
            result.append(self.inner.allocator, toExternal(internal)) catch @panic("OOM");
        }
    }

    return .{
        .entities = result.toOwnedSlice(self.inner.allocator) catch @panic("OOM"),
        .allocator = self.inner.allocator,
    };
}

/// Validates that `components` is a tuple of types.
fn validateComponentTuple(comptime components: anytype) void {
    const info = @typeInfo(@TypeOf(components));
    if (info != .@"struct" or !info.@"struct".is_tuple)
        @compileError("query() expects a tuple of component types, e.g. .{Pos, Vel}");
    inline for (info.@"struct".fields) |field| {
        if (field.type != type)
            @compileError("query() tuple elements must be types, got: " ++ @typeName(field.type));
    }
}

fn QueryResultType(comptime components: anytype) type {
    comptime validateComponentTuple(components);
    const fields_info = @typeInfo(@TypeOf(components)).@"struct".fields;
    var fields: [fields_info.len + 1]std.builtin.Type.StructField = undefined;
    fields[0] = .{
        .name = "entity",
        .type = Entity,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(Entity),
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

/// QueryIterator type for this backend.
pub fn QueryIterator(comptime components: anytype) type {
    comptime validateComponentTuple(components);
    return struct {
        backend: *Self,
        entities: std.ArrayListUnmanaged(Entity),
        index: usize,

        const QI = @This();
        pub const Result = QueryResultType(components);

        pub fn next(self_qi: *QI) ?Result {
            while (self_qi.index < self_qi.entities.items.len) {
                const entity = self_qi.entities.items[self_qi.index];
                self_qi.index += 1;

                var has_all = true;
                inline for (@typeInfo(@TypeOf(components)).@"struct".fields, 0..) |_, i| {
                    const T = components[i];
                    if (self_qi.backend.getComponent(entity, T) == null) {
                        has_all = false;
                        break;
                    }
                }
                if (!has_all) continue;

                var result: Result = undefined;
                result.entity = entity;
                inline for (@typeInfo(@TypeOf(components)).@"struct".fields, 0..) |_, i| {
                    const T = components[i];
                    @field(result, std.fmt.comptimePrint("comp_{d}", .{i})) = self_qi.backend.getComponent(entity, T).?;
                }
                return result;
            }
            return null;
        }

        pub fn deinit(self_qi: *QI, allocator: std.mem.Allocator) void {
            self_qi.entities.deinit(allocator);
        }
    };
}

/// Query entities with direct component access.
pub fn query(self: *Self, comptime components: anytype) QueryIterator(components) {
    var entities = std.ArrayListUnmanaged(Entity){};
    entities.appendSlice(self.alloc, self.alive_entities.items) catch @panic("OOM");
    return .{
        .backend = self,
        .entities = entities,
        .index = 0,
    };
}

