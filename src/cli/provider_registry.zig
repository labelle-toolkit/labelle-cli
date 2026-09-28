//! The registry document: `providers.json` in `labelle-registry`
//! (contract §4, docs/provider-contract-v1.md).
//!
//! Schema 1 is the pin list alone. Schema 2 adds what the CLI needs before a
//! provider is pinned, or even cached (#411):
//!
//! - every release record states the `namespace` and `targets` its
//!   `plugin.labelle` declares, so a missing target or namespace is looked up
//!   by name (`targetOwner`, `namespaceOwner`) instead of by reading archives;
//! - a top-level `defaults` list names the exact releases `labelle init`
//!   proposes to a new project (`defaultPins`).
//!
//! Schema 3 adds each release's `command_contract` (the range its
//! `plugin.labelle` declares), so a hint can name a release this CLI can
//! speak to (`latestSupported`) instead of the newest one by version (#456).
//!
//! All of them are claims, not authority. `providers resolve --accept` checks each
//! release it pins against its verified manifest (`checkDeclarations`), so a
//! pinned release never disagrees with the table that pointed at it. Defaults
//! are suggestions resolved to exact records for a consent prompt; nothing
//! here writes a pin or runs package code.
const std = @import("std");
const github = @import("provider_github.zig");
const contract = @import("provider_contract.zig");
const manifest = @import("provider_manifest.zig");
const compat = @import("compatibility.zig");

/// The newest registry schema this CLI reads. Schemas 1 and 2 stay readable.
pub const latest_schema: u8 = 3;

/// A release record of a schema-2 or schema-3 document: the pin fields plus
/// the release's declarations. On the wire both declaration fields are
/// required (strict like the wire context): an absent `namespace` is an
/// error, a release without one says `null`. `command_contract` is required
/// in schema 3, refused in schema 2, and null here for a schema-2 record.
pub const Record = struct {
    package: []const u8,
    repo: []const u8,
    version: []const u8,
    commit: []const u8,
    sha256: []const u8,
    namespace: ?[]const u8,
    targets: []const []const u8,
    command_contract: ?[]const u8 = null,

    fn two(self: Record) RecordTwo {
        return .{ .package = self.package, .repo = self.repo, .version = self.version, .commit = self.commit, .sha256 = self.sha256, .namespace = self.namespace, .targets = self.targets };
    }

    fn three(self: Record) RecordThree {
        return .{ .package = self.package, .repo = self.repo, .version = self.version, .commit = self.commit, .sha256 = self.sha256, .namespace = self.namespace, .targets = self.targets, .command_contract = self.command_contract.? };
    }

    /// Whether this CLI speaks a provider contract version the release's
    /// recorded `command_contract` admits. False without a recorded range.
    pub fn supported(self: Record) bool {
        _ = manifest.negotiate(self.command_contract orelse return false) catch return false;
        return true;
    }

    pub fn pin(self: Record) github.Pin {
        return .{ .package = self.package, .repo = self.repo, .version = self.version, .commit = self.commit, .sha256 = self.sha256 };
    }

    /// This release's OWN record declares `declaration`.
    pub fn declares(self: Record, declaration: Declaration) bool {
        switch (declaration) {
            .namespace => |ns| return self.namespace != null and std.mem.eql(u8, self.namespace.?, ns),
            .target => |target| {
                for (self.targets) |t| if (std.mem.eql(u8, t, target)) return true;
                return false;
            },
        }
    }
};

/// A name a release declares that the CLI may have to look up an owner
/// for: a build target (`--platform=<t>`) or a command namespace
/// (`labelle <namespace> ...`).
pub const Declaration = union(enum) {
    target: []const u8,
    namespace: []const u8,

    pub fn name(self: Declaration) []const u8 {
        return switch (self) {
            inline else => |value| value,
        };
    }
};

/// One default package: an exact release, never a bare name or a range, so
/// the consent prompt shows the exact bytes that would be pinned.
pub const DefaultRef = struct { package: []const u8, version: []const u8 };

/// The schema-2 wire record.
const RecordTwo = struct {
    package: []const u8,
    repo: []const u8,
    version: []const u8,
    commit: []const u8,
    sha256: []const u8,
    namespace: ?[]const u8,
    targets: []const []const u8,
};

/// The schema-3 wire record: schema 2 plus the release's `command_contract`.
const RecordThree = struct {
    package: []const u8,
    repo: []const u8,
    version: []const u8,
    commit: []const u8,
    sha256: []const u8,
    namespace: ?[]const u8,
    targets: []const []const u8,
    command_contract: []const u8,
};

