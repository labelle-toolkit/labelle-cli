/// Android `zig build` orchestration — single-arch and fat-APK
/// (`--all-abis`) paths, plus the `buildAndPackage` helper that
/// both `android build` and `android deploy` use.
const std = @import("std");
const gen = @import("generator");
const runner = @import("../runner.zig");
const android = @import("../android.zig");
const package = @import("package.zig");
const config = @import("../config.zig");

const ReleaseMode = android.ReleaseMode;
const SigningConfig = android.SigningConfig;
const StagedAbi = android.StagedAbi;
const AbiArch = android.AbiArch;

/// The two arches `--all-abis` produces, in the order they're built.
/// arm64 first so the faster device build runs before the slower
/// x86_64 cross-build.
const all_abi_archs = [_]AbiArch{ .arm64, .x86_64 };

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
pub fn buildAllAbis(allocator: std.mem.Allocator, target_dir: []const u8, release_mode: ReleaseMode) ![]const StagedAbi {
    const stash_root = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "android-multi" });
    defer allocator.free(stash_root);
    // Wipe any stale per-arch binaries from a previous `--all-abis`
    // run — we want each invocation to start from a clean slate so
    // aborted builds don't leave half-a-fat-APK lying around. Missing
    // is fine; permission errors will surface on makePath below.
    std.Io.Dir.cwd().deleteTree(config.globalIo(), stash_root) catch {};
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), stash_root);

    var staged: std.ArrayList(StagedAbi) = .empty;
    errdefer {
        for (staged.items) |item| allocator.free(item.so_path);
        staged.deinit(allocator);
    }

    for (all_abi_archs) |abi| {
        try androidBuildArch(allocator, target_dir, abi, release_mode);

        const src = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "lib", "libgame.so" });
        defer allocator.free(src);
        std.Io.Dir.cwd().access(config.globalIo(), src, .{}) catch {
            std.debug.print("labelle: build for {s} did not produce {s}\n", .{ abi.optionValue(), src });
            return error.BinaryNotFound;
        };

        const dst_dir = try std.fs.path.join(allocator, &.{ stash_root, abi.libDir() });
        defer allocator.free(dst_dir);
        try std.Io.Dir.cwd().createDirPath(config.globalIo(), dst_dir);

        const dst = try std.fs.path.join(allocator, &.{ dst_dir, "libgame.so" });
        errdefer allocator.free(dst);
        try std.Io.Dir.cwd().copyFile(src, std.Io.Dir.cwd(), dst, config.globalIo(), .{});

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

    var zig_args: std.ArrayList([]const u8) = .empty;
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
        .exited => |code| if (code != 0) {
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
pub fn androidBuild(allocator: std.mem.Allocator, target_dir: []const u8, emulator: bool, release_mode: ReleaseMode) !void {
    const mode_label = switch (release_mode) {
        .debug => "",
        .fast => " [ReleaseFast]",
        .small => " [ReleaseSmall]",
    };
    std.debug.print("labelle: building for Android{s}{s}...\n", .{
        if (emulator) " (emulator)" else "",
        mode_label,
    });

    var zig_args: std.ArrayList([]const u8) = .empty;
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
        .exited => |code| if (code != 0) {
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

/// Build the shared library and package the APK in one go. Returns
/// the caller-owned APK path on disk. Shared by `android build` and
/// `android/deploy.cmdDeploy` (#141) — the build half of deploy is
/// identical to a regular build.
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
        return package.packageApkWithAbis(allocator, target_dir, cfg, abis, signing);
    } else {
        try androidBuild(allocator, target_dir, emulator, release_mode);
        return package.packageApk(allocator, target_dir, cfg, emulator, signing);
    }
}
