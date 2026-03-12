/// WebGPU gfx backend — satisfies the labelle-gfx Backend(Impl) contract.
/// Uses wgpu_native_zig (wgpu-native Zig bindings) for GPU rendering with vertex batching.
const std = @import("std");
const log = std.log.scoped(.wgpu_gfx);

// TODO: wire wgpu import once device/pipeline setup is implemented
// const wgpu = @import("wgpu");

// ── Backend types ──────────────────────────────────────────────────────

pub const Texture = struct {
    id: u32,
    width: i32,
    height: i32,
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    /// Convert to packed ABGR u32 for vertex data.
    pub fn toAbgr(self: Color) u32 {
        return (@as(u32, self.a) << 24) |
            (@as(u32, self.b) << 16) |
            (@as(u32, self.g) << 8) |
            @as(u32, self.r);
    }
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

// ── Vertex types ──────────────────────────────────────────────────────

/// Color vertex for shape rendering (position + packed ABGR color).
const ColorVertex = extern struct {
    position: [2]f32,
    color_packed: u32, // ABGR packed

    fn init(x: f32, y: f32, col: u32) ColorVertex {
        return .{ .position = .{ x, y }, .color_packed = col };
    }
};

/// Sprite vertex with position, UV, and packed ABGR color.
const SpriteVertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    color_packed: u32, // ABGR packed

    fn init(x: f32, y: f32, u: f32, v: f32, col: u32) SpriteVertex {
        return .{ .position = .{ x, y }, .uv = .{ u, v }, .color_packed = col };
    }
};

// ── WGSL Shaders ──────────────────────────────────────────────────────

const shape_vs_source =
    \\struct Uniforms {
    \\    projection: mat4x4<f32>,
    \\};
    \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
    \\
    \\struct VertexInput {
    \\    @location(0) position: vec2<f32>,
    \\    @location(1) color_packed: u32,
    \\};
    \\
    \\struct VertexOutput {
    \\    @builtin(position) position: vec4<f32>,
    \\    @location(0) color: vec4<f32>,
    \\};
    \\
    \\@vertex
    \\fn main(in: VertexInput) -> VertexOutput {
    \\    var out: VertexOutput;
    \\    out.position = uniforms.projection * vec4<f32>(in.position, 0.0, 1.0);
    \\    // Unpack ABGR u32 to vec4<f32>
    \\    let c = in.color_packed;
    \\    out.color = vec4<f32>(
    \\        f32(c & 0xFFu) / 255.0,
    \\        f32((c >> 8u) & 0xFFu) / 255.0,
    \\        f32((c >> 16u) & 0xFFu) / 255.0,
    \\        f32((c >> 24u) & 0xFFu) / 255.0,
    \\    );
    \\    return out;
    \\}
;

const shape_fs_source =
    \\struct FragmentInput {
    \\    @location(0) color: vec4<f32>,
    \\};
    \\
    \\@fragment
    \\fn main(in: FragmentInput) -> @location(0) vec4<f32> {
    \\    return in.color;
    \\}
;

const sprite_vs_source =
    \\struct Uniforms {
    \\    projection: mat4x4<f32>,
    \\};
    \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
    \\
    \\struct VertexInput {
    \\    @location(0) position: vec2<f32>,
    \\    @location(1) uv: vec2<f32>,
    \\    @location(2) color_packed: u32,
    \\};
    \\
    \\struct VertexOutput {
    \\    @builtin(position) position: vec4<f32>,
    \\    @location(0) uv: vec2<f32>,
    \\    @location(1) color: vec4<f32>,
    \\};
    \\
    \\@vertex
    \\fn main(in: VertexInput) -> VertexOutput {
    \\    var out: VertexOutput;
    \\    out.position = uniforms.projection * vec4<f32>(in.position, 0.0, 1.0);
    \\    out.uv = in.uv;
    \\    // Unpack ABGR u32 to vec4<f32>
    \\    let c = in.color_packed;
    \\    out.color = vec4<f32>(
    \\        f32(c & 0xFFu) / 255.0,
    \\        f32((c >> 8u) & 0xFFu) / 255.0,
    \\        f32((c >> 16u) & 0xFFu) / 255.0,
    \\        f32((c >> 24u) & 0xFFu) / 255.0,
    \\    );
    \\    return out;
    \\}
;

const sprite_fs_source =
    \\@group(0) @binding(1) var t_diffuse: texture_2d<f32>;
    \\@group(0) @binding(2) var s_diffuse: sampler;
    \\
    \\struct FragmentInput {
    \\    @location(0) uv: vec2<f32>,
    \\    @location(1) color: vec4<f32>,
    \\};
    \\
    \\@fragment
    \\fn main(in: FragmentInput) -> @location(0) vec4<f32> {
    \\    let tex_color = textureSample(t_diffuse, s_diffuse, in.uv);
    \\    return tex_color * in.color;
    \\}
