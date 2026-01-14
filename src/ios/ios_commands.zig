// ============================================================================
// iOS Commands for Labelle CLI
// ============================================================================
// Handles iOS-specific build and deployment commands.
//
// Commands:
//   ios build             Build for iOS device (arm64-ios)
//   ios build --simulator Build for iOS simulator (arm64-ios-simulator)
//   ios build --release   Build release configuration
//   ios xcode             Generate Xcode project for code signing
//   ios run               Build and run on device/simulator (requires xcrun)

const std = @import("std");
const project_config = @import("../project_config.zig");

/// Embedded iOS main template
const ios_main_template = @embedFile("templates/ios_main.zig");

/// iOS build configuration from ios.labelle or defaults
pub const IosConfig = struct {
    app_name: []const u8 = "LabelleGame",
    bundle_id: []const u8 = "com.labelle.game",
    team_id: ?[]const u8 = null,
    minimum_ios: []const u8 = "15.0",
    orientation: Orientation = .all,
    engine_version: []const u8 = "latest",
    physics_enabled: bool = false,

    pub const Orientation = enum {
        portrait,
        landscape,
        all,
    };

    /// Load iOS config from ios.labelle file, or return defaults
    pub fn load(allocator: std.mem.Allocator, project_path: []const u8) !IosConfig {
        // Always read project.labelle first to get engine_version
        const proj_config = project_config.readProjectConfig(allocator, project_path) catch |err| {
            std.debug.print("Warning: could not load project.labelle, using defaults. Error: {any}\n", .{err});
            return IosConfig{};
        };
        defer proj_config.deinit(allocator);

        const engine_version = try allocator.dupe(u8, proj_config.engine_version orelse "latest");

        const ios_config_path = try std.fs.path.join(allocator, &.{ project_path, "ios.labelle" });
        defer allocator.free(ios_config_path);

        const file = std.fs.cwd().openFile(ios_config_path, .{}) catch {
            // No ios.labelle file, use defaults from project.labelle
            return IosConfig{
                .app_name = try allocator.dupe(u8, proj_config.name orelse "LabelleGame"),
                .bundle_id = try std.fmt.allocPrint(allocator, "com.labelle.{s}", .{proj_config.name orelse "game"}),
                .engine_version = engine_version,
                .physics_enabled = proj_config.physics_enabled,
            };
        };
        defer file.close();

        // Parse ios.labelle
        const stat = try file.stat();
        const content = try allocator.allocSentinel(u8, stat.size, 0);
        defer allocator.free(content);
        _ = try file.readAll(content);

        var ios_config = std.zon.parse.fromSlice(IosConfig, allocator, content, null, .{}) catch |err| {
            std.debug.print("Warning: could not parse ios.labelle, using defaults. Error: {any}\n", .{err});
            return IosConfig{
                .engine_version = engine_version,
                .physics_enabled = proj_config.physics_enabled,
            };
        };
        ios_config.engine_version = engine_version;
        ios_config.physics_enabled = proj_config.physics_enabled;
        return ios_config;
    }
};

/// Main iOS command dispatcher
pub fn handleIos(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        printIosHelp();
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "build")) {
        try handleIosBuild(allocator, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "xcode")) {
        try handleIosXcode(allocator, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "run")) {
        try handleIosRun(allocator, args[1..]);
    } else if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        printIosHelp();
    } else {
        std.debug.print("Unknown iOS command: {s}\n\n", .{subcommand});
        printIosHelp();
    }
}

fn printIosHelp() void {
    std.debug.print(
        \\iOS Commands
        \\
        \\Usage: labelle ios <command> [options] [project_path]
        \\
        \\Commands:
        \\  build       Build for iOS
        \\  xcode       Generate Xcode project
        \\  run         Build and run on device/simulator
        \\
        \\Build Options:
        \\  --simulator       Build for iOS simulator instead of device
        \\  --release         Build release configuration
        \\  --app-name NAME   Override app name
        \\  --bundle-id ID    Override bundle identifier
        \\
        \\Xcode Options:
        \\  --team-id ID      Apple Developer Team ID for signing
        \\  --output DIR      Output directory (default: ./ios-xcode)
        \\
        \\Run Options:
        \\  --simulator       Run on iOS simulator
        \\  --device          Run on connected device (default)
        \\
        \\Configuration:
        \\  Create ios.labelle in your project for iOS-specific settings:
        \\
        \\  .{{
        \\      .app_name = "My Game",
        \\      .bundle_id = "com.example.mygame",
        \\      .team_id = "XXXXXXXXXX",
        \\      .minimum_ios = "15.0",
        \\      .orientation = .landscape,
        \\  }}
        \\
        \\Examples:
        \\  labelle ios build              # Build for iOS device
        \\  labelle ios build --simulator  # Build for simulator
        \\  labelle ios xcode              # Generate Xcode project
        \\  labelle ios run --simulator    # Run on simulator
        \\
    , .{});
}

// ============================================================================
// iOS Build Command
// ============================================================================

fn handleIosBuild(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var project_path: []const u8 = ".";
    var simulator = false;
    var release = false;

    // Parse args
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--simulator") or std.mem.eql(u8, arg, "-s")) {
            simulator = true;
        } else if (std.mem.eql(u8, arg, "--release") or std.mem.eql(u8, arg, "-r")) {
            release = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            project_path = arg;
        }
    }

    // Load iOS config
    const ios_config = try IosConfig.load(allocator, project_path);

    // Sanitize app name for binary path (hyphens become underscores)
    const sanitized_name = try sanitizeName(allocator, ios_config.app_name);
    defer allocator.free(sanitized_name);

    std.debug.print("Building {s} for iOS...\n", .{ios_config.app_name});
    std.debug.print("  Target: {s}\n", .{if (simulator) "iOS Simulator (arm64)" else "iOS Device (arm64)"});
    std.debug.print("  Configuration: {s}\n", .{if (release) "Release" else "Debug"});

    // Ensure iOS build files exist
    try ensureIosBuildFiles(allocator, project_path, ios_config);

    // Get iOS build directory
    const ios_dir = try std.fs.path.join(allocator, &.{ project_path, "ios" });
    defer allocator.free(ios_dir);

    // Build command: zig build ios (or ios-sim)
    var cmd_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer cmd_args.deinit(allocator);

    try cmd_args.append(allocator, "zig");
    try cmd_args.append(allocator, "build");
    try cmd_args.append(allocator, if (simulator) "ios-sim" else "ios");

    if (release) {
        try cmd_args.append(allocator, "-Doptimize=ReleaseFast");
    }

    std.debug.print("\nRunning: zig build {s}\n", .{if (simulator) "ios-sim" else "ios"});

    // Run zig build and capture output to check for fingerprint errors
    const run_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = cmd_args.items,
        .cwd = ios_dir,
    }) catch |err| {
        std.debug.print("Failed to run zig build: {}\n", .{err});
        return err;
    };
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    if (run_result.term == .Exited and run_result.term.Exited == 0) {
        std.debug.print("\nBuild successful!\n", .{});
        std.debug.print("Binary: {s}/zig-out/bin/{s}\n", .{ ios_dir, sanitized_name });
        return;
    }

    // Check if it's a fingerprint error and try to fix it
    const prefix = "use this value: 0x";
    if (std.mem.indexOf(u8, run_result.stderr, prefix)) |start| {
        const fp_start = start + prefix.len;
        if (fp_start + 16 <= run_result.stderr.len) {
            const suggested_fp = run_result.stderr[fp_start .. fp_start + 16];

            std.debug.print("Fixing fingerprint and retrying...\n", .{});

            // Update build.zig.zon with correct fingerprint
            const build_zon_path = try std.fs.path.join(allocator, &.{ ios_dir, "build.zig.zon" });
            defer allocator.free(build_zon_path);

            try fixFingerprint(allocator, build_zon_path, suggested_fp);

            // Retry build with inherited IO
            var retry_child = std.process.Child.init(cmd_args.items, allocator);
            retry_child.cwd = ios_dir;
            retry_child.stdin_behavior = .Inherit;
            retry_child.stdout_behavior = .Inherit;
            retry_child.stderr_behavior = .Inherit;

            const retry_term = try retry_child.spawnAndWait();

            if (retry_term == .Exited and retry_term.Exited == 0) {
                std.debug.print("\nBuild successful!\n", .{});
                std.debug.print("Binary: {s}/zig-out/bin/{s}\n", .{ ios_dir, sanitized_name });
                return;
            }
        }
    } else {
        // Print the error output if not a fingerprint error
        std.debug.print("{s}", .{run_result.stderr});
    }
}

