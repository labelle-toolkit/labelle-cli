/// labelle-cli — reads project.labelle and generates/builds/runs the assembled game.
///
/// Usage:
///   labelle generate [dir] [--scene=name] [--optimize=MODE] — generate .labelle/ assembler files
///   labelle run [dir] [--timeout=30s] [--scene=name] [--optimize=MODE] [--progress=json] [--screenshot=<path> [--after=<dur>]] [-- <args>...] — generate + build + run; `--screenshot` captures a frame to <path>, re-encoded to the extension you asked for (cli#356); `--headless` with no `--timeout` stops after 5m (cli#485; `--timeout=0` for none); `--` forwards trailing args to the game; on a provider target whose package replaces `run`, the options travel to its hook as `run.env` (docs/provider-hooks.md)
///   labelle build [dir] [--scene=name] [--optimize=MODE] [--progress=json] [--linux-desktop] — generate + build (no run); on Linux (or with `--linux-desktop`) also writes `zig-out/<exe>.desktop` + `zig-out/<exe>.png` for the desktop target (cli#359)
///   labelle bundle [dir] [--optimize=MODE] [--output dir] [--build-number n] [--platform=<t>] — generate + build the resolved target, then package it: for `desktop`, wrap the exe in a self-contained macOS `<Title>.app` (Info.plist + AppIcon.icns, `assets/` staged into Contents/Resources, sh launcher for the cwd; `CFBundleVersion` = `<major+1>.<minor>.<patch>` of `.version` unless `--build-number` pins it; macOS only, cli#359/#364/#363); for a provider target, run the provider's `replace` hook on `bundle` (RFC #406, docs/provider-targets.md)
///   labelle status [dir] [--json]       — print the current/last build progress (reads .labelle/<target>/.build-progress.json)
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
const bake_mod = @import("cli/bake.zig");
const util = @import("cli/util.zig");
const pack = @import("cli/pack.zig");
const progress = @import("cli/progress.zig");
const status_mod = @import("cli/status.zig");
const astc_cmd = @import("astc/cmd.zig");
const audit = @import("cli/audit.zig");
const migrate = @import("cli/migrate.zig");
const check = @import("cli/check.zig");
const plugins = @import("cli/plugins.zig");
const provider_dispatch = @import("cli/provider_dispatch.zig");
const provider_contract = @import("cli/provider_contract.zig");
const provider_github = @import("cli/provider_github.zig");
const provider_targets = @import("cli/provider_targets.zig");
const doctor = @import("cli/doctor.zig");
const sdl_provision = @import("cli/sdl_provision.zig");

// Argument parsing lives in cli/args.zig (extracted so neither file
// exceeds ~1000 lines). Alias the decls main/dispatch reference so their
// bodies stay unchanged.
const args_mod = @import("cli/args.zig");
const ParsedArgs = args_mod.ParsedArgs;
const parseDirAndScene = args_mod.parseDirAndScene;
const parseRunArgs = args_mod.parseRunArgs;
const parseBundleArgs = args_mod.parseBundleArgs;
const collectExtraArgs = args_mod.collectExtraArgs;
const appendExtraArg = args_mod.appendExtraArg;
const appendRunForwardedArgs = args_mod.appendRunForwardedArgs;
const pipeline = @import("cli/pipeline.zig");

