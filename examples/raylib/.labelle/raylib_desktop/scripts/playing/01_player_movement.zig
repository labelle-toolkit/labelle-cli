// Playing state script — moves the player with arrow keys.
// Numeric prefix 01_ controls execution order (runs first).

pub fn tick(game: anytype, dt: f32) void {
    const speed: f32 = 200.0;

    // Find player entity and move it
    const Player = @import("../../components/player.zig").Player;
    var view = game.ecs_backend.view(.{Player}, .{});
    defer view.deinit();

    while (view.next()) |entity| {
        var pos = game.getPosition(entity);
        if (game.isKeyDown(.right)) pos.x += speed * dt;
        if (game.isKeyDown(.left)) pos.x -= speed * dt;
        if (game.isKeyDown(.down)) pos.y += speed * dt;
        if (game.isKeyDown(.up)) pos.y -= speed * dt;
        game.setPosition(entity, pos);
    }
}
