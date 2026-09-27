//! `WatchBaseline`: which tree signature counts as built once a rebuild
//! returns — the follow-up, cap and ceiling policy that settles
//! self-writing rebuilds without dropping an edit or looping.
const std = @import("std");
const tree = @import("tree.zig");
const TreeSignature = tree.TreeSignature;
const pathKey = tree.pathKey;
const countNovel = tree.countNovel;
const unionKeys = tree.unionKeys;
const isSubset = tree.isSubset;
const test_helpers = @import("testing.zig");
const testSig = test_helpers.testSig;
const testDelta = test_helpers.testDelta;

/// Which tree signature counts as built once a rebuild callback returns.
///
/// Each rebuild is bracketed by two snapshots of the watched tree: `start`,
/// taken right before the callback (the rebuild's trigger), and `post`,
/// right after it. Their per-path diff is the rebuild's `delta`: every path
/// that changed WHILE it ran — its own writes (a provider lifecycle hook
/// declares no outputs; a prebuild step may omit `.outputs`) and any edit
/// the user saved meanwhile, which the rebuild may or may not have read.
///
/// The rule:
///
/// - A rebuild whose `delta` is empty is built at its trigger (= `post`).
/// - A rebuild is SETTLED — `post` counts as built — only when it is a
///   follow-up (fired for exactly the previous rebuild's `post`: nothing
///   changed between the two) AND its `delta` is a subset of the previous
///   rebuild's `delta`. A self-writing hook rewrites the same paths on
///   every run, so its follow-up changes nothing new and settles: one extra
///   rebuild per edit, never a loop (Codex P2 on #420).
/// - Otherwise the rebuild is built at its trigger only, so `post` stays
///   unbuilt and fires one more rebuild. A path the user saves during a
///   rebuild — the first one or a follow-up — is a path that rebuild's
///   predecessor did not change, so the next rebuild is scheduled and
///   reads it (Codex P2 on #427: the follow-up used to accept its whole
///   `post`, an edit it had already compiled past included). That next
///   rebuild is itself a follow-up whose `delta` is the hook's writes
///   again, so the chain still ends.
///
/// Snapshots are `(size, mtime)` per path, so one case stays ambiguous: a
/// path changed during two CONSECUTIVE rebuilds (a user re-saving, during
/// the follow-up, the same file they also saved during the rebuild before
/// it) is indistinguishable from a hook rewriting its output, and is taken
/// as the follow-up's own write. Settling there is what bounds the hook.
///
/// Follow-up cap. A writer that changes a DIFFERENT path on every run (a
/// timestamp-named report: `{a}`, then `{b}`, then `{c}`) never satisfies
/// the subset rule, and used to rebuild and reload forever (Codex P2 on
/// #427). A chain — a rebuild plus the consecutive follow-ups fired for
/// exactly their predecessor's `post` — therefore also tracks the union of
/// every delta in it (`recent`) and the writers' `footprint`: the fewest
/// paths outside `recent` that any rebuild of the chain changed (a varying
/// writer's per-run count; an edit saved meanwhile only adds to it). From
/// the `follow_up_cap`-th follow-up on, a follow-up that changed no more
/// new-to-the-chain paths than that footprint is taken as the writers'
/// own and SETTLES on its `post`, logged once as `labelle: watch: settled
/// after N follow-up rebuilds triggered by build outputs`. One that changed
/// more — the writers' new path plus a source the user saved during it —
/// still fires one more rebuild, so the edit is read. A user edit saved
/// between rebuilds never makes a follow-up at all (the trigger is not the
/// previous `post`): it always rebuilds and starts a new chain. The count
/// cannot tell apart an edit, saved during a capped follow-up, that adds
/// no new-to-the-chain path beyond the footprint — a re-save of a path
/// already in `recent`, or one landing on a run where the writers changed
/// fewer new paths than usual — and takes it as a build output: the
/// ambiguity above, widened to the chain.
///
/// Ceiling. The `follow_up_ceiling`-th follow-up of a chain settles only
/// the chain's own output paths — those an earlier rebuild of the chain
/// changed (`recent`). A path outside that set (a source the user saved
/// while that follow-up ran, or a writer's new output: the two cannot be
/// told apart) stays pending: the tree it left is unbuilt, so one more
/// rebuild reads it, and that rebuild starts a FRESH chain rather than
/// counting as a ninth follow-up (Codex P2 on #427, cli#429: the ceiling
/// used to mark every path the final callback saw as built). As the last
/// bound, a chain started that way which reaches the ceiling again
/// settles whatever it changed, so no writer (one whose output count keeps
/// growing, say) can loop: it costs at most two chains.
pub const WatchBaseline = struct {
    /// Follow-ups after which a varying-path chain may settle (see above).
    const follow_up_cap: u32 = 2;
    /// Follow-ups after which a chain settles unconditionally.
    const follow_up_ceiling: u32 = 8;

    /// Signature of the last (attempted) build.
    applied: TreeSignature,
    /// Signature taken right after the last rebuild callback returned.
    post: ?TreeSignature = null,
    /// Sorted keys of the paths the last rebuild changed while it ran;
    /// `null` when unknown (none yet, or its snapshots were partial).
    /// Owned by `allocator`.
    delta: ?[]u64 = null,
    /// Consecutive follow-ups in the current chain.
    follow_ups: u32 = 0,
    /// Sorted union of the current chain's deltas; `null` when no chain is
    /// tracked (none yet, a delta was unknown, or it could not be stored).
    /// Owned by `allocator`.
    recent: ?[]u64 = null,
    /// Fewest new-to-the-chain paths any rebuild of the chain changed.
    footprint: usize = 0,
    /// Set by the `settle` that ended a chain by the follow-up cap: how many
    /// follow-ups it took (the watcher logs it); 0 otherwise.
    capped: u32 = 0,
    /// Set when a chain reached the ceiling with paths outside its own
    /// outputs: the next rebuild (fired for that pending tree) starts a
    /// fresh chain instead of counting as another follow-up.
    restart_chain: bool = false,
    /// The current chain was started by such a ceiling: reaching the
    /// ceiling again settles unconditionally (the last bound).
    after_ceiling: bool = false,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WatchBaseline) void {
        if (self.delta) |d| self.allocator.free(d);
        self.delta = null;
        self.dropChain();
    }

    fn dropChain(self: *WatchBaseline) void {
        self.forgetRecent();
        self.follow_ups = 0;
        self.footprint = 0;
    }

    /// Record a finished rebuild fired for `trigger` (its start-of-rebuild
    /// signature), with the tree at `post` once the callback returned and
    /// `delta` the sorted keys of the paths that changed in between
    /// (`null`: unknown, which never settles on `post`). Borrows `delta`.
    pub fn settle(self: *WatchBaseline, trigger: TreeSignature, post: TreeSignature, delta: ?[]const u64) void {
        const restarted = self.restart_chain;
        self.restart_chain = false;
        const follow_up = !restarted and if (self.post) |previous| trigger.eql(previous) else false;
        if (!follow_up) {
            self.dropChain();
            self.after_ceiling = restarted;
        }
        self.capped = 0;
        const by_rule = if (delta) |d|
            d.len == 0 or (follow_up and self.delta != null and isSubset(d, self.delta.?))
        else
            false;
        const settled = by_rule or self.chain(follow_up, delta);
        self.applied = if (settled) post else trigger;
        self.post = post;
        const kept: ?[]u64 = if (delta) |d| self.allocator.dupe(u64, d) catch null else null;
        if (self.delta) |old| self.allocator.free(old);
        self.delta = kept;
    }

    /// The follow-up cap (see the type's doc): count a follow-up, record
    /// `delta` in the chain, and return true when this follow-up settles by
    /// the cap or the ceiling. An unknown `delta` stops the chain's path
    /// tracking (the cap cannot judge it) but still counts toward the
    /// ceiling, where it is judged as changing paths outside the chain.
    fn chain(self: *WatchBaseline, follow_up: bool, delta: ?[]const u64) bool {
        if (follow_up) self.follow_ups +|= 1;
        const d = delta orelse {
            self.forgetRecent();
            return self.atCeiling(follow_up, null) == .settled;
        };
        const novel = if (self.recent) |r| countNovel(d, r) else d.len;
        if (follow_up and self.recent != null and self.follow_ups >= follow_up_cap and novel <= self.footprint) {
            self.capped = self.follow_ups;
            self.dropChain();
            return true;
        }
        switch (self.atCeiling(follow_up, d)) {
            .below => {},
            .settled => return true,
            .pending => return false,
        }
        const first = self.recent == null;
        const merged = unionKeys(self.allocator, self.recent orelse &.{}, d) catch {
            // Out of memory: stop tracking; only the ceiling still bounds it.
            self.forgetRecent();
            return false;
        };
        self.forgetRecent();
        self.recent = merged;
        self.footprint = if (first) novel else @min(self.footprint, novel);
        return false;
    }

    fn forgetRecent(self: *WatchBaseline) void {
        if (self.recent) |r| self.allocator.free(r);
        self.recent = null;
    }

    const Ceiling = enum { below, settled, pending };

    /// The ceiling (see the type's doc), judged BEFORE `delta` joins
    /// `recent`: a follow-up at the ceiling settles when every path it
    /// changed is one of the chain's own outputs, or when the chain was
    /// itself started by a ceiling (the last bound). Otherwise the chain
    /// ends with its `post` pending, and the rebuild that reads it starts a
    /// fresh chain.
    fn atCeiling(self: *WatchBaseline, follow_up: bool, delta: ?[]const u64) Ceiling {
        if (!follow_up or self.follow_ups < follow_up_ceiling) return .below;
        const own = if (delta) |d| if (self.recent) |r| isSubset(d, r) else false else false;
        const settled = own or self.after_ceiling;
        if (settled) self.capped = self.follow_ups;
        self.dropChain();
        self.after_ceiling = false;
        self.restart_chain = !settled;
        return if (settled) .settled else .pending;
    }

    /// True when `sig` differs from the last build (subject to debounce).
    pub fn unbuilt(self: WatchBaseline, sig: TreeSignature) bool {
        return !sig.eql(self.applied);
    }
};