/// Handle `labelle providers <resolve|fetch>`.
fn providerCommand(allocator: std.mem.Allocator, args: *std.process.Args.Iterator) !u8 {
    const usage = "Usage: labelle providers resolve [providers.json] [--accept] [--offline]\n" ++
        "  Without --accept: preview pins and record them in .labelle/providers.preview.json.\n" ++
        "  --accept: pin only what that preview recorded; a changed registry is rejected.\n" ++
        "Usage: labelle providers fetch [--offline]\n" ++
        "  Inside a project: download the archives its labelle.providers.lock pins that are not\n" ++
        "  cached and valid. Only bytes verified against the lock's sha256 are cached, each archive\n" ++
        "  atomically (no registry, no lock change, no package code; project.labelle only locates\n" ++
        "  the project root). --offline downloads nothing and only verifies the cache.\n";
    const sub = args.next() orelse {
        std.debug.print("{s}", .{usage});
        return 0;
    };
    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        std.debug.print("{s}", .{usage});
        return 0;
    }
    const is_fetch = std.mem.eql(u8, sub, "fetch");
    if (!is_fetch and !std.mem.eql(u8, sub, "resolve")) return error.UnknownProviderOperation;
    var source: ?[]const u8 = null;
    var accept = false;
    var offline = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print("{s}", .{usage});
            return 0;
        }
        if (std.mem.eql(u8, arg, "--accept") and !is_fetch) {
            accept = true;
        } else if (std.mem.eql(u8, arg, "--offline")) {
            offline = true;
        } else if (std.mem.startsWith(u8, arg, "-") or source != null or is_fetch) return error.InvalidProviderArguments else source = arg;
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try provider_dispatch.projectRoot(a) orelse {
        // The providers lock lives next to project.labelle, so both
        // operations run inside a project; `fetch` parses nothing of it.
        std.debug.print("labelle providers {s}: not inside a labelle project (no project.labelle here or in any parent directory). Run it from the project whose {s} it should use.\n", .{ sub, provider_github.lock_name });
        return error.ProjectRequired;
    };
    if (is_fetch) {
        _ = try provider_github.fetchCommand(a, root, offline, true);
        return 0;
    }
    try provider_github.resolve(a, root, source orelse provider_github.registry_url, accept, offline, &provider_dispatch.reserved);
    return 0;
}

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
    std.debug.print("labelle toolchain: unknown subcommand '{s}'\n", .{cmd_args[0]});
    std.debug.print("  usage: labelle toolchain list | labelle toolchain which [dir]\n", .{});
    return error.UnknownSubcommand;
}

/// Returns the process exit status. `run` earns the game's own status (a
/// crash can no longer exit 0 — cli#390); every other command returns 0 on
/// completion and an error (exit 1) or an explicit code on failure.
/// The exit status of a command line its parser rejected (it printed the
/// diagnostic): never 0, so a shell or CI step cannot read a refused
/// command — `run --watch --docker`, an unknown flag — as a success.
const usage_error: u8 = 2;

