// Playing state script — checks for Escape to pause.
// Numeric prefix 02_ means it runs after player movement.

pub fn tick(game: anytype, _: f32) void {
    if (game.isKeyPressed(.escape)) {
        game.setState("paused");
    }
}
