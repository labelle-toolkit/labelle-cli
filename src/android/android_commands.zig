// ============================================================================
// Android Commands for Labelle CLI
// ============================================================================
// Handles Android-specific build and deployment commands.
//
// Commands:
//   android build             Build APK for Android
//   android build --release   Build release APK
//   android install           Install APK to connected device/emulator
//   android run               Build, install, and run on device/emulator
//   android emulator          List or start Android emulators

const std = @import("std");
const project_config = @import("../project_config.zig");
const engine_resolver = @import("../engine_resolver.zig");

const Allocator = std.mem.Allocator;

/// Android subcommand
const AndroidCommand = enum {
    build,
    install,
    run,
    emulator,
    help,
};

/// Android build options
const AndroidOptions = struct {
    command: AndroidCommand = .help,
    release: bool = false,
    target_arch: TargetArch = .arm64,
    device_id: ?[]const u8 = null,
    show_help: bool = false,
    list_emulators: bool = false,
    start_emulator: ?[]const u8 = null,

    const TargetArch = enum {
        arm64, // aarch64 (most devices)
        arm32, // armv7a (older devices)
        x86_64, // for emulator
    };
};

/// Android configuration from android.labelle or defaults
pub const AndroidConfig = struct {
    app_name: []const u8 = "LabelleGame",
    package_name: []const u8 = "com.labelle.game",
    version_code: u32 = 1,
    version_name: []const u8 = "1.0",
    min_sdk: u32 = 26,
    target_sdk: u32 = 34,
    engine_version: []const u8 = "latest",
    physics_enabled: bool = false,

    /// Load Android config from android.labelle file, or return defaults
    pub fn load(allocator: Allocator, project_path: []const u8) !AndroidConfig {
        // Read project.labelle first to get engine_version
        const proj_config = project_config.readProjectConfig(allocator, project_path) catch |err| {
            std.debug.print("Warning: could not load project.labelle, using defaults. Error: {any}\n", .{err});
            return AndroidConfig{};
        };
        defer proj_config.deinit(allocator);

        const engine_version = try allocator.dupe(u8, proj_config.engine_version orelse "latest");

        const android_config_path = try std.fs.path.join(allocator, &.{ project_path, "android.labelle" });
        defer allocator.free(android_config_path);

        const file = std.fs.cwd().openFile(android_config_path, .{}) catch {
            // No android.labelle file, use defaults from project.labelle
            return AndroidConfig{
                .app_name = try allocator.dupe(u8, proj_config.name orelse "LabelleGame"),
                .package_name = try std.fmt.allocPrint(allocator, "com.labelle.{s}", .{proj_config.name orelse "game"}),
                .engine_version = engine_version,
                .physics_enabled = proj_config.physics_enabled,
            };
        };
        defer file.close();

        // Parse android.labelle
        const stat = try file.stat();
        const content = try allocator.allocSentinel(u8, stat.size, 0);
        defer allocator.free(content);
        _ = try file.readAll(content);

        var android_config = std.zon.parse.fromSlice(AndroidConfig, allocator, content, null, .{}) catch |err| {
            std.debug.print("Warning: could not parse android.labelle, using defaults. Error: {any}\n", .{err});
            return AndroidConfig{
                .engine_version = engine_version,
                .physics_enabled = proj_config.physics_enabled,
            };
        };
        android_config.engine_version = engine_version;
        android_config.physics_enabled = proj_config.physics_enabled;
        return android_config;
    }
};

/// Main Android command dispatcher
pub fn handleAndroid(allocator: Allocator, args: []const []const u8, engine_path: ?[]const u8) !void {
    if (args.len == 0) {
        printAndroidHelp();
        return;
    }

    const options = parseAndroidArgs(args);

    if (options.show_help or options.command == .help) {
        printAndroidHelp();
        return;
    }

    switch (options.command) {
        .build => try handleAndroidBuild(allocator, options, engine_path),
        .install => try handleAndroidInstall(allocator, options),
        .run => try handleAndroidRun(allocator, options, engine_path),
        .emulator => try handleAndroidEmulator(allocator, options),
        .help => printAndroidHelp(),
    }
}

fn parseAndroidArgs(args: []const []const u8) AndroidOptions {
    var options = AndroidOptions{};

    if (args.len == 0) {
        return options;
    }

    // Parse subcommand
    const cmd_str = args[0];
    if (std.mem.eql(u8, cmd_str, "build")) {
        options.command = .build;
    } else if (std.mem.eql(u8, cmd_str, "install")) {
        options.command = .install;
    } else if (std.mem.eql(u8, cmd_str, "run")) {
        options.command = .run;
    } else if (std.mem.eql(u8, cmd_str, "emulator") or std.mem.eql(u8, cmd_str, "emu")) {
        options.command = .emulator;
    } else if (std.mem.eql(u8, cmd_str, "help") or
        std.mem.eql(u8, cmd_str, "--help") or
        std.mem.eql(u8, cmd_str, "-h"))
    {
        options.command = .help;
        return options;
    }

    // Parse remaining options
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--release") or std.mem.eql(u8, arg, "-r")) {
            options.release = true;
        } else if (std.mem.eql(u8, arg, "--arm32")) {
            options.target_arch = .arm32;
        } else if (std.mem.eql(u8, arg, "--x86_64") or std.mem.eql(u8, arg, "--x86")) {
            options.target_arch = .x86_64;
        } else if (std.mem.eql(u8, arg, "--list") or std.mem.eql(u8, arg, "-l")) {
            options.list_emulators = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.show_help = true;
        } else if (std.mem.startsWith(u8, arg, "--device=")) {
            options.device_id = arg["--device=".len..];
        } else if (std.mem.startsWith(u8, arg, "--start=")) {
            options.start_emulator = arg["--start=".len..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Positional argument for emulator name
            if (options.command == .emulator and options.start_emulator == null) {
                options.start_emulator = arg;
            }
        }
    }

    return options;
}

