//! The run stage: the `run` hook phases around the launch branches (wasm
//! serve / export with the `--watch` wiring, the iOS deploy,
//! the host and docker launches) and the `RunOutcome` plumbing, plus the
//! `wasm serve|export --no-build` path that skips generate and build.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const project_config = @import("../project_config.zig");
const runner = @import("../runner.zig");
const prebuild = @import("../prebuild.zig");
const serve = @import("../serve.zig");
const export_mod = @import("../export.zig");
const ios = @import("../ios.zig");
const util = @import("../util.zig");
const progress = @import("../progress.zig");
const args_mod = @import("../args.zig");
const provider_contract = @import("../provider_contract.zig");
const provider_dispatch = @import("../provider_dispatch.zig");
const provider_github = @import("../provider_github.zig");
const provider_hooks = @import("../provider_hooks.zig");
const refuseLegacyWasmReplacement = @import("args_resolve.zig").refuseLegacyWasmReplacement;
const confirmTarget = @import("args_resolve.zig").confirmTarget;
const AssemblerInstaller = @import("install.zig").AssemblerInstaller;
const resolveExportOutput = @import("export_output.zig").resolveExportOutput;
const ScreenshotProbe = @import("screenshot.zig").ScreenshotProbe;
const RebuildCtx = @import("rebuild.zig").RebuildCtx;
const Replanner = @import("rebuild_replan.zig").Replanner;
const watch_session = @import("watch_session.zig");
const refuseKnownLegacyWasmReplacement = @import("args_resolve.zig").refuseKnownLegacyWasmReplacement;
const optimize_mod = @import("optimize.zig");
const Context = @import("context.zig").Context;
const ParsedArgs = args_mod.ParsedArgs;
const appendRunForwardedArgs = args_mod.appendRunForwardedArgs;

