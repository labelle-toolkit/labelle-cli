const std = @import("std");
const gfx = @import("labelle-gfx");
const engine = @import("engine");

const testing = std.testing;

const MockBackend = gfx.MockBackend;
const MockEcsBackend = engine.MockEcsBackend;
const DefaultLayers = gfx.DefaultLayers;

// Construct mock renderer: GfxRenderer(MockBackend, DefaultLayers, u32)
const MockRenderer = gfx.GfxRenderer(MockBackend, DefaultLayers, MockEcsBackend(u32).Entity);
const Game = engine.GameConfig(MockRenderer, MockEcsBackend(u32), engine.StubInput, engine.StubAudio, engine.StubGui, void);

// ============================================================
// Assembler-defined backend — proves Backend(Impl) slot can be filled
// ============================================================

const AssemblerBackend = struct {
    pub const Texture = struct { id: u32, width: i32, height: i32 };
    pub const Color = struct { r: u8, g: u8, b: u8, a: u8 };
    pub const Rectangle = struct { x: f32, y: f32, width: f32, height: f32 };
    pub const Vector2 = struct { x: f32, y: f32 };
    pub const Camera2D = struct {
        offset: Vector2 = .{ .x = 0, .y = 0 },
        target: Vector2 = .{ .x = 0, .y = 0 },
        rotation: f32 = 0,
        zoom: f32 = 1,
    };

    pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const red = Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
    pub const green = Color{ .r = 0, .g = 255, .b = 0, .a = 255 };
    pub const blue = Color{ .r = 0, .g = 0, .b = 255, .a = 255 };
    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

    threadlocal var call_count: u32 = 0;

    pub fn drawTexturePro(_: Texture, _: Rectangle, _: Rectangle, _: Vector2, _: f32, _: Color) void {
        call_count += 1;
    }
    pub fn drawRectangleRec(_: Rectangle, _: Color) void {
        call_count += 1;
    }
    pub fn drawCircle(_: f32, _: f32, _: f32, _: Color) void {
        call_count += 1;
    }
    pub fn drawLine(_: f32, _: f32, _: f32, _: f32, _: f32, _: Color) void {
        call_count += 1;
    }
    pub fn drawText(_: [:0]const u8, _: f32, _: f32, _: f32, _: Color) void {
        call_count += 1;
    }
    pub fn loadTexture(_: [:0]const u8) !Texture {
        return .{ .id = 1, .width = 64, .height = 64 };
    }
    pub fn unloadTexture(_: Texture) void {}
    pub fn beginMode2D(_: Camera2D) void {}
    pub fn endMode2D() void {}
    pub fn getScreenWidth() i32 { return 320; }
    pub fn getScreenHeight() i32 { return 240; }
    pub fn screenToWorld(pos: Vector2, _: Camera2D) Vector2 { return pos; }
    pub fn worldToScreen(pos: Vector2, _: Camera2D) Vector2 { return pos; }

    pub fn resetCallCount() void { call_count = 0; }
    pub fn getCallCount() u32 { return call_count; }
};

// ============================================================
// Assembler-defined input/audio impls
// ============================================================

const AssemblerInput = struct {
    threadlocal var pressed_key: ?u32 = null;

    pub fn isKeyDown(key: u32) bool {
        return pressed_key != null and pressed_key.? == key;
    }
    pub fn isKeyPressed(key: u32) bool {
        return pressed_key != null and pressed_key.? == key;
    }
    pub fn getMouseX() f32 { return 123.0; }
    pub fn getMouseY() f32 { return 456.0; }
};

const AssemblerAudio = struct {
    threadlocal var last_sound_id: ?u32 = null;
    threadlocal var volume_val: f32 = 1.0;

    pub fn playSound(id: u32) void { last_sound_id = id; }
    pub fn stopSound(_: u32) void { last_sound_id = null; }
    pub fn setVolume(v: f32) void { volume_val = v; }
};

// ============================================================
// Integration Tests
// ============================================================

test "integration: full stack game lifecycle" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    const e1 = game.createEntity();
    game.addSprite(e1, .{ .sprite_name = "sprite_a" });
    game.setPosition(e1, .{ .x = 50, .y = 100 });

    const e2 = game.createEntity();
    game.addSprite(e2, .{ .sprite_name = "sprite_b" });
    game.setPosition(e2, .{ .x = 200, .y = 300 });

    game.tick(0.016);
    game.render();

    try testing.expect(MockBackend.getDrawCallCount() >= 2);
}

