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
const registry = @import("../provider_registry.zig");
const registry_cache = @import("registry_cache.zig");
const files = @import("files.zig");

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

/// The largest registry document the CLI accepts, from a download or a file.
pub const max_document_bytes: usize = 1024 * 1024;

/// Download a registry document over HTTPS with curl; curl cannot execute
/// the returned document. The 1 MiB cap is enforced here, on the captured
/// stdout, not only by `--max-filesize`: curl before 8.4.0 ignores that flag
/// when the response size is unknown (chunked). Oversize is a failed download.
pub fn download(a: std.mem.Allocator, source: []const u8, limits: Limits) ![]const u8 {
    return capture(a, &.{ "curl", "--fail", "--silent", "--show-error", "--proto", "=https", "--connect-timeout", limits.connect_timeout, "--max-time", limits.max_time, "--max-filesize", "1048576", source }, max_document_bytes);
}

/// Run `argv` and return its stdout, failing with
/// `ProviderRegistryDownloadFailed` on a non-zero exit or when stdout grows
/// past `limit` bytes (the child is killed as soon as it does).
fn capture(a: std.mem.Allocator, argv: []const []const u8, limit: usize) ![]const u8 {
    const result = std.process.run(a, config.globalIo(), .{
        .argv = argv,
        .stdout_limit = .limited(limit),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.StreamTooLong => return error.ProviderRegistryDownloadFailed,
        else => return err,
    };
    if (result.term != .exited or result.term.exited != 0) return error.ProviderRegistryDownloadFailed;
    return result.stdout;
}

/// Project-local record of the registry source the project's last
/// `providers resolve --accept` used, and the normalised document it bound.
/// The no-provider lookup asks THAT source first, so a project resolved from
/// a custom or local `providers.json` never gets a suggestion from the public
/// registry. Written after the lock commits; best effort.
pub const accepted_name = ".labelle/providers.registry.json";

pub const Accepted = struct {
    schema_version: u8 = 1,
    /// An https URL, or the absolute path of a local file.
    source: []const u8,
    /// `Registry.normalised` of the accepted document.
    document: []const u8,
};

fn isUrl(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "://") != null;
}

/// A registry source as it is recorded: a URL as given, a local path made absolute.
pub fn canonicalSource(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    return if (isUrl(source)) source else try std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), source, a);
}

/// Record the source an accept used (a local path made absolute) with the
/// normalised document it bound.
pub fn recordAccepted(a: std.mem.Allocator, root: []const u8, source: []const u8, document: []const u8) !void {
    const io = config.globalIo();
    const canonical = try canonicalSource(a, source);
    const dest = try std.fs.path.join(a, &.{ root, accepted_name });
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(dest).?);
    try files.writeAtomically(a, dest, try std.json.Stringify.valueAlloc(a, Accepted{ .source = canonical, .document = document }, .{ .whitespace = .indent_2 }));
}

/// The project's accepted-source record, or null (none, or unreadable).
pub fn readAccepted(a: std.mem.Allocator, root: []const u8) ?Accepted {
    const path = std.fs.path.join(a, &.{ root, accepted_name }) catch return null;
    const bytes = files.read(a, path, 2 * 1024 * 1024) catch return null;
    const record = std.json.parseFromSliceLeaky(Accepted, a, bytes, .{ .allocate = .alloc_always }) catch return null;
    if (record.schema_version != 1) return null;
    return record;
}

/// Where a hint came from.
pub const Source = enum {
    /// A fresh download of the public registry, made for this diagnostic.
    online,
    /// The public registry as the last accept bound it (the project's
    /// record, else the global cache).
    cache,
    /// A fresh read of the custom source the project last accepted.
    accepted_source,
    /// The project's recorded copy of that custom source, when a fresh read
    /// is not possible (offline URL, unreachable, file gone).
    accepted_copy,
};

