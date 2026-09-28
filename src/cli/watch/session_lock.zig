//! One watch session per session root (project and target) at a time
//! (RFC cli#466 §3.4): the session claims `<root>.lock` BEFORE any build,
//! so a second `labelle run --watch` for the same target is refused
//! (`error.WatchSessionActive`) before it touches the target's staging tree
//! or the published output.
//!
//! Ownership is an OS lock on the file (`flock` / `LockFileEx`, through
//! `std.Io`), taken when it is opened and held for the whole session: the
//! kernel arbitrates between contenders, so two sessions taking over the
//! same stale lock at once can never both own it (cli#474). A session
//! killed outright releases its lock with its last handle, so a stale lock
//! needs no liveness check of the PID it recorded: whoever gets the OS lock
//! owns the file, whatever it says. The PID written into it only names the
//! owner in the refusal.
//!
//! The file is never deleted: unlinking a lock file another contender has
//! already opened would let a third create a fresh one and lock it too.
//! Releasing closes the handle, which drops the lock.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const lock_open = @import("../lock_open.zig");

const is_windows = builtin.os.tag == .windows;

/// Byte 0 of the file is a marker: Windows locks that byte (the range
/// `std.Io` locks), and a locked range cannot be read through another
/// handle, so the owner's PID is written from byte 1 on, where a refused
/// contender can still read it.
const pid_offset = 1;

pub const SessionLock = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    /// Holds the OS lock until `release`.
    file: std.Io.File,
    /// The PID a stale lock recorded when this session took it over (a
    /// session that ended without releasing); `null` for a fresh or
    /// cleanly released lock.
    took_over: ?u64 = null,

    pub fn acquire(allocator: std.mem.Allocator, root: []const u8) !SessionLock {
        const path = try std.fmt.allocPrint(allocator, "{s}.lock", .{root});
        errdefer allocator.free(path);
        if (std.fs.path.dirname(root)) |parent| try std.Io.Dir.cwd().createDirPath(config.globalIo(), parent);
        const claimed = try claim(path);
        return .{ .allocator = allocator, .path = path, .file = claimed.file, .took_over = claimed.took_over };
    }

    /// Drop the OS lock (the file stays; see the module comment). The PID
    /// is cleared first, while the lock is still ours: an empty lock was
    /// released cleanly, so the next session takes it without calling it
    /// stale. The OS lock stays the authority either way.
    pub fn release(self: *SessionLock) void {
        const io = config.globalIo();
        self.file.setLength(io, 0) catch {};
        self.file.close(io);
        self.allocator.free(self.path);
    }
};

/// Open `lock_path` (created if missing, never truncated before the lock
/// is ours) with a non-blocking exclusive OS lock. Refused: another live
/// session holds it. Granted: whatever the file recorded belongs to a
/// session that is gone, and it is rewritten with our PID.
///
/// The path is opened WITHOUT following a symbolic link and must be a
/// regular file: the lock lives in the project tree, and a link planted
/// there (a damaged or untrusted checkout) must never make a watch session
/// truncate and overwrite the file it names (cli#476 review).
const Claimed = struct { file: std.Io.File, took_over: ?u64 };

fn claim(lock_path: []const u8) !Claimed {
    const io = config.globalIo();
    const file = try openRegular(lock_path);
    // The one cleanup of this handle on every error path below (closing
    // twice could close a descriptor another thread was just handed).
    errdefer closeClaimed(file);
    const locked = file.tryLock(io, .exclusive) catch |err| switch (err) {
        else => return err,
    };
    if (!locked) {
        var buf: [24]u8 = undefined;
        if (readOwner(lock_path, &buf)) |owner| {
            std.debug.print("labelle: run --watch: another watch session (pid {d}) is already running for this target; stop it first (lock: {s})\n", .{ owner, lock_path });
        } else {
            std.debug.print("labelle: run --watch: another watch session (pid unknown) is already running for this target; stop it first (lock: {s})\n", .{lock_path});
        }
        return error.WatchSessionActive;
    }
    // The lock is ours: a previous owner, if the file still names one,
    // ended without releasing it (a clean release empties the file).
    var prev: [24]u8 = undefined;
    const n = file.readPositionalAll(io, &prev, pid_offset) catch 0;
    const took_over = parseOwner(prev[0..n]);
    if (took_over) |owner| {
        std.debug.print("labelle: run --watch: taking over a stale watch session lock (pid {d} is gone)\n", .{owner});
    }
    try rewritePid(file);
    return .{ .file = file, .took_over = took_over };
}

fn rewritePid(file: std.Io.File) !void {
    if (builtin.is_test and test_fail_rewrite) return error.NoSpaceLeft;
    const io = config.globalIo();
    try file.setLength(io, 0);
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "#{d}\n", .{ownPid()});
    try file.writePositionalAll(io, text, 0);
}

/// Test seams: make the PID rewrite fail, and count claim's cleanups.
var test_fail_rewrite = false;
var test_closes: usize = 0;

fn closeClaimed(file: std.Io.File) void {
    if (builtin.is_test) test_closes += 1;
    file.close(config.globalIo());
}

