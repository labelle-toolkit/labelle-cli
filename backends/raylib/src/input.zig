/// Raylib input backend — satisfies the engine InputInterface(Impl) contract.
const rl = @import("raylib");

// ── Keyboard ──────────────────────────────────────────────

pub fn isKeyDown(key: u32) bool {
    return rl.isKeyDown(@enumFromInt(key));
}

pub fn isKeyPressed(key: u32) bool {
    return rl.isKeyPressed(@enumFromInt(key));
}

pub fn isKeyReleased(key: u32) bool {
    return rl.isKeyReleased(@enumFromInt(key));
}

// ── Mouse ─────────────────────────────────────────────────

pub fn getMouseX() f32 {
    return @floatFromInt(rl.getMouseX());
}

pub fn getMouseY() f32 {
    return @floatFromInt(rl.getMouseY());
}

pub fn isMouseButtonDown(button: u32) bool {
    return rl.isMouseButtonDown(@enumFromInt(button));
}

pub fn isMouseButtonPressed(button: u32) bool {
    return rl.isMouseButtonPressed(@enumFromInt(button));
}

pub fn isMouseButtonReleased(button: u32) bool {
    return rl.isMouseButtonReleased(@enumFromInt(button));
}

pub fn getMouseWheelMove() f32 {
    return rl.getMouseWheelMove();
}

// ── Touch ─────────────────────────────────────────────────

pub fn getTouchCount() u32 {
    const count = rl.getTouchPointCount();
    return if (count > 0) @intCast(count) else 0;
}

pub fn getTouchX(index: u32) f32 {
    return @floatFromInt(rl.getTouchX(@intCast(index)));
}

pub fn getTouchY(index: u32) f32 {
    return @floatFromInt(rl.getTouchY(@intCast(index)));
}

pub fn getTouchId(index: u32) u64 {
    return @intCast(rl.getTouchPointId(@intCast(index)));
}

// ── Gamepad ───────────────────────────────────────────────

pub fn isGamepadAvailable(gamepad: u32) bool {
    return rl.isGamepadAvailable(@intCast(gamepad));
}

pub fn isGamepadButtonDown(gamepad: u32, button: u32) bool {
    return rl.isGamepadButtonDown(@intCast(gamepad), @enumFromInt(button));
}

pub fn isGamepadButtonPressed(gamepad: u32, button: u32) bool {
    return rl.isGamepadButtonPressed(@intCast(gamepad), @enumFromInt(button));
}

pub fn getGamepadAxisValue(gamepad: u32, axis: u32) f32 {
    return rl.getGamepadAxisMovement(@intCast(gamepad), @enumFromInt(axis));
}
