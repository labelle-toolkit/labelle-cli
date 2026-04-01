/// Raylib gfx backend — satisfies the labelle-gfx Backend(Impl) contract.
const rl = @import("raylib");

// ── Backend types ──────────────────────────────────────────────────────

pub const Texture = struct { id: u32, width: i32, height: i32 };

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    fn toRl(c: Color) rl.Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
    }
};

pub const Rectangle = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    fn toRl(r: Rectangle) rl.Rectangle {
        return .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
    }
};

pub const Vector2 = struct {
    x: f32,
    y: f32,

    fn toRl(v: Vector2) rl.Vector2 {
        return .{ .x = v.x, .y = v.y };
    }
};

pub const Camera2D = struct {
    offset: Vector2 = .{ .x = 0, .y = 0 },
    target: Vector2 = .{ .x = 0, .y = 0 },
    rotation: f32 = 0,
    zoom: f32 = 1,

    fn toRl(c: Camera2D) rl.Camera2D {
        return .{
            .offset = .{ .x = c.offset.x, .y = c.offset.y },
            .target = .{ .x = c.target.x, .y = c.target.y },
            .rotation = c.rotation,
            .zoom = c.zoom,
        };
    }
};

// ── Color constants ────────────────────────────────────────────────────

pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
pub const red = Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
pub const green = Color{ .r = 0, .g = 255, .b = 0, .a = 255 };
pub const blue = Color{ .r = 0, .g = 0, .b = 255, .a = 255 };
pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

// ── Draw primitives (Backend contract) ─────────────────────────────────

pub fn drawTexturePro(texture: Texture, source: Rectangle, dest: Rectangle, origin: Vector2, rotation: f32, tint: Color) void {
    const rl_tex: rl.Texture = .{
        .id = @intCast(texture.id),
        .width = texture.width,
        .height = texture.height,
        .mipmaps = 1,
        .format = .uncompressed_r8g8b8a8,
    };
    rl.drawTexturePro(rl_tex, source.toRl(), dest.toRl(), origin.toRl(), rotation, tint.toRl());
}

pub fn drawRectangleRec(rec: Rectangle, tint: Color) void {
    rl.drawRectangleRec(rec.toRl(), tint.toRl());
}

pub fn drawCircle(center_x: f32, center_y: f32, radius: f32, tint: Color) void {
    rl.drawCircleV(.{ .x = center_x, .y = center_y }, radius, tint.toRl());
}

pub fn drawRectangleLinesEx(rec: Rectangle, line_thick: f32, tint: Color) void {
    rl.drawRectangleLinesEx(rec.toRl(), line_thick, tint.toRl());
}

pub fn drawCircleLines(center_x: f32, center_y: f32, radius: f32, tint: Color) void {
    rl.drawCircleLinesV(.{ .x = center_x, .y = center_y }, radius, tint.toRl());
}

pub fn drawLine(start_x: f32, start_y: f32, end_x: f32, end_y: f32, thickness: f32, tint: Color) void {
    rl.drawLineEx(.{ .x = start_x, .y = start_y }, .{ .x = end_x, .y = end_y }, thickness, tint.toRl());
}

pub fn drawText(text: [:0]const u8, x: f32, y: f32, size: f32, tint: Color) void {
    rl.drawText(text, @intFromFloat(x), @intFromFloat(y), @intFromFloat(size), tint.toRl());
}

pub fn color(r: u8, g: u8, b: u8, a: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

pub fn loadTexture(path: [:0]const u8) !Texture {
    const tex = rl.loadTexture(path) catch return error.LoadFailed;
    if (tex.id == 0) return error.LoadFailed;
    return .{ .id = @intCast(tex.id), .width = tex.width, .height = tex.height };
}

pub fn loadTextureFromMemory(file_type: [:0]const u8, data: []const u8) !Texture {
    const image = rl.loadImageFromMemory(file_type, data) catch return error.LoadFailed;
    defer rl.unloadImage(image);
    const tex = rl.loadTextureFromImage(image) catch return error.LoadFailed;
    if (tex.id == 0) return error.LoadFailed;
    return .{ .id = @intCast(tex.id), .width = tex.width, .height = tex.height };
}

pub fn unloadTexture(texture: Texture) void {
    rl.unloadTexture(.{
        .id = @intCast(texture.id),
        .width = texture.width,
        .height = texture.height,
        .mipmaps = 1,
        .format = .uncompressed_r8g8b8a8,
    });
}

pub fn beginMode2D(camera: Camera2D) void {
    rl.beginMode2D(camera.toRl());
}

pub fn endMode2D() void {
    rl.endMode2D();
}

pub fn getScreenWidth() i32 {
    return rl.getScreenWidth();
}

pub fn getScreenHeight() i32 {
    return rl.getScreenHeight();
}

pub fn screenToWorld(pos: Vector2, camera: Camera2D) Vector2 {
    const result = rl.getScreenToWorld2D(pos.toRl(), camera.toRl());
    return .{ .x = result.x, .y = result.y };
}

pub fn worldToScreen(pos: Vector2, camera: Camera2D) Vector2 {
    const result = rl.getWorldToScreen2D(pos.toRl(), camera.toRl());
    return .{ .x = result.x, .y = result.y };
}
