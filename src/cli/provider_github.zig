//! GitHub metadata + a project pin file. No registry service or implicit updates.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const project = @import("project_config.zig");
const cache = @import("asm_cache.zig");
const manifest = @import("provider_manifest.zig");
const contract = @import("provider_contract.zig");
const util = @import("util.zig");
const dispatch = @import("provider_dispatch.zig");
const hooks = @import("provider_hooks.zig");
const registry = @import("provider_registry.zig");

pub const lock_name = "labelle.providers.lock";
/// Project-local record of the last `resolve` preview. `--accept` refuses to
/// pin anything that differs from it (Codex P1 on #414: a registry repointed
/// between preview and accept must not cross the consent boundary).
pub const preview_name = ".labelle/providers.preview.json";
pub const registry_url = "https://raw.githubusercontent.com/labelle-toolkit/labelle-registry/main/providers.json";
/// Where the last accepted registry document is kept under the cache root.
/// Read only by `cachedRegistryOwner`, for a diagnostic; never for resolution.
pub const registry_cache_dir = "registry";
pub const registry_cache_file = "providers.json";
pub const Pin = struct {
    package: []const u8,
    repo: []const u8,
    version: []const u8,
    commit: []const u8,
    sha256: []const u8,

    pub fn validate(self: Pin) !void {
        if (!contract.identifier(self.package)) return error.InvalidProviderPackage;
        var parts = std.mem.splitScalar(u8, self.repo, '/');
        var count: usize = 0;
        while (parts.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidGitHubRepository;
            for (part) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return error.InvalidGitHubRepository;
            count += 1;
        }
        if (count != 2) return error.InvalidGitHubRepository;
        const version = try std.SemanticVersion.parse(self.version);
        if (version.pre != null or version.build != null) return error.InvalidProviderVersion;
        if (!lowerHex(self.commit, 40)) return error.InvalidGitHubCommit;
        if (!lowerHex(self.sha256, 64)) return error.InvalidArchiveHash;
    }

    pub fn matches(self: Pin, dep: project.PluginDep) bool {
        return std.mem.eql(u8, self.package, dep.name) and std.mem.eql(u8, self.repo, dep.repo) and std.mem.eql(u8, self.version, dep.version);
    }

    pub fn archiveUrl(self: Pin, a: std.mem.Allocator) ![]const u8 {
        try self.validate();
        return std.fmt.allocPrint(a, "https://codeload.github.com/{s}/tar.gz/{s}", .{ self.repo, self.commit });
    }
};

pub const Document = struct {
    schema_version: u8,
    providers: []const Pin,
};

fn lowerHex(text: []const u8, length: usize) bool {
    if (text.len != length) return false;
    for (text) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

/// The project integrity lock (and a schema-1 registry) share this small
/// schema; locks allow one pin/package. Registry documents are read through
/// `provider_registry.parse`, which also accepts schema 2.
pub fn parse(a: std.mem.Allocator, bytes: []const u8, is_lock: bool) !Document {
    const parsed = try std.json.parseFromSlice(Document, a, bytes, .{ .allocate = .alloc_always });
    // The caller owns an arena; successful parsed strings live through invocation.
    const doc = parsed.value;
    if (doc.schema_version != 1) return error.UnsupportedProviderSchema;
    try checkPins(doc.providers, is_lock);
    return doc;
}

/// The per-record and cross-record rules every pin list obeys, whatever
/// document carried it (a lock, or a registry of either schema).
pub fn checkPins(pins: []const Pin, is_lock: bool) !void {
    for (pins, 0..) |pin, i| {
        try pin.validate();
        for (pins[0..i]) |prev| {
            if (std.mem.eql(u8, pin.package, prev.package)) {
                if (!std.mem.eql(u8, pin.repo, prev.repo)) return error.ProviderRepositoryConflict;
                if (is_lock or std.mem.eql(u8, pin.version, prev.version)) return error.DuplicateProviderRelease;
            }
        }
    }
}

fn read(a: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, a, .limited(limit));
}

pub fn archivePath(a: std.mem.Allocator, pin: Pin) ![]const u8 {
    try pin.validate();
    return std.fs.path.join(a, &.{ try cacheRoot(a), "provider-archives", try std.fmt.allocPrint(a, "{s}.tar.gz", .{pin.sha256}) });
}

pub fn cacheRoot(a: std.mem.Allocator) ![]const u8 {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), ".", a);
    return std.fs.path.resolve(a, &.{ cwd, try cache.getCacheRoot(a) });
}

fn download(a: std.mem.Allocator, url: []const u8, dest: []const u8, max_size: usize) !void {
    const result = try util.runCmd(a, &.{
        "curl",     "--fail",     "--silent",      "--show-error",   "--location",
        "--proto",  "=https",     "--proto-redir", "=https",         "--connect-timeout",
        "30",       "--max-time", "180",           "--max-filesize", try std.fmt.allocPrint(a, "{d}", .{max_size}),
        "--output", dest,         url,
    });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("labelle: GitHub download failed: {s}\n{s}\n", .{ url, result.stderr });
        return error.ProviderDownloadFailed;
    }
}

fn uniqueName(a: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    var random: [16]u8 = undefined;
    config.globalIo().random(&random);
    return std.fmt.allocPrint(a, "{s}-{s}", .{ prefix, std.fmt.bytesToHex(random, .lower) });
}

/// Verify bytes on every read, including cache hits. A mismatch never refetches
/// silently and never changes a pin. Delete the damaged archive and resolve again.
fn archive(a: std.mem.Allocator, pin: Pin, allow_download: bool) ![]u8 {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const path = try archivePath(a, pin);
    const bytes = read(a, path, 128 * 1024 * 1024) catch |err| blk: {
        if (err != error.FileNotFound) return err;
        if (!allow_download) return error.ProviderArchiveMissing;
        try cwd.createDirPath(io, std.fs.path.dirname(path).?);
        const tmp = try uniqueName(a, path);
        defer cwd.deleteFile(io, tmp) catch {};
        try download(a, try pin.archiveUrl(a), tmp, 128 * 1024 * 1024);
        const downloaded = try read(a, tmp, 128 * 1024 * 1024);
        if (!util.sha256Matches(downloaded, pin.sha256)) return error.ProviderArchiveHashMismatch;
        try std.Io.Dir.renameAbsolute(tmp, path, io);
        break :blk downloaded;
    };
    if (!util.sha256Matches(bytes, pin.sha256)) return error.ProviderArchiveHashMismatch;
    return bytes;
}