fn fixFingerprint(allocator: std.mem.Allocator, path: []const u8, new_fp: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    const stat = try file.stat();
    const content = try allocator.alloc(u8, stat.size);
    defer allocator.free(content);
    _ = try file.readAll(content);
    file.close();

    // Find and replace fingerprint
    const fp_prefix = ".fingerprint = 0x";
    if (std.mem.indexOf(u8, content, fp_prefix)) |start| {
        const fp_start = start + fp_prefix.len;
        if (fp_start + 16 <= content.len) {
            // Create new content with updated fingerprint
            var new_content: std.ArrayListUnmanaged(u8) = .empty;
            defer new_content.deinit(allocator);

            try new_content.appendSlice(allocator, content[0..fp_start]);
            try new_content.appendSlice(allocator, new_fp);
            try new_content.appendSlice(allocator, content[fp_start + 16 ..]);

            // Write back
            const out_file = try std.fs.cwd().createFile(path, .{});
            defer out_file.close();
            try out_file.writeAll(new_content.items);
        }
    }
}

// ============================================================================
// iOS Xcode Command
// ============================================================================

fn handleIosXcode(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var project_path: []const u8 = ".";
    var team_id: ?[]const u8 = null;
    var output_dir: []const u8 = "./ios-xcode";

    // Parse args
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--team-id")) {
            i += 1;
            if (i < args.len) team_id = args[i];
        } else if (std.mem.startsWith(u8, arg, "--team-id=")) {
            team_id = arg["--team-id=".len..];
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i < args.len) output_dir = args[i];
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            output_dir = arg["--output=".len..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            project_path = arg;
        }
    }

    // Load iOS config
    var ios_config = try IosConfig.load(allocator, project_path);
    if (team_id) |tid| {
        ios_config.team_id = tid;
    }

    std.debug.print("Generating Xcode project for {s}...\n", .{ios_config.app_name});

    // First, build the iOS binary
    std.debug.print("\nStep 1: Building iOS binary...\n", .{});
    try handleIosBuild(allocator, &.{project_path});

    // Generate Xcode project
    std.debug.print("\nStep 2: Generating Xcode project...\n", .{});
    try generateXcodeProject(allocator, project_path, output_dir, ios_config);

    const sanitized_name = try sanitizeName(allocator, ios_config.app_name);
    defer allocator.free(sanitized_name);

    std.debug.print("\nXcode project generated!\n", .{});
    std.debug.print("  Location: {s}/{s}.xcodeproj\n", .{ output_dir, sanitized_name });
    std.debug.print("\nNext steps:\n", .{});
    std.debug.print("  1. Open: open \"{s}/{s}.xcodeproj\"\n", .{ output_dir, sanitized_name });
    std.debug.print("  2. Select your development team in Signing & Capabilities\n", .{});
    std.debug.print("  3. Add app icons to Assets.xcassets\n", .{});
    std.debug.print("  4. Build and run on device\n", .{});
}

// ============================================================================
// iOS Run Command
// ============================================================================

fn handleIosRun(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var project_path: []const u8 = ".";
    var simulator = false;

    // Parse args
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--simulator") or std.mem.eql(u8, arg, "-s")) {
            simulator = true;
        } else if (std.mem.eql(u8, arg, "--device") or std.mem.eql(u8, arg, "-d")) {
            simulator = false;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            project_path = arg;
        }
    }

    // Load iOS config
    const ios_config = try IosConfig.load(allocator, project_path);

    if (simulator) {
        std.debug.print("Building and running {s} on iOS Simulator...\n", .{ios_config.app_name});

        // Build for simulator
        try handleIosBuild(allocator, &.{ project_path, "--simulator" });

        // Deploy to simulator
        std.debug.print("\nDeploying to simulator...\n", .{});
        try deployToSimulator(allocator, project_path, ios_config);
    } else {
        std.debug.print("Building and running {s} on iOS Device...\n", .{ios_config.app_name});
        std.debug.print("\nNote: Running on device requires code signing.\n", .{});
        std.debug.print("Run 'labelle ios xcode' first, then deploy via Xcode.\n", .{});
    }
}

