/// Minimal static file server for serving WASM builds locally.
/// Serves files from `web_dir` on 127.0.0.1:`port`, opens the default
/// browser, and runs until the process is interrupted (Ctrl+C).
///
/// Single-threaded, one connection at a time — a dev-only serve loop
/// for a single browser tab, not a production server. Built directly
/// on `std.Io.net.Server` (socket) + `std.http.Server` (HTTP/1.1) so
/// the CLI keeps a zero-dependency graph.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");

/// Extension → Content-Type. WASM and JS are the load-bearing ones:
/// browsers refuse to instantiate `application/wasm` served as
/// `application/octet-stream` via the streaming path, and ES modules
/// need a JS MIME type. The rest cover a typical asset bundle.
const mime_table = [_]struct { ext: []const u8, ct: []const u8 }{
    .{ .ext = ".wasm", .ct = "application/wasm" },
    .{ .ext = ".js", .ct = "text/javascript" },
    .{ .ext = ".mjs", .ct = "text/javascript" },
    .{ .ext = ".html", .ct = "text/html; charset=utf-8" },
    .{ .ext = ".css", .ct = "text/css" },
    .{ .ext = ".json", .ct = "application/json" },
    .{ .ext = ".png", .ct = "image/png" },
    .{ .ext = ".jpg", .ct = "image/jpeg" },
    .{ .ext = ".jpeg", .ct = "image/jpeg" },
    .{ .ext = ".gif", .ct = "image/gif" },
    .{ .ext = ".svg", .ct = "image/svg+xml" },
    .{ .ext = ".ico", .ct = "image/x-icon" },
    .{ .ext = ".wav", .ct = "audio/wav" },
    .{ .ext = ".ogg", .ct = "audio/ogg" },
    .{ .ext = ".ttf", .ct = "font/ttf" },
    .{ .ext = ".woff2", .ct = "font/woff2" },
};

fn mimeFor(path: []const u8) []const u8 {
    for (mime_table) |row| {
        if (std.ascii.endsWithIgnoreCase(path, row.ext)) return row.ct;
    }
    return "application/octet-stream";
}

/// Serve static files from `web_dir` on 127.0.0.1:`port`, then open the
/// browser. Blocks forever — returns only on a bind failure (the
/// accept loop swallows per-connection errors so a flaky tab can't
/// kill the server).
///
/// `open_browser` controls the auto-launch — `labelle wasm serve
/// --no-open` passes `false` to suppress it.
pub fn serveAndOpen(allocator: std.mem.Allocator, web_dir: []const u8, port: u16, open_browser_tab: bool) !void {
    const io = config.globalIo();

    const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    var server = addr.listen(io, .{ .reuse_address = true }) catch |err| {
        std.debug.print(
            "labelle: could not bind 127.0.0.1:{d} ({s}).\n" ++
                "  Another server may already be on that port — try a different --port.\n",
            .{ port, @errorName(err) },
        );
        return err;
    };
    defer server.deinit(io);

    std.debug.print(
        "labelle: serving {s}\n" ++
            "  Local:   http://127.0.0.1:{d}\n" ++
            "  Press Ctrl+C to stop\n",
        .{ web_dir, port },
    );

    if (open_browser_tab) openBrowser(allocator, port);

    while (true) {
        const stream = server.accept(io) catch |err| {
            // Transient accept failures (e.g. the peer reset between
            // the SYN and our accept) shouldn't take the server down.
            std.debug.print("labelle: accept failed ({s}), continuing\n", .{@errorName(err)});
            continue;
        };
        handleConnection(io, allocator, stream, web_dir) catch |err| {
            std.debug.print("labelle: connection error ({s})\n", .{@errorName(err)});
        };
    }
}

/// Serve a single HTTP/1.1 request off `stream`, then close it.
/// Connection: close — no keep-alive; the dev loop reopens per asset.
fn handleConnection(
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    web_dir: []const u8,
) !void {
    defer stream.close(io);

    var recv_buf: [16 * 1024]u8 = undefined;
    var send_buf: [64 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &recv_buf);
    var stream_writer = stream.writer(io, &send_buf);

    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    var request = http_server.receiveHead() catch |err| switch (err) {
        // Browser closed the socket before sending a full request line
        // (favicon probes, preconnect sockets) — nothing to answer.
        error.HttpConnectionClosing => return,
        else => return err,
    };

    if (request.head.method != .GET and request.head.method != .HEAD) {
        try request.respond("405 Method Not Allowed\n", .{ .status = .method_not_allowed });
        return;
    }

    const rel = resolveTarget(request.head.target);
    if (rel == null) {
        try request.respond("400 Bad Request\n", .{ .status = .bad_request });
        return;
    }

    const file_path = try std.fs.path.join(allocator, &.{ web_dir, rel.? });
    defer allocator.free(file_path);

    const body = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            try request.respond("404 Not Found\n", .{ .status = .not_found });
            return;
        },
        else => return err,
    };
    defer allocator.free(body);

    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = mimeFor(rel.?) },
            // WASM ships uncompressed and large; spare the browser a
            // re-fetch across reloads within a dev session.
            .{ .name = "cache-control", .value = "no-cache" },
        },
    });
}

