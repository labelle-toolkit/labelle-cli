const std = @import("std");
const testing = std.testing;
const Adapter = @import("ecs");

const Entity = Adapter.Entity;
const Position = struct { x: f32 = 0, y: f32 = 0 };
const Health = struct { current: f32 = 100, max: f32 = 100 };
const Tag = struct { label: u32 = 0 };

test "createEntity and entityExists" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    try testing.expect(ecs.entityExists(e));
    try testing.expectEqual(@as(usize, 1), ecs.entityCount());
}

test "destroyEntity removes entity" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.destroyEntity(e);
    try testing.expect(!ecs.entityExists(e));
    try testing.expectEqual(@as(usize, 0), ecs.entityCount());
}

test "addComponent and getComponent" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Position{ .x = 10, .y = 20 });

    const pos = ecs.getComponent(e, Position);
    try testing.expect(pos != null);
    try testing.expectEqual(@as(f32, 10), pos.?.x);
    try testing.expectEqual(@as(f32, 20), pos.?.y);
}

test "removeComponent removes component" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Tag{ .label = 42 });
    try testing.expect(ecs.hasComponent(e, Tag));

    ecs.removeComponent(e, Tag);
    try testing.expect(!ecs.hasComponent(e, Tag));
}

test "getComponent returns null for destroyed entity" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Position{ .x = 5, .y = 5 });
    ecs.destroyEntity(e);

    try testing.expectEqual(@as(?*Position, null), ecs.getComponent(e, Position));
}

test "view returns only alive entities" {
    var ecs = Adapter.init(testing.allocator);
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
    try testing.expectEqual(@as(usize, 2), count);
}

test "destroyEntity then create leaves only new entity alive" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e1 = ecs.createEntity();
    ecs.destroyEntity(e1);
    const e2 = ecs.createEntity();

    try testing.expect(ecs.entityExists(e2));
    try testing.expect(!ecs.entityExists(e1));
    try testing.expectEqual(@as(usize, 1), ecs.entityCount());
}

test "multiple components on same entity" {
    var ecs = Adapter.init(testing.allocator);
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
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    var entities: [10]Entity = undefined;
    for (&entities, 0..) |*e, i| {
        e.* = ecs.createEntity();
        ecs.addComponent(e.*, Position{ .x = @floatFromInt(i), .y = 0 });
        ecs.addComponent(e.*, Tag{ .label = @intCast(i) });
    }

    for (entities, 0..) |e, i| {
        if (i % 2 == 1) ecs.destroyEntity(e);
    }

    var v = ecs.view(.{Tag}, .{});
    defer v.deinit();
    var count: usize = 0;
    while (v.next()) |entity| {
        try testing.expect(ecs.entityExists(entity));
        const tag = ecs.getComponent(entity, Tag).?;
        try testing.expect(tag.label % 2 == 0);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 5), count);
}

test "double destroyEntity is safe in release mode" {
    if (comptime @import("builtin").mode == .Debug) return;
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Tag{ .label = 1 });
    ecs.destroyEntity(e);

    ecs.destroyEntity(e);

    try testing.expectEqual(@as(usize, 0), ecs.entityCount());
    try testing.expect(!ecs.entityExists(e));
}

test "hasComponent returns false for destroyed entity" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Tag{ .label = 1 });
    ecs.addComponent(e, Position{ .x = 5, .y = 10 });
    ecs.destroyEntity(e);

    try testing.expect(!ecs.hasComponent(e, Tag));
    try testing.expect(!ecs.hasComponent(e, Position));
}

test "addComponent replaces existing component" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    const e = ecs.createEntity();
    ecs.addComponent(e, Tag{ .label = 1 });
    try testing.expectEqual(@as(u32, 1), ecs.getComponent(e, Tag).?.label);

    ecs.addComponent(e, Tag{ .label = 99 });
    try testing.expectEqual(@as(u32, 99), ecs.getComponent(e, Tag).?.label);
}

test "query excludes destroyed entities" {
    var ecs = Adapter.init(testing.allocator);
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
        try testing.expectEqual(@as(u32, 2), result.comp_0.label);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "destroy and recreate cycle preserves integrity" {
    var ecs = Adapter.init(testing.allocator);
    defer ecs.deinit();

    for (0..50) |i| {
        const e = ecs.createEntity();
        ecs.addComponent(e, Tag{ .label = @intCast(i) });
        ecs.addComponent(e, Position{ .x = @floatFromInt(i), .y = 0 });
        ecs.destroyEntity(e);
    }

    try testing.expectEqual(@as(usize, 0), ecs.entityCount());

    for (0..10) |i| {
        const e = ecs.createEntity();
        ecs.addComponent(e, Tag{ .label = @intCast(i + 100) });
        try testing.expect(ecs.entityExists(e));
        try testing.expectEqual(@as(u32, @intCast(i + 100)), ecs.getComponent(e, Tag).?.label);
    }
    try testing.expectEqual(@as(usize, 10), ecs.entityCount());
}
