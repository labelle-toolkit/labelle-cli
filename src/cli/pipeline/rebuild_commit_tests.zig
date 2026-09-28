//! A watched rebuild's commit point and what it watches (cli#474), end to
//! end against real projects, locks and a real `watch.Publisher`:
//!
//! - the staged `labelle.lock` is committed BEFORE the generation
//!   advances, and a failure after that still rolls it back;
//! - a lock that cannot be committed fails the rebuild, which rolls back;
//! - a cancel that arrives during the publication is honoured before the
//!   output switch and before the commit;
//! - a local provider's source edit is a session change, and its tree
//!   outside the project is watched.
//!
//! The tools are scripts (`testing.okTool`), so these tests are POSIX-only
//! like the transaction tests whose fixture they share.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const project_config = @import("../project_config.zig");
const supervise = @import("../supervise.zig");
const watch = @import("../watch.zig");
const rebuild = @import("rebuild.zig");
const Replanner = @import("rebuild_replan.zig").Replanner;
const project_lock = @import("../project_lock.zig");
const lockfile = @import("../lockfile.zig");
const SessionKey = @import("session_key.zig").SessionKey;
const tx = @import("rebuild_transaction_tests.zig");
const Fixture = tx.Fixture;
const Publish = tx.Publish;
const target = tx.target;

/// A real publisher over `<tmp>/stage`, publishing into `<tmp>/session`,
/// with generation 0 ("zero") already published.
pub const Published = struct {
    publisher: watch.Publisher,
    stage: []const u8,
    root: []const u8,
    /// Runs inside the publication, before the real one (a test's
    /// interleaving: a cancel "during the copy", ...).
    group: ?*supervise.Group = null,
    cancel_at: enum { never, copy, switch_ } = .never,
    gate: watch.PublishGate = undefined,

    pub fn init(self: *Published, fx: *Fixture) !void {
        const a = fx.a;
        const io = config.globalIo();
        try fx.tmp.dir.createDirPath(io, "stage");
        try fx.tmp.dir.writeFile(io, .{ .sub_path = "stage/index.txt", .data = "zero" });
        const base = try fx.tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(base);
        const stage = try std.fs.path.join(a, &.{ base, "stage" });
        const root = try std.fs.path.join(a, &.{ base, "session" });
        self.* = .{ .publisher = try watch.Publisher.init(a, root, stage), .stage = stage, .root = root };
        try self.publisher.publish(null);
        try fx.tmp.dir.writeFile(io, .{ .sub_path = "stage/index.txt", .data = "one" });
    }

    pub fn deinit(self: *Published, a: std.mem.Allocator) void {
        self.publisher.deinit(true);
        a.free(self.stage);
        a.free(self.root);
    }

    pub fn seam(self: *Published) @import("rebuild.zig").RebuildCtx.Publish {
        return .{ .ctx = self, .run = run };
    }

    fn run(ptr: *anyopaque, gate: watch.PublishGate) anyerror!void {
        const self: *Published = @ptrCast(@alignCast(ptr));
        if (self.cancel_at == .copy) self.group.?.cancel(config.globalIo());
        self.gate = gate;
        return self.publisher.publish(.{ .ctx = self, .before_switch = beforeSwitch, .before_advance = beforeAdvance });
    }

    fn beforeAdvance(ptr: *anyopaque) anyerror!void {
        const self: *Published = @ptrCast(@alignCast(ptr));
        try self.gate.before_advance(self.gate.ctx);
    }

    fn beforeSwitch(ptr: *anyopaque) anyerror!void {
        const self: *Published = @ptrCast(@alignCast(ptr));
        try self.gate.before_switch(self.gate.ctx);
        if (self.cancel_at == .switch_) self.group.?.cancel(config.globalIo());
    }

    fn served(self: *Published, a: std.mem.Allocator) ![]u8 {
        const path = try std.fs.path.join(a, &.{ self.publisher.output_dir, "index.txt" });
        defer a.free(path);
        return std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, a, .limited(64));
    }

    fn expectServes(self: *Published, a: std.mem.Allocator, text: []const u8, generation: u64) !void {
        const got = try self.served(a);
        defer a.free(got);
        try std.testing.expectEqualStrings(text, got);
        try std.testing.expectEqual(@as(?u64, generation), self.publisher.generation);
        const g = try std.Io.Dir.cwd().readFileAlloc(config.globalIo(), self.publisher.generation_file, a, .limited(64));
        defer a.free(g);
        var buf: [24]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "{d}\n", .{generation}), g);
    }
};

