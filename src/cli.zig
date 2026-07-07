/// labelle-cli — reads project.labelle and generates/builds/runs the assembled game.
///
/// Usage:
///   labelle generate [dir] [--scene=name] [--optimize=MODE] — generate .labelle/ assembler files
///   labelle run [dir] [--timeout=30s] [--scene=name] [--optimize=MODE] [--progress=json] [--screenshot=<path> [--after=<dur>]] [-- <args>...] — generate + build + run; `--screenshot` captures a frame to <path> (raylib picks PNG/BMP by extension); `--` forwards trailing args to the game
///   labelle build [dir] [--scene=name] [--optimize=MODE] [--progress=json] — generate + build (no run)
///   labelle status [dir] [--json]       — print the current/last build progress (reads .labelle/<target>/.build-progress.json)
///   labelle wasm serve [dir] [--port n] [--no-build] [--no-open] — build the WASM target and serve it locally
///   labelle [dir]                       — alias for `run`
///   labelle init <name> [dir]           — scaffold a new project
///   labelle install [pkg] [ver]         — fetch packages into cache
///   labelle install assembler <ver>    — download and cache an assembler binary
///   labelle assembler list             — list cached assembler versions
///   labelle upgrade [dir] [pkg] [ver]   — bump versions in project.labelle
///   labelle update [ver]                — self-update the CLI
///   labelle clean [--dry-run]           — prune unused package versions
///   labelle test [dir] [--verbose]      — run inline `test` blocks across the project source tree
///   labelle check [dir]                 — lint packs for §6 convention violations (Packs RFC)
const std = @import("std");
const project_config = @import("cli/project_config.zig");

// Submodules
const help = @import("cli/help.zig");
const init = @import("cli/init.zig");
const add = @import("cli/add.zig");
const install = @import("cli/install.zig");
const upgrade = @import("cli/upgrade.zig");
const update = @import("cli/update.zig");
const clean = @import("cli/clean.zig");
const test_cmd_mod = @import("cli/test.zig");
const config = @import("cli/config.zig");
const compatibility = @import("cli/compatibility.zig");
const lockfile = @import("cli/lockfile.zig");
const runner = @import("cli/runner.zig");
const assembler = @import("cli/assembler.zig");
const assembler_proc = @import("cli/assembler_proc.zig");
const zig_toolchain = @import("cli/zig_toolchain.zig");
const emsdk_toolchain = @import("cli/emsdk_toolchain.zig");
const emsdk_activate = @import("cli/emsdk_activate.zig");
const bake_mod = @import("cli/bake.zig");
const docker = @import("cli/docker.zig");
const serve = @import("cli/serve.zig");
const ios = @import("cli/ios.zig");
const android = @import("cli/android.zig");
const util = @import("cli/util.zig");
const pack = @import("cli/pack.zig");
const progress = @import("cli/progress.zig");
const status_mod = @import("cli/status.zig");
const astc_cmd = @import("astc/cmd.zig");
const audit = @import("cli/audit.zig");
const migrate = @import("cli/migrate.zig");
const check = @import("cli/check.zig");
const doctor = @import("cli/doctor.zig");
const sdl_provision = @import("cli/sdl_provision.zig");

const Command = enum { generate, build, run, init_cmd, add_cmd, install_cmd, upgrade_cmd, update_cmd, clean_cmd, ios_cmd, android_cmd, wasm_cmd, help_cmd, version, targets, assembler_cmd, test_cmd, pack_cmd, astc_cmd, audit_cmd, migrate_cmd, doctor_cmd, check_cmd, toolchain_cmd, status_cmd };

const SceneResult = enum { not_scene, parsed, needs_next, err };

/// Parse a --scene flag from the current argument string.
/// Returns .parsed with the value set if --scene=<value> was found,
/// .needs_next if bare --scene was found (caller must provide next arg),
/// .not_scene if the arg is unrelated, or .err if the value is empty.
fn parseSceneArg(arg: []const u8) SceneResult {
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
fn sceneArgValue(arg: []const u8) []const u8 {
    return arg["--scene=".len..];
}

/// Parse --scene=<name> or --scene <name> from args, consuming the iterator as needed.
/// `args` is `anytype` so tests can pass a `std.process.ArgIteratorGeneral`
/// over a fixed string instead of the platform `ArgIterator`.
fn parseSceneFlag(
    arg: []const u8,
    args: anytype,
    scene_override: *?[]const u8,
    cmd_name: []const u8,
) SceneResult {
    switch (parseSceneArg(arg)) {
        .parsed => {
            scene_override.* = sceneArgValue(arg);
            return .parsed;
        },
        .needs_next => {
            if (args.next()) |val| {
                if (val.len == 0) {
                    std.debug.print("labelle {s}: --scene requires a non-empty value (e.g. --scene main_menu)\n", .{cmd_name});
                    return .err;
                }
                scene_override.* = val;
                return .parsed;
            } else {
                std.debug.print("labelle {s}: --scene requires a value (e.g. --scene main_menu)\n", .{cmd_name});
                return .err;
            }
        },
        .err => {
            std.debug.print("labelle {s}: --scene requires a non-empty value (e.g. --scene=main_menu)\n", .{cmd_name});
            return .err;
        },
        .not_scene => return .not_scene,
    }
}

const ParseError = error{TooManyArguments};

const Platform = project_config.Platform;
const Backend = project_config.Backend;

/// Resolve the backend for an `labelle android` invocation, honoring the
/// project's declared backend when it can actually target Android.
///
/// Android-capable backends are `sokol` and `bgfx` (the bgfx-on-Android
/// bring-up, cli#300-#303). A project that declares either keeps it. Any
/// other backend (`raylib`/`sdl`/`wgpu`/`null` — desktop/web only) can't
/// target Android, so we fall back to `sokol` to preserve the historical
/// behavior for projects that just say "android" without a real Android
/// backend (#252).
///
/// Pure: the caller logs when the resolved backend differs from the
/// project's, so unit tests can call this without polluting console output.
fn resolveAndroidBackend(project_backend: Backend) Backend {
    return switch (project_backend) {
        .sokol, .bgfx => project_backend,
        .raylib, .sdl, .wgpu, .null => .sokol,
    };
}

const ParsedArgs = struct {
    command: Command,
    project_dir: []const u8 = ".",
    // Sized for the longest realistic android invocation:
    //   android run --all-abis --release --keystore k --keystore-pass p
    //               --key-alias a --key-pass kp
    // That's 11 tokens — 16 gives headroom for future flags without
    // risking silent truncation (flagged by the PR #171 review).
    extra_args: [16][]const u8 = undefined,
    extra_count: usize = 0,
    timeout_ns: ?u64 = null,
    scene_override: ?[]const u8 = null,
    platform_override: ?Platform = null,
    optimize_override: ?[]const u8 = null,
    docker: bool = false,
    docker_target: ?[]const u8 = null,
    bake: bool = false,
    // `wasm serve` options. `serve_port` is also read by the wasm
    // branch of `run`; the others only apply to `wasm serve`.
    serve_port: u16 = 8080,
    serve_no_build: bool = false,
    serve_no_open: bool = false,
    // labelle-cli#227 — out-of-band screenshot capture. `--screenshot`
    // takes a destination path (raylib picks the format from the
    // extension); `--after` is an optional delay (parsed via
    // `parseDuration`, default 0 = fire on the first frame). Wired
    // through to the spawned game via `LABELLE_SCREENSHOT_PATH` +
    // `LABELLE_SCREENSHOT_AFTER_SEC` env vars so the assembler
    // templates stay argv-agnostic.
    screenshot_path: ?[]const u8 = null,
    screenshot_after_ns: ?u64 = null,
    // Headless perf / CI knobs. Wired through to the spawned game via
    // `LABELLE_HEADLESS` / `LABELLE_HEADLESS_UNCAPPED` /
    // `LABELLE_HEADLESS_TICKS` env vars (the sokol desktop backend reads
    // them). `--uncapped` and `--ticks` both imply `--headless`.
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
    // `--progress=<mode>` (cli#284): how build/run progress is surfaced on
    // the terminal — `human` (default; spinner on TTY stderr), `json`
    // (NDJSON records on stdout for studio/CI), or `off`. The live status
    // file `.labelle/<target>/.build-progress.json` is written in every
    // mode (that's what `labelle status` reads).
    progress_mode: progress.Mode = .human,
};

/// Parsed `wasm serve` flags. Returned by `parseWasmServeArgs`; `null`
/// signals a parse error (the helper has already printed a message).
const WasmServeArgs = struct {
    dir: []const u8 = ".",
    port: u16 = 8080,
    no_build: bool = false,
    no_open: bool = false,
    // `wasm serve` runs the same resolve→generate→build pipeline as
    // `labelle build`, so it carries the cli#284 progress feed too (the
    // reporter marks the pipeline `done` before the interactive serve
    // loop takes over).
    progress_mode: progress.Mode = .human,
};

/// Parse the flags of `labelle wasm serve [dir] [--port <n>]
/// [--no-build] [--no-open] [--progress=<m>]`. `args` is `anytype` so
/// tests can drive it with an in-memory `Args.IteratorGeneral`, mirroring
/// `parseRunArgs`.
fn parseWasmServeArgs(args: anytype) ?WasmServeArgs {
    var result = WasmServeArgs{};
    var dir_set = false;

    while (args.next()) |arg| {
        // Same tri-state idiom as parseRunArgs: consumed → next arg,
        // not-a-progress-flag → fall through, bad value → parse error.
        if (parseProgressFlag(arg, &result.progress_mode, "wasm serve")) |consumed| {
            if (consumed) continue;
        } else return null;
        if (std.mem.eql(u8, arg, "--no-build")) {
            result.no_build = true;
        } else if (std.mem.eql(u8, arg, "--no-open")) {
            result.no_open = true;
        } else if (std.mem.startsWith(u8, arg, "--port=") or std.mem.eql(u8, arg, "--port")) {
            const val = if (std.mem.eql(u8, arg, "--port"))
                (args.next() orelse {
                    std.debug.print("labelle wasm serve: --port requires a value (e.g. --port 3000)\n", .{});
                    return null;
                })
            else
                arg["--port=".len..];
            result.port = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("labelle wasm serve: invalid --port value '{s}' (expected 1-65535)\n", .{val});
                return null;
            };
            if (result.port == 0) {
                std.debug.print("labelle wasm serve: --port must be between 1 and 65535\n", .{});
                return null;
            }
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("labelle wasm serve: unknown flag '{s}'\n", .{arg});
            return null;
        } else {
            if (dir_set) {
                std.debug.print("labelle wasm serve: unexpected argument '{s}'\n", .{arg});
                return null;
            }
            result.dir = arg;
            dir_set = true;
        }
    }
    return result;
}

/// Parse a --platform=<value> string into a Platform enum, or null if invalid.
fn parsePlatformValue(val: []const u8) ?Platform {
    return std.meta.stringToEnum(Platform, val);
}

/// Try to parse --platform=<value> from an argument. Returns true if consumed.
fn parsePlatformFlag(arg: []const u8, platform: *?Platform, cmd_name: []const u8) ?bool {
    if (!std.mem.startsWith(u8, arg, "--platform=")) return false;
    const val = arg["--platform=".len..];
    if (val.len == 0) {
        std.debug.print("labelle {s}: --platform requires a value (e.g. --platform=wasm)\n", .{cmd_name});
        return null;
    }
    platform.* = parsePlatformValue(val);
    if (platform.* == null) {
        const expected = comptime blk: {
            const fields = @typeInfo(Platform).@"enum".fields;
            var result: []const u8 = "";
            for (fields, 0..) |f, i| {
                if (i > 0) result = result ++ ", ";
                result = result ++ f.name;
            }
            break :blk result;
        };
        std.debug.print("labelle {s}: unknown platform '{s}' (expected: {s})\n", .{ cmd_name, val, expected });
        return null;
    }
    return true;
}

