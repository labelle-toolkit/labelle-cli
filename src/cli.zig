/// labelle-cli — reads project.labelle and generates/builds/runs the assembled game.
///
/// Usage:
///   labelle generate [dir] [--scene=name] [--optimize=MODE] — generate .labelle/ assembler files
///   labelle run [dir] [--timeout=30s] [--scene=name] [--optimize=MODE] [-- <args>...] — generate + build + run; `--` forwards trailing args to the game
///   labelle build [dir] [--scene=name] [--optimize=MODE] — generate + build (no run)
///   labelle wasm serve [dir] [--port n] [--no-build] [--no-open] — build the WASM target and serve it locally
///   labelle [dir]                       — alias for `run`
///   labelle init <name> [dir]           — scaffold a new project
///   labelle install [pkg] [ver]         — fetch packages into cache
///   labelle install assembler <ver>    — download and cache an assembler binary
///   labelle assembler list             — list cached assembler versions
///   labelle upgrade [dir] [pkg] [ver]   — bump versions in project.labelle
///   labelle update [ver]                — self-update the CLI
///   labelle clean [--dry-run]           — prune unused package versions
///   labelle test [dir] [--verbose]      — run inline `test` blocks across the project source tree
const std = @import("std");
const gen = @import("generator");

// Submodules
const help = @import("cli/help.zig");
const init = @import("cli/init.zig");
const install = @import("cli/install.zig");
const upgrade = @import("cli/upgrade.zig");
const update = @import("cli/update.zig");
const clean = @import("cli/clean.zig");
const test_cmd_mod = @import("cli/test.zig");
const config = @import("cli/config.zig");
const compatibility = @import("cli/compatibility.zig");
const lockfile = @import("cli/lockfile.zig");
const cache = @import("cli/cache.zig");
const runner = @import("cli/runner.zig");
const assembler = @import("cli/assembler.zig");
const bake_mod = @import("cli/bake.zig");
const docker = @import("cli/docker.zig");
const serve = @import("cli/serve.zig");
const ios = @import("cli/ios.zig");
const android = @import("cli/android.zig");
const util = @import("cli/util.zig");

const Command = enum { generate, build, run, init_cmd, install_cmd, upgrade_cmd, update_cmd, clean_cmd, ios_cmd, android_cmd, wasm_cmd, help_cmd, version, targets, assembler_cmd, test_cmd };

const SceneResult = enum { not_scene, parsed, needs_next, err };

/// Parse a --scene flag from the current argument string.
/// Returns .parsed with the value set if --scene=<value> was found,
/// .needs_next if bare --scene was found (caller must provide next arg),
/// .not_scene if the arg is unrelated, or .err if the value is empty.
fn parseSceneArg(arg: []const u8) SceneResult {
    if (std.mem.startsWith(u8, arg, "--scene=")) {
        const val = arg["--scene=".len..];
        if (val.len == 0) return .err;
        return .parsed;
    } else if (std.mem.eql(u8, arg, "--scene")) {
        return .needs_next;
    }
    return .not_scene;
}

/// Extract the scene value from a --scene=<value> argument.
fn sceneArgValue(arg: []const u8) []const u8 {
    return arg["--scene=".len..];
}

/// Parse --scene=<name> or --scene <name> from args, consuming the iterator as needed.
/// `args` is `anytype` so tests can pass a `std.process.ArgIteratorGeneral`
/// over a fixed string instead of the platform `ArgIterator`.
fn parseSceneFlag(
    arg: []const u8,
    args: anytype,
    scene_override: *?[]const u8,
    cmd_name: []const u8,
) SceneResult {
    switch (parseSceneArg(arg)) {
        .parsed => {
            scene_override.* = sceneArgValue(arg);
            return .parsed;
        },
        .needs_next => {
            if (args.next()) |val| {
                if (val.len == 0) {
                    std.debug.print("labelle {s}: --scene requires a non-empty value (e.g. --scene main_menu)\n", .{cmd_name});
                    return .err;
                }
                scene_override.* = val;
                return .parsed;
            } else {
                std.debug.print("labelle {s}: --scene requires a value (e.g. --scene main_menu)\n", .{cmd_name});
                return .err;
            }
        },
        .err => {
            std.debug.print("labelle {s}: --scene requires a non-empty value (e.g. --scene=main_menu)\n", .{cmd_name});
            return .err;
        },
        .not_scene => return .not_scene,
    }
}

const ParseError = error{TooManyArguments};

const Platform = gen.Platform;

