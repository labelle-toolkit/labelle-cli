/// Android Studio project generation — `labelle android studio`.
///
/// Mirrors `labelle ios xcode`: builds the game's `libgame.so`, then
/// scaffolds a self-contained Gradle project around it so users can
/// open the project in Android Studio for signing, release builds,
/// Play Store packaging, or just IDE-driven debugging.
///
/// The generated tree is:
///
///   android-studio/
///     settings.gradle.kts
///     build.gradle.kts
///     gradle.properties
///     gradle/wrapper/gradle-wrapper.properties
///     app/build.gradle.kts
///     app/src/main/AndroidManifest.xml
///     app/src/main/jniLibs/arm64-v8a/libgame.so
///     app/src/main/assets/...
///
/// v1 scope: arm64-v8a only (the device ABI). The generated Gradle
/// project ships no Gradle wrapper JAR/scripts — Android Studio's
/// "use Gradle wrapper" prompt or a locally installed `gradle` fills
/// that in. Multi-ABI jniLibs and a vendored wrapper are deferred
/// (see the PR description).
const std = @import("std");
const config = @import("../config.zig");
const project_config = @import("../project_config.zig");
const android = @import("../android.zig");
const build_mod = @import("build.zig");
const package = @import("package.zig");

const AndroidConfig = project_config.AndroidConfig;
const ReleaseMode = android.ReleaseMode;

/// Gradle/AGP versions the generated project pins. Kept here as named
/// constants so a future bump is a one-line change.
const agp_version = "8.5.2";
const gradle_distribution = "gradle-8.9-bin.zip";
const ndk_version = "27.0.12077973";

/// Generate an Android Studio (Gradle) project under
/// `android-studio/` next to the game's `.labelle/` directory.
///
/// `target_dir` is the generated `.labelle/<backend>_<platform>/`
/// directory (same value the other Android subcommands receive), so
/// the project lands two levels up alongside `.labelle/`.
pub fn androidStudio(
    allocator: std.mem.Allocator,
    target_dir: []const u8,
    cfg: project_config.ProjectConfig,
    release_mode: ReleaseMode,
) !void {
    const android_cfg = cfg.android orelse AndroidConfig{};
    const app_name = if (android_cfg.app_name.len > 0) android_cfg.app_name else cfg.title;

    const package_name = try package.resolvePackageName(allocator, cfg);
    defer allocator.free(package_name);

    // Build the device .so first so the project is runnable as soon
    // as it is opened. arm64-v8a only in v1.
    std.debug.print("labelle: step 1 — building libgame.so for arm64-v8a...\n", .{});
    try build_mod.androidBuild(allocator, target_dir, false, release_mode);

    const so_src = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "lib", "libgame.so" });
    defer allocator.free(so_src);
    std.Io.Dir.cwd().access(config.globalIo(), so_src, .{}) catch {
        std.debug.print("labelle: build did not produce {s}\n", .{so_src});
        return error.BinaryNotFound;
    };

    // Output directory: <target_dir>/../../android-studio
    const studio_dir = try std.fs.path.join(allocator, &.{ target_dir, "..", "..", "android-studio" });
    defer allocator.free(studio_dir);

    const app_dir = try std.fs.path.join(allocator, &.{ studio_dir, "app" });
    defer allocator.free(app_dir);

    const main_dir = try std.fs.path.join(allocator, &.{ app_dir, "src", "main" });
    defer allocator.free(main_dir);

    const jni_dir = try std.fs.path.join(allocator, &.{ main_dir, "jniLibs", "arm64-v8a" });
    defer allocator.free(jni_dir);

    const wrapper_dir = try std.fs.path.join(allocator, &.{ studio_dir, "gradle", "wrapper" });
    defer allocator.free(wrapper_dir);

    try std.Io.Dir.cwd().createDirPath(config.globalIo(), jni_dir);
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), wrapper_dir);

    // ── Native library ────────────────────────────────────────────
    const so_dst = try std.fs.path.join(allocator, &.{ jni_dir, "libgame.so" });
    defer allocator.free(so_dst);
    try std.Io.Dir.cwd().copyFile(so_src, std.Io.Dir.cwd(), so_dst, config.globalIo(), .{});

    // ── Assets ────────────────────────────────────────────────────
    const assets_src = try std.fs.path.join(allocator, &.{ target_dir, "assets" });
    defer allocator.free(assets_src);
    const assets_dst = try std.fs.path.join(allocator, &.{ main_dir, "assets" });
    defer allocator.free(assets_dst);
    // A game without an assets/ directory is still valid — skip the
    // copy in that case, but let genuine I/O errors surface.
    if (std.Io.Dir.cwd().access(config.globalIo(), assets_src, .{})) |_| {
        try package.copyDirectory(allocator, assets_src, assets_dst);
    } else |_| {}

    // ── Generated files ───────────────────────────────────────────
    try writeFile(allocator, studio_dir, "settings.gradle.kts", try settingsGradle(allocator, app_name));
    try writeFile(allocator, studio_dir, "build.gradle.kts", try rootBuildGradle(allocator));
    try writeFile(allocator, studio_dir, "gradle.properties", try gradleProperties(allocator));

    const wrapper_props = try gradleWrapperProperties(allocator);
    try writeFile(allocator, wrapper_dir, "gradle-wrapper.properties", wrapper_props);

    const app_gradle = try appBuildGradle(allocator, package_name, android_cfg);
    try writeFile(allocator, app_dir, "build.gradle.kts", app_gradle);

    const manifest = try generateStudioManifest(allocator, app_name, android_cfg);
    try writeFile(allocator, main_dir, "AndroidManifest.xml", manifest);

    std.debug.print("\nlabelle: Android Studio project generated!\n", .{});
    std.debug.print("  location: android-studio/\n\n", .{});
    std.debug.print("Next steps:\n", .{});
    std.debug.print("  1. Open the android-studio/ directory in Android Studio\n", .{});
    std.debug.print("  2. Let it create the Gradle wrapper / sync the project\n", .{});
    std.debug.print("  3. Build & run, or configure signing for a release build\n", .{});
}

