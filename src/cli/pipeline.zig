//! Command-execution pipeline for the labelle CLI (#311). Extracted from
//! cli.zig `main` so the dispatcher stays small: this owns the
//! generate -> build -> run flow and the docker / wasm / ios / android
//! branches, plus the two execution helpers that go with it
//! (WasmRebuildCtx for `wasm serve --watch`; the export output-path
//! resolvers). Behavior is identical to when this lived in `main`.
const std = @import("std");
const builtin = @import("builtin");
const project_config = @import("project_config.zig");
const upgrade = @import("upgrade.zig");
const config = @import("config.zig");
const compatibility = @import("compatibility.zig");
const lockfile = @import("lockfile.zig");
const runner = @import("runner.zig");
const assembler = @import("assembler.zig");
const assembler_proc = @import("assembler_proc.zig");
const emsdk_toolchain = @import("emsdk_toolchain.zig");
const emsdk_activate = @import("emsdk_activate.zig");
const python_provision = @import("python_provision.zig");
const prebuild = @import("prebuild.zig");
const bake_mod = @import("bake.zig");
const docker = @import("docker.zig");
const serve = @import("serve.zig");
const export_mod = @import("export.zig");
const ios = @import("ios.zig");
const android = @import("android.zig");
const util = @import("util.zig");
const progress = @import("progress.zig");
const astc_cmd = @import("../astc/cmd.zig");
const sdl_provision = @import("sdl_provision.zig");
const bundle = @import("bundle.zig");
const linux_desktop = @import("linux_desktop.zig");
const args_mod = @import("args.zig");
const screenshot_format = @import("screenshot_format.zig");
const ParsedArgs = args_mod.ParsedArgs;
const appendRunForwardedArgs = args_mod.appendRunForwardedArgs;
const resolveAndroidBackend = args_mod.resolveAndroidBackend;

/// Rebuild context for `wasm serve --watch` (cli#208). Bundles the
/// generate+build inputs the initial pipeline computed so the serve
/// loop's watcher thread can re-run them on a source change. Passed to
/// `serve.serveAndOpen` as an opaque `*anyopaque` + a static `rebuild`
/// entry point matching `serve.RebuildFn`.
const WasmRebuildCtx = struct {
    allocator: std.mem.Allocator,
    asm_bin: assembler_proc.Assembler,
    project_dir: []const u8,
    platform_tag: []const u8,
    backend_tag: []const u8,
    output_dir: []const u8,
    target_dir: []const u8,
    zig_args: []const []const u8,
    zig_env: ?*const std.process.Environ.Map,
    /// The project's declared `.prebuild` steps (cli#355), borrowed from
    /// the parse arena. A watched rebuild must re-run them: they are what
    /// turn an edited `.tsx`/generator into the atlas or `.zig` table the
    /// regeneration below then reads, so skipping them would serve a
    /// "successful" rebuild made of STALE generated assets — the exact
    /// silent-staleness bug the hook exists to kill.
    prebuild_steps: []const prebuild.Step,
    /// Options for those steps. `fatal_on_step_failure = false` here: a
    /// failing step in watch mode must report and keep the server alive,
    /// like a failing `generate` or `zig build` already does — not exit
    /// the process out from under the serve loop.
    prebuild_opts: prebuild.Options,

    /// Re-run prebuild → generate → fixFingerprints → `zig build`. Returns
    /// true only on a clean rebuild; on any failure it prints the error
    /// (keeping the server alive) and returns false so the browser is NOT
    /// reloaded onto a broken build.
    fn rebuild(ctx_ptr: *anyopaque) bool {
        const self: *WasmRebuildCtx = @ptrCast(@alignCast(ctx_ptr));
        const a = self.allocator;

        // 0. Re-run the declared prebuild steps, ahead of generation just
        //    as the initial pipeline does. Steps that declare `.inputs` +
        //    `.outputs` are skipped while fresh, so the common watch
        //    iteration costs a few stats — and their declared `.outputs`
        //    are excluded from the watch signature (`ignore_files` at the
        //    `serveAndOpen` call below), so the run that DOES regenerate
        //    them no longer looks like a fresh edit on the next poll.
        //    A step that declares no `.outputs` runs on every rebuild by
        //    design and is not excluded from anything; if such a step
        //    also writes into the watched tree it retriggers the watcher
        //    in a loop, so declare `.outputs` for generators used under
        //    `--watch`.
        prebuild.runAll(a, self.project_dir, self.prebuild_steps, self.prebuild_opts) catch |err| {
            std.debug.print("labelle: rebuild prebuild step failed ({s})\n", .{@errorName(err)});
            return false;
        };

        // 1. Regenerate — scene/prefab/script *structure* (new files, added
        //    components) can change, not just @embedFile'd content.
        assembler_proc.generate(self.asm_bin, a, self.project_dir, self.platform_tag, self.backend_tag) catch |err| {
            std.debug.print("labelle: rebuild generate failed ({s})\n", .{@errorName(err)});
            return false;
        };
        // 2. `generate` rewrites build.zig with a placeholder fingerprint;
        //    re-fix it before building.
        runner.fixFingerprints(a, self.project_dir, self.output_dir) catch |err| {
            std.debug.print("labelle: rebuild fingerprint fix failed ({s})\n", .{@errorName(err)});
            return false;
        };
        // 3. Rebuild the WASM bundle (captured output so a compile error
        //    surfaces in the terminal without killing the serve loop).
        const res = runner.runZigWithEnv(a, self.target_dir, self.zig_args, self.zig_env) catch |err| {
            std.debug.print("labelle: rebuild could not spawn zig ({s})\n", .{@errorName(err)});
            return false;
        };
        defer a.free(res.stdout);
        defer a.free(res.stderr);
        switch (res.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("labelle: rebuild failed:\n{s}\n", .{res.stderr});
                return false;
            },
            else => {
                std.debug.print("labelle: rebuild terminated abnormally\n{s}\n", .{res.stderr});
                return false;
            },
        }
        return true;
    }
};

