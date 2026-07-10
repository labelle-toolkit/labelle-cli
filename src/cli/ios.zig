/// iOS build, deployment, and Xcode project generation for labelle-cli.
const std = @import("std");
const project_config = @import("project_config.zig");
const runner = @import("runner.zig");
const config = @import("config.zig");

/// Deploy the built iOS binary to the iOS Simulator.
/// Expects the binary at `target_dir/zig-out/bin/game`.
pub fn deployToSimulator(allocator: std.mem.Allocator, target_dir: []const u8, cfg: project_config.ProjectConfig) !void {
    const ios_cfg = cfg.ios orelse project_config.IosConfig{};
    const bundle_id = if (ios_cfg.bundle_id.len > 0) ios_cfg.bundle_id else try defaultBundleId(allocator, cfg.name);
    const app_name = if (ios_cfg.app_name.len > 0) ios_cfg.app_name else cfg.title;

    // Path to simulator binary
    const binary_path = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "bin", "game" });
    defer allocator.free(binary_path);

    // Check binary exists
    std.Io.Dir.cwd().access(config.globalIo(), binary_path, .{}) catch {
        std.debug.print("labelle: iOS binary not found at {s}\n", .{binary_path});
        return error.BinaryNotFound;
    };

    // Create .app bundle directory
    const app_bundle = try std.fs.path.join(allocator, &.{ target_dir, "game.app" });
    defer allocator.free(app_bundle);

    // Remove old bundle to ensure clean state
    std.Io.Dir.cwd().deleteTree(config.globalIo(), app_bundle) catch {};
    std.Io.Dir.cwd().createDirPath(config.globalIo(), app_bundle) catch {};

    // Copy binary into .app bundle
    const app_binary = try std.fs.path.join(allocator, &.{ app_bundle, "game" });
    defer allocator.free(app_binary);

    try std.Io.Dir.cwd().copyFile(binary_path, std.Io.Dir.cwd(), app_binary, config.globalIo(), .{});

    // Make executable
    _ = std.process.run(allocator, config.globalIo(), .{
        .argv = &.{ "chmod", "+x", app_binary },
    }) catch {};

    // Generate Info.plist
    const info_plist_path = try std.fs.path.join(allocator, &.{ app_bundle, "Info.plist" });
    defer allocator.free(info_plist_path);

    const info_plist = try generateInfoPlist(allocator, bundle_id, app_name, ios_cfg);
    defer allocator.free(info_plist);

    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = info_plist_path, .data = info_plist });

    // Generate LaunchScreen.storyboard
    const launch_path = try std.fs.path.join(allocator, &.{ app_bundle, "LaunchScreen.storyboard" });
    defer allocator.free(launch_path);

    const launch_content = try generateLaunchScreen(allocator, app_name);
    defer allocator.free(launch_content);

    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = launch_path, .data = launch_content });

    // Copy assets into .app bundle
    const assets_src = try std.fs.path.join(allocator, &.{ target_dir, "assets" });
    defer allocator.free(assets_src);

    const assets_dst = try std.fs.path.join(allocator, &.{ app_bundle, "assets" });
    defer allocator.free(assets_dst);

    copyDirectory(allocator, assets_src, assets_dst) catch {
        // No assets directory is fine — not all projects have assets
    };

    // Ensure a simulator is booted
    const udid = try ensureSimulatorBooted(allocator);
    defer allocator.free(udid);

    // Install app on simulator
    std.debug.print("labelle: installing on simulator...\n", .{});
    const install_result = std.process.run(allocator, config.globalIo(), .{ .argv = &.{ "xcrun", "simctl", "install", udid, app_bundle } }) catch |err| {
        std.debug.print("labelle: failed to run simctl install: {}\n", .{err});
        return err;
    };
    defer allocator.free(install_result.stdout);
    defer allocator.free(install_result.stderr);

    if (install_result.term != .exited or install_result.term.exited != 0) {
        std.debug.print("labelle: simulator install failed: {s}\n", .{install_result.stderr});
        return error.InstallFailed;
    }

    // Launch app
    std.debug.print("labelle: launching on simulator...\n", .{});
    const launch_result = std.process.run(allocator, config.globalIo(), .{ .argv = &.{ "xcrun", "simctl", "launch", udid, bundle_id } }) catch |err| {
        std.debug.print("labelle: failed to run simctl launch: {}\n", .{err});
        return err;
    };
    defer allocator.free(launch_result.stdout);
    defer allocator.free(launch_result.stderr);

    if (launch_result.term != .exited or launch_result.term.exited != 0) {
        std.debug.print("labelle: simulator launch failed: {s}\n", .{launch_result.stderr});
        return error.LaunchFailed;
    }

    // Parse PID from output (format: "com.bundle.id: 12345")
    if (std.mem.indexOf(u8, launch_result.stdout, ": ")) |colon_pos| {
        const pid = std.mem.trim(u8, launch_result.stdout[colon_pos + 2 ..], &.{ ' ', '\n', '\r' });
        std.debug.print("labelle: app launched (PID: {s})\n", .{pid});
    } else {
        std.debug.print("labelle: app launched\n", .{});
    }
}

