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
//! Both are claims, not authority. `providers resolve --accept` checks each
//! release it pins against its verified manifest (`checkDeclarations`), so a
//! pinned release never disagrees with the table that pointed at it. Defaults
//! are suggestions resolved to exact records for a consent prompt; nothing
//! here writes a pin or runs package code.
const std = @import("std");
const github = @import("provider_github.zig");
const contract = @import("provider_contract.zig");
const manifest = @import("provider_manifest.zig");

/// The newest registry schema this CLI reads. Schema 1 stays readable.
pub const latest_schema: u8 = 2;

/// A schema-2 release record: the pin fields plus the release's declarations.
/// Both declaration fields are required (strict like the wire context): an
/// absent `namespace` is an error, a release without one says `null`.
pub const Record = struct {
    package: []const u8,
    repo: []const u8,
    version: []const u8,
    commit: []const u8,
    sha256: []const u8,
    namespace: ?[]const u8,
    targets: []const []const u8,

    pub fn pin(self: Record) github.Pin {
        return .{ .package = self.package, .repo = self.repo, .version = self.version, .commit = self.commit, .sha256 = self.sha256 };
    }
};

/// One default package: an exact release, never a bare name or a range, so
/// the consent prompt shows the exact bytes that would be pinned.
pub const DefaultRef = struct { package: []const u8, version: []const u8 };

const SchemaTwo = struct {
    schema_version: u8,
    defaults: []const DefaultRef,
    providers: []const Record,
};

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

    /// The exact records the default list names, in its order: what a
    /// consent prompt presents before anything is pinned or run.
    pub fn defaultPins(self: Registry, a: std.mem.Allocator) ![]const github.Pin {
        const pins = try a.alloc(github.Pin, self.defaults.len);
        for (self.defaults, pins) |ref, *out| out.* = (self.find(ref.package, ref.version) orelse return error.UnknownDefaultRelease).pin();
        return pins;
    }

    fn find(self: Registry, package: []const u8, version: []const u8) ?Record {
        for (self.records) |record| {
            if (std.mem.eql(u8, record.package, package) and std.mem.eql(u8, record.version, version)) return record;
        }
        return null;
    }

    /// The verified manifest of a release about to be pinned must declare
    /// exactly what its record claims: same namespace, same set of targets.
    /// A schema-1 document claims nothing, so there is nothing to check.
    pub fn checkDeclarations(self: Registry, pin: github.Pin, meta: manifest.Manifest) !void {
        if (!self.claimsOwnership()) return;
        const record = self.find(pin.package, pin.version) orelse return error.ProviderReleaseNotInRegistry;
        const same_namespace = if (record.namespace) |claimed|
            meta.namespace != null and std.mem.eql(u8, claimed, meta.namespace.?)
        else
            meta.namespace == null;
        if (same_namespace and sameSet(record.targets, meta.targets)) return;
        std.debug.print("labelle: registry record {s} {s} does not match its verified plugin.labelle (namespace/targets); the registry entry must be corrected\n", .{ pin.package, pin.version });
        return error.RegistryDeclarationMismatch;
    }
};

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
    switch (head.schema_version) {
        1 => return .{ .schema_version = 1, .pins = (try github.parse(a, bytes, false)).providers },
        latest_schema => {},
        else => return error.UnsupportedProviderSchema,
    }
    const doc = try std.json.parseFromSliceLeaky(SchemaTwo, a, bytes, .{ .allocate = .alloc_always });
    const pins = try a.alloc(github.Pin, doc.providers.len);
    for (doc.providers, pins) |record, *out| out.* = record.pin();
    try github.checkPins(pins, false);
    // Each claim is shaped like the manifest declaration it mirrors.
    for (doc.providers) |record| {
        if (record.namespace) |ns| if (!contract.identifier(ns)) return error.InvalidNamespace;
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
    const registry: Registry = .{ .schema_version = latest_schema, .pins = pins, .records = doc.providers, .defaults = doc.defaults, .ownership = ownership };
    _ = try registry.defaultPins(a);
    return registry;
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
    try std.testing.expectError(error.UnsupportedProviderSchema, parse(a, "{\"schema_version\":3,\"defaults\":[],\"providers\":[]}"));
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
