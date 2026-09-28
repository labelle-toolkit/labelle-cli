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
const registry = @import("provider_registry.zig");

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

/// The diagnostic for a target (or command namespace) no pinned provider
/// declares, with the steps that fix it. `lookup` is the registry's answer
/// (`lookupRegistryOwner`): on a hit the steps name the owning package, its
/// repository and a candidate release (registry data, never a name the CLI
/// knows); on a miss they are generic — no package, version or source — and
/// say why. Either way the first line, the exit status and everything else
/// about the failure are the same.
///
/// A custom source is never interpolated into a shell command (quoting
/// differs per shell, and `cmd.exe` expands `%…%` even inside quotes): it is
/// printed on a line of its own, and the steps say where it goes.
pub fn noProviderDiagnostic(a: std.mem.Allocator, declaration: registry.Declaration, lookup: github.RegistryLookup) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    const kind = @tagName(declaration);
    const name = declaration.name();
    try w.print("labelle: no provider for {s} '{s}' in this project; add and pin the package that declares {s} '{s}'\n", .{ kind, name, kind, name });
    switch (lookup) {
        .hit => |hint| {
            const from: []const u8 = if (hint.registry != null) "The registry this project last accepted from" else "The provider registry";
            try w.print("  (registry: {s})\n", .{hint.package});
            try w.print("  {s} lists package '{s}' as the provider of {s} '{s}'.\n", .{ from, hint.package, kind, name });
            if (hint.contract_checked) {
                try w.print("  Its newest release that declares the {s} and whose recorded command_contract this CLI supports,\n  {s}, is a candidate: `labelle providers resolve --accept` verifies it.\n", .{ kind, hint.version });
            } else {
                try w.print("  Its newest release that declares the {s}, {s}, is a candidate: `labelle providers resolve --accept`\n", .{ kind, hint.version });
                try w.print("  checks whether this CLI supports it (on UnsupportedContract, try an older release that declares the {s}).\n", .{kind});
            }
            if (hint.registry) |source| try w.print("  That registry's source, to pass as the argument of both resolve steps (quote or escape it for your shell, since it may contain spaces or special characters):\n    {s}\n", .{source});
            try w.writeAll("  To use it:\n");
            try w.print("    1. add it to .plugins in project.labelle:\n         .{{ .name = \"{s}\", .repo = \"github.com/{s}\", .version = \"{s}\" }},\n", .{ hint.package, hint.repo, hint.version });
            if (hint.registry != null) {
                try w.writeAll("    2. preview the pin: run `labelle providers resolve` with the source above as its argument\n");
                try w.writeAll("    3. run the same command again with `--accept` after the source, to verify it and write\n");
                try w.writeAll("       labelle.providers.lock (commit it; fresh clones and CI run `labelle providers fetch`)\n");
            } else try writeResolveSteps(w);
        },
        .miss => |why| {
            const subject: []const u8 = if (why.custom) "the registry this project last accepted from" else "the provider registry";
            switch (why.reason) {
                .offline => try w.writeAll("  (registry not consulted: " ++ github.registry_offline_env ++ " is set)\n"),
                .unreachable_registry => try w.print("  ({s} could not be read)\n", .{subject}),
                .no_owner_table => try w.print("  ({s} does not publish {s} owners: registry schema 1)\n", .{ subject, kind }),
                .not_listed => try w.print("  ({s} lists no package for this {s})\n", .{ subject, kind }),
                .unverified_source => try w.writeAll("  (the registry this project last accepted from is unknown: " ++ github.registry_accepted_name ++ " does not verify)\n"),
                .not_recorded => try w.writeAll("  (" ++ github.lock_name ++ " came from a registry other than the public one, and " ++ github.registry_accepted_name ++ "\n   holds no verified copy of its document)\n"),
                .no_supported_release => try w.print("  ({s} lists releases for this {s}, but none whose command_contract this CLI supports;\n   a newer labelle CLI may)\n", .{ subject, kind }),
            }
            try w.writeAll("  To add one:\n");
            try w.print("    1. add the package that declares {s} '{s}' to .plugins in project.labelle\n       (a provider registry lists each package's {s}s):\n         .{{ .name = \"<package>\", .repo = \"github.com/<owner>/<repo>\", .version = \"<version>\" }},\n", .{ kind, name, kind });
            try writeResolveSteps(w);
            // Never the public registry as the source of a project whose pins came from elsewhere.
            if (why.custom) {
                try w.writeAll("  This project's pins came from another registry: pass its providers.json path or URL as the\n  argument of both resolve steps.\n");
            } else try w.writeAll("  Both resolve steps read the public provider registry; to use another one, pass its\n  providers.json path or URL as the argument of both.\n");
        },
    }
    try w.print("  Upgrading a project from CLI 1.x? See {s}\n", .{migration_guide_url});
    return out.toOwnedSlice();
}

