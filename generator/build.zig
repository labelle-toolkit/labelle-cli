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
