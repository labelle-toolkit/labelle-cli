//! Concurrency-safe publication into the shared labelle cache.
//!
//! `LABELLE_HOME` (default `~/.labelle`) is shared by every labelle process on
//! the machine — and on a CI shell runner, by every CONCURRENT JOB. A download
//! that writes through a fixed path (`<dest>.part`, `<ver_dir>/astcenc.zip`,
//! the version directory itself) lets two processes clobber each other: a
//! Flying Platform pipeline ran two jobs that fetched assembler v0.126.0 into
//! the same `.part`; one renamed it into place and the other failed with
//! "could not read the download to verify it" → `AssemblerNotCached`.
//!
//! Every cache writer follows the same rules:
//!
//!   1. Stage on a UNIQUE sibling of the final path (`tempSibling`). Same
//!      directory → same filesystem → the publishing rename is atomic. The
//!      name carries the pid and 64 random bits, so neither two processes nor
//!      two threads of one process can pick the same staging path.
//!   2. Verify the STAGED bytes/tree, never the final path.
//!   3. Publish with one rename (`publishFile` / `publishDir`). If the final
//!      path already holds a valid install when we finish — a concurrent
//!      process won the race — keep theirs and discard ours.
//!   4. Remove the staging path on every exit. Nothing partial is ever visible
//!      at the final path, so "exists" keeps meaning "complete and verified"
//!      for every reader that only checks existence.
//!
//! `InstallLock` additionally serializes installs of ONE item across processes
//! so only one of them downloads (the others wait, then find it published).
//! For a single file it is only an optimisation — rules 1–4 are the safety
//! baseline. For a directory it also makes replacing a broken leftover tree
//! safe (see `publishDir`).
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const util = @import("util.zig");

/// The current process id (0 where the platform offers none). Only used to
/// make staging names readable and unique across processes; the random part
/// keeps them unique across threads of one process.
pub fn processId() u64 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .linux => @intCast(std.os.linux.getpid()),
        else => if (builtin.link_libc) @intCast(std.c.getpid()) else 0,
    };
}

/// `<dest>.<tag>-<pid>-<16 hex>` — a unique sibling of `dest` (same directory,
/// so a rename from it onto `dest` is atomic). `tag` is `tmp` for staging and
/// `stale` for a broken tree moved aside. Caller owns the slice.
pub fn tempSibling(a: std.mem.Allocator, dest: []const u8, tag: []const u8) ![]u8 {
    var random: [8]u8 = undefined;
    config.globalIo().random(&random);
    return std.fmt.allocPrint(a, "{s}.{s}-{d}-{s}", .{
        std.mem.trimEnd(u8, dest, "/\\"),
        tag,
        processId(),
        std.fmt.bytesToHex(random, .lower),
    });
}

/// True if `name` (a bare file name) is a staging/stale sibling of `base`
/// made by `tempSibling`. Tests use it to assert nothing was left behind.
pub fn isSiblingName(name: []const u8, base: []const u8) bool {
    if (!std.mem.startsWith(u8, name, base) or name.len == base.len) return false;
    const rest = name[base.len..];
    return std.mem.startsWith(u8, rest, ".tmp-") or std.mem.startsWith(u8, rest, ".stale-");
}

/// An exclusive advisory lock on `<dest>.lock`, held across a download +
/// verify + publish so concurrent labelle processes install one item once.
/// Blocking; the OS releases it if the holder dies. The lock file itself is
/// empty and harmless, and is left in place (deleting it would race a waiter
/// that already opened it).
pub const InstallLock = struct {
    file: std.Io.File,

    pub fn acquire(a: std.mem.Allocator, dest: []const u8) !InstallLock {
        const io = config.globalIo();
        const cwd = std.Io.Dir.cwd();
        const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{std.mem.trimEnd(u8, dest, "/\\")});
        defer a.free(lock_path);
        if (std.fs.path.dirname(lock_path)) |dir| try cwd.createDirPath(io, dir);
        const file = cwd.createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive }) catch |err| {
            std.debug.print("labelle: could not acquire install lock {s}: {s}\n", .{ lock_path, @errorName(err) });
            return err;
        };
        return .{ .file = file };
    }

    pub fn release(self: *InstallLock) void {
        self.file.close(config.globalIo());
    }
};

