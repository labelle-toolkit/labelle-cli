const std = @import("std");

/// Re-export sokol's emscripten linker helpers so consumers (generated build.zig)
/// can use emLinkStep for WASM builds without a direct sokol dep.
pub const EmLinkOptions = @import("sokol").EmLinkOptions;
pub const emLinkStep = @import("sokol").emLinkStep;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Forward dont_link_system_libs for iOS builds — we link frameworks manually.
    const dont_link_system_libs = b.option(bool, "dont_link_system_libs", "Don't link system libraries (for iOS cross-compilation)") orelse false;

    const sokol_dep = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .dont_link_system_libs = dont_link_system_libs,
    });
    const sokol_mod = sokol_dep.module("sokol");
    const sokol_clib = sokol_dep.artifact("sokol_clib");

    // ── Gfx backend module ──────────────────────────────────────────
    const gfx_mod = b.addModule("gfx", .{
        .root_source_file = b.path("src/gfx.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    gfx_mod.addImport("sokol", sokol_mod);
    gfx_mod.addIncludePath(b.path("src"));
    gfx_mod.addCSourceFile(.{ .file = b.path("src/stb_image_impl.c"), .flags = &.{} });

    // ── Input backend module ────────────────────────────────────────
    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_mod.addImport("sokol", sokol_mod);

    // ── Audio backend module ────────────────────────────────────────
    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_mod.addImport("sokol", sokol_mod);

    // ── Window backend module ───────────────────────────────────────
    const window_mod = b.addModule("window", .{
        .root_source_file = b.path("src/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_mod.addImport("sokol", sokol_mod);

    // ── Re-export the native artifact so consumers can link it ──────
    b.installArtifact(sokol_clib);
}
