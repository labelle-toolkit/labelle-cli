//! Test helpers shared by the `serve/` modules' tests.
const std = @import("std");
const tree = @import("tree.zig");
const TreeSignature = tree.TreeSignature;
const pathKey = tree.pathKey;

/// A distinct synthetic tree signature per label, for the baseline tests.
pub fn testSig(label: []const u8) TreeSignature {
    var sig = TreeSignature{};
    sig.mix(label, label.len, 0);
    return sig;
}

/// A scripted rebuild for the baseline tests: the sorted path keys that
/// changed while it ran.
pub fn testDelta(comptime paths: []const []const u8) [paths.len]u64 {
    var keys: [paths.len]u64 = undefined;
    for (paths, 0..) |path, i| keys[i] = pathKey(path);
    std.mem.sort(u64, &keys, {}, std.sort.asc(u64));
    return keys;
}

/// Bind 127.0.0.1 on the first free port in a fixed candidate range.
/// Avoids needing `getsockname` to discover a port-0 assignment —
/// that symbol isn't linked in Zig's Windows std, so the port-0 +
/// getsockname trick fails to compile on Windows.
pub fn testBindFreePort(io: std.Io) ?struct { server: std.Io.net.Server, port: u16 } {
    var port: u16 = 49500;
    while (port < 49600) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
        const server = addr.listen(io, .{ .reuse_address = true }) catch continue;
        return .{ .server = server, .port = port };
    }
    return null;
}
