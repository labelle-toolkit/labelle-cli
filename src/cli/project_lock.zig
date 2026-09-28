//! The project lock (cli#481): one advisory OS lock per project, taken by
//! every command around its write of `labelle.lock` (and of
//! `labelle.providers.lock`), so a read-compare-write of the lock is one
//! step to every other labelle command in the project.
//!
//! Why: a failed watched rebuild restores `labelle.lock` only while it still
//! holds what that rebuild wrote (cli#478 compare-and-restore). Without a
//! lock shared between processes, an install or another watch session could
//! write between the compare and the restore, and the older lock would
//! overwrite it. Holding this lock across the compare AND the restore, and
//! across every other write, closes that window.
//!
//! The lock is `<project>/.labelle/project.lock`, taken like the watch
//! session lock (`watch/session_lock.zig`): an OS lock (`flock` /
//! `LockFileEx`, through `std.Io`) on a file opened without following a
//! symbolic link, a regular file only, created exclusively when missing
//! (`lock_open.openRegular`). The kernel drops it with the last handle, so
//! a killed command never leaves it held. The file is never deleted and
//! carries no content.
//!
//! Held only for the short critical section of reading, comparing and
//! writing the lock — never across an install, a generation or a build.
//!
//! Contention policy: a BOUNDED WAIT. Every critical section is a few file
//! operations, so a contender polls for up to `wait_budget_ms` (10 s)
//! rather than failing a build that merely collided with another command's
//! lock write. Past the budget something is wrong (a hung command holding
//! it), and the command fails with `error.ProjectLockBusy` and a message
//! naming the lock file, instead of hanging forever.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const lock_open = @import("lock_open.zig");

/// Relative to the project directory (`.labelle/`, which no watch walk
/// enters).
pub const rel_path = ".labelle" ++ std.fs.path.sep_str ++ "project.lock";

/// How long `acquire` waits for another command's critical section.
/// A variable only so tests can shorten it.
pub var wait_budget_ms: u64 = 10_000;
const poll_ms: u64 = 10;
/// A contender says it is waiting once it has waited this long.
const notice_ms: u64 = 1_000;

/// Test seam: counts the polls that found the lock held by someone else,
/// so a test can see a contender actually waited.
pub var test_busy_polls: std.atomic.Value(usize) = .init(0);

pub const Held = struct {
    file: std.Io.File,

    /// Drop the lock (closing the handle releases it).
    pub fn release(self: Held) void {
        self.file.close(config.globalIo());
    }
};

/// Take the project lock of `project_dir`, waiting (bounded) while another
/// labelle command holds it. Release it with `Held.release` as soon as the
/// lock write is done.
pub fn acquire(a: std.mem.Allocator, project_dir: []const u8) !Held {
    const io = config.globalIo();
    const path = try std.fs.path.join(a, &.{ project_dir, rel_path });
    defer a.free(path);
    const file = try open(path);
    errdefer file.close(io);
    var waited: u64 = 0;
    var noticed = false;
    while (!try file.tryLock(io, .exclusive)) {
        _ = test_busy_polls.fetchAdd(1, .monotonic);
        if (waited >= wait_budget_ms) {
            std.debug.print("labelle: another labelle command has held the project lock for {d} s while writing labelle.lock; gave up waiting (lock: {s}). Let it finish, or stop it, and run again\n", .{ waited / 1000, path });
            return error.ProjectLockBusy;
        }
        if (!noticed and waited >= notice_ms) {
            noticed = true;
            std.debug.print("labelle: waiting for another labelle command writing labelle.lock (lock: {s})\n", .{path});
        }
        io.sleep(std.Io.Duration.fromMilliseconds(@intCast(poll_ms)), .awake) catch {};
        waited += poll_ms;
    }
    return .{ .file = file };
}

/// `acquire` without waiting: `null` while another command holds the lock.
/// For a retry that must not stall its caller (a watch tick).
pub fn tryAcquire(a: std.mem.Allocator, project_dir: []const u8) !?Held {
    const io = config.globalIo();
    const path = try std.fs.path.join(a, &.{ project_dir, rel_path });
    defer a.free(path);
    const file = try open(path);
    errdefer file.close(io);
    if (!try file.tryLock(io, .exclusive)) {
        _ = test_busy_polls.fetchAdd(1, .monotonic);
        file.close(io);
        return null;
    }
    return .{ .file = file };
}

fn open(path: []const u8) !std.Io.File {
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(config.globalIo(), dir);
    return lock_open.openRegular(path) catch |err| switch (err) {
        error.LockNotRegular => {
            std.debug.print("labelle: the project lock '{s}' is not a regular file (a symbolic link or a directory); remove it and run again\n", .{path});
            return error.ProjectLockNotRegular;
        },
        else => return err,
    };
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

test "project lock: a lock held past the budget fails with ProjectLockBusy (cli#481)" {
    const a = std.testing.allocator;
    var t = try Tmp.init(a);
    defer t.deinit(a);
    const held = try acquire(a, t.dir);
    const saved = wait_budget_ms;
    wait_budget_ms = 50;
    defer wait_budget_ms = saved;
    try std.testing.expectError(error.ProjectLockBusy, acquire(a, t.dir));
    // Nor does a try, which returns at once.
    try std.testing.expect(try tryAcquire(a, t.dir) == null);
    held.release();
    // Released: the next command takes it at once.
    const next = try acquire(a, t.dir);
    next.release();
    const tried = (try tryAcquire(a, t.dir)) orelse return error.TestUnexpectedResult;
    tried.release();
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