pub fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "rebuild commit: labelle.lock is committed before the generation advances, and rolled back after (cli#474)" {
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

    // What `labelle.lock` said when the generation file moved.
    const Spy = struct {
        var project: []const u8 = "";
        var lock_was_new = false;
        var fail = false;
        fn write(p: *watch.Publisher, n: u64) anyerror!void {
            const lock = try std.fs.path.join(std.testing.allocator, &.{ project, "labelle.lock" });
            defer std.testing.allocator.free(lock);
            const bytes = try std.Io.Dir.cwd().readFileAlloc(config.globalIo(), lock, std.testing.allocator, .limited(1 << 20));
            defer std.testing.allocator.free(bytes);
            lock_was_new = contains(bytes, "\"7.7.7\"");
            if (fail) return error.SharingViolation;
            return watch.Publisher.writeGeneration(p, n);
        }
    };
    Spy.project = fx.project;
    published.publisher.write_generation = Spy.write;
    try fx.write(.{ .version = "7.7.7" });

    // The generation write fails AFTER the lock was committed: the lock was
    // already the new one, and the rollback puts the old one back with the
    // old output.
    Spy.fail = true;
    try std.testing.expectError(error.PublishFailed, ctx.rebuildStaged());
    try std.testing.expect(Spy.lock_was_new);
    {
        const now = try fx.lockBytes();
        defer a.free(now);
        try std.testing.expectEqualSlices(u8, lock_v1, now);
    }
    try published.expectServes(a, "zero", 0);
    try std.testing.expectEqualStrings("1.0.0", site.cfg.plugins[0].version);

    // The same edit succeeding: when the generation advanced, the lock it
    // was built with was already in place.
    Spy.fail = false;
    Spy.lock_was_new = false;
    try ctx.rebuildStaged();
    try std.testing.expect(Spy.lock_was_new);
    try published.expectServes(a, "one", 1);
    const committed = try fx.lockBytes();
    defer a.free(committed);
    try std.testing.expect(contains(committed, "\"7.7.7\""));
}

test "rebuild commit: a staged lock that cannot be committed fails the rebuild, which rolls back (cli#474)" {
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
    const lock_v1 = try fx.lockBytes();
    defer a.free(lock_v1);
    const staged = try replan.stagedPath();
    const Fail = struct {
        fn rename(_: []const u8, _: []const u8) anyerror!void {
            return error.AccessDenied;
        }
    };

    try fx.write(.{ .version = "7.7.7" });
    // With a publication and without one (the legacy serve): the rename
    // fails, the rebuild fails, nothing is published and nothing of the
    // replan survives.
    for ([_]bool{ true, false }) |publishes| {
        if (!publishes) ctx.publish = null;
        replan.rename_lock = Fail.rename;
        Publish.reset();
        try std.testing.expectError(error.LockCommitFailed, ctx.rebuildStaged());
        try std.testing.expectEqual(@as(usize, 0), Publish.count);
        const now = try fx.lockBytes();
        defer a.free(now);
        try std.testing.expectEqualSlices(u8, lock_v1, now);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(config.globalIo(), staged, .{}));
        try std.testing.expectEqualStrings("1.0.0", site.cfg.plugins[0].version);
        try std.testing.expect(replan.current == null and replan.staged == null);
    }
    // The rename works again: the SAME bytes are replanned and locked
    // afresh (the synced digest was rolled back too) and committed.
    ctx.publish = .{ .ctx = &dummy, .run = Publish.run };
    replan.rename_lock = Replanner.renameLock;
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(usize, 1), Publish.count);
    try std.testing.expectEqualStrings("7.7.7", site.cfg.plugins[0].version);
    const committed = try fx.lockBytes();
    defer a.free(committed);
    try std.testing.expect(contains(committed, "\"7.7.7\""));
}