/// The watcher's `ignore_files` set for `wasm serve --watch`: the absolute
/// paths of every declared prebuild `.outputs` entry, anchored at
/// `project_dir`. Caller owns the list and every slice in it.
///
/// Excluding them is what stops the rebuild callback from tripping its own
/// watcher (cli#355): `watchLoop` records the signature captured BEFORE the
/// callback runs, so a hook's regeneration of `assets/out.png` otherwise
/// looked like a fresh edit on the next poll and fired a second full
/// generate/compile/reload. Same reasoning as the `.labelle/` skip.
///
/// `hooks_enabled` is the `LABELLE_NO_PREBUILD` kill switch, and the reason
/// it is a parameter rather than an assumption. With hooks off, the rebuild
/// callback writes none of these files, so the self-trigger cannot happen —
/// while excluding them anyway broke a documented use of the switch:
/// regenerating those outputs OUT OF BAND (in CI, or by hand) never reached
/// the watch signature, so the browser kept serving the previous build until
/// some unrelated watched file happened to change (cli#361 review). With
/// hooks off, the outputs are ordinary externally managed inputs and belong
/// in the watch set, so the set comes back empty.
///
/// Best-effort: a path that can't be joined is simply not excluded — that
/// costs a redundant rebuild, never a missed one.
fn collectPrebuildIgnorePaths(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    steps: []const prebuild.Step,
    hooks_enabled: bool,
) std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    if (!hooks_enabled) return out;
    for (steps) |step| {
        for (step.outputs) |rel| {
            const p = serve.watchIgnorePath(allocator, project_dir, rel) catch continue;
            out.append(allocator, p) catch {
                allocator.free(p);
                continue;
            };
        }
    }
    return out;
}

/// Resolve the `wasm export --output` value to a path the packager can
/// use. Absolute paths pass through; a relative path is anchored to the
/// project dir so `labelle wasm export ../game --output release` writes
/// under the project, matching where the build output already lives.
/// Caller owns the returned slice.
///
/// SAFETY: the export dir is wiped (`deleteTree`) on every run, so a
/// destructive `--output` — `.`, `..`, the project/cwd root, or any
/// ancestor of them — would delete the user's source tree. Such targets
/// are refused with `error.DestructiveOutputPath` instead. (The
/// complementary "non-empty dir not created by a prior export" guard
/// lives in `export.packageExport`, which owns the deletion.)
fn resolveExportOutput(allocator: std.mem.Allocator, project_dir: []const u8, output: []const u8) ![]const u8 {
    // Normalized form of `output` alone (collapses `.`/`..`; keeps a
    // relative path relative). `resolve` does NOT anchor relatives at the
    // cwd in Zig 0.16, so this is pure path math — no filesystem access,
    // which also keeps it unit-testable.
    const norm = try std.fs.path.resolve(allocator, &.{output});
    defer allocator.free(norm);

    const destructive = if (std.fs.path.isAbsolute(norm))
        // Absolute output: refuse the filesystem root (no parent to scope
        // the wipe) or the project dir / an ancestor of it when the
        // project path is itself absolute. Other absolute dirs are still
        // guarded by the non-empty-without-marker check in packageExport.
        std.fs.path.dirname(norm) == null or
            (std.fs.path.isAbsolute(project_dir) and try absTargetHitsProject(allocator, norm, project_dir))
    else
        // Relative output: refuse the project root itself (`.`) or any
        // path that escapes above it (leading `..`) — wiping either would
        // delete the project / a parent tree.
        std.mem.eql(u8, norm, ".") or escapesUpward(norm);

    if (destructive) {
        std.debug.print(
            "labelle wasm export: refusing to use '{s}' as --output\n" ++
                "  the export directory is wiped on every run, and this path is the\n" ++
                "  project directory, an ancestor of it, or the filesystem root.\n" ++
                "  choose a dedicated subdirectory, e.g. --output ./release\n",
            .{output},
        );
        return error.DestructiveOutputPath;
    }

    if (std.fs.path.isAbsolute(output)) return allocator.dupe(u8, output);
    return std.fs.path.join(allocator, &.{ project_dir, output });
}

/// True when a relative, normalized `norm` names the project root
/// itself (`.` is handled by the caller) via an upward escape — i.e. its
/// first path component is `..`. Separator-agnostic: matches both `../`
/// and `..\` so a Windows-style output is caught even if `resolve`
/// emitted the other separator.
fn escapesUpward(norm: []const u8) bool {
    if (std.mem.eql(u8, norm, "..")) return true;
    return norm.len > 2 and std.mem.eql(u8, norm[0..2], "..") and std.fs.path.isSep(norm[2]);
}

/// Path-boundary equality, case-insensitive on Windows (whose
/// filesystems are case-insensitive, so `C:\Proj` and `c:\proj` name the
/// same dir — a destructive-ancestor check must treat them as equal).
fn pathEql(a: []const u8, b: []const u8) bool {
    return if (@import("builtin").os.tag == .windows)
        std.ascii.eqlIgnoreCase(a, b)
    else
        std.mem.eql(u8, a, b);
}

