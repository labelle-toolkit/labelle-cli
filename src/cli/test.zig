const std = @import("std");
const config = @import("config.zig");
const runner = @import("runner.zig");

/// Directory names that hold generated, cached, or vendored output
/// rather than user-authored source. We prune them at the iterator
/// level so `labelle test` doesn't recurse into the assembler's
/// emitted build tree (which has its own `zig build test`) or into
/// large dependency caches.
///
/// `.claude` holds Claude Code worktrees (snapshot copies of the
/// project under `.claude/worktrees/<id>/`), which would otherwise
/// double-count every `.zig` file in the tree against stale checkouts.
///
/// `tests/` is the assembler convention (>=0.13.0): files there get
/// wired into the generated `.labelle/<backend>/build.zig`'s `test`
/// step, which we invoke separately after the walk. Running bare
/// `zig test <file>` on them would fail because the test compile
/// unit needs the project's full module graph.
const skip_dirs = [_][]const u8{
    ".labelle",
    "zig-out",
    "zig-cache",
    ".zig-cache",
    ".git",
    ".claude",
    "node_modules",
    "tests",
};

const TestStats = struct {
    files_run: usize = 0,
    files_with_tests: usize = 0,
    files_failed: usize = 0,
};

const usage = "  usage: labelle test [dir] [--verbose] [--no-libs]\n";

/// Run in-file Zig tests across the project's source tree.
///
/// Walks the project directory for `.zig` files, skipping generated
/// and cache directories, then invokes `zig test <file>` on each file
/// that contains a `test` block. Aggregates results and returns a
/// non-zero error on any failure so this is usable from CI.
pub fn cmdTest(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    var project_dir: []const u8 = ".";
    var verbose = false;
    var skip_libs = false;
    var dir_set = false;

    for (cmd_args) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--no-libs")) {
            // Skip the project-tree walk entirely. Useful in CI where a
            // separate job already runs `cd libs/<lib> && zig build test`
            // and the comprehensive `labelle test` job only needs the
            // game-side `.labelle/<backend>_<platform>/` step.
            skip_libs = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("labelle test: unknown flag '{s}'\n", .{arg});
            std.debug.print(usage, .{});
            return error.UnknownFlag;
        } else if (!dir_set) {
            project_dir = arg;
            dir_set = true;
        } else {
            std.debug.print("labelle test: unexpected argument '{s}'\n", .{arg});
            std.debug.print(usage, .{});
            return error.TooManyArguments;
        }
    }

    // Confirm we're in a labelle project. Use the quiet variant so we
    // don't double-print: the inner reader already logs "could not
    // read ..." which would duplicate the friendly hint below.
    var probe_arena = std.heap.ArenaAllocator.init(allocator);
    defer probe_arena.deinit();
    const cfg = config.readProjectConfigQuiet(probe_arena.allocator(), project_dir) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("\n  No project.labelle found in '{s}'.\n\n", .{project_dir});
            std.debug.print("  Run `labelle test` from the root of a labelle project.\n\n", .{});
        }
        // Propagate so CI exits non-zero on a misconfigured invocation.
        return err;
    };

    var stats = TestStats{};
    if (!skip_libs) {
        try discoverAndRun(allocator, project_dir, &stats, verbose);
    }

    // Game-side `tests/` are exercised through an assembler-generated
    // `build.zig`'s `test` step, not via bare `zig test <file>`. The
    // generated build.zig wires the full module graph the exe sees, so
    // test files can `@import` game modules the same way `main.zig` does.
    //
    // Assembler >=0.14.0 emits a backend-agnostic `.labelle/tests/` dir
    // dedicated to the test step; prefer it when present so we don't
    // pull raylib (or whatever backend is active) into the test build.
    // Older assemblers (>=0.13.0, <0.14.0) only emit the exe dir, so
    // fall back to `.labelle/<backend>_<platform>/`. Picking the backend
    // from `project.labelle` (rather than the first dir we find) avoids
    // running stale generations left over from prior backend switches.
    //
    // Probe `tests/build.zig` rather than just the directory so a stale
    // `.labelle/tests/` left behind by a prior 0.14+ generate (e.g. user
    // downgraded their assembler pin to 0.13.x) doesn't get preferred
    // over the still-valid backend dir.
    const tests_build_zig = try std.fs.path.join(allocator, &.{ project_dir, ".labelle", "tests", "build.zig" });
    defer allocator.free(tests_build_zig);
    if (std.Io.Dir.cwd().access(config.globalIo(), tests_build_zig, .{})) |_| {
        try runGeneratedTestStep(allocator, project_dir, "tests", &stats, verbose);
    } else |_| {
        const target_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ @tagName(cfg.backend), @tagName(cfg.platform) });
        defer allocator.free(target_name);
        try runGeneratedTestStep(allocator, project_dir, target_name, &stats, verbose);
    }

    std.debug.print("\nlabelle test: {d} file(s) scanned, {d} ran tests, {d} failed\n", .{
        stats.files_run,
        stats.files_with_tests,
        stats.files_failed,
    });

    // Return an error rather than calling `std.process.exit` so the
    // caller's `defer` blocks (allocator deinit, arena cleanup) run.
    if (stats.files_failed > 0) return error.TestsFailed;
}