// ============================================================================
// Android Build Command
// ============================================================================

fn handleAndroidBuild(allocator: Allocator, options: AndroidOptions, engine_path: ?[]const u8) !void {
    const project_path = ".";

    // Load Android config
    const config = try AndroidConfig.load(allocator, project_path);

    std.debug.print("Building {s} for Android...\n", .{config.app_name});
    std.debug.print("  Package: {s}\n", .{config.package_name});
    std.debug.print("  Target: {s}\n", .{archToString(options.target_arch)});
    std.debug.print("  Configuration: {s}\n", .{if (options.release) "Release" else "Debug"});
    std.debug.print("\n", .{});

    // Step 1: Generate Android build files
    try ensureAndroidBuildFiles(allocator, project_path, config, engine_path);

    // Step 2: Build the shared library
    std.debug.print("Building native library...\n", .{});

    const android_dir = try std.fs.path.join(allocator, &.{ project_path, "android" });
    defer allocator.free(android_dir);

    var build_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer build_args.deinit(allocator);

    try build_args.appendSlice(allocator, &.{ "zig", "build", "android" });

    if (options.release) {
        try build_args.append(allocator, "-Doptimize=ReleaseFast");
    }

    var build_child = std.process.Child.init(build_args.items, allocator);
    build_child.cwd = android_dir;
    build_child.stdin_behavior = .Inherit;
    build_child.stdout_behavior = .Inherit;
    build_child.stderr_behavior = .Inherit;

    const build_term = try build_child.spawnAndWait();

    if (build_term != .Exited or build_term.Exited != 0) {
        std.debug.print("\nBuild failed!\n", .{});
        return error.BuildFailed;
    }

    // Step 3: Package APK
    std.debug.print("\nPackaging APK...\n", .{});
    try packageApk(allocator, project_path, config);

    // Get APK path
    const apk_path = try std.fmt.allocPrint(allocator, "{s}/apk_build/{s}.apk", .{ android_dir, config.app_name });
    defer allocator.free(apk_path);

    // Get APK size
    var apk_size: u64 = 0;
    if (std.fs.cwd().openFile(apk_path, .{})) |file| {
        defer file.close();
        const stat = try file.stat();
        apk_size = stat.size;
    } else |_| {}

    std.debug.print("\nBuild successful!\n", .{});
    std.debug.print("  APK: {s}\n", .{apk_path});
    if (apk_size > 0) {
        std.debug.print("  Size: {d:.1} MB\n", .{@as(f64, @floatFromInt(apk_size)) / (1024 * 1024)});
    }
}

fn archToString(arch: AndroidOptions.TargetArch) []const u8 {
    return switch (arch) {
        .arm64 => "arm64-v8a",
        .arm32 => "armeabi-v7a",
        .x86_64 => "x86_64",
    };
}

// ============================================================================
// Android Install Command
// ============================================================================

fn handleAndroidInstall(allocator: Allocator, options: AndroidOptions) !void {
    const project_path = ".";
    const config = try AndroidConfig.load(allocator, project_path);

    const android_dir = try std.fs.path.join(allocator, &.{ project_path, "android" });
    defer allocator.free(android_dir);

    const apk_path = try std.fmt.allocPrint(allocator, "{s}/apk_build/{s}.apk", .{ android_dir, config.app_name });
    defer allocator.free(apk_path);

    // Check APK exists
    std.fs.cwd().access(apk_path, .{}) catch {
        std.debug.print("Error: APK not found at {s}\n", .{apk_path});
        std.debug.print("Run 'labelle android build' first.\n", .{});
        return error.ApkNotFound;
    };

    std.debug.print("Installing {s}...\n", .{config.app_name});

    // Build adb install command
    var install_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer install_args.deinit(allocator);

    try install_args.append(allocator, "adb");
    if (options.device_id) |device| {
        try install_args.append(allocator, "-s");
        try install_args.append(allocator, device);
    }
    try install_args.appendSlice(allocator, &.{ "install", "-r", apk_path });

    var install_child = std.process.Child.init(install_args.items, allocator);
    install_child.stdin_behavior = .Inherit;
    install_child.stdout_behavior = .Inherit;
    install_child.stderr_behavior = .Inherit;

    const install_term = try install_child.spawnAndWait();

    if (install_term != .Exited or install_term.Exited != 0) {
        std.debug.print("\nInstall failed!\n", .{});
        std.debug.print("Make sure a device/emulator is connected (run 'adb devices')\n", .{});
        return error.InstallFailed;
    }

    std.debug.print("\nInstalled successfully!\n", .{});
}