/// Deploy app to iOS Simulator using xcrun simctl
fn deployToSimulator(allocator: std.mem.Allocator, project_path: []const u8, ios_config: IosConfig) !void {
    const sanitized_name = try sanitizeName(allocator, ios_config.app_name);
    defer allocator.free(sanitized_name);

    // Path to simulator binary
    const binary_path = try std.fmt.allocPrint(allocator, "{s}/ios/zig-out/bin/{s}_sim", .{ project_path, sanitized_name });
    defer allocator.free(binary_path);

    // Check binary exists
    std.fs.cwd().access(binary_path, .{}) catch {
        std.debug.print("Error: Binary not found at {s}\n", .{binary_path});
        return error.BinaryNotFound;
    };

    // Create temporary .app bundle
    const app_bundle = try std.fmt.allocPrint(allocator, "{s}/ios/{s}.app", .{ project_path, sanitized_name });
    defer allocator.free(app_bundle);

    // Create app directory
    std.fs.cwd().makePath(app_bundle) catch {};

    // Copy binary to app bundle
    const app_binary = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ app_bundle, sanitized_name });
    defer allocator.free(app_binary);

    // Copy binary using file operations
    const src_file = std.fs.cwd().openFile(binary_path, .{}) catch |err| {
        std.debug.print("Error opening binary: {}\n", .{err});
        return err;
    };
    defer src_file.close();

    const dst_file = std.fs.cwd().createFile(app_binary, .{}) catch |err| {
        std.debug.print("Error creating app binary: {}\n", .{err});
        return err;
    };
    defer dst_file.close();

    // Copy contents
    const stat = src_file.stat() catch |err| {
        std.debug.print("Error getting file stats: {}\n", .{err});
        return err;
    };

    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < stat.size) {
        const bytes_read = src_file.read(&buf) catch |err| {
            std.debug.print("Error reading binary: {}\n", .{err});
            return err;
        };
        if (bytes_read == 0) break;
        dst_file.writeAll(buf[0..bytes_read]) catch |err| {
            std.debug.print("Error writing binary: {}\n", .{err});
            return err;
        };
        total += bytes_read;
    }

    // Make executable using chmod
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "chmod", "+x", app_binary },
    }) catch {};

    // Generate Info.plist
    const info_plist_path = try std.fmt.allocPrint(allocator, "{s}/Info.plist", .{app_bundle});
    defer allocator.free(info_plist_path);

    const info_plist_content = try generateSimulatorInfoPlist(allocator, ios_config);
    defer allocator.free(info_plist_content);

    const info_file = try std.fs.cwd().createFile(info_plist_path, .{});
    defer info_file.close();
    try info_file.writeAll(info_plist_content);

    // Ensure a simulator is booted
    const booted_udid = try ensureSimulatorBooted(allocator);

    // Install app on simulator
    std.debug.print("Installing app...\n", .{});
    const install_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "xcrun", "simctl", "install", booted_udid, app_bundle },
    }) catch |err| {
        std.debug.print("Error running simctl install: {}\n", .{err});
        return err;
    };
    defer allocator.free(install_result.stdout);
    defer allocator.free(install_result.stderr);

    if (install_result.term != .Exited or install_result.term.Exited != 0) {
        std.debug.print("Install failed: {s}\n", .{install_result.stderr});
        return error.InstallFailed;
    }

    // Launch app on simulator
    std.debug.print("Launching app...\n", .{});
    const launch_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "xcrun", "simctl", "launch", booted_udid, ios_config.bundle_id },
    }) catch |err| {
        std.debug.print("Error running simctl launch: {}\n", .{err});
        return err;
    };
    defer allocator.free(launch_result.stdout);
    defer allocator.free(launch_result.stderr);

    if (launch_result.term != .Exited or launch_result.term.Exited != 0) {
        std.debug.print("Launch failed: {s}\n", .{launch_result.stderr});
        return error.LaunchFailed;
    }

    // Parse PID from output (format: "com.bundle.id: 12345")
    if (std.mem.indexOf(u8, launch_result.stdout, ": ")) |colon_pos| {
        const pid = std.mem.trim(u8, launch_result.stdout[colon_pos + 2 ..], &.{ ' ', '\n', '\r' });
        std.debug.print("\nApp launched successfully! (PID: {s})\n", .{pid});
    } else {
        std.debug.print("\nApp launched successfully!\n", .{});
    }

    // Clean up app bundle (optional - leave it for reinstalls)
    // std.fs.cwd().deleteTree(app_bundle) catch {};
}

/// Ensure an iOS simulator is booted, boot one if needed
fn ensureSimulatorBooted(allocator: std.mem.Allocator) ![]const u8 {
    // Check for booted simulator
    const list_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "xcrun", "simctl", "list", "devices", "booted", "-j" },
    }) catch |err| {
        std.debug.print("Error listing simulators: {}\n", .{err});
        return err;
    };
    defer allocator.free(list_result.stdout);
    defer allocator.free(list_result.stderr);

    // Simple check: if output contains a UDID pattern, a simulator is booted
    // Look for pattern like "udid" : "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
    if (std.mem.indexOf(u8, list_result.stdout, "\"udid\"")) |_| {
        // Extract first UDID from JSON
        const udid_key = "\"udid\" : \"";
        if (std.mem.indexOf(u8, list_result.stdout, udid_key)) |start| {
            const udid_start = start + udid_key.len;
            if (std.mem.indexOfPos(u8, list_result.stdout, udid_start, "\"")) |end| {
                const udid = list_result.stdout[udid_start..end];
                std.debug.print("Using booted simulator: {s}\n", .{udid});
                // Return a copy since we're freeing list_result
                return allocator.dupe(u8, udid) catch "booted";
            }
        }
        // Fallback to "booted" which simctl understands
        return "booted";
    }

    // No simulator booted, try to boot one
    std.debug.print("No simulator booted. Starting iPhone simulator...\n", .{});

    // Get available simulators
    const avail_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "xcrun", "simctl", "list", "devices", "available" },
    }) catch {
        return "booted"; // Fallback
    };
    defer allocator.free(avail_result.stdout);
    defer allocator.free(avail_result.stderr);

    // Find an iPhone simulator UDID (look for pattern like "(XXXXXXXX-XXXX-")
    var lines = std.mem.splitScalar(u8, avail_result.stdout, '\n');
    while (lines.next()) |line| {
        // Look for iPhone lines with UDID
        if (std.mem.indexOf(u8, line, "iPhone") != null) {
            if (std.mem.indexOf(u8, line, "(")) |paren_start| {
                if (std.mem.indexOfPos(u8, line, paren_start, ")")) |paren_end| {
                    const udid = line[paren_start + 1 .. paren_end];
                    // Verify it looks like a UDID (36 chars with dashes)
                    if (udid.len == 36 and udid[8] == '-') {
                        std.debug.print("Booting simulator: {s}\n", .{std.mem.trim(u8, line, " \t")});

                        // Boot this simulator
                        var boot_child = std.process.Child.init(&.{ "xcrun", "simctl", "boot", udid }, allocator);
                        _ = boot_child.spawnAndWait() catch {};

                        // Wait a moment for boot
                        std.Thread.sleep(2 * std.time.ns_per_s);

                        return allocator.dupe(u8, udid) catch "booted";
                    }
                }
            }
        }
    }

    return "booted"; // Fallback
}

/// Generate minimal Info.plist for simulator app bundle
fn generateSimulatorInfoPlist(allocator: std.mem.Allocator, ios_config: IosConfig) ![]const u8 {
    const sanitized_name = try sanitizeName(allocator, ios_config.app_name);
    defer allocator.free(sanitized_name);

    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleExecutable</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleIdentifier</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleName</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleVersion</key>
        \\    <string>1.0</string>
        \\    <key>CFBundleShortVersionString</key>
        \\    <string>1.0</string>
        \\    <key>LSRequiresIPhoneOS</key>
        \\    <true/>
        \\    <key>UIRequiredDeviceCapabilities</key>
        \\    <array>
        \\        <string>arm64</string>
        \\    </array>
        \\    <key>UISupportedInterfaceOrientations</key>
        \\    <array>
        \\        <string>UIInterfaceOrientationPortrait</string>
        \\        <string>UIInterfaceOrientationLandscapeLeft</string>
        \\        <string>UIInterfaceOrientationLandscapeRight</string>
        \\    </array>
        \\</dict>
        \\</plist>
        \\
    , .{ sanitized_name, ios_config.bundle_id, ios_config.app_name });
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Ensure iOS build directory and files exist
fn ensureIosBuildFiles(allocator: std.mem.Allocator, project_path: []const u8, ios_config: IosConfig) !void {
    const ios_dir = try std.fs.path.join(allocator, &.{ project_path, "ios" });
    defer allocator.free(ios_dir);

    // Create ios directory if it doesn't exist
    std.fs.cwd().makePath(ios_dir) catch {};

    // Check if build.zig exists
    const build_zig_path = try std.fs.path.join(allocator, &.{ ios_dir, "build.zig" });
    defer allocator.free(build_zig_path);

    std.fs.cwd().access(build_zig_path, .{}) catch {
        // Generate iOS build files
        std.debug.print("Generating iOS build files...\n", .{});
        try generateIosBuildFiles(allocator, project_path, ios_config);
    };
}

