//! The immutable GitHub pin, the lock document schema and its parse rules.
const std = @import("std");
const project = @import("../project_config.zig");
const contract = @import("../provider_contract.zig");
const safeArchivePath = @import("archive.zig").safeArchivePath;

pub const lock_name = "labelle.providers.lock";

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
