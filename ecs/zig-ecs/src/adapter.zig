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
    const ie = toInternal(entity);
    if (!self.inner.valid(ie)) {
        self.assertValid(entity, "destroyEntity");
        return;
    }
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
    self.assertValid(entity, "addComponent");
    self.inner.addOrReplace(toInternal(entity), component);
}

pub fn getComponent(self: *Self, entity: Entity, comptime T: type) ?*T {
    return self.inner.tryGet(T, toInternal(entity));
}

pub fn hasComponent(self: *Self, entity: Entity, comptime T: type) bool {
    return self.inner.tryGet(T, toInternal(entity)) != null;
}

pub fn removeComponent(self: *Self, entity: Entity, comptime T: type) void {
    self.assertValid(entity, "removeComponent");
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

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Position = struct { x: f32 = 0, y: f32 = 0 };
const Health = struct { current: f32 = 100, max: f32 = 100 };
const Tag = struct { label: u32 = 0 };

test "createEntity and entityExists" {
    var ecs = Self.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    try testing.expect(ecs.entityExists(e));
    try testing.expectEqual(1, ecs.entityCount());
}

test "destroyEntity removes entity" {
    var ecs = Self.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.destroyEntity(e);
    try testing.expect(!ecs.entityExists(e));
    try testing.expectEqual(0, ecs.entityCount());
}

test "addComponent and getComponent" {
    var ecs = Self.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Position{ .x = 10, .y = 20 });

    const pos = ecs.getComponent(e, Position);
    try testing.expect(pos != null);
    try testing.expectEqual(10, pos.?.x);
    try testing.expectEqual(20, pos.?.y);
}

test "removeComponent removes component" {
    var ecs = Self.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Tag{ .label = 42 });
    try testing.expect(ecs.hasComponent(e, Tag));

    ecs.removeComponent(e, Tag);
    try testing.expect(!ecs.hasComponent(e, Tag));
}

test "getComponent returns null for destroyed entity" {
    var ecs = Self.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Position{ .x = 5, .y = 5 });
    ecs.destroyEntity(e);

    try testing.expectEqual(@as(?*Position, null), ecs.getComponent(e, Position));
}

test "view returns only alive entities" {
    var ecs = Self.init(testing.allocator);
    defer ecs.deinit();

    const e1 = ecs.createEntity();
    ecs.addComponent(e1, Tag{ .label = 1 });
    const e2 = ecs.createEntity();
    ecs.addComponent(e2, Tag{ .label = 2 });
    const e3 = ecs.createEntity();
    ecs.addComponent(e3, Tag{ .label = 3 });

    ecs.destroyEntity(e2);

    var count: usize = 0;
    var v = ecs.view(.{Tag}, .{});
    defer v.deinit();
    while (v.next()) |entity| {
        try testing.expect(ecs.entityExists(entity));
        count += 1;
    }
    try testing.expectEqual(2, count);
}

test "destroyEntity then create reuses entity slots" {
    var ecs = Self.init(testing.allocator);
    defer ecs.deinit();

    const e1 = ecs.createEntity();
    ecs.destroyEntity(e1);
    const e2 = ecs.createEntity();

    // New entity should be alive, old should not
    try testing.expect(ecs.entityExists(e2));
    try testing.expect(!ecs.entityExists(e1));
    try testing.expectEqual(1, ecs.entityCount());
}

test "multiple components on same entity" {
    var ecs = Self.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Position{ .x = 1, .y = 2 });
    ecs.addComponent(e, Health{ .current = 50, .max = 100 });
    ecs.addComponent(e, Tag{ .label = 99 });

    try testing.expect(ecs.hasComponent(e, Position));
    try testing.expect(ecs.hasComponent(e, Health));
    try testing.expect(ecs.hasComponent(e, Tag));

    ecs.destroyEntity(e);

    try testing.expect(!ecs.hasComponent(e, Position));
    try testing.expect(!ecs.hasComponent(e, Health));
    try testing.expect(!ecs.hasComponent(e, Tag));
}

