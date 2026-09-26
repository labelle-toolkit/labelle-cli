//! Verified archive download and cache reads, tar validation (one root,
//! portable ASCII paths, no device names, no case-folded collisions) and the
//! read-only manifest lookup inside a cached archive.
const std = @import("std");
const config = @import("../config.zig");
const manifest = @import("../provider_manifest.zig");
const contract = @import("../provider_contract.zig");
const util = @import("../util.zig");
const Pin = @import("pin.zig").Pin;
const files_mod = @import("files.zig");
const read = files_mod.read;
const cacheRoot = files_mod.cacheRoot;
const uniqueName = files_mod.uniqueName;

pub fn archivePath(a: std.mem.Allocator, pin: Pin) ![]const u8 {
    try pin.validate();
    return std.fs.path.join(a, &.{ try cacheRoot(a), "provider-archives", try std.fmt.allocPrint(a, "{s}.tar.gz", .{pin.sha256}) });
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

/// Verify bytes on every read, including cache hits. A mismatch never refetches
/// silently and never changes a pin. Delete the damaged archive and resolve again.
pub fn archive(a: std.mem.Allocator, pin: Pin, allow_download: bool) ![]u8 {
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

/// The `plugin.labelle` of a pinned package, read straight out of its
/// verified cached archive — nothing is extracted, downloaded or run — or
/// null when the archive holds no manifest. `ProviderArchiveMissing` when
/// the archive is not cached. Every buffer lands on `a`; callers that scan
/// several releases pass a scratch arena.
pub fn cachedManifest(a: std.mem.Allocator, pin: Pin) !?manifest.Manifest {
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

pub fn safeArchivePath(path: []const u8) bool {
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

pub fn validateTar(a: std.mem.Allocator, bytes: []const u8) !void {
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
