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

    /// The project declaration names this exact release. The repo is
    /// compared through `projectRepo`, so the host-qualified form the
    /// assembler fetches (`github.com/<owner>/<name>`) and the bare registry
    /// form (`<owner>/<name>`) both name the pin's repository; any other
    /// host never matches.
    pub fn matches(self: Pin, dep: project.PluginDep) bool {
        const repo = projectRepo(dep.repo) catch return false;
        return std.mem.eql(u8, self.package, dep.name) and std.mem.eql(u8, self.repo, repo) and std.mem.eql(u8, self.version, dep.version);
    }

    pub fn archiveUrl(self: Pin, a: std.mem.Allocator) ![]const u8 {
        try self.validate();
        return std.fmt.allocPrint(a, "https://codeload.github.com/{s}/tar.gz/{s}", .{ self.repo, self.commit });
    }
};

/// The single normaliser from a project `.plugins[].repo` to the bare
/// `<owner>/<name>` form registry records and locks carry (and codeload
/// URLs use). Every comparison of a pin with a project declaration goes
/// through it (`Pin.matches`), never through its own string handling.
///
/// Accepted spellings are the ones the assembler fetches as the same GitHub
/// repository (its `normalizeRemote`): an optional `git+`, an optional
/// `https://`, `http://`, `git://` or `ssh://` scheme, `user@` userinfo, the
/// `github.com` host (ASCII case-insensitive, as DNS is), a `?ref`/`#sha`
/// suffix, trailing slashes and a `.git` suffix are all dropped. The scp form
/// `git@github.com:<owner>/<name>` is not one of them: the assembler cannot
/// fetch it (it builds `https://git@github.com:<owner>/…`, an invalid port),
/// so it is `InvalidGitHubRepository` here too. The bare `<owner>/<name>`
/// form (no host) is kept for projects that declared it before. Owner and
/// name are returned byte for byte and compared exactly, as before: a pin
/// for `Owner/Name` does not match a project declaring `owner/name`.
///
/// Provider pins are GitHub archives only (contract §4), so a repo on any
/// other host is `NonGitHubProviderRepository`, never a match; anything
/// else that is not `<owner>/<name>` is `InvalidGitHubRepository`.
pub fn projectRepo(repo: []const u8) error{ NonGitHubProviderRepository, InvalidGitHubRepository }![]const u8 {
    var r = repo;
    if (std.ascii.startsWithIgnoreCase(r, "git+")) r = r["git+".len..];
    inline for (.{ "https://", "http://", "git://", "ssh://" }) |scheme| {
        if (std.ascii.startsWithIgnoreCase(r, scheme)) {
            r = r[scheme.len..];
            break;
        }
    }
    if (std.mem.indexOfAny(u8, r, "?#")) |i| r = r[0..i];
    while (r.len > 0 and r[r.len - 1] == '/') r = r[0 .. r.len - 1];
    if (std.mem.endsWith(u8, r, ".git")) r = r[0 .. r.len - ".git".len];
    const slashes = std.mem.count(u8, r, "/");
    if (slashes == 1) return checkedRepo(r);
    if (slashes == 0) return error.InvalidGitHubRepository;
    const authority = r[0..std.mem.indexOfScalar(u8, r, '/').?];
    // `ssh://git@github.com/<owner>/<name>`: `user@` userinfo is not part of
    // the host. The assembler keeps it in the URL it downloads
    // (`https://git@github.com/…/archive/…`), which GitHub serves as the
    // same repository, so it is dropped before the host comparison.
    const host = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority[at + 1 ..] else authority;
    if (!std.ascii.eqlIgnoreCase(host, github_host)) return error.NonGitHubProviderRepository;
    return checkedRepo(r[authority.len + 1 ..]);
}

pub const github_host = "github.com";

fn checkedRepo(repo: []const u8) error{InvalidGitHubRepository}![]const u8 {
    var parts = std.mem.splitScalar(u8, repo, '/');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidGitHubRepository;
        // A host or scp remnant (`git@github.com:owner`) is never a GitHub
        // owner or repository name.
        if (std.mem.indexOfAny(u8, part, "@:") != null) return error.InvalidGitHubRepository;
        count += 1;
    }
    if (count != 2) return error.InvalidGitHubRepository;
    return repo;
}

/// The diagnostic for a declared package whose `.repo` names another host.
pub fn reportNonGitHub(dep: project.PluginDep) void {
    std.debug.print("labelle: package '{s}' declares .repo = \"{s}\", which is not on GitHub; provider pins are GitHub archives only (codeload.github.com). Declare it as \"github.com/<owner>/<name>\".\n", .{ dep.name, dep.repo });
}

pub const Document = struct {
    schema_version: u8,
    providers: []const Pin,
};

