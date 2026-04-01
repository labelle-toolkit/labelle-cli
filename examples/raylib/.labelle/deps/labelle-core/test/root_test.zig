const std = @import("std");
const testing = std.testing;
const root = @import("labelle-core");

const HookDispatcher = root.HookDispatcher;
const MergeHooks = root.MergeHooks;
const Ecs = root.Ecs;
const MockEcsBackend = root.MockEcsBackend;
const Position = root.Position;
const AudioInterface = root.AudioInterface;
const StubAudio = root.StubAudio;
const InputInterface = root.InputInterface;
const StubInput = root.StubInput;
const GuiInterface = root.GuiInterface;
const StubGui = root.StubGui;
const LogSinkInterface = root.LogSinkInterface;
const StubLogSink = root.StubLogSink;
const StderrLogSink = root.StderrLogSink;
const GizmoInterface = root.GizmoInterface;
const StubGizmos = root.StubGizmos;
const RenderInterface = root.RenderInterface;
const StubRender = root.StubRender;
const ParentComponent = root.ParentComponent;
const ChildrenComponent = root.ChildrenComponent;
const CoordinateSystem = root.CoordinateSystem;
const GamePosition = root.GamePosition;
const ScreenPosition = root.ScreenPosition;
const gameToScreen = root.gameToScreen;
const screenToGame = root.screenToGame;

const SimplePayload = union(enum) {
    ping: u32,
    pong: []const u8,
};

test "dispatcher: basic emit calls receiver method" {
    const Receiver = struct {
        ping_value: u32 = 0,

        pub fn ping(self: *@This(), value: u32) void {
            self.ping_value = value;
        }
    };

    var recv = Receiver{};
    const D = HookDispatcher(SimplePayload, *Receiver, .{});
    const d = D{ .receiver = &recv };

    d.emit(.{ .ping = 42 });
    try testing.expectEqual(42, recv.ping_value);

    d.emit(.{ .pong = "hello" });
    try testing.expectEqual(42, recv.ping_value);
}

test "dispatcher: partial handling compiles" {
    const Receiver = struct {
        pub fn ping(_: @This(), _: u32) void {}
    };

    const D = HookDispatcher(SimplePayload, Receiver, .{});
    const d = D{ .receiver = .{} };
    d.emit(.{ .ping = 1 });
    d.emit(.{ .pong = "test" });
}

test "MergeHooks: calls receivers in tuple order" {
    var order: [3]u8 = .{ 0, 0, 0 };
    var idx: u8 = 0;
    const idx_ptr = &idx;
    const order_ptr = &order;

    const ReceiverA = struct {
        order: *[3]u8,
        idx: *u8,

        pub fn ping(self: @This(), _: u32) void {
            self.order[self.idx.*] = 'A';
            self.idx.* += 1;
        }
    };

    const ReceiverB = struct {
        order: *[3]u8,
        idx: *u8,

        pub fn ping(self: @This(), _: u32) void {
            self.order[self.idx.*] = 'B';
            self.idx.* += 1;
        }

        pub fn pong(self: @This(), _: []const u8) void {
            self.order[self.idx.*] = 'b';
            self.idx.* += 1;
        }
    };

    const Merged = MergeHooks(SimplePayload, .{ ReceiverA, ReceiverB });
    const merged = Merged{ .receivers = .{
        ReceiverA{ .order = order_ptr, .idx = idx_ptr },
        ReceiverB{ .order = order_ptr, .idx = idx_ptr },
    } };

    merged.emit(.{ .ping = 1 });
    try testing.expectEqual('A', order[0]);
    try testing.expectEqual('B', order[1]);

    merged.emit(.{ .pong = "x" });
    try testing.expectEqual('b', order[2]);
}

const MergeHookPayloads = root.MergeHookPayloads;

