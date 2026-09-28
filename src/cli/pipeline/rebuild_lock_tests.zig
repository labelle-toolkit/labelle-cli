//! labelle.lock under the project lock (cli#481), end to end against real
//! projects and replanners: a write racing a rollback waits for it; each
//! watch session stages its lock privately; a commit keeps a newer CLI's
//! stamp; a rollback the project lock holds up is retried on a tick; the
//! rollback ancestry of overlapping sessions; the staged-lock sweep.
//!
//! POSIX-only like the transaction tests whose fixture they share.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const watch = @import("../watch.zig");
const rebuild = @import("rebuild.zig");
const Replanner = @import("rebuild_replan.zig").Replanner;
const project_lock = @import("../project_lock.zig");
const lockfile = @import("../lockfile.zig");
const lock_state = @import("../lock_state.zig");
const tx = @import("rebuild_transaction_tests.zig");
const commit_tests = @import("rebuild_commit_tests.zig");
const Fixture = tx.Fixture;
const Published = commit_tests.Published;
const contains = commit_tests.contains;

test "rebuild commit: a write racing the rollback's compare-and-restore waits for it and is never overwritten (cli#481)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit();
    try fx.write(.{});
    try fx.startup();
    var site = fx.site();
    defer site.env.deinit();
    var replan = Replanner{ .backing = a, .project_dir = fx.project };
    defer replan.deinit(&site, fx.providers, fx.cfg);
    replan.baseline();
    var dummy: u8 = 0;
    var ctx = tx.rebuildCtx(&fx, &site, &replan, &dummy);
    defer ctx.deinit();
    var published: Published = undefined;
    try published.init(&fx);
    defer published.deinit(a);
    ctx.publish = published.seam();
    const Fail = struct {
        fn write(_: *watch.Publisher, _: u64) anyerror!void {
            return error.SharingViolation;
        }
    };
    // Another command writes `labelle.lock` exactly in the window between
    // the rollback's compare (the lock is still this rebuild's) and its
    // restore, through the project lock as every writer does. Before
    // cli#481 that write landed and the restore overwrote it.
    const Racer = struct {
        const newer = "// written by another command\n";
        var thread: ?std.Thread = null;
        var saw_restored = false;
        var wrote = false;
        var project: []const u8 = "";
        fn write() void {
            const held = project_lock.acquire(std.testing.allocator, project) catch return;
            defer held.release();
            const io = config.globalIo();
            // Its own path: the rollback's is freed once it returns.
            const lock = std.fs.path.join(std.testing.allocator, &.{ project, "labelle.lock" }) catch return;
            defer std.testing.allocator.free(lock);
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, lock, std.testing.allocator, .limited(1 << 20)) catch return;
            defer std.testing.allocator.free(bytes);
            // It only got the lock after the restore finished.
            saw_restored = !contains(bytes, "\"7.7.7\"");
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lock, .data = newer }) catch return;
            wrote = true;
        }
        fn window(_: []const u8) void {
            const before = project_lock.test_busy_polls.load(.monotonic);
            thread = std.Thread.spawn(.{}, write, .{}) catch return;
            // Hold the window open until the racer is blocked on the lock.
            var spins: usize = 0;
            while (project_lock.test_busy_polls.load(.monotonic) == before and spins < 1000) : (spins += 1) {
                config.globalIo().sleep(std.Io.Duration.fromMilliseconds(5), .awake) catch {};
            }
        }
    };
    Racer.project = fx.project;
    published.publisher.write_generation = Fail.write;
    replan.restore_window = Racer.window;
    const polls = project_lock.test_busy_polls.load(.monotonic);
    try fx.write(.{ .version = "7.7.7" });
    try std.testing.expectError(error.PublishFailed, ctx.rebuildStaged());
    (Racer.thread orelse return error.TestUnexpectedResult).join();
    // The mechanism: the racer found the lock held and waited, and only
    // wrote after the restore; its newer lock is what stays.
    try std.testing.expect(project_lock.test_busy_polls.load(.monotonic) > polls);
    try std.testing.expect(Racer.saw_restored and Racer.wrote);
    const now = try fx.lockBytes();
    defer a.free(now);
    try std.testing.expectEqualStrings(Racer.newer, now);
}

