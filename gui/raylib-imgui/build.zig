const std = @import("std");
const cimgui = @import("cimgui");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cimgui_conf = cimgui.getConfig(false);

    const dep_raylib = b.dependency("raylib-zig", .{ .target = target, .optimize = optimize });
    const dep_cimgui = b.dependency("cimgui", .{ .target = target, .optimize = optimize });
    const dep_rlimgui = b.dependency("rlImGui", .{ .target = target, .optimize = optimize });

    const raylib_artifact = dep_raylib.artifact("raylib");
    const cimgui_artifact = dep_cimgui.artifact(cimgui_conf.clib_name);
    const raylib_mod = dep_raylib.module("raylib");
    const cimgui_mod = dep_cimgui.module(cimgui_conf.module_name);

    // Build rlImGui as a C++ library
    const rlimgui_mod = b.addModule("mod_rlimgui_clib", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    // Add rlImGui C++ source
    rlimgui_mod.addCSourceFile(.{
        .file = dep_rlimgui.path("rlImGui.cpp"),
        .flags = &.{"-DNO_FONT_AWESOME"},
    });

    // Include paths: imgui headers from dcimgui, rlImGui's own headers
    rlimgui_mod.addIncludePath(dep_cimgui.path(cimgui_conf.include_dir));
    rlimgui_mod.addIncludePath(dep_rlimgui.path(""));

    // Link raylib and cimgui so rlImGui can find their headers
    rlimgui_mod.linkLibrary(raylib_artifact);
    rlimgui_mod.linkLibrary(cimgui_artifact);

    const rlimgui_clib = b.addLibrary(.{
        .name = "rlimgui_clib",
        .root_module = rlimgui_mod,
        .linkage = .static,
    });
    b.installArtifact(rlimgui_clib);

    // GUI adapter module
    const gui_mod = b.addModule("gui", .{
        .root_source_file = b.path("src/adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_mod.addImport("cimgui", cimgui_mod);
    gui_mod.linkLibrary(rlimgui_clib);

    // Re-export raylib backend modules (using the same raylib dep)
    // to avoid module conflicts when the demo needs both raylib backends and imgui.
    const backend_root = "../../../backends/raylib/src";

    const gfx_mod = b.addModule("gfx", .{
        .root_source_file = b.path(backend_root ++ "/gfx.zig"),
        .target = target,
        .optimize = optimize,
    });
    gfx_mod.addImport("raylib", raylib_mod);

    const input_mod = b.addModule("input", .{
        .root_source_file = b.path(backend_root ++ "/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_mod.addImport("raylib", raylib_mod);

    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path(backend_root ++ "/audio.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_mod.addImport("raylib", raylib_mod);

    const window_mod = b.addModule("window", .{
        .root_source_file = b.path(backend_root ++ "/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_mod.addImport("raylib", raylib_mod);

    // Re-export the raylib artifact so consumers can link it
    b.installArtifact(raylib_artifact);
}
