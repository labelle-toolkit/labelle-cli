//! Argument parsing for the labelle CLI, extracted from cli.zig so
//! neither file exceeds ~1000 lines. Holds the Command enum, the
//! ParsedArgs/BundleArgs result structs, and the
//! parse*/collect*/append* helpers. Behavior is unchanged from when
//! these lived in cli.zig. Unit tests live in the sibling
//! args_tests.zig, surfaced to the runner via re-exports in cli.zig.
const std = @import("std");
const builtin = @import("builtin");
const project_config = @import("project_config.zig");
const util = @import("util.zig");
const config = @import("config.zig");
const progress = @import("progress.zig");
const zig_toolchain = @import("zig_toolchain.zig");
const bundle = @import("bundle.zig");
const contract = @import("provider_contract.zig");

pub const Command = enum { generate, build, run, init_cmd, add_cmd, install_cmd, upgrade_cmd, update_cmd, clean_cmd, help_cmd, version, targets, assembler_cmd, test_cmd, pack_cmd, astc_cmd, audit_cmd, migrate_cmd, doctor_cmd, check_cmd, plugins_cmd, toolchain_cmd, status_cmd, bundle_cmd };

const SceneResult = enum { not_scene, parsed, needs_next, err };

/// Parse a --scene flag from the current argument string.
/// Returns .parsed with the value set if --scene=<value> was found,
/// .needs_next if bare --scene was found (caller must provide next arg),
/// .not_scene if the arg is unrelated, or .err if the value is empty.
pub fn parseSceneArg(arg: []const u8) SceneResult {
    if (std.mem.startsWith(u8, arg, "--scene=")) {
        const val = arg["--scene=".len..];
        if (val.len == 0) return .err;
        return .parsed;
    } else if (std.mem.eql(u8, arg, "--scene")) {
        return .needs_next;
    }
    return .not_scene;
}

/// Extract the scene value from a --scene=<value> argument.
pub fn sceneArgValue(arg: []const u8) []const u8 {
    return arg["--scene=".len..];
}

/// Parse --scene=<name> or --scene <name> from args, consuming the iterator as needed.
/// `args` is `anytype` so tests can pass a `std.process.ArgIteratorGeneral`
/// over a fixed string instead of the platform `ArgIterator`.
pub fn parseSceneFlag(
    arg: []const u8,
    args: anytype,
    scene_override: *?[]const u8,
    cmd_name: []const u8,
) SceneResult {
    switch (parseValueFlag(arg, args, "scene", "--scene main_menu", cmd_name) orelse return .err) {
        .value => |val| {
            scene_override.* = val;
            return .parsed;
        },
        .skip => return .not_scene,
    }
}

const ParseError = error{TooManyArguments};

