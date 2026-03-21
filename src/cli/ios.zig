/// iOS simulator deployment for labelle-cli.
/// Assembles a .app bundle and deploys to the iOS Simulator via xcrun simctl.
const std = @import("std");

/// Deploy the built iOS binary to the iOS Simulator.
/// Expects the binary at `target_dir/zig-out/bin/game`.
pub fn deployToSimulator(allocator: std.mem.Allocator, target_dir: []const u8, bundle_id: []const u8, app_name: []const u8) !void {
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

    const info_plist = try generateInfoPlist(allocator, bundle_id, app_name);
    defer allocator.free(info_plist);

    const info_file = try std.fs.cwd().createFile(info_plist_path, .{});
    defer info_file.close();
    try info_file.writeAll(info_plist);

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
                    // Verify it looks like a UDID (36 chars with dashes)
                    if (udid.len == 36 and udid[8] == '-') {
                        std.debug.print("labelle: booting {s}\n", .{std.mem.trim(u8, line, " \t")});

                        // Boot this simulator
                        var boot_child = std.process.Child.init(&.{ "xcrun", "simctl", "boot", udid }, allocator);
                        _ = boot_child.spawnAndWait() catch {};

                        // Wait for boot
                        std.Thread.sleep(2 * std.time.ns_per_s);

                        return allocator.dupe(u8, udid);
                    }
                }
            }
        }
    }

    // Fallback — "booted" is understood by simctl
    return allocator.dupe(u8, "booted");
}

/// Generate minimal Info.plist for simulator .app bundle.
fn generateInfoPlist(allocator: std.mem.Allocator, bundle_id: []const u8, app_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleExecutable</key>
        \\    <string>game</string>
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
        \\    <key>UILaunchScreen</key>
        \\    <dict/>
        \\</dict>
        \\</plist>
        \\
    , .{ bundle_id, app_name });
}
