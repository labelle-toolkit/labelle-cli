//! Structured build-progress feed (labelle-cli#284).
//!
//! One event source, three access modes:
//!   - `--progress=json` — one NDJSON record per line on **stdout** for
//!     programmatic consumers (labelle-studio's `spawn_build`, CI).
//!   - a live status file `.labelle/<target>/.build-progress.json`,
//!     atomically rewritten (temp + rename) with the CURRENT record so any
//!     unrelated process can read build state mid-flight (`labelle status`,
//!     studio's fs bridge). Written in ALL modes.
//!   - the default human mode — a single-line terminal spinner during the
//!     otherwise-silent `zig build` compile/link gap (TTY stderr only).
//!
//! The compile-phase step/total/detail granularity comes from Zig's native
//! `std.Progress` IPC (see `zig_progress.zig`); this module is the pure
//! phase model + fan-out sink and knows nothing about the wire format.
//!
//! Record schema (stable; additive changes only — studio#28 consumes it):
//!   { "phase":"resolve|generate|compile|link|run|done|failed",
//!     "step":int?, "total":int?, "percent":float?,
//!     "detail":"...", "elapsed_ms":int,
//!     "exit_code":int?, "updated_at_ms":int }

const std = @import("std");
const builtin = @import("builtin");

/// Build phases in pipeline order, plus the two terminal states. A build
/// may legally SKIP forward (e.g. no `link` granularity was detected, or a
/// `labelle build` never enters `run`) but may never move backward, and
/// terminal states absorb.
pub const Phase = enum {
    resolve,
    generate,
    compile,
    link,
    run,
    done,
    failed,

    pub fn isTerminal(p: Phase) bool {
        return p == .done or p == .failed;
    }

    fn rank(p: Phase) u8 {
        return switch (p) {
            .resolve => 0,
            .generate => 1,
            .compile => 2,
            .link => 3,
            .run => 4,
            .done, .failed => 5,
        };
    }
};

/// One progress record — what a consumer sees per NDJSON line and what the
/// status file holds at any instant. `null` means "unknown/not applicable".
/// `exit_code` is populated on the terminal `done`/`failed` record (`done`
/// carries the run's exit code for `labelle run`; `failed` the failing
/// stage's). `updated_at_ms` is wall-clock unix ms of the write, so an
/// out-of-band reader can tell "progressing" from "stale/dead".
pub const Record = struct {
    phase: Phase,
    step: ?u64 = null,
    total: ?u64 = null,
    percent: ?f32 = null,
    detail: []const u8 = "",
    elapsed_ms: u64 = 0,
    exit_code: ?u8 = null,
    updated_at_ms: u64 = 0,
};

/// How the CLI surfaces progress. Parsed from `--progress=<mode>`.
///   human — default; terminal spinner on TTY stderr, nothing when piped.
///   json  — NDJSON records on stdout, no spinner.
///   off   — no terminal output at all.
/// The status file is written in every mode.
pub const Mode = enum { human, json, off };

/// Phase state machine. Pure — no I/O, no clock.
pub const Machine = struct {
    current: ?Phase = null,

    pub const TransitionError = error{InvalidTransition};

    /// Enforce the phase order: forward-only (skips allowed), `failed`
    /// reachable from any non-terminal state (including before the first
    /// phase), `done` from any started non-terminal state, terminal states
    /// absorbing.
    pub fn transition(m: *Machine, to: Phase) TransitionError!void {
        if (m.current) |cur| {
            if (cur.isTerminal()) return error.InvalidTransition;
            switch (to) {
                .done, .failed => {},
                else => if (to.rank() <= cur.rank()) return error.InvalidTransition,
            }
        } else {
            // Nothing has started yet: any working phase may open the
            // pipeline, and an early setup error may fail it — but there
            // is nothing to be "done" with.
            if (to == .done) return error.InvalidTransition;
        }
        m.current = to;
    }

    pub fn isTerminal(m: *const Machine) bool {
        return if (m.current) |c| c.isTerminal() else false;
    }
};