pub const ParsedArgs = struct {
    command: Command,
    project_dir: []const u8 = ".",
    // Sized for the longest realistic built-in subcommand invocation with
    // headroom; overflow is an error, never silent truncation (PR #171
    // review). Provider commands forward their argv directly and never
    // go through this buffer.
    extra_args: [16][]const u8 = undefined,
    extra_count: usize = 0,
    timeout_ns: ?u64 = null,
    /// `timeout_ns` is the headless default (cli#485), not a `--timeout`
    /// the user gave: the launch announces it, and says so when it fires.
    timeout_defaulted: bool = false,
    scene_override: ?[]const u8 = null,
    /// The requested target name (`--platform=<t>`, or the legacy platform
    /// subcommands' fixed value), resolved by the pipeline against the core
    /// target and the pinned providers' declared targets — see
    /// `provider_targets.zig`. A string: the CLI has no list of targets.
    platform_override: ?[]const u8 = null,
    optimize_override: ?[]const u8 = null,
    docker: bool = false,
    docker_target: ?[]const u8 = null,
    bake: bool = false,
    /// `labelle build --linux-desktop` (cli#359): write the freedesktop
    /// `.desktop` entry + 256px PNG beside `zig-out/bin` after a desktop
    /// build. Automatic on a Linux host; this flag forces it elsewhere.
    linux_desktop: bool = false,
    /// `labelle run --watch` (RFC cli#466 A2): after the initial build,
    /// keep the target's watch-capable run replacement running and rebuild
    /// + publish on every source change.
    run_watch: bool = false,
    // labelle-cli#227 — out-of-band screenshot capture. `--screenshot`
    // takes a destination path (the backend picks the format from the
    // extension); `--after` is an optional delay (parsed via
    // `parseDuration`, default 0 = fire on the first frame). Wired
    // through to the spawned game via `LABELLE_SCREENSHOT_PATH` +
    // `LABELLE_SCREENSHOT_AFTER_SEC` env vars so the assembler
    // templates stay argv-agnostic.
    screenshot_path: ?[]const u8 = null,
    screenshot_after_ns: ?u64 = null,
    // Headless perf / CI knobs. Wired through to the spawned game via
    // `LABELLE_HEADLESS` / `LABELLE_HEADLESS_UNCAPPED` /
    // `LABELLE_HEADLESS_TICKS` env vars (the desktop backends that support
    // headless runs read them). `--uncapped` and `--ticks` both imply `--headless`.
    //   - headless          windowless run (no GUI window)
    //   - headless_uncapped  drop the ~16ms/frame sleep (run flat-out)
    //   - headless_ticks     exit cleanly after N frames (null = run forever)
    headless: bool = false,
    headless_uncapped: bool = false,
    headless_ticks: ?u64 = null,
    // `--profile` surfaces as the `LABELLE_PROFILE=1` env var, which the
    // engine's built-in per-script/per-plugin frame profiler reads to
    // enable recording (it logs a worst-first ranking via
    // `std.log.scoped(.profiler)`). Independent of `--headless` — you can
    // profile a windowed run too.
    profile: bool = false,
    // `--progress=<mode>` (cli#284): how build/run progress is surfaced —
    // `human` (default; spinner during compile/link on TTY stderr, plus
    // slow "still working" heartbeat lines during resolve/generate on
    // stderr whether piped or not), `json`
    // (NDJSON records on stdout for studio/CI), or `off`. The live status
    // file `.labelle/<target>/.build-progress.json` is written in every
    // mode (that's what `labelle status` reads).
    progress_mode: progress.Mode = .human,
    // `labelle bundle --output <dir>` (cli#359): where the macOS `.app`
    // lands. `null` = the target dir's `zig-out/bundle/desktop/`. A
    // relative path anchors to the project dir; see
    // `bundle.resolveOutputDir`.
    bundle_output: ?[]const u8 = null,
    /// `--allow-older-cli` (#353): downgrade the stale-CLI lock gate from a
    /// hard error to a warning for THIS invocation. Set by the
    /// `generate`/`build`/`run` parsers; `labelle astc` carries its own copy
    /// (it is dispatched before the pipeline). Every other command keeps the
    /// `LABELLE_ALLOW_OLDER_CLI=1` env form.
    allow_older_cli: bool = false,
    // `labelle bundle --build-number <n>` (cli#363): pins `CFBundleVersion`.
    // Already validated by the parser; `null` = derived from `.version` —
    // see `bundle.resolveBuildVersion`.
    bundle_build_number: ?[]const u8 = null,
};

/// Parsed `bundle` flags (cli#359). Returned by `parseBundleArgs`; `null`
/// signals a parse error (the helper has already printed a message).
pub const BundleArgs = struct {
    dir: []const u8 = ".",
    optimize: ?[]const u8 = null,
    output: ?[]const u8 = null,
    build_number: ?[]const u8 = null,
    progress_mode: progress.Mode = .human,
    /// `--platform=<t>`: the target to bundle (RFC #406 phase 3b). `null`
    /// = the project's declared platform. A provider target is bundled by
    /// that provider's `replace` hook on `bundle`.
    platform: ?[]const u8 = null,
};

/// Result of `parseValueFlag`: `.skip` = not this flag.
pub const ValueFlag = union(enum) { skip, value: []const u8 };