;

// ── Shape batch ───────────────────────────────────────────────────────

const MAX_SHAPE_VERTICES = 16384;
const MAX_SHAPE_INDICES = 32768;
const MAX_SPRITE_VERTICES = 8192;
const MAX_SPRITE_INDICES = 16384;
const MAX_SPRITE_QUADS = MAX_SPRITE_VERTICES / 4;

var shape_vertices: [MAX_SHAPE_VERTICES]ColorVertex = undefined;
var shape_indices: [MAX_SHAPE_INDICES]u32 = undefined;
var shape_vertex_count: usize = 0;
var shape_index_count: usize = 0;

var sprite_vertices: [MAX_SPRITE_VERTICES]SpriteVertex = undefined;
var sprite_indices: [MAX_SPRITE_INDICES]u32 = undefined;
var sprite_vertex_count: usize = 0;
var sprite_index_count: usize = 0;

/// Texture ID for each sprite quad, so the renderer knows which texture to bind.
var sprite_texture_ids: [MAX_SPRITE_QUADS]u32 = undefined;
var sprite_quad_count: usize = 0;

// ── Texture storage ────────────────────────────────────────────────────

const MAX_TEXTURES = 256;

const TextureSlot = struct {
    /// Raw RGBA8 pixel data (owned).
    pixels: ?[]u8 = null,
    width: i32 = 0,
    height: i32 = 0,
    active: bool = false,
};

var textures: [MAX_TEXTURES]TextureSlot = [_]TextureSlot{.{}} ** MAX_TEXTURES;
var next_texture_id: u32 = 1;

// ── State ──────────────────────────────────────────────────────────────

var screen_w: i32 = 800;
var screen_h: i32 = 600;
var active_camera: ?Camera2D = null;

pub fn setScreenSize(w: i32, h: i32) void {
    screen_w = w;
    screen_h = h;
}

// ── Camera coordinate transform ────────────────────────────────────────

fn transformX(x: f32) f32 {
    if (active_camera) |cam| {
        return (x - cam.target.x) * cam.zoom + cam.offset.x;
    }
    return x;
}

fn transformY(y: f32) f32 {
    if (active_camera) |cam| {
        return (y - cam.target.y) * cam.zoom + cam.offset.y;
    }
    return y;
}

/// Convert screen X to NDC (-1..1).
fn toNdcX(x: f32) f32 {
    const sw: f32 = @floatFromInt(screen_w);
    return (transformX(x) / sw) * 2.0 - 1.0;
}

/// Convert screen Y to NDC (-1..1), flipped for GPU.
fn toNdcY(y: f32) f32 {
    const sh: f32 = @floatFromInt(screen_h);
    return 1.0 - (transformY(y) / sh) * 2.0;
}

// ── Shape batch helpers ───────────────────────────────────────────────

/// Check whether the shape batch has room for the given number of vertices and indices.
fn hasShapeCapacity(verts: usize, idxs: usize) bool {
    return (shape_vertex_count + verts <= MAX_SHAPE_VERTICES) and
        (shape_index_count + idxs <= MAX_SHAPE_INDICES);
}

/// Check whether the sprite batch has room for the given number of vertices and indices.
fn hasSpriteCapacity(verts: usize, idxs: usize) bool {
    return (sprite_vertex_count + verts <= MAX_SPRITE_VERTICES) and
        (sprite_index_count + idxs <= MAX_SPRITE_INDICES);
}

fn appendShapeVertex(v: ColorVertex) void {
    shape_vertices[shape_vertex_count] = v;
    shape_vertex_count += 1;
}

fn appendShapeIndex(idx: u32) void {
    shape_indices[shape_index_count] = idx;
    shape_index_count += 1;
}

fn appendSpriteVertex(v: SpriteVertex) void {
    sprite_vertices[sprite_vertex_count] = v;
    sprite_vertex_count += 1;
}

fn appendSpriteIndex(idx: u32) void {
    sprite_indices[sprite_index_count] = idx;
    sprite_index_count += 1;
}

/// Reset shape batch for the next frame.
pub fn resetShapeBatch() void {
    shape_vertex_count = 0;
    shape_index_count = 0;
}

/// Reset sprite batch for the next frame.
pub fn resetSpriteBatch() void {
    sprite_vertex_count = 0;
    sprite_index_count = 0;
    sprite_quad_count = 0;
}