// ============================================================================
// Android Run Command
// ============================================================================

fn handleAndroidRun(allocator: Allocator, options: AndroidOptions, engine_path: ?[]const u8) !void {
    // Build first
    try handleAndroidBuild(allocator, options, engine_path);

    // Install
    try handleAndroidInstall(allocator, options);

    // Launch
    const project_path = ".";
    const config = try AndroidConfig.load(allocator, project_path);

    std.debug.print("\nLaunching {s}...\n", .{config.app_name});

    // Build launch command
    var launch_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer launch_args.deinit(allocator);

    try launch_args.append(allocator, "adb");
    if (options.device_id) |device| {
        try launch_args.append(allocator, "-s");
        try launch_args.append(allocator, device);
    }
    try launch_args.append(allocator, "shell");
    try launch_args.append(allocator, "am");
    try launch_args.append(allocator, "start");
    try launch_args.append(allocator, "-n");

    const activity = try std.fmt.allocPrint(allocator, "{s}/android.app.NativeActivity", .{config.package_name});
    defer allocator.free(activity);
    try launch_args.append(allocator, activity);

    var launch_child = std.process.Child.init(launch_args.items, allocator);
    launch_child.stdin_behavior = .Inherit;
    launch_child.stdout_behavior = .Inherit;
    launch_child.stderr_behavior = .Inherit;

    const launch_term = try launch_child.spawnAndWait();

    if (launch_term != .Exited or launch_term.Exited != 0) {
        std.debug.print("\nLaunch failed!\n", .{});
        return error.LaunchFailed;
    }

    std.debug.print("\nApp launched!\n", .{});

    // Show logcat hint
    std.debug.print("\nTo view logs:\n", .{});
    std.debug.print("  adb logcat -s sokol,sapp,{s}\n", .{config.app_name});
}

// ============================================================================
// Android Emulator Command
// ============================================================================

fn handleAndroidEmulator(allocator: Allocator, options: AndroidOptions) !void {
    if (options.list_emulators) {
        try listEmulators(allocator);
        return;
    }

    if (options.start_emulator) |name| {
        try startEmulator(allocator, name);
        return;
    }

    // Default: list emulators
    try listEmulators(allocator);
}

fn listEmulators(allocator: Allocator) !void {
    std.debug.print("Available Android emulators:\n\n", .{});

    // Get ANDROID_HOME
    const android_home = std.process.getEnvVarOwned(allocator, "ANDROID_HOME") catch {
        std.debug.print("Error: ANDROID_HOME not set\n", .{});
        std.debug.print("Set ANDROID_HOME to your Android SDK path\n", .{});
        return error.AndroidHomeNotSet;
    };
    defer allocator.free(android_home);

    const emulator_path = try std.fs.path.join(allocator, &.{ android_home, "emulator", "emulator" });
    defer allocator.free(emulator_path);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ emulator_path, "-list-avds" },
    }) catch |err| {
        std.debug.print("Error running emulator: {}\n", .{err});
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.stdout.len == 0) {
        std.debug.print("No emulators found.\n", .{});
        std.debug.print("Create one in Android Studio: Tools > AVD Manager\n", .{});
        return;
    }

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) {
            std.debug.print("  {s}\n", .{trimmed});
        }
    }

    std.debug.print("\nTo start an emulator:\n", .{});
    std.debug.print("  labelle android emulator <name>\n", .{});
}

