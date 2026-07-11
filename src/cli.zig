/// labelle-cli — reads project.labelle and generates/builds/runs the assembled game.
///
/// Usage:
///   labelle generate [dir] [--scene=name] [--optimize=MODE] — generate .labelle/ assembler files
///   labelle run [dir] [--timeout=30s] [--scene=name] [--optimize=MODE] [--progress=json] [--screenshot=<path> [--after=<dur>]] [-- <args>...] — generate + build + run; `--screenshot` captures a frame to <path> (raylib picks PNG/BMP by extension); `--` forwards trailing args to the game
///   labelle build [dir] [--scene=name] [--optimize=MODE] [--progress=json] — generate + build (no run)
///   labelle status [dir] [--json]       — print the current/last build progress (reads .labelle/<target>/.build-progress.json)
///   labelle wasm serve [dir] [--port n] [--no-build] [--no-open] — build the WASM target and serve it locally
///   labelle wasm export [dir] [--output dir] [--zip] [--platform itch|github-pages] [--no-build] — build + package a deployment-ready WASM dir
///   labelle [dir]                       — alias for `run`
///   labelle init <name> [dir]           — scaffold a new project
///   labelle install [pkg] [ver]         — fetch packages into cache
///   labelle install assembler <ver>    — download and cache an assembler binary
///   labelle assembler list             — list cached assembler versions
///   labelle upgrade [dir] [pkg] [ver] [--check] [--json]  — bump versions in project.labelle; `--check`/`--json` report pins vs latest read-only (labelle-cli#276)
///   labelle update [ver] [--check] [--json]  — self-update the CLI; `--check`/`--json` report installed vs latest read-only (labelle-cli#276)
///   labelle clean [--dry-run]           — prune unused package versions
///   labelle test [dir] [--verbose]      — run inline `test` blocks across the project source tree
///   labelle check [dir]                 — lint packs for §6 convention violations (Packs RFC)
const std = @import("std");
const project_config = @import("cli/project_config.zig");

// Submodules
const help = @import("cli/help.zig");
const init = @import("cli/init.zig");
const add = @import("cli/add.zig");
const install = @import("cli/install.zig");
const upgrade = @import("cli/upgrade.zig");
const update = @import("cli/update.zig");
const update_check = @import("cli/update_check.zig");
const clean = @import("cli/clean.zig");
const test_cmd_mod = @import("cli/test.zig");
const config = @import("cli/config.zig");
const compatibility = @import("cli/compatibility.zig");
const lockfile = @import("cli/lockfile.zig");
const runner = @import("cli/runner.zig");
const assembler = @import("cli/assembler.zig");
const assembler_proc = @import("cli/assembler_proc.zig");
const zig_toolchain = @import("cli/zig_toolchain.zig");
const emsdk_toolchain = @import("cli/emsdk_toolchain.zig");
const emsdk_activate = @import("cli/emsdk_activate.zig");
const bake_mod = @import("cli/bake.zig");
const docker = @import("cli/docker.zig");
const serve = @import("cli/serve.zig");
const export_mod = @import("cli/export.zig");
const ios = @import("cli/ios.zig");
const android = @import("cli/android.zig");
const util = @import("cli/util.zig");
const pack = @import("cli/pack.zig");
const progress = @import("cli/progress.zig");
const status_mod = @import("cli/status.zig");
const astc_cmd = @import("astc/cmd.zig");
const audit = @import("cli/audit.zig");
const migrate = @import("cli/migrate.zig");
const check = @import("cli/check.zig");
const plugins = @import("cli/plugins.zig");
const doctor = @import("cli/doctor.zig");
const sdl_provision = @import("cli/sdl_provision.zig");


// Argument parsing lives in cli/args.zig (extracted so neither file
// exceeds ~1000 lines). Alias the decls main/dispatch reference so their
// bodies stay unchanged.
const args_mod = @import("cli/args.zig");
const ParsedArgs = args_mod.ParsedArgs;
const resolveAndroidBackend = args_mod.resolveAndroidBackend;
const parseDirAndScene = args_mod.parseDirAndScene;
const parseRunArgs = args_mod.parseRunArgs;
const parseWasmServeArgs = args_mod.parseWasmServeArgs;
const parseWasmExportArgs = args_mod.parseWasmExportArgs;
const collectExtraArgs = args_mod.collectExtraArgs;
const appendExtraArg = args_mod.appendExtraArg;
const appendRunForwardedArgs = args_mod.appendRunForwardedArgs;

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