/// Consume shape batch data for GPU submission (called once per frame at endDrawing).
/// Resets the batch after returning — the returned slices are valid until the next draw call.
pub fn consumeShapeBatch() struct { vertices: []const ColorVertex, indices: []const u32 } {
    const batch = .{
        .vertices = shape_vertices[0..shape_vertex_count],
        .indices = shape_indices[0..shape_index_count],
    };
    resetShapeBatch();
    return batch;
}

/// Consume sprite batch data for GPU submission (called once per frame at endDrawing).
/// Resets the batch after returning — the returned slices are valid until the next draw call.
/// `texture_ids` has one entry per quad (every 4 vertices / 6 indices).
pub fn consumeSpriteBatch() struct { vertices: []const SpriteVertex, indices: []const u32, texture_ids: []const u32 } {
    const batch = .{
        .vertices = sprite_vertices[0..sprite_vertex_count],
        .indices = sprite_indices[0..sprite_index_count],
        .texture_ids = sprite_texture_ids[0..sprite_quad_count],
    };
    resetSpriteBatch();
    return batch;
}

/// Backward-compatible alias for `consumeShapeBatch`.
pub const getShapeBatch = consumeShapeBatch;

/// Backward-compatible alias for `consumeSpriteBatch`.
pub const getSpriteBatch = consumeSpriteBatch;

// ── Draw primitives (Backend contract) ─────────────────────────────────

pub fn drawRectangleRec(rec: Rectangle, tint: Color) void {
    if (!hasShapeCapacity(4, 6)) {
        log.warn("shape batch full, dropping rectangle primitive", .{});
        return;
    }
    const col = tint.toAbgr();
    const x = rec.x;
    const y = rec.y;
    const w = rec.width;
    const h = rec.height;
    const base: u32 = @intCast(shape_vertex_count);

    // 4 vertices for the rectangle
    appendShapeVertex(ColorVertex.init(toNdcX(x), toNdcY(y), col));
    appendShapeVertex(ColorVertex.init(toNdcX(x + w), toNdcY(y), col));
    appendShapeVertex(ColorVertex.init(toNdcX(x + w), toNdcY(y + h), col));
    appendShapeVertex(ColorVertex.init(toNdcX(x), toNdcY(y + h), col));

    // 2 triangles (CCW winding)
    appendShapeIndex(base + 0);
    appendShapeIndex(base + 1);
    appendShapeIndex(base + 2);
    appendShapeIndex(base + 0);
    appendShapeIndex(base + 2);
    appendShapeIndex(base + 3);
}

pub fn drawCircle(center_x: f32, center_y: f32, radius: f32, tint: Color) void {
    const segments: u32 = 36;
    if (!hasShapeCapacity(segments + 2, segments * 3)) {
        log.warn("shape batch full, dropping circle primitive", .{});
        return;
    }
    const col = tint.toAbgr();
    const base: u32 = @intCast(shape_vertex_count);

    // Center vertex
    appendShapeVertex(ColorVertex.init(toNdcX(center_x), toNdcY(center_y), col));

    // Perimeter vertices
    var i: u32 = 0;
    while (i <= segments) : (i += 1) {
        const angle = (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments))) * 2.0 * std.math.pi;
        const px = center_x + @cos(angle) * radius;
        const py = center_y + @sin(angle) * radius;
        appendShapeVertex(ColorVertex.init(toNdcX(px), toNdcY(py), col));
    }

    // Fan triangles (center + 2 consecutive perimeter vertices)
    i = 0;
    while (i < segments) : (i += 1) {
        appendShapeIndex(base); // center
        appendShapeIndex(base + i + 1);
        appendShapeIndex(base + i + 2);
    }
}

pub fn drawLine(start_x: f32, start_y: f32, end_x: f32, end_y: f32, thickness: f32, tint: Color) void {
    if (!hasShapeCapacity(4, 6)) {
        log.warn("shape batch full, dropping line primitive", .{});
        return;
    }
    const col = tint.toAbgr();
    const dx = end_x - start_x;
    const dy = end_y - start_y;
    const len = @sqrt(dx * dx + dy * dy);

    if (len < 0.0001) return; // skip degenerate lines

    // Perpendicular offset for thickness
    const perp_x = -dy / len * (thickness * 0.5);
    const perp_y = dx / len * (thickness * 0.5);

    const base: u32 = @intCast(shape_vertex_count);

    // Quad from 4 offset vertices
    appendShapeVertex(ColorVertex.init(toNdcX(start_x + perp_x), toNdcY(start_y + perp_y), col));
    appendShapeVertex(ColorVertex.init(toNdcX(start_x - perp_x), toNdcY(start_y - perp_y), col));
    appendShapeVertex(ColorVertex.init(toNdcX(end_x - perp_x), toNdcY(end_y - perp_y), col));
    appendShapeVertex(ColorVertex.init(toNdcX(end_x + perp_x), toNdcY(end_y + perp_y), col));

    appendShapeIndex(base + 0);
    appendShapeIndex(base + 1);
    appendShapeIndex(base + 2);
    appendShapeIndex(base + 0);
    appendShapeIndex(base + 2);
    appendShapeIndex(base + 3);
}