pub const Outcome = enum {
    /// Our staged copy is now at the final path.
    published,
    /// The final path already held a valid install (a concurrent process won
    /// the race); ours was discarded.
    kept_existing,
};

/// A validator that accepts any existing path. For callers whose final path
/// is only ever produced by a verified publish (so existence implies valid).
pub const Exists = struct {
    pub fn valid(_: Exists, path: []const u8) bool {
        return util.fileExists(path);
    }
};

/// A validator for a published FILE: it exists and, when `sha256` (lowercase
/// hex) is given, its bytes hash to it.
pub const Sha256File = struct {
    sha256: ?[]const u8,
    max_bytes: usize = 512 << 20,

    pub fn valid(self: Sha256File, path: []const u8) bool {
        const expected = self.sha256 orelse return util.fileExists(path);
        const data = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, std.heap.page_allocator, .limited(self.max_bytes)) catch return false;
        defer std.heap.page_allocator.free(data);
        return util.sha256Matches(data, expected);
    }
};

/// Move the verified file `staged` to `dest` with one atomic rename (replacing
/// a damaged `dest`). If `dest` already validates — before we start, or after a
/// rename that failed because a concurrent process holds it (Windows cannot
/// replace a running executable) — ours is discarded and theirs is used.
/// `staged` never survives this call.
pub fn publishFile(staged: []const u8, dest: []const u8, validator: anytype) !Outcome {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    if (util.fileExists(dest) and validator.valid(dest)) {
        cwd.deleteFile(io, staged) catch {};
        return .kept_existing;
    }
    cwd.rename(staged, cwd, dest, io) catch |err| {
        cwd.deleteFile(io, staged) catch {};
        if (validator.valid(dest)) return .kept_existing;
        return err;
    };
    return .published;
}

