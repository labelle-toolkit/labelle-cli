//! GitHub metadata + a project pin file. No registry service or implicit updates.
const std = @import("std");
const config = @import("config.zig");
const project = @import("project_config.zig");
const cache = @import("asm_cache.zig");
const manifest = @import("provider_manifest.zig");
const contract = @import("provider_contract.zig");
const util = @import("util.zig");

pub const lock_name = "labelle.providers.lock";
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
        const stem = part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len];
        for ([_][]const u8{ "con", "prn", "aux", "nul" }) |device| {
            if (std.ascii.eqlIgnoreCase(stem, device)) return false;
        }
        if (stem.len == 4 and (std.ascii.eqlIgnoreCase(stem[0..3], "com") or std.ascii.eqlIgnoreCase(stem[0..3], "lpt")) and stem[3] >= '1' and stem[3] <= '9') return false;
    }
    return true;
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
        // The duplicate check below folds ASCII case only; case-insensitive
        // hosts also fold non-ASCII letters, so such paths are not portable.
        for (entry.name) |c| if (!std.ascii.isAscii(c)) {
            std.debug.print("provider archive entry '{s}' contains non-ASCII bytes; archive paths must be ASCII\n", .{entry.name});
            return error.NonAsciiProviderArchivePath;
        };
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

/// Resolve only explicitly declared project versions. Preview is read-only;
/// --accept fetches/verifies metadata and sources, but runs no package code.
pub fn resolve(a: std.mem.Allocator, root: []const u8, source: []const u8, accept: bool, offline: bool, reserved: []const []const u8) !void {
    const io = config.globalIo();
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
            std.debug.print("  {s} {s}: {s}@{s}\n    sha256 {s}\n", .{ pin.package, pin.version, pin.repo, pin.commit, pin.sha256 });
        }
        if (known and !found) return error.ProviderReleaseNotInRegistry;
    }
    if (!accept) {
        std.debug.print("Preview: {d} provider pin(s). Repeat with --accept to verify archives and write {s}.\n", .{ selected.items.len, lock_name });
        return;
    }
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
    const temp = try uniqueName(a, dest);
    defer std.Io.Dir.cwd().deleteFile(io, temp) catch {};
    const data = try std.json.Stringify.valueAlloc(a, Document{ .schema_version = 1, .providers = selected.items }, .{ .whitespace = .indent_2 });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = temp, .data = data });
    try std.Io.Dir.renameAbsolute(temp, dest, io);
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