/// Ensure an iOS simulator is booted, boot one if needed.
/// Returns the UDID of the booted simulator.
fn ensureSimulatorBooted(allocator: std.mem.Allocator) ![]const u8 {
    // Check for already-booted simulator
    const list_result = std.process.run(allocator, config.globalIo(), .{ .argv = &.{ "xcrun", "simctl", "list", "devices", "booted", "-j" } }) catch |err| {
        std.debug.print("labelle: failed to list simulators: {}\n", .{err});
        return err;
    };
    defer allocator.free(list_result.stdout);
    defer allocator.free(list_result.stderr);

    // Look for a UDID in the JSON output
    const udid_key = "\"udid\" : \"";
    if (std.mem.indexOf(u8, list_result.stdout, udid_key)) |start| {
        const udid_start = start + udid_key.len;
        if (std.mem.indexOfPos(u8, list_result.stdout, udid_start, "\"")) |end| {
            const udid = list_result.stdout[udid_start..end];
            std.debug.print("labelle: using booted simulator {s}\n", .{udid});
            return allocator.dupe(u8, udid);
        }
    }

    // No simulator booted — find an available iPhone and boot it
    std.debug.print("labelle: no simulator booted, starting one...\n", .{});

    const avail_result = std.process.run(allocator, config.globalIo(), .{ .argv = &.{ "xcrun", "simctl", "list", "devices", "available" } }) catch {
        return allocator.dupe(u8, "booted");
    };
    defer allocator.free(avail_result.stdout);
    defer allocator.free(avail_result.stderr);

    // Find an iPhone with a UDID
    var lines = std.mem.splitScalar(u8, avail_result.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "iPhone") != null) {
            if (std.mem.indexOf(u8, line, "(")) |paren_start| {
                if (std.mem.indexOfPos(u8, line, paren_start, ")")) |paren_end| {
                    const udid = line[paren_start + 1 .. paren_end];
                    if (udid.len == 36 and udid[8] == '-') {
                        std.debug.print("labelle: booting {s}\n", .{std.mem.trim(u8, line, " \t")});

                        _ = std.process.run(allocator, config.globalIo(), .{ .argv = &.{ "xcrun", "simctl", "boot", udid } }) catch null;

                        // std.Thread.sleep removed in 0.16 — would re-add via Io.Clock.Duration.sleep; harmless to skip in dev path

                        return allocator.dupe(u8, udid);
                    }
                }
            }
        }
    }

    return allocator.dupe(u8, "booted");
}

/// Copy directory recursively. Silently returns if source doesn't exist.
fn copyDirectory(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    var src_dir = try std.Io.Dir.cwd().openDir(config.globalIo(), src, .{ .iterate = true });
    defer src_dir.close(config.globalIo());

    std.Io.Dir.cwd().createDirPath(config.globalIo(), dst) catch {};

    var iter = src_dir.iterate();
    while (try iter.next(config.globalIo())) |entry| {
        const src_path = try std.fs.path.join(allocator, &.{ src, entry.name });
        defer allocator.free(src_path);

        const dst_path = try std.fs.path.join(allocator, &.{ dst, entry.name });
        defer allocator.free(dst_path);

        switch (entry.kind) {
            .file => {
                std.Io.Dir.cwd().copyFile(src_path, std.Io.Dir.cwd(), dst_path, config.globalIo(), .{}) catch {};
            },
            .directory => {
                try copyDirectory(allocator, src_path, dst_path);
            },
            else => {},
        }
    }
}

