//! The watch loop (cli#208, RFC cli#466 §3.4): configuration, the state
//! shared with whoever consumes the builds, the debounce rule, and the
//! watcher thread body that polls the tree, rebuilds and bumps the build
//! version. Platform-neutral: what a successful rebuild is FOR (a live
//! reload, a publication) is the caller's business.
const std = @import("std");
const tree = @import("tree.zig");
const TreeSignature = tree.TreeSignature;
const computeSignature = tree.computeSignature;
const snapshotTree = tree.snapshotTree;
const changedPaths = tree.changedPaths;
const WatchBaseline = @import("baseline.zig").WatchBaseline;

/// The rebuild callback signature. Returns true on a clean rebuild, false
/// on any failure (the session stays up; nothing consumes a broken build).
pub const RebuildFn = *const fn (ctx: *anyopaque) bool;

/// A rebuild's own declared outputs, which the rebuild may REPLACE when a
/// replan changes the prebuild steps (cli#463). Owned by the rebuild
/// context and mutated only by the rebuild callback, which runs on the
/// watcher thread, so the loop reads it without a lock. `epoch` moves
/// whenever `files` changes.
pub const IgnoreSet = struct {
    files: []const []const u8 = &.{},
    epoch: u64 = 0,
};

/// The loop's clock: waits one poll interval and returns false when the
/// loop must end. Injected by tests so a loop runs scripted, event-driven
/// ticks instead of sleeping; production uses `io.sleep`.
pub const Clock = struct {
    ctx: *anyopaque,
    wait: *const fn (ctx: *anyopaque, interval_ms: u32) bool,
};

/// Watch configuration.
pub const WatchConfig = struct {
    /// Project source tree to poll for changes. Build-output and VCS dirs
    /// (`.labelle`, `.git`, `zig-out`, …) are skipped so a rebuild — which
    /// writes into `.labelle/` — can't trigger itself.
    watch_dir: []const u8,
    /// Invoked (on the watcher thread) after a debounced change.
    rebuild_fn: RebuildFn,
    /// Opaque payload handed back to `rebuild_fn`.
    rebuild_ctx: *anyopaque,
    /// Poll cadence.
    poll_interval_ms: u32 = 400,
    /// Consecutive stable polls required before firing a rebuild — debounces
    /// a burst of saves into a single build. Minimum 1.
    quiet_polls: u32 = 2,
    /// Files the rebuild itself WRITES into the watched tree: the declared
    /// `.outputs` of the project's `.prebuild` steps (cli#355), as paths
    /// rooted the same way the walk builds them — see `watchIgnorePath`.
    ///
    /// They are excluded from the signature entirely, the same way
    /// `.labelle/` already is. Folding them in made a hook's own
    /// regeneration look like a fresh edit: `applied` is the signature
    /// captured BEFORE the rebuild callback, so the next poll saw the
    /// hook's write as a new change and ran a SECOND full
    /// generate/compile/browser-reload for it.
    ///
    /// Excluding rather than re-snapshotting after every callback is
    /// deliberate: a re-snapshot would also swallow a source file the
    /// user saved DURING the rebuild, which is a silently dropped edit —
    /// strictly worse than a redundant one. A declared output is a
    /// generated target, not a source; the input that produces it is
    /// still watched, so a real change still fires exactly one rebuild.
    ///
    /// Writers with no such declaration — provider lifecycle hooks, a
    /// prebuild step without `.outputs` — are bounded by `WatchBaseline`
    /// instead: their write costs a bounded number of follow-up rebuilds
    /// (one when it rewrites the same paths), never a loop.
    ignore_files: []const []const u8 = &.{},
    /// When set, the ignore set is read from here on every poll instead of
    /// `ignore_files`, so a rebuild that swaps the prebuild steps swaps
    /// their declared outputs out of the signature at the same moment.
    ignore: ?*const IgnoreSet = null,
    /// The tree as the build the session starts from read it: a watch
    /// session takes it BEFORE its cold build, so an edit saved while that
    /// build ran is unbuilt and fires a rebuild. `null`: the tree when the
    /// loop starts.
    baseline: ?TreeSignature = null,
    clock: ?Clock = null,
    /// The line printed after a clean rebuild.
    ok_note: []const u8 = "rebuild ok",

    fn ignored(self: WatchConfig) []const []const u8 {
        return if (self.ignore) |set| set.files else self.ignore_files;
    }

    fn epoch(self: WatchConfig) u64 {
        return if (self.ignore) |set| set.epoch else 0;
    }
};