/// Serialize one record as a single JSON line (no trailing newline) into
/// `buf`. All keys are always present (`null` when unknown) so typed
/// consumers get a stable shape. Pure; unit-tested.
pub fn encodeRecord(buf: []u8, rec: Record) error{WriteFailed}![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try std.json.Stringify.value(rec, .{}, &w);
    return w.buffered();
}

/// Atomically publish `bytes` at `final_path`: write `tmp_path` fully, then
/// rename over the destination. A concurrent reader sees either the previous
/// complete JSON document or the new one — never a torn write.
pub fn writeFileAtomic(
    io: std.Io,
    final_path: []const u8,
    tmp_path: []const u8,
    bytes: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp_path, .data = bytes });
    try cwd.rename(tmp_path, cwd, final_path, io);
}

/// Basename of the live status file inside `.labelle/<target>/`.
pub const status_file_name = ".build-progress.json";
const status_tmp_name = ".build-progress.json.tmp";

/// Longest `detail` we retain (a `std.Progress` node name is at most 120
/// bytes; phase labels are shorter).
pub const max_detail_len = 120;

// Emission throttles (milliseconds). Phase transitions and terminal
// records always flush immediately; these only pace the high-frequency
// compile-phase updates (zig writes a snapshot ~every 80ms).
const file_throttle_ms: u64 = 250;
const json_change_throttle_ms: u64 = 200;
const json_heartbeat_ms: u64 = 1000;
const spinner_throttle_ms: u64 = 100;
/// Keepalive ticker period: refreshes `elapsed_ms`/`updated_at_ms` while a
/// child (assembler, zig, game) owns the foreground, so an out-of-band
/// reader can distinguish "working" from "dead" in every phase.
const ticker_period_ms: i64 = 500;

/// The process-wide active reporter, registered by `Reporter.activate` and
/// cleared by `Reporter.deinit`. Exists for one reason: some pipeline
/// helpers terminate the CLI via `std.process.exit` to proxy a child's
/// exact exit code (assembler delegation, compatibility validation), which
/// skips every `errdefer` up the stack — including the one that marks the
/// status file `failed`. Those sites call `fatalExit` instead, which
/// notifies the active reporter first. Main-thread only.
var active_reporter: ?*Reporter = null;

/// Mark the active build `failed` (if a reporter is active) and terminate
/// the process with `code`. Drop-in replacement for `std.process.exit` in
/// code reachable from the build pipeline. `detail` names the failing stage
/// (e.g. "assembler generate failed") so the terminal record tells feed
/// consumers WHY the build died, not just THAT it did (cli#318) — pass a
/// precise per-call-site label, never the bare "error".
pub fn fatalExit(code: u8, detail: []const u8) noreturn {
    if (active_reporter) |r| r.failIfActive(code, detail);
    std.process.exit(code);
}

