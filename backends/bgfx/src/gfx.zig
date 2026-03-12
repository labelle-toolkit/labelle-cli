/// bgfx gfx backend — satisfies the labelle-gfx Backend(Impl) contract.
/// Uses bgfx transient vertex buffers for shape rendering, bgfx texture API for sprites.
const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const shaders = @import("shaders.zig");

// Blend helpers matching bgfx C macros.
// BGFX_STATE_BLEND_FUNC_SEPARATE(_srcRGB, _dstRGB, _srcA, _dstA):
//   (_srcRGB | (_dstRGB << 4)) | ((_srcA | (_dstA << 4)) << 8)
fn stateBlendFuncSeparate(src_rgb: u64, dst_rgb: u64, src_a: u64, dst_a: u64) u64 {
    return (src_rgb | (dst_rgb << 4)) | ((src_a | (dst_a << 4)) << 8);
}

const STATE_BLEND_ALPHA: u64 = stateBlendFuncSeparate(
    bgfx.StateFlags_BlendSrcAlpha,
    bgfx.StateFlags_BlendInvSrcAlpha,
    bgfx.StateFlags_BlendSrcAlpha,
    bgfx.StateFlags_BlendInvSrcAlpha,
);

// ── Backend types ──────────────────────────────────────────────────────

pub const Texture = struct { id: u32, width: i32, height: i32 };

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    fn toAbgr(c: Color) u32 {
        return @as(u32, c.a) << 24 | @as(u32, c.b) << 16 | @as(u32, c.g) << 8 | @as(u32, c.r);
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

// ── Vertex layout ─────────────────────────────────────────────────────

/// Unified 2D vertex: position (x, y) + texcoord (u, v) + ABGR color packed as u32.
/// Matches the v1 sprite shader layout: a_position (vec2), a_texcoord0 (vec2), a_color0 (vec4 normalized).
/// For flat-color rendering, use UV (0,0) with a 1x1 white texture.
const PosTexColorVertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    abgr: u32,
};

var vertex_layout: bgfx.VertexLayout = undefined;
var layouts_initialized: bool = false;

/// Shader program handle (single program for both flat and textured rendering).
/// The sprite shader samples a texture and multiplies by vertex color.
/// For flat-color rendering, a 1x1 white texture is bound so texture * color = color.
var sprite_program: bgfx.ProgramHandle = .{ .idx = std.math.maxInt(u16) };

/// Sampler uniform handle for texture binding (created via createUniform).
var s_tex_uniform: bgfx.UniformHandle = .{ .idx = std.math.maxInt(u16) };

/// u_viewProj uniform handle (4x4 matrix). Set to identity since we compute NDC in Zig.
// u_viewProj is a built-in bgfx uniform set via setViewTransform, not createUniform

/// 1x1 white texture used for flat-color rendering (texture * color = color).
var white_texture: bgfx.TextureHandle = .{ .idx = std.math.maxInt(u16) };

/// Whether embedded shaders have been initialized.
var shaders_initialized: bool = false;

/// Returns true if `handle` is a valid bgfx handle (not the sentinel value).
fn isValidHandle(idx: u16) bool {
    return idx != std.math.maxInt(u16);
}

/// Returns true if `prog` is a valid bgfx program handle.
fn isValidProgram(prog: bgfx.ProgramHandle) bool {
    return isValidHandle(prog.idx);
}

/// Initialize embedded shaders, uniforms, and the 1x1 white fallback texture.
/// Called lazily from submit functions. Detects the renderer type and selects
/// the appropriate pre-compiled shader variant (Metal, Vulkan, or GLSL).
fn initShaders() void {
    if (shaders_initialized) return;

    // Select shader variant based on active renderer
    const vs_data: []const u8 = switch (bgfx.getRendererType()) {
        .Metal => &shaders.vs_sprite_mtl,
        .Vulkan => &shaders.vs_sprite_spv,
        else => &shaders.vs_sprite_glsl,
    };
    const fs_data: []const u8 = switch (bgfx.getRendererType()) {
        .Metal => &shaders.fs_sprite_mtl,
        .Vulkan => &shaders.fs_sprite_spv,
        else => &shaders.fs_sprite_glsl,
    };

    const vs_handle = bgfx.createShader(bgfx.makeRef(vs_data.ptr, @intCast(vs_data.len)));
    const fs_handle = bgfx.createShader(bgfx.makeRef(fs_data.ptr, @intCast(fs_data.len)));

    if (!isValidHandle(vs_handle.idx) or !isValidHandle(fs_handle.idx)) {
        std.log.err("bgfx: failed to create sprite shaders", .{});
        return;
    }

    // createProgram with destroy_shaders=true so bgfx owns the shader handles
    sprite_program = bgfx.createProgram(vs_handle, fs_handle, true);
    if (!isValidProgram(sprite_program)) {
        std.log.err("bgfx: failed to create sprite shader program", .{});
        return;
    }

    // Create sampler uniform
    s_tex_uniform = bgfx.createUniform("s_tex", .Sampler, 1);

    // Set view transform to identity (we compute NDC positions in Zig)
    const identity = [16]f32{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    };
    bgfx.setViewTransform(VIEW_ID, &identity, &identity);

    // Create 1x1 white RGBA8 texture for flat-color rendering
    const white_pixel = [4]u8{ 255, 255, 255, 255 };
    const white_mem = bgfx.copy(&white_pixel, 4);
    white_texture = bgfx.createTexture2D(1, 1, false, 1, .RGBA8, 0, white_mem, 0);

    if (!isValidHandle(white_texture.idx)) {
        std.log.err("bgfx: failed to create 1x1 white texture", .{});
        return;
    }

    shaders_initialized = true;
    std.log.info("bgfx: sprite shaders initialized (renderer: {})", .{bgfx.getRendererType()});
}