test "watch baseline: a rebuild that rewrites its own output settles after one follow-up" {
    // A hook that rewrites `assets/out.png` on every run: each callback
    // leaves the tree at a fresh signature, with that one path changed.
    const hook = testDelta(&.{"assets/out.png"});
    const edited = testSig("user edit");
    var b: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator };
    defer b.deinit();
    try std.testing.expect(b.unbuilt(edited));
    // Rebuild 1, for the user's edit; its hook writes -> `write1`.
    const write1 = testSig("hook write 1");
    b.settle(edited, write1, &hook);
    // The hook's write is unbuilt: one follow-up rebuild fires.
    try std.testing.expect(b.unbuilt(write1));
    // The follow-up's hook writes the same path again -> `write2`: nothing
    // its predecessor did not change, so it settles on `write2`.
    const write2 = testSig("hook write 2");
    b.settle(write1, write2, &hook);
    try std.testing.expect(!b.unbuilt(write2));
    // The mechanism: it is the follow-up's delta that settles it — the
    // same rebuild with an unknown delta leaves the hook's write pending.
    var unknown: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator };
    defer unknown.deinit();
    unknown.settle(edited, write1, &hook);
    unknown.settle(write1, write2, null);
    try std.testing.expect(unknown.unbuilt(write2));
}