fn writeResolveSteps(w: *std.Io.Writer) !void {
    try w.writeAll("    2. labelle providers resolve            # preview the pin\n");
    try w.writeAll("    3. labelle providers resolve --accept   # verify it and write labelle.providers.lock (commit it;\n");
    try w.writeAll("                                            # fresh clones and CI run `labelle providers fetch`)\n");
}

/// Print the no-provider diagnostic for the project at `root`. The registry
/// lookup is best-effort metadata (the recorded document of the custom
/// source the project last accepted from, else one short-timeout download
/// of the public registry, skipped under `LABELLE_OFFLINE`): nothing is
/// pinned or run, and a failed lookup only makes the steps generic.
pub fn reportNoProvider(a: std.mem.Allocator, root: ?[]const u8, target: []const u8) void {
    const declaration: registry.Declaration = .{ .target = target };
    const text = noProviderDiagnostic(a, declaration, github.lookupRegistryOwner(a, root, declaration)) catch return;
    std.debug.print("{s}", .{text});
}

/// The namespace twin of `reportNoProvider`, for a first token that is no
/// built-in, no pinned provider's namespace and no directory. Inside a
/// project, the same one document the target hint reads (the project's
/// verified custom source, else the public registry) may name the package
/// that declares it as a namespace; then the diagnostic says so. Anything
/// else — outside a project, offline, a miss of any kind — is the plain
/// unknown-command error: the word is as likely a misspelled command, so a
/// miss prints no steps. Never another project's document (#465).
pub fn reportUnknownCommand(a: std.mem.Allocator, root: ?[]const u8, word: []const u8) void {
    if (namespaceDiagnostic(a, root, word)) |text| {
        std.debug.print("{s}", .{text});
        return;
    }
    std.debug.print("labelle: unknown command '{s}'\nRun 'labelle help' to see available commands.\n", .{word});
}