/// Ensure shaders are initialized before any rendering. Called from submit paths.
fn ensureShadersInitialized() void {
    if (!shaders_initialized) initShaders();
}

/// Destroy shader programs, uniforms, and textures, resetting to invalid sentinels.
pub fn shutdownPrograms() void {
    if (isValidProgram(sprite_program)) {
        bgfx.destroyProgram(sprite_program);
        sprite_program = .{ .idx = std.math.maxInt(u16) };
    }
    if (isValidHandle(s_tex_uniform.idx)) {
        bgfx.destroyUniform(s_tex_uniform);
        s_tex_uniform = .{ .idx = std.math.maxInt(u16) };
    }
    // u_viewProj is a built-in bgfx uniform — nothing to destroy
    if (isValidHandle(white_texture.idx)) {
        bgfx.destroyTexture(white_texture);
        white_texture = .{ .idx = std.math.maxInt(u16) };
    }
    shaders_initialized = false;

    // Destroy user textures
    for (0..MAX_TEXTURES) |i| {
        if (texture_handles[i].idx != std.math.maxInt(u16)) {
            bgfx.destroyTexture(texture_handles[i]);
            texture_handles[i] = .{ .idx = std.math.maxInt(u16) };
        }
        if (texture_pixel_data[i]) |px| {
            std.heap.page_allocator.free(px);
            texture_pixel_data[i] = null;
        }
    }
    // Destroy font atlas texture if it was created
    if (font_texture.idx != std.math.maxInt(u16)) {
        bgfx.destroyTexture(font_texture);
        font_texture = .{ .idx = std.math.maxInt(u16) };
        font_atlas_initialized = false;
    }
}

/// Returns true when the shader program is valid and ready for use.
pub fn areProgramsReady() bool {
    return shaders_initialized and isValidProgram(sprite_program);
}

/// View ID used for 2D rendering.
const VIEW_ID: u16 = 0;

fn ensureLayouts() void {
    if (layouts_initialized) return;

    // Unified layout matching the v1 sprite shader:
    //   a_position  (vec2)  — 2 floats
    //   a_texcoord0 (vec2)  — 2 floats
    //   a_color0    (vec4)  — 4 Uint8, normalized
    _ = vertex_layout.begin(.Noop);
    _ = vertex_layout.add(.Position, 2, .Float, false, false);
    _ = vertex_layout.add(.TexCoord0, 2, .Float, false, false);
    _ = vertex_layout.add(.Color0, 4, .Uint8, true, false);
    vertex_layout.end();

    layouts_initialized = true;
}

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

/// Convert screen-space pixel coordinate to NDC for the orthographic projection.
fn toNdcX(px: f32) f32 {
    return (px / @as(f32, @floatFromInt(screen_w))) * 2.0 - 1.0;
}

fn toNdcY(px: f32) f32 {
    // Flip Y: screen top=0 maps to NDC +1
    return 1.0 - (px / @as(f32, @floatFromInt(screen_h))) * 2.0;
}

// ── Internal helpers ──────────────────────────────────────────────────

fn submitFlatTriangles(vertices: []const PosTexColorVertex) void {
    ensureShadersInitialized();
    if (!isValidProgram(sprite_program)) return;
    ensureLayouts();

    // Set u_viewProj to identity each frame (bgfx clears uniforms after submit)
    const identity = [16]f32{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    };
    bgfx.setViewTransform(VIEW_ID, &identity, &identity);

    const num_vertices: usize = vertices.len;
    const num: u32 = @intCast(num_vertices);
    var tvb: bgfx.TransientVertexBuffer = undefined;

    bgfx.allocTransientVertexBuffer(&tvb, num, &vertex_layout);

    const dest: [*]PosTexColorVertex = @ptrCast(@alignCast(tvb.data));
    @memcpy(dest[0..num_vertices], vertices);

    bgfx.setTransientVertexBuffer(0, &tvb, 0, num);
    // Bind 1x1 white texture so the shader computes: white * vertex_color = vertex_color
    bgfx.setTexture(0, s_tex_uniform, white_texture, 0);
    bgfx.setState(bgfx.StateFlags_WriteRgb | bgfx.StateFlags_WriteA | STATE_BLEND_ALPHA, 0);
    bgfx.submit(VIEW_ID, sprite_program, 0, @as(u8, @intCast(bgfx.DiscardFlags_All)));
}

