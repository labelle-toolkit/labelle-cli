const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

const windows = if (is_windows) struct {
    extern "kernel32" fn GetProcessId(Process: std.os.windows.HANDLE) callconv(.c) std.os.windows.DWORD;
} else struct {};

/// Shared state between the main thread and the timeout thread.
/// Heap-allocated so it outlives the spawning stack frame.
const TimeoutState = struct {
    timed_out: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Run a zig command capturing stdout/stderr.
pub fn runZig(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !std.process.Child.RunResult {
    return std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
    });
}

/// Run a zig command with inherited stdio (output goes straight to terminal).
/// Optionally kills the process after `timeout_ns` nanoseconds.
pub fn runZigInherit(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8, timeout_ns: ?u64) !u8 {
    var child: std.process.Child = .init(argv, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    if (!is_windows and timeout_ns != null) child.pgid = 0;
    try child.spawn();

    // Heap-allocate so the detached thread can safely access it after this function returns
    var state: ?*TimeoutState = null;
    defer if (state) |s| allocator.destroy(s);

    if (timeout_ns) |ns| {
        state = try allocator.create(TimeoutState);
        state.?.* = .{};

        if (is_windows) {
            const win_pid = windows.GetProcessId(child.id);
            const thread = try std.Thread.spawn(.{}, timeoutKillWindows, .{ allocator, win_pid, ns, state.? });
            thread.detach();
        } else {
            const thread = try std.Thread.spawn(.{}, timeoutKillPosix, .{ child.id, ns, state.? });
            thread.detach();
        }
    }

    const term = try child.wait();

    const did_timeout = if (state) |s| s.timed_out.load(.acquire) else false;

    return switch (term) {
        .Exited => |code| blk: {
            if (did_timeout) {
                std.debug.print("\nlabelle: timed out\n", .{});
                break :blk 0;
            }
            break :blk code;
        },
        .Signal => |sig| {
            if (did_timeout) {
                std.debug.print("\nlabelle: timed out\n", .{});
                return 0;
            }
            std.debug.print("labelle: killed by signal {d}\n", .{sig});
            return 1;
        },
        .Stopped => |sig| {
            std.debug.print("labelle: stopped by signal {d}\n", .{sig});
            return 1;
        },
        .Unknown => |val| {
            std.debug.print("labelle: unknown termination {d}\n", .{val});
            return 1;
        },
    };
}

fn timeoutKillPosix(pid: std.process.Child.Id, timeout_ns: u64, state: *TimeoutState) void {
    std.Thread.sleep(timeout_ns);
    state.timed_out.store(true, .release);
    const pgid: std.posix.pid_t = -@as(std.posix.pid_t, @intCast(pid));
    std.posix.kill(pgid, std.posix.SIG.TERM) catch |err| {
        if (err != error.ProcessNotFound) {
            std.debug.print("labelle: timeout kill failed: {any}\n", .{err});
        }
    };
}

fn timeoutKillWindows(allocator: std.mem.Allocator, pid: std.os.windows.DWORD, timeout_ns: u64, state: *TimeoutState) void {
    std.Thread.sleep(timeout_ns);
    state.timed_out.store(true, .release);
    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return;
    const argv = [_][]const u8{ "taskkill", "/F", "/T", "/PID", pid_str };
    var kill_child: std.process.Child = .init(&argv, allocator);
    kill_child.stdin_behavior = .Ignore;
    kill_child.stdout_behavior = .Ignore;
    kill_child.stderr_behavior = .Ignore;
    kill_child.spawn() catch return;
    _ = kill_child.wait() catch {};
}

/// Run `zig build` in output_dir, parse the fingerprint error, and patch build.zig.zon.
pub fn fixFingerprint(allocator: std.mem.Allocator, output_dir: []const u8) !void {
    const zon_path = try std.fs.path.join(allocator, &.{ output_dir, "build.zig.zon" });
    defer allocator.free(zon_path);

    const result = try runZig(allocator, output_dir, &.{ "zig", "build" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const marker = "use this value: ";
    if (std.mem.indexOf(u8, result.stderr, marker)) |idx| {
        const start = idx + marker.len;
        var end = start;
        while (end < result.stderr.len and result.stderr[end] != '\n' and result.stderr[end] != ';') {
            end += 1;
        }
        const suggested = result.stderr[start..end];

        const zon_content = try std.fs.cwd().readFileAlloc(allocator, zon_path, 1024 * 1024);
        defer allocator.free(zon_content);

        const fp_marker = ".fingerprint = ";
        if (std.mem.indexOf(u8, zon_content, fp_marker)) |fp_idx| {
            const val_start = fp_idx + fp_marker.len;
            var val_end = val_start;
            while (val_end < zon_content.len and zon_content[val_end] != ',') {
                val_end += 1;
            }

            var new_content: std.ArrayList(u8) = .{};
            defer new_content.deinit(allocator);
            try new_content.appendSlice(allocator, zon_content[0..val_start]);
            try new_content.appendSlice(allocator, suggested);
            try new_content.appendSlice(allocator, zon_content[val_end..]);

            const file = try std.fs.cwd().createFile(zon_path, .{});
            defer file.close();
            try file.writeAll(new_content.items);
        }
    }
}