fn Wire(comptime R: type) type {
    return struct {
        schema_version: u8,
        defaults: []const DefaultRef,
        providers: []const R,
    };
}

pub const Registry = struct {
    schema_version: u8,
    pins: []const github.Pin,
    /// Schema 2 only; empty for schema 1, which makes no claims.
    records: []const Record = &.{},
    defaults: []const DefaultRef = &.{},
    /// One entry per package: the union of its releases' declarations.
    ownership: []const contract.Ownership = &.{},

    pub fn claimsOwnership(self: Registry) bool {
        return self.schema_version >= 2;
    }

    /// Schema 3: every record carries its release's `command_contract`.
    pub fn carriesContracts(self: Registry) bool {
        return self.schema_version >= 3;
    }

    /// The package whose releases declare `target`, or null. Schema 1 never
    /// answers: its records carry no declarations.
    pub fn targetOwner(self: Registry, target: []const u8) ?[]const u8 {
        return contract.providerForTarget(self.ownership, target);
    }

    /// The package whose releases declare `namespace`, or null.
    pub fn namespaceOwner(self: Registry, namespace: []const u8) ?[]const u8 {
        for (self.ownership) |entry| {
            for (entry.namespaces) |declared| {
                if (std.mem.eql(u8, declared, namespace)) return entry.package;
            }
        }
        return null;
    }

    /// The package whose releases declare `declaration`, or null.
    pub fn owner(self: Registry, declaration: Declaration) ?[]const u8 {
        return switch (declaration) {
            .target => |target| self.targetOwner(target),
            .namespace => |ns| self.namespaceOwner(ns),
        };
    }

    /// The exact records the default list names, in its order: what a
    /// consent prompt presents before anything is pinned or run.
    pub fn defaultPins(self: Registry, a: std.mem.Allocator) ![]const github.Pin {
        const pins = try a.alloc(github.Pin, self.defaults.len);
        for (self.defaults, pins) |ref, *out| out.* = (self.find(ref.package, ref.version) orelse return error.UnknownDefaultRelease).pin();
        return pins;
    }

    /// The newest release of `package` whose OWN record declares
    /// `declaration`, or null. The ownership table is the union of a
    /// package's releases, so the package's newest release may have dropped
    /// a target or namespace an older one declares; a suggestion must name a
    /// release that still provides it. Schema 2 or 3 (schema-1 records
    /// declare nothing).
    pub fn latestDeclaring(self: Registry, package: []const u8, declaration: Declaration) ?Record {
        return self.newest(package, declaration, false);
    }

    /// `latestDeclaring` narrowed, in schema 3, to releases whose recorded
    /// `command_contract` this CLI supports (#456). A schema-2 document
    /// records no contract, so there it is `latestDeclaring` unchanged: a
    /// candidate `--accept` still checks.
    pub fn latestSupported(self: Registry, package: []const u8, declaration: Declaration) ?Record {
        return self.newest(package, declaration, self.carriesContracts());
    }

    fn newest(self: Registry, package: []const u8, declaration: Declaration, supported_only: bool) ?Record {
        var best: ?Record = null;
        for (self.records) |record| {
            if (!std.mem.eql(u8, record.package, package) or !record.declares(declaration)) continue;
            if (supported_only and !record.supported()) continue;
            if (best == null or releaseNewer(record.version, best.?.version)) best = record;
        }
        return best;
    }

    /// The schema-2 record for one release, or null (always null for schema 1).
    pub fn find(self: Registry, package: []const u8, version: []const u8) ?Record {
        for (self.records) |record| {
            if (std.mem.eql(u8, record.package, package) and std.mem.eql(u8, record.version, version)) return record;
        }
        return null;
    }

    /// The document in canonical form: compact JSON of exactly the fields its
    /// schema defines, in declaration order, records in document order. It
    /// parses back to the same `Registry`, so two documents with the same
    /// normalised bytes are the same document whatever their whitespace or
    /// key order. Its SHA-256 is what a provider preview binds (#433).
    pub fn normalised(self: Registry, a: std.mem.Allocator) ![]const u8 {
        if (!self.claimsOwnership()) return std.json.Stringify.valueAlloc(a, github.Document{ .schema_version = self.schema_version, .providers = self.pins }, .{});
        if (!self.carriesContracts()) {
            const records = try a.alloc(RecordTwo, self.records.len);
            for (self.records, records) |record, *out| out.* = record.two();
            return std.json.Stringify.valueAlloc(a, Wire(RecordTwo){ .schema_version = self.schema_version, .defaults = self.defaults, .providers = records }, .{});
        }
        const records = try a.alloc(RecordThree, self.records.len);
        for (self.records, records) |record, *out| out.* = record.three();
        return std.json.Stringify.valueAlloc(a, Wire(RecordThree){ .schema_version = self.schema_version, .defaults = self.defaults, .providers = records }, .{});
    }

    /// The verified manifest of a release about to be pinned must declare
    /// exactly what its record claims: same namespace, same set of targets,
    /// and in schema 3 the same `command_contract` text. A schema-1 document
    /// claims nothing, so there is nothing to check.
    pub fn checkDeclarations(self: Registry, pin: github.Pin, meta: manifest.Manifest) !void {
        if (!self.claimsOwnership()) return;
        const record = self.find(pin.package, pin.version) orelse return error.ProviderReleaseNotInRegistry;
        const same_namespace = if (record.namespace) |claimed|
            meta.namespace != null and std.mem.eql(u8, claimed, meta.namespace.?)
        else
            meta.namespace == null;
        const same_contract = if (record.command_contract) |claimed|
            meta.command_contract != null and std.mem.eql(u8, claimed, meta.command_contract.?)
        else
            true;
        if (same_namespace and same_contract and sameSet(record.targets, meta.targets)) return;
        std.debug.print("labelle: registry record {s} {s} does not match its verified plugin.labelle (namespace/targets/command_contract); the registry entry must be corrected\n", .{ pin.package, pin.version });
        return error.RegistryDeclarationMismatch;
    }
};