test "MergeHookPayloads: merges two unions into one" {
    const EnginePayload = union(enum) {
        frame_start: u32,
        entity_created: u64,
    };
    const PluginPayload = union(enum) {
        collision_begin: struct { a: u32, b: u32 },
        collision_end: struct { a: u32, b: u32 },
    };

    const Merged = MergeHookPayloads(.{ EnginePayload, PluginPayload });

    // Should have all 4 fields
    const fields = @typeInfo(Merged).@"union".fields;
    try testing.expectEqual(4, fields.len);

    // Can construct and switch on merged values
    const v1: Merged = .{ .frame_start = 42 };
    const v2: Merged = .{ .collision_begin = .{ .a = 1, .b = 2 } };

    switch (v1) {
        .frame_start => |val| try testing.expectEqual(42, val),
        else => unreachable,
    }
    switch (v2) {
        .collision_begin => |val| {
            try testing.expectEqual(1, val.a);
            try testing.expectEqual(2, val.b);
        },
        else => unreachable,
    }
}

test "MergeHookPayloads: works with HookDispatcher" {
    const PayloadA = union(enum) { ping: u32 };
    const PayloadB = union(enum) { pong: []const u8 };
    const Merged = MergeHookPayloads(.{ PayloadA, PayloadB });

    const Receiver = struct {
        ping_val: u32 = 0,
        pub fn ping(self: *@This(), val: u32) void {
            self.ping_val = val;
        }
    };

    var recv = Receiver{};
    const D = HookDispatcher(Merged, *Receiver, .{});
    const d = D{ .receiver = &recv };

    d.emit(.{ .ping = 99 });
    try testing.expectEqual(99, recv.ping_val);

    // pong has no handler — should be a no-op
    d.emit(.{ .pong = "hello" });
    try testing.expectEqual(99, recv.ping_val);
}

test "MockEcsBackend: create entity, add/get/has/remove component" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const e = Ecs(MockEcsBackend(u32)){ .backend = &backend };

    const entity = e.createEntity();
    try testing.expect(e.entityExists(entity));
    try testing.expectEqual(1, e.entityCount());

    const Pos = struct { x: f32, y: f32 };

    e.add(entity, Pos{ .x = 10, .y = 20 });
    try testing.expect(e.has(entity, Pos));

    const pos = e.get(entity, Pos).?;
    try testing.expectEqual(10.0, pos.x);
    try testing.expectEqual(20.0, pos.y);

    pos.x = 99;
    try testing.expectEqual(99.0, e.get(entity, Pos).?.x);

    e.remove(entity, Pos);
    try testing.expect(!e.has(entity, Pos));

    e.destroyEntity(entity);
    try testing.expect(!e.entityExists(entity));
    try testing.expectEqual(0, e.entityCount());
}

test "MockEcsBackend: multiple component types on same entity" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const e = Ecs(MockEcsBackend(u32)){ .backend = &backend };

    const Pos = struct { x: f32, y: f32 };
    const Health = struct { current: u32, max: u32 };

    const entity = e.createEntity();
    e.add(entity, Pos{ .x = 1, .y = 2 });
    e.add(entity, Health{ .current = 100, .max = 100 });

    try testing.expect(e.has(entity, Pos));
    try testing.expect(e.has(entity, Health));
    try testing.expectEqual(100, e.get(entity, Health).?.current);

    e.remove(entity, Pos);
    try testing.expect(!e.has(entity, Pos));
    try testing.expect(e.has(entity, Health));
}

test "MockEcsBackend: entityCount tracks alive entities" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const e = Ecs(MockEcsBackend(u32)){ .backend = &backend };

    try testing.expectEqual(0, e.entityCount());

    const e1 = e.createEntity();
    const e2 = e.createEntity();
    _ = e.createEntity();
    try testing.expectEqual(3, e.entityCount());

    e.destroyEntity(e1);
    try testing.expectEqual(2, e.entityCount());

    e.destroyEntity(e2);
    try testing.expectEqual(1, e.entityCount());
}

