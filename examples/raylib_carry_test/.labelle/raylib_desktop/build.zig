const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_dep = b.dependency("labelle_core", .{ .target = target, .optimize = optimize });
    const core_mod = core_dep.module("labelle-core");

    const gfx_dep = b.dependency("labelle_gfx", .{ .target = target, .optimize = optimize });
    const gfx_mod = gfx_dep.module("labelle-gfx");

    const engine_dep = b.dependency("engine", .{ .target = target, .optimize = optimize });
    const engine_mod = engine_dep.module("engine");

    // Deduplicate labelle-core across gfx and engine — ensures a single core
    // module in the build, preventing diamond dependency version mismatches.
    gfx_mod.addImport("labelle-core", core_mod);
    engine_mod.addImport("labelle-core", core_mod);
    engine_mod.addImport("labelle-gfx", gfx_mod);

    const backend_dep = b.dependency("labelle_raylib", .{ .target = target, .optimize = optimize });
    const backend_gfx = backend_dep.module("gfx");
    const backend_input = backend_dep.module("input");
    const backend_audio = backend_dep.module("audio");
    const backend_window = backend_dep.module("window");
    const raylib_artifact = backend_dep.artifact("raylib");

    const ecs_dep = b.dependency("labelle_zig_ecs", .{ .target = target, .optimize = optimize });
    const ecs_mod = ecs_dep.module("ecs");

    const exe = b.addExecutable(.{
        .name = "game",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-core", .module = core_mod },
                .{ .name = "labelle-gfx", .module = gfx_mod },
                .{ .name = "labelle-engine", .module = engine_mod },
                .{ .name = "backend_gfx", .module = backend_gfx },
                .{ .name = "backend_input", .module = backend_input },
                .{ .name = "backend_audio", .module = backend_audio },
                .{ .name = "backend_window", .module = backend_window },

                .{ .name = "ecs_backend", .module = ecs_mod },

            },
        }),
    });

    exe.linkLibrary(raylib_artifact);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the game");
    run_step.dependOn(&run_cmd.step);
}