/// Semver order (`0.10.0` beats `0.9.0`; pins are plain `x.y.z`,
/// `checkPins`): is `candidate` newer than `current`?
fn releaseNewer(candidate: []const u8, current: []const u8) bool {
    const cand = std.SemanticVersion.parse(candidate) catch return false;
    const cur = std.SemanticVersion.parse(current) catch return true;
    return cand.order(cur) == .gt;
}

/// Both lists are duplicate-free (records by `parse`, manifests by
/// `manifest.validate`/`validateOwnership`), so equal length plus inclusion
/// is set equality.
fn sameSet(left: []const []const u8, right: []const []const u8) bool {
    if (left.len != right.len) return false;
    outer: for (left) |name| {
        for (right) |other| {
            if (std.mem.eql(u8, name, other)) continue :outer;
        }
        return false;
    }
    return true;
}

/// Strict, like the lock: duplicate keys, unknown fields and unsupported
/// schemas are errors; schema 1 must not carry schema-2 fields. Every string
/// lands on `a` (an arena in every caller).
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Registry {
    const Head = struct { schema_version: u8 };
    const head = try std.json.parseFromSliceLeaky(Head, a, bytes, .{ .ignore_unknown_fields = true });
    const doc: Wire(Record) = switch (head.schema_version) {
        1 => return .{ .schema_version = 1, .pins = (try github.parse(a, bytes, false)).providers },
        2 => try fromWire(RecordTwo, a, try std.json.parseFromSliceLeaky(Wire(RecordTwo), a, bytes, .{ .allocate = .alloc_always })),
        3 => try fromWire(RecordThree, a, try std.json.parseFromSliceLeaky(Wire(RecordThree), a, bytes, .{ .allocate = .alloc_always })),
        else => return error.UnsupportedProviderSchema,
    };
    const pins = try a.alloc(github.Pin, doc.providers.len);
    for (doc.providers, pins) |record, *out| out.* = record.pin();
    try github.checkPins(pins, false);
    // Each claim is shaped like the manifest declaration it mirrors.
    for (doc.providers) |record| {
        if (record.namespace) |ns| if (!contract.identifier(ns)) return error.InvalidNamespace;
        // A range, shaped like the manifest's; whether THIS CLI speaks it is
        // not checked here (one registry serves every CLI version).
        if (record.command_contract) |range| _ = compat.parseRange(range) catch return error.InvalidCommandContract;
        for (record.targets, 0..) |target, i| {
            if (!contract.identifier(target)) return error.InvalidTarget;
            if (!contract.targetName(target)) return error.ReservedDeviceTarget;
            for (record.targets[0..i]) |prev| if (std.mem.eql(u8, prev, target)) return error.DuplicateName;
        }
    }
    const ownership = try ownershipTable(a, doc.providers);
    // Cross-package conflicts and the core `desktop` target. Namespaces the
    // running CLI reserves are deliberately not checked here: a registry
    // lists packages for every CLI version, and dispatch refuses a reserved
    // namespace where it matters.
    try contract.validateOwnership(ownership, &.{});
    for (doc.defaults, 0..) |ref, i| {
        for (doc.defaults[0..i]) |prev| if (std.mem.eql(u8, prev.package, ref.package)) return error.DuplicateDefaultPackage;
    }
    const registry: Registry = .{ .schema_version = head.schema_version, .pins = pins, .records = doc.providers, .defaults = doc.defaults, .ownership = ownership };
    _ = try registry.defaultPins(a);
    return registry;
}