/// Move the verified directory `staged` to `dest` with one atomic rename. If
/// `dest` already validates, ours is deleted and theirs is used. If `dest`
/// exists but does NOT validate (a partial tree left by a crash, or by an
/// older CLI that extracted in place), it is moved aside in one rename, ours
/// takes its place, and the old tree is deleted — so at no point is a mix of
/// the two visible at `dest`. Callers hold the item's `InstallLock` so no
/// other labelle process replaces `dest` at the same time. `staged` never
/// survives this call.
pub fn publishDir(a: std.mem.Allocator, staged: []const u8, dest: []const u8, validator: anytype) !Outcome {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteTree(io, staged) catch {};
    if (validator.valid(dest)) return .kept_existing;
    cwd.rename(staged, cwd, dest, io) catch |first_err| {
        if (validator.valid(dest)) return .kept_existing;
        if (!util.fileExists(dest)) return first_err;
        const stale = try tempSibling(a, dest, "stale");
        defer a.free(stale);
        cwd.rename(dest, cwd, stale, io) catch |err| {
            if (validator.valid(dest)) return .kept_existing;
            return err;
        };
        defer cwd.deleteTree(io, stale) catch {};
        cwd.rename(staged, cwd, dest, io) catch |err| {
            if (validator.valid(dest)) return .kept_existing;
            return err;
        };
        return .published;
    };
    return .published;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn testRoot(tmp: *std.testing.TmpDir) ![:0]u8 {
    return tmp.dir.realPathFileAlloc(config.globalIo(), ".", testing.allocator);
}

/// Names in `dir` that are staging/stale siblings of `base`.
fn countSiblings(dir_path: []const u8, base: []const u8) !usize {
    const io = config.globalIo();
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |e| {
        if (isSiblingName(e.name, base)) n += 1;
    }
    return n;
}

test "tempSibling: same directory, tagged, pid-stamped and unique per call" {
    const a = testing.allocator;
    const dest = try std.fs.path.join(a, &.{ "cache", "assembler", "1.2.3", "labelle-assembler" });
    defer a.free(dest);
    const one = try tempSibling(a, dest, "tmp");
    defer a.free(one);
    const two = try tempSibling(a, dest, "tmp");
    defer a.free(two);

    try testing.expect(!std.mem.eql(u8, one, two));
    try testing.expectEqualStrings(std.fs.path.dirname(dest).?, std.fs.path.dirname(one).?);
    try testing.expect(std.mem.startsWith(u8, one, dest));
    const pid = try std.fmt.allocPrint(a, ".tmp-{d}-", .{processId()});
    defer a.free(pid);
    try testing.expect(std.mem.indexOf(u8, one, pid) != null);
    try testing.expect(isSiblingName(std.fs.path.basename(one), "labelle-assembler"));
    try testing.expect(!isSiblingName("labelle-assembler", "labelle-assembler"));
    try testing.expect(!isSiblingName("labelle-assembler.lock", "labelle-assembler"));

    // A trailing separator on a directory destination does not leak in.
    const dir_dest = try std.fmt.allocPrint(a, "{s}{c}", .{ std.fs.path.dirname(dest).?, std.fs.path.sep });
    defer a.free(dir_dest);
    const staged_dir = try tempSibling(a, dir_dest, "stale");
    defer a.free(staged_dir);
    try testing.expect(isSiblingName(std.fs.path.basename(staged_dir), "1.2.3"));
}

test "publishFile: publishes, keeps a valid existing file, replaces a damaged one" {
    const a = testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    const dest = try std.fs.path.join(a, &.{ root, "item" });
    defer a.free(dest);
    const good = "good bytes";
    const good_sha = try @import("provider_github/files.zig").sha256Hex(a, good);
    defer a.free(good_sha);
    const v: Sha256File = .{ .sha256 = good_sha };

    // Absent → published.
    const s1 = try tempSibling(a, dest, "tmp");
    defer a.free(s1);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = s1, .data = good });
    try testing.expectEqual(Outcome.published, try publishFile(s1, dest, v));
    try testing.expect(v.valid(dest));

    // Valid existing → ours discarded, theirs kept.
    const s2 = try tempSibling(a, dest, "tmp");
    defer a.free(s2);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = s2, .data = good });
    try testing.expectEqual(Outcome.kept_existing, try publishFile(s2, dest, v));
    try testing.expect(!util.fileExists(s2));

    // Damaged existing → replaced in one rename.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = "trunc" });
    const s3 = try tempSibling(a, dest, "tmp");
    defer a.free(s3);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = s3, .data = good });
    try testing.expectEqual(Outcome.published, try publishFile(s3, dest, v));
    try testing.expect(v.valid(dest));
    try testing.expectEqual(@as(usize, 0), try countSiblings(root, "item"));
}

test "publishDir: publishes, keeps a valid tree, replaces a partial leftover" {
    const a = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    const dest = try std.fs.path.join(a, &.{ root, "5.5.0" });
    defer a.free(dest);
    const marker = try std.fs.path.join(a, &.{ dest, "bin", "tool" });
    defer a.free(marker);
    const HasTool = struct {
        pub fn valid(_: @This(), dir: []const u8) bool {
            var buf: [1024]u8 = undefined;
            const p = std.fmt.bufPrint(&buf, "{s}{c}bin{c}tool", .{ dir, std.fs.path.sep, std.fs.path.sep }) catch return false;
            return util.fileExists(p);
        }
    };

    const stage = struct {
        fn make(alloc: std.mem.Allocator, d: []const u8, content: []const u8) ![]u8 {
            const s = try tempSibling(alloc, d, "tmp");
            const bin = try std.fs.path.join(alloc, &.{ s, "bin" });
            defer alloc.free(bin);
            try std.Io.Dir.cwd().createDirPath(config.globalIo(), bin);
            const f = try std.fs.path.join(alloc, &.{ bin, "tool" });
            defer alloc.free(f);
            try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = f, .data = content });
            return s;
        }
    }.make;

    const s1 = try stage(a, dest, "first");
    defer a.free(s1);
    try testing.expectEqual(Outcome.published, try publishDir(a, s1, dest, HasTool{}));
    try testing.expect(!util.fileExists(s1));

    const s2 = try stage(a, dest, "second");
    defer a.free(s2);
    try testing.expectEqual(Outcome.kept_existing, try publishDir(a, s2, dest, HasTool{}));
    try testing.expect(!util.fileExists(s2));
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("first", try cwd.readFile(io, marker, &buf));

    // A partial tree (no bin/tool) — what the old in-place extract left on a
    // crash — is replaced wholesale.
    try cwd.deleteTree(io, dest);
    const junk = try std.fs.path.join(a, &.{ dest, "half-extracted" });
    defer a.free(junk);
    try cwd.createDirPath(io, dest);
    try cwd.writeFile(io, .{ .sub_path = junk, .data = "x" });
    const s3 = try stage(a, dest, "third");
    defer a.free(s3);
    try testing.expectEqual(Outcome.published, try publishDir(a, s3, dest, HasTool{}));
    try testing.expectEqualStrings("third", try cwd.readFile(io, marker, &buf));
    try testing.expect(!util.fileExists(junk));
    try testing.expectEqual(@as(usize, 0), try countSiblings(root, "5.5.0"));
}

