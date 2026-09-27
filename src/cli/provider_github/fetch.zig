//! `labelle providers fetch`: materialise exactly the archives the project's
//! integrity lock pins, so a fresh checkout (a CI runner, a new clone, an
//! emptied cache) can run normal commands, which never download (contract §4).
//!
//! It reads `labelle.providers.lock` and nothing else: no registry, no
//! `project.labelle`, no preview. Each pin's archive comes from the one URL
//! the pin determines (`https://codeload.github.com/<repo>/tar.gz/<commit>`)
//! and is kept only if its bytes hash to the pinned sha256. It never writes
//! the lock, never extracts an archive and never runs package code.
//!
//! Per-archive atomic, verified-only: only bytes that hash to the lock's
//! sha256 ever reach the cache, and each archive lands there by one rename
//! of a verified temporary file, so a cached archive is never partial or
//! unverified. Every needed archive is downloaded and verified before the
//! first rename, so a failed download or a hash mismatch names the package
//! and adds nothing to the cache. A failed rename can leave the set partly
//! fetched; that is harmless (every cached archive verifies) and the next
//! run fetches the rest. An archive that is already cached and verifies is
//! left alone, so a second run is a no-op; a cached archive that does not
//! verify is replaced by the verified bytes.
const std = @import("std");
const config = @import("../config.zig");
const util = @import("../util.zig");
const pin_mod = @import("pin.zig");
const Pin = pin_mod.Pin;
const Document = pin_mod.Document;
const lock_name = pin_mod.lock_name;
const files = @import("files.zig");
const read = files.read;
const uniqueName = files.uniqueName;
const archive_mod = @import("archive.zig");
const archivePath = archive_mod.archivePath;
const cache = @import("../asm_cache.zig");

/// The compressed-archive bound every archive read already uses.
const max_archive_size = archive_mod.max_archive_size;

pub const Action = enum {
    /// Cached and its bytes hash to the pin: nothing to do.
    cached,
    /// Not cached: download it.
    download,
    /// Cached, but the bytes do not hash to the pin: download the pinned
    /// bytes over it (only once they verify).
    replace,
};

pub const Step = struct { pin: Pin, path: []const u8, action: Action };

/// Downloads `url` to `dest`. The CLI's is `archive.download` (curl, https
/// only); tests substitute a local one so nothing reaches the network.
pub const Downloader = *const fn (a: std.mem.Allocator, url: []const u8, dest: []const u8) anyerror!void;

fn curlDownload(a: std.mem.Allocator, url: []const u8, dest: []const u8) anyerror!void {
    return archive_mod.download(a, url, dest, max_archive_size);
}

pub const default_downloader: Downloader = curlDownload;

/// What each pin needs: reads (and hashes) every cached archive, changes nothing.
pub fn plan(a: std.mem.Allocator, pins: []const Pin) ![]Step {
    const steps = try a.alloc(Step, pins.len);
    for (pins, steps) |pin, *step| {
        const path = try archivePath(a, pin);
        // A scratch arena per archive (up to 128 MiB each), freed per pin:
        // the caller's arena would keep every archive read alive.
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const action: Action = if (read(scratch.allocator(), path, archive_mod.cache_read_limit)) |bytes|
            (if (util.sha256Matches(bytes, pin.sha256)) .cached else .replace)
        else |err| switch (err) {
            error.FileNotFound => .download,
            // Larger than any archive we accept: not the pinned bytes.
            error.StreamTooLong => .replace,
            else => return err,
        };
        step.* = .{ .pin = pin, .path = path, .action = action };
    }
    return steps;
}

pub const Summary = struct {
    /// Pins in the lock (0 when the project has none).
    pinned: usize = 0,
    /// Archives downloaded, verified and cached by this run.
    fetched: usize = 0,
    /// Archives that were already cached and verified.
    cached: usize = 0,
    /// Whether the project has a providers lock at all.
    has_lock: bool = false,
};