/// Create a flat-color vertex (UV 0,0 for use with the 1x1 white texture).
fn makeVertex(px: f32, py: f32, abgr: u32) PosTexColorVertex {
    return .{
        .x = toNdcX(px),
        .y = toNdcY(py),
        .u = 0.0,
        .v = 0.0,
        .abgr = abgr,
    };
}

fn submitTexturedTriangles(vertices: []const PosTexColorVertex, texture_handle: bgfx.TextureHandle) void {
    ensureShadersInitialized();
    if (!isValidProgram(sprite_program)) return;
    if (!isValidHandle(s_tex_uniform.idx)) return;
    ensureLayouts();

    // Set u_viewProj to identity each frame (bgfx clears uniforms after submit)
    const identity = [16]f32{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    };
    bgfx.setViewTransform(VIEW_ID, &identity, &identity);

    const num_vertices: usize = vertices.len;
    const num: u32 = @intCast(num_vertices);
    var tvb: bgfx.TransientVertexBuffer = undefined;

    bgfx.allocTransientVertexBuffer(&tvb, num, &vertex_layout);

    const dest_ptr: [*]PosTexColorVertex = @ptrCast(@alignCast(tvb.data));
    @memcpy(dest_ptr[0..num_vertices], vertices);

    bgfx.setTransientVertexBuffer(0, &tvb, 0, num);
    bgfx.setTexture(0, s_tex_uniform, texture_handle, 0);
    bgfx.setState(bgfx.StateFlags_WriteRgb | bgfx.StateFlags_WriteA | STATE_BLEND_ALPHA, 0);
    bgfx.submit(VIEW_ID, sprite_program, 0, @as(u8, @intCast(bgfx.DiscardFlags_All)));
}

fn makeTexVertex(px: f32, py: f32, u: f32, v: f32, abgr: u32) PosTexColorVertex {
    return .{
        .x = toNdcX(px),
        .y = toNdcY(py),
        .u = u,
        .v = v,
        .abgr = abgr,
    };
}

// ── Draw primitives (Backend contract) ─────────────────────────────────

/// Draw a filled rectangle.
pub fn drawRectangleRec(rec: Rectangle, tint: Color) void {
    const x0 = transformX(rec.x);
    const y0 = transformY(rec.y);
    const x1 = transformX(rec.x + rec.width);
    const y1 = transformY(rec.y + rec.height);
    const abgr = tint.toAbgr();

    // Two triangles forming a quad
    const vertices = [6]PosTexColorVertex{
        makeVertex(x0, y0, abgr), makeVertex(x1, y0, abgr), makeVertex(x1, y1, abgr),
        makeVertex(x0, y0, abgr), makeVertex(x1, y1, abgr), makeVertex(x0, y1, abgr),
    };
    submitFlatTriangles(&vertices);
}

/// Draw a filled circle approximated with triangles (fan from center).
/// Vertices are computed directly in NDC space with aspect ratio correction
/// so the circle remains round on non-square windows.
pub fn drawCircle(center_x: f32, center_y: f32, radius: f32, tint: Color) void {
    const SEGMENTS = 32;
    const cx = transformX(center_x);
    const cy = transformY(center_y);
    const scaled_radius = if (active_camera) |cam| radius * cam.zoom else radius;
    const abgr = tint.toAbgr();

    // Convert center to NDC once
    const ndc_cx = toNdcX(cx);
    const ndc_cy = toNdcY(cy);

    // Convert radius to NDC space separately for X and Y to preserve circularity.
    // toNdcX/Y map pixels to [-1,1] with different denominators (screen_w vs screen_h),
    // so a pixel radius maps to different NDC spans on each axis.
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    const ndc_rx = scaled_radius * 2.0 / sw;
    const ndc_ry = scaled_radius * 2.0 / sh;

    var vertices: [SEGMENTS * 3]PosTexColorVertex = undefined;

    for (0..SEGMENTS) |i| {
        const angle0 = @as(f32, @floatFromInt(i)) * (2.0 * std.math.pi / @as(f32, SEGMENTS));
        const angle1 = @as(f32, @floatFromInt(i + 1)) * (2.0 * std.math.pi / @as(f32, SEGMENTS));

        vertices[i * 3 + 0] = .{ .x = ndc_cx, .y = ndc_cy, .u = 0.0, .v = 0.0, .abgr = abgr };
        vertices[i * 3 + 1] = .{ .x = ndc_cx + ndc_rx * @cos(angle0), .y = ndc_cy + ndc_ry * @sin(angle0), .u = 0.0, .v = 0.0, .abgr = abgr };
        vertices[i * 3 + 2] = .{ .x = ndc_cx + ndc_rx * @cos(angle1), .y = ndc_cy + ndc_ry * @sin(angle1), .u = 0.0, .v = 0.0, .abgr = abgr };
    }

    submitFlatTriangles(&vertices);
}