/// Fresh extraction per invocation means altered unpacked cache files are never
/// executable inputs. Only verified compressed bytes are persisted in the cache.
///
/// A long-lived invocation (a watched serve) re-discovers its providers
/// on every rebuild; it passes `shared` so an extraction made earlier in the
/// SAME invocation, from an archive with the same verified hash, is reused
/// instead of unpacked again (cli#429). With `extract = false` the sources
/// only look such an extraction up and never touch an archive: a pin with no
/// extraction yet is `ProviderSourceNotExtracted` — the metadata-only view
/// the watch pre-check reads.
pub const Sources = struct {
    a: std.mem.Allocator,
    directories: std.ArrayList([]const u8) = .empty,
    /// Every extraction this value performed or reused: `(sha256, path)`.
    /// A generation's `used` set is what its providers point into.
    used: std.ArrayList(Extracted) = .empty,
    shared: ?*Extractions = null,
    extract: bool = true,

    pub const Extracted = struct { sha256: []const u8, path: []const u8 };

    pub fn deinit(self: *Sources) void {
        for (self.directories.items) |path| std.Io.Dir.cwd().deleteTree(config.globalIo(), path) catch |err| {
            std.debug.print("labelle: could not remove provider source '{s}': {s}\n", .{ path, @errorName(err) });
        };
        self.directories.deinit(self.a);
        self.used.deinit(self.a);
    }

    pub fn fromPin(self: *Sources, pin: Pin, allow_download: bool) ![]const u8 {
        if (self.shared) |shared| if (try shared.reuse(pin)) |path| {
            try self.used.append(self.a, .{ .sha256 = try self.a.dupe(u8, pin.sha256), .path = try self.a.dupe(u8, path) });
            return self.a.dupe(u8, path);
        };
        if (!self.extract) return error.ProviderSourceNotExtracted;
        const extracted = try self.extractPin(pin, allow_download);
        if (self.shared) |shared| {
            // The shared cache owns the directory from here on: it outlives
            // this value, and its `retain` decides when it is removed.
            const owned = self.directories.pop().?;
            shared.adopt(pin.sha256, extracted, owned) catch |err| {
                std.Io.Dir.cwd().deleteTree(config.globalIo(), owned) catch {};
                return err;
            };
        }
        try self.used.append(self.a, .{ .sha256 = try self.a.dupe(u8, pin.sha256), .path = extracted });
        return extracted;
    }

    fn extractPin(self: *Sources, pin: Pin, allow_download: bool) ![]const u8 {
        extraction_count +%= 1;
        const bytes = try archive(self.a, pin, allow_download);
        defer self.a.free(bytes);
        var input: std.Io.Reader = .fixed(bytes);
        var buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var decompressor = std.compress.flate.Decompress.init(&input, .gzip, &buffer);
        const tar = try decompressor.reader.allocRemaining(self.a, .limited(512 * 1024 * 1024));
        defer self.a.free(tar);
        try validateTar(self.a, tar);
        const io = config.globalIo();
        const root = try std.fs.path.join(self.a, &.{ try cacheRoot(self.a), "provider-sources" });
        try std.Io.Dir.cwd().createDirPath(io, root);
        const path = try uniqueName(self.a, try std.fs.path.join(self.a, &.{ root, "source" }));
        try std.Io.Dir.cwd().createDir(io, path, .default_dir);
        self.directories.append(self.a, path) catch |err| {
            std.Io.Dir.cwd().deleteTree(io, path) catch {};
            return err;
        };
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
        defer dir.close(io);
        var reader: std.Io.Reader = .fixed(tar);
        try std.tar.extract(io, dir, &reader, .{ .strip_components = 1 });
        try checkName(self.a, path, pin);
        return std.Io.Dir.cwd().realPathFileAlloc(io, path, self.a);
    }

    pub fn projectDir(self: *Sources, root: []const u8, dep: project.PluginDep) !?[]const u8 {
        const bytes = read(self.a, try std.fs.path.join(self.a, &.{ root, lock_name }), 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        const doc = try parse(self.a, bytes, true);
        for (doc.providers) |pin| {
            if (!std.mem.eql(u8, pin.package, dep.name)) continue;
            if (!pin.matches(dep)) return error.StaleProviderIntegrityPin;
            return try self.fromPin(pin, false);
        }
        return null;
    }
};

/// The extracted manifest names the pinned package.
fn checkName(a: std.mem.Allocator, dir: []const u8, pin: Pin) !void {
    const meta = try manifest.parse(a, try read(a, try std.fs.path.join(a, &.{ dir, "plugin.labelle" }), 1024 * 1024));
    if (!meta.isProvider() or !std.mem.eql(u8, meta.name, pin.package)) return error.ProviderNameMismatch;
}

/// Fresh archive extractions performed by any `Sources` — the test seam that
/// shows which rebuilds unpacked an archive and which reused one.
pub var extraction_count: usize = 0;

/// Provider extractions shared by the `Sources` of one long-lived invocation,
/// keyed by the pin's verified archive hash (see `Sources`). Every
/// extraction in it was made during this invocation from bytes that matched
/// that hash; an entry `owned` by the cache is removed by `retain` or
/// `deinit`, a borrowed one (`seed`) belongs to the `Sources` it came from.
pub const Extractions = struct {
    a: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { sha256: []const u8, path: []const u8, dir: ?[]const u8 };

    pub fn deinit(self: *Extractions) void {
        for (self.entries.items) |entry| self.release(entry);
        self.entries.deinit(self.a);
    }

    fn release(self: *Extractions, entry: Entry) void {
        if (entry.dir) |dir| {
            std.Io.Dir.cwd().deleteTree(config.globalIo(), dir) catch |err| {
                std.debug.print("labelle: could not remove provider source '{s}': {s}\n", .{ dir, @errorName(err) });
            };
            self.a.free(dir);
        }
        self.a.free(entry.sha256);
        self.a.free(entry.path);
    }

    fn find(self: *Extractions, sha256: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, i| if (std.mem.eql(u8, entry.sha256, sha256)) return i;
        return null;
    }

    /// The directory an earlier extraction of `pin`'s archive left, or
    /// null. Its manifest is read again (a small file) so a pin naming a
    /// different package over the same bytes still fails
    /// `ProviderNameMismatch`; a directory that vanished is dropped and
    /// reads as no extraction.
    fn reuse(self: *Extractions, pin: Pin) !?[]const u8 {
        const index = self.find(pin.sha256) orelse return null;
        const path = self.entries.items[index].path;
        var scratch = std.heap.ArenaAllocator.init(self.a);
        defer scratch.deinit();
        checkName(scratch.allocator(), path, pin) catch |err| switch (err) {
            error.FileNotFound => {
                self.release(self.entries.orderedRemove(index));
                return null;
            },
            else => return err,
        };
        return path;
    }

    /// Take ownership of a fresh extraction: `dir` is removed by `retain`
    /// or `deinit`, never by the `Sources` that made it.
    fn adopt(self: *Extractions, sha256: []const u8, path: []const u8, dir: []const u8) !void {
        return self.insert(sha256, path, dir);
    }

    fn insert(self: *Extractions, sha256: []const u8, path: []const u8, dir: ?[]const u8) !void {
        const sha_copy = try self.a.dupe(u8, sha256);
        errdefer self.a.free(sha_copy);
        const path_copy = try self.a.dupe(u8, path);
        errdefer self.a.free(path_copy);
        const dir_copy: ?[]const u8 = if (dir) |d| try self.a.dupe(u8, d) else null;
        errdefer if (dir_copy) |d| self.a.free(d);
        try self.entries.append(self.a, .{ .sha256 = sha_copy, .path = path_copy, .dir = dir_copy });
    }

    /// Borrow every extraction `sources` made (the cold pipeline's, which
    /// outlive this cache): a later rebuild reuses them, nobody here removes
    /// them.
    pub fn seed(self: *Extractions, sources: *const Sources) !void {
        for (sources.used.items) |extracted| {
            if (self.find(extracted.sha256) != null) continue;
            try self.insert(extracted.sha256, extracted.path, null);
        }
    }

    /// Remove every owned extraction none of `keep` uses — once a new
    /// generation is installed, the ones only the previous one (or a failed
    /// replan) read. Borrowed entries stay: they cost nothing here.
    pub fn retain(self: *Extractions, keep: []const []const Sources.Extracted) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = self.entries.items[i];
            if (entry.dir == null or kept(keep, entry.sha256)) {
                i += 1;
                continue;
            }
            self.release(self.entries.orderedRemove(i));
        }
    }

    fn kept(keep: []const []const Sources.Extracted, sha256: []const u8) bool {
        for (keep) |set| for (set) |extracted| if (std.mem.eql(u8, extracted.sha256, sha256)) return true;
        return false;
    }
};

/// The `plugin.labelle` of a pinned package, read straight out of its
/// verified cached archive — nothing is extracted, downloaded or run — or
/// null when the archive holds no manifest. `ProviderArchiveMissing` when
/// the archive is not cached. Every buffer lands on `a`; callers that scan
/// several releases pass a scratch arena.
fn cachedManifest(a: std.mem.Allocator, pin: Pin) !?manifest.Manifest {
    const bytes = try archive(a, pin, false);
    defer a.free(bytes);
    var input: std.Io.Reader = .fixed(bytes);
    var buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&input, .gzip, &buffer);
    const tar = try decompressor.reader.allocRemaining(a, .limited(512 * 1024 * 1024));
    defer a.free(tar);
    try validateTar(a, tar);
    var reader: std.Io.Reader = .fixed(tar);
    var name: [4096]u8 = undefined;
    var link: [4096]u8 = undefined;
    var it = std.tar.Iterator.init(&reader, .{ .file_name_buffer = &name, .link_name_buffer = &link });
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        // One root directory (validateTar), so the manifest is `<root>/plugin.labelle`.
        const slash = std.mem.indexOfScalar(u8, entry.name, '/') orelse continue;
        if (!std.mem.eql(u8, entry.name[slash + 1 ..], "plugin.labelle")) continue;
        if (entry.size > 1024 * 1024) return error.StreamTooLong;
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try it.streamRemaining(entry, &out.writer);
        return try manifest.parse(a, out.written());
    }
    return null;
}

/// How many cached releases the registry-hint scan reads before giving up
/// on the hint. Each read decompresses a whole archive (up to 128 MiB
/// compressed, 512 MiB unpacked), so the scan is bounded rather than the
/// size of the registry document.
pub const registry_hint_scan_limit: usize = 16;

