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

/// Pure. `InvalidTarget` for a non-identifier or a Windows reserved device
/// name (the parsers reject those first, with their own message).
pub fn provisional(requested: []const u8) !Provisional {
    if (!contract.targetName(requested)) return error.InvalidTarget;
    if (std.mem.eql(u8, requested, core_target)) return .{ .name = core_target, .is_core = true, .legacy = .desktop };
    return .{ .name = requested, .is_core = false, .legacy = std.meta.stringToEnum(project.Platform, requested) };
}

/// The discovered provider declaring `target`, if any (ownership is unique:
/// `contract.validateOwnership`).
pub fn ownerOf(providers: []const dispatch.Provider, target: []const u8) ?*const dispatch.Provider {
    for (providers) |*provider| {
        if (provider.meta.ownsTarget(target)) return provider;
    }
    return null;
}

/// Pure: the core target, or the target one of `providers` declares.
/// `NoProviderForTarget` when none does; the caller reports it with
/// `reportNoProvider` so the registry is consulted only on that path.
/// `UnverifiedTargetOwner` when the owner is a remote package read from the
/// ordinary cache without an integrity pin (`Provider.verified`): owning a
/// target means generating, building or bundling for it, so the owner is
/// held to the same boundary as a hook that runs (`dispatch.requirePinned`)
/// — even when it declares no hook at all and nothing else would ever ask
/// for its pin. The caller reports it with `reportUnverifiedOwner`.
/// This is the only place ownership of a requested target is decided.
pub fn resolve(providers: []const dispatch.Provider, requested: []const u8) !Resolved {
    const candidate = try provisional(requested);
    if (candidate.is_core) return .{ .name = core_target, .provider = null, .legacy = .desktop };
    const provider = ownerOf(providers, candidate.name) orelse return error.NoProviderForTarget;
    if (!provider.verified) return error.UnverifiedTargetOwner;
    return .{ .name = candidate.name, .provider = provider, .legacy = candidate.legacy };
}

/// The diagnostic for `UnverifiedTargetOwner`: names the package, and the
/// way to pin it.
pub fn unverifiedOwnerDiagnostic(a: std.mem.Allocator, target: []const u8, package: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "labelle: target '{s}' is declared by remote package '{s}', which is unpinned; a target's provider must be pinned. Run labelle providers resolve, review the pins, then repeat with --accept.\n", .{ target, package });
}

/// Print the unverified-owner diagnostic for `target` (which `resolve` just
/// refused, so a provider does declare it).
pub fn reportUnverifiedOwner(a: std.mem.Allocator, providers: []const dispatch.Provider, target: []const u8) void {
    const provider = ownerOf(providers, target) orelse return;
    const text = unverifiedOwnerDiagnostic(a, target, provider.meta.name) catch return;
    std.debug.print("{s}", .{text});
}

/// Where the 1.x → 2.0 migration is explained; every no-provider
/// diagnostic points at it.
pub const migration_guide_url = "https://github.com/labelle-toolkit/labelle-cli/blob/main/docs/migrating-to-2.0.md";

/// The diagnostic for a target no pinned provider declares, with the steps
/// that fix it. `lookup` is the registry's answer (`lookupRegistryOwner`):
/// on a hit the steps name the owning package, its repository and newest
/// release (registry data, never a name the CLI knows); on a miss they are
/// generic and say why no package was named. Either way the first line, the
/// exit status and everything else about the failure are the same.
pub fn noProviderDiagnostic(a: std.mem.Allocator, target: []const u8, lookup: github.RegistryLookup) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("labelle: no provider for target '{s}' in this project; add and pin the package that declares target '{s}'\n", .{ target, target });
    switch (lookup) {
        .hit => |hint| {
            try w.print("  (registry: {s})\n", .{hint.package});
            const from: []const u8 = switch (hint.source) {
                .online => "the provider registry",
                .cache => "the cached provider registry (last `providers resolve --accept`)",
            };
            try w.print("  {s} lists package '{s}' {s} as the provider of target '{s}'. To use it:\n", .{ from, hint.package, hint.version, target });
            try w.print("    1. add it to .plugins in project.labelle:\n         .{{ .name = \"{s}\", .repo = \"github.com/{s}\", .version = \"{s}\" }},\n", .{ hint.package, hint.repo, hint.version });
        },
        .miss => |why| {
            const reason: []const u8 = switch (why) {
                .offline => "registry not consulted: " ++ github.registry_offline_env ++ " is set",
                .unreachable_registry => "the provider registry could not be read",
                .not_listed => "the provider registry lists no package for this target",
            };
            try w.print("  ({s})\n  To add one:\n", .{reason});
            try w.print("    1. add the package that declares target '{s}' to .plugins in project.labelle\n       (the registry lists each package's targets: {s}):\n         .{{ .name = \"<package>\", .repo = \"github.com/<owner>/<repo>\", .version = \"<version>\" }},\n", .{ target, github.registry_url });
        },
    }
    try w.writeAll("    2. labelle providers resolve            # preview the pin\n");
    try w.writeAll("    3. labelle providers resolve --accept   # verify it and write labelle.providers.lock (commit it;\n");
    try w.writeAll("                                            # fresh clones and CI run `labelle providers fetch`)\n");
    try w.print("  Upgrading a project from CLI 1.x? See {s}\n", .{migration_guide_url});
    return out.toOwnedSlice();
}

