//! A watch session's lock transaction under the project lock (cli#481),
//! against real projects and replanners: two sessions whose rebuilds both
//! change `labelle.lock` run their transactions one after the other, the
//! second rendering its lock from the first's result; whatever fails, the
//! lock ends on the last published one; a Ctrl+C while a session waits
//! stops its rebuild cleanly; a commit never lowers a newer CLI's stamp.
//!
//! POSIX-only like the transaction tests whose fixture they share.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const supervise = @import("../supervise.zig");
const project_config = @import("../project_config.zig");
const provider_hooks = @import("../provider_hooks.zig");
const lockfile = @import("../lockfile.zig");
const project_lock = @import("../project_lock.zig");
const Replanner = @import("rebuild_replan.zig").Replanner;
const testing = @import("testing.zig");
const tx = @import("rebuild_transaction_tests.zig");
const commit_tests = @import("rebuild_commit_tests.zig");
const Fixture = tx.Fixture;
const contains = commit_tests.contains;

/// Two watch sessions of one project (one per target).
const Sessions = struct {
    fx: Fixture = undefined,
    site: provider_hooks.Site = undefined,
    one: Replanner = undefined,
    two: Replanner = undefined,

    fn init(s: *Sessions, a: std.mem.Allocator) !void {
        try s.fx.init(a);
        errdefer s.fx.deinit();
        try s.fx.write(.{});
        try s.fx.startup();
        s.site = s.fx.site();
        s.one = .{ .backing = a, .project_dir = s.fx.project, .describer = testing.fakeDescriber(s.fx.project) };
        s.two = .{ .backing = a, .project_dir = s.fx.project, .describer = testing.fakeDescriber(s.fx.project) };
    }

    fn deinit(s: *Sessions) void {
        s.two.deinit(&s.site, s.fx.providers, s.fx.cfg);
        s.one.deinit(&s.site, s.fx.providers, s.fx.cfg);
        s.site.env.deinit();
        s.fx.deinit();
    }

    fn cfg(s: *Sessions, engine: []const u8) project_config.ProjectConfig {
        var c = s.fx.cfg;
        c.engine_version = engine;
        return c;
    }
};

/// A session's lock transaction, as `run` + the commit point + the end of
/// the rebuild drive it: take the lock, stage, commit the lock, then
/// publish (commit) or fail (rollback).
const Txn = struct {
    replan: *Replanner,
    project: []const u8,
    cfg: project_config.ProjectConfig,
    publishes: bool,
    /// `labelle.lock` as the transaction found it once it had the lock.
    saw: ?[]u8 = null,
    err: ?anyerror = null,

    fn begin(t: *Txn) !void {
        const a = std.testing.allocator;
        try t.replan.holdLock(null);
        const lock = try std.fs.path.join(a, &.{ t.project, "labelle.lock" });
        defer a.free(lock);
        t.saw = try std.Io.Dir.cwd().readFileAlloc(config.globalIo(), lock, a, .limited(1 << 20));
        try Replanner.stageLock(a, t.project, t.cfg);
        try Replanner.commitLock(t.replan);
    }

    fn end(t: *Txn) void {
        if (t.publishes) Replanner.commit(t.replan) else Replanner.rollback(t.replan);
    }

    fn whole(t: *Txn) void {
        t.begin() catch |err| {
            t.err = err;
            return;
        };
        t.end();
    }

    fn deinit(t: *Txn) void {
        if (t.saw) |bytes| std.testing.allocator.free(bytes);
    }
};

