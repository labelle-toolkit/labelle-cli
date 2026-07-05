const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const zig_toolchain = @import("zig_toolchain.zig");
const zig_cache = @import("zig_cache.zig");
const emsdk_toolchain = @import("emsdk_toolchain.zig");
const emsdk_cache = @import("emsdk_cache.zig");
const progress = @import("progress.zig");
const zig_progress = @import("zig_progress.zig");
const is_windows = builtin.os.tag == .windows;

/// Resolve the managed `zig` binary for `project_dir` (labelle-cli#279).
/// This is the ONE place spawns get a `zig` path — never PATH. Downloads +
/// verifies the required toolchain on a cache miss. Caller owns the slice.
pub fn resolveZigExe(allocator: std.mem.Allocator, project_dir: []const u8) ![]u8 {
    return zig_toolchain.resolveZig(allocator, project_dir);
}

/// PATH separator for the host (`;` on Windows, `:` elsewhere).
const path_sep = if (is_windows) ";" else ":";

/// Build an env map for a child `zig build` that targets wasm: the standard
/// `buildZigEnv` layer (ZIG_*_CACHE_DIR) PLUS the managed emsdk wiring
/// (labelle-cli#283) when a managed/overridden emcc is AVAILABLE. Exports:
///   - `EMSDK`      → the managed emsdk version dir
///   - `EM_CONFIG`  → its `.emscripten` (absolute paths into upstream/+node/)
///   - `PATH`       → the managed `upstream/emscripten` dir prepended, so a
///                    bare `emcc` resolves to the managed toolchain, never a
///                    PATH `emcc` (`/opt/homebrew/bin`, `~/emsdk`).
///
/// This is the emsdk analog of pointing every `zig` spawn at the managed
/// binary. It is intentionally NON-forcing: it uses
/// `resolveEmccIfAvailable`, so it never blocks a wasm build on a fresh
/// multi-hundred-MB `emsdk install/activate`. Provision the managed emsdk
/// ahead of time with `labelle install emsdk <ver>`, or point
/// `LABELLE_EMSDK`/`--emcc` at an existing emcc; when neither is present this
/// falls back to the plain Zig env (unchanged behavior for the current
/// zig-package emsdk build path). Caller owns the map.
pub fn buildWasmEnv(allocator: std.mem.Allocator, project_dir: []const u8) !std.process.Environ.Map {
    // Escape hatches (LABELLE_EMSDK / --emcc) short-circuit into a bare emcc
    // path; a managed emsdk is used only if already activated. No provisioning
    // side effect here.
    const emcc = (try emsdk_toolchain.resolveEmccIfAvailable(allocator, project_dir)) orelse
        return buildZigEnv(allocator, &.{});
    defer allocator.free(emcc);

    // The emsdk root is emcc's grandparent-of-grandparent:
    // <emsdk>/upstream/emscripten/emcc → <emsdk>. Derive it from `emcc` so an
    // overridden emcc (LABELLE_EMSDK/--emcc) still yields a coherent EMSDK.
    const emscripten_dir = std.fs.path.dirname(emcc) orelse emcc; // .../upstream/emscripten
    const upstream_dir = std.fs.path.dirname(emscripten_dir) orelse emscripten_dir; // .../upstream
    const emsdk_dir = std.fs.path.dirname(upstream_dir) orelse upstream_dir; // <emsdk>

    const em_config = try std.fs.path.join(allocator, &.{ emsdk_dir, emsdk_cache.em_config_name });
    defer allocator.free(em_config);

    // Prepend the emscripten bin dir to the inherited PATH.
    const old_path = config.globalEnviron().getAlloc(allocator, "PATH") catch |err| switch (err) {
        error.EnvironmentVariableMissing => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(old_path);
    const new_path = if (old_path.len > 0)
        try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ emscripten_dir, path_sep, old_path })
    else
        try allocator.dupe(u8, emscripten_dir);
    defer allocator.free(new_path);

    // Only export EMSDK/EM_CONFIG when the derived `.emscripten` actually
    // exists (a real activated-emsdk layout). For an escape-hatch emcc that
    // ISN'T in an emsdk layout (a system `/usr/bin/emcc`, a Homebrew emcc via
    // LABELLE_EMSDK/--emcc), the derived EMSDK/EM_CONFIG would be bogus paths
    // (`/`, `/.emscripten`) that BREAK an otherwise self-contained emcc. In
    // that case wire only PATH and leave any inherited EMSDK/EM_CONFIG intact
    // (buildZigEnv snapshots the parent env, so they are preserved).
    const has_config = blk: {
        std.Io.Dir.cwd().access(config.globalIo(), em_config, .{}) catch break :blk false;
        break :blk true;
    };
    if (has_config) {
        return buildZigEnv(allocator, &.{
            .{ .key = "EMSDK", .value = emsdk_dir },
            .{ .key = "EM_CONFIG", .value = em_config },
            .{ .key = "PATH", .value = new_path },
        });
    }
    return buildZigEnv(allocator, &.{
        .{ .key = "PATH", .value = new_path },
    });
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

