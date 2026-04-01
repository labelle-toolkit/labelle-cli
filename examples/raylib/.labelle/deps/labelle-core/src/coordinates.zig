/// Coordinate system convention for LaBelle.
///
/// The engine uses a Y-up coordinate system with the origin at bottom-left.
/// Game code always works in Y-up coordinates. Transforms between Y-up (game)
/// and Y-down (screen/render) happen at render and input boundaries only.
///
/// Backend implementations (raylib, sokol, SDL, etc.) use screen coordinates
/// (Y-down, origin at top-left). The helpers below convert between the two.

const position = @import("position.zig");
const Position = position.Position;

/// Which coordinate convention a value is expressed in.
pub const CoordinateSystem = enum {
    /// Game coordinates: origin at bottom-left, Y increases upward.
    /// This is the default for all game logic.
    y_up,

    /// Screen/render coordinates: origin at top-left, Y increases downward.
    /// Used by backends and low-level rendering.
    y_down,
};

/// A position explicitly tagged as being in game (Y-up) coordinate space.
/// Use this at API boundaries to make the coordinate system unambiguous.
pub const GamePosition = struct {
    pos: Position,

    pub fn toScreen(self: GamePosition, screen_height: f32) ScreenPosition {
        return .{ .pos = .{
            .x = self.pos.x,
            .y = gameToScreen(self.pos.y, screen_height),
        } };
    }
};

/// A position explicitly tagged as being in screen (Y-down) coordinate space.
/// Use this at API boundaries to make the coordinate system unambiguous.
pub const ScreenPosition = struct {
    pos: Position,

    pub fn toGame(self: ScreenPosition, screen_height: f32) GamePosition {
        return .{ .pos = .{
            .x = self.pos.x,
            .y = screenToGame(self.pos.y, screen_height),
        } };
    }
};

/// Convert a Y value from game coordinates (Y-up, origin bottom-left) to
/// screen coordinates (Y-down, origin top-left).
///
/// screen_y = screen_height - game_y
pub fn gameToScreen(y: f32, screen_height: f32) f32 {
    return screen_height - y;
}

/// Convert a Y value from screen coordinates (Y-down, origin top-left) to
/// game coordinates (Y-up, origin bottom-left).
///
/// game_y = screen_height - screen_y
pub fn screenToGame(y: f32, screen_height: f32) f32 {
    return screen_height - y;
}
