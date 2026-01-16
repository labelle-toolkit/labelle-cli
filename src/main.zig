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
//   self-update Update the labelle CLI itself
//   help        Show help information
//   version     Show CLI version

const std = @import("std");
const engine_resolver = @import("engine_resolver.zig");
const project_config = @import("project_config.zig");
const ios_commands = @import("ios/ios_commands.zig");
const android_commands = @import("android/android_commands.zig");

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
    self_update,
    ios,
    android,
    targets,
    help,
    version,
};

const Options = struct {
    command: Command = .help,
    project_path: []const u8 = ".",
    project_name: ?[]const u8 = null,
    engine_version: ?[]const u8 = null,
    engine_path: ?[]const u8 = null, // Local engine path (for development/CI)
    main_only: bool = false,
    release: bool = false,
    backend: ?[]const u8 = null,
    ecs_backend: ?[]const u8 = null,
    show_help: bool = false,
    fetch_hashes: bool = true,
    // Target options
    target: ?[]const u8 = null,
    build_all_targets: bool = false,
    // Upgrade options
    upgrade_check_only: bool = false,
    upgrade_version: ?[]const u8 = null,
    upgrade_force: bool = false,
    upgrade_list: bool = false,
    // iOS options - pass remaining args to ios_commands
    ios_args: []const []const u8 = &.{},
    // Android options - pass remaining args to android_commands
    android_args: []const []const u8 = &.{},
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
        .self_update => try runSelfUpdate(allocator),
        .ios => try ios_commands.handleIos(allocator, options.ios_args, options.engine_path),
        .android => try android_commands.handleAndroid(allocator, options.android_args, options.engine_path),
        .targets => try listTargets(allocator),
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
    } else if (std.mem.eql(u8, cmd_str, "targets")) {
        options.command = .targets;
    } else if (std.mem.eql(u8, cmd_str, "update")) {
        options.command = .update;
    } else if (std.mem.eql(u8, cmd_str, "upgrade")) {
        options.command = .upgrade;
    } else if (std.mem.eql(u8, cmd_str, "self-update")) {
        options.command = .self_update;
    } else if (std.mem.eql(u8, cmd_str, "ios")) {
        options.command = .ios;
        // Pass all remaining args to ios_commands
        if (args.len > 2) {
            options.ios_args = args[2..];
        }
        return options;
    } else if (std.mem.eql(u8, cmd_str, "android") or std.mem.eql(u8, cmd_str, "apk")) {
        options.command = .android;
        // Pass all remaining args to android_commands
        if (args.len > 2) {
            options.android_args = args[2..];
        }
        return options;
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
        } else if (std.mem.eql(u8, arg, "--all")) {
            options.build_all_targets = true;
        } else if (std.mem.eql(u8, arg, "--check")) {
            options.upgrade_check_only = true;
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            options.upgrade_list = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            options.upgrade_force = true;
        } else if (std.mem.startsWith(u8, arg, "--target=")) {
            options.target = arg["--target=".len..];
        } else if (std.mem.eql(u8, arg, "--target") or std.mem.eql(u8, arg, "-t")) {
            // Next arg is the target name
            if (i + 1 < args.len) {
                i += 1;
                options.target = args[i];
            }
        } else if (std.mem.startsWith(u8, arg, "--engine=")) {
            options.engine_version = arg["--engine=".len..];
        } else if (std.mem.startsWith(u8, arg, "--engine-path=")) {
            options.engine_path = arg["--engine-path=".len..];
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
    std.debug.print("Generating project files...\n", .{});

    // Read project.labelle to get engine version
    const config = project_config.readProjectConfig(allocator, ".") catch |err| {
        std.debug.print("Error reading project.labelle: {}\n", .{err});
        std.debug.print("Run 'labelle init <name>' to create a new project\n", .{});
        return;
    };
    defer config.deinit(allocator);

    // Use local engine path if provided, otherwise resolve version
    if (options.engine_path) |local_path| {
        std.debug.print("Using local labelle-engine from: {s}\n", .{local_path});

        // Run generator from local path
        engine_resolver.runLocalEngineGenerator(allocator, local_path, ".") catch |err| {
            std.debug.print("Error running generator from local engine: {}\n", .{err});
            return;
        };
    } else {
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
}

/// Detect available targets by scanning for *_build.zig files in .labelle directory
fn detectAvailableTargets(allocator: std.mem.Allocator) ![][]const u8 {
    var targets: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (targets.items) |target| allocator.free(target);
        targets.deinit(allocator);
    }

    const labelle_dir = std.fs.cwd().openDir(".labelle", .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            return &.{};
        }
        return err;
    };
    var dir = labelle_dir;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        // With the new subfolder structure, each target is a directory containing build.zig
        // Check if this directory has a build.zig file
        const build_zig_path = try std.fmt.allocPrint(allocator, "{s}/build.zig", .{entry.name});
        defer allocator.free(build_zig_path);

        dir.access(build_zig_path, .{}) catch continue;

        // This is a valid target directory
        const target_name = try allocator.dupe(u8, entry.name);
        try targets.append(allocator, target_name);
    }

    return targets.toOwnedSlice(allocator);
}

