//! The install stage: the pre-install work (compatibility, `.prebuild`,
//! env wiring), the shader-override gate ahead of `assembler install`, and
//! provider discovery, target ownership, the hook plans and the lock write
//! that follow the install.
const std = @import("std");
const config = @import("../config.zig");
const project_config = @import("../project_config.zig");
const compatibility = @import("../compatibility.zig");
const lockfile = @import("../lockfile.zig");
const assembler_proc = @import("../assembler_proc.zig");
const assembler_describe = @import("../assembler_describe.zig");
const python_provision = @import("../python_provision.zig");
const prebuild = @import("../prebuild.zig");
const project_lock = @import("../project_lock.zig");
const material_toolchain = @import("../material_toolchain.zig");
const progress = @import("../progress.zig");
const args_mod = @import("../args.zig");
const provider_dispatch = @import("../provider_dispatch.zig");
const provider_github = @import("../provider_github.zig");
const provider_hooks = @import("../provider_hooks.zig");
const provider_targets = @import("../provider_targets.zig");
const confirmTarget = @import("args_resolve.zig").confirmTarget;
const HookPlans = @import("context.zig").HookPlans;
const ParsedArgs = args_mod.ParsedArgs;

/// Version compatibility and the `.prebuild` steps: everything between the
/// progress feed's start and the assembler resolution. A desktop build's
/// system libraries are its providers' business (the `env` hooks), not the
/// core's (cli#471 S4).
/// The managed-Python PATH wiring the `.prebuild` steps get (see
/// `preInstall`): only when steps will actually run, so a project without
/// `.prebuild` — or `LABELLE_NO_PREBUILD=1` — stays inert. Shared with a
/// watched rebuild, whose re-read project may have gained a step
/// mid-session. Idempotent.
pub fn wirePrebuildPython(allocator: std.mem.Allocator, steps: []const prebuild.Step) void {
    if (steps.len > 0 and !prebuild.skipRequested(allocator)) {
        python_provision.autoWireEnv(allocator);
    }
}

pub fn preInstall(allocator: std.mem.Allocator, project_dir: []const u8, parsed: project_config.ProjectConfig, parsed_args: *const ParsedArgs) !void {
    // Validate version compatibility
    compatibility.validateCompatibility(parsed);

    // Pre-build hooks (#355). Runs on `generate` / `build` / `run` /
    // `bundle` — the first thing
    // that touches the project after its config is validated, and ahead
    // of EVERY generation input reader: the ASTC pre-pass, the `--bake`
    // pre-pass, the assembler's cache populate and `generate`. That
    // ordering is the point: a step may emit an atlas declared in
    // `.resources` or a script the game compiles against, and all of
    // those are read downstream.
    //
    // No-op — no print, no stat, no spawn — for a project with no
    // `.prebuild`, so the default path is byte-identical to before.
    //
    // In `--progress=json` mode the child's stdout is routed to the CLI's
    // stderr so the NDJSON stdout feed stays pure (cli#320); see
    // `prebuild.zig`'s module doc for that and for the trust posture.
    // A non-zero step exits the CLI with the child's exact code from
    // inside `runAll` (via `progress.fatalExit`, which marks the status
    // file `failed` first), mirroring the assembler delegation.
    //
    // A hook is very often a Python program — `.run = .{ "python3",
    // "tools/gen_tiles.py", ... }` is this feature's documented example. On a
    // machine whose only interpreter is the CLI-managed one (`labelle install
    // python`), that interpreter reaches PATH solely through
    // `python_provision.autoWireEnv`. It is wired HERE, ahead of the first
    // spawn (cli#361 review), so the documented generator works on every
    // target.
    //
    // Gated on hooks that will actually run, so the no-`.prebuild` path stays
    // byte-identical (no cache stat, no "using provisioned Python" line) and
    // `LABELLE_NO_PREBUILD=1` stays fully inert. Idempotent and cheap: a
    // second call returns early once the dir is on PATH.
    //
    // Nothing else a hook could reasonably need is wired later. The managed
    // Zig toolchain is spawned by absolute path and never joins PATH at all;
    // a provider's toolchain reaches the build through its hooks' environment
    // contributions (a system library too: the core provisions none,
    // cli#471 S4).
    wirePrebuildPython(allocator, parsed.prebuild);

    // Inside a hook or prebuild step of a command holding this project's
    // lock (a watch rebuild), this command could never write the lock:
    // refuse now, before its prebuild steps start the same step again
    // (cli#490).
    try project_lock.refuseNested(allocator, project_dir);

    try prebuild.runAll(allocator, project_dir, parsed.prebuild, .{
        .route_stdout_to_stderr = parsed_args.progress_mode == .json,
    });
}

