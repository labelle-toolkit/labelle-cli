//! Subprocess-level e2e for the `labelle run` exit-status contract
//! (labelle-cli#390). Spawns the REAL built CLI on a scaffolded headless
//! (`null` backend) fixture whose one script leaves the game with the
//! status named by `E390_EXIT`, and asserts the CLI's OWN exit status:
//!
//!   game exits 0                       → CLI exits 0
//!   game exits 7                       → CLI exits 7 (and the
//!                                        `--progress=json` terminal record
//!                                        is a single `done` with exit_code 7)
//!   game aborts                        → CLI exits nonzero (134 on POSIX)
//!   game runs its 5 frames and returns → CLI exits 0
//!   game hangs, `--timeout=3s`         → CLI exits 0: a GENUINE watchdog
//!                                        expiry is success under the
//!                                        smoke-run contract
//!   game exits 7 under `--timeout=60s` → CLI exits 7: a crash before the
//!                                        deadline is not a timeout
//!   a script that does not compile     → CLI exits nonzero, no launch
//!
//! Before the fix every one of the nonzero rows exited 0.
//!
//! Opt-in like progress_e2e.zig — skips unless LABELLE_E2E_DEPS and
//! LABELLE_ASSEMBLER are set. Needs the same sibling checkouts plus
//! `labelle-null` (pinned `local:` so the headless backend never comes
//! from a release fetch). Run: `zig build test-e2e-run`.
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

const Fixture = struct {
    a: Allocator,
    cli_bin: []const u8,
    project_dir: []const u8,

    /// `labelle run <project> --timeout=<t> [--progress=json]` with
    /// `E390_EXIT=<spec>` in the child's env; returns the CLI's termination.
    fn run(self: Fixture, spec: ?[]const u8, timeout: []const u8, stdout_path: ?[]const u8) !std.process.Child.Term {
        var env = try std.testing.environ.createMap(self.a);
        defer env.deinit();
        if (spec) |s| try env.put("E390_EXIT", s);
        const timeout_arg = try std.fmt.allocPrint(self.a, "--timeout={s}", .{timeout});
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(self.a, &.{ self.cli_bin, "run", self.project_dir, timeout_arg });
        if (stdout_path != null) try argv.append(self.a, "--progress=json");
        const out_file = if (stdout_path) |p| try std.Io.Dir.cwd().createFile(io, p, .{}) else null;
        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .cwd = .{ .path = self.project_dir },
            .stdin = .ignore,
            .stdout = if (out_file) |f| .{ .file = f } else .ignore,
            .stderr = .inherit,
            .environ_map = &env,
        });
        if (out_file) |f| f.close(io);
        return child.wait(io);
    }
};

fn code(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |c| c,
        else => null,
    };
}