test "MockEcsBackend: view iterates entities with matching components" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const Pos = struct { x: f32, y: f32 };
    const Vel = struct { dx: f32, dy: f32 };

    // e1 has Pos only, e2 has Pos+Vel, e3 has Vel only
    const e1 = backend.createEntity();
    const e2 = backend.createEntity();
    const e3 = backend.createEntity();

    backend.addComponent(e1, Pos{ .x = 1, .y = 0 });
    backend.addComponent(e2, Pos{ .x = 2, .y = 0 });
    backend.addComponent(e2, Vel{ .dx = 1, .dy = 0 });
    backend.addComponent(e3, Vel{ .dx = 2, .dy = 0 });

    // View with Pos only — should match e1 and e2
    {
        var v = backend.view(.{Pos}, .{});
        defer v.deinit();
        var count: usize = 0;
        while (v.next()) |_| count += 1;
        try testing.expectEqual(2, count);
    }

    // View with Pos+Vel — should match only e2
    {
        var v = backend.view(.{ Pos, Vel }, .{});
        defer v.deinit();
        var count: usize = 0;
        var found: u32 = 0;
        while (v.next()) |entity| {
            count += 1;
            found = entity;
        }
        try testing.expectEqual(1, count);
        try testing.expectEqual(e2, found);
    }
}

test "MockEcsBackend: viewExcluding filters out excluded components" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const e = Ecs(MockEcsBackend(u32)){ .backend = &backend };

    const Pos = struct { x: f32, y: f32 };
    const Vel = struct { dx: f32, dy: f32 };
    const Locked = struct {};

    const e1 = e.createEntity();
    const e2 = e.createEntity();
    const e3 = e.createEntity();

    e.add(e1, Pos{ .x = 1, .y = 0 });
    e.add(e2, Pos{ .x = 2, .y = 0 });
    e.add(e2, Locked{});
    e.add(e3, Pos{ .x = 3, .y = 0 });
    e.add(e3, Vel{ .dx = 1, .dy = 0 });

    // viewExcluding: Pos but not Locked — should match e1 and e3
    {
        var v = e.viewExcluding(.{Pos}, .{Locked});
        defer v.deinit();
        var count: usize = 0;
        while (v.next()) |entity| {
            count += 1;
            try testing.expect(entity != e2);
        }
        try testing.expectEqual(2, count);
    }
}

test "Position: basic math" {
    const a = Position{ .x = 3, .y = 4 };
    const b = Position{ .x = 1, .y = 2 };

    const sum = a.add(b);
    try testing.expectEqual(4.0, sum.x);
    try testing.expectEqual(6.0, sum.y);

    const diff = a.sub(b);
    try testing.expectEqual(2.0, diff.x);
    try testing.expectEqual(2.0, diff.y);

    try testing.expectEqual(5.0, a.length());
    try testing.expectEqual(a.distance(b), diff.length());

    const scaled = b.scale(3);
    try testing.expectEqual(3.0, scaled.x);
    try testing.expectEqual(6.0, scaled.y);
}

test "AudioInterface(StubAudio) compiles" {
    const Audio = AudioInterface(StubAudio);
    Audio.playSound(0);
    Audio.stopSound(0);
    Audio.setVolume(0.5);
}

test "InputInterface(StubInput) compiles" {
    const Input = InputInterface(StubInput);
    try testing.expect(!Input.isKeyDown(0));
    try testing.expect(!Input.isKeyPressed(0));
    try testing.expectEqual(0.0, Input.getMouseX());
    try testing.expectEqual(0.0, Input.getMouseY());
}

test "GuiInterface(StubGui) compiles" {
    const Gui = GuiInterface(StubGui);
    Gui.begin();
    Gui.end();
    try testing.expect(!Gui.wantsMouse());
    try testing.expect(!Gui.wantsKeyboard());
}