/// Cold-path stage order (cli#387 gap 3): the shader-compiler override gate
/// runs BEFORE `assembler install`, not after it. The gate is pure local
/// stat-ing; the install is a network-bound package fetch that can take
/// minutes, so validating afterwards made a one-character typo in
/// `LABELLE_SHADERC` cost a full download before the diagnostic appeared.
///
/// `installer` is a value with an `install(allocator, project_dir)` method
/// rather than a plain fn pointer because the real one carries the resolved
/// assembler binary. The seam exists so a test can observe that a rejected
/// override means the install step NEVER RAN, instead of inferring it from
/// wall-clock timing.
pub fn gateThenInstall(
    a: std.mem.Allocator,
    project_dir: []const u8,
    gate: *const fn (std.mem.Allocator, []const u8) anyerror!void,
    installer: anytype,
) !void {
    try gate(a, project_dir);
    try installer.install(a, project_dir);
}

/// Production installer: `labelle-assembler install --project-root <dir>`,
/// which populates the package cache `generate` assumes.
pub const AssemblerInstaller = struct {
    bin: assembler_proc.Assembler,

    pub fn install(self: AssemblerInstaller, a: std.mem.Allocator, project_dir: []const u8) !void {
        return self.bin.run(a, "install", &.{ "--project-root", project_dir });
    }
};

/// Provider discovery, target ownership and the hook plans, then the
/// post-resolve compatibility check and the lock write: what `discoverAndPlan`
/// settled, or the exit status the command ends with.
pub const Planned = union(enum) {
    ready: Ready,
    exit: u8,

    pub const Ready = struct {
        providers: []const provider_dispatch.Provider,
        target: provider_targets.Resolved,
        hook_plans: HookPlans,
    };
};

