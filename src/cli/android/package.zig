/// APK packaging — staging, manifest, aapt/zipalign/apksigner pipeline,
/// keystore resolution, Android SDK probes. Called from
/// `android/build.zig` (after the .so is built) and `android/run.zig`
/// (single- and multi-arch deploy paths share this module).
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const project_config = @import("../project_config.zig");
const asm_cache = @import("../asm_cache.zig");
const util = @import("../util.zig");
const android = @import("../android.zig");
const launcher_icon = @import("launcher_icon.zig");

const ProjectConfig = project_config.ProjectConfig;
const AndroidConfig = project_config.AndroidConfig;
const SigningConfig = android.SigningConfig;
const StagedAbi = android.StagedAbi;

/// Post-validation signing values passed into apksigner. Unlike
/// `SigningConfig`, every required field is non-optional — the
/// resolver picks debug defaults when the user didn't supply a
/// keystore.
const ResolvedSigning = struct {
    keystore: []const u8,
    keystore_pass: []const u8,
    key_alias: ?[]const u8,
    key_pass: ?[]const u8,
    is_debug: bool,
};

/// Single-arch wrapper around `packageApkWithAbis` that mirrors
/// `deployToDevice`: picks the ABI from `emulator` + host arch,
/// compiles a one-element `StagedAbi` slice, and returns the path to
/// the signed APK (caller owns it).
///
/// Used by `labelle android build` when `--all-abis` is not set.
pub fn packageApk(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    target_dir: []const u8,
    cfg: ProjectConfig,
    emulator: bool,
    signing: SigningConfig,
) ![]u8 {
    const abi_dir = hostAbiDir(emulator);
    const so_path = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "lib", "libgame.so" });
    defer allocator.free(so_path);
    const abis = [_]StagedAbi{.{ .abi_dir = abi_dir, .so_path = so_path }};
    return packageApkWithAbis(allocator, project_dir, target_dir, cfg, abis[0..], signing);
}