/// `labelle wasm serve|export --no-build` — skip the generate+build
/// pipeline and serve/package the existing build output. The web dir
/// lives under the wasm target subdir (`.labelle/<backend>_wasm/`).
///
/// Only generate and build are skipped: serving or exporting the existing
/// artifact IS the `run` step, so the `run` hook plan (contract §6) runs
/// here exactly as on the building path — `--no-build` used to return
/// before discovery and silently dropped every declared run hook (Codex
/// P2 on #420). No installer runs on this path, so discovery is the
/// metadata-only kind (`.unknown`, as `labelle help`): a declared remote
/// package absent from every cache is not listed rather than reported as
/// a broken install that never happened.
pub fn serveNoBuild(
    allocator: std.mem.Allocator,
    hook_arena: std.mem.Allocator,
    project_dir: []const u8,
    project_root: []const u8,
    parsed: project_config.ProjectConfig,
    parsed_args: *const ParsedArgs,
    requested_target: []const u8,
) !u8 {
    // Nothing is installed on this path, so the provisional target is
    // confirmed against the providers discoverable as-is (`.unknown`,
    // like `labelle targets`): a package absent from the cache cannot
    // own a target here. Same diagnostics as the pipeline's own check.
    var no_build_sources: provider_github.Sources = .{ .a = hook_arena };
    defer no_build_sources.deinit();
    const known = provider_dispatch.discover(hook_arena, project_root, parsed, &no_build_sources, .unknown) catch |err| {
        std.debug.print("labelle: provider discovery failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    const served = switch (try confirmTarget(hook_arena, project_root, known, requested_target)) {
        .resolved => |resolved| resolved,
        .refused => return 1,
    };
    const no_build_plan = try provider_hooks.plan(hook_arena, known, .run, served.name);
    if (refuseLegacyWasmReplacement(no_build_plan)) return 1;
    const wasm_target = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ @tagName(parsed.backend), served.name });
    defer allocator.free(wasm_target);
    const wasm_target_dir = try std.fs.path.join(allocator, &.{ project_dir, ".labelle", wasm_target });
    defer allocator.free(wasm_target_dir);
    const web_dir = try std.fs.path.join(allocator, &.{ wasm_target_dir, "zig-out", "web" });
    defer allocator.free(web_dir);
    if (std.Io.Dir.cwd().access(config.globalIo(), web_dir, .{})) |_| {} else |_| {
        const verb = if (parsed_args.wasm_export) "export" else "serve";
        std.debug.print(
            "labelle wasm {s}: no existing WASM build at '{s}'\n" ++
                "  run `labelle wasm {s}` (without --no-build) first.\n",
            .{ verb, web_dir, verb },
        );
        return error.BuildFailed;
    }
    const project_web_dir = try std.fs.path.join(allocator, &.{ project_dir, "web" });
    defer allocator.free(project_web_dir);

    // The same wire `optimize` the building path reports for this
    // platform; there is no progress feed on this path.
    const no_build_optimize = std.meta.stringToEnum(provider_contract.Optimize, optimize_mod.effective(
        parsed_args.optimize_override,
        optimize_mod.ownerDefault(known, served.name),
        "ReleaseSafe",
    ).mode.?) orelse {
        std.debug.print("labelle: unknown optimize mode '{s}'\n", .{parsed_args.optimize_override.?});
        return 1;
    };
    var no_build_site: provider_hooks.Site = .{
        .a = hook_arena,
        .backing = allocator,
        .providers = known,
        .root = project_root,
        .cfg = parsed,
        .target = served.name,
        // Contract §2 `target_dir`, under the canonical root so it is
        // absolute whatever `project_dir` was (the building path's
        // `hook_site` does the same); `wasm_target_dir` keeps the raw
        // `project_dir`, so `wasm serve ../game --no-build` made it relative.
        .target_dir = try std.fs.path.join(hook_arena, &.{ project_root, ".labelle", wasm_target }),
        .optimize = no_build_optimize,
        .progress = switch (parsed_args.progress_mode) {
            .human => .human,
            .json => .json,
            .off => .off,
        },
        .reporter = null,
    };
    const no_build_out = try provider_hooks.stepOutputDir(hook_arena, wasm_target_dir, .run, served.name, null);
    {
        const code = try provider_hooks.runPhase(&no_build_site, no_build_plan.before, .run, .before, no_build_out);
        if (code != 0) return code;
    }
    if (no_build_plan.replace) |replacement| {
        const code = try provider_hooks.runPhase(&no_build_site, &.{replacement}, .run, .replace, no_build_out);
        if (code != 0) return code;
        return provider_hooks.finishRun(&no_build_site, no_build_plan.after, no_build_out, .exited_clean);
    }
    if (parsed_args.wasm_export) {
        const out_abs = try resolveExportOutput(allocator, project_dir, parsed_args.export_output);
        defer allocator.free(out_abs);
        try export_mod.packageExport(allocator, web_dir, project_web_dir, .{
            .output_dir = out_abs,
            .zip = parsed_args.export_zip,
            .platform = parsed_args.export_pkg_platform,
        });
        return provider_hooks.finishRun(&no_build_site, no_build_plan.after, no_build_out, .exited_clean);
    }
    // No watch in the `--no-build` path (the parser already rejects the
    // `--watch --no-build` combination, so `serve_watch` is false here).
    // The server returns on Ctrl+C / SIGTERM, the serve's clean end, and
    // the after hooks run then — as on the building path.
    try serve.serveAndOpen(allocator, web_dir, project_web_dir, parsed_args.serve_port, !parsed_args.serve_no_open, null);
    return provider_hooks.finishServe(&no_build_site, no_build_plan.after, no_build_out);
}

