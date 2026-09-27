//! A provider's persistent cache directory (contract §2 `cache_dir`, wire
//! `1.3.0`+): `<LABELLE_HOME>/providers/<canonical provider id>/`.
//!
//! The directory is keyed by what the provider IS, not by what a project
//! calls it, so every project that pins the same provider shares one cache:
//!
//! - A pinned GitHub provider's id is its repository, normalised by
//!   `provider_github.projectRepo` (every spelling the assembler fetches as
//!   the same repository) and lowercased, since GitHub names are
//!   case-insensitive: `github.com/<owner>/<name>`. Each segment keeps its
//!   characters (GitHub allows only `[A-Za-z0-9._-]`), except that a segment
//!   Windows cannot create is escaped with `~`, a character no GitHub name
//!   contains, so the escape never collides with another repository: a
//!   reserved device stem gets `~` before its first dot (`con` -> `con~`,
//!   `con.tools` -> `con~.tools`, whose stem `con~` is not a device), and a
//!   trailing `.` gets `~` after it (`name.` -> `name.~`).
//! - A local provider (`local:<path>`, `@<path>`) has no repository; its id
//!   is its canonical directory: `local/<name>-<hash>`, where `<hash>` is
//!   the first 32 hex digits of the SHA-256 of the provider's real path
//!   (lowercased on Windows, whose paths are case-insensitive) and `<name>`
//!   is the directory's basename reduced to `[a-z0-9._-]` for readability.
//!   Two projects pointing at one checkout share its cache; a moved
//!   checkout gets a new one.
//!
//! The CLI only creates the directory. What lives inside, and how
//! concurrent builds share it, is the provider's (docs/provider-contract-v1.md).
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("provider_contract.zig");
const github = @import("provider_github.zig");
const project = @import("project_config.zig");

pub const providers_dir = "providers";

/// The canonical provider id, as relative path segments joined with `/`.
/// `real_dir` is the provider's canonical directory (used for local
/// providers only).
pub fn canonicalId(a: std.mem.Allocator, dep: project.PluginDep, real_dir: []const u8, windows: bool) ![]const u8 {
    if (dep.isLocal()) {
        const key = if (windows) try std.ascii.allocLowerString(a, real_dir) else real_dir;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
        const hex = std.fmt.bytesToHex(digest[0..16].*, .lower);
        return std.fmt.allocPrint(a, "local/{s}-{s}", .{ try readableName(a, basename(real_dir)), &hex });
    }
    const repo = try github.projectRepo(dep.repo);
    const slash = std.mem.indexOfScalar(u8, repo, '/').?;
    return std.fmt.allocPrint(a, "{s}/{s}/{s}", .{
        github_host,
        try segment(a, repo[0..slash]),
        try segment(a, repo[slash + 1 ..]),
    });
}

const github_host = "github.com";

fn basename(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    var start = end;
    while (start > 0 and path[start - 1] != '/' and path[start - 1] != '\\') start -= 1;
    return path[start..end];
}

fn readableName(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name) |c| {
        if (out.items.len == 40) break;
        const lower = std.ascii.toLower(c);
        const keep = std.ascii.isLower(lower) or std.ascii.isDigit(lower) or lower == '-' or lower == '_' or lower == '.';
        try out.append(a, if (keep) lower else '-');
    }
    while (out.items.len > 0 and out.items[0] == '.') _ = out.orderedRemove(0);
    if (out.items.len == 0) try out.appendSlice(a, "provider");
    return out.items;
}

fn segment(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out = try std.ascii.allocLowerString(a, raw);
    if (contract.windowsReservedDeviceName(out)) {
        const dot = std.mem.indexOfScalar(u8, out, '.') orelse out.len;
        out = try std.fmt.allocPrint(a, "{s}~{s}", .{ out[0..dot], out[dot..] });
    }
    if (std.mem.endsWith(u8, out, ".")) out = try std.fmt.allocPrint(a, "{s}~", .{out});
    return out;
}

/// `<cache_root>/providers/<canonical id>/`, with the host's separators.
/// Pure: the caller creates it.
pub fn dirPath(a: std.mem.Allocator, cache_root: []const u8, dep: project.PluginDep, real_dir: []const u8) ![]const u8 {
    const id = try canonicalId(a, dep, real_dir, builtin.os.tag == .windows);
    var parts: std.ArrayList([]const u8) = .empty;
    try parts.appendSlice(a, &.{ cache_root, providers_dir });
    var it = std.mem.splitScalar(u8, id, '/');
    while (it.next()) |part| try parts.append(a, part);
    return std.fs.path.join(a, parts.items);
}

fn segmentPath(a: std.mem.Allocator, repo: []const u8) ![]const u8 {
    return canonicalId(a, .{ .name = "x", .repo = repo, .version = "1.0.0" }, "/unused", false);
}

