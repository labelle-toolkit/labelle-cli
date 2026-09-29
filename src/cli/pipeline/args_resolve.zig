//! Target and platform resolution: the NAME half settled before the
//! install (`resolve`), the pre-install ownership verdict
//! (`earlyTargetCheck`) and `confirmTarget`, the ownership check with the
//! pipeline's diagnostic.
const std = @import("std");
const config = @import("../config.zig");
const project_config = @import("../project_config.zig");
const bundle = @import("../bundle.zig");
const args_mod = @import("../args.zig");
const provider_dispatch = @import("../provider_dispatch.zig");
const provider_github = @import("../provider_github.zig");
const provider_targets = @import("../provider_targets.zig");
const ParsedArgs = args_mod.ParsedArgs;

/// What `resolve` settled, or the exit status the command ends with.
pub const Resolution = union(enum) {
    proceed: Proceed,
    exit: u8,

    pub const Proceed = struct {
        project_root: []const u8,
        provisional: provider_targets.Provisional,
    };
};

/// ── Target resolution, the NAME half (RFC #406 phase 3b) ──────────
/// (docs/provider-targets.md "Resolution")
/// The target is the core `desktop` or one a pinned provider declares;
/// nothing else, including the project's own `.platform` (no shim,
/// RFC #406 "Migration").
/// Ownership needs the providers, and provider discovery runs only
/// after the assembler's `install` populated the package cache (below,
/// next to `gateThenInstall`; Codex P1 on #420) — while the target
/// directory, the progress feed and the schema platform every
/// pre-install step keys off need the name now. So the name is settled
/// here from the string alone: `desktop` is core; any other name is
/// PROVISIONALLY a provider target, confirmed against the discovered
/// providers right after the install and refused there when nobody
/// owns it. Two verdicts need no provider and land immediately:
pub fn resolve(
    allocator: std.mem.Allocator,
    hook_arena: std.mem.Allocator,
    project_dir: []const u8,
    command: args_mod.Command,
    parsed: *project_config.ProjectConfig,
    requested_target: []const u8,
) !Resolution {
    const project_root = try std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), project_dir, hook_arena);
    const provisional = try provider_targets.provisional(requested_target);
    // (1) A project that declares no packages can have no provider, so a
    //     provider target fails before anything is read, written or built.
    //     The failure names the owning package when the registry lookup
    //     (best-effort metadata, `LABELLE_OFFLINE` skips it) finds one.
    if (!provisional.is_core and parsed.plugins.len == 0) {
        provider_targets.reportNoProvider(hook_arena, project_root, requested_target);
        return .{ .exit = 1 };
    }
    // (2) `labelle bundle` of the core target: the desktop packager is
    //     macOS-only and no hook can replace it (nobody may own `desktop`,
    //     so no `replace` hook on `bundle` can plan for it), so refuse it
    //     off macOS before any install or build, as the old `cli.zig` gate
    //     did. A provider target is packaged by its provider — checked
    //     with the plans, after discovery.
    if (command == .bundle_cmd and provisional.is_core and !bundle.hostSupported()) {
        bundle.printUnsupported();
        return .{ .exit = 1 };
    }
    // (3) A provider target whose ownership is decidable NOW is decided
    //     now, so an identifier-shaped typo (`--platform=waasm`) never runs
    //     `.prebuild`, the assembler resolution, the ASTC prepass or the
    //     install first (Codex on #421). This is the same metadata-only read
    //     `labelle targets` does (`.unknown`: cached manifests, no
    //     installer): when it can read EVERY declared package, the verdict
    //     — no owner, or an unpinned remote owner — is the one the
    //     post-install check would reach, so it lands here with the same
    //     diagnostics. A declared remote package it cannot read yet (cold
    //     cache, no pin) leaves the view partial, and the verdict waits for
    //     the post-install discovery, which stays the authoritative check.
    //     A manifest that fails discovery fails it closed here: the install
    //     cannot mend a manifest it can already read. Never for the core
    //     target, which needs no provider.
    //     The pass runs on a scratch arena of its own (`earlyTargetCheck`),
    //     so the pinned archives it reads are not held again beside the
    //     authoritative discovery's copies (Codex P2 on #421).
    if (!provisional.is_core) {
        switch (earlyTargetCheck(allocator, project_root, parsed.*, requested_target) catch return .{ .exit = 1 }) {
            .confirmed, .deferred => {},
            .refused => return .{ .exit = 1 },
        }
    }
    // The legacy sites below (`parsed.platform == .X`; the guard's migration
    // allowlist) keep working for the schema-named provider targets. A
    // target outside the enum reaches only steps its provider does not
    // replace, which treat it as the generic host baseline. `parsed.platform`
    // is derived from the NAME only where the pinned assembler and the
    // legacy sites still need the schema enum.
    parsed.platform = provisional.legacy orelse .desktop;

    return .{ .proceed = .{ .project_root = project_root, .provisional = provisional } };
}

