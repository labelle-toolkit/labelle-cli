//! The `--watch` loop (cli#208): configuration, the state shared with the
//! request handler, the debounce rule, and the watcher thread that polls
//! the tree, rebuilds and bumps the build version.
const std = @import("std");
const tree = @import("tree.zig");
const TreeSignature = tree.TreeSignature;
const computeSignature = tree.computeSignature;
const snapshotTree = tree.snapshotTree;
const changedPaths = tree.changedPaths;
const WatchBaseline = @import("baseline.zig").WatchBaseline;

/// The rebuild callback signature. Returns true on a clean rebuild, false
/// on any failure (the server stays up; the browser is NOT reloaded onto a
/// broken build).
pub const RebuildFn = *const fn (ctx: *anyopaque) bool;

/// Watch configuration passed to `serveAndOpen`.
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
};

/// Shared state between the watcher thread and the serve loop. `version`
/// is what the browser polls; `stop` lets `serveAndOpen`'s defer join the
/// thread cleanly (only exercised if the accept loop ever returns).
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
/// Runs until `state.stop` is set. A rebuild failure is surfaced in the
/// terminal but keeps the loop (and server) alive; `applied` still advances
/// so we don't respin on the same broken tree — a later edit retriggers.
pub fn watchLoop(io: std.Io, cfg: WatchConfig, state: *WatchState) void {
    var scan_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scan_arena.deinit();

    // `baseline.applied` = signature of the last (attempted) build (see
    // `WatchBaseline` for how a self-writing rebuild settles it). `last` =
    // signature seen on the previous poll — used to detect a burst still in
    // flight.
    var initial = TreeSignature{};
    computeSignature(io, scan_arena.allocator(), cfg.watch_dir, cfg.ignore_files, &initial);
    _ = scan_arena.reset(.retain_capacity);
    var baseline: WatchBaseline = .{ .applied = initial, .allocator = std.heap.page_allocator };
    defer baseline.deinit();
    // The two per-path snapshots bracketing each rebuild; reset after it.
    var rebuild_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer rebuild_arena.deinit();
    var last = initial;
    var stable_polls: u32 = 0;

    const interval = std.Io.Duration.fromMilliseconds(@intCast(cfg.poll_interval_ms));

    while (!state.stop.load(.acquire)) {
        io.sleep(interval, .awake) catch return;
        if (state.stop.load(.acquire)) return;

        var sig = TreeSignature{};
        computeSignature(io, scan_arena.allocator(), cfg.watch_dir, cfg.ignore_files, &sig);
        _ = scan_arena.reset(.retain_capacity);

        if (!sig.eql(last)) {
            // Tree still changing — reset the quiet counter (debounce).
            last = sig;
            stable_polls = 0;
            continue;
        }
        stable_polls +|= 1;
        if (!shouldRebuild(baseline.unbuilt(sig), stable_polls, cfg.quiet_polls)) continue;

        std.debug.print("labelle: change detected — rebuilding WASM...\n", .{});
        // The tree as this rebuild starts on it, and as the callback leaves
        // it: their per-path diff is what changed while it ran
        // (`WatchBaseline`).
        const ra = rebuild_arena.allocator();
        const start = snapshotTree(io, ra, cfg.watch_dir, cfg.ignore_files);
        const ok = cfg.rebuild_fn(cfg.rebuild_ctx);
        const post = snapshotTree(io, ra, cfg.watch_dir, cfg.ignore_files);
        const delta: ?[]const u64 = if (start.complete and post.complete)
            changedPaths(ra, start.paths.items, post.paths.items) catch null
        else
            null;
        baseline.settle(start.sig, post.sig, delta);
        if (baseline.capped != 0) std.debug.print("labelle: watch: settled after {d} follow-up rebuilds triggered by build outputs\n", .{baseline.capped});
        _ = rebuild_arena.reset(.retain_capacity);
        stable_polls = 0;
        if (ok) {
            _ = state.version.fetchAdd(1, .release);
            std.debug.print("labelle: rebuild ok — reloading connected browsers\n", .{});
        } else {
            std.debug.print("labelle: rebuild failed — see errors above; server still running\n", .{});
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
