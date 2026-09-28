//! The CLI's ONE builder for `packages/plugins/<repo>/<version>` cache paths
//! (#496) — a mirror of labelle-assembler's `src/cache/path_key.zig`
//! (assembler#782/#788). Duplicated rather than imported for the same reason
//! as `asm_cache`: the CLI carries no `labelle_assembler` package dep.
//!
//! A remote `.plugins` entry lives in a cache slot named after the
//! user-written `repo` and `version` strings, verbatim. Those strings are
//! unconstrained: `git+https://github.com/x/y` is a spelling the fetcher
//! accepts, and it carries a `:`. On Windows a `:` (or any of `< > " | ? *`,
//! or a control byte) makes the path an invalid object name, and Zig 0.16's
//! std answers `OBJECT_NAME_INVALID` from `Dir.access` & co. with
//! `statusBug` — a PANIC in Debug, `error.Unexpected` in release — instead
//! of an error the caller can handle.
//!
//! So a path is never built from a string the host cannot name: the builder
//! checks each user-written segment against the host's file-name rules FIRST
//! and returns `error.UnusableCachePath` without touching the filesystem.
//! The layout is unchanged — a string that is valid today maps to the same
//! path it always did, byte for byte the assembler's — so the check can only
//! turn a crash into an error, never move a working cache.
const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{UnusableCachePath};

/// Characters Win32 forbids in a file or directory name. Path separators are
/// not listed: a `/` in a repo is the intended nesting (`github.com/o/r`).
const windows_forbidden = "<>:\"|?*";

/// The first byte of `segment` that `os` cannot put in a path, or null when
/// the whole segment is nameable. Only the bytes are judged — emptiness,
/// `..` and nesting are the callers' existing concerns, left unchanged.
/// Same rule as the assembler's `path_key.firstBadByte`.
pub fn firstBadByte(segment: []const u8, os: std.Target.Os.Tag) ?u8 {
    for (segment) |c| {
        if (c == 0) return c;
        if (os == .windows and (c < 0x20 or std.mem.indexOfScalar(u8, windows_forbidden, c) != null)) return c;
    }
    return null;
}

/// `<packages_dir>/plugins/<repo>/<version>`, or `error.UnusableCachePath`
/// when `repo` or `version` cannot be named on `os`. Silent: callers that
/// face the user report through `report`.
pub fn pluginCachePathFor(
    allocator: std.mem.Allocator,
    os: std.Target.Os.Tag,
    packages_dir: []const u8,
    repo: []const u8,
    version: []const u8,
) (Error || std.mem.Allocator.Error)![]const u8 {
    if (firstBadByte(repo, os) != null or firstBadByte(version, os) != null) return error.UnusableCachePath;
    return std.fs.path.join(allocator, &.{ packages_dir, "plugins", repo, version });
}

/// `pluginCachePathFor` on the host OS.
pub fn pluginCachePath(
    allocator: std.mem.Allocator,
    packages_dir: []const u8,
    repo: []const u8,
    version: []const u8,
) (Error || std.mem.Allocator.Error)![]const u8 {
    return pluginCachePathFor(allocator, builtin.os.tag, packages_dir, repo, version);
}

/// The fetcher's identity for a remote — a mirror of the assembler's
/// `config.normalizeRemote`: an optional `git+`, an optional `https://`,
/// `http://`, `git://` or `ssh://` scheme, a `?ref`/`#sha` suffix, trailing
/// slashes and a `.git` suffix are dropped. Only used to suggest a spelling.
pub fn normalizeRemote(repo: []const u8) []const u8 {
    if (std.mem.startsWith(u8, repo, "local:")) return repo;
    var r = repo;
    if (std.ascii.startsWithIgnoreCase(r, "git+")) r = r["git+".len..];
    inline for (.{ "https://", "http://", "git://", "ssh://" }) |scheme| {
        if (std.ascii.startsWithIgnoreCase(r, scheme)) {
            r = r[scheme.len..];
            break;
        }
    }
    if (std.mem.indexOfAny(u8, r, "?#")) |i| r = r[0..i];
    while (r.len > 0 and r[r.len - 1] == '/') r = r[0 .. r.len - 1];
    if (std.mem.endsWith(u8, r, ".git")) r = r[0 .. r.len - ".git".len];
    return r;
}

/// One line naming what is wrong with `repo`/`version` on `os` and how to
/// fix it, or null when both are usable. Allocated in `allocator`. Same
/// wording as the assembler's `path_key.problem`.
pub fn problem(allocator: std.mem.Allocator, os: std.Target.Os.Tag, repo: []const u8, version: []const u8) !?[]const u8 {
    const which: []const u8, const value: []const u8, const bad: u8 = if (firstBadByte(repo, os)) |c|
        .{ "repo", repo, c }
    else if (firstBadByte(version, os)) |c|
        .{ "version", version, c }
    else
        return null;

    const what = if (bad < 0x20 or bad == 0x7f)
        try std.fmt.allocPrint(allocator, "contains control byte 0x{x:0>2}", .{bad})
    else
        try std.fmt.allocPrint(allocator, "contains '{c}', which {s} does not allow in a file name", .{ bad, @tagName(os) });
    defer allocator.free(what);

    // For the repo, the fetcher's own identity names the same remote without
    // the scheme/query — suggest it when it is itself usable, so the fix is
    // one copy-paste.
    const canonical = if (std.mem.eql(u8, which, "repo")) normalizeRemote(repo) else "";
    if (canonical.len > 0 and firstBadByte(canonical, os) == null and !std.mem.eql(u8, canonical, repo)) {
        return try std.fmt.allocPrint(allocator, "package {s} '{s}' cannot be used as a cache path: it {s}. Spell it '{s}' — the same remote", .{ which, value, what, canonical });
    }
    return try std.fmt.allocPrint(allocator, "package {s} '{s}' cannot be used as a cache path: it {s}", .{ which, value, what });
}

