const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const zig_toolchain = @import("zig_toolchain.zig");
const zig_cache = @import("zig_cache.zig");
const is_windows = builtin.os.tag == .windows;

/// Resolve the managed `zig` binary for `project_dir` (labelle-cli#279).
/// This is the ONE place spawns get a `zig` path — never PATH. Downloads +
/// verifies the required toolchain on a cache miss. Caller owns the slice.
pub fn resolveZigExe(allocator: std.mem.Allocator, project_dir: []const u8) ![]u8 {
    return zig_toolchain.resolveZig(allocator, project_dir);
}

/// Build an env map for a child `zig` that inherits the parent environment
/// and adds `ZIG_GLOBAL_CACHE_DIR` / `ZIG_LOCAL_CACHE_DIR` pointing into the
/// labelle cache tree, plus any `extras`. Keeps the compiler's own cache in
/// user-writable space (never next to a read-only install). Caller owns the
/// map and must `deinit()` it after the child is waited on.
pub fn buildZigEnv(allocator: std.mem.Allocator, extras: []const EnvKV) !std.process.Environ.Map {
    const global = try zig_cache.globalCacheDir(allocator);
    defer allocator.free(global);
    const local = try zig_cache.localCacheDir(allocator);
    defer allocator.free(local);
    // Ensure the dirs exist so zig doesn't choke on a missing cache root.
    std.Io.Dir.cwd().createDirPath(config.globalIo(), global) catch {};
    std.Io.Dir.cwd().createDirPath(config.globalIo(), local) catch {};

    var all: std.ArrayList(EnvKV) = .empty;
    defer all.deinit(allocator);
    try all.append(allocator, .{ .key = "ZIG_GLOBAL_CACHE_DIR", .value = global });
    try all.append(allocator, .{ .key = "ZIG_LOCAL_CACHE_DIR", .value = local });
    try all.appendSlice(allocator, extras);
    return buildEnvironWithExtra(allocator, all.items);
}

const windows = if (is_windows) struct {
    extern "kernel32" fn GetProcessId(Process: std.os.windows.HANDLE) callconv(.c) std.os.windows.DWORD;
} else struct {};

/// Shared state between the main thread and the timeout thread.
/// Heap-allocated so it outlives the spawning stack frame.
const TimeoutState = struct {
    allocator: std.mem.Allocator,
    timed_out: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Both the main thread and the detached timeout thread hold a reference
    // (init 2); whoever drops the last one frees it. Without this the main
    // thread's `defer` frees `state` as soon as `child.wait` returns — and if
    // the child exits BEFORE the timeout fires, the still-sleeping timeout
    // thread then writes `timed_out` into freed memory (use-after-free).
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(2),

    fn release(self: *TimeoutState) void {
        // `.acq_rel`: the decrement publishes our writes to other releasers
        // and, on the last decrement, observes theirs before we destroy.
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            self.allocator.destroy(self);
        }
    }
};

/// Run a zig command capturing stdout/stderr.
pub fn runZig(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(allocator, config.globalIo(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
    });
}

/// Like `runZig`, but with an optional environment map (used to inject
/// `ZIG_*_CACHE_DIR` — see `buildZigEnv`). When null, inherits the parent env.
pub fn runZigWithEnv(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
) !std.process.RunResult {
    return std.process.run(allocator, config.globalIo(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = environ_map,
    });
}

