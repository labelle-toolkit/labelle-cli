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

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/adapter_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ecs", .module = adapter_mod },
            },
        }),
    });
    const test_step = b.step("test", "Run adapter tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
