//! Graceful stop for long-lived sessions: the POSIX signal / Windows
//! console control handler that sets `cancel_requested` and forwards the
//! stop to the supervised child trees (`supervise.zig`).
//!
//! Ctrl+C / SIGTERM (POSIX) or a console Ctrl+C / Ctrl+Break / close
//! (Windows) sets `cancel_requested`, which the session's loop observes to
//! return cleanly so the caller can run what follows it (the `after run`
//! provider hooks, cleanup). On POSIX the signal is also forwarded to every
//! attached supervised group: those children run in their own process
//! groups, which the terminal's Ctrl+C does not reach. On Windows every
//! child shares the console and receives the event itself. A repeated stop
//! kills every supervised tree; with none registered it ends the process
//! (POSIX: status 130; Windows: the console's default handling).
//! Windows Ctrl+C handling is compile-checked only: CI cannot raise a
//! console control event.
const std = @import("std");
const builtin = @import("builtin");
const supervise = @import("../supervise.zig");

/// Set once a stop was asked for; a session loop returns when it sees it.
pub var cancel_requested: std.atomic.Value(bool) = .init(false);

/// Register the stop handler for this process. Idempotent.
pub fn installCancelHandler() void {
    if (builtin.os.tag == .windows) {
        _ = SetConsoleCtrlHandler(consoleCtrl, .TRUE);
    } else {
        var act: std.posix.Sigaction = .{
            .handler = .{ .handler = onSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &act, null);
        std.posix.sigaction(.TERM, &act, null);
    }
}

/// Async-signal-safe: an atomic swap and `kill(2)` calls. The first stop
/// is forwarded as the same signal; the repeat kills every supervised
/// tree, or ends the process when there is none.
fn onSignal(sig: std.posix.SIG) callconv(.c) void {
    if (cancel_requested.swap(true, .acq_rel)) {
        if (supervise.forwardAll(.kill) == 0) std.c._exit(130);
        return;
    }
    _ = supervise.forwardAll(if (sig == .TERM) .terminate else .interrupt);
}

const HandlerRoutine = *const fn (ctrl_type: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?HandlerRoutine, add: std.os.windows.BOOL) callconv(.winapi) std.os.windows.BOOL;

/// Runs on a console-owned thread. Returning TRUE claims the event; the
/// repeat returns FALSE so the console's default handling ends the process.
fn consoleCtrl(_: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
    if (!cancel_requested.swap(true, .acq_rel)) return .TRUE;
    return if (supervise.forwardAll(.kill) == 0) .FALSE else .TRUE;
}
