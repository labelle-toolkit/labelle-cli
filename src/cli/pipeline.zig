//! Command-execution pipeline for the labelle CLI (#311). Extracted from
//! cli.zig `main` so the dispatcher stays small: this owns the
//! generate -> build -> run flow and the docker / ios
//! branches. Behavior is identical to when this lived in `main`.
//!
//! Thin root: `run` walks the stages in order and owns every resource they
//! borrow; each stage lives in `pipeline/`, one responsibility per file.
//!
//!   pipeline/args_resolve.zig        target + platform resolution, the
//!                                    early pre-install verdict, `confirmTarget`
//!   pipeline/install.zig             pre-install work, `gateThenInstall`,
//!                                    discovery + hook plans, the lock write
//!   pipeline/generate.zig            before/core/after generate, the ASTC and
//!                                    `--bake` prepasses, the shader re-gate
//!   pipeline/build.zig               core build, packaging finalisation,
//!                                    after-build, the `bundle` step
//!   pipeline/run.zig                 run branches, `RunOutcome` plumbing
//!   pipeline/context.zig             `Context` + `HookPlans` the stages share
//!   pipeline/optimize.zig            the effective optimize mode (flag, the
//!                                    target owner's default, core fallback)
//!   pipeline/rebuild.zig             `RebuildCtx`, the watch ignore set
//!   pipeline/rebuild_tests.zig       the rebuild's tests
//!   pipeline/rebuild_replan.zig      `Replanner` and its generations
//!   pipeline/rebuild_replan_tests.zig the replan's tests
//!   pipeline/session_key.zig         what a running watch replacement
//!                                    depends on (the restart rules)
//!   pipeline/watch_session.zig       `labelle run --watch`: refusals,
//!                                    publication, supervision
//!   pipeline/screenshot.zig          the post-run `--screenshot` report
//!   pipeline/testing.zig             helpers shared by the tests above
const std = @import("std");
const config = @import("config.zig");
const upgrade = @import("upgrade.zig");
const lockfile = @import("lockfile.zig");
const runner = @import("runner.zig");
const assembler_proc = @import("assembler_proc.zig");
const material_toolchain = @import("material_toolchain.zig");
const ios = @import("ios.zig");
const progress = @import("progress.zig");
const args_mod = @import("args.zig");
const provider_contract = @import("provider_contract.zig");
const provider_github = @import("provider_github.zig");
const provider_hooks = @import("provider_hooks.zig");
const ParsedArgs = args_mod.ParsedArgs;

const args_resolve = @import("pipeline/args_resolve.zig");
const install = @import("pipeline/install.zig");
const generate = @import("pipeline/generate.zig");
const build = @import("pipeline/build.zig");
const run_stage = @import("pipeline/run.zig");
const context = @import("pipeline/context.zig");
const rebuild = @import("pipeline/rebuild.zig");
const rebuild_replan = @import("pipeline/rebuild_replan.zig");
const rebuild_replan_tests = @import("pipeline/rebuild_replan_tests.zig");
const session_key = @import("pipeline/session_key.zig");
const watch_session = @import("pipeline/watch_session.zig");
const optimize_mod = @import("pipeline/optimize.zig");
const screenshot = @import("pipeline/screenshot.zig");
const testing = @import("pipeline/testing.zig");

pub const ScreenshotProbeSpec = screenshot.ScreenshotProbeSpec;
pub const CollectPrebuildIgnorePathsSpec = rebuild.CollectPrebuildIgnorePathsSpec;

