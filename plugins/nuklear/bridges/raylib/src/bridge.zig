/// Nuklear ↔ Raylib bridge — implements the nk_bridge_* symbol contract.
/// Manages the Nuklear context, feeds raylib input, and renders
/// Nuklear's command buffer using raylib draw calls.
const nk = @import("nuklear");
const rl = @import("raylib");

const c = nk.c;

var ctx: c.nk_context = undefined;
var atlas: c.nk_font_atlas = undefined;
var font_tex: rl.Texture = undefined;

export fn nk_bridge_init() void {
    // Init font atlas with default font
    c.nk_font_atlas_init_default(&atlas);
    c.nk_font_atlas_begin(&atlas);

    const default_font = c.nk_font_atlas_add_default(&atlas, 16, null);

    // Bake font atlas to RGBA image
    var img_w: c_int = undefined;
    var img_h: c_int = undefined;
    const img_data = c.nk_font_atlas_bake(&atlas, &img_w, &img_h, c.NK_FONT_ATLAS_RGBA32);

    // Upload to raylib texture
    const rl_img = rl.Image{
        .data = @constCast(@ptrCast(img_data)),
        .width = img_w,
        .height = img_h,
        .mipmaps = 1,
        .format = .uncompressed_r8g8b8a8,
    };
    font_tex = rl.loadTextureFromImage(rl_img) catch {
        @panic("nuklear bridge: failed to load font atlas texture");
    };

    // Finish atlas — pass the texture ID as a handle
    var null_tex: c.nk_draw_null_texture = undefined;
    c.nk_font_atlas_end(&atlas, c.nk_handle_id(@intCast(font_tex.id)), &null_tex);

    // Init context with default font
    _ = c.nk_init_default(&ctx, &default_font.*.handle);
}

export fn nk_bridge_shutdown() void {
    c.nk_free(&ctx);
    c.nk_font_atlas_clear(&atlas);
    rl.unloadTexture(font_tex);
}

export fn nk_bridge_begin() void {
    // Feed raylib input into nuklear
    c.nk_input_begin(&ctx);

    // Mouse position
    const mouse_pos = rl.getMousePosition();
    c.nk_input_motion(&ctx, @intFromFloat(mouse_pos.x), @intFromFloat(mouse_pos.y));

    // Mouse buttons
    const mx: c_int = @intFromFloat(mouse_pos.x);
    const my: c_int = @intFromFloat(mouse_pos.y);
    c.nk_input_button(&ctx, c.NK_BUTTON_LEFT, mx, my, rl.isMouseButtonDown(.left));
    c.nk_input_button(&ctx, c.NK_BUTTON_RIGHT, mx, my, rl.isMouseButtonDown(.right));
    c.nk_input_button(&ctx, c.NK_BUTTON_MIDDLE, mx, my, rl.isMouseButtonDown(.middle));

    // Scroll
    const scroll = rl.getMouseWheelMoveV();
    c.nk_input_scroll(&ctx, .{ .x = scroll.x, .y = scroll.y });

    // Keyboard — text input (drain the queue, multiple chars may be buffered per frame)
    while (true) {
        const ch = rl.getCharPressed();
        if (ch == 0) break;
        c.nk_input_unicode(&ctx, @intCast(ch));
    }

    // Key mappings
    c.nk_input_key(&ctx, c.NK_KEY_BACKSPACE, rl.isKeyDown(.backspace));
    c.nk_input_key(&ctx, c.NK_KEY_DEL, rl.isKeyDown(.delete));
    c.nk_input_key(&ctx, c.NK_KEY_LEFT, rl.isKeyDown(.left));
    c.nk_input_key(&ctx, c.NK_KEY_RIGHT, rl.isKeyDown(.right));
    c.nk_input_key(&ctx, c.NK_KEY_ENTER, rl.isKeyDown(.enter));

    c.nk_input_end(&ctx);
}