/// Whether `--docker` must be refused for `requested` (RFC cli#466 D5),
/// after printing why. The container build is the core target's only: a
/// provider target's hooks, their environment contributions (contract §2
/// `env_file`) and the toolchain they provision all live on this host, and
/// the container sees none of them. Decided from the target NAME alone, so
/// the refusal lands before the prebuild steps, the install or any
/// generation, and before the no-provider diagnostic. A malformed name is
/// left to `resolve`, which reports it.
pub fn dockerRefused(docker: bool, requested: []const u8) bool {
    if (!docker) return false;
    const target = provider_targets.provisional(requested) catch return false;
    if (target.is_core) return false;
    std.debug.print(
        "labelle: --docker builds the `{s}` target only; target '{s}' comes from a provider, whose hooks and toolchain run on this host\n" ++
            "  build it without --docker (docs/migrating-to-3.0.md)\n",
        .{ provider_targets.core_target, requested },
    );
    return true;
}

test "dockerRefused: --docker is refused for every provider target, never for the core one" {
    try std.testing.expect(!dockerRefused(false, "probe-target"));
    try std.testing.expect(!dockerRefused(true, provider_targets.core_target));
    try std.testing.expect(dockerRefused(true, "probe-target"));
    // A malformed name is not decided here: `resolve` reports it.
    try std.testing.expect(!dockerRefused(true, "Not A Target"));
}

/// Why `confirmTarget` refused the requested target. The kind survives to
/// the `failed` progress record, so a `labelle status --json` consumer can
/// tell an absent owner (add a provider) from an unpinned one (pin the
/// declared package) the same way the human diagnostic does (Codex on #421).
pub const TargetRefusal = enum {
    no_provider,
    unpinned_owner,

    /// The `detail` of the `failed` progress record.
    pub fn detail(self: TargetRefusal) []const u8 {
        return switch (self) {
            .no_provider => "no provider for target",
            .unpinned_owner => "unpinned provider for target",
        };
    }
};

pub const TargetVerdict = union(enum) {
    resolved: provider_targets.Resolved,
    refused: TargetRefusal,
};

/// The ownership half of target resolution with the pipeline's diagnostic:
/// `provider_targets.resolve` against the discovered providers, or the
/// refusal kind after printing its diagnostic (the no-provider steps name
/// the owning package when the best-effort registry lookup finds one). The
/// caller marks its feed with the kind and exits.
pub fn confirmTarget(a: std.mem.Allocator, project_root: []const u8, providers: []const provider_dispatch.Provider, requested: []const u8) !TargetVerdict {
    const resolved = provider_targets.resolve(providers, requested) catch |err| switch (err) {
        error.NoProviderForTarget => {
            provider_targets.reportNoProvider(a, project_root, requested);
            return .{ .refused = .no_provider };
        },
        // The owner is a remote package read from the ordinary cache with
        // no integrity pin: a target-owning provider is held to the pinned
        // boundary even when no hook of its would ever call `requirePinned`.
        error.UnverifiedTargetOwner => {
            provider_targets.reportUnverifiedOwner(a, providers, requested);
            return .{ .refused = .unpinned_owner };
        },
        else => return err,
    };
    return .{ .resolved = resolved };
}