/// Run the project-scoped pipeline: read project.labelle, then
/// generate -> build -> run (or the docker / ios
/// variant selected by `parsed_args`). Dispatch of the standalone
/// subcommands stays in cli.zig `main`; this is invoked only for the
/// project commands (generate / build / run / bundle / ios).
/// Returns the process exit status the command earned: the game's own exit
/// status for `run` (0 for a genuine `--timeout` expiry), 0 for everything
/// that completed. `main` returns it as the CLI's exit code, so automation
/// can tell a crash from a clean run (cli#390).
///
/// A build that stops the launch is always NONZERO: the build (docker /
/// progress / captured) fails through `error.BuildFailed`, i.e. exit 1,
/// because that error path is what runs this function's errdefers. The
/// build's real code is in the `failed` progress record.
/// A subcommand that completed is exit 0; its error propagates unchanged.
/// Lets `run` return a status while the subcommands it delegates to keep
/// their `!void` signatures.
fn ok(result: anytype) !u8 {
    if (comptime @typeInfo(@TypeOf(result)) == .error_union) try result;
    return 0;
}

pub fn run(allocator: std.mem.Allocator, parsed_args: ParsedArgs) !u8 {
    const command = parsed_args.command;
    const project_dir = parsed_args.project_dir;

    // Read and parse project.labelle
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // Stale-CLI gate (#353), BEFORE the project parse: refuse to build a
    // project whose lock was written by a NEWER CLI —
    // `ignore_unknown_fields` means this binary would silently skip
    // config it doesn't know (the incident: per-atlas `.astc_block`
    // ignored → every atlas encoded at the old global block size,
    // visibly mangled art, zero errors). Running first also means a
    // newer project whose MIRRORED fields changed shape gets this
    // actionable message instead of a bare parse error. `upgrade` is
    // exempt: it is the way out of this error.
    if (command != .upgrade_cmd) {
        lockfile.enforceCliNotStale(allocator, project_dir, parsed_args.allow_older_cli) catch std.process.exit(1);
    }

    var parsed = config.readProjectConfig(arena.allocator(), project_dir) catch |err| {
        if (err == error.FileNotFound) {
            config.printNoProjectError(project_dir);
        }
        return 1;
    };

    // Normalize the deprecated `.initial_scene` alias (RFC #560 / #565)
    // into `.initial_prefab`. The `--scene=` flag does NOT rewrite
    // `.initial_prefab` anymore — it sets `LABELLE_SCENE=<name>` in the
    // spawned game's env (cli#229) and the project's loading-scene
    // controller reads it via `engine.requestedScene()` and transitions
    // once `assets.allReady`. The legacy initial-prefab-rewrite path was
    // removed because it bypassed the loading gate and made the game
    // stick on the target scene's async-load forever for projects with
    // a loading-scene gate.
    parsed.normalizeInitialPrefab();

    // The requested target (RFC #406 phase 3b, docs/provider-targets.md):
    // `--platform=<t>` — the legacy platform subcommands set the same
    // override — else the project's declared platform. It is resolved below
    // against the core target and the pinned providers' declarations;
    // `parsed.platform` is derived from the RESULT only where the pinned
    // assembler and the legacy sites still need the schema enum.
    const requested_target: []const u8 = parsed_args.platform_override orelse @tagName(parsed.platform);

    // Upgrade modifies project.labelle in the project directory
    if (command == .upgrade_cmd) {
        return ok(upgrade.cmdUpgrade(allocator, project_dir, parsed, parsed_args.extra_args[0..parsed_args.extra_count]));
    }

    // ── Target resolution, the NAME half (RFC #406 phase 3b) ──────────
    // (`args_resolve.resolve`; docs/provider-targets.md "Resolution")
    const hook_arena = arena.allocator();
    // `--docker` builds the core target only (RFC cli#466 D5): refused for
    // a provider target before anything is read, written or built.
    if (args_resolve.dockerRefused(parsed_args.docker, requested_target)) return 1;
    const resolved = switch (try args_resolve.resolve(allocator, hook_arena, project_dir, command, &parsed, requested_target)) {
        .proceed => |proceed| proceed,
        .exit => |code| return code,
    };
    const project_root = resolved.project_root;
    const provisional = resolved.provisional;

    // (Provider discovery, the ownership check of the provisional target
    // and the hook plans are computed further down, right after the package
    // cache is populated — see the `gateThenInstall` call.)

    // ── Build-progress feed (cli#284) ──────────────────────────────────
    // Target subdir: .labelle/raylib_desktop/, etc. Computed up front so
    // the live status file `.labelle/<target>/.build-progress.json` has a
    // home from the first `resolve` record onward (the dir is created by
    // the reporter; the assembler generates into it later). Named after
    // the PROVISIONAL target: the name depends on the string alone, and a
    // target refused after the install leaves only a `failed` record here.
    const target_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ @tagName(parsed.backend), provisional.name });
    defer allocator.free(target_name);
    const target_dir = try std.fs.path.join(allocator, &.{ project_dir, ".labelle", target_name });
    defer allocator.free(target_dir);

    // `labelle run --watch`: claim the session FIRST, before the progress
    // reporter, the prebuild steps, the install or the `labelle.lock` write
    // touch anything a running session owns, so a second session for the
    // same target is refused having changed nothing (`watch.SessionLock`).
    var session_lock: ?@import("watch.zig").SessionLock = if (parsed_args.run_watch)
        @import("watch.zig").SessionLock.acquire(allocator, try std.fs.path.join(hook_arena, &.{ project_root, ".labelle", ".watch", target_name })) catch |err| {
            // `WatchSessionActive` printed its own diagnostic (the owner's
            // PID); anything else is reported for what it is.
            if (err != error.WatchSessionActive) std.debug.print("labelle: run --watch: could not claim the watch session lock ({s})\n", .{@errorName(err)});
            return 1;
        }
    else
        null;
    defer if (session_lock) |*lock| lock.release();
    // ...and read the watched tree now, before the cold build consumes it:
    // an edit saved while that build runs is then unbuilt when the watcher
    // starts, and rebuilds (the same ignore set the watcher starts with).
    const watch_baseline: ?@import("watch.zig").TreeSignature = if (parsed_args.run_watch) blk: {
        var ignore = rebuild.watchIgnorePaths(allocator, project_dir, parsed.prebuild, !@import("prebuild.zig").skipRequested(allocator));
        defer {
            for (ignore.items) |f| allocator.free(f);
            ignore.deinit(allocator);
        }
        // The local providers' trees outside the project too (cli#474):
        // the same roots the watcher starts with (`RebuildCtx.initIgnore`).
        var roots = rebuild.localProviderRoots(allocator, project_dir, parsed.plugins);
        defer {
            for (roots.items) |r| allocator.free(r);
            roots.deinit(allocator);
        }
        var sig: @import("watch.zig").TreeSignature = .{};
        @import("watch.zig").computeSignatureRoots(config.globalIo(), allocator, project_dir, roots.items, ignore.items, &sig);
        break :blk sig;
    } else null;

    // One event source, three access modes: NDJSON on stdout
    // (`--progress=json`), the atomically-rewritten status file (all
    // modes; read by `labelle status` + studio), and a live indicator on
    // stderr (default human mode — a TTY-only spinner while `zig build`
    // runs, "still working" heartbeat lines while the assembler child
    // owns stderr during resolve/generate, cli#321). Enabled for the
    // commands that run the shared build pipeline; `labelle generate` and
    // the ios subcommand (which owns its own build flow) stay
    // report-free. A
    // reporter that fails to initialize downgrades to the pre-#284
    // behavior instead of blocking the build.
    var reporter_storage: progress.Reporter = undefined;
    const reporter: ?*progress.Reporter = blk: {
        if (command != .build and command != .run and command != .bundle_cmd) break :blk null;
        reporter_storage = progress.Reporter.init(allocator, config.globalIo(), parsed_args.progress_mode, target_dir) catch break :blk null;
        break :blk &reporter_storage;
    };
    defer if (reporter) |r| r.deinit();
    // Any error path from here on marks the status file `failed`, so an
    // out-of-band reader never sees a live phase for a dead build. The
    // catch-all detail is composed from the live phase ("generate
    // failed", …) so the terminal record still names the stage that was
    // active — the record's own `phase` field flips to "failed" (cli#318).
    // (Pipeline code that terminates via process-exit instead of an error
    // return goes through `progress.fatalExit`, which does the same.)
    errdefer if (reporter) |r| r.failActiveStage(1);
    if (reporter) |r| {
        // Registers the fatalExit hook + starts the keepalive ticker that
        // refreshes elapsed/updated timestamps while child processes own
        // the foreground (assembler, zig, game).
        r.activate();
        r.beginPhase(.resolve, "resolving toolchain + packages");
    }

    // Version compatibility, the pre-build hooks (#355) and the SDL2 env
    // wiring (`install.preInstall`).
    const wants_sdl2 = try install.preInstall(allocator, project_dir, parsed, &parsed_args);

    // Issue #217: the CLI is a thin driver over the standalone
    // labelle-assembler binary. Resolve it once here (LABELLE_ASSEMBLER
    // env var > assembler_version in project.labelle > auto-downloaded
    // default) and reuse the located binary for both the cache-populate
    // step and code generation below.
    const asm_bin = try assembler_proc.resolve(allocator, project_dir, "generate");
    defer asm_bin.deinit(allocator);
    std.debug.print("  using assembler: {s}\n", .{asm_bin.path});

    // (The ASTC conversion pre-pass used to run here, before the install.
    // It is a generation-input reader — it consumes the declared PNGs — so
    // it now runs inside the core `generate` step below, AFTER the `before
    // generate` provider hooks; see the note there.)

    // Ensure the package cache is populated. The assembler's `generate`
    // subcommand assumes a populated cache (it does not fetch packages
    // itself), so delegate `install --project-root` to the binary first.
    // This replaces the CLI's former in-process `cache.ensureCache`,
    // which depended on the assembler's `generator` module.
    //
    // The shader-compiler override gate runs immediately BEFORE this install
    // (cli#387 gap 3): a typo'd `LABELLE_SHADERC` used to be reported only
    // after the slow, network-bound fetch had finished. `--docker` selects the
    // docker-aware variant, which validates identically and then says that the
    // host path is not forwarded into the container.
    try install.gateThenInstall(
        allocator,
        project_dir,
        if (parsed_args.docker) material_toolchain.preflightDocker else material_toolchain.preflight,
        install.AssemblerInstaller{ .bin = asm_bin },
    );

    // ── Provider discovery, target ownership and hook plans ────────────
    // (`install.discoverAndPlan`; contract §6, docs/provider-hooks.md,
    // docs/provider-targets.md)
    var provider_sources: provider_github.Sources = .{ .a = hook_arena };
    defer provider_sources.deinit();
    const planned = switch (try install.discoverAndPlan(allocator, hook_arena, project_dir, project_root, command, parsed_args.run_watch, parsed, requested_target, reporter, &provider_sources)) {
        .ready => |ready| ready,
        .exit => |code| return code,
    };
    const providers = planned.providers;
    const target = planned.target;
    const hook_plans = planned.hook_plans;

    // Generate into .labelle/
    const output_dir = try std.fs.path.join(allocator, &.{ project_dir, ".labelle" });
    defer allocator.free(output_dir);

    // GUI resolution (reading the plugin's gui.labelle manifest) is owned
    // by the assembler's `generate` subcommand — the CLI no longer
    // resolves it. The status line reports whether a GUI is *configured*
    // in project.labelle; the assembler logs the resolved plugin name.
    const gui_label: []const u8 = if (parsed.gui != null) "configured" else "none";
    if (reporter) |r| r.beginPhase(.generate, "assembler generate");
    std.debug.print("labelle: generating '{s}'...\n", .{parsed.name});
    std.debug.print("  backend: {s}  target: {s}  ecs: {s}  gui: {s}  window: {d}x{d}\n", .{
        @tagName(parsed.backend), target.name, @tagName(parsed.ecs), gui_label, parsed.width, parsed.height,
    });

    // Scenes and prefabs are always embedded via @embedFile
    //
    // The effective optimize mode (`pipeline/optimize.zig`): an explicit
    // `--optimize` wins; else the target owner's `.target_defaults`; else
    // none (Zig's default). The core keeps no per-target default of its own.
    const effective_optimize = optimize_mod.effective(
        parsed_args.optimize_override,
        optimize_mod.ownerDefault(providers, target.name),
        null,
    ).mode;

    // A path that cannot carry a provider's environment contribution or its
    // optimize default refuses here, before any hook, generation or build,
    // rather than silently bypassing the provider (`install.providerBypass`).
    if (install.providerBypass(
        command,
        parsed_args.docker,
        provider_hooks.planContributor(hook_plans.generate, hook_plans.build) != null,
        optimize_mod.ownerDefault(providers, target.name) != null,
        hook_plans.build.replace != null,
    )) |bypass| {
        if (provider_hooks.planContributor(hook_plans.generate, hook_plans.build)) |hook| {
            std.debug.print("labelle: hook '{s}' may contribute an environment for target '{s}'\n", .{ hook.qualified, target.name });
        } else {
            std.debug.print("labelle: '{s}' declares an optimize default for target '{s}'\n", .{ target.providerName(), target.name });
        }
        std.debug.print("labelle: {s}\n", .{bypass.message()});
        if (reporter) |r| r.finishFailed(1, "the build path cannot carry the provider's inputs");
        return 1;
    }

    // Everything a provider hook run needs. The host compiler is resolved by
    // the first hook that runs (never for an empty plan), and hooks report
    // under the phase of the core step they wrap; the wire `optimize` and
    // `progress` mirror this invocation's, so a hook builds what the core
    // step builds and speaks the mode the user asked for.
    const hook_optimize = std.meta.stringToEnum(provider_contract.Optimize, effective_optimize orelse "Debug") orelse {
        std.debug.print("labelle: unknown optimize mode '{s}'\n", .{effective_optimize.?});
        return 1;
    };
    var hook_site: provider_hooks.Site = .{
        .a = hook_arena,
        .backing = allocator,
        .providers = providers,
        .root = project_root,
        .cfg = parsed,
        .target = target.name,
        .optimize = hook_optimize,
        .progress = switch (parsed_args.progress_mode) {
            .human => .human,
            .json => .json,
            .off => .off,
        },
        .reporter = reporter,
        // Reaches the `bundle` hooks only; a provider target's bundle
        // replacement would otherwise drop it silently (Codex P2 on #421).
        .build_number = if (command == .bundle_cmd) parsed_args.bundle_build_number else null,
        // Every hook's contract §2 `target_dir` (wire 1.2.0+), under the
        // canonical root so it is absolute whatever `project_dir` was.
        .target_dir = try std.fs.path.join(hook_arena, &.{ project_root, ".labelle", target_name }),
        // The `run` hooks' contract §2 `run` (wire 1.2.0+): the options the
        // core launch would set, for a replacement standing in for it.
        .run_options = if (command == .run) try run_stage.hookRunOptions(hook_arena, &parsed_args) else null,
    };
    // The hooks' environment contributions (contract §2) live until the
    // command ends: the run and bundle hooks after the build still see them.
    defer hook_site.env.deinit();

    const cx: context.Context = .{
        .allocator = allocator,
        .parsed_args = &parsed_args,
        .parsed = parsed,
        .project_dir = project_dir,
        .hook_arena = hook_arena,
        .target_name = target_name,
        .target_dir = target_dir,
        .output_dir = output_dir,
        .reporter = reporter,
        .asm_bin = asm_bin,
        .providers = providers,
        .provider_sources = &provider_sources,
        .target = target,
        .hook_plans = hook_plans,
        .hook_site = &hook_site,
        .effective_optimize = effective_optimize,
        .watch_baseline = watch_baseline,
    };

    // Provider hooks on `generate` around the core generation
    // (`generate.run`).
    const generate_out = try provider_hooks.stepOutputDir(hook_arena, target_dir, .generate, target.name, null);
    if (try generate.run(&cx, generate_out)) |code| return code;

    if (command == .generate) return 0;

    // `labelle ios` subcommand — handles its own build/xcode/run
    if (command == .ios_cmd) {
        return ok(ios.handleIos(allocator, parsed_args.extra_args[0..parsed_args.extra_count], parsed, target_dir));
    }

    // Warn if --target is used without --docker (it has no effect otherwise)
    if (parsed_args.docker_target != null and !parsed_args.docker) {
        std.debug.print("labelle: warning: --target has no effect without --docker\n", .{});
    }

    // Build with the effective optimize mode computed above.
    const optimize_flag: ?[]const u8 = if (effective_optimize) |opt|
        try std.fmt.allocPrint(allocator, "-Doptimize={s}", .{opt})
    else
        null;
    defer if (optimize_flag) |f| allocator.free(f);

    // Resolve the managed Zig toolchain (labelle-cli#279): every `zig` spawn
    // uses this binary, never PATH. Downloads + verifies on a cache miss.
    // Skipped for docker builds — the toolchain lives inside the container.
    const managed_zig: ?[]u8 = if (parsed_args.docker) null else try runner.resolveZigExe(allocator, project_dir);
    defer if (managed_zig) |z| allocator.free(z);

    // Build a base env for child `zig` that pins ZIG_*_CACHE_DIR into the
    // labelle cache tree (user-writable, never next to a read-only install).
    // A provider's toolchain reaches the compile through its hooks'
    // environment contributions (contract §2 `env_file`), merged on top of
    // this base by the build stage.
    var zig_env_storage: ?std.process.Environ.Map = if (parsed_args.docker)
        null
    else
        try runner.buildZigEnv(allocator, &.{});
    defer if (zig_env_storage) |*m| m.deinit();
    const zig_env_ptr: ?*const std.process.Environ.Map = if (zig_env_storage) |*m| m else null;

    var zig_args: std.ArrayList([]const u8) = .empty;
    defer zig_args.deinit(allocator);
    try zig_args.append(allocator, managed_zig orelse "zig");
    try zig_args.append(allocator, "build");
    if (optimize_flag) |flag| try zig_args.append(allocator, flag);

    // Provider hooks on `build` around the core build (`build.run`).
    const build_out = try provider_hooks.stepOutputDir(hook_arena, target_dir, .build, target.name, null);
    if (try build.run(&cx, build_out, zig_args.items, zig_env_ptr, wants_sdl2)) |code| return code;

    // `labelle bundle` (cli#359): the exe is built; wrap it
    // (`build.bundleStep`).
    if (command == .bundle_cmd) return build.bundleStep(&cx);

    if (command == .build) {
        // (The build's finalization — the Linux `.desktop` entry and the
        // APK packaging — ran inside the core build above, ahead of the
        // `after build` hooks.)
        if (reporter) |r| r.finishDone(0);
        return 0;
    }

    // Run: the `run` hook phases around the launch branches
    // (`run_stage.launch`).
    return run_stage.launch(&cx, generate_out, build_out, zig_args.items, zig_env_ptr);
}

// Reference every module so its tests run: a file reached only lazily
// (or not at all from here) would silently drop out of `zig build test`.
test {
    _ = args_resolve;
    _ = install;
    _ = generate;
    _ = build;
    _ = run_stage;
    _ = context;
    _ = rebuild;
    _ = rebuild_replan;
    _ = rebuild_replan_tests;
    _ = @import("pipeline/rebuild_transaction_tests.zig");
    _ = @import("pipeline/rebuild_commit_tests.zig");
    _ = @import("pipeline/rebuild_lock_tests.zig");
    _ = session_key;
    _ = watch_session;
    _ = optimize_mod;
    _ = screenshot;
    _ = testing;
}
