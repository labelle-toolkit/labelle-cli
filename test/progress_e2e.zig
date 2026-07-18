//! Subprocess-level end-to-end test for the build-progress feed
//! (labelle-cli#319; the feed itself is labelle-cli#284).
//!
//! The feed's in-process coverage (PhaseMachineSpec, NdjsonEncodingSpec,
//! AtomicStatusFileSpec, ReporterPipelineSpec, PacketDecodingSpec) cannot
//! catch subprocess-level regressions — stdio routing, progress-pipe
//! attach, stdout purity, assembler-failure propagation. This test spawns
//! the REAL built CLI (`zig-out/bin/labelle`) against a scaffolded
//! fixture project and drives two builds:
//!
//!   1. Happy path — `labelle build --progress=json`. Asserts every
//!      stdout line parses as JSON (stdout purity), phases are
//!      forward-ordered per the phase machine (resolve → generate →
//!      compile → done; link/run may legally be skipped), `elapsed_ms`
//!      is monotonic, and the terminal record is `done` with
//!      `exit_code: 0`. While the build runs, a poller thread reads
//!      `.labelle/raylib_desktop/.build-progress.json` and observes a
//!      non-terminal record, and a `labelle status --json` subprocess
//!      mid-build agrees; after the build exits the file holds the
//!      terminal record.
//!
//!   2. Failure variant — a syntactically broken game script is added
//!      after the first successful build; the rebuild must end in a
//!      terminal `failed` record carrying a nonzero `exit_code`, and the
//!      CLI itself must exit nonzero. Only stable contract facts are
//!      asserted (phase, exit_code presence) — the failed record's
//!      `detail` string is deliberately NOT asserted: its content is
//!      evolving under labelle-cli#318.
//!
//! This test is NOT part of `zig build test` — it is the opt-in
//! `zig build test-e2e` step. It needs:
//!
//!   - the built CLI at `zig-out/bin/labelle` (the `test-e2e` build step
//!     depends on the install step, so the binary is always fresh),
//!   - sibling checkouts of labelle-core / labelle-engine / labelle-gfx /
//!     labelle-assembler, pinned as `local:` versions in the fixture's
//!     project.labelle so NO GitHub-release package fetching happens at
//!     test time (the same pattern as the versions-integration CI job),
//!   - a built `labelle-assembler` binary.
//!
//! Gating — the test SKIPS unless both are set:
//!   LABELLE_E2E_DEPS    directory holding the sibling checkouts
//!                       (labelle-core, labelle-engine, labelle-gfx,
//!                       labelle-assembler as immediate subdirs)
//!   LABELLE_ASSEMBLER   path to a built labelle-assembler binary
//!                       (inherited by the CLI child, which honors it)
//! Optional:
//!   LABELLE_E2E_CLI_SRC labelle-cli checkout for the `labelle_version`
//!                       pin (default: $LABELLE_E2E_DEPS/labelle-cli)
//!   LABELLE_E2E_CLI_BIN path to the labelle binary under test
//!                       (default: zig-out/bin/labelle[.exe] under cwd)
//!   LABELLE_ZIG         forwarded to the CLI child; point it at a zig
//!                       binary to skip the managed-toolchain download
//!
//! Local run (from the repo root, siblings checked out next to it):
//!   LABELLE_E2E_DEPS=$PWD/.. \
//!   LABELLE_ASSEMBLER=$PWD/../labelle-assembler/zig-out/bin/labelle-assembler \
//!   zig build test-e2e

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const io = std.testing.io;

/// Phase ranks mirroring the phase machine in src/cli/progress.zig
/// (forward-only, skips allowed, terminal states absorbing). Duplicated
/// rather than imported so this subprocess-level test stays decoupled
/// from the CLI's module graph — it exercises the binary, not the lib.
fn phaseRank(phase: []const u8) ?u8 {
    const ranks = .{
        .{ "resolve", @as(u8, 0) },
        .{ "generate", 1 },
        .{ "compile", 2 },
        .{ "link", 3 },
        .{ "run", 4 },
        .{ "done", 5 },
        .{ "failed", 5 },
    };
    inline for (ranks) |r| {
        if (std.mem.eql(u8, phase, r[0])) return r[1];
    }
    return null;
}

fn isTerminalPhase(phase: []const u8) bool {
    return std.mem.eql(u8, phase, "done") or std.mem.eql(u8, phase, "failed");
}

