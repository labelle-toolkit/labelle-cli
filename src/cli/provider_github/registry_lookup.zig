//! The registry download, and the best-effort owner lookup behind the
//! no-provider diagnostic.
//!
//! `labelle providers resolve` fetches the registry document to preview and
//! pin releases. The no-provider diagnostic reads a registry document for a
//! different, weaker purpose: to NAME the package that declares a target the
//! project has no provider for, and a candidate release, so the error can
//! say what to add to `.plugins`. That is registry metadata only (contract
//! §4): nothing is pinned, cached, extracted or run, and the answer is a
//! suggestion the user still has to add, resolve and accept.
//!
//! The hint is advisory and deliberately simple (#459). Only a schema-2
//! document names an owner, and only one document is read:
//!
//! - the project last accepted from a custom source: the copy of that
//!   source's document recorded with it, read and verified as one snapshot;
//! - otherwise: one short-timeout download of the public registry, skipped
//!   under `LABELLE_OFFLINE`.
//!
//! Anything else — schema 1, offline, a failed or oversize download, a
//! record that does not verify — is a miss, and the diagnostic prints the
//! generic steps. Missing information makes the hint less specific; it
//! never changes which source it recommends, and never changes how the
//! command fails.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const registry = @import("../provider_registry.zig");
const files = @import("files.zig");

pub const registry_url = "https://raw.githubusercontent.com/labelle-toolkit/labelle-registry/main/providers.json";

/// Set to anything but empty or `0` to skip the no-provider diagnostic's
/// registry download (no network).
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
/// `providers resolve --accept` used, and the normalised document it bound,
/// in one file (one snapshot). Written after the lock commits; best effort.
/// It lives in `.labelle/`, so deleting that directory forgets it (#456).
pub const accepted_name = ".labelle/providers.registry.json";

/// The record's layout. Version 2 binds the source to its document by the
/// document's digest; a record without it (CLI 2.0.0) does not verify.
pub const accepted_schema: u8 = 2;

pub const Accepted = struct {
    schema_version: u8 = accepted_schema,
    /// An https URL, or the absolute path of a local file.
    source: []const u8,
    /// SHA-256 of `document`.
    document_sha256: []const u8,
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
/// normalised document it bound and that document's digest.
pub fn recordAccepted(a: std.mem.Allocator, root: []const u8, source: []const u8, document: []const u8) !void {
    const io = config.globalIo();
    const record: Accepted = .{ .source = try canonicalSource(a, source), .document_sha256 = try files.sha256Hex(a, document), .document = document };
    const dest = try std.fs.path.join(a, &.{ root, accepted_name });
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(dest).?);
    try files.writeAtomically(a, dest, try std.json.Stringify.valueAlloc(a, record, .{ .whitespace = .indent_2 }));
}

/// What the project's record says about its accepted source.
pub const AcceptedRecord = union(enum) {
    /// No record: nothing says the project uses a custom source.
    none,
    /// A record exists but does not verify (unreadable, another layout, a
    /// document that does not match its digest, a source that is not one
    /// printable line): the project's source is unknown.
    unverified,
    /// A record whose source and document come from one verified snapshot.
    verified: Accepted,
};

/// Read the project's record once and check the source and document
/// against that same snapshot.
pub fn readAccepted(a: std.mem.Allocator, root: []const u8) AcceptedRecord {
    const path = std.fs.path.join(a, &.{ root, accepted_name }) catch return .unverified;
    const bytes = files.read(a, path, 4 * max_document_bytes) catch |err| return switch (err) {
        error.FileNotFound => .none,
        else => .unverified,
    };
    const record = std.json.parseFromSliceLeaky(Accepted, a, bytes, .{ .allocate = .alloc_always }) catch return .unverified;
    if (record.schema_version != accepted_schema or record.source.len == 0) return .unverified;
    // The source is printed on a line of its own: no control bytes.
    for (record.source) |c| if (c < 0x20 or c == 0x7f) return .unverified;
    const digest = files.sha256Hex(a, record.document) catch return .unverified;
    if (!std.mem.eql(u8, digest, record.document_sha256)) return .unverified;
    return .{ .verified = record };
}

/// The owner a schema-2 document names for a target, and the release to
/// suggest: a candidate, whose compatibility with this CLI only
/// `providers resolve --accept` checks (the registry has no contract data, #456).
pub const OwnerHint = struct {
    package: []const u8,
    /// `<owner>/<name>` (the registry's form; `.plugins` takes it with a
    /// `github.com/` prefix).
    repo: []const u8,
    /// The newest release whose own record declares the target.
    version: []const u8,
    /// The project's verified custom source; null for the public registry.
    registry: ?[]const u8 = null,
};