/// Report a failed process spawn with the executable + cwd, so a missing
/// tool or DLL is diagnosable instead of surfacing as a bare
/// `error: FileNotFound` from main's default error printer (cli#277, cli#285).
/// On Windows a missing implicitly-linked DLL (e.g. SDL2.dll) also makes
/// process creation fail with FileNotFound, so the hint names it too.
fn reportSpawnFailure(err: anyerror, argv: []const []const u8, cwd: []const u8) void {
    if (err != error.FileNotFound) return;
    const exe = if (argv.len > 0) argv[0] else "(no executable)";
    std.debug.print("labelle: could not launch `{s}` in {s}\n", .{ exe, cwd });
    if (is_windows) {
        // On Windows a missing implicitly-linked DLL also surfaces as
        // FileNotFound from process creation, so name it here.
        std.debug.print(
            "  hint: the executable was not found on PATH, or a required DLL\n" ++
                "        (e.g. SDL2.dll) is missing next to it. Run `labelle doctor`\n" ++
                "        to check your toolchain and system libraries.\n",
            .{},
        );
    } else {
        std.debug.print(
            "  hint: the executable was not found on PATH or at that path. Run\n" ++
                "        `labelle doctor` to check your toolchain.\n",
            .{},
        );
    }
}

/// Run a zig command capturing stdout/stderr.
pub fn runZig(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(allocator, config.globalIo(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
    }) catch |err| {
        reportSpawnFailure(err, argv, cwd);
        return err;
    };
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
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .pgid = if (!is_windows and timeout_ns != null) 0 else null,
        .environ_map = environ_map,
    }) catch |err| {
        reportSpawnFailure(err, argv, cwd);
        return err;
    };

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

// ── Progress-attached build spawn (labelle-cli#284) ─────────────────────
//
// A Zig process spawned with `ZIG_PROGRESS=<fd>` in its environment
// reports its progress tree over that pipe (std.Progress IPC) instead of
// rendering to the terminal. The functions below attach that pipe to the
// `zig build` child and pump the decoded snapshots into a
// `progress.Reporter` (NDJSON / status file / spinner).
//
// What actually flows (empirical, Zig 0.16.0): a *compiler* process
// (`zig build-exe`) streams its full node tree — "Semantic Analysis",
// "Code Generation", "Linking" with real counts. The `zig build`
// *frontend*, however, only streams its own nodes ("Compile Build
// Script"); it hands the build runner a separate `-Z` integration handle
// and does not fold the runner's steps/compile subtree into its
// ZIG_PROGRESS packets. So today the feed gets live node names +
// keepalives from the frontend, while `step`/`total` stay null for `zig
// build`. `zig_progress.Parser` already decodes the full multi-node
// format (incl. the runner's "steps" node — unit-tested against
// synthesized packets), so richer data lights up without code changes if
// a future Zig relays it.
//
// Why the `/usr/bin/env ZIG_PROGRESS=<fd>` argv wrapper instead of putting
// the var in `environ_map`: `std.process.spawn` actively *strips* a
// `ZIG_PROGRESS` key from any user-supplied env block unless it manages
// the pipe itself via `options.progress_node` (see
// `Environ.Map.createPosixBlock` — a stale inherited fd number would be
// bogus, so std scrubs it). `progress_node` in turn requires a running
// `std.Progress` instance whose tree is not readable from outside std. The
// wrapper sets the variable *after* the env block is materialized, in the
// exec'd child itself, dodging the scrub while keeping the whole standard
// spawn path (cwd handling, spawn-failure reporting, etc.).
//
// The write end of the pipe has CLOEXEC cleared so it survives the
// `env` → `zig` execs. Windows passes handles instead of fd numbers and
// has no `env(1)`, so it (and any pipe/spawn failure) falls back to
// phase-level heartbeats — same schema, just no node names.

