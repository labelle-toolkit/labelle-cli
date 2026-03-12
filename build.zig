const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Core dependencies ──────────────────────────────────────────────
    const core_dep = b.dependency("labelle_core", .{ .target = target, .optimize = optimize });
    const core_mod = core_dep.module("labelle-core");

    const gfx_dep = b.dependency("labelle_gfx", .{ .target = target, .optimize = optimize });
    const gfx_mod = gfx_dep.module("labelle-gfx");

    const engine_dep = b.dependency("engine", .{ .target = target, .optimize = optimize });
    const engine_mod = engine_dep.module("engine");

    const physics_dep = b.dependency("labelle_physics", .{ .target = target, .optimize = optimize });
    const physics_mod = physics_dep.module("labelle-physics");

    // Game module — hooks are the game's wiring entry point
    const game_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "../game/hooks/game_hooks.zig" },
        .target = target,
        .optimize = optimize,
    });
    game_mod.addImport("engine", engine_mod);

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "labelle-core", .module = core_mod },
        .{ .name = "labelle-gfx", .module = gfx_mod },
        .{ .name = "engine", .module = engine_mod },
        .{ .name = "labelle-physics", .module = physics_mod },
    };

    // ── CLI executable (mock-only, zero native deps) ───────────────────
    const exe = b.addExecutable(.{
        .name = "labelle-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the assembler demo");
    run_step.dependOn(&run_cmd.step);

    // ── Tests (mock-only, zero native deps) ─────────────────────────
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });

    const game_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/game_compile_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-core", .module = core_mod },
                .{ .name = "labelle-gfx", .module = gfx_mod },
                .{ .name = "engine", .module = engine_mod },
                .{ .name = "game", .module = game_mod },
            },
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const run_game_tests = b.addRunArtifact(game_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_game_tests.step);

    // ── Generator CLI ───────────────────────────────────────────────
    const gen_dep = b.dependency("generator", .{ .target = target, .optimize = optimize });
    const gen_mod = gen_dep.module("generator");

    const gen_exe = b.addExecutable(.{
        .name = "labelle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "generator", .module = gen_mod },
            },
        }),
    });
    b.installArtifact(gen_exe);

    const gen_run = b.addRunArtifact(gen_exe);
    if (b.args) |args| {
        gen_run.addArgs(args);
    }
    const gen_step = b.step("generate", "Generate assembler from project.labelle");
    gen_step.dependOn(&gen_run.step);
}