/// Generate Info.plist with full iOS metadata.
fn generateInfoPlist(allocator: std.mem.Allocator, bundle_id: []const u8, app_name: []const u8, ios_cfg: project_config.IosConfig) ![]const u8 {
    const orientations = switch (ios_cfg.orientation) {
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
        \\    <string>game</string>
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
        \\    <key>UIDeviceFamily</key>
        \\{s}
        \\    <key>MinimumOSVersion</key>
        \\    <string>{s}</string>
        \\</dict>
        \\</plist>
        \\
    , .{ app_name, bundle_id, app_name, orientations, deviceFamilyPlist(ios_cfg.device_family), ios_cfg.minimum_ios });
}

// ============================================================================
// labelle ios subcommand
// ============================================================================

/// Handle `labelle ios <subcommand>` — build, xcode, run for iOS.
pub fn handleIos(allocator: std.mem.Allocator, args: []const []const u8, cfg: project_config.ProjectConfig, target_dir: []const u8) !void {
    if (args.len == 0) {
        printIosHelp();
        return;
    }

    const subcmd = args[0];
    const rest = if (args.len > 1) args[1..] else &[_][]const u8{};

    if (std.mem.eql(u8, subcmd, "build")) {
        var device = false;
        var release = false;
        for (rest) |arg| {
            if (std.mem.eql(u8, arg, "--device") or std.mem.eql(u8, arg, "-d")) device = true;
            if (std.mem.eql(u8, arg, "--release") or std.mem.eql(u8, arg, "-r")) release = true;
        }
        try iosBuild(allocator, target_dir, device, release);
    } else if (std.mem.eql(u8, subcmd, "xcode")) {
        var team_id: ?[]const u8 = null;
        for (rest) |arg| {
            if (std.mem.startsWith(u8, arg, "--team-id=")) team_id = arg["--team-id=".len..];
        }
        try iosXcode(allocator, target_dir, cfg, team_id);
    } else if (std.mem.eql(u8, subcmd, "run")) {
        var device = false;
        for (rest) |arg| {
            if (std.mem.eql(u8, arg, "--device") or std.mem.eql(u8, arg, "-d")) device = true;
        }
        if (device) {
            std.debug.print("labelle: device deployment requires code signing.\n", .{});
            std.debug.print("  Run 'labelle ios xcode' first, then deploy via Xcode.\n", .{});
        } else {
            try iosBuild(allocator, target_dir, false, false);
            try deployToSimulator(allocator, target_dir, cfg);
        }
    } else if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        printIosHelp();
    } else {
        std.debug.print("labelle ios: unknown command '{s}'\n\n", .{subcmd});
        printIosHelp();
    }
}

fn printIosHelp() void {
    std.debug.print(
        \\iOS Commands
        \\
        \\Usage: labelle ios <command> [options]
        \\
        \\Commands:
        \\  build       Build for iOS (simulator by default)
        \\  xcode       Generate Xcode project for device deployment
        \\  run         Build and run on simulator
        \\
        \\Build Options:
        \\  --device            Build for iOS device (arm64)
        \\  --release           Build release configuration
        \\
        \\Xcode Options:
        \\  --team-id=ID        Apple Developer Team ID for signing
        \\
        \\Run Options:
        \\  --device            Deploy to device (requires Xcode signing)
        \\
        \\Examples:
        \\  labelle ios build                Build for iOS simulator
        \\  labelle ios build --device       Build for iOS device
        \\  labelle ios xcode                Generate Xcode project
        \\  labelle ios run                  Run on simulator
        \\
    , .{});
}