/// Package a signed APK from one or more built `libgame.so` entries.
/// Does NOT touch ADB — this is the path that `labelle android build`
/// and CI pipelines use to produce an installable artifact without
/// requiring a connected device. Returns the owned path to the APK
/// (typically `<target_dir>/game.apk`).
///
/// `abis` is the list of `(abi_dir, libgame.so path)` pairs that get
/// fanned out into `apk-staging/lib/<abi_dir>/libgame.so` before
/// `buildApk` runs. A single-element slice produces a single-arch
/// APK; multi-element slices produce a fat APK.
///
/// `project_dir` is the source project root — needed because
/// `.app_icon` in `project.labelle` is relative to it (cli#340).
pub fn packageApkWithAbis(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    target_dir: []const u8,
    cfg: ProjectConfig,
    abis: []const StagedAbi,
    signing: SigningConfig,
) ![]u8 {
    if (abis.len == 0) return error.NoAbisProvided;

    const android_cfg = cfg.android orelse AndroidConfig{};
    // package_name may be heap-allocated (defaultPackageName) or a slice into
    // android_cfg (no allocation).  Track whether we own it so we can free it.
    const package_name_owned = android_cfg.package_name.len == 0;
    const package_name = if (android_cfg.package_name.len > 0) android_cfg.package_name else try defaultPackageName(allocator, cfg.name);
    defer if (package_name_owned) allocator.free(package_name);
    const app_name = if (android_cfg.app_name.len > 0) android_cfg.app_name else cfg.title;

    // Validate every .so exists before we touch the staging dir.
    for (abis) |abi| {
        std.Io.Dir.cwd().access(config.globalIo(), abi.so_path, .{}) catch {
            std.debug.print("labelle: Android .so not found at {s}\n", .{abi.so_path});
            return error.BinaryNotFound;
        };
    }

    // Create APK staging directory
    const staging_dir = try std.fs.path.join(allocator, &.{ target_dir, "apk-staging" });
    defer allocator.free(staging_dir);
    // Intentionally ignoring errors: the staging directory may not exist on first run.
    std.Io.Dir.cwd().deleteTree(config.globalIo(), staging_dir) catch {};

    // Fan out every staged .so into `lib/<abi>/libgame.so`. The fat
    // APK case produces multiple directories under `lib/`; apksigner
    // and Android's package installer pick the right one per device.
    for (abis) |abi| {
        const lib_dir = try std.fs.path.join(allocator, &.{ staging_dir, "lib", abi.abi_dir });
        defer allocator.free(lib_dir);
        try std.Io.Dir.cwd().createDirPath(config.globalIo(), lib_dir);

        const staged_so = try std.fs.path.join(allocator, &.{ lib_dir, "libgame.so" });
        defer allocator.free(staged_so);
        try std.Io.Dir.cwd().copyFile(abi.so_path, std.Io.Dir.cwd(), staged_so, config.globalIo(), .{});
    }

    // Stage the launcher icon into `res/mipmap-*/ic_launcher.png`
    // (cli#340). Runs BEFORE the manifest is written: `android:icon`
    // may only reference `@mipmap/ic_launcher` if that resource actually
    // exists, otherwise aapt fails to link it.
    const has_launcher_icon = try launcher_icon.stage(allocator, staging_dir, project_dir, target_dir, cfg.app_icon);

    // Generate AndroidManifest.xml
    const manifest_path = try std.fs.path.join(allocator, &.{ staging_dir, "AndroidManifest.xml" });
    defer allocator.free(manifest_path);
    const manifest = try generateAndroidManifest(allocator, package_name, app_name, android_cfg, has_launcher_icon);
    defer allocator.free(manifest);
    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = manifest_path, .data = manifest });

    // Stage assets. A project that declares no `.resources` (e.g. a pure-HUD
    // gamepad demo) generates no `<target>/assets/` dir, so skip the copy when
    // the source is absent rather than failing the whole package step on a
    // missing directory. aapt is happy with an APK that has no assets/ entry.
    const assets_src = try std.fs.path.join(allocator, &.{ target_dir, "assets" });
    defer allocator.free(assets_src);
    const assets_dst = try std.fs.path.join(allocator, &.{ staging_dir, "assets" });
    defer allocator.free(assets_dst);
    if (std.Io.Dir.cwd().access(config.globalIo(), assets_src, .{})) |_| {
        try copyDirectory(allocator, assets_src, assets_dst);
    } else |err| switch (err) {
        error.FileNotFound => {}, // no assets to stage — fine
        else => return err,
    }

    // Build APK
    const apk_path = try std.fs.path.join(allocator, &.{ target_dir, "game.apk" });
    errdefer allocator.free(apk_path);
    try buildApk(allocator, staging_dir, apk_path, android_cfg, signing);
    return apk_path;
}

/// Pick the ABI directory for a single-arch build. On Apple Silicon
/// the Android emulator runs ARM64 images; on Intel Macs it runs
/// x86_64. Physical device builds always target arm64-v8a.
pub fn hostAbiDir(emulator: bool) []const u8 {
    return if (emulator and builtin.cpu.arch != .aarch64) "x86_64" else "arm64-v8a";
}

/// Resolve the Android package name from `cfg`, defaulting to
/// `com.labelle.<project>` when the project doesn't set one. Caller
/// owns the returned slice.
pub fn resolvePackageName(allocator: std.mem.Allocator, cfg: ProjectConfig) ![]const u8 {
    const android_cfg = cfg.android orelse AndroidConfig{};
    if (android_cfg.package_name.len > 0) return allocator.dupe(u8, android_cfg.package_name);
    return defaultPackageName(allocator, cfg.name);
}