test "rebuild commit: two watch sessions stage their locks privately, and each commits its own (cli#481)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit();
    try fx.write(.{});
    try fx.startup();
    var site = fx.site();
    defer site.env.deinit();
    // Two sessions of one project (two targets), each with its replanner.
    var one = Replanner{ .backing = a, .project_dir = fx.project };
    defer one.deinit(&site, fx.providers, fx.cfg);
    var two = Replanner{ .backing = a, .project_dir = fx.project };
    defer two.deinit(&site, fx.providers, fx.cfg);
    const p1 = try one.stagedPath();
    const p2 = try two.stagedPath();
    try std.testing.expect(!std.mem.eql(u8, p1, p2));
    var cfg1 = fx.cfg;
    cfg1.engine_version = "1.1.1";
    var cfg2 = fx.cfg;
    cfg2.engine_version = "2.2.2";
    // Both stage at once; one session rolling back drops only its own.
    try Replanner.stageLock(a, fx.project, cfg1, p1);
    try Replanner.stageLock(a, fx.project, cfg2, p2);
    Replanner.rollback(&one);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, p1, .{}));
    try std.Io.Dir.cwd().access(io, p2, .{});
    // Staged again: each commit installs its own session's lock.
    try Replanner.stageLock(a, fx.project, cfg1, p1);
    try Replanner.commitLock(&one);
    {
        const now = try fx.lockBytes();
        defer a.free(now);
        try std.testing.expect(contains(now, "\"1.1.1\"") and !contains(now, "\"2.2.2\""));
    }
    try std.Io.Dir.cwd().access(io, p2, .{});
    try Replanner.commitLock(&two);
    const now = try fx.lockBytes();
    defer a.free(now);
    try std.testing.expect(contains(now, "\"2.2.2\"") and !contains(now, "\"1.1.1\""));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, p2, .{}));
}

test "rebuild commit: the commit keeps a newer CLI's stamp written after the lock was staged (cli#481)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit();
    try fx.write(.{});
    try fx.startup();
    var site = fx.site();
    defer site.env.deinit();
    var replan = Replanner{ .backing = a, .project_dir = fx.project };
    defer replan.deinit(&site, fx.providers, fx.cfg);
    var cfg = fx.cfg;
    cfg.engine_version = "3.3.3";
    // Rendered with this CLI's stamp...
    try Replanner.stageLock(a, fx.project, cfg, try replan.stagedPath());
    // ...then a newer CLI writes the project's lock before the commit.
    const newer = ".{\n    .cli_version = \"999.0.0\",\n}\n";
    try fx.tmp.dir.writeFile(io, .{ .sub_path = "project/labelle.lock", .data = newer });
    try Replanner.commitLock(&replan);
    {
        const now = try fx.lockBytes();
        defer a.free(now);
        // The staged content, with the high-water stamp.
        try std.testing.expectEqualStrings("999.0.0", lockfile.lockCliVersion(now).?);
        try std.testing.expect(contains(now, "\"3.3.3\""));
    }
    // What the rollback compares against is the committed (raised) bytes:
    // the rollback recognises its own write and restores the newer CLI's lock.
    Replanner.rollback(&replan);
    const now = try fx.lockBytes();
    defer a.free(now);
    try std.testing.expectEqualStrings(newer, now);
}

test "rebuild commit: a rollback the project lock holds up is kept and done on a later watch tick (cli#481)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit();
    try fx.write(.{});
    try fx.startup();
    var site = fx.site();
    defer site.env.deinit();
    var replan = Replanner{ .backing = a, .project_dir = fx.project };
    defer replan.deinit(&site, fx.providers, fx.cfg);
    replan.baseline();
    var dummy: u8 = 0;
    var ctx = tx.rebuildCtx(&fx, &site, &replan, &dummy);
    defer ctx.deinit();
    var published: Published = undefined;
    try published.init(&fx);
    defer published.deinit(a);
    ctx.publish = published.seam();
    const lock_v1 = try fx.lockBytes();
    defer a.free(lock_v1);
    const Fail = struct {
        fn write(_: *watch.Publisher, _: u64) anyerror!void {
            return error.SharingViolation;
        }
    };
    // Another command takes the project lock after this rebuild committed
    // its lock and keeps it past the (shortened) wait of the rollback.
    const Holder = struct {
        var held: ?project_lock.Held = null;
        var project: []const u8 = "";
        fn take(_: []const u8) void {
            held = project_lock.acquire(std.testing.allocator, project) catch null;
        }
    };
    Holder.project = fx.project;
    const saved = project_lock.wait_budget_ms;
    project_lock.wait_budget_ms = 30;
    defer project_lock.wait_budget_ms = saved;
    published.publisher.write_generation = Fail.write;
    replan.before_restore_lock = Holder.take;
    try fx.write(.{ .version = "7.7.7" });
    try std.testing.expectError(error.PublishFailed, ctx.rebuildStaged());
    try std.testing.expect(Holder.held != null);
    // Not rolled back yet, and not given up: the saved lock is kept.
    try std.testing.expect(replan.restore_pending and replan.lock_before != null);
    {
        const now = try fx.lockBytes();
        defer a.free(now);
        try std.testing.expect(contains(now, "\"7.7.7\""));
    }
    // A tick while the lock is still held does not wait and changes nothing.
    rebuild.RebuildCtx.tick(&ctx);
    try std.testing.expect(replan.restore_pending);
    // The holder finishes: the next tick does the rollback.
    Holder.held.?.release();
    Holder.held = null;
    rebuild.RebuildCtx.tick(&ctx);
    try std.testing.expect(!replan.restore_pending and replan.lock_before == null);
    const now = try fx.lockBytes();
    defer a.free(now);
    try std.testing.expectEqualSlices(u8, lock_v1, now);
}