/// Fan-out sink: takes phase transitions from the CLI command flow and
/// compile-granularity updates from the `std.Progress` pump thread, and
/// drives all three access modes from that single source. Thread-safe (one
/// internal mutex); does not allocate after `init`.
pub const Reporter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mode: Mode,
    /// `.labelle/<target>/<status_file_name>` (owned).
    status_path: []u8,
    /// Sibling temp path for the atomic rename (owned).
    tmp_path: []u8,
    start: std.Io.Timestamp,
    stderr_is_tty: bool,

    mutex: std.Io.Mutex = .init,
    machine: Machine = .{},
    step: ?u64 = null,
    total: ?u64 = null,
    exit_code: ?u8 = null,
    detail_buf: [max_detail_len]u8 = undefined,
    detail_len: usize = 0,

    last_file_ms: u64 = 0,
    last_json_ms: u64 = 0,
    last_spin_ms: u64 = 0,
    file_ever_written: bool = false,
    json_ever_written: bool = false,
    spinner_frame: usize = 0,
    spinner_visible_len: usize = 0,

    ticker: ?std.Thread = null,
    ticker_stop: std.Io.Event = .unset,

    const spinner_frames = [_]u8{ '|', '/', '-', '\\' };

    /// `target_dir` is `.labelle/<backend>_<platform>` relative to (or
    /// absolute under) the project; it is created if missing so the status
    /// file exists from the first `resolve` record onward — before the
    /// assembler has generated anything.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        mode: Mode,
        target_dir: []const u8,
    ) !Reporter {
        std.Io.Dir.cwd().createDirPath(io, target_dir) catch {};
        const status_path = try std.fs.path.join(allocator, &.{ target_dir, status_file_name });
        errdefer allocator.free(status_path);
        const tmp_path = try std.fs.path.join(allocator, &.{ target_dir, status_tmp_name });
        errdefer allocator.free(tmp_path);
        const is_tty = std.Io.File.stderr().isTty(io) catch false;
        return .{
            .allocator = allocator,
            .io = io,
            .mode = mode,
            .status_path = status_path,
            .tmp_path = tmp_path,
            .start = std.Io.Timestamp.now(io, .awake),
            .stderr_is_tty = is_tty,
        };
    }

    /// Register as the process-wide reporter (see `fatalExit`) and start
    /// the keepalive ticker. Call once, after the reporter sits at its
    /// final address — `init` returns by value, so the ticker thread must
    /// not capture the pre-move location.
    pub fn activate(self: *Reporter) void {
        active_reporter = self;
        self.ticker = std.Thread.spawn(.{}, tickerMain, .{self}) catch null;
    }

    pub fn deinit(self: *Reporter) void {
        self.ticker_stop.set(self.io);
        if (self.ticker) |t| t.join();
        if (active_reporter == self) active_reporter = null;
        self.allocator.free(self.status_path);
        self.allocator.free(self.tmp_path);
    }

    /// Keepalive loop: refresh the sinks every `ticker_period_ms` until
    /// `deinit` sets the stop event. Heartbeats no-op once terminal.
    fn tickerMain(self: *Reporter) void {
        const timeout: std.Io.Timeout = .{ .duration = .{
            .clock = .awake,
            .raw = .fromMilliseconds(ticker_period_ms),
        } };
        while (true) {
            if (self.ticker_stop.waitTimeout(self.io, timeout)) |_| {
                return; // stop event set
            } else |err| switch (err) {
                error.Timeout => self.heartbeat(),
                error.Canceled => return,
            }
        }
    }

    /// Enter a pipeline phase. Illegal transitions (programmer error) are
    /// dropped rather than crashing a build that is otherwise working.
    pub fn beginPhase(self: *Reporter, phase: Phase, detail: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.machine.transition(phase) catch return;
        self.step = null;
        self.total = null;
        self.setDetailLocked(detail);
        self.emitLocked(true, true);
    }

    /// Compile-granularity update from the zig `std.Progress` pump thread.
    /// `saw_link` flips `compile` → `link` (forward-only; enforced by the
    /// machine). No-op outside the compile/link phases.
    pub fn compileUpdate(self: *Reporter, step: ?u64, total: ?u64, detail: []const u8, saw_link: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const cur = self.machine.current orelse return;
        if (cur != .compile and cur != .link) return;
        const entered_link = saw_link and cur == .compile;
        if (entered_link) {
            self.machine.transition(.link) catch {};
        }
        const changed = entered_link or
            !std.meta.eql(step, self.step) or
            !std.meta.eql(total, self.total) or
            !std.mem.eql(u8, detail, self.detailSliceLocked());
        self.step = step;
        self.total = total;
        self.setDetailLocked(detail);
        // The link transition is a phase change and flushes immediately;
        // ordinary within-phase updates ride the per-sink throttles (zig
        // sends a snapshot ~every 80ms — no consumer needs them all).
        self.emitLocked(entered_link, changed);
    }

    /// Periodic tick while a child is running and no packet arrived —
    /// refreshes `elapsed_ms`/spinner so "alive but quiet" is visible.
    pub fn heartbeat(self: *Reporter) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.machine.isTerminal()) return;
        self.emitLocked(false, false);
    }

    /// Terminal success record. `exit_code` is the exit status of the last
    /// stage (0 for a plain build; the game's exit code for `labelle run`).
    pub fn finishDone(self: *Reporter, exit_code: u8) void {
        self.finishWith(.done, exit_code, "");
    }

    /// Terminal failure record carrying the failing stage's exit code.
    pub fn finishFailed(self: *Reporter, exit_code: u8, detail: []const u8) void {
        self.finishWith(.failed, exit_code, detail);
    }

    /// Wipe the spinner line (no-op when nothing is drawn) so a subsequent
    /// plain print starts on a clean column. Called at the compile → next
    /// output seam; terminal records clear it themselves.
    pub fn clearSpinner(self: *Reporter) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.clearSpinnerLocked();
    }

    /// errdefer hook: mark `failed` unless a terminal record was already
    /// emitted. Keeps the status file truthful on any early-error path.
    /// `detail` names the failing stage (cli#318); it lands verbatim in the
    /// terminal record, so pass a stage label a consumer can render.
    pub fn failIfActive(self: *Reporter, exit_code: u8, detail: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        const terminal = self.machine.isTerminal();
        self.mutex.unlock(self.io);
        if (!terminal) self.finishFailed(exit_code, detail);
    }

    /// Catch-all errdefer variant: mark `failed` with a detail composed
    /// from the LIVE phase ("generate failed", "resolve failed", …). The
    /// terminal record's own `phase` field flips to "failed", so without
    /// this the stage that was active when the error returned would be
    /// lost to feed consumers (cli#318 / PR #325 review).
    pub fn failActiveStage(self: *Reporter, exit_code: u8) void {
        self.mutex.lockUncancelable(self.io);
        const terminal = self.machine.isTerminal();
        const stage: []const u8 = if (self.machine.current) |c| @tagName(c) else "build";
        self.mutex.unlock(self.io);
        if (terminal) return;
        var buf: [max_detail_len]u8 = undefined;
        const detail = std.fmt.bufPrint(&buf, "{s} failed", .{stage}) catch "build failed";
        self.finishFailed(exit_code, detail);
    }

    fn finishWith(self: *Reporter, phase: Phase, exit_code: u8, detail: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.machine.isTerminal()) return;
        self.machine.transition(phase) catch return;
        self.exit_code = exit_code;
        if (detail.len > 0) self.setDetailLocked(detail);
        self.emitLocked(true, true);
        self.clearSpinnerLocked();
    }

    // ── Internals (mutex held) ──────────────────────────────────────────

    fn setDetailLocked(self: *Reporter, detail: []const u8) void {
        const n = @min(detail.len, self.detail_buf.len);
        @memcpy(self.detail_buf[0..n], detail[0..n]);
        self.detail_len = n;
    }

    fn detailSliceLocked(self: *const Reporter) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }

    fn elapsedMs(self: *const Reporter) u64 {
        const now = std.Io.Timestamp.now(self.io, .awake);
        const ms = self.start.durationTo(now).toMilliseconds();
        return if (ms > 0) @intCast(ms) else 0;
    }

    fn wallMs(self: *const Reporter) u64 {
        const ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        return if (ms > 0) @intCast(ms) else 0;
    }

    fn recordLocked(self: *const Reporter, elapsed: u64) Record {
        const percent: ?f32 = blk: {
            const s = self.step orelse break :blk null;
            const t = self.total orelse break :blk null;
            if (t == 0) break :blk null;
            const p = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(t)) * 100.0;
            break :blk @round(@min(p, 100.0) * 10.0) / 10.0;
        };
        return .{
            .phase = self.machine.current orelse .resolve,
            .step = self.step,
            .total = self.total,
            .percent = percent,
            .detail = self.detailSliceLocked(),
            .elapsed_ms = elapsed,
            .exit_code = self.exit_code,
            .updated_at_ms = self.wallMs(),
        };
    }

    /// Fan one record out to the three sinks, honoring per-sink throttles.
    /// `force` (phase transitions, terminal records) bypasses throttling
    /// for the NDJSON stream and the status file. `changed` marks a record
    /// whose data differs from the last one: changes stream at up to
    /// 1/200ms, while pure keepalives (elapsed only) drop to 1/s.
    fn emitLocked(self: *Reporter, force: bool, changed: bool) void {
        const elapsed = self.elapsedMs();
        var enc_buf: [512 + max_detail_len * 6]u8 = undefined;
        const line = encodeRecord(&enc_buf, self.recordLocked(elapsed)) catch return;

        if (self.mode == .json) {
            const due_change = changed and elapsed >= self.last_json_ms + json_change_throttle_ms;
            const due_heartbeat = elapsed >= self.last_json_ms + json_heartbeat_ms;
            if (force or due_change or due_heartbeat or !self.json_ever_written) {
                self.writeJsonLine(line);
                self.last_json_ms = elapsed;
                self.json_ever_written = true;
            }
        }

        if (force or !self.file_ever_written or elapsed >= self.last_file_ms + file_throttle_ms) {
            writeFileAtomic(self.io, self.status_path, self.tmp_path, line) catch {};
            self.last_file_ms = elapsed;
            self.file_ever_written = true;
        }

        if (self.mode == .human and self.stderr_is_tty) {
            if (force or elapsed >= self.last_spin_ms + spinner_throttle_ms) {
                self.drawSpinnerLocked(elapsed);
                self.last_spin_ms = elapsed;
            }
        }
    }

    fn writeJsonLine(self: *Reporter, line: []const u8) void {
        // MUST be a *streaming* writer: the positional variant tracks its
        // own offset starting at 0, so with stdout redirected to a file
        // every record would overwrite the first line (found by the #284
        // smoke test). Streaming writes append at the fd's own offset.
        var w = std.Io.File.stdout().writerStreaming(self.io, &.{});
        var vec = [2][]const u8{ line, "\n" };
        w.interface.writeVecAll(&vec) catch return;
        w.interface.flush() catch return;
    }

    /// Single-line spinner on TTY stderr. Only during compile/link — in the
    /// other phases a child process (assembler, game) owns the terminal and
    /// a rewriting line would fight its output. No ANSI escapes: the line is
    /// cleared by overwriting with spaces, so it renders anywhere.
    fn drawSpinnerLocked(self: *Reporter, elapsed: u64) void {
        const phase = self.machine.current orelse return;
        if (phase != .compile and phase != .link) {
            self.clearSpinnerLocked();
            return;
        }
        var line_buf: [160]u8 = undefined;
        var w = std.Io.Writer.fixed(&line_buf);
        const frame = spinner_frames[self.spinner_frame % spinner_frames.len];
        self.spinner_frame +%= 1;
        const secs = @as(f64, @floatFromInt(elapsed)) / 1000.0;
        w.print("{c} {s}", .{ frame, @tagName(phase) }) catch {};
        if (self.step) |s| {
            if (self.total) |t| {
                w.print(" [{d}/{d}]", .{ s, t }) catch {};
            } else {
                w.print(" [{d}]", .{s}) catch {};
            }
        }
        if (self.detail_len > 0) w.print(" {s}", .{self.detailSliceLocked()}) catch {};
        w.print(" ({d:.1}s)", .{secs}) catch {};
        const line = w.buffered();

        var out: [256]u8 = undefined;
        var ow = std.Io.Writer.fixed(&out);
        ow.writeAll("\r") catch return;
        ow.writeAll(line) catch return;
        // Overwrite any residue from a longer previous line.
        if (self.spinner_visible_len > line.len) {
            const pad = @min(self.spinner_visible_len - line.len, out.len - ow.buffered().len);
            for (0..pad) |_| ow.writeAll(" ") catch break;
            ow.writeAll("\r") catch {};
            // Re-draw so the cursor parks at the end of the live text.
            ow.writeAll(line) catch {};
        }
        std.debug.print("{s}", .{ow.buffered()});
        self.spinner_visible_len = line.len;
    }

    fn clearSpinnerLocked(self: *Reporter) void {
        if (self.spinner_visible_len == 0) return;
        var out: [200]u8 = undefined;
        var ow = std.Io.Writer.fixed(&out);
        ow.writeAll("\r") catch return;
        const pad = @min(self.spinner_visible_len, out.len - 2);
        for (0..pad) |_| ow.writeAll(" ") catch break;
        ow.writeAll("\r") catch {};
        std.debug.print("{s}", .{ow.buffered()});
        self.spinner_visible_len = 0;
    }
};