/// ── Provider discovery, target ownership and hook plans ────────────
/// (contract §6; docs/provider-hooks.md, docs/provider-targets.md)
/// Discovery reads every declared provider manifest and validates the
/// whole hook graph ONCE, so a malformed provider fails a plain `labelle
/// build` closed before generation or any compiler runs. It sits HERE,
/// after `install` populated the package cache and not before it (Codex
/// P1 on #420): a declared remote package that is neither pinned nor yet
/// in the ordinary cache has no manifest to read, and discovering ahead of
/// the installer read every such package as runtime-only — a cold cache
/// silently built without the package's hooks while a warm one ran them
/// (or refused as unpinned). With the cache populated, `.populated` makes
/// an absent package an error instead. Skipped for a project with no
/// plugins; for pinned remote providers it is the same verified extraction
/// every provider command performs (the integrity model of cli#414 — the
/// cost is accepted). The plans are pure and computed here for all four
/// steps; a project without hooks gets four empty plans and never resolves
/// the host compiler.
pub fn discoverAndPlan(
    allocator: std.mem.Allocator,
    hook_arena: std.mem.Allocator,
    project_dir: []const u8,
    project_root: []const u8,
    command: args_mod.Command,
    watch: bool,
    parsed: project_config.ProjectConfig,
    requested_target: []const u8,
    reporter: ?*progress.Reporter,
    provider_sources: *provider_github.Sources,
    describer: assembler_describe.Describer,
) !Planned {
    const providers: []const provider_dispatch.Provider = if (parsed.plugins.len == 0)
        &.{}
    else
        provider_dispatch.discover(hook_arena, project_root, parsed, provider_sources, .populated) catch |err| {
            std.debug.print("labelle: provider discovery failed: {s}\n", .{@errorName(err)});
            if (reporter) |r| r.finishFailed(1, "provider discovery failed");
            return .{ .exit = 1 };
        };
    // The ownership half of target resolution: the provisional target from
    // above is confirmed against the discovered providers — the first point
    // at which a declared package's manifest is guaranteed readable — and
    // refused when none declares it. This is the only place a provider
    // target becomes a resolved one; nothing has been generated, locked or
    // compiled yet, and the `failed` progress record names the reason —
    // which of the two refusals it was, since each calls for a different fix.
    const target = switch (try confirmTarget(hook_arena, project_root, providers, requested_target)) {
        .resolved => |resolved| resolved,
        .refused => |why| {
            if (reporter) |r| r.finishFailed(1, why.detail());
            return .{ .exit = 1 };
        },
    };
    const hook_plans: HookPlans = .{
        .generate = try provider_hooks.plan(hook_arena, providers, .generate, target.name),
        .build = try provider_hooks.plan(hook_arena, providers, .build, target.name),
        .bundle = try provider_hooks.plan(hook_arena, providers, .bundle, target.name),
        .run = try provider_hooks.plan(hook_arena, providers, .run, target.name),
    };
    // Whether the assembler can generate the target at all is ITS answer
    // (`describe`'s `supported`, cli#471 D3/P3): a name its codegen does not
    // know, or a backend × target pair the backend does not support, comes
    // back unsupported with a reason. Asked HERE, after the install, so an
    // installed backend is judged from its own manifest — before the lock,
    // the assembler's `generate` and any compiler. Only asked when the core
    // generation will run at all: a `replace` hook on `generate` stands in
    // for it, whatever the assembler knows.
    const described: ?assembler_describe.Description = if (hook_plans.generate.replace == null)
        describer.require(hook_arena, target.name) catch {
            if (reporter) |r| r.finishFailed(1, "assembler describe failed");
            return .{ .exit = 1 };
        }
    else
        null;
    switch (coreGenerateGate(hook_plans.generate.replace != null, described)) {
        .proceed => {},
        .unsupported => |reason| {
            reportUnsupported(target, described.?.backend.name, reason);
            if (reporter) |r| r.finishFailed(1, "the assembler cannot generate this target");
            return .{ .exit = 1 };
        },
    }
    // `labelle bundle` of a provider target is packaged by its provider, so
    // it needs a `replace` hook on `bundle` — and needs no particular host.
    // (The core target's macOS-only gate ran before the install, above.)
    if (command == .bundle_cmd) {
        if (target.provider) |provider| {
            if (hook_plans.bundle.replace == null) {
                std.debug.print("labelle: target '{s}' has no bundle replacement; package '{s}' must declare a `.when = .replace` hook on `bundle`\n", .{ target.name, provider.meta.name });
                return error.NoBundleReplacement;
            }
        }
    }
    // `labelle run` of a provider target is launched by its provider, so it
    // needs a `replace` hook on `run`: the CLI has no launch of its own for
    // any provider target (the last built-in one, the simulator deploy, left
    // with cli#471 I5). Without one the run would fall through to the host
    // launch and try to execute a binary built for another platform, so
    // stop HERE, after the install and before generation or any compiler.
    if (noRunReplacement(command, target.provider != null, hook_plans.run.replace != null)) {
        std.debug.print("labelle: target '{s}' has no run replacement; package '{s}' must declare a `.when = .replace` hook on `run`\n", .{ target.name, target.providerName() });
        return error.NoRunReplacement;
    }

    // `labelle run --watch` (RFC cli#466 §3.4) needs a watch-capable run
    // replacement speaking wire 1.3.0+: refused HERE, before the lock,
    // generation or any compiler (`watch_session.refusal`).
    if (watch) if (@import("watch_session.zig").refusal(target.name, hook_plans.run)) |why| {
        if (reporter) |r| r.finishFailed(1, why.detail());
        return .{ .exit = 1 };
    };

    // Plugin→core compatibility, the POST-RESOLVE half (#332).
    //
    // Deliberately here and not beside `validateCompatibility` above: that one
    // runs on `ProjectConfig` alone, before any package exists on disk, so a
    // remote plugin's `plugin.labelle` is simply not readable yet and every
    // declaration would read as absent. `install` above is what populates the
    // cache, so this is the first point where a declared `.core_compat` can be
    // honored at all. Warn-only and non-fatal, like every other check in
    // `compatibility.zig`.
    compatibility.validatePluginCoreCompat(allocator, parsed, project_dir);

    // `labelle.lock` is written HERE, before generation, rather than after
    // it: a `before generate` provider hook already needs the lock (contract
    // §2 — `lock_file` is non-null inside a project, and the hook's own pin
    // is verified against it). `install` above populated the cache the lock
    // writer reads, so every resolved version is already known. A generate
    // that then fails leaves a fresh lock reflecting the declared pins —
    // harmless, and `enforceCliNotStale` only reads it on the next run.
    try lockfile.writeLockFile(allocator, project_dir, parsed);
    return .{ .ready = .{ .providers = providers, .target = target, .hook_plans = hook_plans } };
}