fn cachedOwner(a: std.mem.Allocator, target: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(a, &.{ try cacheRoot(a), registry_cache_dir, registry_cache_file });
    const bytes = read(a, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const doc = try registry.parse(a, bytes);
    // Schema 2 publishes target ownership (#411): the lookup is by name and
    // reads no archive at all. Only a schema-1 document, whose records claim
    // nothing, falls back to the bounded scan of cached archives.
    if (doc.claimsOwnership()) return doc.targetOwner(target);
    var inspected: usize = 0;
    for (doc.pins) |pin| {
        if (inspected == registry_hint_scan_limit) break;
        // Only a verified cached archive can say what a package declares; a
        // release that is not cached, or whose bytes do not verify, says nothing.
        // The archive and its unpacked tar live on a scratch arena freed per
        // release: the caller's arena (the pipeline's) would keep every
        // inspected release's buffers alive until the command exits.
        var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch.deinit();
        const read_manifest = cachedManifest(scratch.allocator(), pin) catch |err| switch (err) {
            error.ProviderArchiveMissing => continue, // Not cached: nothing was read.
            else => {
                inspected += 1;
                continue;
            },
        };
        // Counted whether or not the archive carries a `plugin.labelle`: the
        // bytes were read, verified and decompressed either way, and a
        // registry of manifest-less releases must not read past the bound
        // (Codex on #421).
        inspected += 1;
        const meta = read_manifest orelse continue;
        // `pin.package` is on the caller's allocator, unlike `meta`.
        if (std.mem.eql(u8, meta.name, pin.package) and meta.ownsTarget(target)) return pin.package;
    }
    return null;
}

/// The package the cached registry document names as the owner of `target`,
/// or null. Reads the cache only: no network, no extraction, no package code.
/// A schema-2 document answers from its target-ownership table (whose claims
/// `--accept` checked against every release it pinned); a schema-1 record
/// carries no declarations, so there the owner is whichever listed package's
/// verified cached archive declares the target. A missing document, an
/// uncached archive or an unreadable manifest is simply no hint — the caller
/// never invents a name.
pub fn cachedRegistryOwner(a: std.mem.Allocator, target: []const u8) ?[]const u8 {
    return cachedOwner(a, target) catch null;
}

/// Keep the document an accept just resolved against, for `cachedRegistryOwner`.
fn cacheRegistry(a: std.mem.Allocator, data: []const u8) !void {
    const dir = try std.fs.path.join(a, &.{ try cacheRoot(a), registry_cache_dir });
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), dir);
    try writeAtomically(a, try std.fs.path.join(a, &.{ dir, registry_cache_file }), data);
}

fn safeArchivePath(path: []const u8) bool {
    if (path.len == 0 or std.mem.indexOfAny(u8, path, "\\:\x00<>\"|?*") != null) return false;
    var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, path, "/"), '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or
            std.mem.endsWith(u8, part, ".") or std.mem.endsWith(u8, part, " ")) return false;
    }
    return true;
}

/// An archive containing a Windows reserved device name extracts on Unix but
/// fails on Windows (`contract.windowsReservedDeviceName`, shared with the
/// target-name rule).
fn hasReservedDeviceName(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, path, "/"), '/');
    while (parts.next()) |part| if (contract.windowsReservedDeviceName(part)) return true;
    return false;
}

fn validateTar(a: std.mem.Allocator, bytes: []const u8) !void {
    var reader: std.Io.Reader = .fixed(bytes);
    var name: [4096]u8 = undefined;
    var link: [4096]u8 = undefined;
    var it = std.tar.Iterator.init(&reader, .{ .file_name_buffer = &name, .link_name_buffer = &link });
    var root: ?[]const u8 = null;
    var names: std.StringHashMap(void) = .init(a);
    defer names.deinit();
    // Case-folded regular-file paths, and every case-folded path that some
    // entry needs to be a directory (each proper ancestor of an entry).
    var files: std.StringHashMap(void) = .init(a);
    defer files.deinit();
    var parents: std.StringHashMap(void) = .init(a);
    defer parents.deinit();
    while (try it.next()) |entry| {
        if (entry.kind == .sym_link) return error.ProviderArchiveLinkNotSupported;
        if (!safeArchivePath(entry.name)) return error.UnsafeProviderArchivePath;
        // Windows rejects control characters in file names (NUL is already an
        // unsafe path above), so such archives only extract on Unix.
        for (entry.name) |c| if (std.ascii.isControl(c)) {
            std.debug.print("provider archive entry '{f}' contains an ASCII control character (byte 0x{x:0>2}); archive paths must be printable\n", .{ std.ascii.hexEscape(entry.name, .lower), c });
            return error.ControlCharProviderArchivePath;
        };
        // The duplicate check below folds ASCII case only; case-insensitive
        // hosts also fold non-ASCII letters, so such paths are not portable.
        for (entry.name) |c| if (!std.ascii.isAscii(c)) {
            std.debug.print("provider archive entry '{s}' contains non-ASCII bytes; archive paths must be ASCII\n", .{entry.name});
            return error.NonAsciiProviderArchivePath;
        };
        if (hasReservedDeviceName(entry.name)) {
            std.debug.print("provider archive entry '{s}' uses a Windows reserved device name (CON, PRN, AUX, NUL, COM1-9, LPT1-9, CONIN$, CONOUT$; any case, with or without extension)\n", .{entry.name});
            return error.ReservedProviderArchiveName;
        }
        const trimmed = std.mem.trimEnd(u8, entry.name, "/");
        const slash = std.mem.indexOfScalar(u8, trimmed, '/') orelse trimmed.len;
        if (root) |r| {
            if (!std.mem.eql(u8, r, trimmed[0..slash])) return error.MultipleProviderArchiveRoots;
        } else root = try a.dupe(u8, trimmed[0..slash]);
        if (slash == trimmed.len and entry.kind != .directory) return error.MissingProviderArchiveRoot;
        // Case-fold on every host so archives are portable to Windows.
        const key = try std.ascii.allocLowerString(a, trimmed);
        if ((try names.getOrPut(key)).found_existing) return error.DuplicateProviderArchivePath;
        // A regular file `root/Foo` and an entry below `root/foo/` extract on
        // a case-sensitive host but collide on a case-insensitive one, in
        // either archive order.
        var end = key.len;
        while (std.mem.lastIndexOfScalar(u8, key[0..end], '/')) |cut| : (end = cut) {
            const parent = key[0..cut];
            if (files.contains(parent)) return fileDirConflict(entry.name, parent);
            if ((try parents.getOrPut(parent)).found_existing) break; // Its ancestors were checked already.
        }
        if (entry.kind != .directory) {
            if (parents.contains(key)) return fileDirConflict(entry.name, key);
            try files.put(key, {});
        }
    }
    if (root == null) return error.EmptyProviderArchive;
}

fn fileDirConflict(name: []const u8, folded: []const u8) error{CaseFoldedProviderArchiveFileDirConflict} {
    std.debug.print("provider archive entry '{s}' conflicts with another entry: '{s}' is both a regular file and a directory once ASCII case is folded\n", .{ name, folded });
    return error.CaseFoldedProviderArchiveFileDirConflict;
}

/// One previewed pin: every field the user was shown, including the derived
/// archive URL and, for a schema-2 registry, the record's ownership claims
/// (`null`/`[]` under schema 1, which claims nothing), so a later accept can
/// be checked against exactly that.
pub const PreviewEntry = struct {
    package: []const u8,
    repo: []const u8,
    version: []const u8,
    commit: []const u8,
    sha256: []const u8,
    archive_url: []const u8,
    namespace: ?[]const u8,
    targets: []const []const u8,

    fn fromPin(a: std.mem.Allocator, doc: registry.Registry, pin: Pin) !PreviewEntry {
        const record = doc.find(pin.package, pin.version);
        return .{
            .package = pin.package,
            .repo = pin.repo,
            .version = pin.version,
            .commit = pin.commit,
            .sha256 = pin.sha256,
            .archive_url = try pin.archiveUrl(a),
            .namespace = if (record) |r| r.namespace else null,
            .targets = if (record) |r| r.targets else &.{},
        };
    }

    fn toPin(self: PreviewEntry) Pin {
        return .{ .package = self.package, .repo = self.repo, .version = self.version, .commit = self.commit, .sha256 = self.sha256 };
    }
};

/// The preview file's own format. 2 added the registry binding (#433); an
/// older file is unreadable, which only asks for a new review.
pub const preview_schema: u8 = 2;

/// Persisted by a preview, consumed (and removed) by a successful accept.
/// It binds the WHOLE registry document, not only the selected pins (#433):
/// `registry_digest` is the SHA-256 of `Registry.normalised`, so a schema
/// swap, a changed claim or default, or a changed unselected record between
/// preview and accept is a mismatch. `registry_schema`, `defaults` and each
/// entry's claims repeat parts of that document so a mismatch can name the
/// field; the digest is the catch-all for everything else.
pub const Preview = struct {
    schema_version: u8,
    source: []const u8,
    registry_schema: u8,
    registry_digest: []const u8,
    defaults: []const registry.DefaultRef,
    digest: []const u8,
    providers: []const PreviewEntry,

    /// Everything the preview digest covers: the record minus the digest.
    fn body(self: Preview) PreviewBody {
        return .{ .source = self.source, .registry_schema = self.registry_schema, .registry_digest = self.registry_digest, .defaults = self.defaults, .providers = self.providers };
    }
};

const PreviewBody = struct {
    source: []const u8,
    registry_schema: u8,
    registry_digest: []const u8,
    defaults: []const registry.DefaultRef,
    providers: []const PreviewEntry,
};