/// Select a target based on options and available targets
fn selectTarget(allocator: std.mem.Allocator, options: Options, available_targets: []const []const u8) !?[]const u8 {
    _ = allocator;

    // If --all flag is set, return null to indicate build all
    if (options.build_all_targets) {
        return null;
    }

    // If target is explicitly specified, validate it
    if (options.target) |target| {
        for (available_targets) |available| {
            if (std.mem.eql(u8, target, available)) {
                return target;
            }
        }
        std.debug.print("Error: Target '{s}' not found.\n", .{target});
        std.debug.print("Available targets:\n", .{});
        for (available_targets) |available| {
            std.debug.print("  - {s}\n", .{available});
        }
        return error.TargetNotFound;
    }

    // If no target specified, auto-select based on available targets
    if (available_targets.len == 0) {
        std.debug.print("Error: No targets found. Run 'labelle generate' first.\n", .{});
        return error.NoTargetsFound;
    } else if (available_targets.len == 1) {
        // Single target - use it automatically
        return available_targets[0];
    } else {
        // Multiple targets - require explicit selection
        std.debug.print("Multiple targets found:\n", .{});
        for (available_targets) |target| {
            std.debug.print("  - {s}\n", .{target});
        }
        std.debug.print("\nPlease specify a target with --target <name> or use --all to build all targets\n", .{});
        return error.MultipleTargetsFound;
    }
}

/// List available targets
fn listTargets(allocator: std.mem.Allocator) !void {
    const targets = try detectAvailableTargets(allocator);
    defer {
        for (targets) |target| allocator.free(target);
        allocator.free(targets);
    }

    if (targets.len == 0) {
        std.debug.print("No targets found. Run 'labelle generate' first.\n", .{});
        return;
    }

    std.debug.print("Available targets:\n", .{});
    for (targets) |target| {
        std.debug.print("  - {s}\n", .{target});
    }
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

    // Detect available targets
    const available_targets = try detectAvailableTargets(allocator);
    defer {
        for (available_targets) |target| allocator.free(target);
        allocator.free(available_targets);
    }

    // Select target(s) to build
    const selected_target = try selectTarget(allocator, options, available_targets);

    if (selected_target) |target| {
        // Build single target
        try buildTarget(allocator, output_dir, target, options.release);
    } else {
        // Build all targets
        std.debug.print("Building all targets...\n", .{});
        for (available_targets) |target| {
            try buildTarget(allocator, output_dir, target, options.release);
        }
    }
}

