// Paused state script — press Escape again to resume playing.

pub fn tick(game: anytype, _: f32) void {
    if (game.isKeyPressed(.escape)) {
        game.setState("playing");
    }
}