fn sha256Hex(a: std.mem.Allocator, data: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

/// SHA-256 over the canonical JSON of the registry source, the registry
/// binding and every shown field. Recomputed on load, so an edited preview
/// file is caught too.
fn previewDigest(a: std.mem.Allocator, body: PreviewBody) ![]const u8 {
    return sha256Hex(a, try std.json.Stringify.valueAlloc(a, body, .{}));
}

/// The preview record for `pins` selected from `doc` (read from `source`).
fn previewOf(a: std.mem.Allocator, source: []const u8, doc: registry.Registry, pins: []const Pin) !Preview {
    const entries = try a.alloc(PreviewEntry, pins.len);
    for (pins, 0..) |pin, i| entries[i] = try PreviewEntry.fromPin(a, doc, pin);
    var preview: Preview = .{
        .schema_version = preview_schema,
        .source = source,
        .registry_schema = doc.schema_version,
        .registry_digest = try sha256Hex(a, try doc.normalised(a)),
        .defaults = doc.defaults,
        .digest = "",
        .providers = entries,
    };
    preview.digest = try previewDigest(a, preview.body());
    return preview;
}

fn writeAtomically(a: std.mem.Allocator, dest: []const u8, data: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const temp = try uniqueName(a, dest);
    defer cwd.deleteFile(io, temp) catch {};
    try cwd.writeFile(io, .{ .sub_path = temp, .data = data });
    try std.Io.Dir.renameAbsolute(temp, dest, io);
}

pub fn writePreview(a: std.mem.Allocator, root: []const u8, source: []const u8, doc: registry.Registry, pins: []const Pin) !Preview {
    const preview = try previewOf(a, source, doc, pins);
    const dest = try std.fs.path.join(a, &.{ root, preview_name });
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), std.fs.path.dirname(dest).?);
    try writeAtomically(a, dest, try std.json.Stringify.valueAlloc(a, preview, .{ .whitespace = .indent_2 }));
    return preview;
}

/// Missing, unparseable, or digest-mismatched previews all fail closed: accept
/// never falls back to a fresh registry fetch.
pub fn loadPreview(a: std.mem.Allocator, root: []const u8) !Preview {
    const path = try std.fs.path.join(a, &.{ root, preview_name });
    const bytes = read(a, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("labelle: no provider preview at {s}; run 'labelle providers resolve' first and review the pins before --accept\n", .{preview_name});
            return error.ProviderPreviewMissing;
        },
        else => return err,
    };
    const parsed = std.json.parseFromSlice(Preview, a, bytes, .{ .allocate = .alloc_always }) catch |err| {
        std.debug.print("labelle: provider preview {s} is unreadable ({s}); run 'labelle providers resolve' again\n", .{ preview_name, @errorName(err) });
        return error.ProviderPreviewCorrupt;
    };
    const preview = parsed.value;
    if (preview.schema_version != preview_schema) {
        std.debug.print("labelle: provider preview {s} has format {d}, this CLI writes {d}; run 'labelle providers resolve' again\n", .{ preview_name, preview.schema_version, preview_schema });
        return error.ProviderPreviewCorrupt;
    }
    for (preview.providers) |entry| {
        const pin = entry.toPin();
        pin.validate() catch return error.ProviderPreviewCorrupt;
        if (!std.mem.eql(u8, entry.archive_url, try pin.archiveUrl(a))) return error.ProviderPreviewCorrupt;
    }
    if (!std.mem.eql(u8, preview.digest, try previewDigest(a, preview.body()))) {
        std.debug.print("labelle: provider preview {s} does not match its digest; run 'labelle providers resolve' again\n", .{preview_name});
        return error.ProviderPreviewCorrupt;
    }
    return preview;
}

fn reportChange(package: []const u8, field: []const u8, previewed: []const u8, now: []const u8) void {
    std.debug.print("labelle: provider '{s}' {s} changed since preview: {s} -> {s}\n", .{ package, field, previewed, now });
}

fn jsonText(a: std.mem.Allocator, value: anytype) []const u8 {
    return std.json.Stringify.valueAlloc(a, value, .{}) catch "<unprintable>";
}

/// Every field the user reviewed, and the whole registry document it came
/// from, must equal what the registry serves now. Any difference names the
/// field (and package) and aborts the accept.
pub fn checkPreview(a: std.mem.Allocator, preview: Preview, source: []const u8, doc: registry.Registry, pins: []const Pin) !void {
    var changed = false;
    if (!std.mem.eql(u8, preview.source, source)) {
        std.debug.print("labelle: registry source changed since preview: {s} -> {s}\n", .{ preview.source, source });
        changed = true;
    }
    const now = try previewOf(a, source, doc, pins);
    if (preview.registry_schema != now.registry_schema) {
        std.debug.print("labelle: registry schema_version changed since preview: {d} -> {d}\n", .{ preview.registry_schema, now.registry_schema });
        changed = true;
    }
    if (!std.mem.eql(u8, jsonText(a, preview.defaults), jsonText(a, now.defaults))) {
        std.debug.print("labelle: registry defaults changed since preview: {s} -> {s}\n", .{ jsonText(a, preview.defaults), jsonText(a, now.defaults) });
        changed = true;
    }
    const fresh = now.providers;
    for (preview.providers) |old| {
        var found = false;
        for (fresh) |new| {
            if (!std.mem.eql(u8, old.package, new.package)) continue;
            found = true;
            inline for (.{ "repo", "version", "commit", "sha256", "archive_url" }) |field| {
                if (!std.mem.eql(u8, @field(old, field), @field(new, field))) {
                    reportChange(old.package, field, @field(old, field), @field(new, field));
                    changed = true;
                }
            }
            inline for (.{ "namespace", "targets" }) |field| {
                const was = jsonText(a, @field(old, field));
                const is = jsonText(a, @field(new, field));
                if (!std.mem.eql(u8, was, is)) {
                    reportChange(old.package, field, was, is);
                    changed = true;
                }
            }
        }
        if (!found) {
            std.debug.print("labelle: provider '{s}' was previewed but is no longer selected\n", .{old.package});
            changed = true;
        }
    }
    for (fresh) |new| {
        var found = false;
        for (preview.providers) |old| found = found or std.mem.eql(u8, old.package, new.package);
        if (!found) {
            std.debug.print("labelle: provider '{s}' is selected now but was not previewed\n", .{new.package});
            changed = true;
        }
    }
    // The catch-all: nothing shown above differs, yet the document does, so
    // an unselected release record changed (it could otherwise reach the
    // cached ownership table the accept writes for target diagnostics).
    if (!changed and !std.mem.eql(u8, preview.registry_digest, now.registry_digest)) {
        std.debug.print("labelle: registry document changed since preview outside the selected releases (an unselected release record): sha256 {s} -> {s}\n", .{ preview.registry_digest, now.registry_digest });
        changed = true;
    }
    if (changed) {
        std.debug.print("labelle: refusing --accept: the registry no longer matches the reviewed preview. Run 'labelle providers resolve' again and review the new pins.\n", .{});
        return error.ProviderPreviewMismatch;
    }
}

/// Test-only fault: makes `removePreview` fail as an unwritable `.labelle`
/// would, so the post-commit path can be exercised on every host.
var fail_preview_removal_for_test = false;