/// Shared state between the spawning thread and the progress pump thread.
const PumpCtx = struct {
    fd: std.posix.fd_t,
    reporter: *progress.Reporter,
    /// Set after `child.wait` returns; the pump drains remaining packets
    /// and exits on the next empty read.
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// `LABELLE_PROGRESS_DEBUG=1`: log each new node name to stderr —
    /// handy for tuning the link heuristic / studio integration.
    debug: bool = false,
};

/// Read the `ZIG_PROGRESS` pipe until EOF (all write ends closed — child
/// tree exited) or until `stop` is set and the pipe is drained. Feeds
/// decoded snapshots into the reporter; emits heartbeats while the pipe is
/// quiet so `elapsed_ms` (and the spinner) stay live.
fn pumpZigProgress(ctx: *PumpCtx) void {
    var parser = zig_progress.Parser{};
    var read_buf: [4096]u8 = undefined;
    var last_detail: [zig_progress.max_name_len]u8 = undefined;
    var last_detail_len: usize = 0;
    while (true) {
        const n = std.posix.read(ctx.fd, &read_buf) catch |err| switch (err) {
            error.WouldBlock => {
                if (ctx.stop.load(.acquire)) return;
                ctx.reporter.heartbeat();
                sleepNanos(80 * std.time.ns_per_ms);
                continue;
            },
            else => return,
        };
        if (n == 0) return; // EOF
        parser.feed(read_buf[0..n]);
        const snap = parser.poll() orelse continue;
        ctx.reporter.compileUpdate(snap.step, snap.total, snap.detail(), snap.saw_link);
        if (ctx.debug and !std.mem.eql(u8, snap.detail(), last_detail[0..last_detail_len])) {
            std.debug.print("labelle-progress: node \"{s}\" [{?d}/{?d}] link={}\n", .{
                snap.detail(), snap.step, snap.total, snap.saw_link,
            });
            last_detail_len = snap.detail().len;
            @memcpy(last_detail[0..last_detail_len], snap.detail());
        }
    }
}

/// Create the progress pipe: read end parent-only (CLOEXEC) and
/// nonblocking (the pump polls it), write end inheritable (no CLOEXEC —
/// it must survive the exec) and nonblocking (a stalled parent must never
/// block the compiler; matches how std's own spawn configures it).
fn makeProgressPipe() ?[2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return null;
    _ = std.posix.system.fcntl(fds[0], std.posix.F.SETFD, @as(usize, std.posix.FD_CLOEXEC));
    setNonblocking(fds[0]);
    setNonblocking(fds[1]);
    return fds;
}

fn setNonblocking(fd: std.posix.fd_t) void {
    const fl = std.posix.system.fcntl(fd, std.posix.F.GETFL, @as(usize, 0));
    if (fl < 0) return;
    const nonblock: u32 = @bitCast(std.c.O{ .NONBLOCK = true });
    _ = std.posix.system.fcntl(fd, std.posix.F.SETFL, @as(usize, @intCast(fl)) | nonblock);
}

fn closeFd(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

fn termToExitCode(term: anytype) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| blk: {
            std.debug.print("labelle: killed by signal {d}\n", .{@intFromEnum(sig)});
            break :blk 1;
        },
        .stopped => |sig| blk: {
            std.debug.print("labelle: stopped by signal {d}\n", .{@intFromEnum(sig)});
            break :blk 1;
        },
        .unknown => |val| blk: {
            std.debug.print("labelle: unknown termination {d}\n", .{val});
            break :blk 1;
        },
    };
}

