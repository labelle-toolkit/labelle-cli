const std = @import("std");
const project_config = @import("project_config.zig");

/// Process-wide Io handle used by helpers in cli/* that historically
/// used `std.fs.cwd()` (which no longer exists on 0.16). Must be
/// initialized from `main()` by calling `initGlobalIo()` with the
/// process-level setup in main().
///
/// Tests don't call `main`, so `globalIo()` lazy-initializes a default
/// Threaded instance with empty argv0 / environ on first access. This
/// keeps `std.testing.tmpDir` + dir/file helpers working under
/// `zig build test` without requiring every test to thread an Io
/// through.
var _global_threaded: std.Io.Threaded = undefined;
var _global_io: std.Io = undefined;
var _global_environ: std.process.Environ = .empty;
var _global_io_initialized: bool = false;

/// Initialize the process-wide Io. Call once from main() before any
/// helper accesses globalIo(). Mirrors labelle-assembler's pattern.
pub fn initGlobalIo(minimal: std.process.Init.Minimal) void {
    _global_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .argv0 = .init(minimal.args),
        .environ = minimal.environ,
    });
    _global_io = _global_threaded.io();
    _global_environ = minimal.environ;
    _global_io_initialized = true;
}

pub fn globalIo() std.Io {
    if (!_global_io_initialized) {
        _global_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        _global_io = _global_threaded.io();
        _global_io_initialized = true;
    }
    return _global_io;
}

pub fn globalEnviron() std.process.Environ {
    return _global_environ;
}

pub fn readProjectConfig(allocator: std.mem.Allocator, project_dir: []const u8) !project_config.ProjectConfig {
    return readProjectConfigImpl(allocator, project_dir, true);
}

/// Same as readProjectConfig but without printing error messages.
/// Used by commands where a missing project.labelle is expected (e.g. clean).
pub fn readProjectConfigQuiet(allocator: std.mem.Allocator, project_dir: []const u8) !project_config.ProjectConfig {
    return readProjectConfigImpl(allocator, project_dir, false);
}

/// True when `<project_dir>/project.labelle` exists — i.e. `project_dir`
/// is (the root of) a Labelle project. Used by standalone-dispatched
/// commands that still require a project (e.g. `add`, #271) to reject
/// running outside one before they mutate the filesystem.
pub fn projectExists(project_dir: []const u8) bool {
    const labelle_path = std.fs.path.join(std.heap.page_allocator, &.{ project_dir, "project.labelle" }) catch return false;
    defer std.heap.page_allocator.free(labelle_path);
    std.Io.Dir.cwd().access(globalIo(), labelle_path, .{}) catch return false;
    return true;
}

/// Print the standard "no project.labelle found" guidance. Shared so a
/// standalone-dispatched command that requires a project emits the exact
/// message the main project-config guard (see cli.zig) prints.
pub fn printNoProjectError(project_dir: []const u8) void {
    std.debug.print("\n  No project.labelle found in '{s}'.\n\n", .{project_dir});
    std.debug.print("  To create a new project:\n", .{});
    std.debug.print("    labelle init <name>\n\n", .{});
    std.debug.print("  To see all commands:\n", .{});
    std.debug.print("    labelle help\n\n", .{});
}

fn readProjectConfigImpl(allocator: std.mem.Allocator, project_dir: []const u8, verbose: bool) !project_config.ProjectConfig {
    // Raise branch quota for std.zon.parse.fromSlice — ProjectConfig has many
    // fields (including nested IosConfig) that exceed the default 1100 limit.
    @setEvalBranchQuota(10000);
    const labelle_path = try std.fs.path.join(allocator, &.{ project_dir, "project.labelle" });
    defer allocator.free(labelle_path);

    const source_raw = std.Io.Dir.cwd().readFileAlloc(globalIo(), labelle_path, allocator, .limited(1024 * 1024)) catch |err| {
        if (verbose) std.debug.print("labelle: could not read '{s}': {any}\n", .{ labelle_path, err });
        return error.FileNotFound;
    };
    defer allocator.free(source_raw);

    const source = try allocator.dupeZ(u8, source_raw);
    defer allocator.free(source);

    // `ignore_unknown_fields`: the CLI's `project_config.ProjectConfig`
    // is a deliberately minimal copy of the assembler's schema (#217).
    // The assembler owns the schema and may add fields the CLI does not
    // mirror — without this, a newer project.labelle would fail to parse
    // and break the CLI for no good reason.
    try @import("provider_settings.zig").validateProject(allocator, source, if (verbose) labelle_path else null);
    return std.zon.parse.fromSliceAlloc(project_config.ProjectConfig, allocator, source, null, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        if (verbose) std.debug.print("labelle: could not parse '{s}': {any}\n", .{ labelle_path, err });
        return error.ParseError;
    };
}

