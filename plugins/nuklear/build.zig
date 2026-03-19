const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nk_dep = b.dependency("nuklear", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .default_font = true,
        .font_baking = true,
        .vertex_backend = true,
        .no_stb_rect_pack = true, // avoid duplicate symbols when linked with raylib
    });

    const nk_mod = nk_dep.module("nuklear");

    // GUI adapter module — satisfies GuiInterface contract.
    const gui_mod = b.addModule("gui", .{
        .root_source_file = b.path("src/adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_mod.addImport("nuklear", nk_mod);

    // Re-export nuklear module for game code
    _ = b.addModule("nuklear", .{
        .root_source_file = nk_mod.root_source_file.?,
        .target = target,
        .optimize = optimize,
    });

    // Re-export nuklear artifact so bridge can link
    const nk_lib = nk_dep.artifact("nuklear");
    b.installArtifact(nk_lib);
}