export fn nk_bridge_end() void {
    // Render nuklear command buffer using raylib draw calls
    var cmd: ?*const c.nk_command = c.nk__begin(&ctx);
    while (cmd) |command| : (cmd = c.nk__next(&ctx, command)) {
        switch (command.@"type") {
            c.NK_COMMAND_SCISSOR => {
                const s: *const c.nk_command_scissor = @ptrCast(@alignCast(command));
                rl.beginScissorMode(s.x, s.y, s.w, s.h);
            },
            c.NK_COMMAND_LINE => {
                const l: *const c.nk_command_line = @ptrCast(@alignCast(command));
                rl.drawLine(l.begin.x, l.begin.y, l.end.x, l.end.y, nkColorToRl(l.color));
            },
            c.NK_COMMAND_RECT => {
                const r: *const c.nk_command_rect = @ptrCast(@alignCast(command));
                rl.drawRectangleLines(r.x, r.y, r.w, r.h, nkColorToRl(r.color));
            },
            c.NK_COMMAND_RECT_FILLED => {
                const r: *const c.nk_command_rect_filled = @ptrCast(@alignCast(command));
                rl.drawRectangle(r.x, r.y, r.w, r.h, nkColorToRl(r.color));
            },
            c.NK_COMMAND_CIRCLE => {
                const ci: *const c.nk_command_circle = @ptrCast(@alignCast(command));
                const cx: f32 = @as(f32, @floatFromInt(ci.x)) + @as(f32, @floatFromInt(ci.w)) / 2;
                const cy: f32 = @as(f32, @floatFromInt(ci.y)) + @as(f32, @floatFromInt(ci.h)) / 2;
                const radius: f32 = @as(f32, @floatFromInt(ci.w)) / 2;
                rl.drawCircleLines(@intFromFloat(cx), @intFromFloat(cy), radius, nkColorToRl(ci.color));
            },
            c.NK_COMMAND_CIRCLE_FILLED => {
                const ci: *const c.nk_command_circle_filled = @ptrCast(@alignCast(command));
                const cx: f32 = @as(f32, @floatFromInt(ci.x)) + @as(f32, @floatFromInt(ci.w)) / 2;
                const cy: f32 = @as(f32, @floatFromInt(ci.y)) + @as(f32, @floatFromInt(ci.h)) / 2;
                const radius: f32 = @as(f32, @floatFromInt(ci.w)) / 2;
                rl.drawCircle(@intFromFloat(cx), @intFromFloat(cy), radius, nkColorToRl(ci.color));
            },
            c.NK_COMMAND_TRIANGLE_FILLED => {
                const t: *const c.nk_command_triangle_filled = @ptrCast(@alignCast(command));
                rl.drawTriangle(
                    .{ .x = @floatFromInt(t.a.x), .y = @floatFromInt(t.a.y) },
                    .{ .x = @floatFromInt(t.b.x), .y = @floatFromInt(t.b.y) },
                    .{ .x = @floatFromInt(t.c.x), .y = @floatFromInt(t.c.y) },
                    nkColorToRl(t.color),
                );
            },
            c.NK_COMMAND_TEXT => {
                const t: *const c.nk_command_text = @ptrCast(@alignCast(command));
                const text_ptr: [*]const u8 = @ptrCast(&t.string);
                const text_len: usize = @intCast(t.length);
                if (text_len > 0) {
                    // Use raylib's default font for simplicity
                    const text_slice = text_ptr[0..text_len];
                    // Null-terminate for raylib
                    var buf: [256]u8 = undefined;
                    const len = @min(text_len, buf.len - 1);
                    @memcpy(buf[0..len], text_slice[0..len]);
                    buf[len] = 0;
                    rl.drawText(@ptrCast(&buf), t.x, t.y, @intFromFloat(t.height), nkColorToRl(t.foreground));
                }
            },
            c.NK_COMMAND_NOP => {},
            else => {}, // Unhandled commands (curve, arc, polygon, image)
        }
    }
    rl.endScissorMode();
    c.nk_clear(&ctx);
}

export fn nk_bridge_get_context() *c.nk_context {
    return &ctx;
}

fn nkColorToRl(color: c.nk_color) rl.Color {
    return .{
        .r = color.r,
        .g = color.g,
        .b = color.b,
        .a = color.a,
    };
}
