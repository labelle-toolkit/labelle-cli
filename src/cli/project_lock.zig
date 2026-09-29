//! The project lock (cli#481): one advisory OS lock per project, held by
//! every labelle command around its write of `labelle.lock` (and of
//! `labelle.providers.lock`), so no two writers ever interleave.
//!
//! A watch session holds it for its whole lock TRANSACTION: from staging
//! the lock of an edited project, through the build and the publication,
//! to the commit or the rollback (`Replanner`). A rollback therefore always
//! restores the lock its own transaction replaced, with no other writer in
//! between, and two sessions (one per target) whose rebuilds both change
//! the lock run their transactions one after the other: the second waits,
//! then renders its lock from the first's result. A rebuild that does not
//! change the lock takes nothing. Every other writer (install, generate,
//! build, run, `providers resolve --accept`) holds it for its write only.
//!
//! The lock is `<project>/.labelle/project.lock`, taken like the watch
//! session lock (`watch/session_lock.zig`): an OS lock (`flock` /
//! `LockFileEx`, through `std.Io`) on a file opened without following a
//! symbolic link, a regular file only, created exclusively when missing
//! (`lock_open.openRegular`). The kernel drops it with the last handle, so
//! a killed command never leaves it held. The file is never deleted and
//! carries no content.
//!
//! Contention: a contender WAITS, however long — a session's transaction
//! spans a build — saying so once, and stays interruptible: Ctrl+C (the
//! session stop handler's `cancel_requested`) or its own cancellation (a
//! session ending) returns `error.Canceled`. Without a stop handler, Ctrl+C
//! ends the process, which releases whatever it held.
//!
//! Nested commands (cli#490): while this process holds a project's lock,
//! every child it spawns through `runner.buildEnvironWithExtra` (hooks,
//! provider tools, `zig build`) or as a `.prebuild` step gets
//! `LABELLE_PROJECT_LOCK_HELD` naming the canonical project directory
//! (`exportHeld`; several are joined with the PATH delimiter, an inherited
//! value kept in front). A labelle process that finds the lock of a
//! project named there BUSY fails at once with `error.ProjectLockHeldByParent`
//! instead of waiting: the holder is its own ancestor, waiting for it to
//! exit, so the wait could never end. It never writes, so the holder's
//! transaction (and its compare-and-restore) stays exclusive. A FREE lock
//! is taken as usual even with the marker (a hook's detached process that
//! outlived the holder is not refused). One watch session runs per
//! process, so every lock this process holds is its caller's.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const lock_open = @import("lock_open.zig");
const cancel = @import("watch/cancel.zig");

/// Relative to the project directory (`.labelle/`, which no watch walk
/// enters).
pub const rel_path = ".labelle" ++ std.fs.path.sep_str ++ "project.lock";

const poll_ms: u64 = 20;

/// Test seam: counts the polls that found the lock held by someone else,
/// so a test can see a contender actually waited.
pub var test_busy_polls: std.atomic.Value(usize) = .init(0);

/// Names the projects whose lock an ancestor labelle process holds
/// (cli#490): canonical directories joined with `std.fs.path.delimiter`.
pub const held_env = "LABELLE_PROJECT_LOCK_HELD";

/// The canonical directories of the project locks this process holds, for
/// `exportHeld`. Owned by `std.heap.smp_allocator`.
const Registry = struct {
    mutex: std.Io.Mutex = .init,
    dirs: std.ArrayList([]u8) = .empty,
};
var registry: Registry = .{};

pub const Held = struct {
    file: std.Io.File,
    /// This lock's entry in `registry`.
    dir: []u8,

    /// Drop the lock (closing the handle releases it).
    pub fn release(self: Held) void {
        const io = config.globalIo();
        registry.mutex.lockUncancelable(io);
        for (registry.dirs.items, 0..) |dir, i| if (dir.ptr == self.dir.ptr) {
            _ = registry.dirs.swapRemove(i);
            break;
        };
        registry.mutex.unlock(io);
        std.heap.smp_allocator.free(self.dir);
        self.file.close(io);
    }
};

