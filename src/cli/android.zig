/// Android build and deployment for labelle-cli.
///
/// This file is a thin dispatcher + shared type namespace. Each
/// cohesive section of the Android pipeline lives in its own sibling
/// module under `android/`, and public surface is re-exported here so
/// call sites (and tests) keep using `android.foo` unchanged:
///
///   android/build.zig     — zig build orchestration, buildAndPackage
///   android/package.zig   — APK staging / manifest / aapt / signing
///   android/run.zig       — adb install + launch
///   android/deploy.zig    — GitHub Releases upload (labelle.games v1)
///   android/doctor.zig    — SDK/NDK probe + report
///   android/studio.zig    — Android Studio (Gradle) project generation
const std = @import("std");
const project_config = @import("project_config.zig");

// ── Submodules ─────────────────────────────────────────────────────
const build_mod = @import("android/build.zig");
const package_mod = @import("android/package.zig");
const run_mod = @import("android/run.zig");
const deploy_mod = @import("android/deploy.zig");
const doctor_mod = @import("android/doctor.zig");
const studio_mod = @import("android/studio.zig");

// ── Public re-exports ──────────────────────────────────────────────
// Keeps `android.buildAndPackage`, `android.deployToDevice`, etc.
// callable from `cli.zig` and future tests without knowing where the
// implementation lives.
pub const runDoctor = doctor_mod.runDoctor;
pub const buildAndPackage = build_mod.buildAndPackage;
pub const buildAllAbis = build_mod.buildAllAbis;
pub const packageApk = package_mod.packageApk;
pub const packageApkWithAbis = package_mod.packageApkWithAbis;
pub const deployToDevice = run_mod.deployToDevice;
pub const deployToDeviceWithAbis = run_mod.deployToDeviceWithAbis;
pub const DeployOpts = deploy_mod.DeployOpts;
pub const cmdDeploy = deploy_mod.cmdDeploy;
pub const androidStudio = studio_mod.androidStudio;

// ── Shared types ───────────────────────────────────────────────────
// These cross submodule boundaries (flag parsing here populates them,
// every submodule reads them), so they live on the dispatcher module
// both to avoid circular imports and because they ARE the common
// vocabulary of the Android pipeline.

/// Optimisation mode selected from the CLI flags.
/// `debug` is the default (stack-safe), `fast` is `ReleaseFast`,
/// `small` is `ReleaseSmall`. Maps directly to the `-Doptimize=` arg
/// we pass to `zig build`.
pub const ReleaseMode = enum {
    debug,
    fast,
    small,

    pub fn optimizeFlag(self: ReleaseMode) ?[]const u8 {
        return switch (self) {
            .debug => null,
            .fast => "-Doptimize=ReleaseFast",
            .small => "-Doptimize=ReleaseSmall",
        };
    }
};

/// APK signing configuration. Every field is optional — unset means
/// "use the debug keystore with the well-known `android` passwords".
/// When `keystore` is set, `keystore_pass` is required too; the rest
/// fall back to sensible defaults (`--key-pass` defaults to the
/// keystore pass, `--key-alias` defaults to the only alias in the
/// keystore when apksigner can find one).
pub const SigningConfig = struct {
    keystore: ?[]const u8 = null,
    keystore_pass: ?[]const u8 = null,
    key_alias: ?[]const u8 = null,
    key_pass: ?[]const u8 = null,
};

/// One built .so ready to be staged into `lib/<abi_dir>/libgame.so`.
/// `deployToDevice` takes a slice of these so the single-arch and
/// multi-arch (`--all-abis` fat APK) paths share the same staging /
/// packaging / signing / install pipeline.
pub const StagedAbi = struct {
    /// APK `lib/` subdirectory (e.g. `arm64-v8a`, `x86_64`).
    abi_dir: []const u8,
    /// Absolute or target-dir-relative path to the built `libgame.so`.
    so_path: []const u8,
};