/// Parse the `--zig <path>` / `--zig=<path>` escape hatch (cli#279, folding
/// in the superseded cli#203 option 2). Records the override in
/// `zig_toolchain` so `resolveZig` returns it directly. `LABELLE_ZIG` still
/// wins (checked first in `resolveZig`). Returns true when consumed, false
/// when `arg` is not `--zig`, and null on a missing value. The stored slice
/// borrows argv, which lives for the whole `main()` call.
fn parseZigFlag(arg: []const u8, args: anytype) ?bool {
    if (std.mem.startsWith(u8, arg, "--zig=")) {
        const val = arg["--zig=".len..];
        if (val.len == 0) {
            std.debug.print("labelle: --zig requires a path (e.g. --zig=/opt/zig/zig)\n", .{});
            return null;
        }
        zig_toolchain.setFlagOverride(val);
        return true;
    }
    if (std.mem.eql(u8, arg, "--zig")) {
        const val = args.next() orelse {
            std.debug.print("labelle: --zig requires a path (e.g. --zig /opt/zig/zig)\n", .{});
            return null;
        };
        if (val.len == 0) {
            std.debug.print("labelle: --zig requires a non-empty path (e.g. --zig /opt/zig/zig)\n", .{});
            return null;
        }
        zig_toolchain.setFlagOverride(val);
        return true;
    }
    return false;
}

/// Parse the `--emcc <path>` / `--emcc=<path>` escape hatch (cli#283), the
/// emsdk analog of `--zig`. Records the override in `emsdk_toolchain` so
/// `resolveEmcc` returns it directly. `LABELLE_EMSDK` still wins (checked first
/// in `resolveEmcc`). Returns true when consumed, false when `arg` is not
/// `--emcc`, and null on a missing value. The stored slice borrows argv.
fn parseEmccFlag(arg: []const u8, args: anytype) ?bool {
    if (std.mem.startsWith(u8, arg, "--emcc=")) {
        const val = arg["--emcc=".len..];
        if (val.len == 0) {
            std.debug.print("labelle: --emcc requires a path (e.g. --emcc=/opt/emsdk/upstream/emscripten/emcc)\n", .{});
            return null;
        }
        emsdk_toolchain.setFlagOverride(val);
        return true;
    }
    if (std.mem.eql(u8, arg, "--emcc")) {
        const val = args.next() orelse {
            std.debug.print("labelle: --emcc requires a path (e.g. --emcc /opt/emsdk/upstream/emscripten/emcc)\n", .{});
            return null;
        };
        if (val.len == 0) {
            std.debug.print("labelle: --emcc requires a non-empty path\n", .{});
            return null;
        }
        emsdk_toolchain.setFlagOverride(val);
        return true;
    }
    return false;
}