/// Fetch every archive `root`'s providers lock pins that is not cached and
/// valid. `offline` downloads nothing: it only verifies the cache and fails
/// (`ProviderArchiveMissing` / `ProviderArchiveHashMismatch`) naming every
/// package whose archive is absent or damaged. A project without a lock has
/// nothing to fetch.
pub fn fetch(a: std.mem.Allocator, root: []const u8, offline: bool, download: Downloader) !Summary {
    const bytes = read(a, try std.fs.path.join(a, &.{ root, lock_name }), 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const doc = try pin_mod.parse(a, bytes, true);
    const steps = try plan(a, doc.providers);
    var summary: Summary = .{ .pinned = steps.len, .has_lock = true };
    var missing = false;
    var damaged = false;
    for (steps) |step| switch (step.action) {
        .cached => summary.cached += 1,
        .download => missing = true,
        .replace => damaged = true,
    };
    if (offline) {
        for (steps) |step| switch (step.action) {
            .cached => {},
            .download => std.debug.print("labelle: provider '{s}' {s}: archive {s} is not cached, and --offline downloads nothing\n", .{ step.pin.package, step.pin.version, step.pin.sha256 }),
            .replace => std.debug.print("labelle: provider '{s}' {s}: the cached archive does not match its pinned sha256 {s}, and --offline downloads nothing\n", .{ step.pin.package, step.pin.version, step.pin.sha256 }),
        };
        if (missing) return error.ProviderArchiveMissing;
        if (damaged) return error.ProviderArchiveHashMismatch;
        return summary;
    }
    if (!missing and !damaged) return summary;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    var temps: std.ArrayList(struct { tmp: []const u8, path: []const u8, pin: Pin }) = .empty;
    // Until the renames below, every temporary file is removed on any exit:
    // a failed download or verification adds nothing to the cache.
    var committed = false;
    defer if (!committed) for (temps.items) |t| cwd.deleteFile(io, t.tmp) catch {};
    for (steps) |step| {
        if (step.action == .cached) continue;
        try cwd.createDirPath(io, std.fs.path.dirname(step.path).?);
        const tmp = try uniqueName(a, step.path);
        try temps.append(a, .{ .tmp = tmp, .path = step.path, .pin = step.pin });
        const url = try step.pin.archiveUrl(a);
        std.debug.print("  fetching {s} {s}: {s}\n", .{ step.pin.package, step.pin.version, url });
        download(a, url, tmp) catch |err| {
            std.debug.print("labelle: provider '{s}' {s}: download of {s} failed ({s}); nothing was cached\n", .{ step.pin.package, step.pin.version, url, @errorName(err) });
            return err;
        };
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const downloaded = read(scratch.allocator(), tmp, max_archive_size) catch |err| {
            std.debug.print("labelle: provider '{s}' {s}: the download of {s} is unreadable ({s}); nothing was cached\n", .{ step.pin.package, step.pin.version, url, @errorName(err) });
            return err;
        };
        if (!util.sha256Matches(downloaded, step.pin.sha256)) {
            const got = try files.sha256Hex(scratch.allocator(), downloaded);
            std.debug.print("labelle: provider '{s}' {s}: {s} served sha256 {s}, but {s} pins {s}; nothing was cached. The lock is not changed: a pinned commit must keep its archive bytes.\n", .{ step.pin.package, step.pin.version, url, got, lock_name, step.pin.sha256 });
            return error.ProviderArchiveHashMismatch;
        }
    }
    // Every archive verified: commit each by one rename (which also replaces
    // a damaged cached archive in one step). A failed rename stops here with
    // the earlier archives cached: each of them verified, so nothing is rolled
    // back, and the temporaries not yet renamed are removed.
    committed = true;
    for (temps.items) |t| {
        std.Io.Dir.renameAbsolute(t.tmp, t.path, io) catch |err| {
            std.debug.print("labelle: provider '{s}' {s}: the verified archive could not be moved into the cache at {s} ({s}); the {d} archive(s) cached before it are verified and kept. Run `labelle providers fetch` again.\n", .{ t.pin.package, t.pin.version, t.path, @errorName(err), summary.fetched });
            for (temps.items) |left| cwd.deleteFile(io, left.tmp) catch {};
            return err;
        };
        summary.fetched += 1;
    }
    return summary;
}

/// `labelle providers fetch`, and the step `labelle install` runs for a
/// project with a providers lock: `fetch` with the real downloader and a
/// one-line report. `report_no_lock` is false for `install`, which only
/// fetches when the project has a lock. Returns whether a lock was found.
pub fn fetchCommand(a: std.mem.Allocator, root: []const u8, offline: bool, report_no_lock: bool) !bool {
    const summary = try fetch(a, root, offline, default_downloader);
    if (!summary.has_lock) {
        if (report_no_lock) std.debug.print("No {s} in {s}: no provider archives to fetch.\n", .{ lock_name, root });
    } else if (offline) {
        std.debug.print("Verified {d} cached provider archive(s) pinned in {s}.\n", .{ summary.cached, lock_name });
    } else {
        std.debug.print("Provider archives pinned in {s}: {d} fetched, {d} already cached and verified.\n", .{ lock_name, summary.fetched, summary.cached });
    }
    return summary.has_lock;
}

// ── Tests ────────────────────────────────────────────────────────────

const Served = struct {
    /// URL -> bytes the fake codeload serves; a URL not listed fails like a 404.
    var urls: std.StringHashMapUnmanaged([]const u8) = .empty;
    var requests: usize = 0;

    fn download(a: std.mem.Allocator, url: []const u8, dest: []const u8) anyerror!void {
        _ = a;
        requests += 1;
        const bytes = urls.get(url) orelse return error.ProviderDownloadFailed;
        try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = dest, .data = bytes });
    }

    fn reset() void {
        urls = .empty;
        requests = 0;
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    home: []const u8,

    fn init(a: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const base = try a.dupe(u8, buf[0..try tmp.dir.realPath(config.globalIo(), &buf)]);
        try tmp.dir.createDirPath(config.globalIo(), "project");
        const self: Fixture = .{ .tmp = tmp, .root = try std.fs.path.join(a, &.{ base, "project" }), .home = try std.fs.path.join(a, &.{ base, "home" }) };
        cache.setCacheRootOverride(self.home);
        Served.reset();
        return self;
    }

    fn deinit(self: *Fixture) void {
        cache.clearCacheRootOverride();
        Served.reset();
        self.tmp.cleanup();
    }

    /// A pin over `bytes`, served by the fake codeload at its archive URL.
    fn pin(a: std.mem.Allocator, package: []const u8, commit_digit: u8, bytes: []const u8) !Pin {
        return .{ .package = package, .repo = try std.fmt.allocPrint(a, "example/{s}", .{package}), .version = "1.0.0", .commit = try a.dupe(u8, &([_]u8{commit_digit} ** 40)), .sha256 = try files.sha256Hex(a, bytes) };
    }

    fn serve(a: std.mem.Allocator, p: Pin, bytes: []const u8) !void {
        try Served.urls.put(a, try p.archiveUrl(a), bytes);
    }

    fn writeLock(self: *Fixture, a: std.mem.Allocator, pins: []const Pin) ![]const u8 {
        const bytes = try std.json.Stringify.valueAlloc(a, Document{ .schema_version = 1, .providers = pins }, .{ .whitespace = .indent_2 });
        try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = try std.fs.path.join(a, &.{ self.root, lock_name }), .data = bytes });
        return bytes;
    }

    fn seed(a: std.mem.Allocator, p: Pin, bytes: []const u8) !void {
        const path = try archivePath(a, p);
        try std.Io.Dir.cwd().createDirPath(config.globalIo(), std.fs.path.dirname(path).?);
        try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = path, .data = bytes });
    }

    fn cachedBytes(a: std.mem.Allocator, p: Pin) !?[]u8 {
        return read(a, try archivePath(a, p), max_archive_size) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    /// Every file in the archive cache directory (temporaries included).
    fn cacheEntries(self: *Fixture, a: std.mem.Allocator) !usize {
        var dir = std.Io.Dir.cwd().openDir(config.globalIo(), try std.fs.path.join(a, &.{ self.home, "provider-archives" }), .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer dir.close(config.globalIo());
        var it = dir.iterate();
        var count: usize = 0;
        while (try it.next(config.globalIo())) |_| count += 1;
        return count;
    }
};

test "provider fetch: the plan downloads what is missing, replaces what is damaged, skips what verifies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const valid = try Fixture.pin(a, "valid", '1', "valid bytes");
    const absent = try Fixture.pin(a, "absent", '2', "absent bytes");
    const damaged = try Fixture.pin(a, "damaged", '3', "damaged bytes");
    try Fixture.seed(a, valid, "valid bytes");
    try Fixture.seed(a, damaged, "damaged bytes, tampered");
    const steps = try plan(a, &.{ valid, absent, damaged });
    try std.testing.expectEqual(@as(usize, 3), steps.len);
    try std.testing.expectEqual(Action.cached, steps[0].action);
    try std.testing.expectEqual(Action.download, steps[1].action);
    try std.testing.expectEqual(Action.replace, steps[2].action);
    // The plan reads only: nothing was added to or removed from the cache.
    try std.testing.expectEqual(@as(usize, 2), try fx.cacheEntries(a));
    try std.testing.expectEqualStrings(try archivePath(a, absent), steps[1].path);
}