pub const Reason = enum {
    /// `LABELLE_OFFLINE` is set: the public registry was not downloaded.
    offline,
    /// The download failed, was oversize, or did not parse.
    unreachable_registry,
    /// A schema-1 document: it publishes no target owners.
    no_owner_table,
    /// A schema-2 document lists no package for the target.
    not_listed,
    /// The project's accepted-source record does not verify, so its source
    /// is unknown (and the public registry is not asked in its place).
    unverified_source,
};

/// Why no owner is named; the diagnostic says which, so the path that ran
/// is visible. The steps stay generic either way.
pub const Miss = struct {
    reason: Reason,
    /// The document read was the project's custom source's.
    custom: bool = false,
};

pub const Lookup = union(enum) {
    hit: OwnerHint,
    miss: Miss,
};

/// The answer a parsed document gives for `target`: only a schema-2
/// document names an owner, with the newest release whose own record
/// declares the target (the ownership table is the union of a package's
/// releases, so its newest release may have dropped it).
pub fn ownerIn(doc: registry.Registry, target: []const u8, from: ?[]const u8) Lookup {
    const custom = from != null;
    if (!doc.claimsOwnership()) return .{ .miss = .{ .reason = .no_owner_table, .custom = custom } };
    const package = doc.targetOwner(target) orelse return .{ .miss = .{ .reason = .not_listed, .custom = custom } };
    const record = doc.latestDeclaring(package, target) orelse return .{ .miss = .{ .reason = .not_listed, .custom = custom } };
    return .{ .hit = .{ .package = package, .repo = record.repo, .version = record.version, .registry = from } };
}

/// The download the lookup uses: the real one, or a test's stand-in.
pub const Fetcher = *const fn (a: std.mem.Allocator, url: []const u8) anyerror![]const u8;

fn fetchLive(a: std.mem.Allocator, url: []const u8) anyerror![]const u8 {
    return download(a, url, Limits.hint);
}

/// The best-effort lookup behind the no-provider diagnostic. Never an error.
///
/// - A verified record of a custom source: that source's recorded document
///   answers. Nothing is downloaded.
/// - A record that does not verify: a miss. The project may use a custom
///   source, so the public registry is not asked in its place.
/// - No record, or a record of the public registry: one download of the
///   public registry, unless offline.
pub fn lookupOwner(a: std.mem.Allocator, root: ?[]const u8, target: []const u8, offline: bool, fetch: Fetcher) Lookup {
    if (root) |r| switch (readAccepted(a, r)) {
        .none => {},
        .unverified => return .{ .miss = .{ .reason = .unverified_source } },
        .verified => |record| if (!std.mem.eql(u8, record.source, registry_url)) {
            const doc = registry.parse(a, record.document) catch return .{ .miss = .{ .reason = .unverified_source } };
            return ownerIn(doc, target, record.source);
        },
    };
    if (offline) return .{ .miss = .{ .reason = .offline } };
    const bytes = fetch(a, registry_url) catch return .{ .miss = .{ .reason = .unreachable_registry } };
    if (bytes.len > max_document_bytes) return .{ .miss = .{ .reason = .unreachable_registry } };
    const doc = registry.parse(a, bytes) catch return .{ .miss = .{ .reason = .unreachable_registry } };
    return ownerIn(doc, target, null);
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

// ── Tests ────────────────────────────────────────────────────────────────

const AcceptFixture = @import("test_fixtures.zig").AcceptFixture;
const registry_cache = @import("registry_cache.zig");

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

const custom_doc = "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++
    testRecord("custom-owner", "2.0.0", "\"probe-target\"") ++ "," ++ testRecord("custom-owner", "2.1.0", "\"other-target\"") ++ "]}";

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

fn fetchSchemaOne(a: std.mem.Allocator, url: []const u8) anyerror![]const u8 {
    note(url);
    return a.dupe(u8, "{\"schema_version\":1,\"providers\":[]}");
}

fn fetchGarbage(a: std.mem.Allocator, url: []const u8) anyerror![]const u8 {
    note(url);
    return a.dupe(u8, "<html>not json</html>");
}

/// `live_doc` padded with trailing whitespace to `padded_len` bytes: still
/// a valid document, so only the size decides the outcome.
var padded_len: usize = 0;

fn fetchPadded(a: std.mem.Allocator, url: []const u8) anyerror![]const u8 {
    note(url);
    const out = try a.alloc(u8, padded_len);
    @memcpy(out[0..live_doc.len], live_doc);
    @memset(out[live_doc.len..], ' ');
    return out;
}

test "provider registry lookup: a public schema-2 hit names the owner and its newest declaring release (semver, not lexical)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    fetch_calls = 0;
    const hint = lookupOwner(a, fx.root, "probe-target", false, fetchLiveDoc).hit;
    try std.testing.expectEqual(@as(usize, 1), fetch_calls);
    try std.testing.expectEqualStrings(registry_url, fetched[0]);
    try std.testing.expectEqualStrings("fixture", hint.package);
    try std.testing.expectEqualStrings("owner/fixture", hint.repo);
    // The package's newest release (0.11.0) dropped `probe-target`: the
    // candidate is the newest release that still declares it.
    try std.testing.expectEqualStrings("0.10.0", hint.version);
    try std.testing.expect(hint.registry == null);
    try std.testing.expectEqualStrings("0.11.0", lookupOwner(a, fx.root, "later-target", false, fetchLiveDoc).hit.version);
    // The registry was reached and lists nobody for this target.
    const miss = lookupOwner(a, fx.root, "absent-target", false, fetchLiveDoc).miss;
    try std.testing.expectEqual(Reason.not_listed, miss.reason);
    try std.testing.expect(!miss.custom);
    try std.testing.expectEqual(@as(usize, 3), fetch_calls);
}