/// The release a `.plugins` entry should name for a target, and where the
/// suggestion came from.
pub const OwnerHint = struct {
    package: []const u8,
    /// `<owner>/<name>` (the registry's form; `.plugins` takes it with a
    /// `github.com/` prefix).
    repo: []const u8,
    /// The newest release whose record declares the target; null when the
    /// document cannot tie a release to the declaration (schema 1: the owner
    /// was found through a cached archive), so the user picks the version
    /// from the `providers resolve` preview instead.
    version: ?[]const u8,
    source: Source,
    /// The custom registry source that answered; null for the public one.
    registry: ?[]const u8 = null,
    /// The answer came from the global registry cache, whose source was not
    /// recorded (a cache from before sources were kept): it may be another
    /// project's custom registry, so it is never presented as the public one.
    unknown_origin: bool = false,
};

pub const Reason = enum {
    /// `LABELLE_OFFLINE` is set and nothing readable offline names an owner.
    offline,
    /// The download or read failed (or did not parse), and nothing cached
    /// names an owner.
    unreachable_registry,
    /// A registry was read and no release in it declares the target.
    not_listed,
};

/// Why no hint could be given; the diagnostic says which, so the path that
/// ran is visible.
pub const Miss = struct {
    reason: Reason,
    /// The custom registry source consulted; null for the public one.
    registry: ?[]const u8 = null,
};

pub const Lookup = union(enum) {
    hit: OwnerHint,
    miss: Miss,
};

/// The release to suggest for `target` from a parsed document: the owner's
/// newest release whose own record declares the target (schema 2: the
/// owner is the union of its releases, and the newest may have dropped it).
/// A schema-1 document claims nothing, so only `named` (an owner found
/// through a verified cached archive) resolves it there, and without a
/// version: no record ties a release to the declaration.
pub fn ownerIn(doc: registry.Registry, target: []const u8, named: ?[]const u8, source: Source, from: ?[]const u8) ?OwnerHint {
    const package = named orelse doc.targetOwner(target) orelse return null;
    if (doc.claimsOwnership()) {
        const record = doc.latestDeclaring(package, target) orelse return null;
        return .{ .package = package, .repo = record.repo, .version = record.version, .source = source, .registry = from };
    }
    const latest = doc.latestRelease(package) orelse return null;
    return .{ .package = package, .repo = latest.repo, .version = null, .source = source, .registry = from };
}

/// `ownerIn` for any document: a schema-1 document's owner comes from the
/// bounded scan of verified cached archives (`registry_cache.scanOwner`),
/// the same scan the public path's cache fallback runs.
fn ownerOfDoc(a: std.mem.Allocator, budget: *registry_cache.ScanBudget, doc: registry.Registry, target: []const u8, source: Source, from: ?[]const u8) ?OwnerHint {
    if (doc.claimsOwnership()) return ownerIn(doc, target, null, source, from);
    const named = (registry_cache.scanOwner(a, doc, target, budget) catch return null) orelse return null;
    return ownerIn(doc, target, named, source, from);
}

/// The download the lookup uses: the real one, or a test's stand-in.
pub const Fetcher = *const fn (a: std.mem.Allocator, url: []const u8) anyerror![]const u8;

fn fetchLive(a: std.mem.Allocator, url: []const u8) anyerror![]const u8 {
    return download(a, url, Limits.hint);
}

/// The best-effort lookup behind the no-provider diagnostic. Never an error.
///
/// - The project last accepted from a custom source (`accepted_name`): ask
///   that source (a fresh download of a URL unless offline, or a read of the
///   local file), then the project's recorded copy of it. The public
///   registry is never fetched: it may assign the target differently.
/// - Otherwise the public registry: a fresh download unless offline, then
///   the document the project (or, without a record, any project) last
///   accepted from it.
pub fn lookupOwner(a: std.mem.Allocator, root: ?[]const u8, target: []const u8, offline: bool, fetch: Fetcher) Lookup {
    // One archive-scan allowance for the whole lookup: a schema-1 fresh
    // read and its fallbacks share it and never read an archive twice.
    var scan_budget: registry_cache.ScanBudget = .{};
    const budget = &scan_budget;
    const accepted = if (root) |r| readAccepted(a, r) else null;
    if (accepted) |record| {
        if (!std.mem.eql(u8, record.source, registry_url)) return lookupCustom(a, budget, record, target, offline, fetch);
    }
    var reached = false;
    if (!offline) live: {
        const bytes = fetch(a, registry_url) catch break :live;
        const doc = registry.parse(a, bytes) catch break :live;
        reached = true;
        if (ownerOfDoc(a, budget, doc, target, .online, null)) |hint| return .{ .hit = hint };
        // A schema-2 document that answered is authoritative: a target it
        // no longer lists is not revived from older cached metadata.
        if (doc.claimsOwnership()) return .{ .miss = .{ .reason = .not_listed } };
    }
    if (accepted) |record| {
        if (registry.parse(a, record.document)) |doc| {
            if (ownerOfDoc(a, budget, doc, target, .cache, null)) |hint| return .{ .hit = hint };
        } else |_| {}
    } else if (cachedOwner(a, budget, target)) |hint| return .{ .hit = hint };
    if (offline) return .{ .miss = .{ .reason = .offline } };
    return .{ .miss = .{ .reason = if (reached) .not_listed else .unreachable_registry } };
}

