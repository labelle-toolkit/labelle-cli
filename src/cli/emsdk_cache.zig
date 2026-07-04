//! emsdk-toolchain cache-path resolution — the sibling of `zig_cache.zig`.
//!
//! Part of labelle-studio#25 (labelle-cli#283): the CLI owns the emsdk/emcc
//! toolchain the same way it owns Zig (#279) and `labelle-assembler`. This
//! module owns the *paths* under the shared `~/.labelle/` tree; the
//! resolve/download/verify/**activate** flow lives in `emsdk_toolchain.zig`
//! (mirroring the Zig split, where `zig_cache.zig` owns paths and
//! `zig_toolchain.zig` owns the flow).
//!
//! Cache layout:
//!
//!   <cache-root>/emsdk/<version>/emsdk[.bat]                 ← the emsdk launcher
//!   <cache-root>/emsdk/<version>/.emscripten                 ← EM_CONFIG (activation writes this)
//!   <cache-root>/emsdk/<version>/upstream/emscripten/emcc    ← the managed emcc
//!   <cache-root>/emsdk/<version>/upstream/…, node/…          ← the activated SDK
//!
//! Unlike Zig (whose release archive is *flattened* into the version dir), the
//! emsdk version dir is a full emsdk checkout: the launcher at the root plus
//! the `upstream/` and `node/` trees its own `emsdk install`/`emsdk activate`
//! populate. `emcc` only EXISTS after activation — its presence is therefore
//! the "installed" marker `emsdk_toolchain.ensureInstalled` checks (the direct
//! analog of #279's `zig` binary check, and the exact gap behind
//! labelle-assembler#492's fetched-but-not-activated failure).
//!
//! The whole tree lives under the same shared `~/.labelle/` root the assembler
//! (`asm_cache`), the package cache, and the Zig manager (`zig_cache`) use, so
//! `LABELLE_HOME` relocates everything at once.

const std = @import("std");
const builtin = @import("builtin");
const asm_cache = @import("asm_cache.zig");

const is_windows = builtin.os.tag == .windows;

/// Subdirectory of the cache root that holds managed emsdk toolchains.
pub const EMSDK_SUBDIR = "emsdk";

/// The emsdk launcher script name for the host (`emsdk` / `emsdk.bat`).
pub const emsdk_launcher_name = if (is_windows) "emsdk.bat" else "emsdk";

/// The activated `emcc` compiler-driver name for the host. Emscripten ships a
/// shebang `emcc` script on Unix and `emcc.bat` on Windows.
pub const emcc_name = if (is_windows) "emcc.bat" else "emcc";

/// `emcc`'s path RELATIVE to an activated emsdk root.
pub const emcc_relpath = "upstream" ++ std.fs.path.sep_str ++ "emscripten" ++ std.fs.path.sep_str ++ emcc_name;

/// The emscripten bin dir RELATIVE to an activated emsdk root — the dir that
/// must be on PATH for a bare `emcc` invocation to resolve.
pub const emscripten_bin_relpath = "upstream" ++ std.fs.path.sep_str ++ "emscripten";

/// `.emscripten` config file (EM_CONFIG) name, written by `emsdk activate`.
pub const em_config_name = ".emscripten";

/// Re-export the shared cache root so callers and tests resolve emsdk paths
/// against the SAME `~/.labelle/` tree the assembler, package cache and Zig
/// manager use. Tests pin it with `asm_cache.setCacheRootOverride`. Caller
/// owns the returned slice.
pub fn getCacheRoot(allocator: std.mem.Allocator) ![]const u8 {
    return asm_cache.getCacheRoot(allocator);
}

/// `<cache-root>/emsdk` — the directory that holds one subdir per installed
/// emsdk version. Caller owns the returned slice.
pub fn emsdkRoot(allocator: std.mem.Allocator) ![]u8 {
    const root = try getCacheRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, EMSDK_SUBDIR });
}

/// `<cache-root>/emsdk/<version>` — the install dir for `version`.
/// Caller owns the returned slice.
pub fn versionDir(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const root = try getCacheRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, EMSDK_SUBDIR, version });
}

