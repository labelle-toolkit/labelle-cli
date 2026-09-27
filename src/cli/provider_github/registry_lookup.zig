//! The registry download, and the best-effort owner lookup behind the
//! no-provider diagnostic.
//!
//! `labelle providers resolve` fetches the registry document to preview and
//! pin releases. The no-provider diagnostic fetches the same document for a
//! different, weaker purpose: to NAME the package that declares a target the
//! project has no provider for, and its newest release, so the error can say
//! what to add to `.plugins`. That is registry metadata only (contract §4):
//! nothing is pinned, cached, extracted or run, and the answer is printed as
//! a suggestion the user still has to add, resolve and accept. The lookup is
//! bounded by a short timeout, skipped under `LABELLE_OFFLINE`, and every
//! failure is just "no hint": it can never change how the command fails.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const util = @import("../util.zig");
const registry = @import("../provider_registry.zig");
const registry_cache = @import("registry_cache.zig");

pub const registry_url = "https://raw.githubusercontent.com/labelle-toolkit/labelle-registry/main/providers.json";

/// Set to anything but empty or `0` to skip the no-provider diagnostic's
/// registry lookup (no network). The cached registry is still read.
pub const offline_env = "LABELLE_OFFLINE";

/// curl limits: `resolve` waits for the document a user asked to preview;
/// the diagnostic only decorates an error, so it gives up quickly.
pub const Limits = struct {
    connect_timeout: []const u8,
    max_time: []const u8,

    pub const resolve: Limits = .{ .connect_timeout = "30", .max_time = "60" };
    pub const hint: Limits = .{ .connect_timeout = "3", .max_time = "5" };
};

/// Download a registry document over HTTPS with curl. stdout capture is
/// bounded (1 MiB); curl cannot execute the returned document.
pub fn download(a: std.mem.Allocator, source: []const u8, limits: Limits) ![]const u8 {
    const result = try util.runCmd(a, &.{ "curl", "--fail", "--silent", "--show-error", "--proto", "=https", "--connect-timeout", limits.connect_timeout, "--max-time", limits.max_time, "--max-filesize", "1048576", source });
    if (result.term != .exited or result.term.exited != 0) return error.ProviderRegistryDownloadFailed;
    return result.stdout;
}

/// Where a hint came from.
pub const Source = enum {
    /// A fresh download of the registry, made for this diagnostic.
    online,
    /// The document the last `providers resolve --accept` bound.
    cache,
};

/// The package that declares a target, and its newest release in the
/// document that named it: everything the `.plugins` entry needs.
pub const OwnerHint = struct {
    package: []const u8,
    /// `<owner>/<name>` (the registry's form; `.plugins` takes it with a
    /// `github.com/` prefix).
    repo: []const u8,
    version: []const u8,
    source: Source,
};

/// Why no hint could be given; the diagnostic says which, so the path that
/// ran is visible.
pub const Miss = enum {
    /// `LABELLE_OFFLINE` is set and no cached registry names an owner.
    offline,
    /// The download failed or the document did not parse, and no cached
    /// registry names an owner.
    unreachable_registry,
    /// The registry was read and no package in it declares the target.
    not_listed,
};

pub const Lookup = union(enum) {
    hit: OwnerHint,
    miss: Miss,
};

/// The owner of `target` in a parsed document, with its newest release;
/// null when no package declares it. A schema-1 document claims nothing, so
/// only `named` (an owner found some other way) can resolve it there.
pub fn ownerIn(doc: registry.Registry, target: []const u8, named: ?[]const u8, source: Source) ?OwnerHint {
    const package = named orelse doc.targetOwner(target) orelse return null;
    const latest = doc.latestRelease(package) orelse return null;
    return .{ .package = package, .repo = latest.repo, .version = latest.version, .source = source };
}

/// The fetch the lookup uses: the real download, or a test's stand-in.
pub const Fetcher = *const fn (a: std.mem.Allocator) anyerror![]const u8;

fn fetchLive(a: std.mem.Allocator) anyerror![]const u8 {
    return download(a, registry_url, Limits.hint);
}

/// The best-effort lookup behind the no-provider diagnostic: the live
/// registry first (fresh, so the version is the newest release), then the
/// cached registry the last `--accept` bound. Never an error.
pub fn lookupOwner(a: std.mem.Allocator, target: []const u8, offline: bool, fetch: Fetcher) Lookup {
    var reached = false;
    if (!offline) live: {
        const bytes = fetch(a) catch break :live;
        const doc = registry.parse(a, bytes) catch break :live;
        reached = true;
        if (ownerIn(doc, target, null, .online)) |hint| return .{ .hit = hint };
    }
    if (cachedOwner(a, target)) |hint| return .{ .hit = hint };
    if (offline) return .{ .miss = .offline };
    return .{ .miss = if (reached) .not_listed else .unreachable_registry };
}

/// `lookupOwner` with the real download and `LABELLE_OFFLINE` from the
/// environment. Unit tests never reach the network: a test binary that ends
/// up here (a pipeline test hitting the no-provider path) is offline; the
/// lookup itself is tested through `lookupOwner` with stand-in fetchers.
pub fn lookupOwnerFromEnv(a: std.mem.Allocator, target: []const u8) Lookup {
    return lookupOwner(a, target, builtin.is_test or offlineRequested(a), fetchLive);
}

