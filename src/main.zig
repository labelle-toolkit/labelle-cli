// Labelle CLI - Command-line interface for labelle-engine projects
//
// This is a thin bootstrap CLI that delegates to the generator from
// the labelle-engine version specified in the project.
//
// Usage:
//   labelle <command> [options]
//
// Commands:
//   init        Create a new labelle project
//   generate    Generate project files from project.labelle
//   build       Build the project
//   run         Build and run the project
//   update      Clear caches and regenerate
//   upgrade     Upgrade to a newer labelle-engine version
//   help        Show help information
//   version     Show CLI version

const std = @import("std");
const engine_resolver = @import("engine_resolver.zig");
const project_config = @import("project_config.zig");

// Version from build.zig.zon
const build_zon = @import("build_zon");
const cli_version = build_zon.version;

const Command = enum {
    init,
    generate,
    build,
    run,
    update,
    upgrade,
    help,
    version,
};

const Options = struct {
    command: Command = .help,
    project_path: []const u8 = ".",
    project_name: ?[]const u8 = null,
    engine_version: ?[]const u8 = null,
    main_only: bool = false,
    release: bool = false,
    backend: ?[]const u8 = null,
    ecs_backend: ?[]const u8 = null,
    show_help: bool = false,
    fetch_hashes: bool = true,
    // Upgrade options
    upgrade_check_only: bool = false,
    upgrade_version: ?[]const u8 = null,
    upgrade_force: bool = false,
    upgrade_list: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const options = parseArgs(args);

    if (options.show_help) {
        printCommandHelp(options.command);
        return;
    }

    switch (options.command) {
        .init => try runInit(allocator, options),
        .generate => try runGenerate(allocator, options),
        .build => try runBuild(allocator, options),
        .run => try runRun(allocator, options),
        .update => try runUpdate(allocator, options),
        .upgrade => try runUpgrade(allocator, options),
        .help => printHelp(),
        .version => printVersion(),
    }
}

fn parseArgs(args: []const []const u8) Options {
    var options = Options{};

    if (args.len < 2) {
        return options;
    }

    const cmd_str = args[1];
    if (std.mem.eql(u8, cmd_str, "init")) {
        options.command = .init;
    } else if (std.mem.eql(u8, cmd_str, "generate") or std.mem.eql(u8, cmd_str, "gen")) {
        options.command = .generate;
    } else if (std.mem.eql(u8, cmd_str, "build")) {
        options.command = .build;
    } else if (std.mem.eql(u8, cmd_str, "run")) {
        options.command = .run;
    } else if (std.mem.eql(u8, cmd_str, "update")) {
        options.command = .update;
    } else if (std.mem.eql(u8, cmd_str, "upgrade")) {
        options.command = .upgrade;
    } else if (std.mem.eql(u8, cmd_str, "help") or std.mem.eql(u8, cmd_str, "--help") or std.mem.eql(u8, cmd_str, "-h")) {
        options.command = .help;
    } else if (std.mem.eql(u8, cmd_str, "version") or std.mem.eql(u8, cmd_str, "--version") or std.mem.eql(u8, cmd_str, "-v")) {
        options.command = .version;
    }

    // Parse remaining arguments
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.show_help = true;
        } else if (std.mem.eql(u8, arg, "--release") or std.mem.eql(u8, arg, "-r")) {
            options.release = true;
        } else if (std.mem.eql(u8, arg, "--main-only")) {
            options.main_only = true;
        } else if (std.mem.eql(u8, arg, "--no-fetch")) {
            options.fetch_hashes = false;
        } else if (std.mem.eql(u8, arg, "--check")) {
            options.upgrade_check_only = true;
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            options.upgrade_list = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            options.upgrade_force = true;
        } else if (std.mem.startsWith(u8, arg, "--engine=")) {
            options.engine_version = arg["--engine=".len..];
        } else if (std.mem.startsWith(u8, arg, "--backend=")) {
            options.backend = arg["--backend=".len..];
        } else if (std.mem.startsWith(u8, arg, "--ecs=")) {
            options.ecs_backend = arg["--ecs=".len..];
        } else if (std.mem.startsWith(u8, arg, "--version=")) {
            options.upgrade_version = arg["--version=".len..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Positional argument
            if (options.command == .init and options.project_name == null) {
                options.project_name = arg;
            } else {
                options.project_path = arg;
            }
        }
    }

    return options;
}