/// Generate iOS build.zig and build.zig.zon
fn generateIosBuildFiles(allocator: std.mem.Allocator, project_path: []const u8, ios_config: IosConfig) !void {
    const ios_dir = try std.fs.path.join(allocator, &.{ project_path, "ios" });
    defer allocator.free(ios_dir);

    // Create directories
    std.fs.cwd().makePath(ios_dir) catch {};

    const templates_dir = try std.fs.path.join(allocator, &.{ ios_dir, "templates" });
    defer allocator.free(templates_dir);
    std.fs.cwd().makePath(templates_dir) catch {};

    // Generate build.zig.zon
    const build_zon_path = try std.fs.path.join(allocator, &.{ ios_dir, "build.zig.zon" });
    defer allocator.free(build_zon_path);

    // Sanitize app name for Zig identifier (replace hyphens with underscores)
    const sanitized_app_name = try sanitizeName(allocator, ios_config.app_name);
    defer allocator.free(sanitized_app_name);

    // Try to read engine dependency from main project's .labelle/build.zig.zon
    const engine_dep = readEngineDependency(allocator, project_path) catch |err| {
        std.debug.print("Warning: Could not read engine dependency from .labelle/build.zig.zon: {}\n", .{err});
        std.debug.print("Please run 'labelle generate' first to set up the project.\n", .{});
        return err;
    };
    defer engine_dep.deinit(allocator);

    // Note: The fingerprint will be validated by Zig on first build.
    // If it fails, Zig will suggest the correct value.
    // sokol dependency is needed for linking sokol_clib, but the Zig module
    // is accessed through engine.sokol to avoid module conflicts
    const build_zon_content = switch (engine_dep) {
        .path => |path| try std.fmt.allocPrint(allocator,
            \\.{{
            \\    .fingerprint = 0xb8a8f4e73d5c1a92,
            \\    .name = .{s}_ios,
            \\    .version = "0.1.0",
            \\    .dependencies = .{{
            \\        // sokol for linking sokol_clib (C library)
            \\        // Zig module accessed via engine.sokol to avoid conflicts
            \\        .sokol = .{{
            \\            .url = "git+https://github.com/floooh/sokol-zig.git#bb1a4e95b243e655e788076c545ca6a1f6bf1558",
            \\            .hash = "sokol-0.1.0-pb1HK_0CLwBZEK_EZfeR-l9Mtt-BBIuucIZ-c5tLDZxc",
            \\        }},
            \\        .@"labelle-engine" = .{{
            \\            .path = "{s}",
            \\        }},
            \\    }},
            \\    .paths = .{{ "build.zig", "build.zig.zon" }},
            \\}}
            \\
        , .{ sanitized_app_name, path }),
        .hash => |hash| try std.fmt.allocPrint(allocator,
            \\.{{
            \\    .fingerprint = 0xb8a8f4e73d5c1a92,
            \\    .name = .{s}_ios,
            \\    .version = "0.1.0",
            \\    .dependencies = .{{
            \\        // sokol for linking sokol_clib (C library)
            \\        // Zig module accessed via engine.sokol to avoid conflicts
            \\        .sokol = .{{
            \\            .url = "git+https://github.com/floooh/sokol-zig.git#bb1a4e95b243e655e788076c545ca6a1f6bf1558",
            \\            .hash = "sokol-0.1.0-pb1HK_0CLwBZEK_EZfeR-l9Mtt-BBIuucIZ-c5tLDZxc",
            \\        }},
            \\        .@"labelle-engine" = .{{
            \\            .url = "git+https://github.com/labelle-toolkit/labelle-engine#v{s}",
            \\            .hash = "{s}",
            \\        }},
            \\    }},
            \\    .paths = .{{ "build.zig", "build.zig.zon" }},
            \\}}
            \\
        , .{ sanitized_app_name, ios_config.engine_version, hash }),
    };
    defer allocator.free(build_zon_content);

    const build_zon_file = try std.fs.cwd().createFile(build_zon_path, .{});
    defer build_zon_file.close();
    try build_zon_file.writeAll(build_zon_content);

    // Generate build.zig (simplified version)
    const build_zig_path = try std.fs.path.join(allocator, &.{ ios_dir, "build.zig" });
    defer allocator.free(build_zig_path);

    const build_zig_content = try generateIosBuildZig(allocator, ios_config);
    defer allocator.free(build_zig_content);

    const build_zig_file = try std.fs.cwd().createFile(build_zig_path, .{});
    defer build_zig_file.close();
    try build_zig_file.writeAll(build_zig_content);

    // Generate Info.plist template
    const info_plist_path = try std.fs.path.join(allocator, &.{ templates_dir, "Info.plist" });
    defer allocator.free(info_plist_path);

    const info_plist_content = try generateInfoPlist(allocator, ios_config);
    defer allocator.free(info_plist_content);

    const info_plist_file = try std.fs.cwd().createFile(info_plist_path, .{});
    defer info_plist_file.close();
    try info_plist_file.writeAll(info_plist_content);

    // Generate LaunchScreen.storyboard
    const launch_screen_path = try std.fs.path.join(allocator, &.{ templates_dir, "LaunchScreen.storyboard" });
    defer allocator.free(launch_screen_path);

    const launch_screen_content = try generateLaunchScreen(allocator, ios_config);
    defer allocator.free(launch_screen_content);

    const launch_screen_file = try std.fs.cwd().createFile(launch_screen_path, .{});
    defer launch_screen_file.close();
    try launch_screen_file.writeAll(launch_screen_content);

    // Generate ios_main.zig in project root
    const ios_main_path = try std.fs.path.join(allocator, &.{ project_path, "ios_main.zig" });
    defer allocator.free(ios_main_path);

    // Only create if it doesn't exist (don't overwrite user modifications)
    std.fs.cwd().access(ios_main_path, .{}) catch {
        const ios_main_file = try std.fs.cwd().createFile(ios_main_path, .{});
        defer ios_main_file.close();
        try ios_main_file.writeAll(ios_main_template);
        std.debug.print("Generated: {s}\n", .{ios_main_path});
    };

    std.debug.print("Generated iOS build files in: {s}\n", .{ios_dir});
}