/// Try the managed-toolchain path overrides (`--zig`, then `--emcc`) for one
/// arg. true = consumed, false = neither flag, null = a flag with a bad value.
fn parseToolchainFlag(arg: []const u8, args: anytype) ?bool {
    const zig = parseZigFlag(arg, args) orelse return null;
    if (zig) return true;
    return parseEmccFlag(arg, args);
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

const valid_optimize_modes = [_][]const u8{ "Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall" };

/// Try to parse --optimize=<value> from an argument. Returns true if consumed,
/// false if this is not an --optimize= flag, and null on error.
fn parseOptimizeFlag(arg: []const u8, optimize: *?[]const u8, cmd_name: []const u8) ?bool {
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

/// Parse [dir], --scene, --platform, --optimize, --progress, --docker, and --target flags for generate/build commands.
fn parseDirAndScene(args: *std.process.Args.Iterator, cmd_name: []const u8) ?struct { dir: []const u8, scene: ?[]const u8, platform: ?Platform, optimize: ?[]const u8, docker_build: bool, docker_target: ?[]const u8, bake: bool, progress_mode: progress.Mode } {
    var dir: []const u8 = ".";
    var dir_set = false;
    var scene: ?[]const u8 = null;
    var platform: ?Platform = null;
    var optimize: ?[]const u8 = null;
    var docker_build = false;
    var docker_target: ?[]const u8 = null;
    var bake = false;
    var progress_mode: progress.Mode = .human;

    while (args.next()) |arg| {
        switch (parseSceneFlag(arg, args, &scene, cmd_name)) {
            .parsed => continue,
            .err => return null,
            .not_scene => {},
            .needs_next => unreachable,
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
        if (parseToolchainFlag(arg, args)) |consumed| {
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
    return .{ .dir = dir, .scene = scene, .platform = platform, .optimize = optimize, .docker_build = docker_build, .docker_target = docker_target, .bake = bake, .progress_mode = progress_mode };
}

/// Parse [dir], --scene, --timeout, --platform, --optimize, --docker, and --target flags for run command (explicit or implicit).
///
/// A bare `--` token switches the parser into "passthrough" mode: every
/// subsequent token is collected verbatim into `parsed_args.extra_args`
/// without flag interpretation, so callers can forward args to the game
/// binary via `zig build run -- <extras>` (see run_cmd handler).
fn parseRunArgs(args: anytype, cmd_name: []const u8, allow_dir: bool, parsed_args: *ParsedArgs) ?struct { dir: []const u8, scene: ?[]const u8, timeout_ns: ?u64, platform: ?Platform, optimize: ?[]const u8, docker_build: bool, docker_target: ?[]const u8, bake: bool, screenshot_path: ?[]const u8, screenshot_after_ns: ?u64 } {
    var dir: []const u8 = ".";
    var dir_set = !allow_dir;
    var scene: ?[]const u8 = null;
    var timeout_ns: ?u64 = null;
    var platform: ?Platform = null;
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
        if (std.mem.startsWith(u8, arg, "--timeout=")) {
            timeout_ns = util.parseDuration(arg["--timeout=".len..]);
            if (timeout_ns == null) {
                std.debug.print("labelle: invalid --timeout value '{s}'\n", .{arg["--timeout=".len..]});
                std.debug.print("  expected format: --timeout=30s, --timeout=2m\n", .{});
                return null;
            }
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            if (args.next()) |val| {
                timeout_ns = util.parseDuration(val);
                if (timeout_ns == null) {
                    std.debug.print("labelle: invalid --timeout value '{s}'\n", .{val});
                    std.debug.print("  expected format: --timeout 30s, --timeout 2m\n", .{});
                    return null;
                }
            } else {
                std.debug.print("labelle: --timeout requires a value (e.g. --timeout 30s)\n", .{});
                return null;
            }
        } else if (std.mem.startsWith(u8, arg, "--screenshot=")) {
            const val = arg["--screenshot=".len..];
            if (val.len == 0) {
                std.debug.print("labelle {s}: --screenshot requires a path (e.g. --screenshot=/tmp/shot.png)\n", .{cmd_name});
                return null;
            }
            screenshot_path = val;
            continue;
        } else if (std.mem.eql(u8, arg, "--screenshot")) {
            if (args.next()) |val| {
                if (val.len == 0) {
                    std.debug.print("labelle {s}: --screenshot requires a path (e.g. --screenshot /tmp/shot.png)\n", .{cmd_name});
                    return null;
                }
                screenshot_path = val;
            } else {
                std.debug.print("labelle {s}: --screenshot requires a path (e.g. --screenshot /tmp/shot.png)\n", .{cmd_name});
                return null;
            }
            continue;
        } else if (std.mem.startsWith(u8, arg, "--after=")) {
            screenshot_after_ns = util.parseDuration(arg["--after=".len..]);
            if (screenshot_after_ns == null) {
                std.debug.print("labelle {s}: invalid --after value '{s}'\n", .{ cmd_name, arg["--after=".len..] });
                std.debug.print("  expected format: --after=2s, --after=500ms\n", .{});
                return null;
            }
            continue;
        } else if (std.mem.eql(u8, arg, "--after")) {
            if (args.next()) |val| {
                screenshot_after_ns = util.parseDuration(val);
                if (screenshot_after_ns == null) {
                    std.debug.print("labelle {s}: invalid --after value '{s}'\n", .{ cmd_name, val });
                    std.debug.print("  expected format: --after 2s, --after 500ms\n", .{});
                    return null;
                }
            } else {
                std.debug.print("labelle {s}: --after requires a value (e.g. --after 2s)\n", .{cmd_name});
                return null;
            }
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
        } else if (std.mem.startsWith(u8, arg, "--ticks=")) {
            const val = arg["--ticks=".len..];
            const n = std.fmt.parseInt(u64, val, 10) catch null;
            if (n == null or n.? == 0) {
                std.debug.print("labelle {s}: invalid --ticks value '{s}'\n", .{ cmd_name, val });
                std.debug.print("  expected a positive integer, e.g. --ticks=600\n", .{});
                return null;
            }
            parsed_args.headless = true; // --ticks implies --headless
            parsed_args.headless_ticks = n.?;
            continue;
        } else if (std.mem.eql(u8, arg, "--ticks")) {
            // Space-separated form, same as `--timeout 30s`.
            if (args.next()) |val| {
                const n = std.fmt.parseInt(u64, val, 10) catch null;
                if (n == null or n.? == 0) {
                    std.debug.print("labelle {s}: invalid --ticks value '{s}'\n", .{ cmd_name, val });
                    std.debug.print("  expected a positive integer, e.g. --ticks 600\n", .{});
                    return null;
                }
                parsed_args.headless = true; // --ticks implies --headless
                parsed_args.headless_ticks = n.?;
            } else {
                std.debug.print("labelle {s}: --ticks requires a value (e.g. --ticks=600)\n", .{cmd_name});
                return null;
            }
            continue;
        } else if (parseToolchainFlag(arg, args)) |consumed| {
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
    return .{ .dir = dir, .scene = scene, .timeout_ns = timeout_ns, .platform = platform, .optimize = optimize, .docker_build = docker_build, .docker_target = docker_target, .bake = bake, .screenshot_path = screenshot_path, .screenshot_after_ns = screenshot_after_ns };
}

/// Collect all remaining args into extra_args buffer.
fn collectExtraArgs(args: *std.process.Args.Iterator, parsed_args: *ParsedArgs) ParseError!void {
    while (args.next()) |arg| {
        try appendExtraArg(parsed_args, arg);
    }
}

/// Append one token to `ParsedArgs.extra_args`, surfacing overflow as
/// an error instead of silently dropping it (which would let the
/// subcommand fall through to `project_dir`).
fn appendExtraArg(parsed_args: *ParsedArgs, arg: []const u8) ParseError!void {
    if (parsed_args.extra_count >= parsed_args.extra_args.len) {
        std.debug.print("labelle: too many arguments\n", .{});
        return error.TooManyArguments;
    }
    parsed_args.extra_args[parsed_args.extra_count] = arg;
    parsed_args.extra_count += 1;
}

fn appendRunForwardedArgs(argv: *std.ArrayList([]const u8), allocator: std.mem.Allocator, parsed_args: *const ParsedArgs) !void {
    if (parsed_args.extra_count == 0) return;
    try argv.append(allocator, "--");
    for (parsed_args.extra_args[0..parsed_args.extra_count]) |extra| {
        try argv.append(allocator, extra);
    }
}

/// Handle `labelle assembler <subcommand>`.
fn handleAssemblerCmd(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    if (cmd_args.len == 0 or std.mem.eql(u8, cmd_args[0], "list")) {
        return assembler.cmdListAssemblers(allocator);
    }
    std.debug.print("labelle assembler: unknown subcommand '{s}'\n", .{cmd_args[0]});
    std.debug.print("  usage: labelle assembler list\n", .{});
    return error.UnknownSubcommand;
}

/// Handle `labelle toolchain <subcommand>` — managed Zig introspection (cli#279).
///   list         — cached versions under `~/.labelle/zig/`
///   which [dir]  — the version + source + path the project would use
fn handleToolchainCmd(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    if (cmd_args.len == 0 or std.mem.eql(u8, cmd_args[0], "list")) {
        return zig_toolchain.cmdToolchainList(allocator);
    }
    if (std.mem.eql(u8, cmd_args[0], "which")) {
        const dir = if (cmd_args.len >= 2) cmd_args[1] else ".";
        return zig_toolchain.cmdToolchainWhich(allocator, dir);
    }
    // `toolchain emsdk [dir]` — managed emsdk/emcc resolution (cli#283).
    if (std.mem.eql(u8, cmd_args[0], "emsdk")) {
        const dir = if (cmd_args.len >= 2) cmd_args[1] else ".";
        return emsdk_toolchain.cmdEmsdkWhich(allocator, dir);
    }
    std.debug.print("labelle toolchain: unknown subcommand '{s}'\n", .{cmd_args[0]});
    std.debug.print("  usage: labelle toolchain list | labelle toolchain which [dir] | labelle toolchain emsdk [dir]\n", .{});
    return error.UnknownSubcommand;
}

pub fn main(proc_init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize the process-wide Io for the CLI's filesystem/env
    // helpers. Must happen before any submodule reaches for
    // `globalIo()`/`globalEnviron()`.
    config.initGlobalIo(proc_init.minimal);

    var args = try std.process.Args.Iterator.initAllocator(proc_init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip(); // skip program name

    var parsed_args = ParsedArgs{ .command = .run };

    const first_arg = args.next();
    if (first_arg == null) {
        return help.printHelp();
    }

    if (first_arg) |first| {
        if (std.mem.eql(u8, first, "generate") or std.mem.eql(u8, first, "build")) {
            parsed_args.command = if (std.mem.eql(u8, first, "generate")) .generate else .build;
            const result = parseDirAndScene(&args, first) orelse return;
            parsed_args.project_dir = result.dir;
            parsed_args.scene_override = result.scene;
            parsed_args.platform_override = result.platform;
            parsed_args.optimize_override = result.optimize;
            parsed_args.docker = result.docker_build;
            parsed_args.docker_target = result.docker_target;
            parsed_args.bake = result.bake;
            parsed_args.progress_mode = result.progress_mode;
        } else if (std.mem.eql(u8, first, "run")) {
            parsed_args.command = .run;
            const result = parseRunArgs(&args, "run", true, &parsed_args) orelse return;
            parsed_args.project_dir = result.dir;
            parsed_args.scene_override = result.scene;
            parsed_args.timeout_ns = result.timeout_ns;
            parsed_args.platform_override = result.platform;
            parsed_args.optimize_override = result.optimize;
            parsed_args.docker = result.docker_build;
            parsed_args.docker_target = result.docker_target;
            parsed_args.bake = result.bake;
            parsed_args.screenshot_path = result.screenshot_path;
            parsed_args.screenshot_after_ns = result.screenshot_after_ns;
        } else if (std.mem.eql(u8, first, "init")) {
            parsed_args.command = .init_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "install")) {
            parsed_args.command = .install_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "upgrade")) {
            parsed_args.command = .upgrade_cmd;
            if (args.next()) |next_arg| {
                if (std.mem.eql(u8, next_arg, "core") or
                    std.mem.eql(u8, next_arg, "engine") or
                    std.mem.eql(u8, next_arg, "gfx") or
                    std.mem.eql(u8, next_arg, "cli") or
                    std.mem.eql(u8, next_arg, "labelle") or
                    std.mem.eql(u8, next_arg, "assembler") or
                    std.mem.eql(u8, next_arg, "all"))
                {
                    try appendExtraArg(&parsed_args, next_arg);
                } else {
                    parsed_args.project_dir = next_arg;
                }
            }
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "update")) {
            parsed_args.command = .update_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "clean")) {
            parsed_args.command = .clean_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "test")) {
            parsed_args.command = .test_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "pack")) {
            parsed_args.command = .pack_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "astc")) {
            parsed_args.command = .astc_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "audit")) {
            parsed_args.command = .audit_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "add")) {
            // `add pack <name>` / `add feature <kind> <name>` — forwarded
            // verbatim to the assembler's `add` subcommand (Packs #271).
            parsed_args.command = .add_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "migrate")) {
            parsed_args.command = .migrate_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "check")) {
            parsed_args.command = .check_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "toolchain")) {
            // `labelle toolchain list|which` — managed Zig introspection (cli#279).
            parsed_args.command = .toolchain_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "status")) {
            // `labelle status [dir] [--json]` — read the live build-progress
            // status file from a second shell (cli#284).
            parsed_args.command = .status_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "doctor")) {
            parsed_args.command = .doctor_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "ios")) {
            parsed_args.command = .ios_cmd;
            // First non-flag arg that isn't a subcommand is the project dir
            while (args.next()) |arg| {
                if (std.mem.startsWith(u8, arg, "-") or
                    std.mem.eql(u8, arg, "build") or
                    std.mem.eql(u8, arg, "xcode") or
                    std.mem.eql(u8, arg, "run"))
                {
                    try appendExtraArg(&parsed_args, arg);
                } else {
                    parsed_args.project_dir = arg;
                }
            }
        } else if (std.mem.eql(u8, first, "android")) {
            parsed_args.command = .android_cmd;
            // Android value-bearing flags: the NEXT token after one of
            // these is the flag's value, not the project directory.
            var expect_value = false;
            while (args.next()) |arg| {
                if (expect_value) {
                    try appendExtraArg(&parsed_args, arg);
                    expect_value = false;
                    continue;
                }
                if (std.mem.startsWith(u8, arg, "-") or
                    std.mem.eql(u8, arg, "build") or
                    std.mem.eql(u8, arg, "run") or
                    std.mem.eql(u8, arg, "studio") or
                    std.mem.eql(u8, arg, "deploy") or
                    std.mem.eql(u8, arg, "doctor") or
                    std.mem.eql(u8, arg, "help"))
                {
                    try appendExtraArg(&parsed_args, arg);
                    if (std.mem.eql(u8, arg, "--keystore") or
                        std.mem.eql(u8, arg, "--keystore-pass") or
                        std.mem.eql(u8, arg, "--key-alias") or
                        std.mem.eql(u8, arg, "--key-pass") or
                        std.mem.eql(u8, arg, "--tag") or
                        std.mem.eql(u8, arg, "--channel") or
                        std.mem.eql(u8, arg, "--notes-file"))
                    {
                        expect_value = true;
                    }
                } else {
                    parsed_args.project_dir = arg;
                }
            }
        } else if (std.mem.eql(u8, first, "wasm")) {
            // `labelle wasm <subcommand>` — only `serve` exists today.
            const sub = args.next();
            if (sub == null or !std.mem.eql(u8, sub.?, "serve")) {
                if (sub) |s| {
                    std.debug.print("labelle wasm: unknown subcommand '{s}'\n", .{s});
                } else {
                    std.debug.print("labelle wasm: missing subcommand\n", .{});
                }
                std.debug.print("  usage: labelle wasm serve [dir] [--port <n>] [--no-build] [--no-open] [--progress=<m>]\n", .{});
                return;
            }
            parsed_args.command = .wasm_cmd;
            const result = parseWasmServeArgs(&args) orelse return;
            parsed_args.project_dir = result.dir;
            parsed_args.serve_port = result.port;
            parsed_args.serve_no_build = result.no_build;
            parsed_args.serve_no_open = result.no_open;
            parsed_args.progress_mode = result.progress_mode;
            // `wasm serve` always builds/serves the WASM target.
            parsed_args.platform_override = .wasm;
        } else if (std.mem.eql(u8, first, "assembler")) {
            parsed_args.command = .assembler_cmd;
            try collectExtraArgs(&args, &parsed_args);
        } else if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
            parsed_args.command = .help_cmd;
        } else if (std.mem.eql(u8, first, "version") or std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-v")) {
            parsed_args.command = .version;
        } else if (std.mem.eql(u8, first, "targets")) {
            parsed_args.command = .targets;
        } else {
            // No command — treat as project dir, default to run
            const result = parseRunArgs(&args, "run", false, &parsed_args) orelse return;
            parsed_args.project_dir = first;
            parsed_args.scene_override = result.scene;
            parsed_args.timeout_ns = result.timeout_ns;
            parsed_args.platform_override = result.platform;
            parsed_args.optimize_override = result.optimize;
            parsed_args.docker = result.docker_build;
            parsed_args.docker_target = result.docker_target;
            parsed_args.bake = result.bake;
            parsed_args.screenshot_path = result.screenshot_path;
            parsed_args.screenshot_after_ns = result.screenshot_after_ns;
        }
    }

    const command = parsed_args.command;
    const project_dir = parsed_args.project_dir;
    const timeout_ns = parsed_args.timeout_ns;

    // Standalone commands (no project.labelle needed)
    switch (command) {
        .help_cmd => return help.printHelp(),
        .version => return help.printVersion(),
        .targets => return help.printTargets(),
        .init_cmd => return init.cmdInit(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .add_cmd => return add.cmdAdd(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .install_cmd => return install.cmdInstall(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .update_cmd => return update.cmdUpdate(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .clean_cmd => return clean.cmdClean(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .test_cmd => return test_cmd_mod.cmdTest(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .pack_cmd => return pack.cmdPack(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .astc_cmd => return astc_cmd.cmdAstc(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .audit_cmd => return audit.cmdAudit(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .migrate_cmd => return migrate.cmdMigrate(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .check_cmd => return check.cmdCheck(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .doctor_cmd => return doctor.cmdDoctor(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .assembler_cmd => return handleAssemblerCmd(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .toolchain_cmd => return handleToolchainCmd(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        .status_cmd => return status_mod.cmdStatus(allocator, parsed_args.extra_args[0..parsed_args.extra_count]),
        else => {},
    }

    // `labelle android doctor` and `labelle android help` are
    // standalone — they don't need a project.labelle. Intercept here
    // so running them from any directory works without the "No
    // project.labelle found" bail below.
    //
    // Doctor still *uses* the project's android config when available
    // so the probe targets the right `target_sdk_version`. The read
    // is quiet: if there's no project (or it fails to parse), we fall
    // through to the defaults instead of erroring out.
    //
    // `AndroidToolsMissing` is caught and turned into `exit(1)` so
    // the Zig error-return trace stays out of the user's terminal —
    // the report was already printed.
    if (command == .android_cmd and parsed_args.extra_count > 0) {
        const first = parsed_args.extra_args[0];
        if (std.mem.eql(u8, first, "doctor")) {
            var doctor_arena = std.heap.ArenaAllocator.init(allocator);
            defer doctor_arena.deinit();
            const project_cfg: ?project_config.AndroidConfig = blk: {
                const parsed_cfg = config.readProjectConfigQuiet(doctor_arena.allocator(), project_dir) catch break :blk null;
                break :blk parsed_cfg.android;
            };
            android.runDoctor(allocator, project_cfg) catch |err| {
                if (err == error.AndroidToolsMissing) std.process.exit(1);
                return err;
            };
            return;
        }
        if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
            return android.printHelp();
        }
    }

    // Read and parse project.labelle
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parsed = config.readProjectConfig(arena.allocator(), project_dir) catch |err| {
        if (err == error.FileNotFound) {
            config.printNoProjectError(project_dir);
        }
        return;
    };

    // Normalize the deprecated `.initial_scene` alias (RFC #560 / #565)
    // into `.initial_prefab`. The `--scene=` flag does NOT rewrite
    // `.initial_prefab` anymore — it sets `LABELLE_SCENE=<name>` in the
    // spawned game's env (cli#229) and the project's loading-scene
    // controller reads it via `engine.requestedScene()` and transitions
    // once `assets.allReady`. The legacy initial-prefab-rewrite path was
    // removed because it bypassed the loading gate and made the game
    // stick on the target scene's async-load forever for projects with
    // a loading-scene gate.
    parsed.normalizeInitialPrefab();

    // Apply --platform override
    if (parsed_args.platform_override) |platform| {
        parsed.platform = platform;
    }

    // `labelle ios` always implies sokol + ios platform
    if (command == .ios_cmd) {
        parsed.platform = .ios;
        parsed.backend = .sokol;
    }

    // `labelle android` implies the android platform.
    if (command == .android_cmd) {
        parsed.platform = .android;
    }

    // Resolve the backend for ANY android-targeting invocation —
    // `labelle android`, `labelle run --platform=android`, or
    // `labelle build --platform=android` all land here. The backend is
    // taken from the project's declared backend, honoring an
    // Android-capable choice (`sokol` or `bgfx`) and falling back to
    // sokol otherwise (#252). Keying off the resolved platform (rather
    // than the subcommand) means a `.backend = .raylib` project run with
    // `--platform=android` gets the same helpful fallback as `labelle
    // android` instead of failing later on a missing `raylib_android`
    // target dir.
    if (parsed.platform == .android) {
        const android_backend = resolveAndroidBackend(parsed.backend);
        if (android_backend != parsed.backend) {
            std.debug.print(
                "labelle: backend '{s}' can't target Android; defaulting to sokol.\n",
                .{@tagName(parsed.backend)},
            );
        }
        parsed.backend = android_backend;
    }

    // Upgrade modifies project.labelle in the project directory
    if (command == .upgrade_cmd) {
        return upgrade.cmdUpgrade(allocator, project_dir, parsed, parsed_args.extra_args[0..parsed_args.extra_count]);
    }

    // `labelle wasm serve --no-build` — skip the generate+build
    // pipeline entirely and serve the existing build output. The web
    // dir lives under the wasm target subdir (`.labelle/<backend>_wasm/`).
    if (command == .wasm_cmd and parsed_args.serve_no_build) {
        const wasm_target = try std.fmt.allocPrint(allocator, "{s}_wasm", .{@tagName(parsed.backend)});
        defer allocator.free(wasm_target);
        const web_dir = try std.fs.path.join(allocator, &.{
            project_dir, ".labelle", wasm_target, "zig-out", "web",
        });
        defer allocator.free(web_dir);
        if (std.Io.Dir.cwd().access(config.globalIo(), web_dir, .{})) |_| {} else |_| {
            std.debug.print(
                "labelle wasm serve: no existing WASM build at '{s}'\n" ++
                    "  run `labelle wasm serve` (without --no-build) first.\n",
                .{web_dir},
            );
            return error.BuildFailed;
        }
        const project_web_dir = try std.fs.path.join(allocator, &.{ project_dir, "web" });
        defer allocator.free(project_web_dir);
        return serve.serveAndOpen(allocator, web_dir, project_web_dir, parsed_args.serve_port, !parsed_args.serve_no_open);
    }

    // ── Build-progress feed (cli#284) ──────────────────────────────────
    // Target subdir: .labelle/raylib_desktop/, etc. Computed up front so
    // the live status file `.labelle/<target>/.build-progress.json` has a
    // home from the first `resolve` record onward (the dir is created by
    // the reporter; the assembler generates into it later).
    const target_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ @tagName(parsed.backend), @tagName(parsed.platform) });
    defer allocator.free(target_name);
    const target_dir = try std.fs.path.join(allocator, &.{ project_dir, ".labelle", target_name });
    defer allocator.free(target_dir);

    // One event source, three access modes: NDJSON on stdout
    // (`--progress=json`), the atomically-rewritten status file (all
    // modes; read by `labelle status` + studio), and a spinner on TTY
    // stderr (default human mode). Enabled for the commands that run the
    // shared build pipeline; `labelle generate` and the ios/android
    // subcommands (which own their own build flows) stay report-free. A
    // reporter that fails to initialize downgrades to the pre-#284
    // behavior instead of blocking the build.
    var reporter_storage: progress.Reporter = undefined;
    const reporter: ?*progress.Reporter = blk: {
        if (command != .build and command != .run and command != .wasm_cmd) break :blk null;
        reporter_storage = progress.Reporter.init(allocator, config.globalIo(), parsed_args.progress_mode, target_dir) catch break :blk null;
        break :blk &reporter_storage;
    };
    defer if (reporter) |r| r.deinit();
    // Any error path from here on marks the status file `failed`, so an
    // out-of-band reader never sees a live phase for a dead build.
    // (Pipeline code that terminates via process-exit instead of an error
    // return goes through `progress.fatalExit`, which does the same.)
    errdefer if (reporter) |r| r.failIfActive(1);
    if (reporter) |r| {
        // Registers the fatalExit hook + starts the keepalive ticker that
        // refreshes elapsed/updated timestamps while child processes own
        // the foreground (assembler, zig, game).
        r.activate();
        r.beginPhase(.resolve, "resolving toolchain + packages");
    }

    // Validate version compatibility
    compatibility.validateCompatibility(parsed);

    // Auto-wire a cache-provisioned SDL2 (`labelle doctor --fix`) into the
    // build/run environment so desktop games that need it (raylib/sokol
    // gamepad, sdl backend) link + run without the user setting
    // LABELLE_SDL2_LIB by hand. No-op when SDL2 isn't in the cache or the
    // user already set the var. Scoped like `labelle doctor`: the sdl
    // backend always needs SDL2; raylib/sokol only for the gamepad
    // source, so `.gamepad = .none` projects get nothing injected.
    // Backends that pull in SDL2: the `sdl` renderer always, and
    // raylib/sokol/bgfx for the shared desktop gamepad source unless gamepad
    // is opted out. Mirrors the assembler's `deps_linker.stagesSdlGamepad`
    // (raylib/sokol/bgfx with `gamepad == .auto`) — bgfx was previously
    // missing here, so its default gamepad-enabled desktop builds never got
    // SDL2 auto-wired or the runtime DLL staged (cli#285 / cli#286).
    const wants_sdl2 = parsed.backend == .sdl or
        ((parsed.backend == .raylib or parsed.backend == .sokol or parsed.backend == .bgfx) and parsed.gamepad != .none);
    if (parsed.platform == .desktop and wants_sdl2) {
        sdl_provision.autoWireEnv(allocator);
    }

    // Issue #217: the CLI is a thin driver over the standalone
    // labelle-assembler binary. Resolve it once here (LABELLE_ASSEMBLER
    // env var > assembler_version in project.labelle > auto-downloaded
    // default) and reuse the located binary for both the cache-populate
    // step and code generation below.
    const asm_bin = try assembler_proc.resolve(allocator, project_dir, "generate");
    defer asm_bin.deinit(allocator);
    std.debug.print("  using assembler: {s}\n", .{asm_bin.path});

    // ASTC build-time conversion (#340): when this platform ships ASTC atlases
    // (`asset_compression`), run `labelle astc` first so the `<name>.astc`
    // siblings exist for the assembler's catalog `.png → .astc` swap. Runs
    // before the assembler steps (it only needs project.labelle + the PNGs +
    // astcenc). Non-fatal — on any failure the assembler finds no sibling and
    // falls back to the source PNG, so the build still succeeds.
    if (parsed.asset_compression.formatFor(parsed.platform) == .astc) {
        astc_cmd.cmdAstc(allocator, &.{project_dir}) catch |err| {
            std.debug.print("labelle: ASTC conversion failed ({s}); falling back to PNG atlases\n", .{@errorName(err)});
        };
    }

    // Ensure the package cache is populated. The assembler's `generate`
    // subcommand assumes a populated cache (it does not fetch packages
    // itself), so delegate `install --project-root` to the binary first.
    // This replaces the CLI's former in-process `cache.ensureCache`,
    // which depended on the assembler's `generator` module.
    try asm_bin.run(allocator, "install", &.{ "--project-root", project_dir });

    // Generate into .labelle/
    const output_dir = try std.fs.path.join(allocator, &.{ project_dir, ".labelle" });
    defer allocator.free(output_dir);

    // GUI resolution (reading the plugin's gui.labelle manifest) is owned
    // by the assembler's `generate` subcommand — the CLI no longer
    // resolves it. The status line reports whether a GUI is *configured*
    // in project.labelle; the assembler logs the resolved plugin name.
    const gui_label: []const u8 = if (parsed.gui != null) "configured" else "none";
    if (reporter) |r| r.beginPhase(.generate, "assembler generate");
    std.debug.print("labelle: generating '{s}'...\n", .{parsed.name});
    std.debug.print("  backend: {s}  platform: {s}  ecs: {s}  gui: {s}  window: {d}x{d}\n", .{
        @tagName(parsed.backend), @tagName(parsed.platform), @tagName(parsed.ecs), gui_label, parsed.width, parsed.height,
    });

    // Scenes and prefabs are always embedded via @embedFile
    const effective_optimize = parsed_args.optimize_override orelse
        if (parsed.platform == .wasm) @as(?[]const u8, "ReleaseSafe") else null;

    // Opt-in PNG → LRGBA pre-bake. Runs before the assembler so its
    // @embedFile path picks up the fresh `.rgba` files. Skipped unless
    // `--bake` is passed: raw RGBA expands heavily-transparent atlases
    // by 100×+ (a 200 KB PNG can become 64 MB), so default-off keeps
    // APK size sane. Use for projects whose atlases are nearly opaque
    // and PNG decode dominates cold start.
    if (parsed_args.bake) {
        bake_mod.run(allocator, project_dir, parsed.resources) catch |err| {
            std.debug.print("labelle: bake failed: {s}\n", .{@errorName(err)});
            return err;
        };
    }

    // Issue #217 phase 2: delegate code generation to the standalone
    // labelle-assembler binary via the shared subprocess harness, instead
    // of calling an in-process generator. The binary was located above
    // (`asm_bin`) and already used for the `install` cache-populate step.
    //
    // `build` / `run` are not assembler subcommands: the subsequent
    // `zig build` invocation and binary launch stay CLI-side (see below).
    // The CLI owns docker orchestration, the WASM serve loop, the
    // iOS/Android deploy paths and `--timeout` — generation is the only
    // step the assembler binary delegates.
    // `parsed_args.scene_override` is intentionally NOT forwarded to the
    // assembler. PR #243 removed the CLI's `cfg.initial_prefab` rewrite for
    // exactly this reason; the assembler's own `--scene` handling does the
    // same rewrite, which bypasses any loading-scene gate the project
    // declares. The override is delivered at runtime via the
    // `LABELLE_SCENE` env var injected at the spawn site (~line 990).
    try assembler_proc.generate(
        asm_bin,
        allocator,
        project_dir,
        @tagName(parsed.platform),
        @tagName(parsed.backend),
    );

    // (`target_name`/`target_dir` — .labelle/raylib_desktop/, etc. — are
    // computed up front, before the progress reporter init; see cli#284.)

    // fixFingerprints runs `zig build` locally per emitted target dir to
    // discover the correct hash. With assembler >=0.14.0 there are two
    // (`<backend>_<platform>/` and `tests/`); patching only the exe dir
    // would leave `tests/` with a placeholder fingerprint and break
    // `labelle test`.
    //
    // For docker builds we skip the exe target — the host Zig toolchain
    // may not have the native libs the chosen backend needs (that's why
    // we're routing through docker in the first place). The tests target
    // is the exception: it uses the null backend (no native libs), so
    // host Zig can build it even when --docker is set, and skipping
    // would leave `labelle test` broken on the host after `labelle build
    // --docker`. Patch `tests/` directly when present.
    if (!parsed_args.docker) {
        try runner.fixFingerprints(allocator, project_dir, output_dir);
    } else {
        const tests_dir = try std.fs.path.join(allocator, &.{ output_dir, "tests" });
        defer allocator.free(tests_dir);
        const tests_build_zig = try std.fs.path.join(allocator, &.{ tests_dir, "build.zig" });
        defer allocator.free(tests_build_zig);
        if (std.Io.Dir.cwd().access(config.globalIo(), tests_build_zig, .{})) |_| {
            try runner.fixFingerprint(allocator, project_dir, tests_dir);
        } else |_| {}
    }
    try lockfile.writeLockFile(allocator, project_dir, parsed);
    std.debug.print("  generated .labelle/{s}/\n", .{target_name});

    // For a wasm build: activate the emsdk checkout Zig just fetched into the
    // project-local `zig-pkg/` (during the fingerprint pass above) so the emcc
    // link step finds `upstream/emscripten/emcc`. Without this a fresh
    // `labelle build --platform wasm` — or `generate --platform wasm` followed
    // by a manual `zig build` — dies at the emcc step because the fetched emsdk
    // package is NOT activated: the remaining half of labelle-assembler#492 (the
    // docker path already does this in-container). Run it BEFORE the `generate`
    // early-return so the generate-then-build path is covered too. Best-effort +
    // idempotent; on failure the build still surfaces the clear #492 guidance.
    // The PINNED version keeps activation deterministic.
    if (!parsed_args.docker and parsed.platform == .wasm) {
        const resolved_emsdk = try emsdk_toolchain.resolveRequiredVersion(allocator, project_dir);
        defer allocator.free(resolved_emsdk.version);
        emsdk_activate.activateFetchedEmsdk(allocator, target_dir, resolved_emsdk.version);
    }

    if (command == .generate) return;

    // `labelle ios` subcommand — handles its own build/xcode/run
    if (command == .ios_cmd) {
        return ios.handleIos(allocator, parsed_args.extra_args[0..parsed_args.extra_count], parsed, target_dir);
    }

    // `labelle android` subcommand — handles its own build/run
    if (command == .android_cmd) {
        return android.handleAndroid(allocator, parsed_args.extra_args[0..parsed_args.extra_count], parsed, target_dir);
    }

    // Warn if --target is used without --docker (it has no effect otherwise)
    if (parsed_args.docker_target != null and !parsed_args.docker) {
        std.debug.print("labelle: warning: --target has no effect without --docker\n", .{});
    }

    // Build — default to ReleaseSafe for WASM (Debug exceeds browser local variable limits)
    const optimize_flag: ?[]const u8 = if (effective_optimize) |opt|
        try std.fmt.allocPrint(allocator, "-Doptimize={s}", .{opt})
    else
        null;
    defer if (optimize_flag) |f| allocator.free(f);

    // Resolve the managed Zig toolchain (labelle-cli#279): every `zig` spawn
    // uses this binary, never PATH. Downloads + verifies on a cache miss.
    // Skipped for docker builds — the toolchain lives inside the container.
    const managed_zig: ?[]u8 = if (parsed_args.docker) null else try runner.resolveZigExe(allocator, project_dir);
    defer if (managed_zig) |z| allocator.free(z);

    // Build a base env for child `zig` that pins ZIG_*_CACHE_DIR into the
    // labelle cache tree (user-writable, never next to a read-only install).
    // For a wasm build, ALSO layer the managed emsdk's EMSDK/EM_CONFIG/PATH
    // wiring on top when one is already provisioned (labelle-cli#283) — an
    // escape hatch for builds/backends that resolve `emcc` via PATH/env rather
    // than the fetched package activated just above.
    var zig_env_storage: ?std.process.Environ.Map = if (parsed_args.docker)
        null
    else if (parsed.platform == .wasm)
        try runner.buildWasmEnv(allocator, project_dir)
    else
        try runner.buildZigEnv(allocator, &.{});
    defer if (zig_env_storage) |*m| m.deinit();
    const zig_env_ptr: ?*const std.process.Environ.Map = if (zig_env_storage) |*m| m else null;

    var zig_args: std.ArrayList([]const u8) = .empty;
    defer zig_args.deinit(allocator);
    try zig_args.append(allocator, managed_zig orelse "zig");
    try zig_args.append(allocator, "build");
    if (optimize_flag) |flag| try zig_args.append(allocator, flag);

    if (parsed_args.docker) {
        // Docker builds get phase-level progress only: the toolchain (and
        // its progress pipe) lives inside the container.
        if (reporter) |r| r.beginPhase(.compile, "docker build");
        std.debug.print("labelle: building via docker...\n", .{});
        const docker_exit = try docker.runBuild(allocator, target_dir, parsed.platform, parsed_args.docker_target, effective_optimize);
        if (reporter) |r| r.clearSpinner();
        if (docker_exit != 0) {
            if (reporter) |r| r.finishFailed(docker_exit, "docker build failed");
            std.debug.print("labelle: docker build failed (exit code {d})\n", .{docker_exit});
            return error.BuildFailed;
        }
    } else if (reporter) |r| {
        // cli#284: spawn `zig build` with Zig's std.Progress IPC pipe
        // attached — live node names + keepalives flow into the feed
        // during the compile (see runner.zig for what Zig 0.16 actually
        // relays), and stdio is inherited so compile errors stream to the
        // terminal unaltered (nothing is captured or eaten).
        std.debug.print("labelle: building...\n", .{});
        r.beginPhase(.compile, "zig build");
        const build_code = try runner.runZigInheritProgress(allocator, target_dir, zig_args.items, zig_env_ptr, r);
        // Wipe the spinner line before anything else prints on it.
        r.clearSpinner();
        if (build_code != 0) {
            r.finishFailed(build_code, "zig build failed");
            std.debug.print("labelle: build failed (exit {d})\n", .{build_code});
            return error.BuildFailed;
        }
    } else {
        std.debug.print("labelle: building...\n", .{});
        const build_result = try runner.runZigWithEnv(allocator, target_dir, zig_args.items, zig_env_ptr);
        defer allocator.free(build_result.stdout);
        defer allocator.free(build_result.stderr);

        switch (build_result.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("labelle: build failed:\n{s}\n", .{build_result.stderr});
                return error.BuildFailed;
            },
            else => {
                std.debug.print("labelle: build process terminated abnormally\n{s}\n", .{build_result.stderr});
                return error.BuildFailed;
            },
        }
    }
    std.debug.print("  build ok\n", .{});

    // Stage the runtime SDL2.dll next to the freshly-built desktop exe. A
    // gamepad/SDL2 build's exe fails process creation with a bare
    // `FileNotFound` when SDL2.dll isn't in its own directory (cli#285): the
    // Windows loader resolves implicitly-linked DLLs from the exe dir first,
    // and neither the PATH prepend from autoWireEnv nor a user-set
    // LABELLE_SDL2_LIB puts the DLL there. Docker builds are skipped — their
    // exe is built for the container's OS, so a host SDL2.dll is irrelevant.
    if (!parsed_args.docker and parsed.platform == .desktop and wants_sdl2) {
        const bin_dir = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "bin" });
        defer allocator.free(bin_dir);
        sdl_provision.stageSdl2DllBesideExe(allocator, bin_dir);
    }

    if (command == .build) {
        // `labelle build --platform=android` builds the shared library
        // above (the generic `zig build` produces `zig-out/lib/libgame.so`)
        // but, unlike `labelle android build`, used to stop there and leave
        // a bare `.so`. Package it into a signed APK so the artifact is
        // installable — backend-agnostic, so it covers sokol and bgfx alike.
        if (parsed.platform == .android) {
            const apk_path = try android.packageApk(allocator, target_dir, parsed, false, .{});
            defer allocator.free(apk_path);
            std.debug.print("labelle: APK ready: {s}\n", .{apk_path});
        }
        if (reporter) |r| r.finishDone(0);
        return;
    }

    // Run
    if (parsed.platform == .wasm) {
        // WASM: serve via local HTTP server + open browser. The build
        // pipeline is complete here — the serve loop is interactive (runs
        // until Ctrl+C), so the terminal `done` record lands first.
        if (reporter) |r| r.finishDone(0);
        const web_dir = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "web" });
        defer allocator.free(web_dir);
        const project_web_dir = try std.fs.path.join(allocator, &.{ project_dir, "web" });
        defer allocator.free(project_web_dir);
        try serve.serveAndOpen(allocator, web_dir, project_web_dir, parsed_args.serve_port, !parsed_args.serve_no_open);
    } else if (parsed.platform == .ios) {
        // iOS: deploy to simulator
        if (reporter) |r| r.beginPhase(.run, "deploying to iOS Simulator");
        std.debug.print("labelle: deploying to iOS Simulator...\n", .{});
        try ios.deployToSimulator(allocator, target_dir, parsed);
        if (reporter) |r| r.finishDone(0);
    } else if (parsed.platform == .android) {
        // Android: deploy to device/emulator
        if (reporter) |r| r.beginPhase(.run, "deploying to Android");
        std.debug.print("labelle: deploying to Android...\n", .{});
        try android.deployToDevice(allocator, target_dir, parsed, false, .{});
        if (reporter) |r| r.finishDone(0);
    } else {
        if (timeout_ns) |t| {
            const secs = t / std.time.ns_per_s;
            const mins = secs / 60;
            const rem = secs % 60;
            if (mins > 0 and rem > 0) {
                std.debug.print("labelle: running (timeout: {d}m{d}s)...\n\n", .{ mins, rem });
            } else if (mins > 0) {
                std.debug.print("labelle: running (timeout: {d}m)...\n\n", .{mins});
            } else {
                std.debug.print("labelle: running (timeout: {d}s)...\n\n", .{secs});
            }
        } else {
            std.debug.print("labelle: running...\n\n", .{});
        }
        // Build a combined env map for the child when --scene (cli#229)
        // and/or --screenshot (cli#227) are set. Both flags need to be
        // surfaced as env vars to the spawned game:
        //  - LABELLE_SCENE          (cli#229 runtime scene-override)
        //  - LABELLE_SCREENSHOT_PATH
        //  - LABELLE_SCREENSHOT_AFTER_SEC
        // Loading-controller scripts read LABELLE_SCENE *after*
        // assets.allReady succeeds and call setScene(requested), so
        // asset streaming for large scenes no longer races boot. This
        // is now the ONLY mechanism for `--scene=` — the legacy
        // `.initial_prefab` rewrite was removed (see above).
        // Default the child env to the ZIG_*_CACHE_DIR map (cli#279) so the
        // rebuilt-and-run step still lands the compiler cache in user space.
        var env_map_storage: ?std.process.Environ.Map = null;
        defer if (env_map_storage) |*m| m.deinit();
        var env_map_ptr: ?*const std.process.Environ.Map = zig_env_ptr;
        const has_scene_env = parsed_args.scene_override != null;
        const has_screenshot_env = parsed_args.screenshot_path != null;
        // --headless (and the flags that imply it) surface as
        // LABELLE_HEADLESS=1 plus the optional uncapped/ticks knobs that
        // the sokol desktop backend reads. `parsed_args.headless` is
        // already set true by `--uncapped`/`--ticks`, so this one check
        // covers all three.
        const has_headless_env = parsed_args.headless;
        // --profile surfaces as LABELLE_PROFILE=1, enabling the engine's
        // built-in frame profiler. Independent of --headless.
        const has_profile_env = parsed_args.profile;
        if (has_scene_env or has_screenshot_env or has_headless_env or has_profile_env) {
            var extras: std.ArrayList(runner.EnvKV) = .empty;
            defer extras.deinit(allocator);
            if (parsed_args.scene_override) |scene| {
                try extras.append(allocator, .{ .key = "LABELLE_SCENE", .value = scene });
            }
            var ticks_buf: [32]u8 = undefined;
            if (parsed_args.headless) {
                try extras.append(allocator, .{ .key = "LABELLE_HEADLESS", .value = "1" });
                if (parsed_args.headless_uncapped) {
                    try extras.append(allocator, .{ .key = "LABELLE_HEADLESS_UNCAPPED", .value = "1" });
                }
                if (parsed_args.headless_ticks) |n| {
                    const ticks_str = try std.fmt.bufPrint(&ticks_buf, "{d}", .{n});
                    try extras.append(allocator, .{ .key = "LABELLE_HEADLESS_TICKS", .value = ticks_str });
                }
            }
            if (parsed_args.profile) {
                try extras.append(allocator, .{ .key = "LABELLE_PROFILE", .value = "1" });
            }
            var sec_buf: [32]u8 = undefined;
            if (parsed_args.screenshot_path) |path| {
                try extras.append(allocator, .{ .key = "LABELLE_SCREENSHOT_PATH", .value = path });
                if (parsed_args.screenshot_after_ns) |ns| {
                    const sec_f64 = @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_s);
                    const sec_str = try std.fmt.bufPrint(&sec_buf, "{d:.3}", .{sec_f64});
                    try extras.append(allocator, .{ .key = "LABELLE_SCREENSHOT_AFTER_SEC", .value = sec_str });
                }
                std.debug.print("labelle: screenshot will be written to '{s}'\n", .{path});
            }
            // For a non-docker run, fold the ZIG_*_CACHE_DIR vars in too so
            // both the build and run children share the managed cache. For a
            // docker run there is no managed toolchain, so just add extras.
            env_map_storage = if (parsed_args.docker)
                try runner.buildEnvironWithExtra(allocator, extras.items)
            else
                try runner.buildZigEnv(allocator, extras.items);
            env_map_ptr = &env_map_storage.?;
        }

        // When --docker was used, run the built binary directly instead of
        // calling `zig build run` (local Zig may be broken).
        if (parsed_args.docker) {
            // Cross-compiled binaries can't be run on the host
            if (parsed_args.docker_target) |t| {
                std.debug.print("labelle: cannot run cross-compiled binary (target: {s})\n", .{t});
                std.debug.print("  binary is at: {s}/zig-out/bin/\n", .{target_dir});
                if (reporter) |r| r.finishDone(0); // build succeeded; run skipped
                return;
            }
            // The assembler names the desktop binary after the project
            // (sanitized) so concurrent games are distinguishable to
            // `pgrep` (labelle-assembler#362). Derive the same name here so
            // the docker run path execs the binary by its real on-disk name.
            const exe_name = try util.sanitizeExeName(allocator, parsed.name);
            defer allocator.free(exe_name);
            const bin_path = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "bin", exe_name });
            defer allocator.free(bin_path);
            var run_args: std.ArrayList([]const u8) = .empty;
            defer run_args.deinit(allocator);
            try run_args.append(allocator, bin_path);
            try appendRunForwardedArgs(&run_args, allocator, &parsed_args);
            if (reporter) |r| r.beginPhase(.run, exe_name);
            const run_result = try runner.runZigInheritWithEnv(allocator, project_dir, run_args.items, timeout_ns, env_map_ptr);
            if (run_result != 0) {
                std.debug.print("\nlabelle: process exited with code {d}\n", .{run_result});
            }
            // The game ran: the pipeline is `done` even on a nonzero game
            // exit — the code is carried in the terminal record.
            if (reporter) |r| r.finishDone(run_result);
        } else {
            // Build, then run the game BINARY DIRECTLY rather than via
            // `zig build run`. `zig build run` launches the game in its own
            // child process group, which ESCAPES the --timeout kill: the
            // watchdog signals labelle's direct child (the `zig build`
            // process), the game survives in its separate group, gets
            // reparented to init, and orphans. Run as labelle's own child and
            // the game stays in the process group the watchdog signals, so
            // SIGTERM→SIGKILL actually reaches it. Mirrors the --docker path.
            //
            // Build with no timeout (only the run is time-limited); keep the
            // game's cwd at `target_dir` (a target_dir-relative argv[0]) so
            // saves land exactly where `zig build run` put them.
            // The main compile already ran under the `compile`/`link`
            // phases above; this re-build is a warm-cache no-op, so it
            // stays in the compile/link phase — `run` begins when the game
            // binary is about to spawn.
            const build_result = try runner.runZigInheritWithEnv(allocator, target_dir, zig_args.items, null, env_map_ptr);
            if (build_result != 0) {
                if (reporter) |r| r.finishFailed(build_result, "zig build failed");
                std.debug.print("\nlabelle: build failed (exit {d})\n", .{build_result});
                return;
            }
            // Exe name: the assembler names the desktop exe after the
            // sanitized project (labelle-assembler#362); older generated
            // build.zig still emit `game`. Prefer the project name; fall back
            // to `game` when that binary isn't on disk, so this works both
            // before and after the rename ships. Run it by a target_dir-
            // relative path so the game's cwd stays `target_dir` (saves land
            // where `zig build run` put them). Mirrors the --docker path.
            const sanitized = try util.sanitizeExeName(allocator, parsed.name);
            defer allocator.free(sanitized);
            const sanitized_full = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "bin", sanitized });
            defer allocator.free(sanitized_full);
            const exe_basename: []const u8 = if (util.fileExists(sanitized_full)) sanitized else "game";
            const rel_bin = try std.fs.path.join(allocator, &.{ "zig-out", "bin", exe_basename });
            defer allocator.free(rel_bin);
            var run_args: std.ArrayList([]const u8) = .empty;
            defer run_args.deinit(allocator);
            try run_args.append(allocator, rel_bin);
            try appendRunForwardedArgs(&run_args, allocator, &parsed_args);
            if (reporter) |r| r.beginPhase(.run, exe_basename);
            const run_result = try runner.runZigInheritWithEnv(allocator, target_dir, run_args.items, timeout_ns, env_map_ptr);
            if (run_result != 0) {
                std.debug.print("\nlabelle: process exited with code {d}\n", .{run_result});
            }
            // The game ran: the pipeline is `done` even on a nonzero game
            // exit — the code is carried in the terminal record.
            if (reporter) |r| r.finishDone(run_result);
        }
    }
}

