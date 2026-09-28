//! Supervised child processes for long-lived sessions (`labelle run
//! --watch`): every child a supervised thread spawns leads its own process
//! tree that the session can signal, cancel and reap as one unit, so no
//! child outlives the command (RFC cli#466 §4).
//!
//! A thread opts in by setting `current` to a `Group`; every spawn helper
//! in the CLI (`spawn`, `run`, and the runner/prebuild/assembler sites that
//! go through them) then:
//!
//! - POSIX: starts the child in a NEW process group (`pgid = 0`), so a
//!   signal to `-pid` reaches the child and every process it started.
//!   Its stdin is `/dev/null`: a background process group that read the
//!   terminal would be stopped by SIGTTIN.
//! - Windows: starts the child suspended, assigns it to a fresh job object
//!   with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, then resumes it, so every
//!   process it starts is in the job from its first instruction.
//!   Terminating the job ends the tree; closing its last handle (when the
//!   child is reaped, or when `labelle` itself dies) ends any leftover.
//!
//! and registers it in the group until it is reaped. `Group.cancel` asks
//! every registered tree to stop (SIGTERM / TerminateJobObject), a spawn
//! after it is refused, and `cancelAndReap` escalates to SIGKILL after a
//! grace period. When a supervised child is reaped, whatever is left of
//! its tree is killed. A thread without a group (`current == null`) spawns
//! exactly as before.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");

const is_windows = builtin.os.tag == .windows;

/// The most children one group tracks at once. A rebuild runs one child at
/// a time; the headroom covers helpers such as a relay.
pub const max_children = 16;

/// The group the calling thread's spawns register in; `null` spawns
/// unsupervised (today's behaviour everywhere outside a watch session).
pub threadlocal var current: ?*Group = null;

/// Groups a stop signal reaches (`forwardAll`, `killAll`): attached for
/// the life of a session. Read lock-free from a signal handler.
var attached: [4]std.atomic.Value(usize) = [_]std.atomic.Value(usize){.init(0)} ** 4;

pub const Group = struct {
    /// POSIX: the pid of each registered child (it leads its own process
    /// group, so `-pid` is the group). Windows: its job object handle.
    /// Zero is a free slot.
    slots: [max_children]std.atomic.Value(usize) = [_]std.atomic.Value(usize){.init(0)} ** max_children,
    cancelled: std.atomic.Value(bool) = .init(false),
    /// A stop forwarded to the group (`forward`), latched: `Stop` + 1, or
    /// 0. A child registered AFTER the stop arrived — while the session was
    /// still setting up, or between two spawns — is signalled the moment it
    /// registers, so a Ctrl+C is never lost for want of a child to reach.
    pending: std.atomic.Value(u8) = .init(0),
    /// Serialises registration against `cancel`, so a child registered
    /// concurrently with a cancel is either seen by it or refused.
    mutex: std.Io.Mutex = .init,

    /// Make the group reachable from the stop handler.
    pub fn attach(self: *Group) void {
        for (&attached) |*slot| {
            if (slot.cmpxchgStrong(0, @intFromPtr(self), .seq_cst, .seq_cst) == null) return;
        }
    }

    pub fn detach(self: *Group) void {
        for (&attached) |*slot| {
            _ = slot.cmpxchgStrong(@intFromPtr(self), 0, .seq_cst, .seq_cst);
        }
    }

    fn register(self: *Group, io: std.Io, id: usize) error{ Canceled, TooManyChildren }!usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.cancelled.load(.seq_cst)) return error.Canceled;
        for (&self.slots, 0..) |*slot, i| {
            if (slot.load(.seq_cst) == 0) {
                slot.store(id, .seq_cst);
                return i;
            }
        }
        return error.TooManyChildren;
    }

    fn unregister(self: *Group, io: std.Io, index: usize) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const id = self.slots[index].swap(0, .seq_cst);
        // Whatever the reaped child left behind in its tree ends with it.
        if (id != 0) endTree(id);
    }

    /// Ask every registered tree to stop and refuse every later spawn.
    /// Terminal: a cancelled group stays cancelled.
    pub fn cancel(self: *Group, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.cancelled.store(true, .seq_cst);
        for (&self.slots) |*slot| {
            const id = slot.load(.seq_cst);
            if (id != 0) signalTree(id, .terminate);
        }
    }

    pub fn isCancelled(self: *const Group) bool {
        return self.cancelled.load(.seq_cst);
    }

    /// Registered children not yet reaped.
    pub fn live(self: *const Group) usize {
        var n: usize = 0;
        for (&self.slots) |*slot| {
            if (slot.load(.seq_cst) != 0) n += 1;
        }
        return n;
    }

    /// Forget a latched stop (the session's own child ended with it).
    pub fn clearPending(self: *Group) void {
        self.pending.store(0, .seq_cst);
    }

    /// Signal-handler safe: latch `sig`, then forward it to every
    /// registered tree.
    fn forward(self: *Group, sig: Stop) usize {
        self.pending.store(@as(u8, @intFromEnum(sig)) + 1, .seq_cst);
        var n: usize = 0;
        for (&self.slots) |*slot| {
            const id = slot.load(.seq_cst);
            if (id != 0) {
                signalTree(id, sig);
                n += 1;
            }
        }
        return n;
    }

    /// `cancel`, then wait for the owning threads to reap every child for
    /// up to `grace_ms`, then kill whatever is still running. The owners
    /// still reap (their `wait` returns once the child is gone); join them
    /// after this returns.
    pub fn cancelAndReap(self: *Group, io: std.Io, grace_ms: u64) void {
        self.cancel(io);
        const deadline = monotonicMs() +| grace_ms;
        while (self.live() != 0 and monotonicMs() < deadline) sleepMs(10);
        if (self.live() != 0) _ = self.killLive();
    }

    fn killLive(self: *Group) usize {
        var n: usize = 0;
        for (&self.slots) |*slot| {
            const id = slot.load(.seq_cst);
            if (id != 0) {
                signalTree(id, .kill);
                n += 1;
            }
        }
        return n;
    }
};