/// Look up an environment variable; unset/invalid → null, real errors
/// (OOM) propagate.
fn envOpt(a: Allocator, name: []const u8) !?[]u8 {
    return std.process.Environ.getAlloc(std.testing.environ, a, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing, error.InvalidWtf8 => null,
        else => err,
    };
}

/// The stable record schema keys (progress.zig module doc: "All keys are
/// always present (null when unknown)"; additive changes only). Asserting
/// presence — not values of the evolving `detail` string (#318).
const record_keys = [_][]const u8{
    "phase", "step", "total", "percent", "detail", "elapsed_ms", "exit_code", "updated_at_ms",
};

const FeedSummary = struct {
    lines: u32 = 0,
    saw_resolve: bool = false,
    saw_generate: bool = false,
    saw_compile: bool = false,
    terminal_phase: []const u8 = "",
    terminal_exit_code: ?i64 = null,
};

/// Validate one NDJSON capture (the build's whole stdout): every line
/// parses as JSON, carries the full stable key set, phases never move
/// backward, `elapsed_ms` never regresses. Returns a summary for the
/// caller's per-scenario terminal-record assertions. Allocations come
/// from `a` (an arena in practice — per-line JSON values and the
/// returned `terminal_phase` copy all share its lifetime).
fn validateFeed(a: Allocator, stdout_bytes: []const u8) !FeedSummary {
    var summary: FeedSummary = .{};
    var prev_rank: u8 = 0;
    var prev_elapsed: i64 = -1;

    var it = std.mem.splitScalar(u8, stdout_bytes, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
        if (line.len == 0) continue;
        summary.lines += 1;

        const parsed = std.json.parseFromSlice(std.json.Value, a, line, .{}) catch |err| {
            std.debug.print("line {d} is not valid JSON ({s}): {s}\n", .{ summary.lines, @errorName(err), line });
            return error.TestUnexpectedResult;
        };
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => {
                std.debug.print("line {d} is not a JSON object: {s}\n", .{ summary.lines, line });
                return error.TestUnexpectedResult;
            },
        };

        for (record_keys) |key| {
            if (!obj.contains(key)) {
                std.debug.print("line {d} is missing key '{s}': {s}\n", .{ summary.lines, key, line });
                return error.TestUnexpectedResult;
            }
        }

        const phase = switch (obj.get("phase").?) {
            .string => |s| s,
            else => {
                std.debug.print("line {d}: 'phase' is not a string: {s}\n", .{ summary.lines, line });
                return error.TestUnexpectedResult;
            },
        };
        const rank = phaseRank(phase) orelse {
            std.debug.print("line {d}: unknown phase '{s}'\n", .{ summary.lines, phase });
            return error.TestUnexpectedResult;
        };
        if (rank < prev_rank) {
            std.debug.print("line {d}: phase moved backward (rank {d} -> {d}): {s}\n", .{ summary.lines, prev_rank, rank, line });
            return error.TestUnexpectedResult;
        }
        prev_rank = rank;

        const elapsed = switch (obj.get("elapsed_ms").?) {
            .integer => |n| n,
            else => {
                std.debug.print("line {d}: 'elapsed_ms' is not an integer: {s}\n", .{ summary.lines, line });
                return error.TestUnexpectedResult;
            },
        };
        if (elapsed < prev_elapsed) {
            std.debug.print("line {d}: elapsed_ms regressed ({d} -> {d})\n", .{ summary.lines, prev_elapsed, elapsed });
            return error.TestUnexpectedResult;
        }
        prev_elapsed = elapsed;

        summary.saw_resolve = summary.saw_resolve or std.mem.eql(u8, phase, "resolve");
        summary.saw_generate = summary.saw_generate or std.mem.eql(u8, phase, "generate");
        summary.saw_compile = summary.saw_compile or std.mem.eql(u8, phase, "compile");
        summary.terminal_phase = try a.dupe(u8, phase);
        summary.terminal_exit_code = switch (obj.get("exit_code").?) {
            .integer => |n| n,
            else => null,
        };
    }
    return summary;
}

/// One read of the live status file: the two fields the test asserts on.
/// `phase` is owned by the caller (free with the same allocator).
const StatusSnapshot = struct {
    phase: []u8,
    exit_code: ?i64,
};