/// Open the project root and recursively walk it, pruning skip dirs.
fn discoverAndRun(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    stats: *TestStats,
    verbose: bool,
) !void {
    const io = config.globalIo();
    var root_dir = std.Io.Dir.cwd().openDir(io, project_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("labelle test: could not open '{s}': {any}\n", .{ project_dir, err });
        return error.OpenFailed;
    };
    defer root_dir.close(io);

    var rel_buf: std.ArrayList(u8) = .empty;
    defer rel_buf.deinit(allocator);

    try walkDir(allocator, project_dir, &root_dir, &rel_buf, stats, verbose);
}

/// Recursive directory walker that maintains `rel_buf` as the
/// project-relative path of the entry currently being processed.
/// Prunes `skip_dirs` so the walker never descends into them.
fn walkDir(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    dir: *std.Io.Dir,
    rel_buf: *std.ArrayList(u8),
    stats: *TestStats,
    verbose: bool,
) !void {
    const io = config.globalIo();
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const saved_len = rel_buf.items.len;
        defer rel_buf.shrinkRetainingCapacity(saved_len);

        if (saved_len > 0) try rel_buf.append(allocator, std.fs.path.sep);
        try rel_buf.appendSlice(allocator, entry.name);

        switch (entry.kind) {
            .directory => {
                if (isSkipDir(entry.name)) continue;
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch |err| {
                    std.debug.print("labelle test: could not open '{s}': {any}\n", .{ rel_buf.items, err });
                    continue;
                };
                defer sub.close(io);

                // If the subdir has its own build.zig, it's a
                // self-contained Zig package — defer to `zig build
                // test` there instead of walking its source tree.
                // Bare `zig test <file>` can't reconstruct the
                // module-graph wiring (`--dep`, `--mod`) that
                // standalone test files relying on `@import("<lib>")`
                // need; only the package's build.zig has that.
                if (hasBuildZig(&sub)) {
                    stats.files_with_tests += 1;
                    std.debug.print("  build-test {s}\n", .{rel_buf.items});
                    const ok = try runZigBuildTest(allocator, project_dir, rel_buf.items);
                    if (!ok) {
                        stats.files_failed += 1;
                        std.debug.print("    FAILED: {s} (zig build test)\n", .{rel_buf.items});
                    }
                    continue;
                }

                try walkDir(allocator, project_dir, &sub, rel_buf, stats, verbose);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

                // `rel_buf.items` is reused on the next iteration, but
                // we don't append anything else within this branch, so
                // the slice is valid for the duration of the file ops.
                const rel_path = rel_buf.items;

                const full_path = try std.fs.path.join(allocator, &.{ project_dir, rel_path });
                defer allocator.free(full_path);

                stats.files_run += 1;
                const has_tests = fileHasTestBlock(allocator, full_path) catch |err| {
                    std.debug.print("labelle test: could not read '{s}': {any}\n", .{ rel_path, err });
                    stats.files_failed += 1;
                    continue;
                };
                if (!has_tests) {
                    if (verbose) std.debug.print("  skip {s} (no test blocks)\n", .{rel_path});
                    continue;
                }

                stats.files_with_tests += 1;
                std.debug.print("  test {s}\n", .{rel_path});
                const ok = try runZigTest(allocator, project_dir, rel_path);
                if (!ok) {
                    stats.files_failed += 1;
                    std.debug.print("    FAILED: {s}\n", .{rel_path});
                }
            },
            else => {},
        }
    }
}