/// True when the absolute, normalized output `norm` is the (absolute)
/// project dir itself or an ancestor of it.
fn absTargetHitsProject(allocator: std.mem.Allocator, norm: []const u8, project_dir: []const u8) !bool {
    const proj_abs = try std.fs.path.resolve(allocator, &.{project_dir});
    defer allocator.free(proj_abs);
    if (pathEql(norm, proj_abs)) return true;
    // `norm` is an ancestor of `proj_abs` only if it extends it at a path
    // boundary — guards against "/foo" matching "/foobar". `isSep` accepts
    // either separator so a mixed-separator input still lands correctly.
    return proj_abs.len > norm.len and
        pathEql(proj_abs[0..norm.len], norm) and
        std.fs.path.isSep(proj_abs[norm.len]);
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

/// Run the project-scoped pipeline: read project.labelle, then
/// generate -> build -> run (or the docker / wasm / ios / android
/// variant selected by `parsed_args`). Dispatch of the standalone
/// subcommands stays in cli.zig `main`; this is invoked only for the
/// project commands (generate / build / run / wasm / ios / android).
pub fn run(allocator: std.mem.Allocator, parsed_args: ParsedArgs) !void {
    const command = parsed_args.command;
    const project_dir = parsed_args.project_dir;
    const timeout_ns = parsed_args.timeout_ns;

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
        return;
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

    // Apply --platform override
    if (parsed_args.platform_override) |platform| {
        parsed.platform = platform;
    }

    // `labelle ios` always implies sokol + ios platform
    if (command == .ios_cmd) {
        parsed.platform = .ios;
        parsed.backend = .sokol;
    }

    // `labelle android` implies the android platform.
    if (command == .android_cmd) {
        parsed.platform = .android;
    }

    // `labelle bundle` (cli#359) wraps a DESKTOP exe in a macOS `.app`;
    // a project whose `.platform` says otherwise still gets its desktop
    // target built and bundled (the parser accepts no `--platform`).
    if (command == .bundle_cmd and parsed.platform != .desktop) {
        std.debug.print("labelle bundle: project platform is '{s}'; bundling the desktop target instead\n", .{@tagName(parsed.platform)});
        parsed.platform = .desktop;
    }

    // Resolve the backend for ANY android-targeting invocation —
    // `labelle android`, `labelle run --platform=android`, or
    // `labelle build --platform=android` all land here. The backend is
    // taken from the project's declared backend, honoring an
    // Android-capable choice (`sokol` or `bgfx`) and falling back to
    // sokol otherwise (#252). Keying off the resolved platform (rather
    // than the subcommand) means a `.backend = .raylib` project run with
    // `--platform=android` gets the same helpful fallback as `labelle
    // android` instead of failing later on a missing `raylib_android`
    // target dir.
    if (parsed.platform == .android) {
        const android_backend = resolveAndroidBackend(parsed.backend);
        if (android_backend != parsed.backend) {
            std.debug.print(
                "labelle: backend '{s}' can't target Android; defaulting to sokol.\n",
                .{@tagName(parsed.backend)},
            );
        }
        parsed.backend = android_backend;
    }

    // Upgrade modifies project.labelle in the project directory
    if (command == .upgrade_cmd) {
        return upgrade.cmdUpgrade(allocator, project_dir, parsed, parsed_args.extra_args[0..parsed_args.extra_count]);
    }

    // `labelle wasm serve|export --no-build` — skip the generate+build
    // pipeline entirely and serve/package the existing build output. The
    // web dir lives under the wasm target subdir (`.labelle/<backend>_wasm/`).
    if (command == .wasm_cmd and parsed_args.serve_no_build) {
        const wasm_target = try std.fmt.allocPrint(allocator, "{s}_wasm", .{@tagName(parsed.backend)});
        defer allocator.free(wasm_target);
        const web_dir = try std.fs.path.join(allocator, &.{
            project_dir, ".labelle", wasm_target, "zig-out", "web",
        });
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
        if (parsed_args.wasm_export) {
            const out_abs = try resolveExportOutput(allocator, project_dir, parsed_args.export_output);
            defer allocator.free(out_abs);
            return export_mod.packageExport(allocator, web_dir, project_web_dir, .{
                .output_dir = out_abs,
                .zip = parsed_args.export_zip,
                .platform = parsed_args.export_pkg_platform,
            });
        }
        // No watch in the `--no-build` path (the parser already rejects the
        // `--watch --no-build` combination, so `serve_watch` is false here).
        return serve.serveAndOpen(allocator, web_dir, project_web_dir, parsed_args.serve_port, !parsed_args.serve_no_open, null);
    }

    // ── Build-progress feed (cli#284) ──────────────────────────────────
    // Target subdir: .labelle/raylib_desktop/, etc. Computed up front so
    // the live status file `.labelle/<target>/.build-progress.json` has a
    // home from the first `resolve` record onward (the dir is created by
    // the reporter; the assembler generates into it later).
    const target_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ @tagName(parsed.backend), @tagName(parsed.platform) });
    defer allocator.free(target_name);
    const target_dir = try std.fs.path.join(allocator, &.{ project_dir, ".labelle", target_name });
    defer allocator.free(target_dir);

    // One event source, three access modes: NDJSON on stdout
    // (`--progress=json`), the atomically-rewritten status file (all
    // modes; read by `labelle status` + studio), and a live indicator on
    // stderr (default human mode — a TTY-only spinner while `zig build`
    // runs, "still working" heartbeat lines while the assembler child
    // owns stderr during resolve/generate, cli#321). Enabled for the
    // commands that run the shared build pipeline; `labelle generate` and
    // the ios/android subcommands (which own their own build flows) stay
    // report-free. A
    // reporter that fails to initialize downgrades to the pre-#284
    // behavior instead of blocking the build.
    var reporter_storage: progress.Reporter = undefined;
    const reporter: ?*progress.Reporter = blk: {
        if (command != .build and command != .run and command != .wasm_cmd and command != .bundle_cmd) break :blk null;
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

    // Validate version compatibility
    compatibility.validateCompatibility(parsed);

    // Pre-build hooks (#355). Runs on `generate` / `build` / `run` (and
    // the ios/android/wasm flows, which all generate) — the first thing
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

    // Issue #217: the CLI is a thin driver over the standalone
    // labelle-assembler binary. Resolve it once here (LABELLE_ASSEMBLER
    // env var > assembler_version in project.labelle > auto-downloaded
    // default) and reuse the located binary for both the cache-populate
    // step and code generation below.
    const asm_bin = try assembler_proc.resolve(allocator, project_dir, "generate");
    defer asm_bin.deinit(allocator);
    std.debug.print("  using assembler: {s}\n", .{asm_bin.path});

    // ASTC build-time conversion (#340): when this platform ships ASTC atlases
    // (`asset_compression`), run `labelle astc` first so the `<name>.astc`
    // siblings exist for the assembler's catalog `.png → .astc` swap. Runs
    // before the assembler steps (it only needs project.labelle + the PNGs +
    // astcenc). Non-fatal — on any failure the assembler finds no sibling and
    // falls back to the source PNG, so the build still succeeds.
    //
    // EXCEPT a misconfiguration. `ConflictingAstcBlocks` means two atlases
    // compile to one `.astc` with disagreeing block pins; falling back would
    // hand BOTH of them whatever `.astc` is on disk — including a STALE one
    // from an earlier build, which is worse than no atlas because it looks
    // like it worked. So a config error stops the build, while a conversion
    // failure still degrades to PNG.
    if (parsed.asset_compression.formatFor(parsed.platform) == .astc) {
        astc_cmd.cmdAstc(allocator, &.{project_dir}) catch |err| switch (err) {
            error.ConflictingAstcBlocks => progress.fatalExit(
                1,
                "conflicting .astc_block pins compile to one .astc — see the error above",
            ),
            else => std.debug.print(
                "labelle: ASTC conversion failed ({s}); falling back to PNG atlases\n",
                .{@errorName(err)},
            ),
        };
    }

    // Ensure the package cache is populated. The assembler's `generate`
    // subcommand assumes a populated cache (it does not fetch packages
    // itself), so delegate `install --project-root` to the binary first.
    // This replaces the CLI's former in-process `cache.ensureCache`,
    // which depended on the assembler's `generator` module.
    try asm_bin.run(allocator, "install", &.{ "--project-root", project_dir });

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
    std.debug.print("  backend: {s}  platform: {s}  ecs: {s}  gui: {s}  window: {d}x{d}\n", .{
        @tagName(parsed.backend), @tagName(parsed.platform), @tagName(parsed.ecs), gui_label, parsed.width, parsed.height,
    });

    // Scenes and prefabs are always embedded via @embedFile
    const effective_optimize = parsed_args.optimize_override orelse
        if (parsed.platform == .wasm) @as(?[]const u8, "ReleaseSafe") else null;

    // Opt-in PNG → LRGBA pre-bake. Runs before the assembler so its
    // @embedFile path picks up the fresh `.rgba` files. Skipped unless
    // `--bake` is passed: raw RGBA expands heavily-transparent atlases
    // by 100×+ (a 200 KB PNG can become 64 MB), so default-off keeps
    // APK size sane. Use for projects whose atlases are nearly opaque
    // and PNG decode dominates cold start.
    if (parsed_args.bake) {
        bake_mod.run(allocator, project_dir, parsed.resources) catch |err| {
            std.debug.print("labelle: bake failed: {s}\n", .{@errorName(err)});
            return err;
        };
    }

    // Issue #217 phase 2: delegate code generation to the standalone
    // labelle-assembler binary via the shared subprocess harness, instead
    // of calling an in-process generator. The binary was located above
    // (`asm_bin`) and already used for the `install` cache-populate step.
    //
    // `build` / `run` are not assembler subcommands: the subsequent
    // `zig build` invocation and binary launch stay CLI-side (see below).
    // The CLI owns docker orchestration, the WASM serve loop, the
    // iOS/Android deploy paths and `--timeout` — generation is the only
    // step the assembler binary delegates.
    // `parsed_args.scene_override` is intentionally NOT forwarded to the
    // assembler. PR #243 removed the CLI's `cfg.initial_prefab` rewrite for
    // exactly this reason; the assembler's own `--scene` handling does the
    // same rewrite, which bypasses any loading-scene gate the project
    // declares. The override is delivered at runtime via the
    // `LABELLE_SCENE` env var injected at the spawn site (~line 990).
    try assembler_proc.generate(
        asm_bin,
        allocator,
        project_dir,
        @tagName(parsed.platform),
        @tagName(parsed.backend),
    );

    // (`target_name`/`target_dir` — .labelle/raylib_desktop/, etc. — are
    // computed up front, before the progress reporter init; see cli#284.)

    // fixFingerprints runs `zig build` locally per emitted target dir to
    // discover the correct hash. With assembler >=0.14.0 there are two
    // (`<backend>_<platform>/` and `tests/`); patching only the exe dir
    // would leave `tests/` with a placeholder fingerprint and break
    // `labelle test`.
    //
    // For docker builds we skip the exe target — the host Zig toolchain
    // may not have the native libs the chosen backend needs (that's why
    // we're routing through docker in the first place). The tests target
    // is the exception: it uses the null backend (no native libs), so
    // host Zig can build it even when --docker is set, and skipping
    // would leave `labelle test` broken on the host after `labelle build
    // --docker`. Patch `tests/` directly when present.
    if (!parsed_args.docker) {
        try runner.fixFingerprints(allocator, project_dir, output_dir);
    } else {
        const tests_dir = try std.fs.path.join(allocator, &.{ output_dir, "tests" });
        defer allocator.free(tests_dir);
        const tests_build_zig = try std.fs.path.join(allocator, &.{ tests_dir, "build.zig" });
        defer allocator.free(tests_build_zig);
        if (std.Io.Dir.cwd().access(config.globalIo(), tests_build_zig, .{})) |_| {
            try runner.fixFingerprint(allocator, project_dir, tests_dir);
        } else |_| {}
    }
    try lockfile.writeLockFile(allocator, project_dir, parsed);
    std.debug.print("  generated .labelle/{s}/\n", .{target_name});

    // For a wasm build: activate the emsdk checkout Zig just fetched into the
    // project-local `zig-pkg/` (during the fingerprint pass above) so the emcc
    // link step finds `upstream/emscripten/emcc`. Without this a fresh
    // `labelle build --platform wasm` — or `generate --platform wasm` followed
    // by a manual `zig build` — dies at the emcc step because the fetched emsdk
    // package is NOT activated: the remaining half of labelle-assembler#492 (the
    // docker path already does this in-container). Run it BEFORE the `generate`
    // early-return so the generate-then-build path is covered too. Best-effort +
    // idempotent; on failure the build still surfaces the clear #492 guidance.
    // The PINNED version keeps activation deterministic.
    if (!parsed_args.docker and parsed.platform == .wasm) {
        // Python preflight (cli#291): emsdk activation and emcc itself (an
        // `env python3` script) both need a working interpreter. Fail fast
        // with the exact fix instead of dying deep inside emsdk activation
        // with an unrelated-looking error. `autoWireEnv` first: it puts a
        // previously-provisioned managed Python on this process's PATH (and
        // wires the TLS bundle on Windows), which is what makes the
        // availability probe — and the activation below — see it.
        python_provision.autoWireEnv(allocator);
        if (!python_provision.isAvailable(allocator)) {
            std.debug.print("labelle: wasm builds need Python 3 (emsdk activation + emcc) and none was found.\n" ++
                "  fix: labelle install python   (managed, ~25 MB into ~/.labelle/python)\n" ++
                "  or install Python 3 yourself and ensure `python3` is on PATH.\n", .{});
            return error.BuildFailed;
        }
        const resolved_emsdk = try emsdk_toolchain.resolveRequiredVersion(allocator, project_dir);
        defer allocator.free(resolved_emsdk.version);
        emsdk_activate.activateFetchedEmsdk(allocator, target_dir, resolved_emsdk.version);
    }

    if (command == .generate) return;

    // `labelle ios` subcommand — handles its own build/xcode/run
    if (command == .ios_cmd) {
        return ios.handleIos(allocator, parsed_args.extra_args[0..parsed_args.extra_count], parsed, target_dir);
    }

    // `labelle android` subcommand — handles its own build/run
    if (command == .android_cmd) {
        return android.handleAndroid(allocator, parsed_args.extra_args[0..parsed_args.extra_count], parsed, project_dir, target_dir);
    }

    // Warn if --target is used without --docker (it has no effect otherwise)
    if (parsed_args.docker_target != null and !parsed_args.docker) {
        std.debug.print("labelle: warning: --target has no effect without --docker\n", .{});
    }

    // Build — default to ReleaseSafe for WASM (Debug exceeds browser local variable limits)
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
    // For a wasm build, ALSO layer the managed emsdk's EMSDK/EM_CONFIG/PATH
    // wiring on top when one is already provisioned (labelle-cli#283) — an
    // escape hatch for builds/backends that resolve `emcc` via PATH/env rather
    // than the fetched package activated just above.
    var zig_env_storage: ?std.process.Environ.Map = if (parsed_args.docker)
        null
    else if (parsed.platform == .wasm)
        try runner.buildWasmEnv(allocator, project_dir)
    else
        try runner.buildZigEnv(allocator, &.{});
    defer if (zig_env_storage) |*m| m.deinit();
    const zig_env_ptr: ?*const std.process.Environ.Map = if (zig_env_storage) |*m| m else null;

    var zig_args: std.ArrayList([]const u8) = .empty;
    defer zig_args.deinit(allocator);
    try zig_args.append(allocator, managed_zig orelse "zig");
    try zig_args.append(allocator, "build");
    if (optimize_flag) |flag| try zig_args.append(allocator, flag);

    if (parsed_args.docker) {
        // Docker builds get phase-level progress only: the toolchain (and
        // its progress pipe) lives inside the container.
        if (reporter) |r| r.beginPhase(.compile, "docker build");
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
        r.beginPhase(.compile, "zig build");
        const build_code = try runner.runZigInheritProgress(allocator, target_dir, zig_args.items, zig_env_ptr, r);
        // Wipe the spinner line before anything else prints on it.
        r.clearSpinner();
        if (build_code != 0) {
            r.finishFailed(build_code, "zig build failed");
            std.debug.print("labelle: build failed (exit {d})\n", .{build_code});
            return error.BuildFailed;
        }
    } else {
        std.debug.print("labelle: building...\n", .{});
        const build_result = try runner.runZigWithEnv(allocator, target_dir, zig_args.items, zig_env_ptr);
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

    // `labelle bundle` (cli#359): the exe is built; wrap it. Packaging
    // runs AFTER the compile, so keep the progress feed open across it
    // (a `run` phase, as `wasm export` does) and only mark `done` once
    // the `.app` is on disk — a `--progress=json` consumer must not see
    // `done` before the artifact exists.
    if (command == .bundle_cmd) {
        if (reporter) |r| {
            r.beginPhase(.run, "packaging macOS bundle");
            r.clearSpinner();
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
        if (reporter) |r| r.finishDone(0);
        return;
    }

    if (command == .build) {
        // Linux `.desktop` entry + icon (cli#359): after a desktop build,
        // write `zig-out/<exe>.desktop` + `zig-out/<exe>.png` beside `bin/`
        // — automatically on a Linux host, or anywhere with
        // `--linux-desktop`. Skipped under `--docker`: that exe was built
        // for the container's target and the entry's absolute paths would
        // describe this host, not the one that will run it. `run` is
        // deliberately left alone — the entry is a packaging artifact.
        if (!parsed_args.docker and parsed.platform == .desktop and linux_desktop.shouldEmit(parsed_args.linux_desktop)) {
            const entry_path = try linux_desktop.createFromBuild(allocator, project_dir, target_dir, parsed);
            allocator.free(entry_path);
        }
        // `labelle build --platform=android` builds the shared library
        // above (the generic `zig build` produces `zig-out/lib/libgame.so`)
        // but, unlike `labelle android build`, used to stop there and leave
        // a bare `.so`. Package it into a signed APK so the artifact is
        // installable — backend-agnostic, so it covers sokol and bgfx alike.
        if (parsed.platform == .android) {
            const apk_path = try android.packageApk(allocator, project_dir, target_dir, parsed, false, .{});
            defer allocator.free(apk_path);
            std.debug.print("labelle: APK ready: {s}\n", .{apk_path});
        }
        if (reporter) |r| r.finishDone(0);
        return;
    }

    // Run
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
                r.beginPhase(.run, "packaging wasm export");
                r.clearSpinner();
            }
            const out_abs = try resolveExportOutput(allocator, project_dir, parsed_args.export_output);
            defer allocator.free(out_abs);
            try export_mod.packageExport(allocator, web_dir, project_web_dir, .{
                .output_dir = out_abs,
                .zip = parsed_args.export_zip,
                .platform = parsed_args.export_pkg_platform,
            });
            if (reporter) |r| r.finishDone(0);
        } else {
            // WASM serve: the loop is interactive (runs until Ctrl+C), so
            // the terminal `done` record lands before the serve loop.
            if (reporter) |r| r.finishDone(0);
            if (parsed_args.serve_watch) {
                // `--watch` (cli#208): hand the serve loop a rebuild callback
                // that re-runs the same generate→fingerprint→zig-build steps
                // this pipeline just did. The context borrows locals that stay
                // alive because `serveAndOpen` blocks until Ctrl+C.
                var rebuild_ctx = WasmRebuildCtx{
                    .allocator = allocator,
                    .asm_bin = asm_bin,
                    .project_dir = project_dir,
                    .platform_tag = @tagName(parsed.platform),
                    .backend_tag = @tagName(parsed.backend),
                    .output_dir = output_dir,
                    .target_dir = target_dir,
                    .zig_args = zig_args.items,
                    .zig_env = zig_env_ptr,
                    .prebuild_steps = parsed.prebuild,
                    .prebuild_opts = .{
                        .route_stdout_to_stderr = parsed_args.progress_mode == .json,
                        // Keep the serve loop alive on a failing step.
                        .fatal_on_step_failure = false,
                    },
                };
                // The hooks' declared `.outputs` are excluded from the watch
                // signature so the rebuild callback can't trip its own
                // watcher — but ONLY while the hooks actually run, so the
                // kill switch doesn't hide out-of-band regeneration from the
                // watcher. See `collectPrebuildIgnorePaths`.
                var ignore_files = collectPrebuildIgnorePaths(
                    allocator,
                    project_dir,
                    parsed.prebuild,
                    !prebuild.skipRequested(allocator),
                );
                defer {
                    for (ignore_files.items) |f| allocator.free(f);
                    ignore_files.deinit(allocator);
                }

                try serve.serveAndOpen(allocator, web_dir, project_web_dir, parsed_args.serve_port, !parsed_args.serve_no_open, .{
                    .watch_dir = project_dir,
                    .rebuild_fn = WasmRebuildCtx.rebuild,
                    .rebuild_ctx = &rebuild_ctx,
                    .ignore_files = ignore_files.items,
                });
            } else {
                try serve.serveAndOpen(allocator, web_dir, project_web_dir, parsed_args.serve_port, !parsed_args.serve_no_open, null);
            }
        }
    } else if (parsed.platform == .ios) {
        // iOS: deploy to simulator
        if (reporter) |r| r.beginPhase(.run, "deploying to iOS Simulator");
        std.debug.print("labelle: deploying to iOS Simulator...\n", .{});
        try ios.deployToSimulator(allocator, target_dir, parsed);
        if (reporter) |r| r.finishDone(0);
    } else if (parsed.platform == .android) {
        // Android: deploy to device/emulator
        if (reporter) |r| r.beginPhase(.run, "deploying to Android");
        std.debug.print("labelle: deploying to Android...\n", .{});
        try android.deployToDevice(allocator, project_dir, target_dir, parsed, false, .{});
        if (reporter) |r| r.finishDone(0);
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
            if (parsed_args.scene_override) |scene| {
                try extras.append(allocator, .{ .key = "LABELLE_SCENE", .value = scene });
            }
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
            if (parsed_args.profile) {
                try extras.append(allocator, .{ .key = "LABELLE_PROFILE", .value = "1" });
            }
            var sec_buf: [32]u8 = undefined;
            if (parsed_args.screenshot_path) |path| {
                try extras.append(allocator, .{ .key = "LABELLE_SCREENSHOT_PATH", .value = path });
                if (parsed_args.screenshot_after_ns) |ns| {
                    const sec_f64 = @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_s);
                    const sec_str = try std.fmt.bufPrint(&sec_buf, "{d:.3}", .{sec_f64});
                    try extras.append(allocator, .{ .key = "LABELLE_SCREENSHOT_AFTER_SEC", .value = sec_str });
                }
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
            // Cross-compiled binaries can't be run on the host
            if (parsed_args.docker_target) |t| {
                std.debug.print("labelle: cannot run cross-compiled binary (target: {s})\n", .{t});
                std.debug.print("  binary is at: {s}/zig-out/bin/\n", .{target_dir});
                if (reporter) |r| r.finishDone(0); // build succeeded; run skipped
                return;
            }
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
            try appendRunForwardedArgs(&run_args, allocator, &parsed_args);
            if (reporter) |r| r.beginPhase(.run, exe_name);
            noteRunSharesStdout(reporter);
            const run_result = try runner.runZigInheritWithEnv(allocator, project_dir, run_args.items, timeout_ns, env_map_ptr);
            if (run_result != 0) {
                std.debug.print("\nlabelle: process exited with code {d}\n", .{run_result});
            }
            if (screenshot_probe) |p| p.report(allocator);
            // The game ran: the pipeline is `done` even on a nonzero game
            // exit — the code is carried in the terminal record.
            if (reporter) |r| r.finishDone(run_result);
        } else {
            // Build, then run the game BINARY DIRECTLY rather than via
            // `zig build run`. `zig build run` launches the game in its own
            // child process group, which ESCAPES the --timeout kill: the
            // watchdog signals labelle's direct child (the `zig build`
            // process), the game survives in its separate group, gets
            // reparented to init, and orphans. Run as labelle's own child and
            // the game stays in the process group the watchdog signals, so
            // SIGTERM→SIGKILL actually reaches it. Mirrors the --docker path.
            //
            // Build with no timeout (only the run is time-limited); keep the
            // game's cwd at `target_dir` (a target_dir-relative argv[0]) so
            // saves land exactly where `zig build run` put them.
            // The main compile already ran under the `compile`/`link`
            // phases above; this re-build is a warm-cache no-op, so it
            // stays in the compile/link phase — `run` begins when the game
            // binary is about to spawn.
            const build_result = try runner.runZigInheritWithEnv(allocator, target_dir, zig_args.items, null, env_map_ptr);
            if (build_result != 0) {
                if (reporter) |r| r.finishFailed(build_result, "zig build failed");
                std.debug.print("\nlabelle: build failed (exit {d})\n", .{build_result});
                return;
            }
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
            try appendRunForwardedArgs(&run_args, allocator, &parsed_args);
            if (reporter) |r| r.beginPhase(.run, exe_basename);
            noteRunSharesStdout(reporter);
            const run_result = try runner.runZigInheritWithEnv(allocator, target_dir, run_args.items, timeout_ns, env_map_ptr);
            if (run_result != 0) {
                std.debug.print("\nlabelle: process exited with code {d}\n", .{run_result});
            }
            if (screenshot_probe) |p| p.report(allocator);
            // The game ran: the pipeline is `done` even on a nonzero game
            // exit — the code is carried in the terminal record.
            if (reporter) |r| r.finishDone(run_result);
        }
    }
}