/// Android target arch selector. Mirrors the `-Dandroid_arch` option
/// in the generated build.zig template.
pub const AbiArch = enum {
    arm64,
    x86_64,

    pub fn optionValue(self: AbiArch) []const u8 {
        return switch (self) {
            .arm64 => "arm64",
            .x86_64 => "x86_64",
        };
    }

    pub fn libDir(self: AbiArch) []const u8 {
        return switch (self) {
            .arm64 => "arm64-v8a",
            .x86_64 => "x86_64",
        };
    }
};

/// Handle `labelle android <subcommand>` dispatch.
pub fn handleAndroid(
    allocator: std.mem.Allocator,
    extra_args: []const []const u8,
    cfg: project_config.ProjectConfig,
    target_dir: []const u8,
) !void {
    var subcmd: ?[]const u8 = null;
    var emulator = false;
    var all_abis = false;
    var release_mode: ReleaseMode = .debug;
    var signing = SigningConfig{};
    // Deploy-only flags (ignored by other subcommands).
    var deploy_tag: ?[]const u8 = null;
    var deploy_channel: []const u8 = "stable";
    var deploy_notes_file: ?[]const u8 = null;

    var i: usize = 0;
    while (i < extra_args.len) : (i += 1) {
        const arg = extra_args[i];
        if (std.mem.eql(u8, arg, "--emulator")) {
            emulator = true;
        } else if (std.mem.eql(u8, arg, "--all-abis")) {
            all_abis = true;
        } else if (std.mem.eql(u8, arg, "--release")) {
            release_mode = .fast;
        } else if (std.mem.eql(u8, arg, "--release-small")) {
            release_mode = .small;
        } else if (std.mem.eql(u8, arg, "--keystore")) {
            signing.keystore = try takeValue(extra_args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--keystore-pass")) {
            signing.keystore_pass = try takeValue(extra_args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--key-alias")) {
            signing.key_alias = try takeValue(extra_args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--key-pass")) {
            signing.key_pass = try takeValue(extra_args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--tag")) {
            deploy_tag = try takeValue(extra_args, &i, arg);
        } else if (std.mem.startsWith(u8, arg, "--tag=")) {
            deploy_tag = arg["--tag=".len..];
        } else if (std.mem.eql(u8, arg, "--channel")) {
            deploy_channel = try takeValue(extra_args, &i, arg);
        } else if (std.mem.startsWith(u8, arg, "--channel=")) {
            deploy_channel = arg["--channel=".len..];
        } else if (std.mem.eql(u8, arg, "--notes-file")) {
            deploy_notes_file = try takeValue(extra_args, &i, arg);
        } else if (std.mem.startsWith(u8, arg, "--notes-file=")) {
            deploy_notes_file = arg["--notes-file=".len..];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (subcmd == null) subcmd = arg;
        }
    }

    if (signing.keystore != null and signing.keystore_pass == null) {
        std.debug.print("labelle android: --keystore requires --keystore-pass\n", .{});
        return error.InvalidArgs;
    }
    if (signing.keystore == null and
        (signing.keystore_pass != null or signing.key_alias != null or signing.key_pass != null))
    {
        std.debug.print(
            "labelle android: --keystore-pass, --key-alias and --key-pass require --keystore\n",
            .{},
        );
        return error.InvalidArgs;
    }
    if (all_abis and emulator) {
        std.debug.print("labelle android: --all-abis and --emulator are mutually exclusive\n", .{});
        return error.InvalidArgs;
    }

    const cmd = subcmd orelse {
        printHelp();
        return;
    };

    if (std.mem.eql(u8, cmd, "build")) {
        const apk_path = try build_mod.buildAndPackage(allocator, target_dir, cfg, release_mode, all_abis, emulator, signing);
        defer allocator.free(apk_path);
        std.debug.print("labelle: APK ready: {s}\n", .{apk_path});
    } else if (std.mem.eql(u8, cmd, "run")) {
        if (all_abis) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const abis = try build_mod.buildAllAbis(arena.allocator(), target_dir, release_mode);
            try run_mod.deployToDeviceWithAbis(allocator, target_dir, cfg, abis, signing);
        } else {
            try build_mod.androidBuild(allocator, target_dir, emulator, release_mode);
            try run_mod.deployToDevice(allocator, target_dir, cfg, emulator, signing);
        }
    } else if (std.mem.eql(u8, cmd, "deploy")) {
        try deploy_mod.cmdDeploy(allocator, target_dir, cfg, .{
            .tag = deploy_tag,
            .channel = deploy_channel,
            .notes_file = deploy_notes_file,
            .release_mode = if (release_mode == .debug) .fast else release_mode,
            .all_abis = all_abis,
            .emulator = emulator,
            .signing = signing,
        });
    } else if (std.mem.eql(u8, cmd, "studio")) {
        try studio_mod.androidStudio(allocator, target_dir, cfg);
    } else if (std.mem.eql(u8, cmd, "doctor")) {
        try doctor_mod.runDoctor(allocator, cfg.android);
    } else if (std.mem.eql(u8, cmd, "help")) {
        printHelp();
    } else {
        std.debug.print("labelle android: unknown subcommand '{s}'\n", .{cmd});
        printHelp();
    }
}

fn missingValue(flag: []const u8) error{InvalidArgs} {
    std.debug.print("labelle android: {s} requires a value\n", .{flag});
    return error.InvalidArgs;
}

/// Pull the next token as the value of a value-bearing flag. Rejects
/// both the end-of-args case and tokens that look like another flag
/// (start with `-`), so `--keystore --keystore-pass p` surfaces a
/// clear "--keystore requires a value" instead of silently eating
/// `--keystore-pass`.
fn takeValue(extra_args: []const []const u8, i: *usize, flag: []const u8) error{InvalidArgs}![]const u8 {
    i.* += 1;
    if (i.* >= extra_args.len) return missingValue(flag);
    const v = extra_args[i.*];
    if (std.mem.startsWith(u8, v, "-")) return missingValue(flag);
    return v;
}

pub fn printHelp() void {
    std.debug.print(
        \\
        \\Usage: labelle android <command> [options]
        \\
        \\Commands:
        \\  build      Build for Android device (arm64)
        \\  run        Build and deploy to device/emulator
        \\  studio     Generate an Android Studio (Gradle) project
        \\  deploy     Build and upload to GitHub Releases (for Obtainium OTA)
        \\  doctor     Probe the Android SDK/NDK environment and report
        \\             the status of every required tool
        \\  help       Show this help
        \\
        \\Options:
        \\  --emulator         Target x86_64 emulator instead of arm64 device
        \\  --all-abis         Build both arm64-v8a and x86_64 into a fat APK
        \\                     (mutually exclusive with --emulator; requires
        \\                      an assembler release with -Dandroid_arch)
        \\  --release          Build with ReleaseFast optimization
        \\  --release-small    Build with ReleaseSmall optimization
        \\
        \\Signing (release):
        \\  --keystore <path>       Path to JKS keystore (default: debug keystore)
        \\  --keystore-pass <pass>  apksigner --ks-pass (e.g. pass:xxx, env:VAR, file:/p)
        \\  --key-alias <name>      Key alias inside the keystore
        \\  --key-pass <pass>       apksigner --key-pass (defaults to keystore pass)
        \\
        \\Deploy (labelle android deploy):
        \\  --tag <v>               Release tag (required, e.g. v0.3.0)
        \\  --channel <name>        stable (default) | staging | preview | internal
        \\                          staging/preview/internal → GitHub pre-release
        \\  --notes-file <path>     Release notes source (default: --generate-notes
        \\                          from commits since previous tag)
        \\
        \\  Deploy implies a release build (use --release-small to opt into that
        \\  optimize level) and requires `gh` authenticated locally. Testers
        \\  install Obtainium once and subscribe to the repo URL; new releases
        \\  flow automatically.
        \\
    , .{});
}
