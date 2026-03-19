const std = @import("std");
const cimgui = @import("cimgui");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_cimgui = b.dependency("cimgui", .{ .target = target, .optimize = optimize });

    const cimgui_conf = cimgui.getConfig(false);
    const cimgui_mod = dep_cimgui.module(cimgui_conf.module_name);

    // GUI adapter module — satisfies GuiInterface contract.
    // Does NOT depend on any backend. The bridge wires the backend connection.
    const gui_mod = b.addModule("gui", .{
        .root_source_file = b.path("src/adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_mod.addImport("cimgui", cimgui_mod);

    // Re-export cimgui module so consumers (bridges, games) can use it
    _ = b.addModule("cimgui", .{
        .root_source_file = cimgui_mod.root_source_file.?,
        .target = target,
        .optimize = optimize,
    });

    // Re-export cimgui artifact so bridges can link against it
    const cimgui_artifact = dep_cimgui.artifact(cimgui_conf.clib_name);
    b.installArtifact(cimgui_artifact);
}
