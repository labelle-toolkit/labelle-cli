// Menu state script — only runs when game state is "menu".
// Press Enter to switch to "playing" state and load the main scene.

pub fn tick(game: anytype, _: f32) void {
    if (game.isKeyPressed(.enter)) {
        game.setState("playing");
        game.queueSceneChange("main");
    }
}
