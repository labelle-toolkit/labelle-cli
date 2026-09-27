//! The accept loop and `serveAndOpen`: bind the listener, start the stop
//! waker and the file watcher, open the browser, and serve until a stop is
//! asked for.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const signals = @import("cancel.zig");
const installCancelHandler = signals.installCancelHandler;
const wakeLoop = signals.wakeLoop;
const wakeListener = signals.wakeListener;
const handleConnection = @import("http.zig").handleConnection;
const watcher = @import("watch.zig");
const WatchConfig = watcher.WatchConfig;
const WatchState = watcher.WatchState;
const watchLoop = watcher.watchLoop;
const testBindFreePort = @import("testing.zig").testBindFreePort;

/// The accept loop. Returns once `cancel` is set — before handling any
/// connection accepted after the request, so the wake-up poke (or a real
/// request racing it) is closed unanswered. Per-connection errors never
/// end the loop.
fn serveLoop(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: *std.Io.net.Server,
    web_dir: []const u8,
    project_web_dir: ?[]const u8,
    watch_state: ?*WatchState,
    cancel: *const std.atomic.Value(bool),
) void {
    while (!cancel.load(.acquire)) {
        const stream = server.accept(io) catch |err| {
            // Transient accept failures (e.g. the peer reset between
            // the SYN and our accept) shouldn't take the server down.
            std.debug.print("labelle: accept failed ({s}), continuing\n", .{@errorName(err)});
            continue;
        };
        if (cancel.load(.acquire)) {
            stream.close(io);
            return;
        }
        handleConnection(io, allocator, stream, web_dir, project_web_dir, watch_state) catch |err| {
            std.debug.print("labelle: connection error ({s})\n", .{@errorName(err)});
        };
    }
}

/// Serve static files from `web_dir` on 127.0.0.1:`port`, then open the
/// browser. Blocks until a stop is asked for (Ctrl+C / SIGTERM; see
/// `installCancelHandler`), then returns cleanly so the caller can run
/// what follows the serve — or returns early on a bind failure. The
/// accept loop swallows per-connection errors so a flaky tab can't kill
/// the server.
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

    // The stop handler and its waker come first, so a Ctrl+C at any point
    // after the bind ends the loop instead of the process. `wstate.stop`
    // also ends the waker if the loop is left some other way.
    installCancelHandler();
    var wstate = WatchState{};
    const waker: ?std.Thread = std.Thread.spawn(.{}, wakeLoop, .{ io, port, &signals.cancel_requested, &wstate.stop }) catch |err| blk: {
        std.debug.print("labelle: could not start the stop watcher ({s}); Ctrl+C ends the process without after-run hooks\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (waker) |t| {
        wstate.stop.store(true, .release);
        t.join();
    };

    // Start the file watcher before printing the banner so its status is
    // reflected. `wstate` lives on this frame — `serveAndOpen` blocks until
    // the stop is asked for, so it outlives the watcher thread and every
    // connection.
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

    serveLoop(io, allocator, &server, web_dir, project_web_dir, watch_state, &signals.cancel_requested);
    std.debug.print("\nlabelle: stopping server\n", .{});
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

// A stop request ends the accept loop — the path that makes the `after run`
// hooks after `serveAndOpen` reachable (Codex P2 on #420). The signal /
// console handler itself is interactive and is not driven here; the flag
// it sets and the waker's poke are.
test "serveLoop: returns on a stop request after serving what came before it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const web_dir = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(web_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "stop_test.html", .data = "<h1>still here</h1>" });

    const bound = testBindFreePort(io) orelse return error.NoFreePort;
    var server = bound.server;
    defer server.deinit(io);
    var cancel: std.atomic.Value(bool) = .init(false);
    const t = try std.Thread.spawn(.{}, serveLoop, .{ io, alloc, &server, web_dir, @as(?[]const u8, null), @as(?*WatchState, null), &cancel });

    // A request ahead of the stop is answered in full.
    const peer = std.Io.net.IpAddress.parse("127.0.0.1", bound.port) catch unreachable;
    {
        const s = try peer.connect(io, .{ .mode = .stream });
        defer s.close(io);
        var wbuf: [256]u8 = undefined;
        var w = s.writer(io, &wbuf);
        try w.interface.print("GET /stop_test.html HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", .{});
        try w.interface.flush();
        var rbuf: [4096]u8 = undefined;
        var r = s.reader(io, &rbuf);
        const response = try r.interface.allocRemaining(alloc, .unlimited);
        defer alloc.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "still here") != null);
    }

    // The stop: flag, then the same poke the waker thread sends. The join
    // completes only because the loop saw the flag — a loop that ignored it
    // would answer the poke, block in the next accept and never return.
    cancel.store(true, .release);
    wakeListener(io, bound.port);
    t.join();

    // Once set, the loop does not accept at all: a direct call returns
    // without touching the listener (nobody connects here).
    serveLoop(io, alloc, &server, web_dir, null, null, &cancel);
}
