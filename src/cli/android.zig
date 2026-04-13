/// Android build and deployment for labelle-cli.
const std = @import("std");
const gen = @import("generator");
const runner = @import("runner.zig");
const util = @import("util.zig");

/// Handle `labelle android <subcommand>` dispatch.
pub fn handleAndroid(
    allocator: std.mem.Allocator,
    extra_args: []const []const u8,
    cfg: gen.ProjectConfig,
    target_dir: []const u8,
) !void {
    var subcmd: ?[]const u8 = null;
    var emulator = false;
    var release = false;

    for (extra_args) |arg| {
        if (std.mem.eql(u8, arg, "--emulator")) {
            emulator = true;
        } else if (std.mem.eql(u8, arg, "--release")) {
            release = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (subcmd == null) subcmd = arg;
        }
    }

    const cmd = subcmd orelse {
        printHelp();
        return;
    };

    if (std.mem.eql(u8, cmd, "build")) {
        try androidBuild(allocator, target_dir, emulator, release);
    } else if (std.mem.eql(u8, cmd, "run")) {
        try androidBuild(allocator, target_dir, emulator, release);
        try deployToDevice(allocator, target_dir, cfg, emulator);
    } else if (std.mem.eql(u8, cmd, "help")) {
        printHelp();
    } else {
        std.debug.print("labelle android: unknown subcommand '{s}'\n", .{cmd});
        printHelp();
    }
}

/// Build the Android shared library via `zig build`.
fn androidBuild(allocator: std.mem.Allocator, target_dir: []const u8, emulator: bool, release: bool) !void {
    std.debug.print("labelle: building for Android{s}...\n", .{if (emulator) " (emulator)" else ""});

    var zig_args: std.ArrayList([]const u8) = .{};
    defer zig_args.deinit(allocator);
    try zig_args.appendSlice(allocator, &.{ "zig", "build" });

    if (emulator) {
        try zig_args.append(allocator, "-Demulator=true");
    }
    if (release) {
        try zig_args.append(allocator, "-Doptimize=ReleaseFast");
    }

    const build_result = try runner.runZig(allocator, target_dir, zig_args.items);
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);

    switch (build_result.term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("labelle: Android build failed:\n{s}\n", .{build_result.stderr});
            return error.BuildFailed;
        },
        else => {
            std.debug.print("labelle: Android build terminated abnormally\n{s}\n", .{build_result.stderr});
            return error.BuildFailed;
        },
    }
    std.debug.print("  build ok\n", .{});
}

