const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zcs_dep = b.dependency("zcs", .{ .target = target, .optimize = optimize });

    const ecs_mod = b.addModule("ecs", .{
        .root_source_file = b.path("src/adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    ecs_mod.addImport("mr_ecs", zcs_dep.module("zcs"));
}
