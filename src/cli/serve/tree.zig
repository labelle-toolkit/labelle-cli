//! Watched-tree fingerprints: the cheap `TreeSignature` the polls compare,
//! the per-path `TreeSnapshot` taken around a rebuild and its diff, the
//! sorted key-set helpers, and the walk with its skip rules (build output,
//! declared outputs, nested git checkouts).
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const testDelta = @import("testing.zig").testDelta;

/// Directory names skipped while walking the watch tree. `.labelle` is the
/// load-bearing one — the rebuild writes there, so watching it would loop.
const watch_skip_dirs = [_][]const u8{ "zig-out", "zig-cache", "zig-pkg" };

/// A cheap fingerprint of a source tree: a file count plus a `digest`
/// that folds in every file's `(path, size, mtime)`. Folding per file
/// (rather than only summing sizes + tracking the single newest mtime)
/// makes the signature sensitive to *any* single-file change — including a
/// same-size edit to a non-newest file, or swapping content between two
/// files — so any add / edit / remove / mtime-change flips it.
pub const TreeSignature = struct {
    file_count: u64 = 0,
    /// Order-independent digest: each file contributes an independent
    /// 64-bit hash of its path+size+mtime, XOR-folded in. XOR is
    /// commutative, so directory iteration order doesn't matter, and a
    /// change to any single file toggles the bits its hash owns.
    digest: u64 = 0,

    /// Fold one file's identity into the signature.
    pub fn mix(self: *TreeSignature, path: []const u8, size: u64, mtime_ns: i128) void {
        var h = std.hash.Wyhash.init(0);
        h.update(path);
        h.update(std.mem.asBytes(&size));
        const m: i128 = mtime_ns;
        h.update(std.mem.asBytes(&m));
        self.file_count += 1;
        self.digest ^= h.final();
    }

    pub fn eql(a: TreeSignature, b: TreeSignature) bool {
        return a.file_count == b.file_count and a.digest == b.digest;
    }
};

/// One file's entry in a `TreeSnapshot`: a hash of its path (`key`) and of
/// its `(size, mtime)` (`state`).
pub const PathState = struct {
    key: u64,
    state: u64,

    fn lessThan(_: void, a: PathState, b: PathState) bool {
        return a.key < b.key;
    }
};

/// The key a path gets in a `TreeSnapshot`.
pub fn pathKey(path: []const u8) u64 {
    return std.hash.Wyhash.hash(0, path);
}

/// The watched tree at one instant: its `TreeSignature` plus every file's
/// `PathState`, sorted by key, so two snapshots can be diffed per path
/// (`changedPaths`). Taken only around a rebuild — the cheap signature
/// alone still drives the polls.
pub const TreeSnapshot = struct {
    sig: TreeSignature = .{},
    paths: std.ArrayList(PathState) = .empty,
    /// False when recording a path failed (out of memory): the per-path
    /// view is partial, so no delta can be drawn from it.
    complete: bool = true,

    fn record(self: *TreeSnapshot, a: std.mem.Allocator, path: []const u8, size: u64, mtime_ns: i128) void {
        self.sig.mix(path, size, mtime_ns);
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&size));
        const m: i128 = mtime_ns;
        h.update(std.mem.asBytes(&m));
        self.paths.append(a, .{ .key = pathKey(path), .state = h.final() }) catch {
            self.complete = false;
        };
    }

    fn sort(self: *TreeSnapshot) void {
        std.mem.sort(PathState, self.paths.items, {}, PathState.lessThan);
    }
};

/// The keys of the paths added, removed or changed between two sorted
/// snapshots, ascending. Caller owns the result.
pub fn changedPaths(a: std.mem.Allocator, before: []const PathState, after: []const PathState) ![]u64 {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    var j: usize = 0;
    while (i < before.len or j < after.len) {
        if (j == after.len or (i < before.len and before[i].key < after[j].key)) {
            try out.append(a, before[i].key);
            i += 1;
        } else if (i == before.len or after[j].key < before[i].key) {
            try out.append(a, after[j].key);
            j += 1;
        } else {
            if (before[i].state != after[j].state) try out.append(a, before[i].key);
            i += 1;
            j += 1;
        }
    }
    return out.toOwnedSlice(a);
}