test "integration: entity destroy removes from renderer" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    const entity = game.createEntity();
    game.addSprite(entity, .{ .sprite_name = "temp" });
    game.setPosition(entity, .{ .x = 0, .y = 0 });

    game.tick(0.016);
    try testing.expect(game.renderer.hasEntity(entity));

    game.destroyEntity(entity);
    try testing.expect(!game.renderer.hasEntity(entity));
}

test "integration: hooks receive events across full stack" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    const MyHooks = struct {
        entity_count: u32 = 0,
        frame_count: u32 = 0,
        destroy_count: u32 = 0,

        pub fn entity_created(self: *@This(), _: anytype) void {
            self.entity_count += 1;
        }
        pub fn entity_destroyed(self: *@This(), _: anytype) void {
            self.destroy_count += 1;
        }
        pub fn frame_start(self: *@This(), _: anytype) void {
            self.frame_count += 1;
        }
    };

    var hooks = MyHooks{};
    const HookedGame = engine.GameConfig(MockRenderer, MockEcsBackend(u32), engine.StubInput, engine.StubAudio, engine.StubGui, *MyHooks);
    var game = HookedGame.init(testing.allocator);
    defer game.deinit();
    game.setHooks(&hooks);

    const e1 = game.createEntity();
    _ = game.createEntity();
    game.tick(0.016);
    game.destroyEntity(e1);

    try testing.expectEqual(2, hooks.entity_count);
    try testing.expectEqual(1, hooks.frame_count);
    try testing.expectEqual(1, hooks.destroy_count);
}

test "integration: input and audio interfaces compile with stubs" {
    const Input = engine.InputInterface(engine.StubInput);
    const Audio = engine.AudioInterface(engine.StubAudio);

    try testing.expect(!Input.isKeyDown(42));
    try testing.expect(!Input.isKeyPressed(42));
    try testing.expectEqual(0.0, Input.getMouseX());
    try testing.expectEqual(0.0, Input.getMouseY());

    Audio.playSound(1);
    Audio.stopSound(1);
    Audio.setVolume(0.75);
}

test "integration: assembler-defined backend fills Backend(Impl) slot" {
    const B = gfx.Backend(AssemblerBackend);
    try testing.expectEqual(320, B.getScreenWidth());
    try testing.expectEqual(240, B.getScreenHeight());

    // Wire through GfxRenderer into GameConfig
    const Renderer = gfx.GfxRenderer(AssemblerBackend, DefaultLayers, u32);
    const CustomGame = engine.GameConfig(Renderer, MockEcsBackend(u32), engine.StubInput, engine.StubAudio, engine.StubGui, void);

    var game = CustomGame.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.addSprite(e, .{ .sprite_name = "test" });
    game.setPosition(e, .{ .x = 10, .y = 20 });

    AssemblerBackend.resetCallCount();
    game.tick(0.016);
    game.render();
    try testing.expect(AssemblerBackend.getCallCount() > 0);
}

test "integration: assembler-defined input impl fills InputInterface slot" {
    const Input = engine.InputInterface(AssemblerInput);

    AssemblerInput.pressed_key = null;
    try testing.expect(!Input.isKeyDown(5));

    AssemblerInput.pressed_key = 5;
    try testing.expect(Input.isKeyDown(5));
    try testing.expect(!Input.isKeyDown(6));

    try testing.expectEqual(123.0, Input.getMouseX());
    try testing.expectEqual(456.0, Input.getMouseY());
}

test "integration: assembler-defined audio impl fills AudioInterface slot" {
    const Audio = engine.AudioInterface(AssemblerAudio);

    Audio.playSound(42);
    try testing.expectEqual(42, AssemblerAudio.last_sound_id.?);

    Audio.stopSound(42);
    try testing.expect(AssemblerAudio.last_sound_id == null);

    Audio.setVolume(0.3);
    try testing.expectEqual(0.3, AssemblerAudio.volume_val);
}

