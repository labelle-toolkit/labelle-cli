//! Zig-toolchain cache-path resolution — the sibling of `asm_cache.zig`.
//!
//! Part of labelle-studio#25 (SUB1, labelle-cli#279): the CLI owns the Zig
//! toolchain the same way it owns `labelle-assembler`. This module owns the
//! *paths* under the shared `~/.labelle/` tree; the download/verify/extract
//! flow lives in `zig_toolchain.zig` (mirroring the assembler split, where
//! `asm_cache.zig` owns paths and `assembler.zig` owns the flow).
//!
//! Cache layout (the SUB2 / #280 seed contract):
//!
//!   <cache-root>/<ZIG_SUBDIR>/<version>/zig[.exe]   ← the managed binary
//!   <cache-root>/<ZIG_SUBDIR>/<version>/lib/...      ← Zig's std/ tree
//!   <cache-root>/<ZIG_SUBDIR>/<version>/doc/, ...    ← the rest of the release
//!
//! The version directory holds the *flattened* release: `zig`, `lib/`, `doc/`
//! sit directly under `<version>/`, NOT under a nested `zig-<arch>-<os>-<ver>/`
//! dir. `zig_toolchain.extractArchive` strips the leading component to produce
//! this; a #280 seed archive MUST extract to the identical flat layout so a
//! seeded and a downloaded toolchain are byte-for-byte indistinguishable.
//!
//! Windows MAX_PATH: Zig's `lib/std/...` tree plus the compiler's own nested
//! build cache can blow past 260 chars. We keep the subdir SHORT on Windows
//! (`tc` instead of `zig`) so the version root is as shallow as possible. For
//! very deep user profiles, `LABELLE_HOME=C:\labelle` (honored by
//! `asm_cache.getCacheRoot`) moves the whole tree to a short root.

const std = @import("std");
const builtin = @import("builtin");
const asm_cache = @import("asm_cache.zig");

const is_windows = builtin.os.tag == .windows;

/// Subdirectory of the cache root that holds managed Zig toolchains.
///
/// SHORT on Windows (`tc`) to dodge MAX_PATH — a deeply-nested `lib/std/...`
/// path under `zig\<full-version>\` can exceed 260 chars once the compiler
/// adds its own `.zig-cache/` nesting on top. Unix has no such limit, so it
/// keeps the readable `zig` name.
pub const ZIG_SUBDIR = if (is_windows) "tc" else "zig";

/// Global-compiler-cache subdir under the cache root. Passed to child `zig`
/// processes as `ZIG_GLOBAL_CACHE_DIR` so the compiler cache lands in
/// user-writable space, never next to a read-only install (epic gotcha).
pub const GLOBAL_CACHE_SUBDIR = "zig-global-cache";

/// Local-compiler-cache subdir under the cache root. Passed as
/// `ZIG_LOCAL_CACHE_DIR`. Kept under the labelle tree (rather than the
/// project's `.zig-cache/`) so studio-launched builds against a read-only
/// bundle still have somewhere writable.
pub const LOCAL_CACHE_SUBDIR = "zig-local-cache";

const exe_suffix = if (is_windows) ".exe" else "";

/// The managed `zig` binary name for the host (`zig` / `zig.exe`).
pub const zig_exe_name = "zig" ++ exe_suffix;

/// Re-export the shared cache root so callers and tests resolve Zig paths
/// against the SAME `~/.labelle/` tree the assembler and package cache use.
/// Tests pin it with `asm_cache.setCacheRootOverride`. Caller owns the slice.
pub fn getCacheRoot(allocator: std.mem.Allocator) ![]const u8 {
    return asm_cache.getCacheRoot(allocator);
}

/// `<cache-root>/<ZIG_SUBDIR>` — the directory that holds one subdir per
/// installed Zig version. Caller owns the returned slice.
pub fn zigRoot(allocator: std.mem.Allocator) ![]u8 {
    const root = try getCacheRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, ZIG_SUBDIR });
}

/// `<cache-root>/<ZIG_SUBDIR>/<version>` — the flat install dir for `version`.
/// Caller owns the returned slice.
pub fn versionDir(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const root = try getCacheRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, ZIG_SUBDIR, version });
}

/// `<version-dir>/zig[.exe]` — the managed binary a spawn points at.
/// Caller owns the returned slice.
pub fn binaryPath(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const root = try getCacheRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, ZIG_SUBDIR, version, zig_exe_name });
}

/// `<cache-root>/zig-global-cache`. Caller owns the returned slice.
pub fn globalCacheDir(allocator: std.mem.Allocator) ![]u8 {
    const root = try getCacheRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, GLOBAL_CACHE_SUBDIR });
}

/// `<cache-root>/zig-local-cache`. Caller owns the returned slice.
pub fn localCacheDir(allocator: std.mem.Allocator) ![]u8 {
    const root = try getCacheRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, LOCAL_CACHE_SUBDIR });
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "binaryPath places zig under <root>/<subdir>/<version>/" {
    const alloc = testing.allocator;
    asm_cache.setCacheRootOverride("/tmp/labelle-test-home");
    defer asm_cache.clearCacheRootOverride();

    const path = try binaryPath(alloc, "0.16.0");
    defer alloc.free(path);

    const expected = try std.fs.path.join(alloc, &.{
        "/tmp/labelle-test-home", ZIG_SUBDIR, "0.16.0", zig_exe_name,
    });
    defer alloc.free(expected);
    try testing.expectEqualStrings(expected, path);
}

test "Windows uses the short 'tc' subdir; Unix uses 'zig'" {
    if (is_windows) {
        try testing.expectEqualStrings("tc", ZIG_SUBDIR);
    } else {
        try testing.expectEqualStrings("zig", ZIG_SUBDIR);
    }
}

test "versionDir is the flat install root (no nested release dir)" {
    const alloc = testing.allocator;
    asm_cache.setCacheRootOverride("/x");
    defer asm_cache.clearCacheRootOverride();

    const dir = try versionDir(alloc, "0.16.0");
    defer alloc.free(dir);
    const bin = try binaryPath(alloc, "0.16.0");
    defer alloc.free(bin);

    // binaryPath must be exactly `<versionDir>/zig[.exe]` — the contract the
    // #280 seed relies on (binary sits directly in the version dir).
    const expected_bin = try std.fs.path.join(alloc, &.{ dir, zig_exe_name });
    defer alloc.free(expected_bin);
    try testing.expectEqualStrings(expected_bin, bin);
}

test "compiler cache dirs live under the cache root, not the project" {
    const alloc = testing.allocator;
    asm_cache.setCacheRootOverride("/home/u/.labelle");
    defer asm_cache.clearCacheRootOverride();

    const g = try globalCacheDir(alloc);
    defer alloc.free(g);
    const l = try localCacheDir(alloc);
    defer alloc.free(l);

    try testing.expect(std.mem.startsWith(u8, g, "/home/u/.labelle"));
    try testing.expect(std.mem.endsWith(u8, g, GLOBAL_CACHE_SUBDIR));
    try testing.expect(std.mem.endsWith(u8, l, LOCAL_CACHE_SUBDIR));
}