// --- Tests ---

const expect = @import("zspec").expect;

test {
    @import("zspec").runAll(@This());
}

pub const ParseSceneArg = struct {
    pub const with_equals_value = struct {
        test "returns parsed for --scene=main_menu" {
            try expect.equal(parseSceneArg("--scene=main_menu"), .parsed);
        }

        test "returns parsed for --scene=x" {
            try expect.equal(parseSceneArg("--scene=x"), .parsed);
        }
    };

    pub const with_empty_equals = struct {
        test "returns err for --scene=" {
            try expect.equal(parseSceneArg("--scene="), .err);
        }
    };

    pub const bare_flag = struct {
        test "returns needs_next for --scene" {
            try expect.equal(parseSceneArg("--scene"), .needs_next);
        }
    };

    pub const unrelated_flags = struct {
        test "returns not_scene for --timeout=5s" {
            try expect.equal(parseSceneArg("--timeout=5s"), .not_scene);
        }

        test "returns not_scene for --verbose" {
            try expect.equal(parseSceneArg("--verbose"), .not_scene);
        }

        test "returns not_scene for positional arg" {
            try expect.equal(parseSceneArg("mydir"), .not_scene);
        }
    };
};

pub const SceneArgValue = struct {
    test "extracts value from --scene=main_menu" {
        try std.testing.expectEqualStrings("main_menu", sceneArgValue("--scene=main_menu"));
    }

    test "extracts value from --scene=intro" {
        try std.testing.expectEqualStrings("intro", sceneArgValue("--scene=intro"));
    }
};

