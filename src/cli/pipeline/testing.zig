//! Helpers shared by the pipeline's watched-rebuild tests
//! (`watch.zig`, `watch_replan_tests.zig`).
const std = @import("std");
const provider_hooks = @import("../provider_hooks.zig");
const config = @import("../config.zig");
const assembler_describe = @import("../assembler_describe.zig");

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
        // A watched rebuild runs under `labelle run`.
        .final_step = .run,
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

/// A `describe` that reads the project the way the assembler would, for the
/// watch-session tests (cli#471 D4: the session's backend is describe's
/// answer). The backend is `null` when `project.labelle` spells
/// `.backend = .null`, else `probe`; the target dir follows it.
pub fn fakeDescriber(project: []const u8) assembler_describe.Describer {
    return .{ .bin_path = "fake-assembler", .protocol = assembler_describe.min_protocol, .project_dir = project, .spawn = fakeDescribe };
}

fn fakeDescribe(arena: std.mem.Allocator, argv: []const []const u8) ?[]const u8 {
    // argv: <bin> describe --project-root <P> --target <T> --json
    const path = std.fs.path.join(arena, &.{ argv[3], "project.labelle" }) catch return null;
    const text = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, arena, .limited(1 << 20)) catch return null;
    const backend: []const u8 = if (std.mem.indexOf(u8, text, ".backend = .null") != null) "null" else "probe";
    return std.fmt.allocPrint(arena,
        \\{{"schema":"labelle.describe/v1","target":"{s}","target_dir":".labelle/{s}_{s}","backend":{{"name":"{s}","id":null,"repo":null,"version":null,"local_path":null}},"asset_format":"png","supported":true}}
    , .{ argv[5], backend, argv[5], backend }) catch null;
}