pub fn main(proc_init: std.process.Init) !u8 {
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
    if (first_arg == null) return printHelpWithProviders(allocator);

    if (first_arg) |first| {
        if (std.mem.eql(u8, first, "providers")) {
            return providerCommand(allocator, &args) catch |err| {
                std.debug.print("labelle: providers command failed: {s}\n", .{@errorName(err)});
                return 1;
            };
        }
        if (std.mem.eql(u8, first, "generate") or std.mem.eql(u8, first, "build")) {
            parsed_args.command = if (std.mem.eql(u8, first, "generate")) .generate else .build;
            // A usage error must exit NON-ZERO so a CI step cannot read a
            // REJECTED command as a successful build — the same rule PR #362
            // applied to `bundle`. The parser has already printed the
            // diagnostic; this only sets the status. (The `run` parser exits
            // `usage_error`.)
            const result = parseDirAndScene(&args, first) orelse return error.InvalidArguments;
            parsed_args.project_dir = result.dir;
            parsed_args.scene_override = result.scene;
            parsed_args.platform_override = result.platform;
            parsed_args.optimize_override = result.optimize;
            parsed_args.docker = result.docker_build;
            parsed_args.docker_target = result.docker_target;
            parsed_args.bake = result.bake;
            parsed_args.progress_mode = result.progress_mode;
            parsed_args.linux_desktop = result.linux_desktop;
            parsed_args.allow_older_cli = result.allow_older_cli;
        } else if (std.mem.eql(u8, first, "bundle")) {
            // `labelle bundle` (cli#359): generate + build the resolved
            // target, then package it — the core macOS `.app` for
            // `desktop`, or a provider's `replace` hook on `bundle` for a
            // provider target (`--platform=<t>`, RFC #406 phase 3b). The
            // host gate lives in the pipeline now, after target resolution,
            // so it refuses only the core desktop packager off macOS and
            // still does so before any build (docs/provider-targets.md).
            parsed_args.command = .bundle_cmd;
            // A usage error must exit NON-ZERO so automation can't mistake
            // `labelle bundle --bogus` for a built bundle (Codex on #362).
            // The parser has already printed the diagnostic.
            const result = parseBundleArgs(&args) orelse return error.InvalidArguments;
            parsed_args.project_dir = result.dir;
            parsed_args.optimize_override = result.optimize;
            parsed_args.bundle_output = result.output;
            parsed_args.bundle_build_number = result.build_number;
            parsed_args.progress_mode = result.progress_mode;
            parsed_args.platform_override = result.platform;
        } else if (std.mem.eql(u8, first, "run")) {
            parsed_args.command = .run;
            const result = parseRunArgs(&args, "run", true, &parsed_args) orelse return usage_error;
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
            // Provider dispatch discovers the current project first, so a
            // config or discovery error there fails the whole invocation.
            // A token that can never name a provider namespace (`../game`,
            // `./game`, an absolute path) must not reach it, or `labelle
            // ../game` from a broken project reports `provider command
            // failed` instead of running that directory (#460 review). A
            // namespace-shaped token still dispatches before the directory
            // shorthand, so `labelle web …` keeps meaning the provider in
            // a project that also has a `web/` folder.
            if (mayNameProvider(first)) {
                if (provider_dispatch.dispatch(allocator, first, &args) catch |err| {
                    std.debug.print("labelle: provider command failed: {s}\n", .{@errorName(err)});
                    return 1;
                }) |code| return code;
            }

            // Preserve the historical shorthand only for an existing
            // directory. An arbitrary token is much more likely to be a
            // misspelled command than a project path.
            if (!isDirectoryShorthand(first)) {
                reportUnknownCommand(allocator, first);
                std.process.exit(1);
            }
            const result = parseRunArgs(&args, "run", false, &parsed_args) orelse return usage_error;
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

    // Standalone commands (no project.labelle needed)
    switch (command) {
        .help_cmd => return printHelpWithProviders(allocator),
        .version => return ok(help.printVersion()),
        .targets => return ok(provider_targets.printTargets(allocator)),
        .init_cmd => return ok(init.cmdInit(allocator, parsed_args.extra_args[0..parsed_args.extra_count])),
        .add_cmd => return ok(add.cmdAdd(allocator, parsed_args.extra_args[0..parsed_args.extra_count])),
        .install_cmd => return ok(install.cmdInstall(allocator, parsed_args.extra_args[0..parsed_args.extra_count])),
        .update_cmd => return ok(update.cmdUpdate(allocator, parsed_args.extra_args[0..parsed_args.extra_count])),
        .clean_cmd => return ok(clean.cmdClean(allocator, parsed_args.extra_args[0..parsed_args.extra_count])),
        .test_cmd => return ok(test_cmd_mod.cmdTest(allocator, parsed_args.extra_args[0..parsed_args.extra_count])),
        .pack_cmd => return ok(pack.cmdPack(allocator, parsed_args.extra_args[0..parsed_args.extra_count])),
        .astc_cmd => return ok(astc_cmd.cmdAstc(allocator, parsed_args.extra_args[0..parsed_args.extra_count])),
        .audit_cmd => return ok(audit.cmdAudit(allocator, parsed_args.extra_args[0..parsed_args.extra_count])),
        .migrate_cmd => return ok(migrate.cmdMigrate(allocator, parsed_args.extra_args[0..parsed_args.extra_count])),
        .check_cmd => return ok(check.cmdCheck(allocator, parsed_args.extra_args[0..parsed_args.extra_count])),
        .plugins_cmd => return ok(plugins.cmdPlugins(allocator, parsed_args.extra_args[0..parsed_args.extra_count])),
        .doctor_cmd => return ok(doctor.cmdDoctor(allocator, parsed_args.extra_args[0..parsed_args.extra_count])),
        .assembler_cmd => return ok(handleAssemblerCmd(allocator, parsed_args.extra_args[0..parsed_args.extra_count])),
        .toolchain_cmd => return ok(handleToolchainCmd(allocator, parsed_args.extra_args[0..parsed_args.extra_count])),
        .status_cmd => return ok(status_mod.cmdStatus(allocator, parsed_args.extra_args[0..parsed_args.extra_count])),
        else => {},
    }

    return pipeline.run(allocator, parsed_args);
}

/// A completed standalone command is exit 0; its error, if any, propagates
/// (exit 1 with the error name printed), exactly as before `main` returned
/// a status.
fn ok(result: anytype) !u8 {
    if (comptime @typeInfo(@TypeOf(result)) == .error_union) try result;
    return 0;
}

/// Built-in usage followed by the project's provider commands, for both
/// `labelle help` and a bare `labelle`.
///
/// Provider discovery is best-effort and never changes the exit status: the
/// built-in text has already been printed, and a broken project.labelle or
/// provider manifest is exactly the situation in which a user reaches for
/// help (or a script relies on it being universally available). A discovery
/// failure is a one-line stderr warning, not an error (cli#413 review).
fn printHelpWithProviders(allocator: std.mem.Allocator) u8 {
    help.printHelp();
    provider_dispatch.printHelp(allocator) catch |err| {
        std.debug.print("labelle: warning: project package commands not listed, provider discovery failed: {s}\n", .{@errorName(err)});
    };
    return 0;
}

/// A first token that is no built-in command, no pinned provider's
/// namespace and no directory: `provider_targets.reportUnknownCommand` names
/// the package that declares it as a namespace when the project's own
/// registry document (its verified custom source, else the public registry)
/// says so, and is the plain unknown-command error otherwise (#465).
fn reportUnknownCommand(allocator: std.mem.Allocator, first: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = provider_dispatch.projectRoot(a) catch null;
    provider_targets.reportUnknownCommand(a, root, first);
}

fn isDirectoryShorthand(path: []const u8) bool {
    return util.dirExists(path);
}

/// Whether `token` could be a provider namespace at all: namespaces are
/// contract identifiers (`provider_manifest` rejects anything else), so a
/// path such as `../game` is decided without discovering the project.
fn mayNameProvider(token: []const u8) bool {
    return provider_contract.identifier(token);
}

test "mayNameProvider: only a namespace-shaped token reaches provider dispatch" {
    for ([_][]const u8{ "android", "web", "probe", "my-provider", "ns_2" }) |token| {
        try std.testing.expect(mayNameProvider(token));
    }
    for ([_][]const u8{ "../game", "./game", "..", ".", "/abs/game", "game/", "C:\\game", "Game", "" }) |token| {
        try std.testing.expect(!mayNameProvider(token));
    }
}

// --- Tests ---

pub const FirstArgumentSpec = struct {
    test "an existing directory keeps the implicit run shorthand" {
        try std.testing.expect(isDirectoryShorthand("."));
    }

    test "a missing directory is not accepted as an implicit run command" {
        try std.testing.expect(!isDirectoryShorthand("definitely-not-a-labelle-directory"));
    }
};

const expect = @import("zspec").expect;

test {
    @import("zspec").runAll(@This());
}

// Generic watch-session modules (RFC cli#466 A2): referenced so their
// tests run.
test {
    _ = @import("cli/supervise.zig");
    _ = @import("cli/watch.zig");
    _ = @import("cli/project_lock.zig");
}

// `labelle init` stamps the running CLI as `--labelle-version`.
pub const InitCliVersionSpec = init.InitCliVersionSpec;

// Surface the argument-parser spec namespaces (in cli/args_tests.zig).
const args_tests_mod = @import("cli/args_tests.zig");
pub const ArgsParseSceneArgSpec = args_tests_mod.ParseSceneArg;
pub const ArgsSceneArgValueSpec = args_tests_mod.SceneArgValue;
pub const ArgsParseSceneFlagSpec = args_tests_mod.ParseSceneFlagSpec;
pub const ArgsSceneOverridePipelineSpec = args_tests_mod.SceneOverridePipelineSpec;
pub const ArgsParseOptimizeFlagSpec = args_tests_mod.ParseOptimizeFlagSpec;
pub const ArgsParsePlatformValueSpec = args_tests_mod.ParsePlatformValueSpec;
pub const ArgsParseRunArgsPassthroughSpec = args_tests_mod.ParseRunArgsPassthroughSpec;
pub const ArgsParseHeadlessFlagsSpec = args_tests_mod.ParseHeadlessFlagsSpec;
pub const ArgsParseBundleArgsSpec = args_tests_mod.ParseBundleArgsSpec;
pub const ArgsParseDirAndSceneLinuxDesktopSpec = args_tests_mod.ParseDirAndSceneLinuxDesktopSpec;
pub const ArgsAllowOlderCliFlagSpec = args_tests_mod.AllowOlderCliFlagSpec;
pub const ArgsHeadlessDefaultTimeoutSpec = args_tests_mod.HeadlessDefaultTimeoutSpec;
// cli#396: the shared value-flag parser (in cli/args_value_flag_tests.zig).
pub const ArgsValueFlagSpec = @import("cli/args_value_flag_tests.zig").ValueFlagSpec;

// Linux `.desktop` entry emission (cli#359). Re-exported HERE for the same
// reason as the screenshot specs below: `linux_desktop` is a private import,
// so its specs would otherwise never be analyzed.
const linux_desktop_mod = @import("cli/linux_desktop.zig");
pub const LinuxDesktopEscapeExecArgSpec = linux_desktop_mod.EscapeExecArgSpec;
pub const LinuxDesktopDisplayNameSpec = linux_desktop_mod.DisplayNameSpec;
pub const LinuxDesktopRenderSpec = linux_desktop_mod.RenderSpec;
pub const LinuxDesktopStageIconSpec = linux_desktop_mod.StageIconSpec;
pub const LinuxDesktopCreateFromBuildSpec = linux_desktop_mod.CreateFromBuildSpec;
pub const LinuxDesktopShouldEmitSpec = linux_desktop_mod.ShouldEmitSpec;
pub const ArgsAppendRunForwardedArgsSpec = args_tests_mod.AppendRunForwardedArgsSpec;

pub const TestCmdIsSkipDirSpec = test_cmd_mod.IsSkipDirSpec;
pub const TestCmdFileHasTestBlockSpec = test_cmd_mod.FileHasTestBlockSpec;
// The nested-git-checkout prune (labelle-cli#371): `labelle test` must
// not descend into worktrees/submodules parked inside the project.
pub const TestCmdNestedCheckoutSpec = test_cmd_mod.NestedCheckoutSpec;
pub const TestCmdIsNestedCheckoutSpec = test_cmd_mod.IsNestedCheckoutSpec;
pub const TestCmdGameTestFreshnessSpec = test_cmd_mod.GameTestFreshnessSpec;

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
pub const UpdateWindowsScriptSpec = update.WindowsUpdateScriptSpec;

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

pub const PipelineCollectPrebuildIgnorePathsSpec = pipeline.CollectPrebuildIgnorePathsSpec;

// Surface the `.prebuild` hook specs (cli#355) so `zspec.runAll(@This())`
// walks into them: step validation, the mtime staleness rule, argv
// rendering, the no-shell/cwd/exit-code execution contract, and the
// "a project without .prebuild is inert" guarantee.
const prebuild_mod = @import("cli/prebuild.zig");
pub const PrebuildValidateStepSpec = prebuild_mod.ValidateStepSpec;
pub const PrebuildStalenessVerdictSpec = prebuild_mod.StalenessVerdictSpec;
pub const PrebuildScanStepSpec = prebuild_mod.ScanStepSpec;
pub const PrebuildRenderArgvSpec = prebuild_mod.RenderArgvSpec;
pub const PrebuildFailureDetailSpec = prebuild_mod.FailureDetailSpec;
pub const PrebuildNoPrebuildIsInertSpec = prebuild_mod.NoPrebuildIsInertSpec;
pub const PrebuildRunStepSpec = prebuild_mod.RunStepSpec;
pub const PrebuildRunAllSpec = prebuild_mod.RunAllSpec;
pub const PrebuildParsePrebuildSpec = prebuild_mod.ParsePrebuildSpec;
pub const PrebuildStdoutRouteSpec = @import("cli/prebuild_relay.zig").StdoutRouteSpec;
pub const PrebuildRelayOwnershipSpec = @import("cli/prebuild_relay.zig").RelayOwnershipSpec;

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
