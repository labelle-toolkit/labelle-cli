/// Minimal static file server for serving WASM builds locally.
/// Opens the default browser and serves files until interrupted.
///
/// TODO(zig-0.16): rewrite against `std.Io.net.IpAddress` and friends.
/// For the migration we stub this out — WASM serve is exercised by
/// `labelle run --platform=wasm`, not by `zig build` itself.
const std = @import("std");

/// Serve static files from `web_dir` on localhost:`port`, then open the browser.
pub fn serveAndOpen(allocator: std.mem.Allocator, web_dir: []const u8, port: u16) !void {
    _ = allocator;
    _ = port;
    std.debug.print(
        \\labelle: WASM serve is not yet ported to std.Io.net (Zig 0.16 migration).
        \\  Serve `{s}/zig-out/web/` manually with a static file server, e.g.
        \\    python3 -m http.server --directory <web_dir> 8080
        \\
    , .{web_dir});
    return error.NotImplemented;
}