test "run exit e2e: the CLI's exit status is the game's — crash, abort, clean, timeout, failed build" {
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
            std.debug.print("run exit e2e: required binary '{s}' not found (build it first)\n", .{p});
            return error.FileNotFound;
        };
    }
    for ([_][]const u8{ "labelle-core", "labelle-engine", "labelle-gfx", "labelle-assembler", "labelle-null" }) |sub| {
        const p = try std.fs.path.join(a, &.{ deps_dir, sub });
        std.Io.Dir.cwd().access(io, p, .{}) catch {
            std.debug.print("run exit e2e: sibling checkout '{s}' not found under LABELLE_E2E_DEPS='{s}'\n", .{ sub, deps_dir });
            return error.FileNotFound;
        };
    }
    const cli_bin = try std.Io.Dir.cwd().realPathFileAlloc(io, cli_bin_raw, a);

    // ── Scaffold: headless fixture, one script that exits on demand ────
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base_buf);
    const project_dir = try std.fs.path.join(a, &.{ base_buf[0..base_len], "exit_e2e" });

    const project_labelle = try std.fmt.allocPrint(a,
        \\.{{
        \\    .name = "exit_e2e", .title = "exit_e2e", .width = 320, .height = 200, .target_fps = 60,
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
    for ([_][]const u8{ "scenes", "scripts/playing", "prefabs", "assets", "components", "hooks" }) |sub| {
        try tmp.dir.createDirPath(io, try std.fs.path.join(a, &.{ "exit_e2e", sub }));
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "exit_e2e/project.labelle", .data = project_labelle });
    try tmp.dir.writeFile(io, .{ .sub_path = "exit_e2e/scenes/main.jsonc", .data = "{\n  \"name\": \"main\",\n  \"children\": []\n}\n" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "exit_e2e/scripts/playing/10_exit.zig",
        .data =
        \\//! labelle-cli#390 fixture: on the second tick, leave with the status
        \\//! named by E390_EXIT — a code, `abort`, or `hang` (never return, so
        \\//! only the CLI's watchdog can end the run). Unset: run normally.
        \\const std = @import("std");
        \\pub const game_states = .{"playing"};
        \\pub fn State(comptime EcsBackend: type) type {
        \\    _ = EcsBackend;
        \\    return struct { ticks: u32 = 0 };
        \\}
        \\pub fn tick(game: anytype, state: anytype, _: anytype, dt: f32) void {
        \\    _ = game;
        \\    _ = dt;
        \\    state.ticks += 1;
        \\    if (state.ticks < 2) return;
        \\    const raw = std.c.getenv("E390_EXIT") orelse return;
        \\    const spec = std.mem.span(raw);
        \\    if (std.mem.eql(u8, spec, "abort")) std.process.abort();
        \\    if (std.mem.eql(u8, spec, "hang")) {
        \\        while (true) {
        \\            var req: std.c.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        \\            var rem: std.c.timespec = undefined;
        \\            _ = std.c.nanosleep(&req, &rem);
        \\        }
        \\    }
        \\    std.process.exit(std.fmt.parseInt(u8, spec, 10) catch 99);
        \\}
        \\
        ,
    });
    const fx = Fixture{ .a = a, .cli_bin = cli_bin, .project_dir = project_dir };

    // ── 1. exit 7 (cold generate + build), with the progress feed ─────
    const feed_path = try std.fs.path.join(a, &.{ project_dir, "exit7.ndjson" });
    try std.testing.expectEqual(@as(?u8, 7), code(try fx.run("7", "120s", feed_path)));
    // Exactly one terminal record, `done`, carrying the game's status.
    const feed = try std.Io.Dir.cwd().readFileAlloc(io, feed_path, a, .limited(1 << 20));
    var terminal_records: usize = 0;
    var lines = std.mem.splitScalar(u8, feed, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{});
        defer parsed.deinit();
        const phase = parsed.value.object.get("phase").?.string;
        if (!std.mem.eql(u8, phase, "done") and !std.mem.eql(u8, phase, "failed")) continue;
        terminal_records += 1;
        try std.testing.expectEqualStrings("done", phase);
        try std.testing.expectEqual(@as(i64, 7), parsed.value.object.get("exit_code").?.integer);
    }
    try std.testing.expectEqual(@as(usize, 1), terminal_records);

    // ── 2. exit 0 ──────────────────────────────────────────────────────
    try std.testing.expectEqual(@as(?u8, 0), code(try fx.run("0", "120s", null)));

    // ── 3. abnormal termination ────────────────────────────────────────
    const abort_code = code(try fx.run("abort", "120s", null)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(abort_code != 0);
    if (builtin.os.tag != .windows) try std.testing.expectEqual(@as(u8, 128 + 6), abort_code);

    // ── 4. a normal run: the headless main plays its frames and returns ─
    try std.testing.expectEqual(@as(?u8, 0), code(try fx.run(null, "120s", null)));

    // ── 5. a GENUINE watchdog expiry is success ────────────────────────
    try std.testing.expectEqual(@as(?u8, 0), code(try fx.run("hang", "3s", null)));

    // ── 6. a crash BEFORE the deadline is not a timeout ────────────────
    try std.testing.expectEqual(@as(?u8, 7), code(try fx.run("7", "60s", null)));

    // ── 7. a failed prerequisite build fails the command; nothing runs ─
    try tmp.dir.writeFile(io, .{
        .sub_path = "exit_e2e/scripts/playing/20_broken.zig",
        .data = "pub const game_states = .{\"playing\"};\npub fn tick(game: anytype, state: anytype, _: anytype, dt: f32) void { this does not compile }\n",
    });
    const broken = code(try fx.run("0", "60s", null)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(broken != 0);

    std.debug.print("run exit e2e: ok — 7→7 (one done record, exit_code 7), 0→0, abort→{d}, clean→0, timeout→0, crash-under-timeout→7, broken build→{d}\n", .{ abort_code, broken });
}
