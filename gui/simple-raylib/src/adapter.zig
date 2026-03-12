/// Simple immediate-mode GUI backend for raylib.
/// Draws buttons, panels, labels, and other widgets using raylib primitives.
/// Satisfies the engine GuiInterface contract (begin/end/wantsMouse).
const rl = @import("raylib");

var hot_id: u32 = 0;

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

// ── Widget API (game code calls these through GuiBackend) ───────

pub fn button(id: u32, text: [:0]const u8, x: i32, y: i32, w: i32, h: i32) bool {
    const mx = rl.getMouseX();
    const my = rl.getMouseY();
    const over = mx >= x and mx < x + w and my >= y and my < y + h;

    if (over) hot_id = id;

    const pressed = over and rl.isMouseButtonDown(.left);
    const bg: rl.Color = if (pressed)
        .{ .r = 60, .g = 60, .b = 60, .a = 240 }
    else if (over)
        .{ .r = 100, .g = 100, .b = 100, .a = 240 }
    else
        .{ .r = 70, .g = 70, .b = 70, .a = 220 };

    rl.drawRectangle(x, y, w, h, bg);
    rl.drawRectangleLines(x, y, w, h, .{ .r = 200, .g = 200, .b = 200, .a = 255 });
    rl.drawText(text, x + 10, y + @divTrunc(h - 16, 2), 16, .{ .r = 255, .g = 255, .b = 255, .a = 255 });

    return over and rl.isMouseButtonPressed(.left);
}

pub fn panel(x: i32, y: i32, w: i32, h: i32) void {
    rl.drawRectangle(x, y, w, h, .{ .r = 40, .g = 40, .b = 40, .a = 200 });
    rl.drawRectangleLines(x, y, w, h, .{ .r = 120, .g = 120, .b = 120, .a = 255 });
}

pub fn label(text: [:0]const u8, x: i32, y: i32, size: i32, r: u8, g: u8, b: u8) void {
    rl.drawText(text, x, y, size, .{ .r = r, .g = g, .b = b, .a = 255 });
}

pub fn progressBar(x: i32, y: i32, w: i32, h: i32, value: f32, r: u8, g: u8, b: u8) void {
    // Background
    rl.drawRectangle(x, y, w, h, .{ .r = 30, .g = 30, .b = 30, .a = 220 });
    // Fill
    const clamped = @max(0.0, @min(1.0, value));
    const fill_w: i32 = @intFromFloat(@as(f32, @floatFromInt(w)) * clamped);
    if (fill_w > 0) {
        rl.drawRectangle(x, y, fill_w, h, .{ .r = r, .g = g, .b = b, .a = 255 });
    }
    // Border
    rl.drawRectangleLines(x, y, w, h, .{ .r = 120, .g = 120, .b = 120, .a = 255 });
}

pub fn slider(id: u32, x: i32, y: i32, w: i32, h: i32, value: f32, min_val: f32, max_val: f32) f32 {
    const mx = rl.getMouseX();
    const my = rl.getMouseY();
    const over = mx >= x and mx < x + w and my >= y and my < y + h;

    if (over) hot_id = id;

    // Background track
    rl.drawRectangle(x, y, w, h, .{ .r = 30, .g = 30, .b = 30, .a = 220 });
    rl.drawRectangleLines(x, y, w, h, .{ .r = 120, .g = 120, .b = 120, .a = 255 });

    var current = value;
    const range = max_val - min_val;

    // Handle drag
    if (over and rl.isMouseButtonDown(.left) and range > 0) {
        const fx: f32 = @floatFromInt(x);
        const fw: f32 = @floatFromInt(w);
        const fmx: f32 = @floatFromInt(mx);
        const t = @max(0.0, @min(1.0, (fmx - fx) / fw));
        current = min_val + t * range;
    }

    // Thumb position
    if (range > 0) {
        const t = @max(0.0, @min(1.0, (current - min_val) / range));
        const thumb_x: i32 = x + @as(i32, @intFromFloat(@as(f32, @floatFromInt(w)) * t)) - 4;
        const thumb_color: rl.Color = if (over) .{ .r = 200, .g = 200, .b = 200, .a = 255 } else .{ .r = 160, .g = 160, .b = 160, .a = 255 };
        rl.drawRectangle(thumb_x, y - 2, 8, h + 4, thumb_color);
    }

    return current;
}