/// Extensions a backend may append to the requested screenshot path instead of
/// honoring it verbatim. bgfx writes TGA and appends `.tga` to whatever it is
/// given, so `--screenshot=shot.png` lands at `shot.png.tga` (labelle-bgfx#57).
///
/// The append itself lives in the backend, out of this repo's reach — so once
/// the run is over `ScreenshotProbe.report` finishes the job here instead,
/// re-encoding the capture into the requested format and dropping the
/// doubly-named intermediate (cli#356, `screenshot_format.zig`). Every entry
/// must stay decodable by the vendored stb build (`stb_image_impl.c`).
const screenshot_suffixes = [_][]const u8{ ".tga", ".png", ".bmp" };

/// Pre-run fingerprint of one candidate path. Existence alone is not enough to
/// claim "this run wrote it" — a file left by an EARLIER run would be reported
/// as a fresh capture even when the current one failed, and a stale file at the
/// exact requested path would mask a newly written suffixed one. So compare
/// size+mtime across the run and treat only a created-or-changed file as ours.
const FileStamp = struct {
    existed: bool = false,
    size: u64 = 0,
    mtime_ns: i128 = 0,

    fn take(path: []const u8) FileStamp {
        const st = std.Io.Dir.cwd().statFile(config.globalIo(), path, .{}) catch return .{};
        return .{ .existed = true, .size = st.size, .mtime_ns = st.mtime.nanoseconds };
    }

    /// True when `after` represents a file this run created or rewrote.
    fn changed(before: FileStamp, after: FileStamp) bool {
        if (!after.existed) return false;
        if (!before.existed) return true;
        return before.size != after.size or before.mtime_ns != after.mtime_ns;
    }
};

