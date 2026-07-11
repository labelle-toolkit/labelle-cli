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
const args_mod = @import("args.zig");
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

    /// Re-run generate → fixFingerprints → `zig build`. Returns true only
    /// on a clean rebuild; on any failure it prints the error (keeping the
    /// server alive) and returns false so the browser is NOT reloaded onto
    /// a broken build.
    fn rebuild(ctx_ptr: *anyopaque) bool {
        const self: *WasmRebuildCtx = @ptrCast(@alignCast(ctx_ptr));
        const a = self.allocator;

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
    // modes; read by `labelle status` + studio), and a spinner on TTY
    // stderr (default human mode). Enabled for the commands that run the
    // shared build pipeline; `labelle generate` and the ios/android
    // subcommands (which own their own build flows) stay report-free. A
    // reporter that fails to initialize downgrades to the pre-#284
    // behavior instead of blocking the build.
    var reporter_storage: progress.Reporter = undefined;
    const reporter: ?*progress.Reporter = blk: {
        if (command != .build and command != .run and command != .wasm_cmd) break :blk null;
        reporter_storage = progress.Reporter.init(allocator, config.globalIo(), parsed_args.progress_mode, target_dir) catch break :blk null;
        break :blk &reporter_storage;
    };
    defer if (reporter) |r| r.deinit();
    // Any error path from here on marks the status file `failed`, so an
    // out-of-band reader never sees a live phase for a dead build.
    // (Pipeline code that terminates via process-exit instead of an error
    // return goes through `progress.fatalExit`, which does the same.)
    errdefer if (reporter) |r| r.failIfActive(1);
    if (reporter) |r| {
        // Registers the fatalExit hook + starts the keepalive ticker that
        // refreshes elapsed/updated timestamps while child processes own
        // the foreground (assembler, zig, game).
        r.activate();
        r.beginPhase(.resolve, "resolving toolchain + packages");
    }

    // Validate version compatibility
    compatibility.validateCompatibility(parsed);

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
    if (parsed.asset_compression.formatFor(parsed.platform) == .astc) {
        astc_cmd.cmdAstc(allocator, &.{project_dir}) catch |err| {
            std.debug.print("labelle: ASTC conversion failed ({s}); falling back to PNG atlases\n", .{@errorName(err)});
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
        return android.handleAndroid(allocator, parsed_args.extra_args[0..parsed_args.extra_count], parsed, target_dir);
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

    if (command == .build) {
        // `labelle build --platform=android` builds the shared library
        // above (the generic `zig build` produces `zig-out/lib/libgame.so`)
        // but, unlike `labelle android build`, used to stop there and leave
        // a bare `.so`. Package it into a signed APK so the artifact is
        // installable — backend-agnostic, so it covers sokol and bgfx alike.
        if (parsed.platform == .android) {
            const apk_path = try android.packageApk(allocator, target_dir, parsed, false, .{});
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
                };
                try serve.serveAndOpen(allocator, web_dir, project_web_dir, parsed_args.serve_port, !parsed_args.serve_no_open, .{
                    .watch_dir = project_dir,
                    .rebuild_fn = WasmRebuildCtx.rebuild,
                    .rebuild_ctx = &rebuild_ctx,
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
        try android.deployToDevice(allocator, target_dir, parsed, false, .{});
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
                std.debug.print("labelle: screenshot will be written to '{s}'\n", .{path});
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
            const run_result = try runner.runZigInheritWithEnv(allocator, project_dir, run_args.items, timeout_ns, env_map_ptr);
            if (run_result != 0) {
                std.debug.print("\nlabelle: process exited with code {d}\n", .{run_result});
            }
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
            const run_result = try runner.runZigInheritWithEnv(allocator, target_dir, run_args.items, timeout_ns, env_map_ptr);
            if (run_result != 0) {
                std.debug.print("\nlabelle: process exited with code {d}\n", .{run_result});
            }
            // The game ran: the pipeline is `done` even on a nonzero game
            // exit — the code is carried in the terminal record.
            if (reporter) |r| r.finishDone(run_result);
        }
    }
}

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