/// A wire document as the common `Record` form (a schema-2 record has no
/// `command_contract`).
fn fromWire(comptime R: type, a: std.mem.Allocator, wire: Wire(R)) !Wire(Record) {
    const records = try a.alloc(Record, wire.providers.len);
    for (wire.providers, records) |record, *out| {
        out.* = .{ .package = record.package, .repo = record.repo, .version = record.version, .commit = record.commit, .sha256 = record.sha256, .namespace = record.namespace, .targets = record.targets };
        if (R == RecordThree) out.command_contract = record.command_contract;
    }
    return .{ .schema_version = wire.schema_version, .defaults = wire.defaults, .providers = records };
}

/// Group release claims by package, deduplicated, keeping first-seen order.
fn ownershipTable(a: std.mem.Allocator, records: []const Record) ![]const contract.Ownership {
    var table: std.ArrayList(contract.Ownership) = .empty;
    var namespaces: std.ArrayList(std.ArrayList([]const u8)) = .empty;
    var targets: std.ArrayList(std.ArrayList([]const u8)) = .empty;
    for (records) |record| {
        const index = for (table.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.package, record.package)) break i;
        } else blk: {
            try table.append(a, .{ .package = record.package, .namespaces = &.{}, .targets = &.{} });
            try namespaces.append(a, .empty);
            try targets.append(a, .empty);
            break :blk table.items.len - 1;
        };
        if (record.namespace) |ns| try addUnique(a, &namespaces.items[index], ns);
        for (record.targets) |target| try addUnique(a, &targets.items[index], target);
    }
    for (table.items, namespaces.items, targets.items) |*entry, ns, ts| {
        entry.namespaces = ns.items;
        entry.targets = ts.items;
    }
    return table.items;
}

fn addUnique(a: std.mem.Allocator, list: *std.ArrayList([]const u8), name: []const u8) !void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, name)) return;
    try list.append(a, name);
}

const commit_a = "1" ** 40;
const hash_a = "a" ** 64;

inline fn testRecord(comptime package: []const u8, comptime version: []const u8, comptime namespace: []const u8, comptime targets: []const u8) []const u8 {
    return "{\"package\":\"" ++ package ++ "\",\"repo\":\"owner/" ++ package ++ "\",\"version\":\"" ++ version ++
        "\",\"commit\":\"" ++ commit_a ++ "\",\"sha256\":\"" ++ hash_a ++ "\",\"namespace\":" ++ namespace ++ ",\"targets\":[" ++ targets ++ "]}";
}