fn removePreview(a: std.mem.Allocator, root: []const u8) !void {
    if (builtin.is_test and fail_preview_removal_for_test) return error.AccessDenied;
    std.Io.Dir.cwd().deleteFile(config.globalIo(), try std.fs.path.join(a, &.{ root, preview_name })) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// Resolve only explicitly declared project versions. Preview is read-only
/// apart from recording what was shown in `preview_name`; --accept re-fetches
/// metadata, requires it to equal that record, verifies sources, and runs no
/// package code.
pub fn resolve(a: std.mem.Allocator, root: []const u8, source: []const u8, accept: bool, offline: bool, reserved: []const []const u8) !void {
    // Fail closed before any network or archive work when nothing was reviewed.
    const preview: ?Preview = if (accept) try loadPreview(a, root) else null;
    var metadata: []const u8 = undefined;
    if (std.mem.startsWith(u8, source, "https://raw.githubusercontent.com/")) {
        if (offline) return error.OfflineRegistryNeedsLocalFile;
        // stdout capture is bounded; curl cannot execute the returned document.
        const result = try util.runCmd(a, &.{ "curl", "--fail", "--silent", "--show-error", "--proto", "=https", "--connect-timeout", "30", "--max-time", "60", "--max-filesize", "1048576", source });
        if (result.term != .exited or result.term.exited != 0) return error.ProviderRegistryDownloadFailed;
        metadata = result.stdout;
    } else {
        if (std.mem.indexOf(u8, source, "://") != null) return error.InvalidProviderRegistrySource;
        metadata = try read(a, source, 1024 * 1024);
    }
    const doc = try registry.parse(a, metadata);
    const cfg = try config.readProjectConfigQuiet(a, root);
    var selected: std.ArrayList(Pin) = .empty;
    for (cfg.plugins, 0..) |dep, i| {
        for (cfg.plugins[0..i]) |prev| if (std.mem.eql(u8, dep.name, prev.name)) return error.DuplicateProjectPlugin;
        if (dep.isLocal()) continue;
        var known = false;
        var found = false;
        for (doc.pins) |pin| {
            if (!std.mem.eql(u8, pin.package, dep.name)) continue;
            known = true;
            if (!pin.matches(dep)) continue;
            try selected.append(a, pin);
            found = true;
            std.debug.print("  {s} {s}: {s}@{s}\n    sha256 {s}\n    {s}\n", .{ pin.package, pin.version, pin.repo, pin.commit, pin.sha256, try pin.archiveUrl(a) });
            if (doc.find(pin.package, pin.version)) |record| {
                std.debug.print("    namespace {s}, targets {s}\n", .{ jsonText(a, record.namespace), jsonText(a, record.targets) });
            }
        }
        if (known and !found) return error.ProviderReleaseNotInRegistry;
    }
    if (!accept) {
        const shown = try writePreview(a, root, source, doc, selected.items);
        if (doc.claimsOwnership()) std.debug.print("  registry defaults {s}\n", .{jsonText(a, doc.defaults)});
        std.debug.print("  registry schema {d}, normalised document sha256 {s}\n", .{ shown.registry_schema, shown.registry_digest });
        std.debug.print("Preview: {d} provider pin(s), digest {s}, recorded in {s}.\nRepeat with --accept to verify archives and write {s}; accept refuses any pin, claim, default or other registry record that differs from this preview.\n", .{ selected.items.len, shown.digest, preview_name, lock_name });
        return;
    }
    // Acceptance is bound to the reviewed record: the fresh fetch may only
    // confirm it (the whole normalised document, not just the selected
    // pins), and the pins prepared below are the previewed ones.
    try checkPreview(a, preview.?, source, doc, selected.items);
    // What the target-hint cache will hold after the commit: the normalised
    // form of the document just bound to the preview, so its bytes hash to
    // the reviewed `registry_digest`. `checkPreview` already refused any
    // other document; the re-check keeps that true if it ever changes.
    const reviewed = try doc.normalised(a);
    if (!std.mem.eql(u8, try sha256Hex(a, reviewed), preview.?.registry_digest)) return error.ProviderPreviewMismatch;
    selected.clearRetainingCapacity();
    for (preview.?.providers) |entry| try selected.append(a, entry.toPin());
    std.debug.print("Accepting preview digest {s}.\n", .{preview.?.digest});
    var sources: Sources = .{ .a = a };
    defer sources.deinit();
    var ownership: std.ArrayList(contract.Ownership) = .empty;
    // The accepted set as `discover` would see it, so the hook graph is
    // validated across remote AND local providers before any pin is written
    // (Codex P2 on #420): an accept that wrote a lock for a graph with a
    // missing reference, a phase-order violation, duplicate replacements or
    // a cycle only moved the failure to the project's next help/build.
    var providers: std.ArrayList(dispatch.Provider) = .empty;
    for (selected.items) |pin| {
        const dir = try sources.fromPin(pin, !offline);
        const meta = try manifest.parse(a, try read(a, try std.fs.path.join(a, &.{ dir, "plugin.labelle" }), 1024 * 1024));
        // A schema-2 registry's ownership claims for this release must be
        // what its verified manifest declares, before anything is pinned.
        try doc.checkDeclarations(pin, meta);
        const ns = try a.alloc([]const u8, if (meta.namespace != null) 1 else 0);
        if (meta.namespace) |value| ns[0] = value;
        try ownership.append(a, .{ .package = pin.package, .namespaces = ns, .targets = meta.targets });
        for (cfg.plugins) |dep| {
            if (std.mem.eql(u8, dep.name, pin.package)) try providers.append(a, .{ .dep = dep, .dir = dir, .meta = meta, .verified = true });
        }
    }
    // Include local owners before changing pins, even though they need no archive.
    for (cfg.plugins) |dep| {
        if (!dep.isLocal()) continue;
        const dir = try std.fs.path.resolve(a, &.{ root, dep.localPath() });
        const path = try std.fs.path.join(a, &.{ dir, "plugin.labelle" });
        const bytes = read(a, path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const meta = try manifest.parse(a, bytes);
        if (!meta.isProvider()) continue;
        if (!std.mem.eql(u8, dep.name, meta.name)) return error.ProviderNameMismatch;
        const ns = try a.alloc([]const u8, if (meta.namespace != null) 1 else 0);
        if (meta.namespace) |value| ns[0] = value;
        try ownership.append(a, .{ .package = dep.name, .namespaces = ns, .targets = meta.targets });
        try providers.append(a, .{ .dep = dep, .dir = dir, .meta = meta, .verified = true });
    }
    try contract.validateOwnership(ownership.items, reserved);
    try hooks.validateAll(a, providers.items, &.{});
    const dest = try std.fs.path.join(a, &.{ root, lock_name });
    try writeAtomically(a, dest, try std.json.Stringify.valueAlloc(a, Document{ .schema_version = 1, .providers = selected.items }, .{ .whitespace = .indent_2 }));
    // The lock rename above is the commit point: from here on the accept has
    // succeeded, so nothing below may turn it into a failed exit (a failed
    // accept promises the old lock). The preview is consumed so a second
    // --accept needs a new review; if it cannot be removed, say so and keep
    // the exit status in agreement with the lock on disk (#418).
    std.debug.print("Pinned {d} provider(s) in {s}. Commit this file with labelle.lock.\n", .{ selected.items.len, lock_name });
    removePreview(a, root) catch |err| {
        std.debug.print("labelle: warning: the new pins are committed, but the consumed preview {s} could not be removed ({s}); delete it by hand before the next review\n", .{ preview_name, @errorName(err) });
    };
    // The accepted document is kept as the hint source of the no-provider
    // diagnostic (a preview stays read-only): `reviewed`, never this run's
    // raw fetch. Best effort: a failed cache write changes nothing about the pins.
    cacheRegistry(a, reviewed) catch |err| {
        std.debug.print("labelle: warning: could not cache the registry document: {s}\n", .{@errorName(err)});
    };
}

test "provider github: immutable GitHub identity and strict document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pin: Pin = .{ .package = "fixture", .repo = "owner/repo", .version = "1.0.0", .commit = "0123456789012345678901234567890123456789", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" };
    try pin.validate();
    try std.testing.expectEqualStrings("https://codeload.github.com/owner/repo/tar.gz/0123456789012345678901234567890123456789", try pin.archiveUrl(a));
    var bad = pin;
    bad.commit = "main";
    try std.testing.expectError(error.InvalidGitHubCommit, bad.validate());
    bad = pin;
    bad.repo = "../repo";
    try std.testing.expectError(error.InvalidGitHubRepository, bad.validate());
    const bytes = try std.json.Stringify.valueAlloc(a, Document{ .schema_version = 1, .providers = &.{ pin, pin } }, .{});
    try std.testing.expectError(error.DuplicateProviderRelease, parse(a, bytes, false));
    try std.testing.expectError(error.UnknownField, parse(a, "{\"schema_version\":1,\"providers\":[],\"ignored\":true}", false));
    try std.testing.expectError(error.UnsupportedProviderSchema, parse(a, "{\"schema_version\":2,\"providers\":[]}", true));
    try std.testing.expectError(error.DuplicateField, parse(a, "{\"schema_version\":1,\"schema_version\":1,\"providers\":[]}", true));
    bad = pin;
    bad.sha256 = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    try std.testing.expectError(error.InvalidArchiveHash, bad.validate());
    bad = pin;
    bad.version = "1.0.0-beta.1";
    try std.testing.expectError(error.InvalidProviderVersion, bad.validate());
    bad = pin;
    bad.version = "2.0.0";
    const versions = try std.json.Stringify.valueAlloc(a, Document{ .schema_version = 1, .providers = &.{ pin, bad } }, .{});
    _ = try parse(a, versions, false);
    try std.testing.expectError(error.DuplicateProviderRelease, parse(a, versions, true));
    try std.testing.expect(!safeArchivePath("root/../evil"));
    try std.testing.expect(!safeArchivePath("root/C:/evil"));
    try std.testing.expect(!safeArchivePath("root/evil\\escape"));
    try std.testing.expect(safeArchivePath("repo-sha/src/main.zig"));
}

/// A verified-archive fixture for other files' tests: a gzipped tarball with
/// `plugin_manifest` as its `plugin.labelle` and `build_zig` varying its
/// bytes (so each pin gets its own hash). Caller owns the result.
pub fn testProviderArchive(a: std.mem.Allocator, plugin_manifest: []const u8, build_zig: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    return a.dupe(u8, try AcceptFixture.gzipArchiveOf(arena.allocator(), plugin_manifest, build_zig));
}