/// Build APK from staging directory using Android SDK tools.
fn buildApk(allocator: std.mem.Allocator, staging_dir: []const u8, apk_path: []const u8, android_cfg: AndroidConfig, signing: SigningConfig) !void {
    const sdk_home = try findAndroidSdk(allocator);
    defer allocator.free(sdk_home);

    // Find android.jar
    const target_sdk = android_cfg.target_sdk_version;
    // Use std.fs.path.join (not raw string interpolation) so the
    // separators are platform-native — important for any future Windows
    // host support.
    const platform_dir = try std.fmt.allocPrint(allocator, "android-{d}", .{target_sdk});
    defer allocator.free(platform_dir);
    const android_jar = try std.fs.path.join(allocator, &.{ sdk_home, "platforms", platform_dir, "android.jar" });
    defer allocator.free(android_jar);

    std.Io.Dir.cwd().access(config.globalIo(), android_jar, .{}) catch {
        std.debug.print("labelle: android.jar not found at {s}\n", .{android_jar});
        std.debug.print("  install Android SDK platform {d}: sdkmanager \"platforms;android-{d}\"\n", .{ target_sdk, target_sdk });
        return error.SdkNotFound;
    };

    // Find build-tools
    const build_tools_dir = try findBuildTools(allocator, sdk_home);
    defer allocator.free(build_tools_dir);

    // We use aapt v1 for packaging (single-step) — aapt2 isn't called
    // in this function. Keeping only the tools we actually invoke.
    //
    // Resolve with the host-correct extension: on Windows the SDK ships
    // `aapt.exe` / `zipalign.exe` (native binaries) but `apksigner.bat`
    // (a JVM launcher wrapper). On macOS/Linux all three are bare names.
    const zipalign = try sdkToolPath(allocator, build_tools_dir, "zipalign", .native_exe);
    defer allocator.free(zipalign);
    const apksigner = try sdkToolPath(allocator, build_tools_dir, "apksigner", .script);
    defer allocator.free(apksigner);
    const aapt = try sdkToolPath(allocator, build_tools_dir, "aapt", .native_exe);
    defer allocator.free(aapt);

    const manifest_path = try std.fs.path.join(allocator, &.{ staging_dir, "AndroidManifest.xml" });
    defer allocator.free(manifest_path);

    const unsigned_apk = try std.fmt.allocPrint(allocator, "{s}.unsigned", .{apk_path});
    defer allocator.free(unsigned_apk);
    const aligned_apk = try std.fmt.allocPrint(allocator, "{s}.aligned", .{apk_path});
    defer allocator.free(aligned_apk);

    // Package with aapt.
    // Pass -A for assets, -S for compiled resources and -M for the
    // manifest, but do NOT pass the full staging_dir as a positional
    // argument — aapt would scan it, find another AndroidManifest.xml,
    // and report "Duplicate file". Every input therefore has to arrive
    // through its own flag.
    std.debug.print("labelle: packaging APK...\n", .{});
    const assets_dir = try std.fs.path.join(allocator, &.{ staging_dir, "assets" });
    defer allocator.free(assets_dir);
    const res_dir = try std.fs.path.join(allocator, &.{ staging_dir, launcher_icon.res_subdir });
    defer allocator.free(res_dir);
    {
        var aapt_args: std.ArrayList([]const u8) = .empty;
        defer aapt_args.deinit(allocator);
        try aapt_args.appendSlice(allocator, &.{ aapt, "package", "-f", "-M", manifest_path, "-I", android_jar, "-F", unsigned_apk });
        // Only pass -A if the assets directory actually exists.
        if (std.Io.Dir.cwd().access(config.globalIo(), assets_dir, .{})) |_| {
            try aapt_args.appendSlice(allocator, &.{ "-A", assets_dir });
        } else |_| {}
        // `res/` holds the launcher-icon mipmaps (cli#340) and exists
        // only when `launcher_icon.stage` had an icon to write. Passing
        // -S is also what makes the APK carry a `resources.arsc` at all
        // — hence the `-0 arsc` below.
        if (std.Io.Dir.cwd().access(config.globalIo(), res_dir, .{})) |_| {
            try aapt_args.appendSlice(allocator, &.{ "-S", res_dir });
            // Apps targeting API 30+ are rejected at install time with
            // INSTALL_PARSE_FAILED_RESOURCES_ARSC_COMPRESSED if
            // resources.arsc is deflated, and `zipalign` can only align
            // stored entries. aapt v1 happens to store our (tiny) table
            // already — `-0 arsc` makes that a guarantee rather than a
            // size-dependent accident as the resource table grows.
            try aapt_args.appendSlice(allocator, &.{ "-0", "arsc" });
        } else |_| {}
        const result = util.runCmd(allocator, aapt_args.items) catch |err| {
            std.debug.print("labelle: aapt package failed: {}\n", .{err});
            return err;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("labelle: aapt package failed: {s}\n", .{result.stderr});
                return error.PackageFailed;
            },
            else => return error.PackageFailed,
        }
    }

    // Add native libs to the APK (aapt does not handle .so files).
    //
    // The original code shelled out to the Unix-only `zip` tool, which
    // doesn't exist on Windows. Use the JDK's `jar` instead — it ships
    // with every JDK (and the Android SDK requires a JDK), so it's
    // available uniformly on Windows/macOS/Linux.
    //
    // `--update --no-compress -C <staging> lib` adds the `lib/<abi>/*.so`
    // tree to the existing aapt-produced unsigned APK *stored*
    // (uncompressed). Android API 30+ requires .so entries (and
    // resources.arsc) be stored uncompressed; `--no-compress` only
    // affects the newly-added entries, so the aapt-produced manifest /
    // resources.arsc already in the base APK are untouched. Running with
    // `-C staging_dir lib` makes the archive paths `lib/<abi>/libgame.so`
    // without a CWD change.
    {
        const jar = try findJar(allocator);
        defer allocator.free(jar);

        const result = util.runCmd(allocator, &.{
            jar, "--update", "--no-compress", "--file", unsigned_apk, "-C", staging_dir, "lib",
        }) catch |err| {
            std.debug.print("labelle: jar (add native libs) failed: {}\n", .{err});
            return err;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("labelle: jar (add native libs) failed: {s}\n", .{result.stderr});
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
            .exited => |code| if (code != 0) {
                std.debug.print("labelle: zipalign failed: {s}\n", .{result.stderr});
                return error.PackageFailed;
            },
            else => return error.PackageFailed,
        }
    }

    // ── Sign ────────────────────────────────────────────────────────
    // `signing` wins when the user passed `--keystore` — otherwise we
    // generate / reuse the debug keystore at ~/.labelle/. Both paths
    // end up invoking apksigner with an argv built from the same
    // builder so the two code paths stay in sync.
    var debug_keystore_buf: ?[]u8 = null;
    defer if (debug_keystore_buf) |b| allocator.free(b);

    // Re-validate here rather than trust `handleAndroid`'s check — the
    // public `deployToDevice` is callable from other code paths (e.g.
    // `labelle run` dispatching to Android without the android.zig
    // arg parser), and we don't want a `SigningConfig` with a
    // keystore but no pass to hit a panicking `.?` unwrap.
    const resolved: ResolvedSigning = if (signing.keystore) |ks| blk: {
        const kp = signing.keystore_pass orelse {
            std.debug.print("labelle: signing keystore requires keystore_pass\n", .{});
            return error.InvalidArgs;
        };
        break :blk .{
            .keystore = ks,
            .keystore_pass = kp,
            .key_alias = signing.key_alias,
            .key_pass = signing.key_pass,
            .is_debug = false,
        };
    } else blk: {
        const kp = try ensureDebugKeystore(allocator);
        debug_keystore_buf = kp;
        break :blk .{
            .keystore = kp,
            .keystore_pass = "pass:android",
            .key_alias = "androiddebugkey",
            .key_pass = "pass:android",
            .is_debug = true,
        };
    };

    if (resolved.is_debug) {
        std.debug.print("labelle: signing APK with debug keystore\n", .{});
    } else {
        std.debug.print("labelle: signing APK with {s}\n", .{resolved.keystore});
    }

    {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(allocator);
        try args.appendSlice(allocator, &.{
            apksigner, "sign",
            "--ks",     resolved.keystore,
            "--ks-pass", resolved.keystore_pass,
        });
        if (resolved.key_alias) |a| try args.appendSlice(allocator, &.{ "--ks-key-alias", a });
        if (resolved.key_pass) |p| try args.appendSlice(allocator, &.{ "--key-pass", p });
        try args.appendSlice(allocator, &.{ "--out", apk_path, aligned_apk });

        const result = util.runCmd(allocator, args.items) catch |err| {
            std.debug.print("labelle: apksigner failed: {}\n", .{err});
            return err;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("labelle: apksigner failed: {s}\n", .{result.stderr});
                return error.PackageFailed;
            },
            else => return error.PackageFailed,
        }
    }

    // Cleanup intermediates
    std.Io.Dir.cwd().deleteFile(config.globalIo(), unsigned_apk) catch {};
    std.Io.Dir.cwd().deleteFile(config.globalIo(), aligned_apk) catch {};

    std.debug.print("  APK: {s}\n", .{apk_path});
}

