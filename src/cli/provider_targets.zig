//! Target resolution for `--platform=<t>` (RFC #406 phase 3b).
//!
//! `desktop` is the core target. Every other target name is accepted only
//! because a pinned provider declares it in `.targets`; the CLI keeps no
//! list of its own (`docs/provider-targets.md`). The resolved target is a
//! string. `project_config.Platform` stays the strict schema type of
//! `.platform` and is derived from the name only where the pinned assembler
//! still needs it — the labelle-assembler#378 boundary the pipeline enforces.
//!
//! Nothing here knows a platform, store or package name: the CLI is agnostic
//! (`docs/rfc-package-commands.md`).
const std = @import("std");
const contract = @import("provider_contract.zig");
const dispatch = @import("provider_dispatch.zig");
const project = @import("project_config.zig");
const config = @import("config.zig");
const github = @import("provider_github.zig");

/// The one target core owns; no package may declare it (`ReservedTarget`).
pub const core_target = "desktop";

pub const Resolved = struct {
    name: []const u8,
    /// The owning provider, or null for the core target.
    provider: ?*const dispatch.Provider,
    /// The schema platform of the same name, when the pinned assembler can
    /// generate for it; null for every other provider target.
    legacy: ?project.Platform,

    pub fn providerName(self: Resolved) []const u8 {
        return if (self.provider) |p| p.meta.name else "core";
    }
};

/// The name-only half of resolution: everything the requested STRING alone
/// decides. The pipeline discovers providers only after the assembler's
/// `install` populated the package cache (docs/provider-hooks.md), but the
/// target directory, the progress feed and the schema platform of the
/// pre-install steps need a name before that. `desktop` is the core target;
/// any other well-formed name is provisionally a provider target — never a
/// resolved one — until `resolve` confirms a discovered provider owns it.
pub const Provisional = struct {
    name: []const u8,
    /// The core target: resolved by name alone, no provider can own it.
    is_core: bool,
    /// The schema platform of the same name, when the pinned assembler can
    /// generate for it; null for every other name.
    legacy: ?project.Platform,
};

/// Pure. `InvalidTarget` for a non-identifier (the parsers reject those
/// first, with their own message).
pub fn provisional(requested: []const u8) !Provisional {
    if (!contract.identifier(requested)) return error.InvalidTarget;
    if (std.mem.eql(u8, requested, core_target)) return .{ .name = core_target, .is_core = true, .legacy = .desktop };
    return .{ .name = requested, .is_core = false, .legacy = std.meta.stringToEnum(project.Platform, requested) };
}

/// Pure: the core target, or the target one of `providers` declares.
/// `NoProviderForTarget` when none does; the caller reports it with
/// `reportNoProvider` so the registry cache is read only on that path.
/// This is the only place ownership of a requested target is decided.
pub fn resolve(providers: []const dispatch.Provider, requested: []const u8) !Resolved {
    const candidate = try provisional(requested);
    if (candidate.is_core) return .{ .name = core_target, .provider = null, .legacy = .desktop };
    for (providers) |*provider| {
        if (provider.meta.ownsTarget(candidate.name))
            return .{ .name = candidate.name, .provider = provider, .legacy = candidate.legacy };
    }
    return error.NoProviderForTarget;
}

/// The diagnostic for a target no pinned provider declares, plus the
/// registry line when the cached registry names an owner. The hint is only
/// ever a name the cache holds (contract §4): never a guess.
pub fn noProviderDiagnostic(a: std.mem.Allocator, target: []const u8, registry_hint: ?[]const u8) ![]const u8 {
    const head = try std.fmt.allocPrint(a, "labelle: no provider for target '{s}' in this project; add and pin the package that declares target '{s}'\n", .{ target, target });
    if (registry_hint) |package| return std.fmt.allocPrint(a, "{s}  (registry: {s})\n", .{ head, package });
    return head;
}

/// Print the no-provider diagnostic. The registry hint comes from the
/// cached registry document only — no network, no package code.
pub fn reportNoProvider(a: std.mem.Allocator, target: []const u8) void {
    const hint = github.cachedRegistryOwner(a, target);
    const text = noProviderDiagnostic(a, target, hint) catch return;
    std.debug.print("{s}", .{text});
}

/// `labelle targets`: the core target, then every target a pinned provider
/// declares. Metadata only, like `labelle help`: nothing is locked, built
/// or run, and a discovery failure is a warning so the listing is always
/// available. Outside a project only the core target is listed.
pub fn printTargets(allocator: std.mem.Allocator) void {
    std.debug.print("{s} (core)\n", .{core_target});
    listProviderTargets(allocator) catch |err| {
        std.debug.print("labelle: warning: provider targets not listed, provider discovery failed: {s}\n", .{@errorName(err)});
    };
}

