/// Android SDK / NDK detection.
///
/// Centralises the logic for finding every tool the `labelle android`
/// subcommand family needs: `adb`, `aapt2`, `apksigner`, `zipalign`,
/// `android.jar`, and the NDK sysroot. Each helper returns the
/// absolute path on success or an error on failure; the top-level
/// `detect()` runs every helper in tolerant mode so `labelle android
/// doctor` can report a full status instead of bailing on the first
/// missing tool.
///
/// The intent is that `src/cli/android.zig` (build + run + deploy)
/// migrates over to using these helpers in a follow-up — for now it
/// keeps its own private copies of `findAdb` / `findAndroidSdk` /
/// `findBuildTools`.
const std = @import("std");
const builtin = @import("builtin");
const util = @import("util.zig");

pub const Error = error{
    SdkNotFound,
    AdbNotFound,
    BuildToolsNotFound,
    PlatformNotFound,
    NdkNotFound,
    AaptNotFound,
    ApksignerNotFound,
    ZipalignNotFound,
    KeytoolNotFound,
    OutOfMemory,
};

/// Outcome of a single tool / path probe. Used by `detect()` to let
/// the doctor report every check even when earlier ones failed.
pub const Check = struct {
    /// Human-readable label shown in the doctor report ("adb",
    /// "aapt2", "NDK sysroot", …).
    name: []const u8,
    /// Resolved absolute path, or null if detection failed. Owned by
    /// the caller's arena allocator.
    path: ?[]const u8 = null,
    /// Optional one-line message for the user — typically a
    /// remediation hint when `path` is null ("install platform-tools
    /// with sdkmanager").
    hint: ?[]const u8 = null,
    /// Whether the absence of this tool should be treated as a hard
    /// failure (exit 1 from doctor). Optional tools like the NDK are
    /// `false` so doctor can still succeed on an SDK-only install.
    required: bool = true,
};

/// Aggregate result returned by `detect()`. Every field is optional;
/// the caller (`doctor`) walks the slice of `Check`s to print a report
/// and decide on an exit code.
pub const SdkInfo = struct {
    sdk_home: ?[]const u8 = null,
    ndk_sysroot: ?[]const u8 = null,
    adb: ?[]const u8 = null,
    aapt2: ?[]const u8 = null,
    apksigner: ?[]const u8 = null,
    zipalign: ?[]const u8 = null,
    keytool: ?[]const u8 = null,
    android_jar: ?[]const u8 = null,
    build_tools_dir: ?[]const u8 = null,
    build_tools_version: ?[]const u8 = null,
    target_sdk_version: u32 = 34,
    checks: []Check = &.{},

    pub fn hasFailures(self: SdkInfo) bool {
        for (self.checks) |c| {
            if (c.required and c.path == null) return true;
        }
        return false;
    }
};

pub const DetectOptions = struct {
    /// SDK platform version to probe for `android.jar`.
    target_sdk_version: u32 = 34,
    /// When true, surface the NDK as a required tool (build / run
    /// paths need it). Doctor defaults to `false` so the report still
    /// succeeds on SDK-only installs.
    ndk_required: bool = true,
};

