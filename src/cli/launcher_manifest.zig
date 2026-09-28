/// Minimal parser for project.labelle that reads ONLY launcher-relevant fields.
///
/// The launcher must NOT depend on the full ProjectConfig schema so that it
/// can work across assembler versions — new config fields added later won't
/// break older CLIs. We achieve this by using `ignore_unknown_fields = true`
/// in the ZON parser.
const std = @import("std");
const config = @import("config.zig");

pub const LauncherManifest = struct {
    assembler_version: ?[]const u8 = null,
    /// Explicit managed-Zig pin (labelle-cli#279). When set, it is the
    /// highest-precedence *version* source (below only the LABELLE_ZIG /
    /// `--zig` path overrides). See `zig_toolchain.resolveRequiredVersion`.
    zig_version: ?[]const u8 = null,
    /// Pinned engine version — the CLI derives the required Zig from it when
    /// no explicit `zig_version` is set (`zig_toolchain.zigVersionForEngine`).
    engine_version: ?[]const u8 = null,
};

/// Read and parse project.labelle into a LauncherManifest.
/// Unknown fields are silently ignored.
/// Returns null if the file does not exist (no project.labelle).
pub fn readLauncherManifest(allocator: std.mem.Allocator, project_dir: []const u8) !?LauncherManifest {
    @setEvalBranchQuota(10000);
    const labelle_path = try std.fs.path.join(allocator, &.{ project_dir, "project.labelle" });
    defer allocator.free(labelle_path);

    const source_raw = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), labelle_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(source_raw);

    const source = try allocator.dupeZ(u8, source_raw);
    defer allocator.free(source);

    return std.zon.parse.fromSliceAlloc(LauncherManifest, allocator, source, null, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("labelle: could not parse launcher manifest from project.labelle: {any}\n", .{err});
        return error.ParseError;
    };
}
