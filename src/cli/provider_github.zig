//! GitHub metadata + a project pin file. No registry service or implicit updates.
const std = @import("std");
const config = @import("config.zig");
const project = @import("project_config.zig");
const cache = @import("asm_cache.zig");
const manifest = @import("provider_manifest.zig");
const contract = @import("provider_contract.zig");
const util = @import("util.zig");

pub const lock_name = "labelle.providers.lock";
/// Project-local record of the last `resolve` preview. `--accept` refuses to
/// pin anything that differs from it (Codex P1 on #414: a registry repointed
/// between preview and accept must not cross the consent boundary).
pub const preview_name = ".labelle/providers.preview.json";
pub const registry_url = "https://raw.githubusercontent.com/labelle-toolkit/labelle-registry/main/providers.json";
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

/// Both registry and lock have the same small schema; locks allow one pin/package.
pub fn parse(a: std.mem.Allocator, bytes: []const u8, is_lock: bool) !Document {
    const parsed = try std.json.parseFromSlice(Document, a, bytes, .{ .allocate = .alloc_always });
    // The caller owns an arena; successful parsed strings live through invocation.
    const doc = parsed.value;
    if (doc.schema_version != 1) return error.UnsupportedProviderSchema;
    for (doc.providers, 0..) |pin, i| {
        try pin.validate();
        for (doc.providers[0..i]) |prev| {
            if (std.mem.eql(u8, pin.package, prev.package)) {
                if (!std.mem.eql(u8, pin.repo, prev.repo)) return error.ProviderRepositoryConflict;
                if (is_lock or std.mem.eql(u8, pin.version, prev.version)) return error.DuplicateProviderRelease;
            }
        }
    }
    return doc;
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
pub const Sources = struct {
    a: std.mem.Allocator,
    directories: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Sources) void {
        for (self.directories.items) |path| std.Io.Dir.cwd().deleteTree(config.globalIo(), path) catch |err| {
            std.debug.print("labelle: could not remove provider source '{s}': {s}\n", .{ path, @errorName(err) });
        };
        self.directories.deinit(self.a);
    }

    pub fn fromPin(self: *Sources, pin: Pin, allow_download: bool) ![]const u8 {
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
        const meta = try manifest.parse(self.a, try read(self.a, try std.fs.path.join(self.a, &.{ path, "plugin.labelle" }), 1024 * 1024));
        if (!meta.isProvider() or !std.mem.eql(u8, meta.name, pin.package)) return error.ProviderNameMismatch;
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

fn safeArchivePath(path: []const u8) bool {
    if (path.len == 0 or std.mem.indexOfAny(u8, path, "\\:\x00<>\"|?*") != null) return false;
    var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, path, "/"), '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or
            std.mem.endsWith(u8, part, ".") or std.mem.endsWith(u8, part, " ")) return false;
    }
    return true;
}

/// Windows cannot create these names in any directory, case-insensitively and
/// regardless of extension (`nul.zig` is still the NUL device), so an archive
/// containing one extracts on Unix but fails on Windows.
fn reservedDeviceName(part: []const u8) bool {
    const stem = part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len];
    for ([_][]const u8{ "con", "prn", "aux", "nul", "conin$", "conout$" }) |device| {
        if (std.ascii.eqlIgnoreCase(stem, device)) return true;
    }
    return stem.len == 4 and (std.ascii.eqlIgnoreCase(stem[0..3], "com") or std.ascii.eqlIgnoreCase(stem[0..3], "lpt")) and stem[3] >= '1' and stem[3] <= '9';
}

fn hasReservedDeviceName(path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, std.mem.trimEnd(u8, path, "/"), '/');
    while (parts.next()) |part| if (reservedDeviceName(part)) return true;
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
    }
    if (root == null) return error.EmptyProviderArchive;
}