// --- Tests ---

test {
    @import("zspec").runAll(@This());
}

const expect = @import("zspec").expect;

pub const PhaseMachineSpec = struct {
    pub const legal_order = struct {
        test "walks the full pipeline in order" {
            var m = Machine{};
            try m.transition(.resolve);
            try m.transition(.generate);
            try m.transition(.compile);
            try m.transition(.link);
            try m.transition(.run);
            try m.transition(.done);
            try expect.equal(m.current.?, Phase.done);
        }

        test "skipping forward is legal (no link granularity, build-only)" {
            var m = Machine{};
            try m.transition(.resolve);
            try m.transition(.compile); // skipped generate
            try m.transition(.done); // skipped link + run
        }

        test "failed is reachable from any working phase" {
            var m = Machine{};
            try m.transition(.generate);
            try m.transition(.failed);
            try expect.equal(m.current.?, Phase.failed);
        }

        test "failed is reachable before the first phase (early setup error)" {
            var m = Machine{};
            try m.transition(.failed);
        }
    };

    pub const illegal_moves = struct {
        test "moving backward is rejected" {
            var m = Machine{};
            try m.transition(.link);
            try std.testing.expectError(error.InvalidTransition, m.transition(.compile));
        }

        test "re-entering the current phase is rejected" {
            var m = Machine{};
            try m.transition(.compile);
            try std.testing.expectError(error.InvalidTransition, m.transition(.compile));
        }

        test "done before anything started is rejected" {
            var m = Machine{};
            try std.testing.expectError(error.InvalidTransition, m.transition(.done));
        }
    };

    pub const terminal_states = struct {
        test "done absorbs" {
            var m = Machine{};
            try m.transition(.run);
            try m.transition(.done);
            try std.testing.expectError(error.InvalidTransition, m.transition(.run));
            try std.testing.expectError(error.InvalidTransition, m.transition(.failed));
            try expect.toBeTrue(m.isTerminal());
        }

        test "failed absorbs" {
            var m = Machine{};
            try m.transition(.compile);
            try m.transition(.failed);
            try std.testing.expectError(error.InvalidTransition, m.transition(.done));
            try expect.toBeTrue(m.isTerminal());
        }
    };
};