/// Write `data` to `<dir>/<name>` and free `data` afterward. The
/// generated-content helpers all return owned slices, so funnelling
/// them through here keeps the call site free of per-file defers.
fn writeFile(allocator: std.mem.Allocator, dir: []const u8, name: []const u8, data: []const u8) !void {
    defer allocator.free(data);
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = path, .data = data });
}

/// `settings.gradle.kts` — names the Gradle build and includes the
/// single `:app` module.
fn settingsGradle(allocator: std.mem.Allocator, app_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\pluginManagement {{
        \\    repositories {{
        \\        google()
        \\        mavenCentral()
        \\        gradlePluginPortal()
        \\    }}
        \\}}
        \\
        \\dependencyResolutionManagement {{
        \\    repositories {{
        \\        google()
        \\        mavenCentral()
        \\    }}
        \\}}
        \\
        \\rootProject.name = "{s}"
        \\include(":app")
        \\
    , .{app_name});
}

/// Root `build.gradle.kts` — declares the Android Gradle Plugin
/// version for the `:app` module without applying it at the root.
/// Returns an owned slice (the content is static, but `writeFile`
/// takes ownership and frees it).
fn rootBuildGradle(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(u8, "plugins {\n" ++
        "    id(\"com.android.application\") version \"" ++ agp_version ++ "\" apply false\n" ++
        "}\n");
}

/// `gradle.properties` — JVM args + AndroidX opt-in. Plain NativeActivity
/// games need neither, but Android Studio's project sync expects them.
/// Returns an owned slice (see `rootBuildGradle`).
fn gradleProperties(allocator: std.mem.Allocator) ![]const u8 {
    return allocator.dupe(u8, "org.gradle.jvmargs=-Xmx2048m\n" ++
        "android.useAndroidX=true\n" ++
        "android.nonTransitiveRClass=true\n");
}

/// `gradle/wrapper/gradle-wrapper.properties` — points at the Gradle
/// distribution. The wrapper JAR/scripts themselves are not vendored
/// (see module doc comment).
fn gradleWrapperProperties(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\distributionBase=GRADLE_USER_HOME
        \\distributionPath=wrapper/dists
        \\distributionUrl=https\://services.gradle.org/distributions/{s}
        \\zipStoreBase=GRADLE_USER_HOME
        \\zipStorePath=wrapper/dists
        \\
    , .{gradle_distribution});
}

/// `app/build.gradle.kts` — the Android application module. Packages
/// the prebuilt `libgame.so` from `jniLibs/` and the staged assets;
/// it does NOT compile any Zig — `labelle` owns the native build.
fn appBuildGradle(
    allocator: std.mem.Allocator,
    package_name: []const u8,
    cfg: AndroidConfig,
) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\plugins {{
        \\    id("com.android.application")
        \\}}
        \\
        \\android {{
        \\    namespace = "{s}"
        \\    compileSdk = {d}
        \\    ndkVersion = "{s}"
        \\
        \\    defaultConfig {{
        \\        applicationId = "{s}"
        \\        minSdk = {d}
        \\        targetSdk = {d}
        \\        versionCode = 1
        \\        versionName = "1.0"
        \\        ndk {{
        \\            abiFilters += listOf("arm64-v8a")
        \\        }}
        \\    }}
        \\
        \\    buildTypes {{
        \\        release {{
        \\            isMinifyEnabled = false
        \\        }}
        \\    }}
        \\
        \\    // The .so is built by `labelle` and dropped into
        \\    // src/main/jniLibs/ — Gradle just packages it.
        \\    sourceSets {{
        \\        getByName("main") {{
        \\            jniLibs.srcDirs("src/main/jniLibs")
        \\        }}
        \\    }}
        \\}}
        \\
    , .{ package_name, cfg.target_sdk_version, ndk_version, package_name, cfg.min_sdk_version, cfg.target_sdk_version });
}