/// Provider hooks on `run` (contract §6): `before` runs once here, ahead
/// of every branch below; a `replace` hook stands in for all of them;
/// `after` runs at each branch's success exit through
/// `provider_hooks.finishRun`, which also owns the terminal `done` record
/// so a `--progress=json` consumer never sees `done` before the hooks
/// finished. After hooks never run unless the game itself exited 0 —
/// not after a nonzero exit, not after the `--timeout` watchdog's kill
/// (exit 0 for the CLI, cli#390) and not after a detached simulator or
/// device launch (`provider_hooks.RunOutcome`). The interactive `wasm
/// serve` loop is the one exception in timing: its `done` record lands
/// before the loop and the after hooks run only once the server returns.
///
/// A cross-compiled `--docker --target=<t>` binary cannot run on this
/// host, so the core launch is skipped — and with it the whole `run`
/// step: decided HERE, before the `before run` hooks, so no run hook
/// prepares (or fails) a launch that never happens (Codex P2 on #420).
pub fn launch(
    cx: *const Context,
    generate_out: []const u8,
    build_out: []const u8,
    zig_args: []const []const u8,
    zig_env_ptr: ?*const std.process.Environ.Map,
) !u8 {
    const allocator = cx.allocator;
    const timeout_ns = cx.parsed_args.timeout_ns;
    const parsed = cx.parsed;
    const parsed_args = cx.parsed_args;
    const project_dir = cx.project_dir;
    const target_dir = cx.target_dir;
    const target = cx.target;
    const reporter = cx.reporter;
    const hook_arena = cx.hook_arena;
    const hook_site = cx.hook_site;
    const hook_plans = cx.hook_plans;

    if (crossTargetLaunchSkipped(parsed_args.docker, parsed_args.docker_target, parsed.platform, hook_plans.run.replace != null)) |t| {
        std.debug.print("labelle: cannot run cross-compiled binary (target: {s})\n", .{t});
        std.debug.print("  binary is at: {s}/zig-out/bin/\n", .{target_dir});
        if (reporter) |r| r.finishDone(0); // build succeeded; run skipped
        return 0;
    }
    const run_out = try provider_hooks.stepOutputDir(hook_arena, target_dir, .run, target.name, null);
    {
        const code = try provider_hooks.runPhase(hook_site, hook_plans.run.before, .run, .before, run_out);
        if (code != 0) return code;
    }
    if (hook_plans.run.replace) |replacement| {
        // `labelle run --watch` (RFC cli#466 §3.4): the replacement serves
        // while core rebuilds and publishes (`watch_session.zig`). The
        // install stage already refused a replacement that cannot watch.
        if (parsed_args.run_watch) return watch_session.run(cx, replacement, run_out, generate_out, build_out, zig_args, zig_env_ptr);
        const code = try provider_hooks.runPhase(hook_site, &.{replacement}, .run, .replace, run_out);
        if (code != 0) return code;
        return provider_hooks.finishRun(hook_site, hook_plans.run.after, run_out, .exited_clean);
    }
    if (parsed.platform == .wasm) {
        const web_dir = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "web" });
        defer allocator.free(web_dir);
        const project_web_dir = try std.fs.path.join(allocator, &.{ project_dir, "web" });
        defer allocator.free(project_web_dir);
        if (parsed_args.wasm_export) {
            // `wasm export`: package the fresh build into a deployment dir
            // instead of serving it. Packaging runs AFTER the build, so
            // keep the progress feed open across it (a run phase) and only
            // mark `done` once the artifacts are on disk — otherwise a
            // `--progress=json` consumer sees `done` before the export.
            if (reporter) |r| {
                r.beginPhaseOrStep(.run, "packaging wasm export");
                r.clearSpinner();
            }
            const out_abs = try resolveExportOutput(allocator, project_dir, parsed_args.export_output);
            defer allocator.free(out_abs);
            try export_mod.packageExport(allocator, web_dir, project_web_dir, .{
                .output_dir = out_abs,
                .zip = parsed_args.export_zip,
                .platform = parsed_args.export_pkg_platform,
            });
            return provider_hooks.finishRun(hook_site, hook_plans.run.after, run_out, .exited_clean);
        } else {
            // WASM serve: the loop is interactive (runs until Ctrl+C), so
            // the terminal `done` record lands before the serve loop. The
            // loop returns on Ctrl+C / SIGTERM (`serve.serveAndOpen`
            // installs the handler), which is how the `after run` hooks
            // below become reachable at all (Codex P2 on #420); a failing
            // one revises that provisional `done` (`finishServe`).
            if (reporter) |r| r.finishDone(0);
            // The watched session's replan storage lives at THIS scope, not
            // inside the `--watch` branch: once a rebuild has replanned,
            // `hook_site.cfg`/`providers` point into its current generation,
            // and the `after run` hooks below resolve settings through them.
            // Destroyed at the watch branch's end, that storage was freed
            // before the shutdown hooks read it (Codex P2 on #420). The
            // defer runs after the `return` expression below is evaluated,
            // i.e. after the hooks, and restores the startup storage on the
            // site as it releases the generation.
            const watch_installer = AssemblerInstaller{ .bin = cx.asm_bin };
            var watch_replan = Replanner{
                .backing = allocator,
                .project_dir = project_dir,
                .installer = Replanner.assemblerInstaller(&watch_installer),
                // A running legacy serve cannot switch server
                // implementations: a replan that adds a run replacement
                // is refused.
                .forbid_run_replacement = .{ .plan = refuseLegacyWasmReplacement, .known = refuseKnownLegacyWasmReplacement },
            };
            defer watch_replan.deinit(hook_site, cx.providers, parsed);
            if (parsed_args.serve_watch) {
                // `--watch` (cli#208): hand the serve loop the generic
                // rebuild callback (`RebuildCtx`, the same one `labelle run
                // --watch` drives). The context borrows locals that stay
                // alive because `serveAndOpen` blocks until Ctrl+C.
                //
                // Every rebuild re-reads the project and replans through
                // `watch_replan`, transactionally (cli#469); the plans
                // computed above are only the initial state. The project
                // the cold pipeline just installed and locked is the
                // replan's baseline.
                watch_replan.baseline();
                watch_replan.seed(cx.provider_sources);
                var rebuild_ctx = RebuildCtx{
                    .allocator = allocator,
                    .asm_bin = cx.asm_bin,
                    .project_dir = project_dir,
                    .platform_tag = target.name,
                    .backend_tag = @tagName(parsed.backend),
                    .output_dir = cx.output_dir,
                    .target_dir = target_dir,
                    .zig_args = zig_args,
                    .zig_env = zig_env_ptr,
                    .optimize_flag = parsed_args.optimize_override,
                    .fallback_optimize = "ReleaseSafe",
                    .prebuild_steps = parsed.prebuild,
                    .prebuild_opts = .{
                        .route_stdout_to_stderr = parsed_args.progress_mode == .json,
                        .fatal_on_step_failure = false,
                    },
                    .hooks = hook_site,
                    .generate_plan = hook_plans.generate,
                    .build_plan = hook_plans.build,
                    .generate_out = generate_out,
                    .build_out = build_out,
                    .replan = watch_replan.seam(),
                    // The declared outputs of the prebuild steps are kept
                    // out of the watch signature, swapped together with the
                    // steps (cli#463) — but only while the steps actually
                    // run (`collectPrebuildIgnorePaths`).
                    .hooks_enabled = !prebuild.skipRequested(allocator),
                };
                rebuild_ctx.initIgnore();
                defer rebuild_ctx.deinit();

                try serve.serveAndOpen(allocator, web_dir, project_web_dir, parsed_args.serve_port, !parsed_args.serve_no_open, .{
                    .watch_dir = project_dir,
                    .rebuild_fn = RebuildCtx.rebuild,
                    .rebuild_ctx = &rebuild_ctx,
                    .ignore = &rebuild_ctx.ignore,
                });
            } else {
                try serve.serveAndOpen(allocator, web_dir, project_web_dir, parsed_args.serve_port, !parsed_args.serve_no_open, null);
            }
            // The server returned (Ctrl+C / SIGTERM): the serve's clean end.
            // The feed already says `done`; only the hooks run here, and a
            // failing one revises that record to `failed`.
            //
            // The hooks are the CURRENT generation's (`shutdownRunAfter`):
            // `hook_site` already carries that generation's providers and
            // config, and the lock on disk pins its versions.
            return provider_hooks.finishServe(hook_site, watch_replan.shutdownRunAfter(hook_plans.run.after), run_out);
        }
    } else if (parsed.platform == .ios) {
        // iOS: deploy to simulator
        if (reporter) |r| r.beginPhaseOrStep(.run, "deploying to iOS Simulator");
        std.debug.print("labelle: deploying to iOS Simulator...\n", .{});
        try ios.deployToSimulator(allocator, target_dir, parsed);
        // `simctl launch` returns while the app runs on: its exit is never
        // seen here, so this is not the clean exit after hooks wait for.
        return provider_hooks.finishRun(hook_site, hook_plans.run.after, run_out, .launched_detached);
    } else {
        if (timeout_ns) |t| {
            const secs = t / std.time.ns_per_s;
            const mins = secs / 60;
            const rem = secs % 60;
            if (mins > 0 and rem > 0) {
                std.debug.print("labelle: running (timeout: {d}m{d}s)...\n\n", .{ mins, rem });
            } else if (mins > 0) {
                std.debug.print("labelle: running (timeout: {d}m)...\n\n", .{mins});
            } else {
                std.debug.print("labelle: running (timeout: {d}s)...\n\n", .{secs});
            }
        } else {
            std.debug.print("labelle: running...\n\n", .{});
        }
        // Build a combined env map for the child when --scene (cli#229)
        // and/or --screenshot (cli#227) are set. Both flags need to be
        // surfaced as env vars to the spawned game:
        //  - LABELLE_SCENE          (cli#229 runtime scene-override)
        //  - LABELLE_SCREENSHOT_PATH
        //  - LABELLE_SCREENSHOT_AFTER_SEC
        // Loading-controller scripts read LABELLE_SCENE *after*
        // assets.allReady succeeds and call setScene(requested), so
        // asset streaming for large scenes no longer races boot. This
        // is now the ONLY mechanism for `--scene=` — the legacy
        // `.initial_prefab` rewrite was removed (see above).
        // Default the child env to the ZIG_*_CACHE_DIR map (cli#279) so the
        // rebuilt-and-run step still lands the compiler cache in user space.
        var env_map_storage: ?std.process.Environ.Map = null;
        defer if (env_map_storage) |*m| m.deinit();
        var env_map_ptr: ?*const std.process.Environ.Map = zig_env_ptr;
        const has_scene_env = parsed_args.scene_override != null;
        const has_screenshot_env = parsed_args.screenshot_path != null;
        // --headless (and the flags that imply it) surface as
        // LABELLE_HEADLESS=1 plus the optional uncapped/ticks knobs that
        // the sokol desktop backend reads. `parsed_args.headless` is
        // already set true by `--uncapped`/`--ticks`, so this one check
        // covers all three.
        const has_headless_env = parsed_args.headless;
        // --profile surfaces as LABELLE_PROFILE=1, enabling the engine's
        // built-in frame profiler. Independent of --headless.
        const has_profile_env = parsed_args.profile;
        // Fingerprint every path the capture could land at BEFORE the game
        // runs, so the post-run report can tell a file this run wrote from one
        // an earlier run left behind. The game's cwd — what a relative path
        // resolves against — is the project dir under --docker and the target
        // dir otherwise.
        const screenshot_probe: ?ScreenshotProbe = if (parsed_args.screenshot_path) |path|
            ScreenshotProbe.init(allocator, path, if (parsed_args.docker) project_dir else target_dir)
        else
            null;
        defer if (screenshot_probe) |p| p.deinit(allocator);
        if (has_scene_env or has_screenshot_env or has_headless_env or has_profile_env) {
            var extras: std.ArrayList(runner.EnvKV) = .empty;
            defer extras.deinit(allocator);
            // --scene / --profile / --screenshot(+--after): the list shared
            // with a `run`-step hook's `run.env` (`hookRunOptions`, cli#397).
            var sec_buf: [32]u8 = undefined;
            try runner.appendRunOptionEnv(allocator, &extras, runOptionEnv(parsed_args), &sec_buf);
            var ticks_buf: [32]u8 = undefined;
            if (parsed_args.headless) {
                try extras.append(allocator, .{ .key = "LABELLE_HEADLESS", .value = "1" });
                if (parsed_args.headless_uncapped) {
                    try extras.append(allocator, .{ .key = "LABELLE_HEADLESS_UNCAPPED", .value = "1" });
                }
                if (parsed_args.headless_ticks) |n| {
                    const ticks_str = try std.fmt.bufPrint(&ticks_buf, "{d}", .{n});
                    try extras.append(allocator, .{ .key = "LABELLE_HEADLESS_TICKS", .value = ticks_str });
                }
            }
            if (parsed_args.screenshot_path) |path| {
                // Deliberately "requested", not "will be written to": the
                // backend picks the real filename and may not honor this path
                // (labelle-bgfx#57 appends its own `.tga`). The authoritative
                // line is `ScreenshotProbe.report` after the run.
                std.debug.print("labelle: screenshot requested: '{s}'\n", .{path});
            }
            // For a non-docker run, fold the ZIG_*_CACHE_DIR vars in too so
            // both the build and run children share the managed cache. For a
            // docker run there is no managed toolchain, so just add extras.
            env_map_storage = if (parsed_args.docker)
                try runner.buildEnvironWithExtra(allocator, extras.items)
            else
                try runner.buildZigEnv(allocator, extras.items);
            env_map_ptr = &env_map_storage.?;
        }

        // When --docker was used, run the built binary directly instead of
        // calling `zig build run` (local Zig may be broken).
        if (parsed_args.docker) {
            // (A cross-compiled binary never reaches here: the launch is
            // skipped before the run hooks — `crossTargetLaunchSkipped`.)
            // The assembler names the desktop binary after the project
            // (sanitized) so concurrent games are distinguishable to
            // `pgrep` (labelle-assembler#362). Derive the same name here so
            // the docker run path execs the binary by its real on-disk name.
            const exe_name = try util.sanitizeExeName(allocator, parsed.name);
            defer allocator.free(exe_name);
            const bin_path = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "bin", exe_name });
            defer allocator.free(bin_path);
            var run_args: std.ArrayList([]const u8) = .empty;
            defer run_args.deinit(allocator);
            try run_args.append(allocator, bin_path);
            try appendRunForwardedArgs(&run_args, allocator, parsed_args);
            if (reporter) |r| r.beginPhaseOrStep(.run, exe_name);
            noteRunSharesStdout(reporter);
            const run_outcome = runOutcome(try runner.runInheritTerm(allocator, project_dir, run_args.items, timeout_ns, env_map_ptr));
            if (run_outcome == .exited_error) {
                std.debug.print("\nlabelle: process exited with code {d}\n", .{run_outcome.status()});
            }
            if (screenshot_probe) |p| p.report(allocator);
            // The game ran: the pipeline is `done` even on a nonzero game
            // exit — the code is carried in the terminal record, and it is
            // also the CLI's exit status (cli#390). After hooks run first,
            // and only when the game itself exited clean — never after the
            // watchdog's kill, which is also exit 0.
            return provider_hooks.finishRun(hook_site, hook_plans.run.after, run_out, run_outcome);
        } else {
            // Run the game BINARY DIRECTLY rather than via `zig build run`.
            // `zig build run` launches the game in its own child process
            // group, which ESCAPES the --timeout kill: the watchdog signals
            // labelle's direct child (the `zig build` process), the game
            // survives in its separate group, gets reparented to init, and
            // orphans. Run as labelle's own child and the game stays in the
            // process group the watchdog signals, so SIGTERM→SIGKILL
            // actually reaches it. Mirrors the --docker path.
            //
            // Keep the game's cwd at `target_dir` (a target_dir-relative
            // argv[0]) so saves land exactly where `zig build run` put them.
            //
            // There is deliberately NO second `zig build` here. The core
            // build above (`core_build`, or its `replace` hook) is the one
            // and only build of this command; the warm re-build that used
            // to sit here was a leftover of translating `zig build run`
            // into build-then-exec (cli#265) — a warm-cache no-op that
            // nonetheless re-ran the install steps, so a `zig-out/` file an
            // `after build` hook had signed, stripped or patched was copied
            // back to its unhooked original right before launch, and a
            // `replace` hook's build was quietly followed by the core one
            // (Codex P2 on #420). `run` begins when the game binary is
            // about to spawn.
            // Exe name: the assembler names the desktop exe after the
            // sanitized project (labelle-assembler#362); older generated
            // build.zig still emit `game`. Prefer the project name; fall back
            // to `game` when that binary isn't on disk, so this works both
            // before and after the rename ships. Run it by a target_dir-
            // relative path so the game's cwd stays `target_dir` (saves land
            // where `zig build run` put them). Mirrors the --docker path.
            // Probe with the platform executable suffix: on Windows the
            // assembler emits `<name>.exe`, so a suffix-less probe never
            // matches and would wrongly fall back to the legacy `game` name,
            // then fail to launch with FileNotFound (cli#309).
            const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
            const sanitized = try util.sanitizeExeName(allocator, parsed.name);
            defer allocator.free(sanitized);
            const sanitized_exe = try std.fmt.allocPrint(allocator, "{s}{s}", .{ sanitized, exe_suffix });
            defer allocator.free(sanitized_exe);
            const sanitized_full = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "bin", sanitized_exe });
            defer allocator.free(sanitized_full);
            const exe_basename: []const u8 = if (util.fileExists(sanitized_full)) sanitized_exe else "game" ++ exe_suffix;
            const rel_bin = try std.fs.path.join(allocator, &.{ "zig-out", "bin", exe_basename });
            defer allocator.free(rel_bin);
            var run_args: std.ArrayList([]const u8) = .empty;
            defer run_args.deinit(allocator);
            try run_args.append(allocator, rel_bin);
            try appendRunForwardedArgs(&run_args, allocator, parsed_args);
            if (reporter) |r| r.beginPhaseOrStep(.run, exe_basename);
            noteRunSharesStdout(reporter);
            const run_outcome = runOutcome(try runner.runInheritTerm(allocator, target_dir, run_args.items, timeout_ns, env_map_ptr));
            if (run_outcome == .exited_error) {
                std.debug.print("\nlabelle: process exited with code {d}\n", .{run_outcome.status()});
            }
            if (screenshot_probe) |p| p.report(allocator);
            // The game ran: the pipeline is `done` even on a nonzero game
            // exit — the code is carried in the terminal record, and it is
            // also the CLI's exit status (cli#390). After hooks run first,
            // and only when the game itself exited clean — never after the
            // watchdog's kill, which is also exit 0.
            return provider_hooks.finishRun(hook_site, hook_plans.run.after, run_out, run_outcome);
        }
    }
}