test "rebuild commit: a cancel during the publication is honoured before the switch and before the commit (cli#474)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    for ([_]bool{ false, true }) |at_switch| {
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
        var group: supervise.Group = .{};
        ctx.group = &group;
        var published: Published = undefined;
        try published.init(&fx);
        defer published.deinit(a);
        published.group = &group;
        // During the copy, or once the switch check passed (the switch and
        // the commit point still ahead).
        published.cancel_at = if (at_switch) .switch_ else .copy;
        ctx.publish = published.seam();
        const lock_v1 = try fx.lockBytes();
        defer a.free(lock_v1);
        try fx.write(.{ .version = "7.7.7" });

        // The session is shutting down while the output is being copied
        // (or just switched): the rebuild stops, publishes nothing and
        // commits nothing.
        try std.testing.expectError(error.Canceled, ctx.rebuildStaged());
        try published.expectServes(a, "zero", 0);
        const now = try fx.lockBytes();
        defer a.free(now);
        try std.testing.expectEqualSlices(u8, lock_v1, now);
        try std.testing.expectEqualStrings("1.0.0", site.cfg.plugins[0].version);
        try std.testing.expect(replan.current == null and replan.staged == null);
        // No copy of the cancelled generation is left.
        var dir = try std.Io.Dir.cwd().openDir(io, published.root, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            try std.testing.expect(!std.mem.startsWith(u8, entry.name, "published-1"));
        }
    }
}

test "rebuild commit: a local provider's source edit is a session change; its build output is not (cli#474)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit();
    try fx.write(.{});
    try fx.tmp.dir.createDirPath(io, "pkg/src");
    try fx.tmp.dir.writeFile(io, .{ .sub_path = "pkg/src/tool.zig", .data = "v1" });
    try fx.startup();
    var site = fx.site();
    defer site.env.deinit();
    const key = (try SessionKey.of(fx.arena.allocator(), fx.project, fx.cfg, fx.run_plan, @tagName(fx.cfg.backend), target, false, site.optimize)).?;
    try std.testing.expect(key.source != null);
    var replan = Replanner{ .backing = a, .project_dir = fx.project, .session = &key };
    defer replan.deinit(&site, fx.providers, fx.cfg);
    replan.baseline();
    var dummy: u8 = 0;
    var ctx = tx.rebuildCtx(&fx, &site, &replan, &dummy);
    defer ctx.deinit();
    ctx.fallback_optimize = "ReleaseSafe";
    Publish.reset();
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(usize, 1), Publish.count);
    // The provider's own build output (and a rewritten, identical
    // manifest) are not its source.
    try fx.tmp.dir.createDirPath(io, "pkg/zig-out/bin");
    try fx.tmp.dir.writeFile(io, .{ .sub_path = "pkg/zig-out/bin/tool", .data = "binary" });
    try fx.write(.{});
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(usize, 2), Publish.count);
    // Its source is: the running replacement keeps the tool it started with.
    try fx.tmp.dir.writeFile(io, .{ .sub_path = "pkg/src/tool.zig", .data = "v2" });
    try std.testing.expectError(error.SessionChanged, ctx.rebuildStaged());
    try std.testing.expectEqual(@as(usize, 2), Publish.count);
    // Reverted, it rebuilds again.
    try fx.tmp.dir.writeFile(io, .{ .sub_path = "pkg/src/tool.zig", .data = "v1" });
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(usize, 3), Publish.count);
}

