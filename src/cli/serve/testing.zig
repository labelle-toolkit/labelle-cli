//! Test helpers shared by the `serve/` modules' tests.
const std = @import("std");

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
