const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Parser module
    const parser_mod = b.createModule(.{
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Parser tests
    const parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_parser_tests = b.addRunArtifact(parser_tests);

    // Deserialize tests
    const deserialize_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/deserialize.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_deserialize_tests = b.addRunArtifact(deserialize_tests);

    // Scene loader tests
    const scene_loader_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/scene_loader.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_scene_loader_tests = b.addRunArtifact(scene_loader_tests);

    // JSONC parser tests
    const jsonc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/jsonc_parser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_jsonc_tests = b.addRunArtifact(jsonc_tests);

    // Hot reload tests
    const hot_reload_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hot_reload.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_hot_reload_tests = b.addRunArtifact(hot_reload_tests);

    // Game state tests
    const game_state_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/game_state.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_game_state_tests = b.addRunArtifact(game_state_tests);

    // Script scanner tests
    const script_scanner_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/script_scanner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_script_scanner_tests = b.addRunArtifact(script_scanner_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_parser_tests.step);
    test_step.dependOn(&run_deserialize_tests.step);
    test_step.dependOn(&run_scene_loader_tests.step);
    test_step.dependOn(&run_jsonc_tests.step);
    test_step.dependOn(&run_hot_reload_tests.step);
    test_step.dependOn(&run_game_state_tests.step);
    test_step.dependOn(&run_script_scanner_tests.step);

    // CLI demo
    const demo = b.addExecutable(.{
        .name = "zon-parse-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "parser", .module = parser_mod },
            },
        }),
    });
    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    if (b.args) |args| {
        run_demo.addArgs(args);
    }
    const run_step = b.step("run", "Parse a .zon file from disk");
    run_step.dependOn(&run_demo.step);
}
