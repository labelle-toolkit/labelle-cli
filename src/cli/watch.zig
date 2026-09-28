//! Generic file watching for long-lived sessions (RFC cli#466 §3.4): the
//! tree signatures, the debounce/settle policy, the watcher loop, the stop
//! handler and the "last successful output" publication. Nothing here
//! knows what is built or who consumes it.
//!
//! Thin root: the implementation lives in `watch/`, one responsibility per
//! file, and this file re-exports the public API.
//!
//!   watch/loop.zig      `WatchConfig`, `WatchState`, the watcher thread body
//!   watch/baseline.zig  `WatchBaseline`: follow-up / cap / ceiling policy
//!   watch/tree.zig      tree signatures, snapshots and the walk
//!   watch/cancel.zig    Ctrl+C / SIGTERM / console handler and forwarding
//!   watch/publish.zig   published generations, the output link, the
//!                       generation file
//!   watch/testing.zig   helpers shared by the tests above

pub const cancel = @import("watch/cancel.zig");
pub const loop = @import("watch/loop.zig");
pub const publish = @import("watch/publish.zig");
const baseline = @import("watch/baseline.zig");
const tree = @import("watch/tree.zig");
const testing = @import("watch/testing.zig");

pub const installCancelHandler = cancel.installCancelHandler;
pub const RebuildFn = loop.RebuildFn;
pub const WatchConfig = loop.WatchConfig;
pub const WatchState = loop.WatchState;
pub const IgnoreSet = loop.IgnoreSet;
pub const watchLoop = loop.watchLoop;
pub const watchIgnorePath = tree.watchIgnorePath;
pub const TreeSignature = tree.TreeSignature;
pub const computeSignature = tree.computeSignature;
pub const Publisher = publish.Publisher;
pub const SessionLock = publish.SessionLock;

// Reference every module so its tests run.
test {
    _ = cancel;
    _ = loop;
    _ = publish;
    _ = baseline;
    _ = tree;
    _ = testing;
}