test "integration: game-level input/audio forwarding methods" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    const InputGame = engine.GameConfig(
        MockRenderer,
        MockEcsBackend(u32),
        AssemblerInput,
        AssemblerAudio,
        engine.StubGui,
        void,
    );

    var game = InputGame.init(testing.allocator);
    defer game.deinit();

    // Input forwarding
    AssemblerInput.pressed_key = 42;
    try testing.expect(game.isKeyDown(42));
    try testing.expect(!game.isKeyDown(99));
    try testing.expect(game.isKeyPressed(42));

    const mouse = game.getMouse();
    try testing.expectEqual(123.0, mouse.x);
    try testing.expectEqual(456.0, mouse.y);

    // Audio forwarding
    game.playSound(7);
    try testing.expectEqual(7, AssemblerAudio.last_sound_id.?);
    game.stopSound(7);
    try testing.expect(AssemblerAudio.last_sound_id == null);
    game.setVolume(0.5);
    try testing.expectEqual(0.5, AssemblerAudio.volume_val);
}

// ============================================================
// Scene management
// ============================================================

test "integration: scene management — register, load, switch" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    const loadScene1 = struct {
        fn load(g: *Game) anyerror!void {
            const e = g.createEntity();
            g.addSprite(e, .{ .sprite_name = "scene1_sprite" });
            g.setPosition(e, .{ .x = 10, .y = 10 });
        }
    }.load;

    const loadScene2 = struct {
        fn load(g: *Game) anyerror!void {
            const e = g.createEntity();
            g.addShape(e, .{
                .shape = .{ .rectangle = .{ .width = 40, .height = 40 } },
                .color = .{ .r = 0, .g = 255, .b = 0, .a = 255 },
            });
            g.setPosition(e, .{ .x = 50, .y = 50 });
        }
    }.load;

    game.registerSceneSimple("scene1", loadScene1);
    game.registerSceneSimple("scene2", loadScene2);

    try game.setScene("scene1");
    try testing.expectEqualStrings("scene1", game.getCurrentSceneName().?);
    try testing.expectEqual(1, game.entityCount());

    game.tick(0.016);
    game.render();
    try testing.expect(MockBackend.getDrawCallCount() > 0);

    try game.setScene("scene2");
    try testing.expectEqualStrings("scene2", game.getCurrentSceneName().?);
}

test "integration: scene queue — deferred scene change via tick" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    const loadScene = struct {
        fn load(g: *Game) anyerror!void {
            const e = g.createEntity();
            g.addSprite(e, .{ .sprite_name = "queued" });
            g.setPosition(e, .{ .x = 0, .y = 0 });
        }
    }.load;

    game.registerSceneSimple("target", loadScene);
    game.queueSceneChange("target");

    game.tick(0.016);
    try testing.expectEqualStrings("target", game.getCurrentSceneName().?);
}

// ============================================================
// Hierarchy — parent/child transforms
// ============================================================

test "integration: parent-child hierarchy with position inheritance" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.renderer.setScreenHeight(600);

    const parent = game.createEntity();
    game.addSprite(parent, .{ .sprite_name = "parent" });
    game.setPosition(parent, .{ .x = 100, .y = 100 });

    const child = game.createEntity();
    game.addSprite(child, .{ .sprite_name = "child" });
    game.setPosition(child, .{ .x = 20, .y = 30 });
    game.setParent(child, parent, .{});

    game.tick(0.016);
    game.render();

    // Both should be rendered
    const calls = MockBackend.getDrawCalls();
    try testing.expect(calls.len == 2);

    // Parent at (100, 600-100=500), child at (120, 600-130=470)
    var found_parent = false;
    var found_child = false;
    for (calls) |call| {
        if (std.math.approxEqAbs(f32, call.dest.x, 100.0, 1.0) and
            std.math.approxEqAbs(f32, call.dest.y, 500.0, 1.0))
        {
            found_parent = true;
        }
        if (std.math.approxEqAbs(f32, call.dest.x, 120.0, 1.0) and
            std.math.approxEqAbs(f32, call.dest.y, 470.0, 1.0))
        {
            found_child = true;
        }
    }
    try testing.expect(found_parent);
    try testing.expect(found_child);
}

test "integration: cascade destroy removes children" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    const parent = game.createEntity();
    game.addSprite(parent, .{ .sprite_name = "parent" });
    game.setPosition(parent, .{ .x = 0, .y = 0 });

    const child = game.createEntity();
    game.addSprite(child, .{ .sprite_name = "child" });
    game.setPosition(child, .{ .x = 10, .y = 10 });
    game.setParent(child, parent, .{});

    game.tick(0.016);
    try testing.expect(game.renderer.hasEntity(parent));
    try testing.expect(game.renderer.hasEntity(child));

    game.destroyEntity(parent);
    try testing.expect(!game.renderer.hasEntity(parent));
    try testing.expect(!game.renderer.hasEntity(child));
}