/// What a stop does to a registered tree.
pub const Stop = enum { interrupt, terminate, kill };

/// Forward a stop to every attached group (a signal handler's first
/// Ctrl+C / SIGTERM). Returns how many trees it reached.
pub fn forwardAll(sig: Stop) usize {
    var n: usize = 0;
    for (&attached) |*slot| {
        const ptr = slot.load(.seq_cst);
        if (ptr != 0) n += @as(*Group, @ptrFromInt(ptr)).forward(sig);
    }
    return n;
}

fn signalTree(id: usize, sig: Stop) void {
    if (is_windows) {
        // A job cannot be interrupted, only terminated: console Ctrl+C
        // already reached every process attached to the console.
        if (sig == .interrupt) return;
        _ = win.TerminateJobObject(@ptrFromInt(id), 1);
    } else {
        const pgid: std.posix.pid_t = -@as(std.posix.pid_t, @intCast(id));
        const signo: std.posix.SIG = switch (sig) {
            .interrupt => .INT,
            .terminate => .TERM,
            .kill => .KILL,
        };
        _ = std.posix.system.kill(pgid, signo);
    }
}

/// End a reaped child's remaining tree and release its handle.
fn endTree(id: usize) void {
    if (is_windows) {
        const job: std.os.windows.HANDLE = @ptrFromInt(id);
        _ = win.TerminateJobObject(job, 1);
        _ = win.CloseHandle(job);
    } else {
        signalTree(id, .kill);
    }
}

/// A child spawned through `spawn`: `wait` (or `abort`) reaps it and
/// releases its slot.
pub const Supervised = struct {
    child: std.process.Child,
    group: ?*Group,
    slot: usize = 0,

    pub fn wait(self: *Supervised, io: std.Io) !std.process.Child.Term {
        const term = self.child.wait(io);
        if (self.group) |g| g.unregister(io, self.slot);
        self.group = null;
        return term;
    }

    /// Kill and reap (error paths).
    pub fn abort(self: *Supervised, io: std.Io) void {
        if (self.child.id != null) self.child.kill(io);
        if (self.group) |g| g.unregister(io, self.slot);
        self.group = null;
    }
};

/// Test seam: runs between a supervised spawn and its registration, so a
/// test can make cancellation win that race deterministically. Never set
/// in production.
pub var test_after_spawn: ?*const fn (*Group) void = null;

/// `std.process.spawn`, supervised by `current` when the thread has one.
/// A cancelled group refuses the spawn (`error.Canceled`).
pub fn spawn(io: std.Io, options: std.process.SpawnOptions) !Supervised {
    return spawnIn(current, io, options);
}

