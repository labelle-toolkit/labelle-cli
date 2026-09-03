//! Reconcile the screenshot file a backend actually wrote with the path
//! the user asked for (cli#356).
//!
//! `labelle run --screenshot=<path>` forwards the path to the game via
//! `LABELLE_SCREENSHOT_PATH`; the backend owns the final filename. bgfx
//! APPENDS its own extension rather than honoring the request
//! (labelle-bgfx#57 — `bgfx_callback.zig` writes `<path>.tga`), so
//! `--screenshot=/tmp/shot.png` used to land at `/tmp/shot.png.tga`: a
//! name that claims BOTH formats and is wrong either way, and a file the
//! caller has to convert before using.
//!
//! The append lives in the backend repo, so the CLI cannot stop it. What
//! the CLI CAN do is finish the job after the run: the vendored stb
//! single-headers already decode and encode the formats involved
//! (`src/cli/stb_image_impl.c`), so a `.tga` capture is re-encoded to the
//! PNG the user asked for and the intermediate is removed. When the two
//! formats already agree (`--screenshot=shot.tga` → `shot.tga.tga`) the
//! file is simply moved onto the requested path — no re-encode.
//!
//! `plan` is pure and exhaustively tested; `apply` does the I/O.

const std = @import("std");
const config = @import("config.zig");

const c = @cImport({
    @cInclude("stb_image.h");
    @cInclude("stb_image_write.h");
});

/// An image format the CLI can both read (stb_image, see
/// `stb_image_impl.c`'s `STBI_ONLY_*` set) and write (stb_image_write).
/// JPEG is write-only in practice here — a backend never emits one — but
/// costs nothing to honor as a REQUESTED extension.
pub const Format = enum {
    png,
    bmp,
    tga,
    jpg,

    /// Human-facing name for the CLI's report line.
    pub fn label(self: Format) []const u8 {
        return switch (self) {
            .png => "PNG",
            .bmp => "BMP",
            .tga => "TGA",
            .jpg => "JPEG",
        };
    }

    /// True when stb_image can decode this format with the `STBI_ONLY_*`
    /// set the CLI compiles. JPEG decode is deliberately NOT enabled, so
    /// a `.jpg` file cannot be a conversion SOURCE.
    pub fn decodable(self: Format) bool {
        return switch (self) {
            .png, .bmp, .tga => true,
            .jpg => false,
        };
    }
};

/// The format a path's extension asks for, or null when the extension is
/// missing or not one the CLI handles. Case-insensitive: `.PNG` is a PNG
/// request on the case-preserving filesystems where it can occur.
pub fn formatFromPath(path: []const u8) ?Format {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return null;
    // A dot in a parent directory (`/tmp/v1.2/shot`) is not an extension.
    if (std.mem.indexOfAnyPos(u8, path, dot, "/\\") != null) return null;
    const ext = path[dot + 1 ..];
    if (ext.len == 0) return null;

    var buf: [8]u8 = undefined;
    if (ext.len > buf.len) return null;
    const lower = std.ascii.lowerString(buf[0..ext.len], ext);

    if (std.mem.eql(u8, lower, "png")) return .png;
    if (std.mem.eql(u8, lower, "bmp")) return .bmp;
    if (std.mem.eql(u8, lower, "tga")) return .tga;
    if (std.mem.eql(u8, lower, "jpg") or std.mem.eql(u8, lower, "jpeg")) return .jpg;
    return null;
}

/// What to do about the gap between the requested path and the written one.
pub const Plan = union(enum) {
    /// The backend wrote exactly what was asked for. Nothing to do.
    honored,
    /// Same format, wrong name (`shot.tga` → `shot.tga.tga`). Move it.
    move,
    /// Re-encode `from` as `to` at the requested path, then drop the source.
    transcode: struct { from: Format, to: Format },
    /// Nothing safe to do — report the backend's path verbatim. Either the
    /// request carried no usable extension (so there is no format to honor)
    /// or the written file is in a format the CLI cannot decode.
    keep,
};

/// Decide what should happen, given the resolved requested path and the
/// path the capture actually landed at. Pure — no filesystem access.
pub fn plan(requested: []const u8, written: []const u8) Plan {
    if (std.mem.eql(u8, requested, written)) return .honored;

    const want = formatFromPath(requested) orelse return .keep;
    const got = formatFromPath(written) orelse return .keep;
    if (!got.decodable()) return .keep;
    if (want == got) return .move;
    return .{ .transcode = .{ .from = got, .to = want } };
}

pub const ApplyError = error{
    DecodeFailed,
    EncodeFailed,
    OutOfMemory,
} || std.Io.Dir.RenameError || std.Io.Dir.ReadFileAllocError || std.Io.Dir.WriteFileError;

