const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zflecs_dep = b.dependency("zflecs", .{ .target = target, .optimize = optimize });
    const zflecs_mod = zflecs_dep.module("root");

    const adapter_mod = b.addModule("ecs", .{
        .root_source_file = b.path("src/adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    adapter_mod.addImport("zflecs", zflecs_mod);
}