test "provider fetch: materialises exactly the lock, from codeload URLs, and a second run is a no-op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const one = try Fixture.pin(a, "one", '1', "one bytes");
    const two = try Fixture.pin(a, "two", '2', "two bytes");
    const unlisted = try Fixture.pin(a, "unlisted", '3', "unlisted bytes");
    try Fixture.serve(a, one, "one bytes");
    try Fixture.serve(a, two, "two bytes");
    try Fixture.serve(a, unlisted, "unlisted bytes");
    const lock = try fx.writeLock(a, &.{ one, two });
    const first = try fetch(a, fx.root, false, Served.download);
    try std.testing.expectEqual(@as(usize, 2), first.fetched);
    try std.testing.expectEqual(@as(usize, 0), first.cached);
    try std.testing.expectEqual(@as(usize, 2), Served.requests);
    try std.testing.expectEqualStrings("one bytes", (try Fixture.cachedBytes(a, one)).?);
    try std.testing.expectEqualStrings("two bytes", (try Fixture.cachedBytes(a, two)).?);
    // Only the lock's pins: a release the lock does not name is never fetched.
    try std.testing.expect(try Fixture.cachedBytes(a, unlisted) == null);
    try std.testing.expectEqual(@as(usize, 2), try fx.cacheEntries(a));
    // Idempotent: everything verifies, so nothing is requested.
    const second = try fetch(a, fx.root, false, Served.download);
    try std.testing.expectEqual(@as(usize, 0), second.fetched);
    try std.testing.expectEqual(@as(usize, 2), second.cached);
    try std.testing.expectEqual(@as(usize, 2), Served.requests);
    // The lock is read, never written.
    try std.testing.expectEqualStrings(lock, try read(a, try std.fs.path.join(a, &.{ fx.root, lock_name }), 1024 * 1024));
    // Offline verifies the complete cache without a request.
    _ = try fetch(a, fx.root, true, Served.download);
    try std.testing.expectEqual(@as(usize, 2), Served.requests);
}