fn startEmulator(allocator: Allocator, name: []const u8) !void {
    std.debug.print("Starting emulator: {s}...\n", .{name});

    // Get ANDROID_HOME
    const android_home = std.process.getEnvVarOwned(allocator, "ANDROID_HOME") catch {
        std.debug.print("Error: ANDROID_HOME not set\n", .{});
        return error.AndroidHomeNotSet;
    };
    defer allocator.free(android_home);

    const emulator_path = try std.fs.path.join(allocator, &.{ android_home, "emulator", "emulator" });
    defer allocator.free(emulator_path);

    // Start emulator in background
    var child = std.process.Child.init(&.{
        emulator_path,
        "-avd",
        name,
        "-gpu",
        "swiftshader_indirect",
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    _ = try child.spawn();

    std.debug.print("Emulator starting in background...\n", .{});
    std.debug.print("\nWait for it to boot, then run:\n", .{});
    std.debug.print("  labelle android run\n", .{});
}

// ============================================================================
// Build File Generation
// ============================================================================

fn ensureAndroidBuildFiles(allocator: Allocator, project_path: []const u8, config: AndroidConfig, engine_path: ?[]const u8) !void {
    const android_dir = try std.fs.path.join(allocator, &.{ project_path, "android" });
    defer allocator.free(android_dir);

    // Create android directory if it doesn't exist
    std.fs.cwd().makePath(android_dir) catch {};

    // Check if build.zig exists
    const build_zig_path = try std.fs.path.join(allocator, &.{ android_dir, "build.zig" });
    defer allocator.free(build_zig_path);

    std.fs.cwd().access(build_zig_path, .{}) catch {
        // Generate Android build files
        std.debug.print("Generating Android build files...\n", .{});
        try generateAndroidBuildFiles(allocator, project_path, config, engine_path);
    };
}

fn generateAndroidBuildFiles(allocator: Allocator, project_path: []const u8, config: AndroidConfig, engine_path: ?[]const u8) !void {
    const android_dir = try std.fs.path.join(allocator, &.{ project_path, "android" });
    defer allocator.free(android_dir);

    // Create directories
    std.fs.cwd().makePath(android_dir) catch {};

    const apk_build_dir = try std.fs.path.join(allocator, &.{ android_dir, "apk_build" });
    defer allocator.free(apk_build_dir);
    std.fs.cwd().makePath(apk_build_dir) catch {};

    // Sanitize app name
    const sanitized_name = try sanitizeName(allocator, config.app_name);
    defer allocator.free(sanitized_name);

    // Generate build.zig.zon based on whether we have a local engine path or not
    const build_zon_content = if (engine_path) |local_engine_path| blk: {
        // Using local engine - compute relative path from android/ to engine
        const abs_android_dir = try std.fs.cwd().realpathAlloc(allocator, android_dir);
        defer allocator.free(abs_android_dir);

        const abs_engine_path = try std.fs.cwd().realpathAlloc(allocator, local_engine_path);
        defer allocator.free(abs_engine_path);

        const rel_engine_path = try std.fs.path.relative(allocator, abs_android_dir, abs_engine_path);
        defer allocator.free(rel_engine_path);

        break :blk try generateAndroidBuildZonWithPath(allocator, sanitized_name, rel_engine_path);
    } else blk: {
        // Using versioned engine - read hash from .labelle/
        const engine_hash = readEngineHash(allocator, project_path) catch |err| {
            std.debug.print("Warning: Could not read engine hash from .labelle/build.zig.zon: {}\n", .{err});
            std.debug.print("Please run 'labelle generate' first to set up the project.\n", .{});
            return err;
        };
        defer allocator.free(engine_hash);

        break :blk try generateAndroidBuildZon(allocator, sanitized_name, config.engine_version, engine_hash);
    };
    defer allocator.free(build_zon_content);

    const build_zon_path = try std.fs.path.join(allocator, &.{ android_dir, "build.zig.zon" });
    defer allocator.free(build_zon_path);

    const zon_file = try std.fs.cwd().createFile(build_zon_path, .{});
    defer zon_file.close();
    try zon_file.writeAll(build_zon_content);

    // Generate build.zig
    const build_zig_content = try generateAndroidBuildZig(allocator, config);
    defer allocator.free(build_zig_content);

    const build_zig_path = try std.fs.path.join(allocator, &.{ android_dir, "build.zig" });
    defer allocator.free(build_zig_path);

    const zig_file = try std.fs.cwd().createFile(build_zig_path, .{});
    defer zig_file.close();
    try zig_file.writeAll(build_zig_content);

    // Note: android_libc.conf is now generated dynamically by build.zig

    // Generate AndroidManifest.xml
    const manifest_content = try generateAndroidManifest(allocator, config);
    defer allocator.free(manifest_content);

    const manifest_path = try std.fs.path.join(allocator, &.{ apk_build_dir, "AndroidManifest.xml" });
    defer allocator.free(manifest_path);

    const manifest_file = try std.fs.cwd().createFile(manifest_path, .{});
    defer manifest_file.close();
    try manifest_file.writeAll(manifest_content);

    // Generate android_main.zig in project root if it doesn't exist
    const android_main_path = try std.fs.path.join(allocator, &.{ project_path, "android_main.zig" });
    defer allocator.free(android_main_path);

    std.fs.cwd().access(android_main_path, .{}) catch {
        const android_main_content = @embedFile("templates/android_main.zig");
        const main_file = try std.fs.cwd().createFile(android_main_path, .{});
        defer main_file.close();
        try main_file.writeAll(android_main_content);
        std.debug.print("Generated: {s}\n", .{android_main_path});
    };

    std.debug.print("Generated Android build files in: {s}\n", .{android_dir});
}

fn generateAndroidBuildZon(allocator: Allocator, app_name: []const u8, engine_version: []const u8, engine_hash: []const u8) ![]const u8 {
    // Generate fingerprint from app name
    var fingerprint: u64 = 0;
    for (app_name) |c| {
        fingerprint = fingerprint *% 31 +% c;
    }
    fingerprint ^= 0xA11D201D; // Add Android-specific salt

    return std.fmt.allocPrint(allocator,
        \\.{{
        \\    .fingerprint = 0x{x:0>16},
        \\    .name = .{s}_android,
        \\    .version = "0.1.0",
        \\    .dependencies = .{{
        \\        .@"labelle-engine" = .{{
        \\            .url = "git+https://github.com/labelle-toolkit/labelle-engine#v{s}",
        \\            .hash = "{s}",
        \\        }},
        \\    }},
        \\    .paths = .{{ "build.zig", "build.zig.zon" }},
        \\}}
        \\
    , .{ fingerprint, app_name, engine_version, engine_hash });
}

fn generateAndroidBuildZonWithPath(allocator: Allocator, app_name: []const u8, engine_path: []const u8) ![]const u8 {
    // Generate fingerprint from app name
    var fingerprint: u64 = 0;
    for (app_name) |c| {
        fingerprint = fingerprint *% 31 +% c;
    }
    fingerprint ^= 0xA11D201D; // Add Android-specific salt

    return std.fmt.allocPrint(allocator,
        \\.{{
        \\    .fingerprint = 0x{x:0>16},
        \\    .name = .{s}_android,
        \\    .version = "0.1.0",
        \\    .dependencies = .{{
        \\        .@"labelle-engine" = .{{
        \\            .path = "{s}",
        \\        }},
        \\    }},
        \\    .paths = .{{ "build.zig", "build.zig.zon" }},
        \\}}
        \\
    , .{ fingerprint, app_name, engine_path });
}

fn generateAndroidBuildZig(allocator: Allocator, config: AndroidConfig) ![]const u8 {
    const sanitized_name = try sanitizeName(allocator, config.app_name);
    defer allocator.free(sanitized_name);

    return std.fmt.allocPrint(allocator,
        \\//! Android Build Configuration - Auto-generated by labelle CLI
        \\//!
        \\//! Usage:
        \\//!   zig build android    # Build for Android (arm64)
        \\
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\
        \\// Android SDK configuration
        \\const ANDROID_API_VERSION = "{d}";
        \\
        \\const APP_NAME = "{s}";
        \\
        \\pub fn build(b: *std.Build) !void {{
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\
        \\    // Android target: aarch64-linux-android
        \\    const android_target = b.resolveTargetQuery(.{{
        \\        .cpu_arch = .aarch64,
        \\        .os_tag = .linux,
        \\        .abi = .android,
        \\    }});
        \\
        \\    // Get ANDROID_HOME
        \\    const android_home = std.process.getEnvVarOwned(b.allocator, "ANDROID_HOME") catch {{
        \\        std.log.err("ANDROID_HOME environment variable not set", .{{}});
        \\        return;
        \\    }};
        \\
        \\    // Auto-detect NDK version (find highest version in ndk/ directory)
        \\    const ndk_dir = try std.fs.path.join(b.allocator, &.{{ android_home, "ndk" }});
        \\    var ndk_version: ?[]const u8 = null;
        \\    if (std.fs.openDirAbsolute(ndk_dir, .{{ .iterate = true }})) |dir| {{
        \\        var d = dir;
        \\        var iter = d.iterate();
        \\        while (iter.next() catch null) |entry| {{
        \\            if (entry.kind == .directory) {{
        \\                // Keep highest version (simple string compare works for semver)
        \\                if (ndk_version == null or std.mem.order(u8, entry.name, ndk_version.?) == .gt) {{
        \\                    ndk_version = b.allocator.dupe(u8, entry.name) catch null;
        \\                }}
        \\            }}
        \\        }}
        \\    }} else |_| {{}}
        \\
        \\    if (ndk_version == null) {{
        \\        std.log.err("No NDK found in {{s}}/ndk/", .{{android_home}});
        \\        return;
        \\    }}
        \\
        \\    const ndk_path = try std.fs.path.join(b.allocator, &.{{ android_home, "ndk", ndk_version.? }});
        \\
        \\    // Detect host OS for NDK toolchain
        \\    const host_tag: []const u8 = switch (builtin.os.tag) {{
        \\        .macos => "darwin-x86_64",
        \\        .linux => "linux-x86_64",
        \\        .windows => "windows-x86_64",
        \\        else => @panic("Unsupported host OS for Android NDK"),
        \\    }};
        \\
        \\    const sysroot = try std.fs.path.join(b.allocator, &.{{ ndk_path, "toolchains", "llvm", "prebuilt", host_tag, "sysroot" }});
        \\    const arch_inc_path = try std.fs.path.join(b.allocator, &.{{ sysroot, "usr", "include", "aarch64-linux-android" }});
        \\    const inc_path = try std.fs.path.join(b.allocator, &.{{ sysroot, "usr", "include" }});
        \\    const lib_path = try std.fs.path.join(b.allocator, &.{{ sysroot, "usr", "lib", "aarch64-linux-android", ANDROID_API_VERSION }});
        \\
        \\    // Get labelle-engine dependency
        \\    const engine_dep = b.dependency("labelle-engine", .{{
        \\        .target = android_target,
        \\        .optimize = optimize,
        \\        .backend = .sokol,
        \\        .physics = {s},
        \\    }});
        \\    const engine_mod = engine_dep.module("labelle-engine");
        \\
        \\    // Get sokol dependency for Android support
        \\    const sokol_dep = engine_dep.builder.dependency("sokol", .{{
        \\        .target = android_target,
        \\        .optimize = optimize,
        \\        .gles3 = true,
        \\        .dont_link_system_libs = true,
        \\    }});
        \\
        \\    // Configure sokol_clib with NDK paths
        \\    const sokol_clib = sokol_dep.artifact("sokol_clib");
        \\    sokol_clib.root_module.addSystemIncludePath(.{{ .cwd_relative = arch_inc_path }});
        \\    sokol_clib.root_module.addSystemIncludePath(.{{ .cwd_relative = inc_path }});
        \\    sokol_clib.root_module.addLibraryPath(.{{ .cwd_relative = lib_path }});
        \\
        \\    // Create main module from project's main.zig
        \\    const main_mod = b.createModule(.{{
        \\        .root_source_file = b.path("../main.zig"),
        \\        .target = android_target,
        \\        .optimize = optimize,
        \\        .imports = &.{{
        \\            .{{ .name = "labelle-engine", .module = engine_mod }},
        \\        }},
        \\    }});
        \\
        \\    // Create Android shared library
        \\    const android_lib = b.addLibrary(.{{
        \\        .name = APP_NAME,
        \\        .linkage = .dynamic,
        \\        .root_module = b.createModule(.{{
        \\            .root_source_file = b.path("../android_main.zig"),
        \\            .target = android_target,
        \\            .optimize = optimize,
        \\            .link_libc = true,
        \\            .imports = &.{{
        \\                .{{ .name = "labelle-engine", .module = engine_mod }},
        \\                .{{ .name = "main", .module = main_mod }},
        \\            }},
        \\        }}),
        \\    }});
        \\
        \\    // Generate android_libc.conf dynamically
        \\    const libc_conf = try std.fmt.allocPrint(b.allocator,
        \\        \\# Android NDK libc configuration (generated)
        \\        \\include_dir={{s}}
        \\        \\sys_include_dir={{s}}
        \\        \\crt_dir={{s}}
        \\        \\msvc_lib_dir=
        \\        \\kernel32_lib_dir=
        \\        \\gcc_dir=
        \\        \\
        \\    , .{{ inc_path, arch_inc_path, lib_path }});
        \\    const libc_conf_file = b.addWriteFiles();
        \\    const libc_path = libc_conf_file.add("android_libc.conf", libc_conf);
        \\
        \\    // Set custom libc for Android NDK
        \\    android_lib.setLibCFile(libc_path);
        \\
        \\    // Set sysroot for NDK toolchain
        \\    android_lib.root_module.addSystemIncludePath(.{{ .cwd_relative = arch_inc_path }});
        \\    android_lib.root_module.addSystemIncludePath(.{{ .cwd_relative = inc_path }});
        \\
        \\    // Link sokol for Android
        \\    android_lib.root_module.linkLibrary(sokol_dep.artifact("sokol_clib"));
        \\
        \\    // Add library path for linking
        \\    android_lib.root_module.addLibraryPath(.{{ .cwd_relative = lib_path }});
        \\
        \\    // Link Android system libraries
        \\    android_lib.root_module.linkSystemLibrary("GLESv3", .{{}});
        \\    android_lib.root_module.linkSystemLibrary("EGL", .{{}});
        \\    android_lib.root_module.linkSystemLibrary("android", .{{}});
        \\    android_lib.root_module.linkSystemLibrary("log", .{{}});
        \\    android_lib.root_module.linkSystemLibrary("aaudio", .{{}});
        \\
        \\    // Install the shared library
        \\    const install_lib = b.addInstallArtifact(android_lib, .{{}});
        \\
        \\    const android_step = b.step("android", "Build for Android");
        \\    android_step.dependOn(&install_lib.step);
        \\}}
        \\
    , .{
        config.target_sdk,
        sanitized_name,
        if (config.physics_enabled) "true" else "false",
    });
}

fn generateAndroidManifest(allocator: Allocator, config: AndroidConfig) ![]const u8 {
    const sanitized_name = try sanitizeName(allocator, config.app_name);
    defer allocator.free(sanitized_name);

    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<manifest xmlns:android="http://schemas.android.com/apk/res/android"
        \\    package="{s}"
        \\    android:versionCode="{d}"
        \\    android:versionName="{s}">
        \\
        \\    <uses-sdk
        \\        android:minSdkVersion="{d}"
        \\        android:targetSdkVersion="{d}" />
        \\
        \\    <uses-feature android:glEsVersion="0x00030000" android:required="true" />
        \\
        \\    <application
        \\        android:allowBackup="false"
        \\        android:label="{s}"
        \\        android:hasCode="false">
        \\
        \\        <activity
        \\            android:name="android.app.NativeActivity"
        \\            android:label="{s}"
        \\            android:configChanges="orientation|screenSize|screenLayout|keyboardHidden"
        \\            android:exported="true">
        \\
        \\            <meta-data
        \\                android:name="android.app.lib_name"
        \\                android:value="{s}" />
        \\
        \\            <intent-filter>
        \\                <action android:name="android.intent.action.MAIN" />
        \\                <category android:name="android.intent.category.LAUNCHER" />
        \\            </intent-filter>
        \\        </activity>
        \\    </application>
        \\</manifest>
        \\
    , .{
        config.package_name,
        config.version_code,
        config.version_name,
        config.min_sdk,
        config.target_sdk,
        config.app_name,
        config.app_name,
        sanitized_name,
    });
}

// ============================================================================
// APK Packaging
// ============================================================================

fn packageApk(allocator: Allocator, project_path: []const u8, config: AndroidConfig) !void {
    const android_dir = try std.fs.path.join(allocator, &.{ project_path, "android" });
    defer allocator.free(android_dir);

    const apk_build_dir = try std.fs.path.join(allocator, &.{ android_dir, "apk_build" });
    defer allocator.free(apk_build_dir);

    const sanitized_name = try sanitizeName(allocator, config.app_name);
    defer allocator.free(sanitized_name);

    // Get ANDROID_HOME
    const android_home = std.process.getEnvVarOwned(allocator, "ANDROID_HOME") catch {
        std.debug.print("Error: ANDROID_HOME not set\n", .{});
        return error.AndroidHomeNotSet;
    };
    defer allocator.free(android_home);

    // Paths to Android tools
    const build_tools = try std.fs.path.join(allocator, &.{ android_home, "build-tools", "34.0.0" });
    defer allocator.free(build_tools);

    const aapt2 = try std.fs.path.join(allocator, &.{ build_tools, "aapt2" });
    defer allocator.free(aapt2);

    const zipalign = try std.fs.path.join(allocator, &.{ build_tools, "zipalign" });
    defer allocator.free(zipalign);

    const apksigner = try std.fs.path.join(allocator, &.{ build_tools, "apksigner" });
    defer allocator.free(apksigner);

    const android_jar = try std.fs.path.join(allocator, &.{ android_home, "platforms", "android-34", "android.jar" });
    defer allocator.free(android_jar);

    // Create lib/arm64-v8a directory
    const lib_dir = try std.fs.path.join(allocator, &.{ apk_build_dir, "lib", "arm64-v8a" });
    defer allocator.free(lib_dir);
    std.fs.cwd().makePath(lib_dir) catch {};

    // Copy .so file to lib directory
    const so_src = try std.fmt.allocPrint(allocator, "{s}/zig-out/lib/lib{s}.so", .{ android_dir, sanitized_name });
    defer allocator.free(so_src);

    const so_dst = try std.fmt.allocPrint(allocator, "{s}/lib{s}.so", .{ lib_dir, sanitized_name });
    defer allocator.free(so_dst);

    std.fs.cwd().copyFile(so_src, std.fs.cwd(), so_dst, .{}) catch |err| {
        std.debug.print("Error copying .so file: {}\n", .{err});
        std.debug.print("  Source: {s}\n", .{so_src});
        return err;
    };

    // Step 1: Compile AndroidManifest.xml
    std.debug.print("  Compiling manifest...\n", .{});

    const manifest_path = try std.fs.path.join(allocator, &.{ apk_build_dir, "AndroidManifest.xml" });
    defer allocator.free(manifest_path);

    const compiled_manifest = try std.fs.path.join(allocator, &.{ apk_build_dir, "AndroidManifest.flat" });
    defer allocator.free(compiled_manifest);

    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ aapt2, "compile", manifest_path, "-o", apk_build_dir },
    }) catch |err| {
        std.debug.print("aapt2 compile failed: {}\n", .{err});
        return err;
    };

    // Step 2: Link into APK
    std.debug.print("  Linking APK...\n", .{});

    const unaligned_apk = try std.fmt.allocPrint(allocator, "{s}/{s}-unaligned.apk", .{ apk_build_dir, config.app_name });
    defer allocator.free(unaligned_apk);

    const link_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            aapt2,
            "link",
            "-o",
            unaligned_apk,
            "-I",
            android_jar,
            "--manifest",
            manifest_path,
            "--min-sdk-version",
            try std.fmt.allocPrint(allocator, "{d}", .{config.min_sdk}),
            "--target-sdk-version",
            try std.fmt.allocPrint(allocator, "{d}", .{config.target_sdk}),
        },
    }) catch |err| {
        std.debug.print("aapt2 link failed: {}\n", .{err});
        return err;
    };
    defer allocator.free(link_result.stdout);
    defer allocator.free(link_result.stderr);

    // Step 3: Add native library to APK
    std.debug.print("  Adding native library...\n", .{});

    // Use zip to add the lib directory
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zip", "-r", unaligned_apk, "lib" },
        .cwd = apk_build_dir,
    }) catch |err| {
        std.debug.print("Failed to add library to APK: {}\n", .{err});
        return err;
    };

    // Step 4: Align the APK
    std.debug.print("  Aligning APK...\n", .{});

    const aligned_apk = try std.fmt.allocPrint(allocator, "{s}/{s}-aligned.apk", .{ apk_build_dir, config.app_name });
    defer allocator.free(aligned_apk);

    // Remove old aligned APK if it exists
    std.fs.cwd().deleteFile(aligned_apk) catch {};

    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ zipalign, "-v", "4", unaligned_apk, aligned_apk },
    }) catch |err| {
        std.debug.print("zipalign failed: {}\n", .{err});
        return err;
    };

    // Step 5: Create debug keystore if needed
    const keystore_path = try std.fs.path.join(allocator, &.{ apk_build_dir, "debug.keystore" });
    defer allocator.free(keystore_path);

    std.fs.cwd().access(keystore_path, .{}) catch {
        std.debug.print("  Creating debug keystore...\n", .{});

        _ = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{
                "keytool",
                "-genkeypair",
                "-keystore",
                keystore_path,
                "-alias",
                "androiddebugkey",
                "-keyalg",
                "RSA",
                "-keysize",
                "2048",
                "-validity",
                "10000",
                "-storepass",
                "android",
                "-keypass",
                "android",
                "-dname",
                "CN=Debug,O=Debug,C=US",
            },
        }) catch |err| {
            std.debug.print("keytool failed: {}\n", .{err});
            return err;
        };
    };

    // Step 6: Sign the APK
    std.debug.print("  Signing APK...\n", .{});

    const final_apk = try std.fmt.allocPrint(allocator, "{s}/{s}.apk", .{ apk_build_dir, config.app_name });
    defer allocator.free(final_apk);

    // Copy aligned to final (apksigner signs in place)
    std.fs.cwd().copyFile(aligned_apk, std.fs.cwd(), final_apk, .{}) catch |err| {
        std.debug.print("Failed to copy APK: {}\n", .{err});
        return err;
    };

    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            apksigner,
            "sign",
            "--ks",
            keystore_path,
            "--ks-key-alias",
            "androiddebugkey",
            "--ks-pass",
            "pass:android",
            "--key-pass",
            "pass:android",
            final_apk,
        },
    }) catch |err| {
        std.debug.print("apksigner failed: {}\n", .{err});
        return err;
    };

    // Clean up intermediate files
    std.fs.cwd().deleteFile(unaligned_apk) catch {};
    std.fs.cwd().deleteFile(aligned_apk) catch {};
}

