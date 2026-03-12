/// zflecs adapter — satisfies the labelle-core Ecs(Impl) contract.
/// Wraps zig-gamedev/zflecs (flecs C bindings) with the required interface.
const std = @import("std");
const flecs = @import("zflecs");

/// Entity is u32 externally; internally maps to flecs entity_t (u64).
pub const Entity = u32;

const Self = @This();

world: *flecs.world_t,
/// Map external u32 id → flecs entity_t
id_to_flecs: std.AutoHashMap(u32, flecs.entity_t),
/// Map flecs entity_t → external u32 id
flecs_to_id: std.AutoHashMap(flecs.entity_t, u32),
next_id: u32,
entity_count: usize,
alive_entities: std.ArrayListUnmanaged(Entity),
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .world = flecs.init(),
        .id_to_flecs = std.AutoHashMap(u32, flecs.entity_t).init(allocator),
        .flecs_to_id = std.AutoHashMap(flecs.entity_t, u32).init(allocator),
        .next_id = 1,
        .entity_count = 0,
        .alive_entities = .{},
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.alive_entities.deinit(self.allocator);
    self.id_to_flecs.deinit();
    self.flecs_to_id.deinit();
    _ = flecs.fini(self.world);
}

pub fn createEntity(self: *Self) Entity {
    const id = self.next_id;
    self.next_id += 1;

    const flecs_entity = flecs.new_id(self.world);
    self.id_to_flecs.put(id, flecs_entity) catch @panic("OOM");
    self.flecs_to_id.put(flecs_entity, id) catch @panic("OOM");
    self.entity_count += 1;
    self.alive_entities.append(self.allocator, id) catch @panic("OOM");
    return id;
}

pub fn destroyEntity(self: *Self, entity: Entity) void {
    if (self.id_to_flecs.get(entity)) |flecs_entity| {
        flecs.delete(self.world, flecs_entity);
        _ = self.flecs_to_id.remove(flecs_entity);
        _ = self.id_to_flecs.remove(entity);
        self.entity_count -= 1;
        for (self.alive_entities.items, 0..) |e, idx| {
            if (e == entity) {
                _ = self.alive_entities.swapRemove(idx);
                break;
            }
        }
    }
}

pub fn entityExists(self: *Self, entity: Entity) bool {
    if (self.id_to_flecs.get(entity)) |flecs_entity| {
        return flecs.is_alive(self.world, flecs_entity);
    }
    return false;
}

pub fn entityCount(self: *Self) usize {
    return self.entity_count;
}

pub fn addComponent(self: *Self, entity: Entity, component: anytype) void {
    const T = @TypeOf(component);
    const flecs_entity = self.id_to_flecs.get(entity) orelse return;
    flecs.COMPONENT(self.world, T);
    _ = flecs.set(self.world, flecs_entity, T, component);
}

pub fn getComponent(self: *Self, entity: Entity, comptime T: type) ?*T {
    const flecs_entity = self.id_to_flecs.get(entity) orelse return null;
    flecs.COMPONENT(self.world, T);
    return flecs.get_mut(self.world, flecs_entity, T);
}

pub fn hasComponent(self: *Self, entity: Entity, comptime T: type) bool {
    const flecs_entity = self.id_to_flecs.get(entity) orelse return false;
    flecs.COMPONENT(self.world, T);
    return flecs.get_mut(self.world, flecs_entity, T) != null;
}

pub fn removeComponent(self: *Self, entity: Entity, comptime T: type) void {
    const flecs_entity = self.id_to_flecs.get(entity) orelse return;
    flecs.COMPONENT(self.world, T);
    flecs.remove(self.world, flecs_entity, T);
}

/// View type — iterates matching entities using flecs queries.
/// Materializes results into a fixed buffer to ensure query cleanup.
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
    inline for (includes) |T| flecs.COMPONENT(self.world, T);
    inline for (excludes) |T| flecs.COMPONENT(self.world, T);

    var result: std.ArrayListUnmanaged(Entity) = .{};
    var it = self.id_to_flecs.iterator();
    while (it.next()) |entry| {
        const ext_id = entry.key_ptr.*;
        if (matchesAll(self, ext_id, includes, excludes)) {
            result.append(self.allocator, ext_id) catch @panic("OOM");
        }
    }

    return .{
        .entities = result.toOwnedSlice(self.allocator) catch @panic("OOM"),
        .allocator = self.allocator,
    };
}

fn matchesAll(self: *Self, entity: Entity, comptime includes: anytype, comptime excludes: anytype) bool {
    inline for (includes) |T| {
        if (!self.hasComponent(entity, T)) return false;
    }
    inline for (excludes) |T| {
        if (self.hasComponent(entity, T)) return false;
    }
    return true;
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
    entities.appendSlice(self.allocator, self.alive_entities.items) catch @panic("OOM");
    return .{
        .backend = self,
        .entities = entities,
        .index = 0,
    };
}