/// The one parser for every value-taking `--<name> <value>` /
/// `--<name>=<value>` flag (`run`, `build`, `generate`, `bundle`).
/// `.skip` when `arg` is not this flag, `.value` on a match, `null` on a
/// usage error (already printed).
///
/// In the space form the next token is the value only when it does not
/// itself look like a flag: `run --screenshot --timeout=60` used to write
/// the capture to a file named `--timeout=60` and silently drop the
/// timeout (cli#396), and `bundle --output --progress=json` the same way
/// (CodeRabbit on #362). A bare `--` is refused too, so a missing value
/// cannot swallow the passthrough separator. A value that really starts
/// with `--` can still be given in the `=` form (`--screenshot=--odd.png`).
pub fn parseValueFlag(
    arg: []const u8,
    args: anytype,
    comptime name: []const u8,
    comptime example: []const u8,
    cmd_name: []const u8,
) ?ValueFlag {
    const bare = "--" ++ name;
    const eq_form = bare ++ "=";
    if (std.mem.startsWith(u8, arg, eq_form)) {
        const val = arg[eq_form.len..];
        if (val.len == 0) {
            std.debug.print("labelle {s}: {s} requires a value (e.g. {s})\n", .{ cmd_name, bare, example });
            return null;
        }
        return .{ .value = val };
    }
    if (!std.mem.eql(u8, arg, bare)) return .skip;
    const next = args.next();
    switch (classifySeparateValue(next)) {
        .value => return .{ .value = next.? },
        .missing => std.debug.print("labelle {s}: {s} requires a value (e.g. {s})\n", .{ cmd_name, bare, example }),
        .empty => std.debug.print("labelle {s}: {s} requires a non-empty value (e.g. {s})\n", .{ cmd_name, bare, example }),
        .flag => std.debug.print("labelle {s}: {s} requires a value, but the next argument '{s}' is a flag (e.g. {s}; a value that starts with `--` needs the `{s}<value>` form)\n", .{ cmd_name, bare, next.?, example, eq_form }),
    }
    return null;
}

/// What the token after a bare `--<name>` is to `parseValueFlag`: the
/// flag's value, or why it is not. `.flag` = it starts with `--`, so it
/// is the next flag or the `--` passthrough separator (cli#396).
pub const SeparateValue = enum { value, missing, empty, flag };

pub fn classifySeparateValue(next: ?[]const u8) SeparateValue {
    const val = next orelse return .missing;
    if (val.len == 0) return .empty;
    if (std.mem.startsWith(u8, val, "--")) return .flag;
    return .value;
}

/// Parse the flags of `labelle bundle [dir] [--optimize=<mode>]
/// [--output <dir>] [--build-number <n>] [--platform=<t>] [--progress=<m>]`.
/// Deliberately NARROWER than `build`'s parser: no `--docker` (the bundle
/// wraps a host exe; a container-built one may not even be a Mach-O), no
/// `--scene` (that is a run-time env var, and `bundle` does not run the
/// game). `--platform=<t>` selects the target to bundle (RFC #406 phase
/// 3b): the core `desktop` bundle, or a provider target whose provider
/// replaces the `bundle` step. `--zig` is accepted like everywhere else so
/// a pinned toolchain still works. `args` is `anytype` so tests can drive
/// it with an in-memory `Args.IteratorGeneral`, mirroring
/// `parseRunArgs`.
pub fn parseBundleArgs(args: anytype) ?BundleArgs {
    var result = BundleArgs{};
    var dir_set = false;

    while (args.next()) |arg| {
        if (parseOptimizeFlag(arg, &result.optimize, "bundle")) |consumed| {
            if (consumed) continue;
        } else return null;
        if (parseProgressFlag(arg, &result.progress_mode, "bundle")) |consumed| {
            if (consumed) continue;
        } else return null;
        if (parseToolchainFlag(arg, args, "bundle")) |consumed| {
            if (consumed) continue;
        } else return null;
        switch (parseValueFlag(arg, args, "platform", "--platform=<target>", "bundle") orelse return null) {
            .value => |v| {
                result.platform = parseTargetValue(v) orelse {
                    printInvalidTarget("bundle", v);
                    return null;
                };
                continue;
            },
            .skip => {},
        }
        switch (parseValueFlag(arg, args, "output", "--output ./dist", "bundle") orelse return null) {
            .value => |v| {
                result.output = v;
                continue;
            },
            .skip => {},
        }
        switch (parseValueFlag(arg, args, "build-number", "--build-number 42", "bundle") orelse return null) {
            .value => |v| {
                // Validated HERE, before the (minutes-long) build, not when
                // the plist is rendered after it (cli#363). Same words as
                // the re-check in `bundle.resolveBuildVersion`.
                bundle.validateBuildNumber(v) catch |err| {
                    bundle.printInvalidBuildNumber("--build-number", v, err);
                    return null;
                };
                result.build_number = v;
                continue;
            },
            .skip => {},
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("labelle bundle: unknown flag '{s}'\n", .{arg});
            return null;
        } else {
            if (dir_set) {
                std.debug.print("labelle bundle: unexpected argument '{s}'\n", .{arg});
                return null;
            }
            result.dir = arg;
            dir_set = true;
        }
    }
    return result;
}