/// Two overlapping watch sessions of one project: session one commits lock
/// "1.1.1" over the original, then session two commits "2.2.2" over it.
const Overlap = struct {
    fx: Fixture = undefined,
    site: @import("../provider_hooks.zig").Site = undefined,
    one: Replanner = undefined,
    two: Replanner = undefined,
    original: []u8 = &.{},

    fn init(o: *Overlap, a: std.mem.Allocator) !void {
        try o.fx.init(a);
        try o.fx.write(.{});
        try o.fx.startup();
        o.site = o.fx.site();
        o.one = .{ .backing = a, .project_dir = o.fx.project };
        o.two = .{ .backing = a, .project_dir = o.fx.project };
        o.original = try o.fx.lockBytes();
        var cfg1 = o.fx.cfg;
        cfg1.engine_version = "1.1.1";
        var cfg2 = o.fx.cfg;
        cfg2.engine_version = "2.2.2";
        try Replanner.stageLock(a, o.fx.project, cfg1, try o.one.stagedPath());
        try Replanner.commitLock(&o.one);
        try Replanner.stageLock(a, o.fx.project, cfg2, try o.two.stagedPath());
        try Replanner.commitLock(&o.two);
    }

    fn deinit(o: *Overlap, a: std.mem.Allocator) void {
        a.free(o.original);
        o.two.deinit(&o.site, o.fx.providers, o.fx.cfg);
        o.one.deinit(&o.site, o.fx.providers, o.fx.cfg);
        o.site.env.deinit();
        o.fx.deinit();
    }

    fn expectLock(o: *Overlap, a: std.mem.Allocator, expected: []const u8) !void {
        const now = try o.fx.lockBytes();
        defer a.free(now);
        try std.testing.expectEqualSlices(u8, expected, now);
    }

    fn ancestors(o: *Overlap) !usize {
        const io = config.globalIo();
        var dir = try o.fx.tmp.dir.openDir(io, "project/.labelle", .{ .iterate = true });
        defer dir.close(io);
        var n: usize = 0;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (std.mem.startsWith(u8, entry.name, "labelle.lock.ancestor-")) n += 1;
        }
        return n;
    }
};

test "rebuild lock: overlapping sessions failing first-committed first end on the original lock (cli#481)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var o: Overlap = .{};
    try o.init(a);
    defer o.deinit(a);
    // Session one fails: session two's newer lock stays, and the lock one
    // replaced is recorded instead of dropped.
    Replanner.rollback(&o.one);
    {
        const now = try o.fx.lockBytes();
        defer a.free(now);
        try std.testing.expect(contains(now, "\"2.2.2\""));
    }
    try std.testing.expectEqual(@as(usize, 1), try o.ancestors());
    // Session two fails: it would restore session one's failed lock; the
    // record leads past it to the original, and is consumed.
    Replanner.rollback(&o.two);
    try o.expectLock(a, o.original);
    try std.testing.expectEqual(@as(usize, 0), try o.ancestors());
}

test "rebuild lock: overlapping sessions failing last-committed first end on the original lock (cli#481)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var o: Overlap = .{};
    try o.init(a);
    defer o.deinit(a);
    // Session two fails first: session one's lock is back...
    Replanner.rollback(&o.two);
    {
        const now = try o.fx.lockBytes();
        defer a.free(now);
        try std.testing.expect(contains(now, "\"1.1.1\""));
    }
    // ...then session one fails: the original is back; nothing recorded.
    Replanner.rollback(&o.one);
    try o.expectLock(a, o.original);
    try std.testing.expectEqual(@as(usize, 0), try o.ancestors());
}

test "rebuild lock: a session that commits after an earlier one failed keeps its lock and drops the stale record (cli#481)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var o: Overlap = .{};
    try o.init(a);
    defer o.deinit(a);
    Replanner.rollback(&o.one);
    try std.testing.expectEqual(@as(usize, 1), try o.ancestors());
    // Session two's rebuild succeeds: its lock is the published one, and
    // the record leading back from session one's lock is gone.
    Replanner.commit(&o.two);
    const now = try o.fx.lockBytes();
    defer a.free(now);
    try std.testing.expect(contains(now, "\"2.2.2\""));
    try std.testing.expectEqual(@as(usize, 0), try o.ancestors());
}

test "rebuild lock: a session start sweeps the staged locks of gone sessions (cli#481)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit();
    try fx.write(.{});
    try fx.startup();
    var site = fx.site();
    defer site.env.deinit();
    try fx.tmp.dir.createDirPath(io, "project/.labelle");
    // A session killed outright (no such PID) and a live one (this process).
    const gone = "project/.labelle/labelle.lock.staged-2147483000-0";
    try fx.tmp.dir.writeFile(io, .{ .sub_path = gone, .data = "x" });
    var buf: [96]u8 = undefined;
    const live = try std.fmt.bufPrint(&buf, "project/.labelle/labelle.lock.staged-{d}-4242", .{@import("../lock_open.zig").ownPid()});
    try fx.tmp.dir.writeFile(io, .{ .sub_path = live, .data = "x" });
    var replan = Replanner{ .backing = a, .project_dir = fx.project };
    defer replan.deinit(&site, fx.providers, fx.cfg);
    replan.baseline();
    try std.testing.expectError(error.FileNotFound, fx.tmp.dir.access(io, gone, .{}));
    try fx.tmp.dir.access(io, live, .{});
}