/// Map an HTTP request target to a `web_dir`-relative path.
/// Returns `null` for anything that escapes the served root.
///
///   "/"            → "index.html"
///   "/game.wasm"   → "game.wasm"
///   "/a/b.js?v=1"  → "a/b.js"
///   "/../etc"      → null   (rejected)
fn resolveTarget(target: []const u8) ?[]const u8 {
    // Drop the query string / fragment.
    var path = target;
    if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
    if (std.mem.indexOfScalar(u8, path, '#')) |h| path = path[0..h];

    if (path.len == 0 or path[0] != '/') return null;
    path = path[1..]; // strip leading '/'
    if (path.len == 0) return "index.html";

    // Reject traversal. A '..' segment or an embedded NUL would let a
    // request walk out of `web_dir`.
    if (std.mem.indexOfScalar(u8, path, 0) != null) return null;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return null;
    }
    return path;
}

/// Best-effort browser launch. A failure here is non-fatal — the
/// server is already up and the URL is printed; the user can open it
/// by hand.
fn openBrowser(allocator: std.mem.Allocator, port: u16) void {
    const io = config.globalIo();
    const url = std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port}) catch return;
    defer allocator.free(url);

    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .windows => &.{ "cmd", "/c", "start", "", url },
        else => &.{ "xdg-open", url },
    };

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch return;
}

// ── Tests ───────────────────────────────────────────────────────────

test "resolveTarget: root maps to index.html" {
    try std.testing.expectEqualStrings("index.html", resolveTarget("/").?);
}

test "resolveTarget: plain file" {
    try std.testing.expectEqualStrings("game.wasm", resolveTarget("/game.wasm").?);
}

test "resolveTarget: nested path" {
    try std.testing.expectEqualStrings("assets/atlas.png", resolveTarget("/assets/atlas.png").?);
}

test "resolveTarget: strips query string" {
    try std.testing.expectEqualStrings("game.js", resolveTarget("/game.js?v=42").?);
}

test "resolveTarget: strips fragment" {
    try std.testing.expectEqualStrings("index.html", resolveTarget("/index.html#top").?);
}

test "resolveTarget: rejects parent traversal" {
    try std.testing.expect(resolveTarget("/../etc/passwd") == null);
    try std.testing.expect(resolveTarget("/assets/../../secret") == null);
}

test "resolveTarget: rejects embedded NUL" {
    try std.testing.expect(resolveTarget("/game\x00.wasm") == null);
}

test "resolveTarget: rejects target without leading slash" {
    try std.testing.expect(resolveTarget("game.wasm") == null);
    try std.testing.expect(resolveTarget("") == null);
}

test "resolveTarget: a literal '..' segment only — not a substring" {
    // "..foo" is a legitimate filename, not traversal.
    try std.testing.expectEqualStrings("..foo.txt", resolveTarget("/..foo.txt").?);
}

test "mimeFor: known extensions" {
    try std.testing.expectEqualStrings("application/wasm", mimeFor("game.wasm"));
    try std.testing.expectEqualStrings("text/javascript", mimeFor("game.js"));
    try std.testing.expectEqualStrings("text/html; charset=utf-8", mimeFor("index.html"));
}

test "mimeFor: case-insensitive extension match" {
    try std.testing.expectEqualStrings("image/png", mimeFor("LOGO.PNG"));
}

test "mimeFor: unknown extension falls back to octet-stream" {
    try std.testing.expectEqualStrings("application/octet-stream", mimeFor("data.bin"));
}

/// Accept `n` connections then return — the test side of the loop in
/// `serveAndOpen`. Lives in a thread so the test's request side can
/// drive the real `std.Io.net` round-trip in-process.
fn testServeN(io: std.Io, alloc: std.mem.Allocator, server: *std.Io.net.Server, web_dir: []const u8, n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const stream = server.accept(io) catch return;
        handleConnection(io, alloc, stream, web_dir) catch {};
    }
}

test "handleConnection: serves a file, 404s a miss, 400s traversal" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // web_dir = /tmp; the served file is a uniquely-named sibling so
    // the test needs no directory creation.
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "/tmp/labelle_serve_test.html",
        .data = "<h1>hi</h1>",
    });

    const bind = std.Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable;
    var server = try bind.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    var sa: std.posix.sockaddr.in = undefined;
    var sa_len: std.posix.socklen_t = @sizeOf(@TypeOf(sa));
    _ = std.posix.system.getsockname(server.socket.handle, @ptrCast(&sa), &sa_len);
    const port = std.mem.bigToNative(u16, sa.port);

    const t = try std.Thread.spawn(.{}, testServeN, .{ io, alloc, &server, "/tmp", @as(usize, 3) });
    defer t.join();

    const peer = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    const Case = struct { target: []const u8, want: []const u8 };
    for ([_]Case{
        .{ .target = "/labelle_serve_test.html", .want = "<h1>hi</h1>" },
        .{ .target = "/no_such_file.wasm", .want = "404" },
        .{ .target = "/../../etc/passwd", .want = "400" },
    }) |case| {
        const s = try peer.connect(io, .{ .mode = .stream });
        defer s.close(io);
        var wbuf: [512]u8 = undefined;
        var w = s.writer(io, &wbuf);
        try w.interface.print(
            "GET {s} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
            .{case.target},
        );
        try w.interface.flush();

        var rbuf: [8192]u8 = undefined;
        var r = s.reader(io, &rbuf);
        const resp = try r.interface.allocRemaining(alloc, .unlimited);
        defer alloc.free(resp);
        try std.testing.expect(std.mem.indexOf(u8, resp, case.want) != null);
    }
}