test "GizmoInterface(StubGizmos) draws and counts" {
    const Gizmo = GizmoInterface(StubGizmos);
    StubGizmos.reset();

    Gizmo.drawLine(0, 0, 10, 10, 0xFF0000);
    Gizmo.drawRect(5, 5, 20, 20, 0x00FF00);
    Gizmo.drawCircle(50, 50, 10, 0x0000FF);
    Gizmo.drawText(0, 0, "debug", 0xFFFFFF);
    Gizmo.drawLineBetween(.{ .x = 0, .y = 0 }, .{ .x = 100, .y = 100 }, 0xFF0000);

    try testing.expectEqual(2, StubGizmos.getLineCount());
    try testing.expectEqual(1, StubGizmos.getRectCount());
    try testing.expectEqual(1, StubGizmos.getCircleCount());
    try testing.expectEqual(1, StubGizmos.getTextCount());
}

test "RenderInterface(StubRender) validates" {
    const Renderer = StubRender(u32);
    _ = RenderInterface(Renderer);

    var r = Renderer.init(testing.allocator);
    defer r.deinit();

    r.trackEntity(1, .sprite);
    try testing.expectEqual(1, r.tracked_count);

    r.untrackEntity(1);
    try testing.expectEqual(0, r.tracked_count);

    r.render();
    try testing.expectEqual(1, r.render_count);

    r.setScreenHeight(600);
    r.clear();
    try testing.expectEqual(0, r.tracked_count);
}

test "StubRender: component types have expected fields" {
    const Renderer = StubRender(u32);
    const sprite = Renderer.Sprite{ .sprite_name = "hero" };
    try testing.expectEqualStrings("hero", sprite.sprite_name);

    const shape = Renderer.Shape{
        .shape = .{ .rectangle = .{ .width = 50, .height = 50 } },
        .color = .{ .r = 255, .g = 0, .b = 0, .a = 255 },
    };
    try testing.expect(shape.visible);
}

test "MockEcsBackend: single component query with data access" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const e = Ecs(MockEcsBackend(u32)){ .backend = &backend };

    const Pos = struct { x: f32, y: f32 };

    const e1 = e.createEntity();
    const e2 = e.createEntity();
    const e3 = e.createEntity();

    e.add(e1, Pos{ .x = 1, .y = 2 });
    e.add(e2, Pos{ .x = 3, .y = 4 });
    // e3 has no Pos

    _ = e3;

    var q = e.query(.{Pos});
    defer q.deinit();

    var count: usize = 0;
    var sum_x: f32 = 0;
    while (q.next()) |row| {
        sum_x += row.comp_0.x;
        count += 1;
    }
    try testing.expectEqual(2, count);
    try testing.expectEqual(4.0, sum_x); // 1 + 3
}

test "MockEcsBackend: multi-component query" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const e = Ecs(MockEcsBackend(u32)){ .backend = &backend };

    const Pos = struct { x: f32, y: f32 };
    const Health = struct { current: u32, max: u32 };

    const e1 = e.createEntity();
    const e2 = e.createEntity();
    const e3 = e.createEntity();

    // e1: Pos + Health
    e.add(e1, Pos{ .x = 10, .y = 20 });
    e.add(e1, Health{ .current = 100, .max = 100 });

    // e2: Pos only
    e.add(e2, Pos{ .x = 30, .y = 40 });

    // e3: Health only
    e.add(e3, Health{ .current = 50, .max = 50 });

    var q = e.query(.{ Pos, Health });
    defer q.deinit();

    var count: usize = 0;
    while (q.next()) |row| {
        try testing.expectEqual(10.0, row.comp_0.x);
        try testing.expectEqual(100, row.comp_1.current);
        count += 1;
    }
    try testing.expectEqual(1, count);
}

test "ParentComponent and ChildrenComponent" {
    const Parent = ParentComponent(u32);
    const Children = ChildrenComponent(u32);

    const p = Parent{ .entity = 42 };
    try testing.expectEqual(42, p.entity);
    try testing.expect(!p.inherit_rotation);

    const c = Children{};
    try testing.expectEqual(@as(usize, 0), c.count());
}

