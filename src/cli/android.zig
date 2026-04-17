/// Android build and deployment for labelle-cli.
///
/// Submodules live in `android/`. Each one owns a cohesive slice of
/// the Android pipeline and imports the types it needs from this
/// file (which doubles as the public namespace — `android.DeployOpts`,
/// `android.buildAndPackage`, …).
const std = @import("std");
const gen = @import("generator");
const runner = @import("runner.zig");
const util = @import("util.zig");
const android_sdk = @import("android_sdk.zig");

// ── Submodules ─────────────────────────────────────────────────────
const deploy_mod = @import("android/deploy.zig");

// Re-export deploy-side public types so callers see them on the
// `android` namespace (`android.DeployOpts`) without having to know
// about the internal module layout.
pub const DeployOpts = deploy_mod.DeployOpts;
pub const cmdDeploy = deploy_mod.cmdDeploy;

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

/// The two arches `--all-abis` produces, in the order they're built.
/// arm64 first so the faster device build runs before the slower
/// x86_64 cross-build.
const all_abi_archs = [_]AbiArch{ .arm64, .x86_64 };

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
    cfg: gen.ProjectConfig,
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
        const apk_path = try buildAndPackage(allocator, target_dir, cfg, release_mode, all_abis, emulator, signing);
        defer allocator.free(apk_path);
        std.debug.print("labelle: APK ready: {s}\n", .{apk_path});
    } else if (std.mem.eql(u8, cmd, "run")) {
        if (all_abis) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const abis = try buildAllAbis(arena.allocator(), target_dir, release_mode);
            try deployToDeviceWithAbis(allocator, target_dir, cfg, abis, signing);
        } else {
            try androidBuild(allocator, target_dir, emulator, release_mode);
            try deployToDevice(allocator, target_dir, cfg, emulator, signing);
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
    } else if (std.mem.eql(u8, cmd, "doctor")) {
        try runDoctor(allocator, cfg.android);
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

/// Run the SDK / NDK environment probe and print a pass/fail report.
/// Used via `labelle android doctor`. Exits the process with code 1
/// when any required tool is missing so CI scripts can gate on it.
///
/// Takes an optional `android_cfg` purely to pick up the project's
/// `target_sdk_version`. When called without a project (via the
/// standalone dispatch in cli.zig for `labelle android doctor` in a
/// random directory), pass `null` to use the defaults.
pub fn runDoctor(allocator: std.mem.Allocator, android_cfg: ?gen.AndroidConfig) !void {
    // Every probe allocates path strings and the checks list; they all
    // live until the report is printed at the end of this function. An
    // arena matches that lifetime exactly and avoids tracking every
    // individual allocation through optional / catch-null branches.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const resolved = android_cfg orelse gen.AndroidConfig{};
    const info = try android_sdk.detect(arena_alloc, .{
        .target_sdk_version = resolved.target_sdk_version,
        // In doctor mode the NDK miss is still a hard failure — builds
        // will fail without it — but we surface every check first so
        // the user sees the full picture.
        .ndk_required = true,
    });

    std.debug.print(
        \\
        \\labelle android doctor
        \\======================
        \\  target SDK: {d}
        \\
    , .{info.target_sdk_version});

    var failures: u32 = 0;
    var optional_misses: u32 = 0;
    for (info.checks) |check| {
        if (check.path) |p| {
            std.debug.print("  [  OK  ] {s}\n           {s}\n", .{ check.name, p });
        } else if (check.required) {
            failures += 1;
            std.debug.print("  [ FAIL ] {s}\n", .{check.name});
            if (check.hint) |h| std.debug.print("           → {s}\n", .{h});
        } else {
            optional_misses += 1;
            std.debug.print("  [ WARN ] {s}\n", .{check.name});
            if (check.hint) |h| std.debug.print("           → {s}\n", .{h});
        }
    }

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("  All required Android tools are present.\n", .{});
        if (optional_misses > 0) {
            std.debug.print("  ({d} optional tool(s) missing — see WARN lines above.)\n", .{optional_misses});
        }
        std.debug.print("\n", .{});
    } else {
        std.debug.print("  {d} required tool(s) missing — see FAIL lines above.\n", .{failures});
        std.debug.print("  Install instructions: https://developer.android.com/tools\n\n", .{});
        return error.AndroidToolsMissing;
    }
}