test "watch baseline: an edit saved during the follow-up rebuild stays pending (Codex P2 on #427)" {
    const hook = testDelta(&.{"assets/out.png"});
    // The follow-up changed the hook's path AND a source the user saved
    // after the follow-up had read it.
    const hook_and_edit = testDelta(&.{ "assets/out.png", "src/main.zig" });
    var b: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator };
    defer b.deinit();
    const edited = testSig("user edit");
    const write1 = testSig("hook write 1");
    b.settle(edited, write1, &hook);
    try std.testing.expect(b.unbuilt(write1));
    // Follow-up (fired for `write1`), during which the user saves main.zig.
    const write2_with_edit = testSig("hook write 2 + edit");
    b.settle(write1, write2_with_edit, &hook_and_edit);
    // Not settled: main.zig is new relative to the previous rebuild's
    // writes, so the tree the follow-up left is still unbuilt and fires
    // one more rebuild. The old rule accepted it and lost the edit.
    try std.testing.expect(b.unbuilt(write2_with_edit));
    try std.testing.expect(b.applied.eql(write1));
    // That rebuild (fired for exactly the follow-up's post) only rewrites
    // the hook's path again: a subset, so the chain ends here — (a) still
    // holds with the edit in it, after exactly one more rebuild.
    const write3 = testSig("hook write 3");
    b.settle(write2_with_edit, write3, &hook);
    try std.testing.expect(!b.unbuilt(write3));
}

