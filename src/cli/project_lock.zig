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
//! Nested commands (cli#490): a holder writes a random token to
//! `.labelle/project.lock.owner` (cleared before it releases), and every
//! child it spawns (through `supervise.spawn` or
//! `runner.buildEnvironWithExtra`: hooks, provider tools, `.prebuild`
//! steps, the assembler, `zig build`) inherits `LABELLE_PROJECT_LOCK_HELD`
//! listing the tokens of the locks it holds, after any inherited ones. A
//! labelle process that finds a project's lock BUSY while the owner file
//! holds one of its inherited tokens runs inside that holder, which waits
//! for it: it fails at once with `error.ProjectLockHeldByParent` instead of
//! waiting forever, and never writes, so the holder's transaction (and its
//! compare-and-restore) stays exclusive. A free lock, or one held by anybody
//! else (a stale token from a descendant that outlived its holder), is
//! waited for and taken as usual. The pipeline checks this before its
//! `.prebuild` steps too (`refuseNested`), so a nested command never re-runs
//! the step that started it. One watch session runs per process, so every
//! lock this process holds belongs to its children's caller.
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

/// The tokens of the project locks an ancestor labelle process holds
/// (cli#490), joined with `std.fs.path.delimiter` (hex: never ambiguous).
pub const held_env = "LABELLE_PROJECT_LOCK_HELD";

/// Where a holder records its token, next to the lock.
pub const owner_rel_path = ".labelle" ++ std.fs.path.sep_str ++ "project.lock.owner";

pub const Token = [32]u8;

/// The tokens of the project locks this process holds, for `exportHeld`.
const Registry = struct {
    mutex: std.Io.Mutex = .init,
    tokens: std.ArrayList(Token) = .empty,
};
var registry: Registry = .{};

pub const Held = struct {
    file: std.Io.File,
    token: Token,
    /// `<project>/<owner_rel_path>`, owned by `std.heap.smp_allocator`.
    owner_path: []u8,

    /// Drop the lock (closing the handle releases it), clearing the owner
    /// record first, while still holding, so the token never names a later
    /// holder.
    pub fn release(self: Held) void {
        const io = config.globalIo();
        registry.mutex.lockUncancelable(io);
        for (registry.tokens.items, 0..) |token, i| if (std.mem.eql(u8, &token, &self.token)) {
            _ = registry.tokens.swapRemove(i);
            break;
        };
        registry.mutex.unlock(io);
        lock_open.writeRegular(self.owner_path, "") catch {};
        std.heap.smp_allocator.free(self.owner_path);
        self.file.close(io);
    }
};

/// Tell a child process which project locks it runs under (cli#490): sets
/// `held_env` in `map` to the inherited value followed by the token of
/// every lock this process holds that it does not name yet. Leaves `map`
/// untouched while it holds none.
pub fn exportHeld(a: std.mem.Allocator, map: *std.process.Environ.Map) !void {
    const io = config.globalIo();
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);
    if (registry.tokens.items.len == 0) return;
    var value: std.ArrayList(u8) = .empty;
    defer value.deinit(a);
    if (map.get(held_env)) |inherited| if (inherited.len > 0) try value.appendSlice(a, inherited);
    for (registry.tokens.items) |token| {
        if (namesToken(value.items, &token)) continue;
        if (value.items.len > 0) try value.append(a, std.fs.path.delimiter);
        try value.appendSlice(a, &token);
    }
    try map.put(held_env, value.items);
}

/// The environment for a child about to be spawned with `given` (`null`:
/// the inherited one) while this process may hold a project lock: `null`
/// (spawn with `given` as is) when it holds none, else a copy with
/// `exportHeld` applied. Applied at spawn time, so an environment built
/// before the lock was taken still carries its token.
pub fn childEnviron(a: std.mem.Allocator, given: ?*const std.process.Environ.Map) !?std.process.Environ.Map {
    const io = config.globalIo();
    registry.mutex.lockUncancelable(io);
    const holding = registry.tokens.items.len > 0;
    registry.mutex.unlock(io);
    if (!holding) return null;
    var map = if (given) |env| try env.clone(a) else try config.globalEnviron().createMap(a);
    errdefer map.deinit();
    try exportHeld(a, &map);
    return map;
}

