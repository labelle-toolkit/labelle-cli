//! Resolve the prebuilt `astcenc` binary for build-time ASTC conversion
//! (assembler#340), mirroring how the CLI resolves the assembler binary:
//! cache under `<labelle-home>/astcenc/<version>/`, downloading the ARM-software
//! release archive on first use. Shelling out to a prebuilt binary (vs.
//! vendoring astcenc's multi-file C++/per-ISA build) matches the existing
//! external-asset-tool pattern and keeps the toolchain light.
//!
//! Pure parts (asset-suffix / URL / candidate-names / version-dir) take their
//! inputs explicitly so they're host-testable; `ensure` does download + extract.

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

/// The `bin/`-relative binary names to look for, in preference order. CRITICAL:
/// the macOS universal archive ships a single `astcenc`, but the Linux/Windows
/// archives ship ISA-specific builds (`astcenc-sse2`/`-sse4.1`/`-avx2`, or
/// `-neon` on arm64) with NO plain `astcenc`. We prefer the SAFEST build that
/// always runs (sse2 on any x86-64) so the tool never SIGILLs on an older CPU —
/// astcenc is fast enough that the ISA tier barely matters for a build step.
pub fn candidateNames(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) []const []const u8 {
    return switch (os) {
        .macos => &.{"astcenc"},
        .windows => switch (arch) {
            .aarch64 => &.{"astcenc-neon.exe"},
            else => &.{ "astcenc-sse2.exe", "astcenc-sse4.1.exe", "astcenc-avx2.exe" },
        },
        else => switch (arch) { // linux + any other unix
            .aarch64 => &.{"astcenc-neon"},
            else => &.{ "astcenc-sse2", "astcenc-sse4.1", "astcenc-avx2" },
        },
    };
}

/// `https://.../<version>/astcenc-<version>-<suffix>.zip`. Caller owns the slice.
pub fn releaseUrl(allocator: std.mem.Allocator, version: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/astcenc-{s}-{s}.zip", .{ RELEASE_BASE, version, version, suffix });
}

/// `<cache_root>/astcenc/<version>` — the archive extracts its own `bin/...`
/// under here. Caller owns the slice.
pub fn versionDir(allocator: std.mem.Allocator, cache_root: []const u8, version: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ cache_root, "astcenc", version });
}

/// First candidate binary that exists under `<ver_dir>/bin/`, or null. Caller
/// owns the returned slice.
fn resolveExisting(allocator: std.mem.Allocator, ver_dir: []const u8) !?[]u8 {
    for (candidateNames(builtin.os.tag, builtin.cpu.arch)) |name| {
        const p = try std.fs.path.join(allocator, &.{ ver_dir, "bin", name });
        if (util.fileExists(p)) return p;
        allocator.free(p);
    }
    return null;
}

/// Resolve a usable astcenc path: the cached binary if present, else download +
/// extract the release archive into the cache and return that. `cache_root` is
/// the labelle home (e.g. from `asm_cache.getCacheRoot`). Caller owns the slice.
pub fn ensure(allocator: std.mem.Allocator, cache_root: []const u8, version: []const u8) ![]u8 {
    const ver_dir = try versionDir(allocator, cache_root, version);
    defer allocator.free(ver_dir);

    if (try resolveExisting(allocator, ver_dir)) |p| return p;

    const suffix = assetSuffix(builtin.os.tag, builtin.cpu.arch) catch {
        std.debug.print("labelle: no prebuilt astcenc for this platform; install astcenc {s} under {s}/bin/\n", .{ version, ver_dir });
        return error.AstcencUnavailable;
    };
    const url = try releaseUrl(allocator, version, suffix);
    defer allocator.free(url);

    const zip_path = try std.fmt.allocPrint(allocator, "{s}/astcenc.zip", .{ver_dir});
    defer allocator.free(zip_path);

    std.debug.print("labelle: downloading astcenc {s}...\n  url: {s}\n", .{ version, url });
    std.Io.Dir.cwd().createDirPath(util_io(), ver_dir) catch {};

    if (!runOk(allocator, &.{ "curl", "-fSL", "-o", zip_path, url })) {
        std.debug.print("labelle: astcenc download failed (curl). Install astcenc under {s}/bin/\n", .{ver_dir});
        return error.AstcencDownloadFailed;
    }
    // Extract: `unzip` on unix (GNU tar can't read zips), bsdtar on Windows
    // (where `unzip` isn't shipped but `tar` reads zips since Win10).
    const extracted = if (builtin.os.tag == .windows)
        runOk(allocator, &.{ "tar", "-xf", zip_path, "-C", ver_dir })
    else
        runOk(allocator, &.{ "unzip", "-o", "-q", zip_path, "-d", ver_dir });
    if (!extracted) {
        std.debug.print("labelle: astcenc extract failed. Install astcenc under {s}/bin/\n", .{ver_dir});
        return error.AstcencExtractFailed;
    }

    const bin = (try resolveExisting(allocator, ver_dir)) orelse {
        std.debug.print("labelle: astcenc binary not found after extracting {s}\n", .{zip_path});
        return error.AstcencExtractFailed;
    };
    if (builtin.os.tag != .windows) {
        if (std.Io.Dir.cwd().openFile(util_io(), bin, .{})) |f| {
            defer f.close(util_io());
            f.setPermissions(util_io(), .fromMode(0o755)) catch {};
        } else |_| {}
    }
    std.debug.print("  cached at {s}\n", .{bin});
    return bin;
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

// ── Tests (pure suffix/url/candidate/path logic) ─────────────────────────────

test "assetSuffix maps platforms" {
    try std.testing.expectEqualStrings("macos-universal", try assetSuffix(.macos, .aarch64));
    try std.testing.expectEqualStrings("linux-x64", try assetSuffix(.linux, .x86_64));
    try std.testing.expectEqualStrings("linux-arm64", try assetSuffix(.linux, .aarch64));
    try std.testing.expectEqualStrings("windows-x64", try assetSuffix(.windows, .x86_64));
    try std.testing.expectError(error.UnsupportedPlatform, assetSuffix(.freestanding, .x86_64));
    try std.testing.expectError(error.UnsupportedPlatform, assetSuffix(.linux, .arm));
}

test "candidateNames: macOS single, x64 ISA tiers (sse2 first), arm64 neon, .exe on Windows" {
    try std.testing.expectEqualStrings("astcenc", candidateNames(.macos, .aarch64)[0]);
    const lx = candidateNames(.linux, .x86_64);
    try std.testing.expectEqualStrings("astcenc-sse2", lx[0]); // safest first
    try std.testing.expectEqual(@as(usize, 3), lx.len);
    try std.testing.expectEqualStrings("astcenc-neon", candidateNames(.linux, .aarch64)[0]);
    try std.testing.expectEqualStrings("astcenc-sse2.exe", candidateNames(.windows, .x86_64)[0]);
}

test "releaseUrl + versionDir shapes" {
    const a = std.testing.allocator;
    const url = try releaseUrl(a, "5.5.0", "linux-x64");
    defer a.free(url);
    try std.testing.expectEqualStrings(
        "https://github.com/ARM-software/astc-encoder/releases/download/5.5.0/astcenc-5.5.0-linux-x64.zip",
        url,
    );
    const vd = try versionDir(a, "/home/u/.labelle", "5.5.0");
    defer a.free(vd);
    try std.testing.expect(std.mem.endsWith(u8, vd, "5.5.0"));
    try std.testing.expect(std.mem.indexOf(u8, vd, "astcenc") != null);
}
