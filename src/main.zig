const std = @import("std");
const gfx = @import("labelle-gfx");
const engine = @import("engine");

const MockBackend = gfx.MockBackend;
const MockEcsBackend = engine.MockEcsBackend;
const DefaultLayers = gfx.DefaultLayers;

// Construct mock renderer: GfxRenderer(MockBackend, DefaultLayers, u32)
const MockRenderer = gfx.GfxRenderer(MockBackend, DefaultLayers, MockEcsBackend(u32).Entity);
const Game = engine.GameConfig(MockRenderer, MockEcsBackend(u32), engine.StubInput, engine.StubAudio, engine.StubGui, void);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== labelle-cli assembler demo ===\n\n", .{});

    // --- Demo 1: Full stack wiring ---
    std.debug.print("1. Full stack wiring (engine + gfx + core)...\n", .{});
    {
        MockBackend.initMock(allocator);
        defer MockBackend.deinitMock();

        var game = Game.init(allocator);
        defer game.deinit();

        const player = game.createEntity();
        game.addSprite(player, .{ .sprite_name = "player" });
        game.setPosition(player, .{ .x = 100, .y = 200 });

        const tree = game.createEntity();
        game.addSprite(tree, .{ .sprite_name = "tree" });
        game.setPosition(tree, .{ .x = 300, .y = 150 });

        game.tick(0.016);
        game.render();

        const draw_count = MockBackend.getDrawCallCount();
        std.debug.print("   Created 2 entities, rendered {d} draw calls\n", .{draw_count});
        std.debug.assert(draw_count >= 2);
    }
    std.debug.print("   PASS\n\n", .{});

    // --- Demo 2: Hooks wiring ---
    std.debug.print("2. Hooks wiring (GameConfig custom hooks)...\n", .{});
    {
        MockBackend.initMock(allocator);
        defer MockBackend.deinitMock();

        const MyHooks = struct {
            entities: u32 = 0,
            frames: u32 = 0,

            pub fn entity_created(self: *@This(), _: anytype) void {
                self.entities += 1;
            }
            pub fn frame_start(self: *@This(), _: anytype) void {
                self.frames += 1;
            }
        };

        var hooks = MyHooks{};
        const HookedGame = engine.GameConfig(MockRenderer, MockEcsBackend(u32), engine.StubInput, engine.StubAudio, engine.StubGui, *MyHooks);
        var game = HookedGame.init(allocator);
        defer game.deinit();
        game.setHooks(&hooks);

        _ = game.createEntity();
        _ = game.createEntity();
        _ = game.createEntity();
        game.tick(0.016);
        game.tick(0.016);

        std.debug.print("   Created {d} entities, ran {d} frames\n", .{ hooks.entities, hooks.frames });
        std.debug.assert(hooks.entities == 3);
        std.debug.assert(hooks.frames == 2);
    }
    std.debug.print("   PASS\n\n", .{});

    // --- Demo 3: Input/Audio stubs compile ---
    std.debug.print("3. Input/Audio interface stubs...\n", .{});
    {
        const Input = engine.InputInterface(engine.StubInput);
        const Audio = engine.AudioInterface(engine.StubAudio);
        std.debug.assert(!Input.isKeyDown(0));
        std.debug.assert(!Input.isKeyPressed(0));
        std.debug.assert(Input.getMouseX() == 0);
        Audio.playSound(0);
        Audio.stopSound(0);
        Audio.setVolume(0.5);
    }
    std.debug.print("   PASS\n\n", .{});

    std.debug.print("=== All demos passed. Zero native dependencies. ===\n", .{});
}