/// Like `runZigInheritWithEnv` (inherited stdio — compile errors stream to
/// the terminal unaltered), but attaches Zig's `std.Progress` IPC pipe and
/// folds the decoded step/total/current-unit updates into `reporter`'s
/// compile/link phases. Falls back to phase-level heartbeats when the pipe
/// can't be attached (Windows, no `/usr/bin/env`, pipe failure).
pub fn runZigInheritProgress(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
    reporter: *progress.Reporter,
) !u8 {
    if (comptime is_windows) {
        // ZIG_PROGRESS on Windows carries a HANDLE value that must be
        // injected by the spawner itself; there is no wrapper trick.
        return runZigInheritHeartbeat(allocator, cwd, argv, environ_map, reporter);
    }
    const fds = makeProgressPipe() orelse
        return runZigInheritHeartbeat(allocator, cwd, argv, environ_map, reporter);

    var fd_env_buf: [32]u8 = undefined;
    const fd_env = std.fmt.bufPrint(&fd_env_buf, "ZIG_PROGRESS={d}", .{fds[1]}) catch unreachable;

    var wrapped: std.ArrayList([]const u8) = .empty;
    defer wrapped.deinit(allocator);
    try wrapped.append(allocator, "/usr/bin/env");
    try wrapped.append(allocator, fd_env);
    try wrapped.appendSlice(allocator, argv);

    const io = config.globalIo();
    var child = std.process.spawn(io, .{
        .argv = wrapped.items,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = environ_map,
    }) catch |err| {
        closeFd(fds[0]);
        closeFd(fds[1]);
        if (err == error.FileNotFound) {
            // `/usr/bin/env` missing is indistinguishable from a missing
            // zig here; retry unwrapped so success — or the error report —
            // is attributed to the real binary.
            return runZigInheritHeartbeat(allocator, cwd, argv, environ_map, reporter);
        }
        reportSpawnFailure(err, argv, cwd);
        return err;
    };
    // The child holds its own copy of the write end; drop ours so the pump
    // sees EOF when the child process tree exits.
    closeFd(fds[1]);

    const debug_progress = blk: {
        const v = config.globalEnviron().getAlloc(allocator, "LABELLE_PROGRESS_DEBUG") catch break :blk false;
        defer allocator.free(v);
        break :blk v.len > 0 and !std.mem.eql(u8, v, "0");
    };
    var ctx = PumpCtx{ .fd = fds[0], .reporter = reporter, .debug = debug_progress };
    // If the pump thread can't start, the build still runs — the child's
    // nonblocking writes fail once the pipe fills and it carries on; we
    // just lose granularity.
    const pump_thread: ?std.Thread = std.Thread.spawn(.{}, pumpZigProgress, .{&ctx}) catch null;
    defer {
        ctx.stop.store(true, .release);
        if (pump_thread) |t| t.join();
        closeFd(fds[0]);
    }

    const term = try child.wait(io);
    return termToExitCode(term);
}

/// Fallback: no IPC granularity available — run with inherited stdio and
/// tick the reporter every 500ms so `elapsed_ms`/spinner (and the status
/// file) keep moving during the compile.
fn runZigInheritHeartbeat(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
    environ_map: ?*const std.process.Environ.Map,
    reporter: *progress.Reporter,
) !u8 {
    const Beat = struct {
        reporter: *progress.Reporter,
        stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(b: *@This()) void {
            while (!b.stop.load(.acquire)) {
                b.reporter.heartbeat();
                sleepNanos(500 * std.time.ns_per_ms);
            }
        }
    };
    var beat = Beat{ .reporter = reporter };
    const thread: ?std.Thread = std.Thread.spawn(.{}, Beat.run, .{&beat}) catch null;
    defer if (thread) |t| {
        beat.stop.store(true, .release);
        t.join();
    };
    return runZigInheritWithEnv(allocator, cwd, argv, null, environ_map);
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
    // `--list-steps`: the probe only exists to trigger the manifest
    // fingerprint validation (which happens during configuration, before
    // any step runs) and read the `use this value:` hint. A bare `zig
    // build` here did the project's ENTIRE first compile captured and
    // silent whenever the generated zon already carried a correct
    // fingerprint — swallowing the real build into this probe (~0.15s vs
    // minutes; found while wiring the cli#284 progress feed, which showed
    // the cold compile landing inside the "generate" phase).
    const result = try runZigWithEnv(allocator, output_dir, &.{ zig_exe, "build", "--list-steps" }, &zig_env);
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