fn listProviderTargets(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try dispatch.projectRoot(a) orelse return;
    const cfg = try config.readProjectConfigQuiet(a, root);
    var sources: github.Sources = .{ .a = a };
    defer sources.deinit();
    // Metadata only, ahead of any installer: an absent package is simply
    // not listed (`.unknown`, like `labelle help`).
    const providers = try dispatch.discover(a, root, cfg, &sources, .unknown);
    for (providers) |provider| {
        for (provider.meta.targets) |target| std.debug.print("{s}  provided by {s}\n", .{ target, provider.meta.name });
    }
}

// ── Tests ────────────────────────────────────────────────────────────────

fn fixtureProvider(name: []const u8, targets: []const []const u8) dispatch.Provider {
    return .{
        .dep = .{ .name = name, .repo = "local:../x", .version = "1.0.0" },
        .dir = "/x",
        .meta = .{ .name = name, .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0", .targets = targets },
        .verified = true,
    };
}

test "provider targets: the core target resolves with no providers and never to a provider" {
    const core = try resolve(&.{}, core_target);
    try std.testing.expectEqualStrings(core_target, core.name);
    try std.testing.expect(core.provider == null);
    try std.testing.expectEqual(project.Platform.desktop, core.legacy.?);
    try std.testing.expectEqualStrings("core", core.providerName());
    const owner = fixtureProvider("fixture", &.{"probe-target"});
    const with = try resolve(&.{owner}, core_target);
    try std.testing.expect(with.provider == null);
}

test "provider targets: the provisional target is decided by the name alone and never claims a provider" {
    const core = try provisional(core_target);
    try std.testing.expect(core.is_core);
    try std.testing.expectEqualStrings(core_target, core.name);
    try std.testing.expectEqual(project.Platform.desktop, core.legacy.?);
    // A schema name is provisionally a provider target with its legacy
    // platform; a name outside the enum has none. Neither is resolved.
    for (std.enums.values(project.Platform)) |platform| {
        if (platform == .desktop) continue;
        const schema = try provisional(@tagName(platform));
        try std.testing.expect(!schema.is_core);
        try std.testing.expectEqual(platform, schema.legacy.?);
    }
    const foreign = try provisional("probe-target");
    try std.testing.expect(!foreign.is_core);
    try std.testing.expect(foreign.legacy == null);
    try std.testing.expectError(error.InvalidTarget, provisional("Probe"));
    // `resolve` is the provisional step plus ownership: the same names
    // agree with it once a provider is discovered, and fail without one.
    const owner = fixtureProvider("fixture", &.{"probe-target"});
    const resolved = try resolve(&.{owner}, "probe-target");
    try std.testing.expectEqualStrings(foreign.name, resolved.name);
    try std.testing.expectEqual(foreign.legacy, resolved.legacy);
    try std.testing.expectError(error.NoProviderForTarget, resolve(&.{}, "probe-target"));
}

test "provider targets: a declared target resolves to its provider; an undeclared one fails closed" {
    const owner = fixtureProvider("fixture", &.{ "other-target", "probe-target" });
    const other = fixtureProvider("other", &.{"third-target"});
    const providers = [_]dispatch.Provider{ other, owner };
    const resolved = try resolve(&providers, "probe-target");
    try std.testing.expectEqualStrings("probe-target", resolved.name);
    try std.testing.expectEqualStrings("fixture", resolved.providerName());
    try std.testing.expect(resolved.provider.? == &providers[1]);
    try std.testing.expect(resolved.legacy == null);
    try std.testing.expectError(error.NoProviderForTarget, resolve(&.{other}, "probe-target"));
    try std.testing.expectError(error.NoProviderForTarget, resolve(&.{}, "probe-target"));
    // Shape is checked before ownership: a non-identifier never resolves.
    try std.testing.expectError(error.InvalidTarget, resolve(&providers, "Probe"));
    try std.testing.expectError(error.InvalidTarget, resolve(&providers, ""));
}

test "provider targets: schema platforms map by name only through a provider; other targets never map" {
    for (std.enums.values(project.Platform)) |platform| {
        if (platform == .desktop) continue;
        const name = @tagName(platform);
        // The schema name alone resolves nothing: the provider is required.
        try std.testing.expectError(error.NoProviderForTarget, resolve(&.{}, name));
        const owner = fixtureProvider("owner", &.{name});
        const resolved = try resolve(&.{owner}, name);
        try std.testing.expectEqualStrings("owner", resolved.providerName());
        try std.testing.expectEqual(platform, resolved.legacy.?);
    }
    const owner = fixtureProvider("owner", &.{"probe-target"});
    try std.testing.expect((try resolve(&.{owner}, "probe-target")).legacy == null);
}

test "provider targets: the no-provider diagnostic names a registry owner only when the cache has one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const absent = try noProviderDiagnostic(a, "probe-target", null);
    try std.testing.expectEqualStrings("labelle: no provider for target 'probe-target' in this project; add and pin the package that declares target 'probe-target'\n", absent);
    const present = try noProviderDiagnostic(a, "probe-target", "fixture");
    try std.testing.expect(std.mem.startsWith(u8, present, absent));
    try std.testing.expectEqualStrings("  (registry: fixture)\n", present[absent.len..]);
}