pub const NdjsonEncodingSpec = struct {
    test "encodes a full record as one valid JSON line" {
        var buf: [1024]u8 = undefined;
        const line = try encodeRecord(&buf, .{
            .phase = .compile,
            .step = 34,
            .total = 210,
            .percent = 16.2,
            .detail = "engine.zig",
            .elapsed_ms = 12345,
            .exit_code = null,
            .updated_at_ms = 1700000000000,
        });
        // One line: no embedded newline.
        try std.testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);

        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expectEqualStrings("compile", obj.get("phase").?.string);
        try expect.equal(obj.get("step").?.integer, @as(i64, 34));
        try expect.equal(obj.get("total").?.integer, @as(i64, 210));
        try std.testing.expectEqualStrings("engine.zig", obj.get("detail").?.string);
        try expect.equal(obj.get("elapsed_ms").?.integer, @as(i64, 12345));
        // Unknowns serialize as explicit null so the shape is stable.
        try std.testing.expect(obj.get("exit_code").? == .null);
    }

    test "escapes JSON-hostile detail strings" {
        var buf: [1024]u8 = undefined;
        const line = try encodeRecord(&buf, .{
            .phase = .failed,
            .detail = "quote\" backslash\\ newline\n",
            .exit_code = 2,
        });
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(
            "quote\" backslash\\ newline\n",
            parsed.value.object.get("detail").?.string,
        );
        try expect.equal(parsed.value.object.get("exit_code").?.integer, @as(i64, 2));
    }

    test "terminal record carries phase failed and exit code" {
        var buf: [1024]u8 = undefined;
        const line = try encodeRecord(&buf, .{ .phase = .failed, .exit_code = 1, .elapsed_ms = 7 });
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("failed", parsed.value.object.get("phase").?.string);
        try expect.equal(parsed.value.object.get("exit_code").?.integer, @as(i64, 1));
    }
};