fn lookupCustom(a: std.mem.Allocator, budget: *registry_cache.ScanBudget, record: Accepted, target: []const u8, offline: bool, fetch: Fetcher) Lookup {
    const from = record.source;
    const fresh: ?[]const u8 = if (isUrl(from))
        (if (offline) null else fetch(a, from) catch null)
    else
        files.read(a, from, max_document_bytes) catch null;
    if (fresh) |bytes| {
        if (registry.parse(a, bytes)) |doc| {
            // A schema-2 answer is authoritative, even when it lists nobody.
            if (ownerOfDoc(a, budget, doc, target, .accepted_source, from)) |hint| return .{ .hit = hint };
            if (doc.claimsOwnership()) return .{ .miss = .{ .reason = .not_listed, .registry = from } };
        } else |_| {}
    }
    if (registry.parse(a, record.document)) |doc| {
        if (ownerOfDoc(a, budget, doc, target, .accepted_copy, from)) |hint| return .{ .hit = hint };
        return .{ .miss = .{ .reason = .not_listed, .registry = from } };
    } else |_| {}
    const reason: Reason = if (offline and isUrl(from)) .offline else .unreachable_registry;
    return .{ .miss = .{ .reason = reason, .registry = from } };
}

/// `lookupOwner` with the real download and `LABELLE_OFFLINE` from the
/// environment. Unit tests never reach the network: a test binary that ends
/// up here (a pipeline test hitting the no-provider path) is offline; the
/// lookup itself is tested through `lookupOwner` with stand-in fetchers.
pub fn lookupOwnerFromEnv(a: std.mem.Allocator, root: ?[]const u8, target: []const u8) Lookup {
    return lookupOwner(a, root, target, builtin.is_test or offlineRequested(a), fetchLive);
}

/// True when `LABELLE_OFFLINE` is set to anything but empty or `0`.
pub fn offlineRequested(a: std.mem.Allocator) bool {
    const value = config.globalEnviron().getAlloc(a, offline_env) catch return false;
    return value.len > 0 and !std.mem.eql(u8, value, "0");
}

/// The global cache's answer, labelled with the source it was accepted
/// from: a custom source is named (and passed to the resolve steps); an
/// unrecorded one is marked `unknown_origin`, never presented as public.
fn cachedOwner(a: std.mem.Allocator, budget: *registry_cache.ScanBudget, target: []const u8) ?OwnerHint {
    const doc = (registry_cache.cachedRegistry(a) catch return null) orelse return null;
    const origin = registry_cache.cachedRegistrySource(a);
    const custom: ?[]const u8 = if (origin) |from| (if (std.mem.eql(u8, from, registry_url)) null else from) else null;
    var hint = ownerOfDoc(a, budget, doc, target, .cache, custom) orelse return null;
    hint.unknown_origin = origin == null;
    return hint;
}

// ── Tests ────────────────────────────────────────────────────────────────

const AcceptFixture = @import("test_fixtures.zig").AcceptFixture;

const commit_a = "1" ** 40;
const hash_a = "a" ** 64;

fn testRecord(comptime package: []const u8, comptime version: []const u8, comptime targets: []const u8) []const u8 {
    return "{\"package\":\"" ++ package ++ "\",\"repo\":\"owner/" ++ package ++ "\",\"version\":\"" ++ version ++
        "\",\"commit\":\"" ++ commit_a ++ "\",\"sha256\":\"" ++ hash_a ++ "\",\"namespace\":null,\"targets\":[" ++ targets ++ "]}";
}