test "watch baseline: a scripted session never settles past an unread edit and never loops" {
    // A self-writing hook plus user saves landing at every point of the
    // chain. Each step: the trigger the watcher fired for, and what changed
    // while that rebuild ran. `must_rebuild` is whether the tree it left
    // is (correctly) still unbuilt.
    const Step = struct { trigger: []const u8, post: []const u8, delta: []const u64, must_rebuild: bool };
    const hook = testDelta(&.{"gen/out.zig"});
    const hook_a = testDelta(&.{ "gen/out.zig", "src/a.zig" });
    const hook_b = testDelta(&.{ "gen/out.zig", "src/b.zig" });
    const none = testDelta(&.{});
    const a_only = testDelta(&.{"src/a.zig"});
    const script = [_]Step{
        // Edit 1; the hook writes; a.zig saved meanwhile -> follow-up.
        .{ .trigger = "e1", .post = "p1", .delta = &hook_a, .must_rebuild = true },
        // Follow-up; b.zig saved during it -> one more.
        .{ .trigger = "p1", .post = "p2", .delta = &hook_b, .must_rebuild = true },
        // One more: only the hook's path -> settled.
        .{ .trigger = "p2", .post = "p3", .delta = &hook, .must_rebuild = false },
        // A later ordinary edit, with a save of a.zig during it and no
        // self-write -> the next rebuild reads a.zig...
        .{ .trigger = "e2", .post = "p4", .delta = &a_only, .must_rebuild = true },
        // ...and writes nothing: built.
        .{ .trigger = "p4", .post = "p4", .delta = &none, .must_rebuild = false },
    };
    var b: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator };
    defer b.deinit();
    for (script) |step| {
        b.settle(testSig(step.trigger), testSig(step.post), step.delta);
        try std.testing.expectEqual(step.must_rebuild, b.unbuilt(testSig(step.post)));
    }
}

test "watch baseline: a hook writing a different path each run settles at the follow-up cap (Codex P2 on #427)" {
    // A timestamp-named report: every run writes a NEW path, so no
    // follow-up's delta is a subset of its predecessor's.
    const r1 = testDelta(&.{"reports/1.txt"});
    const r2 = testDelta(&.{"reports/2.txt"});
    const r3 = testDelta(&.{"reports/3.txt"});
    var b: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator };
    defer b.deinit();
    b.settle(testSig("edit"), testSig("p1"), &r1);
    try std.testing.expect(b.unbuilt(testSig("p1")));
    // Follow-up 1: below the cap, still pending.
    b.settle(testSig("p1"), testSig("p2"), &r2);
    try std.testing.expect(b.unbuilt(testSig("p2")));
    try std.testing.expectEqual(@as(u32, 0), b.capped);
    // Follow-up 2 reaches the cap: one new path, the writer's footprint,
    // so it settles — and it was the cap that did it, not the subset rule.
    try std.testing.expect(!isSubset(&r3, &r2));
    b.settle(testSig("p2"), testSig("p3"), &r3);
    try std.testing.expect(!b.unbuilt(testSig("p3")));
    try std.testing.expectEqual(WatchBaseline.follow_up_cap, b.capped);
    // The chain is over: the next edit starts a fresh one, with the full
    // allowance again.
    b.settle(testSig("edit 2"), testSig("p4"), &r1);
    try std.testing.expectEqual(@as(u32, 0), b.capped);
    try std.testing.expect(b.unbuilt(testSig("p4")));
    b.settle(testSig("p4"), testSig("p5"), &r2);
    try std.testing.expect(b.unbuilt(testSig("p5")));
}