fn runInit(allocator: std.mem.Allocator, options: Options) !void {
    const project_name = options.project_name orelse {
        std.debug.print("Error: Project name required\n", .{});
        std.debug.print("Usage: labelle init <project-name>\n", .{});
        return;
    };

    std.debug.print("Creating new labelle project: {s}\n", .{project_name});

    // Resolve engine version (default to latest, validate against releases)
    const engine_version = options.engine_version orelse "latest";
    const resolved = engine_resolver.resolveVersion(allocator, engine_version, true) catch |err| {
        if (err == engine_resolver.VersionError.VersionNotFound) {
            return; // Error already printed
        }
        return err;
    };
    defer if (resolved.allocated) allocator.free(resolved.version);

    std.debug.print("Using labelle-engine {s}\n", .{resolved.version});

    // Create project directory
    std.fs.cwd().makeDir(project_name) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Create project.labelle
    const project_labelle = try std.fmt.allocPrint(allocator,
        \\.{{
        \\    .version = 1,
        \\    .name = "{s}",
        \\    .engine_version = "{s}",
        \\    .initial_scene = "main",
        \\    .window = .{{ .width = 800, .height = 600, .title = "{s}" }},
        \\}}
        \\
    , .{ project_name, resolved.version, project_name });
    defer allocator.free(project_labelle);

    var dir = try std.fs.cwd().openDir(project_name, .{});
    defer dir.close();

    var file = try dir.createFile("project.labelle", .{});
    defer file.close();
    try file.writeAll(project_labelle);

    // Create directories
    dir.makeDir("scenes") catch {};
    dir.makeDir("prefabs") catch {};
    dir.makeDir("components") catch {};
    dir.makeDir("scripts") catch {};
    dir.makeDir("hooks") catch {};
    dir.makeDir("resources") catch {};

    // Create main scene
    var scenes_dir = try dir.openDir("scenes", .{});
    defer scenes_dir.close();
    var scene_file = try scenes_dir.createFile("main.zon", .{});
    defer scene_file.close();
    try scene_file.writeAll(
        \\.{
        \\    .name = "main",
        \\    .entities = .{},
        \\}
        \\
    );

    std.debug.print("Project created successfully!\n", .{});
    std.debug.print("\nNext steps:\n", .{});
    std.debug.print("  cd {s}\n", .{project_name});
    std.debug.print("  labelle generate\n", .{});
    std.debug.print("  labelle run\n", .{});
}

fn runGenerate(allocator: std.mem.Allocator, options: Options) !void {
    _ = options;
    std.debug.print("Generating project files...\n", .{});

    // Read project.labelle to get engine version
    const config = project_config.readProjectConfig(allocator, ".") catch |err| {
        std.debug.print("Error reading project.labelle: {}\n", .{err});
        std.debug.print("Run 'labelle init <name>' to create a new project\n", .{});
        return;
    };
    defer config.deinit(allocator);

    const engine_version = config.engine_version orelse "latest";
    const resolved = engine_resolver.resolveVersion(allocator, engine_version, true) catch |err| {
        if (err == engine_resolver.VersionError.VersionNotFound) {
            return; // Error already printed
        }
        return err;
    };
    defer if (resolved.allocated) allocator.free(resolved.version);

    std.debug.print("Using labelle-engine {s}\n", .{resolved.version});

    // Fetch engine and run its generator
    engine_resolver.runEngineGenerator(allocator, resolved.version, ".") catch |err| {
        if (err == engine_resolver.VersionError.FetchFailed) {
            return; // Error already printed
        }
        return err;
    };
}

fn runBuild(allocator: std.mem.Allocator, options: Options) !void {
    // First generate, then build
    try runGenerate(allocator, options);

    std.debug.print("\nBuilding project...\n", .{});

    // Run zig build in the output directory
    const output_dir = ".labelle";

    // Check if output directory exists
    std.fs.cwd().access(output_dir, .{}) catch {
        std.debug.print("Error: Output directory not found. Run 'labelle generate' first.\n", .{});
        return;
    };

    var child = std.process.Child.init(&.{ "zig", "build" }, allocator);
    child.cwd = output_dir;

    _ = try child.spawnAndWait();
}

fn runRun(allocator: std.mem.Allocator, options: Options) !void {
    // First generate, then run
    try runGenerate(allocator, options);

    std.debug.print("\nRunning project...\n", .{});

    const output_dir = ".labelle";

    // Check if output directory exists
    std.fs.cwd().access(output_dir, .{}) catch {
        std.debug.print("Error: Output directory not found. Run 'labelle generate' first.\n", .{});
        return;
    };

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(allocator);

    try args.appendSlice(allocator, &.{ "zig", "build", "run" });
    if (options.release) {
        try args.append(allocator, "-Doptimize=ReleaseSafe");
    }

    var child = std.process.Child.init(args.items, allocator);
    child.cwd = output_dir;

    _ = try child.spawnAndWait();
}