test "rebuild commit: the local providers outside the project are watched with it (cli#474)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit();
    try fx.write(.{});
    // A local provider inside the project (walked with it already), a
    // local package without a manifest (not a provider), a remote one.
    try fx.tmp.dir.createDirPath(io, "project/providers/inner");
    try fx.tmp.dir.writeFile(io, .{ .sub_path = "project/providers/inner/plugin.labelle", .data = ".{}" });
    try fx.tmp.dir.createDirPath(io, "lib");
    const deps = [_]project_config.PluginDep{
        .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
        .{ .name = "inner", .repo = "local:providers/inner", .version = "1.0.0" },
        .{ .name = "lib", .repo = "local:../lib", .version = "1.0.0" },
        .{ .name = "remote", .repo = "github.com/example/remote", .version = "1.0.0" },
        .{ .name = "again", .repo = "local:../pkg/.", .version = "1.0.0" },
    };
    var roots = rebuild.localProviderRoots(a, fx.project, &deps);
    defer {
        for (roots.items) |r| a.free(r);
        roots.deinit(a);
    }
    const pkg = try fx.tmp.dir.realPathFileAlloc(io, "pkg", a);
    defer a.free(pkg);
    try std.testing.expectEqual(@as(usize, 1), roots.items.len);
    try std.testing.expectEqualStrings(pkg, roots.items[0]);

    // The session's watch set carries it from the start, and the watcher's
    // signature follows an edit there.
    try fx.startup();
    var site = fx.site();
    defer site.env.deinit();
    var replan = Replanner{ .backing = a, .project_dir = fx.project };
    defer replan.deinit(&site, fx.providers, fx.cfg);
    var dummy: u8 = 0;
    var ctx = tx.rebuildCtx(&fx, &site, &replan, &dummy);
    defer ctx.deinit();
    ctx.initIgnore();
    try std.testing.expectEqual(@as(u64, 0), ctx.ignore.epoch);
    try std.testing.expectEqual(@as(usize, 1), ctx.ignore.roots.len);
    try std.testing.expectEqualStrings(pkg, ctx.ignore.roots[0]);
    var before: watch.TreeSignature = .{};
    watch.computeSignatureRoots(io, a, fx.project, ctx.ignore.roots, ctx.ignore.files, &before);
    try fx.tmp.dir.writeFile(io, .{ .sub_path = "pkg/hooks.zig", .data = "edited" });
    var after: watch.TreeSignature = .{};
    watch.computeSignatureRoots(io, a, fx.project, ctx.ignore.roots, ctx.ignore.files, &after);
    try std.testing.expect(!before.eql(after));
}

/// A scripted watch loop over `project` + `roots`: `edit` is written at
/// tick 2; returns how many rebuilds fired in 10 ticks.
fn rebuildsAfterEdit(project: []const u8, roots: []const []const u8, edit: []const u8) !u32 {
    return rebuildsAfterEditIgnoring(project, roots, &.{}, edit);
}

fn rebuildsAfterEditIgnoring(project: []const u8, roots: []const []const u8, ignore: []const []const u8, edit: []const u8) !u32 {
    const Script = struct {
        path: []const u8,
        ticks: u32 = 0,
        rebuilds: u32 = 0,
        fn wait(ctx: *anyopaque, _: u32) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ticks += 1;
            if (self.ticks == 2) std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = self.path, .data = "edited in place" }) catch unreachable;
            return self.ticks <= 10;
        }
        fn rebuild(ctx: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.rebuilds += 1;
            return true;
        }
    };
    var script: Script = .{ .path = edit };
    var state: watch.WatchState = .{};
    watch.watchLoop(config.globalIo(), .{ .watch_dir = project, .extra_roots = roots, .ignore_files = ignore, .rebuild_fn = Script.rebuild, .rebuild_ctx = &script, .clock = .{ .ctx = &script, .wait = Script.wait } }, &state);
    return script.rebuilds;
}

fn freeRoots(a: std.mem.Allocator, roots: *std.ArrayList([]const u8)) void {
    for (roots.items) |r| a.free(r);
    roots.deinit(a);
}

