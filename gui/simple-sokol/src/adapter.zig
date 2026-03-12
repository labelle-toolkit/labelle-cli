/// Simple immediate-mode GUI backend for sokol.
/// Draws buttons, panels, labels, and other widgets using sokol_gl quads.
/// Satisfies the engine GuiInterface contract (begin/end/wantsMouse).
///
/// Since sokol uses event-based input, call feedEvent() from your event callback
/// and newFrame() at the start of each frame.
const sokol = @import("sokol");
const sgl = sokol.gl;
const sapp = sokol.app;

var hot_id: u32 = 0;
var mouse_x: f32 = 0;
var mouse_y: f32 = 0;
var mouse_down: bool = false;
var mouse_pressed: bool = false;

/// Call at the start of each frame to clear per-frame state.
pub fn newFrame() void {
    mouse_pressed = false;
}

/// Feed mouse events from the sokol event callback.
pub fn feedEvent(ev: [*c]const sapp.Event) void {
    switch (ev.*.type) {
        .MOUSE_MOVE => {
            mouse_x = ev.*.mouse_x;
            mouse_y = ev.*.mouse_y;
        },
        .MOUSE_DOWN => {
            if (ev.*.mouse_button == .LEFT) {
                mouse_down = true;
                mouse_pressed = true;
            }
        },
        .MOUSE_UP => {
            if (ev.*.mouse_button == .LEFT) {
                mouse_down = false;
            }
        },
        else => {},
    }
}

pub fn begin() void {
    hot_id = 0;
}

pub fn end() void {}

pub fn wantsMouse() bool {
    return hot_id != 0;
}

pub fn wantsKeyboard() bool {
    return false;
}

// ── Coordinate helpers (screen pixels to NDC) ───────────────

fn toNdcX(px: f32) f32 {
    const fw: f32 = @floatFromInt(sapp.width());
    return (px / fw) * 2.0 - 1.0;
}

fn toNdcY(px: f32) f32 {
    const fh: f32 = @floatFromInt(sapp.height());
    return 1.0 - (px / fh) * 2.0;
}

fn drawRect(x: f32, y: f32, w: f32, h: f32, r: u8, g: u8, b: u8, a: u8) void {
    const x0 = toNdcX(x);
    const y0 = toNdcY(y);
    const x1 = toNdcX(x + w);
    const y1 = toNdcY(y + h);

    sgl.beginQuads();
    sgl.c4b(r, g, b, a);
    sgl.v2f(x0, y0);
    sgl.v2f(x1, y0);
    sgl.v2f(x1, y1);
    sgl.v2f(x0, y1);
    sgl.end();
}

fn drawRectOutline(x: f32, y: f32, w: f32, h: f32, r: u8, g: u8, b: u8, a: u8) void {
    const t: f32 = 1.0;
    drawRect(x, y, w, t, r, g, b, a);
    drawRect(x, y + h - t, w, t, r, g, b, a);
    drawRect(x, y, t, h, r, g, b, a);
    drawRect(x + w - t, y, t, h, r, g, b, a);
}

// ── Widget API ──────────────────────────────────────────────

pub fn button(id: u32, _: [:0]const u8, x: i32, y: i32, w: i32, h: i32) bool {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);

    const over = mouse_x >= fx and mouse_x < fx + fw and mouse_y >= fy and mouse_y < fy + fh;

    if (over) hot_id = id;

    if (over and mouse_down) {
        drawRect(fx, fy, fw, fh, 60, 60, 60, 240);
    } else if (over) {
        drawRect(fx, fy, fw, fh, 100, 100, 100, 240);
    } else {
        drawRect(fx, fy, fw, fh, 70, 70, 70, 220);
    }
    drawRectOutline(fx, fy, fw, fh, 200, 200, 200, 255);

    // No text rendering in sokol_gl — draw a lighter bar as label placeholder
    const bar_y = fy + @as(f32, @floatFromInt(@divTrunc(h, 2))) - 3;
    drawRect(fx + 4, bar_y, fw - 8, 6, 200, 200, 200, 180);

    return over and mouse_pressed;
}

