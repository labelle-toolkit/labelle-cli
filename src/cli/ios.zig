/// iOS simulator deployment for labelle-cli.
/// Assembles a .app bundle and deploys to the iOS Simulator via xcrun simctl.
const std = @import("std");
const gen = @import("generator");

/// Deploy the built iOS binary to the iOS Simulator.
/// Expects the binary at `target_dir/zig-out/bin/game`.
pub fn deployToSimulator(allocator: std.mem.Allocator, target_dir: []const u8, cfg: gen.ProjectConfig) !void {
    const ios_cfg = cfg.ios orelse gen.IosConfig{};
    const bundle_id = if (ios_cfg.bundle_id.len > 0) ios_cfg.bundle_id else cfg.name;
    const app_name = if (ios_cfg.app_name.len > 0) ios_cfg.app_name else cfg.title;

    // Path to simulator binary
    const binary_path = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "bin", "game" });
    defer allocator.free(binary_path);

    // Check binary exists
    std.fs.cwd().access(binary_path, .{}) catch {
        std.debug.print("labelle: iOS binary not found at {s}\n", .{binary_path});
        return error.BinaryNotFound;
    };

    // Create .app bundle directory
    const app_bundle = try std.fs.path.join(allocator, &.{ target_dir, "game.app" });
    defer allocator.free(app_bundle);

    // Remove old bundle to ensure clean state
    std.fs.cwd().deleteTree(app_bundle) catch {};
    std.fs.cwd().makePath(app_bundle) catch {};

    // Copy binary into .app bundle
    const app_binary = try std.fs.path.join(allocator, &.{ app_bundle, "game" });
    defer allocator.free(app_binary);

    try std.fs.cwd().copyFile(binary_path, std.fs.cwd(), app_binary, .{});

    // Make executable
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "chmod", "+x", app_binary },
    }) catch {};

    // Generate Info.plist
    const info_plist_path = try std.fs.path.join(allocator, &.{ app_bundle, "Info.plist" });
    defer allocator.free(info_plist_path);

    const info_plist = try generateInfoPlist(allocator, bundle_id, app_name, ios_cfg);
    defer allocator.free(info_plist);

    {
        const f = try std.fs.cwd().createFile(info_plist_path, .{});
        defer f.close();
        try f.writeAll(info_plist);
    }

    // Generate LaunchScreen.storyboard
    const launch_path = try std.fs.path.join(allocator, &.{ app_bundle, "LaunchScreen.storyboard" });
    defer allocator.free(launch_path);

    const launch_content = try generateLaunchScreen(allocator, app_name);
    defer allocator.free(launch_content);

    {
        const f = try std.fs.cwd().createFile(launch_path, .{});
        defer f.close();
        try f.writeAll(launch_content);
    }

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
    const install_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "xcrun", "simctl", "install", udid, app_bundle },
    }) catch |err| {
        std.debug.print("labelle: failed to run simctl install: {}\n", .{err});
        return err;
    };
    defer allocator.free(install_result.stdout);
    defer allocator.free(install_result.stderr);

    if (install_result.term != .Exited or install_result.term.Exited != 0) {
        std.debug.print("labelle: simulator install failed: {s}\n", .{install_result.stderr});
        return error.InstallFailed;
    }

    // Launch app
    std.debug.print("labelle: launching on simulator...\n", .{});
    const launch_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "xcrun", "simctl", "launch", udid, bundle_id },
    }) catch |err| {
        std.debug.print("labelle: failed to run simctl launch: {}\n", .{err});
        return err;
    };
    defer allocator.free(launch_result.stdout);
    defer allocator.free(launch_result.stderr);

    if (launch_result.term != .Exited or launch_result.term.Exited != 0) {
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
    const list_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "xcrun", "simctl", "list", "devices", "booted", "-j" },
    }) catch |err| {
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

    const avail_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "xcrun", "simctl", "list", "devices", "available" },
    }) catch {
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

                        var boot_child = std.process.Child.init(&.{ "xcrun", "simctl", "boot", udid }, allocator);
                        _ = boot_child.spawnAndWait() catch {};

                        std.Thread.sleep(2 * std.time.ns_per_s);

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
                std.fs.cwd().copyFile(src_path, std.fs.cwd(), dst_path, .{}) catch {};
            },
            .directory => {
                try copyDirectory(allocator, src_path, dst_path);
            },
            else => {},
        }
    }
}

/// Generate Info.plist with full iOS metadata.
fn generateInfoPlist(allocator: std.mem.Allocator, bundle_id: []const u8, app_name: []const u8, ios_cfg: gen.IosConfig) ![]const u8 {
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
        \\    <key>MinimumOSVersion</key>
        \\    <string>{s}</string>
        \\</dict>
        \\</plist>
        \\
    , .{ app_name, bundle_id, app_name, orientations, ios_cfg.minimum_ios });
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
