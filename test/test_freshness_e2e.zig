//! Subprocess-level e2e for `labelle test` freshness (labelle-assembler#722).
//!
//! `labelle test` used to build whatever was already staged under
//! `.labelle/` — a SNAPSHOT of the project from the last `generate`. Test
//! discovery is baked into that snapshot on every OS, and where the staged
//! dirs are copies (Windows with neither symlink privilege nor a junction)
//! so is every source edit. Either way: `0 failed` for code that never ran.
//!
//! This drives the REAL built CLI on a headless (`null` backend) fixture and
//! runs ONLY `labelle test` between edits — never `generate`/`build`/`run`:
//!
//!   1. a passing test                                → exit 0
//!   2. edit it to fail                               → nonzero
//!   3. repair it                                     → 0
//!   4. ADD a new failing test file                   → nonzero (discovery)
//!   5. delete it                                     → 0 (no orphan)
//!   6. RENAME the test file                          → 0 (no stale import)
//!   7. staged dirs replaced by COPIES, then change a
//!      script the test imports                       → nonzero (transitive
//!                                                      freshness, copy mode)
//!   8. make `generate` fail while a previously
//!      passing tree exists                           → nonzero, and the old
//!                                                      tree is NOT run
//!
//! Opt-in like the other e2es (LABELLE_E2E_DEPS + LABELLE_ASSEMBLER, plus a
//! `labelle-null` sibling). Run alone with `zig build test-e2e-fresh`.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const io = std.testing.io;

fn envOpt(a: Allocator, name: []const u8) !?[]u8 {
    return std.process.Environ.getAlloc(std.testing.environ, a, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing, error.InvalidWtf8 => null,
        else => err,
    };
}

const passing_test =
    \\const std = @import("std");
    \\const script = @import("../scripts/playing/10_limit.zig");
    \\test "the limit is what the test expects" {
    \\    try std.testing.expectEqual(@as(u32, 3), script.limit);
    \\}
    \\
;
const failing_test =
    \\const std = @import("std");
    \\test "the limit is what the test expects" {
    \\    try std.testing.expect(false); // CANARY
    \\}
    \\
;
const new_failing_test =
    \\const std = @import("std");
    \\test "a test file added after the last generate" {
    \\    try std.testing.expect(false);
    \\}
    \\
;

fn scriptSource(comptime limit: []const u8) []const u8 {
    return "pub const game_states = .{\"playing\"};\n" ++
        "pub const limit: u32 = " ++ limit ++ ";\n" ++
        "pub fn tick(game: anytype, state: anytype, _: anytype, dt: f32) void {\n" ++
        "    _ = game;\n    _ = state;\n    _ = dt;\n}\n";
}

const Fixture = struct {
    a: Allocator,
    cli_bin: []const u8,
    project_dir: []const u8,
    runs: usize = 0,

    const Result = struct { code: ?u8, log: []const u8 };

    /// `labelle test <project> --no-libs`, stderr+stdout captured.
    fn labelleTest(self: *Fixture) !Result {
        self.runs += 1;
        const log_path = try std.fmt.allocPrint(self.a, "{s}/labelle-test-{d}.log", .{ self.project_dir, self.runs });
        const log_file = try std.Io.Dir.cwd().createFile(io, log_path, .{});
        var child = try std.process.spawn(io, .{
            .argv = &.{ self.cli_bin, "test", self.project_dir, "--no-libs" },
            .cwd = .{ .path = self.project_dir },
            .stdin = .ignore,
            .stdout = .{ .file = log_file },
            .stderr = .{ .file = log_file },
        });
        log_file.close(io);
        const term = try child.wait(io);
        const log = try std.Io.Dir.cwd().readFileAlloc(io, log_path, self.a, .limited(8 << 20));
        return .{ .code = switch (term) {
            .exited => |c| c,
            else => null,
        }, .log = log };
    }

    /// The game-side test step RAN (not merely: the command exited 0) and
    /// Zig reported its tests as passing.
    fn expectPass(self: *Fixture, comptime what: []const u8) !void {
        const r = try self.labelleTest();
        if (r.code == @as(?u8, 0) and ranTestStep(r.log) and std.mem.indexOf(u8, r.log, "tests passed") != null) return;
        std.debug.print("test freshness e2e: {s}: expected exit 0 WITH the test step run and passing, got exit {?d}\n---- log ----\n{s}\n", .{ what, r.code, r.log });
        return error.TestUnexpectedResult;
    }

    /// Nonzero BECAUSE a test failed: the step ran and was reported FAILED.
    /// A bare nonzero exit is not enough — an unrelated refusal (a stale-CLI
    /// lock gate, a missing tool) would satisfy it while proving nothing.
    fn expectTestFailure(self: *Fixture, comptime what: []const u8) !void {
        const r = try self.labelleTest();
        if (r.code != null and r.code.? != 0 and ranTestStep(r.log) and std.mem.indexOf(u8, r.log, "FAILED:") != null) return;
        std.debug.print("test freshness e2e: {s}: expected a NONZERO exit from a FAILED test step, got exit {?d} — a stale tree was reported as passing, or the run failed for another reason\n---- log ----\n{s}\n", .{ what, r.code, r.log });
        return error.TestUnexpectedResult;
    }

    /// Nonzero because the REFRESH failed — and the staged tree was not run.
    fn expectRefreshFailure(self: *Fixture, comptime what: []const u8, generate_error: []const u8) !void {
        const r = try self.labelleTest();
        if (r.code != null and r.code.? != 0 and !ranTestStep(r.log) and std.mem.indexOf(u8, r.log, generate_error) != null) return;
        std.debug.print("test freshness e2e: {s}: expected a NONZERO exit from the failed refresh ('{s}') with NO test step run, got exit {?d}\n---- log ----\n{s}\n", .{ what, generate_error, r.code, r.log });
        return error.TestUnexpectedResult;
    }

    fn ranTestStep(log: []const u8) bool {
        return std.mem.indexOf(u8, log, "build-test") != null;
    }
};