/// A complete in-process resolve/accept fixture: temp project, local registry
/// file, and a verified provider archive seeded into a pinned cache root.
const AcceptFixture = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    home: []const u8,
    registry: []const u8,
    pin: Pin,

    const manifest_text = ".{ .name = \"fixture\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .namespace = \"probe\", .commands = .{ .{ .name = \"inspect\", .build_step = \"tool\", .executable = \"bin/probe\", .help = \"Inspect\" } } }";

    fn gzipArchive(a: std.mem.Allocator) ![]u8 {
        return gzipArchiveWith(a, manifest_text);
    }

    fn gzipArchiveWith(a: std.mem.Allocator, plugin_manifest: []const u8) ![]u8 {
        return gzipArchiveOf(a, plugin_manifest, "// fixture\n");
    }

    /// A valid archive with no `plugin.labelle` at all (`cachedManifest`
    /// reads it whole and returns null); `build_zig` varies the bytes so
    /// every pin verifies its own archive.
    fn gzipArchiveWithoutManifest(a: std.mem.Allocator, build_zig: []const u8) ![]u8 {
        return gzipArchiveOf(a, null, build_zig);
    }

    fn gzipArchiveOf(a: std.mem.Allocator, plugin_manifest: ?[]const u8, build_zig: []const u8) ![]u8 {
        var tar_out: std.Io.Writer.Allocating = .init(a);
        var tar: std.tar.Writer = .{ .underlying_writer = &tar_out.writer };
        try tar.setRoot("fixture-commit");
        if (plugin_manifest) |text| try tar.writeFileBytes("plugin.labelle", text, .{});
        try tar.writeFileBytes("build.zig", build_zig, .{});
        try tar.finishPedantically();
        var gz_out: std.Io.Writer.Allocating = try .initCapacity(a, 4096);
        var window: [std.compress.flate.max_window_len * 2]u8 = undefined;
        var compress = try std.compress.flate.Compress.init(&gz_out.writer, &window, .gzip, .default);
        try compress.writer.writeAll(tar_out.written());
        try compress.finish();
        return gz_out.toOwnedSlice();
    }

    fn init(a: std.mem.Allocator) !AcceptFixture {
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const base = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
        const root = try std.fs.path.join(a, &.{ base, "project" });
        const home = try std.fs.path.join(a, &.{ base, "home" });
        try tmp.dir.createDirPath(io, "project");
        try tmp.dir.createDirPath(io, "home/provider-archives");
        const data = try gzipArchive(a);
        const pin: Pin = .{ .package = "fixture", .repo = "example/fixture", .version = "1.0.0", .commit = "1" ** 40, .sha256 = try sha256Hex(a, data) };
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "home/provider-archives/{s}.tar.gz", .{pin.sha256}), .data = data });
        try tmp.dir.writeFile(io, .{ .sub_path = "project/project.labelle", .data = ".{ .name = \"game\", .plugins = .{ .{ .name = \"fixture\", .repo = \"example/fixture\", .version = \"1.0.0\" } } }" });
        var self: AcceptFixture = .{ .tmp = tmp, .root = root, .home = home, .registry = try std.fs.path.join(a, &.{ base, "providers.json" }), .pin = pin };
        try self.publish(a, pin);
        cache.setCacheRootOverride(home);
        return self;
    }

    fn deinit(self: *AcceptFixture) void {
        cache.clearCacheRootOverride();
        self.tmp.cleanup();
    }

    fn publish(self: *AcceptFixture, a: std.mem.Allocator, pin: Pin) !void {
        const data = try std.json.Stringify.valueAlloc(a, Document{ .schema_version = 1, .providers = &.{pin} }, .{});
        try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = self.registry, .data = data });
    }

    /// A schema-2 registry (#411) listing `pin` with the given ownership
    /// claims, as JSON fragments (`"probe"` or `null`; `"t1","t2"`).
    fn schemaTwo(a: std.mem.Allocator, pin: Pin, namespace: []const u8, targets: []const u8) ![]const u8 {
        return std.fmt.allocPrint(a, "{{\"schema_version\":2,\"defaults\":[],\"providers\":[{{\"package\":\"{s}\",\"repo\":\"{s}\",\"version\":\"{s}\",\"commit\":\"{s}\",\"sha256\":\"{s}\",\"namespace\":{s},\"targets\":[{s}]}}]}}", .{ pin.package, pin.repo, pin.version, pin.commit, pin.sha256, namespace, targets });
    }

    fn publishSchemaTwo(self: *AcceptFixture, a: std.mem.Allocator, namespace: []const u8, targets: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = self.registry, .data = try schemaTwo(a, self.pin, namespace, targets) });
    }

    fn publishRaw(self: *AcceptFixture, bytes: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = self.registry, .data = bytes });
    }

    fn run(self: *AcceptFixture, a: std.mem.Allocator, accept: bool) !void {
        return resolve(a, self.root, self.registry, accept, true, &.{});
    }

    fn exists(self: *AcceptFixture, a: std.mem.Allocator, name: []const u8) !bool {
        std.Io.Dir.cwd().access(config.globalIo(), try std.fs.path.join(a, &.{ self.root, name }), .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }
};