const ParsedArgs = struct {
    command: Command,
    project_dir: []const u8 = ".",
    // Sized for the longest realistic android invocation:
    //   android run --all-abis --release --keystore k --keystore-pass p
    //               --key-alias a --key-pass kp
    // That's 11 tokens — 16 gives headroom for future flags without
    // risking silent truncation (flagged by the PR #171 review).
    extra_args: [16][]const u8 = undefined,
    extra_count: usize = 0,
    timeout_ns: ?u64 = null,
    scene_override: ?[]const u8 = null,
    platform_override: ?Platform = null,
    optimize_override: ?[]const u8 = null,
    docker: bool = false,
    docker_target: ?[]const u8 = null,
    bake: bool = false,
    // `wasm serve` options. `serve_port` is also read by the wasm
    // branch of `run`; the others only apply to `wasm serve`.
    serve_port: u16 = 8080,
    serve_no_build: bool = false,
    serve_no_open: bool = false,
};

/// Parsed `wasm serve` flags. Returned by `parseWasmServeArgs`; `null`
/// signals a parse error (the helper has already printed a message).
const WasmServeArgs = struct {
    dir: []const u8 = ".",
    port: u16 = 8080,
    no_build: bool = false,
    no_open: bool = false,
};

/// Parse the flags of `labelle wasm serve [dir] [--port <n>]
/// [--no-build] [--no-open]`. `args` is `anytype` so tests can drive
/// it with an in-memory `Args.IteratorGeneral`, mirroring
/// `parseRunArgs`.
fn parseWasmServeArgs(args: anytype) ?WasmServeArgs {
    var result = WasmServeArgs{};
    var dir_set = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--no-build")) {
            result.no_build = true;
        } else if (std.mem.eql(u8, arg, "--no-open")) {
            result.no_open = true;
        } else if (std.mem.startsWith(u8, arg, "--port=") or std.mem.eql(u8, arg, "--port")) {
            const val = if (std.mem.eql(u8, arg, "--port"))
                (args.next() orelse {
                    std.debug.print("labelle wasm serve: --port requires a value (e.g. --port 3000)\n", .{});
                    return null;
                })
            else
                arg["--port=".len..];
            result.port = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("labelle wasm serve: invalid --port value '{s}' (expected 1-65535)\n", .{val});
                return null;
            };
            if (result.port == 0) {
                std.debug.print("labelle wasm serve: --port must be between 1 and 65535\n", .{});
                return null;
            }
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("labelle wasm serve: unknown flag '{s}'\n", .{arg});
            return null;
        } else {
            if (dir_set) {
                std.debug.print("labelle wasm serve: unexpected argument '{s}'\n", .{arg});
                return null;
            }
            result.dir = arg;
            dir_set = true;
        }
    }
    return result;
}

/// Parse a --platform=<value> string into a Platform enum, or null if invalid.
fn parsePlatformValue(val: []const u8) ?Platform {
    return std.meta.stringToEnum(Platform, val);
}

/// Try to parse --platform=<value> from an argument. Returns true if consumed.
fn parsePlatformFlag(arg: []const u8, platform: *?Platform, cmd_name: []const u8) ?bool {
    if (!std.mem.startsWith(u8, arg, "--platform=")) return false;
    const val = arg["--platform=".len..];
    if (val.len == 0) {
        std.debug.print("labelle {s}: --platform requires a value (e.g. --platform=wasm)\n", .{cmd_name});
        return null;
    }
    platform.* = parsePlatformValue(val);
    if (platform.* == null) {
        const expected = comptime blk: {
            const fields = @typeInfo(Platform).@"enum".fields;
            var result: []const u8 = "";
            for (fields, 0..) |f, i| {
                if (i > 0) result = result ++ ", ";
                result = result ++ f.name;
            }
            break :blk result;
        };
        std.debug.print("labelle {s}: unknown platform '{s}' (expected: {s})\n", .{ cmd_name, val, expected });
        return null;
    }
    return true;
}

const valid_optimize_modes = [_][]const u8{ "Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall" };

/// Try to parse --optimize=<value> from an argument. Returns true if consumed,
/// false if this is not an --optimize= flag, and null on error.
fn parseOptimizeFlag(arg: []const u8, optimize: *?[]const u8, cmd_name: []const u8) ?bool {
    if (!std.mem.startsWith(u8, arg, "--optimize=")) return false;
    const val = arg["--optimize=".len..];
    if (val.len == 0) {
        std.debug.print("labelle {s}: --optimize requires a value (e.g. --optimize=ReleaseSafe)\n", .{cmd_name});
        return null;
    }
    for (valid_optimize_modes) |mode| {
        if (std.mem.eql(u8, val, mode)) {
            optimize.* = val;
            return true;
        }
    }
    const expected = comptime blk: {
        var result: []const u8 = "";
        for (valid_optimize_modes, 0..) |mode, i| {
            if (i > 0) result = result ++ ", ";
            result = result ++ mode;
        }
        break :blk result;
    };
    std.debug.print("labelle {s}: unknown optimize mode '{s}' (expected: {s})\n", .{ cmd_name, val, expected });
    return null;
}