/// Detect the known iOS-simulator ARM NEON/SIMD compile failure (labelle-cli#4, #5).
///
/// The `aarch64-ios-simulator` target compiles ARM SIMD (NEON) intrinsics that
/// require CPU features the simulator toolchain does not enable, producing
/// `zig cc`/clang errors like:
///
///   always_inline function 'vdupq_n_u64' requires target feature 'altnzcv',
///   but would be inlined into function ... compiled without support for 'altnzcv'
///
/// The durable fix lives in the plugins that compile ARM SIMD — they must select
/// their scalar fallback for the simulator triple (`os == .ios and abi ==
/// .simulator`), e.g. Box2D's `BOX2D_DISABLE_SIMD` and Clay's non-NEON hash path.
/// The CLI cannot influence those C compiles directly (it only invokes `zig build`
/// on the generated project), so it recognises this failure signature and points
/// the user at the fix instead of dumping a wall of intrinsic errors.
///
/// Returns true when `stderr` carries the feature-mismatch signature paired with a
/// NEON marker (so a generic "requires target feature" is not mistaken for this).
fn isSimdFeatureBuildError(stderr: []const u8) bool {
    if (std.mem.indexOf(u8, stderr, "requires target feature") == null) return false;
    const neon_markers = [_][]const u8{
        "altnzcv", // ARMv8.5 FEAT_FlagM2 — the feature the intrinsics demand
        "vdupq_n_", "vld1", "vst1", "vmulq_", "vaddq_", // common NEON intrinsics
        "arm_neon.h", "neon", "NEON",
    };
    for (neon_markers) |marker| {
        if (std.mem.indexOf(u8, stderr, marker) != null) return true;
    }
    return false;
}

/// Print an actionable hint for the iOS-simulator NEON/SIMD build failure.
fn printSimdBuildHint() void {
    std.debug.print(
        \\
        \\labelle: this looks like the iOS-simulator ARM NEON/SIMD compile failure
        \\  (labelle-cli#4 / #5). The aarch64-ios-simulator target compiles NEON
        \\  intrinsics that its toolchain does not enable.
        \\
        \\  A plugin that compiles ARM SIMD must fall back to scalar for the
        \\  simulator triple (os == .ios and abi == .simulator). In the plugin's
        \\  build.zig, gate its SIMD-disable on that target:
        \\
        \\    Box2D: add `BOX2D_DISABLE_SIMD=1` (like the existing emscripten branch)
        \\    Clay:  compile the non-NEON hash path
        \\
        \\  Building for a physical device (`labelle ios build --device`) avoids
        \\  this, as does upgrading the toolchain past the 0.15.2-era clang bug.
        \\
    , .{});
}

/// Build the iOS target (simulator or device).
fn iosBuild(allocator: std.mem.Allocator, target_dir: []const u8, device: bool, release: bool) !void {
    // Simulator is the default target; `--device` switches to the physical-device
    // arm64 build. The NEON/SIMD failure below only affects the simulator triple.
    const simulator = !device;
    const target_label: []const u8 = if (device) "iOS device (arm64)" else "iOS simulator (arm64)";
    const config_label: []const u8 = if (release) "Release" else "Debug";
    std.debug.print("labelle: building for {s} ({s})...\n", .{ target_label, config_label });

    // Managed Zig (cli#279) — resolve against the generated target dir; it
    // has no project.labelle, so this falls back to the CLI's default Zig.
    const zig_exe = try runner.resolveZigExe(allocator, target_dir);
    defer allocator.free(zig_exe);

    var argv_buf: [8][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = zig_exe;
    argc += 1;
    argv_buf[argc] = "build";
    argc += 1;
    if (device) {
        argv_buf[argc] = "-Ddevice=true";
        argc += 1;
    }
    if (release) {
        argv_buf[argc] = "-Doptimize=ReleaseFast";
        argc += 1;
    }

    const result = try runner.runZig(allocator, target_dir, argv_buf[0..argc]);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("labelle: build failed:\n{s}\n", .{result.stderr});
            if (simulator and isSimdFeatureBuildError(result.stderr)) printSimdBuildHint();
            return error.BuildFailed;
        },
        else => {
            std.debug.print("labelle: build terminated abnormally\n{s}\n", .{result.stderr});
            return error.BuildFailed;
        },
    }
    std.debug.print("  build ok\n", .{});
}