/// Print the no-provider diagnostic. The registry lookup is best-effort
/// metadata (a short-timeout download, skipped under `LABELLE_OFFLINE`, then
/// the cached document): nothing is pinned or run, and a failed lookup only
/// makes the steps generic.
pub fn reportNoProvider(a: std.mem.Allocator, target: []const u8) void {
    const lookup = github.lookupRegistryOwner(a, target);
    const text = noProviderDiagnostic(a, target, lookup) catch return;
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
        // An unpinned remote owner is listed — the declaration is real —
        // but marked: its targets do not resolve until it is pinned.
        const note: []const u8 = if (provider.verified) "" else " (unpinned)";
        for (provider.meta.targets) |target| std.debug.print("{s}  provided by {s}{s}\n", .{ target, provider.meta.name, note });
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

test "provider targets: an unpinned remote owner never resolves its target, hooks or not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A remote package read from the ordinary cache without a pin
    // (`dispatch.discover` sets `verified = false` for it).
    var unpinned = fixtureProvider("fixture", &.{ "probe-target", "other-target" });
    unpinned.dep.repo = "example/fixture";
    unpinned.verified = false;
    const other = fixtureProvider("other", &.{"third-target"});
    const providers = [_]dispatch.Provider{ other, unpinned };
    try std.testing.expectError(error.UnverifiedTargetOwner, resolve(&providers, "probe-target"));
    try std.testing.expectError(error.UnverifiedTargetOwner, resolve(&providers, "other-target"));
    // It IS the owner — the refusal is about its pin, not about ownership —
    // so the diagnostic names it; a target nobody declares stays the other error.
    try std.testing.expect(ownerOf(&providers, "probe-target").? == &providers[1]);
    try std.testing.expectError(error.NoProviderForTarget, resolve(&providers, "fourth-target"));
    try std.testing.expectEqualStrings("other", (try resolve(&providers, "third-target")).providerName());
    try std.testing.expectEqualStrings("core", (try resolve(&providers, core_target)).providerName());
    const text = try unverifiedOwnerDiagnostic(a, "probe-target", "fixture");
    try std.testing.expect(std.mem.indexOf(u8, text, "target 'probe-target' is declared by remote package 'fixture', which is unpinned") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--accept") != null);
    // Pinned (or local), the same declaration resolves.
    unpinned.verified = true;
    const pinned = [_]dispatch.Provider{ other, unpinned };
    try std.testing.expectEqualStrings("fixture", (try resolve(&pinned, "probe-target")).providerName());
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
    try std.testing.expectError(error.InvalidTarget, provisional("nul"));
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

test "provider targets: the no-provider diagnostic names the registry owner on a hit and stays generic on a miss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = "labelle: no provider for target 'probe-target' in this project; add and pin the package that declares target 'probe-target'\n";
    const steps = [_][]const u8{ "labelle providers resolve ", "labelle providers resolve --accept", "labelle providers fetch", migration_guide_url };
    const hit = try noProviderDiagnostic(a, "probe-target", .{ .hit = .{ .package = "fixture", .repo = "owner/fixture", .version = "1.2.0", .source = .online } });
    try std.testing.expect(std.mem.startsWith(u8, hit, head));
    try std.testing.expectEqualStrings("  (registry: fixture)\n", hit[head.len..][0.."  (registry: fixture)\n".len]);
    try std.testing.expect(std.mem.indexOf(u8, hit, "the provider registry lists package 'fixture' 1.2.0 as the provider of target 'probe-target'") != null);
    try std.testing.expect(std.mem.indexOf(u8, hit, ".{ .name = \"fixture\", .repo = \"github.com/owner/fixture\", .version = \"1.2.0\" },") != null);
    try std.testing.expect(std.mem.indexOf(u8, hit, "<package>") == null);
    for (steps) |step| try std.testing.expect(std.mem.indexOf(u8, hit, step) != null);
    const cached = try noProviderDiagnostic(a, "probe-target", .{ .hit = .{ .package = "fixture", .repo = "owner/fixture", .version = "1.0.0", .source = .cache } });
    try std.testing.expect(std.mem.indexOf(u8, cached, "the cached provider registry") != null);
    // Every miss: the same head and steps, the placeholder entry, no owner,
    // and the reason that says which path ran.
    const reasons = [_]struct { github.RegistryMiss, []const u8 }{
        .{ .offline, "registry not consulted: LABELLE_OFFLINE is set" },
        .{ .unreachable_registry, "the provider registry could not be read" },
        .{ .not_listed, "the provider registry lists no package for this target" },
    };
    for (reasons) |case| {
        const text = try noProviderDiagnostic(a, "probe-target", .{ .miss = case[0] });
        try std.testing.expect(std.mem.startsWith(u8, text, head));
        try std.testing.expect(std.mem.indexOf(u8, text, "(registry:") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, case[1]) != null);
        try std.testing.expect(std.mem.indexOf(u8, text, ".{ .name = \"<package>\", .repo = \"github.com/<owner>/<repo>\", .version = \"<version>\" },") != null);
        for (steps) |step| try std.testing.expect(std.mem.indexOf(u8, text, step) != null);
    }
}