/// One previewed pin: every field the user was shown, including the derived
/// archive URL, so a later accept can be checked against exactly that.
pub const PreviewEntry = struct {
    package: []const u8,
    repo: []const u8,
    version: []const u8,
    commit: []const u8,
    sha256: []const u8,
    archive_url: []const u8,

    fn fromPin(a: std.mem.Allocator, pin: Pin) !PreviewEntry {
        return .{ .package = pin.package, .repo = pin.repo, .version = pin.version, .commit = pin.commit, .sha256 = pin.sha256, .archive_url = try pin.archiveUrl(a) };
    }

    fn toPin(self: PreviewEntry) Pin {
        return .{ .package = self.package, .repo = self.repo, .version = self.version, .commit = self.commit, .sha256 = self.sha256 };
    }
};

/// Persisted by a preview, consumed (and removed) by a successful accept.
pub const Preview = struct {
    schema_version: u8,
    source: []const u8,
    digest: []const u8,
    providers: []const PreviewEntry,
};

fn sha256Hex(a: std.mem.Allocator, data: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

/// SHA-256 over the canonical JSON of the registry source and every shown
/// field. Recomputed on load, so an edited preview file is caught too.
pub fn previewDigest(a: std.mem.Allocator, source: []const u8, entries: []const PreviewEntry) ![]const u8 {
    return sha256Hex(a, try std.json.Stringify.valueAlloc(a, .{ .source = source, .providers = entries }, .{}));
}

fn previewEntries(a: std.mem.Allocator, pins: []const Pin) ![]const PreviewEntry {
    const entries = try a.alloc(PreviewEntry, pins.len);
    for (pins, 0..) |pin, i| entries[i] = try PreviewEntry.fromPin(a, pin);
    return entries;
}

fn writeAtomically(a: std.mem.Allocator, dest: []const u8, data: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const temp = try uniqueName(a, dest);
    defer cwd.deleteFile(io, temp) catch {};
    try cwd.writeFile(io, .{ .sub_path = temp, .data = data });
    try std.Io.Dir.renameAbsolute(temp, dest, io);
}

pub fn writePreview(a: std.mem.Allocator, root: []const u8, source: []const u8, pins: []const Pin) ![]const u8 {
    const entries = try previewEntries(a, pins);
    const digest = try previewDigest(a, source, entries);
    const dest = try std.fs.path.join(a, &.{ root, preview_name });
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), std.fs.path.dirname(dest).?);
    const preview: Preview = .{ .schema_version = 1, .source = source, .digest = digest, .providers = entries };
    try writeAtomically(a, dest, try std.json.Stringify.valueAlloc(a, preview, .{ .whitespace = .indent_2 }));
    return digest;
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
    if (preview.schema_version != 1) return error.ProviderPreviewCorrupt;
    for (preview.providers) |entry| {
        const pin = entry.toPin();
        pin.validate() catch return error.ProviderPreviewCorrupt;
        if (!std.mem.eql(u8, entry.archive_url, try pin.archiveUrl(a))) return error.ProviderPreviewCorrupt;
    }
    if (!std.mem.eql(u8, preview.digest, try previewDigest(a, preview.source, preview.providers))) {
        std.debug.print("labelle: provider preview {s} does not match its digest; run 'labelle providers resolve' again\n", .{preview_name});
        return error.ProviderPreviewCorrupt;
    }
    return preview;
}

fn reportChange(package: []const u8, field: []const u8, previewed: []const u8, now: []const u8) void {
    std.debug.print("labelle: provider '{s}' {s} changed since preview: {s} -> {s}\n", .{ package, field, previewed, now });
}

/// Every field the user reviewed must equal what the registry serves now.
/// Any difference names the package and field(s) and aborts the accept.
pub fn checkPreview(a: std.mem.Allocator, preview: Preview, source: []const u8, pins: []const Pin) !void {
    var changed = false;
    if (!std.mem.eql(u8, preview.source, source)) {
        std.debug.print("labelle: registry source changed since preview: {s} -> {s}\n", .{ preview.source, source });
        changed = true;
    }
    const fresh = try previewEntries(a, pins);
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
    if (changed) {
        std.debug.print("labelle: refusing --accept: the registry no longer matches the reviewed preview. Run 'labelle providers resolve' again and review the new pins.\n", .{});
        return error.ProviderPreviewMismatch;
    }
}