/// Carry out a `move`/`transcode` plan: after this returns, `requested`
/// holds the capture and `written` is gone. `honored`/`keep` are no-ops.
pub fn apply(allocator: std.mem.Allocator, p: Plan, requested: []const u8, written: []const u8) ApplyError!void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    switch (p) {
        .honored, .keep => {},
        .move => try cwd.rename(written, cwd, requested, io),
        .transcode => |t| {
            const out = try transcode(allocator, written, t.to);
            defer allocator.free(out);
            try cwd.writeFile(io, .{ .sub_path = requested, .data = out });
            // Only now is the capture safe at the requested path, so a
            // failed delete leaves a stray file rather than losing the
            // screenshot. Best-effort: a read-only directory is not worth
            // failing a successful conversion over.
            cwd.deleteFile(io, written) catch {};
        },
    }
}

/// Decode `src_path` and re-encode it as `to`. Caller owns the bytes.
fn transcode(allocator: std.mem.Allocator, src_path: []const u8, to: Format) ApplyError![]u8 {
    const src = try std.Io.Dir.cwd().readFileAlloc(config.globalIo(), src_path, allocator, .unlimited);
    defer allocator.free(src);

    var w: c_int = 0;
    var h: c_int = 0;
    var ch: c_int = 0;
    const raw = c.stbi_load_from_memory(@ptrCast(src.ptr), @intCast(src.len), &w, &h, &ch, 4);
    if (raw == null) return error.DecodeFailed;
    defer c.stbi_image_free(raw);
    if (w <= 0 or h <= 0) return error.DecodeFailed;

    return encode(allocator, @as([*]const u8, @ptrCast(raw)), w, h, to);
}

/// Encode tightly-packed RGBA8 pixels as `fmt`. Caller owns the bytes.
pub fn encode(allocator: std.mem.Allocator, px: [*]const u8, w: c_int, h: c_int, fmt: Format) error{ EncodeFailed, OutOfMemory }![]u8 {
    var sink: Sink = .{ .list = .empty, .allocator = allocator };
    errdefer sink.list.deinit(allocator);
    // The vendored implementation is built with `STBI_WRITE_NO_STDIO`, so
    // the `_to_func` entry points are the only ones available.
    const ok = switch (fmt) {
        .png => c.stbi_write_png_to_func(sinkWrite, &sink, w, h, 4, px, w * 4),
        .bmp => c.stbi_write_bmp_to_func(sinkWrite, &sink, w, h, 4, px),
        .tga => c.stbi_write_tga_to_func(sinkWrite, &sink, w, h, 4, px),
        // 90 is stb's own example quality: visually clean, and a
        // screenshot asked for as `.jpg` is wanted small, not archival.
        .jpg => c.stbi_write_jpg_to_func(sinkWrite, &sink, w, h, 4, px, 90),
    };
    if (ok == 0 or sink.failed) return error.EncodeFailed;
    return sink.list.toOwnedSlice(allocator);
}

/// Collects stb_image_write's output chunks (mirrors `texpack`'s PngSink).
const Sink = struct {
    list: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    failed: bool = false,
};

fn sinkWrite(ctx: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
    const sink: *Sink = @ptrCast(@alignCast(ctx.?));
    if (sink.failed or size <= 0) return;
    const bytes: [*]const u8 = @ptrCast(data.?);
    sink.list.appendSlice(sink.allocator, bytes[0..@intCast(size)]) catch {
        sink.failed = true;
    };
}

// ── Tests ──────────────────────────────────────────────────────────

/// Write a small solid-color image of `fmt` at `sub_path`. Encoded by stb,
/// so the fixture is a genuine file of that format rather than a
/// hand-rolled header. Shared with `pipeline.zig`'s ScreenshotProbe spec.
pub fn writeTestFixture(allocator: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8, fmt: Format) !void {
    const w = 4;
    const h = 3;
    var px: [w * h * 4]u8 = undefined;
    for (0..w * h) |i| {
        px[i * 4 + 0] = 200;
        px[i * 4 + 1] = 100;
        px[i * 4 + 2] = 50;
        px[i * 4 + 3] = 255;
    }
    const bytes = try encode(allocator, &px, w, h, fmt);
    defer allocator.free(bytes);
    try dir.writeFile(config.globalIo(), .{ .sub_path = sub_path, .data = bytes });
}

/// The extension→format mapping the whole reconciliation hangs off.
pub const FormatFromPathSpec = struct {
    test "recognizes the formats the CLI can read or write" {
        try std.testing.expectEqual(Format.png, formatFromPath("/tmp/shot.png").?);
        try std.testing.expectEqual(Format.bmp, formatFromPath("shot.bmp").?);
        try std.testing.expectEqual(Format.tga, formatFromPath("shot.tga").?);
        try std.testing.expectEqual(Format.jpg, formatFromPath("shot.jpg").?);
        try std.testing.expectEqual(Format.jpg, formatFromPath("shot.jpeg").?);
    }

    test "is case-insensitive" {
        try std.testing.expectEqual(Format.png, formatFromPath("/tmp/SHOT.PNG").?);
        try std.testing.expectEqual(Format.tga, formatFromPath("/tmp/shot.Tga").?);
    }

    test "reads only the LAST extension" {
        // The doubly-wrong name this issue is about: it is a TGA file.
        try std.testing.expectEqual(Format.tga, formatFromPath("/tmp/shot.png.tga").?);
    }

    test "an extension-less or unknown path has no format" {
        try std.testing.expectEqual(@as(?Format, null), formatFromPath("/tmp/shot"));
        try std.testing.expectEqual(@as(?Format, null), formatFromPath("/tmp/shot.webp"));
        try std.testing.expectEqual(@as(?Format, null), formatFromPath("/tmp/shot."));
        try std.testing.expectEqual(@as(?Format, null), formatFromPath(""));
    }

    test "a dot in a parent directory is not an extension" {
        try std.testing.expectEqual(@as(?Format, null), formatFromPath("/tmp/v1.2/shot"));
    }
};