const live_doc = "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++
    testRecord("fixture", "0.9.0", "\"probe-target\"") ++ "," ++
    testRecord("fixture", "0.10.0", "\"probe-target\"") ++ "," ++
    testRecord("fixture", "0.2.1", "\"probe-target\"") ++ "," ++
    testRecord("fixture", "0.11.0", "\"later-target\"") ++ "," ++
    testRecord("other", "3.0.0", "\"other-target\"") ++ "]}";

/// URLs the stand-in fetchers were asked for, in order.
var fetched: [16][]const u8 = undefined;
var fetch_calls: usize = 0;

fn note(url: []const u8) void {
    if (fetch_calls < fetched.len) fetched[fetch_calls] = url;
    fetch_calls += 1;
}

fn fetchLiveDoc(a: std.mem.Allocator, url: []const u8) anyerror![]const u8 {
    note(url);
    return a.dupe(u8, live_doc);
}

fn fetchFails(_: std.mem.Allocator, url: []const u8) anyerror![]const u8 {
    note(url);
    return error.ProviderRegistryDownloadFailed;
}

fn fetchWithoutProbe(a: std.mem.Allocator, url: []const u8) anyerror![]const u8 {
    note(url);
    return a.dupe(u8, comptime "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++ testRecord("other", "3.0.0", "\"other-target\"") ++ "]}");
}

fn fetchSchemaOne(a: std.mem.Allocator, url: []const u8) anyerror![]const u8 {
    note(url);
    return a.dupe(u8, "{\"schema_version\":1,\"providers\":[]}");
}

fn fetchGarbage(a: std.mem.Allocator, url: []const u8) anyerror![]const u8 {
    note(url);
    return a.dupe(u8, "<html>not json</html>");
}

test "provider registry lookup: a live hit names the owner and its newest declaring release (semver, not lexical)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    fetch_calls = 0;
    const found = lookupOwner(a, fx.root, "probe-target", false, fetchLiveDoc);
    try std.testing.expectEqual(@as(usize, 1), fetch_calls);
    try std.testing.expectEqualStrings(registry_url, fetched[0]);
    const hint = found.hit;
    try std.testing.expectEqualStrings("fixture", hint.package);
    try std.testing.expectEqualStrings("owner/fixture", hint.repo);
    try std.testing.expectEqualStrings("0.10.0", hint.version.?);
    try std.testing.expectEqual(Source.online, hint.source);
    try std.testing.expect(hint.registry == null);
    // The package's newest release (0.11.0) dropped `probe-target`: the
    // suggestion pins the newest release that still declares it.
    try std.testing.expectEqualStrings("0.11.0", lookupOwner(a, fx.root, "later-target", false, fetchLiveDoc).hit.version.?);
    // The registry was reached and lists nobody for this target.
    try std.testing.expectEqual(Reason.not_listed, lookupOwner(a, fx.root, "absent-target", false, fetchLiveDoc).miss.reason);
    try std.testing.expectEqual(@as(usize, 3), fetch_calls);
}

test "provider registry lookup: offline never fetches; a failed fetch is a miss, never an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    fetch_calls = 0;
    // Offline: the fetcher is not called at all (it would have answered).
    try std.testing.expectEqual(Reason.offline, lookupOwner(a, fx.root, "probe-target", true, fetchLiveDoc).miss.reason);
    try std.testing.expectEqual(@as(usize, 0), fetch_calls);
    try std.testing.expectEqual(Reason.unreachable_registry, lookupOwner(a, fx.root, "probe-target", false, fetchFails).miss.reason);
    try std.testing.expectEqual(Reason.unreachable_registry, lookupOwner(a, null, "probe-target", false, fetchGarbage).miss.reason);
    try std.testing.expectEqual(@as(usize, 2), fetch_calls);
}