fn removePreview(a: std.mem.Allocator, root: []const u8) !void {
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
    const doc = try parse(a, metadata, false);
    const cfg = try config.readProjectConfigQuiet(a, root);
    var selected: std.ArrayList(Pin) = .empty;
    for (cfg.plugins, 0..) |dep, i| {
        for (cfg.plugins[0..i]) |prev| if (std.mem.eql(u8, dep.name, prev.name)) return error.DuplicateProjectPlugin;
        if (dep.isLocal()) continue;
        var known = false;
        var found = false;
        for (doc.providers) |pin| {
            if (!std.mem.eql(u8, pin.package, dep.name)) continue;
            known = true;
            if (!pin.matches(dep)) continue;
            try selected.append(a, pin);
            found = true;
            std.debug.print("  {s} {s}: {s}@{s}\n    sha256 {s}\n    {s}\n", .{ pin.package, pin.version, pin.repo, pin.commit, pin.sha256, try pin.archiveUrl(a) });
        }
        if (known and !found) return error.ProviderReleaseNotInRegistry;
    }
    if (!accept) {
        const digest = try writePreview(a, root, source, selected.items);
        std.debug.print("Preview: {d} provider pin(s), digest {s}, recorded in {s}.\nRepeat with --accept to verify archives and write {s}; accept refuses any pin that differs from this preview.\n", .{ selected.items.len, digest, preview_name, lock_name });
        return;
    }
    // Acceptance is bound to the reviewed record: the fresh fetch may only
    // confirm it, and the pins prepared below are the previewed ones.
    try checkPreview(a, preview.?, source, selected.items);
    selected.clearRetainingCapacity();
    for (preview.?.providers) |entry| try selected.append(a, entry.toPin());
    std.debug.print("Accepting preview digest {s}.\n", .{preview.?.digest});
    var sources: Sources = .{ .a = a };
    defer sources.deinit();
    var ownership: std.ArrayList(contract.Ownership) = .empty;
    for (selected.items) |pin| {
        const dir = try sources.fromPin(pin, !offline);
        const meta = try manifest.parse(a, try read(a, try std.fs.path.join(a, &.{ dir, "plugin.labelle" }), 1024 * 1024));
        const ns = try a.alloc([]const u8, if (meta.namespace != null) 1 else 0);
        if (meta.namespace) |value| ns[0] = value;
        try ownership.append(a, .{ .package = pin.package, .namespaces = ns, .targets = meta.targets });
    }
    // Include local owners before changing pins, even though they need no archive.
    for (cfg.plugins) |dep| {
        if (!dep.isLocal()) continue;
        const path = try std.fs.path.resolve(a, &.{ root, dep.localPath(), "plugin.labelle" });
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
    }
    try contract.validateOwnership(ownership.items, reserved);
    const dest = try std.fs.path.join(a, &.{ root, lock_name });
    try writeAtomically(a, dest, try std.json.Stringify.valueAlloc(a, Document{ .schema_version = 1, .providers = selected.items }, .{ .whitespace = .indent_2 }));
    // The preview is consumed: a second --accept must be preceded by a new review.
    try removePreview(a, root);
    std.debug.print("Pinned {d} provider(s) in {s}. Commit this file with labelle.lock.\n", .{ selected.items.len, lock_name });
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
        var tar_out: std.Io.Writer.Allocating = .init(a);
        var tar: std.tar.Writer = .{ .underlying_writer = &tar_out.writer };
        try tar.setRoot("fixture-commit");
        try tar.writeFileBytes("plugin.labelle", manifest_text, .{});
        try tar.writeFileBytes("build.zig", "// fixture\n", .{});
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
    try std.testing.expectEqualStrings(try previewDigest(a, fx.registry, preview.providers), preview.digest);
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