/// cli#320: in `--progress=json` mode a desktop `run` spawns the game
/// with inherited stdout, so the game's own log lines share the stream
/// with the NDJSON progress records — pure NDJSON on stdout is a
/// `build`-only guarantee. Say so once, on stderr, at the run-phase
/// seam (the two call sites below are mutually exclusive branches, so
/// the note prints exactly once per invocation). No-op when no reporter
/// is active — without one there is no NDJSON stream to interleave with.
fn noteRunSharesStdout(reporter: ?*progress.Reporter) void {
    const r = reporter orelse return;
    if (r.mode != .json) return;
    std.debug.print("labelle: note: during `run`, game output shares stdout with NDJSON progress records\n", .{});
}

/// The `--target` of a `run --docker` whose launch is skipped: a
/// cross-compiled binary cannot run on this host. Only the host launch
/// branch launches a binary here — `wasm` and `ios` deploy their own way,
/// and every other provider target has a `replace run` hook (the install
/// stage refuses it otherwise, `NoRunReplacement`), which stands in for the
/// launch entirely — so neither is skipped. `null` when the launch happens.
fn crossTargetLaunchSkipped(in_docker: bool, docker_target: ?[]const u8, platform: project_config.Platform, replaced: bool) ?[]const u8 {
    if (!in_docker or replaced) return null;
    switch (platform) {
        .wasm, .ios => return null,
        else => return docker_target,
    }
}