/// A `--platform=<value>` target name: `val` itself when it is
/// identifier-shaped (the contract's `[a-z][a-z0-9_-]*`), else null. Shape
/// only — whether a target EXISTS is decided by the pipeline against the
/// core target and the pinned providers (`provider_targets.resolve`), so
/// the parser holds no list of targets.
pub fn parseTargetValue(val: []const u8) ?[]const u8 {
    return if (contract.targetName(val)) val else null;
}

/// The one diagnostic for a malformed `--platform` value, shared by every
/// parser that accepts the flag. A Windows reserved device name is
/// identifier-shaped, so it gets its own reason: the target names a
/// directory (`zig-out/bundle/<t>/`) that Windows cannot create.
pub fn printInvalidTarget(cmd_name: []const u8, val: []const u8) void {
    if (contract.identifier(val) and contract.windowsReservedDeviceName(val)) {
        std.debug.print("labelle {s}: invalid target '{s}' (a Windows reserved device name cannot name a target; run 'labelle targets')\n", .{ cmd_name, val });
        return;
    }
    std.debug.print("labelle {s}: invalid target '{s}' (targets are lowercase identifiers; run 'labelle targets')\n", .{ cmd_name, val });
}

/// Try to parse --platform=<value> from an argument. Returns true if consumed.
fn parsePlatformFlag(arg: []const u8, platform: *?[]const u8, cmd_name: []const u8) ?bool {
    if (!std.mem.startsWith(u8, arg, "--platform=")) return false;
    const val = arg["--platform=".len..];
    if (val.len == 0) {
        std.debug.print("labelle {s}: --platform requires a value (e.g. --platform=desktop)\n", .{cmd_name});
        return null;
    }
    platform.* = parseTargetValue(val) orelse {
        printInvalidTarget(cmd_name, val);
        return null;
    };
    return true;
}

/// Parse the `--zig <path>` / `--zig=<path>` escape hatch (cli#279, folding
/// in the superseded cli#203 option 2). Records the override in
/// `zig_toolchain` so `resolveZig` returns it directly. `LABELLE_ZIG` still
/// wins (checked first in `resolveZig`). Returns true when consumed, false
/// when `arg` is not `--zig`, and null on a missing value. The stored slice
/// borrows argv, which lives for the whole `main()` call.
fn parseZigFlag(arg: []const u8, args: anytype, cmd_name: []const u8) ?bool {
    switch (parseValueFlag(arg, args, "zig", "--zig /opt/zig/zig", cmd_name) orelse return null) {
        .value => |val| {
            zig_toolchain.setFlagOverride(val);
            return true;
        },
        .skip => return false,
    }
}

/// `--allow-older-cli` (#353): the escape hatch of the stale-CLI lock gate
/// (`lockfile.enforceCliNotStale`). A bare boolean flag — true = consumed.
/// Deliberately valueless: `LABELLE_ALLOW_OLDER_CLI=1` is the env form for
/// CI, this is the interactive one.
pub fn parseAllowOlderCliFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--allow-older-cli");
}

/// Try the managed-toolchain path override (`--zig`) for one arg. true =
/// consumed, false = not the flag, null = the flag with a bad value.
fn parseToolchainFlag(arg: []const u8, args: anytype, cmd_name: []const u8) ?bool {
    return parseZigFlag(arg, args, cmd_name);
}

/// Try to parse `--progress=<mode>` (cli#284). Returns true if consumed,
/// false if `arg` is not a `--progress` flag, and null on an invalid value.
fn parseProgressFlag(arg: []const u8, mode: *progress.Mode, cmd_name: []const u8) ?bool {
    if (!std.mem.startsWith(u8, arg, "--progress=")) return false;
    const val = arg["--progress=".len..];
    if (std.meta.stringToEnum(progress.Mode, val)) |m| {
        mode.* = m;
        return true;
    }
    std.debug.print("labelle {s}: unknown progress mode '{s}' (expected: human, json, off)\n", .{ cmd_name, val });
    return null;
}

pub const valid_optimize_modes = [_][]const u8{ "Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall" };

