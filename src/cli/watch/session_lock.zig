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

    pub fn acquire(allocator: std.mem.Allocator, root: []const u8) !SessionLock {
        const path = try std.fmt.allocPrint(allocator, "{s}.lock", .{root});
        errdefer allocator.free(path);
        if (std.fs.path.dirname(root)) |parent| try std.Io.Dir.cwd().createDirPath(config.globalIo(), parent);
        const file = try claim(path);
        return .{ .allocator = allocator, .path = path, .file = file };
    }

    /// Drop the OS lock (the file stays; see the module comment).
    pub fn release(self: *SessionLock) void {
        self.file.close(config.globalIo());
        self.allocator.free(self.path);
    }
};

/// Open `lock_path` (created if missing, never truncated before the lock
/// is ours) with a non-blocking exclusive OS lock. Refused: another live
/// session holds it. Granted: whatever the file recorded belongs to a
/// session that is gone, and it is rewritten with our PID.
fn claim(lock_path: []const u8) !std.Io.File {
    const io = config.globalIo();
    const file = std.Io.Dir.cwd().createFile(io, lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => {
            var buf: [24]u8 = undefined;
            if (readOwner(lock_path, &buf)) |owner| {
                std.debug.print("labelle: run --watch: another watch session (pid {d}) is already running for this target; stop it first (lock: {s})\n", .{ owner, lock_path });
            } else {
                std.debug.print("labelle: run --watch: another watch session (pid unknown) is already running for this target; stop it first (lock: {s})\n", .{lock_path});
            }
            return error.WatchSessionActive;
        },
        else => return err,
    };
    errdefer file.close(io);
    // The lock is ours: a previous owner, if the file names one, is gone.
    var prev: [24]u8 = undefined;
    const n = file.readPositionalAll(io, &prev, pid_offset) catch 0;
    if (parseOwner(prev[0..n])) |owner| {
        std.debug.print("labelle: run --watch: taking over a stale watch session lock (pid {d} is gone)\n", .{owner});
    }
    try file.setLength(io, 0);
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "#{d}\n", .{ownPid()});
    try file.writePositionalAll(io, text, 0);
    return file;
}

/// The PID a lock file records, read without taking the lock.
fn readOwner(lock_path: []const u8, buf: []u8) ?u64 {
    const io = config.globalIo();
    const file = std.Io.Dir.cwd().openFile(io, lock_path, .{}) catch return null;
    defer file.close(io);
    const n = file.readPositionalAll(io, buf, pid_offset) catch return null;
    return parseOwner(buf[0..n]);
}

fn parseOwner(bytes: []const u8) ?u64 {
    const owner = std.fmt.parseInt(u64, std.mem.trim(u8, bytes, " #\r\n"), 10) catch return null;
    return if (owner == 0) null else owner;
}

fn ownPid() u64 {
    if (is_windows) return GetCurrentProcessId();
    if (builtin.os.tag == .linux) return @intCast(std.os.linux.getpid());
    return @intCast(std.c.getpid());
}

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

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
    first.release();
    // Released: the next session claims it at once.
    var second = try SessionLock.acquire(a, root);
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
    var buf: [24]u8 = undefined;
    try std.testing.expectEqual(ownPid(), readOwner(owner.path, &buf).?);
}
