//! Where a REMOTE `.plugins` entry lives on disk — the CLI's mirror of the
//! assembler's `cache/resolve.zig:resolvePlugin` for a non-local pin.
//!
//! Duplicated rather than imported for the same reason as `asm_cache`: the
//! CLI carries no `labelle_assembler` package dep. Two things the assembler
//! resolves that a plain `<packages>/plugins/<repo>/<version>` join misses:
//!
//!   * a `.subdir` pin (assembler#771) — a plugin that lives in a directory
//!     of a monorepo. The archive is cached whole; the plugin root is
//!     `<archive>/<subdir>` (`resolveRemotePlugin`).
//!   * an `install plugin <name> local:<path>` override (assembler#772) —
//!     an EXPLICIT local slot at `<packages>/local/plugins/<key>` with a
//!     provenance marker at `<packages>/local.origins/plugins/<key>`. The
//!     assembler builds from it instead of the pinned release. Rather than
//!     teach every CLI consumer about it, `applyOverrides` runs once when
//!     project.labelle is read and turns the dep into a LOCAL one
//!     (`PluginDep.cli_override_source`): provider discovery, watch roots,
//!     atlases and manifests then all treat it like a `local:` pin — which
//!     is what it is for this build — while `repo`/`version` keep the
//!     committed pin for `labelle.lock`.
//!
//! Only `.explicit` markers are honoured here. A `.discovered` slot is the
//! assembler's monorepo auto-discovery, which activates only for an
//! assembler running inside that monorepo — a question the CLI cannot
//! answer, and one the released binary it runs answers "no" to.
const std = @import("std");
const config = @import("config.zig");
const project_config = @import("project_config.zig");
const asm_cache = @import("asm_cache.zig");

/// The cached plugin directory for a REMOTE dep: `<archive>/<subdir>`.
/// Overrides are not consulted here — `applyOverrides` has already made an
/// overridden dep local. Caller owns the returned slice.
pub fn resolveRemotePlugin(allocator: std.mem.Allocator, dep: project_config.PluginDep) ![]const u8 {
    const packages_dir = try asm_cache.getPackagesDir(allocator);
    defer allocator.free(packages_dir);
    const sub = std.mem.trimEnd(u8, dep.subdir, "/\\");
    if (sub.len == 0) return std.fs.path.join(allocator, &.{ packages_dir, "plugins", dep.repo, dep.version });
    return std.fs.path.join(allocator, &.{ packages_dir, "plugins", dep.repo, dep.version, sub });
}

/// Undo `applyOverrides`: every dep back to its committed declaration.
/// For the commands whose output is committed (`providers resolve`).
pub fn clearOverrides(cfg: project_config.ProjectConfig) void {
    for (@constCast(cfg.plugins)) |*dep| dep.cli_override_source = null;
}

/// Mark every remote `.plugins` entry that has an active explicit override
/// as local to its checkout. `cfg.plugins` is the parser's own allocation,
/// so the entries are updated in place; the source string is allocated with
/// `allocator` like every other parsed field. A value AUTHORED in
/// project.labelle is discarded first: only the assembler's marker counts.
pub fn applyOverrides(allocator: std.mem.Allocator, cfg: project_config.ProjectConfig) !void {
    const plugins = @constCast(cfg.plugins);
    for (plugins) |*dep| {
        dep.cli_override_source = null;
        if (dep.isLocal()) continue;
        dep.cli_override_source = try explicitOverrideSource(allocator, dep.*);
    }
}

/// `<readable name>-<16 hex digits>` — mirrors the assembler's
/// `cache/local.zig:pluginSlotKey` byte for byte (Wyhash seeded 0x1abe11e
/// over `repo ++ "\x00" ++ name`; the readable part keeps up to 32 of the
/// name's `[A-Za-z0-9_.-]` characters, or "plugin" when none survive).
pub fn slotKey(allocator: std.mem.Allocator, repo: []const u8, name: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0x1abe11e);
    hasher.update(repo);
    hasher.update(&[_]u8{0});
    hasher.update(name);

    var label: std.ArrayList(u8) = .empty;
    defer label.deinit(allocator);
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.') {
            if (label.items.len < 32) try label.append(allocator, c);
        }
    }
    const readable = if (label.items.len == 0) "plugin" else label.items;
    return std.fmt.allocPrint(allocator, "{s}-{x:0>16}", .{ readable, hasher.final() });
}

/// The checkout an EXPLICIT override names for `dep`, when its slot and
/// its source both still exist (the assembler's activation rule). Caller
/// owns the result.
pub fn explicitOverrideSource(allocator: std.mem.Allocator, dep: project_config.PluginDep) !?[]const u8 {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    // No cache home (no LABELLE_HOME/HOME/USERPROFILE) means no override can
    // be registered, and reading project.labelle must not fail over it.
    const packages_dir = asm_cache.getPackagesDir(allocator) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer allocator.free(packages_dir);
    const key = try slotKey(allocator, dep.repo, dep.name);
    defer allocator.free(key);

    const marker = try std.fs.path.join(allocator, &.{ packages_dir, "local.origins", "plugins", key });
    defer allocator.free(marker);
    const content = cwd.readFileAlloc(io, marker, allocator, .limited(64 * 1024)) catch return null;
    defer allocator.free(content);

    const mode = field(content, "mode") orelse return null;
    if (!std.mem.eql(u8, mode, "explicit")) return null;
    const source = field(content, "source") orelse return null;

    const slot = try std.fs.path.join(allocator, &.{ packages_dir, "local", "plugins", key });
    defer allocator.free(slot);
    cwd.access(io, slot, .{}) catch return null;
    cwd.access(io, source, .{}) catch return null;
    return try allocator.dupe(u8, source);
}