pub fn panel(x: i32, y: i32, w: i32, h: i32) void {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    drawRect(fx, fy, fw, fh, 40, 40, 40, 200);
    drawRectOutline(fx, fy, fw, fh, 120, 120, 120, 255);
}

pub fn label(_: [:0]const u8, x: i32, y: i32, _: i32, r: u8, g: u8, b: u8) void {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    // Placeholder bar (no text rendering without a font atlas)
    drawRect(fx, fy + 4, 40, 8, r, g, b, 200);
}

pub fn progressBar(x: i32, y: i32, w: i32, h: i32, value: f32, r: u8, g: u8, b: u8) void {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);

    // Background
    drawRect(fx, fy, fw, fh, 30, 30, 30, 220);
    // Fill
    const clamped = @max(0.0, @min(1.0, value));
    const fill_w = fw * clamped;
    if (fill_w > 0) {
        drawRect(fx, fy, fill_w, fh, r, g, b, 255);
    }
    // Border
    drawRectOutline(fx, fy, fw, fh, 120, 120, 120, 255);
}

pub fn slider(id: u32, x: i32, y: i32, w: i32, h: i32, value: f32, min_val: f32, max_val: f32) f32 {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);

    const over = mouse_x >= fx and mouse_x < fx + fw and mouse_y >= fy and mouse_y < fy + fh;
    if (over) hot_id = id;

    // Track
    drawRect(fx, fy, fw, fh, 30, 30, 30, 220);
    drawRectOutline(fx, fy, fw, fh, 120, 120, 120, 255);

    var current = value;
    const range = max_val - min_val;

    // Handle drag
    if (over and mouse_down and range > 0) {
        const t = @max(0.0, @min(1.0, (mouse_x - fx) / fw));
        current = min_val + t * range;
    }

    // Thumb
    if (range > 0) {
        const t = @max(0.0, @min(1.0, (current - min_val) / range));
        const thumb_x = fx + fw * t - 4;
        const c: u8 = if (over) 200 else 160;
        drawRect(thumb_x, fy - 2, 8, fh + 4, c, c, c, 255);
    }

    return current;
}

pub fn checkbox(id: u32, _: [:0]const u8, x: i32, y: i32, checked: bool) bool {
    const fx: f32 = @floatFromInt(x);
    const fy: f32 = @floatFromInt(y);
    const box_size: f32 = 18;

    const over = mouse_x >= fx and mouse_x < fx + box_size and mouse_y >= fy and mouse_y < fy + box_size;
    if (over) hot_id = id;

    // Box
    if (over) {
        drawRect(fx, fy, box_size, box_size, 80, 80, 80, 240);
    } else {
        drawRect(fx, fy, box_size, box_size, 50, 50, 50, 220);
    }
    drawRectOutline(fx, fy, box_size, box_size, 200, 200, 200, 255);

    // Checkmark (filled inner square)
    if (checked) {
        drawRect(fx + 4, fy + 4, box_size - 8, box_size - 8, 100, 200, 100, 255);
    }

    // Label placeholder bar
    drawRect(fx + box_size + 6, fy + 5, 40, 8, 200, 200, 200, 200);

    return over and mouse_pressed;
}

// ── Dev Overlay ─────────────────────────────────────────────

pub fn devOverlay(_: i32, _: u32, _: u32) void {
    // Dev overlay with stats — rendered as colored bars since sokol has no text.
    const ox: f32 = 8;
    const oy: f32 = 8;
    const pw: f32 = 120;
    const ph: f32 = 50;

    // Background
    drawRect(ox, oy, pw, ph, 0, 0, 0, 180);
    drawRectOutline(ox, oy, pw, ph, 80, 80, 80, 200);

    // Placeholder bars for stats
    drawRect(ox + 8, oy + 8, 40, 6, 100, 255, 100, 255);
    drawRect(ox + 8, oy + 22, 60, 6, 200, 200, 200, 255);
    drawRect(ox + 8, oy + 36, 50, 6, 200, 200, 200, 255);
}