/// True when `list` (a `held_env` value) holds `token`.
pub fn namesToken(list: []const u8, token: []const u8) bool {
    if (token.len == 0) return false;
    var it = std.mem.splitScalar(u8, list, std.fs.path.delimiter);
    while (it.next()) |entry| if (std.mem.eql(u8, entry, token)) return true;
    return false;
}

/// Test seam: stands in for an inherited `held_env` value (the process
/// environment is a snapshot a test cannot change). Never set in production.
pub var test_inherited: ?[]const u8 = null;

/// True when the owner record of `project_dir` holds a token this process
/// inherited: the lock's current holder is one of its ancestors.
fn ownerIsAncestor(a: std.mem.Allocator, project_dir: []const u8) bool {
    const env_list: ?[]u8 = if (test_inherited == null) (config.globalEnviron().getAlloc(a, held_env) catch return false) else null;
    defer if (env_list) |l| a.free(l);
    const list = test_inherited orelse env_list.?;
    const path = std.fs.path.join(a, &.{ project_dir, owner_rel_path }) catch return false;
    defer a.free(path);
    const owner = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, a, .limited(256)) catch return false;
    defer a.free(owner);
    return namesToken(list, std.mem.trim(u8, owner, " \t\r\n"));
}

fn reportNested(lock_path: []const u8) error{ProjectLockHeldByParent} {
    std.debug.print("labelle: this command writes labelle.lock, but it runs inside another labelle command that holds this project's lock (from a hook or a prebuild step of a watch rebuild, say), which waits for it to finish; waiting here would never end. Run it outside that command. (lock: {s})\n", .{lock_path});
    return error.ProjectLockHeldByParent;
}

/// Fail with `error.ProjectLockHeldByParent` when an ancestor of this
/// process holds the project lock of `project_dir` (cli#490). The pipeline
/// calls it before anything runs (its `.prebuild` steps would otherwise
/// start again, and could nest forever) instead of meeting it only at its
/// lock write.
pub fn refuseNested(a: std.mem.Allocator, project_dir: []const u8) !void {
    if (!inherits(a)) return;
    const io = config.globalIo();
    const path = try std.fs.path.join(a, &.{ project_dir, rel_path });
    defer a.free(path);
    const file = lock_open.openRegular(path) catch return;
    defer file.close(io);
    // The owner is read only once the lock is seen busy, as in
    // `acquireWaiting`: a holder records its token after taking the lock
    // and clears it before releasing, so a token read then names a holder
    // that still holds it (a dead holder leaves its token, not its lock).
    if (try file.tryLock(io, .exclusive)) return;
    if (ownerIsAncestor(a, project_dir)) return reportNested(path);
}

/// True when this process inherited any project-lock token.
fn inherits(a: std.mem.Allocator) bool {
    if (test_inherited) |list| return list.len > 0;
    const list = config.globalEnviron().getAlloc(a, held_env) catch return false;
    defer a.free(list);
    return list.len > 0;
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
    var noticed = false;
    while (!try file.tryLock(io, .exclusive)) {
        _ = test_busy_polls.fetchAdd(1, .monotonic);
        if (!noticed and ownerIsAncestor(a, project_dir)) return reportNested(path);
        if (cancel.cancel_requested.load(.acquire)) return error.Canceled;
        if (wait.cancel) |c| if (c.canceled(c.ctx)) return error.Canceled;
        if (!noticed) {
            noticed = true;
            std.debug.print("labelle: waiting for {s}... (lock: {s})\n", .{ wait.note, path });
        }
        io.sleep(std.Io.Duration.fromMilliseconds(@intCast(poll_ms)), .awake) catch {};
    }
    var random: [16]u8 = undefined;
    io.random(&random);
    const token: Token = std.fmt.bytesToHex(random, .lower);
    const owner_path = try std.fs.path.join(std.heap.smp_allocator, &.{ project_dir, owner_rel_path });
    errdefer std.heap.smp_allocator.free(owner_path);
    // Best effort: without it a nested command waits, as before cli#490.
    lock_open.writeRegular(owner_path, &token) catch {};
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);
    try registry.tokens.append(std.heap.smp_allocator, token);
    return .{ .file = file, .token = token, .owner_path = owner_path };
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
    // The child inherits the marker carrying the holder's token.
    const list = try std.mem.concat(a, u8, &.{ "0123456789abcdef0123456789abcdef", &.{std.fs.path.delimiter}, &held.token });
    defer a.free(list);
    test_inherited = list;
    const before = test_busy_polls.load(.monotonic);
    try std.testing.expectError(error.ProjectLockHeldByParent, acquire(a, t.dir));
    // Exactly one busy poll: it recognised its ancestor on the first one
    // and never slept in the wait loop.
    try std.testing.expectEqual(before + 1, test_busy_polls.load(.monotonic));
    // The pipeline's early check refuses too, before any prebuild step.
    try std.testing.expectError(error.ProjectLockHeldByParent, refuseNested(a, t.dir));
}