const expect = @import("zspec").expect;

test {
    @import("zspec").runAll(@This());
}

/// Codex review (#272): `add` is dispatched from the standalone-command
/// switch, skipping the `readProjectConfig` guard project-scoped commands
/// use. `projectExists` is the guard `cli/add.zig` calls before scaffolding
/// so `labelle add ...` in a non-project cwd errors instead of writing
/// `packs/`/`components/`/`scripts/` into the wrong directory.
pub const ProjectExistsSpec = struct {
    pub const with_manifest = struct {
        test "returns true when project.labelle is present" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const io = globalIo();
            try tmp.dir.writeFile(io, .{ .sub_path = "project.labelle", .data = ".{}" });

            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const n = try tmp.dir.realPath(io, &buf);
            try expect.toBeTrue(projectExists(buf[0..n]));
        }
    };

    pub const without_manifest = struct {
        test "returns false in a directory with no project.labelle" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const io = globalIo();

            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const n = try tmp.dir.realPath(io, &buf);
            try expect.toBeFalse(projectExists(buf[0..n]));
        }

        test "returns false for a path that does not exist" {
            try expect.toBeFalse(projectExists("/no/such/labelle/dir/xyzzy"));
        }
    };
};

/// #353 guard 2 ("unknown keys in `project.labelle` are a hard error in
/// the CLI too") — DELIBERATELY NOT IMPLEMENTED, and this spec is the
/// reason, executable so it cannot rot into folklore.
///
/// The CLI's `project_config.ProjectConfig` is a MINIMAL MIRROR of the
/// assembler's schema (#217): the assembler owns `project.labelle` and
/// parses it STRICTLY (`ignore_unknown_fields = false`), so a key no
/// version of the toolchain knows already fails there, at generate time,
/// in the component that owns the schema. What the CLI's mirror lacks is
/// not "unknown to everyone" but "known to the pinned assembler, not
/// mirrored here" — today that includes the resource fields `.image` and
/// `.grid`. Rejecting those would break projects that are entirely
/// valid, including ones the CLI builds correctly right now.
///
/// The asymmetry is structural and permanent: the assembler is pinned
/// per project and released independently, so its schema is always
/// allowed to be ahead of the CLI's mirror. A CLI-side unknown-field
/// gate would therefore refuse newer-but-valid projects — the inverse of
/// the incident's failure and a far more frequent one. The stale-CLI lock
/// gate (`lockfile.enforceCliNotStale`) covers the incident instead: it
/// keys off the CLI version the project was locked with, which is the
/// fact that actually predicts "this binary may not understand this
/// project", rather than guessing from field names.
/// A `project.labelle` with no `.backend` field builds with bgfx, the
/// assembler's default since assembler#768 (it was raylib before).
pub const DefaultBackendSpec = struct {
    test "a project without .backend resolves to bgfx" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(globalIo(), .{ .sub_path = "project.labelle", .data = ".{ .name = \"demo\" }" });
        const dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
        const cfg = try readProjectConfigQuiet(alloc, dir);
        try std.testing.expectEqual(project_config.Backend.bgfx, cfg.backend);
        try std.testing.expectEqual(project_config.Backend.bgfx, project_config.default_backend);
        // An explicit field still wins.
        try tmp.dir.writeFile(globalIo(), .{ .sub_path = "project.labelle", .data = ".{ .name = \"demo\", .backend = .raylib }" });
        try std.testing.expectEqual(project_config.Backend.raylib, (try readProjectConfigQuiet(alloc, dir)).backend);
    }
};