test "integration: removeParent detaches child" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    const parent = game.createEntity();
    game.setPosition(parent, .{ .x = 100, .y = 100 });

    const child = game.createEntity();
    game.addSprite(child, .{ .sprite_name = "child" });
    game.setPosition(child, .{ .x = 10, .y = 10 });
    game.setParent(child, parent, .{});

    try testing.expect(game.hasComponent(child, engine.ParentComponent(u32)));
    game.removeParent(child);
    try testing.expect(!game.hasComponent(child, engine.ParentComponent(u32)));
}

// ============================================================
// New component types
// ============================================================

test "integration: shape entities render correctly" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.addShape(e, .{
        .shape = .{ .rectangle = .{ .width = 50, .height = 50 } },
        .color = .{ .r = 255, .g = 0, .b = 0, .a = 255 },
    });
    game.setPosition(e, .{ .x = 200, .y = 300 });

    game.tick(0.016);
    game.render();

    try testing.expect(MockBackend.getShapeCallCount() > 0);
}

test "integration: z-index update marks visual dirty" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.addSprite(e, .{ .sprite_name = "layered" });
    game.setPosition(e, .{ .x = 0, .y = 0 });

    game.tick(0.016);

    game.setZIndex(e, 10);
    game.tick(0.016);
    game.render();

    try testing.expect(MockBackend.getDrawCallCount() > 0);
}

test "integration: generic component access" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    const Tag = struct { label: u32 };
    const e = game.createEntity();
    game.addComponent(e, Tag{ .label = 42 });

    const tag = game.getComponent(e, Tag);
    try testing.expect(tag != null);
    try testing.expectEqual(42, tag.?.label);

    try testing.expect(game.hasComponent(e, Tag));
    game.removeComponent(e, Tag);
    try testing.expect(!game.hasComponent(e, Tag));
}

// ============================================================
// GUI forwarding
// ============================================================

test "integration: GUI forwarding with stub backend" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    game.guiBegin();
    game.guiEnd();
    try testing.expect(!game.guiWantsMouse());
    try testing.expect(!game.guiWantsKeyboard());
}

test "integration: GUI assembler slot — custom GuiImpl fills GuiInterface" {
    const AssemblerGui = struct {
        threadlocal var began: bool = false;
        threadlocal var ended: bool = false;

        pub fn begin() void { began = true; }
        pub fn end() void { ended = true; }
        pub fn wantsMouse() bool { return true; }
        pub fn wantsKeyboard() bool { return false; }
    };

    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    const GuiGame = engine.GameConfig(
        MockRenderer,
        MockEcsBackend(u32),
        engine.StubInput,
        engine.StubAudio,
        AssemblerGui,
        void,
    );

    var game = GuiGame.init(testing.allocator);
    defer game.deinit();

    game.guiBegin();
    try testing.expect(AssemblerGui.began);
    game.guiEnd();
    try testing.expect(AssemblerGui.ended);
    try testing.expect(game.guiWantsMouse());
    try testing.expect(!game.guiWantsKeyboard());
}

// ============================================================
// Gizmo toggle / lifecycle
// ============================================================

test "integration: gizmo enable/disable" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    try testing.expect(game.isGizmosEnabled());
    game.setGizmosEnabled(false);
    try testing.expect(!game.isGizmosEnabled());
    game.setGizmosEnabled(true);
    try testing.expect(game.isGizmosEnabled());
}

test "integration: quit sets running to false" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    try testing.expect(game.isRunning());
    game.quit();
    try testing.expect(!game.isRunning());
}

// ============================================================
// Engine-owned types compile in CLI context
// ============================================================

test "integration: physics components compile" {
    const physics = @import("labelle-physics");
    const rb = physics.RigidBody{};
    try testing.expectEqual(physics.BodyType.dynamic, rb.body_type);
    try testing.expectEqual(1.0, rb.mass);

    var touching = physics.Touching{};
    touching.add(5);
    try testing.expect(touching.contains(5));
    touching.remove(5);
    try testing.expect(!touching.contains(5));
}