/// Generate the Xcode project structure
fn generateXcodeProject(allocator: std.mem.Allocator, project_path: []const u8, output_dir: []const u8, ios_config: IosConfig) !void {
    const app_name = try sanitizeName(allocator, ios_config.app_name);
    defer allocator.free(app_name);

    // Create directory structure
    const xcodeproj_dir = try std.fmt.allocPrint(allocator, "{s}/{s}.xcodeproj", .{ output_dir, app_name });
    defer allocator.free(xcodeproj_dir);

    const app_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, app_name });
    defer allocator.free(app_dir);

    const assets_dir = try std.fmt.allocPrint(allocator, "{s}/Assets.xcassets/AppIcon.appiconset", .{app_dir});
    defer allocator.free(assets_dir);

    std.fs.cwd().makePath(xcodeproj_dir) catch {};
    std.fs.cwd().makePath(assets_dir) catch {};

    // Copy binary from ios/zig-out/bin/
    const ios_dir = try std.fs.path.join(allocator, &.{ project_path, "ios" });
    defer allocator.free(ios_dir);

    const binary_src = try std.fmt.allocPrint(allocator, "{s}/zig-out/bin/{s}", .{ ios_dir, app_name });
    defer allocator.free(binary_src);

    const binary_dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ app_dir, app_name });
    defer allocator.free(binary_dst);

    std.fs.cwd().copyFile(binary_src, std.fs.cwd(), binary_dst, .{}) catch |err| {
        std.debug.print("Warning: Could not copy binary: {}\n", .{err});
        std.debug.print("  Source: {s}\n", .{binary_src});
    };

    // Copy Info.plist
    const templates_dir = try std.fs.path.join(allocator, &.{ ios_dir, "templates" });
    defer allocator.free(templates_dir);

    const info_src = try std.fmt.allocPrint(allocator, "{s}/Info.plist", .{templates_dir});
    defer allocator.free(info_src);

    const info_dst = try std.fmt.allocPrint(allocator, "{s}/Info.plist", .{app_dir});
    defer allocator.free(info_dst);

    std.fs.cwd().copyFile(info_src, std.fs.cwd(), info_dst, .{}) catch {
        // Generate if template doesn't exist
        const content = try generateInfoPlist(allocator, ios_config);
        defer allocator.free(content);
        const file = try std.fs.cwd().createFile(info_dst, .{});
        defer file.close();
        try file.writeAll(content);
    };

    // Copy LaunchScreen.storyboard
    const launch_src = try std.fmt.allocPrint(allocator, "{s}/LaunchScreen.storyboard", .{templates_dir});
    defer allocator.free(launch_src);

    const launch_dst = try std.fmt.allocPrint(allocator, "{s}/LaunchScreen.storyboard", .{app_dir});
    defer allocator.free(launch_dst);

    std.fs.cwd().copyFile(launch_src, std.fs.cwd(), launch_dst, .{}) catch {
        const content = try generateLaunchScreen(allocator, ios_config);
        defer allocator.free(content);
        const file = try std.fs.cwd().createFile(launch_dst, .{});
        defer file.close();
        try file.writeAll(content);
    };

    // Copy resources if they exist
    const resources_src = try std.fs.path.join(allocator, &.{ project_path, "resources" });
    defer allocator.free(resources_src);

    const resources_dst = try std.fmt.allocPrint(allocator, "{s}/resources", .{app_dir});
    defer allocator.free(resources_dst);

    copyDirectory(allocator, resources_src, resources_dst) catch |err| {
        std.debug.print("Warning: could not copy resources directory: {any}\n", .{err});
    };

    // Copy project.labelle
    const proj_src = try std.fs.path.join(allocator, &.{ project_path, "project.labelle" });
    defer allocator.free(proj_src);

    const proj_dst = try std.fmt.allocPrint(allocator, "{s}/project.labelle", .{app_dir});
    defer allocator.free(proj_dst);

    std.fs.cwd().copyFile(proj_src, std.fs.cwd(), proj_dst, .{}) catch |err| {
        std.debug.print("Warning: could not copy project.labelle: {any}\n", .{err});
    };

    // Generate Assets.xcassets Contents.json files
    const assets_contents = try std.fmt.allocPrint(allocator, "{s}/Assets.xcassets/Contents.json", .{app_dir});
    defer allocator.free(assets_contents);

    const assets_file = try std.fs.cwd().createFile(assets_contents, .{});
    defer assets_file.close();
    try assets_file.writeAll(
        \\{
        \\  "info" : {
        \\    "author" : "xcode",
        \\    "version" : 1
        \\  }
        \\}
    );

    const icon_contents = try std.fmt.allocPrint(allocator, "{s}/Contents.json", .{assets_dir});
    defer allocator.free(icon_contents);

    const icon_file = try std.fs.cwd().createFile(icon_contents, .{});
    defer icon_file.close();
    try icon_file.writeAll(
        \\{
        \\  "images" : [
        \\    {
        \\      "idiom" : "universal",
        \\      "platform" : "ios",
        \\      "size" : "1024x1024"
        \\    }
        \\  ],
        \\  "info" : {
        \\    "author" : "xcode",
        \\    "version" : 1
        \\  }
        \\}
    );

    // Generate project.pbxproj
    const pbxproj_path = try std.fmt.allocPrint(allocator, "{s}/project.pbxproj", .{xcodeproj_dir});
    defer allocator.free(pbxproj_path);

    const pbxproj_content = try generatePbxproj(allocator, ios_config);
    defer allocator.free(pbxproj_content);

    const pbxproj_file = try std.fs.cwd().createFile(pbxproj_path, .{});
    defer pbxproj_file.close();
    try pbxproj_file.writeAll(pbxproj_content);
}

/// Sanitize name for use in identifiers (replace spaces and special chars with underscores)
fn sanitizeName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var result = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        result[i] = if (std.ascii.isAlphanumeric(c) or c == '_') c else '_';
    }
    return result;
}

/// Engine dependency - either a hash (for URL-based) or path (for local)
const EngineDependency = union(enum) {
    hash: []const u8,
    path: []const u8,

    pub fn deinit(self: EngineDependency, allocator: std.mem.Allocator) void {
        switch (self) {
            .hash => |h| allocator.free(h),
            .path => |p| allocator.free(p),
        }
    }
};

/// Read the labelle-engine dependency from the main project's .labelle/build.zig.zon
/// Returns either a hash (for URL-based dependency) or a path (for local dependency)
fn readEngineDependency(allocator: std.mem.Allocator, project_path: []const u8) !EngineDependency {
    const build_zon_path = try std.fs.path.join(allocator, &.{ project_path, ".labelle", "build.zig.zon" });
    defer allocator.free(build_zon_path);

    const file = try std.fs.cwd().openFile(build_zon_path, .{});
    defer file.close();

    const stat = try file.stat();
    const content = try allocator.alloc(u8, stat.size);
    defer allocator.free(content);
    _ = try file.readAll(content);

    // First check for path-based dependency: .path = "..."
    // Look for labelle-engine section first
    if (std.mem.indexOf(u8, content, ".@\"labelle-engine\"")) |engine_start| {
        const section = content[engine_start..];

        // Check for .path within this section
        if (std.mem.indexOf(u8, section, ".path = \"")) |path_start| {
            const value_start = path_start + ".path = \"".len;
            if (std.mem.indexOfPos(u8, section, value_start, "\"")) |value_end| {
                return .{ .path = try allocator.dupe(u8, section[value_start..value_end]) };
            }
        }

        // Check for .hash within this section
        if (std.mem.indexOf(u8, section, ".hash = \"")) |hash_start| {
            const value_start = hash_start + ".hash = \"".len;
            if (std.mem.indexOfPos(u8, section, value_start, "\"")) |value_end| {
                return .{ .hash = try allocator.dupe(u8, section[value_start..value_end]) };
            }
        }
    }

    return error.HashNotFound;
}