/// Tell a child process which project locks it runs under (cli#490): sets
/// `held_env` in `map` to the inherited value followed by every lock this
/// process holds. Leaves `map` untouched while it holds none.
pub fn exportHeld(a: std.mem.Allocator, map: *std.process.Environ.Map) !void {
    const io = config.globalIo();
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);
    if (registry.dirs.items.len == 0) return;
    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(a);
    if (map.get(held_env)) |inherited| if (inherited.len > 0) try value.appendSlice(a, inherited);
    for (registry.dirs.items) |dir| {
        if (value.items.len > 0) try value.append(a, std.fs.path.delimiter);
        try value.appendSlice(a, dir);
    }
    try map.put(held_env, value.items);
}

/// The environment for a child spawned while this process may hold a
/// project lock: `null` (inherit as usual) when it holds none, else the
/// full environment with `exportHeld` applied.
pub fn childEnviron(a: std.mem.Allocator) !?std.process.Environ.Map {
    const io = config.globalIo();
    registry.mutex.lockUncancelable(io);
    const holding = registry.dirs.items.len > 0;
    registry.mutex.unlock(io);
    if (!holding) return null;
    var map = try config.globalEnviron().createMap(a);
    errdefer map.deinit();
    try exportHeld(a, &map);
    return map;
}

/// True when `list` (a `held_env` value) names `dir`, compared the way the
/// host compares paths.
pub fn namesProject(list: []const u8, dir: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, std.fs.path.delimiter);
    while (it.next()) |entry| {
        if (if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(entry, dir) else std.mem.eql(u8, entry, dir)) return true;
    }
    return false;
}

/// Test seam: stands in for an inherited `held_env` value (the process
/// environment is a snapshot a test cannot change). Never set in production.
pub var test_inherited: ?[]const u8 = null;

/// True when an ancestor labelle process holds the lock of `dir`.
fn heldByAncestor(a: std.mem.Allocator, dir: []const u8) bool {
    if (test_inherited) |list| return namesProject(list, dir);
    const list = config.globalEnviron().getAlloc(a, held_env) catch return false;
    defer a.free(list);
    return namesProject(list, dir);
}

/// How a contender waits.
pub const Wait = struct {
    /// Printed once, when the lock is first found held.
    note: []const u8 = "another labelle command to finish writing labelle.lock",
    /// Checked on every poll besides Ctrl+C: true stops the wait.
    cancel: ?Cancel = null,

    pub const Cancel = struct {
        ctx: *const anyopaque,
        canceled: *const fn (*const anyopaque) bool,
    };
};

/// Take the project lock of `project_dir` for a lock write, waiting while
/// another labelle command holds it. Release it with `Held.release`.
pub fn acquire(a: std.mem.Allocator, project_dir: []const u8) !Held {
    return acquireWaiting(a, project_dir, .{});
}

/// `acquire`, saying what it waits for, and stoppable by `wait.cancel`.
pub fn acquireWaiting(a: std.mem.Allocator, project_dir: []const u8, wait: Wait) !Held {
    const io = config.globalIo();
    const path = try std.fs.path.join(a, &.{ project_dir, rel_path });
    defer a.free(path);
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    const file = lock_open.openRegular(path) catch |err| switch (err) {
        error.LockNotRegular => {
            std.debug.print("labelle: the project lock '{s}' is not a regular file (a symbolic link or a directory); remove it and run again\n", .{path});
            return error.ProjectLockNotRegular;
        },
        else => return err,
    };
    errdefer file.close(io);
    const canonical = std.Io.Dir.cwd().realPathFileAlloc(io, project_dir, std.heap.smp_allocator) catch
        try std.heap.smp_allocator.dupe(u8, project_dir);
    errdefer std.heap.smp_allocator.free(canonical);
    var noticed = false;
    while (!try file.tryLock(io, .exclusive)) {
        _ = test_busy_polls.fetchAdd(1, .monotonic);
        if (!noticed and heldByAncestor(a, canonical)) {
            std.debug.print("labelle: this command writes labelle.lock, but it runs inside another labelle command that holds the lock of this project ('{s}'), e.g. from a hook or a prebuild step of a watch rebuild; that command waits for this one, so waiting here would never end. Run it outside the hook. (lock: {s})\n", .{ canonical, path });
            return error.ProjectLockHeldByParent;
        }
        if (cancel.cancel_requested.load(.acquire)) return error.Canceled;
        if (wait.cancel) |c| if (c.canceled(c.ctx)) return error.Canceled;
        if (!noticed) {
            noticed = true;
            std.debug.print("labelle: waiting for {s}... (lock: {s})\n", .{ wait.note, path });
        }
        io.sleep(std.Io.Duration.fromMilliseconds(@intCast(poll_ms)), .awake) catch {};
    }
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);
    try registry.dirs.append(std.heap.smp_allocator, canonical);
    return .{ .file = file, .dir = canonical };
}