/// Smoke tests for the full `parseSceneFlag` parser (issue #228).
///
/// `ParseSceneArg` and `SceneArgValue` above test the two lower-level
/// helpers in isolation, but the actual CLI dispatch (`parseDirAndScene`,
/// `parseRunArgs`) goes through `parseSceneFlag`, which combines them
/// and additionally consumes the *next* arg for the space-separated
/// `--scene name` form. This spec exercises that combined path so a
/// refactor of either helper can't silently drop the contract that
/// PR #216 / RFC #565 introduced.
pub const ParseSceneFlagSpec = struct {
    pub const equals_form = struct {
        test "--scene=name sets the override and reports parsed" {
            var iter = testIter("--scene=main_menu");
            defer iter.deinit();
            var scene: ?[]const u8 = null;
            const arg = iter.next().?;
            const result = parseSceneFlag(arg, &iter, &scene, "build");
            try expect.equal(result, .parsed);
            try std.testing.expectEqualStrings("main_menu", scene.?);
        }
    };

    pub const space_form = struct {
        test "--scene name (separate tokens) consumes the next arg" {
            var iter = testIter("--scene main_menu");
            defer iter.deinit();
            var scene: ?[]const u8 = null;
            const arg = iter.next().?;
            const result = parseSceneFlag(arg, &iter, &scene, "build");
            try expect.equal(result, .parsed);
            try std.testing.expectEqualStrings("main_menu", scene.?);
            // The value arg should have been consumed off the iterator.
            try std.testing.expect(iter.next() == null);
        }
    };

    pub const empty_value = struct {
        test "--scene= (empty after equals) returns .err and leaves override null" {
            var iter = testIter("--scene=");
            defer iter.deinit();
            var scene: ?[]const u8 = null;
            const arg = iter.next().?;
            const result = parseSceneFlag(arg, &iter, &scene, "build");
            try expect.equal(result, .err);
            try std.testing.expect(scene == null);
        }
    };

    pub const missing_value = struct {
        test "bare --scene with no following arg returns .err" {
            var iter = testIter("--scene");
            defer iter.deinit();
            var scene: ?[]const u8 = null;
            const arg = iter.next().?;
            const result = parseSceneFlag(arg, &iter, &scene, "build");
            try expect.equal(result, .err);
            try std.testing.expect(scene == null);
        }
    };

    pub const unrelated = struct {
        test "non-scene arg returns .not_scene and leaves override untouched" {
            var iter = testIter("--platform=desktop");
            defer iter.deinit();
            var scene: ?[]const u8 = null;
            const arg = iter.next().?;
            const result = parseSceneFlag(arg, &iter, &scene, "build");
            try expect.equal(result, .not_scene);
            try std.testing.expect(scene == null);
        }
    };
};