pub fn drawTriangle(x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32, tint: Color) void {
    if (!hasShapeCapacity(3, 3)) {
        log.warn("shape batch full, dropping triangle primitive", .{});
        return;
    }
    const col = tint.toAbgr();
    const base: u32 = @intCast(shape_vertex_count);

    appendShapeVertex(ColorVertex.init(toNdcX(x1), toNdcY(y1), col));
    appendShapeVertex(ColorVertex.init(toNdcX(x2), toNdcY(y2), col));
    appendShapeVertex(ColorVertex.init(toNdcX(x3), toNdcY(y3), col));

    appendShapeIndex(base + 0);
    appendShapeIndex(base + 1);
    appendShapeIndex(base + 2);
}

pub fn drawPoly(center_x: f32, center_y: f32, sides: i32, radius: f32, rotation: f32, tint: Color) void {
    if (sides < 3 or radius <= 0) return;
    const num_sides: u32 = @intCast(sides);
    if (!hasShapeCapacity(num_sides + 2, num_sides * 3)) {
        log.warn("shape batch full, dropping polygon primitive", .{});
        return;
    }
    const col = tint.toAbgr();
    const base: u32 = @intCast(shape_vertex_count);

    // Convert rotation from degrees to radians (consistent with drawTexturePro / raylib convention)
    const rot_rad = rotation * std.math.pi / 180.0;

    // Center vertex
    appendShapeVertex(ColorVertex.init(toNdcX(center_x), toNdcY(center_y), col));

    // Perimeter vertices
    var i: u32 = 0;
    while (i <= num_sides) : (i += 1) {
        const angle = rot_rad + (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(num_sides))) * 2.0 * std.math.pi;
        const px = center_x + @cos(angle) * radius;
        const py = center_y + @sin(angle) * radius;
        appendShapeVertex(ColorVertex.init(toNdcX(px), toNdcY(py), col));
    }

    // Fan triangles
    i = 0;
    while (i < num_sides) : (i += 1) {
        appendShapeIndex(base);
        appendShapeIndex(base + i + 1);
        appendShapeIndex(base + i + 2);
    }
}

// ── Texture / Sprite rendering ─────────────────────────────────────────

pub fn drawTexturePro(texture: Texture, source: Rectangle, dest: Rectangle, origin: Vector2, rotation: f32, tint: Color) void {
    if (!hasSpriteCapacity(4, 6)) {
        log.warn("sprite batch full, dropping sprite primitive", .{});
        return;
    }
    const col = tint.toAbgr();

    // Track which texture this quad uses so the renderer can bind correctly.
    if (sprite_quad_count < MAX_SPRITE_QUADS) {
        sprite_texture_ids[sprite_quad_count] = texture.id;
        sprite_quad_count += 1;
    }

    // UV coordinates from source rectangle
    const tex_w: f32 = @floatFromInt(texture.width);
    const tex_h: f32 = @floatFromInt(texture.height);
    const uv_x0 = source.x / tex_w;
    const uv_y0 = source.y / tex_h;
    const uv_x1 = (source.x + source.width) / tex_w;
    const uv_y1 = (source.y + source.height) / tex_h;

    // Local corner positions relative to origin
    const x0 = -origin.x;
    const y0 = -origin.y;
    const x1 = dest.width - origin.x;
    const y1 = dest.height - origin.y;

    // Rotation
    const cos_r = @cos(rotation * std.math.pi / 180.0);
    const sin_r = @sin(rotation * std.math.pi / 180.0);

    const base: u32 = @intCast(sprite_vertex_count);

    // Top-left
    const tx0 = dest.x + (x0 * cos_r - y0 * sin_r);
    const ty0 = dest.y + (x0 * sin_r + y0 * cos_r);
    appendSpriteVertex(SpriteVertex.init(toNdcX(tx0), toNdcY(ty0), uv_x0, uv_y0, col));

    // Top-right
    const tx1 = dest.x + (x1 * cos_r - y0 * sin_r);
    const ty1 = dest.y + (x1 * sin_r + y0 * cos_r);
    appendSpriteVertex(SpriteVertex.init(toNdcX(tx1), toNdcY(ty1), uv_x1, uv_y0, col));

    // Bottom-right
    const tx2 = dest.x + (x1 * cos_r - y1 * sin_r);
    const ty2 = dest.y + (x1 * sin_r + y1 * cos_r);
    appendSpriteVertex(SpriteVertex.init(toNdcX(tx2), toNdcY(ty2), uv_x1, uv_y1, col));

    // Bottom-left
    const tx3 = dest.x + (x0 * cos_r - y1 * sin_r);
    const ty3 = dest.y + (x0 * sin_r + y1 * cos_r);
    appendSpriteVertex(SpriteVertex.init(toNdcX(tx3), toNdcY(ty3), uv_x0, uv_y1, col));

    // 2 triangles (CCW)
    appendSpriteIndex(base + 0);
    appendSpriteIndex(base + 1);
    appendSpriteIndex(base + 2);
    appendSpriteIndex(base + 0);
    appendSpriteIndex(base + 2);
    appendSpriteIndex(base + 3);
}

