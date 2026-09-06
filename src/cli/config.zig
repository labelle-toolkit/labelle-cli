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
    errdefer allocator.free(source);

    // `ignore_unknown_fields`: the CLI's `project_config.ProjectConfig`
    // is a deliberately minimal copy of the assembler's schema (#217).
    // The assembler owns the schema and may add fields the CLI does not
    // mirror — without this, a newer project.labelle would fail to parse
    // and break the CLI for no good reason.
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
