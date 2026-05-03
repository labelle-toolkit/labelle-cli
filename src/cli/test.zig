const std = @import("std");
const config = @import("config.zig");

/// Directories that hold generated, cached, or vendored output rather
/// than user-authored source. We skip them when discovering test files
/// so that `labelle test` doesn't try to run `zig test` against the
/// assembler's emitted build tree (which has its own `zig build test`)
/// or against pulled-in dependency caches.
const skip_dirs = [_][]const u8{
    ".labelle",
    "zig-out",
    "zig-cache",
    ".zig-cache",
    ".git",
    "node_modules",
};

const TestStats = struct {
    files_run: usize = 0,
    files_with_tests: usize = 0,
    files_failed: usize = 0,
};

/// Run in-file Zig tests across the project's source tree.
///
/// Walks the project directory for `.zig` files, skipping generated
/// and cache directories, then invokes `zig test <file>` on each file
/// that contains a `test` block. Aggregates results and exits non-zero
/// if any file fails so this is usable from CI.
pub fn cmdTest(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    var project_dir: []const u8 = ".";
    var verbose = false;
    var dir_set = false;

    for (cmd_args) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("labelle test: unknown flag '{s}'\n", .{arg});
            std.debug.print("  usage: labelle test [dir] [--verbose]\n", .{});
            return error.UnknownFlag;
        } else if (!dir_set) {
            project_dir = arg;
            dir_set = true;
        } else {
            std.debug.print("labelle test: unexpected argument '{s}'\n", .{arg});
            return error.TooManyArguments;
        }
    }

    // Confirm we're in a labelle project so users running `labelle test`
    // outside of one get a familiar error rather than an empty pass.
    var probe_arena = std.heap.ArenaAllocator.init(allocator);
    defer probe_arena.deinit();
    _ = config.readProjectConfig(probe_arena.allocator(), project_dir) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("\n  No project.labelle found in '{s}'.\n\n", .{project_dir});
            std.debug.print("  Run `labelle test` from the root of a labelle project.\n\n", .{});
            return;
        }
        return err;
    };

    var stats = TestStats{};
    try discoverAndRun(allocator, project_dir, &stats, verbose);

    std.debug.print("\nlabelle test: {d} file(s) scanned, {d} ran tests, {d} failed\n", .{
        stats.files_run,
        stats.files_with_tests,
        stats.files_failed,
    });

    if (stats.files_failed > 0) {
        std.process.exit(1);
    }
}

/// Walk `root` recursively, invoking `zig test` on each `.zig` file
/// that declares at least one `test` block. Skips entries from `skip_dirs`.
fn discoverAndRun(
    allocator: std.mem.Allocator,
    root: []const u8,
    stats: *TestStats,
    verbose: bool,
) !void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |err| {
        std.debug.print("labelle test: could not open '{s}': {any}\n", .{ root, err });
        return error.OpenFailed;
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (shouldSkipPath(entry.path)) continue;

        const rel_path = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(rel_path);

        stats.files_run += 1;

        const has_tests = fileHasTestBlock(allocator, rel_path) catch |err| {
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
        const ok = try runZigTest(allocator, rel_path);
        if (!ok) {
            stats.files_failed += 1;
            std.debug.print("    FAILED: {s}\n", .{rel_path});
        }
    }
}

/// Return true if `rel_path` (a forward-slash or os-sep separated
/// relative path produced by `Dir.Walker`) starts with a directory we
/// want to skip — generated output, cache, vendored deps, etc.
fn shouldSkipPath(rel_path: []const u8) bool {
    var iter = std.mem.splitAny(u8, rel_path, "/\\");
    while (iter.next()) |segment| {
        if (segment.len == 0) continue;
        for (skip_dirs) |skip| {
            if (std.mem.eql(u8, segment, skip)) return true;
        }
    }
    return false;
}

/// Cheap heuristic: scan the source for a `test` keyword followed by
/// either a string literal or a brace, which catches both
/// `test "name" { ... }` and `test { ... }` forms. Avoids spawning a
/// `zig test` process for every .zig file in the tree, most of which
/// (components, scripts, hooks) won't have inline tests.
fn fileHasTestBlock(allocator: std.mem.Allocator, path: []const u8) !bool {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024);
    defer allocator.free(bytes);

    var i: usize = 0;
    while (i < bytes.len) {
        const idx = std.mem.indexOfPos(u8, bytes, i, "test") orelse return false;
        // Must be at start-of-line or preceded by whitespace so we don't
        // match identifiers like `latest` or `mytest`.
        const at_word_boundary = idx == 0 or isIdentifierBoundary(bytes[idx - 1]);
        const after = idx + "test".len;
        if (at_word_boundary and after < bytes.len) {
            // Skip whitespace after the keyword.
            var j = after;
            while (j < bytes.len and (bytes[j] == ' ' or bytes[j] == '\t')) : (j += 1) {}
            if (j < bytes.len and (bytes[j] == '{' or bytes[j] == '"')) return true;
        }
        i = idx + 1;
    }
    return false;
}

fn isIdentifierBoundary(c: u8) bool {
    return !(std.ascii.isAlphanumeric(c) or c == '_');
}

/// Run `zig test <path>` with inherited stdio. Returns true on a clean
/// (exit 0) run, false otherwise.
fn runZigTest(allocator: std.mem.Allocator, path: []const u8) !bool {
    var child: std.process.Child = .init(&.{ "zig", "test", path }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

// --- Tests ---

const expect = @import("zspec").expect;

test {
    @import("zspec").runAll(@This());
}

pub const ShouldSkipPathSpec = struct {
    pub const skips = struct {
        test "skips .labelle subtree" {
            try expect.equal(shouldSkipPath(".labelle/sokol_desktop/build.zig"), true);
        }
        test "skips zig-out subtree" {
            try expect.equal(shouldSkipPath("zig-out/bin/foo.zig"), true);
        }
        test "skips nested .zig-cache" {
            try expect.equal(shouldSkipPath("subdir/.zig-cache/o/x.zig"), true);
        }
        test "skips .git tree" {
            try expect.equal(shouldSkipPath(".git/objects/x.zig"), true);
        }
    };

    pub const keeps = struct {
        test "keeps components" {
            try expect.equal(shouldSkipPath("components/player.zig"), false);
        }
        test "keeps scripts/playing" {
            try expect.equal(shouldSkipPath("scripts/playing/move.zig"), false);
        }
        test "keeps top-level zig file" {
            try expect.equal(shouldSkipPath("util.zig"), false);
        }
    };
};

pub const FileHasTestBlockSpec = struct {
    fn writeAndCheck(contents: []const u8) !bool {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const file = try tmp.dir.createFile("x.zig", .{});
        try file.writeAll(contents);
        file.close();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_path = try tmp.dir.realpath(".", &buf);
        const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "x.zig" });
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