/// Copy directory recursively
fn copyDirectory(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    var src_dir = try std.fs.cwd().openDir(src, .{ .iterate = true });
    defer src_dir.close();

    std.fs.cwd().makePath(dst) catch {};

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        const src_path = try std.fs.path.join(allocator, &.{ src, entry.name });
        defer allocator.free(src_path);

        const dst_path = try std.fs.path.join(allocator, &.{ dst, entry.name });
        defer allocator.free(dst_path);

        switch (entry.kind) {
            .file => {
                std.fs.cwd().copyFile(src_path, std.fs.cwd(), dst_path, .{}) catch |err| {
                    std.debug.print("Warning: could not copy {s}: {any}\n", .{ src_path, err });
                };
            },
            .directory => {
                try copyDirectory(allocator, src_path, dst_path);
            },
            else => {},
        }
    }
}

// ============================================================================
// Template Generators
// ============================================================================

fn generateIosBuildZig(allocator: std.mem.Allocator, ios_config: IosConfig) ![]const u8 {
    // Sanitize app name for Zig identifier (replace hyphens with underscores)
    const sanitized_app_name = try sanitizeName(allocator, ios_config.app_name);
    defer allocator.free(sanitized_app_name);

    return std.fmt.allocPrint(allocator,
        \\//! iOS Build Configuration - Auto-generated by labelle CLI
        \\//!
        \\//! Usage:
        \\//!   zig build ios       # Build for iOS device
        \\//!   zig build ios-sim   # Build for iOS simulator
        \\//!
        \\//! Note: The sokol Zig module is accessed through engine.sokol to avoid
        \\//! module conflicts. The sokol dependency is only used for linking sokol_clib.
        \\//! The ios_main.zig template uses `const sokol = engine.sokol;`
        \\
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\
        \\    const app_name = "{s}";
        \\
        \\    // iOS Device Target
        \\    const ios_device_target = b.resolveTargetQuery(.{{
        \\        .cpu_arch = .aarch64,
        \\        .os_tag = .ios,
        \\    }});
        \\
        \\    // iOS Simulator Target (Apple Silicon Macs)
        \\    // Use apple_a14 to enable NEON SIMD features required by box2d physics
        \\    const ios_sim_target = b.resolveTargetQuery(.{{
        \\        .cpu_arch = .aarch64,
        \\        .os_tag = .ios,
        \\        .abi = .simulator,
        \\        .cpu_model = .{{ .explicit = &std.Target.aarch64.cpu.apple_a14 }},
        \\    }});
        \\
        \\    // iOS Device build
        \\    // sokol dependency for linking C library (dont_link_system_libs=true for iOS)
        \\    const ios_sokol = b.dependency("sokol", .{{
        \\        .target = ios_device_target,
        \\        .optimize = optimize,
        \\        .dont_link_system_libs = true,
        \\    }});
        \\
        \\    // Engine provides sokol through engine.sokol (re-exported to avoid module conflicts)
        \\    const ios_engine = b.dependency("labelle-engine", .{{
        \\        .target = ios_device_target,
        \\        .optimize = optimize,
        \\        .backend = .sokol,
        \\        .physics = {s},
        \\    }});
        \\
        \\    // Create main module from project's main.zig (contains registries and scenes)
        \\    const ios_main_mod = b.createModule(.{{
        \\        .root_source_file = b.path("../main.zig"),
        \\        .target = ios_device_target,
        \\        .optimize = optimize,
        \\        .imports = &.{{
        \\            .{{ .name = "labelle-engine", .module = ios_engine.module("labelle-engine") }},
        \\        }},
        \\    }});
        \\
        \\    const ios_exe = b.addExecutable(.{{
        \\        .name = app_name,
        \\        .root_module = b.createModule(.{{
        \\            .root_source_file = b.path("../ios_main.zig"),
        \\            .target = ios_device_target,
        \\            .optimize = optimize,
        \\            .imports = &.{{
        \\                .{{ .name = "labelle-engine", .module = ios_engine.module("labelle-engine") }},
        \\                .{{ .name = "main", .module = ios_main_mod }},
        \\            }},
        \\        }}),
        \\    }});
        \\
        \\    // Link sokol C library (for iOS Metal backend)
        \\    ios_exe.linkLibrary(ios_sokol.artifact("sokol_clib"));
        \\    ios_exe.linkLibC();
        \\
        \\    // Add iOS Device SDK framework search path
        \\    ios_exe.root_module.addFrameworkPath(.{{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks" }});
        \\
        \\    // Link iOS frameworks
        \\    ios_exe.root_module.linkFramework("Foundation", .{{}});
        \\    ios_exe.root_module.linkFramework("UIKit", .{{}});
        \\    ios_exe.root_module.linkFramework("Metal", .{{}});
        \\    ios_exe.root_module.linkFramework("MetalKit", .{{}});
        \\    ios_exe.root_module.linkFramework("AudioToolbox", .{{}});
        \\    ios_exe.root_module.linkFramework("AVFoundation", .{{}});
        \\
        \\    const ios_step = b.step("ios", "Build for iOS device");
        \\    ios_step.dependOn(&ios_exe.step);
        \\    ios_step.dependOn(&b.addInstallArtifact(ios_exe, .{{}}).step);
        \\
        \\    // iOS Simulator build
        \\    const sim_sokol = b.dependency("sokol", .{{
        \\        .target = ios_sim_target,
        \\        .optimize = optimize,
        \\        .dont_link_system_libs = true,
        \\    }});
        \\
        \\    const sim_engine = b.dependency("labelle-engine", .{{
        \\        .target = ios_sim_target,
        \\        .optimize = optimize,
        \\        .backend = .sokol,
        \\        .physics = {s},
        \\    }});
        \\
        \\    // Create main module from project's main.zig (contains registries and scenes)
        \\    const sim_main_mod = b.createModule(.{{
        \\        .root_source_file = b.path("../main.zig"),
        \\        .target = ios_sim_target,
        \\        .optimize = optimize,
        \\        .imports = &.{{
        \\            .{{ .name = "labelle-engine", .module = sim_engine.module("labelle-engine") }},
        \\        }},
        \\    }});
        \\
        \\    const sim_exe = b.addExecutable(.{{
        \\        .name = app_name ++ "_sim",
        \\        .root_module = b.createModule(.{{
        \\            .root_source_file = b.path("../ios_main.zig"),
        \\            .target = ios_sim_target,
        \\            .optimize = optimize,
        \\            .imports = &.{{
        \\                .{{ .name = "labelle-engine", .module = sim_engine.module("labelle-engine") }},
        \\                .{{ .name = "main", .module = sim_main_mod }},
        \\            }},
        \\        }}),
        \\    }});
        \\
        \\    // Link sokol C library (for iOS Simulator Metal backend)
        \\    sim_exe.linkLibrary(sim_sokol.artifact("sokol_clib"));
        \\    sim_exe.linkLibC();
        \\
        \\    // Add iOS Simulator SDK framework search path
        \\    sim_exe.root_module.addFrameworkPath(.{{ .cwd_relative = "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk/System/Library/Frameworks" }});
        \\
        \\    sim_exe.root_module.linkFramework("Foundation", .{{}});
        \\    sim_exe.root_module.linkFramework("UIKit", .{{}});
        \\    sim_exe.root_module.linkFramework("Metal", .{{}});
        \\    sim_exe.root_module.linkFramework("MetalKit", .{{}});
        \\    sim_exe.root_module.linkFramework("AudioToolbox", .{{}});
        \\    sim_exe.root_module.linkFramework("AVFoundation", .{{}});
        \\
        \\    const sim_step = b.step("ios-sim", "Build for iOS simulator");
        \\    sim_step.dependOn(&sim_exe.step);
        \\    sim_step.dependOn(&b.addInstallArtifact(sim_exe, .{{}}).step);
        \\}}
        \\
    , .{
        sanitized_app_name,
        if (ios_config.physics_enabled) "true" else "false",
        if (ios_config.physics_enabled) "true" else "false",
    });
}

fn generateInfoPlist(allocator: std.mem.Allocator, ios_config: IosConfig) ![]const u8 {
    const orientations = switch (ios_config.orientation) {
        .portrait =>
        \\    <array>
        \\        <string>UIInterfaceOrientationPortrait</string>
        \\    </array>
        ,
        .landscape =>
        \\    <array>
        \\        <string>UIInterfaceOrientationLandscapeLeft</string>
        \\        <string>UIInterfaceOrientationLandscapeRight</string>
        \\    </array>
        ,
        .all =>
        \\    <array>
        \\        <string>UIInterfaceOrientationPortrait</string>
        \\        <string>UIInterfaceOrientationLandscapeLeft</string>
        \\        <string>UIInterfaceOrientationLandscapeRight</string>
        \\    </array>
        ,
    };

    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleDevelopmentRegion</key>
        \\    <string>en</string>
        \\    <key>CFBundleDisplayName</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleExecutable</key>
        \\    <string>$(EXECUTABLE_NAME)</string>
        \\    <key>CFBundleIdentifier</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleInfoDictionaryVersion</key>
        \\    <string>6.0</string>
        \\    <key>CFBundleName</key>
        \\    <string>{s}</string>
        \\    <key>CFBundlePackageType</key>
        \\    <string>APPL</string>
        \\    <key>CFBundleShortVersionString</key>
        \\    <string>1.0</string>
        \\    <key>CFBundleVersion</key>
        \\    <string>1</string>
        \\    <key>LSRequiresIPhoneOS</key>
        \\    <true/>
        \\    <key>UILaunchStoryboardName</key>
        \\    <string>LaunchScreen</string>
        \\    <key>UIRequiredDeviceCapabilities</key>
        \\    <array>
        \\        <string>arm64</string>
        \\        <string>metal</string>
        \\    </array>
        \\    <key>UIRequiresFullScreen</key>
        \\    <true/>
        \\    <key>UIStatusBarHidden</key>
        \\    <true/>
        \\    <key>UISupportedInterfaceOrientations</key>
        \\{s}
        \\    <key>MinimumOSVersion</key>
        \\    <string>{s}</string>
        \\</dict>
        \\</plist>
        \\
    , .{ ios_config.app_name, ios_config.bundle_id, ios_config.app_name, orientations, ios_config.minimum_ios });
}

