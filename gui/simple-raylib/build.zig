const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib_dep = b.dependency("raylib-zig", .{ .target = target, .optimize = optimize });
    const raylib_mod = raylib_dep.module("raylib");

    const gui_mod = b.addModule("gui", .{
        .root_source_file = b.path("src/adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_mod.addImport("raylib", raylib_mod);
}