/// Parse [dir], --scene, --platform, --optimize, --docker, and --target flags for generate/build commands.
fn parseDirAndScene(args: *std.process.Args.Iterator, cmd_name: []const u8) ?struct { dir: []const u8, scene: ?[]const u8, platform: ?Platform, optimize: ?[]const u8, docker_build: bool, docker_target: ?[]const u8, bake: bool } {
    var dir: []const u8 = ".";
    var dir_set = false;
    var scene: ?[]const u8 = null;
    var platform: ?Platform = null;
    var optimize: ?[]const u8 = null;
    var docker_build = false;
    var docker_target: ?[]const u8 = null;
    var bake = false;

    while (args.next()) |arg| {
        switch (parseSceneFlag(arg, args, &scene, cmd_name)) {
            .parsed => continue,
            .err => return null,
            .not_scene => {},
            .needs_next => unreachable,
        }
        if (parsePlatformFlag(arg, &platform, cmd_name) orelse return null) continue;
        if (parseOptimizeFlag(arg, &optimize, cmd_name) orelse return null) continue;
        if (std.mem.eql(u8, arg, "--docker")) {
            docker_build = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--bake")) {
            bake = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--target=")) {
            const val = arg["--target=".len..];
            if (val.len == 0) {
                std.debug.print("labelle {s}: --target requires a value (e.g. --target=x86_64-windows)\n", .{cmd_name});
                return null;
            }
            docker_target = val;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("labelle {s}: unknown flag '{s}'\n", .{ cmd_name, arg });
            return null;
        } else {
            if (dir_set) {
                std.debug.print("labelle {s}: unexpected argument '{s}'\n", .{ cmd_name, arg });
                return null;
            }
            dir = arg;
            dir_set = true;
        }
    }
    return .{ .dir = dir, .scene = scene, .platform = platform, .optimize = optimize, .docker_build = docker_build, .docker_target = docker_target, .bake = bake };
}

/// Parse [dir], --scene, --timeout, --platform, --optimize, --docker, and --target flags for run command (explicit or implicit).
///
/// A bare `--` token switches the parser into "passthrough" mode: every
/// subsequent token is collected verbatim into `parsed_args.extra_args`
/// without flag interpretation, so callers can forward args to the game
/// binary via `zig build run -- <extras>` (see run_cmd handler).
fn parseRunArgs(args: anytype, cmd_name: []const u8, allow_dir: bool, parsed_args: *ParsedArgs) ?struct { dir: []const u8, scene: ?[]const u8, timeout_ns: ?u64, platform: ?Platform, optimize: ?[]const u8, docker_build: bool, docker_target: ?[]const u8, bake: bool } {
    var dir: []const u8 = ".";
    var dir_set = !allow_dir;
    var scene: ?[]const u8 = null;
    var timeout_ns: ?u64 = null;
    var platform: ?Platform = null;
    var optimize: ?[]const u8 = null;
    var docker_build = false;
    var docker_target: ?[]const u8 = null;
    var bake = false;
    var passthrough = false;

    while (args.next()) |arg| {
        if (passthrough) {
            appendExtraArg(parsed_args, arg) catch return null;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            passthrough = true;
            continue;
        }
        switch (parseSceneFlag(arg, args, &scene, cmd_name)) {
            .parsed => continue,
            .err => return null,
            .not_scene => {},
            .needs_next => unreachable,
        }
        if (parsePlatformFlag(arg, &platform, cmd_name)) |consumed| {
            if (consumed) continue;
        } else return null;
        if (parseOptimizeFlag(arg, &optimize, cmd_name)) |consumed| {
            if (consumed) continue;
        } else return null;
        if (std.mem.eql(u8, arg, "--docker")) {
            docker_build = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--bake")) {
            bake = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--target=")) {
            const val = arg["--target=".len..];
            if (val.len == 0) {
                std.debug.print("labelle {s}: --target requires a value (e.g. --target=x86_64-windows)\n", .{cmd_name});
                return null;
            }
            docker_target = val;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--timeout=")) {
            timeout_ns = util.parseDuration(arg["--timeout=".len..]);
            if (timeout_ns == null) {
                std.debug.print("labelle: invalid --timeout value '{s}'\n", .{arg["--timeout=".len..]});
                std.debug.print("  expected format: --timeout=30s, --timeout=2m\n", .{});
                return null;
            }
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            if (args.next()) |val| {
                timeout_ns = util.parseDuration(val);
                if (timeout_ns == null) {
                    std.debug.print("labelle: invalid --timeout value '{s}'\n", .{val});
                    std.debug.print("  expected format: --timeout 30s, --timeout 2m\n", .{});
                    return null;
                }
            } else {
                std.debug.print("labelle: --timeout requires a value (e.g. --timeout 30s)\n", .{});
                return null;
            }
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("labelle {s}: unknown flag '{s}'\n", .{ cmd_name, arg });
            return null;
        } else {
            if (dir_set) {
                std.debug.print("labelle {s}: unexpected argument '{s}'\n", .{ cmd_name, arg });
                return null;
            }
            dir = arg;
            dir_set = true;
        }
    }
    return .{ .dir = dir, .scene = scene, .timeout_ns = timeout_ns, .platform = platform, .optimize = optimize, .docker_build = docker_build, .docker_target = docker_target, .bake = bake };
}