fn namespaceDiagnostic(a: std.mem.Allocator, root: ?[]const u8, word: []const u8) ?[]const u8 {
    // Only an identifier can be a namespace: `--bogus` is never looked up.
    if (!contract.identifier(word)) return null;
    const r = root orelse return null;
    const declaration: registry.Declaration = .{ .namespace = word };
    const lookup = github.lookupRegistryOwner(a, r, declaration);
    if (lookup != .hit) return null;
    return noProviderDiagnostic(a, declaration, lookup) catch null;
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

test "provider targets: the no-provider diagnostic names a candidate on a hit and stays generic on a miss" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = "labelle: no provider for target 'probe-target' in this project; add and pin the package that declares target 'probe-target'\n";
    const has = struct {
        fn f(text: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, text, needle) != null;
        }
    }.f;
    // Public hit: the owner, a candidate release checked by --accept, literal steps.
    const hit = try noProviderDiagnostic(a, .{ .target = "probe-target" }, .{ .hit = .{ .package = "fixture", .repo = "owner/fixture", .version = "1.2.0" } });
    try std.testing.expect(std.mem.startsWith(u8, hit, head));
    try std.testing.expectEqualStrings("  (registry: fixture)\n", hit[head.len..][0.."  (registry: fixture)\n".len]);
    try std.testing.expect(has(hit, "The provider registry lists package 'fixture' as the provider of target 'probe-target'."));
    try std.testing.expect(has(hit, "1.2.0, is a candidate: `labelle providers resolve --accept`\n  checks whether this CLI supports it"));
    try std.testing.expect(!has(hit, "compatible"));
    try std.testing.expect(has(hit, ".{ .name = \"fixture\", .repo = \"github.com/owner/fixture\", .version = \"1.2.0\" },"));
    try std.testing.expect(has(hit, "    2. labelle providers resolve            # preview the pin\n"));
    try std.testing.expect(has(hit, "    3. labelle providers resolve --accept   #"));
    try std.testing.expect(!has(hit, "<package>") and !has(hit, "source"));
    // Custom hit: the source on a line of its own, never inside a command.
    const source = "C:\\My Registry\\%20b%\\it's \"x\".json";
    const custom = try noProviderDiagnostic(a, .{ .target = "probe-target" }, .{ .hit = .{ .package = "fixture", .repo = "owner/fixture", .version = "2.0.0", .registry = source } });
    try std.testing.expect(std.mem.startsWith(u8, custom, head));
    try std.testing.expect(has(custom, "The registry this project last accepted from lists package 'fixture' as the provider"));
    try std.testing.expect(has(custom, "2.0.0, is a candidate: `labelle providers resolve --accept`"));
    try std.testing.expect(has(custom, try std.fmt.allocPrint(a, "(quote or escape it for your shell, since it may contain spaces or special characters):\n    {s}\n", .{source})));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, custom, source));
    try std.testing.expect(has(custom, "run `labelle providers resolve` with the source above as its argument"));
    try std.testing.expect(!has(custom, "labelle providers resolve --accept   #") and !has(custom, "labelle providers resolve            #"));
    // Every miss: the same head and generic steps — no package, version or
    // source — and the reason that says which path ran.
    const generic = try noProviderDiagnostic(a, .{ .target = "probe-target" }, .{ .miss = .{ .reason = .offline } });
    const reason_end = std.mem.indexOf(u8, generic, "  To add one:\n").?;
    const reasons = [_]struct { github.RegistryMiss, []const u8 }{
        .{ .{ .reason = .offline }, "  (registry not consulted: LABELLE_OFFLINE is set)\n" },
        .{ .{ .reason = .unreachable_registry }, "  (the provider registry could not be read)\n" },
        .{ .{ .reason = .no_owner_table }, "  (the provider registry does not publish target owners: registry schema 1)\n" },
        .{ .{ .reason = .not_listed }, "  (the provider registry lists no package for this target)\n" },
        .{ .{ .reason = .unverified_source }, "  (the registry this project last accepted from is unknown: .labelle/providers.registry.json does not verify)\n" },
        .{ .{ .reason = .no_supported_release }, "  (the provider registry lists releases for this target, but none whose command_contract this CLI supports;\n   a newer labelle CLI may)\n" },
    };
    for (reasons) |case| {
        const text = try noProviderDiagnostic(a, .{ .target = "probe-target" }, .{ .miss = case[0] });
        try std.testing.expect(std.mem.startsWith(u8, text, head));
        try std.testing.expectEqualStrings(case[1], text[head.len..std.mem.indexOf(u8, text, "  To add one:\n").?]);
        // Past the reason, every miss prints exactly the same text.
        try std.testing.expectEqualStrings(generic[reason_end..], text[std.mem.indexOf(u8, text, "  To add one:\n").?..]);
        try std.testing.expect(!has(text, "(registry:") and !has(text, "candidate") and !has(text, "https://raw."));
    }
    try std.testing.expect(has(generic, ".{ .name = \"<package>\", .repo = \"github.com/<owner>/<repo>\", .version = \"<version>\" },"));
    // A project whose pins came from a custom source: the same generic
    // steps, but the public registry is never presented as its source.
    const custom_reasons = [_]struct { github.RegistryMiss, []const u8 }{
        .{ .{ .reason = .not_listed, .custom = true }, "  (the registry this project last accepted from lists no package for this target)\n" },
        .{ .{ .reason = .no_owner_table, .custom = true }, "  (the registry this project last accepted from does not publish target owners: registry schema 1)\n" },
        .{ .{ .reason = .not_recorded, .custom = true }, "  (labelle.providers.lock came from a registry other than the public one, and .labelle/providers.registry.json\n   holds no verified copy of its document)\n" },
    };
    const public_line = "  Both resolve steps read the public provider registry";
    const custom_line = "  This project's pins came from another registry: pass its providers.json path or URL as the\n  argument of both resolve steps.\n";
    const generic_steps = generic[reason_end..std.mem.indexOf(u8, generic, public_line).?];
    for (custom_reasons) |case| {
        const text = try noProviderDiagnostic(a, .{ .target = "probe-target" }, .{ .miss = case[0] });
        const steps = std.mem.indexOf(u8, text, "  To add one:\n").?;
        try std.testing.expectEqualStrings(case[1], text[head.len..steps]);
        try std.testing.expect(std.mem.startsWith(u8, text[steps..], generic_steps));
        try std.testing.expect(has(text, custom_line) and !has(text, public_line) and !has(text, "(registry:"));
    }
    try std.testing.expect(has(generic, public_line) and !has(generic, custom_line));
    // A schema-3 hit says the contract was checked, and still says candidate.
    const checked = try noProviderDiagnostic(a, .{ .target = "probe-target" }, .{ .hit = .{ .package = "fixture", .repo = "owner/fixture", .version = "1.4.0", .contract_checked = true } });
    try std.testing.expect(has(checked, "declares the target and whose recorded command_contract this CLI supports,\n  1.4.0, is a candidate: `labelle providers resolve --accept` verifies it.\n"));
    try std.testing.expect(!has(checked, "UnsupportedContract") and !has(checked, "compatible"));
    try std.testing.expect(has(generic, "    3. labelle providers resolve --accept   #"));
    try std.testing.expect(has(generic, "labelle providers fetch") and has(generic, migration_guide_url));
}