// ── Tests ─────────────────────────────────────────────────────────────

const Tmp = struct {
    tmp: std.testing.TmpDir,
    dir: [:0]const u8,

    fn init(a: std.mem.Allocator) !Tmp {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(config.globalIo(), ".", a);
        return .{ .tmp = tmp, .dir = dir };
    }

    fn deinit(self: *Tmp, a: std.mem.Allocator) void {
        a.free(self.dir);
        self.tmp.cleanup();
    }
};

test "project lock: a second writer waits for the first, then gets the lock (cli#481)" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var t = try Tmp.init(a);
    defer t.deinit(a);
    // Writer 1 holds the lock across a read-compare-write of the lock file.
    const first = try acquire(a, t.dir);
    try t.tmp.dir.writeFile(io, .{ .sub_path = "labelle.lock", .data = "first" });
    const Second = struct {
        fn run(dir: []const u8, done: *std.atomic.Value(bool)) void {
            const held = acquire(std.testing.allocator, dir) catch return;
            defer held.release();
            // It only runs once the first writer released: it sees the
            // first's write and replaces it.
            const lock = std.fs.path.join(std.testing.allocator, &.{ dir, "labelle.lock" }) catch return;
            defer std.testing.allocator.free(lock);
            const now = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), lock, std.testing.allocator, .limited(64)) catch return;
            defer std.testing.allocator.free(now);
            if (!std.mem.eql(u8, now, "first")) return;
            std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = lock, .data = "second" }) catch return;
            done.store(true, .release);
        }
    };
    var done: std.atomic.Value(bool) = .init(false);
    const before = test_busy_polls.load(.monotonic);
    const thread = try std.Thread.spawn(.{}, Second.run, .{ t.dir, &done });
    // Wait until the second writer has found the lock busy (the mechanism,
    // not only the result).
    var spins: usize = 0;
    while (test_busy_polls.load(.monotonic) == before and spins < 1000) : (spins += 1) {
        io.sleep(std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }
    try std.testing.expect(test_busy_polls.load(.monotonic) > before);
    // Still blocked: nothing written behind the first writer's back.
    try std.testing.expect(!done.load(.acquire));
    first.release();
    thread.join();
    try std.testing.expect(done.load(.acquire));
    const now = try t.tmp.dir.readFileAlloc(io, "labelle.lock", a, .limited(64));
    defer a.free(now);
    try std.testing.expectEqualStrings("second", now);
}

test "project lock: Ctrl+C or a cancellation ends the wait, and nothing is held (cli#481)" {
    const a = std.testing.allocator;
    var t = try Tmp.init(a);
    defer t.deinit(a);
    const held = try acquire(a, t.dir);
    // The session's own cancellation (a session ending).
    const Stop = struct {
        var polls: usize = 0;
        fn canceled(_: *const anyopaque) bool {
            polls += 1;
            return polls >= 3;
        }
    };
    const before = test_busy_polls.load(.monotonic);
    try std.testing.expectError(error.Canceled, acquireWaiting(a, t.dir, .{ .cancel = .{ .ctx = &Stop.polls, .canceled = Stop.canceled } }));
    // It waited (three busy polls) before giving up.
    try std.testing.expectEqual(before + 3, test_busy_polls.load(.monotonic));
    // Ctrl+C, as the session stop handler records it.
    cancel.cancel_requested.store(true, .release);
    const ctrl_c = acquire(a, t.dir);
    cancel.cancel_requested.store(false, .release);
    try std.testing.expectError(error.Canceled, ctrl_c);
    // The canceled waits left nothing held: once released, the lock is free.
    held.release();
    const next = try acquire(a, t.dir);
    next.release();
}

