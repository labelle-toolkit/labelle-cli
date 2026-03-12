const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Sokol backend dependency (parent package) ─────────────────────
    const sokol_backend = b.dependency("labelle_sokol", .{
        .target = target,
        .optimize = optimize,
    });

    // ── Native sokol C library (needed for linking) ──────────────────
    const sokol_clib = sokol_backend.artifact("sokol_clib");

    // ── Build the example executable ─────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "sokol-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gfx", .module = sokol_backend.module("gfx") },
                .{ .name = "input", .module = sokol_backend.module("input") },
                .{ .name = "audio", .module = sokol_backend.module("audio") },
                .{ .name = "window", .module = sokol_backend.module("window") },
            },
        }),
    });

    // Link the native sokol C library
    exe.linkLibrary(sokol_clib);

    b.installArtifact(exe);

    // ── Run step ─────────────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the Sokol backend demo");
    run_step.dependOn(&run_cmd.step);
}