test "rebuild commit: nested local providers are walked once, so an inner edit rebuilds (cli#474)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "outer/inner/src");
    try tmp.dir.createDirPath(io, "outer/checkout");
    try tmp.dir.writeFile(io, .{ .sub_path = "project/game.zig", .data = "g" });
    try tmp.dir.writeFile(io, .{ .sub_path = "outer/plugin.labelle", .data = ".{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "outer/inner/plugin.labelle", .data = ".{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "outer/inner/src/tool.zig", .data = "v1" });
    // A provider that is its own checkout: the outer walk skips it.
    try tmp.dir.writeFile(io, .{ .sub_path = "outer/checkout/plugin.labelle", .data = ".{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "outer/checkout/.git", .data = "gitdir: /elsewhere\n" });
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    const outer = try tmp.dir.realPathFileAlloc(io, "outer", a);
    defer a.free(outer);
    const checkout = try tmp.dir.realPathFileAlloc(io, "outer/checkout", a);
    defer a.free(checkout);
    const deps = [_]project_config.PluginDep{
        .{ .name = "inner", .repo = "local:../outer/inner", .version = "1.0.0" },
        .{ .name = "outer", .repo = "local:../outer", .version = "1.0.0" },
        .{ .name = "checkout", .repo = "local:../outer/checkout", .version = "1.0.0" },
    };
    var roots = rebuild.localProviderRoots(a, project, &deps);
    defer freeRoots(a, &roots);
    // The inner provider is covered by the outer root; the checkout is not.
    try std.testing.expectEqual(@as(usize, 2), roots.items.len);
    try std.testing.expectEqualStrings(outer, roots.items[0]);
    try std.testing.expectEqualStrings(checkout, roots.items[1]);
    // An edit in the inner provider fires one rebuild. Walked twice (once
    // per root), its XOR contributions cancelled out and nothing fired.
    const edit = try std.fs.path.join(a, &.{ outer, "inner", "src", "tool.zig" });
    defer a.free(edit);
    try std.testing.expectEqual(@as(u32, 1), try rebuildsAfterEdit(project, roots.items, edit));
    // The control edits real bytes too: back to "v1" first, so the edit
    // below is a change, not a rewrite of the same content.
    try tmp.dir.writeFile(io, .{ .sub_path = "outer/inner/src/tool.zig", .data = "v1" });
    const inner = try tmp.dir.realPathFileAlloc(io, "outer/inner", a);
    defer a.free(inner);
    const doubled = [_][]const u8{ outer, inner };
    try std.testing.expectEqual(@as(u32, 0), try rebuildsAfterEdit(project, &doubled, edit));
}

test "rebuild commit: a local provider containing the project is watched without the project (cli#474)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A monorepo whose root is a provider; the game lives inside it.
    try tmp.dir.createDirPath(io, "mono/tools");
    try tmp.dir.createDirPath(io, "mono/games/game/.labelle");
    try tmp.dir.writeFile(io, .{ .sub_path = "mono/plugin.labelle", .data = ".{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mono/tools/tool.zig", .data = "v1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mono/games/game/game.zig", .data = "g" });
    const mono = try tmp.dir.realPathFileAlloc(io, "mono", a);
    defer a.free(mono);
    const project = try tmp.dir.realPathFileAlloc(io, "mono/games/game", a);
    defer a.free(project);
    const deps = [_]project_config.PluginDep{.{ .name = "mono", .repo = "local:../..", .version = "1.0.0" }};
    var roots = rebuild.localProviderRoots(a, project, &deps);
    defer freeRoots(a, &roots);
    // Kept, not dropped.
    try std.testing.expectEqual(@as(usize, 1), roots.items.len);
    try std.testing.expectEqualStrings(mono, roots.items[0]);
    // An edit to the provider around the project rebuilds...
    const tool = try std.fs.path.join(a, &.{ mono, "tools", "tool.zig" });
    defer a.free(tool);
    try std.testing.expectEqual(@as(u32, 1), try rebuildsAfterEdit(project, roots.items, tool));
    // ...a project edit still does (the project is walked once, by its own
    // walk: folded twice, it would cancel out)...
    const game = try std.fs.path.join(a, &.{ project, "game.zig" });
    defer a.free(game);
    try std.testing.expectEqual(@as(u32, 1), try rebuildsAfterEdit(project, roots.items, game));
    // ...and the build output under the project's `.labelle/` does not.
    const out = try std.fs.path.join(a, &.{ project, ".labelle", "out.bin" });
    defer a.free(out);
    try std.testing.expectEqual(@as(u32, 0), try rebuildsAfterEdit(project, roots.items, out));
}

test "rebuild commit: a rollback restores an absent labelle.lock as absent (cli#474)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit();
    try fx.write(.{});
    try fx.startup();
    // The project had no lock before this rebuild.
    try fx.tmp.dir.deleteFile(io, "project/labelle.lock");
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
    const Spy = struct {
        var project: []const u8 = "";
        var lock_existed = false;
        fn write(_: *watch.Publisher, _: u64) anyerror!void {
            const lock = try std.fs.path.join(std.testing.allocator, &.{ project, "labelle.lock" });
            defer std.testing.allocator.free(lock);
            lock_existed = if (std.Io.Dir.cwd().access(config.globalIo(), lock, .{})) |_| true else |_| false;
            return error.SharingViolation;
        }
    };
    Spy.project = fx.project;
    published.publisher.write_generation = Spy.write;
    try fx.write(.{ .version = "7.7.7" });
    try std.testing.expectError(error.PublishFailed, ctx.rebuildStaged());
    // The lock was committed at the commit point, then rolled back to none.
    try std.testing.expect(Spy.lock_existed);
    try std.testing.expectError(error.FileNotFound, fx.tmp.dir.access(io, "project/labelle.lock", .{}));
    try published.expectServes(a, "zero", 0);
}