/// Generate Xcode project for device deployment and code signing.
fn iosXcode(allocator: std.mem.Allocator, target_dir: []const u8, cfg: project_config.ProjectConfig, team_id_override: ?[]const u8) !void {
    const ios_cfg = cfg.ios orelse project_config.IosConfig{};
    const app_name = if (ios_cfg.app_name.len > 0) ios_cfg.app_name else cfg.title;
    const bundle_id = if (ios_cfg.bundle_id.len > 0) ios_cfg.bundle_id else try defaultBundleId(allocator, cfg.name);
    const minimum_ios = ios_cfg.minimum_ios;
    const team_id = team_id_override orelse if (ios_cfg.team_id.len > 0) ios_cfg.team_id else null;

    // Build for device first
    std.debug.print("labelle: step 1 — building for device...\n", .{});
    try iosBuild(allocator, target_dir, true, false);

    // Create xcode output directory next to .labelle/
    const xcode_dir = try std.fs.path.join(allocator, &.{ target_dir, "..", "..", "ios-xcode" });
    defer allocator.free(xcode_dir);

    const sanitized = try sanitizeName(allocator, app_name);
    defer allocator.free(sanitized);

    // Create directory structure
    const xcodeproj_dir = try std.fmt.allocPrint(allocator, "{s}/{s}.xcodeproj", .{ xcode_dir, sanitized });
    defer allocator.free(xcodeproj_dir);

    const app_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ xcode_dir, sanitized });
    defer allocator.free(app_dir);

    const assets_xcassets = try std.fmt.allocPrint(allocator, "{s}/Assets.xcassets/AppIcon.appiconset", .{app_dir});
    defer allocator.free(assets_xcassets);

    std.Io.Dir.cwd().createDirPath(config.globalIo(), xcodeproj_dir) catch {};
    std.Io.Dir.cwd().createDirPath(config.globalIo(), assets_xcassets) catch {};

    // Copy device binary
    const binary_src = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "bin", "game" });
    defer allocator.free(binary_src);

    const binary_dst = try std.fmt.allocPrint(allocator, "{s}/game", .{app_dir});
    defer allocator.free(binary_dst);

    std.Io.Dir.cwd().copyFile(binary_src, std.Io.Dir.cwd(), binary_dst, config.globalIo(), .{}) catch |err| {
        std.debug.print("labelle: could not copy binary: {}\n", .{err});
        std.debug.print("  source: {s}\n", .{binary_src});
        return err;
    };

    // Generate Info.plist
    const info_content = try generateInfoPlist(allocator, bundle_id, app_name, ios_cfg);
    defer allocator.free(info_content);
    const info_path = try std.fmt.allocPrint(allocator, "{s}/Info.plist", .{app_dir});
    defer allocator.free(info_path);
    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = info_path, .data = info_content });

    // Generate LaunchScreen.storyboard
    const launch_content = try generateLaunchScreen(allocator, app_name);
    defer allocator.free(launch_content);
    const launch_path = try std.fmt.allocPrint(allocator, "{s}/LaunchScreen.storyboard", .{app_dir});
    defer allocator.free(launch_path);
    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = launch_path, .data = launch_content });

    // Generate Assets.xcassets
    const assets_json = try std.fmt.allocPrint(allocator, "{s}/Assets.xcassets/Contents.json", .{app_dir});
    defer allocator.free(assets_json);
    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = assets_json, .data = "{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}" });

    const icon_json = try std.fmt.allocPrint(allocator, "{s}/Contents.json", .{assets_xcassets});
    defer allocator.free(icon_json);
    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = icon_json, .data = "{\n  \"images\" : [\n    {\n      \"idiom\" : \"universal\",\n      \"platform\" : \"ios\",\n      \"size\" : \"1024x1024\"\n    }\n  ],\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}" });

    // Copy assets
    const game_assets = try std.fs.path.join(allocator, &.{ target_dir, "assets" });
    defer allocator.free(game_assets);
    const xcode_assets = try std.fmt.allocPrint(allocator, "{s}/assets", .{app_dir});
    defer allocator.free(xcode_assets);
    copyDirectory(allocator, game_assets, xcode_assets) catch {};

    // Generate project.pbxproj
    const pbxproj_path = try std.fmt.allocPrint(allocator, "{s}/project.pbxproj", .{xcodeproj_dir});
    defer allocator.free(pbxproj_path);

    const pbxproj = try generatePbxproj(allocator, sanitized, bundle_id, minimum_ios, ios_cfg.device_family, team_id);
    defer allocator.free(pbxproj);
    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = pbxproj_path, .data = pbxproj });

    std.debug.print("\nlabelle: Xcode project generated!\n", .{});
    std.debug.print("  location: ios-xcode/{s}.xcodeproj\n\n", .{sanitized});
    std.debug.print("Next steps:\n", .{});
    std.debug.print("  1. open ios-xcode/{s}.xcodeproj\n", .{sanitized});
    std.debug.print("  2. Select your development team in Signing & Capabilities\n", .{});
    std.debug.print("  3. Build and run on device\n", .{});
}