/// True when `name` is a top-level directory we never descend into.
fn isSkipDir(name: []const u8) bool {
    for (skip_dirs) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return false;
}

/// Cheap heuristic: scan the source for a `test` keyword followed by
/// either a string literal or a brace, which catches both
/// `test "name" { ... }` and `test { ... }` forms — including the
/// Zig-allowed newline-after-keyword variant. Avoids spawning a
/// `zig test` process for every .zig file in the tree, most of which
/// (components, scripts, hooks) won't have inline tests.
fn fileHasTestBlock(allocator: std.mem.Allocator, path: []const u8) !bool {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);

    var i: usize = 0;
    while (i < bytes.len) {
        const idx = std.mem.indexOfPos(u8, bytes, i, "test") orelse return false;
        const at_word_boundary = idx == 0 or isIdentifierBoundary(bytes[idx - 1]);
        const after = idx + "test".len;
        if (at_word_boundary and after < bytes.len) {
            var j = after;
            while (j < bytes.len and std.ascii.isWhitespace(bytes[j])) : (j += 1) {}
            if (j < bytes.len and (bytes[j] == '{' or bytes[j] == '"')) return true;
        }
        i = idx + 1;
    }
    return false;
}

fn isIdentifierBoundary(c: u8) bool {
    return !(std.ascii.isAlphanumeric(c) or c == '_');
}

/// Run `zig test <rel_path>` from `cwd` with inherited stdio. Running
/// in `cwd` (the project root) means tests that touch relative paths
/// see the same filesystem layout as `zig build run` would. Delegates
/// the spawn/wait dance to `runner.runZigInherit` so all CLI-driven
/// zig invocations share one process-management code path.
fn runZigTest(allocator: std.mem.Allocator, cwd: []const u8, rel_path: []const u8) !bool {
    const code = try runner.runZigInherit(allocator, cwd, &.{ "zig", "test", rel_path }, null);
    return code == 0;
}

/// True when `dir` contains a `build.zig` at its top level.
fn hasBuildZig(dir: *std.Io.Dir) bool {
    dir.access(config.globalIo(), "build.zig", .{}) catch return false;
    return true;
}

/// Run `zig build test` inside `<project_dir>/<rel_path>` so the
/// package's own build script wires up modules, dependencies, and
/// test steps. This is how `libs/<lib>/` test files that use
/// `@import("<lib>")` are exercised.
fn runZigBuildTest(allocator: std.mem.Allocator, project_dir: []const u8, rel_path: []const u8) !bool {
    const sub_cwd = try std.fs.path.join(allocator, &.{ project_dir, rel_path });
    defer allocator.free(sub_cwd);
    const code = try runner.runZigInherit(allocator, sub_cwd, &.{ "zig", "build", "test" }, null);
    return code == 0;
}