/// Run a zig command with inherited stdio (output goes straight to terminal).
/// Optionally kills the process after `timeout_ns` nanoseconds.
///
/// `environ_map`, when non-null, *replaces* the child's environment block.
/// Callers that need to *augment* the parent env (e.g. to inject
/// `LABELLE_SCENE` for the cli#229 runtime scene-override flow, or
/// `LABELLE_SCREENSHOT_PATH` for the cli#227 screenshot flow) should
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
    defer if (state) |s| s.release();

    if (timeout_ns) |ns| {
        state = try allocator.create(TimeoutState);
        state.?.* = .{ .allocator = allocator };

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
    // `Environ.createMap` is the platform-correct snapshot: on Windows the
    // inherited environment is a *global* block (read live from the PEB),
    // NOT a `WindowsBlock` slice, so the old `switch (@TypeOf(block))` hit
    // the global branch and produced an extras-ONLY map — stripping PATH,
    // LOCALAPPDATA, etc. That made every env-injecting `run` flag
    // (--headless/--scene/--screenshot/--profile) fail with
    // `AppDataDirUnavailable` because the child `zig build` lost its cache
    // dir. createMap reads the PEB on Windows, `environ` on POSIX, and the
    // WASI environ API on WASI, so the parent env is preserved everywhere.
    const environ = config.globalEnviron();
    var map = try environ.createMap(allocator);
    errdefer map.deinit();

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

/// Grace period between the SIGTERM and the SIGKILL escalation below.
const KILL_GRACE_NS: u64 = 2 * std.time.ns_per_s;

fn timeoutKillPosix(pid: std.process.Child.Id, timeout_ns: u64, state: *TimeoutState) void {
    defer state.release();
    sleepNanos(timeout_ns);
    state.timed_out.store(true, .release);
    // Negative pid = the child's whole process group. The child was spawned
    // with `.pgid = 0`, so it leads its own group — this signals only THIS
    // game's process tree (game + its `zig build run` parent), never any
    // other game that happens to be running.
    const pgid: std.posix.pid_t = -@as(std.posix.pid_t, @intCast(pid));
    // SIGTERM first, so a game that installs a handler can tear down its
    // GPU/window cleanly.
    std.posix.kill(pgid, std.posix.SIG.TERM) catch |err| {
        if (err != error.ProcessNotFound) {
            std.debug.print("labelle: timeout kill failed: {any}\n", .{err});
        }
    };
    // Escalate to SIGKILL. The bgfx/raylib game traps SIGTERM (it installs a
    // handler for that clean teardown), so it can also just ignore it —
    // leaving `child.wait()` to block forever and the game orphaned (the
    // long-standing "labelle run --timeout doesn't terminate" symptom).
    // SIGKILL can't be trapped. Still scoped to the same process group, so
    // other running games are untouched. If the game DID exit on SIGTERM,
    // `child.wait()` has already returned and `labelle` exits before this
    // grace elapses — this detached thread dies with the process — so the
    // SIGKILL only ever fires on a game that actually ignored SIGTERM.
    sleepNanos(KILL_GRACE_NS);
    std.posix.kill(pgid, std.posix.SIG.KILL) catch |err| {
        if (err != error.ProcessNotFound) {
            std.debug.print("labelle: timeout SIGKILL failed: {any}\n", .{err});
        }
    };
}

fn timeoutKillWindows(allocator: std.mem.Allocator, pid: std.os.windows.DWORD, timeout_ns: u64, state: *TimeoutState) void {
    _ = allocator;
    defer state.release();
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
pub fn fixFingerprints(allocator: std.mem.Allocator, project_dir: []const u8, output_dir: []const u8) !void {
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
        try fixFingerprint(allocator, project_dir, sub_path);
    }
}

/// Run `zig build` in output_dir, parse the fingerprint error, and patch build.zig.zon.
pub fn fixFingerprint(allocator: std.mem.Allocator, project_dir: []const u8, output_dir: []const u8) !void {
    const io = config.globalIo();
    const zon_path = try std.fs.path.join(allocator, &.{ output_dir, "build.zig.zon" });
    defer allocator.free(zon_path);

    const zig_exe = try resolveZigExe(allocator, project_dir);
    defer allocator.free(zig_exe);
    // Give the fingerprint build the same ZIG_*_CACHE_DIR wiring as every
    // other managed spawn, so its compiler cache lands in user-writable space.
    var zig_env = try buildZigEnv(allocator, &.{});
    defer zig_env.deinit();
    const result = try runZigWithEnv(allocator, output_dir, &.{ zig_exe, "build" }, &zig_env);
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