/// A signature no tree has: the baseline a rebuild that changed the ignore
/// set leaves, so the next poll always fires one confirming rebuild.
const unbuilt_sentinel: TreeSignature = .{ .file_count = std.math.maxInt(u64), .digest = 0 };

/// Shared state between the watcher thread and its session. `version`
/// counts clean rebuilds; `stop` ends the loop so the session can join it.
pub const WatchState = struct {
    version: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Pure debounce decision: fire a rebuild once the tree has held a new,
/// unbuilt signature steady for at least `quiet_polls` consecutive polls.
/// Extracted for unit testing the burst-coalescing logic without threads.
fn shouldRebuild(unbuilt: bool, stable_polls: u32, quiet_polls: u32) bool {
    const need = if (quiet_polls == 0) 1 else quiet_polls;
    return unbuilt and stable_polls >= need;
}

/// Watcher thread body: poll the tree, debounce, rebuild, bump version.
/// Runs until `state.stop` is set (or the injected clock says stop). A
/// rebuild failure is surfaced in the terminal but keeps the loop (and the
/// session) alive; `applied` still advances so we don't respin on the same
/// broken tree — a later edit retriggers.
///
/// A rebuild that changed the ignore set (a replan swapped the prebuild
/// steps, cli#463) cannot be settled against snapshots taken under the old
/// set, so the loop re-baselines under the new set and forces ONE
/// confirming rebuild: an edit saved while that rebuild ran is never
/// dropped, at the cost of one redundant build per such change.
pub fn watchLoop(io: std.Io, cfg: WatchConfig, state: *WatchState) void {
    var scan_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scan_arena.deinit();

    // `baseline.applied` = signature of the last (attempted) build (see
    // `WatchBaseline` for how a self-writing rebuild settles it). `last` =
    // signature seen on the previous poll — used to detect a burst still in
    // flight.
    var initial = TreeSignature{};
    computeSignature(io, scan_arena.allocator(), cfg.watch_dir, cfg.ignored(), &initial);
    _ = scan_arena.reset(.retain_capacity);
    var baseline: WatchBaseline = .{ .applied = cfg.baseline orelse initial, .allocator = std.heap.page_allocator };
    defer baseline.deinit();
    // The two per-path snapshots bracketing each rebuild; reset after it.
    var rebuild_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer rebuild_arena.deinit();
    var last = initial;
    var stable_polls: u32 = 0;

    while (!state.stop.load(.acquire)) {
        if (cfg.clock) |clock| {
            if (!clock.wait(clock.ctx, cfg.poll_interval_ms)) return;
        } else {
            io.sleep(std.Io.Duration.fromMilliseconds(@intCast(cfg.poll_interval_ms)), .awake) catch return;
        }
        if (state.stop.load(.acquire)) return;

        var sig = TreeSignature{};
        computeSignature(io, scan_arena.allocator(), cfg.watch_dir, cfg.ignored(), &sig);
        _ = scan_arena.reset(.retain_capacity);

        if (!sig.eql(last)) {
            // Tree still changing — reset the quiet counter (debounce).
            last = sig;
            stable_polls = 0;
            continue;
        }
        stable_polls +|= 1;
        if (!shouldRebuild(baseline.unbuilt(sig), stable_polls, cfg.quiet_polls)) continue;

        std.debug.print("labelle: change detected — rebuilding...\n", .{});
        // The tree as this rebuild starts on it, and as the callback leaves
        // it: their per-path diff is what changed while it ran
        // (`WatchBaseline`).
        const ra = rebuild_arena.allocator();
        const epoch = cfg.epoch();
        const start = snapshotTree(io, ra, cfg.watch_dir, cfg.ignored());
        const ok = cfg.rebuild_fn(cfg.rebuild_ctx);
        if (cfg.epoch() != epoch) {
            // The declared outputs changed under this rebuild: judge the
            // tree afresh under the new set and confirm with one more build.
            baseline.deinit();
            var now = TreeSignature{};
            computeSignature(io, ra, cfg.watch_dir, cfg.ignored(), &now);
            baseline = .{ .applied = unbuilt_sentinel, .allocator = std.heap.page_allocator };
            last = now;
        } else {
            const post = snapshotTree(io, ra, cfg.watch_dir, cfg.ignored());
            const delta: ?[]const u64 = if (start.complete and post.complete)
                changedPaths(ra, start.paths.items, post.paths.items) catch null
            else
                null;
            baseline.settle(start.sig, post.sig, delta);
            if (baseline.capped != 0) std.debug.print("labelle: watch: settled after {d} follow-up rebuilds triggered by build outputs\n", .{baseline.capped});
        }
        _ = rebuild_arena.reset(.retain_capacity);
        stable_polls = 0;
        if (ok) {
            _ = state.version.fetchAdd(1, .release);
            std.debug.print("labelle: {s}\n", .{cfg.ok_note});
        } else {
            std.debug.print("labelle: rebuild failed — see errors above; still watching\n", .{});
        }
    }
}

test "shouldRebuild: fires only after quiet_polls stable ticks with unbuilt changes" {
    // Not yet stable enough.
    try std.testing.expect(!shouldRebuild(true, 1, 2));
    // Stable long enough + unbuilt → fire.
    try std.testing.expect(shouldRebuild(true, 2, 2));
    try std.testing.expect(shouldRebuild(true, 5, 2));
    // Nothing unbuilt → never fire, however long it's been quiet.
    try std.testing.expect(!shouldRebuild(false, 9, 2));
}

test "shouldRebuild: quiet_polls of 0 is clamped to 1 (fires on first stable tick)" {
    try std.testing.expect(shouldRebuild(true, 1, 0));
    try std.testing.expect(!shouldRebuild(false, 1, 0));
}

test "computeSignature: a same-size in-place edit triggers a rebuild" {
    // Windows FS mtime granularity/update timing makes real-FS same-size-edit
    // detection non-deterministic in CI; the deterministic coverage is the
    // in-memory `TreeSignature.mix` test in tree.zig.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(dir_path);

    // Two files; `b.txt` is written last (newest). Editing the OLDER `a.txt`
    // to the same length is the case the naive signature missed.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "aaaa" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "bbbb" });

    var applied = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &applied);

    // Same 4-byte length, different content → only the mtime moves. On
    // macOS/Linux the write bumps the file's mtime to a distinguishable
    // value, so the (path,size,mtime) digest flips.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "AAAA" });
    var now = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &now);

    try std.testing.expectEqual(applied.file_count, now.file_count);
    try std.testing.expect(!applied.eql(now));
    // …and that unbuilt delta drives a rebuild once it's held steady.
    try std.testing.expect(shouldRebuild(!now.eql(applied), 2, 2));
}