test "provider cache: a pinned provider is keyed by its normalised repository" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Every spelling of one repository, under any project alias, is one id.
    for ([_][]const u8{
        "github.com/Labelle-Toolkit/Labelle-Probe",
        "labelle-toolkit/labelle-probe",
        "https://github.com/labelle-toolkit/labelle-probe.git",
        "git+ssh://git@GitHub.com/labelle-toolkit/labelle-probe/",
    }) |repo| {
        for ([_][]const u8{ "probe", "alias" }) |alias| {
            const id = try canonicalId(a, .{ .name = alias, .repo = repo, .version = "0.3.0" }, "/unused", false);
            try std.testing.expectEqualStrings("github.com/labelle-toolkit/labelle-probe", id);
        }
    }
    // A segment Windows cannot create is escaped with a character no GitHub
    // name holds, so it cannot collide with a real repository.
    try std.testing.expectEqualStrings("github.com/con~/aux~", try canonicalId(a, .{ .name = "x", .repo = "github.com/CON/aux", .version = "1.0.0" }, "/unused", false));
    try std.testing.expectEqualStrings("github.com/owner/name.~", try canonicalId(a, .{ .name = "x", .repo = "owner/name.", .version = "1.0.0" }, "/unused", false));
    try std.testing.expectEqualStrings("github.com/owner/con~.tools", try canonicalId(a, .{ .name = "x", .repo = "owner/con.tools", .version = "1.0.0" }, "/unused", false));
    try std.testing.expectEqualStrings("github.com/owner/con~.~", try segmentPath(a, "owner/con."));
    // Every reserved device name, bare, with an extension, with two and with
    // a trailing dot, in any case: the escaped segment is creatable on
    // Windows (its stem is no device, it has no trailing dot) and keeps the
    // original characters apart from the inserted `~`s.
    var names: std.ArrayList([]const u8) = .empty;
    try names.appendSlice(a, &.{ "con", "prn", "aux", "nul", "conin$", "conout$" });
    for (1..10) |n| {
        try names.append(a, try std.fmt.allocPrint(a, "com{d}", .{n}));
        try names.append(a, try std.fmt.allocPrint(a, "lpt{d}", .{n}));
    }
    for (names.items) |name| {
        for ([_][]const u8{ "", ".tools", ".tar.gz", "." }) |suffix| {
            for ([_]bool{ false, true }) |upper| {
                const raw = try std.fmt.allocPrint(a, "{s}{s}", .{ name, suffix });
                if (upper) _ = std.ascii.upperString(raw, raw);
                const escaped = try segment(a, raw);
                try std.testing.expect(!contract.windowsReservedDeviceName(escaped));
                try std.testing.expect(!std.mem.endsWith(u8, escaped, "."));
                const without = try std.mem.replaceOwned(u8, a, escaped, "~", "");
                try std.testing.expect(std.ascii.eqlIgnoreCase(without, raw));
            }
        }
    }
    // Near misses are not escaped.
    for ([_][]const u8{ "console", "com10", "lpt", "nul0", "tools.con" }) |name| {
        try std.testing.expectEqualStrings(name, try segment(a, name));
    }
    try std.testing.expectEqualStrings("github.com/owner/console", try canonicalId(a, .{ .name = "x", .repo = "owner/console", .version = "1.0.0" }, "/unused", false));
    // Another host is refused, never keyed.
    try std.testing.expectError(error.NonGitHubProviderRepository, canonicalId(a, .{ .name = "x", .repo = "gitlab.com/o/n", .version = "1.0.0" }, "/unused", false));
}

test "provider cache: a local provider is keyed by its canonical directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try canonicalId(a, .{ .name = "probe", .repo = "local:../labelle-probe" }, "/src/Labelle Probe", false);
    // Same directory, another alias and spelling: the same id.
    try std.testing.expectEqualStrings(one, try canonicalId(a, .{ .name = "other", .repo = "@../../src/Labelle Probe" }, "/src/Labelle Probe", false));
    try std.testing.expect(std.mem.startsWith(u8, one, "local/labelle-probe-"));
    try std.testing.expectEqual(@as(usize, "local/labelle-probe-".len + 32), one.len);
    // Another directory: another id.
    try std.testing.expect(!std.mem.eql(u8, one, try canonicalId(a, .{ .name = "probe", .repo = "local:../x" }, "/src/labelle-probe", false)));
    // Windows paths are case-insensitive, so the key folds case there only.
    try std.testing.expectEqualStrings(
        try canonicalId(a, .{ .name = "w", .repo = "local:x" }, "C:\\Src\\Probe", true),
        try canonicalId(a, .{ .name = "w", .repo = "local:x" }, "c:\\src\\probe", true),
    );
    // A basename with nothing readable still yields a usable segment.
    try std.testing.expect(std.mem.startsWith(u8, try canonicalId(a, .{ .name = "w", .repo = "local:x" }, "/...", false), "local/provider-"));
}

test "provider cache: the directory sits under the cache root's providers/" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = if (builtin.os.tag == .windows) "C:\\home" else "/home";
    const got = try dirPath(a, root, .{ .name = "probe", .repo = "github.com/o/n", .version = "1.0.0" }, "/unused");
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "providers", "github.com", "o", "n" }), got);
}