/// `<version-dir>/emsdk[.bat]` — the emsdk launcher used to install/activate.
/// Caller owns the returned slice.
pub fn launcherPath(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const root = try getCacheRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, EMSDK_SUBDIR, version, emsdk_launcher_name });
}

/// `<version-dir>/upstream/emscripten/emcc[.bat]` — the managed emcc a wasm
/// build spawn points at. Present ONLY after activation. Caller owns the slice.
pub fn emccPath(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const root = try getCacheRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, EMSDK_SUBDIR, version, emcc_relpath });
}

/// `<version-dir>/upstream/emscripten` — the dir prepended to PATH so a bare
/// `emcc` resolves to the managed toolchain. Caller owns the returned slice.
pub fn emscriptenBinDir(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const root = try getCacheRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, EMSDK_SUBDIR, version, emscripten_bin_relpath });
}

/// `<version-dir>/.emscripten` — the EM_CONFIG file `emsdk activate` writes,
/// with absolute paths into `upstream/`/`node/`. Caller owns the slice.
pub fn emConfigPath(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const root = try getCacheRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, EMSDK_SUBDIR, version, em_config_name });
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "emccPath places emcc under <root>/emsdk/<version>/upstream/emscripten/" {
    const alloc = testing.allocator;
    asm_cache.setCacheRootOverride("/tmp/labelle-test-home");
    defer asm_cache.clearCacheRootOverride();

    const path = try emccPath(alloc, "4.0.9");
    defer alloc.free(path);

    const expected = try std.fs.path.join(alloc, &.{
        "/tmp/labelle-test-home", EMSDK_SUBDIR, "4.0.9", "upstream", "emscripten", emcc_name,
    });
    defer alloc.free(expected);
    try testing.expectEqualStrings(expected, path);
}

test "emcc lives directly under the emscripten bin dir the PATH points at" {
    const alloc = testing.allocator;
    asm_cache.setCacheRootOverride("/x");
    defer asm_cache.clearCacheRootOverride();

    const bin = try emscriptenBinDir(alloc, "4.0.9");
    defer alloc.free(bin);
    const emcc = try emccPath(alloc, "4.0.9");
    defer alloc.free(emcc);

    // The PATH-prepended dir plus the launcher name must equal the emcc path,
    // so a bare `emcc` on PATH resolves to exactly the managed binary.
    const expected_emcc = try std.fs.path.join(alloc, &.{ bin, emcc_name });
    defer alloc.free(expected_emcc);
    try testing.expectEqualStrings(expected_emcc, emcc);
}

test "the launcher and EM_CONFIG sit at the version-dir root" {
    const alloc = testing.allocator;
    asm_cache.setCacheRootOverride("/home/u/.labelle");
    defer asm_cache.clearCacheRootOverride();

    const dir = try versionDir(alloc, "4.0.9");
    defer alloc.free(dir);
    const launcher = try launcherPath(alloc, "4.0.9");
    defer alloc.free(launcher);
    const cfg = try emConfigPath(alloc, "4.0.9");
    defer alloc.free(cfg);

    const expected_launcher = try std.fs.path.join(alloc, &.{ dir, emsdk_launcher_name });
    defer alloc.free(expected_launcher);
    try testing.expectEqualStrings(expected_launcher, launcher);

    const expected_cfg = try std.fs.path.join(alloc, &.{ dir, em_config_name });
    defer alloc.free(expected_cfg);
    try testing.expectEqualStrings(expected_cfg, cfg);
}

test "emsdkRoot is <cache-root>/emsdk" {
    const alloc = testing.allocator;
    asm_cache.setCacheRootOverride("/root/.labelle");
    defer asm_cache.clearCacheRootOverride();

    const r = try emsdkRoot(alloc);
    defer alloc.free(r);
    try testing.expect(std.mem.startsWith(u8, r, "/root/.labelle"));
    try testing.expect(std.mem.endsWith(u8, r, EMSDK_SUBDIR));
}
