//! The build and bundle stages: the `build` hook phases around the core
//! build (docker or host `zig build`, SDL2 DLL staging and the `labelle
//! build` packaging finalisation), and the `bundle` step.
const std = @import("std");
const docker = @import("../docker.zig");
const runner = @import("../runner.zig");
const android = @import("../android.zig");
const sdl_provision = @import("../sdl_provision.zig");
const bundle = @import("../bundle.zig");
const linux_desktop = @import("../linux_desktop.zig");
const provider_hooks = @import("../provider_hooks.zig");
const Context = @import("context.zig").Context;

/// Provider hooks on `build` (contract §6) wrap the whole core build —
/// docker or host `zig build` plus the runtime DLL staging — with
/// `output_dir` = the target's `zig-out/`. A `replace` hook stands in for
/// all of it. Hooks report under the `compile` phase.
///
/// Returns the exit status the command ends with, or null to go on.
pub fn run(
    cx: *const Context,
    build_out: []const u8,
    zig_args: []const []const u8,
    zig_env_ptr: ?*const std.process.Environ.Map,
    wants_sdl2: bool,
) !?u8 {
    const allocator = cx.allocator;
    const command = cx.parsed_args.command;
    const parsed = cx.parsed;
    const parsed_args = cx.parsed_args;
    const project_dir = cx.project_dir;
    const target_dir = cx.target_dir;
    const target = cx.target;
    const reporter = cx.reporter;
    const effective_optimize = cx.effective_optimize;
    const hook_site = cx.hook_site;
    const hook_plans = cx.hook_plans;

    {
        const code = try provider_hooks.runPhase(hook_site, hook_plans.build.before, .build, .before, build_out);
        if (code != 0) return code;
    }
    core_build: {
        if (hook_plans.build.replace) |replacement| {
            const code = try provider_hooks.runPhase(hook_site, &.{replacement}, .build, .replace, build_out);
            if (code != 0) return code;
            break :core_build;
        }
        if (parsed_args.docker) {
            // Docker builds get phase-level progress only: the toolchain (and
            // its progress pipe) lives inside the container.
            if (reporter) |r| r.beginPhaseOrStep(.compile, "docker build");
            std.debug.print("labelle: building via docker...\n", .{});
            const docker_exit = try docker.runBuild(allocator, target_dir, parsed.platform, parsed_args.docker_target, effective_optimize);
            if (reporter) |r| r.clearSpinner();
            if (docker_exit != 0) {
                if (reporter) |r| r.finishFailed(docker_exit, "docker build failed");
                std.debug.print("labelle: docker build failed (exit code {d})\n", .{docker_exit});
                return error.BuildFailed;
            }
        } else if (reporter) |r| {
            // cli#284: spawn `zig build` with Zig's std.Progress IPC pipe
            // attached — live node names + keepalives flow into the feed
            // during the compile (see runner.zig for what Zig 0.16 actually
            // relays), and stdio is inherited so compile errors stream to the
            // terminal unaltered (nothing is captured or eaten).
            std.debug.print("labelle: building...\n", .{});
            r.beginPhaseOrStep(.compile, "zig build");
            const build_code = try runner.runZigInheritProgress(allocator, target_dir, zig_args, zig_env_ptr, r);
            // Wipe the spinner line before anything else prints on it.
            r.clearSpinner();
            if (build_code != 0) {
                r.finishFailed(build_code, "zig build failed");
                std.debug.print("labelle: build failed (exit {d})\n", .{build_code});
                return error.BuildFailed;
            }
        } else {
            std.debug.print("labelle: building...\n", .{});
            const build_result = try runner.runZigWithEnv(allocator, target_dir, zig_args, zig_env_ptr);
            defer allocator.free(build_result.stdout);
            defer allocator.free(build_result.stderr);

            switch (build_result.term) {
                .exited => |code| if (code != 0) {
                    std.debug.print("labelle: build failed:\n{s}\n", .{build_result.stderr});
                    return error.BuildFailed;
                },
                else => {
                    std.debug.print("labelle: build process terminated abnormally\n{s}\n", .{build_result.stderr});
                    return error.BuildFailed;
                },
            }
        }
        std.debug.print("  build ok\n", .{});

        // Stage the runtime SDL2.dll next to the freshly-built desktop exe. A
        // gamepad/SDL2 build's exe fails process creation with a bare
        // `FileNotFound` when SDL2.dll isn't in its own directory (cli#285): the
        // Windows loader resolves implicitly-linked DLLs from the exe dir first,
        // and neither the PATH prepend from autoWireEnv nor a user-set
        // LABELLE_SDL2_LIB puts the DLL there. Docker builds are skipped — their
        // exe is built for the container's OS, so a host SDL2.dll is irrelevant.
        if (!parsed_args.docker and parsed.platform == .desktop and wants_sdl2) {
            const bin_dir = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "bin" });
            defer allocator.free(bin_dir);
            sdl_provision.stageSdl2DllBesideExe(allocator, bin_dir);
        }

        // `labelle build` finalization — everything that turns the compiled
        // tree into the command's final artifact. It sits INSIDE the core
        // build so the `after build` hooks below see the finished artifact
        // (a signing, inspecting or publishing hook used to run before the
        // APK existed, and reported success even when packaging then
        // failed — Codex P2 on #420), and so that a `replace build` hook
        // owns it: the replacement produces the artifact its target needs,
        // packaging included.
        if (command == .build) {
            // Linux `.desktop` entry + icon (cli#359): after a desktop build,
            // write `zig-out/<exe>.desktop` + `zig-out/<exe>.png` beside `bin/`
            // — automatically on a Linux host, or anywhere with
            // `--linux-desktop`. Skipped under `--docker`: that exe was built
            // for the container's target and the entry's absolute paths would
            // describe this host, not the one that will run it. `run` is
            // deliberately left alone — the entry is a packaging artifact.
            // Core desktop only: a provider target is packaged by its provider.
            if (!parsed_args.docker and target.provider == null and linux_desktop.shouldEmit(parsed_args.linux_desktop)) {
                const entry_path = try linux_desktop.createFromBuild(allocator, project_dir, target_dir, parsed);
                allocator.free(entry_path);
            }
            // `labelle build --platform=android` builds the shared library
            // above (the generic `zig build` produces `zig-out/lib/libgame.so`)
            // but, unlike `labelle android build`, used to stop there and leave
            // a bare `.so`. Package it into a signed APK so the artifact is
            // installable — backend-agnostic, so it covers sokol and bgfx alike.
            if (parsed.platform == .android) {
                const apk_path = try android.packageApk(allocator, project_dir, target_dir, parsed, false, .{}, .{
                    .strip_native = android.stripForOptimize(effective_optimize),
                });
                defer allocator.free(apk_path);
                std.debug.print("labelle: APK ready: {s}\n", .{apk_path});
            }
        }
    }
    {
        const code = try provider_hooks.runPhase(hook_site, hook_plans.build.after, .build, .after, build_out);
        if (code != 0) return code;
    }
    return null;
}