/// Convert device_family string ("1,2") to plist array XML.
fn deviceFamilyPlist(device_family: []const u8) []const u8 {
    if (std.mem.eql(u8, device_family, "1"))
        return "    <array>\n        <integer>1</integer>\n    </array>";
    if (std.mem.eql(u8, device_family, "2"))
        return "    <array>\n        <integer>2</integer>\n    </array>";
    return "    <array>\n        <integer>1</integer>\n        <integer>2</integer>\n    </array>";
}

/// Generate a default bundle ID from project name (e.g. "my_game" → "com.labelle.my-game").
fn defaultBundleId(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "com.labelle.{s}", .{name});
}

/// Sanitize name for identifiers (replace non-alphanumeric with underscores).
fn sanitizeName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var result = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        result[i] = if (std.ascii.isAlphanumeric(c) or c == '_') c else '_';
    }
    return result;
}

/// Generate Xcode project.pbxproj.
fn generatePbxproj(allocator: std.mem.Allocator, app_name: []const u8, bundle_id: []const u8, minimum_ios: []const u8, device_family: []const u8, team_id: ?[]const u8) ![]const u8 {
    const team_setting: []const u8 = if (team_id) |tid| tid else "";
    const team_line: []const u8 = if (team_id != null) "                DEVELOPMENT_TEAM = " else "                // DEVELOPMENT_TEAM not set — configure in Xcode";

    return std.fmt.allocPrint(allocator,
        \\// !$*UTF8*$!
        \\{{
        \\    archiveVersion = 1;
        \\    classes = {{}};
        \\    objectVersion = 56;
        \\    objects = {{
        \\        /* Begin PBXBuildFile section */
        \\        A1000001 /* game in CopyFiles */ = {{isa = PBXBuildFile; fileRef = A2000001; }};
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
        \\        A2000001 /* game */ = {{isa = PBXFileReference; lastKnownFileType = "compiled.mach-o.executable"; path = game; sourceTree = "<group>"; }};
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
        \\        A7000006 /* Release */ = {{
        \\            isa = XCBuildConfiguration;
        \\            buildSettings = {{
        \\                ALWAYS_SEARCH_USER_PATHS = NO;
        \\                IPHONEOS_DEPLOYMENT_TARGET = {s};
        \\                SDKROOT = iphoneos;
        \\            }};
        \\            name = Release;
        \\        }};
        \\        A7000004 /* Debug */ = {{
        \\            isa = XCBuildConfiguration;
        \\            buildSettings = {{
        \\                ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
        \\                CODE_SIGN_STYLE = Automatic;
        \\                CURRENT_PROJECT_VERSION = 1;
        \\                INFOPLIST_FILE = Info.plist;
        \\                INFOPLIST_KEY_CFBundleDisplayName = "{s}";
        \\                INFOPLIST_KEY_LSRequiresIPhoneOS = YES;
        \\                INFOPLIST_KEY_MinimumOSVersion = {s};
        \\                INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
        \\                INFOPLIST_KEY_UILaunchStoryboardName = LaunchScreen;
        \\                INFOPLIST_KEY_UIRequiresFullScreen = YES;
        \\                INFOPLIST_KEY_UIStatusBarHidden = YES;
        \\                MARKETING_VERSION = 1.0;
        \\                PRODUCT_BUNDLE_IDENTIFIER = "{s}";
        \\                PRODUCT_NAME = "$(TARGET_NAME)";
        \\                TARGETED_DEVICE_FAMILY = "{s}";
        \\{s}{s};
        \\            }};
        \\            name = Debug;
        \\        }};
        \\        A7000005 /* Release */ = {{
        \\            isa = XCBuildConfiguration;
        \\            buildSettings = {{
        \\                ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
        \\                CODE_SIGN_STYLE = Automatic;
        \\                CURRENT_PROJECT_VERSION = 1;
        \\                INFOPLIST_FILE = Info.plist;
        \\                INFOPLIST_KEY_CFBundleDisplayName = "{s}";
        \\                INFOPLIST_KEY_LSRequiresIPhoneOS = YES;
        \\                INFOPLIST_KEY_MinimumOSVersion = {s};
        \\                INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
        \\                INFOPLIST_KEY_UILaunchStoryboardName = LaunchScreen;
        \\                INFOPLIST_KEY_UIRequiresFullScreen = YES;
        \\                INFOPLIST_KEY_UIStatusBarHidden = YES;
        \\                MARKETING_VERSION = 1.0;
        \\                PRODUCT_BUNDLE_IDENTIFIER = "{s}";
        \\                PRODUCT_NAME = "$(TARGET_NAME)";
        \\                TARGETED_DEVICE_FAMILY = "{s}";
        \\{s}{s};
        \\            }};
        \\            name = Release;
        \\        }};
        \\        /* End XCBuildConfiguration section */
        \\        /* Begin XCConfigurationList section */
        \\        A7000001 = {{
        \\            isa = XCConfigurationList;
        \\            buildConfigurations = (A7000002, A7000006);
        \\            defaultConfigurationIsVisible = 0;
        \\            defaultConfigurationName = Debug;
        \\        }};
        \\        A7000003 = {{
        \\            isa = XCConfigurationList;
        \\            buildConfigurations = (A7000004, A7000005);
        \\            defaultConfigurationIsVisible = 0;
        \\            defaultConfigurationName = Debug;
        \\        }};
        \\        /* End XCConfigurationList section */
        \\    }};
        \\    rootObject = A8000001;
        \\}}
        \\
    , .{
        // PBXFileReference
        app_name,
        app_name,
        // PBXGroup
        app_name,
        // PBXNativeTarget
        app_name,
        app_name,
        // XCBuildConfiguration - project level (Debug + Release)
        minimum_ios,
        minimum_ios,
        // Debug target config
        app_name,
        minimum_ios,
        bundle_id,
        device_family,
        team_line,
        team_setting,
        // Release target config
        app_name,
        minimum_ios,
        bundle_id,
        device_family,
        team_line,
        team_setting,
    });
}