/// Open (or create) `lock_path` without following a symbolic link, a
/// regular file only (`lock_open.openRegular`, shared with the project
/// lock of cli#481).
fn openRegular(lock_path: []const u8) !std.Io.File {
    return lock_open.openRegular(lock_path) catch |err| switch (err) {
        error.LockNotRegular => return notRegular(lock_path),
        else => return err,
    };
}

fn notRegular(lock_path: []const u8) error{WatchLockNotRegular} {
    std.debug.print("labelle: run --watch: the watch session lock '{s}' is not a regular file (a symbolic link or a directory); remove it and run again\n", .{lock_path});
    return error.WatchLockNotRegular;
}

/// The PID a lock file records, read without taking the lock.
fn readOwner(lock_path: []const u8, buf: []u8) ?u64 {
    const io = config.globalIo();
    const file = std.Io.Dir.cwd().openFile(io, lock_path, .{ .follow_symlinks = is_windows, .allow_directory = false }) catch return null;
    defer file.close(io);
    const n = file.readPositionalAll(io, buf, pid_offset) catch return null;
    return parseOwner(buf[0..n]);
}

fn parseOwner(bytes: []const u8) ?u64 {
    const owner = std.fmt.parseInt(u64, std.mem.trim(u8, bytes, " #\r\n"), 10) catch return null;
    return if (owner == 0) null else owner;
}

const ownPid = lock_open.ownPid;

// ── Tests ─────────────────────────────────────────────────────────────

test "session lock: one session per root; the lock is released with the session" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const root = try std.fs.path.join(a, &.{ base, "watch", "session" });
    defer a.free(root);
    var first = try SessionLock.acquire(a, root);
    // A second session for the same root is refused while the first runs.
    try std.testing.expectError(error.WatchSessionActive, SessionLock.acquire(a, root));
    // The refusal can name the owner: the file records our PID.
    var buf: [24]u8 = undefined;
    try std.testing.expectEqual(ownPid(), readOwner(first.path, &buf).?);
    try std.testing.expect(first.took_over == null);
    first.release();
    // Released cleanly: the next session claims it at once, and does not
    // take it for a stale lock.
    var second = try SessionLock.acquire(a, root);
    try std.testing.expect(second.took_over == null);
    second.release();
}

test "session lock: a stale lock is taken over by exactly one contender (cli#474)" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const root = try std.fs.path.join(a, &.{ base, "session" });
    defer a.free(root);
    // A lock left by a session killed outright: it names a PID that no
    // longer runs, and nobody holds the OS lock.
    try tmp.dir.writeFile(io, .{ .sub_path = "session.lock", .data = "#2147483000\n" });
    // Contender 1 has just taken it over (it holds the OS lock) but has not
    // rewritten the file yet: the file still names the dead PID. Under the
    // old PID-liveness check, contender 2 read the dead PID and took the
    // lock over as well.
    const contender = try tmp.dir.openFile(io, "session.lock", .{ .mode = .read_write, .lock = .exclusive, .lock_nonblocking = true });
    try std.testing.expectError(error.WatchSessionActive, SessionLock.acquire(a, root));
    // The kernel's verdict, not the recorded PID, decides: once the first
    // contender is gone, the stale lock is taken over and rewritten.
    contender.close(io);
    var owner = try SessionLock.acquire(a, root);
    defer owner.release();
    try std.testing.expectEqual(@as(?u64, 2147483000), owner.took_over);
    var buf: [24]u8 = undefined;
    try std.testing.expectEqual(ownPid(), readOwner(owner.path, &buf).?);
}

test "session lock: a symbolic link or directory at the lock path is refused, and never written through (cli#476)" {
    if (is_windows) return error.SkipZigTest; // links need a privilege there
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const root = try std.fs.path.join(a, &.{ base, "session" });
    defer a.free(root);
    // A link planted at the lock path, naming a file of the user's.
    try tmp.dir.writeFile(io, .{ .sub_path = "victim.txt", .data = "precious" });
    try tmp.dir.symLink(io, "victim.txt", "session.lock", .{});
    try std.testing.expectError(error.WatchLockNotRegular, SessionLock.acquire(a, root));
    const victim = try tmp.dir.readFileAlloc(io, "victim.txt", a, .limited(64));
    defer a.free(victim);
    try std.testing.expectEqualStrings("precious", victim);
    // A dangling link is refused too (nothing is created through it).
    try tmp.dir.deleteFile(io, "session.lock");
    try tmp.dir.symLink(io, "created.txt", "session.lock", .{});
    try std.testing.expectError(error.WatchLockNotRegular, SessionLock.acquire(a, root));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "created.txt", .{}));
    // So is a directory.
    try tmp.dir.deleteFile(io, "session.lock");
    try tmp.dir.createDirPath(io, "session.lock");
    try std.testing.expectError(error.WatchLockNotRegular, SessionLock.acquire(a, root));
}

test "session lock: a failed PID rewrite closes the claimed handle exactly once (cli#476)" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const root = try std.fs.path.join(a, &.{ base, "session" });
    defer a.free(root);
    test_fail_rewrite = true;
    const before = test_closes;
    try std.testing.expectError(error.NoSpaceLeft, SessionLock.acquire(a, root));
    test_fail_rewrite = false;
    // One cleanup ran, not two...
    try std.testing.expectEqual(before + 1, test_closes);
    // ...and it released the lock: the next session claims it.
    var next = try SessionLock.acquire(a, root);
    next.release();
}