test "watch baseline: an edit saved during a capped follow-up still fires one more rebuild" {
    const r1 = testDelta(&.{"reports/1.txt"});
    const r2 = testDelta(&.{"reports/2.txt"});
    // At the cap, the writer's new report AND a source the user saved
    // while that follow-up ran: more new paths than the writer's footprint.
    const r3_edit = testDelta(&.{ "reports/3.txt", "src/main.zig" });
    const r4 = testDelta(&.{"reports/4.txt"});
    var b: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator };
    defer b.deinit();
    b.settle(testSig("edit"), testSig("p1"), &r1);
    b.settle(testSig("p1"), testSig("p2"), &r2);
    b.settle(testSig("p2"), testSig("p3"), &r3_edit);
    // Not settled: main.zig is read by one more rebuild.
    try std.testing.expect(b.unbuilt(testSig("p3")));
    try std.testing.expectEqual(@as(u32, 0), b.capped);
    // That rebuild only writes the next report: settled past the cap.
    b.settle(testSig("p3"), testSig("p4"), &r4);
    try std.testing.expect(!b.unbuilt(testSig("p4")));
    try std.testing.expectEqual(@as(u32, 3), b.capped);
}

test "watch baseline: an edit saved between capped-chain rebuilds always rebuilds and restarts the chain" {
    const r1 = testDelta(&.{"reports/1.txt"});
    const r2 = testDelta(&.{"reports/2.txt"});
    const r3 = testDelta(&.{"reports/3.txt"});
    const r4 = testDelta(&.{"reports/4.txt"});
    var b: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator };
    defer b.deinit();
    b.settle(testSig("edit"), testSig("p1"), &r1);
    b.settle(testSig("p1"), testSig("p2"), &r2);
    // The user saves after follow-up 1 returned: the tree the watcher
    // fires for is not `p2`, so this is no follow-up and cannot settle...
    b.settle(testSig("p2 + edit"), testSig("p3"), &r3);
    try std.testing.expect(b.unbuilt(testSig("p3")));
    try std.testing.expectEqual(@as(u32, 0), b.follow_ups);
    // ...and its follow-up is the new chain's first, below the cap.
    b.settle(testSig("p3"), testSig("p4"), &r4);
    try std.testing.expect(b.unbuilt(testSig("p4")));
    try std.testing.expectEqual(@as(u32, 1), b.follow_ups);
}

/// Drives a writer whose output count keeps growing (run `i` writes `i + 1`
/// paths nobody wrote before): never within the chain's footprint, so only
/// the ceiling can end its chains.
const GrowingWriter = struct {
    b: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator },
    keys: [512]u64 = undefined,
    next: usize = 0,
    run: usize = 0,
    trigger: TreeSignature = testSig("edit"),

    fn init(self: *GrowingWriter) void {
        for (&self.keys, 0..) |*k, i| k.* = 1_000_000 + i;
    }

    fn postOf(run: usize) TreeSignature {
        var sig = TreeSignature{};
        sig.mix("post", run, 0);
        return sig;
    }

    /// One rebuild; `extra` is a path saved while it ran (or null).
    /// Returns its post signature.
    fn step(self: *GrowingWriter, extra: ?u64) !TreeSignature {
        var delta: [64]u64 = undefined;
        const count = self.run + 1;
        @memcpy(delta[0..count], self.keys[self.next .. self.next + count]);
        self.next += count;
        var len = count;
        if (extra) |key| {
            delta[len] = key;
            len += 1;
        }
        std.mem.sort(u64, delta[0..len], {}, std.sort.asc(u64));
        const post = postOf(self.run);
        self.b.settle(self.trigger, post, delta[0..len]);
        self.trigger = post;
        self.run += 1;
        return post;
    }
};