/// Generate LaunchScreen.storyboard with centered app name.
fn generateLaunchScreen(allocator: std.mem.Allocator, app_name: []const u8) ![]const u8 {
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
    , .{app_name});
}

// ============================================================================
// Tests
// ============================================================================

test "isSimdFeatureBuildError: detects the altnzcv NEON signature" {
    const stderr =
        \\clay.h:1449:21: error: always_inline function 'vdupq_n_u64' requires target feature 'altnzcv',
        \\but would be inlined into function 'Clay__HashData' that is compiled without support for 'altnzcv'
    ;
    try std.testing.expect(isSimdFeatureBuildError(stderr));
}

test "isSimdFeatureBuildError: detects the box2d vdupq_n_f32 signature" {
    const stderr =
        \\error: always_inline function 'vdupq_n_f32' requires target feature 'altnzcv',
        \\but would be inlined into function that is compiled without support for 'altnzcv'
    ;
    try std.testing.expect(isSimdFeatureBuildError(stderr));
}

test "isSimdFeatureBuildError: ignores unrelated feature-mismatch errors" {
    // A "requires target feature" error with no NEON marker must not trip the hint.
    const stderr =
        \\error: always_inline function 'foo' requires target feature 'avx512f',
        \\but would be inlined into function 'bar' that is compiled without support for 'avx512f'
    ;
    try std.testing.expect(!isSimdFeatureBuildError(stderr));
}

test "isSimdFeatureBuildError: ignores ordinary build failures" {
    const stderr = "error: unable to find 'game.zig'\n";
    try std.testing.expect(!isSimdFeatureBuildError(stderr));
}