/// End-to-end pipeline smoke test for the `--scene` flow.
///
/// Contract as of fix/scene-flag-no-initial-prefab-rewrite:
///   - `--scene=X` does NOT rewrite `cfg.initial_prefab`.
///   - `--scene=X` injects `LABELLE_SCENE=X` into the spawned game's env.
///   - Loading-scene controllers read `engine.requestedScene()` after
///     `assets.allReady` and call `setScene(requested)`.
///
/// Tracked by issue #228 (cli#229 follow-through).
pub const SceneOverridePipelineSpec = struct {
    test "--scene=name does NOT rewrite initial_prefab on an empty config" {
        var iter = testIter("--scene=mymain");
        defer iter.deinit();
        var scene_override: ?[]const u8 = null;
        const arg = iter.next().?;
        try expect.equal(parseSceneFlag(arg, &iter, &scene_override, "build"), .parsed);

        var cfg = project_config.ProjectConfig{ .name = "smoke" };
        cfg.normalizeInitialPrefab();
        // Post-fix: cli does NOT assign scene_override onto cfg.initial_prefab.
        try std.testing.expectEqual(@as(?[]const u8, null), cfg.initial_prefab);
        // The override is still captured for env-var injection downstream.
        try std.testing.expectEqualStrings("mymain", scene_override.?);
    }

    test "--scene name (space form) does NOT rewrite initial_prefab" {
        var iter = testIter("--scene mymain");
        defer iter.deinit();
        var scene_override: ?[]const u8 = null;
        const arg = iter.next().?;
        try expect.equal(parseSceneFlag(arg, &iter, &scene_override, "build"), .parsed);

        var cfg = project_config.ProjectConfig{ .name = "smoke" };
        cfg.normalizeInitialPrefab();
        try std.testing.expectEqual(@as(?[]const u8, null), cfg.initial_prefab);
        try std.testing.expectEqualStrings("mymain", scene_override.?);
    }

    test "legacy initial_scene normalizes; --scene does NOT clobber it" {
        var iter = testIter("--scene=override");
        defer iter.deinit();
        var scene_override: ?[]const u8 = null;
        const arg = iter.next().?;
        try expect.equal(parseSceneFlag(arg, &iter, &scene_override, "build"), .parsed);

        // Fixture simulates a project.labelle that still uses the legacy
        // `.initial_scene` alias. After normalization it should be promoted
        // to `.initial_prefab`. The --scene override must NOT clobber it
        // anymore — it only feeds LABELLE_SCENE downstream.
        var cfg = project_config.ProjectConfig{ .name = "smoke", .initial_scene = "legacy" };
        cfg.normalizeInitialPrefab();
        try std.testing.expectEqualStrings("legacy", cfg.initial_prefab.?);
        try std.testing.expectEqual(@as(?[]const u8, null), cfg.initial_scene);
        try std.testing.expectEqualStrings("override", scene_override.?);
        // Critical: initial_prefab stays "legacy" so loading-gated projects
        // still boot through their loading scene.
        try std.testing.expectEqualStrings("legacy", cfg.initial_prefab.?);
    }

    test "config initial_prefab=\"loading\" stays \"loading\" even with --scene=colony" {
        var iter = testIter("--scene=colony");
        defer iter.deinit();
        var scene_override: ?[]const u8 = null;
        const arg = iter.next().?;
        try expect.equal(parseSceneFlag(arg, &iter, &scene_override, "build"), .parsed);

        // The loading-scene-gate case: project boots into "loading", whose
        // controller reads engine.requestedScene() and transitions to
        // "colony" after assets.allReady. The CLI must NOT rewrite
        // initial_prefab to "colony" — that bypasses the gate and hangs.
        var cfg = project_config.ProjectConfig{ .name = "smoke", .initial_prefab = "loading" };
        cfg.normalizeInitialPrefab();
        try std.testing.expectEqualStrings("loading", cfg.initial_prefab.?);
        try std.testing.expectEqualStrings("colony", scene_override.?);
    }

    test "no --scene flag preserves normalized initial_prefab from config" {
        // No `--scene` on the command line — only normalization runs.
        var iter = testIter("--platform=desktop");
        defer iter.deinit();
        var scene_override: ?[]const u8 = null;
        const arg = iter.next().?;
        try expect.equal(parseSceneFlag(arg, &iter, &scene_override, "build"), .not_scene);

        var cfg = project_config.ProjectConfig{ .name = "smoke", .initial_prefab = "from_config" };
        cfg.normalizeInitialPrefab();
        try std.testing.expectEqualStrings("from_config", cfg.initial_prefab.?);
        try std.testing.expectEqual(@as(?[]const u8, null), scene_override);
    }

    test "empty --scene= aborts the override; initial_prefab untouched" {
        var iter = testIter("--scene=");
        defer iter.deinit();
        var scene_override: ?[]const u8 = null;
        const arg = iter.next().?;
        try expect.equal(parseSceneFlag(arg, &iter, &scene_override, "build"), .err);

        // The CLI bails on .err (returns null from parseDirAndScene / parseRunArgs),
        // so initial_prefab should remain whatever the (normalized) config said.
        var cfg = project_config.ProjectConfig{ .name = "smoke", .initial_prefab = "untouched" };
        cfg.normalizeInitialPrefab();
        try std.testing.expectEqualStrings("untouched", cfg.initial_prefab.?);
        try std.testing.expectEqual(@as(?[]const u8, null), scene_override);
    }

    test "--scene=X feeds LABELLE_SCENE via buildEnvironWithExtra" {
        // Verify the env-var injection path used by the spawn site at
        // cli.zig:~990. This is the canonical mechanism after the fix.
        var iter = testIter("--scene=colony");
        defer iter.deinit();
        var scene_override: ?[]const u8 = null;
        const arg = iter.next().?;
        try expect.equal(parseSceneFlag(arg, &iter, &scene_override, "build"), .parsed);

        const allocator = std.testing.allocator;
        var extras: std.ArrayList(runner.EnvKV) = .empty;
        defer extras.deinit(allocator);
        if (scene_override) |scene| {
            try extras.append(allocator, .{ .key = "LABELLE_SCENE", .value = scene });
        }
        var env_map = try runner.buildEnvironWithExtra(allocator, extras.items);
        defer env_map.deinit();

        const got = env_map.get("LABELLE_SCENE") orelse return error.MissingLabelleScene;
        try std.testing.expectEqualStrings("colony", got);
    }
};

