const std = @import("std");

/// Bridge between Nuklear and raylib.
/// Renders Nuklear's command buffer using raylib draw calls and feeds
/// raylib input into Nuklear. Does NOT own either dependency.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib_dep = b.dependency("raylib-zig", .{ .target = target, .optimize = optimize });
    const raylib_mod = raylib_dep.module("raylib");
    const raylib_artifact = raylib_dep.artifact("raylib");

    const nk_dep = b.dependency("nuklear", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .default_font = true,
        .font_baking = true,
        .no_stb_rect_pack = true, // raylib provides stb_rect_pack
    });
    const nk_mod = nk_dep.module("nuklear");
    const nk_lib = nk_dep.artifact("nuklear");

    // Bridge module — Zig code that implements nk_bridge_* exports
    const bridge_mod = b.addModule("bridge", .{
        .root_source_file = b.path("src/bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    bridge_mod.addImport("nuklear", nk_mod);
    bridge_mod.addImport("raylib", raylib_mod);

    // Static library that exports the nk_bridge_* symbols
    const bridge_lib = b.addLibrary(.{
        .name = "nuklear_raylib_bridge",
        .root_module = bridge_mod,
        .linkage = .static,
    });
    bridge_lib.linkLibrary(nk_lib);
    bridge_lib.linkLibrary(raylib_artifact);

    b.installArtifact(bridge_lib);
}