test "gameToScreen: converts Y-up to Y-down" {
    // Screen height 600: game y=0 (bottom) -> screen y=600 (bottom)
    try testing.expectEqual(@as(f32, 600.0), gameToScreen(0, 600));
    // game y=600 (top) -> screen y=0 (top)
    try testing.expectEqual(@as(f32, 0.0), gameToScreen(600, 600));
    // game y=100 -> screen y=500
    try testing.expectEqual(@as(f32, 500.0), gameToScreen(100, 600));
}

test "screenToGame: converts Y-down to Y-up" {
    // screen y=0 (top) -> game y=600 (top)
    try testing.expectEqual(@as(f32, 600.0), screenToGame(0, 600));
    // screen y=600 (bottom) -> game y=0 (bottom)
    try testing.expectEqual(@as(f32, 0.0), screenToGame(600, 600));
    // screen y=100 -> game y=500
    try testing.expectEqual(@as(f32, 500.0), screenToGame(100, 600));
}

test "gameToScreen and screenToGame are inverse operations" {
    const screen_height: f32 = 480;
    const original_y: f32 = 123.45;

    const screen_y = gameToScreen(original_y, screen_height);
    const round_trip = screenToGame(screen_y, screen_height);
    try testing.expectApproxEqAbs(original_y, round_trip, 0.001);
}

test "GamePosition.toScreen and ScreenPosition.toGame" {
    const game_pos = GamePosition{ .pos = .{ .x = 50, .y = 100 } };
    const screen_pos = game_pos.toScreen(600);

    try testing.expectEqual(@as(f32, 50.0), screen_pos.pos.x);
    try testing.expectEqual(@as(f32, 500.0), screen_pos.pos.y);

    const back = screen_pos.toGame(600);
    try testing.expectEqual(@as(f32, 50.0), back.pos.x);
    try testing.expectEqual(@as(f32, 100.0), back.pos.y);
}

test "CoordinateSystem enum values" {
    try testing.expect(CoordinateSystem.y_up != CoordinateSystem.y_down);
}

test "Query: single component with data access" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const e = Ecs(MockEcsBackend(u32)){ .backend = &backend };

    const Pos = struct { x: f32, y: f32 };

    const e1 = e.createEntity();
    const e2 = e.createEntity();
    e.add(e1, Pos{ .x = 10, .y = 20 });
    e.add(e2, Pos{ .x = 30, .y = 40 });

    var q = e.query(.{Pos});
    defer q.deinit();

    var count: usize = 0;
    var sum_x: f32 = 0;
    while (q.next()) |row| {
        sum_x += row.comp_0.x;
        count += 1;
    }
    try testing.expectEqual(2, count);
    try testing.expectEqual(40.0, sum_x); // 10 + 30
}

test "Query: multiple components with data access" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const e = Ecs(MockEcsBackend(u32)){ .backend = &backend };

    const Pos = struct { x: f32, y: f32 };
    const Vel = struct { dx: f32, dy: f32 };

    const e1 = e.createEntity();
    const e2 = e.createEntity();
    const e3 = e.createEntity();

    // e1 has both Pos and Vel
    e.add(e1, Pos{ .x = 1, .y = 2 });
    e.add(e1, Vel{ .dx = 10, .dy = 20 });

    // e2 has only Pos — should NOT appear in query(.{Pos, Vel})
    e.add(e2, Pos{ .x = 3, .y = 4 });

    // e3 has both
    e.add(e3, Pos{ .x = 5, .y = 6 });
    e.add(e3, Vel{ .dx = 50, .dy = 60 });

    var q = e.query(.{ Pos, Vel });
    defer q.deinit();

    var count: usize = 0;
    var sum_dx: f32 = 0;
    while (q.next()) |row| {
        // Verify both component pointers are accessible
        sum_dx += row.comp_1.dx;
        try testing.expect(row.comp_0.x > 0);
        count += 1;
    }
    try testing.expectEqual(2, count);
    try testing.expectEqual(60.0, sum_dx); // 10 + 50
}