/// Try to parse --optimize=<value> from an argument. Returns true if consumed,
/// false if this is not an --optimize= flag, and null on error.
pub fn parseOptimizeFlag(arg: []const u8, optimize: *?[]const u8, cmd_name: []const u8) ?bool {
    if (!std.mem.startsWith(u8, arg, "--optimize=")) return false;
    const val = arg["--optimize=".len..];
    if (val.len == 0) {
        std.debug.print("labelle {s}: --optimize requires a value (e.g. --optimize=ReleaseSafe)\n", .{cmd_name});
        return null;
    }
    for (valid_optimize_modes) |mode| {
        if (std.mem.eql(u8, val, mode)) {
            optimize.* = val;
            return true;
        }
    }
    const expected = comptime blk: {
        var result: []const u8 = "";
        for (valid_optimize_modes, 0..) |mode, i| {
            if (i > 0) result = result ++ ", ";
            result = result ++ mode;
        }
        break :blk result;
    };
    std.debug.print("labelle {s}: unknown optimize mode '{s}' (expected: {s})\n", .{ cmd_name, val, expected });
    return null;
}

/// A `--docker` build for macOS is refused (cli#471 X3, D6): the container
/// build cannot link macOS without Apple's frameworks, and the core no longer
/// fetches a third-party copy of them. Linux and Windows cross builds stay.
/// The effective target is the explicit `--target`, else the host's own
/// (`docker.runBuild` falls back to it), so a bare `--docker` on a Mac is
/// refused too; an OS version suffix (`aarch64-macos.13.0`) does not hide
/// it. Without `--docker`, `--target` is a no-op the pipeline warns about,
/// so nothing is refused here. Only commands that reach the container build
/// ask (`build`, `run`): `generate --docker` generates on the host.
fn dockerBuildRefused(docker_build: bool, target: ?[]const u8, host_os: std.Target.Os.Tag) bool {
    if (!docker_build) return false;
    const t = target orelse return host_os == .macos;
    var parts = std.mem.splitScalar(u8, t, '-');
    _ = parts.next() orelse return false; // arch
    const os_query = parts.next() orelse return false;
    const os = os_query[0 .. std.mem.indexOfScalar(u8, os_query, '.') orelse os_query.len];
    return std.mem.eql(u8, os, "macos");
}

fn refuseDockerBuild(cmd_name: []const u8, docker_build: bool, target: ?[]const u8) bool {
    if (!dockerBuildRefused(docker_build, target, builtin.os.tag)) return false;
    std.debug.print("labelle {s}: --docker does not cross-compile for macOS (target {s}); pick a Linux or Windows --target, or build natively on a Mac\n", .{ cmd_name, target orelse "defaults to this Mac" });
    return true;
}

test "dockerBuildRefused: the effective docker target, macOS only" {
    try std.testing.expect(dockerBuildRefused(true, "aarch64-macos", .linux));
    try std.testing.expect(dockerBuildRefused(true, "x86_64-macos-none", .linux));
    try std.testing.expect(!dockerBuildRefused(true, "x86_64-windows", .macos));
    try std.testing.expect(!dockerBuildRefused(true, "x86_64-linux-gnu", .macos));
    try std.testing.expect(!dockerBuildRefused(true, "x86_64-linux-macosish", .linux));
    try std.testing.expect(dockerBuildRefused(true, "aarch64-macos.13.0", .linux));
    try std.testing.expect(dockerBuildRefused(true, "x86_64-macos.12.0...14.0-none", .linux));
    // No --target: the host's own target.
    try std.testing.expect(dockerBuildRefused(true, null, .macos));
    try std.testing.expect(!dockerBuildRefused(true, null, .linux));
    // Without --docker nothing is refused.
    try std.testing.expect(!dockerBuildRefused(false, "aarch64-macos", .linux));
    try std.testing.expect(!dockerBuildRefused(false, null, .macos));
}