// The loop itself, on a real tree, driven by a scripted clock: every tick
// is an event the test controls, so nothing here depends on timing.
const Script = struct {
    dir: std.Io.Dir,
    ticks: u32 = 0,
    rebuilds: u32 = 0,
    rebuild_ticks: [8]u32 = undefined,
    max_ticks: u32,
    /// Writes to perform at a tick: (tick, file).
    edits: []const struct { tick: u32, name: []const u8 },
    ignore: IgnoreSet = .{},
    /// The rebuild at this index writes `out.txt` and adds it to the ignore
    /// set (a replan that swapped in a step declaring it, cli#463).
    swap_at: ?u32 = null,
    swapped: [1][]const u8 = undefined,
    out_path: []const u8 = "",

    fn wait(ctx: *anyopaque, _: u32) bool {
        const self: *Script = @ptrCast(@alignCast(ctx));
        self.ticks += 1;
        for (self.edits) |edit| {
            if (edit.tick == self.ticks) self.dir.writeFile(std.testing.io, .{ .sub_path = edit.name, .data = edit.name }) catch unreachable;
        }
        return self.ticks <= self.max_ticks;
    }

    fn rebuild(ctx: *anyopaque) bool {
        const self: *Script = @ptrCast(@alignCast(ctx));
        self.rebuild_ticks[self.rebuilds] = self.ticks;
        if (self.swap_at) |at| if (at == self.rebuilds) {
            self.dir.writeFile(std.testing.io, .{ .sub_path = "out.txt", .data = "generated" }) catch unreachable;
            self.swapped = .{self.out_path};
            self.ignore = .{ .files = &self.swapped, .epoch = self.ignore.epoch + 1 };
        };
        self.rebuilds += 1;
        return true;
    }
};