// ============================================================================
// Helper Functions
// ============================================================================

fn sanitizeName(allocator: Allocator, name: []const u8) ![]const u8 {
    var result = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        result[i] = if (std.ascii.isAlphanumeric(c) or c == '_') c else '_';
    }
    return result;
}

fn readEngineHash(allocator: Allocator, project_path: []const u8) ![]const u8 {
    const build_zon_path = try std.fs.path.join(allocator, &.{ project_path, ".labelle", "build.zig.zon" });
    defer allocator.free(build_zon_path);

    const file = try std.fs.cwd().openFile(build_zon_path, .{});
    defer file.close();

    const stat = try file.stat();
    const content = try allocator.alloc(u8, stat.size);
    defer allocator.free(content);
    _ = try file.readAll(content);

    // Look for .hash = "labelle_engine-..." pattern
    const hash_prefix = ".hash = \"labelle_engine-";
    if (std.mem.indexOf(u8, content, hash_prefix)) |start| {
        const hash_start = start + ".hash = \"".len;
        if (std.mem.indexOfPos(u8, content, hash_start, "\"")) |end| {
            return try allocator.dupe(u8, content[hash_start..end]);
        }
    }

    return error.HashNotFound;
}

// ============================================================================
// Help
// ============================================================================

fn printAndroidHelp() void {
    std.debug.print(
        \\Android Commands
        \\
        \\Usage: labelle android <command> [options]
        \\
        \\Commands:
        \\  build           Build APK for Android
        \\  install         Install APK to device/emulator
        \\  run             Build, install, and run
        \\  emulator        List or start emulators
        \\
        \\Build Options:
        \\  --release, -r   Build release APK
        \\  --arm32         Target armv7a (older devices)
        \\  --x86_64        Target x86_64 (emulator)
        \\
        \\Install/Run Options:
        \\  --device=ID     Target specific device (from 'adb devices')
        \\
        \\Emulator Options:
        \\  --list, -l      List available emulators
        \\  --start=NAME    Start a specific emulator
        \\
        \\Configuration:
        \\  Create android.labelle in your project for Android-specific settings:
        \\
        \\  .{{
        \\      .app_name = "My Game",
        \\      .package_name = "com.example.mygame",
        \\      .version_code = 1,
        \\      .version_name = "1.0",
        \\      .min_sdk = 26,
        \\      .target_sdk = 34,
        \\  }}
        \\
        \\Requirements:
        \\  - ANDROID_HOME environment variable set to Android SDK path
        \\  - Android NDK 26.1.10909125 installed
        \\  - Android SDK Build-Tools 34.0.0
        \\  - Java (for keytool)
        \\
        \\Examples:
        \\  labelle android build                 # Build debug APK
        \\  labelle android build --release      # Build release APK
        \\  labelle android run                   # Build and run on device
        \\  labelle android emulator --list       # List emulators
        \\  labelle android emulator Pixel_8      # Start Pixel 8 emulator
        \\
    , .{});
}