test "rebuild commit: a prebuild output inside an external local provider is ignored by its canonical walk (cli#476)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "pkg");
    try tmp.dir.writeFile(io, .{ .sub_path = "project/game.zig", .data = "g" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/plugin.labelle", .data = ".{}" });
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    const deps = [_]project_config.PluginDep{.{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" }};
    var roots = rebuild.localProviderRoots(a, project, &deps);
    defer freeRoots(a, &roots);
    try std.testing.expectEqual(@as(usize, 1), roots.items.len);
    // A step that regenerates a file inside the provider (not there yet).
    const steps = [_]@import("../prebuild.zig").Step{.{ .run = &.{"gen"}, .outputs = &.{"../pkg/gen.zig"} }};
    var ignore = rebuild.collectPrebuildIgnorePaths(a, project, &steps, true);
    defer freeRoots(a, &ignore);
    const gen = try std.fs.path.join(a, &.{ roots.items[0], "gen.zig" });
    defer a.free(gen);
    // The project-relative spelling, and the canonical one the walk uses.
    try std.testing.expectEqual(@as(usize, 2), ignore.items.len);
    try std.testing.expectEqualStrings(gen, ignore.items[1]);
    // The step's rewrite fires nothing...
    try std.testing.expectEqual(@as(u32, 0), try rebuildsAfterEditIgnoring(project, roots.items, ignore.items, gen));
    // ...which the project-relative spelling alone did not achieve (the
    // file is removed first, so the write is an addition, not a rewrite).
    try tmp.dir.deleteFile(io, "pkg/gen.zig");
    try std.testing.expectEqual(@as(u32, 1), try rebuildsAfterEditIgnoring(project, roots.items, ignore.items[0..1], gen));
}

test "rebuild commit: a project reached through a link watches the providers beside its real path (cli#476)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // links need a privilege there
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "real/project");
    try tmp.dir.createDirPath(io, "real/pkg");
    try tmp.dir.createDirPath(io, "elsewhere");
    try tmp.dir.writeFile(io, .{ .sub_path = "real/pkg/plugin.labelle", .data = ".{}" });
    // The project, as the user reaches it: `elsewhere/link`. Lexically,
    // `local:../pkg` from there is `elsewhere/pkg`, which does not exist;
    // discovery resolves it from the real path, `real/pkg`.
    try tmp.dir.symLink(io, "../real/project", "elsewhere/link", .{ .is_directory = true });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const link = try std.fs.path.join(a, &.{ base, "elsewhere", "link" });
    defer a.free(link);
    const pkg = try tmp.dir.realPathFileAlloc(io, "real/pkg", a);
    defer a.free(pkg);
    const deps = [_]project_config.PluginDep{.{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" }};
    var roots = rebuild.localProviderRoots(a, link, &deps);
    defer freeRoots(a, &roots);
    try std.testing.expectEqual(@as(usize, 1), roots.items.len);
    try std.testing.expectEqualStrings(pkg, roots.items[0]);
}

test "rebuild commit: a newly declared provider whose manifest fails the replan is still watched (cli#476)" {
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
    replan.baseline();
    var dummy: u8 = 0;
    var ctx = tx.rebuildCtx(&fx, &site, &replan, &dummy);
    defer ctx.deinit();
    ctx.initIgnore();
    try std.testing.expectEqual(@as(usize, 1), ctx.ignore.roots.len);
    const epoch = ctx.ignore.epoch;

    // The edit declares a second external provider whose manifest is
    // broken: the replan fails and nothing of it is committed...
    try fx.tmp.dir.createDirPath(io, "ext");
    try fx.tmp.dir.writeFile(io, .{ .sub_path = "ext/plugin.labelle", .data = ".{ this is not zon" });
    try fx.tmp.dir.writeFile(io, .{ .sub_path = "project/project.labelle", .data = ".{ .name = \"game\", .plugins = .{ .{ .name = \"pkg\", .repo = \"local:../pkg\", .version = \"1.0.0\" }, .{ .name = \"ext\", .repo = \"local:../ext\", .version = \"1.0.0\" } } }" });
    Publish.reset();
    if (ctx.rebuildStaged()) |_| return error.TestUnexpectedResult else |_| {}
    try std.testing.expectEqual(@as(usize, 0), Publish.count);
    try std.testing.expectEqual(@as(usize, 1), site.cfg.plugins.len);
    // ...but its tree joins the watch set.
    const ext = try fx.tmp.dir.realPathFileAlloc(io, "ext", a);
    defer a.free(ext);
    try std.testing.expectEqual(@as(usize, 2), ctx.ignore.roots.len);
    try std.testing.expect(ctx.ignore.epoch != epoch);
    var watched = false;
    for (ctx.ignore.roots) |r| watched = watched or std.mem.eql(u8, r, ext);
    try std.testing.expect(watched);
    // Fixing the manifest is a watched change: it fires a rebuild. With
    // only the committed roots, the same fix fired nothing.
    const manifest = try std.fs.path.join(a, &.{ ext, "plugin.labelle" });
    defer a.free(manifest);
    try std.testing.expectEqual(@as(u32, 1), try rebuildsAfterEditIgnoring(fx.project, ctx.ignore.roots, ctx.ignore.files, manifest));
    var committed = rebuild.localProviderRoots(a, fx.project, fx.cfg.plugins);
    defer freeRoots(a, &committed);
    try fx.tmp.dir.writeFile(io, .{ .sub_path = "ext/plugin.labelle", .data = ".{ still not zon" });
    try std.testing.expectEqual(@as(u32, 0), try rebuildsAfterEditIgnoring(fx.project, committed.items, ctx.ignore.files, manifest));
}

test "rebuild commit: a rollback leaves a labelle.lock another command rewrote meanwhile (cli#478)" {
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
    // Another command (a watch session for another target, an install)
    // writes its own lock between this rebuild's commit and its rollback.
    const Writer = struct {
        const newer = "// written by another command\n";
        var wrote = false;
        var saw_ours = false;
        fn write(lock: []const u8) void {
            const io = config.globalIo();
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, lock, std.testing.allocator, .limited(1 << 20)) catch return;
            defer std.testing.allocator.free(bytes);
            saw_ours = contains(bytes, "\"7.7.7\"");
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lock, .data = newer }) catch return;
            wrote = true;
        }
    };
    published.publisher.write_generation = Fail.write;
    replan.before_restore_lock = Writer.write;
    try fx.write(.{ .version = "7.7.7" });
    try std.testing.expectError(error.PublishFailed, ctx.rebuildStaged());
    // The mechanism: the rollback ran against this rebuild's committed lock,
    // found the concurrent write instead, and kept it.
    try std.testing.expect(Writer.saw_ours and Writer.wrote);
    {
        const now = try fx.lockBytes();
        defer a.free(now);
        try std.testing.expectEqualStrings(Writer.newer, now);
    }
    // Control: with nobody writing in between, the same rollback restores.
    const Quiet = struct {
        fn write(_: []const u8) void {}
    };
    replan.before_restore_lock = Quiet.write;
    try fx.write(.{ .version = "8.8.8" });
    try std.testing.expectError(error.PublishFailed, ctx.rebuildStaged());
    const now = try fx.lockBytes();
    defer a.free(now);
    try std.testing.expectEqualStrings(Writer.newer, now);
}

