//! What watched rebuilds keep on disk about `labelle.lock` under the
//! project's `.labelle/` (cli#481), shared between the watch sessions of a
//! project (one per target, each its own process). Every function here runs
//! with the project lock held (`project_lock.zig`).
//!
//! - **Rollback ancestry.** Session A commits lock A (replacing O), then
//!   session B commits lock B (replacing A). If A fails first, its
//!   compare-and-restore finds B in place and keeps it, but O — the lock to
//!   return to once B fails too — must not be lost: A records it here,
//!   keyed by the digest of the lock A committed (`record`). When B fails,
//!   the lock it would restore is A's failed one, so it follows the records
//!   (`resolve`) back to O. Rollbacks across overlapping sessions thus end
//!   on the last lock whose rebuild succeeded, or the original. A record is
//!   consumed when followed, dropped when the session that replaced its lock
//!   commits (`forget`: that lock is now superseded by a published one), and
//!   all of them go when a full lock write (install, generate, build, run)
//!   replaces the lock (`clearAll`).
//! - **Staged-lock sweep.** Each session stages its lock privately
//!   (`labelle.lock.staged-<pid>-<n>`); a session killed outright leaves its
//!   file behind. A new session removes those of processes that are gone
//!   (`sweepStaged`).
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const lock_open = @import("lock_open.zig");

const ancestor_prefix = "labelle.lock.ancestor-";
pub const staged_prefix = "labelle.lock.staged-";

/// A lock to return to: its bytes, or `null` when there was none.
pub const Lock = ?[]const u8;

fn ancestorPath(a: std.mem.Allocator, project_dir: []const u8, digest: [32]u8) ![]u8 {
    var name: [ancestor_prefix.len + 64]u8 = undefined;
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(name[0..ancestor_prefix.len], ancestor_prefix);
    @memcpy(name[ancestor_prefix.len..], &hex);
    return std.fs.path.join(a, &.{ project_dir, ".labelle", &name });
}

/// Remember `before` as the lock to return to once the lock with `digest`
/// (a failed rebuild's, still in effect under a newer one) is rolled back.
pub fn record(a: std.mem.Allocator, project_dir: []const u8, digest: [32]u8, before: Lock) !void {
    const path = try ancestorPath(a, project_dir, digest);
    defer a.free(path);
    const io = config.globalIo();
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    // 'A': there was no lock; 'B' + bytes: the lock.
    const data = if (before) |bytes| try std.mem.concat(a, u8, &.{ "B", bytes }) else try a.dupe(u8, "A");
    defer a.free(data);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

/// Follow the records from `start`: while the candidate is a lock some
/// failed rebuild committed, step to the lock that one replaced. Records
/// followed are consumed. Returns an owned copy (or `null` for no lock).
pub fn resolve(a: std.mem.Allocator, project_dir: []const u8, start: Lock) !Lock {
    const io = config.globalIo();
    var current: Lock = if (start) |bytes| try a.dupe(u8, bytes) else null;
    errdefer if (current) |bytes| a.free(bytes);
    var hops: usize = 0;
    while (current) |bytes| : (hops += 1) {
        if (hops == 64) break; // a cycle cannot happen; never loop forever
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const path = try ancestorPath(a, project_dir, digest);
        defer a.free(path);
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => break,
            else => return err,
        };
        defer a.free(data);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        a.free(bytes);
        current = if (data.len > 0 and data[0] == 'B') try a.dupe(u8, data[1..]) else null;
    }
    return current;
}

/// Drop the record of the lock with `digest`, if any.
pub fn forget(a: std.mem.Allocator, project_dir: []const u8, digest: [32]u8) void {
    const path = ancestorPath(a, project_dir, digest) catch return;
    defer a.free(path);
    std.Io.Dir.cwd().deleteFile(config.globalIo(), path) catch {};
}

/// Drop every record: a full lock write replaced whatever they led back to.
pub fn clearAll(a: std.mem.Allocator, project_dir: []const u8) void {
    removeMatching(a, project_dir, struct {
        fn remove(name: []const u8) bool {
            return std.mem.startsWith(u8, name, ancestor_prefix);
        }
    }.remove);
}

/// Remove the staged locks of watch sessions that are gone. POSIX: a file
/// whose PID no longer runs. Windows, where a PID check is awkward: a file
/// untouched for `stale_hours`. This process's own files stay.
pub fn sweepStaged(a: std.mem.Allocator, project_dir: []const u8) void {
    removeMatching(a, project_dir, staleStaged);
}