/// Draw a line with thickness using a quad (two triangles).
pub fn drawLine(start_x: f32, start_y: f32, end_x: f32, end_y: f32, thickness: f32, tint: Color) void {
    const sx = transformX(start_x);
    const sy = transformY(start_y);
    const ex = transformX(end_x);
    const ey = transformY(end_y);
    const abgr = tint.toAbgr();

    // Compute perpendicular direction for thickness
    const dx = ex - sx;
    const dy = ey - sy;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.0001) return;

    const scaled_thickness = if (active_camera) |cam| thickness * cam.zoom else thickness;
    const half = scaled_thickness * 0.5;
    const nx = -dy / len * half; // perpendicular x
    const ny = dx / len * half; // perpendicular y

    const vertices = [6]PosTexColorVertex{
        makeVertex(sx + nx, sy + ny, abgr), makeVertex(sx - nx, sy - ny, abgr), makeVertex(ex - nx, ey - ny, abgr),
        makeVertex(sx + nx, sy + ny, abgr), makeVertex(ex - nx, ey - ny, abgr), makeVertex(ex + nx, ey + ny, abgr),
    };
    submitFlatTriangles(&vertices);
}

/// Draw a filled triangle.
pub fn drawTriangle(v1: Vector2, v2: Vector2, v3: Vector2, tint: Color) void {
    const abgr = tint.toAbgr();
    const vertices = [3]PosTexColorVertex{
        makeVertex(transformX(v1.x), transformY(v1.y), abgr),
        makeVertex(transformX(v2.x), transformY(v2.y), abgr),
        makeVertex(transformX(v3.x), transformY(v3.y), abgr),
    };
    submitFlatTriangles(&vertices);
}

/// Draw a filled convex polygon using a triangle fan.
/// `points` must have at least 3 vertices and the polygon must be convex.
pub fn drawPolygon(points: []const Vector2, tint: Color) void {
    if (points.len < 3) return;

    const abgr = tint.toAbgr();
    const num_triangles = points.len - 2;
    const num_verts = num_triangles * 3;

    // Stack buffer for small polygons, skip very large ones.
    const MAX_POLYGON_VERTS = 128 * 3;
    if (num_verts > MAX_POLYGON_VERTS) return;

    var vertices: [MAX_POLYGON_VERTS]PosTexColorVertex = undefined;
    const p0 = makeVertex(transformX(points[0].x), transformY(points[0].y), abgr);

    for (0..num_triangles) |i| {
        vertices[i * 3 + 0] = p0;
        vertices[i * 3 + 1] = makeVertex(transformX(points[i + 1].x), transformY(points[i + 1].y), abgr);
        vertices[i * 3 + 2] = makeVertex(transformX(points[i + 2].x), transformY(points[i + 2].y), abgr);
    }

    submitFlatTriangles(vertices[0..num_verts]);
}

// ── Texture / Sprite rendering ────────────────────────────────────────

/// Texture handle storage: maps our Texture.id to bgfx TextureHandle.
const MAX_TEXTURES = 512;
var texture_handles: [MAX_TEXTURES]bgfx.TextureHandle = [_]bgfx.TextureHandle{.{ .idx = std.math.maxInt(u16) }} ** MAX_TEXTURES;
/// Pixel data backing each texture (decoded RGBA8 pixels, owned).
/// Stored so we can free on unload/shutdown. null means no decoded data.
var texture_pixel_data: [MAX_TEXTURES]?[]u8 = [_]?[]u8{null} ** MAX_TEXTURES;

/// Find a free texture slot by scanning for invalid handles (supports reuse after unload).
fn findFreeTextureSlot() ?u32 {
    // Start from 1 (slot 0 is reserved/unused)
    for (1..MAX_TEXTURES) |i| {
        if (texture_handles[i].idx == std.math.maxInt(u16)) {
            return @intCast(i);
        }
    }
    return null;
}

pub fn loadTexture(path: [:0]const u8) !Texture {
    // Check for a free texture slot before doing any work
    const id = findFreeTextureSlot() orelse return error.LoadFailed;

    // Read file from disk
    const file = std.fs.cwd().openFile(path, .{}) catch return error.LoadFailed;
    defer file.close();

    const stat = file.stat() catch return error.LoadFailed;
    const file_size = stat.size;
    if (file_size < 18) return error.LoadFailed; // Too small for any image header

    const allocator = std.heap.page_allocator;
    const data = allocator.alloc(u8, file_size) catch return error.LoadFailed;
    defer allocator.free(data);

    const bytes_read = file.readAll(data) catch return error.LoadFailed;
    if (bytes_read < 18) return error.LoadFailed;

    const file_buf = data[0..bytes_read];

    // Try BMP first, then TGA
    // TODO: Add PNG decoding (requires inflate/zlib decompression) or integrate stb_image
    if (tryDecodeBmp(file_buf)) |img| {
        const mem = bgfx.copy(img.pixels.ptr, @intCast(img.pixels.len));
        const handle = bgfx.createTexture2D(
            img.width,
            img.height,
            false,
            1,
            .RGBA8,
            bgfx.SamplerFlags_UClamp | bgfx.SamplerFlags_VClamp,
            mem,
            0,
        );
        if (handle.idx == std.math.maxInt(u16)) {
            allocator.free(img.pixels);
            return error.LoadFailed;
        }
        texture_handles[id] = handle;
        texture_pixel_data[id] = img.pixels;
        return .{ .id = id, .width = @intCast(img.width), .height = @intCast(img.height) };
    }

    if (tryDecodeTga(file_buf)) |img| {
        const mem = bgfx.copy(img.pixels.ptr, @intCast(img.pixels.len));
        const handle = bgfx.createTexture2D(
            img.width,
            img.height,
            false,
            1,
            .RGBA8,
            bgfx.SamplerFlags_UClamp | bgfx.SamplerFlags_VClamp,
            mem,
            0,
        );
        if (handle.idx == std.math.maxInt(u16)) {
            allocator.free(img.pixels);
            return error.LoadFailed;
        }
        texture_handles[id] = handle;
        texture_pixel_data[id] = img.pixels;
        return .{ .id = id, .width = @intCast(img.width), .height = @intCast(img.height) };
    }

    return error.LoadFailed;
}

