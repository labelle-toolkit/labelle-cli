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

/// Look up an environment variable, returning a heap-owned copy or null.
fn envLookup(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    const env = config.globalEnviron();
    if (env.getAlloc(allocator, name)) |v| return v else |_| {}
    return null;
}

/// Resolve the labelle cache root: `$LABELLE_HOME` if set, else
/// `<home>/.labelle`. Caller owns the returned slice.
///
/// Self-contained reimplementation of the assembler's
/// `cache.zig:getCacheRoot` — duplicated (it is ~15 lines) rather than
/// imported so the CLI carries no `labelle_assembler` package dep.
pub fn getCacheRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (envLookup(allocator, "LABELLE_HOME")) |home| return home;

    const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home_dir = envLookup(allocator, home_env) orelse {
        std.debug.print("labelle: could not determine home directory ({s})\n", .{home_env});
        return error.NoHomeDirectory;
    };
    defer allocator.free(home_dir);

    return try std.fs.path.join(allocator, &.{ home_dir, DEFAULT_CACHE_DIR });
}