test "watch baseline: a writer whose output keeps growing settles at the second ceiling" {
    var w: GrowingWriter = .{};
    w.init();
    defer w.b.deinit();
    // The first chain: the rebuild plus `follow_up_ceiling` follow-ups.
    // At its ceiling the writer's new paths are outside the chain's own
    // outputs, so the tree stays pending and the chain restarts.
    while (w.run < WatchBaseline.follow_up_ceiling) {
        try std.testing.expect(w.b.unbuilt(try w.step(null)));
    }
    const first_ceiling = try w.step(null);
    try std.testing.expect(w.b.unbuilt(first_ceiling));
    try std.testing.expectEqual(@as(u32, 0), w.b.capped);
    // The fresh chain started by that ceiling reaches it again: the last
    // bound settles it, so the writer cannot loop.
    var follow_up: u32 = 0;
    while (follow_up < WatchBaseline.follow_up_ceiling) : (follow_up += 1) {
        try std.testing.expect(w.b.unbuilt(try w.step(null)));
        try std.testing.expectEqual(follow_up, w.b.follow_ups);
    }
    const second_ceiling = try w.step(null);
    try std.testing.expect(!w.b.unbuilt(second_ceiling));
    try std.testing.expectEqual(WatchBaseline.follow_up_ceiling, w.b.capped);
}

test "watch baseline: a source edit saved during the ceiling follow-up stays pending (cli#429)" {
    var w: GrowingWriter = .{};
    w.init();
    defer w.b.deinit();
    while (w.run < WatchBaseline.follow_up_ceiling) _ = try w.step(null);
    try std.testing.expectEqual(WatchBaseline.follow_up_ceiling - 1, w.b.follow_ups);
    // The ceiling follow-up: the writer's paths plus a source the user
    // saved while it ran. Not settled — the old ceiling marked the whole
    // post built and the edit was never compiled.
    const trigger = w.trigger;
    const with_edit = try w.step(pathKey("src/main.zig"));
    try std.testing.expect(w.b.unbuilt(with_edit));
    try std.testing.expect(w.b.applied.eql(trigger));
    try std.testing.expectEqual(@as(u32, 0), w.b.capped);
    // The rebuild that reads it is fired for exactly that post, yet starts
    // a fresh chain instead of counting as a ninth follow-up.
    _ = try w.step(null);
    try std.testing.expectEqual(@as(u32, 0), w.b.follow_ups);
    try std.testing.expect(w.b.after_ceiling);
}

test "watch baseline: a ceiling follow-up that changed only the chain's own outputs settles" {
    // `atCeiling` judged directly: every path already in the chain's
    // `recent` set settles; one outside it leaves the tree pending.
    const own = testDelta(&.{ "gen/a.zig", "gen/b.zig" });
    const outside = testDelta(&.{ "gen/a.zig", "src/main.zig" });
    for ([_]struct { delta: []const u64, settles: bool }{
        .{ .delta = own[0..1], .settles = true },
        .{ .delta = &outside, .settles = false },
    }) |case| {
        var b: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator };
        defer b.deinit();
        b.recent = try std.testing.allocator.dupe(u64, &own);
        b.follow_ups = WatchBaseline.follow_up_ceiling;
        const verdict = b.atCeiling(true, case.delta);
        try std.testing.expectEqual(if (case.settles) WatchBaseline.Ceiling.settled else .pending, verdict);
        try std.testing.expectEqual(!case.settles, b.restart_chain);
    }
}

test "watch baseline: an edit saved during an ordinary rebuild still fires the next one" {
    var b: WatchBaseline = .{ .applied = testSig("start"), .allocator = std.testing.allocator };
    defer b.deinit();
    const first = testSig("edit 1");
    // A rebuild that writes nothing into the tree; the user saves again
    // while it runs, so the tree after the callback is `second`.
    const second = testSig("edit 2");
    const edit = testDelta(&.{"src/main.zig"});
    b.settle(first, second, &edit);
    try std.testing.expect(b.unbuilt(second));
    // That rebuild (fired for `second`) writes nothing: settled on it.
    b.settle(second, second, &.{});
    try std.testing.expect(!b.unbuilt(second));
    // A later edit is an ordinary trigger again: built at the trigger, so
    // a save during THIS rebuild is not swallowed either.
    const third = testSig("edit 3");
    const fourth = testSig("edit 4");
    b.settle(third, fourth, &edit);
    try std.testing.expect(b.unbuilt(fourth));
}
