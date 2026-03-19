const std = @import("std");

/// Bridge between Dear ImGui (cimgui) and raylib via rlImGui.
///
/// This bridge compiles rlImGui.cpp as a C++ static library that links against
/// both raylib and cimgui. It does NOT own either dependency — it receives them
/// from the assembler, which means raylib and cimgui version independently.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_rlimgui = b.dependency("rlImGui", .{ .target = target, .optimize = optimize });

    // These are injected by the assembler — the bridge does not own them.
    // The assembler adds raylib and cimgui as dependencies when wiring the bridge.
    const raylib_artifact = b.dependency("raylib-zig", .{ .target = target, .optimize = optimize }).artifact("raylib");
    const cimgui_dep = b.dependency("cimgui", .{ .target = target, .optimize = optimize });

    const cimgui_conf = @import("cimgui").getConfig(false);
    const cimgui_artifact = cimgui_dep.artifact(cimgui_conf.clib_name);

    // Build rlImGui as a C++ static library
    const rlimgui_mod = b.addModule("mod_rlimgui_clib", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });

    rlimgui_mod.addCSourceFile(.{
        .file = dep_rlimgui.path("rlImGui.cpp"),
        .flags = &.{"-DNO_FONT_AWESOME"},
    });

    // Bridge wrapper: re-exports rlImGui functions under generic imgui_bridge_* names
    rlimgui_mod.addCSourceFile(.{
        .file = b.path("src/bridge.c"),
        .flags = &.{},
    });

    // Include paths: imgui headers from dcimgui, rlImGui's own headers
    rlimgui_mod.addIncludePath(cimgui_dep.path(cimgui_conf.include_dir));
    rlimgui_mod.addIncludePath(dep_rlimgui.path(""));

    // Link raylib and cimgui so rlImGui can find their symbols
    rlimgui_mod.linkLibrary(raylib_artifact);
    rlimgui_mod.linkLibrary(cimgui_artifact);

    const rlimgui_clib = b.addLibrary(.{
        .name = "rlimgui_bridge",
        .root_module = rlimgui_mod,
        .linkage = .static,
    });
    b.installArtifact(rlimgui_clib);
}