/// `AndroidManifest.xml` for the Gradle project. Unlike the
/// aapt-packaged manifest in `package.zig`, this one carries no
/// `package=` attribute (AGP injects `applicationId` from
/// `build.gradle.kts`) and no version attributes.
fn generateStudioManifest(
    allocator: std.mem.Allocator,
    app_name: []const u8,
    cfg: AndroidConfig,
) ![]const u8 {
    const orientation = switch (cfg.orientation) {
        .portrait => "portrait",
        .landscape => "landscape",
        .sensor_landscape => "sensorLandscape",
        .all => "unspecified",
    };

    const theme_attr: []const u8 = if (cfg.immersive_mode)
        "\n            android:theme=\"@android:style/Theme.NoTitleBar.Fullscreen\""
    else
        "";

    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<manifest xmlns:android="http://schemas.android.com/apk/res/android">
        \\
        \\    <uses-feature android:glEsVersion="0x00030000" android:required="true" />
        \\    <uses-feature android:name="android.hardware.gamepad" android:required="false" />
        \\
        \\    <application android:hasCode="false" android:label="{s}">
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
    , .{ app_name, orientation, theme_attr });
}

// ── Tests ──────────────────────────────────────────────────────────

test "settingsGradle embeds the app name as the root project name" {
    const allocator = std.testing.allocator;
    const out = try settingsGradle(allocator, "My Cool Game");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "rootProject.name = \"My Cool Game\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "include(\":app\")") != null);
}

test "rootBuildGradle pins the Android Gradle Plugin version" {
    const allocator = std.testing.allocator;
    const out = try rootBuildGradle(allocator);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "com.android.application") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, agp_version) != null);
    // Root build must not apply the plugin.
    try std.testing.expect(std.mem.indexOf(u8, out, "apply false") != null);
}

test "gradleWrapperProperties references the pinned distribution" {
    const allocator = std.testing.allocator;
    const out = try gradleWrapperProperties(allocator);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, gradle_distribution) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "distributionUrl=") != null);
}

test "appBuildGradle wires applicationId, sdk versions and abiFilters" {
    const allocator = std.testing.allocator;
    const cfg = AndroidConfig{ .min_sdk_version = 28, .target_sdk_version = 34 };
    const out = try appBuildGradle(allocator, "com.test.game", cfg);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "applicationId = \"com.test.game\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "namespace = \"com.test.game\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "minSdk = 28") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "targetSdk = 34") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "arm64-v8a") != null);
}

test "generateStudioManifest omits package and version attributes" {
    const allocator = std.testing.allocator;
    const cfg = AndroidConfig{};
    const out = try generateStudioManifest(allocator, "Test", cfg);
    defer allocator.free(out);
    // AGP injects applicationId/versionCode — the manifest must not.
    try std.testing.expect(std.mem.indexOf(u8, out, "package=") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "android:versionCode") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "android:label=\"Test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "NativeActivity") != null);
}

test "generateStudioManifest honours orientation and immersive_mode" {
    const allocator = std.testing.allocator;
    const portrait = try generateStudioManifest(allocator, "T", .{ .orientation = .portrait });
    defer allocator.free(portrait);
    try std.testing.expect(std.mem.indexOf(u8, portrait, "android:screenOrientation=\"portrait\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, portrait, "android:theme=") == null);

    const immersive = try generateStudioManifest(allocator, "T", .{ .immersive_mode = true });
    defer allocator.free(immersive);
    try std.testing.expect(std.mem.indexOf(u8, immersive, "Theme.NoTitleBar.Fullscreen") != null);
}

test "generateStudioManifest advertises the gamepad as an optional feature" {
    const allocator = std.testing.allocator;
    const cfg = AndroidConfig{};
    const out = try generateStudioManifest(allocator, "Test", cfg);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<uses-feature android:name=\"android.hardware.gamepad\" android:required=\"false\" />") != null);
}

test "generateStudioManifest maps every Orientation to its android:screenOrientation value" {
    // Same exhaustive pin as the package (APK) manifest — the Studio-project
    // manifest is a second emitter of the same attribute and has drifted from
    // it before, so both are checked against the identical table (#341).
    const allocator = std.testing.allocator;
    inline for (.{
        .{ project_config.Orientation.portrait, "portrait" },
        .{ project_config.Orientation.landscape, "landscape" },
        .{ project_config.Orientation.sensor_landscape, "sensorLandscape" },
        .{ project_config.Orientation.all, "unspecified" },
    }) |case| {
        const xml = try generateStudioManifest(allocator, "T", .{ .orientation = case[0] });
        defer allocator.free(xml);
        const expected = "android:screenOrientation=\"" ++ case[1] ++ "\"";
        try std.testing.expect(std.mem.indexOf(u8, xml, expected) != null);
    }
}