pub fn loadTexture(path: [:0]const u8) !Texture {
    const id = next_texture_id;
    if (id >= MAX_TEXTURES) return error.LoadFailed;

    const file = std.fs.cwd().openFile(std.mem.span(path), .{}) catch return error.LoadFailed;
    defer file.close();

    const stat = file.stat() catch return error.LoadFailed;
    const file_size = stat.size;
    if (file_size < 18) return error.LoadFailed; // Too small for any image header

    const file_buf = std.heap.page_allocator.alloc(u8, file_size) catch return error.LoadFailed;
    defer std.heap.page_allocator.free(file_buf);

    const bytes_read = file.readAll(file_buf) catch return error.LoadFailed;
    if (bytes_read != file_size) return error.LoadFailed;

    // Try BMP first, then TGA
    if (decodeBmp(file_buf[0..bytes_read])) |img| {
        textures[id] = .{ .pixels = img.pixels, .width = img.width, .height = img.height, .active = true };
        next_texture_id += 1;
        return Texture{ .id = id, .width = img.width, .height = img.height };
    }

    if (decodeTga(file_buf[0..bytes_read])) |img| {
        textures[id] = .{ .pixels = img.pixels, .width = img.width, .height = img.height, .active = true };
        next_texture_id += 1;
        return Texture{ .id = id, .width = img.width, .height = img.height };
    }

    return error.LoadFailed;
}

pub fn unloadTexture(texture: Texture) void {
    if (texture.id >= MAX_TEXTURES) return;
    const slot = &textures[texture.id];
    if (slot.pixels) |px| {
        std.heap.page_allocator.free(px);
    }
    slot.* = .{};
}

// ── Image decoding helpers ─────────────────────────────────────────────

const DecodedImage = struct {
    pixels: []u8, // RGBA8, owned
    width: i32,
    height: i32,
};

/// Decode an uncompressed 24-bit or 32-bit BMP to RGBA8.
fn decodeBmp(data: []const u8) ?DecodedImage {
    if (data.len < 54) return null;
    if (data[0] != 'B' or data[1] != 'M') return null;

    const pixel_offset = std.mem.readInt(u32, data[10..14], .little);
    const w_signed = std.mem.readInt(i32, data[18..22], .little);
    const h_signed = std.mem.readInt(i32, data[22..26], .little);
    const bpp = std.mem.readInt(u16, data[28..30], .little);

    if (w_signed <= 0) return null;
    const width: u32 = @intCast(w_signed);
    // BMP height can be negative (top-down); handle both.
    const flip = h_signed > 0;
    const height: u32 = if (h_signed < 0) @intCast(-h_signed) else @intCast(h_signed);

    if (bpp != 24 and bpp != 32) return null; // Only uncompressed RGB/RGBA

    const bytes_per_pixel: u32 = @as(u32, bpp) / 8;
    const row_size = ((width * bytes_per_pixel + 3) / 4) * 4; // BMP rows are 4-byte aligned

    const out_size = @as(usize, width) * @as(usize, height) * 4;
    const pixels = std.heap.page_allocator.alloc(u8, out_size) catch return null;

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_y = if (flip) height - 1 - y else y;
        const row_off = @as(usize, pixel_offset) + @as(usize, src_y) * @as(usize, row_size);
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const src = row_off + @as(usize, x) * @as(usize, bytes_per_pixel);
            const dst = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 4;
            if (src + bytes_per_pixel > data.len or dst + 4 > pixels.len) {
                std.heap.page_allocator.free(pixels);
                return null;
            }
            // BMP stores BGR(A)
            pixels[dst + 0] = data[src + 2]; // R
            pixels[dst + 1] = data[src + 1]; // G
            pixels[dst + 2] = data[src + 0]; // B
            pixels[dst + 3] = if (bytes_per_pixel == 4) data[src + 3] else 255;
        }
    }

    return DecodedImage{ .pixels = pixels, .width = @intCast(width), .height = @intCast(height) };
}

