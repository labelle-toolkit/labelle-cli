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
const project_lock = @import("project_lock.zig");

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
    /// Bumped each time a slot is taken: a `Handle` names one registration,
    /// so a kill aimed at a child already reaped never reaches the child
    /// registered in its slot since (cli#478). Guarded by `mutex`.
    generations: [max_children]u64 = [_]u64{0} ** max_children,
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

    /// One registration: a slot and the generation it held then.
    pub const Handle = struct { index: usize, generation: u64 };

    fn register(self: *Group, io: std.Io, id: usize) error{ Canceled, TooManyChildren }!Handle {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.cancelled.load(.seq_cst)) return error.Canceled;
        for (&self.slots, 0..) |*slot, i| {
            if (slot.load(.seq_cst) == 0) {
                self.generations[i] +%= 1;
                slot.store(id, .seq_cst);
                return .{ .index = i, .generation = self.generations[i] };
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

    /// Kill the tree `handle` registered, if it still is registered: a
    /// slot freed since, or taken by another child, is left alone (cli#478).
    /// Under `mutex`, so the slot cannot be freed and re-taken between the
    /// check and the signal. `mark`, when given, is set before the signal
    /// (so whoever sees the child die sees it too). Returns whether it
    /// signalled.
    fn killSlot(self: *Group, io: std.Io, handle: Handle, mark: ?*std.atomic.Value(bool)) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.generations[handle.index] != handle.generation) return false;
        const id = self.slots[handle.index].load(.seq_cst);
        if (id == 0) return false;
        if (mark) |m| m.store(true, .release);
        signalTree(id, .kill);
        return true;
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
    slot: Group.Handle = .{ .index = 0, .generation = 0 },

    pub fn wait(self: *Supervised, io: std.Io) !std.process.Child.Term {
        const term = self.child.wait(io);
        if (self.group) |g| g.unregister(io, self.slot.index);
        self.group = null;
        return term;
    }

    /// Kill and reap (error paths).
    pub fn abort(self: *Supervised, io: std.Io) void {
        if (self.child.id != null) self.child.kill(io);
        if (self.group) |g| g.unregister(io, self.slot.index);
        self.group = null;
    }
};

/// Test seam: runs between a supervised spawn and its registration, so a
/// test can make cancellation win that race deterministically. Never set
/// in production.
pub var test_after_spawn: ?*const fn (*Group) void = null;

/// Test seam: runs on a captured child's waiting thread after the child
/// was reaped (its slot released) and before the drain learns it ended,
/// so a test can register another child in that gap. Never set in
/// production.
var test_after_reap: ?*const fn (*Waited) void = null;

/// `std.process.spawn`, supervised by `current` when the thread has one.
/// A cancelled group refuses the spawn (`error.Canceled`).
pub fn spawn(io: std.Io, options: std.process.SpawnOptions) !Supervised {
    return spawnIn(current, io, options);
}