/// How many keys of sorted `keys` are not in sorted `seen`.
pub fn countNovel(keys: []const u64, seen: []const u64) usize {
    var n: usize = 0;
    var j: usize = 0;
    for (keys) |key| {
        while (j < seen.len and seen[j] < key) j += 1;
        if (j == seen.len or seen[j] != key) n += 1;
    }
    return n;
}

/// The sorted, deduplicated union of sorted `x` and `y`. Caller owns it.
pub fn unionKeys(a: std.mem.Allocator, x: []const u64, y: []const u64) ![]u64 {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    var j: usize = 0;
    while (i < x.len or j < y.len) {
        if (j == y.len or (i < x.len and x[i] < y[j])) {
            try out.append(a, x[i]);
            i += 1;
        } else if (i == x.len or y[j] < x[i]) {
            try out.append(a, y[j]);
            j += 1;
        } else {
            try out.append(a, x[i]);
            i += 1;
            j += 1;
        }
    }
    return out.toOwnedSlice(a);
}

/// True when every key of sorted `sub` is in sorted `super`.
pub fn isSubset(sub: []const u64, super: []const u64) bool {
    var j: usize = 0;
    for (sub) |key| {
        while (j < super.len and super[j] < key) j += 1;
        if (j == super.len or super[j] != key) return false;
        j += 1;
    }
    return true;
}

/// True when a directory name should be skipped during the walk: any
/// dot-prefixed dir (`.labelle`, `.git`, `.zig-cache`, `.cache`) plus the
/// non-hidden build dirs in `watch_skip_dirs`.
fn skipWatchDir(name: []const u8) bool {
    if (name.len > 0 and name[0] == '.') return true;
    for (watch_skip_dirs) |d| {
        if (std.mem.eql(u8, name, d)) return true;
    }
    return false;
}

/// Root a project-relative declared path (a `.prebuild` `.outputs` entry)
/// the same way `computeSignature`'s walk builds its paths, so the two can
/// be compared as plain strings. `resolve` collapses a leading `./` and
/// any `..` first — pure path math, no filesystem access — so
/// `"./assets/out.png"` and `"assets/out.png"` both match the walked
/// `<watch_dir>/assets/out.png`. Caller owns the result.
pub fn watchIgnorePath(
    allocator: std.mem.Allocator,
    watch_dir: []const u8,
    rel: []const u8,
) ![]const u8 {
    const norm = try std.fs.path.resolve(allocator, &.{rel});
    defer allocator.free(norm);
    return std.fs.path.join(allocator, &.{ watch_dir, norm });
}

/// True when `dir_path` is the root of its own git checkout: a linked
/// worktree, a submodule, or a nested clone.
///
/// Same marker probe as `labelle test`'s walker (#371): test for the
/// *existence* of a `.git` entry, never its kind — `git worktree add`
/// and submodules both write `.git` as a regular FILE holding a
/// `gitdir:` pointer. `skipWatchDir`'s dot rule only catches a checkout
/// whose own folder is dot-prefixed; a copy of the project parked under
/// a plain name (`worktrees/`, `vendor/`, `branches/`) would otherwise
/// fold thousands of unrelated files into the signature and make edits
/// on another branch trigger rebuilds here.
fn isNestedCheckout(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) bool {
    const marker = std.fs.path.join(allocator, &.{ dir_path, ".git" }) catch return false;
    defer allocator.free(marker);
    std.Io.Dir.cwd().access(io, marker, .{}) catch return false;
    return true;
}

/// True when a walked file path is one of the rebuild's own declared
/// outputs and must not contribute to the signature.
fn skipWatchFile(path: []const u8, ignore_files: []const []const u8) bool {
    for (ignore_files) |ig| {
        if (std.mem.eql(u8, path, ig)) return true;
    }
    return false;
}