test "provider registry: schema 1 stays readable and claims nothing; schema 2 fields are strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try parse(a, "{\"schema_version\":1,\"providers\":[{\"package\":\"fixture\",\"repo\":\"owner/fixture\",\"version\":\"1.0.0\",\"commit\":\"" ++ commit_a ++ "\",\"sha256\":\"" ++ hash_a ++ "\"}]}");
    try std.testing.expectEqual(@as(usize, 1), one.pins.len);
    try std.testing.expect(!one.claimsOwnership());
    try std.testing.expect(one.targetOwner("probe-target") == null);
    // Schema 1 may not smuggle in schema-2 claims.
    try std.testing.expectError(error.UnknownField, parse(a, "{\"schema_version\":1,\"defaults\":[],\"providers\":[]}"));
    try std.testing.expectError(error.UnknownField, parse(a, "{\"schema_version\":1,\"providers\":[" ++ testRecord("fixture", "1.0.0", "null", "") ++ "]}"));
    // Schema 2 requires the claims and the defaults list, explicitly.
    try std.testing.expectError(error.MissingField, parse(a, "{\"schema_version\":2,\"providers\":[]}"));
    try std.testing.expectError(error.MissingField, parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[{\"package\":\"fixture\",\"repo\":\"owner/fixture\",\"version\":\"1.0.0\",\"commit\":\"" ++ commit_a ++ "\",\"sha256\":\"" ++ hash_a ++ "\",\"targets\":[]}]}"));
    try std.testing.expectError(error.UnknownField, parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[],\"extra\":1}"));
    try std.testing.expectError(error.UnsupportedProviderSchema, parse(a, "{\"schema_version\":4,\"defaults\":[],\"providers\":[]}"));
    // A contract belongs to schema 3 only.
    try std.testing.expectError(error.UnknownField, parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++ contractRecord("fixture", "1.0.0", ">=1.0.0 <2.0.0") ++ "]}"));
    try std.testing.expectError(error.DuplicateField, parse(a, "{\"schema_version\":2,\"schema_version\":2,\"defaults\":[],\"providers\":[]}"));
    // The pin rules still apply to schema-2 records.
    try std.testing.expectError(error.DuplicateProviderRelease, parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++ testRecord("fixture", "1.0.0", "null", "") ++ "," ++ testRecord("fixture", "1.0.0", "null", "") ++ "]}"));
    const two = try parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++ testRecord("fixture", "1.0.0", "\"probe\"", "\"probe-target\"") ++ "]}");
    try std.testing.expect(two.claimsOwnership());
    try std.testing.expectEqualStrings(commit_a, two.pins[0].commit);
}

test "provider registry: target and namespace lookup by name, conflicts rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two releases of one package may differ; the table is their union.
    const doc = try parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++
        testRecord("fixture", "1.0.0", "\"probe\"", "\"probe-target\"") ++ "," ++
        testRecord("fixture", "1.1.0", "\"probe\"", "\"probe-target\",\"second-target\"") ++ "," ++
        testRecord("other", "1.0.0", "null", "\"other-target\"") ++ "]}");
    try std.testing.expectEqualStrings("fixture", doc.targetOwner("probe-target").?);
    try std.testing.expectEqualStrings("fixture", doc.targetOwner("second-target").?);
    try std.testing.expectEqualStrings("other", doc.targetOwner("other-target").?);
    try std.testing.expect(doc.targetOwner("missing-target") == null);
    try std.testing.expectEqualStrings("fixture", doc.namespaceOwner("probe").?);
    try std.testing.expect(doc.namespaceOwner("other") == null);
    try std.testing.expectEqual(@as(usize, 2), doc.ownership.len);
    try std.testing.expectEqual(@as(usize, 2), doc.ownership[0].targets.len);
    // One owner per name across packages, and core keeps `desktop`.
    try std.testing.expectError(error.TargetConflict, parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++
        testRecord("fixture", "1.0.0", "null", "\"probe-target\"") ++ "," ++ testRecord("other", "1.0.0", "null", "\"probe-target\"") ++ "]}"));
    try std.testing.expectError(error.NamespaceConflict, parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++
        testRecord("fixture", "1.0.0", "\"probe\"", "") ++ "," ++ testRecord("other", "1.0.0", "\"probe\"", "") ++ "]}"));
    try std.testing.expectError(error.ReservedTarget, parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++ testRecord("fixture", "1.0.0", "null", "\"desktop\"") ++ "]}"));
    try std.testing.expectError(error.ReservedDeviceTarget, parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++ testRecord("fixture", "1.0.0", "null", "\"nul\"") ++ "]}"));
    try std.testing.expectError(error.InvalidTarget, parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++ testRecord("fixture", "1.0.0", "null", "\"Bad\"") ++ "]}"));
    try std.testing.expectError(error.InvalidNamespace, parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++ testRecord("fixture", "1.0.0", "\"Bad\"", "") ++ "]}"));
    try std.testing.expectError(error.DuplicateName, parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++ testRecord("fixture", "1.0.0", "null", "\"probe-target\",\"probe-target\"") ++ "]}"));
}

