//! Per-invocation provider source extractions (`Sources`) and the cache that
//! shares them across the rebuilds of one long-lived invocation (`Extractions`).
const std = @import("std");
const config = @import("../config.zig");
const project = @import("../project_config.zig");
const manifest = @import("../provider_manifest.zig");
const github = @import("../provider_github.zig");
const pin_mod = @import("pin.zig");
const Pin = pin_mod.Pin;
const lock_name = pin_mod.lock_name;
const parse = pin_mod.parse;
const files = @import("files.zig");
const read = files.read;
const cacheRoot = files.cacheRoot;
const uniqueName = files.uniqueName;
const archive_mod = @import("archive.zig");
const archive = archive_mod.archive;
const validateTar = archive_mod.validateTar;

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
        github.extraction_count +%= 1;
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