test "provider fetch: a hash mismatch fails closed, names the package and caches nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const good = try Fixture.pin(a, "good", '1', "good bytes");
    const bad = try Fixture.pin(a, "bad", '2', "bad bytes");
    try Fixture.serve(a, good, "good bytes");
    try Fixture.serve(a, bad, "bad bytes, but different");
    const lock = try fx.writeLock(a, &.{ good, bad });
    try std.testing.expectError(error.ProviderArchiveHashMismatch, fetch(a, fx.root, false, Served.download));
    // Both were requested, and neither is cached: not even the one that verified.
    try std.testing.expectEqual(@as(usize, 2), Served.requests);
    try std.testing.expect(try Fixture.cachedBytes(a, good) == null);
    try std.testing.expect(try Fixture.cachedBytes(a, bad) == null);
    try std.testing.expectEqual(@as(usize, 0), try fx.cacheEntries(a));
    try std.testing.expectEqualStrings(lock, try read(a, try std.fs.path.join(a, &.{ fx.root, lock_name }), 1024 * 1024));
    // A failed download is the same: nothing cached, the error kept.
    Served.reset();
    try Fixture.serve(a, good, "good bytes");
    try std.testing.expectError(error.ProviderDownloadFailed, fetch(a, fx.root, false, Served.download));
    try std.testing.expectEqual(@as(usize, 0), try fx.cacheEntries(a));
    // A damaged cached archive is kept until verified bytes replace it.
    Served.reset();
    try Fixture.serve(a, good, "good bytes");
    try Fixture.serve(a, bad, "bad bytes");
    try Fixture.seed(a, good, "good bytes");
    try Fixture.seed(a, bad, "damaged");
    try std.testing.expectError(error.ProviderArchiveHashMismatch, fetch(a, fx.root, true, Served.download));
    try std.testing.expectEqual(@as(usize, 0), Served.requests);
    try std.testing.expectEqualStrings("damaged", (try Fixture.cachedBytes(a, bad)).?);
    const repaired = try fetch(a, fx.root, false, Served.download);
    try std.testing.expectEqual(@as(usize, 1), repaired.fetched);
    try std.testing.expectEqual(@as(usize, 1), repaired.cached);
    try std.testing.expectEqual(@as(usize, 1), Served.requests);
    try std.testing.expectEqualStrings("bad bytes", (try Fixture.cachedBytes(a, bad)).?);
    try std.testing.expectEqual(@as(usize, 2), try fx.cacheEntries(a));
}