test "provider registry: defaults resolve to exact releases for consent, never to a bare name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const providers = "\"providers\":[" ++ testRecord("fixture", "1.0.0", "null", "") ++ "," ++ testRecord("fixture", "1.1.0", "null", "") ++ "," ++ testRecord("other", "2.0.0", "null", "") ++ "]}";
    const doc = try parse(a, "{\"schema_version\":2,\"defaults\":[{\"package\":\"other\",\"version\":\"2.0.0\"},{\"package\":\"fixture\",\"version\":\"1.0.0\"}]," ++ providers);
    const pins = try doc.defaultPins(a);
    try std.testing.expectEqual(@as(usize, 2), pins.len);
    try std.testing.expectEqualStrings("other", pins[0].package);
    // The exact release named, not the newest one of the package.
    try std.testing.expectEqualStrings("fixture", pins[1].package);
    try std.testing.expectEqualStrings("1.0.0", pins[1].version);
    try std.testing.expectEqualStrings(hash_a, pins[1].sha256);
    try std.testing.expectError(error.UnknownDefaultRelease, parse(a, "{\"schema_version\":2,\"defaults\":[{\"package\":\"fixture\",\"version\":\"9.0.0\"}]," ++ providers));
    try std.testing.expectError(error.UnknownDefaultRelease, parse(a, "{\"schema_version\":2,\"defaults\":[{\"package\":\"absent\",\"version\":\"1.0.0\"}]," ++ providers));
    try std.testing.expectError(error.DuplicateDefaultPackage, parse(a, "{\"schema_version\":2,\"defaults\":[{\"package\":\"fixture\",\"version\":\"1.0.0\"},{\"package\":\"fixture\",\"version\":\"1.1.0\"}]," ++ providers));
    try std.testing.expectError(error.MissingField, parse(a, "{\"schema_version\":2,\"defaults\":[{\"package\":\"fixture\"}]," ++ providers));
}

test "provider registry: the suggested release is the newest one in semver order, not document or lexical order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++
        testRecord("fixture", "0.9.0", "null", "\"t\"") ++ "," ++ testRecord("fixture", "0.10.0", "null", "\"t\"") ++ "," ++
        testRecord("fixture", "0.2.1", "null", "\"t\"") ++ "," ++ testRecord("other", "9.0.0", "null", "\"u\"") ++ "]}");
    try std.testing.expectEqualStrings("0.10.0", doc.latestDeclaring("fixture", .{ .target = "t" }).?.version);
    try std.testing.expectEqualStrings("9.0.0", doc.latestDeclaring("other", .{ .target = "u" }).?.version);
    try std.testing.expect(doc.latestDeclaring("absent", .{ .target = "t" }) == null);
}

test "provider registry: the suggested release for a target is the newest one that still declares it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 0.10.0 dropped `probe-target`; the union table still names `fixture`.
    const doc = try parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++
        testRecord("fixture", "0.2.0", "null", "\"probe-target\"") ++ "," ++ testRecord("fixture", "0.9.0", "null", "\"probe-target\"") ++ "," ++
        testRecord("fixture", "0.10.0", "null", "\"second-target\"") ++ "]}");
    try std.testing.expectEqualStrings("fixture", doc.targetOwner("probe-target").?);
    try std.testing.expectEqualStrings("0.9.0", doc.latestDeclaring("fixture", .{ .target = "probe-target" }).?.version);
    try std.testing.expectEqualStrings("0.10.0", doc.latestDeclaring("fixture", .{ .target = "second-target" }).?.version);
    try std.testing.expect(doc.latestDeclaring("fixture", .{ .target = "absent-target" }) == null);
    try std.testing.expect(doc.latestDeclaring("absent", .{ .target = "probe-target" }) == null);
}

test "provider registry: the suggested release for a namespace is the newest one that still declares it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 0.10.0 dropped the `probe` namespace; the union table still names `fixture`.
    const doc = try parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++
        testRecord("fixture", "0.2.0", "\"probe\"", "") ++ "," ++ testRecord("fixture", "0.9.0", "\"probe\"", "\"probe-target\"") ++ "," ++
        testRecord("fixture", "0.10.0", "null", "\"probe-target\"") ++ "]}");
    try std.testing.expectEqualStrings("fixture", doc.owner(.{ .namespace = "probe" }).?);
    try std.testing.expectEqualStrings("0.9.0", doc.latestDeclaring("fixture", .{ .namespace = "probe" }).?.version);
    try std.testing.expectEqualStrings("0.10.0", doc.latestDeclaring("fixture", .{ .target = "probe-target" }).?.version);
    // A target is not a namespace, and the reverse.
    try std.testing.expect(doc.owner(.{ .namespace = "probe-target" }) == null);
    try std.testing.expect(doc.owner(.{ .target = "probe" }) == null);
    try std.testing.expect(doc.latestDeclaring("fixture", .{ .namespace = "absent" }) == null);
}

