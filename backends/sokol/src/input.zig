/// Sokol input backend — satisfies the engine InputInterface(Impl) contract.
/// Uses sokol_app events for keyboard/mouse/touch state.
const sokol = @import("sokol");
const sapp = sokol.app;

// ── State ─────────────────────────────────────────────────

var keys_down: [512]bool = [_]bool{false} ** 512;
var keys_pressed: [512]bool = [_]bool{false} ** 512;
var keys_released: [512]bool = [_]bool{false} ** 512;
var mouse_x: f32 = 0;
var mouse_y: f32 = 0;
var mouse_buttons_down: [3]bool = [_]bool{false} ** 3;
var mouse_buttons_pressed: [3]bool = [_]bool{false} ** 3;
var mouse_buttons_released: [3]bool = [_]bool{false} ** 3;
var mouse_wheel: f32 = 0;

const MAX_TOUCHES = 10;
var touch_count: u32 = 0;
var touch_xs: [MAX_TOUCHES]f32 = [_]f32{0} ** MAX_TOUCHES;
var touch_ys: [MAX_TOUCHES]f32 = [_]f32{0} ** MAX_TOUCHES;
var touch_ids: [MAX_TOUCHES]u64 = [_]u64{0} ** MAX_TOUCHES;

// ── Keyboard ──────────────────────────────────────────────

pub fn isKeyDown(key: u32) bool {
    if (key >= 512) return false;
    return keys_down[key];
}

pub fn isKeyPressed(key: u32) bool {
    if (key >= 512) return false;
    return keys_pressed[key];
}

pub fn isKeyReleased(key: u32) bool {
    if (key >= 512) return false;
    return keys_released[key];
}

// ── Mouse ─────────────────────────────────────────────────

pub fn getMouseX() f32 {
    return mouse_x;
}

pub fn getMouseY() f32 {
    return mouse_y;
}

pub fn isMouseButtonDown(btn: u32) bool {
    if (btn >= 3) return false;
    return mouse_buttons_down[btn];
}

pub fn isMouseButtonPressed(btn: u32) bool {
    if (btn >= 3) return false;
    return mouse_buttons_pressed[btn];
}

pub fn isMouseButtonReleased(btn: u32) bool {
    if (btn >= 3) return false;
    return mouse_buttons_released[btn];
}

pub fn getMouseWheelMove() f32 {
    return mouse_wheel;
}

// ── Touch ─────────────────────────────────────────────────

pub fn getTouchCount() u32 {
    return touch_count;
}

pub fn getTouchX(index: u32) f32 {
    if (index >= MAX_TOUCHES) return 0;
    return touch_xs[index];
}

pub fn getTouchY(index: u32) f32 {
    if (index >= MAX_TOUCHES) return 0;
    return touch_ys[index];
}

pub fn getTouchId(index: u32) u64 {
    if (index >= MAX_TOUCHES) return 0;
    return touch_ids[index];
}

// ── Gamepad (not available via sokol_app — return defaults) ─

pub fn isGamepadAvailable(_: u32) bool {
    return false;
}

pub fn isGamepadButtonDown(_: u32, _: u32) bool {
    return false;
}

pub fn isGamepadButtonPressed(_: u32, _: u32) bool {
    return false;
}

pub fn getGamepadAxisValue(_: u32, _: u32) f32 {
    return 0;
}

// ── Event handling ────────────────────────────────────────

/// Call from the sokol event callback to feed input state.
pub fn handleEvent(ev: [*c]const sapp.Event) void {
    switch (ev.*.type) {
        .KEY_DOWN => {
            const ki: i32 = @intFromEnum(ev.*.key_code);
            if (ki >= 0 and ki < 512) {
                const k: usize = @intCast(ki);
                keys_down[k] = true;
                keys_pressed[k] = true;
            }
        },
        .KEY_UP => {
            const ki: i32 = @intFromEnum(ev.*.key_code);
            if (ki >= 0 and ki < 512) {
                const k: usize = @intCast(ki);
                keys_down[k] = false;
                keys_released[k] = true;
            }
        },
        .MOUSE_MOVE => {
            mouse_x = ev.*.mouse_x;
            mouse_y = ev.*.mouse_y;
        },
        .MOUSE_DOWN => {
            const bi: i32 = @intFromEnum(ev.*.mouse_button);
            if (bi >= 0 and bi < 3) {
                const b: usize = @intCast(bi);
                mouse_buttons_down[b] = true;
                mouse_buttons_pressed[b] = true;
            }
        },
        .MOUSE_UP => {
            const bi: i32 = @intFromEnum(ev.*.mouse_button);
            if (bi >= 0 and bi < 3) {
                const b: usize = @intCast(bi);
                mouse_buttons_down[b] = false;
                mouse_buttons_released[b] = true;
            }
        },
        .MOUSE_SCROLL => {
            mouse_wheel = ev.*.scroll_y;
        },
        .TOUCHES_BEGAN, .TOUCHES_MOVED, .TOUCHES_ENDED, .TOUCHES_CANCELLED => {
            touch_count = @intCast(ev.*.num_touches);
            for (0..@intCast(ev.*.num_touches)) |i| {
                if (i >= MAX_TOUCHES) break;
                touch_xs[i] = ev.*.touches[i].pos_x;
                touch_ys[i] = ev.*.touches[i].pos_y;
                touch_ids[i] = @intCast(ev.*.touches[i].identifier);
            }
            if (ev.*.type == .TOUCHES_ENDED or ev.*.type == .TOUCHES_CANCELLED) {
                touch_count = 0;
            }
        },
        else => {},
    }
}

/// Re-export Event type for consumers that need it (e.g., GUI adapters).
pub const Event = sapp.Event;

/// Clear per-frame state (call at start of each frame).
pub fn newFrame() void {
    keys_pressed = [_]bool{false} ** 512;
    keys_released = [_]bool{false} ** 512;
    mouse_buttons_pressed = [_]bool{false} ** 3;
    mouse_buttons_released = [_]bool{false} ** 3;
    mouse_wheel = 0;
}