fn runUpdate(allocator: std.mem.Allocator, options: Options) !void {
    std.debug.print("Clearing caches and regenerating...\n", .{});

    // Clear generated and bootstrap directories
    std.fs.cwd().deleteTree(".labelle") catch {};
    std.fs.cwd().deleteTree(".labelle-bootstrap") catch {};

    // Regenerate
    try runGenerate(allocator, options);
}

fn runUpgrade(allocator: std.mem.Allocator, options: Options) !void {
    // Handle --list flag
    if (options.upgrade_list) {
        try engine_resolver.printAvailableVersions(allocator);
        return;
    }

    // Read current project config
    const config = project_config.readProjectConfig(allocator, ".") catch |err| {
        std.debug.print("Error reading project.labelle: {}\n", .{err});
        return;
    };
    defer config.deinit(allocator);

    const current_version = config.engine_version orelse "unknown";

    // Get latest version
    const latest = try engine_resolver.getLatestVersion(allocator);
    defer allocator.free(latest);

    if (options.upgrade_check_only) {
        std.debug.print("Current: {s}\n", .{current_version});
        std.debug.print("Latest:  {s}\n", .{latest});
        if (!std.mem.eql(u8, current_version, latest)) {
            std.debug.print("\nRun 'labelle upgrade' to upgrade.\n", .{});
        } else {
            std.debug.print("\nAlready on latest version.\n", .{});
        }
        return;
    }

    // Validate target version exists
    const target_version = options.upgrade_version orelse latest;
    if (options.upgrade_version != null) {
        // Validate the specified version
        _ = engine_resolver.resolveVersion(allocator, target_version, true) catch |err| {
            if (err == engine_resolver.VersionError.VersionNotFound) {
                return; // Error already printed
            }
            return err;
        };
    }

    if (std.mem.eql(u8, current_version, target_version) and !options.upgrade_force) {
        std.debug.print("Already on version {s}. Use --force to reinstall.\n", .{target_version});
        return;
    }

    std.debug.print("Upgrading from {s} to {s}...\n", .{ current_version, target_version });

    // Update project.labelle with new version
    project_config.updateEngineVersion(allocator, ".", target_version) catch |err| {
        std.debug.print("Error updating project.labelle: {}\n", .{err});
        return;
    };

    // Clear .labelle directory to force regeneration with new version
    std.fs.cwd().deleteTree(".labelle") catch {};
    std.fs.cwd().deleteTree(".labelle-bootstrap") catch {};

    std.debug.print("Updated engine_version to {s} in project.labelle\n", .{target_version});
    std.debug.print("Run 'labelle generate' to regenerate files with the new version.\n", .{});
}

fn printHelp() void {
    std.debug.print(
        \\Labelle CLI v{s}
        \\
        \\Usage: labelle <command> [options]
        \\
        \\Commands:
        \\  init <name>     Create a new labelle project
        \\  generate        Generate project files from project.labelle
        \\  build           Build the project
        \\  run             Build and run the project
        \\  update          Clear caches and regenerate
        \\  upgrade         Upgrade to a newer labelle-engine version
        \\  help            Show this help
        \\  version         Show CLI version
        \\
        \\Options:
        \\  --engine=VER    Specify labelle-engine version (default: from project.labelle)
        \\  --release, -r   Build in release mode
        \\  --help, -h      Show help for a command
        \\
        \\Examples:
        \\  labelle init my-game
        \\  labelle generate
        \\  labelle run
        \\  labelle run --release
        \\  labelle upgrade --check
        \\
    , .{cli_version});
}

fn printVersion() void {
    std.debug.print("labelle-cli {s}\n", .{cli_version});
}

fn printCommandHelp(command: Command) void {
    switch (command) {
        .init => std.debug.print(
            \\Create a new labelle project
            \\
            \\Usage: labelle init <project-name> [options]
            \\
            \\Options:
            \\  --engine=VER    Specify labelle-engine version (default: latest)
            \\  --backend=BE    Graphics backend (raylib, sokol)
            \\  --ecs=ECS       ECS backend (zig_ecs, zflecs)
            \\
        , .{}),
        .generate => std.debug.print(
            \\Generate project files from project.labelle
            \\
            \\Usage: labelle generate [options]
            \\
            \\Options:
            \\  --main-only     Only regenerate main.zig
            \\  --no-fetch      Skip fetching dependency hashes
            \\
        , .{}),
        .upgrade => std.debug.print(
            \\Upgrade to a newer labelle-engine version
            \\
            \\Usage: labelle upgrade [options]
            \\
            \\Options:
            \\  --list, -l      List all available versions
            \\  --check         Only check for updates, don't upgrade
            \\  --version=VER   Upgrade to specific version
            \\  --force         Force upgrade even if on same version
            \\
        , .{}),
        else => printHelp(),
    }
}