pub fn spawnIn(group_opt: ?*Group, io: std.Io, given: std.process.SpawnOptions) !Supervised {
    // A child that would inherit the environment while this process holds
    // a project lock learns so (cli#490): a nested labelle command then
    // fails fast instead of waiting for its own ancestor. An explicit
    // environment is left to its caller (`runner.buildEnvironWithExtra`
    // adds the marker to the ones the CLI builds).
    var held_env = if (given.environ_map == null) try project_lock.childEnviron(std.heap.smp_allocator) else null;
    defer if (held_env) |*map| map.deinit();
    var options = given;
    if (held_env) |*map| options.environ_map = map;
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

/// How long `run` keeps draining a captured child's pipes after the child
/// itself has exited (the cli#453 pattern of the prebuild relay).
pub const drain_grace_ms: u64 = 500;

/// `std.process.run` (captured stdout/stderr), supervised by `current`
/// when the thread has one.
///
/// Supervised, the output is drained while the child is waited for on a
/// thread of its own: a child that leaves a descendant holding its pipes
/// never produces EOF, which used to hang the rebuild (cli#474). Once the
/// direct child has exited, its tree is ended (a descendant in its process
/// group or job goes with it, closing the pipes) and the drain gets
/// `drain_grace_ms` more to collect what is buffered — enough for any
/// descendant that escaped the tree too — then stops. The caller's
/// `options.timeout` still holds: a child still running when it expires is
/// killed (with its tree) and `error.Timeout` returned, as `std.process.run`
/// does; after the child exited, the drain ends at whichever of the grace
/// and the timeout comes first.
pub fn run(gpa: std.mem.Allocator, io: std.Io, options: std.process.RunOptions) !std.process.RunResult {
    if (current == null) return std.process.run(gpa, io, options);
    return runDrained(gpa, io, options, drain_grace_ms);
}

/// The child's end, as the waiting thread saw it.
const Waited = struct {
    sup: *Supervised,
    io: std.Io,
    /// The child's group and registration, read once (the waiting thread
    /// clears `sup.group` when it reaps). A kill through them reaches this
    /// child only: once it is reaped its slot may hold another (cli#478).
    group: ?*Group,
    slot: Group.Handle,
    term: ?(std.process.Child.WaitError!std.process.Child.Term) = null,
    done: std.atomic.Value(bool) = .init(false),
    /// Set when the caller's timeout ended the child.
    timed_out: std.atomic.Value(bool) = .init(false),
    /// Ends the watchdog early (the drain returned).
    stop: std.atomic.Value(bool) = .init(false),

    fn wait(self: *Waited) void {
        self.term = self.sup.wait(self.io);
        // The child is reaped and its slot free, but `done` is not set yet:
        // a kill from here on must not reach whoever registers in the slot.
        if (test_after_reap) |hook| hook(self);
        self.done.store(true, .release);
    }

    /// Kill the child's tree once `deadline` passes while it still runs.
    /// A thread of its own because a pipe read cannot always be timed out
    /// (Windows): the kill closes the pipes, which ends the drain.
    fn watchdog(self: *Waited, deadline: u64) void {
        while (!self.done.load(.acquire) and !self.stop.load(.acquire)) {
            const now = monotonicMs();
            if (now >= deadline) {
                self.expire();
                return;
            }
            sleepMs(@min(10, deadline - now));
        }
    }

    /// The deadline passed: kill the child if it is still registered. One
    /// already reaped did not time out, and its slot is not touched.
    fn expire(self: *Waited) void {
        if (self.done.load(.acquire)) return;
        const g = self.group orelse return;
        _ = g.killSlot(self.io, self.slot, &self.timed_out);
    }
};

fn runDrained(gpa: std.mem.Allocator, io: std.Io, options: std.process.RunOptions, grace_ms: u64) !std.process.RunResult {
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
    // The pipes are ours from here on: reaping the child (on the waiting
    // thread) must not close them under the drain.
    const pipes = [2]std.Io.File{ sup.child.stdout.?, sup.child.stderr.? };
    sup.child.stdout = null;
    sup.child.stderr = null;
    defer for (pipes) |pipe| pipe.close(io);

    var waited: Waited = .{ .sup = &sup, .io = io, .group = sup.group, .slot = sup.slot };
    const waiter = std.Thread.spawn(.{}, Waited.wait, .{&waited}) catch |err| {
        sup.abort(io);
        return err;
    };
    var joined = false;
    defer if (!joined) {
        // An error ends the child's tree so the waiting thread returns.
        // The group and slot saved before the waiter started: it clears
        // `sup.group` itself when it reaps.
        if (waited.group) |g| _ = g.killSlot(io, waited.slot, null);
        waiter.join();
    };

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &pipes);
    defer multi_reader.deinit();
    const poll_ms: u64 = 50;
    // The caller's timeout, as an absolute deadline on our clock.
    const deadline: ?u64 = if (options.timeout.toDurationFromNow(io)) |d|
        monotonicMs() +| @as(u64, @intCast(@max(d.raw.toMilliseconds(), 0)))
    else
        null;
    const watchdog: ?std.Thread = if (deadline) |d| std.Thread.spawn(.{}, Waited.watchdog, .{ &waited, d }) catch |err| return err else null;
    defer if (watchdog) |t| {
        waited.stop.store(true, .release);
        t.join();
    };
    var exited_at: ?u64 = null;
    while (true) {
        if (exited_at == null and waited.done.load(.acquire)) exited_at = monotonicMs();
        const now = monotonicMs();
        var end: ?u64 = deadline;
        if (exited_at) |t| end = if (end) |e| @min(e, t +| grace_ms) else t +| grace_ms;
        const wait_ms: u64 = if (end) |e| blk: {
            const left = e -| now;
            if (left == 0) {
                // Past the end: a child still running timed out (its tree
                // is killed); an exited one is done.
                if (exited_at == null) waited.expire();
                break;
            }
            break :blk @min(left, poll_ms);
        } else poll_ms;
        multi_reader.fill(options.reserve_amount, .{ .duration = .{ .raw = .fromMilliseconds(@intCast(wait_ms)), .clock = .awake } }) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => continue,
            else => |e| return e,
        };
    }
    try multi_reader.checkAnyError();
    waiter.join();
    joined = true;
    if (waited.timed_out.load(.acquire)) return error.Timeout;
    const term = try waited.term.?;
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