test "pipeline: a cross-target docker run is skipped before the run hooks" {
    // The skipped shape: docker, a cross target, the host launch branch.
    try std.testing.expectEqualStrings("aarch64-linux", crossTargetLaunchSkipped(true, "aarch64-linux", .desktop, false).?);
    // Each condition alone is not enough.
    try std.testing.expect(crossTargetLaunchSkipped(false, "aarch64-linux", .desktop, false) == null);
    try std.testing.expect(crossTargetLaunchSkipped(true, null, .desktop, false) == null);
    // A replacement launches its own way; the deploy targets never reach
    // the host launch branch.
    try std.testing.expect(crossTargetLaunchSkipped(true, "aarch64-linux", .desktop, true) == null);
    for ([_]project_config.Platform{ .wasm, .ios }) |platform| {
        try std.testing.expect(crossTargetLaunchSkipped(true, "aarch64-linux", platform, false) == null);
    }
    // `android` has no launch branch of its own any more: its provider's
    // `replace run` hook launches it (a cross target is not skipped then),
    // and without one the install stage refused the run already.
    try std.testing.expect(crossTargetLaunchSkipped(true, "aarch64-linux", .android, true) == null);
    try std.testing.expectEqualStrings("aarch64-linux", crossTargetLaunchSkipped(true, "aarch64-linux", .android, false).?);
}

