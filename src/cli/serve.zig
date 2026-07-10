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
///
/// `watch` (cli#208) enables the rebuild-on-change live-reload loop: a
/// background thread polls `watch.watch_dir`, runs `watch.rebuild_fn` on
/// change, and bumps a shared build version that connected browsers poll
/// via an injected client snippet (`/__labelle_livereload`). Pass `null`
/// for a plain static serve.
pub fn serveAndOpen(
    allocator: std.mem.Allocator,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
    port: u16,
    open_browser_tab: bool,
    watch: ?WatchConfig,
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

    // Start the file watcher before printing the banner so its status is
    // reflected. `wstate` lives on this frame — `serveAndOpen` blocks until
    // Ctrl+C, so it outlives the watcher thread and every connection.
    var wstate = WatchState{};
    var watch_thread: ?std.Thread = null;
    if (watch) |cfg| {
        watch_thread = std.Thread.spawn(.{}, watchLoop, .{ io, cfg, &wstate }) catch |err| blk: {
            std.debug.print(
                "labelle: could not start file watcher ({s}); serving without --watch\n",
                .{@errorName(err)},
            );
            break :blk null;
        };
    }
    defer if (watch_thread) |t| {
        wstate.stop.store(true, .release);
        t.join();
    };
    // Only inject the reload client + answer the version endpoint when a
    // watcher is actually running.
    const watch_state: ?*WatchState = if (watch_thread != null) &wstate else null;

    std.debug.print(
        "labelle: serving {s}\n" ++
            "  Local:   http://127.0.0.1:{d}\n" ++
            "{s}" ++
            "  Press Ctrl+C to stop\n",
        .{
            web_dir,
            port,
            if (watch_state != null) "  Watching for changes — edits rebuild + live-reload\n" else "",
        },
    );

    if (open_browser_tab) openBrowser(allocator, port);

    while (true) {
        const stream = server.accept(io) catch |err| {
            // Transient accept failures (e.g. the peer reset between
            // the SYN and our accept) shouldn't take the server down.
            std.debug.print("labelle: accept failed ({s}), continuing\n", .{@errorName(err)});
            continue;
        };
        handleConnection(io, allocator, stream, web_dir, project_web_dir, watch_state) catch |err| {
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
    watch_state: ?*WatchState,
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

    // Live-reload version endpoint (cli#208). The injected client polls
    // this; the plain-text body is the current build version, bumped by
    // the watcher thread after a successful rebuild. A changed value tells
    // the page to reload. Answered before static routing so the reserved
    // path never hits the filesystem. Returns `0` when no watcher is
    // running (a stray poll from a cached page won't ever reload).
    if (std.mem.eql(u8, rel.?, livereload_rel)) {
        const version = if (watch_state) |ws| ws.version.load(.acquire) else 0;
        var buf: [24]u8 = undefined;
        const vbody = std.fmt.bufPrint(&buf, "{d}", .{version}) catch "0";
        try request.respond(vbody, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-cache" },
            },
        });
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

    // Under `--watch`, splice the live-reload client into served HTML so
    // the open tab starts polling the version endpoint. Non-HTML assets
    // (wasm/js/png/…) and non-watch serves pass through untouched.
    const is_html = std.mem.startsWith(u8, content_type, "text/html");
    const send_body: []const u8 = if (watch_state != null and is_html)
        try injectReloadScript(allocator, body)
    else
        body;
    defer if (send_body.ptr != body.ptr) allocator.free(send_body);

    // `request.respond` omits the body for HEAD requests automatically
    // while still emitting a `content-length` reflecting the real file
    // size, so passing the full `body` is correct for GET and HEAD.
    try request.respond(send_body, .{
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

// ── Live reload / watch (cli#208) ────────────────────────────────────

/// Reserved request path the injected client polls for the build version.
const livereload_path = "/__labelle_livereload";
/// The `web_dir`-relative form `resolveTarget` yields for that path.
const livereload_rel = "__labelle_livereload";

/// Client snippet spliced into served HTML under `--watch`. Polls the
/// version endpoint once a second; when the value changes (the watcher
/// bumped it after a rebuild) it reloads the page. Plain ES5 + `fetch`,
/// no dependencies — works in every browser that can run a WASM game.
const reload_client_js =
    \\<script>
    \\(function () {
    \\  var current = null;
    \\  function poll() {
    \\    fetch("/__labelle_livereload", { cache: "no-store" })
    \\      .then(function (r) { return r.text(); })
    \\      .then(function (v) {
    \\        if (current === null) { current = v; }
    \\        else if (v !== current) { location.reload(); return; }
    \\        setTimeout(poll, 1000);
    \\      })
    \\      .catch(function () { setTimeout(poll, 2000); });
    \\  }
    \\  poll();
    \\})();
    \\</script>
    \\
;

/// The rebuild callback signature. Returns true on a clean rebuild, false
/// on any failure (the server stays up; the browser is NOT reloaded onto a
/// broken build).
pub const RebuildFn = *const fn (ctx: *anyopaque) bool;

/// Watch configuration passed to `serveAndOpen`.
pub const WatchConfig = struct {
    /// Project source tree to poll for changes. Build-output and VCS dirs
    /// (`.labelle`, `.git`, `zig-out`, …) are skipped so a rebuild — which
    /// writes into `.labelle/` — can't trigger itself.
    watch_dir: []const u8,
    /// Invoked (on the watcher thread) after a debounced change.
    rebuild_fn: RebuildFn,
    /// Opaque payload handed back to `rebuild_fn`.
    rebuild_ctx: *anyopaque,
    /// Poll cadence.
    poll_interval_ms: u32 = 400,
    /// Consecutive stable polls required before firing a rebuild — debounces
    /// a burst of saves into a single build. Minimum 1.
    quiet_polls: u32 = 2,
};

/// Shared state between the watcher thread and the serve loop. `version`
/// is what the browser polls; `stop` lets `serveAndOpen`'s defer join the
/// thread cleanly (only exercised if the accept loop ever returns).
const WatchState = struct {
    version: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Directory names skipped while walking the watch tree. `.labelle` is the
/// load-bearing one — the rebuild writes there, so watching it would loop.
const watch_skip_dirs = [_][]const u8{ "zig-out", "zig-cache", "zig-pkg" };

/// A cheap fingerprint of a source tree: a file count plus a `digest`
/// that folds in every file's `(path, size, mtime)`. Folding per file
/// (rather than only summing sizes + tracking the single newest mtime)
/// makes the signature sensitive to *any* single-file change — including a
/// same-size edit to a non-newest file, or swapping content between two
/// files — so any add / edit / remove / mtime-change flips it.
const TreeSignature = struct {
    file_count: u64 = 0,
    /// Order-independent digest: each file contributes an independent
    /// 64-bit hash of its path+size+mtime, XOR-folded in. XOR is
    /// commutative, so directory iteration order doesn't matter, and a
    /// change to any single file toggles the bits its hash owns.
    digest: u64 = 0,

    /// Fold one file's identity into the signature.
    fn mix(self: *TreeSignature, path: []const u8, size: u64, mtime_ns: i128) void {
        var h = std.hash.Wyhash.init(0);
        h.update(path);
        h.update(std.mem.asBytes(&size));
        const m: i128 = mtime_ns;
        h.update(std.mem.asBytes(&m));
        self.file_count += 1;
        self.digest ^= h.final();
    }

    fn eql(a: TreeSignature, b: TreeSignature) bool {
        return a.file_count == b.file_count and a.digest == b.digest;
    }
};

/// True when a directory name should be skipped during the walk: any
/// dot-prefixed dir (`.labelle`, `.git`, `.zig-cache`, `.cache`) plus the
/// non-hidden build dirs in `watch_skip_dirs`.
fn skipWatchDir(name: []const u8) bool {
    if (name.len > 0 and name[0] == '.') return true;
    for (watch_skip_dirs) |d| {
        if (std.mem.eql(u8, name, d)) return true;
    }
    return false;
}

/// Accumulate `dir_path`'s tree signature into `sig`. Best-effort: an
/// unreadable dir/file is skipped rather than fatal (a transient rename
/// mid-scan just shows up as a change on the next poll). Recurses into
/// subdirectories except those `skipWatchDir` rejects.
fn computeSignature(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    sig: *TreeSignature,
) void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        if (entry.kind == .directory) {
            if (skipWatchDir(entry.name)) continue;
            const sub = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;
            defer allocator.free(sub);
            computeSignature(io, allocator, sub, sig);
        } else if (entry.kind == .file) {
            const fpath = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;
            defer allocator.free(fpath);
            const st = std.Io.Dir.cwd().statFile(io, fpath, .{}) catch continue;
            sig.mix(fpath, st.size, st.mtime.nanoseconds);
        }
    }
}

/// Pure debounce decision: fire a rebuild once the tree has held a new,
/// unbuilt signature steady for at least `quiet_polls` consecutive polls.
/// Extracted for unit testing the burst-coalescing logic without threads.
fn shouldRebuild(unbuilt: bool, stable_polls: u32, quiet_polls: u32) bool {
    const need = if (quiet_polls == 0) 1 else quiet_polls;
    return unbuilt and stable_polls >= need;
}

/// Splice `reload_client_js` into `html` just before `</body>` (or append
/// it when there's no body tag). Caller owns the returned buffer.
fn injectReloadScript(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    const marker = "</body>";
    if (std.mem.lastIndexOf(u8, html, marker)) |idx| {
        var out = try allocator.alloc(u8, html.len + reload_client_js.len);
        @memcpy(out[0..idx], html[0..idx]);
        @memcpy(out[idx..][0..reload_client_js.len], reload_client_js);
        @memcpy(out[idx + reload_client_js.len ..], html[idx..]);
        return out;
    }
    return std.mem.concat(allocator, u8, &.{ html, reload_client_js });
}

/// Watcher thread body: poll the tree, debounce, rebuild, bump version.
/// Runs until `state.stop` is set. A rebuild failure is surfaced in the
/// terminal but keeps the loop (and server) alive; `applied` still advances
/// so we don't respin on the same broken tree — a later edit retriggers.
fn watchLoop(io: std.Io, cfg: WatchConfig, state: *WatchState) void {
    var scan_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scan_arena.deinit();

    // `applied` = signature of the last (attempted) build. `last` = signature
    // seen on the previous poll — used to detect a burst still in flight.
    var applied = TreeSignature{};
    computeSignature(io, scan_arena.allocator(), cfg.watch_dir, &applied);
    _ = scan_arena.reset(.retain_capacity);
    var last = applied;
    var stable_polls: u32 = 0;

    const interval = std.Io.Duration.fromMilliseconds(@intCast(cfg.poll_interval_ms));

    while (!state.stop.load(.acquire)) {
        io.sleep(interval, .awake) catch return;
        if (state.stop.load(.acquire)) return;

        var sig = TreeSignature{};
        computeSignature(io, scan_arena.allocator(), cfg.watch_dir, &sig);
        _ = scan_arena.reset(.retain_capacity);

        if (!sig.eql(last)) {
            // Tree still changing — reset the quiet counter (debounce).
            last = sig;
            stable_polls = 0;
            continue;
        }
        stable_polls +|= 1;
        if (!shouldRebuild(!sig.eql(applied), stable_polls, cfg.quiet_polls)) continue;

        std.debug.print("labelle: change detected — rebuilding WASM...\n", .{});
        const ok = cfg.rebuild_fn(cfg.rebuild_ctx);
        applied = sig;
        stable_polls = 0;
        if (ok) {
            _ = state.version.fetchAdd(1, .release);
            std.debug.print("labelle: rebuild ok — reloading connected browsers\n", .{});
        } else {
            std.debug.print("labelle: rebuild failed — see errors above; server still running\n", .{});
        }
    }
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
    testServeNWatch(io, alloc, server, web_dir, project_web_dir, n, null);
}

/// Like `testServeN` but with an explicit watch state, so tests can drive
/// the `--watch` request paths (version endpoint + HTML injection).
fn testServeNWatch(
    io: std.Io,
    alloc: std.mem.Allocator,
    server: *std.Io.net.Server,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
    n: usize,
    watch_state: ?*WatchState,
) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const stream = server.accept(io) catch return;
        handleConnection(io, alloc, stream, web_dir, project_web_dir, watch_state) catch {};
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

// ── Watch / live-reload tests (cli#208) ──────────────────────────────

test "shouldRebuild: fires only after quiet_polls stable ticks with unbuilt changes" {
    // Not yet stable enough.
    try std.testing.expect(!shouldRebuild(true, 1, 2));
    // Stable long enough + unbuilt → fire.
    try std.testing.expect(shouldRebuild(true, 2, 2));
    try std.testing.expect(shouldRebuild(true, 5, 2));
    // Nothing unbuilt → never fire, however long it's been quiet.
    try std.testing.expect(!shouldRebuild(false, 9, 2));
}

test "shouldRebuild: quiet_polls of 0 is clamped to 1 (fires on first stable tick)" {
    try std.testing.expect(shouldRebuild(true, 1, 0));
    try std.testing.expect(!shouldRebuild(false, 1, 0));
}

test "skipWatchDir: skips dot-dirs and build output, keeps source dirs" {
    try std.testing.expect(skipWatchDir(".labelle"));
    try std.testing.expect(skipWatchDir(".git"));
    try std.testing.expect(skipWatchDir(".zig-cache"));
    try std.testing.expect(skipWatchDir("zig-out"));
    try std.testing.expect(skipWatchDir("zig-pkg"));
    try std.testing.expect(!skipWatchDir("scenes"));
    try std.testing.expect(!skipWatchDir("prefabs"));
    try std.testing.expect(!skipWatchDir("assets"));
    try std.testing.expect(!skipWatchDir("src"));
}

test "injectReloadScript: splices before </body>" {
    const alloc = std.testing.allocator;
    const html = "<html><body><canvas></canvas></body></html>";
    const out = try injectReloadScript(alloc, html);
    defer alloc.free(out);
    // The client script is present...
    try std.testing.expect(std.mem.indexOf(u8, out, "__labelle_livereload") != null);
    // ...and it lands before the closing body tag, not after it.
    const script_at = std.mem.indexOf(u8, out, "location.reload").?;
    const body_at = std.mem.indexOf(u8, out, "</body>").?;
    try std.testing.expect(script_at < body_at);
    // Original content is preserved.
    try std.testing.expect(std.mem.indexOf(u8, out, "<canvas>") != null);
}

test "injectReloadScript: appends when there is no </body>" {
    const alloc = std.testing.allocator;
    const html = "<h1>bare fragment</h1>";
    const out = try injectReloadScript(alloc, html);
    defer alloc.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "<h1>bare fragment</h1>"));
    try std.testing.expect(std.mem.indexOf(u8, out, "__labelle_livereload") != null);
}

test "computeSignature: changes on add, edit, and remove" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(dir_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });

    var base = TreeSignature{};
    computeSignature(io, alloc, dir_path, &base);
    try std.testing.expectEqual(@as(u64, 1), base.file_count);

    // Add a file → count + digest change.
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "twelve!" });
    var after_add = TreeSignature{};
    computeSignature(io, alloc, dir_path, &after_add);
    try std.testing.expect(!base.eql(after_add));
    try std.testing.expectEqual(@as(u64, 2), after_add.file_count);

    // Edit a file in place, keeping the byte count identical → count + size
    // stay put but the mtime advances, so the digest (and signature) differ.
    // Force the mtime forward explicitly instead of relying on the write to
    // bump it: Windows' filesystem mtime granularity is coarse enough that
    // two back-to-back writes can share an mtime, leaving the
    // (path,size,mtime) digest unchanged. A deterministic +2s jump makes the
    // edit observable on every platform.
    const b_before = try tmp.dir.statFile(io, "b.txt", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "TWELVE!" });
    try tmp.dir.setTimestamps(io, "b.txt", .{
        .modify_timestamp = .{ .new = .{ .nanoseconds = b_before.mtime.nanoseconds + 10 * std.time.ns_per_s } },
    });
    var after_edit = TreeSignature{};
    computeSignature(io, alloc, dir_path, &after_edit);
    try std.testing.expectEqual(after_add.file_count, after_edit.file_count);
    try std.testing.expect(!after_add.eql(after_edit));

    // Remove a file → back down to one entry, different from every prior sig.
    try tmp.dir.deleteFile(io, "b.txt");
    var after_rm = TreeSignature{};
    computeSignature(io, alloc, dir_path, &after_rm);
    try std.testing.expectEqual(@as(u64, 1), after_rm.file_count);
    try std.testing.expect(!after_rm.eql(after_add));
}