/// The verdict on handing the target to the assembler's core `generate`.
pub const GenerateGate = union(enum) {
    proceed,
    /// `describe` said the assembler cannot generate the target with the
    /// resolved backend (an unknown target name included); carries its
    /// reason.
    unsupported: []const u8,
};

/// Pure. `replaced`: a `replace` hook on `generate` stands in for the core
/// generation; `described`: the assembler's `describe` answer, null only
/// when it was not asked (the generation is replaced).
pub fn coreGenerateGate(replaced: bool, described: ?assembler_describe.Description) GenerateGate {
    if (replaced) return .proceed;
    if (described) |d| if (!d.supported) return .{ .unsupported = d.reason orelse "unsupported (no reason given)" };
    return .proceed;
}

/// The refusal of a target the assembler cannot generate: its reason, and
/// for a provider target, what the provider could do about it. The CLI
/// keeps no list of targets, so an unknown name reads the same way — the
/// assembler's reason names what it does generate for.
pub fn reportUnsupported(target: provider_targets.Resolved, backend: []const u8, reason: []const u8) void {
    std.debug.print("labelle: backend '{s}' cannot build target '{s}': {s}\n", .{ backend, target.name, reason });
    if (target.provider) |provider|
        std.debug.print("  package '{s}' declares target '{s}' but no `.when = .replace` hook on `generate`, so the assembler must generate it\n", .{ provider.meta.name, target.name });
}

test "coreGenerateGate: describe refuses an unsupported pair" {
    var d = std.mem.zeroInit(assembler_describe.Description, .{ .supported = true });
    // A replacement generates: nothing else is asked.
    try std.testing.expect(coreGenerateGate(true, null) == .proceed);
    d.supported = false;
    try std.testing.expect(coreGenerateGate(true, d) == .proceed);
    // Supported: proceed. Unsupported — an unknown target name included —
    // refused with describe's reason.
    d.supported = true;
    try std.testing.expect(coreGenerateGate(false, d) == .proceed);
    d.supported = false;
    d.reason = "backend 'acme' has no target 'probe-target': this assembler generates for desktop";
    try std.testing.expectEqualStrings(d.reason.?, coreGenerateGate(false, d).unsupported);
    d.reason = null;
    try std.testing.expect(coreGenerateGate(false, d) == .unsupported);
}

/// A build path that cannot carry what a provider supplies for the target.
/// Such a path refuses before anything runs rather than silently bypassing
/// the provider (RFC cli#466 A1):
/// - `--docker` builds inside a container that never sees a hook's
///   environment contribution (contract §2 `env_file`); it does pass the
///   effective optimize mode through as `-Doptimize`, so a target default
///   is honoured there. Only a command that reaches that container build
///   refuses: `labelle generate --docker` stops after generation, and its
///   one zig invocation (the host-side fingerprint pass of `tests/`) does
///   receive the contributions; and when the target owner replaces `build`,
///   its hook stands in for the container build and gets the
///   contributions like every hook.
/// (The legacy platform subcommand's own build, refused for both the
/// contributions and the owner's optimize default, left with cli#471 I5.)
pub const Bypass = enum {
    docker_env,

    pub fn message(self: Bypass) []const u8 {
        return switch (self) {
            .docker_env => "--docker doesn't carry provider environment contributions; build without --docker",
        };
    }
};

/// Pure. `contributor` is the plan's first hook that can contribute an
/// environment (`provider_hooks.planContributor`); `build_replaced`
/// whether the plan has a `replace` hook on `build`. The target owner's
/// optimize default never refuses: `--docker` passes it as `-Doptimize`.
pub fn providerBypass(command: args_mod.Command, docker: bool, contributor: bool, build_replaced: bool) ?Bypass {
    if (docker and contributor and reachesContainerBuild(command) and !build_replaced) return .docker_env;
    return null;
}

/// The commands whose `--docker` run reaches `docker.runBuild`: every one
/// that goes on past generation into the shared build step.
fn reachesContainerBuild(command: args_mod.Command) bool {
    return switch (command) {
        .build, .run, .bundle_cmd => true,
        else => false,
    };
}