test "provider github: accept is bound to the recorded preview" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    // (c) Nothing reviewed yet: accept fails closed before touching the registry or the lock.
    try std.testing.expectError(error.ProviderPreviewMissing, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    // Preview records exactly what was shown, with a digest that verifies on load.
    try fx.run(a, false);
    try std.testing.expect(try fx.exists(a, preview_name));
    try std.testing.expect(!try fx.exists(a, lock_name));
    const preview = try loadPreview(a, fx.root);
    try std.testing.expectEqual(@as(usize, 1), preview.providers.len);
    try std.testing.expectEqualStrings(fx.pin.commit, preview.providers[0].commit);
    try std.testing.expectEqualStrings(fx.pin.sha256, preview.providers[0].sha256);
    try std.testing.expectEqualStrings(try fx.pin.archiveUrl(a), preview.providers[0].archive_url);
    try std.testing.expectEqualStrings(fx.registry, preview.source);
    try std.testing.expectEqualStrings(try previewDigest(a, preview.body()), preview.digest);
    // (b) The registry is repointed between preview and accept: the changed
    // field is rejected by name, the lock is never written, and the stale
    // preview stays so the diagnostic can be compared against it.
    var repointed = fx.pin;
    repointed.commit = "2" ** 40;
    try fx.publish(a, repointed);
    try std.testing.expectError(error.ProviderPreviewMismatch, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    var rehashed = fx.pin;
    rehashed.sha256 = "0" ** 64;
    try fx.publish(a, rehashed);
    try std.testing.expectError(error.ProviderPreviewMismatch, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    try std.testing.expect(try fx.exists(a, preview_name));
    // (a) The registry serves the reviewed record again: accept pins it,
    // verifying the archive against the previewed hash, and consumes the preview.
    try fx.publish(a, fx.pin);
    try fx.run(a, true);
    const lock = try parse(a, try read(a, try std.fs.path.join(a, &.{ fx.root, lock_name }), 1024 * 1024), true);
    try std.testing.expectEqual(@as(usize, 1), lock.providers.len);
    try std.testing.expectEqualStrings(fx.pin.commit, lock.providers[0].commit);
    try std.testing.expectEqualStrings(fx.pin.sha256, lock.providers[0].sha256);
    try std.testing.expect(!try fx.exists(a, preview_name));
    // A consumed preview cannot be accepted twice.
    try std.testing.expectError(error.ProviderPreviewMissing, fx.run(a, true));
}

test "provider github: accept is bound to the whole registry document, not only the selected pins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    const fixture_record = try std.fmt.allocPrint(a, "{{\"package\":\"fixture\",\"repo\":\"{s}\",\"version\":\"{s}\",\"commit\":\"{s}\",\"sha256\":\"{s}\",\"namespace\":\"probe\",\"targets\":[]}}", .{ fx.pin.repo, fx.pin.version, fx.pin.commit, fx.pin.sha256 });
    const other_record = "{\"package\":\"other\",\"repo\":\"example/other\",\"version\":\"1.0.0\",\"commit\":\"" ++ "3" ** 40 ++ "\",\"sha256\":\"" ++ "0" ** 64 ++ "\",\"namespace\":null,\"targets\":[\"TARGET\"]}";
    const Doc = struct {
        fn of(al: std.mem.Allocator, fixture: []const u8, other_target: []const u8, defaults: []const u8, sep: []const u8) ![]const u8 {
            const other = try std.mem.replaceOwned(u8, al, other_record, "TARGET", other_target);
            return std.fmt.allocPrint(al, "{{\"schema_version\":2,{s}\"defaults\":[{s}],{s}\"providers\":[{s},{s}{s}]}}", .{ sep, defaults, sep, fixture, sep, other });
        }
    };
    // (1) Schema 2 swapped for an otherwise identical schema 1: same pins,
    // but the declaration check would become a no-op. Rejected.
    try fx.publishSchemaTwo(a, "\"probe\"", "");
    try fx.run(a, false);
    try fx.publish(a, fx.pin);
    try std.testing.expectError(error.ProviderPreviewMismatch, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    // (2) A selected record's ownership claim changes. Mechanism: the
    // reviewed claim (`null`) is false and the served one is true, so the
    // declaration check alone would pin it; only the preview binding refuses.
    try fx.publishSchemaTwo(a, "null", "");
    try fx.run(a, false);
    try fx.publishSchemaTwo(a, "\"probe\"", "");
    try std.testing.expectError(error.ProviderPreviewMismatch, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    // (3) An unselected record's claim changes: only the document digest sees it.
    try fx.publishRaw(try Doc.of(a, fixture_record, "other-target", "", ""));
    try fx.run(a, false);
    try fx.publishRaw(try Doc.of(a, fixture_record, "moved-target", "", ""));
    try std.testing.expectError(error.ProviderPreviewMismatch, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    // (4) The defaults list changes.
    try fx.publishRaw(try Doc.of(a, fixture_record, "other-target", "", ""));
    try fx.run(a, false);
    try fx.publishRaw(try Doc.of(a, fixture_record, "other-target", "{\"package\":\"fixture\",\"version\":\"1.0.0\"}", ""));
    try std.testing.expectError(error.ProviderPreviewMismatch, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    // (5) The same document with other whitespace is the same normalised
    // document: accepted. The target-hint cache then holds exactly the
    // reviewed document (its bytes hash to the preview's registry digest).
    try fx.publishRaw(try Doc.of(a, fixture_record, "other-target", "", ""));
    try fx.run(a, false);
    const reviewed = try loadPreview(a, fx.root);
    try std.testing.expectEqual(@as(u8, 2), reviewed.registry_schema);
    try std.testing.expectEqualStrings("probe", reviewed.providers[0].namespace.?);
    try fx.publishRaw(try Doc.of(a, fixture_record, "other-target", "", "\n  "));
    try fx.run(a, true);
    try std.testing.expect(try fx.exists(a, lock_name));
    const cached = try read(a, try std.fs.path.join(a, &.{ fx.home, registry_cache_dir, registry_cache_file }), 1024 * 1024);
    try std.testing.expectEqualStrings(reviewed.registry_digest, try sha256Hex(a, cached));
    try std.testing.expectEqualStrings("other", cachedRegistryOwner(a, "other-target").?);
}

test "provider github: accept stays committed when the consumed preview cannot be removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    const lock_path = try std.fs.path.join(a, &.{ fx.root, lock_name });
    const old_lock = "{\"schema_version\":1,\"providers\":[]}";
    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = lock_path, .data = old_lock });
    try fx.run(a, false);
    fail_preview_removal_for_test = true;
    defer fail_preview_removal_for_test = false;
    // The delete fails after the lock rename: the accept still succeeds, and
    // the lock on disk is the new one, so exit status and lock state agree.
    try fx.run(a, true);
    const lock = try parse(a, try read(a, lock_path, 1024 * 1024), true);
    try std.testing.expectEqual(@as(usize, 1), lock.providers.len);
    try std.testing.expectEqualStrings(fx.pin.sha256, lock.providers[0].sha256);
    // The fault really ran: the preview the accept could not consume is still there.
    try std.testing.expect(try fx.exists(a, preview_name));
    // Mechanism check: with the fault lifted the same path removes it.
    fail_preview_removal_for_test = false;
    try fx.run(a, true);
    try std.testing.expect(!try fx.exists(a, preview_name));
}

test "provider github: an edited preview file fails its digest and is not accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    try fx.run(a, false);
    const path = try std.fs.path.join(a, &.{ fx.root, preview_name });
    const original = try read(a, path, 1024 * 1024);
    // Same shape, one hex digit of the reviewed commit changed: the digest no longer verifies.
    const edited = try std.mem.replaceOwned(u8, a, original, fx.pin.commit, "2" ** 40);
    try std.testing.expect(!std.mem.eql(u8, original, edited));
    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = path, .data = edited });
    try std.testing.expectError(error.ProviderPreviewCorrupt, loadPreview(a, fx.root));
    try std.testing.expectError(error.ProviderPreviewCorrupt, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = path, .data = "{ not json" });
    try std.testing.expectError(error.ProviderPreviewCorrupt, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
}

test "provider github: the cached registry names a target owner only from a verified cached archive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    // No cached document: no hint, whatever the archives hold.
    try std.testing.expect(cachedRegistryOwner(a, "probe-target") == null);
    // A second release of the package whose manifest declares the target.
    const declaring = ".{ .name = \"fixture\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{ \"probe-target\" } }";
    const data = try AcceptFixture.gzipArchiveWith(a, declaring);
    var pin = fx.pin;
    pin.version = "1.1.0";
    pin.sha256 = try sha256Hex(a, data);
    try cacheRegistry(a, try std.json.Stringify.valueAlloc(a, Document{ .schema_version = 1, .providers = &.{ fx.pin, pin } }, .{}));
    // The document lists the package, but the record carries no targets and
    // the declaring archive is not cached: still no hint.
    try std.testing.expect(cachedRegistryOwner(a, "probe-target") == null);
    const archive_path = try archivePath(a, pin);
    try cwd.writeFile(io, .{ .sub_path = archive_path, .data = data });
    try std.testing.expectEqualStrings("fixture", cachedRegistryOwner(a, "probe-target").?);
    try std.testing.expect(cachedRegistryOwner(a, "other-target") == null);
    // Bytes that do not verify against the pin say nothing.
    try cwd.writeFile(io, .{ .sub_path = archive_path, .data = "not the archive" });
    try std.testing.expect(cachedRegistryOwner(a, "probe-target") == null);
}

test "provider github: accept refuses a schema-2 record whose claims the verified manifest contradicts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    // The fixture manifest declares namespace `probe` and no target; the
    // record claims a target it does not declare. The archive verifies, so
    // only the claim check can refuse it, and it does before the lock exists.
    try fx.publishSchemaTwo(a, "\"probe\"", "\"probe-target\"");
    try fx.run(a, false);
    try std.testing.expectError(error.RegistryDeclarationMismatch, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    try fx.publishSchemaTwo(a, "null", "");
    try fx.run(a, false);
    try std.testing.expectError(error.RegistryDeclarationMismatch, fx.run(a, true));
    try std.testing.expect(!try fx.exists(a, lock_name));
    // Truthful claims pin, and the accepted schema-2 document is the hint source.
    try fx.publishSchemaTwo(a, "\"probe\"", "");
    try fx.run(a, false);
    try fx.run(a, true);
    const lock = try parse(a, try read(a, try std.fs.path.join(a, &.{ fx.root, lock_name }), 1024 * 1024), true);
    try std.testing.expectEqual(@as(usize, 1), lock.providers.len);
    try std.testing.expectEqual(@as(u8, 1), lock.schema_version);
}

test "provider github: a schema-2 cached registry names a target owner by lookup, reading no archive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    // Remove the only cached archive: a hint can now come only from the table.
    try std.Io.Dir.cwd().deleteFile(config.globalIo(), try archivePath(a, fx.pin));
    try cacheRegistry(a, try AcceptFixture.schemaTwo(a, fx.pin, "\"probe\"", "\"probe-target\""));
    try std.testing.expectEqualStrings("fixture", cachedRegistryOwner(a, "probe-target").?);
    try std.testing.expect(cachedRegistryOwner(a, "other-target") == null);
    // Mechanism: the same release as a schema-1 document has no claims, and
    // with its archive gone the scan has nothing to read, so no hint.
    try cacheRegistry(a, try std.json.Stringify.valueAlloc(a, Document{ .schema_version = 1, .providers = &.{fx.pin} }, .{}));
    try std.testing.expect(cachedRegistryOwner(a, "probe-target") == null);
}

