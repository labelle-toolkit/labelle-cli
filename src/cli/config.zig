const std = @import("std");
const gen = @import("generator");

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

    const source_raw = std.fs.cwd().readFileAlloc(allocator, labelle_path, 1024 * 1024) catch |err| {
        if (verbose) std.debug.print("labelle: could not read '{s}': {any}\n", .{ labelle_path, err });
        return error.FileNotFound;
    };
    defer allocator.free(source_raw);

    const source = try allocator.dupeZ(u8, source_raw);
    errdefer allocator.free(source);

    return std.zon.parse.fromSlice(gen.ProjectConfig, allocator, source, null, .{}) catch |err| {
        if (verbose) std.debug.print("labelle: could not parse '{s}': {any}\n", .{ labelle_path, err });
        return error.ParseError;
    };
}
