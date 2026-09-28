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

/// What a stop does, on every host: the FIRST one is latched on every
/// attached supervised group and forwarded to their trees (a child that
/// registers later is stopped the moment it registers, so no stop is lost
/// before the session's child exists); a REPEATED one kills every tree,
/// and asks the caller to end the process when there is none.
/// Async-signal-safe: atomic operations and `kill(2)` / job calls only.
pub fn handleStop(sig: supervise.Stop) enum { handled, exit } {
    if (cancel_requested.swap(true, .acq_rel)) {
        return if (supervise.forwardAll(.kill) == 0) .exit else .handled;
    }
    _ = supervise.forwardAll(sig);
    return .handled;
}

fn onSignal(sig: std.posix.SIG) callconv(.c) void {
    if (handleStop(if (sig == .TERM) .terminate else .interrupt) == .exit) std.c._exit(130);
}

const HandlerRoutine = *const fn (ctrl_type: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?HandlerRoutine, add: std.os.windows.BOOL) callconv(.winapi) std.os.windows.BOOL;

/// Runs on a console-owned thread. The first event is latched like a POSIX
/// signal (every child attached to the console already received it; one
/// that starts later is stopped when it registers); returning TRUE claims
/// it. A repeat with no tree left returns FALSE so the console's default
/// handling ends the process.
fn consoleCtrl(_: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
    return if (handleStop(.interrupt) == .exit) .FALSE else .TRUE;
}

test "handleStop: the first stop is latched on every attached group, on every host" {
    const saved = cancel_requested.swap(false, .acq_rel);
    defer cancel_requested.store(saved, .release);
    var group: supervise.Group = .{};
    group.attach();
    defer group.detach();
    // The console handler and the signal handler both go through this.
    try std.testing.expectEqual(.handled, handleStop(.interrupt));
    try std.testing.expect(group.pending.load(.seq_cst) == @as(u8, @intFromEnum(supervise.Stop.interrupt)) + 1);
    // A repeat with no tree registered asks the caller to end the process.
    try std.testing.expectEqual(.exit, handleStop(.interrupt));
}
