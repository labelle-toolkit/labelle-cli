//! Android launcher-icon staging (labelle-cli#340).
//!
//! `project.labelle` has carried an `app_icon` field for a while, but
//! nothing consumed it — every packaged APK shipped with the stock
//! Android robot. This module closes that gap: it resolves which PNG is
//! the app icon, downscales it to the five launcher densities, and
//! writes them into the APK staging tree as
//! `res/mipmap-<density>/ic_launcher.png` for aapt to compile.
//!
//! The icon-source precedence, the failure policy and the PNG
//! decode / box-resample / encode helpers live in the platform-neutral
//! `cli/app_icon.zig` (shared with the macOS `.app` bundle, cli#359) —
//! see that module's doc comment for the rules. This file owns only the
//! Android-specific half: WHICH sizes and WHERE they go.
//!
//! ## Failure policy (summary; `app_icon.load` is authoritative)
//!
//! A *custom* icon that is missing or undecodable is a hard error naming
//! the path — never a silent fall back to the default. An *absent*
//! `default_icon.png` (older assembler) degrades to "no launcher icon
//! staged" and the manifest omits `android:icon` (see `package.zig`).

const std = @import("std");
const config = @import("../config.zig");
const app_icon = @import("../app_icon.zig");

/// Re-exported so existing call sites and the assembler contract note
/// keep one name for the default-icon file.
pub const default_icon_name = app_icon.default_icon_name;
pub const Source = app_icon.Source;
pub const Resolved = app_icon.Resolved;
pub const resolve = app_icon.resolve;

/// Resource subdirectory inside the APK staging tree. Handed to aapt as
/// `-S <staging>/res`.
pub const res_subdir = "res";

/// The manifest reference the staged mipmaps satisfy.
pub const icon_resource_ref = "@mipmap/ic_launcher";

/// One Android launcher density bucket. `dir` is the resource
/// directory name, `size` the square edge length in pixels.
pub const Density = struct {
    dir: []const u8,
    size: u32,
};

/// The launcher densities we emit. These are the standard Android
/// buckets; a device picks the closest one at install time, so shipping
/// all five means no scaling artefacts on any screen.
pub const densities = [_]Density{
    .{ .dir = "mipmap-mdpi", .size = 48 },
    .{ .dir = "mipmap-hdpi", .size = 72 },
    .{ .dir = "mipmap-xhdpi", .size = 96 },
    .{ .dir = "mipmap-xxhdpi", .size = 144 },
    .{ .dir = "mipmap-xxxhdpi", .size = 192 },
};

/// Generate `res/mipmap-*/ic_launcher.png` under `staging_dir`.
///
/// Returns `true` when the mipmaps were written (so the caller passes
/// `-S` to aapt and puts `android:icon` in the manifest), `false` when
/// there was no icon to stage at all — which happens only for a
/// `default_icon.png` that the generating assembler never wrote.
///
/// Errors (all loud, all naming the offending path):
///   * `error.LauncherIconNotFound`     — `app_icon` points at nothing
///   * `error.LauncherIconDecodeFailed` — the file is not a decodable PNG
pub fn stage(
    allocator: std.mem.Allocator,
    staging_dir: []const u8,
    project_dir: []const u8,
    target_dir: []const u8,
    icon_field: ?[]const u8,
) !bool {
    // The shared loader speaks in platform-neutral error names; keep the
    // Android-specific ones this module has always surfaced so callers
    // (and their tests) don't churn.
    const maybe_img = app_icon.load(allocator, project_dir, target_dir, icon_field, .{
        .label = "launcher icon",
        .recommended_px = densities[densities.len - 1].size,
    }) catch |err| switch (err) {
        error.AppIconNotFound => return error.LauncherIconNotFound,
        error.AppIconDecodeFailed => return error.LauncherIconDecodeFailed,
        else => return err,
    };
    const img = maybe_img orelse return false;
    defer img.free();

    const io = config.globalIo();
    const res_dir = try std.fs.path.join(allocator, &.{ staging_dir, res_subdir });
    defer allocator.free(res_dir);

    for (densities) |d| {
        const dir = try std.fs.path.join(allocator, &.{ res_dir, d.dir });
        defer allocator.free(dir);
        try std.Io.Dir.cwd().createDirPath(io, dir);

        const scaled = try app_icon.resampleBox(allocator, img.pixels, img.width, img.height, d.size, d.size);
        defer allocator.free(scaled);

        const png = try app_icon.encodePng(allocator, scaled, d.size, d.size);
        defer allocator.free(png);

        const out = try std.fs.path.join(allocator, &.{ dir, "ic_launcher.png" });
        defer allocator.free(out);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = png });
    }

    return true;
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const gradientRgba = app_icon.gradientRgba;
const encodePng = app_icon.encodePng;
const decodePng = app_icon.decodePng;