/// Handle `labelle assembler <subcommand>`.
fn handleAssemblerCmd(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    if (cmd_args.len == 0 or std.mem.eql(u8, cmd_args[0], "list")) {
        return assembler.cmdListAssemblers(allocator);
    }
    std.debug.print("labelle assembler: unknown subcommand '{s}'\n", .{cmd_args[0]});
    std.debug.print("  usage: labelle assembler list\n", .{});
    return error.UnknownSubcommand;
}

/// Handle `labelle toolchain <subcommand>` — managed Zig introspection (cli#279).
///   list         — cached versions under `~/.labelle/zig/`
///   which [dir]  — the version + source + path the project would use
fn handleToolchainCmd(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    if (cmd_args.len == 0 or std.mem.eql(u8, cmd_args[0], "list")) {
        return zig_toolchain.cmdToolchainList(allocator);
    }
    if (std.mem.eql(u8, cmd_args[0], "which")) {
        const dir = if (cmd_args.len >= 2) cmd_args[1] else ".";
        return zig_toolchain.cmdToolchainWhich(allocator, dir);
    }
    // `toolchain emsdk [dir]` — managed emsdk/emcc resolution (cli#283).
    if (std.mem.eql(u8, cmd_args[0], "emsdk")) {
        const dir = if (cmd_args.len >= 2) cmd_args[1] else ".";
        return emsdk_toolchain.cmdEmsdkWhich(allocator, dir);
    }
    std.debug.print("labelle toolchain: unknown subcommand '{s}'\n", .{cmd_args[0]});
    std.debug.print("  usage: labelle toolchain list | labelle toolchain which [dir] | labelle toolchain emsdk [dir]\n", .{});
    return error.UnknownSubcommand;
}