pub const AtomicStatusFileSpec = struct {
    test "temp file is renamed over the destination and remains parseable" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const io = std.testing.io;

        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &path_buf);
        const base = path_buf[0..n];

        const final_path = try std.fs.path.join(std.testing.allocator, &.{ base, status_file_name });
        defer std.testing.allocator.free(final_path);
        const tmp_path = try std.fs.path.join(std.testing.allocator, &.{ base, status_tmp_name });
        defer std.testing.allocator.free(tmp_path);

        // First write.
        try writeFileAtomic(io, final_path, tmp_path, "{\"phase\":\"resolve\"}");
        // Overwrite (the mid-build rewrite path).
        try writeFileAtomic(io, final_path, tmp_path, "{\"phase\":\"compile\"}");

        const got = try std.Io.Dir.cwd().readFileAlloc(io, final_path, std.testing.allocator, .limited(4096));
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("{\"phase\":\"compile\"}", got);

        // The temp file must not linger after a successful publish.
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, tmp_path, .{}));
    }
};

/// Integration-ish: drive the reporter through a fake build and assert the
/// status file advances through the phases and lands terminal — the exact
/// contract `labelle status` and studio#28 rely on.
pub const ReporterPipelineSpec = struct {
    fn readPhase(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
        defer allocator.free(raw);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        return allocator.dupe(u8, parsed.value.object.get("phase").?.string);
    }

    test "fake build: resolve → generate → compile updates → done, status file tracks" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const io = std.testing.io;
        const allocator = std.testing.allocator;

        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &path_buf);
        const target_dir = try std.fs.path.join(allocator, &.{ path_buf[0..n], "raylib_desktop" });
        defer allocator.free(target_dir);

        var rep = try Reporter.init(allocator, io, .off, target_dir);
        defer rep.deinit();

        rep.beginPhase(.resolve, "resolving packages");
        {
            const phase = try readPhase(io, allocator, rep.status_path);
            defer allocator.free(phase);
            try std.testing.expectEqualStrings("resolve", phase);
        }

        rep.beginPhase(.generate, "assembler generate");
        rep.beginPhase(.compile, "zig build");
        rep.compileUpdate(3, 10, "game.zig", false);
        rep.compileUpdate(9, 10, "linking game", true); // flips to link
        {
            const phase = try readPhase(io, allocator, rep.status_path);
            defer allocator.free(phase);
            try std.testing.expectEqualStrings("link", phase);
        }

        rep.beginPhase(.run, "game");
        rep.finishDone(0);
        {
            const raw = try std.Io.Dir.cwd().readFileAlloc(io, rep.status_path, allocator, .limited(64 * 1024));
            defer allocator.free(raw);
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings("done", parsed.value.object.get("phase").?.string);
            try expect.equal(parsed.value.object.get("exit_code").?.integer, @as(i64, 0));
        }

        // Terminal absorbs: further updates must not resurrect the build.
        rep.compileUpdate(1, 2, "zombie", false);
        rep.finishFailed(1, "late");
        {
            const phase = try readPhase(io, allocator, rep.status_path);
            defer allocator.free(phase);
            try std.testing.expectEqualStrings("done", phase);
        }
    }

    test "failure path: compile error ends failed with the zig exit code" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const io = std.testing.io;
        const allocator = std.testing.allocator;

        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &path_buf);
        const target_dir = try std.fs.path.join(allocator, &.{ path_buf[0..n], "bgfx_desktop" });
        defer allocator.free(target_dir);

        var rep = try Reporter.init(allocator, io, .off, target_dir);
        defer rep.deinit();

        rep.beginPhase(.resolve, "");
        rep.beginPhase(.compile, "zig build");
        rep.finishFailed(2, "zig build failed");

        const raw = try std.Io.Dir.cwd().readFileAlloc(io, rep.status_path, allocator, .limited(64 * 1024));
        defer allocator.free(raw);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("failed", parsed.value.object.get("phase").?.string);
        try expect.equal(parsed.value.object.get("exit_code").?.integer, @as(i64, 2));
        // cli#318: the terminal record names the failing stage so a feed
        // consumer learns WHY the build died, not just THAT it did.
        try std.testing.expectEqualStrings("zig build failed", parsed.value.object.get("detail").?.string);

        // failIfActive after an explicit terminal record is a no-op.
        rep.failIfActive(9, "late");
        const raw2 = try std.Io.Dir.cwd().readFileAlloc(io, rep.status_path, allocator, .limited(64 * 1024));
        defer allocator.free(raw2);
        const parsed2 = try std.json.parseFromSlice(std.json.Value, allocator, raw2, .{});
        defer parsed2.deinit();
        try expect.equal(parsed2.value.object.get("exit_code").?.integer, @as(i64, 2));
        try std.testing.expectEqualStrings("zig build failed", parsed2.value.object.get("detail").?.string);
    }

    test "failIfActive ends a live build failed with the caller's stage label" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const io = std.testing.io;
        const allocator = std.testing.allocator;

        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &path_buf);
        const target_dir = try std.fs.path.join(allocator, &.{ path_buf[0..n], "raylib_desktop" });
        defer allocator.free(target_dir);

        var rep = try Reporter.init(allocator, io, .off, target_dir);
        defer rep.deinit();

        // The cli#318 contract: an early-error path (errdefer / fatalExit)
        // must surface its stage label in the terminal record — never the
        // bare "error" the pre-#318 code wrote.
        rep.beginPhase(.generate, "assembler generate");
        rep.failIfActive(1, "assembler generate failed");

        const raw = try std.Io.Dir.cwd().readFileAlloc(io, rep.status_path, allocator, .limited(64 * 1024));
        defer allocator.free(raw);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("failed", parsed.value.object.get("phase").?.string);
        try expect.equal(parsed.value.object.get("exit_code").?.integer, @as(i64, 1));
        try std.testing.expectEqualStrings("assembler generate failed", parsed.value.object.get("detail").?.string);
    }

    test "failActiveStage composes the detail from the live phase" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const io = std.testing.io;
        const allocator = std.testing.allocator;

        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &path_buf);
        const target_dir = try std.fs.path.join(allocator, &.{ path_buf[0..n], "raylib_desktop" });
        defer allocator.free(target_dir);

        var rep = try Reporter.init(allocator, io, .off, target_dir);
        defer rep.deinit();

        // The catch-all errdefer path (pipeline.zig): the terminal record's
        // phase flips to "failed", so the detail must carry the stage that
        // was live when the error returned (cli#318 / PR #325 review).
        rep.beginPhase(.resolve, "");
        rep.beginPhase(.generate, "assembler generate");
        rep.failActiveStage(1);

        const raw = try std.Io.Dir.cwd().readFileAlloc(io, rep.status_path, allocator, .limited(64 * 1024));
        defer allocator.free(raw);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("failed", parsed.value.object.get("phase").?.string);
        try expect.equal(parsed.value.object.get("exit_code").?.integer, @as(i64, 1));
        try std.testing.expectEqualStrings("generate failed", parsed.value.object.get("detail").?.string);
    }

    test "failActiveStage before any phase falls back to a build label" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const io = std.testing.io;
        const allocator = std.testing.allocator;

        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &path_buf);
        const target_dir = try std.fs.path.join(allocator, &.{ path_buf[0..n], "raylib_desktop" });
        defer allocator.free(target_dir);

        var rep = try Reporter.init(allocator, io, .off, target_dir);
        defer rep.deinit();

        rep.failActiveStage(1);

        const raw = try std.Io.Dir.cwd().readFileAlloc(io, rep.status_path, allocator, .limited(64 * 1024));
        defer allocator.free(raw);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("failed", parsed.value.object.get("phase").?.string);
        try std.testing.expectEqualStrings("build failed", parsed.value.object.get("detail").?.string);
    }
};