test "every launcher density survives a 512px box resample + PNG round-trip" {
    const a = testing.allocator;
    const src = try gradientRgba(a, 512, 512);
    defer a.free(src);

    for (densities) |d| {
        const scaled = try app_icon.resampleBox(a, src, 512, 512, d.size, d.size);
        defer a.free(scaled);
        try testing.expectEqual(@as(usize, d.size) * d.size * 4, scaled.len);

        const png = try encodePng(a, scaled, d.size, d.size);
        defer a.free(png);
        const img = try decodePng(png);
        defer img.free();
        try testing.expectEqual(@as(usize, d.size), img.width);
        try testing.expectEqual(@as(usize, d.size), img.height);
        try testing.expectEqualSlices(u8, scaled, img.pixels);
    }
}

test "stage writes one ic_launcher.png per density and reports success" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const work = ".zig-cache/launcher-icon-stage";
    cwd.deleteTree(io, work) catch {};
    defer cwd.deleteTree(io, work) catch {};
    const project = try std.fs.path.join(a, &.{ work, "proj" });
    defer a.free(project);
    const staging = try std.fs.path.join(a, &.{ work, "staging" });
    defer a.free(staging);
    try cwd.createDirPath(io, project);
    try cwd.createDirPath(io, staging);

    // A 256x256 custom icon at <project>/art/icon.png.
    const art = try std.fs.path.join(a, &.{ project, "art" });
    defer a.free(art);
    try cwd.createDirPath(io, art);
    const src = try gradientRgba(a, 256, 256);
    defer a.free(src);
    const png = try encodePng(a, src, 256, 256);
    defer a.free(png);
    const icon_path = try std.fs.path.join(a, &.{ art, "icon.png" });
    defer a.free(icon_path);
    try cwd.writeFile(io, .{ .sub_path = icon_path, .data = png });

    try testing.expect(try stage(a, staging, project, work, "art/icon.png"));

    for (densities) |d| {
        const out = try std.fs.path.join(a, &.{ staging, res_subdir, d.dir, "ic_launcher.png" });
        defer a.free(out);
        const bytes = try cwd.readFileAlloc(io, out, a, .unlimited);
        defer a.free(bytes);
        const img = try decodePng(bytes);
        defer img.free();
        try testing.expectEqual(@as(usize, d.size), img.width);
        try testing.expectEqual(@as(usize, d.size), img.height);
    }
}

test "stage picks up the assembler default when the project sets no app_icon" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const work = ".zig-cache/launcher-icon-default";
    cwd.deleteTree(io, work) catch {};
    defer cwd.deleteTree(io, work) catch {};
    const target = try std.fs.path.join(a, &.{ work, "target" });
    defer a.free(target);
    const staging = try std.fs.path.join(a, &.{ work, "staging" });
    defer a.free(staging);
    try cwd.createDirPath(io, target);
    try cwd.createDirPath(io, staging);

    const src = try gradientRgba(a, 64, 64);
    defer a.free(src);
    const png = try encodePng(a, src, 64, 64);
    defer a.free(png);
    const default_path = try std.fs.path.join(a, &.{ target, default_icon_name });
    defer a.free(default_path);
    try cwd.writeFile(io, .{ .sub_path = default_path, .data = png });

    try testing.expect(try stage(a, staging, work, target, null));

    const out = try std.fs.path.join(a, &.{ staging, res_subdir, "mipmap-mdpi", "ic_launcher.png" });
    defer a.free(out);
    try cwd.access(io, out, .{});
}

test "stage fails loudly when app_icon names a file that does not exist" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const work = ".zig-cache/launcher-icon-missing";
    cwd.deleteTree(io, work) catch {};
    defer cwd.deleteTree(io, work) catch {};
    try cwd.createDirPath(io, work);

    // Never silently falls back — even when a usable default sits right
    // there in the target dir.
    const src = try gradientRgba(a, 32, 32);
    defer a.free(src);
    const png = try encodePng(a, src, 32, 32);
    defer a.free(png);
    const default_path = try std.fs.path.join(a, &.{ work, default_icon_name });
    defer a.free(default_path);
    try cwd.writeFile(io, .{ .sub_path = default_path, .data = png });

    try testing.expectError(
        error.LauncherIconNotFound,
        stage(a, work, work, work, "art/nope.png"),
    );
}

test "stage fails loudly when app_icon is not a decodable PNG" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const work = ".zig-cache/launcher-icon-garbage";
    cwd.deleteTree(io, work) catch {};
    defer cwd.deleteTree(io, work) catch {};
    try cwd.createDirPath(io, work);
    const bogus = try std.fs.path.join(a, &.{ work, "icon.png" });
    defer a.free(bogus);
    try cwd.writeFile(io, .{ .sub_path = bogus, .data = "definitely not a png" });

    try testing.expectError(
        error.LauncherIconDecodeFailed,
        stage(a, work, work, work, "icon.png"),
    );
}

test "stage degrades to no icon when the assembler wrote no default" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const work = ".zig-cache/launcher-icon-none";
    cwd.deleteTree(io, work) catch {};
    defer cwd.deleteTree(io, work) catch {};
    try cwd.createDirPath(io, work);

    try testing.expect(!try stage(a, work, work, work, null));
    // Nothing staged means aapt must not be handed a `res/` tree.
    const res = try std.fs.path.join(a, &.{ work, res_subdir });
    defer a.free(res);
    try testing.expectError(error.FileNotFound, cwd.access(io, res, .{}));
}
