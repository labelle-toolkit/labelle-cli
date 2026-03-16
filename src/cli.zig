/// labelle-cli — reads project.labelle and generates/builds/runs the assembled game.
///
/// Usage:
///   labelle generate [dir]              — generate .labelle/ assembler files
///   labelle run [dir] [--timeout=30s] [--scene=name] — generate + build + run
///   labelle build [dir] [--scene=name]  — generate + build (no run)
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
const util = @import("cli/util.zig");

const Command = enum { generate, build, run, init_cmd, install_cmd, upgrade_cmd, update_cmd, clean_cmd, help_cmd, version, targets };

const SceneResult = enum { not_scene, parsed, err };

/// Parse --scene=<name> or --scene <name> from an argument.
/// Returns .parsed if the flag was consumed (value stored in scene_override),
/// .not_scene if the arg is not a --scene flag, or .err if the flag is malformed.
fn parseSceneFlag(
    arg: []const u8,
    args: *std.process.ArgIterator,
    scene_override: *?[]const u8,
    cmd_name: []const u8,
) SceneResult {
    if (std.mem.startsWith(u8, arg, "--scene=")) {
        const val = arg["--scene=".len..];
        if (val.len == 0) {
            std.debug.print("labelle {s}: --scene requires a non-empty value (e.g. --scene=main_menu)\n", .{cmd_name});
            return .err;
        }
        scene_override.* = val;
        return .parsed;
    } else if (std.mem.eql(u8, arg, "--scene")) {
        if (args.next()) |val| {
            scene_override.* = val;
            return .parsed;
        } else {
            std.debug.print("labelle {s}: --scene requires a value (e.g. --scene main_menu)\n", .{cmd_name});
            return .err;
        }
    }
    return .not_scene;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip(); // skip program name

    // Parse command and project dir
    var command: Command = .run;
    var project_dir: []const u8 = ".";
    var dir_set = false;
    var extra_args: [8][]const u8 = undefined;
    var extra_count: usize = 0;
    var timeout_ns: ?u64 = null;
    var scene_override: ?[]const u8 = null;

    const first_arg = args.next();
    if (first_arg == null) {
        return help.printHelp();
    }

    if (first_arg) |first| {
        if (std.mem.eql(u8, first, "generate")) {
            command = .generate;
            while (args.next()) |arg| {
                switch (parseSceneFlag(arg, &args, &scene_override, "generate")) {
                    .parsed => continue,
                    .err => return,
                    .not_scene => {},
                }
                if (std.mem.startsWith(u8, arg, "--")) {
                    std.debug.print("labelle generate: unknown flag '{s}'\n", .{arg});
                    return;
                } else {
                    if (dir_set) {
                        std.debug.print("labelle generate: unexpected argument '{s}'\n", .{arg});
                        return;
                    }
                    project_dir = arg;
                    dir_set = true;
                }
            }
        } else if (std.mem.eql(u8, first, "build")) {
            command = .build;
            while (args.next()) |arg| {
                switch (parseSceneFlag(arg, &args, &scene_override, "build")) {
                    .parsed => continue,
                    .err => return,
                    .not_scene => {},
                }
                if (std.mem.startsWith(u8, arg, "--")) {
                    std.debug.print("labelle build: unknown flag '{s}'\n", .{arg});
                    return;
                } else {
                    if (dir_set) {
                        std.debug.print("labelle build: unexpected argument '{s}'\n", .{arg});
                        return;
                    }
                    project_dir = arg;
                    dir_set = true;
                }
            }
        } else if (std.mem.eql(u8, first, "run")) {
            command = .run;
            // Parse optional [dir], --timeout, and --scene flags
            while (args.next()) |arg| {
                switch (parseSceneFlag(arg, &args, &scene_override, "run")) {
                    .parsed => continue,
                    .err => return,
                    .not_scene => {},
                }
                if (std.mem.startsWith(u8, arg, "--timeout=")) {
                    timeout_ns = util.parseDuration(arg["--timeout=".len..]);
                    if (timeout_ns == null) {
                        std.debug.print("labelle: invalid --timeout value '{s}'\n", .{arg["--timeout=".len..]});
                        std.debug.print("  expected format: --timeout=30s, --timeout=2m\n", .{});
                        return;
                    }
                } else if (std.mem.eql(u8, arg, "--timeout")) {
                    if (args.next()) |val| {
                        timeout_ns = util.parseDuration(val);
                        if (timeout_ns == null) {
                            std.debug.print("labelle: invalid --timeout value '{s}'\n", .{val});
                            std.debug.print("  expected format: --timeout 30s, --timeout 2m\n", .{});
                            return;
                        }
                    } else {
                        std.debug.print("labelle: --timeout requires a value (e.g. --timeout 30s)\n", .{});
                        return;
                    }
                } else if (std.mem.startsWith(u8, arg, "--")) {
                    std.debug.print("labelle run: unknown flag '{s}'\n", .{arg});
                    return;
                } else {
                    if (dir_set) {
                        std.debug.print("labelle run: unexpected argument '{s}'\n", .{arg});
                        return;
                    }
                    project_dir = arg;
                    dir_set = true;
                }
            }
        } else if (std.mem.eql(u8, first, "init")) {
            command = .init_cmd;
            while (args.next()) |arg| {
                if (extra_count >= extra_args.len) {
                    std.debug.print("labelle: too many arguments\n", .{});
                    return error.TooManyArguments;
                }
                extra_args[extra_count] = arg;
                extra_count += 1;
            }
        } else if (std.mem.eql(u8, first, "install")) {
            command = .install_cmd;
            while (args.next()) |arg| {
                if (extra_count >= extra_args.len) {
                    std.debug.print("labelle: too many arguments\n", .{});
                    return error.TooManyArguments;
                }
                extra_args[extra_count] = arg;
                extra_count += 1;
            }
        } else if (std.mem.eql(u8, first, "upgrade")) {
            command = .upgrade_cmd;
            if (args.next()) |next_arg| {
                if (std.mem.eql(u8, next_arg, "core") or
                    std.mem.eql(u8, next_arg, "engine") or
                    std.mem.eql(u8, next_arg, "gfx") or
                    std.mem.eql(u8, next_arg, "cli") or
                    std.mem.eql(u8, next_arg, "labelle") or
                    std.mem.eql(u8, next_arg, "all"))
                {
                    extra_args[extra_count] = next_arg;
                    extra_count += 1;
                } else {
                    project_dir = next_arg;
                }
            }
            while (args.next()) |arg| {
                if (extra_count >= extra_args.len) {
                    std.debug.print("labelle: too many arguments\n", .{});
                    return error.TooManyArguments;
                }
                extra_args[extra_count] = arg;
                extra_count += 1;
            }
        } else if (std.mem.eql(u8, first, "update")) {
            command = .update_cmd;
            while (args.next()) |arg| {
                if (extra_count >= extra_args.len) {
                    std.debug.print("labelle: too many arguments\n", .{});
                    return error.TooManyArguments;
                }
                extra_args[extra_count] = arg;
                extra_count += 1;
            }
        } else if (std.mem.eql(u8, first, "clean")) {
            command = .clean_cmd;
            while (args.next()) |arg| {
                if (extra_count >= extra_args.len) {
                    std.debug.print("labelle: too many arguments\n", .{});
                    return error.TooManyArguments;
                }
                extra_args[extra_count] = arg;
                extra_count += 1;
            }
        } else if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
            command = .help_cmd;
        } else if (std.mem.eql(u8, first, "version") or std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-v")) {
            command = .version;
        } else if (std.mem.eql(u8, first, "targets")) {
            command = .targets;
        } else {
            // No command — treat as project dir, default to run
            project_dir = first;
            dir_set = true;
            // Parse remaining args (e.g. `labelle mydir --timeout=5s --scene=intro`)
            while (args.next()) |arg| {
                switch (parseSceneFlag(arg, &args, &scene_override, "run")) {
                    .parsed => continue,
                    .err => return,
                    .not_scene => {},
                }
                if (std.mem.startsWith(u8, arg, "--timeout=")) {
                    timeout_ns = util.parseDuration(arg["--timeout=".len..]);
                    if (timeout_ns == null) {
                        std.debug.print("labelle: invalid --timeout value '{s}'\n", .{arg["--timeout=".len..]});
                        return;
                    }
                } else if (std.mem.eql(u8, arg, "--timeout")) {
                    if (args.next()) |val| {
                        timeout_ns = util.parseDuration(val);
                        if (timeout_ns == null) {
                            std.debug.print("labelle: invalid --timeout value '{s}'\n", .{val});
                            return;
                        }
                    } else {
                        std.debug.print("labelle: --timeout requires a value\n", .{});
                        return;
                    }
                } else if (std.mem.startsWith(u8, arg, "--")) {
                    std.debug.print("labelle: unknown flag '{s}'\n", .{arg});
                    return;
                } else {
                    std.debug.print("labelle: unexpected argument '{s}'\n", .{arg});
                    return;
                }
            }
        }
    }

    // Standalone commands (no project.labelle needed)
    switch (command) {
        .help_cmd => return help.printHelp(),
        .version => return help.printVersion(),
        .targets => return help.printTargets(),
        .init_cmd => return init.cmdInit(allocator, extra_args[0..extra_count]),
        .install_cmd => return install.cmdInstall(allocator, extra_args[0..extra_count]),
        .update_cmd => return update.cmdUpdate(allocator, extra_args[0..extra_count]),
        .clean_cmd => return clean.cmdClean(allocator, extra_args[0..extra_count]),
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
    if (scene_override) |scene| {
        parsed.initial_scene = scene;
    }

    // Upgrade modifies project.labelle in the project directory
    if (command == .upgrade_cmd) {
        return upgrade.cmdUpgrade(allocator, project_dir, parsed, extra_args[0..extra_count]);
    }

    // Ensure package cache is populated
    try cache.ensureCache(allocator, parsed);

    // Validate version compatibility
    compatibility.validateCompatibility(parsed);

    // Generate into .labelle/
    const output_dir = try std.fs.path.join(allocator, &.{ project_dir, ".labelle" });
    defer allocator.free(output_dir);

    std.debug.print("labelle: generating '{s}'...\n", .{parsed.name});
    std.debug.print("  backend: {s}  platform: {s}  ecs: {s}  gui: {s}  window: {d}x{d}\n", .{
        @tagName(parsed.backend), @tagName(parsed.platform), @tagName(parsed.ecs), @tagName(parsed.gui), parsed.width, parsed.height,
    });

    try gen.generate(allocator, parsed, output_dir, project_dir);

    // Target subdir: .labelle/raylib_desktop/, etc.
    const target_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ @tagName(parsed.backend), @tagName(parsed.platform) });
    defer allocator.free(target_name);
    const target_dir = try std.fs.path.join(allocator, &.{ output_dir, target_name });
    defer allocator.free(target_dir);

    try runner.fixFingerprint(allocator, target_dir);
    try lockfile.writeLockFile(allocator, project_dir, parsed);
    std.debug.print("  generated .labelle/{s}/\n", .{target_name});

    if (command == .generate) return;

    // Build
    std.debug.print("labelle: building...\n", .{});
    const build_result = try runner.runZig(allocator, target_dir, &.{ "zig", "build" });
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
    std.debug.print("  build ok\n", .{});

    if (command == .build) return;

    // Run
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
    const run_result = try runner.runZigInherit(allocator, target_dir, &.{ "zig", "build", "run" }, timeout_ns);
    if (run_result != 0) {
        std.debug.print("\nlabelle: process exited with code {d}\n", .{run_result});
    }
}