test "provider registry: a pinned release must declare exactly what its record claims" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++ testRecord("fixture", "1.0.0", "\"probe\"", "\"probe-target\",\"second-target\"") ++ "]}");
    const pin = doc.pins[0];
    const exact: manifest.Manifest = .{ .name = "fixture", .namespace = "probe", .targets = &.{ "second-target", "probe-target" } };
    try doc.checkDeclarations(pin, exact);
    var lies = exact;
    lies.targets = &.{"probe-target"};
    try std.testing.expectError(error.RegistryDeclarationMismatch, doc.checkDeclarations(pin, lies));
    lies = exact;
    lies.targets = &.{ "probe-target", "third-target" };
    try std.testing.expectError(error.RegistryDeclarationMismatch, doc.checkDeclarations(pin, lies));
    lies = exact;
    lies.namespace = null;
    try std.testing.expectError(error.RegistryDeclarationMismatch, doc.checkDeclarations(pin, lies));
    lies.namespace = "other";
    try std.testing.expectError(error.RegistryDeclarationMismatch, doc.checkDeclarations(pin, lies));
    var unknown = pin;
    unknown.version = "2.0.0";
    try std.testing.expectError(error.ProviderReleaseNotInRegistry, doc.checkDeclarations(unknown, exact));
    // Mechanism: schema 1 has no claims, so the same disagreeing manifest passes.
    const one: Registry = .{ .schema_version = 1, .pins = doc.pins };
    try one.checkDeclarations(pin, lies);
}

test "provider registry: the normalised document ignores layout, keeps every schema field, and reparses to itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const compact = try parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++ testRecord("fixture", "1.0.0", "\"probe\"", "\"probe-target\"") ++ "]}");
    // Same document, other whitespace and key order: same normalised bytes.
    const spaced = try parse(a, "{ \"providers\" : [" ++ testRecord("fixture", "1.0.0", "\"probe\"", "\"probe-target\"") ++ "],\n  \"defaults\": [ ], \"schema_version\": 2 }");
    const bytes = try compact.normalised(a);
    try std.testing.expectEqualStrings(bytes, try spaced.normalised(a));
    try std.testing.expectEqualStrings(bytes, try (try parse(a, bytes)).normalised(a));
    // A claim is part of it, and so is the schema: the same pins as schema 1 differ.
    const other_claim = try parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++ testRecord("fixture", "1.0.0", "\"probe\"", "") ++ "]}");
    try std.testing.expect(!std.mem.eql(u8, bytes, try other_claim.normalised(a)));
    const one: Registry = .{ .schema_version = 1, .pins = compact.pins };
    const one_bytes = try one.normalised(a);
    try std.testing.expect(!std.mem.eql(u8, bytes, one_bytes));
    // Schema 1 normalises to a valid schema-1 document (no schema-2 keys).
    try std.testing.expectEqual(@as(u8, 1), (try parse(a, one_bytes)).schema_version);
}

inline fn contractRecord(comptime package: []const u8, comptime version: []const u8, comptime range: []const u8) []const u8 {
    return "{\"package\":\"" ++ package ++ "\",\"repo\":\"owner/" ++ package ++ "\",\"version\":\"" ++ version ++
        "\",\"commit\":\"" ++ commit_a ++ "\",\"sha256\":\"" ++ hash_a ++ "\",\"namespace\":\"probe\",\"targets\":[\"probe-target\"],\"command_contract\":\"" ++ range ++ "\"}";
}