fn lowerHex(text: []const u8, length: usize) bool {
    if (text.len != length) return false;
    for (text) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

/// The lock schema `providers resolve --accept` writes. Schema 1 (CLI 2.x)
/// stays readable; it records no registry source.
pub const lock_schema: u8 = 2;

/// Lock schema 2: the pins plus `registry`, the source the accept that
/// wrote them read (#456) — the public registry URL, a custom https URL, or
/// a local `providers.json` as a path relative to the project root with `/`
/// separators, so a committed lock names no machine's directories. It lives
/// outside `.labelle/`, so deleting generated output does not forget it.
pub const Lock = struct {
    schema_version: u8,
    registry: []const u8,
    providers: []const Pin,
};

pub const ParsedLock = struct {
    document: Document,
    /// Null for a schema-1 lock.
    registry: ?[]const u8,
};

/// A lock's `registry` is one printable line: non-empty, no control bytes.
/// `--accept` checks it before writing, so it never commits a lock this
/// parser would refuse.
pub fn checkRegistrySource(source: []const u8) !void {
    if (source.len == 0) return error.InvalidProviderRegistrySource;
    for (source) |c| if (c < 0x20 or c == 0x7f) return error.InvalidProviderRegistrySource;
}

/// Strict, like every lock read: schema 1 may not carry `registry`, schema 2
/// must, as one printable line.
pub fn parseLock(a: std.mem.Allocator, bytes: []const u8) !ParsedLock {
    const Head = struct { schema_version: u8 };
    const head = try std.json.parseFromSliceLeaky(Head, a, bytes, .{ .ignore_unknown_fields = true });
    switch (head.schema_version) {
        1 => {
            const doc = try std.json.parseFromSliceLeaky(Document, a, bytes, .{ .allocate = .alloc_always });
            try checkPins(doc.providers, true);
            return .{ .document = doc, .registry = null };
        },
        lock_schema => {
            const lock = try std.json.parseFromSliceLeaky(Lock, a, bytes, .{ .allocate = .alloc_always });
            try checkRegistrySource(lock.registry);
            try checkPins(lock.providers, true);
            return .{ .document = .{ .schema_version = lock.schema_version, .providers = lock.providers }, .registry = lock.registry };
        },
        else => return error.UnsupportedProviderSchema,
    }
}

/// The project integrity lock (either lock schema, `parseLock`) or a
/// schema-1 registry; locks allow one pin/package. Registry documents are
/// read through `provider_registry.parse`, which also accepts schemas 2 and 3.
pub fn parse(a: std.mem.Allocator, bytes: []const u8, is_lock: bool) !Document {
    if (is_lock) return (try parseLock(a, bytes)).document;
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
    try std.testing.expectError(error.UnsupportedProviderSchema, parse(a, "{\"schema_version\":3,\"registry\":\"x\",\"providers\":[]}", true));
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

test "provider github: a project repo matches its pin in the GitHub forms the assembler fetches" {
    const pin: Pin = .{ .package = "fixture", .repo = "owner/repo", .version = "1.0.0", .commit = "1" ** 40, .sha256 = "a" ** 64 };
    const Case = struct { repo: []const u8, matches: bool };
    for ([_]Case{
        // The assembler's form and the bare registry form.
        .{ .repo = "github.com/owner/repo", .matches = true },
        .{ .repo = "owner/repo", .matches = true },
        // Every other spelling the assembler resolves to the same repository.
        .{ .repo = "https://github.com/owner/repo", .matches = true },
        .{ .repo = "https://github.com/owner/repo.git", .matches = true },
        .{ .repo = "git+https://github.com/owner/repo?ref=main", .matches = true },
        .{ .repo = "GitHub.COM/owner/repo/", .matches = true },
        // `ssh://` with `user@` userinfo: the host is still github.com,
        // case-insensitively (#460 review).
        .{ .repo = "ssh://git@github.com/owner/repo", .matches = true },
        .{ .repo = "SSH://git@GitHub.com/owner/repo.git", .matches = true },
        .{ .repo = "git+ssh://git@github.com/owner/repo", .matches = true },
        .{ .repo = "ssh://git@gitlab.com/owner/repo", .matches = false },
        .{ .repo = "ssh://github.com@evil.com/owner/repo", .matches = false },
        // The scp form is not fetched by the assembler, so it never matches.
        .{ .repo = "git@github.com:owner/repo", .matches = false },
        .{ .repo = "git@github.com:owner/repo.git", .matches = false },
        // Owner/name are compared exactly, host or not (unchanged).
        .{ .repo = "github.com/Owner/repo", .matches = false },
        .{ .repo = "Owner/Repo", .matches = false },
        // Another host never matches, even with the same owner/name.
        .{ .repo = "gitlab.com/owner/repo", .matches = false },
        .{ .repo = "https://codeberg.org/owner/repo", .matches = false },
        .{ .repo = "github.com.evil/owner/repo", .matches = false },
        .{ .repo = "github.com/owner/repo/extra", .matches = false },
        .{ .repo = "repo", .matches = false },
        .{ .repo = "", .matches = false },
    }) |case| {
        const dep: project.PluginDep = .{ .name = "fixture", .repo = case.repo, .version = "1.0.0" };
        std.testing.expectEqual(case.matches, pin.matches(dep)) catch |err| {
            std.debug.print("repo '{s}'\n", .{case.repo});
            return err;
        };
    }
    // The helper says WHY: another host is its own error, named for the diagnostic.
    try std.testing.expectEqualStrings("owner/repo", try projectRepo("github.com/owner/repo"));
    try std.testing.expectEqualStrings("owner/repo", try projectRepo("owner/repo"));
    try std.testing.expectError(error.NonGitHubProviderRepository, projectRepo("gitlab.com/owner/repo"));
    try std.testing.expectError(error.NonGitHubProviderRepository, projectRepo("https://codeberg.org/owner/repo"));
    try std.testing.expectError(error.InvalidGitHubRepository, projectRepo("github.com/owner/repo/extra"));
    try std.testing.expectError(error.InvalidGitHubRepository, projectRepo("github.com/../repo"));
    try std.testing.expectError(error.InvalidGitHubRepository, projectRepo("repo"));
    try std.testing.expectEqualStrings("owner/repo", try projectRepo("ssh://git@github.com/owner/repo"));
    try std.testing.expectEqualStrings("owner/repo", try projectRepo("ssh://Git@GITHUB.com/owner/repo.git"));
    try std.testing.expectError(error.NonGitHubProviderRepository, projectRepo("ssh://git@gitlab.com/owner/repo"));
    try std.testing.expectError(error.NonGitHubProviderRepository, projectRepo("ssh://github.com@evil.com/owner/repo"));
    try std.testing.expectError(error.InvalidGitHubRepository, projectRepo("git@github.com:owner/repo"));
    try std.testing.expectError(error.InvalidGitHubRepository, projectRepo("git@github.com:owner/repo.git"));
    // Name and version still have to match.
    try std.testing.expect(!pin.matches(.{ .name = "other", .repo = "github.com/owner/repo", .version = "1.0.0" }));
    try std.testing.expect(!pin.matches(.{ .name = "fixture", .repo = "github.com/owner/repo", .version = "1.0.1" }));
}

test "provider github: lock schema 2 records the registry source; schema 1 stays readable; both are strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pin = "{\"package\":\"fixture\",\"repo\":\"owner/fixture\",\"version\":\"1.0.0\",\"commit\":\"" ++ "1" ** 40 ++ "\",\"sha256\":\"" ++ "a" ** 64 ++ "\"}";
    const one = try parseLock(a, "{\"schema_version\":1,\"providers\":[" ++ pin ++ "]}");
    try std.testing.expect(one.registry == null);
    try std.testing.expectEqual(@as(usize, 1), one.document.providers.len);
    const two = try parseLock(a, "{\"schema_version\":2,\"registry\":\"../my registry/providers.json\",\"providers\":[" ++ pin ++ "]}");
    try std.testing.expectEqualStrings("../my registry/providers.json", two.registry.?);
    try std.testing.expectEqualStrings("fixture", (try parse(a, "{\"schema_version\":2,\"registry\":\"x\",\"providers\":[" ++ pin ++ "]}", true)).providers[0].package);
    try std.testing.expectError(error.UnknownField, parseLock(a, "{\"schema_version\":1,\"registry\":\"x\",\"providers\":[]}"));
    try std.testing.expectError(error.MissingField, parseLock(a, "{\"schema_version\":2,\"providers\":[]}"));
    try std.testing.expectError(error.InvalidProviderRegistrySource, parseLock(a, "{\"schema_version\":2,\"registry\":\"\",\"providers\":[]}"));
    try std.testing.expectError(error.InvalidProviderRegistrySource, parseLock(a, "{\"schema_version\":2,\"registry\":\"a\\u001bb\",\"providers\":[]}"));
    try std.testing.expectError(error.UnsupportedProviderSchema, parseLock(a, "{\"schema_version\":3,\"registry\":\"x\",\"providers\":[]}"));
    // The same rule `--accept` applies before it writes (a POSIX path may hold a newline).
    try std.testing.expectError(error.InvalidProviderRegistrySource, checkRegistrySource("../reg\nistry/providers.json"));
    try checkRegistrySource("../my registry/providers.json");
    try std.testing.expectError(error.DuplicateProviderRelease, parseLock(a, "{\"schema_version\":2,\"registry\":\"x\",\"providers\":[" ++ pin ++ "," ++ pin ++ "]}"));
    // A registry document is still schema 1 only through this parser.
    try std.testing.expectError(error.UnknownField, parse(a, "{\"schema_version\":2,\"registry\":\"x\",\"providers\":[]}", false));
}
