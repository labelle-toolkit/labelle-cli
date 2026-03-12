const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl_include = std.Build.LazyPath{ .cwd_relative = "/opt/homebrew/include" };
    const sdl_lib = std.Build.LazyPath{ .cwd_relative = "/opt/homebrew/lib" };

    // Shared SDL2 C import module — ensures a single set of opaque types.
    // Only include/library *paths* are set here for @cImport resolution.
    // Actual linkSystemLibrary calls are deferred to the final executable
    // to prevent duplicate dylib entries when multiple modules import sdl.
    const sdl_mod = b.addModule("sdl", .{
        .root_source_file = b.path("src/sdl.zig"),
        .target = target,
        .optimize = optimize,
    });
    sdl_mod.addIncludePath(sdl_include);
    sdl_mod.addLibraryPath(sdl_lib);

    // ── Gfx backend module ──────────────────────────────────────────
    const gfx_mod = b.addModule("gfx", .{
        .root_source_file = b.path("src/gfx.zig"),
        .target = target,
        .optimize = optimize,
    });
    gfx_mod.addImport("sdl", sdl_mod);

    // ── Input backend module ────────────────────────────────────────
    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_mod.addImport("sdl", sdl_mod);

    // ── Audio backend module ────────────────────────────────────────
    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_mod.addImport("sdl", sdl_mod);
    audio_mod.addIncludePath(sdl_include);
    audio_mod.addLibraryPath(sdl_lib);

    // ── Window backend module ───────────────────────────────────────
    const window_mod = b.addModule("window", .{
        .root_source_file = b.path("src/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_mod.addImport("sdl", sdl_mod);
    window_mod.addImport("gfx", gfx_mod);
    window_mod.addImport("input", input_mod);
    window_mod.addImport("audio", audio_mod);
}