test "supervise: a captured child whose descendant holds its pipes cannot hang the drain (cli#474)" {
    const io = config.globalIo();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const pid_file = try std.fs.path.join(a, &.{ dir, "grandchild.pid" });
    defer a.free(pid_file);
    const Gone = struct {
        pid: u32,
        fn check(self: @This()) bool {
            return processGone(self.pid);
        }
    };
    const Case = struct { mode: []const u8, grace_ms: u64, escapes: bool };
    const cases = [_]Case{
        // A descendant in the child's tree ends with it, closing the pipes:
        // the drain reaches EOF long before a grace this long could expire.
        .{ .mode = "stay", .grace_ms = 60_000, .escapes = false },
        // One that left the tree (its own process group) keeps them open:
        // the grace bounds the drain.
        .{ .mode = "escape", .grace_ms = 100, .escapes = true },
    };
    for (cases) |case| {
        if (case.escapes and is_windows) continue; // a job cannot be left
        var group: Group = .{};
        current = &group;
        defer current = null;
        const began = monotonicMs();
        const res = try runDrained(a, io, .{ .argv = &.{ test_fixtures.child_exe, "leak", case.mode, pid_file, test_fixtures.child_exe } }, case.grace_ms);
        defer a.free(res.stdout);
        defer a.free(res.stderr);
        // The grandchild sleeps 60 s: an unbounded drain would wait for it.
        try std.testing.expect(monotonicMs() - began < 30_000);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, res.term);
        try std.testing.expect(std.mem.indexOf(u8, res.stdout, "child-output") != null);
        try std.testing.expectEqual(@as(usize, 0), group.live());
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, pid_file, a, .limited(64));
        defer a.free(bytes);
        const grandchild = try std.fmt.parseInt(u32, std.mem.trim(u8, bytes, " \r\n"), 10);
        if (!is_windows and case.escapes) {
            // The mechanism: it is still running, so the drain ended on the
            // grace, not on EOF. Clean it up.
            try std.testing.expect(!processGone(grandchild));
            if (!is_windows) _ = std.posix.system.kill(@intCast(grandchild), .KILL);
        }
        try std.testing.expect(waitUntil(Gone{ .pid = grandchild }, 10_000));
    }
}