/// The `labelle run` options that reach the game as `LABELLE_*` variables on
/// every platform (env block on desktop; a provider's `run` hook gets the same
/// pairs as `run.env` and decides how they reach its game — cli#397).
/// The `run` outcome a launched game's termination stands for.
fn runOutcome(term: runner.Termination) provider_hooks.RunOutcome {
    return switch (term) {
        .exited => |code| provider_hooks.RunOutcome.fromExit(code),
        .timed_out => .timed_out,
    };
}

fn runOptionEnv(parsed_args: *const ParsedArgs) runner.RunOptionEnv {
    return .{
        .scene = parsed_args.scene_override,
        .profile = parsed_args.profile,
        .screenshot_path = parsed_args.screenshot_path,
        .screenshot_after_ns = parsed_args.screenshot_after_ns,
    };
}

/// The `run` options a `run`-step hook receives (contract §2 `run`, wire
/// `1.2.0`+): `env` is exactly the list the core launch sets
/// (`runner.appendRunOptionEnv` over `runOptionEnv`), `args` the tokens
/// after `--`, `timeout_ms` the `--timeout`. The CLI maps nothing to any
/// platform: a provider decides how the pairs reach its game. Everything
/// lives on `a` (the pipeline's hook arena), which outlives every phase.
pub fn hookRunOptions(a: std.mem.Allocator, parsed_args: *const ParsedArgs) !provider_contract.RunContext {
    var extras: std.ArrayList(runner.EnvKV) = .empty;
    const sec_buf = try a.create([32]u8);
    try runner.appendRunOptionEnv(a, &extras, runOptionEnv(parsed_args), sec_buf);
    const env = try a.alloc(provider_contract.RunEnv, extras.items.len);
    for (extras.items, env) |kv, *entry| entry.* = .{ .name = kv.key, .value = kv.value };
    return .{
        .env = env,
        .args = try a.dupe([]const u8, parsed_args.extra_args[0..parsed_args.extra_count]),
        .timeout_ms = if (parsed_args.timeout_ns) |ns| ns / std.time.ns_per_ms else null,
    };
}