/// Collect all remaining args into extra_args buffer.
fn collectExtraArgs(args: *std.process.Args.Iterator, parsed_args: *ParsedArgs) ParseError!void {
    while (args.next()) |arg| {
        try appendExtraArg(parsed_args, arg);
    }
}

/// Append one token to `ParsedArgs.extra_args`, surfacing overflow as
/// an error instead of silently dropping it (which would let the
/// subcommand fall through to `project_dir`).
fn appendExtraArg(parsed_args: *ParsedArgs, arg: []const u8) ParseError!void {
    if (parsed_args.extra_count >= parsed_args.extra_args.len) {
        std.debug.print("labelle: too many arguments\n", .{});
        return error.TooManyArguments;
    }
    parsed_args.extra_args[parsed_args.extra_count] = arg;
    parsed_args.extra_count += 1;
}

fn appendRunForwardedArgs(argv: *std.ArrayList([]const u8), allocator: std.mem.Allocator, parsed_args: *const ParsedArgs) !void {
    if (parsed_args.extra_count == 0) return;
    try argv.append(allocator, "--");
    for (parsed_args.extra_args[0..parsed_args.extra_count]) |extra| {
        try argv.append(allocator, extra);
    }
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

pub fn main(proc_init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize the process-wide Io for both the assembler's helpers
    // (used via `gen.*`) and the CLI's own filesystem/env helpers. Must
    // happen before any submodule reaches for `globalIo()`/`globalEnviron()`.
    gen.initGlobalIo(proc_init.minimal);
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
        } else if (std.mem.eql(u8, first, "init")) {
            parsed_args.command = .init_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "install")) {
            parsed_args.command = .install_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "upgrade")) {
            parsed_args.command = .upgrade_cmd;
            if (args.next()) |next_arg| {
                if (std.mem.eql(u8, next_arg, "core") or
                    std.mem.eql(u8, next_arg, "engine") or
                    std.mem.eql(u8, next_arg, "gfx") or
                    std.mem.eql(u8, next_arg, "cli") or
                    std.mem.eql(u8, next_arg, "labelle") or
                    std.mem.eql(u8, next_arg, "assembler") or
                    std.mem.eql(u8, next_arg, "all"))
                {
                    try appendExtraArg(&parsed_args, next_arg);
                } else {
                    parsed_args.project_dir = next_arg;
                }
            }
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "update")) {
            parsed_args.command = .update_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "clean")) {
            parsed_args.command = .clean_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "test")) {
            parsed_args.command = .test_cmd;
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
            // `labelle wasm <subcommand>` — only `serve` exists today.
            const sub = args.next();
            if (sub == null or !std.mem.eql(u8, sub.?, "serve")) {
                if (sub) |s| {
                    std.debug.print("labelle wasm: unknown subcommand '{s}'\n", .{s});
                } else {
                    std.debug.print("labelle wasm: missing subcommand\n", .{});
                }
                std.debug.print("  usage: labelle wasm serve [dir] [--port <n>] [--no-build] [--no-open]\n", .{});
                return;
            }
            parsed_args.command = .wasm_cmd;
            const result = parseWasmServeArgs(&args) orelse return;
            parsed_args.project_dir = result.dir;
            parsed_args.serve_port = result.port;
            parsed_args.serve_no_build = result.no_build;
            parsed_args.serve_no_open = result.no_open;
            // `wasm serve` always builds/serves the WASM target.
            parsed_args.platform_override = .wasm;
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
        .install_cmd => return install.cmdInstall(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .update_cmd => return update.cmdUpdate(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .clean_cmd => return clean.cmdClean(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .test_cmd => return test_cmd_mod.cmdTest(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .assembler_cmd => return handleAssemblerCmd(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
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
            const project_cfg: ?gen.AndroidConfig = blk: {
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
            std.debug.print("\n  No project.labelle found in '{s}'.\n\n", .{project_dir});
            std.debug.print("  To create a new project:\n", .{});
            std.debug.print("    labelle init <name>\n\n", .{});
            std.debug.print("  To see all commands:\n", .{});
            std.debug.print("    labelle help\n\n", .{});
        }
        return;
    };

    // Apply --scene override
    if (parsed_args.scene_override) |scene| {
        parsed.initial_scene = scene;
    }

    // Apply --platform override
    if (parsed_args.platform_override) |platform| {
        parsed.platform = platform;
    }

    // `labelle ios` always implies sokol + ios platform
    if (command == .ios_cmd) {
        parsed.platform = .ios;
        parsed.backend = .sokol;
    }

    // `labelle android` always implies sokol + android platform
    if (command == .android_cmd) {
        parsed.platform = .android;
        parsed.backend = .sokol;
    }

    // Upgrade modifies project.labelle in the project directory
    if (command == .upgrade_cmd) {
        return upgrade.cmdUpgrade(allocator, project_dir, parsed, parsed_args.extra_args[0..parsed_args.extra_count]);
    }

    // `labelle wasm serve --no-build` — skip the generate+build
    // pipeline entirely and serve the existing build output. The web
    // dir lives under the wasm target subdir (`.labelle/<backend>_wasm/`).
    if (command == .wasm_cmd and parsed_args.serve_no_build) {
        const wasm_target = try std.fmt.allocPrint(allocator, "{s}_wasm", .{@tagName(parsed.backend)});
        defer allocator.free(wasm_target);
        const web_dir = try std.fs.path.join(allocator, &.{
            project_dir, ".labelle", wasm_target, "zig-out", "web",
        });
        defer allocator.free(web_dir);
        if (std.Io.Dir.cwd().access(config.globalIo(), web_dir, .{})) |_| {} else |_| {
            std.debug.print(
                "labelle wasm serve: no existing WASM build at '{s}'\n" ++
                    "  run `labelle wasm serve` (without --no-build) first.\n",
                .{web_dir},
            );
            return error.BuildFailed;
        }
        return serve.serveAndOpen(allocator, web_dir, parsed_args.serve_port, !parsed_args.serve_no_open);
    }

    // Ensure package cache is populated
    try cache.ensureCache(allocator, parsed);

    // Validate version compatibility
    compatibility.validateCompatibility(parsed);

    // Resolve GUI plugin (reads gui.labelle manifest from plugin directory)
    try gen.resolveGuiPlugin(arena.allocator(), &parsed, project_dir);

    // Generate into .labelle/
    const output_dir = try std.fs.path.join(allocator, &.{ project_dir, ".labelle" });
    defer allocator.free(output_dir);

    const gui_label: []const u8 = if (parsed.resolved_gui) |gui| gui.name else "none";
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

    // Route through the standalone labelle-assembler binary.
    // Resolution order: LABELLE_ASSEMBLER env var > assembler_version
    // in project.labelle. If neither is set, auto-downloads the default version.
    const asm_path = try assembler.resolveAssembler(allocator, project_dir) orelse
        try assembler.resolveDefault(allocator);
    defer allocator.free(asm_path);
    std.debug.print("  using assembler: {s}\n", .{asm_path});
    try assembler.spawnGenerate(
        allocator,
        asm_path,
        project_dir,
        parsed_args.scene_override,
        parsed.platform,
        parsed.backend,
    );

    // Target subdir: .labelle/raylib_desktop/, etc.
    const target_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ @tagName(parsed.backend), @tagName(parsed.platform) });
    defer allocator.free(target_name);
    const target_dir = try std.fs.path.join(allocator, &.{ output_dir, target_name });
    defer allocator.free(target_dir);

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
        try runner.fixFingerprints(allocator, output_dir);
    } else {
        const tests_dir = try std.fs.path.join(allocator, &.{ output_dir, "tests" });
        defer allocator.free(tests_dir);
        const tests_build_zig = try std.fs.path.join(allocator, &.{ tests_dir, "build.zig" });
        defer allocator.free(tests_build_zig);
        if (std.Io.Dir.cwd().access(config.globalIo(), tests_build_zig, .{})) |_| {
            try runner.fixFingerprint(allocator, tests_dir);
        } else |_| {}
    }
    try lockfile.writeLockFile(allocator, project_dir, parsed);
    std.debug.print("  generated .labelle/{s}/\n", .{target_name});

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

    var zig_args: std.ArrayList([]const u8) = .empty;
    defer zig_args.deinit(allocator);
    try zig_args.appendSlice(allocator, &.{ "zig", "build" });
    if (optimize_flag) |flag| try zig_args.append(allocator, flag);

    if (parsed_args.docker) {
        std.debug.print("labelle: building via docker...\n", .{});
        const docker_exit = try docker.runBuild(allocator, target_dir, parsed.platform, parsed_args.docker_target, effective_optimize);
        if (docker_exit != 0) {
            std.debug.print("labelle: docker build failed (exit code {d})\n", .{docker_exit});
            return error.BuildFailed;
        }
    } else {
        std.debug.print("labelle: building...\n", .{});
        const build_result = try runner.runZig(allocator, target_dir, zig_args.items);
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

    if (command == .build) return;

    // Run
    if (parsed.platform == .wasm) {
        // WASM: serve via local HTTP server + open browser
        const web_dir = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "web" });
        defer allocator.free(web_dir);
        try serve.serveAndOpen(allocator, web_dir, parsed_args.serve_port, !parsed_args.serve_no_open);
    } else if (parsed.platform == .ios) {
        // iOS: deploy to simulator
        std.debug.print("labelle: deploying to iOS Simulator...\n", .{});
        try ios.deployToSimulator(allocator, target_dir, parsed);
    } else if (parsed.platform == .android) {
        // Android: deploy to device/emulator
        std.debug.print("labelle: deploying to Android...\n", .{});
        try android.deployToDevice(allocator, target_dir, parsed, false, .{});
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
        // When --docker was used, run the built binary directly instead of
        // calling `zig build run` (local Zig may be broken).
        if (parsed_args.docker) {
            // Cross-compiled binaries can't be run on the host
            if (parsed_args.docker_target) |t| {
                std.debug.print("labelle: cannot run cross-compiled binary (target: {s})\n", .{t});
                std.debug.print("  binary is at: {s}/zig-out/bin/\n", .{target_dir});
                return;
            }
            const bin_path = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "bin", "game" });
            defer allocator.free(bin_path);
            var run_args: std.ArrayList([]const u8) = .empty;
            defer run_args.deinit(allocator);
            try run_args.append(allocator, bin_path);
            try appendRunForwardedArgs(&run_args, allocator, &parsed_args);
            const run_result = try runner.runZigInherit(allocator, project_dir, run_args.items, timeout_ns);
            if (run_result != 0) {
                std.debug.print("\nlabelle: process exited with code {d}\n", .{run_result});
            }
        } else {
            try zig_args.append(allocator, "run");
            try appendRunForwardedArgs(&zig_args, allocator, &parsed_args);
            const run_result = try runner.runZigInherit(allocator, target_dir, zig_args.items, timeout_ns);
            if (run_result != 0) {
                std.debug.print("\nlabelle: process exited with code {d}\n", .{run_result});
            }
        }
    }
}

