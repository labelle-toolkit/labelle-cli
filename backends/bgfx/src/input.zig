/// bgfx input backend — satisfies the engine InputInterface(Impl) contract.
/// Uses GLFW for input (bgfx doesn't provide input).
const glfw = @import("zglfw");

const MAX_KEYS = 512;
const MAX_MOUSE_BUTTONS = 8;

var keys_down: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS;
var keys_pressed: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS;
var keys_released: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS;

var mouse_down: [MAX_MOUSE_BUTTONS]bool = [_]bool{false} ** MAX_MOUSE_BUTTONS;
var mouse_pressed: [MAX_MOUSE_BUTTONS]bool = [_]bool{false} ** MAX_MOUSE_BUTTONS;
var mouse_released: [MAX_MOUSE_BUTTONS]bool = [_]bool{false} ** MAX_MOUSE_BUTTONS;

var mouse_x: f32 = 0;
var mouse_y: f32 = 0;
var mouse_wheel: f32 = 0;

var glfw_window: ?*glfw.Window = null;

/// Bind to a GLFW window for input polling.
pub fn setWindow(win: *glfw.Window) void {
    glfw_window = win;
    _ = win.setScrollCallback(scrollCallback);
}

fn scrollCallback(_: *glfw.Window, _: f64, yoffset: f64) callconv(.c) void {
    mouse_wheel = @floatCast(yoffset);
}

/// Call at the start of each frame to reset per-frame state and poll GLFW.
pub fn newFrame() void {
    keys_pressed = [_]bool{false} ** MAX_KEYS;
    keys_released = [_]bool{false} ** MAX_KEYS;
    mouse_pressed = [_]bool{false} ** MAX_MOUSE_BUTTONS;
    mouse_released = [_]bool{false} ** MAX_MOUSE_BUTTONS;
    mouse_wheel = 0;

    glfw.pollEvents();

    if (glfw_window) |win| {
        const pos = win.getCursorPos();
        mouse_x = @floatCast(pos[0]);
        mouse_y = @floatCast(pos[1]);
    }
}

// ── Keyboard ──────────────────────────────────────────────

pub fn isKeyDown(key: u32) bool {
    if (glfw_window) |win| {
        return win.getKey(@enumFromInt(key)) == .press;
    }
    return false;
}

pub fn isKeyPressed(key: u32) bool {
    return if (key < MAX_KEYS) keys_pressed[key] else false;
}

pub fn isKeyReleased(key: u32) bool {
    return if (key < MAX_KEYS) keys_released[key] else false;
}

// ── Mouse ─────────────────────────────────────────────────

pub fn getMouseX() f32 {
    return mouse_x;
}

pub fn getMouseY() f32 {
    return mouse_y;
}

pub fn isMouseButtonDown(button: u32) bool {
    if (glfw_window) |win| {
        return win.getMouseButton(@enumFromInt(button)) == .press;
    }
    return false;
}

pub fn isMouseButtonPressed(button: u32) bool {
    return if (button < MAX_MOUSE_BUTTONS) mouse_pressed[button] else false;
}

pub fn isMouseButtonReleased(button: u32) bool {
    return if (button < MAX_MOUSE_BUTTONS) mouse_released[button] else false;
}

pub fn getMouseWheelMove() f32 {
    return mouse_wheel;
}

// ── Touch ─────────────────────────────────────────────────

pub fn getTouchCount() u32 {
    return 0; // GLFW desktop: no touch support
}

pub fn getTouchX(index: u32) f32 {
    _ = index;
    return 0;
}

pub fn getTouchY(index: u32) f32 {
    _ = index;
    return 0;
}

pub fn getTouchId(index: u32) u64 {
    _ = index;
    return 0;
}

// ── Gamepad ───────────────────────────────────────────────

pub fn isGamepadAvailable(gamepad: u32) bool {
    return glfw.joystickPresent(@enumFromInt(gamepad));
}

pub fn isGamepadButtonDown(gamepad: u32, button: u32) bool {
    _ = gamepad;
    _ = button;
    return false; // TODO: GLFW joystick buttons
}

pub fn isGamepadButtonPressed(gamepad: u32, button: u32) bool {
    _ = gamepad;
    _ = button;
    return false;
}

pub fn getGamepadAxisValue(gamepad: u32, axis: u32) f32 {
    _ = gamepad;
    _ = axis;
    return 0;
}