test "provider fetch: offline only verifies, and a project without a lock has nothing to fetch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const none = try fetch(a, fx.root, false, Served.download);
    try std.testing.expect(!none.has_lock);
    try std.testing.expectEqual(@as(usize, 0), Served.requests);
    const one = try Fixture.pin(a, "one", '1', "one bytes");
    try Fixture.serve(a, one, "one bytes");
    _ = try fx.writeLock(a, &.{one});
    try std.testing.expectError(error.ProviderArchiveMissing, fetch(a, fx.root, true, Served.download));
    try std.testing.expectEqual(@as(usize, 0), Served.requests);
    try std.testing.expectEqual(@as(usize, 0), try fx.cacheEntries(a));
    _ = try fetch(a, fx.root, false, Served.download);
    const verified = try fetch(a, fx.root, true, Served.download);
    try std.testing.expectEqual(@as(usize, 1), verified.cached);
    try std.testing.expectEqual(@as(usize, 1), Served.requests);
}

const Blocked = struct {
    /// The archive path `download` turns into a non-empty directory, so its
    /// commit rename fails after every archive verified.
    var path: ?[]const u8 = null;

    fn download(a: std.mem.Allocator, url: []const u8, dest: []const u8) anyerror!void {
        try Served.download(a, url, dest);
        if (path) |blocked| {
            const io = config.globalIo();
            try std.Io.Dir.cwd().createDirPath(io, blocked);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ blocked, "occupied" }), .data = "" });
        }
    }
};

test "provider fetch: a failed commit keeps only verified archives, each whole, and no temporaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.init(a);
    defer fx.deinit();
    defer Blocked.path = null;
    const first = try Fixture.pin(a, "first", '1', "first bytes");
    const second = try Fixture.pin(a, "second", '2', "second bytes");
    try Fixture.serve(a, first, "first bytes");
    try Fixture.serve(a, second, "second bytes");
    const lock = try fx.writeLock(a, &.{ first, second });
    Blocked.path = try archivePath(a, second);
    // Both downloads verify; the second rename then fails on the directory.
    if (fetch(a, fx.root, false, Blocked.download)) |_| return error.TestExpectedError else |_| {}
    try std.testing.expectEqual(@as(usize, 2), Served.requests);
    // The first archive is cached whole and verified; nothing else is in the
    // cache (the blocking directory aside): no temporary survived.
    const kept = (try Fixture.cachedBytes(a, first)).?;
    try std.testing.expect(util.sha256Matches(kept, first.sha256));
    try std.testing.expectEqual(@as(usize, 2), try fx.cacheEntries(a));
    try std.testing.expectEqualStrings(lock, try read(a, try std.fs.path.join(a, &.{ fx.root, lock_name }), 1024 * 1024));
    // Once the obstruction is gone the next run fetches only the rest.
    try std.Io.Dir.cwd().deleteTree(config.globalIo(), Blocked.path.?);
    Blocked.path = null;
    const rest = try fetch(a, fx.root, false, Served.download);
    try std.testing.expectEqual(@as(usize, 1), rest.fetched);
    try std.testing.expectEqual(@as(usize, 1), rest.cached);
    try std.testing.expectEqualStrings("second bytes", (try Fixture.cachedBytes(a, second)).?);
}

test "provider fetch: a cached archive over the size bound is damaged, like a hash mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.init(a);
    defer fx.deinit();
    const big = try Fixture.pin(a, "big", '1', "sixteen bytes!!!");
    try Fixture.seed(a, big, "sixteen bytes!!!");
    // The bytes verify, so only the size bound can classify them.
    try std.testing.expectEqual(Action.cached, (try plan(a, &.{big}))[0].action);
    const saved = archive_mod.cache_read_limit;
    defer archive_mod.cache_read_limit = saved;
    archive_mod.cache_read_limit = 8;
    try std.testing.expectEqual(Action.replace, (try plan(a, &.{big}))[0].action);
}
