const std = @import("std");
const gen = @import("generator");

/// Process-wide Io handle used by helpers in cli/* that historically
/// used `std.fs.cwd()` (which no longer exists on 0.16). Must be
/// initialized from `main()` by calling `initGlobalIo()` with the
/// process-level setup in main().
var _global_threaded: std.Io.Threaded = undefined;
var _global_io: std.Io = undefined;
const GlobalEnviron = struct {
    pub fn getAlloc(_: @This(), allocator: std.mem.Allocator, key: []const u8) ![]u8 {
        return std.process.getEnvVarOwned(allocator, key);
    }
};
var _global_environ: GlobalEnviron = .{};

/// Initialize the process-wide Io. Call once from main() before any
/// helper accesses globalIo().
pub fn initGlobalIo() void {
    _global_threaded = std.Io.Threaded.init(std.heap.page_allocator);
    _global_io = _global_threaded.io();
}

pub fn globalIo() std.Io {
    return _global_io;
}

pub fn globalEnviron() GlobalEnviron {
    return _global_environ;
}

pub fn readProjectConfig(allocator: std.mem.Allocator, project_dir: []const u8) !gen.ProjectConfig {
    return readProjectConfigImpl(allocator, project_dir, true);
}

/// Same as readProjectConfig but without printing error messages.
/// Used by commands where a missing project.labelle is expected (e.g. clean).
pub fn readProjectConfigQuiet(allocator: std.mem.Allocator, project_dir: []const u8) !gen.ProjectConfig {
    return readProjectConfigImpl(allocator, project_dir, false);
}

fn readProjectConfigImpl(allocator: std.mem.Allocator, project_dir: []const u8, verbose: bool) !gen.ProjectConfig {
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

    return std.zon.parse.fromSliceAlloc(gen.ProjectConfig, allocator, source, null, .{}) catch |err| {
        if (verbose) std.debug.print("labelle: could not parse '{s}': {any}\n", .{ labelle_path, err });
        return error.ParseError;
    };
}