fn generateLaunchScreen(allocator: std.mem.Allocator, ios_config: IosConfig) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB" version="3.0" toolsVersion="21701" targetRuntime="iOS.CocoaTouch" propertyAccessControl="none" useAutolayout="YES" launchScreen="YES" useTraitCollections="YES" useSafeAreas="YES" colorMatched="YES" initialViewController="01J-lp-oVM">
        \\    <dependencies>
        \\        <plugIn identifier="com.apple.InterfaceBuilder.IBCocoaTouchPlugin" version="21679"/>
        \\        <capability name="Safe area layout guides" minToolsVersion="9.0"/>
        \\    </dependencies>
        \\    <scenes>
        \\        <scene sceneID="EHf-IW-A2E">
        \\            <objects>
        \\                <viewController id="01J-lp-oVM" sceneMemberID="viewController">
        \\                    <view key="view" contentMode="scaleToFill" id="Ze5-6b-2t3">
        \\                        <rect key="frame" x="0.0" y="0.0" width="393" height="852"/>
        \\                        <autoresizingMask key="autoresizingMask" widthSizable="YES" heightSizable="YES"/>
        \\                        <subviews>
        \\                            <label opaque="NO" userInteractionEnabled="NO" contentMode="left" horizontalHuggingPriority="251" verticalHuggingPriority="251" text="{s}" textAlignment="center" lineBreakMode="tailTruncation" baselineAdjustment="alignBaselines" adjustsFontSizeToFit="NO" translatesAutoresizingMaskIntoConstraints="NO" id="title-label">
        \\                                <fontDescription key="fontDescription" type="boldSystem" pointSize="32"/>
        \\                                <color key="textColor" white="1" alpha="1" colorSpace="custom" customColorSpace="genericGamma22GrayColorSpace"/>
        \\                            </label>
        \\                        </subviews>
        \\                        <viewLayoutGuide key="safeArea" id="6Tk-OE-BBY"/>
        \\                        <color key="backgroundColor" red="0.118" green="0.137" blue="0.176" alpha="1" colorSpace="custom" customColorSpace="sRGB"/>
        \\                        <constraints>
        \\                            <constraint firstItem="title-label" firstAttribute="centerX" secondItem="Ze5-6b-2t3" secondAttribute="centerX" id="cx"/>
        \\                            <constraint firstItem="title-label" firstAttribute="centerY" secondItem="Ze5-6b-2t3" secondAttribute="centerY" id="cy"/>
        \\                        </constraints>
        \\                    </view>
        \\                </viewController>
        \\                <placeholder placeholderIdentifier="IBFirstResponder" id="iYj-Kq-Ea1" userLabel="First Responder" sceneMemberID="firstResponder"/>
        \\            </objects>
        \\        </scene>
        \\    </scenes>
        \\</document>
        \\
    , .{ios_config.app_name});
}