/// Accumulate `dir_path`'s tree signature into `sig`. Best-effort: an
/// unreadable dir/file is skipped rather than fatal (a transient rename
/// mid-scan just shows up as a change on the next poll). Recurses into
/// subdirectories except those `skipWatchDir` rejects and those that are
/// nested git checkouts (#371).
pub fn computeSignature(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    ignore_files: []const []const u8,
    sig: *TreeSignature,
) void {
    var snap: TreeSnapshot = .{ .sig = sig.* };
    walkTree(io, allocator, dir_path, ignore_files, &snap, false);
    sig.* = snap.sig;
}

/// The watched tree's `TreeSnapshot`: `computeSignature`'s walk, also
/// recording every file's `PathState` (sorted). `allocator` owns `paths`.
pub fn snapshotTree(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    ignore_files: []const []const u8,
) TreeSnapshot {
    var snap: TreeSnapshot = .{};
    walkTree(io, allocator, dir_path, ignore_files, &snap, true);
    snap.sort();
    return snap;
}

fn walkTree(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    ignore_files: []const []const u8,
    snap: *TreeSnapshot,
    per_path: bool,
) void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch return) |entry| {
        if (entry.kind == .directory) {
            if (skipWatchDir(entry.name)) continue;
            const sub = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;
            defer allocator.free(sub);
            if (isNestedCheckout(io, allocator, sub)) continue;
            walkTree(io, allocator, sub, ignore_files, snap, per_path);
        } else if (entry.kind == .file) {
            const fpath = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;
            defer allocator.free(fpath);
            if (skipWatchFile(fpath, ignore_files)) continue;
            const st = std.Io.Dir.cwd().statFile(io, fpath, .{}) catch continue;
            if (per_path) {
                snap.record(allocator, fpath, st.size, st.mtime.nanoseconds);
            } else {
                snap.sig.mix(fpath, st.size, st.mtime.nanoseconds);
            }
        }
    }
}

test "changedPaths: added, removed and changed paths, by key" {
    const a = std.testing.allocator;
    var before: TreeSnapshot = .{};
    defer before.paths.deinit(a);
    before.record(a, "keep", 1, 1);
    before.record(a, "edit", 1, 1);
    before.record(a, "gone", 1, 1);
    before.sort();
    var after: TreeSnapshot = .{};
    defer after.paths.deinit(a);
    after.record(a, "keep", 1, 1);
    after.record(a, "edit", 1, 2);
    after.record(a, "new", 1, 1);
    after.sort();
    const delta = try changedPaths(a, before.paths.items, after.paths.items);
    defer a.free(delta);
    const expected = testDelta(&.{ "edit", "gone", "new" });
    try std.testing.expectEqualSlices(u64, &expected, delta);
    try std.testing.expect(isSubset(&testDelta(&.{"edit"}), delta));
    try std.testing.expect(!isSubset(&testDelta(&.{ "edit", "keep" }), delta));
    // The snapshot's signature is the one the polls compute.
    var sig = TreeSignature{};
    sig.mix("keep", 1, 1);
    sig.mix("edit", 1, 2);
    sig.mix("new", 1, 1);
    try std.testing.expect(sig.eql(after.sig));
}

test "skipWatchDir: skips dot-dirs and build output, keeps source dirs" {
    try std.testing.expect(skipWatchDir(".labelle"));
    try std.testing.expect(skipWatchDir(".git"));
    try std.testing.expect(skipWatchDir(".zig-cache"));
    try std.testing.expect(skipWatchDir("zig-out"));
    try std.testing.expect(skipWatchDir("zig-pkg"));
    try std.testing.expect(!skipWatchDir("scenes"));
    try std.testing.expect(!skipWatchDir("prefabs"));
    try std.testing.expect(!skipWatchDir("assets"));
    try std.testing.expect(!skipWatchDir("src"));
}