/// Probe every Android tool and return a populated `SdkInfo`. Does
/// NOT return an error on individual tool misses — the report in
/// `.checks` is the source of truth. Errors are reserved for
/// allocation / environment-variable failures that make the probe
/// itself unusable.
pub fn detect(allocator: std.mem.Allocator, opts: DetectOptions) !SdkInfo {
    var info = SdkInfo{ .target_sdk_version = opts.target_sdk_version };
    var checks: std.ArrayList(Check) = .{};
    errdefer checks.deinit(allocator);

    // ── SDK home ────────────────────────────────────────────────
    info.sdk_home = findSdkHome(allocator) catch null;
    try checks.append(allocator, .{
        .name = "SDK home (ANDROID_HOME / ANDROID_SDK_ROOT)",
        .path = info.sdk_home,
        .hint = if (info.sdk_home == null)
            "set ANDROID_HOME to your Android SDK directory"
        else
            null,
        .required = true,
    });

    // Everything else is rooted at sdk_home, so bail early if it's missing.
    // The probe still records every expected tool as missing so the doctor
    // report stays informative.
    if (info.sdk_home) |sdk_home| {
        // ── adb ─────────────────────────────────────────────────
        info.adb = findAdbUnder(allocator, sdk_home) catch null;
        try checks.append(allocator, .{
            .name = "adb",
            .path = info.adb,
            .hint = if (info.adb == null)
                "install SDK platform-tools: `sdkmanager \"platform-tools\"`"
            else
                null,
            .required = true,
        });

        // ── Latest build-tools ──────────────────────────────────
        if (findBuildTools(allocator, sdk_home)) |bt| {
            info.build_tools_dir = bt.dir;
            info.build_tools_version = bt.version;
        } else |_| {}
        try checks.append(allocator, .{
            .name = "build-tools",
            .path = info.build_tools_dir,
            .hint = if (info.build_tools_dir == null)
                "install build-tools: `sdkmanager \"build-tools;34.0.0\"`"
            else
                null,
            .required = true,
        });

        // ── aapt2 / apksigner / zipalign (inside build-tools) ───
        if (info.build_tools_dir) |bt_dir| {
            info.aapt2 = joinIfExists(allocator, &.{ bt_dir, "aapt2" });
            info.apksigner = joinIfExists(allocator, &.{ bt_dir, "apksigner" });
            info.zipalign = joinIfExists(allocator, &.{ bt_dir, "zipalign" });
        }
        try checks.append(allocator, .{
            .name = "aapt2",
            .path = info.aapt2,
            .hint = if (info.aapt2 == null) "missing from build-tools" else null,
            .required = true,
        });
        try checks.append(allocator, .{
            .name = "apksigner",
            .path = info.apksigner,
            .hint = if (info.apksigner == null) "missing from build-tools" else null,
            .required = true,
        });
        try checks.append(allocator, .{
            .name = "zipalign",
            .path = info.zipalign,
            .hint = if (info.zipalign == null) "missing from build-tools" else null,
            .required = true,
        });

        // ── android.jar (SDK platform) ──────────────────────────
        info.android_jar = findAndroidJar(allocator, sdk_home, opts.target_sdk_version) catch null;
        try checks.append(allocator, .{
            .name = "android.jar (platform)",
            .path = info.android_jar,
            .hint = if (info.android_jar == null)
                hintAllocPrint(allocator, "install SDK platform: `sdkmanager \"platforms;android-{d}\"`", .{opts.target_sdk_version})
            else
                null,
            .required = true,
        });

        // ── NDK sysroot ─────────────────────────────────────────
        info.ndk_sysroot = findNdkSysroot(allocator, sdk_home) catch null;
        try checks.append(allocator, .{
            .name = "NDK sysroot",
            .path = info.ndk_sysroot,
            .hint = if (info.ndk_sysroot == null)
                "install an NDK: `sdkmanager \"ndk;27.0.12077973\"` (or set ANDROID_NDK_HOME)"
            else
                null,
            .required = opts.ndk_required,
        });
    } else {
        // Record the downstream checks as missing but with an "SDK
        // home required first" hint so the report explains the
        // cascade.
        const cascade_hint: []const u8 = "resolve SDK home first";
        inline for (.{
            "adb",
            "build-tools",
            "aapt2",
            "apksigner",
            "zipalign",
            "android.jar (platform)",
            "NDK sysroot",
        }) |name| {
            try checks.append(allocator, .{
                .name = name,
                .path = null,
                .hint = cascade_hint,
                .required = true,
            });
        }
    }

    // ── keytool (JDK) ───────────────────────────────────────────
    // Needed to generate the debug keystore on first install. Not
    // part of the SDK but required by `android run` / `android build`.
    info.keytool = findOnPath(allocator, "keytool") catch null;
    try checks.append(allocator, .{
        .name = "keytool (JDK)",
        .path = info.keytool,
        .hint = if (info.keytool == null)
            "install a JDK (any modern one ships keytool)"
        else
            null,
        .required = true,
    });

    info.checks = try checks.toOwnedSlice(allocator);
    return info;
}

// ── Individual probes ──────────────────────────────────────────────

/// Resolve `$ANDROID_HOME`, falling back to `$ANDROID_SDK_ROOT`.
pub fn findSdkHome(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "ANDROID_HOME")) |home| {
        return home;
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "ANDROID_SDK_ROOT")) |home| {
        return home;
    } else |_| {}
    return error.SdkNotFound;
}

/// Resolve adb: prefer `<sdk>/platform-tools/adb`, fall back to
/// whatever `which adb` returns.
pub fn findAdbUnder(allocator: std.mem.Allocator, sdk_home: []const u8) ![]u8 {
    const candidate = try std.fs.path.join(allocator, &.{ sdk_home, "platform-tools", exeName("adb") });
    if (std.fs.cwd().access(candidate, .{})) |_| {
        return candidate;
    } else |_| {
        allocator.free(candidate);
    }
    return findOnPath(allocator, "adb") catch error.AdbNotFound;
}

pub const BuildTools = struct {
    dir: []const u8,
    version: []const u8,
};