fn readStatusFile(a: Allocator, status_path: []const u8) !StatusSnapshot {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, status_path, a, .limited(64 * 1024));
    defer a.free(raw);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
    defer parsed.deinit();
    // Defensive: the poller reads this file concurrently with the
    // build's atomic rewrites — a malformed record must surface as an
    // error (the poller retries) rather than panic the test process.
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidStatusRecord,
    };
    const phase = switch (obj.get("phase") orelse return error.InvalidStatusRecord) {
        .string => |s| s,
        else => return error.InvalidStatusRecord,
    };
    return .{
        .phase = try a.dupe(u8, phase),
        .exit_code = switch (obj.get("exit_code") orelse return error.InvalidStatusRecord) {
            .integer => |n| n,
            else => null,
        },
    };
}

/// Concurrent observer: while the build child runs, poll the live status
/// file from this second process (the build is the first). Records
/// whether a non-terminal record was observed mid-flight, and — on that
/// first observation — shells out to `labelle status --json` (a third
/// process) and records whether it reported the same non-terminal state.
/// Allocations are short-lived and use std.testing.allocator directly —
/// the main thread's arena is not safe to share across threads.
const Poller = struct {
    status_path: []const u8,
    cli_bin: []const u8,
    project_dir: []const u8,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    reads: u32 = 0,
    saw_non_terminal: bool = false,
    saw_terminal: bool = false,
    status_cmd_ran: bool = false,
    status_cmd_ok: bool = false,

    fn run(self: *Poller) void {
        const a = std.testing.allocator;
        while (!self.stop.load(.acquire)) {
            if (readStatusFile(a, self.status_path)) |snap| {
                defer a.free(snap.phase);
                self.reads += 1;
                if (isTerminalPhase(snap.phase)) {
                    self.saw_terminal = true;
                } else {
                    if (!self.saw_non_terminal) {
                        self.saw_non_terminal = true;
                        self.checkStatusCommand();
                    }
                }
            } else |_| {
                // Not written yet (build still in early setup) — retry.
            }
            const pause: std.Io.Clock.Duration = .{ .clock = .awake, .raw = .fromMilliseconds(25) };
            pause.sleep(io) catch return;
        }
    }

    /// `labelle status --json` mid-build: must exit 0 and print a single
    /// JSON record in a non-terminal phase.
    fn checkStatusCommand(self: *Poller) void {
        const a = std.testing.allocator;
        self.status_cmd_ran = true;
        const res = std.process.run(a, io, .{
            .argv = &.{ self.cli_bin, "status", self.project_dir, "--json" },
        }) catch return;
        defer a.free(res.stdout);
        defer a.free(res.stderr);
        switch (res.term) {
            .exited => |code| if (code != 0) return,
            else => return,
        }
        const line = std.mem.trim(u8, res.stdout, &std.ascii.whitespace);
        const parsed = std.json.parseFromSlice(std.json.Value, a, line, .{}) catch return;
        defer parsed.deinit();
        const phase = parsed.value.object.get("phase") orelse return;
        const phase_str = switch (phase) {
            .string => |s| s,
            else => return,
        };
        self.status_cmd_ok = !isTerminalPhase(phase_str);
    }
};

/// Spawn `labelle build --progress=json` in `project_dir`, stdout
/// redirected to `stdout_path` (a pipe could fill and block the child on
/// a long cold build; a file cannot). stderr is inherited so a failure
/// streams into the test log for CI diagnosis.
fn spawnBuild(project_dir: []const u8, cli_bin: []const u8, stdout_path: []const u8) !std.process.Child {
    const stdout_file = try std.Io.Dir.cwd().createFile(io, stdout_path, .{});
    errdefer stdout_file.close(io);
    const child = try std.process.spawn(io, .{
        .argv = &.{ cli_bin, "build", "--progress=json" },
        .cwd = .{ .path = project_dir },
        .stdin = .ignore,
        .stdout = .{ .file = stdout_file },
        .stderr = .inherit,
    });
    // The child holds its own dup of the fd now.
    stdout_file.close(io);
    return child;
}

fn termExitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