test "provider github: the registry-hint scan reads a bounded number of cached releases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    // `limit` cached releases that do not declare the target, then the one
    // that does; every archive differs so every pin verifies its own bytes.
    var pins: std.ArrayList(Pin) = .empty;
    var i: usize = 0;
    while (i < registry_hint_scan_limit) : (i += 1) {
        const text = try std.fmt.allocPrint(a, ".{{ .name = \"fixture\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{{ \"other-{d}\" }} }}", .{i});
        const data = try AcceptFixture.gzipArchiveWith(a, text);
        var pin = fx.pin;
        pin.version = try std.fmt.allocPrint(a, "1.{d}.0", .{i});
        pin.sha256 = try sha256Hex(a, data);
        try cwd.writeFile(io, .{ .sub_path = try archivePath(a, pin), .data = data });
        try pins.append(a, pin);
    }
    const declaring = ".{ .name = \"fixture\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{ \"probe-target\" } }";
    const data = try AcceptFixture.gzipArchiveWith(a, declaring);
    var owner = fx.pin;
    owner.version = "9.0.0";
    owner.sha256 = try sha256Hex(a, data);
    try cwd.writeFile(io, .{ .sub_path = try archivePath(a, owner), .data = data });
    // An uncached release costs nothing and is not counted against the bound.
    var uncached = fx.pin;
    uncached.version = "8.0.0";
    uncached.sha256 = "0" ** 64;
    try pins.append(a, uncached);
    try pins.append(a, owner);
    try cacheRegistry(a, try std.json.Stringify.valueAlloc(a, Document{ .schema_version = 1, .providers = pins.items }, .{}));
    // Beyond the bound: the owner is never read, so there is no hint.
    try std.testing.expect(cachedRegistryOwner(a, "probe-target") == null);
    // Within it (one decoy fewer), the same document names the owner.
    const trimmed = try std.mem.concat(a, Pin, &.{ pins.items[1..registry_hint_scan_limit], pins.items[registry_hint_scan_limit..] });
    try cacheRegistry(a, try std.json.Stringify.valueAlloc(a, Document{ .schema_version = 1, .providers = trimmed }, .{}));
    try std.testing.expectEqualStrings("fixture", cachedRegistryOwner(a, "probe-target").?);
    try std.testing.expectEqualStrings("fixture", cachedRegistryOwner(a, "other-1").?);
}

test "provider github: the registry-hint scan counts manifest-less cached releases against its bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    // `limit` cached releases that verify but carry no `plugin.labelle`:
    // each is read, verified and decompressed whole before the scan learns
    // it has nothing to say, so each costs one of the bounded reads.
    var pins: std.ArrayList(Pin) = .empty;
    var i: usize = 0;
    while (i < registry_hint_scan_limit) : (i += 1) {
        const data = try AcceptFixture.gzipArchiveWithoutManifest(a, try std.fmt.allocPrint(a, "// no manifest {d}\n", .{i}));
        var pin = fx.pin;
        pin.version = try std.fmt.allocPrint(a, "1.{d}.0", .{i});
        pin.sha256 = try sha256Hex(a, data);
        try cwd.writeFile(io, .{ .sub_path = try archivePath(a, pin), .data = data });
        try pins.append(a, pin);
    }
    const declaring = ".{ .name = \"fixture\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{ \"probe-target\" } }";
    const data = try AcceptFixture.gzipArchiveWith(a, declaring);
    var owner = fx.pin;
    owner.version = "9.0.0";
    owner.sha256 = try sha256Hex(a, data);
    try cwd.writeFile(io, .{ .sub_path = try archivePath(a, owner), .data = data });
    try pins.append(a, owner);
    try cacheRegistry(a, try std.json.Stringify.valueAlloc(a, Document{ .schema_version = 1, .providers = pins.items }, .{}));
    // The bound is spent on the manifest-less releases: the owner behind
    // them is never read. (Skipping them uncounted would read it and name it.)
    try std.testing.expect(cachedRegistryOwner(a, "probe-target") == null);
    // One manifest-less release fewer and the owner is the last read within
    // the bound: each manifest-less archive cost exactly one read.
    try cacheRegistry(a, try std.json.Stringify.valueAlloc(a, Document{ .schema_version = 1, .providers = pins.items[1..] }, .{}));
    try std.testing.expectEqualStrings("fixture", cachedRegistryOwner(a, "probe-target").?);
}

fn testArchive(a: std.mem.Allocator, file: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var tar: std.tar.Writer = .{ .underlying_writer = &aw.writer };
    try tar.setRoot("repo-sha");
    try tar.writeFileBytes("plugin.labelle", "", .{});
    try tar.writeFileBytes(file, "", .{});
    try tar.finishPedantically();
    return aw.toOwnedSlice();
}

test "provider github: non-ASCII archive paths are rejected by their own rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The ASCII twin passes every other check, so only the byte range differs.
    try validateTar(a, try testArchive(a, "src/a.zig"));
    try std.testing.expectError(error.NonAsciiProviderArchivePath, validateTar(a, try testArchive(a, "src/ä.zig")));
    try std.testing.expectError(error.NonAsciiProviderArchivePath, validateTar(a, try testArchive(a, "src/Ä.zig")));
}

test "provider github: control characters in archive paths are rejected by their own rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The printable twin passes, so only the control byte differs.
    try validateTar(a, try testArchive(a, "src/a-b.zig"));
    try std.testing.expectError(error.ControlCharProviderArchivePath, validateTar(a, try testArchive(a, "src/a\x01b.zig")));
    try std.testing.expectError(error.ControlCharProviderArchivePath, validateTar(a, try testArchive(a, "src/a\x1fb.zig")));
    try std.testing.expectError(error.ControlCharProviderArchivePath, validateTar(a, try testArchive(a, "src/a\x7fb.zig")));
    try std.testing.expectError(error.ControlCharProviderArchivePath, validateTar(a, try testArchive(a, "src\n/b.zig")));
}

test "provider github: Windows reserved device names are rejected by their own rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Each twin differs from a reserved name by one letter, so it passes every other check.
    try validateTar(a, try testArchive(a, "src/null.zig"));
    try validateTar(a, try testArchive(a, "src/cons.zig"));
    try validateTar(a, try testArchive(a, "src/COMA"));
    try validateTar(a, try testArchive(a, "src/lpt.txt"));
    try validateTar(a, try testArchive(a, "src/conout/a.zig"));
    try std.testing.expectError(error.ReservedProviderArchiveName, validateTar(a, try testArchive(a, "src/nul.zig")));
    try std.testing.expectError(error.ReservedProviderArchiveName, validateTar(a, try testArchive(a, "src/NUL")));
    try std.testing.expectError(error.ReservedProviderArchiveName, validateTar(a, try testArchive(a, "src/Con.tar.gz")));
    try std.testing.expectError(error.ReservedProviderArchiveName, validateTar(a, try testArchive(a, "src/prn")));
    try std.testing.expectError(error.ReservedProviderArchiveName, validateTar(a, try testArchive(a, "src/aux.h")));
    try std.testing.expectError(error.ReservedProviderArchiveName, validateTar(a, try testArchive(a, "src/COM1")));
    try std.testing.expectError(error.ReservedProviderArchiveName, validateTar(a, try testArchive(a, "src/com9.zig")));
    try std.testing.expectError(error.ReservedProviderArchiveName, validateTar(a, try testArchive(a, "src/Lpt1")));
    try std.testing.expectError(error.ReservedProviderArchiveName, validateTar(a, try testArchive(a, "src/lpt9.txt")));
    try std.testing.expectError(error.ReservedProviderArchiveName, validateTar(a, try testArchive(a, "src/CONIN$")));
    try std.testing.expectError(error.ReservedProviderArchiveName, validateTar(a, try testArchive(a, "src/conout$.zig")));
    // Directory components count too.
    try std.testing.expectError(error.ReservedProviderArchiveName, validateTar(a, try testArchive(a, "src/aux/a.zig")));
}

fn testArchiveOf(a: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var tar: std.tar.Writer = .{ .underlying_writer = &aw.writer };
    try tar.setRoot("repo-sha");
    try tar.writeFileBytes("plugin.labelle", "", .{});
    for (paths) |path| try tar.writeFileBytes(path, "", .{});
    try tar.finishPedantically();
    return aw.toOwnedSlice();
}

test "provider github: case-folded file/directory conflicts are rejected by their own rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // ASCII twins: a file whose folded name is not a folded ancestor passes,
    // including a sibling that shares a prefix but not a path component.
    try validateTar(a, try testArchiveOf(a, &.{ "Foo.zig", "foo/bar.zig" }));
    try validateTar(a, try testArchiveOf(a, &.{ "foo/bar.zig", "Foox" }));
    try validateTar(a, try testArchiveOf(a, &.{ "src/a.zig", "SRC/b.zig" }));
    // Either order, and at any depth.
    try std.testing.expectError(error.CaseFoldedProviderArchiveFileDirConflict, validateTar(a, try testArchiveOf(a, &.{ "Foo", "foo/bar.zig" })));
    try std.testing.expectError(error.CaseFoldedProviderArchiveFileDirConflict, validateTar(a, try testArchiveOf(a, &.{ "foo/bar.zig", "Foo" })));
    try std.testing.expectError(error.CaseFoldedProviderArchiveFileDirConflict, validateTar(a, try testArchiveOf(a, &.{ "src/Lib", "SRC/lib/deep/x.zig" })));
    try std.testing.expectError(error.CaseFoldedProviderArchiveFileDirConflict, validateTar(a, try testArchiveOf(a, &.{ "src/lib/deep/x.zig", "Src/LIB" })));
    // Same case is a conflict on every host, so it gets the same rule.
    try std.testing.expectError(error.CaseFoldedProviderArchiveFileDirConflict, validateTar(a, try testArchiveOf(a, &.{ "foo", "foo/bar.zig" })));
}