/// The requested-vs-written decision itself.
pub const PlanSpec = struct {
    test "a backend that honored the path needs nothing" {
        try std.testing.expectEqual(Plan.honored, plan("/tmp/shot.png", "/tmp/shot.png"));
    }

    test "an appended .tga on a .png request is transcoded (issue #356)" {
        const p = plan("/tmp/shot.png", "/tmp/shot.png.tga");
        try std.testing.expectEqual(Format.tga, p.transcode.from);
        try std.testing.expectEqual(Format.png, p.transcode.to);
    }

    test "an appended .tga on a .tga request is only moved" {
        try std.testing.expectEqual(Plan.move, plan("/tmp/shot.tga", "/tmp/shot.tga.tga"));
    }

    test "a request with no extension is left where the backend put it" {
        // Nothing was asked for, so `shot.tga` is not a wrong name — and
        // rewriting it to the extension-less `shot` would be worse.
        try std.testing.expectEqual(Plan.keep, plan("/tmp/shot", "/tmp/shot.tga"));
    }

    test "a request the CLI cannot encode is left alone" {
        try std.testing.expectEqual(Plan.keep, plan("/tmp/shot.webp", "/tmp/shot.webp.tga"));
    }

    test "a written format the CLI cannot decode is left alone" {
        // stb is compiled without the JPEG decoder, so a hypothetical
        // `.jpg`-appending backend must not be promised a conversion.
        try std.testing.expectEqual(Plan.keep, plan("/tmp/shot.png", "/tmp/shot.png.jpg"));
    }
};

/// End-to-end: a real TGA on disk comes back as a real PNG at the
/// requested path, with the intermediate gone.
pub const ApplySpec = struct {
    /// `apply` resolves against the process cwd (the pipeline hands it
    /// already-resolved paths), and `std.testing.tmpDir` creates its
    /// directory under a cwd-relative `.zig-cache/tmp/`, so cwd-relative
    /// paths built from `sub_path` address exactly the same files.
    fn tmpPath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
    }

    const writeFixture = writeTestFixture;

    test "a .png request served a .png.tga capture ends up a real PNG" {
        const a = std.testing.allocator;
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try writeFixture(a, tmp.dir, "shot.png.tga", .tga);

        const written = try tmpPath(a, tmp, "shot.png.tga");
        defer a.free(written);
        const requested = written[0 .. written.len - ".tga".len];

        const p = plan(requested, written);
        try apply(a, p, requested, written);

        // The requested path now exists and really is a PNG.
        const out = try tmp.dir.readFileAlloc(io, "shot.png", a, .unlimited);
        defer a.free(out);
        try std.testing.expect(std.mem.startsWith(u8, out, "\x89PNG\r\n\x1a\n"));

        // ...and the doubly-named intermediate is gone.
        try std.testing.expectError(
            error.FileNotFound,
            tmp.dir.statFile(io, "shot.png.tga", .{}),
        );
    }

    test "a .tga request served a .tga.tga capture is moved, not re-encoded" {
        const a = std.testing.allocator;
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try writeFixture(a, tmp.dir, "shot.tga.tga", .tga);
        const before = try tmp.dir.readFileAlloc(io, "shot.tga.tga", a, .unlimited);
        defer a.free(before);

        const written = try tmpPath(a, tmp, "shot.tga.tga");
        defer a.free(written);
        const requested = written[0 .. written.len - ".tga".len];

        try apply(a, plan(requested, written), requested, written);

        const after = try tmp.dir.readFileAlloc(io, "shot.tga", a, .unlimited);
        defer a.free(after);
        // Byte-identical: a move must not round-trip the pixels.
        try std.testing.expectEqualSlices(u8, before, after);
        try std.testing.expectError(
            error.FileNotFound,
            tmp.dir.statFile(io, "shot.tga.tga", .{}),
        );
    }

    test "a keep plan touches nothing" {
        const a = std.testing.allocator;
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try writeFixture(a, tmp.dir, "shot.tga", .tga);
        const written = try tmpPath(a, tmp, "shot.tga");
        defer a.free(written);
        const requested = written[0 .. written.len - ".tga".len];

        try std.testing.expectEqual(Plan.keep, plan(requested, written));
        try apply(a, .keep, requested, written);
        _ = try tmp.dir.statFile(io, "shot.tga", .{});
    }
};