/// Decode an uncompressed TGA (type 2) to RGBA8.
fn decodeTga(data: []const u8) ?DecodedImage {
    if (data.len < 18) return null;

    const image_type = data[2];
    if (image_type != 2) return null; // Only uncompressed true-color

    const width: u32 = std.mem.readInt(u16, data[12..14], .little);
    const height: u32 = std.mem.readInt(u16, data[14..16], .little);
    const bpp = data[16];
    const descriptor = data[17];

    if (width == 0 or height == 0) return null;
    if (bpp != 24 and bpp != 32) return null;

    const id_len: usize = data[0];
    const pixel_offset: usize = 18 + id_len;
    const bytes_per_pixel: usize = @as(usize, bpp) / 8;
    // Bit 5 of descriptor: 0 = bottom-up (default TGA), 1 = top-down
    const top_down = (descriptor & 0x20) != 0;

    const out_size = @as(usize, width) * @as(usize, height) * 4;
    const pixels = std.heap.page_allocator.alloc(u8, out_size) catch return null;

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_y = if (!top_down) height - 1 - y else y;
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const src = pixel_offset + (@as(usize, src_y) * @as(usize, width) + @as(usize, x)) * bytes_per_pixel;
            const dst = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 4;
            if (src + bytes_per_pixel > data.len or dst + 4 > pixels.len) {
                std.heap.page_allocator.free(pixels);
                return null;
            }
            // TGA stores BGR(A)
            pixels[dst + 0] = data[src + 2]; // R
            pixels[dst + 1] = data[src + 1]; // G
            pixels[dst + 2] = data[src + 0]; // B
            pixels[dst + 3] = if (bytes_per_pixel == 4) data[src + 3] else 255;
        }
    }

    return DecodedImage{ .pixels = pixels, .width = @intCast(width), .height = @intCast(height) };
}

// TODO: Add PNG decoding (requires inflate/zlib decompression) or integrate stb_image

// ── Text rendering (bitmap font atlas) ─────────────────────────────────

/// Minimal 8x8 bitmap font for basic text rendering.
/// Each character is an 8x8 monospaced glyph stored as 8 bytes (1 bit per pixel, MSB-left).
/// Printable ASCII range: 0x20 (' ') through 0x7E ('~').
const FONT_GLYPH_W = 8;
const FONT_GLYPH_H = 8;

// Embedded 8x8 font data for printable ASCII (space through '~', 95 glyphs).
// Each glyph is 8 rows of 8 bits packed into u8.
const font_data = initFontData();