test "TreeSignature: a same-size edit to a NON-newest file still flips the signature" {
    // Regression for the codex finding: a summed-size + single-newest-mtime
    // signature misses a same-size edit to a file that isn't the newest.
    // Two files; the second (mtime 200) is the newest. Edit the first to the
    // SAME size (10 bytes) with a new mtime that is still older than the
    // newest (150 < 200) — total size (30) and the newest mtime (200) are
    // both unchanged, so the old scheme would report "no change". The
    // per-file digest catches it.
    var before = TreeSignature{};
    before.mix("old.txt", 10, 100);
    before.mix("new.txt", 20, 200);

    var after = TreeSignature{};
    after.mix("old.txt", 10, 150); // same size, newer mtime, still not newest
    after.mix("new.txt", 20, 200);

    try std.testing.expectEqual(before.file_count, after.file_count);
    try std.testing.expect(!before.eql(after));
}

test "computeSignature: a same-size in-place edit triggers a rebuild" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(dir_path);

    // Two files; `b.txt` is written last (newest). Editing the OLDER `a.txt`
    // to the same length is the case the naive signature missed.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "aaaa" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "bbbb" });

    const a_before = try tmp.dir.statFile(io, "a.txt", .{});

    var applied = TreeSignature{};
    computeSignature(io, alloc, dir_path, &applied);

    // Same 4-byte length, different content. Force the mtime forward
    // explicitly so the change is observable regardless of the platform's
    // write-mtime granularity (Windows can coalesce same-tick writes to an
    // identical mtime, which would hide the edit).
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "AAAA" });
    try tmp.dir.setTimestamps(io, "a.txt", .{
        .modify_timestamp = .{ .new = .{ .nanoseconds = a_before.mtime.nanoseconds + 10 * std.time.ns_per_s } },
    });
    var now = TreeSignature{};
    computeSignature(io, alloc, dir_path, &now);

    try std.testing.expectEqual(applied.file_count, now.file_count);
    try std.testing.expect(!applied.eql(now));
    // …and that unbuilt delta drives a rebuild once it's held steady.
    try std.testing.expect(shouldRebuild(!now.eql(applied), 2, 2));
}