// --- Tests ---

const expect = @import("zspec").expect;

test {
    @import("zspec").runAll(@This());
}

pub const ParseSceneArg = struct {
    pub const with_equals_value = struct {
        test "returns parsed for --scene=main_menu" {
            try expect.equal(parseSceneArg("--scene=main_menu"), .parsed);
        }

        test "returns parsed for --scene=x" {
            try expect.equal(parseSceneArg("--scene=x"), .parsed);
        }
    };

    pub const with_empty_equals = struct {
        test "returns err for --scene=" {
            try expect.equal(parseSceneArg("--scene="), .err);
        }
    };

    pub const bare_flag = struct {
        test "returns needs_next for --scene" {
            try expect.equal(parseSceneArg("--scene"), .needs_next);
        }
    };

    pub const unrelated_flags = struct {
        test "returns not_scene for --timeout=5s" {
            try expect.equal(parseSceneArg("--timeout=5s"), .not_scene);
        }

        test "returns not_scene for --verbose" {
            try expect.equal(parseSceneArg("--verbose"), .not_scene);
        }

        test "returns not_scene for positional arg" {
            try expect.equal(parseSceneArg("mydir"), .not_scene);
        }
    };
};

pub const SceneArgValue = struct {
    test "extracts value from --scene=main_menu" {
        try std.testing.expectEqualStrings("main_menu", sceneArgValue("--scene=main_menu"));
    }

    test "extracts value from --scene=intro" {
        try std.testing.expectEqualStrings("intro", sceneArgValue("--scene=intro"));
    }
};

