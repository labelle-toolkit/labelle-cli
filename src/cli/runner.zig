const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
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
pub fn runZig(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(allocator, config.globalIo(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
    });
}

/// Run a zig command with inherited stdio (output goes straight to terminal).
/// Optionally kills the process after `timeout_ns` nanoseconds.
///
/// `environ_map`, when non-null, *replaces* the child's environment block.
/// Callers that need to *augment* the parent env (e.g. to inject
/// `LABELLE_SCENE` for the cli#229 runtime scene-override flow) should
/// build the map by snapshotting the current process environ and adding
/// the extra entries on top — see `runZigInheritWithEnv` below.
pub fn runZigInherit(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8, timeout_ns: ?u64) !u8 {
    return runZigInheritWithEnv(allocator, cwd, argv, timeout_ns, null);
}

/// Like `runZigInherit`, but accepts an optional environment map that
/// replaces the child's environ when non-null. The map must already
/// contain everything the child needs (parent env + extra keys); see
/// `buildEnvironWithExtra` for the standard snapshot-and-add helper.
pub fn runZigInheritWithEnv(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
    timeout_ns: ?u64,
    environ_map: ?*const std.process.Environ.Map,
) !u8 {
    const io = config.globalIo();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .pgid = if (!is_windows and timeout_ns != null) 0 else null,
        .environ_map = environ_map,
    });

    // Heap-allocate so the detached thread can safely access it after this function returns
    var state: ?*TimeoutState = null;
    defer if (state) |s| allocator.destroy(s);

    if (timeout_ns) |ns| {
        state = try allocator.create(TimeoutState);
        state.?.* = .{};

        if (is_windows) {
            const win_pid = windows.GetProcessId(child.id.?);
            const thread = try std.Thread.spawn(.{}, timeoutKillWindows, .{ allocator, win_pid, ns, state.? });
            thread.detach();
        } else {
            const thread = try std.Thread.spawn(.{}, timeoutKillPosix, .{ child.id.?, ns, state.? });
            thread.detach();
        }
    }

    const term = try child.wait(io);

    const did_timeout = if (state) |s| s.timed_out.load(.acquire) else false;

    return switch (term) {
        .exited => |code| blk: {
            if (did_timeout) {
                std.debug.print("\nlabelle: timed out\n", .{});
                break :blk 0;
            }
            break :blk code;
        },
        .signal => |sig| {
            if (did_timeout) {
                std.debug.print("\nlabelle: timed out\n", .{});
                return 0;
            }
            std.debug.print("labelle: killed by signal {d}\n", .{@intFromEnum(sig)});
            return 1;
        },
        .stopped => |sig| {
            std.debug.print("labelle: stopped by signal {d}\n", .{@intFromEnum(sig)});
            return 1;
        },
        .unknown => |val| {
            std.debug.print("labelle: unknown termination {d}\n", .{val});
            return 1;
        },
    };
}

/// Build a fresh `Environ.Map` that mirrors the current process's
/// environment block plus the entries in `extras`. The caller owns the
/// returned map and must `deinit()` it after the spawned child has
/// been waited on.
///
/// This exists because Zig's `process.spawn` treats `environ_map` as a
/// *replacement* for the parent block — passing a one-entry map would
/// strip PATH, HOME, etc. The cli#229 `LABELLE_SCENE` flow wants
/// "parent env + one extra var," so we snapshot first.
pub const EnvKV = struct { key: []const u8, value: []const u8 };

pub fn buildEnvironWithExtra(
    allocator: std.mem.Allocator,
    extras: []const EnvKV,
) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();

    const environ = config.globalEnviron();
    const block = environ.block;
    switch (@TypeOf(block)) {
        std.process.Environ.PosixBlock => try map.putPosixBlock(block.view()),
        std.process.Environ.WindowsBlock => try map.putWindowsBlock(block.view()),
        std.process.Environ.GlobalBlock => {
            // Nothing to snapshot for global blocks — extras-only env.
        },
        else => @compileError("unsupported Environ.Block variant"),
    }

    for (extras) |kv| {
        try map.put(kv.key, kv.value);
    }
    return map;
}