/// Where a screenshot might land, fingerprinted before the game runs.
///
/// The CLI only forwards `LABELLE_SCREENSHOT_PATH`; the backend owns the real
/// filename and the CLI never verified the result, so a capture written to a
/// different path read as "no screenshot was produced" — the misreading this
/// exists to prevent.
///
/// `run_cwd` is the directory the game runs in, which is NOT the user's cwd:
/// normally `.labelle/<target>/` (so saves land where `zig build run` put
/// them), but `project_dir` under `--docker`. A relative `--screenshot=shot.png`
/// is resolved by the game against that cwd, so that is where to look and what
/// to print — an unqualified relative path would send the user to the wrong
/// directory.
const ScreenshotProbe = struct {
    /// Path as the user typed it.
    requested: []const u8,
    /// `requested` resolved against the game's cwd (owned).
    resolved: []const u8,
    /// Index 0 is `resolved`; the rest follow `screenshot_suffixes`.
    before: [1 + screenshot_suffixes.len]FileStamp = @splat(.{}),

    fn init(allocator: std.mem.Allocator, requested: []const u8, run_cwd: []const u8) ?ScreenshotProbe {
        const resolved: []const u8 = if (std.fs.path.isAbsolute(requested))
            allocator.dupe(u8, requested) catch return null
        else
            std.fs.path.join(allocator, &.{ run_cwd, requested }) catch return null;

        var probe: ScreenshotProbe = .{ .requested = requested, .resolved = resolved };
        for (0..probe.before.len) |i| {
            const path = probe.candidatePath(allocator, i) orelse continue;
            defer allocator.free(path);
            probe.before[i] = FileStamp.take(path);
        }
        return probe;
    }

    fn deinit(self: ScreenshotProbe, allocator: std.mem.Allocator) void {
        allocator.free(self.resolved);
    }

    /// Candidate `i`: 0 is the resolved path itself, then one per suffix.
    fn candidatePath(self: ScreenshotProbe, allocator: std.mem.Allocator, i: usize) ?[]u8 {
        if (i == 0) return allocator.dupe(u8, self.resolved) catch null;
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ self.resolved, screenshot_suffixes[i - 1] }) catch null;
    }

    /// Report where the screenshot ACTUALLY landed, after the game has exited.
    fn report(self: ScreenshotProbe, allocator: std.mem.Allocator) void {
        var stale_exact = false;
        for (0..self.before.len) |i| {
            const path = self.candidatePath(allocator, i) orelse continue;
            defer allocator.free(path);
            const after = FileStamp.take(path);
            if (!FileStamp.changed(self.before[i], after)) {
                // Pre-existing and untouched. Worth calling out only for the
                // exact path, where its presence is actively misleading.
                if (i == 0 and after.existed) stale_exact = true;
                continue;
            }
            self.reconcile(allocator, path);
            return;
        }

        std.debug.print("labelle: warning: no screenshot was written (looked for '{s}'", .{self.resolved});
        for (screenshot_suffixes) |suffix| std.debug.print(", '{s}{s}'", .{ self.resolved, suffix });
        std.debug.print(")\n", .{});
        if (stale_exact) {
            std.debug.print("  note: '{s}' exists but is unchanged — it is left over from an earlier run, not this one\n", .{self.resolved});
        }
        std.debug.print("  hint: capture needs a native surface on some backends — a headless bgfx device has no backbuffer to read back\n\n", .{});
    }

    /// The capture landed at `written`. Put it on the requested path when
    /// the CLI can (cli#356) — a same-format move, or a decode/re-encode
    /// through the vendored stb — then print where the file REALLY is.
    ///
    /// Every branch prints exactly one `screenshot written to` line naming
    /// the path that now holds the capture, so the line stays the
    /// authoritative one a script can parse.
    fn reconcile(self: ScreenshotProbe, allocator: std.mem.Allocator, written: []const u8) void {
        const plan = screenshot_format.plan(self.resolved, written);
        switch (plan) {
            .honored => std.debug.print("labelle: screenshot written to '{s}'\n", .{written}),
            .keep => {
                std.debug.print("labelle: screenshot written to '{s}'\n", .{written});
                if (screenshot_format.formatFromPath(self.resolved) == null) {
                    std.debug.print("  note: the backend appended its own extension — '{s}' names no image format, so the capture was left as written\n", .{self.resolved});
                } else {
                    std.debug.print("  note: the backend wrote a format this CLI cannot decode — the requested path '{s}' was not written\n", .{self.resolved});
                }
            },
            .move, .transcode => {
                screenshot_format.apply(allocator, plan, self.resolved, written) catch |err| {
                    // The capture still exists where the backend put it, so
                    // report THAT path — the old pre-#356 behaviour, which is
                    // the honest fallback when the conversion cannot happen.
                    std.debug.print("labelle: screenshot written to '{s}'\n", .{written});
                    std.debug.print("  note: the backend did not honor '{s}' and the CLI could not rewrite it ({s})\n", .{ self.resolved, @errorName(err) });
                    return;
                };
                std.debug.print("labelle: screenshot written to '{s}'\n", .{self.resolved});
                switch (plan) {
                    .move => std.debug.print("  note: the backend wrote '{s}'; moved onto the requested path\n", .{written}),
                    .transcode => |t| std.debug.print("  note: the backend wrote {s} to '{s}'; re-encoded as {s} at the requested path\n", .{ t.from.label(), written, t.to.label() }),
                    else => unreachable,
                }
            },
        }
    }
};