pub const CliMirrorToleranceSpec = struct {
    test "a resource carrying assembler-only fields still parses" {
        // Arena: the real callers parse into one too (the config strings
        // outlive every loop iteration and `std.zon.parse.free` is
        // finicky on some fields — see `astc/cmd.zig`).
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(globalIo(), .{
            .sub_path = "project.labelle",
            .data = ".{ .name = \"demo\", .resources = .{" ++
                " .{ .name = \"tiles\", .image = \"assets/tiles.png\", .grid = .{ .cell_w = 16, .cell_h = 16 } }," ++
                " .{ .name = \"chars\", .json = \"assets/c.json\", .texture = \"assets/c.png\", .astc_block = .@\"4x4\" }," ++
                " } }",
        });
        const dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
        defer alloc.free(dir);

        // `.image` / `.grid` are assembler-owned resource fields this
        // CLI's mirror does not carry. A "unknown to me = error" gate
        // would reject this project; the toolchain builds it fine.
        const cfg = try readProjectConfigQuiet(alloc, dir);
        try expect.equal(cfg.resources.len, @as(usize, 2));
        // The fields the CLI DOES consume are unaffected by the skip.
        try std.testing.expectEqualStrings("chars", cfg.resources[1].name);
        try std.testing.expectEqualStrings("4x4", @tagName(cfg.resources[1].astc_block.?));
    }
};

/// Environment names a provider's `env_file` may not set (provider contract
/// §2, "Environment contributions"): the ones the CLI owns. `PATH` is
/// extended only through `path_prepend`; the Zig cache variables are the
/// ones the CLI points at its own cache tree; and every `LABELLE_*` name here
/// is one the CLI itself reads, or sets for the game it launches. A fixed
/// table, not a `LABELLE_*` prefix ban: any other name, `LABELLE_*` or not,
/// may be set. `src/reserved_env_guard_test.zig` fails when a `LABELLE_*`
/// name the CLI source spells is in neither this table nor
/// `unreserved_labelle_env`, and when an entry here is no longer spelled
/// anywhere, so the table cannot silently drift from what the CLI reads.
pub const reserved_env = [_][]const u8{
    "PATH",
    "ZIG_GLOBAL_CACHE_DIR",
    "ZIG_LOCAL_CACHE_DIR",
    // Read by the CLI.
    "LABELLE_HOME",
    "LABELLE_CONTEXT",
    "LABELLE_OFFLINE",
    "LABELLE_ZIG",
    "LABELLE_ZIG_SEED",
    "LABELLE_ZIG_SEED_SIG",
    "LABELLE_ASSEMBLER",
    "LABELLE_SHADERC",
    "LABELLE_NO_PREBUILD",
    "LABELLE_PREBUILD_FORCE_RELAY",
    "LABELLE_PROGRESS_DEBUG",
    "LABELLE_ALLOW_OLDER_CLI",
    // Test-only: shortens the headless default timeout (cli#485).
    "LABELLE_TEST_HEADLESS_DEFAULT_TIMEOUT",
    // Set by the CLI for the game it launches (the `labelle run` options).
    "LABELLE_SCENE",
    "LABELLE_PROFILE",
    "LABELLE_SCREENSHOT_PATH",
    "LABELLE_SCREENSHOT_AFTER_SEC",
    "LABELLE_HEADLESS",
    "LABELLE_HEADLESS_UNCAPPED",
    "LABELLE_HEADLESS_TICKS",
};

/// `LABELLE_*` names the CLI source spells that a provider MAY set, each
/// with the reason it is not CLI-owned. Kept beside `reserved_env` so the
/// guard can tell a deliberate decision from a forgotten name.
pub const unreserved_labelle_env = [_][]const u8{
    // The SDL2 library directory. The CLI reads it only to find a user's
    // install; a package that provisions SDL2 is meant to set it for the
    // build (RFC cli#466 §9).
    "LABELLE_SDL2_LIB",
    // Written into a bundle's launcher script for the game; never read by
    // the CLI.
    "LABELLE_DATA_DIR",
};

/// True when an `env_file` may not set `name`. Under Windows rules names
/// compare case-insensitively (`Path` is `PATH`), as the host does.
pub fn reservedEnvName(name: []const u8, windows: bool) bool {
    for (reserved_env) |reserved| {
        if (if (windows) std.ascii.eqlIgnoreCase(name, reserved) else std.mem.eql(u8, name, reserved)) return true;
    }
    return false;
}