/// Generate AndroidManifest.xml for NativeActivity.
///
/// `has_launcher_icon` says whether `launcher_icon.stage` wrote
/// `res/mipmap-*/ic_launcher.png` into the staging tree. The attribute
/// is emitted only when it did — `android:icon` pointing at a resource
/// that isn't in the APK is an aapt link error, and the resource is
/// absent for projects generated by an assembler older than the one
/// that ships `default_icon.png`.
fn generateAndroidManifest(
    allocator: std.mem.Allocator,
    package_name: []const u8,
    app_name: []const u8,
    cfg: AndroidConfig,
    has_launcher_icon: bool,
) ![]u8 {
    const orientation = switch (cfg.orientation) {
        .portrait => "portrait",
        .landscape => "landscape",
        .sensor_landscape => "sensorLandscape",
        .all => "unspecified",
    };

    // Immersive mode: launch fullscreen with the status bar + title bar
    // hidden via the built-in `Theme.NoTitleBar.Fullscreen` framework
    // theme. That's a framework resource, so it costs the APK nothing.
    // Note: this hides the status bar only, NOT the navigation bar;
    // immersive-sticky nav-bar hiding needs runtime JNI work (follow-up).
    const theme_attr: []const u8 = if (cfg.immersive_mode)
        "\n            android:theme=\"@android:style/Theme.NoTitleBar.Fullscreen\""
    else
        "";

    // Launcher icon (cli#340). Until this landed the APK carried NO
    // custom resources at all and every game shipped with the stock
    // Android robot; the mipmaps staged by `launcher_icon.zig` are the
    // first (and so far only) compiled resources in the APK, which is
    // why `buildApk` now hands aapt a `-S <staging>/res`.
    // `android:hasCode="false"` is unaffected — resources are not code.
    const icon_attr: []const u8 = if (has_launcher_icon)
        " android:icon=\"" ++ launcher_icon.icon_resource_ref ++ "\""
    else
        "";

    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<manifest xmlns:android="http://schemas.android.com/apk/res/android"
        \\    package="{s}"
        \\    android:versionCode="1"
        \\    android:versionName="1.0">
        \\
        \\    <uses-sdk android:minSdkVersion="{d}" android:targetSdkVersion="{d}" />
        \\    <uses-feature android:glEsVersion="0x00030000" android:required="true" />
        \\    <uses-feature android:name="android.hardware.gamepad" android:required="false" />
        \\
        \\    <application android:hasCode="false" android:label="{s}"{s}>
        \\        <activity android:name="android.app.NativeActivity"
        \\            android:configChanges="orientation|keyboardHidden|screenSize"
        \\            android:screenOrientation="{s}"{s}
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
    , .{ package_name, cfg.min_sdk_version, cfg.target_sdk_version, app_name, icon_attr, orientation, theme_attr });
}