pub const ParseOptimizeFlagSpec = struct {
    pub const valid_modes = struct {
        test "parses all valid modes" {
            inline for (valid_optimize_modes) |mode| {
                var opt: ?[]const u8 = null;
                const arg = "--optimize=" ++ mode;
                try expect.equal(parseOptimizeFlag(arg, &opt, "build"), true);
                try std.testing.expectEqualStrings(mode, opt.?);
            }
        }
    };

    pub const invalid_modes = struct {
        test "returns null for empty value" {
            var opt: ?[]const u8 = null;
            try expect.equal(parseOptimizeFlag("--optimize=", &opt, "build"), null);
        }
        test "returns null for unknown mode" {
            var opt: ?[]const u8 = null;
            try expect.equal(parseOptimizeFlag("--optimize=Fast", &opt, "build"), null);
        }
    };

    pub const not_optimize = struct {
        test "returns false for unrelated flag" {
            var opt: ?[]const u8 = null;
            try expect.equal(parseOptimizeFlag("--platform=wasm", &opt, "build"), false);
        }
        test "returns false for positional arg" {
            var opt: ?[]const u8 = null;
            try expect.equal(parseOptimizeFlag("my-game", &opt, "build"), false);
        }
    };
};

// Surface inline-test specs from the `test` subcommand module so
// `zspec.runAll(@This())` walks into them. Without these re-exports
// zspec only sees the `pub const` namespaces declared directly in
// cli.zig and would skip the test_cmd_mod's nested spec structs.
pub const TestCmdIsSkipDirSpec = test_cmd_mod.IsSkipDirSpec;
pub const TestCmdFileHasTestBlockSpec = test_cmd_mod.FileHasTestBlockSpec;

