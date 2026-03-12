/// SDL2 gfx backend — satisfies the labelle-gfx Backend(Impl) contract.
const std = @import("std");
const c = @import("sdl").c;

// ── Backend types ──────────────────────────────────────────────────────

const MAX_TEXTURES = 512;

/// Texture handle wrapping an SDL_Texture pointer with cached dimensions.
pub const Texture = struct {
    id: u32,
    width: i32,
    height: i32,
};

/// Internal texture storage — maps id -> SDL_Texture pointer.
var texture_slots: [MAX_TEXTURES]?*c.SDL_Texture = [_]?*c.SDL_Texture{null} ** MAX_TEXTURES;

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

// ── State ──────────────────────────────────────────────────────────────

pub var sdl_renderer: ?*c.SDL_Renderer = null;
var active_camera: ?Camera2D = null;
var screen_w: i32 = 800;
var screen_h: i32 = 600;

pub fn setScreenSize(w: i32, h: i32) void {
    screen_w = w;
    screen_h = h;
}

// ── Internal helpers ──────────────────────────────────────────────────

fn getTexturePtr(id: u32) ?*c.SDL_Texture {
    if (id < MAX_TEXTURES) return texture_slots[id];
    return null;
}

/// Find the first empty slot in texture_slots (starting from index 1).
fn findFreeTextureSlot() ?u32 {
    for (1..MAX_TEXTURES) |i| {
        if (texture_slots[i] == null) return @intCast(i);
    }
    return null;
}

fn cameraZoom() f32 {
    return if (active_camera) |cam| cam.zoom else 1.0;
}

// ── Embedded bitmap font (5x7, ASCII 32-126) ─────────────────────────

const GLYPH_W: i32 = 5;
const GLYPH_H: i32 = 7;
const GLYPH_COUNT = 95; // printable ASCII: 32..126
var font_texture: ?*c.SDL_Texture = null;