const RaceCtx = struct {
    dest: []const u8,
    payload: []const u8,
    sha: []const u8,
    dir_mode: bool,
    failed: std.atomic.Value(u32) = .init(0),

    fn run(ctx: *RaceCtx) void {
        ctx.once() catch |err| {
            std.debug.print("race worker failed: {s}\n", .{@errorName(err)});
            _ = ctx.failed.fetchAdd(1, .monotonic);
        };
    }

    fn once(ctx: *RaceCtx) !void {
        const a = std.heap.page_allocator;
        const io = config.globalIo();
        const cwd = std.Io.Dir.cwd();
        const staged = try tempSibling(a, ctx.dest, "tmp");
        defer a.free(staged);
        if (!ctx.dir_mode) {
            // Unlocked on purpose: atomic staging alone must be safe for files.
            try cwd.writeFile(io, .{ .sub_path = staged, .data = ctx.payload });
            _ = try publishFile(staged, ctx.dest, Sha256File{ .sha256 = ctx.sha });
            return;
        }
        var lock = try InstallLock.acquire(a, ctx.dest);
        defer lock.release();
        const f = try std.fs.path.join(a, &.{ staged, "payload" });
        defer a.free(f);
        try cwd.createDirPath(io, staged);
        try cwd.writeFile(io, .{ .sub_path = f, .data = ctx.payload });
        _ = try publishDir(a, staged, ctx.dest, DirPayload{ .sha = ctx.sha });
    }
};

const DirPayload = struct {
    sha: []const u8,
    pub fn valid(self: DirPayload, dir: []const u8) bool {
        const p = std.fs.path.join(std.heap.page_allocator, &.{ dir, "payload" }) catch return false;
        defer std.heap.page_allocator.free(p);
        return util.fileExists(p) and (Sha256File{ .sha256 = self.sha }).valid(p);
    }
};

fn raceTest(dir_mode: bool) !void {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try testRoot(&tmp);
    defer a.free(root);
    const dest = try std.fs.path.join(a, &.{ root, "shared" });
    defer a.free(dest);
    // Big enough that unsynchronized writers would interleave.
    const payload = try a.alloc(u8, 4 << 20);
    defer a.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i *% 131);
    const sha = try @import("provider_github/files.zig").sha256Hex(a, payload);
    defer a.free(sha);

    var ctx: RaceCtx = .{ .dest = dest, .payload = payload, .sha = sha, .dir_mode = dir_mode };
    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, RaceCtx.run, .{&ctx});
    for (threads) |t| t.join();

    try testing.expectEqual(@as(u32, 0), ctx.failed.load(.monotonic));
    if (dir_mode) {
        try testing.expect((DirPayload{ .sha = sha }).valid(dest));
    } else {
        try testing.expect((Sha256File{ .sha256 = sha }).valid(dest));
    }
    try testing.expectEqual(@as(usize, 0), try countSiblings(root, "shared"));
}

test "publishFile: 8 concurrent unlocked publishers all succeed and the file verifies" {
    try raceTest(false);
}

test "publishDir: 8 concurrent locked publishers all succeed and the tree verifies" {
    try raceTest(true);
}