test "provider targets: the namespace diagnostic names a candidate only on a hit, from the project's one document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const has = struct {
        fn f(text: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, text, needle) != null;
        }
    }.f;
    const source = "https://example.test/fork/providers.json";
    const hit = try noProviderDiagnostic(a, .{ .namespace = "probe" }, .{ .hit = .{ .package = "fixture", .repo = "owner/fixture", .version = "2.0.0", .registry = source } });
    try std.testing.expect(std.mem.startsWith(u8, hit, "labelle: no provider for namespace 'probe' in this project; add and pin the package that declares namespace 'probe'\n  (registry: fixture)\n"));
    try std.testing.expect(has(hit, "The registry this project last accepted from lists package 'fixture' as the provider of namespace 'probe'."));
    try std.testing.expect(has(hit, "Its newest release that declares the namespace, 2.0.0, is a candidate"));
    try std.testing.expect(has(hit, "\n    " ++ source ++ "\n") and !has(hit, "compatible") and !has(hit, "target"));
    // Mechanism: outside a project nothing is looked up, and in a unit test
    // the lookup is offline with no record, so both are the plain error.
    try std.testing.expect(namespaceDiagnostic(a, null, "probe") == null);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(config.globalIo(), ".", a);
    try std.testing.expect(namespaceDiagnostic(a, root, "probe") == null);
    try std.testing.expect(!contract.identifier("--bogus") and namespaceDiagnostic(a, root, "--bogus") == null);
}
