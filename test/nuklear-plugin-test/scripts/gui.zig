const GuiBackend = @import("gui_backend");
const nk = GuiBackend.nk;
const c = nk.c;

var slider_val: f32 = 0.5;
var checkbox_val: bool = false;
var counter: i32 = 0;
var text_buf: [128]u8 = [_]u8{0} ** 128;
var text_len: c_int = 0;

pub fn drawGui(g: anytype) void {
    _ = g;

    const ctx = GuiBackend.getContext();

    // Main window
    if (c.nk_begin(ctx, "Nuklear Plugin Test", .{ .x = 20, .y = 20, .w = 350, .h = 450 }, c.NK_WINDOW_BORDER | c.NK_WINDOW_MOVABLE | c.NK_WINDOW_SCALABLE | c.NK_WINDOW_TITLE | c.NK_WINDOW_MINIMIZABLE)) {
        // Header
        c.nk_layout_row_dynamic(ctx, 25, 1);
        c.nk_label(ctx, "Hello from the Nuklear plugin!", c.NK_TEXT_LEFT);
        c.nk_label(ctx, "Three-layer: backend + plugin + bridge", c.NK_TEXT_LEFT);

        c.nk_layout_row_dynamic(ctx, 5, 1);
        c.nk_spacing(ctx, 1);

        // Buttons
        c.nk_layout_row_dynamic(ctx, 25, 1);
        c.nk_label(ctx, "--- Buttons ---", c.NK_TEXT_CENTERED);
        c.nk_layout_row_static(ctx, 30, 100, 2);
        if (c.nk_button_label(ctx, "Click me!")) {
            counter += 1;
        }
        if (c.nk_button_label(ctx, "Reset")) {
            counter = 0;
        }
        c.nk_layout_row_dynamic(ctx, 25, 1);
        var buf: [64]u8 = undefined;
        const label = std.fmt.bufPrintZ(&buf, "Counter: {d}", .{counter}) catch "?";
        c.nk_label(ctx, label.ptr, c.NK_TEXT_LEFT);

        c.nk_layout_row_dynamic(ctx, 5, 1);
        c.nk_spacing(ctx, 1);

        // Slider
        c.nk_layout_row_dynamic(ctx, 25, 1);
        c.nk_label(ctx, "--- Slider ---", c.NK_TEXT_CENTERED);
        c.nk_layout_row_dynamic(ctx, 25, 1);
        _ = c.nk_slider_float(ctx, 0.0, &slider_val, 1.0, 0.01);
        var sbuf: [32]u8 = undefined;
        const slabel = std.fmt.bufPrintZ(&sbuf, "Value: {d:.2}", .{slider_val}) catch "?";
        c.nk_label(ctx, slabel.ptr, c.NK_TEXT_LEFT);

        c.nk_layout_row_dynamic(ctx, 5, 1);
        c.nk_spacing(ctx, 1);

        // Checkbox
        c.nk_layout_row_dynamic(ctx, 25, 1);
        c.nk_label(ctx, "--- Checkbox ---", c.NK_TEXT_CENTERED);
        c.nk_layout_row_dynamic(ctx, 25, 1);
        _ = c.nk_checkbox_label(ctx, "Enable feature", &checkbox_val);
        if (checkbox_val) {
            c.nk_label_colored(ctx, "Feature is ON", c.NK_TEXT_LEFT, c.nk_rgb(0, 255, 0));
        }

        c.nk_layout_row_dynamic(ctx, 5, 1);
        c.nk_spacing(ctx, 1);

        // Text input
        c.nk_layout_row_dynamic(ctx, 25, 1);
        c.nk_label(ctx, "--- Text Input ---", c.NK_TEXT_CENTERED);
        c.nk_layout_row_dynamic(ctx, 30, 1);
        _ = c.nk_edit_string(ctx, c.NK_EDIT_FIELD, &text_buf, &text_len, text_buf.len, null);

        // Progress bar
        c.nk_layout_row_dynamic(ctx, 5, 1);
        c.nk_spacing(ctx, 1);
        c.nk_layout_row_dynamic(ctx, 25, 1);
        c.nk_label(ctx, "--- Progress ---", c.NK_TEXT_CENTERED);
        c.nk_layout_row_dynamic(ctx, 20, 1);
        var progress: c.nk_size = @intFromFloat(slider_val * 100);
        _ = c.nk_progress(ctx, &progress, 100, false); // false = NK_FIXED
    }
    c.nk_end(ctx);

    // Second window
    if (c.nk_begin(ctx, "About", .{ .x = 400, .y = 20, .w = 280, .h = 150 }, c.NK_WINDOW_BORDER | c.NK_WINDOW_MOVABLE | c.NK_WINDOW_TITLE)) {
        c.nk_layout_row_dynamic(ctx, 25, 1);
        c.nk_label(ctx, "Nuklear 4.12.8", c.NK_TEXT_LEFT);
        c.nk_label(ctx, "Raylib backend bridge", c.NK_TEXT_LEFT);
        c.nk_label(ctx, "Zero engine changes!", c.NK_TEXT_LEFT);
    }
    c.nk_end(ctx);
}

const std = @import("std");
