/// labelle-cli — reads project.labelle and generates/builds/runs the assembled game.
///
/// Usage:
///   labelle generate [dir] [--scene=name] [--optimize=MODE] — generate .labelle/ assembler files
///   labelle run [dir] [--timeout=30s] [--scene=name] [--optimize=MODE] — generate + build + run
///   labelle build [dir] [--scene=name] [--optimize=MODE] — generate + build (no run)
///   labelle [dir]                       — alias for `run`
///   labelle init <name> [dir]           — scaffold a new project
///   labelle install [pkg] [ver]         — fetch packages into cache
///   labelle upgrade [dir] [pkg] [ver]   — bump versions in project.labelle
///   labelle update [ver]                — self-update the CLI
///   labelle clean [--dry-run]           — prune unused package versions
const std = @import("std");
const gen = @import("generator");

// Submodules
const help = @import("cli/help.zig");
const init = @import("cli/init.zig");
const install = @import("cli/install.zig");
const upgrade = @import("cli/upgrade.zig");
const update = @import("cli/update.zig");
const clean = @import("cli/clean.zig");
const config = @import("cli/config.zig");
const compatibility = @import("cli/compatibility.zig");
const lockfile = @import("cli/lockfile.zig");
const cache = @import("cli/cache.zig");
const runner = @import("cli/runner.zig");
const docker = @import("cli/docker.zig");
const serve = @import("cli/serve.zig");
const ios = @import("cli/ios.zig");
const util = @import("cli/util.zig");

const Command = enum { generate, build, run, init_cmd, install_cmd, upgrade_cmd, update_cmd, clean_cmd, ios_cmd, help_cmd, version, targets };

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
fn parseSceneFlag(
    arg: []const u8,
    args: *std.process.ArgIterator,
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
    extra_args: [8][]const u8 = undefined,
    extra_count: usize = 0,
    timeout_ns: ?u64 = null,
    scene_override: ?[]const u8 = null,
    platform_override: ?Platform = null,
    optimize_override: ?[]const u8 = null,
    docker: bool = false,
    docker_target: ?[]const u8 = null,
};

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
fn parseDirAndScene(args: *std.process.ArgIterator, cmd_name: []const u8) ?struct { dir: []const u8, scene: ?[]const u8, platform: ?Platform, optimize: ?[]const u8, docker_build: bool, docker_target: ?[]const u8 } {
    var dir: []const u8 = ".";
    var dir_set = false;
    var scene: ?[]const u8 = null;
    var platform: ?Platform = null;
    var optimize: ?[]const u8 = null;
    var docker_build = false;
    var docker_target: ?[]const u8 = null;

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
    return .{ .dir = dir, .scene = scene, .platform = platform, .optimize = optimize, .docker_build = docker_build, .docker_target = docker_target };
}