/// Package APK and deploy to device/emulator via ADB.
pub fn deployToDevice(allocator: std.mem.Allocator, target_dir: []const u8, cfg: gen.ProjectConfig, emulator: bool) !void {
    const android_cfg = cfg.android orelse gen.AndroidConfig{};
    const package_name = if (android_cfg.package_name.len > 0) android_cfg.package_name else try defaultPackageName(allocator, cfg.name);
    const app_name = if (android_cfg.app_name.len > 0) android_cfg.app_name else cfg.title;

    // Locate the built .so
    const lib_name = if (emulator) "x86_64-linux-android" else "aarch64-linux-android";
    _ = lib_name;
    const so_path = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "lib", "libgame.so" });
    defer allocator.free(so_path);

    std.fs.cwd().access(so_path, .{}) catch {
        std.debug.print("labelle: Android .so not found at {s}\n", .{so_path});
        return error.BinaryNotFound;
    };

    // Find ADB
    const adb = try findAdb(allocator);
    defer allocator.free(adb);

    // Create APK staging directory
    const staging_dir = try std.fs.path.join(allocator, &.{ target_dir, "apk-staging" });
    defer allocator.free(staging_dir);
    // Intentionally ignoring errors: the staging directory may not exist on first run.
    std.fs.cwd().deleteTree(staging_dir) catch {};

    // Stage .so into lib/<abi>/
    const abi_dir = if (emulator) "x86_64" else "arm64-v8a";
    const lib_dir = try std.fs.path.join(allocator, &.{ staging_dir, "lib", abi_dir });
    defer allocator.free(lib_dir);
    try std.fs.cwd().makePath(lib_dir);

    const staged_so = try std.fs.path.join(allocator, &.{ lib_dir, "libgame.so" });
    defer allocator.free(staged_so);
    try std.fs.cwd().copyFile(so_path, std.fs.cwd(), staged_so, .{});

    // Generate AndroidManifest.xml
    const manifest_path = try std.fs.path.join(allocator, &.{ staging_dir, "AndroidManifest.xml" });
    defer allocator.free(manifest_path);
    const manifest = try generateAndroidManifest(allocator, package_name, app_name, android_cfg);
    defer allocator.free(manifest);
    {
        const f = try std.fs.cwd().createFile(manifest_path, .{});
        defer f.close();
        try f.writeAll(manifest);
    }

    // Stage assets
    const assets_src = try std.fs.path.join(allocator, &.{ target_dir, "assets" });
    defer allocator.free(assets_src);
    const assets_dst = try std.fs.path.join(allocator, &.{ staging_dir, "assets" });
    defer allocator.free(assets_dst);
    try copyDirectory(allocator, assets_src, assets_dst);

    // Build APK
    const apk_path = try std.fs.path.join(allocator, &.{ target_dir, "game.apk" });
    defer allocator.free(apk_path);
    try buildApk(allocator, staging_dir, apk_path, android_cfg);

    // Install via ADB
    std.debug.print("labelle: installing on device...\n", .{});
    const install_result = util.runCmd(allocator, &.{ adb, "install", "-r", apk_path }) catch |err| {
        std.debug.print("labelle: adb install failed: {}\n", .{err});
        return err;
    };
    defer allocator.free(install_result.stdout);
    defer allocator.free(install_result.stderr);

    switch (install_result.term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("labelle: adb install failed: {s}\n", .{install_result.stderr});
            return error.InstallFailed;
        },
        else => {
            std.debug.print("labelle: adb install terminated abnormally\n", .{});
            return error.InstallFailed;
        },
    }

    // Launch via ADB
    const activity = try std.fmt.allocPrint(allocator, "{s}/android.app.NativeActivity", .{package_name});
    defer allocator.free(activity);

    std.debug.print("labelle: launching...\n", .{});
    const launch_result = util.runCmd(allocator, &.{ adb, "shell", "am", "start", "-n", activity }) catch |err| {
        std.debug.print("labelle: adb launch failed: {}\n", .{err});
        return err;
    };
    defer allocator.free(launch_result.stdout);
    defer allocator.free(launch_result.stderr);

    switch (launch_result.term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("labelle: launch failed: {s}\n", .{launch_result.stderr});
            return error.LaunchFailed;
        },
        else => {},
    }

    std.debug.print("labelle: app launched on device\n", .{});
}

/// Build APK from staging directory using Android SDK tools.
fn buildApk(allocator: std.mem.Allocator, staging_dir: []const u8, apk_path: []const u8, android_cfg: gen.AndroidConfig) !void {
    const sdk_home = try findAndroidSdk(allocator);
    defer allocator.free(sdk_home);

    // Find android.jar
    const target_sdk = android_cfg.target_sdk_version;
    const android_jar = try std.fmt.allocPrint(allocator, "{s}/platforms/android-{d}/android.jar", .{ sdk_home, target_sdk });
    defer allocator.free(android_jar);

    std.fs.cwd().access(android_jar, .{}) catch {
        std.debug.print("labelle: android.jar not found at {s}\n", .{android_jar});
        std.debug.print("  install Android SDK platform {d}: sdkmanager \"platforms;android-{d}\"\n", .{ target_sdk, target_sdk });
        return error.SdkNotFound;
    };

    // Find build-tools
    const build_tools_dir = try findBuildTools(allocator, sdk_home);
    defer allocator.free(build_tools_dir);

    const aapt2 = try std.fs.path.join(allocator, &.{ build_tools_dir, "aapt2" });
    defer allocator.free(aapt2);
    const zipalign = try std.fs.path.join(allocator, &.{ build_tools_dir, "zipalign" });
    defer allocator.free(zipalign);
    const apksigner = try std.fs.path.join(allocator, &.{ build_tools_dir, "apksigner" });
    defer allocator.free(apksigner);

    // Use aapt (v1) for simplicity — it can package in one step
    const aapt = try std.fs.path.join(allocator, &.{ build_tools_dir, "aapt" });
    defer allocator.free(aapt);

    const manifest_path = try std.fs.path.join(allocator, &.{ staging_dir, "AndroidManifest.xml" });
    defer allocator.free(manifest_path);

    const unsigned_apk = try std.fmt.allocPrint(allocator, "{s}.unsigned", .{apk_path});
    defer allocator.free(unsigned_apk);
    const aligned_apk = try std.fmt.allocPrint(allocator, "{s}.aligned", .{apk_path});
    defer allocator.free(aligned_apk);

    // Package with aapt
    std.debug.print("labelle: packaging APK...\n", .{});
    {
        const result = util.runCmd(allocator, &.{ aapt, "package", "-f", "-M", manifest_path, "-I", android_jar, "-F", unsigned_apk, staging_dir }) catch |err| {
            std.debug.print("labelle: aapt package failed: {}\n", .{err});
            return err;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .Exited => |code| if (code != 0) {
                std.debug.print("labelle: aapt package failed: {s}\n", .{result.stderr});
                return error.PackageFailed;
            },
            else => return error.PackageFailed,
        }
    }

    // Zipalign
    {
        const result = util.runCmd(allocator, &.{ zipalign, "-f", "4", unsigned_apk, aligned_apk }) catch |err| {
            std.debug.print("labelle: zipalign failed: {}\n", .{err});
            return err;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .Exited => |code| if (code != 0) {
                std.debug.print("labelle: zipalign failed: {s}\n", .{result.stderr});
                return error.PackageFailed;
            },
            else => return error.PackageFailed,
        }
    }

    // Sign with debug keystore
    const keystore = try ensureDebugKeystore(allocator);
    defer allocator.free(keystore);

    {
        const result = util.runCmd(allocator, &.{
            apksigner, "sign",
            "--ks",     keystore,
            "--ks-pass", "pass:android",
            "--out",    apk_path,
            aligned_apk,
        }) catch |err| {
            std.debug.print("labelle: apksigner failed: {}\n", .{err});
            return err;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .Exited => |code| if (code != 0) {
                std.debug.print("labelle: apksigner failed: {s}\n", .{result.stderr});
                return error.PackageFailed;
            },
            else => return error.PackageFailed,
        }
    }

    // Cleanup intermediates
    std.fs.cwd().deleteFile(unsigned_apk) catch {};
    std.fs.cwd().deleteFile(aligned_apk) catch {};

    std.debug.print("  APK: {s}\n", .{apk_path});
}

