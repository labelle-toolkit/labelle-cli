/// Minimal parser for project.labelle that reads ONLY launcher-relevant fields.
///
/// The launcher must NOT depend on the full ProjectConfig schema so that it
/// can work across assembler versions — new config fields added later won't
/// break older CLIs. We achieve this by using `ignore_unknown_fields = true`
/// in the ZON parser.
const std = @import("std");

pub const LauncherManifest = struct {
    assembler_version: ?[]const u8 = null,
    // Future: zig_version, etc.
};

/// Read and parse project.labelle into a LauncherManifest.
/// Unknown fields are silently ignored.
/// Returns null if the file does not exist (no project.labelle).
pub fn readLauncherManifest(allocator: std.mem.Allocator, project_dir: []const u8) !?LauncherManifest {
    @setEvalBranchQuota(10000);
    const labelle_path = try std.fs.path.join(allocator, &.{ project_dir, "project.labelle" });
    defer allocator.free(labelle_path);

    const source_raw = std.fs.cwd().readFileAlloc(allocator, labelle_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(source_raw);

    const source = try allocator.dupeZ(u8, source_raw);
    defer allocator.free(source);

    return std.zon.parse.fromSlice(LauncherManifest, allocator, source, null, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("labelle: could not parse launcher manifest from project.labelle: {any}\n", .{err});
        return error.ParseError;
    };
}
