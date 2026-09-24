/// `labelle android run` plumbing — package an APK, push it with
/// `adb install -r`, and launch the NativeActivity. Built on top of
/// `android/package.zig` for the packaging half.
const std = @import("std");
const builtin = @import("builtin");
const project_config = @import("../project_config.zig");
const util = @import("../util.zig");
const android = @import("../android.zig");
const package = @import("package.zig");
const config = @import("../config.zig");
const runner = @import("../runner.zig");

const SigningConfig = android.SigningConfig;
const StagedAbi = android.StagedAbi;
const EnvKV = runner.EnvKV;

/// Package APK and deploy to device/emulator via ADB. Single-arch
/// entry point — picks the ABI from `emulator` + host arch, then
/// delegates to `deployToDeviceWithAbis`. `launch_extras` are handed to the
/// app as intent string extras (see `amStartArgs`).
pub fn deployToDevice(allocator: std.mem.Allocator, project_dir: []const u8, target_dir: []const u8, cfg: project_config.ProjectConfig, emulator: bool, signing: SigningConfig, opts: package.PackageOptions, launch_extras: []const EnvKV) !void {
    const abi_dir = package.hostAbiDir(emulator);
    const so_path = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "lib", "libgame.so" });
    defer allocator.free(so_path);

    const abis = [_]StagedAbi{.{ .abi_dir = abi_dir, .so_path = so_path }};
    try deployToDeviceWithAbis(allocator, project_dir, target_dir, cfg, abis[0..], signing, opts, launch_extras);
}

/// Shared staging / packaging / install / launch pipeline used by
/// both the single-arch and `--all-abis` run paths. Stages every
/// entry in `abis` into `apk-staging/lib/<abi_dir>/libgame.so`,
/// signs an APK via `packageApkWithAbis`, then pushes it to the
/// connected device with ADB and launches the NativeActivity.
pub fn deployToDeviceWithAbis(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    target_dir: []const u8,
    cfg: project_config.ProjectConfig,
    abis: []const StagedAbi,
    signing: SigningConfig,
    opts: package.PackageOptions,
    launch_extras: []const EnvKV,
) !void {
    const apk_path = try package.packageApkWithAbis(allocator, project_dir, target_dir, cfg, abis, signing, opts);
    defer allocator.free(apk_path);

    const package_name = try package.resolvePackageName(allocator, cfg);
    defer allocator.free(package_name);

    try installAndLaunch(allocator, apk_path, package_name, launch_extras);
}

/// Push a previously-built APK to the connected device via `adb
/// install -r` and launch the NativeActivity. Split out of
/// `deployToDeviceWithAbis` so the `build` subcommand and CI
/// pipelines can use the packaging half without touching ADB.
fn installAndLaunch(allocator: std.mem.Allocator, apk_path: []const u8, package_name: []const u8, launch_extras: []const EnvKV) !void {
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

    var argv_arena = std.heap.ArenaAllocator.init(allocator);
    defer argv_arena.deinit();
    const shell_args = try amStartArgs(argv_arena.allocator(), activity, launch_extras);
    var launch_argv: std.ArrayList([]const u8) = .empty;
    defer launch_argv.deinit(allocator);
    try launch_argv.append(allocator, adb);
    try launch_argv.appendSlice(allocator, shell_args);

    std.debug.print("labelle: launching...\n", .{});
    for (launch_extras) |kv| {
        std.debug.print("labelle: intent extra {s}={s}\n", .{ kv.key, kv.value });
    }
    const launch_result = util.runCmd(allocator, launch_argv.items) catch |err| {
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

/// The `adb` arguments that launch the NativeActivity:
/// `shell am start -S -n <activity> [--es <key> <value>]...`, one string extra
/// per entry in `extras`, keyed by the `LABELLE_*` env-var name (cli#397).
/// The Android runtime turns the extras back into env vars before the game
/// starts (labelle-bgfx#139, labelle-sokol#25); a runtime without that
/// support just ignores them. No extras → the bare launch, so a previous
/// run's options can never leak into this one.
///
/// `-S` force-stops the app first, extras or not: the NativeActivity never
/// reads a new intent, so a plain `am start` on a running app only brings it
/// to the front and drops the extras (labelle-bgfx#140) — and a stale
/// running app would also mask a freshly installed build.
///
/// `adb shell` joins its argv with spaces and hands the result to the
/// device's `sh`, so every value is single-quoted (`shellQuote`) — a scene
/// name with spaces or `;`/`$(...)` stays one literal argument to `am`.
/// Keys are fixed `LABELLE_*` identifiers and need no quoting. Everything is
/// allocated in `arena`.
pub fn amStartArgs(arena: std.mem.Allocator, activity: []const u8, extras: []const EnvKV) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, &.{ "shell", "am", "start", "-S", "-n", activity });
    for (extras) |kv| {
        try args.appendSlice(arena, &.{ "--es", kv.key, try shellQuote(arena, kv.value) });
    }
    return args.items;
}