fn initFontData() [95][8]u8 {
    // Minimal embedded bitmap font (subset — uppercase letters, digits, punctuation).
    // Unset glyphs render as hollow rectangles.
    var data: [95][8]u8 = [_][8]u8{.{ 0, 0, 0, 0, 0, 0, 0, 0 }} ** 95;

    // Space (0x20) — blank
    // '!' (0x21)
    data[0x21 - 0x20] = .{ 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x00 };
    // '0' - '9'
    data[0x30 - 0x20] = .{ 0x3C, 0x66, 0x6E, 0x7E, 0x76, 0x66, 0x3C, 0x00 }; // 0
    data[0x31 - 0x20] = .{ 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00 }; // 1
    data[0x32 - 0x20] = .{ 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x30, 0x7E, 0x00 }; // 2
    data[0x33 - 0x20] = .{ 0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00 }; // 3
    data[0x34 - 0x20] = .{ 0x0C, 0x1C, 0x3C, 0x6C, 0x7E, 0x0C, 0x0C, 0x00 }; // 4
    data[0x35 - 0x20] = .{ 0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00 }; // 5
    data[0x36 - 0x20] = .{ 0x1C, 0x30, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0x00 }; // 6
    data[0x37 - 0x20] = .{ 0x7E, 0x06, 0x0C, 0x18, 0x18, 0x18, 0x18, 0x00 }; // 7
    data[0x38 - 0x20] = .{ 0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00 }; // 8
    data[0x39 - 0x20] = .{ 0x3C, 0x66, 0x66, 0x3E, 0x06, 0x0C, 0x38, 0x00 }; // 9
    // A-Z
    data[0x41 - 0x20] = .{ 0x18, 0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x00 }; // A
    data[0x42 - 0x20] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00 }; // B
    data[0x43 - 0x20] = .{ 0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0x00 }; // C
    data[0x44 - 0x20] = .{ 0x78, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0x78, 0x00 }; // D
    data[0x45 - 0x20] = .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x7E, 0x00 }; // E
    data[0x46 - 0x20] = .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x60, 0x00 }; // F
    data[0x47 - 0x20] = .{ 0x3C, 0x66, 0x60, 0x6E, 0x66, 0x66, 0x3E, 0x00 }; // G
    data[0x48 - 0x20] = .{ 0x66, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00 }; // H
    data[0x49 - 0x20] = .{ 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 }; // I
    data[0x4A - 0x20] = .{ 0x06, 0x06, 0x06, 0x06, 0x06, 0x66, 0x3C, 0x00 }; // J
    data[0x4B - 0x20] = .{ 0x66, 0x6C, 0x78, 0x70, 0x78, 0x6C, 0x66, 0x00 }; // K
    data[0x4C - 0x20] = .{ 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x7E, 0x00 }; // L
    data[0x4D - 0x20] = .{ 0x63, 0x77, 0x7F, 0x6B, 0x63, 0x63, 0x63, 0x00 }; // M
    data[0x4E - 0x20] = .{ 0x66, 0x76, 0x7E, 0x7E, 0x6E, 0x66, 0x66, 0x00 }; // N
    data[0x4F - 0x20] = .{ 0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 }; // O
    data[0x50 - 0x20] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x00 }; // P
    data[0x51 - 0x20] = .{ 0x3C, 0x66, 0x66, 0x66, 0x6A, 0x6C, 0x36, 0x00 }; // Q
    data[0x52 - 0x20] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0x66, 0x00 }; // R
    data[0x53 - 0x20] = .{ 0x3C, 0x66, 0x60, 0x3C, 0x06, 0x66, 0x3C, 0x00 }; // S
    data[0x54 - 0x20] = .{ 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00 }; // T
    data[0x55 - 0x20] = .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 }; // U
    data[0x56 - 0x20] = .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 }; // V
    data[0x57 - 0x20] = .{ 0x63, 0x63, 0x63, 0x6B, 0x7F, 0x77, 0x63, 0x00 }; // W
    data[0x58 - 0x20] = .{ 0x66, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x66, 0x00 }; // X
    data[0x59 - 0x20] = .{ 0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x18, 0x00 }; // Y
    data[0x5A - 0x20] = .{ 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x7E, 0x00 }; // Z
    // a-z (lowercase)
    data[0x61 - 0x20] = .{ 0x00, 0x00, 0x3C, 0x06, 0x3E, 0x66, 0x3E, 0x00 }; // a
    data[0x62 - 0x20] = .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x7C, 0x00 }; // b
    data[0x63 - 0x20] = .{ 0x00, 0x00, 0x3C, 0x66, 0x60, 0x66, 0x3C, 0x00 }; // c
    data[0x64 - 0x20] = .{ 0x06, 0x06, 0x3E, 0x66, 0x66, 0x66, 0x3E, 0x00 }; // d
    data[0x65 - 0x20] = .{ 0x00, 0x00, 0x3C, 0x66, 0x7E, 0x60, 0x3C, 0x00 }; // e
    data[0x66 - 0x20] = .{ 0x1C, 0x30, 0x30, 0x7C, 0x30, 0x30, 0x30, 0x00 }; // f
    data[0x67 - 0x20] = .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x3C }; // g
    data[0x68 - 0x20] = .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 }; // h
    data[0x69 - 0x20] = .{ 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x3C, 0x00 }; // i
    data[0x6A - 0x20] = .{ 0x0C, 0x00, 0x1C, 0x0C, 0x0C, 0x0C, 0x6C, 0x38 }; // j
    data[0x6B - 0x20] = .{ 0x60, 0x60, 0x66, 0x6C, 0x78, 0x6C, 0x66, 0x00 }; // k
    data[0x6C - 0x20] = .{ 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 }; // l
    data[0x6D - 0x20] = .{ 0x00, 0x00, 0x76, 0x7F, 0x6B, 0x63, 0x63, 0x00 }; // m
    data[0x6E - 0x20] = .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 }; // n
    data[0x6F - 0x20] = .{ 0x00, 0x00, 0x3C, 0x66, 0x66, 0x66, 0x3C, 0x00 }; // o
    data[0x70 - 0x20] = .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60 }; // p
    data[0x71 - 0x20] = .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x06 }; // q
    data[0x72 - 0x20] = .{ 0x00, 0x00, 0x6C, 0x76, 0x60, 0x60, 0x60, 0x00 }; // r
    data[0x73 - 0x20] = .{ 0x00, 0x00, 0x3E, 0x60, 0x3C, 0x06, 0x7C, 0x00 }; // s
    data[0x74 - 0x20] = .{ 0x30, 0x30, 0x7C, 0x30, 0x30, 0x30, 0x1C, 0x00 }; // t
    data[0x75 - 0x20] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x3E, 0x00 }; // u
    data[0x76 - 0x20] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 }; // v
    data[0x77 - 0x20] = .{ 0x00, 0x00, 0x63, 0x6B, 0x7F, 0x7F, 0x36, 0x00 }; // w
    data[0x78 - 0x20] = .{ 0x00, 0x00, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x00 }; // x
    data[0x79 - 0x20] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3E, 0x06, 0x3C }; // y
    data[0x7A - 0x20] = .{ 0x00, 0x00, 0x7E, 0x0C, 0x18, 0x30, 0x7E, 0x00 }; // z
    // Common punctuation
    data[0x2E - 0x20] = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00 }; // .
    data[0x2C - 0x20] = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30 }; // ,
    data[0x3A - 0x20] = .{ 0x00, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x00 }; // :
    data[0x3B - 0x20] = .{ 0x00, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x30 }; // ;
    data[0x2D - 0x20] = .{ 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00 }; // -
    data[0x3D - 0x20] = .{ 0x00, 0x00, 0x7E, 0x00, 0x7E, 0x00, 0x00, 0x00 }; // =
    data[0x28 - 0x20] = .{ 0x0C, 0x18, 0x30, 0x30, 0x30, 0x18, 0x0C, 0x00 }; // (
    data[0x29 - 0x20] = .{ 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x18, 0x30, 0x00 }; // )
    data[0x5B - 0x20] = .{ 0x3C, 0x30, 0x30, 0x30, 0x30, 0x30, 0x3C, 0x00 }; // [
    data[0x5D - 0x20] = .{ 0x3C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x3C, 0x00 }; // ]
    data[0x2F - 0x20] = .{ 0x02, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x40, 0x00 }; // /
    data[0x3F - 0x20] = .{ 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x00, 0x18, 0x00 }; // ?

    return data;
}