pub fn unloadTexture(texture: Texture) void {
    if (texture.id < MAX_TEXTURES) {
        const handle = texture_handles[texture.id];
        if (handle.idx != std.math.maxInt(u16)) {
            bgfx.destroyTexture(handle);
            texture_handles[texture.id] = .{ .idx = std.math.maxInt(u16) };
        }
        if (texture_pixel_data[texture.id]) |px| {
            std.heap.page_allocator.free(px);
            texture_pixel_data[texture.id] = null;
        }
    }
}

pub fn drawTexturePro(texture: Texture, source: Rectangle, dest: Rectangle, origin: Vector2, rotation: f32, tint: Color) void {
    if (texture.id >= MAX_TEXTURES) return;
    const handle = texture_handles[texture.id];
    if (handle.idx == std.math.maxInt(u16)) return;

    const abgr = tint.toAbgr();
    const tw: f32 = @floatFromInt(texture.width);
    const th: f32 = @floatFromInt(texture.height);

    // Source rect to UV coordinates
    const uv0 = source.x / tw;
    const tv0 = source.y / th;
    const uv1 = (source.x + source.width) / tw;
    const tv1 = (source.y + source.height) / th;

    // Destination quad corners (before rotation)
    // Scale width, height, and origin by camera zoom for consistent coordinate space
    const zoom = if (active_camera) |cam| cam.zoom else @as(f32, 1.0);
    const scaled_ox = origin.x * zoom;
    const scaled_oy = origin.y * zoom;
    const dx = transformX(dest.x) - scaled_ox;
    const dy = transformY(dest.y) - scaled_oy;
    const dw = dest.width * zoom;
    const dh = dest.height * zoom;

    if (rotation == 0.0) {
        // Fast path: axis-aligned textured quad
        const vertices = [6]PosTexColorVertex{
            makeTexVertex(dx, dy, uv0, tv0, abgr),
            makeTexVertex(dx + dw, dy, uv1, tv0, abgr),
            makeTexVertex(dx + dw, dy + dh, uv1, tv1, abgr),
            makeTexVertex(dx, dy, uv0, tv0, abgr),
            makeTexVertex(dx + dw, dy + dh, uv1, tv1, abgr),
            makeTexVertex(dx, dy + dh, uv0, tv1, abgr),
        };
        submitTexturedTriangles(&vertices, handle);
    } else {
        // Rotated quad: rotate corners around origin point
        const rad = rotation * (std.math.pi / 180.0);
        const cos_r = @cos(rad);
        const sin_r = @sin(rad);
        const ox = scaled_ox;
        const oy = scaled_oy;

        const corners = [4][2]f32{
            .{ 0, 0 },
            .{ dw, 0 },
            .{ dw, dh },
            .{ 0, dh },
        };

        var rotated: [4][2]f32 = undefined;
        for (corners, 0..) |corner, i| {
            const cx = corner[0] - ox;
            const cy = corner[1] - oy;
            rotated[i] = .{
                dx + ox + cx * cos_r - cy * sin_r,
                dy + oy + cx * sin_r + cy * cos_r,
            };
        }

        const uvs = [4][2]f32{ .{ uv0, tv0 }, .{ uv1, tv0 }, .{ uv1, tv1 }, .{ uv0, tv1 } };

        const vertices = [6]PosTexColorVertex{
            makeTexVertex(rotated[0][0], rotated[0][1], uvs[0][0], uvs[0][1], abgr),
            makeTexVertex(rotated[1][0], rotated[1][1], uvs[1][0], uvs[1][1], abgr),
            makeTexVertex(rotated[2][0], rotated[2][1], uvs[2][0], uvs[2][1], abgr),
            makeTexVertex(rotated[0][0], rotated[0][1], uvs[0][0], uvs[0][1], abgr),
            makeTexVertex(rotated[2][0], rotated[2][1], uvs[2][0], uvs[2][1], abgr),
            makeTexVertex(rotated[3][0], rotated[3][1], uvs[3][0], uvs[3][1], abgr),
        };
        submitTexturedTriangles(&vertices, handle);
    }
}

// ── Image decoding helpers ─────────────────────────────────────────────