/// Print `problem` for the host (stderr). A no-op when the pair is usable.
pub fn report(repo: []const u8, version: []const u8) void {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const msg = (problem(fba.allocator(), builtin.os.tag, repo, version) catch return) orelse return;
    std.debug.print("labelle: {s}\n", .{msg});
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "plugin_path_key: firstBadByte — table over Windows and POSIX rules (#496)" {
    const Case = struct { s: []const u8, windows: ?u8, linux: ?u8 };
    const cases = [_]Case{
        .{ .s = "github.com/labelle-toolkit/labelle-example", .windows = null, .linux = null },
        .{ .s = "1.2.3", .windows = null, .linux = null },
        .{ .s = "1.2.3-rc.1+build.5", .windows = null, .linux = null },
        .{ .s = "feature/foo", .windows = null, .linux = null },
        .{ .s = "git+https://github.com/labelle-toolkit/labelle-example", .windows = ':', .linux = null },
        .{ .s = "github.com/x/y?ref=main", .windows = '?', .linux = null },
        .{ .s = "a\"b", .windows = '"', .linux = null },
        .{ .s = "a|b", .windows = '|', .linux = null },
        .{ .s = "a*b", .windows = '*', .linux = null },
        .{ .s = "a<b>", .windows = '<', .linux = null },
        .{ .s = "tab\there", .windows = '\t', .linux = null },
        .{ .s = "nul\x00here", .windows = 0, .linux = 0 },
        .{ .s = "", .windows = null, .linux = null },
    };
    for (cases) |c| {
        try testing.expectEqual(c.windows, firstBadByte(c.s, .windows));
        try testing.expectEqual(c.linux, firstBadByte(c.s, .linux));
        try testing.expectEqual(c.linux, firstBadByte(c.s, .macos));
    }
}

test "plugin_path_key: pluginCachePathFor refuses before joining, keeps the layout otherwise (#496)" {
    const a = testing.allocator;
    const repo = "git+https://github.com/labelle-toolkit/labelle-example";

    try testing.expectError(error.UnusableCachePath, pluginCachePathFor(a, .windows, "P", repo, "1.0.0"));
    try testing.expectError(error.UnusableCachePath, pluginCachePathFor(a, .windows, "P", "github.com/x/y", "a:b"));
    try testing.expectError(error.UnusableCachePath, pluginCachePathFor(a, .linux, "P", "github.com/x/y", "a\x00b"));

    // POSIX names it fine: the layout is exactly the verbatim join it always was.
    const p = try pluginCachePathFor(a, .linux, "P", repo, "1.0.0");
    defer a.free(p);
    const want = try std.fs.path.join(a, &.{ "P", "plugins", repo, "1.0.0" });
    defer a.free(want);
    try testing.expectEqualStrings(want, p);

    inline for (.{ std.Target.Os.Tag.windows, .linux, .macos }) |os| {
        const q = try pluginCachePathFor(a, os, "P", "github.com/x/y", "1.2.3-rc.1");
        defer a.free(q);
        const w = try std.fs.path.join(a, &.{ "P", "plugins", "github.com/x/y", "1.2.3-rc.1" });
        defer a.free(w);
        try testing.expectEqualStrings(w, q);
    }
}

test "plugin_path_key: problem names the field and byte, and suggests the canonical spelling (#496)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const m = (try problem(a, .windows, "git+https://github.com/labelle-toolkit/labelle-example?ref=main", "1.0.0")).?;
    try testing.expect(std.mem.indexOf(u8, m, "package repo 'git+https://github.com/labelle-toolkit/labelle-example?ref=main'") != null);
    try testing.expect(std.mem.indexOf(u8, m, "contains ':', which windows does not allow") != null);
    try testing.expect(std.mem.indexOf(u8, m, "Spell it 'github.com/labelle-toolkit/labelle-example'") != null);

    const v = (try problem(a, .windows, "github.com/x/y", "a|b")).?;
    try testing.expect(std.mem.indexOf(u8, v, "package version 'a|b'") != null);
    try testing.expect(std.mem.indexOf(u8, v, "Spell it") == null);

    // No suggestion when the canonical form is itself unusable (a port).
    const port = (try problem(a, .windows, "https://host:8080/x/y", "1.0.0")).?;
    try testing.expect(std.mem.indexOf(u8, port, "Spell it") == null);

    try testing.expect(std.mem.indexOf(u8, (try problem(a, .linux, "x\x00y", "1.0.0")).?, "control byte 0x00") != null);
    try testing.expect((try problem(a, .linux, "git+https://github.com/x/y", "1.0.0")) == null);
    try testing.expect((try problem(a, .windows, "github.com/x/y", "1.0.0")) == null);
}