/// Parse [dir], --scene, --platform, --optimize, --progress, --docker, --target
/// and (build only) --linux-desktop flags for generate/build commands.
/// `args` is `anytype` so tests can drive it with an in-memory iterator.
pub fn parseDirAndScene(args: anytype, cmd_name: []const u8) ?struct { dir: []const u8, scene: ?[]const u8, platform: ?[]const u8, optimize: ?[]const u8, docker_build: bool, docker_target: ?[]const u8, bake: bool, progress_mode: progress.Mode, linux_desktop: bool, allow_older_cli: bool } {
    var dir: []const u8 = ".";
    var dir_set = false;
    var scene: ?[]const u8 = null;
    var platform: ?[]const u8 = null;
    var optimize: ?[]const u8 = null;
    var docker_build = false;
    var docker_target: ?[]const u8 = null;
    var bake = false;
    var progress_mode: progress.Mode = .human;
    var linux_desktop = false;
    var allow_older_cli = false;

    while (args.next()) |arg| {
        if (parseAllowOlderCliFlag(arg)) {
            allow_older_cli = true;
            continue;
        }
        switch (parseSceneFlag(arg, args, &scene, cmd_name)) {
            .parsed => continue,
            .err => return null,
            .not_scene => {},
            .needs_next => unreachable,
        }
        if (std.mem.eql(u8, arg, "--linux-desktop")) {
            // Only `build` produces the exe the entry points at; on
            // `generate` there is nothing to describe, so refuse rather
            // than silently accept a flag that does nothing.
            if (!std.mem.eql(u8, cmd_name, "build")) {
                std.debug.print("labelle {s}: --linux-desktop only applies to `labelle build`\n", .{cmd_name});
                return null;
            }
            linux_desktop = true;
            continue;
        }
        if (parsePlatformFlag(arg, &platform, cmd_name) orelse return null) continue;
        if (parseOptimizeFlag(arg, &optimize, cmd_name) orelse return null) continue;
        if (parseProgressFlag(arg, &progress_mode, cmd_name) orelse return null) continue;
        if (std.mem.eql(u8, arg, "--docker")) {
            docker_build = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--bake")) {
            bake = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--target=")) {
            const val = arg["--target=".len..];
            if (val.len == 0) {
                std.debug.print("labelle {s}: --target requires a value (e.g. --target=x86_64-windows)\n", .{cmd_name});
                return null;
            }
            docker_target = val;
            continue;
        }
        if (parseToolchainFlag(arg, args, cmd_name)) |consumed| {
            if (consumed) continue;
        } else return null;
        if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("labelle {s}: unknown flag '{s}'\n", .{ cmd_name, arg });
            return null;
        } else {
            if (dir_set) {
                std.debug.print("labelle {s}: unexpected argument '{s}'\n", .{ cmd_name, arg });
                return null;
            }
            dir = arg;
            dir_set = true;
        }
    }
    // `generate --docker` never reaches the container build.
    if (!std.mem.eql(u8, cmd_name, "generate") and refuseDockerBuild(cmd_name, docker_build, docker_target)) return null;
    return .{ .dir = dir, .scene = scene, .platform = platform, .optimize = optimize, .docker_build = docker_build, .docker_target = docker_target, .bake = bake, .progress_mode = progress_mode, .linux_desktop = linux_desktop, .allow_older_cli = allow_older_cli };
}

/// cli#485: the run-time budget of a `labelle run --headless` given no
/// `--timeout`. Headless runs have nobody watching them, so they must not
/// run forever; `--timeout=<dur>` extends it and `--timeout=0` (or `none`)
/// turns it off.
pub const headless_default_timeout_ns: u64 = 5 * std.time.ns_per_min;

/// Test-only: a duration (`parseDuration` syntax) that replaces
/// `headless_default_timeout_ns`, so an end-to-end test can watch the
/// default fire in seconds instead of minutes. Not documented as a user
/// knob — the supported way to change the budget is `--timeout`.
pub const headless_default_timeout_env = "LABELLE_TEST_HEADLESS_DEFAULT_TIMEOUT";

/// The headless default budget: `headless_default_timeout_env` when it is
/// set to a positive duration, `headless_default_timeout_ns` otherwise.
pub fn headlessDefaultTimeoutNs() u64 {
    // `getAlloc` copies the whole environment into a map first, so it needs
    // a real allocator, not a small fixed buffer.
    const gpa = std.heap.page_allocator;
    const raw = config.globalEnviron().getAlloc(gpa, headless_default_timeout_env) catch
        return headless_default_timeout_ns;
    defer gpa.free(raw);
    const ns = util.parseDuration(raw) orelse return headless_default_timeout_ns;
    return if (ns == 0) headless_default_timeout_ns else ns;
}

/// A `--timeout` value: a `parseDuration` duration, or `none`. Returns
/// `@as(?u64, null)` wrapped for "no timeout" (`none`, or any zero
/// duration — a zero deadline would kill the game before its first frame,
/// so it means "off" instead), null for a value that does not parse.
pub fn parseTimeoutValue(val: []const u8) ??u64 {
    if (std.mem.eql(u8, val, "none")) return @as(?u64, null);
    const ns = util.parseDuration(val) orelse return null;
    return if (ns == 0) @as(?u64, null) else ns;
}