/// Locate the newest `<sdk>/build-tools/<version>/` directory.
/// Caller owns both returned slices.
pub fn findBuildTools(allocator: std.mem.Allocator, sdk_home: []const u8) !BuildTools {
    const bt_root = try std.fs.path.join(allocator, &.{ sdk_home, "build-tools" });
    defer allocator.free(bt_root);

    var dir = std.fs.cwd().openDir(bt_root, .{ .iterate = true }) catch return error.BuildToolsNotFound;
    defer dir.close();

    var latest: ?[]const u8 = null;
    errdefer if (latest) |v| allocator.free(v);

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (latest) |prev| {
            if (std.mem.order(u8, entry.name, prev) == .gt) {
                allocator.free(prev);
                latest = try allocator.dupe(u8, entry.name);
            }
        } else {
            latest = try allocator.dupe(u8, entry.name);
        }
    }

    const version = latest orelse return error.BuildToolsNotFound;
    const joined = try std.fs.path.join(allocator, &.{ bt_root, version });
    return .{ .dir = joined, .version = version };
}

/// `<sdk>/platforms/android-<target_sdk>/android.jar` — the compile
/// classpath used by `aapt2`.
pub fn findAndroidJar(allocator: std.mem.Allocator, sdk_home: []const u8, target_sdk_version: u32) ![]u8 {
    const joined = try std.fmt.allocPrint(
        allocator,
        "{s}/platforms/android-{d}/android.jar",
        .{ sdk_home, target_sdk_version },
    );
    if (std.fs.cwd().access(joined, .{})) |_| return joined else |_| {
        allocator.free(joined);
        return error.PlatformNotFound;
    }
}

/// Resolve the NDK sysroot (for `-target aarch64-linux-android`):
/// 1. `$ANDROID_NDK_HOME` if set and valid.
/// 2. The newest `<sdk>/ndk/<version>/toolchains/llvm/prebuilt/<host>/sysroot/`.
pub fn findNdkSysroot(allocator: std.mem.Allocator, sdk_home: []const u8) ![]u8 {
    // 1. Explicit env var.
    if (std.process.getEnvVarOwned(allocator, "ANDROID_NDK_HOME")) |ndk_home| {
        defer allocator.free(ndk_home);
        const sysroot = try std.fs.path.join(allocator, &.{
            ndk_home, "toolchains", "llvm", "prebuilt", ndkHostTag(), "sysroot",
        });
        if (std.fs.cwd().access(sysroot, .{})) |_| return sysroot else |_| allocator.free(sysroot);
    } else |_| {}

    // 2. Newest NDK in `<sdk>/ndk/<version>`.
    const ndk_root = try std.fs.path.join(allocator, &.{ sdk_home, "ndk" });
    defer allocator.free(ndk_root);

    var dir = std.fs.cwd().openDir(ndk_root, .{ .iterate = true }) catch return error.NdkNotFound;
    defer dir.close();

    var latest: ?[]const u8 = null;
    errdefer if (latest) |v| allocator.free(v);
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (latest) |prev| {
            if (std.mem.order(u8, entry.name, prev) == .gt) {
                allocator.free(prev);
                latest = try allocator.dupe(u8, entry.name);
            }
        } else {
            latest = try allocator.dupe(u8, entry.name);
        }
    }

    const version = latest orelse return error.NdkNotFound;
    defer allocator.free(version);
    const sysroot = try std.fs.path.join(allocator, &.{
        ndk_root, version, "toolchains", "llvm", "prebuilt", ndkHostTag(), "sysroot",
    });
    if (std.fs.cwd().access(sysroot, .{})) |_| return sysroot else |_| {
        allocator.free(sysroot);
        return error.NdkNotFound;
    }
}

// ── Helpers ────────────────────────────────────────────────────────

/// NDK `<host>` triple used in `toolchains/llvm/prebuilt/<host>/`.
/// The NDK ships only the `darwin-x86_64` directory even on Apple
/// Silicon — aarch64 darwin runs the x86_64 binaries via Rosetta.
fn ndkHostTag() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux-x86_64",
        .macos => "darwin-x86_64",
        .windows => "windows-x86_64",
        else => "linux-x86_64",
    };
}

fn exeName(comptime base: []const u8) []const u8 {
    return if (builtin.os.tag == .windows) base ++ ".exe" else base;
}

/// Join a path and return it only if it exists on disk. Frees the
/// joined buffer on miss. Used for tools inside build-tools where we
/// don't want a user-visible error — just a missing-from-report.
fn joinIfExists(allocator: std.mem.Allocator, parts: []const []const u8) ?[]u8 {
    const joined = std.fs.path.join(allocator, parts) catch return null;
    if (std.fs.cwd().access(joined, .{})) |_| return joined else |_| {
        allocator.free(joined);
        return null;
    }
}

/// Resolve a tool via `which <name>`. Caller owns the returned slice.
fn findOnPath(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const result = util.runCmd(allocator, &.{ "which", name }) catch return error.AdbNotFound;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    if (result.term == .Exited and result.term.Exited == 0 and result.stdout.len > 0) {
        const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
        return allocator.dupe(u8, trimmed);
    }
    return error.AdbNotFound;
}

fn hintAllocPrint(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    return std.fmt.allocPrint(allocator, fmt, args) catch null;
}