const DecodedImage = struct {
    pixels: []u8, // RGBA8, owned by page_allocator
    width: u16,
    height: u16,
};

/// Decode an uncompressed 24-bit or 32-bit BMP to RGBA8.
/// Handles BGR-to-RGB conversion, row padding, and top-down/bottom-up orientation.
fn tryDecodeBmp(data: []const u8) ?DecodedImage {
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
/// Handles 24/32-bit pixels, BGR-to-RGB conversion, and orientation via descriptor bit 5.
fn tryDecodeTga(data: []const u8) ?DecodedImage {
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

// ── Text rendering (embedded bitmap font) ─────────────────────────────

/// Embedded 8x8 bitmap font covering printable ASCII (32..126).
/// Each character is 8 rows of 8 bits (1 byte per row, MSB = leftmost pixel).
const FONT_CHAR_W = 8;
const FONT_CHAR_H = 8;
const FONT_FIRST_CHAR = 32; // space
const FONT_LAST_CHAR = 126; // tilde
const FONT_NUM_CHARS = FONT_LAST_CHAR - FONT_FIRST_CHAR + 1;

/// Font atlas texture (created lazily on first drawText call).
var font_texture: bgfx.TextureHandle = .{ .idx = std.math.maxInt(u16) };
var font_atlas_initialized: bool = false;

/// Atlas dimensions: characters laid out in a single row.
const FONT_ATLAS_W = FONT_CHAR_W * FONT_NUM_CHARS;
const FONT_ATLAS_H = FONT_CHAR_H;

/// 8x8 bitmap font data. Each entry is 8 bytes (rows top-to-bottom).
const font_data: [FONT_NUM_CHARS][8]u8 = generateFontData();

fn generateFontData() [FONT_NUM_CHARS][8]u8 {
    var data: [FONT_NUM_CHARS][8]u8 = [_][8]u8{[_]u8{0} ** 8} ** FONT_NUM_CHARS;

    // ! (33)
    data[33 - 32] = .{ 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x00 };
    // " (34)
    data[34 - 32] = .{ 0x6C, 0x6C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    // # (35)
    data[35 - 32] = .{ 0x6C, 0xFE, 0x6C, 0x6C, 0xFE, 0x6C, 0x00, 0x00 };
    // $ (36)
    data[36 - 32] = .{ 0x18, 0x7E, 0x58, 0x7E, 0x1A, 0x7E, 0x18, 0x00 };
    // % (37)
    data[37 - 32] = .{ 0x62, 0x64, 0x08, 0x10, 0x26, 0x46, 0x00, 0x00 };
    // & (38)
    data[38 - 32] = .{ 0x38, 0x6C, 0x38, 0x76, 0xDC, 0x76, 0x00, 0x00 };
    // ' (39)
    data[39 - 32] = .{ 0x18, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    // ( (40)
    data[40 - 32] = .{ 0x0C, 0x18, 0x30, 0x30, 0x30, 0x18, 0x0C, 0x00 };
    // ) (41)
    data[41 - 32] = .{ 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x18, 0x30, 0x00 };
    // * (42)
    data[42 - 32] = .{ 0x00, 0x66, 0x3C, 0xFF, 0x3C, 0x66, 0x00, 0x00 };
    // + (43)
    data[43 - 32] = .{ 0x00, 0x18, 0x18, 0x7E, 0x18, 0x18, 0x00, 0x00 };
    // , (44)
    data[44 - 32] = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30 };
    // - (45)
    data[45 - 32] = .{ 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00 };
    // . (46)
    data[46 - 32] = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00 };
    // / (47)
    data[47 - 32] = .{ 0x02, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x40, 0x00 };

    // 0-9
    data['0' - 32] = .{ 0x3C, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x3C, 0x00 };
    data['1' - 32] = .{ 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00 };
    data['2' - 32] = .{ 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x30, 0x7E, 0x00 };
    data['3' - 32] = .{ 0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00 };
    data['4' - 32] = .{ 0x0C, 0x1C, 0x2C, 0x4C, 0x7E, 0x0C, 0x0C, 0x00 };
    data['5' - 32] = .{ 0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00 };
    data['6' - 32] = .{ 0x3C, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x3C, 0x00 };
    data['7' - 32] = .{ 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x00 };
    data['8' - 32] = .{ 0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00 };
    data['9' - 32] = .{ 0x3C, 0x66, 0x66, 0x3E, 0x06, 0x06, 0x3C, 0x00 };

    // : (58)
    data[58 - 32] = .{ 0x00, 0x00, 0x18, 0x00, 0x00, 0x18, 0x00, 0x00 };
    // ; (59)
    data[59 - 32] = .{ 0x00, 0x00, 0x18, 0x00, 0x00, 0x18, 0x18, 0x30 };
    // < (60)
    data[60 - 32] = .{ 0x06, 0x0C, 0x18, 0x30, 0x18, 0x0C, 0x06, 0x00 };
    // = (61)
    data[61 - 32] = .{ 0x00, 0x00, 0x7E, 0x00, 0x7E, 0x00, 0x00, 0x00 };
    // > (62)
    data[62 - 32] = .{ 0x60, 0x30, 0x18, 0x0C, 0x18, 0x30, 0x60, 0x00 };
    // ? (63)
    data[63 - 32] = .{ 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x00, 0x18, 0x00 };
    // @ (64)
    data[64 - 32] = .{ 0x3C, 0x66, 0x6E, 0x6A, 0x6E, 0x60, 0x3C, 0x00 };

    // A-Z
    data['A' - 32] = .{ 0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00 };
    data['B' - 32] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00 };
    data['C' - 32] = .{ 0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0x00 };
    data['D' - 32] = .{ 0x78, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0x78, 0x00 };
    data['E' - 32] = .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x7E, 0x00 };
    data['F' - 32] = .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x60, 0x00 };
    data['G' - 32] = .{ 0x3C, 0x66, 0x60, 0x6E, 0x66, 0x66, 0x3E, 0x00 };
    data['H' - 32] = .{ 0x66, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00 };
    data['I' - 32] = .{ 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 };
    data['J' - 32] = .{ 0x1E, 0x0C, 0x0C, 0x0C, 0x0C, 0x6C, 0x38, 0x00 };
    data['K' - 32] = .{ 0x66, 0x6C, 0x78, 0x70, 0x78, 0x6C, 0x66, 0x00 };
    data['L' - 32] = .{ 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x7E, 0x00 };
    data['M' - 32] = .{ 0xC6, 0xEE, 0xFE, 0xD6, 0xC6, 0xC6, 0xC6, 0x00 };
    data['N' - 32] = .{ 0x66, 0x76, 0x7E, 0x7E, 0x6E, 0x66, 0x66, 0x00 };
    data['O' - 32] = .{ 0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 };
    data['P' - 32] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x00 };
    data['Q' - 32] = .{ 0x3C, 0x66, 0x66, 0x66, 0x6A, 0x6C, 0x36, 0x00 };
    data['R' - 32] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0x66, 0x00 };
    data['S' - 32] = .{ 0x3C, 0x66, 0x60, 0x3C, 0x06, 0x66, 0x3C, 0x00 };
    data['T' - 32] = .{ 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00 };
    data['U' - 32] = .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 };
    data['V' - 32] = .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 };
    data['W' - 32] = .{ 0xC6, 0xC6, 0xC6, 0xD6, 0xFE, 0xEE, 0xC6, 0x00 };
    data['X' - 32] = .{ 0x66, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x66, 0x00 };
    data['Y' - 32] = .{ 0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x18, 0x00 };
    data['Z' - 32] = .{ 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x7E, 0x00 };

    // [ (91)
    data[91 - 32] = .{ 0x3C, 0x30, 0x30, 0x30, 0x30, 0x30, 0x3C, 0x00 };
    // \ (92)
    data[92 - 32] = .{ 0x40, 0x60, 0x30, 0x18, 0x0C, 0x06, 0x02, 0x00 };
    // ] (93)
    data[93 - 32] = .{ 0x3C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x3C, 0x00 };
    // ^ (94)
    data[94 - 32] = .{ 0x18, 0x3C, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00 };
    // _ (95)
    data[95 - 32] = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7E, 0x00 };
    // ` (96)
    data[96 - 32] = .{ 0x30, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

    // a-z (lowercase)
    data['a' - 32] = .{ 0x00, 0x00, 0x3C, 0x06, 0x3E, 0x66, 0x3E, 0x00 };
    data['b' - 32] = .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x7C, 0x00 };
    data['c' - 32] = .{ 0x00, 0x00, 0x3C, 0x66, 0x60, 0x66, 0x3C, 0x00 };
    data['d' - 32] = .{ 0x06, 0x06, 0x3E, 0x66, 0x66, 0x66, 0x3E, 0x00 };
    data['e' - 32] = .{ 0x00, 0x00, 0x3C, 0x66, 0x7E, 0x60, 0x3C, 0x00 };
    data['f' - 32] = .{ 0x1C, 0x30, 0x7C, 0x30, 0x30, 0x30, 0x30, 0x00 };
    data['g' - 32] = .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x3C };
    data['h' - 32] = .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 };
    data['i' - 32] = .{ 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x3C, 0x00 };
    data['j' - 32] = .{ 0x0C, 0x00, 0x1C, 0x0C, 0x0C, 0x0C, 0x6C, 0x38 };
    data['k' - 32] = .{ 0x60, 0x60, 0x66, 0x6C, 0x78, 0x6C, 0x66, 0x00 };
    data['l' - 32] = .{ 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 };
    data['m' - 32] = .{ 0x00, 0x00, 0xEC, 0xFE, 0xD6, 0xC6, 0xC6, 0x00 };
    data['n' - 32] = .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 };
    data['o' - 32] = .{ 0x00, 0x00, 0x3C, 0x66, 0x66, 0x66, 0x3C, 0x00 };
    data['p' - 32] = .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60 };
    data['q' - 32] = .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x06 };
    data['r' - 32] = .{ 0x00, 0x00, 0x7C, 0x66, 0x60, 0x60, 0x60, 0x00 };
    data['s' - 32] = .{ 0x00, 0x00, 0x3E, 0x60, 0x3C, 0x06, 0x7C, 0x00 };
    data['t' - 32] = .{ 0x30, 0x30, 0x7C, 0x30, 0x30, 0x30, 0x1C, 0x00 };
    data['u' - 32] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x3E, 0x00 };
    data['v' - 32] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 };
    data['w' - 32] = .{ 0x00, 0x00, 0xC6, 0xD6, 0xFE, 0xEE, 0xC6, 0x00 };
    data['x' - 32] = .{ 0x00, 0x00, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x00 };
    data['y' - 32] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3E, 0x06, 0x3C };
    data['z' - 32] = .{ 0x00, 0x00, 0x7E, 0x0C, 0x18, 0x30, 0x7E, 0x00 };

    // { (123)
    data[123 - 32] = .{ 0x0E, 0x18, 0x18, 0x70, 0x18, 0x18, 0x0E, 0x00 };
    // | (124)
    data[124 - 32] = .{ 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00 };
    // } (125)
    data[125 - 32] = .{ 0x70, 0x18, 0x18, 0x0E, 0x18, 0x18, 0x70, 0x00 };
    // ~ (126)
    data[126 - 32] = .{ 0x00, 0x00, 0x76, 0xDC, 0x00, 0x00, 0x00, 0x00 };

    return data;
}