test "computeSignature: changes on add, edit, and remove" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(dir_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });

    var base = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &base);
    try std.testing.expectEqual(@as(u64, 1), base.file_count);

    // Add a file → count + digest change.
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "twelve!" });
    var after_add = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &after_add);
    try std.testing.expect(!base.eql(after_add));
    try std.testing.expectEqual(@as(u64, 2), after_add.file_count);

    // Edit a file in place, changing its SIZE. Keeping the file count the
    // same, the size component of the per-file digest flips regardless of
    // mtime — deterministic on every platform (no dependency on the OS
    // giving the edited file a distinguishable mtime, which is coarse/
    // coalesced on Windows).
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "twelve!-longer" });
    var after_edit = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &after_edit);
    try std.testing.expectEqual(after_add.file_count, after_edit.file_count);
    try std.testing.expect(!after_add.eql(after_edit));

    // Remove a file → back down to one entry, different from every prior sig.
    try tmp.dir.deleteFile(io, "b.txt");
    var after_rm = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &after_rm);
    try std.testing.expectEqual(@as(u64, 1), after_rm.file_count);
    try std.testing.expect(!after_rm.eql(after_add));
}

test "TreeSignature: a same-size edit to a NON-newest file still flips the signature" {
    // Regression for the codex finding: a summed-size + single-newest-mtime
    // signature misses a same-size edit to a file that isn't the newest.
    // Two files; the second (mtime 200) is the newest. Edit the first to the
    // SAME size (10 bytes) with a new mtime that is still older than the
    // newest (150 < 200) — total size (30) and the newest mtime (200) are
    // both unchanged, so the old scheme would report "no change". The
    // per-file digest catches it.
    var before = TreeSignature{};
    before.mix("old.txt", 10, 100);
    before.mix("new.txt", 20, 200);

    var after = TreeSignature{};
    after.mix("old.txt", 10, 150); // same size, newer mtime, still not newest
    after.mix("new.txt", 20, 200);

    try std.testing.expectEqual(before.file_count, after.file_count);
    try std.testing.expect(!before.eql(after));
}

test "computeSignature: skips .labelle build-output dir (no self-trigger)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer alloc.free(dir_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "scene.zon", .data = "source" });
    var before = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &before);

    // Simulate a rebuild writing into .labelle/ — the signature must not move.
    try tmp.dir.createDirPath(io, ".labelle/raylib_wasm");
    try tmp.dir.writeFile(io, .{ .sub_path = ".labelle/raylib_wasm/out.wasm", .data = "artifact" });
    var after = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &after);
    try std.testing.expect(before.eql(after));
}

// The watch-mode double rebuild (cli#355 review round 2): a prebuild hook
// regenerates a non-hidden output, `watchLoop` records the signature it
// captured BEFORE the callback, and the next poll sees the hook's own
// write as a fresh change — a second full generate/compile/browser-reload
// for a step that is now up to date.
test "computeSignature: a declared prebuild output does not move the signature" {
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = buf[0..try tmp.dir.realPath(io, &buf)];
    const alloc = std.testing.allocator;

    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "game.zig", .data = "const a = 1;" });
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/out.png", .data = "v1" });

    const ignored = try watchIgnorePath(alloc, dir_path, "assets/out.png");
    defer alloc.free(ignored);
    const ignore_files = [_][]const u8{ignored};

    var before = TreeSignature{};
    computeSignature(io, alloc, dir_path, &ignore_files, &before);

    // The hook regenerates its declared output — a different size AND a
    // later mtime, which is what the naive signature keyed on.
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/out.png", .data = "v2-regenerated" });

    var after = TreeSignature{};
    computeSignature(io, alloc, dir_path, &ignore_files, &after);
    try std.testing.expect(before.eql(after));

    // ...while an edit to a watched SOURCE still fires.
    try tmp.dir.writeFile(io, .{ .sub_path = "game.zig", .data = "const a = 2222;" });
    var edited = TreeSignature{};
    computeSignature(io, alloc, dir_path, &ignore_files, &edited);
    try std.testing.expect(!before.eql(edited));
    // And without the exclusion the regeneration DOES move it — the bug.
    var unfiltered_before = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &unfiltered_before);
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/out.png", .data = "v3-regenerated-again" });
    var unfiltered_after = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &unfiltered_after);
    try std.testing.expect(!unfiltered_before.eql(unfiltered_after));
}

