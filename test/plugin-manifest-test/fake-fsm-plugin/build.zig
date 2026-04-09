const std = @import("std");

/// Minimal build.zig for the plugin-manifest system test's fake plugin.
/// Exposes a no-op module so the deps_linker has something to hardlink
/// when the game project declares this plugin.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("fsm_test", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
}