fn generatePbxproj(allocator: std.mem.Allocator, ios_config: IosConfig) ![]const u8 {
    const app_name = try sanitizeName(allocator, ios_config.app_name);
    defer allocator.free(app_name);

    return std.fmt.allocPrint(allocator,
        \\// !$*UTF8*$!
        \\{{
        \\    archiveVersion = 1;
        \\    classes = {{}};
        \\    objectVersion = 56;
        \\    objects = {{
        \\        /* Begin PBXBuildFile section */
        \\        A1000001 /* {s} in CopyFiles */ = {{isa = PBXBuildFile; fileRef = A2000001; }};
        \\        A1000002 /* LaunchScreen.storyboard in Resources */ = {{isa = PBXBuildFile; fileRef = A2000002; }};
        \\        A1000003 /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = A2000003; }};
        \\        /* End PBXBuildFile section */
        \\        /* Begin PBXCopyFilesBuildPhase section */
        \\        A3000001 = {{
        \\            isa = PBXCopyFilesBuildPhase;
        \\            buildActionMask = 2147483647;
        \\            dstPath = "";
        \\            dstSubfolderSpec = 6;
        \\            files = (A1000001);
        \\            runOnlyForDeploymentPostprocessing = 0;
        \\        }};
        \\        /* End PBXCopyFilesBuildPhase section */
        \\        /* Begin PBXFileReference section */
        \\        A4000001 /* {s}.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "{s}.app"; sourceTree = BUILT_PRODUCTS_DIR; }};
        \\        A2000001 /* {s} */ = {{isa = PBXFileReference; lastKnownFileType = "compiled.mach-o.executable"; path = "{s}"; sourceTree = "<group>"; }};
        \\        A2000002 /* LaunchScreen.storyboard */ = {{isa = PBXFileReference; lastKnownFileType = file.storyboard; path = LaunchScreen.storyboard; sourceTree = "<group>"; }};
        \\        A2000003 /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};
        \\        A2000004 /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};
        \\        /* End PBXFileReference section */
        \\        /* Begin PBXGroup section */
        \\        A5000001 = {{
        \\            isa = PBXGroup;
        \\            children = (A5000002, A5000003);
        \\            sourceTree = "<group>";
        \\        }};
        \\        A5000002 = {{
        \\            isa = PBXGroup;
        \\            children = (A2000001, A2000002, A2000003, A2000004);
        \\            path = "{s}";
        \\            sourceTree = "<group>";
        \\        }};
        \\        A5000003 = {{
        \\            isa = PBXGroup;
        \\            children = (A4000001);
        \\            name = Products;
        \\            sourceTree = "<group>";
        \\        }};
        \\        /* End PBXGroup section */
        \\        /* Begin PBXNativeTarget section */
        \\        A6000001 = {{
        \\            isa = PBXNativeTarget;
        \\            buildConfigurationList = A7000003;
        \\            buildPhases = (A3000001, A3000002);
        \\            buildRules = ();
        \\            dependencies = ();
        \\            name = "{s}";
        \\            productName = "{s}";
        \\            productReference = A4000001;
        \\            productType = "com.apple.product-type.application";
        \\        }};
        \\        /* End PBXNativeTarget section */
        \\        /* Begin PBXProject section */
        \\        A8000001 = {{
        \\            isa = PBXProject;
        \\            attributes = {{BuildIndependentTargetsInParallel = 1; LastUpgradeCheck = 1500;}};
        \\            buildConfigurationList = A7000001;
        \\            compatibilityVersion = "Xcode 14.0";
        \\            developmentRegion = en;
        \\            hasScannedForEncodings = 0;
        \\            knownRegions = (en, Base);
        \\            mainGroup = A5000001;
        \\            productRefGroup = A5000003;
        \\            projectDirPath = "";
        \\            projectRoot = "";
        \\            targets = (A6000001);
        \\        }};
        \\        /* End PBXProject section */
        \\        /* Begin PBXResourcesBuildPhase section */
        \\        A3000002 = {{
        \\            isa = PBXResourcesBuildPhase;
        \\            buildActionMask = 2147483647;
        \\            files = (A1000002, A1000003);
        \\            runOnlyForDeploymentPostprocessing = 0;
        \\        }};
        \\        /* End PBXResourcesBuildPhase section */
        \\        /* Begin XCBuildConfiguration section */
        \\        A7000002 /* Debug */ = {{
        \\            isa = XCBuildConfiguration;
        \\            buildSettings = {{
        \\                ALWAYS_SEARCH_USER_PATHS = NO;
        \\                IPHONEOS_DEPLOYMENT_TARGET = {s};
        \\                SDKROOT = iphoneos;
        \\            }};
        \\            name = Debug;
        \\        }};
        \\        A7000004 /* Debug */ = {{
        \\            isa = XCBuildConfiguration;
        \\            buildSettings = {{
        \\                ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
        \\                CODE_SIGN_STYLE = Automatic;
        \\                CURRENT_PROJECT_VERSION = 1;
        \\                GENERATE_INFOPLIST_FILE = YES;
        \\                INFOPLIST_KEY_CFBundleDisplayName = {s};
        \\                INFOPLIST_KEY_LSRequiresIPhoneOS = YES;
        \\                INFOPLIST_KEY_MinimumOSVersion = {s};
        \\                INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
        \\                INFOPLIST_KEY_UILaunchStoryboardName = LaunchScreen;
        \\                INFOPLIST_KEY_UIRequiresFullScreen = YES;
        \\                INFOPLIST_KEY_UIStatusBarHidden = YES;
        \\                "INFOPLIST_KEY_UISupportedInterfaceOrientations" = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
        \\                MARKETING_VERSION = 1.0;
        \\                PRODUCT_BUNDLE_IDENTIFIER = "{s}";
        \\                PRODUCT_NAME = "$(TARGET_NAME)";
        \\                TARGETED_DEVICE_FAMILY = "1,2";
        \\            }};
        \\            name = Debug;
        \\        }};
        \\        A7000005 /* Release */ = {{
        \\            isa = XCBuildConfiguration;
        \\            buildSettings = {{
        \\                ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
        \\                CODE_SIGN_STYLE = Automatic;
        \\                CURRENT_PROJECT_VERSION = 1;
        \\                GENERATE_INFOPLIST_FILE = YES;
        \\                INFOPLIST_KEY_CFBundleDisplayName = {s};
        \\                INFOPLIST_KEY_LSRequiresIPhoneOS = YES;
        \\                INFOPLIST_KEY_MinimumOSVersion = {s};
        \\                INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
        \\                INFOPLIST_KEY_UILaunchStoryboardName = LaunchScreen;
        \\                INFOPLIST_KEY_UIRequiresFullScreen = YES;
        \\                INFOPLIST_KEY_UIStatusBarHidden = YES;
        \\                "INFOPLIST_KEY_UISupportedInterfaceOrientations" = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
        \\                MARKETING_VERSION = 1.0;
        \\                PRODUCT_BUNDLE_IDENTIFIER = "{s}";
        \\                PRODUCT_NAME = "$(TARGET_NAME)";
        \\                TARGETED_DEVICE_FAMILY = "1,2";
        \\            }};
        \\            name = Release;
        \\        }};
        \\        /* End XCBuildConfiguration section */
        \\        /* Begin XCConfigurationList section */
        \\        A7000001 = {{
        \\            isa = XCConfigurationList;
        \\            buildConfigurations = (A7000002);
        \\            defaultConfigurationIsVisible = 0;
        \\            defaultConfigurationName = Debug;
        \\        }};
        \\        A7000003 = {{
        \\            isa = XCConfigurationList;
        \\            buildConfigurations = (A7000004, A7000005);
        \\            defaultConfigurationIsVisible = 0;
        \\            defaultConfigurationName = Release;
        \\        }};
        \\        /* End XCConfigurationList section */
        \\    }};
        \\    rootObject = A8000001;
        \\}}
        \\
    , .{
        app_name,
        app_name,
        app_name,
        app_name,
        app_name,
        app_name,
        app_name,
        app_name,
        ios_config.minimum_ios,
        app_name,
        ios_config.minimum_ios,
        ios_config.bundle_id,
        app_name,
        ios_config.minimum_ios,
        ios_config.bundle_id,
    });
}