/// Parse [dir], --scene, --timeout, --platform, --optimize, --docker, and --target flags for run command (explicit or implicit).
fn parseRunArgs(args: *std.process.ArgIterator, cmd_name: []const u8, allow_dir: bool) ?struct { dir: []const u8, scene: ?[]const u8, timeout_ns: ?u64, platform: ?Platform, optimize: ?[]const u8, docker_build: bool, docker_target: ?[]const u8 } {
    var dir: []const u8 = ".";
    var dir_set = !allow_dir;
    var scene: ?[]const u8 = null;
    var timeout_ns: ?u64 = null;
    var platform: ?Platform = null;
    var optimize: ?[]const u8 = null;
    var docker_build = false;
    var docker_target: ?[]const u8 = null;

    while (args.next()) |arg| {
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
    return .{ .dir = dir, .scene = scene, .timeout_ns = timeout_ns, .platform = platform, .optimize = optimize, .docker_build = docker_build, .docker_target = docker_target };
}

/// Collect all remaining args into extra_args buffer.
fn collectExtraArgs(args: *std.process.ArgIterator, extra_args: *[8][]const u8, extra_count: *usize) ParseError!void {
    while (args.next()) |arg| {
        if (extra_count.* >= extra_args.len) {
            std.debug.print("labelle: too many arguments\n", .{});
            return error.TooManyArguments;
        }
        extra_args[extra_count.*] = arg;
        extra_count.* += 1;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
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
        } else if (std.mem.eql(u8, first, "run")) {
            parsed_args.command = .run;
            const result = parseRunArgs(&args, "run", true) orelse return;
            parsed_args.project_dir = result.dir;
            parsed_args.scene_override = result.scene;
            parsed_args.timeout_ns = result.timeout_ns;
            parsed_args.platform_override = result.platform;
            parsed_args.optimize_override = result.optimize;
            parsed_args.docker = result.docker_build;
            parsed_args.docker_target = result.docker_target;
        } else if (std.mem.eql(u8, first, "init")) {
            parsed_args.command = .init_cmd;
            try collectExtraArgs(&args, &parsed_args.extra_args, &parsed_args.extra_count);
        } else if (std.mem.eql(u8, first, "install")) {
            parsed_args.command = .install_cmd;
            try collectExtraArgs(&args, &parsed_args.extra_args, &parsed_args.extra_count);
        } else if (std.mem.eql(u8, first, "upgrade")) {
            parsed_args.command = .upgrade_cmd;
            if (args.next()) |next_arg| {
                if (std.mem.eql(u8, next_arg, "core") or
                    std.mem.eql(u8, next_arg, "engine") or
                    std.mem.eql(u8, next_arg, "gfx") or
                    std.mem.eql(u8, next_arg, "cli") or
                    std.mem.eql(u8, next_arg, "labelle") or
                    std.mem.eql(u8, next_arg, "all"))
                {
                    parsed_args.extra_args[parsed_args.extra_count] = next_arg;
                    parsed_args.extra_count += 1;
                } else {
                    parsed_args.project_dir = next_arg;
                }
            }
            try collectExtraArgs(&args, &parsed_args.extra_args, &parsed_args.extra_count);
        } else if (std.mem.eql(u8, first, "update")) {
            parsed_args.command = .update_cmd;
            try collectExtraArgs(&args, &parsed_args.extra_args, &parsed_args.extra_count);
        } else if (std.mem.eql(u8, first, "clean")) {
            parsed_args.command = .clean_cmd;
            try collectExtraArgs(&args, &parsed_args.extra_args, &parsed_args.extra_count);
        } else if (std.mem.eql(u8, first, "ios")) {
            parsed_args.command = .ios_cmd;
            // First non-flag arg that isn't a subcommand is the project dir
            while (args.next()) |arg| {
                if (std.mem.startsWith(u8, arg, "-") or
                    std.mem.eql(u8, arg, "build") or
                    std.mem.eql(u8, arg, "xcode") or
                    std.mem.eql(u8, arg, "run"))
                {
                    if (parsed_args.extra_count < parsed_args.extra_args.len) {
                        parsed_args.extra_args[parsed_args.extra_count] = arg;
                        parsed_args.extra_count += 1;
                    }
                } else {
                    parsed_args.project_dir = arg;
                }
            }
        } else if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
            parsed_args.command = .help_cmd;
        } else if (std.mem.eql(u8, first, "version") or std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-v")) {
            parsed_args.command = .version;
        } else if (std.mem.eql(u8, first, "targets")) {
            parsed_args.command = .targets;
        } else {
            // No command — treat as project dir, default to run
            const result = parseRunArgs(&args, "run", false) orelse return;
            parsed_args.project_dir = first;
            parsed_args.scene_override = result.scene;
            parsed_args.timeout_ns = result.timeout_ns;
            parsed_args.platform_override = result.platform;
            parsed_args.optimize_override = result.optimize;
            parsed_args.docker = result.docker_build;
            parsed_args.docker_target = result.docker_target;
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
        else => {},
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

    // Upgrade modifies project.labelle in the project directory
    if (command == .upgrade_cmd) {
        return upgrade.cmdUpgrade(allocator, project_dir, parsed, parsed_args.extra_args[0..parsed_args.extra_count]);
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

    try gen.generate(allocator, parsed, output_dir, project_dir);

    // Target subdir: .labelle/raylib_desktop/, etc.
    const target_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ @tagName(parsed.backend), @tagName(parsed.platform) });
    defer allocator.free(target_name);
    const target_dir = try std.fs.path.join(allocator, &.{ output_dir, target_name });
    defer allocator.free(target_dir);

    // fixFingerprint runs `zig build` locally to discover the correct hash.
    // Skip it for docker builds since the local Zig toolchain may be broken.
    if (!parsed_args.docker) try runner.fixFingerprint(allocator, target_dir);
    try lockfile.writeLockFile(allocator, project_dir, parsed);
    std.debug.print("  generated .labelle/{s}/\n", .{target_name});

    if (command == .generate) return;

    // `labelle ios` subcommand — handles its own build/xcode/run
    if (command == .ios_cmd) {
        return ios.handleIos(allocator, parsed_args.extra_args[0..parsed_args.extra_count], parsed, target_dir);
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

    var zig_args: std.ArrayList([]const u8) = .{};
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
            .Exited => |code| if (code != 0) {
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
        try serve.serveAndOpen(allocator, web_dir, 8080);
    } else if (parsed.platform == .ios) {
        // iOS: deploy to simulator
        std.debug.print("labelle: deploying to iOS Simulator...\n", .{});
        try ios.deployToSimulator(allocator, target_dir, parsed);
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
            const run_result = try runner.runZigInherit(allocator, project_dir, &.{bin_path}, timeout_ns);
            if (run_result != 0) {
                std.debug.print("\nlabelle: process exited with code {d}\n", .{run_result});
            }
        } else {
            try zig_args.append(allocator, "run");
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
