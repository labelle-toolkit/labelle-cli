//! Shader execution/caching lives in the generated Zig graph. The CLI only
//! preflights an explicit host-tool override; normal builds provision it there.
const std = @import("std");
const config = @import("config.zig");
pub fn validateOverridePath(path: []const u8) !void {
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return error.ShadercOverrideMustBeAbsolute;
}
pub fn preflight(a: std.mem.Allocator, project_dir: []const u8) !void {
    const path = config.globalEnviron().getAlloc(a, "LABELLE_SHADERC") catch return;
    defer a.free(path);
    const materials = try std.fs.path.join(a, &.{ project_dir, "materials" });
    defer a.free(materials);
    var dir = std.Io.Dir.cwd().openDir(config.globalIo(), materials, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    dir.close(config.globalIo());
    validateOverridePath(path) catch |err| {
        std.debug.print("labelle: LABELLE_SHADERC must be an absolute path to the host shaderc executable; unset it to build the pinned compiler automatically\n", .{});
        return err;
    };
    std.Io.Dir.cwd().access(config.globalIo(), path, .{}) catch |err| {
        std.debug.print("labelle: LABELLE_SHADERC '{s}' is unavailable ({s}); unset it to build the pinned compiler automatically\n", .{ path, @errorName(err) });
        return error.ShadercOverrideUnavailable;
    };
}
test "shader tool override cannot depend on changed generated working directory" {
    try std.testing.expectError(error.ShadercOverrideMustBeAbsolute, validateOverridePath("shaderc"));
    try std.testing.expectError(error.ShadercOverrideMustBeAbsolute, validateOverridePath(""));
    try validateOverridePath(if (@import("builtin").os.tag == .windows) "C:/tools/shaderc.exe" else "/tools/shaderc");
}