test "provider registry: schema 3 records each release's command_contract, strictly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const three = try parse(a, "{\"schema_version\":3,\"defaults\":[],\"providers\":[" ++ contractRecord("fixture", "1.0.0", ">=1.0.0 <2.0.0") ++ "]}");
    try std.testing.expectEqual(@as(u8, 3), three.schema_version);
    try std.testing.expect(three.claimsOwnership() and three.carriesContracts());
    try std.testing.expectEqualStrings(">=1.0.0 <2.0.0", three.records[0].command_contract.?);
    try std.testing.expectEqualStrings("fixture", three.targetOwner("probe-target").?);
    // Required in schema 3, and a range.
    try std.testing.expectError(error.MissingField, parse(a, "{\"schema_version\":3,\"defaults\":[],\"providers\":[" ++ testRecord("fixture", "1.0.0", "null", "") ++ "]}"));
    try std.testing.expectError(error.InvalidCommandContract, parse(a, "{\"schema_version\":3,\"defaults\":[],\"providers\":[" ++ contractRecord("fixture", "1.0.0", "soon") ++ "]}"));
    // A range this CLI does not speak is still a valid record: one registry
    // serves every CLI version.
    const future = try parse(a, "{\"schema_version\":3,\"defaults\":[],\"providers\":[" ++ contractRecord("fixture", "1.0.0", ">=90.0.0 <91.0.0") ++ "]}");
    try std.testing.expect(!future.records[0].supported());
    try std.testing.expect(three.records[0].supported());
    // Normalised: the contract is kept and the document reparses to itself;
    // schema 2 still normalises without the key.
    const bytes = try three.normalised(a);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"command_contract\":\">=1.0.0 <2.0.0\"") != null);
    try std.testing.expectEqualStrings(bytes, try (try parse(a, bytes)).normalised(a));
    const two = try parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++ testRecord("fixture", "1.0.0", "\"probe\"", "\"probe-target\"") ++ "]}");
    try std.testing.expect(std.mem.indexOf(u8, try two.normalised(a), "command_contract") == null);
    try std.testing.expect(!two.carriesContracts() and two.records[0].command_contract == null);
}

test "provider registry: in schema 3 the candidate is the newest declaring release whose contract this CLI speaks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const providers = "\"providers\":[" ++ contractRecord("fixture", "1.0.0", ">=1.0.0 <2.0.0") ++ "," ++
        contractRecord("fixture", "1.2.0", ">=1.0.0 <2.0.0") ++ "," ++ contractRecord("fixture", "2.0.0", ">=90.0.0 <91.0.0") ++ "]}";
    const doc = try parse(a, "{\"schema_version\":3,\"defaults\":[]," ++ providers);
    // Mechanism: the newest by version (2.0.0) is skipped only for its contract.
    try std.testing.expectEqualStrings("2.0.0", doc.latestDeclaring("fixture", .{ .target = "probe-target" }).?.version);
    try std.testing.expectEqualStrings("1.2.0", doc.latestSupported("fixture", .{ .target = "probe-target" }).?.version);
    try std.testing.expectEqualStrings("1.2.0", doc.latestSupported("fixture", .{ .namespace = "probe" }).?.version);
    const none = try parse(a, "{\"schema_version\":3,\"defaults\":[],\"providers\":[" ++ contractRecord("fixture", "2.0.0", ">=90.0.0 <91.0.0") ++ "]}");
    try std.testing.expect(none.latestDeclaring("fixture", .{ .target = "probe-target" }) != null);
    try std.testing.expect(none.latestSupported("fixture", .{ .target = "probe-target" }) == null);
    // Schema 2 records no contract: `latestSupported` is `latestDeclaring`.
    const two = try parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++
        testRecord("fixture", "1.0.0", "null", "\"t\"") ++ "," ++ testRecord("fixture", "2.0.0", "null", "\"t\"") ++ "]}");
    try std.testing.expectEqualStrings("2.0.0", two.latestSupported("fixture", .{ .target = "t" }).?.version);
}

test "provider registry: a schema-3 pin's verified manifest must declare the recorded command_contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parse(a, "{\"schema_version\":3,\"defaults\":[],\"providers\":[" ++ contractRecord("fixture", "1.0.0", ">=1.0.0 <2.0.0") ++ "]}");
    const exact: manifest.Manifest = .{ .name = "fixture", .command_contract = ">=1.0.0 <2.0.0", .namespace = "probe", .targets = &.{"probe-target"} };
    try doc.checkDeclarations(doc.pins[0], exact);
    var lies = exact;
    lies.command_contract = ">=1.2.0 <2.0.0";
    try std.testing.expectError(error.RegistryDeclarationMismatch, doc.checkDeclarations(doc.pins[0], lies));
    lies.command_contract = null;
    try std.testing.expectError(error.RegistryDeclarationMismatch, doc.checkDeclarations(doc.pins[0], lies));
    // Mechanism: schema 2 records no contract, so the same manifest passes.
    const two = try parse(a, "{\"schema_version\":2,\"defaults\":[],\"providers\":[" ++ testRecord("fixture", "1.0.0", "\"probe\"", "\"probe-target\"") ++ "]}");
    try two.checkDeclarations(two.pins[0], lies);
}