/// Build every ABI the fat APK needs, stashing each `libgame.so` at
/// a per-arch path so back-to-back `zig build` invocations don't
/// clobber each other. Returns a slice of `StagedAbi` entries —
/// every `so_path` field and the slice itself are owned by
/// `allocator`.
///
/// Callers pass an ArenaAllocator so transient intermediate strings
/// (stash_root, per-iter dst_dir) plus the returned slice are
/// released together; manual defers are still used for correctness
/// under a non-arena allocator (the `errdefer` that walks the list
/// on failure, and the per-iter `dst_dir` free).
///
/// Relies on the generated build.zig accepting
/// `-Dandroid_arch=arm64|x86_64`, which landed in labelle-assembler's
/// Android template. Projects generated before that template change
/// will fail with "unknown option 'android_arch'" — users need to
/// regenerate build.zig.
fn buildAllAbis(allocator: std.mem.Allocator, target_dir: []const u8, release_mode: ReleaseMode) ![]const StagedAbi {
    const stash_root = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "android-multi" });
    defer allocator.free(stash_root);
    // Wipe any stale per-arch binaries from a previous `--all-abis`
    // run — we want each invocation to start from a clean slate so
    // aborted builds don't leave half-a-fat-APK lying around. Missing
    // is fine; permission errors will surface on makePath below.
    std.fs.cwd().deleteTree(stash_root) catch {};
    try std.fs.cwd().makePath(stash_root);

    var staged: std.ArrayList(StagedAbi) = .{};
    errdefer {
        for (staged.items) |item| allocator.free(item.so_path);
        staged.deinit(allocator);
    }

    for (all_abi_archs) |abi| {
        try androidBuildArch(allocator, target_dir, abi, release_mode);

        const src = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "lib", "libgame.so" });
        defer allocator.free(src);
        std.fs.cwd().access(src, .{}) catch {
            std.debug.print("labelle: build for {s} did not produce {s}\n", .{ abi.optionValue(), src });
            return error.BinaryNotFound;
        };

        const dst_dir = try std.fs.path.join(allocator, &.{ stash_root, abi.libDir() });
        defer allocator.free(dst_dir);
        try std.fs.cwd().makePath(dst_dir);

        const dst = try std.fs.path.join(allocator, &.{ dst_dir, "libgame.so" });
        errdefer allocator.free(dst);
        try std.fs.cwd().copyFile(src, std.fs.cwd(), dst, .{});

        try staged.append(allocator, .{ .abi_dir = abi.libDir(), .so_path = dst });
    }

    return staged.toOwnedSlice(allocator);
}

/// Run `zig build -Dandroid_arch=<abi>` for a single target arch.
/// Unlike `androidBuild`, this never passes `-Demulator` — the arch
/// is selected explicitly so back-to-back builds are reproducible
/// regardless of host CPU.
fn androidBuildArch(allocator: std.mem.Allocator, target_dir: []const u8, abi: AbiArch, release_mode: ReleaseMode) !void {
    const mode_label = switch (release_mode) {
        .debug => "",
        .fast => " [ReleaseFast]",
        .small => " [ReleaseSmall]",
    };
    std.debug.print("labelle: building for Android ({s}){s}...\n", .{ abi.libDir(), mode_label });

    var zig_args: std.ArrayList([]const u8) = .{};
    defer zig_args.deinit(allocator);
    try zig_args.appendSlice(allocator, &.{ "zig", "build" });

    const arch_flag = try std.fmt.allocPrint(allocator, "-Dandroid_arch={s}", .{abi.optionValue()});
    defer allocator.free(arch_flag);
    try zig_args.append(allocator, arch_flag);

    if (release_mode.optimizeFlag()) |flag| {
        try zig_args.append(allocator, flag);
    }

    const build_result = try runner.runZig(allocator, target_dir, zig_args.items);
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);

    switch (build_result.term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("labelle: Android build failed ({s}):\n{s}\n", .{ abi.libDir(), build_result.stderr });
            return error.BuildFailed;
        },
        else => {
            std.debug.print("labelle: Android build ({s}) terminated abnormally\n{s}\n", .{ abi.libDir(), build_result.stderr });
            return error.BuildFailed;
        },
    }
    std.debug.print("  {s} build ok\n", .{abi.libDir()});
}