test "provider env reserved names: a fixed CLI-owned table, case-folded under Windows rules only" {
    for ([_][]const u8{ "PATH", "ZIG_GLOBAL_CACHE_DIR", "ZIG_LOCAL_CACHE_DIR", "LABELLE_HOME", "LABELLE_CONTEXT", "LABELLE_OFFLINE", "LABELLE_ZIG", "LABELLE_ASSEMBLER" }) |name| {
        try std.testing.expect(reservedEnvName(name, false));
        try std.testing.expect(reservedEnvName(name, true));
    }
    // Not a prefix ban: the SDL2 library variable and any other name stay
    // settable, and an env_file setting it parses.
    for ([_][]const u8{ "LABELLE_SDL2_LIB", "LABELLE_ANYTHING", "TOOLCHAIN_ROOT" }) |name| {
        try std.testing.expect(!reservedEnvName(name, false));
        try std.testing.expect(!reservedEnvName(name, true));
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: @import("provider_env.zig").Diagnostic = .{};
    const file = try @import("provider_env.zig").parseFile(arena.allocator(), "{\"set\":[{\"name\":\"LABELLE_SDL2_LIB\",\"value\":\"/sdl/lib\"}]}", false, &diag);
    try std.testing.expectEqualStrings("LABELLE_SDL2_LIB", file.set[0].name);
    // `Path` is PATH under Windows rules only.
    try std.testing.expect(reservedEnvName("Path", true));
    try std.testing.expect(!reservedEnvName("Path", false));
    // The two tables never overlap.
    for (unreserved_labelle_env) |name| try std.testing.expect(!reservedEnvName(name, true));
}

/// Every `"LABELLE_<NAME>"` string literal in `bytes`, appended to `out`.
fn collectLabelleLiterals(a: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList([]const u8)) !void {
    const prefix = "\"LABELLE_";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, i, prefix)) |start| {
        var end = start + prefix.len;
        while (end < bytes.len and (std.ascii.isUpper(bytes[end]) or std.ascii.isDigit(bytes[end]) or bytes[end] == '_')) end += 1;
        i = end;
        if (end == start + prefix.len or end >= bytes.len or bytes[end] != '"') continue;
        const name = bytes[start + 1 .. end];
        const seen = for (out.items) |known| {
            if (std.mem.eql(u8, known, name)) break true;
        } else false;
        if (!seen) try out.append(a, try a.dupe(u8, name));
    }
}

test "provider env reserved names: every LABELLE_* name the CLI spells is classified, and no entry is stale" {
    // The guard for `reserved_env`: a new CLI-read `LABELLE_*` variable must
    // be added to the table (or, deliberately, to `unreserved_labelle_env`)
    // before this passes. The tables themselves (this file) are not scanned,
    // so an entry nothing else spells any more is caught as stale.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = globalIo();
    var src = try std.Io.Dir.cwd().openDir(io, @import("test_fixtures").src_dir, .{ .iterate = true });
    defer src.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var files: usize = 0;
    var walker = try src.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const rel = try std.mem.replaceOwned(u8, a, entry.path, "\\", "/");
        if (std.mem.eql(u8, rel, "cli/config.zig")) continue;
        files += 1;
        try collectLabelleLiterals(a, try entry.dir.readFileAlloc(io, entry.basename, a, .limited(4 << 20)), &names);
    }
    // The walk reached the tree (a wrong directory would pass vacuously).
    try std.testing.expect(files > 100);
    var unclassified = false;
    for (names.items) |name| {
        var known = false;
        for (reserved_env) |r| known = known or std.mem.eql(u8, r, name);
        for (unreserved_labelle_env) |u| known = known or std.mem.eql(u8, u, name);
        if (!known) {
            std.debug.print("config.zig: '{s}' is spelled by the CLI but is in neither reserved_env nor unreserved_labelle_env\n", .{name});
            unclassified = true;
        }
    }
    var stale = false;
    for (reserved_env ++ unreserved_labelle_env) |entry| {
        if (!std.mem.startsWith(u8, entry, "LABELLE_")) continue;
        var found = false;
        for (names.items) |name| found = found or std.mem.eql(u8, name, entry);
        if (!found) {
            std.debug.print("config.zig: '{s}' is classified but no longer spelled anywhere in src/; remove it\n", .{entry});
            stale = true;
        }
    }
    try std.testing.expect(!unclassified and !stale);
}

test "provider env reserved names: the literal scanner finds whole quoted names only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    try collectLabelleLiterals(a, "get(\"LABELLE_ONE\") \"LABELLE_TWO=x\" LABELLE_THREE \"LABELLE_\" \"LABELLE_ONE\" \"LABELLE_FOUR_4\"", &names);
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("LABELLE_ONE", names.items[0]);
    try std.testing.expectEqualStrings("LABELLE_FOUR_4", names.items[1]);
}
