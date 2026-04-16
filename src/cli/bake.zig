//! Pre-bake PNG atlases to RGBA containers to eliminate cold-start
//! PNG decode cost at runtime. The backend decoders detect the LRGBA
//! magic and take a fast memcpy path; missing or stale .rgba files
//! fall back to the existing stb_image runtime decode.
//!
//! Incremental: a .rgba sibling is regenerated only when absent or
//! older than the source .png. The assembler picks up the fresher
//! sibling automatically (see labelle-assembler main_zig.zig).

const std = @import("std");
const gen = @import("generator");

const stbi = @cImport({
    @cInclude("stb_image.h");
});

/// Container:
///   0..7   magic "LRGBA\0\0\0"
///   8..11  u32 LE width
///   12..15 u32 LE height
///   16..   width * height * 4 bytes RGBA
const magic = "LRGBA\x00\x00\x00";
const header_len: usize = magic.len + 8;

pub fn run(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    resources: []const gen.ResourceDef,
) !void {
    var baked: usize = 0;
    var skipped: usize = 0;

    for (resources) |res| {
        if (res.texture.len == 0) continue;
        if (!std.mem.endsWith(u8, res.texture, ".png")) continue;

        const png_path = try std.fs.path.join(allocator, &.{ project_dir, res.texture });
        defer allocator.free(png_path);

        const rgba_rel = try std.mem.concat(allocator, u8, &.{ res.texture[0 .. res.texture.len - 4], ".rgba" });
        defer allocator.free(rgba_rel);
        const rgba_path = try std.fs.path.join(allocator, &.{ project_dir, rgba_rel });
        defer allocator.free(rgba_path);

        if (try isFresh(rgba_path, png_path)) {
            skipped += 1;
            continue;
        }

        bakeOne(allocator, png_path, rgba_path) catch |err| {
            std.debug.print("labelle: bake '{s}' failed: {s}\n", .{ res.texture, @errorName(err) });
            return err;
        };
        baked += 1;
    }

    if (baked > 0 or skipped > 0) {
        std.debug.print("labelle: baked {d} atlas(es), {d} up-to-date\n", .{ baked, skipped });
    }
}

/// Returns true when the .rgba sibling exists and its mtime is >= the
/// .png's mtime. Missing .rgba (or missing .png) => false so the caller
/// proceeds to bake; actual PNG-read failures surface there.
fn isFresh(rgba_path: []const u8, png_path: []const u8) !bool {
    const rgba_stat = std.fs.cwd().statFile(rgba_path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    const png_stat = std.fs.cwd().statFile(png_path) catch return false;
    return rgba_stat.mtime >= png_stat.mtime;
}

fn bakeOne(allocator: std.mem.Allocator, png_path: []const u8, rgba_path: []const u8) !void {
    const png_file = try std.fs.cwd().openFile(png_path, .{});
    defer png_file.close();
    const png_bytes = try png_file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(png_bytes);

    var w: c_int = 0;
    var h: c_int = 0;
    var ch: c_int = 0;
    const raw = stbi.stbi_load_from_memory(
        @ptrCast(png_bytes.ptr),
        @intCast(png_bytes.len),
        &w,
        &h,
        &ch,
        4, // force RGBA
    );
    if (raw == null) return error.DecodeFailed;
    defer stbi.stbi_image_free(raw);
    if (w <= 0 or h <= 0) return error.DecodeFailed;

    const pixels_len: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;

    var out = try std.fs.cwd().createFile(rgba_path, .{ .truncate = true });
    defer out.close();

    var header: [header_len]u8 = undefined;
    @memcpy(header[0..magic.len], magic);
    std.mem.writeInt(u32, header[magic.len..][0..4], @intCast(w), .little);
    std.mem.writeInt(u32, header[magic.len + 4 ..][0..4], @intCast(h), .little);
    try out.writeAll(&header);
    try out.writeAll(@as([*]const u8, @ptrCast(raw))[0..pixels_len]);
}
