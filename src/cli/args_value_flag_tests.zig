//! Unit tests for `args.parseValueFlag`, the one parser behind every
//! value-taking `--<name> <value>` flag (cli#396). Split from
//! args_tests.zig, which is already at its size budget. Surfaced to the
//! test runner via a re-export in cli.zig.
const std = @import("std");
const args = @import("args.zig");

const ParsedArgs = args.ParsedArgs;
const parseRunArgs = args.parseRunArgs;
const parseDirAndScene = args.parseDirAndScene;
const parseValueFlag = args.parseValueFlag;
const classifySeparateValue = args.classifySeparateValue;

fn testIter(line: []const u8) std.process.Args.IteratorGeneral(.{}) {
    return std.process.Args.IteratorGeneral(.{}).init(std.testing.allocator, line) catch unreachable;
}

pub const ValueFlagSpec = struct {
    pub const classify = struct {
        test "a plain token is the value" {
            try std.testing.expectEqual(args.SeparateValue.value, classifySeparateValue("shot.png"));
            // A single dash is not a labelle flag: `-` / `-1` stay values.
            try std.testing.expectEqual(args.SeparateValue.value, classifySeparateValue("-1"));
        }
        test "a token starting with `--` is a flag, including the bare separator" {
            try std.testing.expectEqual(args.SeparateValue.flag, classifySeparateValue("--timeout=60"));
            try std.testing.expectEqual(args.SeparateValue.flag, classifySeparateValue("--headless"));
            try std.testing.expectEqual(args.SeparateValue.flag, classifySeparateValue("--"));
        }
        test "no token and an empty token are told apart" {
            try std.testing.expectEqual(args.SeparateValue.missing, classifySeparateValue(null));
            try std.testing.expectEqual(args.SeparateValue.empty, classifySeparateValue(""));
        }
    };

    pub const parse_value_flag = struct {
        test "the space form refuses a flag-looking next token" {
            var iter = testIter("--timeout=60 after");
            defer iter.deinit();
            try std.testing.expect(parseValueFlag("--screenshot", &iter, "screenshot", "--screenshot s.png", "run") == null);
            // It consumed exactly the rejected token, nothing past it.
            try std.testing.expectEqualStrings("after", iter.next().?);
        }
        test "the `=` form accepts a value that starts with `--`" {
            var iter = testIter("");
            defer iter.deinit();
            const got = parseValueFlag("--screenshot=--odd.png", &iter, "screenshot", "--screenshot s.png", "run") orelse return error.TestFailed;
            try std.testing.expectEqualStrings("--odd.png", got.value);
        }
        test "another flag, or a longer flag sharing the prefix, is skipped untouched" {
            var iter = testIter("next");
            defer iter.deinit();
            try std.testing.expect((parseValueFlag("--screenshots", &iter, "screenshot", "x", "run") orelse return error.TestFailed) == .skip);
            try std.testing.expect((parseValueFlag("--timeout=5s", &iter, "screenshot", "x", "run") orelse return error.TestFailed) == .skip);
            try std.testing.expectEqualStrings("next", iter.next().?);
        }
    };

    /// cli#396 end to end through `parseRunArgs`.
    pub const run_flags = struct {
        test "`--screenshot --timeout=60` is an error, not a file named `--timeout=60`" {
            var iter = testIter("--scene=debug/storage_room --screenshot --timeout=60");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            try std.testing.expect(parseRunArgs(&iter, "run", true, &pa) == null);
        }
        test "`--screenshot <path>` then `--timeout=60`: both parsed" {
            var iter = testIter("--screenshot shot.png --timeout=60");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            const r = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("shot.png", r.screenshot_path.?);
            try std.testing.expectEqual(@as(?u64, 60 * std.time.ns_per_s), r.timeout_ns);
            try std.testing.expect(!pa.timeout_defaulted);
        }
        test "`--screenshot=<path> --timeout 2m`: both parsed" {
            var iter = testIter("--screenshot=shot.png --timeout 2m");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            const r = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("shot.png", r.screenshot_path.?);
            try std.testing.expectEqual(@as(?u64, 2 * std.time.ns_per_min), r.timeout_ns);
        }
        test "`--screenshot=--odd.png` is the escape for a dash-led path" {
            var iter = testIter("--screenshot=--odd.png --headless");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            const r = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try std.testing.expectEqualStrings("--odd.png", r.screenshot_path.?);
            try std.testing.expect(pa.headless);
        }
        test "`--screenshot --` does not swallow the passthrough separator" {
            var iter = testIter("--screenshot -- game-arg");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            try std.testing.expect(parseRunArgs(&iter, "run", true, &pa) == null);
        }
        test "every other space-form value flag of `run` refuses a following flag" {
            const lines = [_][]const u8{
                "--screenshot s.png --after --timeout=60",
                "--timeout --headless",
                "--ticks --headless",
                "--scene --headless",
                "--zig --headless",
            };
            for (lines) |line| {
                var iter = testIter(line);
                defer iter.deinit();
                var pa = ParsedArgs{ .command = .run };
                if (parseRunArgs(&iter, "run", true, &pa) != null) {
                    std.debug.print("accepted: {s}\n", .{line});
                    return error.TestExpectedRejection;
                }
            }
        }
        test "the space forms still take a plain value and keep parsing" {
            var iter = testIter("--after 2s --screenshot s.png --ticks 600 --scene intro --timeout 30s --profile");
            defer iter.deinit();
            var pa = ParsedArgs{ .command = .run };
            const r = parseRunArgs(&iter, "run", true, &pa) orelse return error.TestFailed;
            try std.testing.expectEqual(@as(?u64, 2 * std.time.ns_per_s), r.screenshot_after_ns);
            try std.testing.expectEqualStrings("s.png", r.screenshot_path.?);
            try std.testing.expectEqual(@as(?u64, 600), pa.headless_ticks);
            try std.testing.expectEqualStrings("intro", r.scene.?);
            try std.testing.expectEqual(@as(?u64, 30 * std.time.ns_per_s), r.timeout_ns);
            try std.testing.expect(pa.profile);
        }
    };

    pub const build_flags = struct {
        test "`build --scene --docker` is an error, not a scene named `--docker`" {
            var iter = testIter("--scene --docker");
            defer iter.deinit();
            try std.testing.expect(parseDirAndScene(&iter, "build") == null);
        }
        test "`build --zig --docker` is an error, not a toolchain path" {
            var iter = testIter("--zig --docker");
            defer iter.deinit();
            try std.testing.expect(parseDirAndScene(&iter, "build") == null);
        }
        test "`build --scene intro --docker`: both parsed" {
            var iter = testIter("--scene intro --docker");
            defer iter.deinit();
            const r = parseDirAndScene(&iter, "build") orelse return error.TestFailed;
            try std.testing.expectEqualStrings("intro", r.scene.?);
            try std.testing.expect(r.docker_build);
        }
    };
};