pub const ParseOptimizeFlagSpec = struct {
    pub const valid_modes = struct {
        test "parses all valid modes" {
            inline for (valid_optimize_modes) |mode| {
                var opt: ?[]const u8 = null;
                const arg = "--optimize=" ++ mode;
                try expect.equal(parseOptimizeFlag(arg, &opt, "build"), true);
                try std.testing.expectEqualStrings(mode, opt.?);
            }
        }
    };

    pub const invalid_modes = struct {
        test "returns null for empty value" {
            var opt: ?[]const u8 = null;
            try expect.equal(parseOptimizeFlag("--optimize=", &opt, "build"), null);
        }
        test "returns null for unknown mode" {
            var opt: ?[]const u8 = null;
            try expect.equal(parseOptimizeFlag("--optimize=Fast", &opt, "build"), null);
        }
    };

    pub const not_optimize = struct {
        test "returns false for unrelated flag" {
            var opt: ?[]const u8 = null;
            try expect.equal(parseOptimizeFlag("--platform=wasm", &opt, "build"), false);
        }
        test "returns false for positional arg" {
            var opt: ?[]const u8 = null;
            try expect.equal(parseOptimizeFlag("my-game", &opt, "build"), false);
        }
    };
};

// Surface inline-test specs from the `test` subcommand module so
// `zspec.runAll(@This())` walks into them. Without these re-exports
// zspec only sees the `pub const` namespaces declared directly in
// cli.zig and would skip the test_cmd_mod's nested spec structs.
pub const TestCmdIsSkipDirSpec = test_cmd_mod.IsSkipDirSpec;
pub const TestCmdFileHasTestBlockSpec = test_cmd_mod.FileHasTestBlockSpec;

// Surface the exe-name sanitizer's spec namespace (labelle-assembler#362)
// so `zspec.runAll(@This())` walks into it.
pub const UtilSanitizeExeNameSpec = util.SanitizeExeName;

// Surface audit-command spec namespaces so `zspec.runAll(@This())`
// walks into them. Without these re-exports the audit tests would
// only run via a direct `zig test src/cli/audit.zig`.
pub const AuditStripJsoncToJsonSpec = audit.StripJsoncToJsonSpec;
pub const AuditBasenameWithoutExtSpec = audit.BasenameWithoutExtSpec;
pub const AuditRunAuditOnSpec = audit.RunAuditOnSpec;

// Surface migrate-command spec namespaces so `zspec.runAll(@This())`
// walks into them.
pub const MigrateTransformRootWrapperSpec = migrate.TransformRootWrapperSpec;
pub const MigrateTransformEntitiesRenameSpec = migrate.TransformEntitiesRenameSpec;
pub const MigrateTransformComponentsOnRefSpec = migrate.TransformComponentsOnRefSpec;
pub const MigrateTransformAssetsDeleteSpec = migrate.TransformAssetsDeleteSpec;
pub const MigrateIdempotencySpec = migrate.IdempotencySpec;
pub const MigrateMixedFileSpec = migrate.MixedFileSpec;
pub const MigrateDeleteTopLevelKeyBlockCommentSpec = migrate.DeleteTopLevelKeyBlockCommentSpec;

// Surface the check-command spec namespace so `zspec.runAll(@This())`
// walks into it (mirrors the audit/migrate re-exports above).
pub const CheckParseCheckArgsSpec = check.ParseCheckArgsSpec;

// Surface the build-progress feed specs (cli#284) so
// `zspec.runAll(@This())` walks into them: the phase state machine,
// NDJSON encoding, atomic status-file writes, the fake-build reporter
// pipeline, the std.Progress IPC packet decoder, and `labelle status`
// formatting.
pub const ProgressPhaseMachineSpec = progress.PhaseMachineSpec;
pub const ProgressNdjsonEncodingSpec = progress.NdjsonEncodingSpec;
pub const ProgressAtomicStatusFileSpec = progress.AtomicStatusFileSpec;
pub const ProgressReporterPipelineSpec = progress.ReporterPipelineSpec;
pub const ZigProgressPacketDecodingSpec = @import("cli/zig_progress.zig").PacketDecodingSpec;
pub const StatusFormatHumanSpec = status_mod.FormatHumanSpec;

pub const ParsePlatformValueSpec = struct {
    pub const valid_platforms = struct {
        test "parses desktop" {
            try expect.equal(parsePlatformValue("desktop"), Platform.desktop);
        }
        test "parses wasm" {
            try expect.equal(parsePlatformValue("wasm"), Platform.wasm);
        }
        test "parses ios" {
            try expect.equal(parsePlatformValue("ios"), Platform.ios);
        }
        test "parses android" {
            try expect.equal(parsePlatformValue("android"), Platform.android);
        }
    };

    pub const invalid_platforms = struct {
        test "returns null for empty string" {
            try expect.equal(parsePlatformValue(""), null);
        }
        test "returns null for unknown value" {
            try expect.equal(parsePlatformValue("windows"), null);
        }
    };
};

pub const ResolveAndroidBackendSpec = struct {
    pub const android_capable_backends_kept = struct {
        test "bgfx project keeps bgfx (#252)" {
            try expect.equal(resolveAndroidBackend(.bgfx), Backend.bgfx);
        }
        test "sokol project keeps sokol" {
            try expect.equal(resolveAndroidBackend(.sokol), Backend.sokol);
        }
    };

    pub const non_android_backends_fall_back_to_sokol = struct {
        test "raylib falls back to sokol" {
            try expect.equal(resolveAndroidBackend(.raylib), Backend.sokol);
        }
        test "sdl falls back to sokol" {
            try expect.equal(resolveAndroidBackend(.sdl), Backend.sokol);
        }
        test "wgpu falls back to sokol" {
            try expect.equal(resolveAndroidBackend(.wgpu), Backend.sokol);
        }
        test "null falls back to sokol" {
            try expect.equal(resolveAndroidBackend(.null), Backend.sokol);
        }
    };
};

/// Build an in-memory ArgIterator over a fixed argv-like string for
/// tests of `parseRunArgs`. `parseRunArgs` takes `anytype` so it
/// accepts both the platform `std.process.Args.Iterator` and
/// `std.process.Args.IteratorGeneral` returned here.
///
/// 0.16 moved `std.process.ArgIteratorGeneral` to
/// `std.process.Args.IteratorGeneral`.
fn testIter(line: []const u8) std.process.Args.IteratorGeneral(.{}) {
    return std.process.Args.IteratorGeneral(.{}).init(std.testing.allocator, line) catch unreachable;
}

