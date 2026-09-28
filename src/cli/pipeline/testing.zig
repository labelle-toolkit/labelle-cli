//! Helpers shared by the pipeline's watched-rebuild tests
//! (`watch.zig`, `watch_replan_tests.zig`).
const std = @import("std");
const provider_hooks = @import("../provider_hooks.zig");

/// A hook site with no providers, for the rebuild tests: the plans are
/// what the tests supply; nothing here reaches a compiler or a lock.
pub fn testSite(a: std.mem.Allocator, project: []const u8) provider_hooks.Site {
    return .{
        .a = a,
        .backing = a,
        .providers = &.{},
        .root = project,
        .cfg = .{ .name = "game" },
        .target = "probe-target",
        .target_dir = project,
        .optimize = .ReleaseSafe,
        .progress = .off,
        .reporter = null,
    };
}

/// An executable that ignores its arguments and exits 0, written into
/// `dir`: an assembler and a compiler under which a whole rebuild
/// succeeds. POSIX only (a shell script); caller frees the path.
pub fn okTool(a: std.mem.Allocator, dir: std.Io.Dir) ![:0]u8 {
    return exitTool(a, dir, "ok-tool", 0);
}

/// `okTool` exiting `code` instead: a compile that fails.
pub fn exitTool(a: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, code: u8) ![:0]u8 {
    const io = @import("../config.zig").globalIo();
    var buf: [64]u8 = undefined;
    const script = try std.fmt.bufPrint(&buf, "#!/bin/sh\nexit {d}\n", .{code});
    try dir.writeFile(io, .{ .sub_path = name, .data = script, .flags = .{ .permissions = .executable_file } });
    return dir.realPathFileAlloc(io, name, a);
}
