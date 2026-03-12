const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Single source of truth: version from build.zig.zon
    const version: []const u8 = @import("build.zig.zon").version;

    // Library versions from versions.zon — the tested compatible set for this CLI release
    const versions = @import("versions.zon");

    // ── Generator CLI ───────────────────────────────────────────────
    const gen_dep = b.dependency("generator", .{
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
    b.installArtifact(gen_exe);

    const gen_run = b.addRunArtifact(gen_exe);
    if (b.args) |args| {
        gen_run.addArgs(args);
    }
    const gen_step = b.step("generate", "Generate assembler from project.labelle");
    gen_step.dependOn(&gen_run.step);
}
