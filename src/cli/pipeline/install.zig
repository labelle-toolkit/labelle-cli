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
const python_provision = @import("../python_provision.zig");
const prebuild = @import("../prebuild.zig");
const material_toolchain = @import("../material_toolchain.zig");
const progress = @import("../progress.zig");
const sdl_provision = @import("../sdl_provision.zig");
const args_mod = @import("../args.zig");
const provider_dispatch = @import("../provider_dispatch.zig");
const provider_github = @import("../provider_github.zig");
const provider_hooks = @import("../provider_hooks.zig");
const provider_targets = @import("../provider_targets.zig");
const confirmTarget = @import("args_resolve.zig").confirmTarget;
const HookPlans = @import("context.zig").HookPlans;
const ParsedArgs = args_mod.ParsedArgs;

/// Version compatibility, the `.prebuild` steps and the SDL2 env wiring:
/// everything between the progress feed's start and the assembler
/// resolution. Returns whether the build wants SDL2 (`wants_sdl2`).
pub fn preInstall(allocator: std.mem.Allocator, project_dir: []const u8, parsed: project_config.ProjectConfig, parsed_args: *const ParsedArgs) !bool {
    // Validate version compatibility
    compatibility.validateCompatibility(parsed);

    // Pre-build hooks (#355). Runs on `generate` / `build` / `run` (and
    // the ios/wasm flows, which all generate) — the first thing
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
    // `python_provision.autoWireEnv`, which used to run far below inside the
    // wasm-only block — i.e. AFTER the hooks had already failed to spawn
    // (cli#361 review). Wire it HERE, ahead of the first spawn, so the
    // documented generator works on every platform and not just after a wasm
    // build has got that far.
    //
    // Gated on hooks that will actually run, so the no-`.prebuild` path stays
    // byte-identical (no cache stat, no "using provisioned Python" line) and
    // `LABELLE_NO_PREBUILD=1` stays fully inert. Idempotent and cheap: the
    // wasm block below still calls it for projects with no hooks, and a
    // second call returns early once the dir is on PATH.
    //
    // Nothing else a hook could reasonably need is wired later. The managed
    // Zig toolchain is spawned by absolute path and never joins PATH at all;
    // emsdk activation exists for the emcc link step and pulling it above the
    // hooks would force a toolchain fetch on every build; and
    // `sdl_provision.autoWireEnv` (just below) sets a Windows link/runtime
    // variable consumed by `zig build`, not a tool a generator spawns.
    if (parsed.prebuild.len > 0 and !prebuild.skipRequested(allocator)) {
        python_provision.autoWireEnv(allocator);
    }

    try prebuild.runAll(allocator, project_dir, parsed.prebuild, .{
        .route_stdout_to_stderr = parsed_args.progress_mode == .json,
    });

    // Auto-wire a cache-provisioned SDL2 (`labelle doctor --fix`) into the
    // build/run environment so desktop games that need it (raylib/sokol
    // gamepad, sdl backend) link + run without the user setting
    // LABELLE_SDL2_LIB by hand. No-op when SDL2 isn't in the cache or the
    // user already set the var. Scoped like `labelle doctor`: the sdl
    // backend always needs SDL2; raylib/sokol only for the gamepad
    // source, so `.gamepad = .none` projects get nothing injected.
    // Backends that pull in SDL2: the `sdl` renderer always, and
    // raylib/sokol/bgfx for the shared desktop gamepad source unless gamepad
    // is opted out. Mirrors the assembler's `deps_linker.stagesSdlGamepad`
    // (raylib/sokol/bgfx with `gamepad == .auto`) — bgfx was previously
    // missing here, so its default gamepad-enabled desktop builds never got
    // SDL2 auto-wired or the runtime DLL staged (cli#285 / cli#286).
    const wants_sdl2 = parsed.backend == .sdl or
        ((parsed.backend == .raylib or parsed.backend == .sokol or parsed.backend == .bgfx) and parsed.gamepad != .none);
    if (parsed.platform == .desktop and wants_sdl2) {
        sdl_provision.autoWireEnv(allocator);
    }
    return wants_sdl2;
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
    parsed: project_config.ProjectConfig,
    requested_target: []const u8,
    reporter: ?*progress.Reporter,
    provider_sources: *provider_github.Sources,
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
    const target = switch (try confirmTarget(hook_arena, providers, requested_target)) {
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
    if (command == .wasm_cmd and @import("args_resolve.zig").refuseLegacyWasmReplacement(hook_plans.run)) {
        if (reporter) |r| r.finishFailed(1, "legacy wasm command conflicts with a provider run replacement");
        return .{ .exit = 1 };
    }
    // The labelle-assembler#378 boundary: the assembler generates only for
    // the schema platforms, so a provider target outside that enum can be
    // generated for only by its provider's `replace` hook on `generate`.
    // Without one, stop HERE — before the lock, the assembler's `generate`
    // and any compiler — rather than hand the assembler a name it cannot
    // take.
    if (target.legacy == null and hook_plans.generate.replace == null) {
        std.debug.print("labelle: target '{s}' is declared by '{s}' but the pinned assembler cannot generate for it yet (labelle-assembler#378)\n", .{ target.name, target.providerName() });
        if (reporter) |r| r.finishFailed(1, "the pinned assembler cannot generate for this target");
        return .{ .exit = 1 };
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
    // any provider target except the legacy branches `legacyRunBranch`
    // still names. Without one the run would fall through to the host
    // launch and try to execute a binary built for another platform, so
    // stop HERE, after the install and before generation or any compiler.
    if (noRunReplacement(command, target.provider != null, hook_plans.run.replace != null, target.legacy)) {
        std.debug.print("labelle: target '{s}' has no run replacement; package '{s}' must declare a `.when = .replace` hook on `run`\n", .{ target.name, target.providerName() });
        return error.NoRunReplacement;
    }

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

/// The platforms whose provider target the CLI still launches through a
/// built-in `run` branch of its own (`pipeline/run.zig`). Every other
/// provider target is launched by its provider's `replace run` hook. The
/// set only shrinks: a platform leaves it when its launch moves into a
/// provider (cli#405 removed `android`).
pub fn legacyRunBranch(platform: ?project_config.Platform) bool {
    const p = platform orelse return false;
    return switch (p) {
        .wasm, .ios => true,
        .desktop, .android => false,
    };
}

/// Whether `labelle run` must be refused before the build
/// (`error.NoRunReplacement`): a provider target, no `replace run` hook in
/// the plan, and no legacy launch branch to fall back to. Pure, so the
/// decision table is unit-tested without a project.
pub fn noRunReplacement(command: args_mod.Command, has_provider: bool, has_run_replacement: bool, legacy: ?project_config.Platform) bool {
    return command == .run and has_provider and !has_run_replacement and !legacyRunBranch(legacy);
}

test "NoRunReplacement: a provider target needs a run replacement unless a legacy branch launches it" {
    // The refused shape: `run`, a provider target, no replacement, no
    // legacy branch (a schema name that left the set, or a foreign name).
    try std.testing.expect(noRunReplacement(.run, true, false, .android));
    try std.testing.expect(noRunReplacement(.run, true, false, null));
    // A replacement launches it.
    try std.testing.expect(!noRunReplacement(.run, true, true, .android));
    try std.testing.expect(!noRunReplacement(.run, true, true, null));
    // The legacy branches still launch their own way.
    try std.testing.expect(!noRunReplacement(.run, true, false, .wasm));
    try std.testing.expect(!noRunReplacement(.run, true, false, .ios));
    // The core target is launched by the host branch.
    try std.testing.expect(!noRunReplacement(.run, false, false, .desktop));
    // Only `run` launches: build, bundle and generate are never refused here.
    for ([_]args_mod.Command{ .build, .bundle_cmd, .generate, .wasm_cmd, .ios_cmd }) |command| {
        try std.testing.expect(!noRunReplacement(command, true, false, .android));
    }
}

test "legacyRunBranch: only wasm and ios keep a built-in launch" {
    try std.testing.expect(legacyRunBranch(.wasm));
    try std.testing.expect(legacyRunBranch(.ios));
    try std.testing.expect(!legacyRunBranch(.android));
    try std.testing.expect(!legacyRunBranch(.desktop));
    try std.testing.expect(!legacyRunBranch(null));
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