pub fn spawnIn(group_opt: ?*Group, io: std.Io, options: std.process.SpawnOptions) !Supervised {
    const group = group_opt orelse return .{ .child = try std.process.spawn(io, options), .group = null };
    if (group.isCancelled()) return error.Canceled;
    var opts = options;
    if (is_windows) {
        opts.start_suspended = true;
    } else {
        opts.pgid = 0;
        if (opts.stdin == .inherit) opts.stdin = .ignore;
    }
    var child = try std.process.spawn(io, opts);
    const id: usize = if (is_windows) blk: {
        const job = createJob(child.id.?) catch |err| {
            child.kill(io);
            return err;
        };
        break :blk @intFromPtr(job);
    } else @intCast(child.id.?);
    if (test_after_spawn) |hook| hook(group);
    const slot = group.register(io, id) catch |err| {
        // Refused (cancelled meanwhile): end the whole tree the child may
        // already have started — its process group, or its job — not only
        // the child, then reap it.
        endTree(id);
        if (is_windows) _ = win.ResumeThread(child.thread_handle);
        child.kill(io);
        return err;
    };
    if (is_windows) _ = win.ResumeThread(child.thread_handle);
    // A stop that arrived before this child could be reached.
    const latched = group.pending.load(.seq_cst);
    if (latched != 0) {
        // On Windows an interrupt is the console event, which a child that
        // was not running then never saw: terminate its job instead.
        const stop: Stop = @enumFromInt(latched - 1);
        signalTree(id, if (is_windows and stop == .interrupt) .terminate else stop);
    }
    return .{ .child = child, .group = group, .slot = slot };
}

/// `std.process.run` (captured stdout/stderr), supervised by `current`
/// when the thread has one.
pub fn run(gpa: std.mem.Allocator, io: std.Io, options: std.process.RunOptions) !std.process.RunResult {
    if (current == null) return std.process.run(gpa, io, options);
    var sup = try spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .expand_arg0 = options.expand_arg0,
        .create_no_window = options.create_no_window,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer sup.abort(io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ sup.child.stdout.?, sup.child.stderr.? });
    defer multi_reader.deinit();
    while (multi_reader.fill(options.reserve_amount, options.timeout)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();
    const term = try sup.wait(io);
    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer gpa.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);
    return .{ .stdout = stdout_slice, .stderr = stderr_slice, .term = term };
}

// ── Windows job objects ──────────────────────────────────────────────

const win = struct {
    const HANDLE = std.os.windows.HANDLE;
    const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
        PerProcessUserTimeLimit: i64 = 0,
        PerJobUserTimeLimit: i64 = 0,
        LimitFlags: u32 = 0,
        MinimumWorkingSetSize: usize = 0,
        MaximumWorkingSetSize: usize = 0,
        ActiveProcessLimit: u32 = 0,
        Affinity: usize = 0,
        PriorityClass: u32 = 0,
        SchedulingClass: u32 = 0,
    };
    const IO_COUNTERS = extern struct { a: u64 = 0, b: u64 = 0, c: u64 = 0, d: u64 = 0, e: u64 = 0, f: u64 = 0 };
    const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
        BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
        IoInfo: IO_COUNTERS = .{},
        ProcessMemoryLimit: usize = 0,
        JobMemoryLimit: usize = 0,
        PeakProcessMemoryUsed: usize = 0,
        PeakJobMemoryUsed: usize = 0,
    };
    const JobObjectExtendedLimitInformation: c_int = 9;
    const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x2000;

    extern "kernel32" fn CreateJobObjectW(attrs: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn SetInformationJobObject(job: HANDLE, class: c_int, info: *anyopaque, len: u32) callconv(.winapi) c_int;
    extern "kernel32" fn AssignProcessToJobObject(job: HANDLE, process: HANDLE) callconv(.winapi) c_int;
    extern "kernel32" fn TerminateJobObject(job: HANDLE, exit_code: c_uint) callconv(.winapi) c_int;
    extern "kernel32" fn ResumeThread(thread: HANDLE) callconv(.winapi) u32;
    extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) c_int;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
    extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
};

fn createJob(process: std.os.windows.HANDLE) !std.os.windows.HANDLE {
    const job = win.CreateJobObjectW(null, null) orelse return error.JobObjectFailed;
    errdefer _ = win.CloseHandle(job);
    var info: win.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
    info.BasicLimitInformation.LimitFlags = win.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (win.SetInformationJobObject(job, win.JobObjectExtendedLimitInformation, &info, @sizeOf(win.JOBOBJECT_EXTENDED_LIMIT_INFORMATION)) == 0)
        return error.JobObjectFailed;
    if (win.AssignProcessToJobObject(job, process) == 0) {
        std.debug.print("labelle: could not assign a child to a job object; refusing to run it unsupervised\n", .{});
        return error.JobObjectFailed;
    }
    return job;
}