test "pipeline: a run hook's options are the core launch's LABELLE_* list, the -- args and the timeout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parsed_args: ParsedArgs = .{ .command = .run };
    // Nothing given: the empty set.
    const none = try hookRunOptions(a, &parsed_args);
    try std.testing.expect(!none.given());
    parsed_args.scene_override = "x";
    parsed_args.profile = true;
    parsed_args.screenshot_path = "s.png";
    parsed_args.screenshot_after_ns = 2 * std.time.ns_per_s;
    parsed_args.timeout_ns = 30 * std.time.ns_per_s;
    // Desktop-only knobs are not run options: they never reach a hook.
    parsed_args.headless = true;
    parsed_args.extra_args[0] = "a";
    parsed_args.extra_args[1] = "b";
    parsed_args.extra_count = 2;
    const options = try hookRunOptions(a, &parsed_args);
    try options.validate();
    // The mechanism: the pairs are the same list the core launch builds.
    var expected: std.ArrayList(runner.EnvKV) = .empty;
    var sec_buf: [32]u8 = undefined;
    try runner.appendRunOptionEnv(a, &expected, runOptionEnv(&parsed_args), &sec_buf);
    try std.testing.expectEqual(expected.items.len, options.env.len);
    for (expected.items, options.env) |kv, entry| {
        try std.testing.expectEqualStrings(kv.key, entry.name);
        try std.testing.expectEqualStrings(kv.value, entry.value);
    }
    try std.testing.expectEqual(@as(usize, 4), options.env.len);
    try std.testing.expectEqualStrings("LABELLE_SCREENSHOT_AFTER_SEC", options.env[3].name);
    try std.testing.expectEqualStrings("2.000", options.env[3].value);
    for (options.env) |entry| try std.testing.expect(!std.mem.eql(u8, entry.name, "LABELLE_HEADLESS"));
    try std.testing.expectEqual(@as(usize, 2), options.args.len);
    try std.testing.expectEqualStrings("b", options.args[1]);
    try std.testing.expectEqual(@as(?u64, 30_000), options.timeout_ms);
}
