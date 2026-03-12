const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zclay_dep = b.dependency("zclay", .{ .target = target, .optimize = optimize });

    const gui_mod = b.addModule("gui", .{
        .root_source_file = b.path("src/adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_mod.addImport("zclay", zclay_dep.module("zclay"));
}