test "rebuild commit: a local provider whose manifest is deleted stays watched, so recreating it rebuilds (cli#478)" {
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
    replan.baseline();
    var dummy: u8 = 0;
    var ctx = tx.rebuildCtx(&fx, &site, &replan, &dummy);
    defer ctx.deinit();
    ctx.initIgnore();
    const pkg = try fx.tmp.dir.realPathFileAlloc(io, "pkg", a);
    defer a.free(pkg);
    try std.testing.expectEqual(@as(usize, 1), ctx.ignore.roots.len);
    try std.testing.expectEqualStrings(pkg, ctx.ignore.roots[0]);
    const manifest_bytes = try fx.tmp.dir.readFileAlloc(io, "pkg/plugin.labelle", a, .limited(1 << 20));
    defer a.free(manifest_bytes);

    // Delete: the rebuild that follows (whatever its verdict) keeps the
    // declared provider's folder in the watch set.
    try fx.tmp.dir.deleteFile(io, "pkg/plugin.labelle");
    _ = ctx.rebuildStaged() catch {};
    try std.testing.expectEqual(@as(usize, 1), ctx.ignore.roots.len);
    try std.testing.expectEqualStrings(pkg, ctx.ignore.roots[0]);
    // The mechanism: without the current watch set to keep it, the folder
    // drops out (no manifest, so not a provider)...
    var fresh = rebuild.localProviderRoots(a, fx.project, fx.cfg.plugins);
    defer freeRoots(a, &fresh);
    try std.testing.expectEqual(@as(usize, 0), fresh.items.len);

    // ...so recreating the manifest fires nothing there, while the kept
    // root rebuilds on it.
    const Recreate = struct {
        path: []const u8,
        data: []const u8,
        ticks: u32 = 0,
        rebuilds: u32 = 0,
        fn wait(c: *anyopaque, _: u32) bool {
            const self: *@This() = @ptrCast(@alignCast(c));
            self.ticks += 1;
            if (self.ticks == 2) std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = self.path, .data = self.data }) catch unreachable;
            return self.ticks <= 10;
        }
        fn rebuild_(c: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(c));
            self.rebuilds += 1;
            return true;
        }
        fn count(project: []const u8, roots: []const []const u8, ignore: []const []const u8, path: []const u8, data: []const u8) u32 {
            var script: @This() = .{ .path = path, .data = data };
            var state: watch.WatchState = .{};
            watch.watchLoop(config.globalIo(), .{ .watch_dir = project, .extra_roots = roots, .ignore_files = ignore, .rebuild_fn = rebuild_, .rebuild_ctx = &script, .clock = .{ .ctx = &script, .wait = wait } }, &state);
            return script.rebuilds;
        }
    };
    const manifest = try std.fs.path.join(a, &.{ pkg, "plugin.labelle" });
    defer a.free(manifest);
    try std.testing.expectEqual(@as(u32, 0), Recreate.count(fx.project, fresh.items, ctx.ignore.files, manifest, manifest_bytes));
    try fx.tmp.dir.deleteFile(io, "pkg/plugin.labelle");
    try std.testing.expectEqual(@as(u32, 1), Recreate.count(fx.project, ctx.ignore.roots, ctx.ignore.files, manifest, manifest_bytes));
    // The recreated manifest rebuilds cleanly, and the provider is watched
    // as a provider again.
    Publish.reset();
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(usize, 1), ctx.ignore.roots.len);
    try std.testing.expectEqualStrings(pkg, ctx.ignore.roots[0]);
}