pub const ParsePlatformValueSpec = struct {
    pub const valid_platforms = struct {
        test "parses desktop" {
            try expect.equal(parsePlatformValue("desktop"), Platform.desktop);
        }
        test "parses wasm" {
            try expect.equal(parsePlatformValue("wasm"), Platform.wasm);
        }
        test "parses ios" {
            try expect.equal(parsePlatformValue("ios"), Platform.ios);
        }
        test "parses android" {
            try expect.equal(parsePlatformValue("android"), Platform.android);
        }
    };

    pub const invalid_platforms = struct {
        test "returns null for empty string" {
            try expect.equal(parsePlatformValue(""), null);
        }
        test "returns null for unknown value" {
            try expect.equal(parsePlatformValue("windows"), null);
        }
    };
};

/// Build an in-memory ArgIterator over a fixed argv-like string for
/// tests of `parseRunArgs`. `parseRunArgs` takes `anytype` so it
/// accepts both the platform `std.process.Args.Iterator` and
/// `std.process.Args.IteratorGeneral` returned here.
///
/// 0.16 moved `std.process.ArgIteratorGeneral` to
/// `std.process.Args.IteratorGeneral`.
fn testIter(line: []const u8) std.process.Args.IteratorGeneral(.{}) {
    return std.process.Args.IteratorGeneral(.{}).init(std.testing.allocator, line) catch unreachable;
}

pub const ParseRunArgsPassthroughSpec = struct {
    pub const no_separator = struct {
        test "empty extras when no `--` token" {
            var iter = testIter("");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            const result = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try std.testing.expectEqualStrings(".", result.dir);
            try expect.equal(pa.extra_count, @as(usize, 0));
        }

        test "scene flag without `--` does not enter passthrough" {
            var iter = testIter("--scene=main");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            const result = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("main", result.scene.?);
            try expect.equal(pa.extra_count, @as(usize, 0));
        }
    };

    pub const single_trailing_arg = struct {
        test "one token after `--` lands in extras" {
            var iter = testIter("-- --preview-mode");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            const result = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try std.testing.expectEqualStrings(".", result.dir);
            try expect.equal(pa.extra_count, @as(usize, 1));
            try std.testing.expectEqualStrings("--preview-mode", pa.extra_args[0]);
        }
    };

    pub const multiple_trailing_args = struct {
        test "multiple tokens after `--` preserved in order" {
            var iter = testIter("-- --preview-mode 127.0.0.1:54321");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            _ = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try expect.equal(pa.extra_count, @as(usize, 2));
            try std.testing.expectEqualStrings("--preview-mode", pa.extra_args[0]);
            try std.testing.expectEqualStrings("127.0.0.1:54321", pa.extra_args[1]);
        }

        test "inner `--` after first `--` is a passthrough token, not a re-trigger" {
            // Once the parser is in passthrough mode it stays there; a
            // second `--` is forwarded verbatim. zig build run uses the
            // first `--` as separator and forwards the rest, so an inner
            // `--` reaches the game unchanged.
            var iter = testIter("-- --foo -- --bar");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            _ = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try expect.equal(pa.extra_count, @as(usize, 3));
            try std.testing.expectEqualStrings("--foo", pa.extra_args[0]);
            try std.testing.expectEqualStrings("--", pa.extra_args[1]);
            try std.testing.expectEqualStrings("--bar", pa.extra_args[2]);
        }
    };

    pub const mixed_labelle_flags_and_passthrough = struct {
        test "labelle flags before `--` consumed, after `--` forwarded" {
            var iter = testIter("mydir --scene=main -- --foo bar");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            const result = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("mydir", result.dir);
            try std.testing.expectEqualStrings("main", result.scene.?);
            try expect.equal(pa.extra_count, @as(usize, 2));
            try std.testing.expectEqualStrings("--foo", pa.extra_args[0]);
            try std.testing.expectEqualStrings("bar", pa.extra_args[1]);
        }

        test "positional dir after `--` is forwarded, not parsed as dir" {
            // After `--` everything is opaque, so a bare word doesn't
            // collide with the project_dir slot.
            var iter = testIter("-- somedir");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            const result = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try std.testing.expectEqualStrings(".", result.dir);
            try expect.equal(pa.extra_count, @as(usize, 1));
            try std.testing.expectEqualStrings("somedir", pa.extra_args[0]);
        }
    };
};