test "generateAndroidManifest omits theme attribute when immersive_mode is false" {
    const allocator = std.testing.allocator;
    const cfg = AndroidConfig{ .immersive_mode = false };
    const xml = try generateAndroidManifest(allocator, "com.test.game", "Test", cfg, false);
    defer allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "android:theme=") == null);
}

test "generateAndroidManifest adds NoTitleBar.Fullscreen theme when immersive_mode is true" {
    const allocator = std.testing.allocator;
    const cfg = AndroidConfig{ .immersive_mode = true };
    const xml = try generateAndroidManifest(allocator, "com.test.game", "Test", cfg, false);
    defer allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "android:theme=\"@android:style/Theme.NoTitleBar.Fullscreen\"") != null);
    // Theme attribute belongs to the <activity> element, before its close `>`.
    // Unwrap each lookup explicitly so a missing substring fails the test
    // with a clear message instead of a generic "unwrap null" panic.
    const activity_start = std.mem.indexOf(u8, xml, "<activity") orelse
        return std.testing.expect(false);
    const activity_open_end = std.mem.indexOfPos(u8, xml, activity_start, ">") orelse
        return std.testing.expect(false);
    const theme_idx = std.mem.indexOf(u8, xml, "android:theme=") orelse
        return std.testing.expect(false);
    try std.testing.expect(theme_idx > activity_start and theme_idx < activity_open_end);
}

