const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The generator executable that the CLI expects
    const generator = b.addExecutable(.{
        .name = "labelle-generate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generator.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(generator);

    // Also expose as a module (not required but good for completeness)
    _ = b.addModule("labelle-engine", .{
        .root_source_file = b.path("src/engine.zig"),
    });
}