test "Query: mutable pointers allow component modification" {
    var backend = MockEcsBackend(u32).init(testing.allocator);
    defer backend.deinit();

    const e = Ecs(MockEcsBackend(u32)){ .backend = &backend };

    const Pos = struct { x: f32, y: f32 };
    const Vel = struct { dx: f32, dy: f32 };

    const entity = e.createEntity();
    e.add(entity, Pos{ .x = 0, .y = 0 });
    e.add(entity, Vel{ .dx = 5, .dy = 10 });

    // Use query to modify position based on velocity
    var q = e.query(.{ Pos, Vel });
    defer q.deinit();

    while (q.next()) |row| {
        row.comp_0.x += row.comp_1.dx;
        row.comp_0.y += row.comp_1.dy;
    }

    // Verify modification persisted
    const pos = e.get(entity, Pos).?;
    try testing.expectEqual(5.0, pos.x);
    try testing.expectEqual(10.0, pos.y);
}

const CapturingLogSink = struct {
    const LogLevel = root.LogLevel;

    var last_level: ?LogLevel = null;
    var last_scope: []const u8 = "";
    var last_elapsed: f64 = 0;
    var call_count: usize = 0;

    pub fn write(
        level: LogLevel,
        comptime scope: []const u8,
        elapsed_s: f64,
        comptime _: []const u8,
        _: anytype,
    ) void {
        last_level = level;
        last_scope = scope;
        last_elapsed = elapsed_s;
        call_count += 1;
    }

    fn reset() void {
        last_level = null;
        last_scope = "";
        last_elapsed = 0;
        call_count = 0;
    }
};

test "LogSinkInterface forwards level, scope, and elapsed time to sink" {
    const Log = LogSinkInterface(CapturingLogSink);
    CapturingLogSink.reset();

    Log.write(.info, "player", 1.5, "spawned at ({d}, {d})", .{ 10, 20 });

    try testing.expectEqual(root.LogLevel.info, CapturingLogSink.last_level.?);
    try testing.expectEqualStrings("player", CapturingLogSink.last_scope);
    try testing.expectApproxEqAbs(@as(f64, 1.5), CapturingLogSink.last_elapsed, 1e-9);
    try testing.expectEqual(@as(usize, 1), CapturingLogSink.call_count);
}

test "LogSinkInterface tracks multiple writes" {
    const Log = LogSinkInterface(CapturingLogSink);
    CapturingLogSink.reset();

    Log.write(.debug, "physics", 0.0, "step", .{});
    Log.write(.warn, "audio", 2.5, "buffer underrun", .{});

    try testing.expectEqual(root.LogLevel.warn, CapturingLogSink.last_level.?);
    try testing.expectEqualStrings("audio", CapturingLogSink.last_scope);
    try testing.expectApproxEqAbs(@as(f64, 2.5), CapturingLogSink.last_elapsed, 1e-9);
    try testing.expectEqual(@as(usize, 2), CapturingLogSink.call_count);
}

test "LogSinkInterface with empty scope" {
    const Log = LogSinkInterface(CapturingLogSink);
    CapturingLogSink.reset();

    Log.write(.err, "", 0.123, "fatal", .{});

    try testing.expectEqual(root.LogLevel.err, CapturingLogSink.last_level.?);
    try testing.expectEqualStrings("", CapturingLogSink.last_scope);
}

test "StubLogSink is a valid LogSinkInterface implementation" {
    const Log = LogSinkInterface(StubLogSink);
    Log.write(.info, "test", 0.0, "{s}", .{"msg"});
    Log.flush();
}

test "StderrLogSink is a valid LogSinkInterface implementation" {
    // Validates the full write path compiles (format string + tuple concat).
    // Output goes to stderr which is expected in test runs.
    const Log = LogSinkInterface(StderrLogSink);
    Log.write(.debug, "test", 0.0, "compile check", .{});
}