/// True when `LABELLE_OFFLINE` is set to anything but empty or `0`.
pub fn offlineRequested(a: std.mem.Allocator) bool {
    const value = config.globalEnviron().getAlloc(a, offline_env) catch return false;
    return value.len > 0 and !std.mem.eql(u8, value, "0");
}

fn cachedOwner(a: std.mem.Allocator, target: []const u8) ?OwnerHint {
    const doc = (registry_cache.cachedRegistry(a) catch return null) orelse return null;
    // Schema 1 names an owner only through a verified cached archive.
    const named = if (doc.claimsOwnership()) null else registry_cache.cachedRegistryOwner(a, target) orelse return null;
    return ownerIn(doc, target, named, .cache);
}

// ── Tests ────────────────────────────────────────────────────────────────

const AcceptFixture = @import("test_fixtures.zig").AcceptFixture;

const commit_a = "1" ** 40;
const hash_a = "a" ** 64;

fn record(comptime package: []const u8, comptime version: []const u8, comptime targets: []const u8) []const u8 {
    return "{\"package\":\"" ++ package ++ "\",\"repo\":\"owner/" ++ package ++ "\",\"version\":\"" ++ version ++
        "\",\"commit\":\"" ++ commit_a ++ "\",\"sha256\":\"" ++ hash_a ++ "\",\"namespace\":null,\"targets\":[" ++ targets ++ "]}";
}

const live_doc = "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++
    record("fixture", "0.9.0", "\"probe-target\"") ++ "," ++
    record("fixture", "0.10.0", "\"probe-target\"") ++ "," ++
    record("fixture", "0.2.1", "\"probe-target\"") ++ "," ++
    record("other", "3.0.0", "\"other-target\"") ++ "]}";

var fetch_calls: usize = 0;

fn fetchLiveDoc(a: std.mem.Allocator) anyerror![]const u8 {
    fetch_calls += 1;
    return a.dupe(u8, live_doc);
}

fn fetchFails(_: std.mem.Allocator) anyerror![]const u8 {
    fetch_calls += 1;
    return error.ProviderRegistryDownloadFailed;
}

fn fetchGarbage(a: std.mem.Allocator) anyerror![]const u8 {
    fetch_calls += 1;
    return a.dupe(u8, "<html>not json</html>");
}

test "provider registry lookup: a live hit names the owner and its newest release (semver, not lexical)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    fetch_calls = 0;
    const found = lookupOwner(a, "probe-target", false, fetchLiveDoc);
    try std.testing.expectEqual(@as(usize, 1), fetch_calls);
    const hint = found.hit;
    try std.testing.expectEqualStrings("fixture", hint.package);
    try std.testing.expectEqualStrings("owner/fixture", hint.repo);
    try std.testing.expectEqualStrings("0.10.0", hint.version);
    try std.testing.expectEqual(Source.online, hint.source);
    // The registry was reached and lists nobody for this target.
    try std.testing.expectEqual(Miss.not_listed, lookupOwner(a, "absent-target", false, fetchLiveDoc).miss);
    try std.testing.expectEqual(@as(usize, 2), fetch_calls);
}

test "provider registry lookup: offline never fetches; a failed fetch is a miss, never an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    fetch_calls = 0;
    // Offline: the fetcher is not called at all (it would have answered).
    try std.testing.expectEqual(Miss.offline, lookupOwner(a, "probe-target", true, fetchLiveDoc).miss);
    try std.testing.expectEqual(@as(usize, 0), fetch_calls);
    try std.testing.expectEqual(Miss.unreachable_registry, lookupOwner(a, "probe-target", false, fetchFails).miss);
    try std.testing.expectEqual(Miss.unreachable_registry, lookupOwner(a, "probe-target", false, fetchGarbage).miss);
    try std.testing.expectEqual(@as(usize, 2), fetch_calls);
}

test "provider registry lookup: the cached registry answers when the live one cannot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    try registry_cache.cacheRegistry(a, try AcceptFixture.schemaTwo(a, fx.pin, "\"probe\"", "\"probe-target\""));
    fetch_calls = 0;
    const offline = lookupOwner(a, "probe-target", true, fetchLiveDoc).hit;
    try std.testing.expectEqual(@as(usize, 0), fetch_calls);
    try std.testing.expectEqual(Source.cache, offline.source);
    try std.testing.expectEqualStrings("fixture", offline.package);
    try std.testing.expectEqualStrings(fx.pin.version, offline.version);
    try std.testing.expectEqual(Source.cache, lookupOwner(a, "probe-target", false, fetchFails).hit.source);
    // Online wins when it answers: its newer release, not the cached one.
    const live = lookupOwner(a, "probe-target", false, fetchLiveDoc).hit;
    try std.testing.expectEqual(Source.online, live.source);
    try std.testing.expectEqualStrings("0.10.0", live.version);
}

test "provider registry lookup: the resolve and hint limits stay distinct and the url is the resolve default" {
    try std.testing.expect(!std.mem.eql(u8, Limits.resolve.max_time, Limits.hint.max_time));
    try std.testing.expect(std.mem.startsWith(u8, registry_url, "https://raw.githubusercontent.com/"));
}
