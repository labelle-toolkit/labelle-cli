/// Sokol gfx backend — satisfies the labelle-gfx Backend(Impl) contract.
/// Uses sokol_gl for immediate-mode 2D drawing with real texture support.
const std = @import("std");
const sokol = @import("sokol");
const sgl = sokol.gl;
const sg = sokol.gfx;

// ── Backend types ──────────────────────────────────────────────────────

pub const Texture = struct {
    id: u32 = 0,
    img: sg.Image = .{},
    view: sg.View = .{},
    smp: sg.Sampler = .{},
    width: i32 = 0,
    height: i32 = 0,
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const Rectangle = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const Vector2 = struct {
    x: f32,
    y: f32,
};

pub const Camera2D = struct {
    offset: Vector2 = .{ .x = 0, .y = 0 },
    target: Vector2 = .{ .x = 0, .y = 0 },
    rotation: f32 = 0,
    zoom: f32 = 1,
};

// ── Color constants ────────────────────────────────────────────────────

pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
pub const red = Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
pub const green = Color{ .r = 0, .g = 255, .b = 0, .a = 255 };
pub const blue = Color{ .r = 0, .g = 0, .b = 255, .a = 255 };
pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

pub fn color(r: u8, g: u8, b: u8, a: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

// ── Screen dimensions (set by the app's frame callback) ─────────────

var screen_w: i32 = 800;
var screen_h: i32 = 600;

pub fn setScreenSize(w: i32, h: i32) void {
    screen_w = w;
    screen_h = h;
}

// ── Camera state ────────────────────────────────────────────────────

var active_camera: Camera2D = .{};
var camera_active: bool = false;

// ── Coordinate helpers ──────────────────────────────────────────────

/// Convert screen-space pixel coordinates to NDC (-1..1) for sokol_gl.
/// When a camera is active, applies forward transform: (world - target) * zoom + offset.
fn toNdcX(px: f32) f32 {
    if (!camera_active) {
        return (px / @as(f32, @floatFromInt(screen_w))) * 2.0 - 1.0;
    }
    const cam = active_camera;
    const screen_x = (px - cam.target.x) * cam.zoom + cam.offset.x;
    return (screen_x / @as(f32, @floatFromInt(screen_w))) * 2.0 - 1.0;
}

fn toNdcY(py: f32) f32 {
    const fh = @as(f32, @floatFromInt(screen_h));
    if (!camera_active) {
        return 1.0 - (py / fh) * 2.0;
    }
    const cam = active_camera;
    // Positions arrive in screen-space (Y-flipped by renderer.toScreenY).
    // Undo the flip to get world Y-up, apply camera with inverted Y
    // (screen Y-down vs world Y-up), then convert to NDC.
    const world_y = fh - py;
    const screen_y = -(world_y - cam.target.y) * cam.zoom + cam.offset.y;
    return 1.0 - (screen_y / fh) * 2.0;
}

// ── Draw primitives (Backend contract) ─────────────────────────────────

pub fn drawTexturePro(texture: Texture, source: Rectangle, dest: Rectangle, origin: Vector2, rotation: f32, tint: Color) void {
    // Guard against division by zero
    if (texture.width == 0 or texture.height == 0) return;

    // Calculate UV coordinates from the source rectangle
    const tex_width: f32 = @floatFromInt(texture.width);
    const tex_height: f32 = @floatFromInt(texture.height);

    const uv0 =source.x / tex_width;
    const tv0 =source.y / tex_height;
    const uv1 =(source.x + source.width) / tex_width;
    const tv1 =(source.y + source.height) / tex_height;

    // Tint as floats (0.0 - 1.0)
    const r: f32 = @as(f32, @floatFromInt(tint.r)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt(tint.g)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(tint.b)) / 255.0;
    const a: f32 = @as(f32, @floatFromInt(tint.a)) / 255.0;

    // Enable texturing and bind the image + sampler directly
    sgl.enableTexture();
    sgl.texture(texture.view, texture.smp);

    if (rotation != 0) {
        // Rotation path: translate to dest origin, rotate, draw at local coords
        const dx = dest.x;
        const dy = dest.y;
        const dw = dest.width;
        const dh = dest.height;

        // Convert to NDC for the pivot point
        const pivot_ndc_x = toNdcX(dx);
        const pivot_ndc_y = toNdcY(dy);
        // Calculate NDC scale factors using toNdcX/toNdcY difference so camera zoom applies consistently
        const ndc_w = toNdcX(dx + dw) - toNdcX(dx);
        const ndc_h = toNdcY(dy) - toNdcY(dy + dh); // positive height in NDC (Y flipped)
        const ndc_ox = toNdcX(dx + origin.x) - toNdcX(dx);
        const ndc_oy = toNdcY(dy) - toNdcY(dy + origin.y);

        sgl.pushMatrix();
        sgl.translate(pivot_ndc_x, pivot_ndc_y, 0);
        sgl.rotate(rotation * std.math.pi / 180.0, 0, 0, 1);
        sgl.translate(-ndc_ox, ndc_oy, 0); // Y flipped in NDC

        sgl.beginQuads();
        sgl.v2fT2fC4f(0, 0, uv0, tv0, r, g, b, a);
        sgl.v2fT2fC4f(ndc_w, 0, uv1, tv0, r, g, b, a);
        sgl.v2fT2fC4f(ndc_w, -ndc_h, uv1, tv1, r, g, b, a);
        sgl.v2fT2fC4f(0, -ndc_h, uv0, tv1, r, g, b, a);
        sgl.end();

        sgl.popMatrix();
    } else {
        // Fast path: no rotation, draw directly in NDC
        const dx = dest.x - origin.x;
        const dy = dest.y - origin.y;

        const x0 = toNdcX(dx);
        const y0 = toNdcY(dy);
        const x1 = toNdcX(dx + dest.width);
        const y1 = toNdcY(dy + dest.height);

        sgl.beginQuads();
        sgl.v2fT2fC4f(x0, y0, uv0, tv0, r, g, b, a);
        sgl.v2fT2fC4f(x1, y0, uv1, tv0, r, g, b, a);
        sgl.v2fT2fC4f(x1, y1, uv1, tv1, r, g, b, a);
        sgl.v2fT2fC4f(x0, y1, uv0, tv1, r, g, b, a);
        sgl.end();
    }

    sgl.disableTexture();
}

pub fn drawRectangleRec(rec: Rectangle, tint: Color) void {
    const x0 = toNdcX(rec.x);
    const y0 = toNdcY(rec.y);
    const x1 = toNdcX(rec.x + rec.width);
    const y1 = toNdcY(rec.y + rec.height);

    sgl.beginQuads();
    sgl.c4b(tint.r, tint.g, tint.b, tint.a);
    sgl.v2f(x0, y0);
    sgl.v2f(x1, y0);
    sgl.v2f(x1, y1);
    sgl.v2f(x0, y1);
    sgl.end();
}

pub fn drawCircle(center_x: f32, center_y: f32, radius: f32, tint: Color) void {
    const segments = 32;
    const cx = toNdcX(center_x);
    const cy = toNdcY(center_y);
    // Convert radius to NDC scale
    const fw: f32 = @floatFromInt(screen_w);
    const rx = (radius / fw) * 2.0;
    const ry = (radius / @as(f32, @floatFromInt(screen_h))) * 2.0;

    sgl.beginTriangleStrip();
    sgl.c4b(tint.r, tint.g, tint.b, tint.a);
    for (0..segments + 1) |i| {
        const angle = @as(f32, @floatFromInt(i)) * (2.0 * 3.14159265) / @as(f32, @floatFromInt(segments));
        const next_angle = @as(f32, @floatFromInt(i + 1)) * (2.0 * 3.14159265) / @as(f32, @floatFromInt(segments));
        sgl.v2f(cx, cy);
        sgl.v2f(cx + @cos(angle) * rx, cy + @sin(angle) * ry);
        sgl.v2f(cx + @cos(next_angle) * rx, cy + @sin(next_angle) * ry);
    }
    sgl.end();
}

pub fn drawLine(start_x: f32, start_y: f32, end_x: f32, end_y: f32, _: f32, tint: Color) void {
    sgl.beginLines();
    sgl.c4b(tint.r, tint.g, tint.b, tint.a);
    sgl.v2f(toNdcX(start_x), toNdcY(start_y));
    sgl.v2f(toNdcX(end_x), toNdcY(end_y));
    sgl.end();
}

/// Draw text using an embedded bitmap font atlas.
/// Renders printable ASCII characters (32..126) as textured quads via sokol_gl.
/// The font is a simple 8x8 pixel monospaced bitmap font.
pub fn drawText(text: [:0]const u8, x: f32, y: f32, size: f32, tint: Color) void {
    if (text.len == 0) return;

    // Lazily initialize the font atlas on first use
    if (!font_initialized) {
        initFontAtlas();
        font_initialized = true;
    }

    // If font failed to initialize, skip rendering
    if (font_image.id == 0) return;

    const r: f32 = @as(f32, @floatFromInt(tint.r)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt(tint.g)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(tint.b)) / 255.0;
    const a: f32 = @as(f32, @floatFromInt(tint.a)) / 255.0;

    // Scale factor: default font is 8px, scale to requested size
    const scale = size / 8.0;
    const char_w = 8.0 * scale;
    const char_h = 8.0 * scale;

    sgl.enableTexture();
    sgl.texture(font_view, font_sampler);

    sgl.beginQuads();

    var cursor_x = x;
    for (text) |ch| {
        if (ch == 0) break;
        // Only render printable ASCII (32..126)
        if (ch >= 32 and ch <= 126) {
            const glyph_index: u32 = @as(u32, ch) - 32;
            // Atlas is 16 columns x 6 rows of 8x8 glyphs in a 128x48 texture
            const col: f32 = @floatFromInt(glyph_index % 16);
            const row: f32 = @floatFromInt(glyph_index / 16);

            const uv0 =col * 8.0 / 128.0;
            const tv0 =row * 8.0 / 48.0;
            const uv1 =(col + 1.0) * 8.0 / 128.0;
            const tv1 =(row + 1.0) * 8.0 / 48.0;

            const x0 = toNdcX(cursor_x);
            const y0 = toNdcY(y);
            const x1 = toNdcX(cursor_x + char_w);
            const y1 = toNdcY(y + char_h);

            sgl.v2fT2fC4f(x0, y0, uv0, tv0, r, g, b, a);
            sgl.v2fT2fC4f(x1, y0, uv1, tv0, r, g, b, a);
            sgl.v2fT2fC4f(x1, y1, uv1, tv1, r, g, b, a);
            sgl.v2fT2fC4f(x0, y1, uv0, tv1, r, g, b, a);
        }
        cursor_x += char_w;
    }

    sgl.end();
    sgl.disableTexture();
}

pub fn loadTexture(path: [:0]const u8) !Texture {
    // Read the file from disk
    const file = std.fs.cwd().openFileZ(path, .{}) catch return error.LoadFailed;
    defer file.close();

    const stat = file.stat() catch return error.LoadFailed;
    const file_size = stat.size;
    if (file_size == 0 or file_size > 256 * 1024 * 1024) return error.LoadFailed;

    const data = file.readToEndAlloc(std.heap.page_allocator, @intCast(file_size)) catch return error.LoadFailed;
    defer std.heap.page_allocator.free(data);

    // Parse as a simple uncompressed format. We support:
    // - Raw RGBA data is not self-describing, so we support TGA (uncompressed) and BMP
    // - For production use, integrate stb_image or zigimg
    // Try TGA first (common in game dev), then BMP
    if (tryLoadTga(data)) |result| {
        return result;
    }
    if (tryLoadBmp(data)) |result| {
        return result;
    }

    // If nothing worked, try treating it as raw RGBA if the size is a perfect square
    const pixel_count = data.len / 4;
    if (data.len % 4 == 0 and pixel_count > 0) {
        const side_f = std.math.sqrt(@as(f32, @floatFromInt(pixel_count)));
        const side: usize = @intFromFloat(side_f);
        if (side * side == pixel_count) {
            return createTextureFromRgba(data, @intCast(side), @intCast(side));
        }
    }

    return error.LoadFailed;
}

pub fn unloadTexture(texture: Texture) void {
    if (texture.view.id != 0) {
        sg.destroyView(texture.view);
    }
    if (texture.img.id != 0) {
        sg.destroyImage(texture.img);
    }
    if (texture.smp.id != 0) {
        sg.destroySampler(texture.smp);
    }
}

pub fn beginMode2D(camera: Camera2D) void {
    active_camera = camera;
    camera_active = true;
}

pub fn endMode2D() void {
    camera_active = false;
}

pub fn getScreenWidth() i32 {
    return screen_w;
}

pub fn getScreenHeight() i32 {
    return screen_h;
}

pub fn screenToWorld(pos: Vector2, camera: Camera2D) Vector2 {
    return .{
        .x = (pos.x - camera.offset.x) / camera.zoom + camera.target.x,
        // Y is inverted: screen Y-down, world Y-up
        .y = camera.target.y - (pos.y - camera.offset.y) / camera.zoom,
    };
}

pub fn worldToScreen(pos: Vector2, camera: Camera2D) Vector2 {
    return .{
        .x = (pos.x - camera.target.x) * camera.zoom + camera.offset.x,
        // Y is inverted: world Y-up, screen Y-down
        .y = -(pos.y - camera.target.y) * camera.zoom + camera.offset.y,
    };
}

// ── Texture creation helper ─────────────────────────────────────────────

fn createTextureFromRgba(pixels: []const u8, width: i32, height: i32) !Texture {
    var img_desc: sg.ImageDesc = .{
        .width = width,
        .height = height,
        .pixel_format = .RGBA8,
    };
    img_desc.data.mip_levels[0] = .{
        .ptr = pixels.ptr,
        .size = pixels.len,
    };

    const img = sg.makeImage(img_desc);
    if (img.id == 0) return error.LoadFailed;

    const smp = sg.makeSampler(.{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });

    if (smp.id == 0) {
        sg.destroyImage(img);
        return error.LoadFailed;
    }

    const view = sg.makeView(.{ .texture = .{ .image = img } });
    if (view.id == 0) {
        sg.destroySampler(smp);
        sg.destroyImage(img);
        return error.LoadFailed;
    }

    return Texture{
        .id = img.id,
        .img = img,
        .view = view,
        .smp = smp,
        .width = width,
        .height = height,
    };
}

// ── TGA loader (uncompressed, 32-bit RGBA) ──────────────────────────────

fn tryLoadTga(data: []const u8) ?Texture {
    // Minimal TGA header is 18 bytes
    if (data.len < 18) return null;

    const image_type = data[2];
    // Only support uncompressed true-color (type 2)
    if (image_type != 2) return null;

    const width: i32 = @as(i32, @intCast(data[12])) | (@as(i32, @intCast(data[13])) << 8);
    const height: i32 = @as(i32, @intCast(data[14])) | (@as(i32, @intCast(data[15])) << 8);
    const bpp = data[16];
    if (bpp != 32 and bpp != 24) return null;

    const id_length: usize = data[0];
    const color_map_length: usize = @as(usize, @intCast(data[5])) | (@as(usize, @intCast(data[6])) << 8);
    const entry_size: usize = if (data[7] != 0) @as(usize, data[7]) else 0;
    const pixel_offset = 18 + id_length + color_map_length * (entry_size / 8);
    const bytes_per_pixel: usize = @as(usize, bpp) / 8;
    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const pixel_data_size = std.math.mul(usize, std.math.mul(usize, w, h) catch return null, bytes_per_pixel) catch return null;

    if (data.len < pixel_offset + pixel_data_size) return null;

    // Convert BGR(A) to RGBA and flip vertically (TGA is bottom-up by default)
    const rgba_size = std.math.mul(usize, std.math.mul(usize, w, h) catch return null, 4) catch return null;
    const rgba = std.heap.page_allocator.alloc(u8, rgba_size) catch return null;

    const descriptor = data[17];
    const top_to_bottom = (descriptor & 0x20) != 0;

    for (0..h) |row| {
        const src_row = if (top_to_bottom) row else (h - 1 - row);
        for (0..w) |col| {
            const src_idx = pixel_offset + (src_row * w + col) * bytes_per_pixel;
            const dst_idx = (row * w + col) * 4;
            // TGA stores as BGRA
            rgba[dst_idx + 0] = data[src_idx + 2]; // R
            rgba[dst_idx + 1] = data[src_idx + 1]; // G
            rgba[dst_idx + 2] = data[src_idx + 0]; // B
            rgba[dst_idx + 3] = if (bpp == 32) data[src_idx + 3] else 255; // A
        }
    }

    defer std.heap.page_allocator.free(rgba);
    return createTextureFromRgba(rgba, width, height) catch null;
}

// ── BMP loader (uncompressed, 24/32-bit) ────────────────────────────────

fn tryLoadBmp(data: []const u8) ?Texture {
    // Check BMP signature
    if (data.len < 54) return null;
    if (data[0] != 'B' or data[1] != 'M') return null;

    const pixel_offset: usize = @as(usize, @intCast(std.mem.readInt(u32, data[10..14], .little)));
    const width: i32 = @bitCast(std.mem.readInt(u32, data[18..22], .little));
    const height_raw: i32 = @bitCast(std.mem.readInt(u32, data[22..26], .little));
    const bpp: u16 = std.mem.readInt(u16, data[28..30], .little);
    const compression: u32 = std.mem.readInt(u32, data[30..34], .little);

    // Only support uncompressed (BI_RGB = 0); reject BI_BITFIELDS since we don't read the masks
    if (compression != 0) return null;
    if (bpp != 24 and bpp != 32) return null;
    if (width <= 0) return null;

    const bottom_up = height_raw > 0;
    const height: i32 = if (height_raw == std.math.minInt(i32)) return null else if (height_raw < 0) -height_raw else height_raw;

    const w: usize = @intCast(width);
    const h: usize = @intCast(height);
    const bytes_per_pixel: usize = @as(usize, bpp) / 8;
    // BMP rows are padded to 4-byte boundaries
    const row_size = std.math.mul(usize, w, bytes_per_pixel) catch return null;
    const row_stride = (row_size + 3) & ~@as(usize, 3);

    const total_pixel_data = std.math.mul(usize, row_stride, h) catch return null;
    if (data.len < pixel_offset + total_pixel_data) return null;

    const rgba_size = std.math.mul(usize, std.math.mul(usize, w, h) catch return null, 4) catch return null;
    const rgba = std.heap.page_allocator.alloc(u8, rgba_size) catch return null;

    for (0..h) |row| {
        const src_row = if (bottom_up) (h - 1 - row) else row;
        for (0..w) |col| {
            const src_idx = pixel_offset + src_row * row_stride + col * bytes_per_pixel;
            const dst_idx = (row * w + col) * 4;
            // BMP stores as BGR(A)
            rgba[dst_idx + 0] = data[src_idx + 2]; // R
            rgba[dst_idx + 1] = data[src_idx + 1]; // G
            rgba[dst_idx + 2] = data[src_idx + 0]; // B
            rgba[dst_idx + 3] = if (bpp == 32) data[src_idx + 3] else 255; // A
        }
    }

    defer std.heap.page_allocator.free(rgba);
    return createTextureFromRgba(rgba, width, height) catch null;
}

// ── Embedded bitmap font atlas ──────────────────────────────────────────

// 8x8 pixel monospaced bitmap font covering ASCII 32..126 (95 glyphs).
// Laid out in a 128x48 pixel atlas (16 columns x 6 rows).
// Each glyph is stored as 8 bytes (one byte per row, MSB = leftmost pixel).

var font_initialized: bool = false;
var font_image: sg.Image = .{ .id = 0 };
var font_view: sg.View = .{ .id = 0 };
var font_sampler: sg.Sampler = .{ .id = 0 };

// Compact 8x8 bitmap font data: 95 printable ASCII chars (space through tilde).
// Each glyph is 8 bytes; each byte is one row, MSB-first.
const font_glyphs: [95][8]u8 = .{
    // 32: space
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 33: !
    .{ 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x00 },
    // 34: "
    .{ 0x6C, 0x6C, 0x6C, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 35: #
    .{ 0x6C, 0x6C, 0xFE, 0x6C, 0xFE, 0x6C, 0x6C, 0x00 },
    // 36: $
    .{ 0x18, 0x3E, 0x60, 0x3C, 0x06, 0x7C, 0x18, 0x00 },
    // 37: %
    .{ 0x00, 0xC6, 0xCC, 0x18, 0x30, 0x66, 0xC6, 0x00 },
    // 38: &
    .{ 0x38, 0x6C, 0x38, 0x76, 0xDC, 0xCC, 0x76, 0x00 },
    // 39: '
    .{ 0x18, 0x18, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 40: (
    .{ 0x0C, 0x18, 0x30, 0x30, 0x30, 0x18, 0x0C, 0x00 },
    // 41: )
    .{ 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x18, 0x30, 0x00 },
    // 42: *
    .{ 0x00, 0x66, 0x3C, 0xFF, 0x3C, 0x66, 0x00, 0x00 },
    // 43: +
    .{ 0x00, 0x18, 0x18, 0x7E, 0x18, 0x18, 0x00, 0x00 },
    // 44: ,
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30 },
    // 45: -
    .{ 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00 },
    // 46: .
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00 },
    // 47: /
    .{ 0x06, 0x0C, 0x18, 0x30, 0x60, 0xC0, 0x80, 0x00 },
    // 48: 0
    .{ 0x7C, 0xC6, 0xCE, 0xDE, 0xF6, 0xE6, 0x7C, 0x00 },
    // 49: 1
    .{ 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00 },
    // 50: 2
    .{ 0x7C, 0xC6, 0x06, 0x1C, 0x30, 0x66, 0xFE, 0x00 },
    // 51: 3
    .{ 0x7C, 0xC6, 0x06, 0x3C, 0x06, 0xC6, 0x7C, 0x00 },
    // 52: 4
    .{ 0x1C, 0x3C, 0x6C, 0xCC, 0xFE, 0x0C, 0x1E, 0x00 },
    // 53: 5
    .{ 0xFE, 0xC0, 0xFC, 0x06, 0x06, 0xC6, 0x7C, 0x00 },
    // 54: 6
    .{ 0x38, 0x60, 0xC0, 0xFC, 0xC6, 0xC6, 0x7C, 0x00 },
    // 55: 7
    .{ 0xFE, 0xC6, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x00 },
    // 56: 8
    .{ 0x7C, 0xC6, 0xC6, 0x7C, 0xC6, 0xC6, 0x7C, 0x00 },
    // 57: 9
    .{ 0x7C, 0xC6, 0xC6, 0x7E, 0x06, 0x0C, 0x78, 0x00 },
    // 58: :
    .{ 0x00, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x00 },
    // 59: ;
    .{ 0x00, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x30 },
    // 60: <
    .{ 0x06, 0x0C, 0x18, 0x30, 0x18, 0x0C, 0x06, 0x00 },
    // 61: =
    .{ 0x00, 0x00, 0x7E, 0x00, 0x00, 0x7E, 0x00, 0x00 },
    // 62: >
    .{ 0x60, 0x30, 0x18, 0x0C, 0x18, 0x30, 0x60, 0x00 },
    // 63: ?
    .{ 0x7C, 0xC6, 0x0C, 0x18, 0x18, 0x00, 0x18, 0x00 },
    // 64: @
    .{ 0x7C, 0xC6, 0xDE, 0xDE, 0xDE, 0xC0, 0x78, 0x00 },
    // 65: A
    .{ 0x38, 0x6C, 0xC6, 0xFE, 0xC6, 0xC6, 0xC6, 0x00 },
    // 66: B
    .{ 0xFC, 0x66, 0x66, 0x7C, 0x66, 0x66, 0xFC, 0x00 },
    // 67: C
    .{ 0x3C, 0x66, 0xC0, 0xC0, 0xC0, 0x66, 0x3C, 0x00 },
    // 68: D
    .{ 0xF8, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0xF8, 0x00 },
    // 69: E
    .{ 0xFE, 0x62, 0x68, 0x78, 0x68, 0x62, 0xFE, 0x00 },
    // 70: F
    .{ 0xFE, 0x62, 0x68, 0x78, 0x68, 0x60, 0xF0, 0x00 },
    // 71: G
    .{ 0x3C, 0x66, 0xC0, 0xC0, 0xCE, 0x66, 0x3A, 0x00 },
    // 72: H
    .{ 0xC6, 0xC6, 0xC6, 0xFE, 0xC6, 0xC6, 0xC6, 0x00 },
    // 73: I
    .{ 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 },
    // 74: J
    .{ 0x1E, 0x0C, 0x0C, 0x0C, 0xCC, 0xCC, 0x78, 0x00 },
    // 75: K
    .{ 0xE6, 0x66, 0x6C, 0x78, 0x6C, 0x66, 0xE6, 0x00 },
    // 76: L
    .{ 0xF0, 0x60, 0x60, 0x60, 0x62, 0x66, 0xFE, 0x00 },
    // 77: M
    .{ 0xC6, 0xEE, 0xFE, 0xFE, 0xD6, 0xC6, 0xC6, 0x00 },
    // 78: N
    .{ 0xC6, 0xE6, 0xF6, 0xDE, 0xCE, 0xC6, 0xC6, 0x00 },
    // 79: O
    .{ 0x7C, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00 },
    // 80: P
    .{ 0xFC, 0x66, 0x66, 0x7C, 0x60, 0x60, 0xF0, 0x00 },
    // 81: Q
    .{ 0x7C, 0xC6, 0xC6, 0xC6, 0xD6, 0xDE, 0x7C, 0x06 },
    // 82: R
    .{ 0xFC, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0xE6, 0x00 },
    // 83: S
    .{ 0x7C, 0xC6, 0x60, 0x38, 0x0C, 0xC6, 0x7C, 0x00 },
    // 84: T
    .{ 0x7E, 0x7E, 0x5A, 0x18, 0x18, 0x18, 0x3C, 0x00 },
    // 85: U
    .{ 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00 },
    // 86: V
    .{ 0xC6, 0xC6, 0xC6, 0xC6, 0x6C, 0x38, 0x10, 0x00 },
    // 87: W
    .{ 0xC6, 0xC6, 0xD6, 0xFE, 0xFE, 0xEE, 0xC6, 0x00 },
    // 88: X
    .{ 0xC6, 0xC6, 0x6C, 0x38, 0x6C, 0xC6, 0xC6, 0x00 },
    // 89: Y
    .{ 0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x3C, 0x00 },
    // 90: Z
    .{ 0xFE, 0xC6, 0x8C, 0x18, 0x32, 0x66, 0xFE, 0x00 },
    // 91: [
    .{ 0x3C, 0x30, 0x30, 0x30, 0x30, 0x30, 0x3C, 0x00 },
    // 92: backslash
    .{ 0xC0, 0x60, 0x30, 0x18, 0x0C, 0x06, 0x02, 0x00 },
    // 93: ]
    .{ 0x3C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x3C, 0x00 },
    // 94: ^
    .{ 0x10, 0x38, 0x6C, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    // 95: _
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF },
    // 96: `
    .{ 0x30, 0x18, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 97: a
    .{ 0x00, 0x00, 0x78, 0x0C, 0x7C, 0xCC, 0x76, 0x00 },
    // 98: b
    .{ 0xE0, 0x60, 0x7C, 0x66, 0x66, 0x66, 0xDC, 0x00 },
    // 99: c
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC0, 0xC6, 0x7C, 0x00 },
    // 100: d
    .{ 0x1C, 0x0C, 0x7C, 0xCC, 0xCC, 0xCC, 0x76, 0x00 },
    // 101: e
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xFE, 0xC0, 0x7C, 0x00 },
    // 102: f
    .{ 0x38, 0x6C, 0x60, 0xF8, 0x60, 0x60, 0xF0, 0x00 },
    // 103: g
    .{ 0x00, 0x00, 0x76, 0xCC, 0xCC, 0x7C, 0x0C, 0xF8 },
    // 104: h
    .{ 0xE0, 0x60, 0x6C, 0x76, 0x66, 0x66, 0xE6, 0x00 },
    // 105: i
    .{ 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x3C, 0x00 },
    // 106: j
    .{ 0x06, 0x00, 0x06, 0x06, 0x06, 0x66, 0x66, 0x3C },
    // 107: k
    .{ 0xE0, 0x60, 0x66, 0x6C, 0x78, 0x6C, 0xE6, 0x00 },
    // 108: l
    .{ 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 },
    // 109: m
    .{ 0x00, 0x00, 0xEC, 0xFE, 0xD6, 0xD6, 0xD6, 0x00 },
    // 110: n
    .{ 0x00, 0x00, 0xDC, 0x66, 0x66, 0x66, 0x66, 0x00 },
    // 111: o
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xC6, 0x7C, 0x00 },
    // 112: p
    .{ 0x00, 0x00, 0xDC, 0x66, 0x66, 0x7C, 0x60, 0xF0 },
    // 113: q
    .{ 0x00, 0x00, 0x76, 0xCC, 0xCC, 0x7C, 0x0C, 0x1E },
    // 114: r
    .{ 0x00, 0x00, 0xDC, 0x76, 0x60, 0x60, 0xF0, 0x00 },
    // 115: s
    .{ 0x00, 0x00, 0x7E, 0xC0, 0x7C, 0x06, 0xFC, 0x00 },
    // 116: t
    .{ 0x30, 0x30, 0x7C, 0x30, 0x30, 0x36, 0x1C, 0x00 },
    // 117: u
    .{ 0x00, 0x00, 0xCC, 0xCC, 0xCC, 0xCC, 0x76, 0x00 },
    // 118: v
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0x6C, 0x38, 0x00 },
    // 119: w
    .{ 0x00, 0x00, 0xC6, 0xD6, 0xD6, 0xFE, 0x6C, 0x00 },
    // 120: x
    .{ 0x00, 0x00, 0xC6, 0x6C, 0x38, 0x6C, 0xC6, 0x00 },
    // 121: y
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0x7E, 0x06, 0xFC },
    // 122: z
    .{ 0x00, 0x00, 0xFE, 0x8C, 0x18, 0x32, 0xFE, 0x00 },
    // 123: {
    .{ 0x0E, 0x18, 0x18, 0x70, 0x18, 0x18, 0x0E, 0x00 },
    // 124: |
    .{ 0x18, 0x18, 0x18, 0x00, 0x18, 0x18, 0x18, 0x00 },
    // 125: }
    .{ 0x70, 0x18, 0x18, 0x0E, 0x18, 0x18, 0x70, 0x00 },
    // 126: ~
    .{ 0x76, 0xDC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
};