// ── Clock ─────────────────────────────────────────────────────────────

pub fn monotonicMs() u64 {
    if (is_windows) return win.GetTickCount64();
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

pub fn sleepMs(ms: u64) void {
    if (is_windows) return win.Sleep(@intCast(@min(ms, std.math.maxInt(u32) - 1)));
    var req: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    var rem: std.c.timespec = undefined;
    while (std.c.nanosleep(&req, &rem) != 0) req = rem;
}

// ── Tests ─────────────────────────────────────────────────────────────
//
// Against the REAL child fixture (`test/fixtures/child.zig`): the tests
// wait on events (a slot registered, a pid file written, a process gone),
// never on a fixed delay.

const test_fixtures = if (builtin.is_test) @import("test_fixtures") else struct {};

/// Spawn `argv` supervised by `group` on this thread and reap it.
fn runIn(group: *Group, argv: []const []const u8, term: *?std.process.Child.Term, spawn_err: *?anyerror) void {
    current = group;
    defer current = null;
    const io = config.globalIo();
    var sup = spawn(io, .{ .argv = argv, .stdout = .ignore, .stderr = .inherit }) catch |err| {
        spawn_err.* = err;
        return;
    };
    term.* = sup.wait(io) catch null;
}

fn waitUntil(cond: anytype, budget_ms: u64) bool {
    const deadline = monotonicMs() + budget_ms;
    while (monotonicMs() < deadline) {
        if (cond.check()) return true;
        std.Thread.yield() catch {};
    }
    return cond.check();
}

/// True once process `pid` no longer runs (POSIX: `kill 0` fails, or it is
/// a zombie awaiting its reparented reaper).
fn processGone(pid: u32) bool {
    if (is_windows) {
        const K = struct {
            extern "kernel32" fn OpenProcess(access: u32, inherit: c_int, pid: u32) callconv(.winapi) ?std.os.windows.HANDLE;
            extern "kernel32" fn WaitForSingleObject(h: std.os.windows.HANDLE, ms: u32) callconv(.winapi) u32;
        };
        const SYNCHRONIZE: u32 = 0x00100000;
        const h = K.OpenProcess(SYNCHRONIZE, 0, pid) orelse return true;
        defer _ = win.CloseHandle(h);
        return K.WaitForSingleObject(h, 0) == 0;
    }
    return std.posix.system.kill(@intCast(pid), @enumFromInt(0)) != 0;
}

test "supervise: an unsupervised thread spawns exactly as before" {
    const io = config.globalIo();
    try std.testing.expect(current == null);
    var sup = try spawn(io, .{ .argv = &.{ test_fixtures.child_exe, "exit:7" }, .stdout = .ignore, .stderr = .inherit });
    try std.testing.expect(sup.group == null);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, try sup.wait(io));
}

test "supervise: a registered child is released when reaped; a cancelled group refuses new spawns" {
    const io = config.globalIo();
    var group: Group = .{};
    var term: ?std.process.Child.Term = null;
    var err: ?anyerror = null;
    runIn(&group, &.{ test_fixtures.child_exe, "exit:3" }, &term, &err);
    try std.testing.expect(err == null);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 3 }, term.?);
    try std.testing.expectEqual(@as(usize, 0), group.live());
    group.cancel(io);
    runIn(&group, &.{ test_fixtures.child_exe, "exit:0" }, &term, &err);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), err);
}

test "supervise: cancel stops a running child and its whole tree, and it is reaped" {
    const io = config.globalIo();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const pid_file = try std.fs.path.join(a, &.{ dir, "grandchild.pid" });
    defer a.free(pid_file);

    var group: Group = .{};
    var term: ?std.process.Child.Term = null;
    var err: ?anyerror = null;
    // The fixture starts a grandchild (a 60 s sleeper), writes its pid and
    // then sleeps itself: a tree two processes deep.
    const t = try std.Thread.spawn(.{}, runIn, .{ &group, &[_][]const u8{ test_fixtures.child_exe, "tree", pid_file, test_fixtures.child_exe }, &term, &err });
    const PidWritten = struct {
        path: []const u8,
        fn check(self: @This()) bool {
            const bytes = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), self.path, std.testing.allocator, .limited(64)) catch return false;
            defer std.testing.allocator.free(bytes);
            return std.mem.endsWith(u8, bytes, "\n");
        }
    };
    try std.testing.expect(waitUntil(PidWritten{ .path = pid_file }, 30_000));
    try std.testing.expectEqual(@as(usize, 1), group.live());
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, pid_file, a, .limited(64));
    defer a.free(bytes);
    const grandchild = try std.fmt.parseInt(u32, std.mem.trim(u8, bytes, " \r\n"), 10);

    group.cancelAndReap(io, 5_000);
    t.join();
    try std.testing.expect(err == null);
    // Stopped, not a clean exit.
    switch (term.?) {
        .exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
    try std.testing.expectEqual(@as(usize, 0), group.live());
    const Gone = struct {
        pid: u32,
        fn check(self: @This()) bool {
            return processGone(self.pid);
        }
    };
    // The grandchild went with its parent's tree (POSIX process group,
    // Windows job object): no orphan.
    try std.testing.expect(waitUntil(Gone{ .pid = grandchild }, 10_000));
}