test "project lock: a symbolic link at the lock path is refused and never written through (cli#481)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // links need a privilege there
    const a = std.testing.allocator;
    const io = config.globalIo();
    var t = try Tmp.init(a);
    defer t.deinit(a);
    try t.tmp.dir.createDirPath(io, ".labelle");
    try t.tmp.dir.writeFile(io, .{ .sub_path = "victim.txt", .data = "precious" });
    try t.tmp.dir.symLink(io, "../victim.txt", ".labelle/project.lock", .{});
    try std.testing.expectError(error.ProjectLockNotRegular, acquire(a, t.dir));
    const victim = try t.tmp.dir.readFileAlloc(io, "victim.txt", a, .limited(64));
    defer a.free(victim);
    try std.testing.expectEqualStrings("precious", victim);
    // A dangling link is refused too (nothing is created through it).
    try t.tmp.dir.deleteFile(io, ".labelle/project.lock");
    try t.tmp.dir.symLink(io, "../created.txt", ".labelle/project.lock", .{});
    try std.testing.expectError(error.ProjectLockNotRegular, acquire(a, t.dir));
    try std.testing.expectError(error.FileNotFound, t.tmp.dir.access(io, "created.txt", .{}));
}

test "project lock: a directory at the lock path is refused (cli#481)" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var t = try Tmp.init(a);
    defer t.deinit(a);
    try t.tmp.dir.createDirPath(io, ".labelle/project.lock");
    try std.testing.expectError(error.ProjectLockNotRegular, acquire(a, t.dir));
}

test "project lock: a nested command whose ancestor holds the lock fails at once, without waiting (cli#490)" {
    const a = std.testing.allocator;
    var t = try Tmp.init(a);
    defer t.deinit(a);
    // The ancestor: a watch rebuild holding its lock transaction.
    const held = try acquire(a, t.dir);
    defer held.release();
    defer test_inherited = null;
    // The child inherits the marker naming this very project.
    const list = try std.mem.concat(a, u8, &.{ "/elsewhere", &.{std.fs.path.delimiter}, held.dir });
    defer a.free(list);
    test_inherited = list;
    const before = test_busy_polls.load(.monotonic);
    try std.testing.expectError(error.ProjectLockHeldByParent, acquire(a, t.dir));
    // Exactly one busy poll: it recognised its ancestor on the first one
    // and never slept in the wait loop.
    try std.testing.expectEqual(before + 1, test_busy_polls.load(.monotonic));
}

test "project lock: a marker for another project, or a free lock, changes nothing (cli#490)" {
    const a = std.testing.allocator;
    var t = try Tmp.init(a);
    defer t.deinit(a);
    defer test_inherited = null;
    // A free lock is taken even though the marker names this project (a
    // hook's process that outlived its caller).
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), t.dir, a);
    defer a.free(canonical);
    test_inherited = canonical;
    const free = try acquire(a, t.dir);
    // Busy, but the marker names another project: an ordinary wait (ended
    // here by a cancellation after three polls), not the nested refusal.
    test_inherited = "/some/other/project";
    const Stop = struct {
        var polls: usize = 0;
        fn canceled(_: *const anyopaque) bool {
            polls += 1;
            return polls >= 3;
        }
    };
    const before = test_busy_polls.load(.monotonic);
    try std.testing.expectError(error.Canceled, acquireWaiting(a, t.dir, .{ .cancel = .{ .ctx = &Stop.polls, .canceled = Stop.canceled } }));
    try std.testing.expectEqual(before + 3, test_busy_polls.load(.monotonic));
    free.release();
}

test "project lock: children of a holder are told which project lock it holds (cli#490)" {
    const a = std.testing.allocator;
    var t = try Tmp.init(a);
    defer t.deinit(a);
    var map = std.process.Environ.Map.init(a);
    defer map.deinit();
    // Holding nothing: the environment is left alone.
    try exportHeld(a, &map);
    try std.testing.expect(map.get(held_env) == null);
    try std.testing.expect((try childEnviron(a)) == null);
    const held = try acquire(a, t.dir);
    // The canonical project directory, after what an ancestor exported.
    try map.put(held_env, "/ancestor/project");
    try exportHeld(a, &map);
    const value = map.get(held_env).?;
    try std.testing.expect(namesProject(value, "/ancestor/project"));
    try std.testing.expect(namesProject(value, held.dir));
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), t.dir, a);
    defer a.free(canonical);
    try std.testing.expectEqualStrings(canonical, held.dir);
    // A spawn that would inherit gets a full environment carrying it.
    var child = (try childEnviron(a)).?;
    defer child.deinit();
    try std.testing.expect(namesProject(child.get(held_env).?, canonical));
    held.release();
    // Released: nothing is exported any more.
    try std.testing.expect((try childEnviron(a)) == null);
}
