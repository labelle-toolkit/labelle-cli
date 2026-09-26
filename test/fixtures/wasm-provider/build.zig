const std = @import("std");

/// The assembler wires a declared package as `b.dependency("labelle_<name>")
/// .module("labelle_<name>")`, so the module carries the package's zon name.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("labelle_wasm_fixture", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
}
