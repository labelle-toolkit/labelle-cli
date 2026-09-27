//! Minimal static file server for serving WASM builds locally.
//! Serves files from `web_dir` on 127.0.0.1:`port`, opens the default
//! browser, and runs until the process is interrupted (Ctrl+C).
//!
//! Single-threaded, one connection at a time — a dev-only serve loop
//! for a single browser tab, not a production server. Built directly
//! on `std.Io.net.Server` (socket) + `std.http.Server` (HTTP/1.1) so
//! the CLI keeps a zero-dependency graph.
//!
//! Thin root: the implementation lives in `serve/`, one responsibility
//! per file, and this file re-exports the public API.
//!
//!   serve/server.zig    `serveAndOpen`, the accept loop, browser launch
//!   serve/http.zig      one request: routing, MIME, live-reload endpoint
//!   serve/cancel.zig    Ctrl+C / SIGTERM / console handler and the waker
//!   serve/watch.zig     `--watch` config, shared state, the watcher thread
//!   serve/baseline.zig  `WatchBaseline`: follow-up / cap / ceiling policy
//!   serve/tree.zig      tree signatures, snapshots and the walk
//!   serve/testing.zig   helpers shared by the tests above

/// The stop flag and its handler; `cancel.cancel_requested` is the flag.
pub const cancel = @import("serve/cancel.zig");
const server = @import("serve/server.zig");
const http = @import("serve/http.zig");
const watch = @import("serve/watch.zig");
const baseline = @import("serve/baseline.zig");
const tree = @import("serve/tree.zig");
const testing = @import("serve/testing.zig");

pub const installCancelHandler = cancel.installCancelHandler;
pub const serveAndOpen = server.serveAndOpen;
pub const RebuildFn = watch.RebuildFn;
pub const WatchConfig = watch.WatchConfig;
pub const watchIgnorePath = tree.watchIgnorePath;

// Reference every module so its tests run: a file reached only lazily
// (or not at all from here) would silently drop out of `zig build test`.
test {
    _ = cancel;
    _ = server;
    _ = http;
    _ = watch;
    _ = baseline;
    _ = tree;
    _ = testing;
}