/// Replace the staged link at `<project>/.labelle/tests/<name>` with a real
/// copy of `<project>/<rel_src>` — what the assembler's last-resort copy
/// fallback produces. Flat: the fixture's dirs hold files only.
fn replaceLinkWithCopy(a: Allocator, project: std.Io.Dir, staged: []const u8, src: []const u8) !void {
    try project.deleteTree(io, staged);
    try project.createDirPath(io, staged);
    var src_dir = try project.openDir(io, src, .{ .iterate = true });
    defer src_dir.close(io);
    var it = src_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const data = try src_dir.readFileAlloc(io, entry.name, a, .limited(1 << 20));
        const dst = try std.fs.path.join(a, &.{ staged, entry.name });
        try project.writeFile(io, .{ .sub_path = dst, .data = data });
    }
}

test "test freshness e2e: only `labelle test` between edits — edit, add, delete, rename, copy-mode import, failed refresh" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const deps_dir = (try envOpt(a, "LABELLE_E2E_DEPS")) orelse return error.SkipZigTest;
    const assembler_bin = (try envOpt(a, "LABELLE_ASSEMBLER")) orelse return error.SkipZigTest;
    if (assembler_bin.len == 0 or deps_dir.len == 0) return error.SkipZigTest;
    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    const cli_bin_raw = (try envOpt(a, "LABELLE_E2E_CLI_BIN")) orelse
        try std.fs.path.join(a, &.{ "zig-out", "bin", "labelle" ++ exe_suffix });
    const cli_src = (try envOpt(a, "LABELLE_E2E_CLI_SRC")) orelse
        try std.fs.path.join(a, &.{ deps_dir, "labelle-cli" });
    for ([_][]const u8{ cli_bin_raw, assembler_bin }) |p| {
        std.Io.Dir.cwd().access(io, p, .{}) catch {
            std.debug.print("test freshness e2e: required binary '{s}' not found (build it first)\n", .{p});
            return error.FileNotFound;
        };
    }
    for ([_][]const u8{ "labelle-core", "labelle-engine", "labelle-gfx", "labelle-assembler", "labelle-null" }) |sub| {
        const p = try std.fs.path.join(a, &.{ deps_dir, sub });
        std.Io.Dir.cwd().access(io, p, .{}) catch {
            std.debug.print("test freshness e2e: sibling checkout '{s}' not found under LABELLE_E2E_DEPS='{s}'\n", .{ sub, deps_dir });
            return error.FileNotFound;
        };
    }
    const cli_bin = try std.Io.Dir.cwd().realPathFileAlloc(io, cli_bin_raw, a);

    // ── Scaffold ───────────────────────────────────────────────────────
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base_buf);
    const project_dir = try std.fs.path.join(a, &.{ base_buf[0..base_len], "fresh_e2e" });

    const project_labelle = try std.fmt.allocPrint(a,
        \\.{{
        \\    .name = "fresh_e2e", .title = "fresh_e2e", .width = 320, .height = 200, .target_fps = 60,
        \\    .backend = .null, .y_axis = .up, .ecs = .zig_ecs, .plugins = .{{}},
        \\    .backend_package = .{{ .name = "null", .repo = "local:{s}/labelle-null", .version = "0.0.0" }},
        \\    .initial_prefab = "main", .states = .{{"playing"}}, .resources = .{{}},
        \\    .layers = .{{ .{{ .name = "world", .order = 0, .space = .world }} }},
        \\    .core_version = "local:{s}/labelle-core",
        \\    .engine_version = "local:{s}/labelle-engine",
        \\    .gfx_version = "local:{s}/labelle-gfx",
        \\    .labelle_version = "local:{s}",
        \\    .assembler_version = "local:{s}/labelle-assembler",
        \\}}
        \\
    , .{ deps_dir, deps_dir, deps_dir, deps_dir, cli_src, deps_dir });
    for ([_][]const u8{ "scenes", "scripts/playing", "prefabs", "assets", "components", "hooks", "tests" }) |sub| {
        try tmp.dir.createDirPath(io, try std.fs.path.join(a, &.{ "fresh_e2e", sub }));
    }
    var project = try tmp.dir.openDir(io, "fresh_e2e", .{ .iterate = true });
    defer project.close(io);
    try project.writeFile(io, .{ .sub_path = "project.labelle", .data = project_labelle });
    try project.writeFile(io, .{ .sub_path = "scenes/main.jsonc", .data = "{\n  \"name\": \"main\",\n  \"children\": []\n}\n" });
    try project.writeFile(io, .{ .sub_path = "scripts/playing/10_limit.zig", .data = scriptSource("3") });
    try project.writeFile(io, .{ .sub_path = "tests/limit_test.zig", .data = passing_test });

    var fx = Fixture{ .a = a, .cli_bin = cli_bin, .project_dir = project_dir };

    // 1. Nothing generated yet: `labelle test` alone generates, runs, passes.
    try fx.expectPass("1. a passing test, nothing generated beforehand");
    // 2. Edit the test to fail — no generate/build/run in between.
    try project.writeFile(io, .{ .sub_path = "tests/limit_test.zig", .data = failing_test });
    try fx.expectTestFailure("2. the test was edited to fail");
    // 3. Repair it.
    try project.writeFile(io, .{ .sub_path = "tests/limit_test.zig", .data = passing_test });
    try fx.expectPass("3. the test was repaired");
    // 4. A NEW failing file: invisible to a snapshot's baked-in test root.
    try project.writeFile(io, .{ .sub_path = "tests/added_test.zig", .data = new_failing_test });
    try fx.expectTestFailure("4. a new failing test file was added");
    // 5. Delete it: the snapshot must not run the orphan.
    try project.deleteFile(io, "tests/added_test.zig");
    try fx.expectPass("5. the new test file was deleted");
    // 6. Rename: a stale root would still import the old name and not compile.
    try project.rename("tests/limit_test.zig", project, "tests/renamed_test.zig", io);
    try fx.expectPass("6. the test file was renamed");

    // 7. Copy mode + a TRANSITIVE change. Stage copies where the links were
    //    (tests AND the scripts dir the test imports), then change only the
    //    script: the test file itself is untouched, and a copy-mode snapshot
    //    still holds `limit = 3`.
    try replaceLinkWithCopy(a, project, ".labelle/tests/tests", "tests");
    try replaceLinkWithCopy(a, project, ".labelle/tests/scripts/playing", "scripts/playing");
    try project.writeFile(io, .{ .sub_path = "scripts/playing/10_limit.zig", .data = scriptSource("4") });
    try fx.expectTestFailure("7. an imported script changed while the staged dirs were COPIES");
    try project.writeFile(io, .{ .sub_path = "scripts/playing/10_limit.zig", .data = scriptSource("3") });
    try fx.expectPass("7b. the imported script was restored");

    // 8. The refresh fails (two scripts with the same order prefix is a
    //    generate-time error) while a previously PASSING tree is staged: the
    //    command fails and that tree is not run as a consolation.
    try project.writeFile(io, .{ .sub_path = "scripts/playing/10_duplicate.zig", .data = scriptSource("3") });
    try fx.expectRefreshFailure("8. generate fails with a passing tree already staged", "duplicate script order");

    std.debug.print("test freshness e2e: ok — {d} `labelle test` runs, no generate/build/run between edits: edit, repair, add, delete, rename, copy-mode import, failed refresh\n", .{fx.runs});
}
