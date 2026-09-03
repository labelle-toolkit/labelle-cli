/// labelle-cli — reads project.labelle and generates/builds/runs the assembled game.
///
/// Usage:
///   labelle generate [dir] [--scene=name] [--optimize=MODE] — generate .labelle/ assembler files
///   labelle run [dir] [--timeout=30s] [--scene=name] [--optimize=MODE] [--progress=json] [--screenshot=<path> [--after=<dur>]] [-- <args>...] — generate + build + run; `--screenshot` captures a frame to <path>, re-encoded to the extension you asked for (cli#356); `--` forwards trailing args to the game
///   labelle build [dir] [--scene=name] [--optimize=MODE] [--progress=json] — generate + build (no run)
///   labelle bundle [dir] [--optimize=MODE] [--output dir] — generate + build the desktop target, then wrap the exe in a macOS `<Title>.app` with Info.plist + AppIcon.icns (macOS only, cli#359)
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
const builtin = @import("builtin");
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
const bundle = @import("cli/bundle.zig");

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
const parseBundleArgs = args_mod.parseBundleArgs;
const collectExtraArgs = args_mod.collectExtraArgs;
const appendExtraArg = args_mod.appendExtraArg;
const appendRunForwardedArgs = args_mod.appendRunForwardedArgs;
const pipeline = @import("cli/pipeline.zig");

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
        } else if (std.mem.eql(u8, first, "bundle")) {
            // `labelle bundle` (cli#359): generate + build the desktop
            // target, then wrap the exe in a macOS `.app`. Host-gated
            // HERE, before the project is even read, so a Linux/Windows
            // user gets the one-line refusal instead of a multi-minute
            // build followed by a failure.
            if (!bundle.hostSupported()) {
                bundle.printUnsupported();
                std.process.exit(1);
            }
            parsed_args.command = .bundle_cmd;
            // A usage error must exit NON-ZERO so automation can't mistake
            // `labelle bundle --bogus` for a built bundle (Codex on #362).
            // The parser has already printed the diagnostic. (The older
            // parsers above still `return` with exit 0 — pre-existing, left
            // alone here; candidate for a separate cleanup.)
            const result = parseBundleArgs(&args) orelse return error.InvalidArguments;
            parsed_args.project_dir = result.dir;
            parsed_args.optimize_override = result.optimize;
            parsed_args.bundle_output = result.output;
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

    return pipeline.run(allocator, parsed_args);
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
pub const ArgsParseBundleArgsSpec = args_tests_mod.ParseBundleArgsSpec;
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

// Surface the doctor `--json` capability-report spec so `zspec.runAll(@This())`
// walks into it — it pins the cross-repo contract with labelle-studio's
// ToolchainGate (src/services/doctor.ts).
pub const DoctorJsonReportSpec = doctor.JsonReportSpec;

pub const PipelineResolveExportOutputSpec = pipeline.ResolveExportOutputSpec;

// Surface the screenshot output-format specs (cli#356) so
// `zspec.runAll(@This())` walks into the extension parser, the
// requested-vs-written plan, the encoder's OOM reporting, and the
// on-disk re-encode. `screenshot_format.zig` has no file-level
// `test { runAll(@This()) }` of its own, and `screenshot_format_mod`
// below is private, so a spec that is not re-exported HERE is never
// analyzed and its tests silently never run — which is exactly what
// happened to `EncodeSpec` when it was added.
const screenshot_format_mod = @import("cli/screenshot_format.zig");
pub const ScreenshotFormatFromPathSpec = screenshot_format_mod.FormatFromPathSpec;
pub const ScreenshotFormatPlanSpec = screenshot_format_mod.PlanSpec;
pub const ScreenshotFormatEncodeSpec = screenshot_format_mod.EncodeSpec;
pub const ScreenshotFormatApplySpec = screenshot_format_mod.ApplySpec;
pub const PipelineScreenshotProbeSpec = pipeline.ScreenshotProbeSpec;

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