/// The post-run screenshot report end to end (cli#356): a backend that
/// appended its own extension is reconciled onto the requested path.
///
/// Drives the REAL `ScreenshotProbe` — pre-run fingerprint, suffix scan,
/// change detection, reconcile — rather than `screenshot_format` alone, so
/// the wiring between them is covered too. `report` prints to stderr, so
/// the `labelle: screenshot written to ...` lines in the test log are the
/// actual user-facing output.
pub const ScreenshotProbeSpec = struct {
    /// `ScreenshotProbe` resolves relative paths against the game's cwd and
    /// then works from the process cwd, and `std.testing.tmpDir` creates its
    /// directory under a cwd-relative `.zig-cache/tmp/`, so a cwd-relative
    /// `run_cwd` addresses exactly the files the tmp dir holds.
    fn runCwd(allocator: std.mem.Allocator, tmp: std.testing.TmpDir) ![]u8 {
        return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    }

    test "a .png request the backend answered with .png.tga lands as a PNG" {
        const a = std.testing.allocator;
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const run_cwd = try runCwd(a, tmp);
        defer a.free(run_cwd);

        // Fingerprint BEFORE the "run", exactly as the pipeline does.
        const probe = ScreenshotProbe.init(a, "shot.png", run_cwd).?;
        defer probe.deinit(a);

        // The "backend" writes TGA under the doubly-wrong name.
        try screenshot_format.writeTestFixture(a, tmp.dir, "shot.png.tga", .tga);

        probe.report(a);

        const out = try tmp.dir.readFileAlloc(io, "shot.png", a, .unlimited);
        defer a.free(out);
        try std.testing.expect(std.mem.startsWith(u8, out, "\x89PNG\r\n\x1a\n"));
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "shot.png.tga", .{}));
    }

    test "a capture left over from an earlier run is not reconciled" {
        const a = std.testing.allocator;
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const run_cwd = try runCwd(a, tmp);
        defer a.free(run_cwd);

        // Stale file exists BEFORE the probe fingerprints it, and the "run"
        // writes nothing. Touching it would turn a failed capture into a
        // report of a screenshot this run never took.
        try screenshot_format.writeTestFixture(a, tmp.dir, "shot.png.tga", .tga);
        const probe = ScreenshotProbe.init(a, "shot.png", run_cwd).?;
        defer probe.deinit(a);

        probe.report(a);

        _ = try tmp.dir.statFile(io, "shot.png.tga", .{});
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "shot.png", .{}));
    }

    test "an extension-less request is left where the backend put it" {
        const a = std.testing.allocator;
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const run_cwd = try runCwd(a, tmp);
        defer a.free(run_cwd);

        const probe = ScreenshotProbe.init(a, "shot", run_cwd).?;
        defer probe.deinit(a);

        try screenshot_format.writeTestFixture(a, tmp.dir, "shot.tga", .tga);

        probe.report(a);

        // Nothing was asked for, so `shot.tga` is the better name of the two.
        _ = try tmp.dir.statFile(io, "shot.tga", .{});
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "shot", .{}));
    }
};

