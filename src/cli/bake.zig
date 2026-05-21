//! Pre-bake PNG atlases to RGBA containers to eliminate cold-start
//! PNG decode cost at runtime. The backend decoders detect the LRGBA
//! magic and take a fast memcpy path; missing or stale .rgba files
//! fall back to the existing stb_image runtime decode.
//!
//! Incremental: a .rgba sibling is regenerated only when absent or
//! older than the source .png. The assembler picks up the fresher
//! sibling automatically (see labelle-assembler main_zig.zig).

const std = @import("std");
const project_config = @import("project_config.zig");
const config = @import("config.zig");

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
    resources: []const project_config.ResourceDef,
) !void {
    var baked: usize = 0;
    var skipped: usize = 0;

    for (resources) |res| {
        if (res.texture.len == 0) continue;
        // Case-insensitive so `.PNG` / `.Png` (common when art comes
        // from asset pipelines that preserve uploader casing) still
        // match. Skipped silently when the extension isn't a PNG.
        if (res.texture.len < 4) continue;
        const ext = res.texture[res.texture.len - 4 ..];
        if (!std.ascii.eqlIgnoreCase(ext, ".png")) continue;

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
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const rgba_stat = cwd.statFile(io, rgba_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    const png_stat = cwd.statFile(io, png_path, .{}) catch return false;
    return rgba_stat.mtime.nanoseconds >= png_stat.mtime.nanoseconds;
}

fn bakeOne(allocator: std.mem.Allocator, png_path: []const u8, rgba_path: []const u8) !void {
    const io = config.globalIo();
    // Read the PNG via the new Io.Dir API; trust the local build input.
    const png_bytes = try std.Io.Dir.cwd().readFileAlloc(io, png_path, allocator, .unlimited);
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

    // Checked multiplication — `w * h * 4` could overflow `usize` on
    // 32-bit targets or on adversarial inputs (stb_image permits up to
    // 2^24 per axis by default).
    const wh = std.math.mul(usize, @as(usize, @intCast(w)), @as(usize, @intCast(h))) catch return error.DecodeFailed;
    const pixels_len = std.math.mul(usize, wh, 4) catch return error.DecodeFailed;

    // Delete the partial .rgba on any error from here on. Without this
    // `errdefer`, a crash/OOM/disk-full mid-write leaves a truncated
    // file that `isFresh` would mistake for a valid cached bake on the
    // next run (mtime >= PNG).
    const cwd = std.Io.Dir.cwd();
    var out = try cwd.createFile(io, rgba_path, .{ .truncate = true });
    errdefer cwd.deleteFile(io, rgba_path) catch {};
    defer out.close(io);

    var header: [header_len]u8 = undefined;
    @memcpy(header[0..magic.len], magic);
    std.mem.writeInt(u32, header[magic.len..][0..4], @intCast(w), .little);
    std.mem.writeInt(u32, header[magic.len + 4 ..][0..4], @intCast(h), .little);
    try out.writeStreamingAll(io, &header);
    try out.writeStreamingAll(io, @as([*]const u8, @ptrCast(raw))[0..pixels_len]);
}
