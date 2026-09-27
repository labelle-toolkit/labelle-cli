//! The last accepted registry document, kept under the cache root, and the
//! command-namespace hint read from it (never used for resolution).
const std = @import("std");
const config = @import("../config.zig");
const registry = @import("../provider_registry.zig");
const Document = @import("pin.zig").Document;
const files = @import("files.zig");
const AcceptFixture = @import("test_fixtures.zig").AcceptFixture;

/// Where the last accepted registry document is kept under the cache root.
/// Read only by `cachedRegistryNamespaceOwner`, for a diagnostic; never for
/// resolution.
pub const registry_cache_dir = "registry";
pub const registry_cache_file = "providers.json";

/// The cached registry document, parsed, or null when none is cached.
pub fn cachedRegistry(a: std.mem.Allocator) !?registry.Registry {
    const path = try std.fs.path.join(a, &.{ try files.cacheRoot(a), registry_cache_dir, registry_cache_file });
    const bytes = files.read(a, path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try registry.parse(a, bytes);
}

/// The package the cached registry document names as declaring the command
/// `namespace`, or null — the hint for a `labelle <namespace> ...` that no
/// pinned provider serves. Schema 2 only: a schema-1 record claims nothing.
/// Cache only: never used for dispatch.
pub fn cachedRegistryNamespaceOwner(a: std.mem.Allocator, namespace: []const u8) ?[]const u8 {
    return cachedNamespaceOwner(a, namespace) catch null;
}

fn cachedNamespaceOwner(a: std.mem.Allocator, namespace: []const u8) !?[]const u8 {
    const doc = try cachedRegistry(a) orelse return null;
    if (!doc.claimsOwnership()) return null;
    return doc.namespaceOwner(namespace);
}

/// Keep the document an accept just resolved against, for
/// `cachedRegistryNamespaceOwner`.
pub fn cacheRegistry(a: std.mem.Allocator, data: []const u8) !void {
    const dir = try std.fs.path.join(a, &.{ try files.cacheRoot(a), registry_cache_dir });
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), dir);
    try files.writeAtomically(a, try std.fs.path.join(a, &.{ dir, registry_cache_file }), data);
}

test "provider github: a schema-2 cached registry names a namespace owner; schema 1 never does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    try std.testing.expect(cachedRegistryNamespaceOwner(a, "probe") == null);
    try cacheRegistry(a, try AcceptFixture.schemaTwo(a, fx.pin, "\"probe\"", "\"probe-target\""));
    try std.testing.expectEqualStrings("fixture", cachedRegistryNamespaceOwner(a, "probe").?);
    try std.testing.expect(cachedRegistryNamespaceOwner(a, "other") == null);
    // A target is not a namespace.
    try std.testing.expect(cachedRegistryNamespaceOwner(a, "probe-target") == null);
    // The same release as schema 1 claims nothing, and no archive is read.
    try cacheRegistry(a, try std.json.Stringify.valueAlloc(a, Document{ .schema_version = 1, .providers = &.{fx.pin} }, .{}));
    try std.testing.expect(cachedRegistryNamespaceOwner(a, "probe") == null);
}