/// `key = value` lookup over the marker's line-oriented body (the format
/// the assembler's `cache/local.zig:writeOrigin` writes).
fn field(content: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeAny(u8, content, "\r\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, key)) continue;
        const rest = std.mem.trim(u8, trimmed[key.len..], " \t");
        if (!std.mem.startsWith(u8, rest, "=")) continue;
        return std.mem.trim(u8, rest[1..], " \t");
    }
    return null;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

const debug_dep: project_config.PluginDep = .{
    .name = "debug",
    .repo = "github.com/labelle-toolkit/labelle-assembler",
    .version = "0.118.0",
    .subdir = "plugins/debug",
};

test "plugin slot key matches the assembler's pluginSlotKey" {
    // Produced by labelle-assembler's `install plugin debug local:<path>`
    // for this repo/name pair: packages/local/plugins/debug-ce1b0657dc37ae68.
    const key = try slotKey(testing.allocator, debug_dep.repo, debug_dep.name);
    defer testing.allocator.free(key);
    try testing.expectEqualStrings("debug-ce1b0657dc37ae68", key);

    const odd = try slotKey(testing.allocator, "github.com/acme/x", "!!");
    defer testing.allocator.free(odd);
    try testing.expect(std.mem.startsWith(u8, odd, "plugin-"));
}

fn tmpRoot(tmp: *testing.TmpDir, a: std.mem.Allocator) ![]const u8 {
    const z = try tmp.dir.realPathFileAlloc(config.globalIo(), ".", a);
    defer a.free(z);
    return a.dupe(u8, z);
}

test "plugin slot: a .subdir pin resolves inside the cached archive" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(&tmp, a);
    defer a.free(root);
    asm_cache.setCacheRootOverride(root);
    defer asm_cache.clearCacheRootOverride();

    const dir = try resolveRemotePlugin(a, debug_dep);
    defer a.free(dir);
    const expected = try std.fs.path.join(a, &.{ root, "packages", "plugins", debug_dep.repo, "0.118.0", "plugins/debug" });
    defer a.free(expected);
    try testing.expectEqualStrings(expected, dir);

    var plain = debug_dep;
    plain.subdir = "";
    const plain_dir = try resolveRemotePlugin(a, plain);
    defer a.free(plain_dir);
    const plain_expected = try std.fs.path.join(a, &.{ root, "packages", "plugins", debug_dep.repo, "0.118.0" });
    defer a.free(plain_expected);
    try testing.expectEqualStrings(plain_expected, plain_dir);
}

test "plugin slot: an EXPLICIT override wins, a discovered one or a dead source does not" {
    const a = testing.allocator;
    const io = config.globalIo();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(&tmp, a);
    defer a.free(root);
    asm_cache.setCacheRootOverride(root);
    defer asm_cache.clearCacheRootOverride();

    try tmp.dir.createDirPath(io, "checkout");
    try tmp.dir.createDirPath(io, "packages/local/plugins/debug-ce1b0657dc37ae68");
    try tmp.dir.createDirPath(io, "packages/local.origins/plugins");
    const checkout = try std.fs.path.join(a, &.{ root, "checkout" });
    defer a.free(checkout);
    const marker_rel = "packages/local.origins/plugins/debug-ce1b0657dc37ae68";

    const explicit = try std.fmt.allocPrint(a, "# labelle local cache slot\nsource = {s}\nrevision = unknown\npinned = 0.1.0\nmode = explicit\n", .{checkout});
    defer a.free(explicit);
    try tmp.dir.writeFile(io, .{ .sub_path = marker_rel, .data = explicit });
    // Folded in at load time: the dep becomes LOCAL to its checkout for
    // every consumer, while the committed pin (what the lock records) stays.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var deps = [_]project_config.PluginDep{
        debug_dep,
        .{ .name = "fsm", .repo = "github.com/labelle-toolkit/labelle-fsm", .version = "0.5.0" },
        .{ .name = "mine", .repo = "@libs/mine", .cli_override_source = "authored" },
    };
    try applyOverrides(arena.allocator(), .{ .name = "g", .plugins = &deps });
    try testing.expect(deps[0].isLocal());
    try testing.expectEqualStrings(checkout, deps[0].localPath());
    try testing.expectEqualStrings(debug_dep.repo, deps[0].repo);
    try testing.expect(!deps[1].isLocal());
    // An authored value is never trusted: only the assembler's marker counts.
    try testing.expect(deps[2].cli_override_source == null);
    try testing.expectEqualStrings("libs/mine", deps[2].localPath());
    const plugin_dir = try @import("plugins.zig").resolvePluginDir(a, root, deps[0]);
    defer a.free(plugin_dir);
    try testing.expectEqualStrings(checkout, plugin_dir);
    // Committed-output commands see the declaration again.
    clearOverrides(.{ .name = "g", .plugins = &deps });
    try testing.expect(!deps[0].isLocal());

    // A discovered slot is the assembler's monorepo business, not ours.
    const discovered = try std.fmt.allocPrint(a, "source = {s}\nmode = discovered\n", .{checkout});
    defer a.free(discovered);
    try tmp.dir.writeFile(io, .{ .sub_path = marker_rel, .data = discovered });
    try testing.expect(try explicitOverrideSource(a, debug_dep) == null);

    // An explicit marker whose checkout is gone falls back to the pin.
    try tmp.dir.writeFile(io, .{ .sub_path = marker_rel, .data = explicit });
    try tmp.dir.deleteTree(io, "checkout");
    try testing.expect(try explicitOverrideSource(a, debug_dep) == null);
    const fallback = try resolveRemotePlugin(a, debug_dep);
    defer a.free(fallback);
    try testing.expect(std.mem.endsWith(u8, fallback, "plugins/debug"));
}