/// Generate AndroidManifest.xml for NativeActivity.
fn generateAndroidManifest(allocator: std.mem.Allocator, package_name: []const u8, app_name: []const u8, cfg: gen.AndroidConfig) ![]u8 {
    const orientation = switch (cfg.orientation) {
        .portrait => "portrait",
        .landscape => "landscape",
        .all => "unspecified",
    };

    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<manifest xmlns:android="http://schemas.android.com/apk/res/android"
        \\    package="{s}"
        \\    android:versionCode="1"
        \\    android:versionName="1.0">
        \\
        \\    <uses-sdk android:minSdkVersion="{d}" android:targetSdkVersion="{d}" />
        \\    <uses-feature android:glEsVersion="0x00030000" android:required="true" />
        \\
        \\    <application android:hasCode="false" android:label="{s}">
        \\        <activity android:name="android.app.NativeActivity"
        \\            android:configChanges="orientation|keyboardHidden|screenSize"
        \\            android:screenOrientation="{s}"
        \\            android:exported="true">
        \\            <meta-data android:name="android.app.lib_name" android:value="game" />
        \\            <intent-filter>
        \\                <action android:name="android.intent.action.MAIN" />
        \\                <category android:name="android.intent.category.LAUNCHER" />
        \\            </intent-filter>
        \\        </activity>
        \\    </application>
        \\</manifest>
        \\
    , .{ package_name, cfg.min_sdk_version, cfg.target_sdk_version, app_name, orientation });
}

/// Find adb in ANDROID_HOME/platform-tools/ or PATH.
fn findAdb(allocator: std.mem.Allocator) ![]u8 {
    // Try ANDROID_HOME first
    if (std.process.getEnvVarOwned(allocator, "ANDROID_HOME") catch null) |home| {
        defer allocator.free(home);
        const adb_path = try std.fs.path.join(allocator, &.{ home, "platform-tools", "adb" });
        if (std.fs.cwd().access(adb_path, .{})) |_| {
            return adb_path;
        } else |_| {
            allocator.free(adb_path);
        }
    }
    // Fall back to PATH
    const result = util.runCmd(allocator, &.{ "which", "adb" }) catch {
        std.debug.print("labelle: adb not found. Set ANDROID_HOME or add adb to PATH.\n", .{});
        return error.AdbNotFound;
    };
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    if (result.term == .Exited and result.term.Exited == 0 and result.stdout.len > 0) {
        const path = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
        return allocator.dupe(u8, path);
    }
    std.debug.print("labelle: adb not found. Set ANDROID_HOME or add adb to PATH.\n", .{});
    return error.AdbNotFound;
}