test "progress feed e2e: real build --progress=json, concurrent status file, failure variant" {
    // Arena for everything the test body builds (paths, fixture text,
    // JSON parses); freed in one shot at the end. The poller thread uses
    // std.testing.allocator directly — an arena is not thread-safe.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // ── Gate: opt-in env, otherwise skip ─────────────────────────────
    const deps_dir = (try envOpt(a, "LABELLE_E2E_DEPS")) orelse return error.SkipZigTest;
    const assembler_bin = (try envOpt(a, "LABELLE_ASSEMBLER")) orelse return error.SkipZigTest;
    if (assembler_bin.len == 0 or deps_dir.len == 0) return error.SkipZigTest;

    const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
    const cli_bin_raw = (try envOpt(a, "LABELLE_E2E_CLI_BIN")) orelse
        try std.fs.path.join(a, &.{ "zig-out", "bin", "labelle" ++ exe_suffix });
    const cli_src = (try envOpt(a, "LABELLE_E2E_CLI_SRC")) orelse
        try std.fs.path.join(a, &.{ deps_dir, "labelle-cli" });

    // Pre-flight: everything the fixture pins must exist, with a
    // diagnostic clearer than the assembler's resolver failure.
    for ([_][]const u8{ cli_bin_raw, assembler_bin }) |path| {
        std.Io.Dir.cwd().access(io, path, .{}) catch {
            std.debug.print("progress e2e: required binary '{s}' not found (build it first)\n", .{path});
            return error.FileNotFound;
        };
    }
    for ([_][]const u8{ "labelle-core", "labelle-engine", "labelle-gfx", "labelle-assembler" }) |sub| {
        const p = try std.fs.path.join(a, &.{ deps_dir, sub });
        std.Io.Dir.cwd().access(io, p, .{}) catch {
            std.debug.print("progress e2e: sibling checkout '{s}' not found under LABELLE_E2E_DEPS='{s}'\n", .{ sub, deps_dir });
            return error.FileNotFound;
        };
    }

    // The build child's cwd is the fixture dir, so the CLI path must be
    // absolute — a relative path would resolve against the fixture.
    const cli_bin = try std.Io.Dir.cwd().realPathFileAlloc(io, cli_bin_raw, a);

    // ── Scaffold the fixture project ─────────────────────────────────
    // `labelle init` is not used (broken pins — cli#322); the minimal
    // layout the assembler expects is written directly: project.labelle
    // + scenes/main.jsonc (+ the conventional dirs). Versions are
    // `local:` pins → zero GitHub-release package fetching at test time.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &base_buf);
    const project_dir = try std.fs.path.join(a, &.{ base_buf[0..base_len], "progress_e2e" });

    const project_labelle = try std.fmt.allocPrint(a,
        \\.{{
        \\    .name = "progress_e2e", .title = "progress_e2e", .width = 800, .height = 600, .target_fps = 60,
        \\    .y_axis = .up,
        \\    .backend = .raylib, .ecs = .zig_ecs, .plugins = .{{}},
        \\    .layers = .{{ .{{ .name = "background", .order = 0, .space = .screen }}, .{{ .name = "world", .order = 1, .space = .world }}, .{{ .name = "ui", .order = 2, .space = .screen }} }},
        \\    .core_version = "local:{s}/labelle-core",
        \\    .engine_version = "local:{s}/labelle-engine",
        \\    .gfx_version = "local:{s}/labelle-gfx",
        \\    .labelle_version = "local:{s}",
        \\    .assembler_version = "local:{s}/labelle-assembler",
        \\}}
        \\
    , .{ deps_dir, deps_dir, deps_dir, cli_src, deps_dir });

    try tmp.dir.createDirPath(io, "progress_e2e/scenes");
    for ([_][]const u8{ "scripts", "prefabs", "assets", "components", "hooks" }) |sub| {
        const p = try std.fs.path.join(a, &.{ "progress_e2e", sub });
        try tmp.dir.createDirPath(io, p);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "progress_e2e/project.labelle", .data = project_labelle });
    try tmp.dir.writeFile(io, .{
        .sub_path = "progress_e2e/scenes/main.jsonc",
        .data =
        \\{
        \\    "name": "main",
        \\    "children": []
        \\}
        \\
        ,
    });

    const status_path = try std.fs.path.join(a, &.{
        project_dir, ".labelle", "raylib_desktop", ".build-progress.json",
    });

    // ── 1. Happy path: cold build with concurrent status polling ──────
    const happy_ndjson = try std.fs.path.join(a, &.{ project_dir, "happy.ndjson" });
    var poller: Poller = .{
        .status_path = status_path,
        .cli_bin = cli_bin,
        .project_dir = project_dir,
    };

    var child = try spawnBuild(project_dir, cli_bin, happy_ndjson);
    const poller_thread = try std.Thread.spawn(.{}, Poller.run, .{&poller});
    // If anything below fails before the orderly stop+join, stop and
    // join the poller here — an orphaned thread would keep polling with
    // a dangling pointer to the stack `poller`. The flag prevents a
    // double-join when a later assertion fails after the orderly join.
    var poller_joined = false;
    errdefer {
        if (!poller_joined) {
            poller.stop.store(true, .release);
            poller_thread.join();
        }
    }
    const term = try child.wait(io);
    poller.stop.store(true, .release);
    poller_thread.join();
    poller_joined = true;

    const happy_code = termExitCode(term) orelse {
        std.debug.print("happy-path build terminated abnormally: {any}\n", .{term});
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(@as(u8, 0), happy_code);

    // stdout purity + feed contract.
    const happy_bytes = try std.Io.Dir.cwd().readFileAlloc(io, happy_ndjson, a, .limited(4 * 1024 * 1024));
    const happy = try validateFeed(a, happy_bytes);
    try std.testing.expect(happy.lines >= 4); // resolve, generate, compile, done at minimum
    try std.testing.expect(happy.saw_resolve);
    try std.testing.expect(happy.saw_generate);
    try std.testing.expect(happy.saw_compile);
    try std.testing.expectEqualStrings("done", happy.terminal_phase);
    try std.testing.expectEqual(@as(?i64, 0), happy.terminal_exit_code);

    // Concurrent observation: the poller (second process) saw the build
    // mid-flight, and `labelle status --json` (third process) agreed.
    try std.testing.expect(poller.reads > 0);
    try std.testing.expect(poller.saw_non_terminal);
    try std.testing.expect(poller.status_cmd_ran);
    try std.testing.expect(poller.status_cmd_ok);

    // Terminal state on disk after exit.
    const snap = try readStatusFile(a, status_path);
    try std.testing.expectEqualStrings("done", snap.phase);
    try std.testing.expectEqual(@as(?i64, 0), snap.exit_code);

    std.debug.print(
        "progress e2e: happy build ok — {d} NDJSON lines, terminal done (exit 0), poller saw non-terminal after {d} reads, status --json agreed mid-build\n",
        .{ happy.lines, poller.reads },
    );

    // ── 2. Failure variant: broken game script → terminal failed ──────
    // Cheapest deterministic failure (cli#319): a script the assembler
    // copies into the generated target fails the next `zig build`.
    try tmp.dir.writeFile(io, .{
        .sub_path = "progress_e2e/scripts/broken.zig",
        .data = "pub fn broken( {\n    this is not zig at all\n",
    });

    const fail_ndjson = try std.fs.path.join(a, &.{ project_dir, "fail.ndjson" });
    var fail_child = try spawnBuild(project_dir, cli_bin, fail_ndjson);
    const fail_term = try fail_child.wait(io);
    const fail_code = termExitCode(fail_term) orelse {
        std.debug.print("failure-variant build terminated abnormally: {any}\n", .{fail_term});
        return error.TestUnexpectedResult;
    };
    // CLI exit code unchanged by the feed: a build failure is nonzero.
    try std.testing.expect(fail_code != 0);

    const fail_bytes = try std.Io.Dir.cwd().readFileAlloc(io, fail_ndjson, a, .limited(4 * 1024 * 1024));
    const failed = try validateFeed(a, fail_bytes);
    try std.testing.expect(failed.lines >= 3); // resolve, generate/compile, failed
    try std.testing.expectEqualStrings("failed", failed.terminal_phase);
    const failed_exit = failed.terminal_exit_code orelse {
        std.debug.print("terminal failed record is missing exit_code\n", .{});
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(failed_exit != 0);
    // NOTE: the failed record's `detail` string is intentionally not
    // asserted — its content is evolving under labelle-cli#318.

    // Status file + `labelle status --json` reflect the terminal failure.
    const fail_snap = try readStatusFile(a, status_path);
    try std.testing.expectEqualStrings("failed", fail_snap.phase);
    try std.testing.expect(fail_snap.exit_code != null and fail_snap.exit_code.? != 0);

    const status_res = try std.process.run(a, io, .{
        .argv = &.{ cli_bin, "status", project_dir, "--json" },
    });
    try std.testing.expectEqual(@as(?u8, 0), termExitCode(status_res.term));
    const status_line = std.mem.trim(u8, status_res.stdout, &std.ascii.whitespace);
    const status_parsed = try std.json.parseFromSlice(std.json.Value, a, status_line, .{});
    const status_obj = status_parsed.value.object;
    try std.testing.expectEqualStrings("failed", status_obj.get("phase").?.string);
    try std.testing.expect(status_obj.get("exit_code").? != .null);

    std.debug.print(
        "progress e2e: failure variant ok — terminal failed (exit {d}), CLI exit {d}, status file + status --json agree\n",
        .{ failed_exit, fail_code },
    );
}