fn initFontAtlas() void {
    // Build a 128x48 RGBA atlas (16 cols x 6 rows of 8x8 glyphs)
    const atlas_w = 128;
    const atlas_h = 48;
    var pixels: [atlas_w * atlas_h * 4]u8 = undefined;
    @memset(&pixels, 0);

    for (0..95) |glyph_idx| {
        const col = glyph_idx % 16;
        const row = glyph_idx / 16;
        const glyph = font_glyphs[glyph_idx];

        for (0..8) |py| {
            const byte = glyph[py];
            for (0..8) |px| {
                const bit: u8 = @intCast((@as(u16, byte) >> @intCast(7 - px)) & 1);
                const ax = col * 8 + px;
                const ay = row * 8 + py;
                const idx = (ay * atlas_w + ax) * 4;
                pixels[idx + 0] = 255 * bit; // R
                pixels[idx + 1] = 255 * bit; // G
                pixels[idx + 2] = 255 * bit; // B
                pixels[idx + 3] = 255 * bit; // A
            }
        }
    }

    var img_desc: sg.ImageDesc = .{
        .width = atlas_w,
        .height = atlas_h,
        .pixel_format = .RGBA8,
    };
    img_desc.data.mip_levels[0] = .{
        .ptr = &pixels,
        .size = pixels.len,
    };

    font_image = sg.makeImage(img_desc);
    if (font_image.id == 0) return;

    font_view = sg.makeView(.{ .texture = .{ .image = font_image } });
    if (font_view.id == 0) {
        sg.destroyImage(font_image);
        font_image = .{ .id = 0 };
        return;
    }

    font_sampler = sg.makeSampler(.{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });

    if (font_sampler.id == 0) {
        sg.destroyImage(font_image);
        font_image = .{ .id = 0 };
        return;
    }
}