pub const CollectPrebuildIgnorePathsSpec = struct {
    const steps: []const prebuild.Step = &.{
        .{ .run = &.{ "python3", "tools/gen.py" }, .outputs = &.{ "assets/out.png", "src/table.zig" } },
        .{ .run = &.{"./tools/nothing.sh"} }, // declares no outputs
    };

    fn free(a: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
        for (list.items) |f| a.free(f);
        list.deinit(a);
    }

    pub const hooks_enabled = struct {
        test "every declared output is excluded from the watch signature" {
            const a = std.testing.allocator;
            var got = collectPrebuildIgnorePaths(a, "/proj", steps, true);
            defer free(a, &got);

            try std.testing.expectEqual(@as(usize, 2), got.items.len);
            // Build the expectation with the SAME resolver the collector
            // uses. Re-implementing the join here (even via `std.fs.path.join`)
            // is not host-portable: `join` inserts the native separator
            // between its arguments but leaves the '/' inside a relative
            // path alone, so on Windows it yields `/proj\assets/out.png`
            // while `watchIgnorePath` normalises to `/proj\assets\out.png`.
            // This spec's subject is WHICH outputs are excluded, not how a
            // path is spelled — that belongs to `watchIgnorePath`'s own tests.
            const png = try serve.watchIgnorePath(a, "/proj", "assets/out.png");
            defer a.free(png);
            try std.testing.expectEqualStrings(png, got.items[0]);
        }

        test "a step that declares no outputs contributes nothing" {
            const a = std.testing.allocator;
            var got = collectPrebuildIgnorePaths(a, "/proj", steps[1..], true);
            defer free(a, &got);
            try std.testing.expectEqual(@as(usize, 0), got.items.len);
        }
    };

    // cli#361 review: with `LABELLE_NO_PREBUILD=1` the rebuild callback never
    // writes these files, so excluding them only hid an out-of-band
    // regeneration — a documented use of the kill switch — from the watcher,
    // leaving the browser on a stale build.
    pub const hooks_disabled = struct {
        test "the kill switch leaves declared outputs in the watch set" {
            const a = std.testing.allocator;
            var got = collectPrebuildIgnorePaths(a, "/proj", steps, false);
            defer free(a, &got);
            try std.testing.expectEqual(@as(usize, 0), got.items.len);
        }
    };
};