test "watchLoop: a debounced edit fires exactly one rebuild on a scripted clock" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(dir_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "a" });
    var script: Script = .{ .dir = tmp.dir, .max_ticks = 10, .edits = &.{.{ .tick = 2, .name = "b.txt" }} };
    var state: WatchState = .{};
    watchLoop(std.testing.io, .{ .watch_dir = dir_path, .rebuild_fn = Script.rebuild, .rebuild_ctx = &script, .clock = .{ .ctx = &script, .wait = Script.wait } }, &state);
    // Seen at tick 2, stable at ticks 3 and 4: one rebuild, then quiet.
    try std.testing.expectEqual(@as(u32, 1), script.rebuilds);
    try std.testing.expectEqual(@as(u32, 4), script.rebuild_ticks[0]);
    try std.testing.expectEqual(@as(u64, 1), state.version.load(.acquire));
}

test "watchLoop: a rebuild that swaps the ignore set is confirmed once, then its outputs never fire" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(dir_path);
    const out_path = try tree.watchIgnorePath(alloc, dir_path, "out.txt");
    defer alloc.free(out_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "a" });
    var script: Script = .{ .dir = tmp.dir, .max_ticks = 20, .edits = &.{.{ .tick = 2, .name = "project.cfg" }}, .swap_at = 0, .out_path = out_path };
    var state: WatchState = .{};
    watchLoop(std.testing.io, .{ .watch_dir = dir_path, .rebuild_fn = Script.rebuild, .rebuild_ctx = &script, .ignore = &script.ignore, .clock = .{ .ctx = &script, .wait = Script.wait } }, &state);
    // The swapping rebuild, then exactly one confirming rebuild; the new
    // step's output (now ignored) triggers nothing after that.
    try std.testing.expectEqual(@as(u32, 2), script.rebuilds);
    try std.testing.expectEqual(@as(u64, 1), script.ignore.epoch);
}

test "watchLoop: an edit saved before the loop started (during the cold build) fires a rebuild" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(dir_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "a" });
    // The session's baseline, taken before its cold build...
    var before = TreeSignature{};
    computeSignature(std.testing.io, alloc, dir_path, &.{}, &before);
    // ...and an edit saved while that build ran.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.txt", .data = "b" });
    var script: Script = .{ .dir = tmp.dir, .max_ticks = 6, .edits = &.{} };
    var state: WatchState = .{};
    watchLoop(std.testing.io, .{ .watch_dir = dir_path, .rebuild_fn = Script.rebuild, .rebuild_ctx = &script, .baseline = before, .clock = .{ .ctx = &script, .wait = Script.wait } }, &state);
    try std.testing.expectEqual(@as(u32, 1), script.rebuilds);
    // The mechanism: without the early baseline nothing fires.
    var quiet: Script = .{ .dir = tmp.dir, .max_ticks = 6, .edits = &.{} };
    var quiet_state: WatchState = .{};
    watchLoop(std.testing.io, .{ .watch_dir = dir_path, .rebuild_fn = Script.rebuild, .rebuild_ctx = &quiet, .clock = .{ .ctx = &quiet, .wait = Script.wait } }, &quiet_state);
    try std.testing.expectEqual(@as(u32, 0), quiet.rebuilds);
}
