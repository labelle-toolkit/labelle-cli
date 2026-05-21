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