/// The pre-install ownership verdict (`run`, step 3).
pub const EarlyVerdict = enum {
    /// A pinned provider owns the target in the complete metadata view.
    confirmed,
    /// A declared remote package is unread, so the view is partial; the
    /// post-install discovery decides.
    deferred,
    /// Refused, with `confirmTarget`'s diagnostic already printed.
    refused,
};

/// The metadata-only (`.unknown`) discovery and ownership check that runs
/// before the install. Everything it reads — the manifests, and the pinned
/// archives `Sources.fromPin` extracts (up to 128 MiB compressed, 512 MiB of
/// tar) — lives on a scratch arena carved from `backing` and freed before
/// this returns: only the verdict leaves. On the pipeline's long-lived arena
/// that storage was never reclaimed, so the authoritative discovery after
/// the install held every pinned provider twice (Codex P2 on #421).
/// `error.ProviderDiscoveryFailed` after printing the reason.
pub fn earlyTargetCheck(backing: std.mem.Allocator, project_root: []const u8, cfg: project_config.ProjectConfig, requested: []const u8) !EarlyVerdict {
    var scratch = std.heap.ArenaAllocator.init(backing);
    defer scratch.deinit();
    const a = scratch.allocator();
    var sources: provider_github.Sources = .{ .a = a };
    defer sources.deinit();
    const early = provider_dispatch.discoverAll(a, project_root, cfg, &sources, .unknown) catch |err| {
        std.debug.print("labelle: provider discovery failed: {s}\n", .{@errorName(err)});
        return error.ProviderDiscoveryFailed;
    };
    if (early.unresolved.len != 0) return .deferred;
    return switch (try confirmTarget(a, project_root, early.providers, requested)) {
        .resolved => .confirmed,
        .refused => .refused,
    };
}

// The mechanism, not just the verdict: the check allocates from `backing`
// (so the discovery really ran on it) and returns every byte before it
// returns — nothing it read survives on a longer-lived allocator.
test "pipeline: the early target check frees its discovery before returning" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "pkg");
    const project = try tmp.dir.realPathFileAlloc(io, "project", std.testing.allocator);
    defer std.testing.allocator.free(project);
    try tmp.dir.writeFile(io, .{
        .sub_path = "pkg/plugin.labelle",
        .data = ".{ .name = \"pkg\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{ \"probe-target\" } }",
    });
    const cfg: project_config.ProjectConfig = .{ .name = "game", .plugins = &.{
        .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
    } };
    const cases = [_]struct { target: []const u8, verdict: EarlyVerdict }{
        .{ .target = "probe-target", .verdict = .confirmed },
        .{ .target = "other-target", .verdict = .refused },
    };
    for (cases) |case| {
        var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const verdict = try earlyTargetCheck(counting.allocator(), project, cfg, case.target);
        try std.testing.expectEqual(case.verdict, verdict);
        try std.testing.expect(counting.allocations > 0);
        try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
        try std.testing.expectEqual(counting.allocations, counting.deallocations);
    }
}

test "pipeline: each target refusal kind writes its own progress detail" {
    // The two kinds call for different fixes, so their records must differ
    // and the unpinned one must name the condition.
    try std.testing.expectEqualStrings("no provider for target", TargetRefusal.no_provider.detail());
    try std.testing.expectEqualStrings("unpinned provider for target", TargetRefusal.unpinned_owner.detail());
    try std.testing.expect(std.mem.indexOf(u8, TargetRefusal.unpinned_owner.detail(), "unpinned") != null);
    try std.testing.expect(std.mem.indexOf(u8, TargetRefusal.no_provider.detail(), "unpinned") == null);
}
