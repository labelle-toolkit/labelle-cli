//! The last accepted registry document, kept under the cache root, and the
//! target-owner hint read from it (never used for resolution).
const std = @import("std");
const config = @import("../config.zig");
const registry = @import("../provider_registry.zig");
const pin_mod = @import("pin.zig");
const Pin = pin_mod.Pin;
const Document = pin_mod.Document;
const files = @import("files.zig");
const read = files.read;
const cacheRoot = files.cacheRoot;
const writeAtomically = files.writeAtomically;
const sha256Hex = files.sha256Hex;
const archive_mod = @import("archive.zig");
const archivePath = archive_mod.archivePath;
const cachedManifest = archive_mod.cachedManifest;
const AcceptFixture = @import("test_fixtures.zig").AcceptFixture;

/// Where the last accepted registry document is kept under the cache root.
/// Read only by `cachedRegistryOwner`, for a diagnostic; never for resolution.
pub const registry_cache_dir = "registry";
pub const registry_cache_file = "providers.json";

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
pub fn cacheRegistry(a: std.mem.Allocator, data: []const u8) !void {
    const dir = try std.fs.path.join(a, &.{ try cacheRoot(a), registry_cache_dir });
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), dir);
    try writeAtomically(a, try std.fs.path.join(a, &.{ dir, registry_cache_file }), data);
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