test "watchIgnorePath: roots a declared output the way the walk builds paths" {
    // POSIX-only: the expected strings spell the separator. The behavior
    // under test (a leading `./` must still match the walked path) is
    // separator-agnostic, and the tree-level test above covers it on
    // every platform.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const plain = try watchIgnorePath(alloc, "/proj", "assets/out.png");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("/proj/assets/out.png", plain);

    // A leading `./` in the declaration must still match the walked path.
    const dotted = try watchIgnorePath(alloc, "/proj", "./assets/out.png");
    defer alloc.free(dotted);
    try std.testing.expectEqualStrings("/proj/assets/out.png", dotted);
}

test "skipWatchFile: matches only the declared outputs" {
    const ignore_files = [_][]const u8{ "/proj/assets/out.png", "/proj/scripts/table.zig" };
    try std.testing.expect(skipWatchFile("/proj/assets/out.png", &ignore_files));
    try std.testing.expect(skipWatchFile("/proj/scripts/table.zig", &ignore_files));
    try std.testing.expect(!skipWatchFile("/proj/assets/out.json", &ignore_files));
    try std.testing.expect(!skipWatchFile("/proj/game.zig", &ignore_files));
    try std.testing.expect(!skipWatchFile("/proj/assets/out.png", &.{}));
}

// #371: the same nested-checkout gap `labelle test` had. `skipWatchDir`'s
// dot rule only hides a checkout whose own folder starts with a dot; a
// worktree parked under a plain name folded a whole second copy of the
// project into the signature, so edits on an unrelated branch fired
// rebuilds here. The fixtures write the `.git` markers by hand (no `git`
// invocation) so they run on the ubuntu and windows CI runners too.
test "computeSignature: nested git checkouts are pruned, ordinary dirs are not" {
    const io = config.globalIo();
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.writeFile(io, .{ .sub_path = "game.zig", .data = "const a = 1;" });

    var base = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &base);
    try std.testing.expectEqual(@as(u64, 1), base.file_count);

    // A linked worktree: `.git` is a FILE holding a `gitdir:` pointer,
    // so a kind check would miss it.
    try tmp.dir.createDirPath(io, "verify-821/libs/ui_kit");
    try tmp.dir.writeFile(io, .{ .sub_path = "verify-821/libs/ui_kit/root.zig", .data = "stale" });
    try tmp.dir.writeFile(io, .{ .sub_path = "verify-821/.git", .data = "gitdir: /somewhere\n" });

    var with_worktree = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &with_worktree);
    try std.testing.expect(base.eql(with_worktree));

    // A plain nested clone: `.git` is a DIRECTORY. Pruned too.
    try tmp.dir.createDirPath(io, "vendor/other/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor/other/main.zig", .data = "stale" });

    var with_clone = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &with_clone);
    try std.testing.expect(base.eql(with_clone));

    // ...but an ordinary directory that merely *looks* like a worktree
    // parent still counts: the prune keys on the marker, not the name.
    try tmp.dir.createDirPath(io, "worktrees");
    try tmp.dir.writeFile(io, .{ .sub_path = "worktrees/helper.zig", .data = "real source" });

    var with_plain_dir = TreeSignature{};
    computeSignature(io, alloc, dir_path, &.{}, &with_plain_dir);
    try std.testing.expect(!base.eql(with_plain_dir));
    try std.testing.expectEqual(@as(u64, 2), with_plain_dir.file_count);
}

test "isNestedCheckout: keys on the .git marker's existence, not its kind" {
    const io = config.globalIo();
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];

    try tmp.dir.createDirPath(io, "wt");
    try tmp.dir.writeFile(io, .{ .sub_path = "wt/.git", .data = "gitdir: /elsewhere\n" });
    try tmp.dir.createDirPath(io, "clone/.git");
    try tmp.dir.createDirPath(io, "plain/src");

    for ([_]struct { name: []const u8, want: bool }{
        .{ .name = "wt", .want = true },
        .{ .name = "clone", .want = true },
        .{ .name = "plain", .want = false },
    }) |case| {
        const p = try std.fs.path.join(alloc, &.{ root, case.name });
        defer alloc.free(p);
        try std.testing.expectEqual(case.want, isNestedCheckout(io, alloc, p));
    }
}