pub const ParseWasmServeArgsSpec = struct {
    pub const defaults = struct {
        test "no args yields port 8080 and all flags off" {
            var iter = testIter("");
            defer iter.deinit();
            const result = parseWasmServeArgs(&iter) orelse return error.TestFailed;
            try expect.equal(result.port, @as(u16, 8080));
            try expect.equal(result.no_build, false);
            try expect.equal(result.no_open, false);
            try std.testing.expectEqualStrings(".", result.dir);
        }
    };

    pub const port_flag = struct {
        test "--port=3000 sets the port" {
            var iter = testIter("--port=3000");
            defer iter.deinit();
            const result = parseWasmServeArgs(&iter) orelse return error.TestFailed;
            try expect.equal(result.port, @as(u16, 3000));
        }

        test "--port 3000 (space form) sets the port" {
            var iter = testIter("--port 3000");
            defer iter.deinit();
            const result = parseWasmServeArgs(&iter) orelse return error.TestFailed;
            try expect.equal(result.port, @as(u16, 3000));
        }

        test "non-numeric --port value is rejected" {
            var iter = testIter("--port abc");
            defer iter.deinit();
            try expect.equal(parseWasmServeArgs(&iter), null);
        }

        test "out-of-range --port value is rejected" {
            var iter = testIter("--port 99999");
            defer iter.deinit();
            try expect.equal(parseWasmServeArgs(&iter), null);
        }

        test "--port 0 is rejected" {
            var iter = testIter("--port 0");
            defer iter.deinit();
            try expect.equal(parseWasmServeArgs(&iter), null);
        }
    };

    pub const boolean_flags = struct {
        test "--no-build sets no_build" {
            var iter = testIter("--no-build");
            defer iter.deinit();
            const result = parseWasmServeArgs(&iter) orelse return error.TestFailed;
            try expect.equal(result.no_build, true);
        }

        test "--no-open sets no_open" {
            var iter = testIter("--no-open");
            defer iter.deinit();
            const result = parseWasmServeArgs(&iter) orelse return error.TestFailed;
            try expect.equal(result.no_open, true);
        }

        test "flags combine with a custom port and dir" {
            var iter = testIter("mygame --port 5000 --no-build --no-open");
            defer iter.deinit();
            const result = parseWasmServeArgs(&iter) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("mygame", result.dir);
            try expect.equal(result.port, @as(u16, 5000));
            try expect.equal(result.no_build, true);
            try expect.equal(result.no_open, true);
        }
    };

    pub const rejects_bad_input = struct {
        test "unknown flag is rejected" {
            var iter = testIter("--watch");
            defer iter.deinit();
            try expect.equal(parseWasmServeArgs(&iter), null);
        }

        test "a second positional arg is rejected" {
            var iter = testIter("dir1 dir2");
            defer iter.deinit();
            try expect.equal(parseWasmServeArgs(&iter), null);
        }
    };
};

pub const AppendRunForwardedArgsSpec = struct {
    test "skips separator when there are no forwarded args" {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(std.testing.allocator);
        var pa = ParsedArgs{ .command = .run };

        try appendRunForwardedArgs(&argv, std.testing.allocator, &pa);
        try expect.equal(argv.items.len, @as(usize, 0));
    }

    test "appends separator and all forwarded args in order" {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(std.testing.allocator);
        var pa = ParsedArgs{ .command = .run };
        try appendExtraArg(&pa, "--preview-mode");
        try appendExtraArg(&pa, "127.0.0.1:54321");

        try appendRunForwardedArgs(&argv, std.testing.allocator, &pa);
        try expect.equal(argv.items.len, @as(usize, 3));
        try std.testing.expectEqualStrings("--", argv.items[0]);
        try std.testing.expectEqualStrings("--preview-mode", argv.items[1]);
        try std.testing.expectEqualStrings("127.0.0.1:54321", argv.items[2]);
    }
};