pub const RunTimeout = struct { timeout_ns: ?u64, defaulted: bool };

/// The run's effective watchdog budget: an explicit `--timeout` (including
/// its `0`/`none` opt-out) always wins; otherwise a headless run gets
/// `default_ns` and every other run keeps running until it exits.
pub fn resolveRunTimeout(explicit_ns: ?u64, timeout_given: bool, headless: bool, default_ns: u64) RunTimeout {
    if (timeout_given or !headless) return .{ .timeout_ns = explicit_ns, .defaulted = false };
    return .{ .timeout_ns = default_ns, .defaulted = true };
}

/// Parse [dir], --scene, --timeout, --platform, --optimize, --docker, and --target flags for run command (explicit or implicit).
///
/// A bare `--` token switches the parser into "passthrough" mode: every
/// subsequent token is collected verbatim into `parsed_args.extra_args`
/// without flag interpretation, so callers can forward args to the game
/// binary via `zig build run -- <extras>` (see run_cmd handler).
pub fn parseRunArgs(args: anytype, cmd_name: []const u8, allow_dir: bool, parsed_args: *ParsedArgs) ?struct { dir: []const u8, scene: ?[]const u8, timeout_ns: ?u64, platform: ?[]const u8, optimize: ?[]const u8, docker_build: bool, docker_target: ?[]const u8, bake: bool, screenshot_path: ?[]const u8, screenshot_after_ns: ?u64 } {
    var dir: []const u8 = ".";
    var dir_set = !allow_dir;
    var scene: ?[]const u8 = null;
    var timeout_ns: ?u64 = null;
    var timeout_given = false;
    var platform: ?[]const u8 = null;
    var optimize: ?[]const u8 = null;
    var docker_build = false;
    var docker_target: ?[]const u8 = null;
    var bake = false;
    var screenshot_path: ?[]const u8 = null;
    var screenshot_after_ns: ?u64 = null;
    var passthrough = false;

    while (args.next()) |arg| {
        if (passthrough) {
            appendExtraArg(parsed_args, arg) catch return null;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            passthrough = true;
            continue;
        }
        switch (parseSceneFlag(arg, args, &scene, cmd_name)) {
            .parsed => continue,
            .err => return null,
            .not_scene => {},
            .needs_next => unreachable,
        }
        if (parsePlatformFlag(arg, &platform, cmd_name)) |consumed| {
            if (consumed) continue;
        } else return null;
        if (parseOptimizeFlag(arg, &optimize, cmd_name)) |consumed| {
            if (consumed) continue;
        } else return null;
        if (parseProgressFlag(arg, &parsed_args.progress_mode, cmd_name)) |consumed| {
            if (consumed) continue;
        } else return null;
        if (std.mem.eql(u8, arg, "--docker")) {
            docker_build = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--bake")) {
            bake = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--target=")) {
            const val = arg["--target=".len..];
            if (val.len == 0) {
                std.debug.print("labelle {s}: --target requires a value (e.g. --target=x86_64-windows)\n", .{cmd_name});
                return null;
            }
            docker_target = val;
            continue;
        }
        if (std.mem.eql(u8, arg, "--watch")) {
            parsed_args.run_watch = true;
            continue;
        }
        switch (parseValueFlag(arg, args, "timeout", "--timeout 30s", cmd_name) orelse return null) {
            .value => |val| {
                timeout_given = true;
                timeout_ns = parseTimeoutValue(val) orelse {
                    std.debug.print("labelle {s}: invalid --timeout value '{s}'\n", .{ cmd_name, val });
                    std.debug.print("  expected format: --timeout=30s, --timeout 2m (--timeout=0 or --timeout=none: no timeout)\n", .{});
                    return null;
                };
                continue;
            },
            .skip => {},
        }
        switch (parseValueFlag(arg, args, "screenshot", "--screenshot /tmp/shot.png", cmd_name) orelse return null) {
            .value => |val| {
                screenshot_path = val;
                continue;
            },
            .skip => {},
        }
        switch (parseValueFlag(arg, args, "after", "--after 2s", cmd_name) orelse return null) {
            .value => |val| {
                screenshot_after_ns = util.parseDuration(val) orelse {
                    std.debug.print("labelle {s}: invalid --after value '{s}'\n", .{ cmd_name, val });
                    std.debug.print("  expected format: --after=2s, --after 500ms\n", .{});
                    return null;
                };
                continue;
            },
            .skip => {},
        }
        switch (parseValueFlag(arg, args, "ticks", "--ticks=600", cmd_name) orelse return null) {
            .value => |val| {
                const n = std.fmt.parseInt(u64, val, 10) catch 0;
                if (n == 0) {
                    std.debug.print("labelle {s}: invalid --ticks value '{s}'\n", .{ cmd_name, val });
                    std.debug.print("  expected a positive integer, e.g. --ticks=600\n", .{});
                    return null;
                }
                parsed_args.headless = true; // --ticks implies --headless
                parsed_args.headless_ticks = n;
                continue;
            },
            .skip => {},
        }
        if (parseAllowOlderCliFlag(arg)) {
            parsed_args.allow_older_cli = true;
            continue;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            parsed_args.headless = true;
            continue;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            parsed_args.profile = true;
            continue;
        } else if (std.mem.eql(u8, arg, "--uncapped")) {
            // Implies --headless (the backend only honours the uncapped
            // path when it's already in headless mode).
            parsed_args.headless = true;
            parsed_args.headless_uncapped = true;
            continue;
        } else if (parseToolchainFlag(arg, args, cmd_name)) |consumed| {
            if (consumed) continue;
            // parseToolchainFlag returned false → fall through to unknown-flag/dir.
            if (std.mem.startsWith(u8, arg, "--")) {
                std.debug.print("labelle {s}: unknown flag '{s}'\n", .{ cmd_name, arg });
                return null;
            }
            if (dir_set) {
                std.debug.print("labelle {s}: unexpected argument '{s}'\n", .{ cmd_name, arg });
                return null;
            }
            dir = arg;
            dir_set = true;
        } else return null;
    }
    // `--after` without `--screenshot` is a user mistake worth flagging
    // — the delay has no observable effect by itself. Don't fail though;
    // a warning preserves forward-compat if future flags reuse `--after`.
    if (screenshot_after_ns != null and screenshot_path == null) {
        std.debug.print("labelle {s}: warning: --after has no effect without --screenshot\n", .{cmd_name});
    }
    // A container build never reaches a watch session: the rebuilds run on
    // this host, next to the replacement.
    if (parsed_args.run_watch and docker_build) {
        std.debug.print("labelle {s}: --watch cannot be combined with --docker\n", .{cmd_name});
        return null;
    }
    // cli#485: a headless run with no `--timeout` gets the default budget,
    // through the same `timeout_ns` an explicit `--timeout` sets — so the
    // watchdog, the exit status and the run hooks' `timeout_ms` are exactly
    // the explicit flag's.
    const resolved = resolveRunTimeout(timeout_ns, timeout_given, parsed_args.headless, headlessDefaultTimeoutNs());
    timeout_ns = resolved.timeout_ns;
    parsed_args.timeout_defaulted = resolved.defaulted;
    if (refuseDockerBuild(cmd_name, docker_build, docker_target)) return null;
    return .{ .dir = dir, .scene = scene, .timeout_ns = timeout_ns, .platform = platform, .optimize = optimize, .docker_build = docker_build, .docker_target = docker_target, .bake = bake, .screenshot_path = screenshot_path, .screenshot_after_ns = screenshot_after_ns };
}

/// Collect all remaining args into extra_args buffer.
pub fn collectExtraArgs(args: *std.process.Args.Iterator, parsed_args: *ParsedArgs) ParseError!void {
    while (args.next()) |arg| {
        try appendExtraArg(parsed_args, arg);
    }
}

/// Append one token to `ParsedArgs.extra_args`, surfacing overflow as
/// an error instead of silently dropping it (which would let the
/// subcommand fall through to `project_dir`).
pub fn appendExtraArg(parsed_args: *ParsedArgs, arg: []const u8) ParseError!void {
    if (parsed_args.extra_count >= parsed_args.extra_args.len) {
        std.debug.print("labelle: too many arguments\n", .{});
        return error.TooManyArguments;
    }
    parsed_args.extra_args[parsed_args.extra_count] = arg;
    parsed_args.extra_count += 1;
}

pub fn appendRunForwardedArgs(argv: *std.ArrayList([]const u8), allocator: std.mem.Allocator, parsed_args: *const ParsedArgs) !void {
    if (parsed_args.extra_count == 0) return;
    try argv.append(allocator, "--");
    for (parsed_args.extra_args[0..parsed_args.extra_count]) |extra| {
        try argv.append(allocator, extra);
    }
}