test "generateAndroidManifest advertises the gamepad as an optional feature" {
    const allocator = std.testing.allocator;
    const cfg = AndroidConfig{};
    const xml = try generateAndroidManifest(allocator, "com.test.game", "Test", cfg, false);
    defer allocator.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<uses-feature android:name=\"android.hardware.gamepad\" android:required=\"false\" />") != null);
}

test "generateAndroidManifest points <application> at the staged launcher icon" {
    const allocator = std.testing.allocator;
    const xml = try generateAndroidManifest(allocator, "com.test.game", "Test", AndroidConfig{}, true);
    defer allocator.free(xml);

    // The attribute must sit on <application>, not on <activity>: an
    // activity-level icon shows in the task switcher but leaves the
    // launcher itself on the stock robot — the exact bug cli#340 fixes.
    const app_start = std.mem.indexOf(u8, xml, "<application") orelse
        return std.testing.expect(false);
    const app_open_end = std.mem.indexOfPos(u8, xml, app_start, ">") orelse
        return std.testing.expect(false);
    const icon_idx = std.mem.indexOf(u8, xml, "android:icon=\"@mipmap/ic_launcher\"") orelse
        return std.testing.expect(false);
    try std.testing.expect(icon_idx > app_start and icon_idx < app_open_end);
}

test "generateAndroidManifest omits android:icon when no icon was staged" {
    const allocator = std.testing.allocator;
    const xml = try generateAndroidManifest(allocator, "com.test.game", "Test", AndroidConfig{}, false);
    defer allocator.free(xml);
    // Referencing @mipmap/ic_launcher without the resource present is an
    // aapt link failure, so the un-staged case must stay attribute-free.
    try std.testing.expect(std.mem.indexOf(u8, xml, "android:icon=") == null);
    // hasCode stays false either way — resources are not code.
    try std.testing.expect(std.mem.indexOf(u8, xml, "android:hasCode=\"false\"") != null);
}

/// Find ANDROID_HOME.
fn findAndroidSdk(allocator: std.mem.Allocator) ![]u8 {
    if (config.globalEnviron().getAlloc(allocator, "ANDROID_HOME")) |home| {
        return home;
    } else |_| {}
    if (config.globalEnviron().getAlloc(allocator, "ANDROID_SDK_ROOT")) |home| {
        return home;
    } else |_| {}
    std.debug.print("labelle: Android SDK not found. Set ANDROID_HOME.\n", .{});
    return error.SdkNotFound;
}

/// How an SDK build-tools entry is launched on the host, which decides
/// the executable suffix to append on Windows. `native_exe` covers true
/// native binaries (aapt, zipalign → `.exe`); `script` covers the JVM
/// launcher wrappers (apksigner → `.bat`). On macOS/Linux both kinds are
/// bare names with no suffix.
const SdkToolKind = enum { native_exe, script };

/// Join a build-tools directory with a tool name, appending the
/// host-correct executable suffix. Caller owns the returned slice.
fn sdkToolPath(allocator: std.mem.Allocator, build_tools_dir: []const u8, name: []const u8, kind: SdkToolKind) ![]u8 {
    if (builtin.target.os.tag == .windows) {
        const suffix = switch (kind) {
            .native_exe => ".exe",
            .script => ".bat",
        };
        const file = try std.fmt.allocPrint(allocator, "{s}{s}", .{ name, suffix });
        defer allocator.free(file);
        return std.fs.path.join(allocator, &.{ build_tools_dir, file });
    }
    return std.fs.path.join(allocator, &.{ build_tools_dir, name });
}

/// Resolve the JDK's `jar` executable via JAVA_HOME (the Android SDK
/// requires a JDK, so JAVA_HOME is expected to point at one). On Windows
/// the binary is `jar.exe`; elsewhere it's bare `jar`. Caller owns the
/// returned slice.
fn findJar(allocator: std.mem.Allocator) ![]u8 {
    const java_home = config.globalEnviron().getAlloc(allocator, "JAVA_HOME") catch {
        std.debug.print("labelle: JAVA_HOME not set — cannot locate the JDK's 'jar' tool.\n", .{});
        std.debug.print("  set JAVA_HOME to a JDK install (the Android SDK requires one).\n", .{});
        return error.SdkNotFound;
    };
    defer allocator.free(java_home);

    const jar_name = if (builtin.target.os.tag == .windows) "jar.exe" else "jar";
    const jar_path = try std.fs.path.join(allocator, &.{ java_home, "bin", jar_name });
    errdefer allocator.free(jar_path);

    std.Io.Dir.cwd().access(config.globalIo(), jar_path, .{}) catch {
        std.debug.print("labelle: 'jar' not found at {s}\n", .{jar_path});
        std.debug.print("  ensure JAVA_HOME points at a JDK (not just a JRE).\n", .{});
        return error.SdkNotFound;
    };
    return jar_path;
}