test "provider registry lookup: the cached public registry answers when the live one cannot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    try registry_cache.cacheRegistry(a, try AcceptFixture.schemaTwo(a, fx.pin, "\"probe\"", "\"probe-target\""));
    fetch_calls = 0;
    const offline = lookupOwner(a, fx.root, "probe-target", true, fetchLiveDoc).hit;
    try std.testing.expectEqual(@as(usize, 0), fetch_calls);
    try std.testing.expectEqual(Source.cache, offline.source);
    try std.testing.expectEqualStrings("fixture", offline.package);
    try std.testing.expectEqualStrings(fx.pin.version, offline.version.?);
    try std.testing.expectEqual(Source.cache, lookupOwner(a, fx.root, "probe-target", false, fetchFails).hit.source);
    // Online wins when it answers: its newer release, not the cached one.
    const live = lookupOwner(a, fx.root, "probe-target", false, fetchLiveDoc).hit;
    try std.testing.expectEqual(Source.online, live.source);
    try std.testing.expectEqualStrings("0.10.0", live.version.?);
    // A live schema-2 document that no longer lists the target is
    // authoritative: the stale cached owner is not revived.
    try std.testing.expectEqual(Reason.not_listed, lookupOwner(a, fx.root, "probe-target", false, fetchWithoutProbe).miss.reason);
    // A live schema-1 document claims nothing, so the cache still answers.
    try std.testing.expectEqual(Source.cache, lookupOwner(a, fx.root, "probe-target", false, fetchSchemaOne).hit.source);
}

test "provider registry lookup: a schema-1 owner is named without a version it cannot tie to the declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    // A verified cached archive (fx.pin, 1.0.0) declares the target; the
    // schema-1 document also lists a newer 2.0.0 that says nothing.
    const declaring = ".{ .name = \"fixture\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{ \"probe-target\" } }";
    const data = try AcceptFixture.gzipArchiveWith(a, declaring);
    var owner = fx.pin;
    owner.sha256 = try files.sha256Hex(a, data);
    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = try @import("archive.zig").archivePath(a, owner), .data = data });
    var newer = fx.pin;
    newer.version = "2.0.0";
    newer.sha256 = "0" ** 64;
    try registry_cache.cacheRegistry(a, try std.json.Stringify.valueAlloc(a, @import("pin.zig").Document{ .schema_version = 1, .providers = &.{ owner, newer } }, .{}));
    const hint = lookupOwner(a, null, "probe-target", true, fetchLiveDoc).hit;
    try std.testing.expectEqualStrings("fixture", hint.package);
    try std.testing.expect(hint.version == null);
    try std.testing.expectEqual(Source.cache, hint.source);
}

test "provider registry lookup: the download capture is capped in the CLI, not only by curl" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A stand-in for a curl that ignores --max-filesize on a chunked
    // response: it writes past the cap, and the capture fails like a bad download.
    try std.testing.expectError(error.ProviderRegistryDownloadFailed, capture(a, &.{ "/bin/sh", "-c", "head -c 1048577 /dev/zero" }, max_document_bytes));
    const exact = try capture(a, &.{ "/bin/sh", "-c", "head -c 1048576 /dev/zero" }, max_document_bytes);
    try std.testing.expectEqual(max_document_bytes, exact.len);
    try std.testing.expectError(error.ProviderRegistryDownloadFailed, capture(a, &.{ "/bin/sh", "-c", "exit 22" }, max_document_bytes));
}

test "provider registry lookup: a project accepted from a custom source is answered by that source, never the public registry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    // Accept from the fixture's LOCAL providers.json: the project records it.
    try fx.publishSchemaTwo(a, "\"probe\"", "");
    try fx.run(a, false);
    try fx.run(a, true);
    const accepted = readAccepted(a, fx.root).?;
    try std.testing.expect(std.fs.path.isAbsolute(accepted.source));
    try std.testing.expect(std.mem.endsWith(u8, accepted.source, "providers.json"));
    // The custom source assigns `probe-target` to `custom-owner`; the public
    // registry (the stand-in) would say `fixture` 0.10.0.
    const custom = comptime "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++
        testRecord("custom-owner", "2.0.0", "\"probe-target\"") ++ "," ++ testRecord("custom-owner", "2.1.0", "\"other-target\"") ++ "]}";
    try fx.publishRaw(custom);
    fetch_calls = 0;
    const hint = lookupOwner(a, fx.root, "probe-target", false, fetchLiveDoc).hit;
    try std.testing.expectEqual(@as(usize, 0), fetch_calls);
    try std.testing.expectEqualStrings("custom-owner", hint.package);
    try std.testing.expectEqualStrings("2.0.0", hint.version.?);
    try std.testing.expectEqual(Source.accepted_source, hint.source);
    try std.testing.expectEqualStrings(accepted.source, hint.registry.?);
    // Listed by the public registry but not by the custom source: not listed
    // there, and still no public fetch.
    const miss = lookupOwner(a, fx.root, "later-target", false, fetchLiveDoc).miss;
    try std.testing.expectEqual(Reason.not_listed, miss.reason);
    try std.testing.expectEqualStrings(accepted.source, miss.registry.?);
    try std.testing.expectEqual(@as(usize, 0), fetch_calls);
    // The file gone: the recorded copy of what was accepted answers (it
    // listed `fixture` with no targets), still without a public fetch.
    try std.Io.Dir.cwd().deleteFile(config.globalIo(), fx.registry);
    const copy = lookupOwner(a, fx.root, "probe-target", false, fetchLiveDoc).miss;
    try std.testing.expectEqual(Reason.not_listed, copy.reason);
    try std.testing.expectEqual(@as(usize, 0), fetch_calls);
    // A project with no record falls back to the public path.
    try std.testing.expectEqual(Source.online, lookupOwner(a, null, "probe-target", false, fetchLiveDoc).hit.source);
    try std.testing.expectEqual(@as(usize, 1), fetch_calls);
}

