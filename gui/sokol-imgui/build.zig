const std = @import("std");
const cimgui = @import("cimgui");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cimgui_conf = cimgui.getConfig(false);

    // Build sokol with imgui support enabled
    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .with_sokol_imgui = true,
    });

    const dep_cimgui = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    });

    // Inject the cimgui header search path into sokol's C library
    dep_sokol.artifact("sokol_clib").root_module.addIncludePath(dep_cimgui.path(cimgui_conf.include_dir));

    const sokol_mod = dep_sokol.module("sokol");
    const cimgui_mod = dep_cimgui.module(cimgui_conf.module_name);

    // GUI adapter module
    const gui_mod = b.addModule("gui", .{
        .root_source_file = b.path("src/adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_mod.addImport("sokol", sokol_mod);
    gui_mod.addImport("cimgui", cimgui_mod);

    // Re-export sokol backend modules (using the same sokol dep with imgui)
    // This avoids module conflicts when the demo needs both sokol backends and imgui.
    const backend_root = "../../../labelle-assembler/backends/sokol/src";

    const gfx_mod = b.addModule("gfx", .{
        .root_source_file = b.path(backend_root ++ "/gfx.zig"),
        .target = target,
        .optimize = optimize,
    });
    gfx_mod.addImport("sokol", sokol_mod);

    const input_mod = b.addModule("input", .{
        .root_source_file = b.path(backend_root ++ "/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_mod.addImport("sokol", sokol_mod);

    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path(backend_root ++ "/audio.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_mod.addImport("sokol", sokol_mod);

    const window_mod = b.addModule("window", .{
        .root_source_file = b.path(backend_root ++ "/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_mod.addImport("sokol", sokol_mod);

    // Re-export the sokol artifact (with imgui) so consumers can link it
    b.installArtifact(dep_sokol.artifact("sokol_clib"));
}