test "project lock: a stale or foreign token, or a free lock, changes nothing (cli#490)" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var t = try Tmp.init(a);
    defer t.deinit(a);
    defer test_inherited = null;
    // A token from a holder that has since released: the owner record
    // was cleared, so the free lock is taken and nothing is refused.
    const old = try acquire(a, t.dir);
    const stale = old.token;
    old.release();
    test_inherited = &stale;
    try refuseNested(a, t.dir);
    const current = try acquire(a, t.dir);
    // Busy, but held by someone other than the ancestor that token named
    // (a descendant that outlived its holder): an ordinary wait (ended
    // here by a cancellation after three polls), not the nested refusal.
    try std.testing.expect(!std.mem.eql(u8, &stale, &current.token));
    try refuseNested(a, t.dir);
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
    current.release();
    // A holder that died leaves its token behind but not its lock.
    try t.tmp.dir.writeFile(io, .{ .sub_path = ".labelle/project.lock.owner", .data = &stale });
    try refuseNested(a, t.dir);
    const next = try acquire(a, t.dir);
    next.release();
}

test "project lock: children of a holder inherit its token, recorded next to the lock (cli#490)" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var t = try Tmp.init(a);
    defer t.deinit(a);
    var map = std.process.Environ.Map.init(a);
    defer map.deinit();
    // Holding nothing: the environment is left alone.
    try exportHeld(a, &map);
    try std.testing.expect(map.get(held_env) == null);
    try std.testing.expect((try childEnviron(a, null)) == null);
    const held = try acquire(a, t.dir);
    // The owner record names the holder.
    const owner = try t.tmp.dir.readFileAlloc(io, ".labelle/project.lock.owner", a, .limited(256));
    defer a.free(owner);
    try std.testing.expectEqualStrings(&held.token, owner);
    // Its token follows what an ancestor exported.
    try map.put(held_env, "ancestor");
    try exportHeld(a, &map);
    const value = map.get(held_env).?;
    try std.testing.expect(namesToken(value, "ancestor"));
    try std.testing.expect(namesToken(value, &held.token));
    // A spawn that would inherit gets a full environment carrying it.
    var child = (try childEnviron(a, null)).?;
    defer child.deinit();
    try std.testing.expect(namesToken(child.get(held_env).?, &held.token));
    // An environment built before the lock was taken gets it at spawn
    // time, once: a map that already names it is not extended.
    var early = std.process.Environ.Map.init(a);
    defer early.deinit();
    try early.put("KEPT", "1");
    var spawned = (try childEnviron(a, &early)).?;
    defer spawned.deinit();
    try std.testing.expectEqualStrings("1", spawned.get("KEPT").?);
    try std.testing.expectEqualStrings(&held.token, spawned.get(held_env).?);
    try std.testing.expect(early.get(held_env) == null);
    var again = (try childEnviron(a, &spawned)).?;
    defer again.deinit();
    try std.testing.expectEqualStrings(&held.token, again.get(held_env).?);
    held.release();
    // Released: nothing is exported any more, and the record is cleared.
    try std.testing.expect((try childEnviron(a, null)) == null);
    const cleared = try t.tmp.dir.readFileAlloc(io, ".labelle/project.lock.owner", a, .limited(256));
    defer a.free(cleared);
    try std.testing.expectEqualStrings("", cleared);
}
