const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ecs_dep = b.dependency("zig_ecs", .{ .target = target, .optimize = optimize });
    const ecs_mod = ecs_dep.module("zig-ecs");

    const adapter_mod = b.addModule("ecs", .{
        .root_source_file = b.path("src/adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    adapter_mod.addImport("zig-ecs", ecs_mod);
}
