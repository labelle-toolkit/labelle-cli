//! Argument parsing for the labelle CLI, extracted from cli.zig so
//! neither file exceeds ~1000 lines. Holds the Command enum, the
//! ParsedArgs/WasmServeArgs/WasmExportArgs result structs, and the
//! parse*/collect*/append* helpers. Behavior is unchanged from when
//! these lived in cli.zig. Unit tests live in the sibling
//! args_tests.zig, surfaced to the runner via re-exports in cli.zig.
const std = @import("std");
const project_config = @import("project_config.zig");
const util = @import("util.zig");
const progress = @import("progress.zig");
const export_mod = @import("export.zig");
const zig_toolchain = @import("zig_toolchain.zig");
const emsdk_toolchain = @import("emsdk_toolchain.zig");

pub const Command = enum { generate, build, run, init_cmd, add_cmd, install_cmd, upgrade_cmd, update_cmd, clean_cmd, ios_cmd, android_cmd, wasm_cmd, help_cmd, version, targets, assembler_cmd, test_cmd, pack_cmd, astc_cmd, audit_cmd, migrate_cmd, doctor_cmd, check_cmd, plugins_cmd, toolchain_cmd, status_cmd };

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
pub fn resolveAndroidBackend(project_backend: Backend) Backend {
    return switch (project_backend) {
        .sokol, .bgfx => project_backend,
        .raylib, .sdl, .wgpu, .null => .sokol,
    };
}

pub const ParsedArgs = struct {
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
    // `wasm serve --watch` (cli#208): rebuild + live-reload on source change.
    serve_watch: bool = false,
    // `wasm export` options. `wasm_export` selects the export action of
    // the shared `wasm_cmd`; the rest configure packaging. `serve_no_build`
    // (above) is reused as the shared "skip build, package existing output"
    // flag for both `wasm serve --no-build` and `wasm export --no-build`.
    wasm_export: bool = false,
    export_output: []const u8 = "release",
    export_zip: bool = false,
    export_pkg_platform: export_mod.Platform = .none,
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
    // the terminal — `human` (default; spinner during compile/link plus
    // slow "still working" heartbeat lines during resolve/generate, on TTY
    // stderr), `json`
    // (NDJSON records on stdout for studio/CI), or `off`. The live status
    // file `.labelle/<target>/.build-progress.json` is written in every
    // mode (that's what `labelle status` reads).
    progress_mode: progress.Mode = .human,
};

/// Parsed `wasm serve` flags. Returned by `parseWasmServeArgs`; `null`
/// signals a parse error (the helper has already printed a message).
pub const WasmServeArgs = struct {
    dir: []const u8 = ".",
    port: u16 = 8080,
    no_build: bool = false,
    no_open: bool = false,
    // `--watch` (cli#208): after the initial build, watch the project
    // source tree and re-run generate+build on change, then push a live
    // reload to connected browsers. Mutually exclusive with `--no-build`
    // (there's no build pipeline to re-run in the skip-build path).
    watch: bool = false,
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
pub fn parseWasmServeArgs(args: anytype) ?WasmServeArgs {
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
        } else if (std.mem.eql(u8, arg, "--watch")) {
            result.watch = true;
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
    if (result.watch and result.no_build) {
        std.debug.print("labelle wasm serve: --watch cannot be combined with --no-build " ++
            "(there's no build pipeline to re-run)\n", .{});
        return null;
    }
    return result;
}

/// Parsed `wasm export` flags. Returned by `parseWasmExportArgs`; `null`
/// signals a parse error (the helper has already printed a message).
pub const WasmExportArgs = struct {
    dir: []const u8 = ".",
    output: []const u8 = "release",
    zip: bool = false,
    no_build: bool = false,
    pkg_platform: export_mod.Platform = .none,
    progress_mode: progress.Mode = .human,
};

/// Parse the flags of `labelle wasm export [dir] [--output <dir>]
/// [--zip] [--platform <itch|github-pages>] [--no-build]
/// [--progress=<m>]`. `args` is `anytype` so tests can drive it with an
/// in-memory `Args.IteratorGeneral`, mirroring `parseWasmServeArgs`.
pub fn parseWasmExportArgs(args: anytype) ?WasmExportArgs {
    var result = WasmExportArgs{};
    var dir_set = false;

    while (args.next()) |arg| {
        // Tri-state progress idiom shared with parseWasmServeArgs.
        if (parseProgressFlag(arg, &result.progress_mode, "wasm export")) |consumed| {
            if (consumed) continue;
        } else return null;
        if (std.mem.eql(u8, arg, "--zip")) {
            result.zip = true;
        } else if (std.mem.eql(u8, arg, "--no-build")) {
            result.no_build = true;
        } else if (std.mem.startsWith(u8, arg, "--output=") or std.mem.eql(u8, arg, "--output")) {
            const val = if (std.mem.eql(u8, arg, "--output"))
                (args.next() orelse {
                    std.debug.print("labelle wasm export: --output requires a value (e.g. --output ./release)\n", .{});
                    return null;
                })
            else
                arg["--output=".len..];
            if (val.len == 0) {
                std.debug.print("labelle wasm export: --output requires a non-empty directory\n", .{});
                return null;
            }
            result.output = val;
        } else if (std.mem.startsWith(u8, arg, "--platform=") or std.mem.eql(u8, arg, "--platform")) {
            const val = if (std.mem.eql(u8, arg, "--platform"))
                (args.next() orelse {
                    std.debug.print("labelle wasm export: --platform requires a value (itch | github-pages)\n", .{});
                    return null;
                })
            else
                arg["--platform=".len..];
            result.pkg_platform = export_mod.parsePlatform(val) orelse {
                std.debug.print("labelle wasm export: unknown --platform '{s}' (expected itch | github-pages)\n", .{val});
                return null;
            };
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("labelle wasm export: unknown flag '{s}'\n", .{arg});
            return null;
        } else {
            if (dir_set) {
                std.debug.print("labelle wasm export: unexpected argument '{s}'\n", .{arg});
                return null;
            }
            result.dir = arg;
            dir_set = true;
        }
    }
    return result;
}

/// Parse a --platform=<value> string into a Platform enum, or null if invalid.
pub fn parsePlatformValue(val: []const u8) ?Platform {
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

/// Parse [dir], --scene, --platform, --optimize, --progress, --docker, and --target flags for generate/build commands.
pub fn parseDirAndScene(args: *std.process.Args.Iterator, cmd_name: []const u8) ?struct { dir: []const u8, scene: ?[]const u8, platform: ?Platform, optimize: ?[]const u8, docker_build: bool, docker_target: ?[]const u8, bake: bool, progress_mode: progress.Mode } {
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
pub fn parseRunArgs(args: anytype, cmd_name: []const u8, allow_dir: bool, parsed_args: *ParsedArgs) ?struct { dir: []const u8, scene: ?[]const u8, timeout_ns: ?u64, platform: ?Platform, optimize: ?[]const u8, docker_build: bool, docker_target: ?[]const u8, bake: bool, screenshot_path: ?[]const u8, screenshot_after_ns: ?u64 } {
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