test "integration: sparse set compile and ops" {
    var set = try engine.SparseSet(f32).init(testing.allocator, 64, 16);
    defer set.deinit();

    try set.put(3, 42.0);
    try testing.expect(set.contains(3));
    try testing.expectEqual(42.0, set.get(3).?);

    set.remove(3);
    try testing.expect(!set.contains(3));
}

test "integration: GUI element types compile" {
    const label = engine.Label{ .text = "Hello" };
    try testing.expectEqualStrings("Hello", label.text);

    const btn = engine.Button{ .text = "Click", .id = "btn1" };
    try testing.expectEqualStrings("btn1", btn.id);

    const elem = engine.GuiElement{ .Label = label };
    try testing.expect(elem.isVisible());
}

test "integration: input types compile" {
    try testing.expectEqual(32, @intFromEnum(engine.KeyboardKey.space));
    try testing.expectEqual(0, @intFromEnum(engine.MouseButton.left));

    const touch = engine.Touch{};
    try testing.expectEqual(engine.TouchPhase.ended, touch.phase);
}

test "integration: audio types compile" {
    const sid = engine.SoundId{ .index = 1, .generation = 0 };
    try testing.expectEqual(1, sid.index);

    const mid = engine.MusicId{ .index = 0, .generation = 1 };
    try testing.expectEqual(1, mid.generation);
}

// ============================================================
// Dependency graph validation
// ============================================================

test "integration: dependency graph — GfxRenderer satisfies RenderInterface" {
    _ = engine.RenderInterface(MockRenderer);
}

test "integration: dependency graph — engine types come from core" {
    const core = @import("labelle-core");
    const core_pos = core.Position{ .x = 1, .y = 2 };
    const engine_pos: engine.Position = core_pos;
    try testing.expectEqual(core_pos.x, engine_pos.x);
    try testing.expectEqual(core_pos.y, engine_pos.y);

    const CoreEcs = core.MockEcsBackend(u32);
    const EngineEcs = engine.MockEcsBackend(u32);
    try testing.expect(@TypeOf(CoreEcs) == @TypeOf(EngineEcs));
}

// ============================================================
// Deterministic draw list
// ============================================================

test "integration: deterministic draw list — positions and Y-flip" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    var game = Game.init(testing.allocator);
    defer game.deinit();
    game.renderer.setScreenHeight(600);

    const entity = game.createEntity();
    game.addSprite(entity, .{ .sprite_name = "hero" });
    game.setPosition(entity, .{ .x = 100, .y = 200 });

    game.tick(0.016);
    game.render();

    const calls = MockBackend.getDrawCalls();
    try testing.expect(calls.len == 1);
    try testing.expectEqual(100.0, calls[0].dest.x);
    // Y-flip: screen_height(600) - game_y(200) = 400
    try testing.expectEqual(400.0, calls[0].dest.y);
}

test "integration: deterministic draw list — invisible sprites excluded" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    var game = Game.init(testing.allocator);
    defer game.deinit();

    const visible = game.createEntity();
    game.addSprite(visible, .{ .sprite_name = "visible_one" });
    game.setPosition(visible, .{ .x = 50, .y = 50 });

    const invisible = game.createEntity();
    game.addSprite(invisible, .{ .sprite_name = "hidden_one", .visible = false });
    game.setPosition(invisible, .{ .x = 999, .y = 999 });

    game.tick(0.016);
    game.render();

    const calls = MockBackend.getDrawCalls();
    try testing.expectEqual(1, calls.len);
    try testing.expectEqual(50.0, calls[0].dest.x);
}

// ============================================================
// GameConfig accepts custom RenderImpl from assembler
// ============================================================

test "integration: GameConfig accepts custom RenderImpl from assembler" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    const CustomRenderer = gfx.GfxRenderer(MockBackend, DefaultLayers, u32);
    const CustomGame = engine.GameConfig(
        CustomRenderer,
        MockEcsBackend(u32),
        engine.StubInput,
        engine.StubAudio,
        engine.StubGui,
        void,
    );

    var game = CustomGame.init(testing.allocator);
    defer game.deinit();

    const e = game.createEntity();
    game.addShape(e, .{
        .shape = .{ .rectangle = .{ .width = 50, .height = 50 } },
        .color = .{ .r = 255, .g = 0, .b = 0, .a = 255 },
    });
    game.setPosition(e, .{ .x = 100, .y = 100 });

    game.tick(0.016);
    game.render();

    try testing.expect(MockBackend.getShapeCallCount() > 0);
}