fn buildTarget(allocator: std.mem.Allocator, output_dir: []const u8, target: []const u8, release: bool) !void {
    std.debug.print("Building target: {s}\n", .{target});

    // With the new subfolder structure, each target has its own directory
    const target_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, target });
    defer allocator.free(target_dir);

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(allocator);

    try args.appendSlice(allocator, &.{ "zig", "build" });
    if (release) {
        try args.append(allocator, "-Doptimize=ReleaseSafe");
    }

    var child = std.process.Child.init(args.items, allocator);
    child.cwd = target_dir;

    const result = try child.spawnAndWait();
    if (result != .Exited or result.Exited != 0) {
        return error.BuildFailed;
    }
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

    // Detect available targets
    const available_targets = try detectAvailableTargets(allocator);
    defer {
        for (available_targets) |target| allocator.free(target);
        allocator.free(available_targets);
    }

    // Select target to run (can't run multiple targets)
    if (options.build_all_targets) {
        std.debug.print("Error: Cannot use --all with 'run' command. Please specify a target with --target.\n", .{});
        return error.CannotRunAllTargets;
    }

    const selected_target = try selectTarget(allocator, options, available_targets);
    const target = selected_target orelse {
        // This shouldn't happen since build_all_targets is false
        return error.NoTargetSelected;
    };

    std.debug.print("Running target: {s}\n", .{target});

    // With the new subfolder structure, each target has its own directory
    const target_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, target });
    defer allocator.free(target_dir);

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(allocator);

    try args.appendSlice(allocator, &.{ "zig", "build", "run" });
    if (options.release) {
        try args.append(allocator, "-Doptimize=ReleaseSafe");
    }

    var child = std.process.Child.init(args.items, allocator);
    child.cwd = target_dir;

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