pub fn drawText(text: [:0]const u8, x: f32, y: f32, size: f32, tint: Color) void {
    const col = tint.toAbgr();
    const scale = size / @as(f32, FONT_GLYPH_H);
    const glyph_w: f32 = @as(f32, FONT_GLYPH_W) * scale;
    const glyph_h: f32 = @as(f32, FONT_GLYPH_H) * scale;

    var cursor_x = x;
    for (text) |ch| {
        if (ch == 0) break;
        if (ch >= 0x20 and ch <= 0x7E) {
            const glyph = font_data[ch - 0x20];
            // Skip entirely blank glyphs (e.g. space)
            var has_pixels = false;
            for (glyph) |row_bits| {
                if (row_bits != 0) {
                    has_pixels = true;
                    break;
                }
            }

            if (has_pixels) {
                // One filled rectangle per glyph (4 vertices, 6 indices).
                if (!hasShapeCapacity(4, 6)) {
                    log.warn("shape batch full, dropping text glyphs", .{});
                    return;
                }

                const base: u32 = @intCast(shape_vertex_count);
                appendShapeVertex(ColorVertex.init(toNdcX(cursor_x), toNdcY(y), col));
                appendShapeVertex(ColorVertex.init(toNdcX(cursor_x + glyph_w), toNdcY(y), col));
                appendShapeVertex(ColorVertex.init(toNdcX(cursor_x + glyph_w), toNdcY(y + glyph_h), col));
                appendShapeVertex(ColorVertex.init(toNdcX(cursor_x), toNdcY(y + glyph_h), col));

                appendShapeIndex(base + 0);
                appendShapeIndex(base + 1);
                appendShapeIndex(base + 2);
                appendShapeIndex(base + 0);
                appendShapeIndex(base + 2);
                appendShapeIndex(base + 3);
            }
        }
        cursor_x += glyph_w;
    }
}

// ── Utility functions ──────────────────────────────────────────────────

pub fn color(r: u8, g: u8, b: u8, a: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
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

pub fn worldToScreen(pos: Vector2, camera: Camera2D) Vector2 {
    return .{
        .x = (pos.x - camera.target.x) * camera.zoom + camera.offset.x,
        .y = (pos.y - camera.target.y) * camera.zoom + camera.offset.y,
    };
}
