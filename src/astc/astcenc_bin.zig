//! Resolve the prebuilt `astcenc` binary for build-time ASTC conversion
//! (assembler#340), mirroring how the CLI resolves the assembler binary:
//! cache under `<labelle-home>/astcenc/<version>/`, downloading the ARM-software
//! release archive on first use. Shelling out to a prebuilt binary (vs.
//! vendoring astcenc's multi-file C++/per-ISA build) matches the existing
//! external-asset-tool pattern and keeps the toolchain light.
//!
//! Pure parts (asset-suffix / URL / cache-path) take their inputs explicitly so
//! they're host-testable; `ensure` does the download + extract.

const std = @import("std");
const builtin = @import("builtin");
const util = @import("../cli/util.zig");

/// Pinned astcenc release. ARM-software tags releases WITHOUT a `v` prefix
/// (e.g. `5.5.0`), and the archive embeds the same version in its name.
pub const DEFAULT_VERSION = "5.5.0";

const RELEASE_BASE = "https://github.com/ARM-software/astc-encoder/releases/download";

/// The platform fragment in an astcenc release asset name. macOS ships a single
/// universal binary; Linux/Windows split by arch. Pure — caller passes the
/// target so tests don't depend on the host.
pub fn assetSuffix(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) error{UnsupportedPlatform}![]const u8 {
    return switch (os) {
        .macos => "macos-universal",
        .linux => switch (arch) {
            .x86_64 => "linux-x64",
            .aarch64 => "linux-arm64",
            else => error.UnsupportedPlatform,
        },
        .windows => switch (arch) {
            .x86_64 => "windows-x64",
            .aarch64 => "windows-arm64",
            else => error.UnsupportedPlatform,
        },
        else => error.UnsupportedPlatform,
    };
}

/// `https://.../<version>/astcenc-<version>-<suffix>.zip`. Caller owns the slice.
pub fn releaseUrl(allocator: std.mem.Allocator, version: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/astcenc-{s}-{s}.zip", .{ RELEASE_BASE, version, version, suffix });
}

/// Cached binary path: `<cache_root>/astcenc/<version>/bin/astcenc[.exe]` — the
/// `bin/` matches the layout inside the release archive, so extraction lands
/// the binary exactly here with no move. Caller owns the slice.
pub fn binPath(allocator: std.mem.Allocator, cache_root: []const u8, version: []const u8) ![]u8 {
    const exe = if (builtin.os.tag == .windows) "astcenc.exe" else "astcenc";
    return std.fs.path.join(allocator, &.{ cache_root, "astcenc", version, "bin", exe });
}

/// Resolve a usable astcenc path: the cached binary if present, else download +
/// extract the release archive into the cache and return that. `cache_root` is
/// the labelle home (e.g. from `asm_cache.getCacheRoot`). Caller owns the slice.
pub fn ensure(allocator: std.mem.Allocator, cache_root: []const u8, version: []const u8) ![]u8 {
    const dest = try binPath(allocator, cache_root, version);
    errdefer allocator.free(dest);

    if (util.fileExists(dest)) return dest;

    const suffix = assetSuffix(builtin.os.tag, builtin.cpu.arch) catch {
        std.debug.print("labelle: no prebuilt astcenc for this platform; install it and place it at {s}\n", .{dest});
        return error.AstcencUnavailable;
    };
    const url = try releaseUrl(allocator, version, suffix);
    defer allocator.free(url);

    // dest = <cache>/astcenc/<version>/bin/astcenc; extract into the version dir
    // (parent of bin/) so the archive's own `bin/astcenc` lands exactly at dest.
    const ver_dir = std.fs.path.dirname(std.fs.path.dirname(dest).?).?;
    const zip_path = try std.fmt.allocPrint(allocator, "{s}/astcenc.zip", .{ver_dir});
    defer allocator.free(zip_path);

    std.debug.print("labelle: downloading astcenc {s}...\n  url: {s}\n", .{ version, url });
    std.Io.Dir.cwd().createDirPath(util_io(), ver_dir) catch {};

    // curl the archive, then extract. `tar -xf` reads zips on macOS, Linux
    // (bsdtar), and Windows 10+ — one extractor for every CI platform, no
    // dependency on `unzip` being installed.
    if (!runOk(allocator, &.{ "curl", "-fSL", "-o", zip_path, url })) {
        std.debug.print("labelle: astcenc download failed (curl). Place the binary at {s}\n", .{dest});
        return error.AstcencDownloadFailed;
    }
    if (!runOk(allocator, &.{ "tar", "-xf", zip_path, "-C", ver_dir })) {
        std.debug.print("labelle: astcenc extract failed (tar). Place the binary at {s}\n", .{dest});
        return error.AstcencExtractFailed;
    }
    if (!util.fileExists(dest)) {
        std.debug.print("labelle: astcenc not at expected archive path {s}\n", .{dest});
        return error.AstcencExtractFailed;
    }
    if (builtin.os.tag != .windows) {
        if (std.Io.Dir.cwd().openFile(util_io(), dest, .{})) |f| {
            defer f.close(util_io());
            f.setPermissions(util_io(), .fromMode(0o755)) catch {};
        } else |_| {}
    }
    std.debug.print("  cached at {s}\n", .{dest});
    return dest;
}

fn util_io() std.Io {
    return @import("../cli/config.zig").globalIo();
}

fn runOk(allocator: std.mem.Allocator, argv: []const []const u8) bool {
    const r = util.runCmd(allocator, argv) catch return false;
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    return switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

// ── Tests (pure path/url/suffix logic) ───────────────────────────────────────

test "assetSuffix maps platforms" {
    try std.testing.expectEqualStrings("macos-universal", try assetSuffix(.macos, .aarch64));
    try std.testing.expectEqualStrings("macos-universal", try assetSuffix(.macos, .x86_64));
    try std.testing.expectEqualStrings("linux-x64", try assetSuffix(.linux, .x86_64));
    try std.testing.expectEqualStrings("linux-arm64", try assetSuffix(.linux, .aarch64));
    try std.testing.expectEqualStrings("windows-x64", try assetSuffix(.windows, .x86_64));
    try std.testing.expectError(error.UnsupportedPlatform, assetSuffix(.freestanding, .x86_64));
    try std.testing.expectError(error.UnsupportedPlatform, assetSuffix(.linux, .arm));
}

test "releaseUrl + binPath shapes" {
    const a = std.testing.allocator;
    const url = try releaseUrl(a, "5.5.0", "macos-universal");
    defer a.free(url);
    try std.testing.expectEqualStrings(
        "https://github.com/ARM-software/astc-encoder/releases/download/5.5.0/astcenc-5.5.0-macos-universal.zip",
        url,
    );
    const p = try binPath(a, "/home/u/.labelle", "5.5.0");
    defer a.free(p);
    const expected_tail = if (builtin.os.tag == .windows) "astcenc.exe" else "astcenc";
    try std.testing.expect(std.mem.indexOf(u8, p, "/.labelle") != null or std.mem.indexOf(u8, p, "\\.labelle") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "5.5.0") != null);
    try std.testing.expect(std.mem.endsWith(u8, p, expected_tail));
}