test "supervise: the caller's timeout still ends a supervised captured child (cli#474)" {
    const io = config.globalIo();
    const a = std.testing.allocator;
    var group: Group = .{};
    current = &group;
    defer current = null;
    const began = monotonicMs();
    // A 60 s child under a 100 ms timeout: error.Timeout, the child reaped.
    try std.testing.expectError(error.Timeout, runDrained(a, io, .{
        .argv = &.{ test_fixtures.child_exe, "sleep:60000" },
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } },
    }, drain_grace_ms));
    try std.testing.expect(monotonicMs() - began < 30_000);
    try std.testing.expectEqual(@as(usize, 0), group.live());
    // A child that ends well inside its timeout is unaffected.
    const res = try runDrained(a, io, .{
        .argv = &.{ test_fixtures.child_exe, "exit:3" },
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(60_000), .clock = .awake } },
    }, drain_grace_ms);
    defer a.free(res.stdout);
    defer a.free(res.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 3 }, res.term);
}

test "supervise: a kill aimed at a reaped child spares the child registered in its slot since (cli#478)" {
    const io = config.globalIo();
    var group: Group = .{};
    // The first child's registration, then its reap.
    var first = try spawnIn(&group, io, .{ .argv = &.{ test_fixtures.child_exe, "exit:0" }, .stdout = .ignore, .stderr = .inherit });
    const stale = first.slot;
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try first.wait(io));
    // A second child takes the same slot: a new generation.
    var second = try spawnIn(&group, io, .{ .argv = &.{ test_fixtures.child_exe, "sleep-exit:1500:9" }, .stdout = .ignore, .stderr = .inherit });
    try std.testing.expectEqual(stale.index, second.slot.index);
    try std.testing.expect(stale.generation != second.slot.generation);
    // The stale kill is refused; the second child runs to its own exit.
    try std.testing.expect(!group.killSlot(io, stale, null));
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 9 }, try second.wait(io));
    try std.testing.expectEqual(@as(usize, 0), group.live());
}

test "supervise: the drain's timeout and error kills never reach a child registered after the reap (cli#478)" {
    const io = config.globalIo();
    const a = std.testing.allocator;
    const Gap = struct {
        var next: ?Supervised = null;
        var spawn_err: ?anyerror = null;
        var killed_by_watchdog = false;
        var killed_by_cleanup = false;
        // In the gap between the reap and `done`: another child registers
        // (in the slot just freed), then the watchdog's expiry and the
        // error cleanup's kill both fire, as a late thread would.
        fn hook(w: *Waited) void {
            const g = w.group.?;
            next = spawnIn(g, w.io, .{ .argv = &.{ test_fixtures.child_exe, "sleep-exit:1500:9" }, .stdout = .ignore, .stderr = .inherit }) catch |err| {
                spawn_err = err;
                return;
            };
            w.expire();
            killed_by_watchdog = w.timed_out.load(.acquire);
            killed_by_cleanup = g.killSlot(w.io, w.slot, null);
        }
    };
    test_after_reap = Gap.hook;
    defer test_after_reap = null;
    var group: Group = .{};
    current = &group;
    defer current = null;
    const res = try runDrained(a, io, .{
        .argv = &.{ test_fixtures.child_exe, "exit:0" },
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(60_000), .clock = .awake } },
    }, drain_grace_ms);
    defer a.free(res.stdout);
    defer a.free(res.stderr);
    // The drained child ended on its own: no timeout reported.
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, res.term);
    try std.testing.expect(Gap.spawn_err == null);
    var next = Gap.next.?;
    // The mechanism: the new child reused the reaped child's slot, and
    // both kills saw the stale registration and did nothing.
    try std.testing.expectEqual(@as(usize, 0), next.slot.index);
    try std.testing.expect(!Gap.killed_by_watchdog);
    try std.testing.expect(!Gap.killed_by_cleanup);
    // It runs to its own exit, not a kill.
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 9 }, try next.wait(io));
    try std.testing.expectEqual(@as(usize, 0), group.live());
}