fn runSelfUpdate(allocator: std.mem.Allocator) !void {
    const github_cli_releases_url = "https://api.github.com/repos/labelle-toolkit/labelle-cli/releases/latest";

    std.debug.print("Checking for labelle-cli updates...\n", .{});
    std.debug.print("Current version: {s}\n\n", .{cli_version});

    // Fetch latest version from GitHub
    var child = std.process.Child.init(&.{
        "curl",
        "-s",
        "-H",
        "Accept: application/vnd.github.v3+json",
        github_cli_releases_url,
    }, allocator);

    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    _ = child.spawn() catch |err| {
        std.debug.print("Error: Failed to check for updates: {}\n", .{err});
        std.debug.print("Make sure curl is installed and you have network access.\n", .{});
        return;
    };

    const stdout = child.stdout orelse return;
    const response = stdout.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        std.debug.print("Error reading response: {}\n", .{err});
        return;
    };
    defer allocator.free(response);

    _ = child.wait() catch |err| {
        std.debug.print("Error waiting for curl: {}\n", .{err});
        return;
    };

    // Parse tag_name from response (simple string search)
    // GitHub API returns JSON with spaces: "tag_name": "v0.3.2"
    const tag_prefix = "\"tag_name\": \"";
    const tag_start = std.mem.indexOf(u8, response, tag_prefix) orelse {
        std.debug.print("Error: Could not find latest version. Check GitHub manually.\n", .{});
        std.debug.print("URL: https://github.com/labelle-toolkit/labelle-cli/releases\n", .{});
        return;
    };

    const version_start = tag_start + tag_prefix.len;
    const version_end = std.mem.indexOfPos(u8, response, version_start, "\"") orelse {
        std.debug.print("Error: Invalid response from GitHub API.\n", .{});
        return;
    };

    var latest_version = response[version_start..version_end];
    // Strip 'v' prefix if present
    if (std.mem.startsWith(u8, latest_version, "v")) {
        latest_version = latest_version[1..];
    }

    // Compare versions using semantic versioning
    const current_order = parseVersion(cli_version);
    const latest_order = parseVersion(latest_version);

    if (current_order >= latest_order) {
        if (current_order > latest_order) {
            std.debug.print("You are running a newer version ({s}) than the latest release ({s}).\n", .{ cli_version, latest_version });
        } else {
            std.debug.print("You are already on the latest version ({s}).\n", .{cli_version});
        }
        return;
    }

    std.debug.print("New version available: {s}\n\n", .{latest_version});

    // Check if we're in a git repository (source install)
    const git_check = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "rev-parse", "--git-dir" },
    }) catch {
        // Not in a git repo, show manual instructions
        printManualUpdateInstructions(latest_version);
        return;
    };
    defer allocator.free(git_check.stdout);
    defer allocator.free(git_check.stderr);

    if (git_check.term != .Exited or git_check.term.Exited != 0) {
        printManualUpdateInstructions(latest_version);
        return;
    }

    // We're in a git repo - offer to update via git
    std.debug.print("Detected source installation. Updating via git...\n\n", .{});

    // Git fetch and pull
    std.debug.print("Running: git fetch origin\n", .{});
    const fetch_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "fetch", "origin" },
    }) catch |err| {
        std.debug.print("Error fetching: {}\n", .{err});
        return;
    };
    defer allocator.free(fetch_result.stdout);
    defer allocator.free(fetch_result.stderr);

    const version_tag = std.fmt.allocPrint(allocator, "v{s}", .{latest_version}) catch return;
    defer allocator.free(version_tag);

    std.debug.print("Running: git checkout {s}\n", .{version_tag});
    const checkout_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "checkout", version_tag },
    }) catch |err| {
        std.debug.print("Error checking out version: {}\n", .{err});
        return;
    };
    defer allocator.free(checkout_result.stdout);
    defer allocator.free(checkout_result.stderr);

    if (checkout_result.term != .Exited or checkout_result.term.Exited != 0) {
        std.debug.print("Error: Could not checkout v{s}\n", .{latest_version});
        std.debug.print("{s}\n", .{checkout_result.stderr});
        return;
    }

    // Rebuild
    std.debug.print("Running: zig build -Doptimize=ReleaseSafe\n", .{});
    var build_child = std.process.Child.init(&.{ "zig", "build", "-Doptimize=ReleaseSafe" }, allocator);
    build_child.stdin_behavior = .Inherit;
    build_child.stdout_behavior = .Inherit;
    build_child.stderr_behavior = .Inherit;

    const build_term = build_child.spawnAndWait() catch |err| {
        std.debug.print("Error building: {}\n", .{err});
        return;
    };

    if (build_term != .Exited or build_term.Exited != 0) {
        std.debug.print("\nBuild failed. You may need to update manually.\n", .{});
        return;
    }

    std.debug.print("\n", .{});
    std.debug.print("Successfully updated to v{s}!\n", .{latest_version});
    std.debug.print("\n", .{});
    std.debug.print("The new binary is at: zig-out/bin/labelle\n", .{});
    std.debug.print("Copy it to your PATH to complete the update.\n", .{});
}

fn printManualUpdateInstructions(latest_version: []const u8) void {
    std.debug.print("To update, run:\n\n", .{});
    std.debug.print("  git clone https://github.com/labelle-toolkit/labelle-cli.git\n", .{});
    std.debug.print("  cd labelle-cli\n", .{});
    std.debug.print("  git checkout v{s}\n", .{latest_version});
    std.debug.print("  zig build -Doptimize=ReleaseSafe\n", .{});
    std.debug.print("  # Copy zig-out/bin/labelle to your PATH\n", .{});
}