pub const ParseRunArgsPassthroughSpec = struct {
    pub const no_separator = struct {
        test "empty extras when no `--` token" {
            var iter = testIter("");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            const result = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try std.testing.expectEqualStrings(".", result.dir);
            try expect.equal(pa.extra_count, @as(usize, 0));
        }

        test "scene flag without `--` does not enter passthrough" {
            var iter = testIter("--scene=main");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            const result = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("main", result.scene.?);
            try expect.equal(pa.extra_count, @as(usize, 0));
        }
    };

    pub const single_trailing_arg = struct {
        test "one token after `--` lands in extras" {
            var iter = testIter("-- --preview-mode");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            const result = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try std.testing.expectEqualStrings(".", result.dir);
            try expect.equal(pa.extra_count, @as(usize, 1));
            try std.testing.expectEqualStrings("--preview-mode", pa.extra_args[0]);
        }
    };

    pub const multiple_trailing_args = struct {
        test "multiple tokens after `--` preserved in order" {
            var iter = testIter("-- --preview-mode 127.0.0.1:54321");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            _ = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try expect.equal(pa.extra_count, @as(usize, 2));
            try std.testing.expectEqualStrings("--preview-mode", pa.extra_args[0]);
            try std.testing.expectEqualStrings("127.0.0.1:54321", pa.extra_args[1]);
        }

        test "inner `--` after first `--` is a passthrough token, not a re-trigger" {
            // Once the parser is in passthrough mode it stays there; a
            // second `--` is forwarded verbatim. zig build run uses the
            // first `--` as separator and forwards the rest, so an inner
            // `--` reaches the game unchanged.
            var iter = testIter("-- --foo -- --bar");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            _ = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try expect.equal(pa.extra_count, @as(usize, 3));
            try std.testing.expectEqualStrings("--foo", pa.extra_args[0]);
            try std.testing.expectEqualStrings("--", pa.extra_args[1]);
            try std.testing.expectEqualStrings("--bar", pa.extra_args[2]);
        }
    };

    pub const mixed_labelle_flags_and_passthrough = struct {
        test "labelle flags before `--` consumed, after `--` forwarded" {
            var iter = testIter("mydir --scene=main -- --foo bar");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            const result = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("mydir", result.dir);
            try std.testing.expectEqualStrings("main", result.scene.?);
            try expect.equal(pa.extra_count, @as(usize, 2));
            try std.testing.expectEqualStrings("--foo", pa.extra_args[0]);
            try std.testing.expectEqualStrings("bar", pa.extra_args[1]);
        }

        test "positional dir after `--` is forwarded, not parsed as dir" {
            // After `--` everything is opaque, so a bare word doesn't
            // collide with the project_dir slot.
            var iter = testIter("-- somedir");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            const result = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try std.testing.expectEqualStrings(".", result.dir);
            try expect.equal(pa.extra_count, @as(usize, 1));
            try std.testing.expectEqualStrings("somedir", pa.extra_args[0]);
        }
    };
};

/// Headless perf / CI knobs (`--headless` / `--uncapped` / `--ticks`).
/// These set fields directly on `ParsedArgs`, which the spawn site turns
/// into `LABELLE_HEADLESS` / `LABELLE_HEADLESS_UNCAPPED` /
/// `LABELLE_HEADLESS_TICKS`. `--uncapped` and `--ticks` both imply
/// `--headless`.
pub const ParseHeadlessFlagsSpec = struct {
    pub const headless_alone = struct {
        test "--headless sets headless only" {
            var iter = testIter("--headless");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            _ = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try expect.equal(pa.headless, true);
            try expect.equal(pa.headless_uncapped, false);
            try expect.equal(pa.headless_ticks, @as(?u64, null));
        }
    };

    pub const profile_independent = struct {
        test "--profile sets profile, not headless" {
            var iter = testIter("--profile");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            _ = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try expect.equal(pa.profile, true);
            try expect.equal(pa.headless, false);
        }
    };

    pub const uncapped_implies_headless = struct {
        test "--uncapped sets headless + uncapped" {
            var iter = testIter("--uncapped");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            _ = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try expect.equal(pa.headless, true);
            try expect.equal(pa.headless_uncapped, true);
        }
    };

    pub const ticks_implies_headless = struct {
        test "--ticks=600 sets headless + ticks" {
            var iter = testIter("--ticks=600");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            _ = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try expect.equal(pa.headless, true);
            try expect.equal(pa.headless_ticks, @as(?u64, 600));
        }

        test "--ticks 600 (space form) sets headless + ticks" {
            var iter = testIter("--ticks 600");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            _ = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try expect.equal(pa.headless, true);
            try expect.equal(pa.headless_ticks, @as(?u64, 600));
        }
    };

    pub const composes = struct {
        test "--headless --uncapped --ticks=600 all set" {
            var iter = testIter("--headless --uncapped --ticks=600");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            _ = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try expect.equal(pa.headless, true);
            try expect.equal(pa.headless_uncapped, true);
            try expect.equal(pa.headless_ticks, @as(?u64, 600));
        }
    };

    pub const invalid_ticks = struct {
        test "--ticks=0 is rejected" {
            var iter = testIter("--ticks=0");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            try std.testing.expect(parseRunArgs(&iter, "run", true, &pa) == null);
        }

        test "--ticks=abc is rejected" {
            var iter = testIter("--ticks=abc");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            try std.testing.expect(parseRunArgs(&iter, "run", true, &pa) == null);
        }

        test "--ticks without value is rejected" {
            var iter = testIter("--ticks");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            try std.testing.expect(parseRunArgs(&iter, "run", true, &pa) == null);
        }

        test "--ticks abc (space form) is rejected" {
            var iter = testIter("--ticks abc");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            try std.testing.expect(parseRunArgs(&iter, "run", true, &pa) == null);
        }
    };
};

pub const ParseWasmServeArgsSpec = struct {
    pub const defaults = struct {
        test "no args yields port 8080 and all flags off" {
            var iter = testIter("");
            defer iter.deinit();
            const result = parseWasmServeArgs(&iter) orelse return error.TestFailed;
            try expect.equal(result.port, @as(u16, 8080));
            try expect.equal(result.no_build, false);
            try expect.equal(result.no_open, false);
            try expect.equal(result.progress_mode, progress.Mode.human);
            try std.testing.expectEqualStrings(".", result.dir);
        }
    };

    // cli#284 review follow-up: `wasm serve` runs the same build pipeline,
    // so `--progress=` must parse here too instead of dying in the
    // unknown-flag branch.
    pub const progress_flag = struct {
        test "--progress=json is accepted and sets the mode" {
            var iter = testIter("--progress=json");
            defer iter.deinit();
            const result = parseWasmServeArgs(&iter) orelse return error.TestFailed;
            try expect.equal(result.progress_mode, progress.Mode.json);
        }

        test "--progress=off combines with other flags" {
            var iter = testIter("mygame --port 5000 --progress=off --no-open");
            defer iter.deinit();
            const result = parseWasmServeArgs(&iter) orelse return error.TestFailed;
            try expect.equal(result.progress_mode, progress.Mode.off);
            try expect.equal(result.port, @as(u16, 5000));
            try expect.equal(result.no_open, true);
            try std.testing.expectEqualStrings("mygame", result.dir);
        }

        test "invalid --progress value is rejected" {
            var iter = testIter("--progress=verbose");
            defer iter.deinit();
            try std.testing.expect(parseWasmServeArgs(&iter) == null);
        }
    };

    pub const port_flag = struct {
        test "--port=3000 sets the port" {
            var iter = testIter("--port=3000");
            defer iter.deinit();
            const result = parseWasmServeArgs(&iter) orelse return error.TestFailed;
            try expect.equal(result.port, @as(u16, 3000));
        }

        test "--port 3000 (space form) sets the port" {
            var iter = testIter("--port 3000");
            defer iter.deinit();
            const result = parseWasmServeArgs(&iter) orelse return error.TestFailed;
            try expect.equal(result.port, @as(u16, 3000));
        }

        test "non-numeric --port value is rejected" {
            var iter = testIter("--port abc");
            defer iter.deinit();
            try std.testing.expect(parseWasmServeArgs(&iter) == null);
        }

        test "out-of-range --port value is rejected" {
            var iter = testIter("--port 99999");
            defer iter.deinit();
            try std.testing.expect(parseWasmServeArgs(&iter) == null);
        }

        test "--port 0 is rejected" {
            var iter = testIter("--port 0");
            defer iter.deinit();
            try std.testing.expect(parseWasmServeArgs(&iter) == null);
        }
    };

    pub const boolean_flags = struct {
        test "--no-build sets no_build" {
            var iter = testIter("--no-build");
            defer iter.deinit();
            const result = parseWasmServeArgs(&iter) orelse return error.TestFailed;
            try expect.equal(result.no_build, true);
        }

        test "--no-open sets no_open" {
            var iter = testIter("--no-open");
            defer iter.deinit();
            const result = parseWasmServeArgs(&iter) orelse return error.TestFailed;
            try expect.equal(result.no_open, true);
        }

        test "flags combine with a custom port and dir" {
            var iter = testIter("mygame --port 5000 --no-build --no-open");
            defer iter.deinit();
            const result = parseWasmServeArgs(&iter) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("mygame", result.dir);
            try expect.equal(result.port, @as(u16, 5000));
            try expect.equal(result.no_build, true);
            try expect.equal(result.no_open, true);
        }
    };

    pub const rejects_bad_input = struct {
        test "unknown flag is rejected" {
            var iter = testIter("--watch");
            defer iter.deinit();
            try std.testing.expect(parseWasmServeArgs(&iter) == null);
        }

        test "a second positional arg is rejected" {
            var iter = testIter("dir1 dir2");
            defer iter.deinit();
            try std.testing.expect(parseWasmServeArgs(&iter) == null);
        }
    };
};

pub const AppendRunForwardedArgsSpec = struct {
    test "skips separator when there are no forwarded args" {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(std.testing.allocator);
        var pa = ParsedArgs{ .command = .run };

        try appendRunForwardedArgs(&argv, std.testing.allocator, &pa);
        try expect.equal(argv.items.len, @as(usize, 0));
    }

    test "appends separator and all forwarded args in order" {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(std.testing.allocator);
        var pa = ParsedArgs{ .command = .run };
        try appendExtraArg(&pa, "--preview-mode");
        try appendExtraArg(&pa, "127.0.0.1:54321");

        try appendRunForwardedArgs(&argv, std.testing.allocator, &pa);
        try expect.equal(argv.items.len, @as(usize, 3));
        try std.testing.expectEqualStrings("--", argv.items[0]);
        try std.testing.expectEqualStrings("--preview-mode", argv.items[1]);
        try std.testing.expectEqualStrings("127.0.0.1:54321", argv.items[2]);
    }
};

/// Regression tests for `ProjectConfig.normalizeInitialPrefab()` — the
/// legacy `.initial_scene` → `.initial_prefab` alias promotion introduced
/// in RFC #560 / issue #565.
///
/// Scope: this spec covers normalization in isolation. The `--scene` CLI
/// override contract (which intentionally does NOT rewrite
/// `cfg.initial_prefab` as of cli#229 follow-through) is covered by
/// `SceneOverridePipelineSpec` above.
///
/// Cases:
///  1. Legacy `.initial_scene` is promoted to `.initial_prefab` when the new
///     field is absent.
///  2. `.initial_prefab` wins when both fields are present in the config.
///  3. Neither field set → normalization is a no-op (null stays null).
pub const InitialPrefabNormalizationSpec = struct {
    test "normalizeInitialPrefab promotes legacy initial_scene when initial_prefab is null" {
        var cfg = project_config.ProjectConfig{ .name = "test_project", .initial_scene = "legacy_scene" };
        cfg.normalizeInitialPrefab();
        try std.testing.expectEqualStrings("legacy_scene", cfg.initial_prefab.?);
        try std.testing.expectEqual(@as(?[]const u8, null), cfg.initial_scene);
    }

    test "normalizeInitialPrefab keeps initial_prefab when both fields are set" {
        var cfg = project_config.ProjectConfig{ .name = "test_project", .initial_prefab = "new_prefab", .initial_scene = "legacy_scene" };
        cfg.normalizeInitialPrefab();
        try std.testing.expectEqualStrings("new_prefab", cfg.initial_prefab.?);
        try std.testing.expectEqual(@as(?[]const u8, null), cfg.initial_scene);
    }

    test "normalizeInitialPrefab is a no-op when neither field is set" {
        var cfg = project_config.ProjectConfig{ .name = "test_project" };
        cfg.normalizeInitialPrefab();
        try std.testing.expectEqual(@as(?[]const u8, null), cfg.initial_prefab);
        try std.testing.expectEqual(@as(?[]const u8, null), cfg.initial_scene);
    }
};