/// `labelle bundle` (cli#359): the exe is built; wrap it. Packaging
/// runs AFTER the compile, so keep the progress feed open across it
/// (a `run` phase, as `wasm export` does) and only mark `done` once
/// the `.app` is on disk — a `--progress=json` consumer must not see
/// `done` before the artifact exists.
pub fn bundleStep(cx: *const Context) !u8 {
    const allocator = cx.allocator;
    const parsed = cx.parsed;
    const parsed_args = cx.parsed_args;
    const project_dir = cx.project_dir;
    const target_dir = cx.target_dir;
    const hook_arena = cx.hook_arena;
    const reporter = cx.reporter;
    const hook_site = cx.hook_site;
    const hook_plans = cx.hook_plans;

    if (reporter) |r| {
        r.beginPhaseOrStep(.run, "packaging bundle");
        r.clearSpinner();
    }
    // Provider hooks on `bundle` (contract §6). `output_dir` is the step
    // output directory — `zig-out/bundle/<target>/`, or the resolved
    // `--output` — which is also where the core packager puts the
    // `.app` (`bundle.resolveOutputDir` shares the default), so hooks
    // and the packager always agree on the artifact's directory.
    const bundle_override: ?[]const u8 = if (parsed_args.bundle_output) |o|
        try bundle.resolveOutputDir(hook_arena, project_dir, target_dir, o)
    else
        null;
    const bundle_out = try provider_hooks.stepOutputDir(hook_arena, target_dir, .bundle, cx.target.name, bundle_override);
    {
        // The feed returns to "packaging bundle" once the hooks are done.
        const code = try provider_hooks.runBefore(hook_site, hook_plans.bundle.before, .bundle, bundle_out, "packaging bundle");
        if (code != 0) return code;
    }
    core_bundle: {
        if (hook_plans.bundle.replace) |replacement| {
            const code = try provider_hooks.runPhase(hook_site, &.{replacement}, .bundle, .replace, bundle_out);
            if (code != 0) return code;
            break :core_bundle;
        }
        const app_path = try bundle.createFromBuild(allocator, project_dir, target_dir, parsed, .{
            .output = parsed_args.bundle_output,
            .build_number = parsed_args.bundle_build_number,
        });
        defer allocator.free(app_path);
        // `createFromBuild` already printed the plain path. The paste-able
        // hint is single-quoted so a `"`, `$VAR` or backtick in a project
        // title stays literal instead of expanding in the user's shell.
        const quoted = try bundle.shellSingleQuote(allocator, app_path);
        defer allocator.free(quoted);
        std.debug.print("  open {s}\n", .{quoted});
    }
    {
        const code = try provider_hooks.runPhase(hook_site, hook_plans.bundle.after, .bundle, .after, bundle_out);
        if (code != 0) return code;
    }
    if (reporter) |r| r.finishDone(0);
    return 0;
}