fn sleepNanos(ns: u64) void {
    // 0.16 removed std.Thread.sleep / std.posix.nanosleep. Use libc
    // nanosleep on POSIX and Win32 Sleep on Windows.
    if (@import("builtin").os.tag == .windows) {
        const SleepFn = struct {
            extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
        };
        const ms = @as(u32, @intCast(@min(ns / std.time.ns_per_ms, std.math.maxInt(u32))));
        SleepFn.Sleep(ms);
        return;
    }
    var req: std.c.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.c.timespec = undefined;
    while (true) {
        const rc = std.c.nanosleep(&req, &rem);
        if (rc == 0) return;
        // EINTR — retry with the remaining duration.
        req = rem;
    }
}

fn timeoutKillPosix(pid: std.process.Child.Id, timeout_ns: u64, state: *TimeoutState) void {
    sleepNanos(timeout_ns);
    state.timed_out.store(true, .release);
    const pgid: std.posix.pid_t = -@as(std.posix.pid_t, @intCast(pid));
    std.posix.kill(pgid, std.posix.SIG.TERM) catch |err| {
        if (err != error.ProcessNotFound) {
            std.debug.print("labelle: timeout kill failed: {any}\n", .{err});
        }
    };
}

fn timeoutKillWindows(allocator: std.mem.Allocator, pid: std.os.windows.DWORD, timeout_ns: u64, state: *TimeoutState) void {
    _ = allocator;
    sleepNanos(timeout_ns);
    state.timed_out.store(true, .release);
    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return;
    const argv = [_][]const u8{ "taskkill", "/F", "/T", "/PID", pid_str };
    const io = config.globalIo();
    var kill_child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = kill_child.wait(io) catch {};
}

/// Iterate over every immediate subdir of `.labelle/` that contains a
/// `build.zig.zon` and patch its fingerprint. The assembler emits one
/// dir per target (e.g. `raylib_desktop/`, plus `tests/` from 0.14.0),
/// and each generated zon ships a placeholder fingerprint that needs
/// replacing with the value Zig computes from the dir's actual path.
pub fn fixFingerprints(allocator: std.mem.Allocator, output_dir: []const u8) !void {
    const io = config.globalIo();
    var dir = std.Io.Dir.cwd().openDir(io, output_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const sub_path = try std.fs.path.join(allocator, &.{ output_dir, entry.name });
        defer allocator.free(sub_path);
        const zon_path = try std.fs.path.join(allocator, &.{ sub_path, "build.zig.zon" });
        defer allocator.free(zon_path);
        std.Io.Dir.cwd().access(io, zon_path, .{}) catch continue;
        try fixFingerprint(allocator, sub_path);
    }
}

/// Run `zig build` in output_dir, parse the fingerprint error, and patch build.zig.zon.
pub fn fixFingerprint(allocator: std.mem.Allocator, output_dir: []const u8) !void {
    const io = config.globalIo();
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

        const zon_content = try std.Io.Dir.cwd().readFileAlloc(io, zon_path, allocator, .limited(1024 * 1024));
        defer allocator.free(zon_content);

        const fp_marker = ".fingerprint = ";
        if (std.mem.indexOf(u8, zon_content, fp_marker)) |fp_idx| {
            const val_start = fp_idx + fp_marker.len;
            var val_end = val_start;
            while (val_end < zon_content.len and zon_content[val_end] != ',') {
                val_end += 1;
            }

            var new_content: std.ArrayList(u8) = .empty;
            defer new_content.deinit(allocator);
            try new_content.appendSlice(allocator, zon_content[0..val_start]);
            try new_content.appendSlice(allocator, suggested);
            try new_content.appendSlice(allocator, zon_content[val_end..]);

            try std.Io.Dir.cwd().writeFile(io, .{
                .sub_path = zon_path,
                .data = new_content.items,
            });
        }
    }
}