/// 5x7 pixel font data. Each glyph is 5 columns x 7 rows, stored row-major.
/// 1 = pixel on, 0 = pixel off.  Covers ASCII 32 (' ') through 126 ('~').
const font_5x7 = [GLYPH_COUNT][7]u8{
    // 32 ' '
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
    // 33 '!'
    .{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00000, 0b00100 },
    // 34 '"'
    .{ 0b01010, 0b01010, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
    // 35 '#'
    .{ 0b01010, 0b11111, 0b01010, 0b01010, 0b11111, 0b01010, 0b00000 },
    // 36 '$'
    .{ 0b00100, 0b01111, 0b10100, 0b01110, 0b00101, 0b11110, 0b00100 },
    // 37 '%'
    .{ 0b11001, 0b11010, 0b00100, 0b01000, 0b10110, 0b10011, 0b00000 },
    // 38 '&'
    .{ 0b01100, 0b10010, 0b01100, 0b10101, 0b10010, 0b01101, 0b00000 },
    // 39 '''
    .{ 0b00100, 0b00100, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
    // 40 '('
    .{ 0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00010 },
    // 41 ')'
    .{ 0b01000, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01000 },
    // 42 '*'
    .{ 0b00000, 0b00100, 0b10101, 0b01110, 0b10101, 0b00100, 0b00000 },
    // 43 '+'
    .{ 0b00000, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000 },
    // 44 ','
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00100, 0b01000 },
    // 45 '-'
    .{ 0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000 },
    // 46 '.'
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00100 },
    // 47 '/'
    .{ 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b00000, 0b00000 },
    // 48 '0'
    .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
    // 49 '1'
    .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
    // 50 '2'
    .{ 0b01110, 0b10001, 0b00001, 0b00110, 0b01000, 0b10000, 0b11111 },
    // 51 '3'
    .{ 0b01110, 0b10001, 0b00001, 0b00110, 0b00001, 0b10001, 0b01110 },
    // 52 '4'
    .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
    // 53 '5'
    .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 },
    // 54 '6'
    .{ 0b01110, 0b10000, 0b11110, 0b10001, 0b10001, 0b10001, 0b01110 },
    // 55 '7'
    .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
    // 56 '8'
    .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
    // 57 '9'
    .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110 },
    // 58 ':'
    .{ 0b00000, 0b00000, 0b00100, 0b00000, 0b00000, 0b00100, 0b00000 },
    // 59 ';'
    .{ 0b00000, 0b00000, 0b00100, 0b00000, 0b00000, 0b00100, 0b01000 },
    // 60 '<'
    .{ 0b00010, 0b00100, 0b01000, 0b10000, 0b01000, 0b00100, 0b00010 },
    // 61 '='
    .{ 0b00000, 0b00000, 0b11111, 0b00000, 0b11111, 0b00000, 0b00000 },
    // 62 '>'
    .{ 0b01000, 0b00100, 0b00010, 0b00001, 0b00010, 0b00100, 0b01000 },
    // 63 '?'
    .{ 0b01110, 0b10001, 0b00010, 0b00100, 0b00100, 0b00000, 0b00100 },
    // 64 '@'
    .{ 0b01110, 0b10001, 0b10111, 0b10101, 0b10110, 0b10000, 0b01110 },
    // 65 'A'
    .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
    // 66 'B'
    .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 },
    // 67 'C'
    .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 },
    // 68 'D'
    .{ 0b11100, 0b10010, 0b10001, 0b10001, 0b10001, 0b10010, 0b11100 },
    // 69 'E'
    .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 },
    // 70 'F'
    .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 },
    // 71 'G'
    .{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111 },
    // 72 'H'
    .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
    // 73 'I'
    .{ 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
    // 74 'J'
    .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100 },
    // 75 'K'
    .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 },
    // 76 'L'
    .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 },
    // 77 'M'
    .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 },
    // 78 'N'
    .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 },
    // 79 'O'
    .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
    // 80 'P'
    .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 },
    // 81 'Q'
    .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 },
    // 82 'R'
    .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 },
    // 83 'S'
    .{ 0b01110, 0b10001, 0b10000, 0b01110, 0b00001, 0b10001, 0b01110 },
    // 84 'T'
    .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
    // 85 'U'
    .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
    // 86 'V'
    .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b01010, 0b00100 },
    // 87 'W'
    .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001 },
    // 88 'X'
    .{ 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b01010, 0b10001 },
    // 89 'Y'
    .{ 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
    // 90 'Z'
    .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 },
    // 91 '['
    .{ 0b01110, 0b01000, 0b01000, 0b01000, 0b01000, 0b01000, 0b01110 },
    // 92 '\'
    .{ 0b10000, 0b01000, 0b00100, 0b00010, 0b00001, 0b00000, 0b00000 },
    // 93 ']'
    .{ 0b01110, 0b00010, 0b00010, 0b00010, 0b00010, 0b00010, 0b01110 },
    // 94 '^'
    .{ 0b00100, 0b01010, 0b10001, 0b00000, 0b00000, 0b00000, 0b00000 },
    // 95 '_'
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b11111 },
    // 96 '`'
    .{ 0b01000, 0b00100, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
    // 97 'a'
    .{ 0b00000, 0b00000, 0b01110, 0b00001, 0b01111, 0b10001, 0b01111 },
    // 98 'b'
    .{ 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b10001, 0b11110 },
    // 99 'c'
    .{ 0b00000, 0b00000, 0b01110, 0b10000, 0b10000, 0b10001, 0b01110 },
    // 100 'd'
    .{ 0b00001, 0b00001, 0b01111, 0b10001, 0b10001, 0b10001, 0b01111 },
    // 101 'e'
    .{ 0b00000, 0b00000, 0b01110, 0b10001, 0b11111, 0b10000, 0b01110 },
    // 102 'f'
    .{ 0b00110, 0b01001, 0b01000, 0b11100, 0b01000, 0b01000, 0b01000 },
    // 103 'g'
    .{ 0b00000, 0b00000, 0b01111, 0b10001, 0b01111, 0b00001, 0b01110 },
    // 104 'h'
    .{ 0b10000, 0b10000, 0b10110, 0b11001, 0b10001, 0b10001, 0b10001 },
    // 105 'i'
    .{ 0b00100, 0b00000, 0b01100, 0b00100, 0b00100, 0b00100, 0b01110 },
    // 106 'j'
    .{ 0b00010, 0b00000, 0b00110, 0b00010, 0b00010, 0b10010, 0b01100 },
    // 107 'k'
    .{ 0b10000, 0b10000, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010 },
    // 108 'l'
    .{ 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
    // 109 'm'
    .{ 0b00000, 0b00000, 0b11010, 0b10101, 0b10101, 0b10001, 0b10001 },
    // 110 'n'
    .{ 0b00000, 0b00000, 0b10110, 0b11001, 0b10001, 0b10001, 0b10001 },
    // 111 'o'
    .{ 0b00000, 0b00000, 0b01110, 0b10001, 0b10001, 0b10001, 0b01110 },
    // 112 'p'
    .{ 0b00000, 0b00000, 0b11110, 0b10001, 0b11110, 0b10000, 0b10000 },
    // 113 'q'
    .{ 0b00000, 0b00000, 0b01111, 0b10001, 0b01111, 0b00001, 0b00001 },
    // 114 'r'
    .{ 0b00000, 0b00000, 0b10110, 0b11001, 0b10000, 0b10000, 0b10000 },
    // 115 's'
    .{ 0b00000, 0b00000, 0b01110, 0b10000, 0b01110, 0b00001, 0b11110 },
    // 116 't'
    .{ 0b01000, 0b01000, 0b11100, 0b01000, 0b01000, 0b01001, 0b00110 },
    // 117 'u'
    .{ 0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b10011, 0b01101 },
    // 118 'v'
    .{ 0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
    // 119 'w'
    .{ 0b00000, 0b00000, 0b10001, 0b10001, 0b10101, 0b10101, 0b01010 },
    // 120 'x'
    .{ 0b00000, 0b00000, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001 },
    // 121 'y'
    .{ 0b00000, 0b00000, 0b10001, 0b10001, 0b01111, 0b00001, 0b01110 },
    // 122 'z'
    .{ 0b00000, 0b00000, 0b11111, 0b00010, 0b00100, 0b01000, 0b11111 },
    // 123 '{'
    .{ 0b00010, 0b00100, 0b00100, 0b01000, 0b00100, 0b00100, 0b00010 },
    // 124 '|'
    .{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
    // 125 '}'
    .{ 0b01000, 0b00100, 0b00100, 0b00010, 0b00100, 0b00100, 0b01000 },
    // 126 '~'
    .{ 0b00000, 0b00000, 0b01000, 0b10101, 0b00010, 0b00000, 0b00000 },
};

/// Build a texture atlas from the embedded bitmap font data.
fn initFontTexture(ren: *c.SDL_Renderer) void {
    const atlas_w: i32 = GLYPH_W * GLYPH_COUNT;
    const atlas_h: i32 = GLYPH_H;

    // RGBA pixel buffer
    var pixels: [GLYPH_COUNT * GLYPH_W * GLYPH_H * 4]u8 = undefined;
    @memset(&pixels, 0);

    for (0..GLYPH_COUNT) |gi| {
        const glyph = font_5x7[gi];
        for (0..@as(usize, @intCast(GLYPH_H))) |row| {
            const row_bits = glyph[row];
            for (0..@as(usize, @intCast(GLYPH_W))) |col| {
                const bit: u8 = @intCast((@as(u32, row_bits) >> @intCast(GLYPH_W - 1 - col)) & 1);
                const px: usize = (row * @as(usize, @intCast(atlas_w)) + gi * @as(usize, @intCast(GLYPH_W)) + col) * 4;
                pixels[px + 0] = 255 * bit; // R
                pixels[px + 1] = 255 * bit; // G
                pixels[px + 2] = 255 * bit; // B
                pixels[px + 3] = 255 * bit; // A
            }
        }
    }

    const surface: *c.SDL_Surface = c.SDL_CreateRGBSurfaceFrom(
        @constCast(@ptrCast(&pixels)),
        atlas_w,
        atlas_h,
        32,
        atlas_w * 4,
        0x000000FF,
        0x0000FF00,
        0x00FF0000,
        @as(u32, 0xFF000000),
    ) orelse return;
    defer c.SDL_FreeSurface(surface);

    font_texture = c.SDL_CreateTextureFromSurface(ren, surface);
    if (font_texture) |ft| {
        // Enable alpha blending so the color-mod tint works on transparent pixels
        _ = c.SDL_SetTextureBlendMode(ft, c.SDL_BLENDMODE_BLEND);
    }
}

// ── Camera coordinate transform ────────────────────────────────────────

// TODO: Camera rotation is not yet applied to position transforms.
fn transformX(x: f32) f32 {
    if (active_camera) |cam| {
        return (x - cam.target.x) * cam.zoom + cam.offset.x;
    }
    return x;
}

// TODO: Camera rotation is not yet applied to position transforms.
fn transformY(y: f32) f32 {
    if (active_camera) |cam| {
        return (y - cam.target.y) * cam.zoom + cam.offset.y;
    }
    return y;
}

// ── Draw primitives (Backend contract) ─────────────────────────────────

pub fn drawTexturePro(texture: Texture, source: Rectangle, dest: Rectangle, origin: Vector2, rotation: f32, tint: Color) void {
    const ren = sdl_renderer orelse return;
    const tex_ptr = getTexturePtr(texture.id) orelse return;

    // Apply tint via color and alpha modulation
    _ = c.SDL_SetTextureColorMod(tex_ptr, tint.r, tint.g, tint.b);
    _ = c.SDL_SetTextureAlphaMod(tex_ptr, tint.a);

    // Detect negative source dimensions (used to signal flipping)
    var flip_flags: c_uint = c.SDL_FLIP_NONE;
    var src_w = source.width;
    var src_h = source.height;
    if (src_w < 0) {
        src_w = -src_w;
        flip_flags |= c.SDL_FLIP_HORIZONTAL;
    }
    if (src_h < 0) {
        src_h = -src_h;
        flip_flags |= c.SDL_FLIP_VERTICAL;
    }

    // Source rect (region of the texture to sample)
    var src_rect = c.SDL_Rect{
        .x = @intFromFloat(source.x),
        .y = @intFromFloat(source.y),
        .w = @intFromFloat(src_w),
        .h = @intFromFloat(src_h),
    };

    // Destination rect with camera transform applied
    var dst_rect = c.SDL_Rect{
        .x = @intFromFloat(transformX(dest.x)),
        .y = @intFromFloat(transformY(dest.y)),
        .w = @intFromFloat(dest.width * cameraZoom()),
        .h = @intFromFloat(dest.height * cameraZoom()),
    };

    // Rotation center point (scaled by camera zoom)
    var center = c.SDL_Point{
        .x = @intFromFloat(origin.x * cameraZoom()),
        .y = @intFromFloat(origin.y * cameraZoom()),
    };

    // Use only the sprite's own rotation (camera rotation not implemented in coordinate transforms)
    const total_rotation: f64 = @floatCast(rotation);

    _ = c.SDL_RenderCopyEx(
        ren,
        tex_ptr,
        &src_rect,
        &dst_rect,
        total_rotation,
        &center,
        flip_flags,
    );

    // Reset color modulation to avoid bleeding into other draws
    _ = c.SDL_SetTextureColorMod(tex_ptr, 255, 255, 255);
    _ = c.SDL_SetTextureAlphaMod(tex_ptr, 255);
}

pub fn drawRectangleRec(rec: Rectangle, tint: Color) void {
    const r = sdl_renderer orelse return;
    _ = c.SDL_SetRenderDrawColor(r, tint.r, tint.g, tint.b, tint.a);
    var rect = c.SDL_Rect{
        .x = @intFromFloat(transformX(rec.x)),
        .y = @intFromFloat(transformY(rec.y)),
        .w = @intFromFloat(rec.width * cameraZoom()),
        .h = @intFromFloat(rec.height * cameraZoom()),
    };
    _ = c.SDL_RenderFillRect(r, &rect);
}

pub fn drawCircle(center_x: f32, center_y: f32, radius: f32, tint: Color) void {
    const r = sdl_renderer orelse return;
    _ = c.SDL_SetRenderDrawColor(r, tint.r, tint.g, tint.b, tint.a);
    const cx: i32 = @intFromFloat(transformX(center_x));
    const cy: i32 = @intFromFloat(transformY(center_y));
    const rad: i32 = @intFromFloat(radius * cameraZoom());
    // Midpoint circle fill
    var x: i32 = rad;
    var y: i32 = 0;
    var err: i32 = 1 - rad;
    while (x >= y) {
        _ = c.SDL_RenderDrawLine(r, cx - x, cy + y, cx + x, cy + y);
        _ = c.SDL_RenderDrawLine(r, cx - x, cy - y, cx + x, cy - y);
        _ = c.SDL_RenderDrawLine(r, cx - y, cy + x, cx + y, cy + x);
        _ = c.SDL_RenderDrawLine(r, cx - y, cy - x, cx + y, cy - x);
        y += 1;
        if (err < 0) {
            err += 2 * y + 1;
        } else {
            x -= 1;
            err += 2 * (y - x) + 1;
        }
    }
}

pub fn drawLine(start_x: f32, start_y: f32, end_x: f32, end_y: f32, thickness: f32, tint: Color) void {
    // SDL2 SDL_RenderDrawLine has no thickness parameter; zoom-scaled value noted for future use.
    const _scaled_thickness = thickness * cameraZoom();
    _ = _scaled_thickness;
    const r = sdl_renderer orelse return;
    _ = c.SDL_SetRenderDrawColor(r, tint.r, tint.g, tint.b, tint.a);
    _ = c.SDL_RenderDrawLine(
        r,
        @intFromFloat(transformX(start_x)),
        @intFromFloat(transformY(start_y)),
        @intFromFloat(transformX(end_x)),
        @intFromFloat(transformY(end_y)),
    );
}

/// Draw text using an embedded 5x7 bitmap font rasterised into an SDL texture.
/// Each glyph covers ASCII 32..126 (printable range). The `size` parameter
/// controls the pixel height of each character; width scales proportionally.
pub fn drawText(text: [:0]const u8, x: f32, y: f32, size: f32, tint: Color) void {
    const ren = sdl_renderer orelse return;

    // Lazily create the font texture on first use
    if (font_texture == null) {
        initFontTexture(ren);
    }
    const ftex = font_texture orelse return;

    _ = c.SDL_SetTextureColorMod(ftex, tint.r, tint.g, tint.b);
    _ = c.SDL_SetTextureAlphaMod(ftex, tint.a);

    const zoom = cameraZoom();
    const scale: f32 = size / @as(f32, GLYPH_H);
    const glyph_w_scaled: f32 = @as(f32, GLYPH_W) * scale * zoom;
    const glyph_h_scaled: f32 = size * zoom;

    var cursor_x = transformX(x);
    const cursor_y = transformY(y);
    var i: usize = 0;
    while (text[i] != 0) : (i += 1) {
        const ch = text[i];
        if (ch < 32 or ch > 126) continue; // skip non-printable

        const glyph_index: i32 = @as(i32, ch) - 32;
        var src = c.SDL_Rect{
            .x = glyph_index * GLYPH_W,
            .y = 0,
            .w = GLYPH_W,
            .h = GLYPH_H,
        };
        var dst = c.SDL_Rect{
            .x = @intFromFloat(cursor_x),
            .y = @intFromFloat(cursor_y),
            .w = @intFromFloat(glyph_w_scaled),
            .h = @intFromFloat(glyph_h_scaled),
        };
        _ = c.SDL_RenderCopy(ren, ftex, &src, &dst);
        cursor_x += glyph_w_scaled + scale * zoom; // 1-pixel gap scaled
    }

    _ = c.SDL_SetTextureColorMod(ftex, 255, 255, 255);
    _ = c.SDL_SetTextureAlphaMod(ftex, 255);
}

pub fn color(r: u8, g: u8, b: u8, a: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

/// NOTE: Currently only supports BMP files. SDL_LoadBMP_RW is the only loader
/// available in base SDL2. For PNG/JPG support, SDL_image (IMG_Load) is needed.
/// TODO: Integrate SDL_image for PNG/JPG/WebP texture loading.
pub fn loadTexture(path: [:0]const u8) !Texture {
    const ren = sdl_renderer orelse return error.LoadFailed;

    // SDL_LoadBMP is a C macro that @cImport cannot translate.
    // Expand it manually: SDL_LoadBMP_RW(SDL_RWFromFile(path, "rb"), 1)
    const rw = c.SDL_RWFromFile(path.ptr, "rb") orelse {
        std.log.err("SDL_RWFromFile failed for '{s}': {s}", .{ path, c.SDL_GetError() });
        return error.LoadFailed;
    };
    const surface: *c.SDL_Surface = c.SDL_LoadBMP_RW(rw, 1) orelse {
        std.log.err("SDL_LoadBMP_RW failed for '{s}': {s}", .{ path, c.SDL_GetError() });
        return error.LoadFailed;
    };
    defer c.SDL_FreeSurface(surface);

    const tex_ptr: *c.SDL_Texture = c.SDL_CreateTextureFromSurface(ren, surface) orelse {
        std.log.err("SDL_CreateTextureFromSurface failed: {s}", .{c.SDL_GetError()});
        return error.LoadFailed;
    };

    // Query dimensions
    var w: c_int = 0;
    var h: c_int = 0;
    if (c.SDL_QueryTexture(tex_ptr, null, null, &w, &h) != 0) {
        c.SDL_DestroyTexture(tex_ptr);
        return error.LoadFailed;
    }

    // Store in first available slot (reuse freed IDs)
    const id = findFreeTextureSlot() orelse {
        c.SDL_DestroyTexture(tex_ptr);
        return error.LoadFailed;
    };
    texture_slots[id] = tex_ptr;

    return .{ .id = id, .width = @intCast(w), .height = @intCast(h) };
}

pub fn unloadTexture(texture: Texture) void {
    if (texture.id < MAX_TEXTURES) {
        if (texture_slots[texture.id]) |tex_ptr| {
            c.SDL_DestroyTexture(tex_ptr);
            texture_slots[texture.id] = null;
        }
    }
}

pub fn beginMode2D(camera: Camera2D) void {
    active_camera = camera;
}

pub fn endMode2D() void {
    active_camera = null;
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
        .y = (pos.y - camera.offset.y) / camera.zoom + camera.target.y,
    };
}

/// Release all GPU resources owned by the gfx module.
/// Called from window.closeWindow() before the renderer is destroyed.
pub fn cleanup() void {
    // Destroy font texture
    if (font_texture) |ft| {
        c.SDL_DestroyTexture(ft);
        font_texture = null;
    }
    // Destroy all loaded textures
    for (&texture_slots) |*slot| {
        if (slot.*) |tex_ptr| {
            c.SDL_DestroyTexture(tex_ptr);
            slot.* = null;
        }
    }
}

pub fn worldToScreen(pos: Vector2, camera: Camera2D) Vector2 {
    return .{
        .x = (pos.x - camera.target.x) * camera.zoom + camera.offset.x,
        .y = (pos.y - camera.target.y) * camera.zoom + camera.offset.y,
    };
}