/// POSIX-`sh` single-quote `value`: wrap it in `'...'` and spell each
/// embedded `'` as `'\''`. Nothing is special inside single quotes, so the
/// remote shell yields `value` byte-for-byte.
pub fn shellQuote(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (value) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

/// Find adb in ANDROID_HOME/platform-tools/ or PATH.
fn findAdb(allocator: std.mem.Allocator) ![]u8 {
    const is_windows = builtin.target.os.tag == .windows;
    // On Windows the binary is `adb.exe`; elsewhere it's bare `adb`.
    // Probe the Windows name first, then the bare name, so a POSIX-named
    // checkout on Windows (or vice versa) still resolves.
    const adb_names: []const []const u8 = if (is_windows)
        &.{ "adb.exe", "adb" }
    else
        &.{"adb"};

    // Try ANDROID_HOME first
    if (config.globalEnviron().getAlloc(allocator, "ANDROID_HOME") catch null) |home| {
        defer allocator.free(home);
        for (adb_names) |name| {
            const adb_path = try std.fs.path.join(allocator, &.{ home, "platform-tools", name });
            if (std.Io.Dir.cwd().access(config.globalIo(), adb_path, .{})) |_| {
                return adb_path;
            } else |_| {
                allocator.free(adb_path);
            }
        }
    }
    // Fall back to PATH. Windows uses `where`, POSIX uses `which`.
    const locator = if (is_windows) "where" else "which";
    const result = util.runCmd(allocator, &.{ locator, "adb" }) catch {
        std.debug.print("labelle: adb not found. Set ANDROID_HOME or add adb to PATH.\n", .{});
        return error.AdbNotFound;
    };
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    if (result.term == .exited and result.term.exited == 0 and result.stdout.len > 0) {
        // `where` can print several matches (one per line); take the
        // first. `which` prints a single path. Trim CR/LF/space either way.
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        const first = lines.next() orelse result.stdout;
        const path = std.mem.trim(u8, first, &std.ascii.whitespace);
        if (path.len > 0) return allocator.dupe(u8, path);
    }
    std.debug.print("labelle: adb not found. Set ANDROID_HOME or add adb to PATH.\n", .{});
    return error.AdbNotFound;
}

// ── amStartArgs / shellQuote (cli#397) ─────────────────────────────

/// `appendRunOptionEnv` → `amStartArgs`, the same path `labelle run
/// --platform=android` takes. Returns the args after `adb`.
fn launchArgsFor(arena: std.mem.Allocator, opts: runner.RunOptionEnv, sec_buf: *[32]u8) ![]const []const u8 {
    var extras: std.ArrayList(EnvKV) = .empty;
    try runner.appendRunOptionEnv(arena, &extras, opts, sec_buf);
    return amStartArgs(arena, "com.example.game/android.app.NativeActivity", extras.items);
}

fn expectArgs(expected: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try std.testing.expectEqualStrings(e, g);
}

test "amStartArgs: no run options → the bare launch, no extras" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sec_buf: [32]u8 = undefined;
    const got = try launchArgsFor(arena.allocator(), .{}, &sec_buf);
    try expectArgs(&.{ "shell", "am", "start", "-S", "-n", "com.example.game/android.app.NativeActivity" }, got);
}

test "amStartArgs: --scene becomes --es LABELLE_SCENE" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sec_buf: [32]u8 = undefined;
    const got = try launchArgsFor(arena.allocator(), .{ .scene = "big_colony" }, &sec_buf);
    try expectArgs(&.{
        "shell", "am",            "start",        "-S", "-n", "com.example.game/android.app.NativeActivity",
        "--es",  "LABELLE_SCENE", "'big_colony'",
    }, got);
}

test "amStartArgs: --profile and --screenshot/--after map to their keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sec_buf: [32]u8 = undefined;
    const got = try launchArgsFor(arena.allocator(), .{
        .profile = true,
        .screenshot_path = "/sdcard/shot.png",
        .screenshot_after_ns = 2500 * std.time.ns_per_ms,
    }, &sec_buf);
    try expectArgs(&.{
        "shell", "am",                           "start",   "-S",   "-n",                      "com.example.game/android.app.NativeActivity",
        "--es",  "LABELLE_PROFILE",              "'1'",     "--es", "LABELLE_SCREENSHOT_PATH", "'/sdcard/shot.png'",
        "--es",  "LABELLE_SCREENSHOT_AFTER_SEC", "'2.500'",
    }, got);
}

test "amStartArgs: --after without --screenshot adds nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var sec_buf: [32]u8 = undefined;
    const got = try launchArgsFor(arena.allocator(), .{ .screenshot_after_ns = std.time.ns_per_s }, &sec_buf);
    try expectArgs(&.{ "shell", "am", "start", "-S", "-n", "com.example.game/android.app.NativeActivity" }, got);
}

test "shellQuote: shell-unsafe values are single-quoted" {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "big_colony", "'big_colony'" },
        .{ "my scene", "'my scene'" },
        .{ "x; reboot", "'x; reboot'" },
        .{ "$(id) `id` $HOME", "'$(id) `id` $HOME'" },
        .{ "it's", "'it'\\''s'" },
        .{ "", "''" },
    };
    for (cases) |c| {
        const got = try shellQuote(a, c[0]);
        defer a.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}

test "shellQuote: a real sh reads every quoted value back verbatim" {
    // `adb shell` joins argv with spaces and runs it through the device's
    // `sh`; reproduce that join against the host's POSIX sh. Each value must
    // come back as exactly ONE argument, byte-for-byte, and nothing in it may
    // execute.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const values = [_][]const u8{ "my scene", "x; echo INJECTED", "$(echo INJECTED)", "`echo INJECTED`", "it's \"q\"", "a\\b|c&d>e" };
    for (values) |v| {
        const quoted = try shellQuote(a, v);
        defer a.free(quoted);
        // `printf '[%s]'` brackets each argument, so a value that split into
        // several arguments would print several brackets.
        const script = try std.fmt.allocPrint(a, "printf '[%s]' {s}", .{quoted});
        defer a.free(script);
        const result = try util.runCmd(a, &.{ "/bin/sh", "-c", script });
        defer a.free(result.stdout);
        defer a.free(result.stderr);
        try std.testing.expect(result.term == .exited and result.term.exited == 0);
        const want = try std.fmt.allocPrint(a, "[{s}]", .{v});
        defer a.free(want);
        try std.testing.expectEqualStrings(want, result.stdout);
    }
}
