/// Compile-time test — proves the game/ hooks compile and wire correctly
/// with mock backends (zero native deps). This tests the types that the
/// assembler-generated main.zig would use.
const std = @import("std");
const engine = @import("engine");
const gfx = @import("labelle-gfx");
const game = @import("game");

const MockBackend = gfx.MockBackend;

const EcsBackend = engine.MockEcsBackend(u32);

/// Test layers — in the real build, GameLayers is generated from project.labelle.
const TestLayers = enum(u8) {
    background,
    world,
    ui,

    pub fn config(self: TestLayers) gfx.LayerConfig {
        return switch (self) {
            .background => .{ .order = 0, .space = .screen },
            .world => .{ .order = 1, .space = .world },
            .ui => .{ .order = 2, .space = .screen },
        };
    }
};

const MockRenderer = gfx.GfxRenderer(MockBackend, TestLayers, EcsBackend.Entity);

const AssembledGame = engine.GameConfig(
    MockRenderer,
    EcsBackend,
    engine.StubInput,
    engine.StubAudio,
    engine.StubGui,
    *game.GameHooks,
);

const testing = std.testing;

test "game: hooks compile with mock backends" {
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    var hooks = game.GameHooks{};
    var g = AssembledGame.init(testing.allocator);
    defer g.deinit();
    g.setHooks(&hooks);
    g.renderer.setScreenHeight(600);

    g.tick(0.016);
    g.render();

    try testing.expect(hooks.ticks >= 1);
}