/// Find ANDROID_HOME.
fn findAndroidSdk(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "ANDROID_HOME")) |home| {
        return home;
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "ANDROID_SDK_ROOT")) |home| {
        return home;
    } else |_| {}
    std.debug.print("labelle: Android SDK not found. Set ANDROID_HOME.\n", .{});
    return error.SdkNotFound;
}

/// Find the latest build-tools directory.
fn findBuildTools(allocator: std.mem.Allocator, sdk_home: []const u8) ![]u8 {
    const bt_dir = try std.fs.path.join(allocator, &.{ sdk_home, "build-tools" });
    defer allocator.free(bt_dir);

    var dir = std.fs.cwd().openDir(bt_dir, .{ .iterate = true }) catch {
        std.debug.print("labelle: build-tools not found at {s}\n", .{bt_dir});
        return error.SdkNotFound;
    };
    defer dir.close();

    var latest: ?[]const u8 = null;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            if (latest) |prev| {
                // Pick the highest version by lexicographic comparison
                // (works for dotted semver like "33.0.0" vs "34.0.0")
                if (std.mem.order(u8, entry.name, prev) == .gt) {
                    allocator.free(prev);
                    latest = try allocator.dupe(u8, entry.name);
                }
            } else {
                latest = try allocator.dupe(u8, entry.name);
            }
        }
    }

    if (latest) |version| {
        defer allocator.free(version);
        return std.fs.path.join(allocator, &.{ bt_dir, version });
    }

    std.debug.print("labelle: no build-tools version found in {s}\n", .{bt_dir});
    return error.SdkNotFound;
}

/// Ensure a debug keystore exists at ~/.labelle/android-debug.keystore.
fn ensureDebugKeystore(allocator: std.mem.Allocator) ![]u8 {
    const cache_root = try gen.getCacheRoot(allocator);
    defer allocator.free(cache_root);

    const keystore = try std.fs.path.join(allocator, &.{ cache_root, "android-debug.keystore" });

    std.fs.cwd().access(keystore, .{}) catch {
        // Generate debug keystore
        std.debug.print("labelle: generating debug keystore...\n", .{});
        const result = util.runCmd(allocator, &.{
            "keytool", "-genkey", "-v",
            "-keystore",  keystore,
            "-alias",     "androiddebugkey",
            "-keyalg",    "RSA",
            "-keysize",   "2048",
            "-validity",  "10000",
            "-storepass", "android",
            "-keypass",   "android",
            "-dname",     "CN=Debug,O=Labelle,C=US",
        }) catch {
            std.debug.print("labelle: failed to generate debug keystore (is keytool installed?)\n", .{});
            allocator.free(keystore);
            return error.KeystoreFailed;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| if (code != 0) {
                std.debug.print("labelle: keytool failed (exit code {d}): {s}\n", .{ code, result.stderr });
                allocator.free(keystore);
                return error.KeystoreFailed;
            },
            else => {
                std.debug.print("labelle: keytool terminated abnormally\n", .{});
                allocator.free(keystore);
                return error.KeystoreFailed;
            },
        }
    };

    return keystore;
}

/// Default package name from project name.
fn defaultPackageName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "com.labelle.{s}", .{name});
}

/// Copy a directory tree recursively.
fn copyDirectory(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const cwd = std.fs.cwd();
    cwd.makePath(dst) catch {};

    var src_dir = try cwd.openDir(src, .{ .iterate = true });
    defer src_dir.close();

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        const src_sub = try std.fs.path.join(allocator, &.{ src, entry.name });
        defer allocator.free(src_sub);
        const dst_sub = try std.fs.path.join(allocator, &.{ dst, entry.name });
        defer allocator.free(dst_sub);

        switch (entry.kind) {
            .directory => try copyDirectory(allocator, src_sub, dst_sub),
            .file => try cwd.copyFile(src_sub, cwd, dst_sub, .{}),
            else => {},
        }
    }
}

fn printHelp() void {
    std.debug.print(
        \\
        \\Usage: labelle android <command> [options]
        \\
        \\Commands:
        \\  build      Build for Android device (arm64)
        \\  run        Build and deploy to device/emulator
        \\  help       Show this help
        \\
        \\Options:
        \\  --emulator   Target x86_64 emulator instead of arm64 device
        \\  --release    Build with ReleaseFast optimization
        \\
    , .{});
}