pub const stale_hours = 24;

/// Test seam: replaces the liveness check.
pub var test_alive: ?*const fn (u64) bool = null;

fn staleStaged(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, staged_prefix)) return false;
    const rest = name[staged_prefix.len..];
    const dash = std.mem.indexOfScalar(u8, rest, '-') orelse return false;
    const pid = std.fmt.parseInt(u64, rest[0..dash], 10) catch return false;
    _ = std.fmt.parseInt(u64, rest[dash + 1 ..], 10) catch return false;
    if (pid == lock_open.ownPid()) return false;
    if (test_alive) |alive| return !alive(pid);
    if (builtin.os.tag == .windows) return false; // decided by age instead (`removeMatching`)
    return !alivePosix(pid);
}

fn alivePosix(pid: u64) bool {
    if (builtin.os.tag == .windows) return true;
    const id = std.math.cast(std.posix.pid_t, pid) orelse return false;
    if (id <= 0) return true;
    std.posix.kill(id, @enumFromInt(0)) catch |err| return switch (err) {
        error.ProcessNotFound => false,
        else => true, // alive, not ours to signal
    };
    return true;
}

fn removeMatching(a: std.mem.Allocator, project_dir: []const u8, matches: *const fn ([]const u8) bool) void {
    const io = config.globalIo();
    const path = std.fs.path.join(a, &.{ project_dir, ".labelle" }) catch return;
    defer a.free(path);
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    const windows_age = builtin.os.tag == .windows and test_alive == null;
    const now_ns: i96 = std.Io.Timestamp.now(io, .real).nanoseconds;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        var remove = matches(entry.name);
        if (!remove and windows_age and std.mem.startsWith(u8, entry.name, staged_prefix) and matches == staleStaged) {
            const st = dir.statFile(io, entry.name, .{}) catch continue;
            remove = now_ns - st.mtime.nanoseconds > @as(i96, stale_hours) * std.time.ns_per_hour;
        }
        if (remove) dir.deleteFile(io, entry.name) catch {};
    }
}

// ── Tests ─────────────────────────────────────────────────────────────

test "lock state: ancestry records are followed back, consumed, and cleared (cli#481)" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    const digest = struct {
        fn of(bytes: []const u8) [32]u8 {
            var d: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
            return d;
        }
    }.of;
    // C was committed over B, B over A, A over no lock; A and B failed.
    try record(a, dir, digest("A"), null);
    try record(a, dir, digest("B"), "A");
    const back = try resolve(a, dir, "B");
    try std.testing.expect(back == null);
    // Consumed: a second walk stops at once.
    const again = (try resolve(a, dir, "B")).?;
    defer a.free(again);
    try std.testing.expectEqualStrings("B", again);
    // A lock no failed rebuild committed resolves to itself.
    try record(a, dir, digest("X"), "O");
    forget(a, dir, digest("X"));
    const kept = (try resolve(a, dir, "X")).?;
    defer a.free(kept);
    try std.testing.expectEqualStrings("X", kept);
    try record(a, dir, digest("Y"), "O");
    clearAll(a, dir);
    const cleared = (try resolve(a, dir, "Y")).?;
    defer a.free(cleared);
    try std.testing.expectEqualStrings("Y", cleared);
}

test "lock state: the sweep removes the staged locks of gone sessions only (cli#481)" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    try tmp.dir.createDirPath(io, ".labelle");
    var buf: [64]u8 = undefined;
    const own = try std.fmt.bufPrint(&buf, ".labelle/" ++ staged_prefix ++ "{d}-3", .{lock_open.ownPid()});
    const names = [_][]const u8{ ".labelle/" ++ staged_prefix ++ "111-0", ".labelle/" ++ staged_prefix ++ "222-5", own, ".labelle/" ++ staged_prefix ++ "junk", ".labelle/project.lock" };
    for (names) |name| try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "x" });
    // Session 111 is gone, 222 still runs (a seam: real PIDs are not ours to pick).
    test_alive = struct {
        fn alive(pid: u64) bool {
            return pid == 222;
        }
    }.alive;
    defer test_alive = null;
    sweepStaged(a, dir);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, names[0], .{}));
    for (names[1..]) |name| try tmp.dir.access(io, name, .{});
}

test "lock state: a PID that no longer runs is not alive (cli#481)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try std.testing.expect(alivePosix(lock_open.ownPid()));
    // Beyond every pid_max: no such process.
    try std.testing.expect(!alivePosix(2147483000));
}
