const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Fetch the bgfx backend dependency ──────────────────────────────
    const bgfx_backend = b.dependency("labelle_bgfx", .{
        .target = target,
        .optimize = optimize,
    });

    // ── Build the example executable ───────────────────────────────────
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("gfx", bgfx_backend.module("gfx"));
    exe_mod.addImport("input", bgfx_backend.module("input"));
    exe_mod.addImport("audio", bgfx_backend.module("audio"));
    exe_mod.addImport("window", bgfx_backend.module("window"));

    const exe = b.addExecutable(.{
        .name = "bgfx-example",
        .root_module = exe_mod,
    });

    // Link native libraries re-exported by the backend
    exe.linkLibrary(bgfx_backend.artifact("bgfx"));
    exe.linkLibrary(bgfx_backend.artifact("glfw"));

    b.installArtifact(exe);

    // ── Run step ───────────────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the bgfx backend demo");
    run_step.dependOn(&run_cmd.step);
}