test "view after destroyEntity returns clean results" {
    var ecs = Self.init(testing.allocator);
    defer ecs.deinit();

    // Create 10 entities with Position + Tag
    var entities: [10]Entity = undefined;
    for (&entities, 0..) |*e, i| {
        e.* = ecs.createEntity();
        ecs.addComponent(e.*, Position{ .x = @floatFromInt(i), .y = 0 });
        ecs.addComponent(e.*, Tag{ .label = @intCast(i) });
    }

    // Destroy odd-indexed entities
    for (entities, 0..) |e, i| {
        if (i % 2 == 1) ecs.destroyEntity(e);
    }

    // View should only return even-indexed entities
    var v = ecs.view(.{Tag}, .{});
    defer v.deinit();
    var count: usize = 0;
    while (v.next()) |entity| {
        try testing.expect(ecs.entityExists(entity));
        const tag = ecs.getComponent(entity, Tag).?;
        try testing.expect(tag.label % 2 == 0);
        count += 1;
    }
    try testing.expectEqual(5, count);
}

test "double destroyEntity is safe in release mode" {
    // In Debug mode this panics (by design — catches use-after-destroy).
    // This test verifies the silent early-return path in non-debug modes.
    if (comptime is_debug) return;
    var ecs = Self.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Tag{ .label = 1 });
    ecs.destroyEntity(e);

    // Second destroy should not corrupt state (silent return in non-debug)
    ecs.destroyEntity(e);

    try testing.expectEqual(0, ecs.entityCount());
    try testing.expect(!ecs.entityExists(e));
}

test "hasComponent returns false for destroyed entity" {
    var ecs = Self.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Tag{ .label = 1 });
    ecs.addComponent(e, Position{ .x = 5, .y = 10 });
    ecs.destroyEntity(e);

    try testing.expect(!ecs.hasComponent(e, Tag));
    try testing.expect(!ecs.hasComponent(e, Position));
}

test "addComponent replaces existing component" {
    var ecs = Self.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Tag{ .label = 1 });
    try testing.expectEqual(1, ecs.getComponent(e, Tag).?.label);

    ecs.addComponent(e, Tag{ .label = 99 });
    try testing.expectEqual(99, ecs.getComponent(e, Tag).?.label);
}

test "query excludes destroyed entities" {
    var ecs = Self.init(testing.allocator);
    defer ecs.deinit();

    const e1 = ecs.createEntity();
    ecs.addComponent(e1, Tag{ .label = 1 });
    const e2 = ecs.createEntity();
    ecs.addComponent(e2, Tag{ .label = 2 });

    ecs.destroyEntity(e1);

    var q = ecs.query(.{Tag});
    defer q.deinit(testing.allocator);
    var count: usize = 0;
    while (q.next()) |result| {
        try testing.expect(ecs.entityExists(result.entity));
        try testing.expectEqual(2, result.comp_0.label);
        count += 1;
    }
    try testing.expectEqual(1, count);
}

test "destroy and recreate cycle preserves integrity" {
    var ecs = Self.init(testing.allocator);
    defer ecs.deinit();

    // Create-destroy-create cycle 50 times
    for (0..50) |i| {
        const e = ecs.createEntity();
        ecs.addComponent(e, Tag{ .label = @intCast(i) });
        ecs.addComponent(e, Position{ .x = @floatFromInt(i), .y = 0 });
        ecs.destroyEntity(e);
    }

    try testing.expectEqual(0, ecs.entityCount());

    // Create fresh entities — should all work
    for (0..10) |i| {
        const e = ecs.createEntity();
        ecs.addComponent(e, Tag{ .label = @intCast(i + 100) });
        try testing.expect(ecs.entityExists(e));
        try testing.expectEqual(@as(u32, @intCast(i + 100)), ecs.getComponent(e, Tag).?.label);
    }
    try testing.expectEqual(10, ecs.entityCount());
}