test "supervise: forwardAll reaches the trees of attached groups only" {
    var group: Group = .{};
    try std.testing.expectEqual(@as(usize, 0), forwardAll(.interrupt));
    group.attach();
    defer group.detach();
    try std.testing.expectEqual(@as(usize, 0), forwardAll(.interrupt));
}

test "supervise: a stop latched before any child exists reaches the next child at once" {
    const io = config.globalIo();
    var group: Group = .{};
    group.attach();
    defer group.detach();
    // The stop arrives while nothing is registered (session setup).
    try std.testing.expectEqual(@as(usize, 0), forwardAll(.terminate));
    // The next child is signalled the moment it registers: it never runs
    // its 60 s. No clock is involved; a lost stop would hang the test.
    var term: ?std.process.Child.Term = null;
    var err: ?anyerror = null;
    runIn(&group, &.{ test_fixtures.child_exe, "sleep:60000" }, &term, &err);
    try std.testing.expect(err == null);
    switch (term.?) {
        .exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
    // Cleared, a later child runs normally.
    group.clearPending();
    runIn(&group, &.{ test_fixtures.child_exe, "exit:0" }, &term, &err);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term.?);
    _ = io;
}

test "supervise: a latched interrupt stops a child registered after it, on every host" {
    var group: Group = .{};
    group.attach();
    defer group.detach();
    // What the POSIX signal handler and the Windows console handler latch.
    _ = forwardAll(.interrupt);
    var term: ?std.process.Child.Term = null;
    var err: ?anyerror = null;
    runIn(&group, &.{ test_fixtures.child_exe, "sleep:60000" }, &term, &err);
    try std.testing.expect(err == null);
    switch (term.?) {
        .exited => |code| try std.testing.expect(code != 0),
        else => {},
    }
}

test "supervise: a cancel that beats registration ends the child's whole tree" {
    // Windows starts the child suspended until it is registered, so no
    // descendant can exist before registration there.
    if (is_windows) return error.SkipZigTest;
    const io = config.globalIo();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const pid_file = try std.fs.path.join(a, &.{ dir, "grandchild.pid" });
    defer a.free(pid_file);
    const Race = struct {
        var path: []const u8 = "";
        // Wait for the grandchild to exist, then cancel: registration loses.
        fn cancelFirst(group: *Group) void {
            const deadline = monotonicMs() + 30_000;
            while (monotonicMs() < deadline) {
                const bytes = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, std.testing.allocator, .limited(64)) catch {
                    std.Thread.yield() catch {};
                    continue;
                };
                defer std.testing.allocator.free(bytes);
                if (std.mem.endsWith(u8, bytes, "\n")) break;
            }
            group.cancel(config.globalIo());
        }
    };
    Race.path = pid_file;
    test_after_spawn = Race.cancelFirst;
    defer test_after_spawn = null;
    var group: Group = .{};
    var term: ?std.process.Child.Term = null;
    var err: ?anyerror = null;
    runIn(&group, &.{ test_fixtures.child_exe, "tree", pid_file, test_fixtures.child_exe }, &term, &err);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), err);
    try std.testing.expectEqual(@as(usize, 0), group.live());
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, pid_file, a, .limited(64));
    defer a.free(bytes);
    const grandchild = try std.fmt.parseInt(u32, std.mem.trim(u8, bytes, " \r\n"), 10);
    const Gone = struct {
        pid: u32,
        fn check(self: @This()) bool {
            return processGone(self.pid);
        }
    };
    try std.testing.expect(waitUntil(Gone{ .pid = grandchild }, 10_000));
}