pub fn checkbox(id: u32, text: [:0]const u8, x: i32, y: i32, checked: bool) bool {
    const box_size: i32 = 18;
    const mx = rl.getMouseX();
    const my = rl.getMouseY();
    const over = mx >= x and mx < x + box_size and my >= y and my < y + box_size;

    if (over) hot_id = id;

    // Box
    const bg: rl.Color = if (over)
        .{ .r = 80, .g = 80, .b = 80, .a = 240 }
    else
        .{ .r = 50, .g = 50, .b = 50, .a = 220 };
    rl.drawRectangle(x, y, box_size, box_size, bg);
    rl.drawRectangleLines(x, y, box_size, box_size, .{ .r = 200, .g = 200, .b = 200, .a = 255 });

    // Checkmark
    if (checked) {
        rl.drawRectangle(x + 4, y + 4, box_size - 8, box_size - 8, .{ .r = 100, .g = 200, .b = 100, .a = 255 });
    }

    // Label
    rl.drawText(text, x + box_size + 6, y + 1, 16, .{ .r = 220, .g = 220, .b = 220, .a = 255 });

    // Toggle on click
    return over and rl.isMouseButtonPressed(.left);
}

// ── Dev Overlay ─────────────────────────────────────────────

pub fn devOverlay(fps: i32, entity_count: u32, draw_calls: u32) void {
    const ox: i32 = 8;
    const oy: i32 = 8;
    const pw: i32 = 180;
    const ph: i32 = 70;

    // Background panel
    rl.drawRectangle(ox, oy, pw, ph, .{ .r = 0, .g = 0, .b = 0, .a = 180 });
    rl.drawRectangleLines(ox, oy, pw, ph, .{ .r = 80, .g = 80, .b = 80, .a = 200 });

    // FPS
    var fps_buf: [32]u8 = undefined;
    const fps_str = std.fmt.bufPrint(&fps_buf, "FPS: {d}", .{fps}) catch "FPS: ?";
    fps_buf[fps_str.len] = 0;
    const fps_z: [:0]const u8 = fps_buf[0..fps_str.len :0];
    const fps_color: rl.Color = if (fps >= 55) .{ .r = 100, .g = 255, .b = 100, .a = 255 } else if (fps >= 30) .{ .r = 255, .g = 255, .b = 100, .a = 255 } else .{ .r = 255, .g = 100, .b = 100, .a = 255 };
    rl.drawText(fps_z, ox + 8, oy + 6, 16, fps_color);

    // Entity count
    var ent_buf: [32]u8 = undefined;
    const ent_str = std.fmt.bufPrint(&ent_buf, "Entities: {d}", .{entity_count}) catch "Entities: ?";
    ent_buf[ent_str.len] = 0;
    const ent_z: [:0]const u8 = ent_buf[0..ent_str.len :0];
    rl.drawText(ent_z, ox + 8, oy + 26, 16, .{ .r = 200, .g = 200, .b = 200, .a = 255 });

    // Draw calls
    var dc_buf: [32]u8 = undefined;
    const dc_str = std.fmt.bufPrint(&dc_buf, "Draw calls: {d}", .{draw_calls}) catch "Draw calls: ?";
    dc_buf[dc_str.len] = 0;
    const dc_z: [:0]const u8 = dc_buf[0..dc_str.len :0];
    rl.drawText(dc_z, ox + 8, oy + 46, 16, .{ .r = 200, .g = 200, .b = 200, .a = 255 });
}

const std = @import("std");
