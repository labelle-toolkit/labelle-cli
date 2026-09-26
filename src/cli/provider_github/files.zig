//! Filesystem helpers shared by the provider_github modules: bounded reads,
//! the cache root, unique temp names, atomic writes and SHA-256 hex digests.
const std = @import("std");
const config = @import("../config.zig");
const cache = @import("../asm_cache.zig");

pub fn read(a: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, a, .limited(limit));
}

pub fn cacheRoot(a: std.mem.Allocator) ![]const u8 {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), ".", a);
    return std.fs.path.resolve(a, &.{ cwd, try cache.getCacheRoot(a) });
}

pub fn uniqueName(a: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    var random: [16]u8 = undefined;
    config.globalIo().random(&random);
    return std.fmt.allocPrint(a, "{s}-{s}", .{ prefix, std.fmt.bytesToHex(random, .lower) });
}

pub fn sha256Hex(a: std.mem.Allocator, data: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

pub fn writeAtomically(a: std.mem.Allocator, dest: []const u8, data: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const temp = try uniqueName(a, dest);
    defer cwd.deleteFile(io, temp) catch {};
    try cwd.writeFile(io, .{ .sub_path = temp, .data = data });
    try std.Io.Dir.renameAbsolute(temp, dest, io);
}
