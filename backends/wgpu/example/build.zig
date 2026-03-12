const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Fetch the WebGPU backend package (parent directory) ───────────
    const wgpu_backend = b.dependency("labelle_wgpu", .{
        .target = target,
        .optimize = optimize,
    });

    // ── Build the example executable ─────────────────────────────────
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("gfx", wgpu_backend.module("gfx"));
    exe_mod.addImport("input", wgpu_backend.module("input"));
    exe_mod.addImport("audio", wgpu_backend.module("audio"));
    exe_mod.addImport("window", wgpu_backend.module("window"));

    const exe = b.addExecutable(.{
        .name = "wgpu-demo",
        .root_module = exe_mod,
    });

    // Link native artifacts
    exe.linkLibrary(wgpu_backend.artifact("glfw"));
    exe.linkLibrary(wgpu_backend.artifact("zdawn"));

    // Dawn prebuilt library path (needed for libdawn native symbols)
    const target_result = target.result;
    if (target_result.os.tag == .macos) {
        if (target_result.cpu.arch.isAARCH64()) {
            const dawn = wgpu_backend.builder.dependency("dawn_aarch64_macos", .{});
            exe.addLibraryPath(dawn.path(""));
        } else if (target_result.cpu.arch.isX86()) {
            const dawn = wgpu_backend.builder.dependency("dawn_x86_64_macos", .{});
            exe.addLibraryPath(dawn.path(""));
        }
    }
    exe.linkSystemLibrary("dawn");

    b.installArtifact(exe);

    // ── Run step ─────────────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the WebGPU backend demo");
    run_step.dependOn(&run_cmd.step);
}