/// Run `zig build test` in `<project_dir>/.labelle/<target_name>/`.
/// The generated build.zig there exposes a `test` step (assembler
/// >=0.13.0) that wires every `tests/**/*.zig` file into the same
/// module graph the exe uses. When the directory is missing we print
/// a hint pointing at `labelle generate` and continue — non-fatal so
/// projects without a `tests/` folder still get a clean run.
fn runGeneratedTestStep(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    target_name: []const u8,
    stats: *TestStats,
    verbose: bool,
) !void {
    _ = verbose;
    const rel_path = try std.fs.path.join(allocator, &.{ ".labelle", target_name });
    defer allocator.free(rel_path);

    const abs_path = try std.fs.path.join(allocator, &.{ project_dir, rel_path });
    defer allocator.free(abs_path);

    const io = config.globalIo();
    var sub = std.Io.Dir.cwd().openDir(io, abs_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            const tests_path = try std.fs.path.join(allocator, &.{ project_dir, "tests" });
            defer allocator.free(tests_path);
            if (std.Io.Dir.cwd().access(io, tests_path, .{})) |_| {
                std.debug.print(
                    "  (skipping tests/ — no .labelle/{s}/ found; run `labelle generate` first)\n",
                    .{target_name},
                );
            } else |_| {}
            return;
        },
        else => return err,
    };
    defer sub.close(io);

    if (!hasBuildZig(&sub)) return;

    stats.files_with_tests += 1;
    std.debug.print("  build-test {s}\n", .{rel_path});
    const ok = runZigBuildTest(allocator, project_dir, rel_path) catch |err| {
        std.debug.print("    FAILED: {s} ({any})\n", .{ rel_path, err });
        stats.files_failed += 1;
        return;
    };
    if (!ok) {
        stats.files_failed += 1;
        std.debug.print("    FAILED: {s} (zig build test)\n", .{rel_path});
    }
}

// --- Tests ---
//
// The specs below are surfaced from `cli.zig` via `pub const`
// re-exports so `zspec.runAll(@This())` in the cli.zig test root
// discovers them. We don't add a `test { runAll(@This()) }` block
// here to avoid double-registering the same tests.

const expect = @import("zspec").expect;

pub const IsSkipDirSpec = struct {
    pub const skips = struct {
        test "skips .labelle" {
            try expect.equal(isSkipDir(".labelle"), true);
        }
        test "skips zig-out" {
            try expect.equal(isSkipDir("zig-out"), true);
        }
        test "skips .zig-cache" {
            try expect.equal(isSkipDir(".zig-cache"), true);
        }
        test "skips .git" {
            try expect.equal(isSkipDir(".git"), true);
        }
        test "skips .claude" {
            try expect.equal(isSkipDir(".claude"), true);
        }
        test "skips tests" {
            // Game-side tests/ is delegated to the assembler-generated
            // build.zig's `test` step, not walked file-by-file.
            try expect.equal(isSkipDir("tests"), true);
        }
        test "skips node_modules" {
            try expect.equal(isSkipDir("node_modules"), true);
        }
    };

    pub const keeps = struct {
        test "keeps components" {
            try expect.equal(isSkipDir("components"), false);
        }
        test "keeps scripts" {
            try expect.equal(isSkipDir("scripts"), false);
        }
        test "keeps hooks" {
            try expect.equal(isSkipDir("hooks"), false);
        }
    };
};

pub const FileHasTestBlockSpec = struct {
    pub fn writeAndCheck(contents: []const u8) !bool {
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "x.zig", .data = contents });
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const path = try std.fs.path.join(std.testing.allocator, &.{ buf[0..n], "x.zig" });
        defer std.testing.allocator.free(path);
        return try fileHasTestBlock(std.testing.allocator, path);
    }

    pub const detects = struct {
        test "named test block" {
            try expect.equal(try writeAndCheck("test \"trivial\" { }\n"), true);
        }
        test "anonymous test block" {
            try expect.equal(try writeAndCheck("test {\n    return;\n}\n"), true);
        }
        test "test block after other code" {
            try expect.equal(try writeAndCheck(
                \\const std = @import("std");
                \\pub fn foo() void {}
                \\test "foo works" { }
                \\
            ), true);
        }
        test "newline between keyword and brace" {
            try expect.equal(try writeAndCheck("test\n{\n    return;\n}\n"), true);
        }
    };

    pub const ignores = struct {
        test "no test blocks" {
            try expect.equal(try writeAndCheck(
                \\const std = @import("std");
                \\pub fn foo() void {}
                \\
            ), false);
        }
        test "test substring inside identifier" {
            try expect.equal(try writeAndCheck(
                \\const latest = 1;
                \\const mytest = 2;
                \\
            ), false);
        }
        test "the word test in a comment without a block" {
            try expect.equal(try writeAndCheck("// no test here\n"), false);
        }
    };
};