test "provider registry lookup: a schema-1 document names no owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    fetch_calls = 0;
    try std.testing.expectEqual(Reason.no_owner_table, lookupOwner(a, null, "probe-target", false, fetchSchemaOne).miss.reason);
    try std.testing.expectEqual(@as(usize, 1), fetch_calls);
}

test "provider registry lookup: offline never fetches; a failed, unparseable or oversize download is a miss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    // Offline: the fetcher is not called at all (it would have answered),
    // and no cached document answers in its place.
    try registry_cache.cacheRegistry(a, try AcceptFixture.schemaTwo(a, fx.pin, "\"probe\"", "\"probe-target\""));
    fetch_calls = 0;
    try std.testing.expectEqual(Reason.offline, lookupOwner(a, fx.root, "probe-target", true, fetchLiveDoc).miss.reason);
    try std.testing.expectEqual(@as(usize, 0), fetch_calls);
    try std.testing.expectEqual(Reason.unreachable_registry, lookupOwner(a, fx.root, "probe-target", false, fetchFails).miss.reason);
    try std.testing.expectEqual(Reason.unreachable_registry, lookupOwner(a, null, "probe-target", false, fetchGarbage).miss.reason);
    try std.testing.expectEqual(@as(usize, 2), fetch_calls);
    // The cap holds whatever the fetcher returns: the same valid document
    // answers at exactly 1 MiB and is refused one byte past it.
    padded_len = max_document_bytes;
    try std.testing.expectEqualStrings("0.10.0", lookupOwner(a, null, "probe-target", false, fetchPadded).hit.version);
    padded_len = max_document_bytes + 1;
    try std.testing.expectEqual(Reason.unreachable_registry, lookupOwner(a, null, "probe-target", false, fetchPadded).miss.reason);
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