/// Find the latest build-tools directory.
fn findBuildTools(allocator: std.mem.Allocator, sdk_home: []const u8) ![]u8 {
    const bt_dir = try std.fs.path.join(allocator, &.{ sdk_home, "build-tools" });
    defer allocator.free(bt_dir);

    var dir = std.Io.Dir.cwd().openDir(config.globalIo(), bt_dir, .{ .iterate = true }) catch {
        std.debug.print("labelle: build-tools not found at {s}\n", .{bt_dir});
        return error.SdkNotFound;
    };
    defer dir.close(config.globalIo());

    var latest: ?[]const u8 = null;
    var latest_parsed: u32 = 0;
    var iter = dir.iterate();
    while (try iter.next(config.globalIo())) |entry| {
        if (entry.kind != .directory) continue;
        // Use the existing semver parser instead of lexicographic order.
        // Lexicographic comparison treats "9.0.0" as greater than
        // "10.0.0" — wrong once the SDK ships double-digit major
        // versions (which it already has on platform-tools).
        const parsed = util.parseVersion(entry.name);
        if (latest) |prev| {
            if (parsed > latest_parsed) {
                allocator.free(prev);
                latest = try allocator.dupe(u8, entry.name);
                latest_parsed = parsed;
            }
        } else {
            latest = try allocator.dupe(u8, entry.name);
            latest_parsed = parsed;
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
    const cache_root = try asm_cache.getCacheRoot(allocator);
    defer allocator.free(cache_root);

    const keystore = try std.fs.path.join(allocator, &.{ cache_root, "android-debug.keystore" });

    std.Io.Dir.cwd().access(config.globalIo(), keystore, .{}) catch {
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
            .exited => |code| if (code != 0) {
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
pub fn copyDirectory(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    // Don't swallow createDirPath errors. PathAlreadyExists is fine — every
    // other case (permission denied, read-only fs, …) needs to surface
    // so the build doesn't continue against an unusable destination
    // and report a confusing copy-step failure later.
    cwd.createDirPath(io, dst) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var src_dir = try cwd.openDir(io, src, .{ .iterate = true });
    defer src_dir.close(io);

    var iter = src_dir.iterate();
    while (try iter.next(io)) |entry| {
        const src_sub = try std.fs.path.join(allocator, &.{ src, entry.name });
        defer allocator.free(src_sub);
        const dst_sub = try std.fs.path.join(allocator, &.{ dst, entry.name });
        defer allocator.free(dst_sub);

        switch (entry.kind) {
            .directory => try copyDirectory(allocator, src_sub, dst_sub),
            .file => try cwd.copyFile(src_sub, cwd, dst_sub, io, .{}),
            else => {},
        }
    }
}

test "generateAndroidManifest maps every Orientation to its android:screenOrientation value" {
    // Exhaustive on purpose: `sensorLandscape` is the whole point of #341, and
    // pinning the other three guards the deliberate asymmetry — `.landscape`
    // stays ONE direction on Android (a 180° flip does not rotate the game),
    // which is what `.sensor_landscape` now exists to opt out of.
    const allocator = std.testing.allocator;
    inline for (.{
        .{ project_config.Orientation.portrait, "portrait" },
        .{ project_config.Orientation.landscape, "landscape" },
        .{ project_config.Orientation.sensor_landscape, "sensorLandscape" },
        .{ project_config.Orientation.all, "unspecified" },
    }) |case| {
        const xml = try generateAndroidManifest(allocator, "com.test.game", "Test", .{ .orientation = case[0] }, false);
        defer allocator.free(xml);
        const expected = "android:screenOrientation=\"" ++ case[1] ++ "\"";
        try std.testing.expect(std.mem.indexOf(u8, xml, expected) != null);
    }
}