/// Parse semantic version string into a comparable number.
/// "0.3.2" -> 0*10000 + 3*100 + 2 = 302
fn parseVersion(version: []const u8) u32 {
    var result: u32 = 0;
    var multiplier: u32 = 10000;
    var current: u32 = 0;

    for (version) |c| {
        if (c == '.') {
            result += current * multiplier;
            multiplier /= 100;
            current = 0;
        } else if (c >= '0' and c <= '9') {
            current = current * 10 + (c - '0');
        }
    }
    result += current * multiplier;

    return result;
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
        \\  targets         List available build targets
        \\  update          Clear caches and regenerate
        \\  upgrade         Upgrade to a newer labelle-engine version
        \\  self-update     Update the labelle CLI itself
        \\  ios             iOS build and deployment commands
        \\  android         Android APK build and deployment commands
        \\  help            Show this help
        \\  version         Show CLI version
        \\
        \\Options:
        \\  --target=NAME, -t NAME  Specify build target (e.g., raylib_desktop)
        \\  --all                   Build all available targets
        \\  --engine=VER            Specify labelle-engine version (default: from project.labelle)
        \\  --engine-path=PATH      Use local engine path (for development)
        \\  --release, -r           Build in release mode
        \\  --help, -h              Show help for a command
        \\
        \\Examples:
        \\  labelle init my-game
        \\  labelle generate
        \\  labelle targets
        \\  labelle run
        \\  labelle run --target raylib_desktop
        \\  labelle build --target raylib_wasm
        \\  labelle build --all
        \\  labelle run --release
        \\  labelle build --engine-path=../labelle-engine
        \\  labelle upgrade --check
        \\  labelle ios build --simulator
        \\  labelle ios xcode
        \\  labelle android build
        \\  labelle android install
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
        .build => std.debug.print(
            \\Build the project
            \\
            \\Usage: labelle build [options]
            \\
            \\Options:
            \\  --target=NAME, -t NAME  Build specific target (e.g., raylib_desktop)
            \\  --all                   Build all available targets
            \\  --release, -r           Build in release mode
            \\
            \\Examples:
            \\  labelle build                      (auto-detect single target)
            \\  labelle build --target raylib_desktop
            \\  labelle build --all
            \\  labelle build --target raylib_wasm --release
            \\
        , .{}),
        .run => std.debug.print(
            \\Build and run the project
            \\
            \\Usage: labelle run [options]
            \\
            \\Options:
            \\  --target=NAME, -t NAME  Run specific target (e.g., raylib_desktop)
            \\  --release, -r           Build in release mode
            \\
            \\Note: Cannot use --all with run command.
            \\
            \\Examples:
            \\  labelle run                      (auto-detect single target)
            \\  labelle run --target raylib_desktop
            \\  labelle run --release
            \\
        , .{}),
        .targets => std.debug.print(
            \\List available build targets
            \\
            \\Usage: labelle targets
            \\
            \\Shows all targets found in .labelle/*_build.zig files.
            \\Targets are generated from the .targets field in project.labelle.
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
        .self_update => std.debug.print(
            \\Update the labelle CLI itself to the latest version
            \\
            \\Usage: labelle self-update
            \\
            \\This command checks for new versions of labelle-cli on GitHub
            \\and updates if a newer version is available.
            \\
            \\If installed from source (git), it will:
            \\  1. Fetch latest changes
            \\  2. Checkout the new version tag
            \\  3. Rebuild with zig build
            \\
            \\Otherwise, it will show manual update instructions.
            \\
        , .{}),
        .ios => std.debug.print(
            \\iOS build and deployment commands
            \\
            \\Usage: labelle ios <command> [options]
            \\
            \\Commands:
            \\  build           Build for iOS device or simulator
            \\  xcode           Generate Xcode project
            \\  run             Build and run on device/simulator
            \\
            \\Run 'labelle ios' for full iOS help.
            \\
        , .{}),
        .android => std.debug.print(
            \\Android APK build and deployment commands
            \\
            \\Usage: labelle android <command> [options]
            \\
            \\Commands:
            \\  build           Build APK for Android
            \\  install         Install APK to connected device/emulator
            \\  run             Build and run on device/emulator
            \\  emulator        List or launch Android emulators
            \\
            \\Run 'labelle android' for full Android help.
            \\
        , .{}),
        else => printHelp(),
    }
}
