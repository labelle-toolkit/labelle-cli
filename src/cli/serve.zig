/// Minimal static file server for serving WASM builds locally.
/// Opens the default browser and serves files until interrupted.
const std = @import("std");
const builtin = @import("builtin");

const max_file_size = 64 * 1024 * 1024; // 64 MB

/// Serve static files from `web_dir` on localhost:`port`, then open the browser.
pub fn serveAndOpen(allocator: std.mem.Allocator, web_dir: []const u8, port: u16) !void {
    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    var server = address.listen(.{ .reuse_address = true }) catch |err| blk: {
        if (port != 0) {
            // Preferred port unavailable — fall back to any free port
            const fallback = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
            break :blk fallback.listen(.{ .reuse_address = true }) catch return err;
        }
        return err;
    };
    defer server.deinit();

    const actual_port = server.listen_address.getPort();
    std.debug.print("labelle: serving at http://localhost:{d}\n", .{actual_port});
    std.debug.print("  press Ctrl+C to stop\n\n", .{});

    openBrowser(allocator, actual_port);

    while (true) {
        const conn = server.accept() catch |err| {
            std.debug.print("labelle: accept error: {any}\n", .{err});
            continue;
        };
        defer conn.stream.close();
        handleConnection(allocator, conn.stream, web_dir) catch {};
    }
}

fn handleConnection(allocator: std.mem.Allocator, stream: std.net.Stream, web_dir: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const n = stream.read(&buf) catch return;
    if (n == 0) return;

    const request = buf[0..n];

    // Parse "GET /path HTTP/1.x"
    const path = parsePath(request) orelse {
        try sendResponse(stream, "400 Bad Request", "text/plain", "Bad Request");
        return;
    };

    // Map "/" to "/index.html"
    const file_path = if (std.mem.eql(u8, path, "/")) "/index.html" else path;

    // Strip leading "/" and resolve against web_dir
    const rel_path = if (file_path.len > 1) file_path[1..] else file_path;

    // Reject absolute paths (e.g. "//etc/passwd" → "/etc/passwd" after strip)
    if (rel_path.len > 0 and (rel_path[0] == '/' or rel_path[0] == '\\')) {
        try sendResponse(stream, "400 Bad Request", "text/plain", "Bad Request");
        return;
    }

    const full_path = std.fs.path.join(allocator, &.{ web_dir, rel_path }) catch {
        try sendResponse(stream, "500 Internal Server Error", "text/plain", "Server Error");
        return;
    };
    defer allocator.free(full_path);

    const content = std.fs.cwd().readFileAlloc(allocator, full_path, max_file_size) catch {
        try sendResponse(stream, "404 Not Found", "text/plain", "Not Found");
        return;
    };
    defer allocator.free(content);

    const content_type = mimeType(rel_path);

    // Send response with CORS and SharedArrayBuffer headers (required by some WASM builds)
    var header_buf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf,
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: {s}\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Cross-Origin-Opener-Policy: same-origin\r\n" ++
        "Cross-Origin-Embedder-Policy: require-corp\r\n" ++
        "Connection: close\r\n" ++
        "\r\n",
        .{ content_type, content.len },
    ) catch return;

    stream.writeAll(header) catch return;
    stream.writeAll(content) catch return;
}

fn sendResponse(stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) !void {
    var buf: [512]u8 = undefined;
    const header = std.fmt.bufPrint(&buf,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len },
    ) catch return;
    stream.writeAll(header) catch return;
    stream.writeAll(body) catch return;
}

fn parsePath(request: []const u8) ?[]const u8 {
    // Find "GET " prefix
    if (!std.mem.startsWith(u8, request, "GET ")) return null;
    const path_start = 4;
    // Find end of path (space before HTTP version)
    const path_end = std.mem.indexOfPos(u8, request, path_start, " ") orelse return null;
    const path = request[path_start..path_end];
    // Basic security: reject paths with ".."
    if (std.mem.indexOf(u8, path, "..") != null) return null;
    return path;
}

fn mimeType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".html")) return "text/html";
    if (std.mem.eql(u8, ext, ".js")) return "application/javascript";
    if (std.mem.eql(u8, ext, ".wasm")) return "application/wasm";
    if (std.mem.eql(u8, ext, ".css")) return "text/css";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".json")) return "application/json";
    if (std.mem.eql(u8, ext, ".ico")) return "image/x-icon";
    return "application/octet-stream";
}

fn openBrowser(allocator: std.mem.Allocator, port: u16) void {
    var url_buf: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://localhost:{d}", .{port}) catch return;

    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .windows => &.{ "cmd", "/c", "start", url },
        else => &.{ "xdg-open", url },
    };

    var child: std.process.Child = .init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;
    _ = child.wait() catch {};
}
