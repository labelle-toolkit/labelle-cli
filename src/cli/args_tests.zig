//! Unit tests for cli/args.zig, split into a sibling file so neither
//! file exceeds ~1000 lines. Surfaced to the test runner via re-exports
//! in cli.zig.
const std = @import("std");
const project_config = @import("project_config.zig");
const runner = @import("runner.zig");
const progress = @import("progress.zig");
const args = @import("args.zig");

const expect = @import("zspec").expect;

const ParsedArgs = args.ParsedArgs;
const valid_optimize_modes = args.valid_optimize_modes;
const parseSceneArg = args.parseSceneArg;
const sceneArgValue = args.sceneArgValue;
const parseSceneFlag = args.parseSceneFlag;
const parseTargetValue = args.parseTargetValue;
const parseOptimizeFlag = args.parseOptimizeFlag;
const parseRunArgs = args.parseRunArgs;
const parseDirAndScene = args.parseDirAndScene;
const parseBundleArgs = args.parseBundleArgs;
const appendExtraArg = args.appendExtraArg;
const appendRunForwardedArgs = args.appendRunForwardedArgs;

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
            try expect.equal(parseOptimizeFlag("--platform=desktop", &opt, "build"), false);
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

/// `--platform=<t>` values are target NAMES, not enum members (RFC #406
/// phase 3b): the parser checks the identifier shape only, and whether a
/// target exists is decided by the pipeline against the core target and
/// the pinned providers' declarations (`provider_targets.resolve`).
pub const ParsePlatformValueSpec = struct {
    pub const identifier_shaped_values = struct {
        test "the core target passes through unchanged" {
            try std.testing.expectEqualStrings("desktop", parseTargetValue("desktop").?);
        }
        test "any lowercase identifier passes through, known to the CLI or not" {
            try std.testing.expectEqualStrings("probe-target", parseTargetValue("probe-target").?);
            try std.testing.expectEqualStrings("t2_beta", parseTargetValue("t2_beta").?);
        }
        test "the returned slice is the input, not a copy of a table entry" {
            const input = "probe-target";
            try std.testing.expect(parseTargetValue(input).?.ptr == input.ptr);
        }
    };

    pub const rejected_values = struct {
        test "returns null for empty string" {
            try std.testing.expect(parseTargetValue("") == null);
        }
        test "returns null for an uppercase name" {
            try std.testing.expect(parseTargetValue("Windows") == null);
        }
        test "returns null for a value with spaces" {
            try std.testing.expect(parseTargetValue("a b") == null);
        }
        test "returns null for a leading digit or dash" {
            try std.testing.expect(parseTargetValue("1st") == null);
            try std.testing.expect(parseTargetValue("-flag") == null);
        }
        test "returns null for a Windows reserved device name, which is identifier-shaped" {
            // `zig-out/bundle/<t>/` must be creatable on every host.
            for ([_][]const u8{ "con", "nul", "prn", "aux", "com1", "lpt9" }) |device| {
                try std.testing.expect(parseTargetValue(device) == null);
            }
            try std.testing.expectEqualStrings("console", parseTargetValue("console").?);
            try std.testing.expectEqualStrings("com10", parseTargetValue("com10").?);
        }
    };

    pub const through_the_build_parser = struct {
        test "build accepts an unknown identifier and hands it on unresolved" {
            var iter = testIter("--platform=probe-target");
            defer iter.deinit();
            const result = parseDirAndScene(&iter, "build") orelse return error.TestFailed;
            try std.testing.expectEqualStrings("probe-target", result.platform.?);
        }
        test "build rejects a malformed value" {
            var iter = testIter("--platform=Probe");
            defer iter.deinit();
            try std.testing.expect(parseDirAndScene(&iter, "build") == null);
        }
        test "run accepts an unknown identifier too" {
            var parsed = ParsedArgs{ .command = .run };
            var iter = testIter("--platform=probe-target");
            defer iter.deinit();
            const result = parseRunArgs(&iter, "run", true, &parsed) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("probe-target", result.platform.?);
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
    pub const watch_flag = struct {
        test "`run --watch` sets the watch session, off by default" {
            var iter = testIter("--watch --platform=probe-target");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            const result = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try std.testing.expect(pa.run_watch);
            try std.testing.expectEqualStrings("probe-target", result.platform.?);
            var plain_iter = testIter("");
            defer plain_iter.deinit();
            var plain = ParsedArgs{ .command = .run };
            _ = parseRunArgs(&plain_iter, "run", true, &plain) orelse return error.TestFailed;
            try std.testing.expect(!plain.run_watch);
        }
        test "`--watch` after `--` is a game argument, not the flag" {
            var iter = testIter("-- --watch");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            _ = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try std.testing.expect(!pa.run_watch);
            try std.testing.expectEqualStrings("--watch", pa.extra_args[0]);
        }
        test "`--watch --docker` is refused" {
            var iter = testIter("--watch --docker");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            try std.testing.expect(parseRunArgs(&iter, "run", true, &pa) == null);
        }
        test "`--docker --target=<arch>-macos` is refused; Windows stays (cli#471 X3)" {
            {
                var iter = testIter("--docker --target=aarch64-macos");
                defer iter.deinit();
                var pa = ParsedArgs{ .command = .run };
                try std.testing.expect(parseRunArgs(&iter, "run", true, &pa) == null);
            }
            {
                var iter = testIter("--docker --target=x86_64-windows");
                defer iter.deinit();
                var pa = ParsedArgs{ .command = .run };
                const r = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
                try std.testing.expectEqualStrings("x86_64-windows", r.docker_target.?);
            }
            {
                // `generate --docker` generates on the host: never refused.
                var iter = testIter("--docker --target=aarch64-macos");
                defer iter.deinit();
                _ = parseDirAndScene(&iter, "generate") orelse return error.TestFailed;
            }
            {
                var iter = testIter("--docker --target=aarch64-macos.13.0");
                defer iter.deinit();
                try std.testing.expect(parseDirAndScene(&iter, "build") == null);
            }
            {
                // Without --docker, --target is a warned no-op, not a refusal.
                var iter = testIter("--target=aarch64-macos");
                defer iter.deinit();
                var pa = ParsedArgs{ .command = .run };
                _ = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            }
        }
    };

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

        test "explicit run directory remains accepted even when it is only parsed" {
            var iter = testIter("missing-project --headless");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            const result = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("missing-project", result.dir);
            try std.testing.expect(pa.headless);
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

/// `labelle bundle` flag parser (cli#359). Narrower than `build` on
/// purpose — see `parseBundleArgs` for why `--docker`/`--scene` are
/// rejected rather than ignored, and `--platform` selects the target.
pub const ParseBundleArgsSpec = struct {
    pub const defaults = struct {
        test "no args yields cwd project, no optimize, no output or build-number override" {
            var iter = testIter("");
            defer iter.deinit();
            const result = parseBundleArgs(&iter) orelse return error.TestFailed;
            try std.testing.expectEqualStrings(".", result.dir);
            try std.testing.expect(result.optimize == null);
            try std.testing.expect(result.output == null);
            try std.testing.expect(result.build_number == null);
            try expect.equal(result.progress_mode, progress.Mode.human);
        }
    };

    pub const positional_dir = struct {
        test "a bare token is the project dir" {
            var iter = testIter("../my-game");
            defer iter.deinit();
            const result = parseBundleArgs(&iter) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("../my-game", result.dir);
        }

        test "a second bare token is rejected" {
            var iter = testIter("a b");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
        }
    };

    pub const optimize_flag = struct {
        test "--optimize=ReleaseFast is recorded" {
            var iter = testIter("--optimize=ReleaseFast");
            defer iter.deinit();
            const result = parseBundleArgs(&iter) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("ReleaseFast", result.optimize.?);
        }

        test "unknown optimize mode is rejected" {
            var iter = testIter("--optimize=Fast");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
        }
    };

    pub const output_flag = struct {
        test "--output=./dist sets the output dir" {
            var iter = testIter("--output=./dist");
            defer iter.deinit();
            const result = parseBundleArgs(&iter) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("./dist", result.output.?);
        }

        test "--output ./dist (space form) sets the output dir and keeps a trailing project dir" {
            var iter = testIter("--output ./dist ../game");
            defer iter.deinit();
            const result = parseBundleArgs(&iter) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("./dist", result.output.?);
            try std.testing.expectEqualStrings("../game", result.dir);
        }

        test "empty --output value is rejected" {
            var iter = testIter("--output=");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
        }

        test "bare --output with no value is rejected" {
            var iter = testIter("--output");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
        }

        test "a following flag is not swallowed as the --output value" {
            // CodeRabbit on #362: `--output --progress=json` used to create a
            // dir literally named `--progress=json` and drop the flag.
            var iter = testIter("--output --progress=json");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
        }

        test "--output=--weird still allows a directory that starts with --" {
            var iter = testIter("--output=--weird");
            defer iter.deinit();
            const result = parseBundleArgs(&iter) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("--weird", result.output.?);
        }
    };

    /// `--build-number <n>` (cli#363) mirrors `--output`'s value handling
    /// and is validated at parse time so a typo fails before the build.
    pub const build_number_flag = struct {
        test "--build-number=42 pins the build number" {
            var iter = testIter("--build-number=42");
            defer iter.deinit();
            const result = parseBundleArgs(&iter) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("42", result.build_number.?);
        }

        test "--build-number 1.2.3 (space form) accepts a dotted value and keeps a trailing project dir" {
            var iter = testIter("--build-number 1.2.3 ../game");
            defer iter.deinit();
            const result = parseBundleArgs(&iter) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("1.2.3", result.build_number.?);
            try std.testing.expectEqualStrings("../game", result.dir);
        }

        test "no --build-number leaves it null (the derived rule decides)" {
            var iter = testIter("--output ./dist");
            defer iter.deinit();
            const result = parseBundleArgs(&iter) orelse return error.TestFailed;
            try std.testing.expect(result.build_number == null);
        }

        test "empty --build-number value is rejected" {
            var iter = testIter("--build-number=");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
        }

        test "bare --build-number with no value is rejected" {
            var iter = testIter("--build-number");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
        }

        test "a following flag is not swallowed as the --build-number value" {
            var iter = testIter("--build-number --progress=json");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
        }

        test "zero is rejected: Apple needs a positive first component" {
            var iter = testIter("--build-number 0");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
        }

        test "a negative value is rejected (not mistaken for a flag either)" {
            var iter = testIter("--build-number -1");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
        }

        test "letters are rejected" {
            var iter = testIter("--build-number=abc");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
        }

        test "a trailing dot is rejected" {
            var iter = testIter("--build-number=1.2.");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
        }

        test "a fourth component is rejected" {
            var iter = testIter("--build-number=1.2.3.4");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
        }

        test "a first component over 4 digits is rejected (Apple's limit)" {
            var iter = testIter("--build-number=10000");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
        }

        test "a second or third component over 2 digits is rejected (Apple's limit)" {
            var iter = testIter("--build-number=1.100");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
            var iter2 = testIter("--build-number 1.2.100");
            defer iter2.deinit();
            try std.testing.expect(parseBundleArgs(&iter2) == null);
        }

        test "9999.99.99, the largest Apple accepts, is accepted" {
            var iter = testIter("--build-number=9999.99.99");
            defer iter.deinit();
            const result = parseBundleArgs(&iter) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("9999.99.99", result.build_number.?);
        }
    };

    pub const progress_flag = struct {
        test "--progress=json is recorded" {
            var iter = testIter("--progress=json");
            defer iter.deinit();
            const result = parseBundleArgs(&iter) orelse return error.TestFailed;
            try expect.equal(result.progress_mode, progress.Mode.json);
        }
    };

    /// `--platform=<t>` (RFC #406 phase 3b): the target to bundle. Shape
    /// only here; the pipeline resolves it and requires a `replace` hook on
    /// `bundle` for a provider target.
    pub const platform_flag = struct {
        test "--platform=<t> selects the target" {
            var iter = testIter("--platform=probe-target");
            defer iter.deinit();
            const result = parseBundleArgs(&iter) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("probe-target", result.platform.?);
        }

        test "--platform <t> (separate value) is accepted" {
            var iter = testIter("--platform probe-target");
            defer iter.deinit();
            const result = parseBundleArgs(&iter) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("probe-target", result.platform.?);
        }

        test "absent, the project's declared platform is bundled" {
            var iter = testIter("--optimize=ReleaseFast");
            defer iter.deinit();
            const result = parseBundleArgs(&iter) orelse return error.TestFailed;
            try std.testing.expect(result.platform == null);
        }

        test "a malformed target is a usage error" {
            var iter = testIter("--platform=Probe");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
        }

        test "--platform without a value is a usage error" {
            var iter = testIter("--platform");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
        }

        test "a following flag is not the value" {
            var iter = testIter("--platform --progress=json");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
        }

        test "composes with the other bundle flags" {
            var iter = testIter("../game --platform=probe-target --output ./dist --progress=off");
            defer iter.deinit();
            const result = parseBundleArgs(&iter) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("../game", result.dir);
            try std.testing.expectEqualStrings("probe-target", result.platform.?);
            try std.testing.expectEqualStrings("./dist", result.output.?);
            try expect.equal(result.progress_mode, progress.Mode.off);
        }
    };

    pub const rejected_flags = struct {
        test "--docker is not a bundle flag" {
            var iter = testIter("--docker");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
        }

        test "any unknown -- flag is rejected" {
            var iter = testIter("--bogus");
            defer iter.deinit();
            try std.testing.expect(parseBundleArgs(&iter) == null);
        }
    };
};

/// `--linux-desktop` on `parseDirAndScene` (cli#359): accepted by `build`,
/// refused by `generate` (nothing to describe without an exe), default off.
pub const ParseDirAndSceneLinuxDesktopSpec = struct {
    test "build accepts --linux-desktop and records it" {
        var iter = testIter("--linux-desktop ../my-game");
        defer iter.deinit();
        const result = parseDirAndScene(&iter, "build") orelse return error.TestFailed;
        try std.testing.expect(result.linux_desktop);
        try std.testing.expectEqualStrings("../my-game", result.dir);
    }

    test "build without the flag leaves it off" {
        var iter = testIter("--optimize=ReleaseFast");
        defer iter.deinit();
        const result = parseDirAndScene(&iter, "build") orelse return error.TestFailed;
        try std.testing.expect(!result.linux_desktop);
        try std.testing.expectEqualStrings("ReleaseFast", result.optimize.?);
    }

    test "generate refuses --linux-desktop" {
        var iter = testIter("--linux-desktop");
        defer iter.deinit();
        try std.testing.expect(parseDirAndScene(&iter, "generate") == null);
    }

    test "the flag composes with the other build flags" {
        var iter = testIter("--platform=desktop --linux-desktop --bake");
        defer iter.deinit();
        const result = parseDirAndScene(&iter, "build") orelse return error.TestFailed;
        try std.testing.expect(result.linux_desktop);
        try std.testing.expect(result.bake);
        try std.testing.expectEqualStrings("desktop", result.platform.?);
    }
};

/// `--allow-older-cli` (#353): the stale-CLI lock gate's escape hatch has
/// to be ACCEPTED by the build-command parsers, otherwise the flag the
/// error message advertises would itself be an "unknown flag" error.
pub const AllowOlderCliFlagSpec = struct {
    test "generate accepts it" {
        var iter = testIter("--allow-older-cli");
        defer iter.deinit();
        const result = parseDirAndScene(&iter, "generate") orelse return error.TestFailed;
        try std.testing.expect(result.allow_older_cli);
    }

    test "build accepts it, and it composes with the other build flags" {
        var iter = testIter("--platform=desktop --allow-older-cli --optimize=ReleaseFast");
        defer iter.deinit();
        const result = parseDirAndScene(&iter, "build") orelse return error.TestFailed;
        try std.testing.expect(result.allow_older_cli);
        try std.testing.expectEqualStrings("desktop", result.platform.?);
        try std.testing.expectEqualStrings("ReleaseFast", result.optimize.?);
    }

    test "build defaults it off" {
        var iter = testIter("--optimize=ReleaseFast");
        defer iter.deinit();
        const result = parseDirAndScene(&iter, "build") orelse return error.TestFailed;
        try std.testing.expect(!result.allow_older_cli);
    }

    test "a positional dir still parses alongside it" {
        var iter = testIter("--allow-older-cli ../my-game");
        defer iter.deinit();
        const result = parseDirAndScene(&iter, "build") orelse return error.TestFailed;
        try std.testing.expect(result.allow_older_cli);
        try std.testing.expectEqualStrings("../my-game", result.dir);
    }

    test "run accepts it and records it on ParsedArgs" {
        var iter = testIter("--allow-older-cli --timeout=30s");
        defer iter.deinit();
        var pa = ParsedArgs{ .command = .run };
        const result = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
        try std.testing.expect(pa.allow_older_cli);
        try std.testing.expect(result.timeout_ns != null);
    }

    test "run defaults it off, and a game arg after `--` is NOT the flag" {
        var iter = testIter("-- --allow-older-cli");
        defer iter.deinit();
        var pa = ParsedArgs{ .command = .run };
        _ = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
        try std.testing.expect(!pa.allow_older_cli);
        try expect.equal(pa.extra_count, @as(usize, 1));
        try std.testing.expectEqualStrings("--allow-older-cli", pa.extra_args[0]);
    }
};

/// cli#485: `labelle run --headless` gets a default run-time budget,
/// carried in the same `timeout_ns` an explicit `--timeout` sets. Under
/// `zig build test` the CLI's environ is empty, so the test-only override
/// is never set here and the default is `headless_default_timeout_ns`.
pub const HeadlessDefaultTimeoutSpec = struct {
    fn parse(line: []const u8, pa: *ParsedArgs) !?u64 {
        var iter = testIter(line);
        defer iter.deinit();
        const result = parseRunArgs(&iter, "run", true, pa) orelse return error.TestFailed;
        return result.timeout_ns;
    }

    test "a headless run with no --timeout gets the default, marked as the default" {
        for ([_][]const u8{ "--headless", "--uncapped", "--ticks=600" }) |line| {
            var pa = ParsedArgs{ .command = .run };
            try expect.equal(try parse(line, &pa), @as(?u64, args.headless_default_timeout_ns));
            try std.testing.expect(pa.timeout_defaulted);
        }
        try expect.equal(args.headless_default_timeout_ns, 5 * std.time.ns_per_min);
    }

    test "an explicit --timeout wins, in either position and form" {
        for ([_][]const u8{ "--headless --timeout=30m", "--timeout=30m --headless", "--headless --timeout 30m" }) |line| {
            var pa = ParsedArgs{ .command = .run };
            try expect.equal(try parse(line, &pa), @as(?u64, 30 * std.time.ns_per_min));
            try std.testing.expect(!pa.timeout_defaulted);
        }
    }

    test "--timeout=0 and --timeout=none opt out: no watchdog at all" {
        for ([_][]const u8{ "--headless --timeout=0", "--headless --timeout=none", "--headless --timeout 0s", "--timeout=0" }) |line| {
            var pa = ParsedArgs{ .command = .run };
            try expect.equal(try parse(line, &pa), @as(?u64, null));
            try std.testing.expect(!pa.timeout_defaulted);
        }
    }

    test "a non-headless run is unchanged: no timeout unless one is given" {
        var pa = ParsedArgs{ .command = .run };
        try expect.equal(try parse("--scene=main", &pa), @as(?u64, null));
        try std.testing.expect(!pa.timeout_defaulted);
        var pb = ParsedArgs{ .command = .run };
        try expect.equal(try parse("--timeout=30s", &pb), @as(?u64, 30 * std.time.ns_per_s));
        try std.testing.expect(!pb.timeout_defaulted);
    }

    test "an invalid --timeout value is still refused" {
        var iter = testIter("--headless --timeout=soon");
        defer iter.deinit();
        var pa = ParsedArgs{ .command = .run };
        try std.testing.expect(parseRunArgs(&iter, "run", true, &pa) == null);
    }

    test "resolveRunTimeout: the default is the only thing a headless, flagless run gets" {
        const d: u64 = 2 * std.time.ns_per_s;
        const defaulted = args.resolveRunTimeout(null, false, true, d);
        try expect.equal(defaulted.timeout_ns, @as(?u64, d));
        try std.testing.expect(defaulted.defaulted);
        try expect.equal(args.resolveRunTimeout(7, true, true, d).timeout_ns, @as(?u64, 7));
        try expect.equal(args.resolveRunTimeout(null, true, true, d).timeout_ns, @as(?u64, null));
        try expect.equal(args.resolveRunTimeout(null, false, false, d).timeout_ns, @as(?u64, null));
    }
};