test "provider registry lookup: a custom URL source is refreshed from that URL, and its recorded copy answers offline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    const fork = "https://raw.githubusercontent.com/example/fork-registry/main/providers.json";
    const copy = comptime "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++ testRecord("fork-owner", "1.0.0", "\"probe-target\"") ++ "]}";
    try recordAccepted(a, fx.root, fork, copy);
    fetch_calls = 0;
    // Online: the fork URL is fetched (the stand-in serves `live_doc`), never the public one.
    const live = lookupOwner(a, fx.root, "probe-target", false, fetchLiveDoc).hit;
    try std.testing.expectEqual(@as(usize, 1), fetch_calls);
    try std.testing.expectEqualStrings(fork, fetched[0]);
    try std.testing.expectEqual(Source.accepted_source, live.source);
    try std.testing.expectEqualStrings(fork, live.registry.?);
    // Offline or unreachable: the recorded copy, no public fetch.
    const offline = lookupOwner(a, fx.root, "probe-target", true, fetchLiveDoc).hit;
    try std.testing.expectEqual(Source.accepted_copy, offline.source);
    try std.testing.expectEqualStrings("fork-owner", offline.package);
    const failed = lookupOwner(a, fx.root, "probe-target", false, fetchFails).hit;
    try std.testing.expectEqual(Source.accepted_copy, failed.source);
    try std.testing.expectEqual(@as(usize, 2), fetch_calls);
    try std.testing.expectEqualStrings(fork, fetched[1]);
}

test "provider registry lookup: the resolve and hint limits stay distinct and the url is the resolve default" {
    try std.testing.expect(!std.mem.eql(u8, Limits.resolve.max_time, Limits.hint.max_time));
    try std.testing.expect(std.mem.startsWith(u8, registry_url, "https://raw.githubusercontent.com/"));
}

test "provider registry lookup: the global cache keeps its source; another project's custom registry is never presented as public" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    // An accept from a local file records that file as the cache's source.
    try fx.publishSchemaTwo(a, "\"probe\"", "");
    try fx.run(a, false);
    try fx.run(a, true);
    const accepted_from = try canonicalSource(a, fx.registry);
    try std.testing.expectEqualStrings(accepted_from, registry_cache.cachedRegistrySource(a).?);
    // Another project (no record of its own, offline) falls back to that
    // cache: the hint names the custom source instead of posing as public.
    const doc = try AcceptFixture.schemaTwo(a, fx.pin, "\"probe\"", "\"probe-target\"");
    try registry_cache.cacheRegistryFrom(a, doc, "/elsewhere/providers.json");
    const custom = lookupOwner(a, null, "probe-target", true, fetchLiveDoc).hit;
    try std.testing.expectEqual(Source.cache, custom.source);
    try std.testing.expectEqualStrings("/elsewhere/providers.json", custom.registry.?);
    try std.testing.expect(!custom.unknown_origin);
    // Cached from the public registry: public, no source.
    try registry_cache.cacheRegistryFrom(a, doc, registry_url);
    const public = lookupOwner(a, null, "probe-target", true, fetchLiveDoc).hit;
    try std.testing.expect(public.registry == null and !public.unknown_origin);
    // Re-cached without a source: the old sidecar (other bytes) no longer
    // labels it, so the origin is unknown rather than assumed public.
    try registry_cache.cacheRegistry(a, try AcceptFixture.schemaTwo(a, fx.pin, "null", "\"probe-target\""));
    try std.testing.expect(registry_cache.cachedRegistrySource(a) == null);
    const unknown = lookupOwner(a, null, "probe-target", true, fetchLiveDoc).hit;
    try std.testing.expect(unknown.registry == null and unknown.unknown_origin);
}

