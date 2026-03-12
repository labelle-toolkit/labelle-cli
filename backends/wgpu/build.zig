const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wgpu_dep = b.dependency("wgpu_native_zig", .{ .target = target, .optimize = optimize });
    const zglfw_dep = b.dependency("zglfw", .{ .target = target, .optimize = optimize });

    const wgpu_mod = wgpu_dep.module("wgpu");
    const zglfw_mod = zglfw_dep.module("zglfw");
    const glfw_artifact = zglfw_dep.artifact("glfw");

    // ── Gfx backend module ──────────────────────────────────────────
    const gfx_mod = b.addModule("gfx", .{
        .root_source_file = b.path("src/gfx.zig"),
        .target = target,
        .optimize = optimize,
    });
    gfx_mod.addImport("wgpu", wgpu_mod);

    // ── Input backend module ────────────────────────────────────────
    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_mod.addImport("zglfw", zglfw_mod);

    // ── Audio backend module ────────────────────────────────────────
    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = audio_mod; // No native audio dep — uses miniaudio or stub

    // ── Window backend module ───────────────────────────────────────
    const window_mod = b.addModule("window", .{
        .root_source_file = b.path("src/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_mod.addImport("zglfw", zglfw_mod);
    window_mod.addImport("wgpu", wgpu_mod);

    // ── Re-export native artifacts so consumers can link them ───────
    b.installArtifact(glfw_artifact);
}
