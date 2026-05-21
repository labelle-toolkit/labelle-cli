//! Self-contained assembler-binary bootstrap.
//!
//! Issue #217 phase 4: the one thing the CLI genuinely cannot delegate
//! is locating/fetching the `labelle-assembler` binary itself —
//! chicken-and-egg: the assembler can't fetch itself. Everything else
//! (package cache population, generation, init, …) is delegated to that
//! binary once located.
//!
//! Before phase 4 the CLI reused the assembler's `generator` cache
//! helpers (`getCacheRoot`, …) for this. Phase 4 reimplements just the
//! sliver needed — the `~/.labelle/` cache-root resolution — as
//! CLI-owned code with no `generator` import, so phase 5 can drop the
//! assembler package dependency entirely.
//!
//! Cache layout this module is responsible for:
//!
//!   ~/.labelle/assembler/<version>/labelle-assembler[.exe]
//!
//! The download URL and the resolve/download flow live in
//! `assembler.zig`; this module owns only the cache *root*.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");

/// Cache directory name under the user's home directory. Mirrors the
/// assembler's `cache.zig:DEFAULT_CACHE_DIR` — the two must agree so the
/// CLI and the assembler share one `~/.labelle/` tree.
const DEFAULT_CACHE_DIR = ".labelle";

/// Packages subdirectory under the cache root. Mirrors the assembler's
/// `cache.zig:PACKAGES_SUBDIR` — the two must agree so the CLI reads the
/// same `~/.labelle/packages/` tree the assembler populates on `install`.
const PACKAGES_SUBDIR = "packages";

/// Look up an environment variable, returning a heap-owned copy or null.
fn envLookup(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    const env = config.globalEnviron();
    if (env.getAlloc(allocator, name)) |v| return v else |_| {}
    return null;
}

/// Test-only override for the cache root. Production code never touches
/// this — it stays null. Tests use `setCacheRootOverride` because this
/// CLI's `config.globalEnviron()` returns a static empty environ under
/// `zig build test` (it is only populated from `main`), so an env-var
/// based override (`LABELLE_HOME`) is not observable in tests.
var _cache_root_override: ?[]const u8 = null;

/// Test-only: pin the cache root to `root` (a borrowed slice — the caller
/// keeps ownership). Pass null via `clearCacheRootOverride` to restore.
pub fn setCacheRootOverride(root: ?[]const u8) void {
    _cache_root_override = root;
}

/// Test-only: clear the cache-root override.
pub fn clearCacheRootOverride() void {
    _cache_root_override = null;
}

/// Resolve the labelle cache root: `$LABELLE_HOME` if set, else
/// `<home>/.labelle`. Caller owns the returned slice.
///
/// Self-contained reimplementation of the assembler's
/// `cache.zig:getCacheRoot` — duplicated (it is ~15 lines) rather than
/// imported so the CLI carries no `labelle_assembler` package dep.
pub fn getCacheRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (_cache_root_override) |root| return allocator.dupe(u8, root);
    if (envLookup(allocator, "LABELLE_HOME")) |home| return home;

    const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home_dir = envLookup(allocator, home_env) orelse {
        std.debug.print("labelle: could not determine home directory ({s})\n", .{home_env});
        return error.NoHomeDirectory;
    };
    defer allocator.free(home_dir);

    return try std.fs.path.join(allocator, &.{ home_dir, DEFAULT_CACHE_DIR });
}

/// Resolve the packages directory: `<cache-root>/packages`. Caller owns
/// the returned slice.
///
/// Mirrors the assembler's `cache.zig:getPackagesDir` — the assembler
/// populates this tree on `labelle install`, and the CLI reads it back
/// (e.g. to find a cached remote GUI plugin's `gui.labelle` manifest
/// when writing the lock file). Duplicated rather than imported so the
/// CLI carries no `labelle_assembler` package dep (see `getCacheRoot`).
pub fn getPackagesDir(allocator: std.mem.Allocator) ![]const u8 {
    const cache_root = try getCacheRoot(allocator);
    defer allocator.free(cache_root);
    return try std.fs.path.join(allocator, &.{ cache_root, PACKAGES_SUBDIR });
}

/// Resolve a remote (non-local) plugin to its cached directory:
/// `<cache-root>/packages/plugins/<repo>/<version>`. Caller owns the
/// returned slice.
///
/// Mirrors the remote branch of the assembler's `cache.zig:resolvePlugin`
/// — the path the assembler resolves a `.plugins` entry to once it has
/// been fetched into the cache by `labelle install`. Local plugins are
/// resolved by the caller directly from their `local:` / `@` path, so
/// this helper only covers the remote case.
pub fn resolveRemotePluginDir(
    allocator: std.mem.Allocator,
    repo: []const u8,
    version: []const u8,
) ![]const u8 {
    const packages_dir = try getPackagesDir(allocator);
    defer allocator.free(packages_dir);
    return try std.fs.path.join(allocator, &.{ packages_dir, "plugins", repo, version });
}