test "provider registry lookup: a verified custom source answers from its recorded document, never the public registry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    // Accept from the fixture's LOCAL providers.json: the project records it.
    try fx.publishSchemaTwo(a, "\"probe\"", "");
    try fx.run(a, false);
    try fx.run(a, true);
    const accepted = readAccepted(a, fx.root).verified;
    try std.testing.expect(std.fs.path.isAbsolute(accepted.source));
    try std.testing.expect(std.mem.endsWith(u8, accepted.source, "providers.json"));
    // The recorded document lists `fixture` with no targets: not listed
    // there, and the public registry (which would say `fixture` 0.10.0) is
    // never asked.
    fetch_calls = 0;
    const miss = lookupOwner(a, fx.root, "probe-target", false, fetchLiveDoc).miss;
    try std.testing.expectEqual(Reason.not_listed, miss.reason);
    try std.testing.expect(miss.custom);
    try std.testing.expectEqual(@as(usize, 0), fetch_calls);
    // A recorded custom URL, online: its recorded document answers and
    // names the source; nothing is downloaded, not even from that URL.
    const fork = "https://example.test/fork registry/%20b%/providers.json";
    try recordAccepted(a, fx.root, fork, custom_doc);
    const hint = lookupOwner(a, fx.root, "probe-target", false, fetchLiveDoc).hit;
    try std.testing.expectEqualStrings("custom-owner", hint.package);
    try std.testing.expectEqualStrings("2.0.0", hint.version);
    try std.testing.expectEqualStrings(fork, hint.registry.?);
    try std.testing.expectEqual(Reason.not_listed, lookupOwner(a, fx.root, "later-target", true, fetchLiveDoc).miss.reason);
    try std.testing.expectEqual(@as(usize, 0), fetch_calls);
    // A recorded schema-1 custom document names nobody, still without a fetch.
    try recordAccepted(a, fx.root, fork, "{\"schema_version\":1,\"providers\":[]}");
    const one = lookupOwner(a, fx.root, "probe-target", false, fetchLiveDoc).miss;
    try std.testing.expectEqual(Reason.no_owner_table, one.reason);
    try std.testing.expect(one.custom);
    try std.testing.expectEqual(@as(usize, 0), fetch_calls);
    // A record of the public registry is the public path: one download.
    try recordAccepted(a, fx.root, registry_url, custom_doc);
    try std.testing.expectEqualStrings("fixture", lookupOwner(a, fx.root, "probe-target", false, fetchLiveDoc).hit.package);
    try std.testing.expectEqual(@as(usize, 1), fetch_calls);
}

test "provider registry lookup: a record that does not verify is a generic miss with no public fetch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try AcceptFixture.init(a);
    defer fx.deinit();
    const fork = "https://example.test/fork/providers.json";
    const path = try std.fs.path.join(a, &.{ fx.root, accepted_name });
    const cwd = std.Io.Dir.cwd();
    const io = config.globalIo();
    try recordAccepted(a, fx.root, fork, custom_doc);
    try std.testing.expect(readAccepted(a, fx.root) == .verified);
    const good = try files.read(a, path, 1024 * 1024);
    const digest = try files.sha256Hex(a, custom_doc);
    const other_doc = try std.mem.replaceOwned(u8, a, custom_doc, "2.0.0", "9.0.0");
    const other_json = try std.json.Stringify.valueAlloc(a, other_doc, .{});
    const cases = [_][]const u8{
        // Another snapshot's document under this digest.
        try std.json.Stringify.valueAlloc(a, Accepted{ .source = fork, .document_sha256 = digest, .document = other_doc }, .{}),
        // A CLI 2.0.0 record: no digest binds its source to its document.
        try std.fmt.allocPrint(a, "{{\"schema_version\":1,\"source\":\"{s}\",\"document\":{s}}}", .{ fork, other_json }),
        // A source that is not one printable line.
        try std.json.Stringify.valueAlloc(a, Accepted{ .source = "https://example.test/\x1b[2Jx", .document_sha256 = digest, .document = custom_doc }, .{}),
        // Not a record at all.
        "{ truncated",
    };
    fetch_calls = 0;
    for (cases) |bytes| {
        try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
        try std.testing.expect(readAccepted(a, fx.root) == .unverified);
        // Online, the public registry would answer: it is not asked.
        try std.testing.expectEqual(Reason.unverified_source, lookupOwner(a, fx.root, "probe-target", false, fetchLiveDoc).miss.reason);
    }
    try std.testing.expectEqual(@as(usize, 0), fetch_calls);
    // Control: the intact record answers from its document; with no record
    // at all the public registry is asked.
    try cwd.writeFile(io, .{ .sub_path = path, .data = good });
    try std.testing.expectEqualStrings("custom-owner", lookupOwner(a, fx.root, "probe-target", false, fetchLiveDoc).hit.package);
    try cwd.deleteFile(io, path);
    try std.testing.expect(readAccepted(a, fx.root) == .none);
    try std.testing.expectEqualStrings("fixture", lookupOwner(a, fx.root, "probe-target", false, fetchLiveDoc).hit.package);
    try std.testing.expectEqual(@as(usize, 1), fetch_calls);
}

test "provider registry lookup: the resolve and hint limits stay distinct and the url is the resolve default" {
    try std.testing.expect(!std.mem.eql(u8, Limits.resolve.max_time, Limits.hint.max_time));
    try std.testing.expect(std.mem.startsWith(u8, registry_url, "https://raw.githubusercontent.com/"));
}