fn ensureFontAtlas() void {
    if (font_atlas_initialized) return;

    // Build RGBA8 atlas: all chars in a single row
    var pixels: [FONT_ATLAS_W * FONT_ATLAS_H * 4]u8 = [_]u8{0} ** (FONT_ATLAS_W * FONT_ATLAS_H * 4);

    for (0..FONT_NUM_CHARS) |ch| {
        const glyph = font_data[ch];
        for (0..FONT_CHAR_H) |row| {
            const bits = glyph[row];
            for (0..FONT_CHAR_W) |col| {
                const px_x = ch * FONT_CHAR_W + col;
                const px_y = row;
                const idx = (px_y * FONT_ATLAS_W + px_x) * 4;
                const bit: u8 = @intCast((bits >> @intCast(7 - col)) & 1);
                const val: u8 = bit * 255;
                pixels[idx + 0] = val; // R
                pixels[idx + 1] = val; // G
                pixels[idx + 2] = val; // B
                pixels[idx + 3] = val; // A
            }
        }
    }

    const mem = bgfx.copy(&pixels, @intCast(pixels.len));
    font_texture = bgfx.createTexture2D(
        @intCast(FONT_ATLAS_W),
        @intCast(FONT_ATLAS_H),
        false,
        1,
        .RGBA8,
        bgfx.SamplerFlags_MinPoint | bgfx.SamplerFlags_MagPoint,
        mem,
        0,
    );

    // Only mark initialized after successful texture creation
    if (font_texture.idx != std.math.maxInt(u16)) {
        font_atlas_initialized = true;
    }
}

