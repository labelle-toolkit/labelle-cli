//! Test-only fixtures for the provider_github modules and their callers'
//! tests. Referenced only from test code and `testProviderArchive`.
const std = @import("std");
const config = @import("../config.zig");
const cache = @import("../asm_cache.zig");
const pin_mod = @import("pin.zig");
const Pin = pin_mod.Pin;
const Document = pin_mod.Document;
const sha256Hex = @import("files.zig").sha256Hex;
const resolve = @import("resolve.zig").resolve;

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
pub const AcceptFixture = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    home: []const u8,
    registry: []const u8,
    pin: Pin,

    const manifest_text = ".{ .name = \"fixture\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .namespace = \"probe\", .commands = .{ .{ .name = \"inspect\", .build_step = \"tool\", .executable = \"bin/probe\", .help = \"Inspect\" } } }";

    pub fn gzipArchive(a: std.mem.Allocator) ![]u8 {
        return gzipArchiveWith(a, manifest_text);
    }

    pub fn gzipArchiveWith(a: std.mem.Allocator, plugin_manifest: []const u8) ![]u8 {
        return gzipArchiveOf(a, plugin_manifest, "// fixture\n");
    }

    /// A valid archive with no `plugin.labelle` at all (`cachedManifest`
    /// reads it whole and returns null); `build_zig` varies the bytes so
    /// every pin verifies its own archive.
    pub fn gzipArchiveWithoutManifest(a: std.mem.Allocator, build_zig: []const u8) ![]u8 {
        return gzipArchiveOf(a, null, build_zig);
    }

    pub fn gzipArchiveOf(a: std.mem.Allocator, plugin_manifest: ?[]const u8, build_zig: []const u8) ![]u8 {
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

    pub fn init(a: std.mem.Allocator) !AcceptFixture {
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

    pub fn deinit(self: *AcceptFixture) void {
        cache.clearCacheRootOverride();
        self.tmp.cleanup();
    }

    pub fn publish(self: *AcceptFixture, a: std.mem.Allocator, pin: Pin) !void {
        const data = try std.json.Stringify.valueAlloc(a, Document{ .schema_version = 1, .providers = &.{pin} }, .{});
        try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = self.registry, .data = data });
    }

    /// A schema-2 registry (#411) listing `pin` with the given ownership
    /// claims, as JSON fragments (`"probe"` or `null`; `"t1","t2"`).
    pub fn schemaTwo(a: std.mem.Allocator, pin: Pin, namespace: []const u8, targets: []const u8) ![]const u8 {
        return std.fmt.allocPrint(a, "{{\"schema_version\":2,\"defaults\":[],\"providers\":[{{\"package\":\"{s}\",\"repo\":\"{s}\",\"version\":\"{s}\",\"commit\":\"{s}\",\"sha256\":\"{s}\",\"namespace\":{s},\"targets\":[{s}]}}]}}", .{ pin.package, pin.repo, pin.version, pin.commit, pin.sha256, namespace, targets });
    }

    pub fn publishSchemaTwo(self: *AcceptFixture, a: std.mem.Allocator, namespace: []const u8, targets: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = self.registry, .data = try schemaTwo(a, self.pin, namespace, targets) });
    }

    pub fn publishRaw(self: *AcceptFixture, bytes: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = self.registry, .data = bytes });
    }

    pub fn run(self: *AcceptFixture, a: std.mem.Allocator, accept: bool) !void {
        return resolve(a, self.root, self.registry, accept, true, &.{});
    }

    pub fn exists(self: *AcceptFixture, a: std.mem.Allocator, name: []const u8) !bool {
        std.Io.Dir.cwd().access(config.globalIo(), try std.fs.path.join(a, &.{ self.root, name }), .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        return true;
    }
};
