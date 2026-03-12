/// SDL2 input backend — satisfies the engine InputInterface(Impl) contract.
/// Event-driven: call handleEvent() from the SDL event loop, then query state.
const c = @import("sdl").c;

const MAX_KEYS = 512;
const MAX_MOUSE_BUTTONS = 7;
const MAX_TOUCHES = 10;

var keys_down: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS;
var keys_pressed: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS;
var keys_released: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS;

var mouse_down: [MAX_MOUSE_BUTTONS]bool = [_]bool{false} ** MAX_MOUSE_BUTTONS;
var mouse_pressed: [MAX_MOUSE_BUTTONS]bool = [_]bool{false} ** MAX_MOUSE_BUTTONS;
var mouse_released: [MAX_MOUSE_BUTTONS]bool = [_]bool{false} ** MAX_MOUSE_BUTTONS;

var mouse_x: f32 = 0;
var mouse_y: f32 = 0;
var mouse_wheel: f32 = 0;

/// Call at the start of each frame to reset per-frame state.
pub fn newFrame() void {
    keys_pressed = [_]bool{false} ** MAX_KEYS;
    keys_released = [_]bool{false} ** MAX_KEYS;
    mouse_pressed = [_]bool{false} ** MAX_MOUSE_BUTTONS;
    mouse_released = [_]bool{false} ** MAX_MOUSE_BUTTONS;
    mouse_wheel = 0;
}

/// Process an SDL event and update input state.
pub fn handleEvent(event: *const c.SDL_Event) void {
    switch (event.type) {
        c.SDL_KEYDOWN => {
            const code: u32 = @intCast(event.key.keysym.scancode);
            if (code < MAX_KEYS) {
                keys_down[code] = true;
                keys_pressed[code] = true;
            }
        },
        c.SDL_KEYUP => {
            const code: u32 = @intCast(event.key.keysym.scancode);
            if (code < MAX_KEYS) {
                keys_down[code] = false;
                keys_released[code] = true;
            }
        },
        c.SDL_MOUSEMOTION => {
            mouse_x = @floatFromInt(event.motion.x);
            mouse_y = @floatFromInt(event.motion.y);
        },
        c.SDL_MOUSEBUTTONDOWN => {
            const btn: u32 = @intCast(event.button.button);
            if (btn < MAX_MOUSE_BUTTONS) {
                mouse_down[btn] = true;
                mouse_pressed[btn] = true;
            }
        },
        c.SDL_MOUSEBUTTONUP => {
            const btn: u32 = @intCast(event.button.button);
            if (btn < MAX_MOUSE_BUTTONS) {
                mouse_down[btn] = false;
                mouse_released[btn] = true;
            }
        },
        c.SDL_MOUSEWHEEL => {
            mouse_wheel = @floatFromInt(event.wheel.y);
        },
        else => {},
    }
}

// ── Keyboard ──────────────────────────────────────────────

pub fn isKeyDown(key: u32) bool {
    return if (key < MAX_KEYS) keys_down[key] else false;
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
    return if (button < MAX_MOUSE_BUTTONS) mouse_down[button] else false;
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
    return 0;
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
    _ = gamepad;
    return false;
}

pub fn isGamepadButtonDown(gamepad: u32, button: u32) bool {
    _ = gamepad;
    _ = button;
    return false;
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