test "computeSignature: skips .labelle build-output dir (no self-trigger)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(dir_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "scene.zon", .data = "source" });
    var before = TreeSignature{};
    computeSignature(io, alloc, dir_path, &before);

    // Simulate a rebuild writing into .labelle/ — the signature must not move.
    try tmp.dir.createDirPath(io, ".labelle/raylib_wasm");
    try tmp.dir.writeFile(io, .{ .sub_path = ".labelle/raylib_wasm/out.wasm", .data = "artifact" });
    var after = TreeSignature{};
    computeSignature(io, alloc, dir_path, &after);
    try std.testing.expect(before.eql(after));
}

test "handleConnection: --watch answers the version endpoint and injects the reload client" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var build_tmp = std.testing.tmpDir(.{});
    defer build_tmp.cleanup();
    const web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &build_tmp.sub_path });
    defer alloc.free(web_dir);
    try build_tmp.dir.writeFile(io, .{
        .sub_path = "index.html",
        .data = "<html><body><canvas id=game></canvas></body></html>",
    });

    var wstate = WatchState{};
    _ = wstate.version.fetchAdd(7, .release);

    const bound = testBindFreePort(io) orelse return error.NoFreePort;
    var server = bound.server;
    const port = bound.port;
    defer server.deinit(io);

    const t = try std.Thread.spawn(.{}, testServeNWatch, .{ io, alloc, &server, web_dir, @as(?[]const u8, null), @as(usize, 2), &wstate });
    defer t.join();

    const peer = std.Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    const Case = struct { target: []const u8, want: []const u8 };
    for ([_]Case{
        // Version endpoint reflects the current build version.
        .{ .target = "/__labelle_livereload", .want = "7" },
        // The root HTML gets the reload client spliced in.
        .{ .target = "/", .want = "__labelle_livereload" },
    }) |case| {
        const s = try peer.connect(io, .{ .mode = .stream });
        defer s.close(io);
        var wbuf: [512]u8 = undefined;
        var w = s.writer(io, &wbuf);
        try w.interface.print("GET {s} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .{case.target});
        try w.interface.flush();

        var rbuf: [8192]u8 = undefined;
        var r = s.reader(io, &rbuf);
        const resp = try r.interface.allocRemaining(alloc, .unlimited);
        defer alloc.free(resp);
        try std.testing.expect(std.mem.indexOf(u8, resp, case.want) != null);
    }
}

test "handleConnection: without --watch, HTML is served untouched and the endpoint is inert" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var build_tmp = std.testing.tmpDir(.{});
    defer build_tmp.cleanup();
    const web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &build_tmp.sub_path });
    defer alloc.free(web_dir);
    try build_tmp.dir.writeFile(io, .{
        .sub_path = "index.html",
        .data = "<html><body>plain</body></html>",
    });

    const resp = try testRootRequest(io, alloc, web_dir, null);
    defer alloc.free(resp);
    // No watcher → no injected client script.
    try std.testing.expect(std.mem.indexOf(u8, resp, "__labelle_livereload") == null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "plain") != null);
}
