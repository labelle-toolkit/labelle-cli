/// `labelle android run` plumbing — package an APK, push it with
/// `adb install -r`, and launch the NativeActivity. Built on top of
/// `android/package.zig` for the packaging half.
const std = @import("std");
const gen = @import("generator");
const util = @import("../util.zig");
const android = @import("../android.zig");
const package = @import("package.zig");
const config = @import("../config.zig");

const SigningConfig = android.SigningConfig;
const StagedAbi = android.StagedAbi;

/// Package APK and deploy to device/emulator via ADB. Single-arch
/// entry point — picks the ABI from `emulator` + host arch, then
/// delegates to `deployToDeviceWithAbis`.
pub fn deployToDevice(allocator: std.mem.Allocator, target_dir: []const u8, cfg: gen.ProjectConfig, emulator: bool, signing: SigningConfig) !void {
    const abi_dir = package.hostAbiDir(emulator);
    const so_path = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "lib", "libgame.so" });
    defer allocator.free(so_path);

    const abis = [_]StagedAbi{.{ .abi_dir = abi_dir, .so_path = so_path }};
    try deployToDeviceWithAbis(allocator, target_dir, cfg, abis[0..], signing);
}

/// Shared staging / packaging / install / launch pipeline used by
/// both the single-arch and `--all-abis` run paths. Stages every
/// entry in `abis` into `apk-staging/lib/<abi_dir>/libgame.so`,
/// signs an APK via `packageApkWithAbis`, then pushes it to the
/// connected device with ADB and launches the NativeActivity.
pub fn deployToDeviceWithAbis(
    allocator: std.mem.Allocator,
    target_dir: []const u8,
    cfg: gen.ProjectConfig,
    abis: []const StagedAbi,
    signing: SigningConfig,
) !void {
    const apk_path = try package.packageApkWithAbis(allocator, target_dir, cfg, abis, signing);
    defer allocator.free(apk_path);

    const package_name = try package.resolvePackageName(allocator, cfg);
    defer allocator.free(package_name);

    try installAndLaunch(allocator, apk_path, package_name);
}

/// Push a previously-built APK to the connected device via `adb
/// install -r` and launch the NativeActivity. Split out of
/// `deployToDeviceWithAbis` so the `build` subcommand and CI
/// pipelines can use the packaging half without touching ADB.
fn installAndLaunch(allocator: std.mem.Allocator, apk_path: []const u8, package_name: []const u8) !void {
    const adb = try findAdb(allocator);
    defer allocator.free(adb);

    // Install via ADB
    std.debug.print("labelle: installing on device...\n", .{});
    const install_result = util.runCmd(allocator, &.{ adb, "install", "-r", apk_path }) catch |err| {
        std.debug.print("labelle: adb install failed: {}\n", .{err});
        return err;
    };
    defer allocator.free(install_result.stdout);
    defer allocator.free(install_result.stderr);

    switch (install_result.term) {
        .exited => |code| if (code != 0) {
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
        .exited => |code| if (code != 0) {
            std.debug.print("labelle: launch failed: {s}\n", .{launch_result.stderr});
            return error.LaunchFailed;
        },
        else => {},
    }

    std.debug.print("labelle: app launched on device\n", .{});
}

/// Find adb in ANDROID_HOME/platform-tools/ or PATH.
fn findAdb(allocator: std.mem.Allocator) ![]u8 {
    // Try ANDROID_HOME first
    if (config.globalEnviron().getAlloc(allocator, "ANDROID_HOME") catch null) |home| {
        defer allocator.free(home);
        const adb_path = try std.fs.path.join(allocator, &.{ home, "platform-tools", "adb" });
        if (std.Io.Dir.cwd().access(config.globalIo(), adb_path, .{})) |_| {
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
    if (result.term == .exited and result.term.exited == 0 and result.stdout.len > 0) {
        const path = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
        return allocator.dupe(u8, path);
    }
    std.debug.print("labelle: adb not found. Set ANDROID_HOME or add adb to PATH.\n", .{});
    return error.AdbNotFound;
}
