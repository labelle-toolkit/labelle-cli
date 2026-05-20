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
/// `web_dir` is the build output dir (`.labelle/<backend>_wasm/zig-out/web`).
/// `project_web_dir` is the durable project shell dir (`<project>/web`);
/// if it holds an `index.html`, that file is served at `/` so the user
/// gets a clean root page instead of emcc's chrome-heavy `game.html`.
/// Pass `null` to disable the project-shell lookup.
///
/// `open_browser` controls the auto-launch — `labelle wasm serve
/// --no-open` passes `false` to suppress it.
pub fn serveAndOpen(
    allocator: std.mem.Allocator,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
    port: u16,
    open_browser_tab: bool,
) !void {
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
        handleConnection(io, allocator, stream, web_dir, project_web_dir) catch |err| {
            std.debug.print("labelle: connection error ({s})\n", .{@errorName(err)});
        };
    }
}

/// True if `path` names a regular file that can be opened for reading.
fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// True if the request target addresses the site root — `/` or a bare
/// `/index.html` (query string / fragment already stripped by the
/// caller via `resolveTarget`, which yields `"index.html"` for both).
fn isRootRequest(rel: []const u8) bool {
    return std.mem.eql(u8, rel, "index.html");
}

/// Resolve a root (`/` or `/index.html`) request to the file that
/// should back it. Resolution order:
///   a. `<project>/web/index.html` — the clean project shell.
///   b. `<build web dir>/index.html` — a build-produced shell.
///   c. `<build web dir>/game.html` — emcc's chrome-heavy shell.
///   d. else `null` — caller answers 404.
/// Returns an allocator-owned path the caller must free.
fn resolveRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
) !?[]const u8 {
    if (project_web_dir) |pwd| {
        const shell = try std.fs.path.join(allocator, &.{ pwd, "index.html" });
        if (fileExists(io, shell)) return shell;
        allocator.free(shell);
    }

    const build_index = try std.fs.path.join(allocator, &.{ web_dir, "index.html" });
    if (fileExists(io, build_index)) return build_index;
    allocator.free(build_index);

    const game_html = try std.fs.path.join(allocator, &.{ web_dir, "game.html" });
    if (fileExists(io, game_html)) return game_html;
    allocator.free(game_html);

    return null;
}

/// Serve a single HTTP/1.1 request off `stream`, then close it.
/// Connection: close — no keep-alive; the dev loop reopens per asset.
fn handleConnection(
    io: std.Io,
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
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

    // The root request (`/` or a bare `/index.html`) is resolved
    // specially: prefer the project's clean shell, then a build-emitted
    // `index.html`, then emcc's `game.html`. Everything else is a plain
    // `web_dir`-relative asset. The root candidates are fixed filenames
    // — not user-controlled — so they don't need `resolveTarget`'s
    // traversal hardening.
    const file_path = if (isRootRequest(rel.?))
        (try resolveRoot(io, allocator, web_dir, project_web_dir)) orelse {
            try request.respond("404 Not Found\n", .{ .status = .not_found });
            return;
        }
    else
        try std.fs.path.join(allocator, &.{ web_dir, rel.? });
    defer allocator.free(file_path);

    // For the root request the served file may be `game.html`; report
    // an HTML content-type regardless of the candidate that matched.
    const content_type = if (isRootRequest(rel.?)) "text/html; charset=utf-8" else mimeFor(rel.?);

    // Cap the read so a stray huge file in `web_dir` can't OOM the
    // server. 1 GiB is generous for a WASM bundle + assets.
    const max_file_bytes = 1024 * 1024 * 1024;
    const body = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => {
            try request.respond("404 Not Found\n", .{ .status = .not_found });
            return;
        },
        // `readFileAlloc` reports a too-large file as a stream-limit
        // error; answer 413 instead of letting the connection die.
        error.StreamTooLong => {
            try request.respond("413 Payload Too Large\n", .{ .status = .payload_too_large });
            return;
        },
        else => return err,
    };
    defer allocator.free(body);

    // `request.respond` omits the body for HEAD requests automatically
    // while still emitting a `content-length` reflecting the real file
    // size, so passing the full `body` is correct for GET and HEAD.
    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = content_type },
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
///   "/..\\win.ini" → null   (rejected — backslash)
///   "//etc/passwd" → null   (rejected — still absolute)
fn resolveTarget(target: []const u8) ?[]const u8 {
    // Drop the query string / fragment.
    var path = target;
    if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
    if (std.mem.indexOfScalar(u8, path, '#')) |h| path = path[0..h];

    if (path.len == 0 or path[0] != '/') return null;

    // Reject any backslash outright. A legit web asset path never has
    // one, and on Windows '\' is a path separator — so a target like
    // "/..\..\windows\win.ini" would otherwise be a single segment
    // that dodges the '..' check below and escapes `web_dir`.
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return null;

    path = path[1..]; // strip leading '/'
    if (path.len == 0) return "index.html";

    // A second leading '/' (e.g. "//etc/passwd") would leave the path
    // absolute after the strip above and flow straight into
    // `std.fs.path.join`, escaping `web_dir`. Reject anything still
    // absolute.
    if (path[0] == '/') return null;

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

test "resolveTarget: rejects backslash (Windows separator traversal)" {
    // On Windows '\' is a path separator, so "/..\..\win.ini" would be
    // a single segment that dodges the '..' check. Reject any '\'.
    try std.testing.expect(resolveTarget("/..\\..\\windows\\win.ini") == null);
    try std.testing.expect(resolveTarget("/assets\\atlas.png") == null);
    try std.testing.expect(resolveTarget("/a\\b") == null);
}

test "resolveTarget: rejects double-slash (still absolute)" {
    // "//etc/passwd" stays absolute after stripping one leading slash
    // and would escape web_dir via path.join.
    try std.testing.expect(resolveTarget("//etc/passwd") == null);
    try std.testing.expect(resolveTarget("///etc/passwd") == null);
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
fn testServeN(
    io: std.Io,
    alloc: std.mem.Allocator,
    server: *std.Io.net.Server,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
    n: usize,
) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const stream = server.accept(io) catch return;
        handleConnection(io, alloc, stream, web_dir, project_web_dir) catch {};
    }
}