test "provider registry lookup: an accepted schema-1 source still runs the bounded verified-archive owner scan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    // Accept from the fixture's local schema-1 providers.json.
    try fx.run(a, false);
    try fx.run(a, true);
    const accepted = readAccepted(a, fx.root).?;
    // The source now lists a release whose verified cached archive declares
    // the target; schema 1 records claim nothing, so only the scan finds it.
    const declaring = ".{ .name = \"fixture\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{ \"probe-target\" } }";
    const data = try AcceptFixture.gzipArchiveWith(a, declaring);
    var owner = fx.pin;
    owner.version = "1.1.0";
    owner.sha256 = try files.sha256Hex(a, data);
    const listing = try std.json.Stringify.valueAlloc(a, @import("pin.zig").Document{ .schema_version = 1, .providers = &.{ fx.pin, owner } }, .{});
    try fx.publishRaw(listing);
    fetch_calls = 0;
    // Not cached yet: the scan reads nothing, so nothing is named.
    try std.testing.expectEqual(Reason.not_listed, lookupOwner(a, fx.root, "probe-target", false, fetchLiveDoc).miss.reason);
    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = try @import("archive.zig").archivePath(a, owner), .data = data });
    const hint = lookupOwner(a, fx.root, "probe-target", false, fetchLiveDoc).hit;
    try std.testing.expectEqualStrings("fixture", hint.package);
    try std.testing.expect(hint.version == null);
    try std.testing.expectEqual(Source.accepted_source, hint.source);
    try std.testing.expectEqualStrings(accepted.source, hint.registry.?);
    // Neither lookup fetched the public registry.
    try std.testing.expectEqual(@as(usize, 0), fetch_calls);
}

test "provider registry lookup: one archive-scan budget covers the fresh read and its fallbacks, with no archive read twice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]usize{ 5, registry_cache.registry_hint_scan_limit + 3 }) |decoys| {
        var fx = try AcceptFixture.init(a);
        defer fx.deinit();
        // A schema-1 source listing the accepted fixture release plus
        // `decoys` cached releases that verify but declare no target.
        var pins: std.ArrayList(@import("pin.zig").Pin) = .empty;
        try pins.append(a, fx.pin);
        for (0..decoys) |i| {
            const text = try std.fmt.allocPrint(a, ".{{ .name = \"fixture\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{{ \"other-{d}\" }} }}", .{i});
            const data = try AcceptFixture.gzipArchiveWith(a, text);
            var pin = fx.pin;
            pin.version = try std.fmt.allocPrint(a, "1.{d}.1", .{i});
            pin.sha256 = try files.sha256Hex(a, data);
            try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = try @import("archive.zig").archivePath(a, pin), .data = data });
            try pins.append(a, pin);
        }
        try fx.publishRaw(try std.json.Stringify.valueAlloc(a, @import("pin.zig").Document{ .schema_version = 1, .providers = pins.items }, .{}));
        try fx.run(a, false);
        try fx.run(a, true);
        // The fresh read (schema 1) misses, so the recorded copy — the same
        // releases — is the fallback. Sharing the budget, the copy reads no
        // archive the fresh read already read, and the total stays bounded.
        const before = registry_cache.archive_inspections;
        try std.testing.expectEqual(Reason.not_listed, lookupOwner(a, fx.root, "probe-target", true, fetchLiveDoc).miss.reason);
        const read = registry_cache.archive_inspections - before;
        try std.testing.expectEqual(@min(decoys + 1, registry_cache.registry_hint_scan_limit), read);
    }
}