/// Build the Android shared library via `zig build`.
fn androidBuild(allocator: std.mem.Allocator, target_dir: []const u8, emulator: bool, release_mode: ReleaseMode) !void {
    const mode_label = switch (release_mode) {
        .debug => "",
        .fast => " [ReleaseFast]",
        .small => " [ReleaseSmall]",
    };
    std.debug.print("labelle: building for Android{s}{s}...\n", .{
        if (emulator) " (emulator)" else "",
        mode_label,
    });

    var zig_args: std.ArrayList([]const u8) = .{};
    defer zig_args.deinit(allocator);
    try zig_args.appendSlice(allocator, &.{ "zig", "build" });

    if (emulator) {
        try zig_args.append(allocator, "-Demulator=true");
    }
    if (release_mode.optimizeFlag()) |flag| {
        try zig_args.append(allocator, flag);
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

/// Package APK and deploy to device/emulator via ADB. Single-arch
/// entry point — picks the ABI from `emulator` + host arch, then
/// delegates to `deployToDeviceWithAbis`.
pub fn deployToDevice(allocator: std.mem.Allocator, target_dir: []const u8, cfg: gen.ProjectConfig, emulator: bool, signing: SigningConfig) !void {
    const abi_dir = hostAbiDir(emulator);
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
    const apk_path = try packageApkWithAbis(allocator, target_dir, cfg, abis, signing);
    defer allocator.free(apk_path);

    const package_name = try resolvePackageName(allocator, cfg);
    defer allocator.free(package_name);

    try installAndLaunch(allocator, apk_path, package_name);
}

/// Single-arch wrapper around `packageApkWithAbis` that mirrors
/// `deployToDevice`: picks the ABI from `emulator` + host arch,
/// compiles a one-element `StagedAbi` slice, and returns the path to
/// the signed APK (caller owns it).
///
/// Used by `labelle android build` when `--all-abis` is not set.
pub fn packageApk(
    allocator: std.mem.Allocator,
    target_dir: []const u8,
    cfg: gen.ProjectConfig,
    emulator: bool,
    signing: SigningConfig,
) ![]u8 {
    const abi_dir = hostAbiDir(emulator);
    const so_path = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "lib", "libgame.so" });
    defer allocator.free(so_path);
    const abis = [_]StagedAbi{.{ .abi_dir = abi_dir, .so_path = so_path }};
    return packageApkWithAbis(allocator, target_dir, cfg, abis[0..], signing);
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
pub fn packageApkWithAbis(
    allocator: std.mem.Allocator,
    target_dir: []const u8,
    cfg: gen.ProjectConfig,
    abis: []const StagedAbi,
    signing: SigningConfig,
) ![]u8 {
    if (abis.len == 0) return error.NoAbisProvided;

    const android_cfg = cfg.android orelse gen.AndroidConfig{};
    // package_name may be heap-allocated (defaultPackageName) or a slice into
    // android_cfg (no allocation).  Track whether we own it so we can free it.
    const package_name_owned = android_cfg.package_name.len == 0;
    const package_name = if (android_cfg.package_name.len > 0) android_cfg.package_name else try defaultPackageName(allocator, cfg.name);
    defer if (package_name_owned) allocator.free(package_name);
    const app_name = if (android_cfg.app_name.len > 0) android_cfg.app_name else cfg.title;

    // Validate every .so exists before we touch the staging dir.
    for (abis) |abi| {
        std.fs.cwd().access(abi.so_path, .{}) catch {
            std.debug.print("labelle: Android .so not found at {s}\n", .{abi.so_path});
            return error.BinaryNotFound;
        };
    }

    // Create APK staging directory
    const staging_dir = try std.fs.path.join(allocator, &.{ target_dir, "apk-staging" });
    defer allocator.free(staging_dir);
    // Intentionally ignoring errors: the staging directory may not exist on first run.
    std.fs.cwd().deleteTree(staging_dir) catch {};

    // Fan out every staged .so into `lib/<abi>/libgame.so`. The fat
    // APK case produces multiple directories under `lib/`; apksigner
    // and Android's package installer pick the right one per device.
    for (abis) |abi| {
        const lib_dir = try std.fs.path.join(allocator, &.{ staging_dir, "lib", abi.abi_dir });
        defer allocator.free(lib_dir);
        try std.fs.cwd().makePath(lib_dir);

        const staged_so = try std.fs.path.join(allocator, &.{ lib_dir, "libgame.so" });
        defer allocator.free(staged_so);
        try std.fs.cwd().copyFile(abi.so_path, std.fs.cwd(), staged_so, .{});
    }

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
    errdefer allocator.free(apk_path);
    try buildApk(allocator, staging_dir, apk_path, android_cfg, signing);
    return apk_path;
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

/// Pick the ABI directory for a single-arch build. On Apple Silicon
/// the Android emulator runs ARM64 images; on Intel Macs it runs
/// x86_64. Physical device builds always target arm64-v8a.
fn hostAbiDir(emulator: bool) []const u8 {
    const builtin = @import("builtin");
    return if (emulator and builtin.cpu.arch != .aarch64) "x86_64" else "arm64-v8a";
}

/// Resolve the Android package name from `cfg`, defaulting to
/// `com.labelle.<project>` when the project doesn't set one. Caller
/// owns the returned slice.
fn resolvePackageName(allocator: std.mem.Allocator, cfg: gen.ProjectConfig) ![]const u8 {
    const android_cfg = cfg.android orelse gen.AndroidConfig{};
    if (android_cfg.package_name.len > 0) return allocator.dupe(u8, android_cfg.package_name);
    return defaultPackageName(allocator, cfg.name);
}

/// Build APK from staging directory using Android SDK tools.
fn buildApk(allocator: std.mem.Allocator, staging_dir: []const u8, apk_path: []const u8, android_cfg: gen.AndroidConfig, signing: SigningConfig) !void {
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

    // Package with aapt.
    // Pass -A for assets and -M for the manifest but do NOT pass the full
    // staging_dir as a positional argument — aapt would scan it, find another
    // AndroidManifest.xml, and report "Duplicate file".
    std.debug.print("labelle: packaging APK...\n", .{});
    const assets_dir = try std.fs.path.join(allocator, &.{ staging_dir, "assets" });
    defer allocator.free(assets_dir);
    {
        const aapt_args: []const []const u8 = blk: {
            const base = &[_][]const u8{ aapt, "package", "-f", "-M", manifest_path, "-I", android_jar, "-F", unsigned_apk };
            // Only pass -A if the assets directory actually exists.
            if (std.fs.cwd().access(assets_dir, .{})) |_| {
                break :blk try std.mem.concat(allocator, []const u8, &.{ base, &.{ "-A", assets_dir } });
            } else |_| {
                break :blk try allocator.dupe([]const u8, base);
            }
        };
        defer allocator.free(aapt_args);
        const result = util.runCmd(allocator, aapt_args) catch |err| {
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

    // Add native libs to the APK with zip (aapt does not handle .so files).
    // Run zip from inside staging_dir so the archive path is lib/<abi>/libgame.so.
    // Resolve both paths to absolute so they survive the CWD change.
    {
        const staging_abs = try std.fs.cwd().realpathAlloc(allocator, staging_dir);
        defer allocator.free(staging_abs);
        const unsigned_abs = try std.fs.cwd().realpathAlloc(allocator, unsigned_apk);
        defer allocator.free(unsigned_abs);

        var child = std.process.Child.init(&.{ "zip", "-r", unsigned_abs, "lib" }, allocator);
        child.cwd = staging_abs;
        child.stdin_behavior = .Close;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        const term = try child.wait();
        switch (term) {
            .Exited => |code| if (code != 0) {
                std.debug.print("labelle: zip native lib failed (exit {d})\n", .{code});
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
        var args: std.ArrayList([]const u8) = .{};
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

/// Build the shared library and package the APK in one go. Returns the
/// caller-owned APK path on disk. Shared by the `android build` entry
/// point and `android/deploy.cmdDeploy` (#141) — the build half of
/// the deploy command is identical to a regular build.
pub fn buildAndPackage(
    allocator: std.mem.Allocator,
    target_dir: []const u8,
    cfg: gen.ProjectConfig,
    release_mode: ReleaseMode,
    all_abis: bool,
    emulator: bool,
    signing: SigningConfig,
) ![]const u8 {
    if (all_abis) {
        // Arena contains every intermediate path string and the
        // StagedAbi slice returned by buildAllAbis — they all live
        // for the duration of the package step and get released
        // together when the arena drops.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const abis = try buildAllAbis(arena.allocator(), target_dir, release_mode);
        return packageApkWithAbis(allocator, target_dir, cfg, abis, signing);
    } else {
        try androidBuild(allocator, target_dir, emulator, release_mode);
        return packageApk(allocator, target_dir, cfg, emulator, signing);
    }
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

pub fn printHelp() void {
    std.debug.print(
        \\
        \\Usage: labelle android <command> [options]
        \\
        \\Commands:
        \\  build      Build for Android device (arm64)
        \\  run        Build and deploy to device/emulator
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
