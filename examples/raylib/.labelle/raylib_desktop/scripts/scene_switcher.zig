// Global script — runs in ALL states.
// Handles scene transitions and hot reload (F5).

pub fn tick(game: anytype, _: f32) void {
    // F5 = hot reload current scene
    if (game.isKeyPressed(.f5)) {
        game.requestReload();
    }
}