test "providerBypass: a path that cannot carry a provider's input refuses instead of bypassing it" {
    // Nothing to carry: every path keeps today's behaviour.
    for ([_]args_mod.Command{ .build, .run, .generate, .bundle_cmd }) |command| {
        try std.testing.expect(providerBypass(command, false, false, false) == null);
        try std.testing.expect(providerBypass(command, true, false, false) == null);
    }
    // --docker: contributions are refused.
    try std.testing.expectEqual(Bypass.docker_env, providerBypass(.build, true, true, false).?);
    try std.testing.expectEqual(Bypass.docker_env, providerBypass(.run, true, true, false).?);
    try std.testing.expectEqual(Bypass.docker_env, providerBypass(.bundle_cmd, true, true, false).?);
    // `labelle generate --docker` never reaches the container build: its
    // fingerprint pass runs on the host with the contributions.
    try std.testing.expect(providerBypass(.generate, true, true, false) == null);
    // A `replace build` hook stands in for the container build and gets the
    // contributions like every hook: nothing is bypassed.
    for ([_]args_mod.Command{ .build, .run, .bundle_cmd }) |command| {
        try std.testing.expectEqual(Bypass.docker_env, providerBypass(command, true, true, false).?);
        try std.testing.expect(providerBypass(command, true, true, true) == null);
    }
    // Without --docker the shared pipeline carries the contributions.
    try std.testing.expect(providerBypass(.build, false, true, false) == null);
}

/// Whether `labelle run` must be refused before the build
/// (`error.NoRunReplacement`): a provider target and no `replace run` hook
/// in the plan. The core has no launch of its own for any provider target
/// (cli#471 I5 removed the last one), so nothing else can launch it. Pure,
/// so the decision table is unit-tested without a project.
pub fn noRunReplacement(command: args_mod.Command, has_provider: bool, has_run_replacement: bool) bool {
    return command == .run and has_provider and !has_run_replacement;
}

test "NoRunReplacement: a provider target needs a run replacement" {
    // The refused shape: `run`, a provider target, no replacement — whatever
    // its name (a former built-in, too, since cli#471 I5).
    try std.testing.expect(noRunReplacement(.run, true, false));
    // A replacement launches it.
    try std.testing.expect(!noRunReplacement(.run, true, true));
    // The core target is launched by the host branch.
    try std.testing.expect(!noRunReplacement(.run, false, false));
    // Only `run` launches: build, bundle and generate are never refused here.
    for ([_]args_mod.Command{ .build, .bundle_cmd, .generate }) |command| {
        try std.testing.expect(!noRunReplacement(command, true, false));
    }
}

test "a rejected shader override stops the cold build before any package is installed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project/materials");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);

    const Spy = struct {
        var installed: bool = false;
        fn install(_: @This(), _: std.mem.Allocator, _: []const u8) !void {
            installed = true;
        }
        // The same gate the cold and watched paths share, with the env read
        // replaced by a known-bad value.
        fn badOverride(alloc: std.mem.Allocator, dir: []const u8) anyerror!void {
            return material_toolchain.preflightWith(alloc, dir, "shaderc", .native);
        }
        fn badDockerOverride(alloc: std.mem.Allocator, dir: []const u8) anyerror!void {
            return material_toolchain.preflightWith(alloc, dir, "shaderc", .docker);
        }
        fn goodOverride(alloc: std.mem.Allocator, dir: []const u8) anyerror!void {
            return material_toolchain.preflightWith(alloc, dir, "/bin/sh", .native);
        }
    };

    Spy.installed = false;
    try std.testing.expectError(error.ShadercOverrideMustBeAbsolute, gateThenInstall(a, project, Spy.badOverride, Spy{}));
    // The point of the move: the network-bound install never ran.
    try std.testing.expect(!Spy.installed);

    // `--docker` takes the same ordering, not a bypass.
    Spy.installed = false;
    try std.testing.expectError(error.ShadercOverrideMustBeAbsolute, gateThenInstall(a, project, Spy.badDockerOverride, Spy{}));
    try std.testing.expect(!Spy.installed);

    // A valid override still reaches the install, so the assertions above
    // are the gate firing rather than the install being unreachable.
    Spy.installed = false;
    try gateThenInstall(a, project, Spy.goodOverride, Spy{});
    try std.testing.expect(Spy.installed);
}