fn waitBusy(before: usize) !void {
    var spins: usize = 0;
    while (project_lock.test_busy_polls.load(.monotonic) == before and spins < 2000) : (spins += 1) {
        config.globalIo().sleep(std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }
    if (project_lock.test_busy_polls.load(.monotonic) == before) return error.TestUnexpectedResult;
}

/// Session `first` is inside its lock transaction when `second` starts its
/// own: `second` waits, then renders from what `first` left.
fn overlap(first_publishes: bool, second_publishes: bool, second_first: bool) !void {
    const a = std.testing.allocator;
    var s: Sessions = .{};
    try s.init(a);
    defer s.deinit();
    const original = try s.fx.lockBytes();
    defer a.free(original);
    var first: Txn = .{ .replan = if (second_first) &s.two else &s.one, .project = s.fx.project, .cfg = s.cfg("1.1.1"), .publishes = first_publishes };
    defer first.deinit();
    var second: Txn = .{ .replan = if (second_first) &s.one else &s.two, .project = s.fx.project, .cfg = s.cfg("2.2.2"), .publishes = second_publishes };
    defer second.deinit();

    try first.begin();
    const polls = project_lock.test_busy_polls.load(.monotonic);
    const thread = try std.Thread.spawn(.{}, Txn.whole, .{&second});
    // The second session is blocked on the lock, not interleaving.
    try waitBusy(polls);
    try std.testing.expect(second.saw == null);
    {
        const now = try s.fx.lockBytes();
        defer a.free(now);
        try std.testing.expect(contains(now, "\"1.1.1\""));
    }
    first.end();
    thread.join();
    if (second.err) |err| return err;

    // The second session saw the first's outcome: its lock if it
    // published, the original if it rolled back.
    const after_first = second.saw.?;
    if (first_publishes) {
        try std.testing.expect(contains(after_first, "\"1.1.1\""));
    } else {
        try std.testing.expectEqualSlices(u8, original, after_first);
    }
    // The lock ends on the last published one.
    const now = try s.fx.lockBytes();
    defer a.free(now);
    if (second_publishes) {
        try std.testing.expect(contains(now, "\"2.2.2\""));
    } else {
        try std.testing.expectEqualSlices(u8, after_first, now);
    }
}

test "rebuild lock: overlapping sessions are serialized; both failing, in either order, leaves the original lock (cli#481)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try overlap(false, false, false); // one fails, then two fails
    try overlap(false, false, true); // two fails, then one fails
}

test "rebuild lock: overlapping sessions end on the last published lock (cli#481)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try overlap(true, false, false); // one publishes, two fails: one's lock
    try overlap(true, false, true); // two publishes, one fails: two's lock
    try overlap(false, true, false); // one fails, two publishes: two's lock
    try overlap(true, true, false); // both publish: the second's lock
}

test "rebuild lock: Ctrl+C while a rebuild waits for another session's transaction stops it cleanly (cli#481)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var s: Sessions = .{};
    try s.init(a);
    defer s.deinit();
    s.two.baseline();
    // Session one is inside its lock transaction.
    var first: Txn = .{ .replan = &s.one, .project = s.fx.project, .cfg = s.cfg("1.1.1"), .publishes = true };
    defer first.deinit();
    try first.begin();
    const locked = try s.fx.lockBytes();
    defer a.free(locked);
    // Session two rebuilds an edit that changes the lock: it waits, and the
    // stop handler cancels its group (Ctrl+C) while it does.
    var dummy: u8 = 0;
    var ctx = tx.rebuildCtx(&s.fx, &s.site, &s.two, &dummy);
    defer ctx.deinit();
    var group: supervise.Group = .{};
    ctx.group = &group;
    const Stopper = struct {
        fn run(g: *supervise.Group, before: usize) void {
            waitBusy(before) catch {};
            g.cancel(config.globalIo());
        }
    };
    try s.fx.write(.{ .version = "7.7.7" });
    const thread = try std.Thread.spawn(.{}, Stopper.run, .{ &group, project_lock.test_busy_polls.load(.monotonic) });
    const result = ctx.rebuildStaged();
    thread.join();
    try std.testing.expectError(error.Canceled, result);
    // Nothing of session two's is held, staged or written.
    try std.testing.expect(s.two.txn == null);
    const now = try s.fx.lockBytes();
    defer a.free(now);
    try std.testing.expectEqualSlices(u8, locked, now);
    first.end();
    // And the lock is free again.
    const held = try project_lock.acquire(a, s.fx.project);
    held.release();
}

test "rebuild lock: the commit keeps a newer CLI's stamp written after the lock was staged (cli#481)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var s: Sessions = .{};
    try s.init(a);
    defer s.deinit();
    try s.one.holdLock(null);
    // Rendered with this CLI's stamp...
    try Replanner.stageLock(a, s.fx.project, s.cfg("3.3.3"));
    // ...then a newer CLI's lock is in place before the commit (written
    // directly: a writer outside labelle).
    const newer = ".{\n    .cli_version = \"999.0.0\",\n}\n";
    try s.fx.tmp.dir.writeFile(io, .{ .sub_path = "project/labelle.lock", .data = newer });
    try Replanner.commitLock(&s.one);
    {
        const now = try s.fx.lockBytes();
        defer a.free(now);
        try std.testing.expectEqualStrings("999.0.0", lockfile.lockCliVersion(now).?);
        try std.testing.expect(contains(now, "\"3.3.3\""));
    }
    // The rollback compares against the committed (raised) bytes: it
    // recognises its own write and restores the lock it replaced.
    Replanner.rollback(&s.one);
    const now = try s.fx.lockBytes();
    defer a.free(now);
    try std.testing.expectEqualStrings(newer, now);
}
