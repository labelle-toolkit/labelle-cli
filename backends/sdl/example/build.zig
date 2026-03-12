const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The SDL backend is declared as a dependency in build.zig.zon.
    const sdl_dep = b.dependency("sdl_backend", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "sdl-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gfx", .module = sdl_dep.module("gfx") },
                .{ .name = "input", .module = sdl_dep.module("input") },
                .{ .name = "audio", .module = sdl_dep.module("audio") },
                .{ .name = "window", .module = sdl_dep.module("window") },
                .{ .name = "sdl", .module = sdl_dep.module("sdl") },
            },
        }),
    });

    // SDL2 is linked transitively via the sdl module's @cImport.
    // SDL2_mixer and Cocoa must be linked explicitly on the exe.
    exe.root_module.linkSystemLibrary("SDL2_mixer", .{});
    exe.root_module.linkFramework("Cocoa", .{});
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the SDL2 backend demo");
    run_step.dependOn(&run_cmd.step);
}
