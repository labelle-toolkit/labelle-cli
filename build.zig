const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Version from build.zig.zon, overridable via -Dversion (used by CI release)
    const version: []const u8 = b.option([]const u8, "version", "Override version string (e.g. from git tag)") orelse @import("build.zig.zon").version;

    // Library versions from versions.zon — the tested compatible set for this CLI release
    const versions = @import("versions.zon");

    // ── Generator module from labelle-assembler ─────────────────────
    // Pulled via the labelle_assembler Zig package dep declared in
    // build.zig.zon. The module exposes the same types/functions the
    // CLI used to read from a hand-synced mirror at ./generator (see
    // #151 and #132 for the history).
    const gen_dep = b.dependency("labelle_assembler", .{
        .target = target,
        .optimize = optimize,
        .cli_version = @as([]const u8, version),
        .core_version = @as([]const u8, versions.core),
        .engine_version = @as([]const u8, versions.engine),
        .gfx_version = @as([]const u8, versions.gfx),
    });
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
    // stb_image for the pre-bake step (PNG → LRGBA). Header-only .h
    // paired with an implementation .c that instantiates the symbols.
    gen_exe.root_module.addCSourceFile(.{
        .file = b.path("src/cli/stb_image_impl.c"),
        .flags = &.{"-std=c99"},
    });
    gen_exe.root_module.addIncludePath(b.path("src/cli"));
    gen_exe.root_module.link_libc = true;
    b.installArtifact(gen_exe);

    const gen_run = b.addRunArtifact(gen_exe);
    if (b.args) |args| {
        gen_run.addArgs(args);
    }
    const gen_step = b.step("generate", "Generate assembler from project.labelle");
    gen_step.dependOn(&gen_run.step);

    // ── Tests ────────────────────────────────────────────────────────
    const zspec_dep = b.dependency("zspec", .{ .target = target, .optimize = optimize });

    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "generator", .module = gen_mod },
                .{ .name = "zspec", .module = zspec_dep.module("zspec") },
            },
        }),
    });
    // Test binary imports the same modules as `gen_exe`, including
    // `bake.zig` which `@cImport`s stb_image. Reproduce the stb
    // wiring so the test build finds the header and links libc.
    cli_tests.root_module.addCSourceFile(.{
        .file = b.path("src/cli/stb_image_impl.c"),
        .flags = &.{"-std=c99"},
    });
    cli_tests.root_module.addIncludePath(b.path("src/cli"));
    cli_tests.root_module.link_libc = true;
    const run_cli_tests = b.addRunArtifact(cli_tests);
    const test_step = b.step("test", "Run CLI unit tests");
    test_step.dependOn(&run_cli_tests.step);
}