pub const ResolveExportOutputSpec = struct {
    // The export dir is wiped on every run, so a destructive `--output`
    // must be refused before it can delete the user's source tree.
    pub const rejects_destructive = struct {
        test "--output . (the project dir) is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "."),
            );
        }

        test "--output .. (an ancestor) is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", ".."),
            );
        }

        test "--output ../.. (a higher ancestor) is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "../.."),
            );
        }

        test "--output / (filesystem root) is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "/"),
            );
        }

        test "an absolute --output equal to the project dir is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "/proj/root"),
            );
        }

        test "an absolute --output that is an ancestor of the project is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "/proj"),
            );
        }

        test "foo/../.. collapsing to an escape is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "foo/../.."),
            );
        }
    };

    pub const accepts_dedicated = struct {
        test "a dedicated subdir under the project is accepted" {
            const a = std.testing.allocator;
            const out = try resolveExportOutput(a, "/proj/root", "release");
            defer a.free(out);
            // Compare against `join` rather than a hardcoded "/" so the
            // assertion holds on Windows (where join uses '\\').
            const want = try std.fs.path.join(a, &.{ "/proj/root", "release" });
            defer a.free(want);
            try std.testing.expectEqualStrings(want, out);
        }

        test "a nested dedicated subdir is accepted" {
            const a = std.testing.allocator;
            const out = try resolveExportOutput(a, "/proj/root", "dist/web");
            defer a.free(out);
            const want = try std.fs.path.join(a, &.{ "/proj/root", "dist/web" });
            defer a.free(want);
            try std.testing.expectEqualStrings(want, out);
        }

        test "an unrelated absolute --output is accepted verbatim" {
            // "/tmp/..." is absolute on POSIX and "rooted" (absolute) on
            // Windows, so it returns verbatim on both.
            const out = try resolveExportOutput(std.testing.allocator, "/proj/root", "/tmp/exports/game");
            defer std.testing.allocator.free(out);
            try std.testing.expectEqualStrings("/tmp/exports/game", out);
        }
    };

    // Windows treats both '/' and '\\' as separators and its filesystem is
    // case-insensitive. These run only on Windows CI (skipped elsewhere)
    // so the directory-wiping guard is actually exercised for those shapes
    // — a hardcoded '/' comparison here would wrongly allow a destructive
    // backslash/drive-letter `--output`.
    pub const windows_separators = struct {
        test "upward escapes via '\\' or mixed separators are rejected" {
            if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
            const a = std.testing.allocator;
            for ([_][]const u8{ "..\\secret", "../secret", "foo\\..\\..", "foo/..\\.." }) |esc| {
                try std.testing.expectError(
                    error.DestructiveOutputPath,
                    resolveExportOutput(a, "C:\\proj\\root", esc),
                );
            }
        }

        test "a case-differing absolute ancestor is rejected" {
            if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
            const a = std.testing.allocator;
            // Same directory on Windows (case-insensitive) — must be
            // treated as a destructive ancestor, not wrongly accepted.
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(a, "C:\\Proj\\Root", "c:\\proj"),
            );
        }

        test "a dedicated backslash subdir is accepted" {
            if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
            const a = std.testing.allocator;
            const out = try resolveExportOutput(a, "C:\\proj\\root", "release");
            defer a.free(out);
            const want = try std.fs.path.join(a, &.{ "C:\\proj\\root", "release" });
            defer a.free(want);
            try std.testing.expectEqualStrings(want, out);
        }
    };
};
