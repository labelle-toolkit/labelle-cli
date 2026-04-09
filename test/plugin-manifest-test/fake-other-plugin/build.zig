const std = @import("std");

/// Second fake plugin for the plugin-manifest system test. Lives
/// alongside fake-fsm-plugin/ so the CI cross-plugin duplicate test
/// can temporarily have two plugins claim the same directory name
/// and confirm the generator rejects the collision.
///
/// Ships no plugin.labelle by default — the CI step writes one when
/// it wants to exercise the duplicate path.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("other_plugin", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
}