pub fn main(proc_init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize the process-wide Io for the CLI's filesystem/env
    // helpers. Must happen before any submodule reaches for
    // `globalIo()`/`globalEnviron()`.
    config.initGlobalIo(proc_init.minimal);

    var args = try std.process.Args.Iterator.initAllocator(proc_init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip(); // skip program name

    var parsed_args = ParsedArgs{ .command = .run };

    const first_arg = args.next();
    if (first_arg == null) {
        return help.printHelp();
    }

    if (first_arg) |first| {
        if (std.mem.eql(u8, first, "generate") or std.mem.eql(u8, first, "build")) {
            parsed_args.command = if (std.mem.eql(u8, first, "generate")) .generate else .build;
            const result = parseDirAndScene(&args, first) orelse return;
            parsed_args.project_dir = result.dir;
            parsed_args.scene_override = result.scene;
            parsed_args.platform_override = result.platform;
            parsed_args.optimize_override = result.optimize;
            parsed_args.docker = result.docker_build;
            parsed_args.docker_target = result.docker_target;
            parsed_args.bake = result.bake;
            parsed_args.progress_mode = result.progress_mode;
        } else if (std.mem.eql(u8, first, "run")) {
            parsed_args.command = .run;
            const result = parseRunArgs(&args, "run", true, &parsed_args) orelse return;
            parsed_args.project_dir = result.dir;
            parsed_args.scene_override = result.scene;
            parsed_args.timeout_ns = result.timeout_ns;
            parsed_args.platform_override = result.platform;
            parsed_args.optimize_override = result.optimize;
            parsed_args.docker = result.docker_build;
            parsed_args.docker_target = result.docker_target;
            parsed_args.bake = result.bake;
            parsed_args.screenshot_path = result.screenshot_path;
            parsed_args.screenshot_after_ns = result.screenshot_after_ns;
        } else if (std.mem.eql(u8, first, "init")) {
            parsed_args.command = .init_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "install")) {
            parsed_args.command = .install_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "upgrade")) {
            parsed_args.command = .upgrade_cmd;
            // Grammar: `upgrade [dir] [flags] [<subcommand> [args...]]`.
            // Flags (`--check`/`--json`/`--force`/`-f`) may appear anywhere;
            // the first bare non-subcommand token is the project dir; once a
            // subcommand is seen, the remaining tokens are its args. A
            // leading-dash token must NEVER be captured as the project dir —
            // otherwise `upgrade --check` would send `--check` to
            // readProjectConfig and bail before the check runs (this also
            // fixes the same latent bug for a leading `--force`).
            var seen_subcommand = false;
            var dir_set = false;
            while (args.next()) |next_arg| {
                if (std.mem.startsWith(u8, next_arg, "-")) {
                    try appendExtraArg(&parsed_args, next_arg);
                } else if (seen_subcommand) {
                    try appendExtraArg(&parsed_args, next_arg);
                } else if (std.mem.eql(u8, next_arg, "core") or
                    std.mem.eql(u8, next_arg, "engine") or
                    std.mem.eql(u8, next_arg, "gfx") or
                    std.mem.eql(u8, next_arg, "cli") or
                    std.mem.eql(u8, next_arg, "labelle") or
                    std.mem.eql(u8, next_arg, "assembler") or
                    std.mem.eql(u8, next_arg, "all"))
                {
                    try appendExtraArg(&parsed_args, next_arg);
                    seen_subcommand = true;
                } else if (!dir_set) {
                    parsed_args.project_dir = next_arg;
                    dir_set = true;
                } else {
                    try appendExtraArg(&parsed_args, next_arg);
                }
            }
        } else if (std.mem.eql(u8, first, "update")) {
            parsed_args.command = .update_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "clean")) {
            parsed_args.command = .clean_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "test")) {
            parsed_args.command = .test_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "pack")) {
            parsed_args.command = .pack_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "astc")) {
            parsed_args.command = .astc_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "audit")) {
            parsed_args.command = .audit_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "add")) {
            // `add pack <name>` / `add feature <kind> <name>` — forwarded
            // verbatim to the assembler's `add` subcommand (Packs #271).
            parsed_args.command = .add_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "migrate")) {
            parsed_args.command = .migrate_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "check")) {
            parsed_args.command = .check_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "plugins")) {
            // `labelle plugins [dir]` — list attached plugins with their
            // version + license/author provenance (labelle-cli#300).
            parsed_args.command = .plugins_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "toolchain")) {
            // `labelle toolchain list|which` — managed Zig introspection (cli#279).
            parsed_args.command = .toolchain_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "status")) {
            // `labelle status [dir] [--json]` — read the live build-progress
            // status file from a second shell (cli#284).
            parsed_args.command = .status_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "doctor")) {
            parsed_args.command = .doctor_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "ios")) {
            parsed_args.command = .ios_cmd;
            // First non-flag arg that isn't a subcommand is the project dir
            while (args.next()) |arg| {
                if (std.mem.startsWith(u8, arg, "-") or
                    std.mem.eql(u8, arg, "build") or
                    std.mem.eql(u8, arg, "xcode") or
                    std.mem.eql(u8, arg, "run"))
                {
                    try appendExtraArg(&parsed_args, arg);
                } else {
                    parsed_args.project_dir = arg;
                }
            }
        } else if (std.mem.eql(u8, first, "android")) {
            parsed_args.command = .android_cmd;
            // Android value-bearing flags: the NEXT token after one of
            // these is the flag's value, not the project directory.
            var expect_value = false;
            while (args.next()) |arg| {
                if (expect_value) {
                    try appendExtraArg(&parsed_args, arg);
                    expect_value = false;
                    continue;
                }
                if (std.mem.startsWith(u8, arg, "-") or
                    std.mem.eql(u8, arg, "build") or
                    std.mem.eql(u8, arg, "run") or
                    std.mem.eql(u8, arg, "studio") or
                    std.mem.eql(u8, arg, "deploy") or
                    std.mem.eql(u8, arg, "doctor") or
                    std.mem.eql(u8, arg, "help"))
                {
                    try appendExtraArg(&parsed_args, arg);
                    if (std.mem.eql(u8, arg, "--keystore") or
                        std.mem.eql(u8, arg, "--keystore-pass") or
                        std.mem.eql(u8, arg, "--key-alias") or
                        std.mem.eql(u8, arg, "--key-pass") or
                        std.mem.eql(u8, arg, "--tag") or
                        std.mem.eql(u8, arg, "--channel") or
                        std.mem.eql(u8, arg, "--notes-file"))
                    {
                        expect_value = true;
                    }
                } else {
                    parsed_args.project_dir = arg;
                }
            }
        } else if (std.mem.eql(u8, first, "wasm")) {
            // `labelle wasm <subcommand>` — `serve` and `export`.
            const sub = args.next();
            if (sub != null and std.mem.eql(u8, sub.?, "serve")) {
                parsed_args.command = .wasm_cmd;
                const result = parseWasmServeArgs(&args) orelse return;
                parsed_args.project_dir = result.dir;
                parsed_args.serve_port = result.port;
                parsed_args.serve_no_build = result.no_build;
                parsed_args.serve_no_open = result.no_open;
                parsed_args.serve_watch = result.watch;
                parsed_args.progress_mode = result.progress_mode;
                // `wasm serve` always builds/serves the WASM target.
                parsed_args.platform_override = .wasm;
            } else if (sub != null and std.mem.eql(u8, sub.?, "export")) {
                parsed_args.command = .wasm_cmd;
                parsed_args.wasm_export = true;
                const result = parseWasmExportArgs(&args) orelse return;
                parsed_args.project_dir = result.dir;
                parsed_args.export_output = result.output;
                parsed_args.export_zip = result.zip;
                parsed_args.export_pkg_platform = result.pkg_platform;
                // `--no-build` is the shared "skip build, package existing
                // output" flag (see ParsedArgs.serve_no_build).
                parsed_args.serve_no_build = result.no_build;
                parsed_args.progress_mode = result.progress_mode;
                // `wasm export` always builds/packages the WASM target.
                parsed_args.platform_override = .wasm;
            } else {
                if (sub) |s| {
                    std.debug.print("labelle wasm: unknown subcommand '{s}'\n", .{s});
                } else {
                    std.debug.print("labelle wasm: missing subcommand\n", .{});
                }
                std.debug.print("  usage: labelle wasm serve [dir] [--port <n>] [--no-build] [--no-open] [--watch] [--progress=<m>]\n", .{});
                std.debug.print("         labelle wasm export [dir] [--output <dir>] [--zip] [--platform <itch|github-pages>] [--no-build] [--progress=<m>]\n", .{});
                return;
            }
        } else if (std.mem.eql(u8, first, "assembler")) {
            parsed_args.command = .assembler_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
            parsed_args.command = .help_cmd;
        } else if (std.mem.eql(u8, first, "version") or std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-v")) {
            parsed_args.command = .version;
        } else if (std.mem.eql(u8, first, "targets")) {
            parsed_args.command = .targets;
        } else {
            // No command — treat as project dir, default to run
            const result = parseRunArgs(&args, "run", false, &parsed_args) orelse return;
            parsed_args.project_dir = first;
            parsed_args.scene_override = result.scene;
            parsed_args.timeout_ns = result.timeout_ns;
            parsed_args.platform_override = result.platform;
            parsed_args.optimize_override = result.optimize;
            parsed_args.docker = result.docker_build;
            parsed_args.docker_target = result.docker_target;
            parsed_args.bake = result.bake;
            parsed_args.screenshot_path = result.screenshot_path;
            parsed_args.screenshot_after_ns = result.screenshot_after_ns;
        }
    }

    const command = parsed_args.command;
    const project_dir = parsed_args.project_dir;
    const timeout_ns = parsed_args.timeout_ns;

    // Standalone commands (no project.labelle needed)
    switch (command) {
        .help_cmd => return help.printHelp(),
        .version => return help.printVersion(),
        .targets => return help.printTargets(),
        .init_cmd => return init.cmdInit(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .add_cmd => return add.cmdAdd(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .install_cmd => return install.cmdInstall(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .update_cmd => return update.cmdUpdate(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .clean_cmd => return clean.cmdClean(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .test_cmd => return test_cmd_mod.cmdTest(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .pack_cmd => return pack.cmdPack(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .astc_cmd => return astc_cmd.cmdAstc(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .audit_cmd => return audit.cmdAudit(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .migrate_cmd => return migrate.cmdMigrate(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .check_cmd => return check.cmdCheck(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .plugins_cmd => return plugins.cmdPlugins(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .doctor_cmd => return doctor.cmdDoctor(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .assembler_cmd => return handleAssemblerCmd(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .toolchain_cmd => return handleToolchainCmd(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .status_cmd => return status_mod.cmdStatus(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        else => {},
    }

    // `labelle android doctor` and `labelle android help` are
    // standalone — they don't need a project.labelle. Intercept here
    // so running them from any directory works without the "No
    // project.labelle found" bail below.
    //
    // Doctor still *uses* the project's android config when available
    // so the probe targets the right `target_sdk_version`. The read
    // is quiet: if there's no project (or it fails to parse), we fall
    // through to the defaults instead of erroring out.
    //
    // `AndroidToolsMissing` is caught and turned into `exit(1)` so
    // the Zig error-return trace stays out of the user's terminal —
    // the report was already printed.
    if (command == .android_cmd and parsed_args.extra_count > 0) {
        const first = parsed_args.extra_args[0];
        if (std.mem.eql(u8, first, "doctor")) {
            var doctor_arena = std.heap.ArenaAllocator.init(allocator);
            defer doctor_arena.deinit();
            const project_cfg: ?project_config.AndroidConfig = blk: {
                const parsed_cfg = config.readProjectConfigQuiet(doctor_arena.allocator(), project_dir) catch break :blk null;
                break :blk parsed_cfg.android;
            };
            android.runDoctor(allocator, project_cfg) catch |err| {
                if (err == error.AndroidToolsMissing) std.process.exit(1);
                return err;
            };
            return;
        }
        if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
            return android.printHelp();
        }
    }

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
            const sanitized = try util.sanitizeExeName(allocator, parsed.name);
            defer allocator.free(sanitized);
            const sanitized_full = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "bin", sanitized });
            defer allocator.free(sanitized_full);
            const exe_basename: []const u8 = if (util.fileExists(sanitized_full)) sanitized else "game";
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

// --- Tests ---

const expect = @import("zspec").expect;

test {
    @import("zspec").runAll(@This());
}


// Surface the argument-parser spec namespaces (in cli/args_tests.zig).
const args_tests_mod = @import("cli/args_tests.zig");
pub const ArgsParseSceneArgSpec = args_tests_mod.ParseSceneArg;
pub const ArgsSceneArgValueSpec = args_tests_mod.SceneArgValue;
pub const ArgsParseSceneFlagSpec = args_tests_mod.ParseSceneFlagSpec;
pub const ArgsSceneOverridePipelineSpec = args_tests_mod.SceneOverridePipelineSpec;
pub const ArgsParseOptimizeFlagSpec = args_tests_mod.ParseOptimizeFlagSpec;
pub const ArgsParsePlatformValueSpec = args_tests_mod.ParsePlatformValueSpec;
pub const ArgsResolveAndroidBackendSpec = args_tests_mod.ResolveAndroidBackendSpec;
pub const ArgsParseRunArgsPassthroughSpec = args_tests_mod.ParseRunArgsPassthroughSpec;
pub const ArgsParseHeadlessFlagsSpec = args_tests_mod.ParseHeadlessFlagsSpec;
pub const ArgsParseWasmServeArgsSpec = args_tests_mod.ParseWasmServeArgsSpec;
pub const ArgsParseWasmExportArgsSpec = args_tests_mod.ParseWasmExportArgsSpec;
pub const ArgsAppendRunForwardedArgsSpec = args_tests_mod.AppendRunForwardedArgsSpec;

pub const TestCmdIsSkipDirSpec = test_cmd_mod.IsSkipDirSpec;
pub const TestCmdFileHasTestBlockSpec = test_cmd_mod.FileHasTestBlockSpec;

// Surface the exe-name sanitizer's spec namespace (labelle-assembler#362)
// so `zspec.runAll(@This())` walks into it.
pub const UtilSanitizeExeNameSpec = util.SanitizeExeName;

// Surface audit-command spec namespaces so `zspec.runAll(@This())`
// walks into them. Without these re-exports the audit tests would
// only run via a direct `zig test src/cli/audit.zig`.
pub const AuditStripJsoncToJsonSpec = audit.StripJsoncToJsonSpec;
pub const AuditBasenameWithoutExtSpec = audit.BasenameWithoutExtSpec;
pub const AuditRunAuditOnSpec = audit.RunAuditOnSpec;

// Surface migrate-command spec namespaces so `zspec.runAll(@This())`
// walks into them.
pub const MigrateTransformRootWrapperSpec = migrate.TransformRootWrapperSpec;
pub const MigrateTransformEntitiesRenameSpec = migrate.TransformEntitiesRenameSpec;
pub const MigrateTransformComponentsOnRefSpec = migrate.TransformComponentsOnRefSpec;
pub const MigrateTransformAssetsDeleteSpec = migrate.TransformAssetsDeleteSpec;
pub const MigrateIdempotencySpec = migrate.IdempotencySpec;
pub const MigrateMixedFileSpec = migrate.MixedFileSpec;
pub const MigrateDeleteTopLevelKeyBlockCommentSpec = migrate.DeleteTopLevelKeyBlockCommentSpec;

// Surface the check-command spec namespace so `zspec.runAll(@This())`
// walks into it (mirrors the audit/migrate re-exports above).
pub const CheckParseCheckArgsSpec = check.ParseCheckArgsSpec;

// Surface the `labelle plugins` listing specs (labelle-cli#300) so
// `zspec.runAll(@This())` walks into the plugin.labelle reader tests and
// the table renderer tests.
pub const PluginsReadPluginMetaSpec = plugins.ReadPluginMetaSpec;
pub const PluginsRenderTableSpec = plugins.RenderTableSpec;

// Surface the machine-readable update/upgrade `--check`/`--json` specs
// (labelle-cli#276) so `zspec.runAll(@This())` walks into them.
pub const UpdateCheckCliStatusSpec = update_check.CliStatusSpec;
pub const UpdateCheckPackageStatusSpec = update_check.PackageStatusSpec;
pub const UpdateCheckExitCodeSpec = update_check.ExitCodeSpec;
pub const UpdateCheckJsonShapeSpec = update_check.JsonShapeSpec;
pub const UpdateParseArgsSpec = update.ParseUpdateArgsSpec;

// Surface the build-progress feed specs (cli#284) so
// `zspec.runAll(@This())` walks into them: the phase state machine,
// NDJSON encoding, atomic status-file writes, the fake-build reporter
// pipeline, the std.Progress IPC packet decoder, and `labelle status`
// formatting.
pub const ProgressPhaseMachineSpec = progress.PhaseMachineSpec;
pub const ProgressNdjsonEncodingSpec = progress.NdjsonEncodingSpec;
pub const ProgressAtomicStatusFileSpec = progress.AtomicStatusFileSpec;
pub const ProgressReporterPipelineSpec = progress.ReporterPipelineSpec;
pub const ZigProgressPacketDecodingSpec = @import("cli/zig_progress.zig").PacketDecodingSpec;
pub const StatusFormatHumanSpec = status_mod.FormatHumanSpec;

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
/// Regression tests for `ProjectConfig.normalizeInitialPrefab()` — the
/// legacy `.initial_scene` → `.initial_prefab` alias promotion introduced
/// in RFC #560 / issue #565.
///
/// Scope: this spec covers normalization in isolation. The `--scene` CLI
/// override contract (which intentionally does NOT rewrite
/// `cfg.initial_prefab` as of cli#229 follow-through) is covered by
/// `SceneOverridePipelineSpec` above.
///
/// Cases:
///  1. Legacy `.initial_scene` is promoted to `.initial_prefab` when the new
///     field is absent.
///  2. `.initial_prefab` wins when both fields are present in the config.
///  3. Neither field set → normalization is a no-op (null stays null).
pub const InitialPrefabNormalizationSpec = struct {
    test "normalizeInitialPrefab promotes legacy initial_scene when initial_prefab is null" {
        var cfg = project_config.ProjectConfig{ .name = "test_project", .initial_scene = "legacy_scene" };
        cfg.normalizeInitialPrefab();
        try std.testing.expectEqualStrings("legacy_scene", cfg.initial_prefab.?);
        try std.testing.expectEqual(@as(?[]const u8, null), cfg.initial_scene);
    }

    test "normalizeInitialPrefab keeps initial_prefab when both fields are set" {
        var cfg = project_config.ProjectConfig{ .name = "test_project", .initial_prefab = "new_prefab", .initial_scene = "legacy_scene" };
        cfg.normalizeInitialPrefab();
        try std.testing.expectEqualStrings("new_prefab", cfg.initial_prefab.?);
        try std.testing.expectEqual(@as(?[]const u8, null), cfg.initial_scene);
    }

    test "normalizeInitialPrefab is a no-op when neither field is set" {
        var cfg = project_config.ProjectConfig{ .name = "test_project" };
        cfg.normalizeInitialPrefab();
        try std.testing.expectEqual(@as(?[]const u8, null), cfg.initial_prefab);
        try std.testing.expectEqual(@as(?[]const u8, null), cfg.initial_scene);
    }
};
