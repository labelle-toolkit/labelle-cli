const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cli_version: []const u8 = b.option([]const u8, "cli_version", "CLI version string") orelse "dev";
    const core_version: []const u8 = b.option([]const u8, "core_version", "Default core library version") orelse cli_version;
    const engine_version: []const u8 = b.option([]const u8, "engine_version", "Default engine library version") orelse cli_version;
    const gfx_version: []const u8 = b.option([]const u8, "gfx_version", "Default gfx library version") orelse cli_version;

    const zspec_dep = b.dependency("zspec", .{ .target = target, .optimize = optimize });

    const options = b.addOptions();
    options.addOption([]const u8, "cli_version", cli_version);
    options.addOption([]const u8, "core_version", core_version);
    options.addOption([]const u8, "engine_version", engine_version);
    options.addOption([]const u8, "gfx_version", gfx_version);

    const generator_module = b.addModule("generator", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    generator_module.addOptions("build_options", options);

    // ── Standalone assembler binary (Phase 1 of RFC #122) ───────────────
    // Coexists with the in-process module above. The `labelle` CLI still
    // imports the module directly today; this binary exposes the same
    // generator behind a subprocess protocol so future CLI versions can
    // invoke an out-of-process assembler pinned by `project.labelle`.
    const assembler_exe = b.addExecutable(.{
        .name = "labelle-assembler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    assembler_exe.root_module.addOptions("build_options", options);
    b.installArtifact(assembler_exe);

    const assembler_run = b.addRunArtifact(assembler_exe);
    if (b.args) |args| assembler_run.addArgs(args);
    const assembler_run_step = b.step("run-assembler", "Run the standalone labelle-assembler binary");
    assembler_run_step.dependOn(&assembler_run.step);

    // ── Tests ───────────────────────────────────────────────────────────
    const test_step = b.step("test", "Run generator tests");

    // Unit tests from src/
    const src_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    src_tests.root_module.addOptions("build_options", options);
    test_step.dependOn(&b.addRunArtifact(src_tests).step);

    // BDD-style tests from test/
    const test_files = [_][]const u8{
        "test/tests.zig",
        "test/script_scanner_tests.zig",
        "test/deps_linker_tests.zig",
        "test/template_dynamic_test.zig",
    };

    for (test_files) |test_file| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "generator", .module = generator_module },
                    .{ .name = "zspec", .module = zspec_dep.module("zspec") },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