/// Bind 127.0.0.1 on the first free port in a fixed candidate range.
/// Avoids needing `getsockname` to discover a port-0 assignment —
/// that symbol isn't linked in Zig's Windows std, so the port-0 +
/// getsockname trick fails to compile on Windows.
fn testBindFreePort(io: std.Io) ?struct { server: std.Io.net.Server, port: u16 } {
    var port: u16 = 49500;
    while (port < 49600) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
        const server = addr.listen(io, .{ .reuse_address = true }) catch continue;
        return .{ .server = server, .port = port };
    }
    return null;
}

test "handleConnection: serves a file, 404s a miss, 400s traversal" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Portable, auto-cleaned temp dir under .zig-cache/tmp/<sub_path>.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(web_dir);

    try tmp.dir.writeFile(io, .{
        .sub_path = "labelle_serve_test.html",
        .data = "<h1>hi</h1>",
    });

    const bound = testBindFreePort(io) orelse return error.NoFreePort;
    var server = bound.server;
    const port = bound.port;
    defer server.deinit(io);

    const t = try std.Thread.spawn(.{}, testServeN, .{ io, alloc, &server, web_dir, @as(?[]const u8, null), @as(usize, 3) });
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

/// Issue a single `GET /` over loopback and return the full response.
/// Caller frees the result.
fn testRootRequest(
    io: std.Io,
    alloc: std.mem.Allocator,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
) ![]u8 {
    const bound = testBindFreePort(io) orelse return error.NoFreePort;
    var server = bound.server;
    const port = bound.port;
    defer server.deinit(io);

    const t = try std.Thread.spawn(.{}, testServeN, .{ io, alloc, &server, web_dir, project_web_dir, @as(usize, 1) });
    defer t.join();

    const peer = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    const s = try peer.connect(io, .{ .mode = .stream });
    defer s.close(io);
    var wbuf: [512]u8 = undefined;
    var w = s.writer(io, &wbuf);
    try w.interface.print("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .{});
    try w.interface.flush();

    var rbuf: [8192]u8 = undefined;
    var r = s.reader(io, &rbuf);
    return r.interface.allocRemaining(alloc, .unlimited);
}

test "handleConnection: root prefers the project web/index.html shell" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Build output dir: holds emcc's game.html only.
    var build_tmp = std.testing.tmpDir(.{});
    defer build_tmp.cleanup();
    const web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &build_tmp.sub_path });
    defer alloc.free(web_dir);
    try build_tmp.dir.writeFile(io, .{ .sub_path = "game.html", .data = "<!-- emcc shell -->" });

    // Project web dir: holds the clean shell.
    var proj_tmp = std.testing.tmpDir(.{});
    defer proj_tmp.cleanup();
    const project_web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &proj_tmp.sub_path });
    defer alloc.free(project_web_dir);
    try proj_tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "<!-- clean shell -->" });

    const resp = try testRootRequest(io, alloc, web_dir, project_web_dir);
    defer alloc.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "clean shell") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "emcc shell") == null);
}

test "handleConnection: root falls back to game.html when no project shell" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var build_tmp = std.testing.tmpDir(.{});
    defer build_tmp.cleanup();
    const web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &build_tmp.sub_path });
    defer alloc.free(web_dir);
    try build_tmp.dir.writeFile(io, .{ .sub_path = "game.html", .data = "<!-- emcc shell -->" });

    // Project web dir exists but has no index.html.
    var proj_tmp = std.testing.tmpDir(.{});
    defer proj_tmp.cleanup();
    const project_web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &proj_tmp.sub_path });
    defer alloc.free(project_web_dir);

    const resp = try testRootRequest(io, alloc, web_dir, project_web_dir);
    defer alloc.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "emcc shell") != null);
}

test "handleConnection: root prefers a build-emitted index.html over game.html" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var build_tmp = std.testing.tmpDir(.{});
    defer build_tmp.cleanup();
    const web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &build_tmp.sub_path });
    defer alloc.free(web_dir);
    try build_tmp.dir.writeFile(io, .{ .sub_path = "game.html", .data = "<!-- emcc shell -->" });
    try build_tmp.dir.writeFile(io, .{ .sub_path = "index.html", .data = "<!-- build index -->" });

    const resp = try testRootRequest(io, alloc, web_dir, null);
    defer alloc.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "build index") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "emcc shell") == null);
}

test "handleConnection: root 404s when neither a shell nor game.html exists" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var build_tmp = std.testing.tmpDir(.{});
    defer build_tmp.cleanup();
    const web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &build_tmp.sub_path });
    defer alloc.free(web_dir);

    const resp = try testRootRequest(io, alloc, web_dir, null);
    defer alloc.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "404") != null);
}