pub fn drawText(text: [:0]const u8, x: f32, y: f32, size: f32, tint: Color) void {
    ensureFontAtlas();
    if (font_texture.idx == std.math.maxInt(u16)) return;

    const zoom = if (active_camera) |cam| cam.zoom else @as(f32, 1.0);
    const scale = size / @as(f32, FONT_CHAR_H) * zoom;
    const char_w = @as(f32, FONT_CHAR_W) * scale;
    const char_h = @as(f32, FONT_CHAR_H) * scale;
    const abgr = tint.toAbgr();

    const atlas_w_f: f32 = @floatFromInt(FONT_ATLAS_W);

    var cursor_x = transformX(x);
    const cursor_y = transformY(y);

    for (text) |ch| {
        if (ch < FONT_FIRST_CHAR or ch > FONT_LAST_CHAR) {
            cursor_x += char_w;
            continue;
        }

        const glyph_idx: usize = ch - FONT_FIRST_CHAR;
        const uv0 = @as(f32, @floatFromInt(glyph_idx * FONT_CHAR_W)) / atlas_w_f;
        const uv1 = @as(f32, @floatFromInt((glyph_idx + 1) * FONT_CHAR_W)) / atlas_w_f;
        const tv0: f32 = 0.0;
        const tv1: f32 = 1.0;

        const vertices = [6]PosTexColorVertex{
            makeTexVertex(cursor_x, cursor_y, uv0, tv0, abgr),
            makeTexVertex(cursor_x + char_w, cursor_y, uv1, tv0, abgr),
            makeTexVertex(cursor_x + char_w, cursor_y + char_h, uv1, tv1, abgr),
            makeTexVertex(cursor_x, cursor_y, uv0, tv0, abgr),
            makeTexVertex(cursor_x + char_w, cursor_y + char_h, uv1, tv1, abgr),
            makeTexVertex(cursor_x, cursor_y + char_h, uv0, tv1, abgr),
        };
        submitTexturedTriangles(&vertices, font_texture);

        cursor_x += char_w;
    }
}

// ── Utility functions (Backend contract) ──────────────────────────────

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
