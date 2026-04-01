// Multi-state script — runs in both "playing" AND "paused" states.
// The + separator in the directory name binds to multiple states.

pub fn tick(game: anytype, _: f32) void {
    // Camera follows player in both playing and paused states
    const Player = @import("../../components/player.zig").Player;
    var view = game.ecs_backend.view(.{Player}, .{});
    defer view.deinit();

    if (view.next()) |entity| {
        const pos = game.getPosition(entity);
        game.getCamera().setPosition(pos.x, pos.y);
    }
}
