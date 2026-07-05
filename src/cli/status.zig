//! `labelle status [dir] [--json]` — one-shot read of the live build
//! status file (labelle-cli#284).
//!
//! Answers "how far along is the build / is it stuck?" from a second
//! terminal without touching the running build: reads
//! `.labelle/<target>/.build-progress.json` (written atomically by the
//! build's `progress.Reporter` in every mode) and prints it human-readably
//! or as raw JSON.
//!
//! Rather than re-deriving the `<backend>_<platform>` target from
//! project.labelle (which `--platform=` overrides would defeat), it scans
//! every `.labelle/*/` target dir and reports the record with the newest
//! `updated_at_ms` — i.e. whatever built (or is building) last.

const std = @import("std");
const config = @import("config.zig");
const progress = @import("progress.zig");

/// A parsed status record. Field-for-field the schema `progress.Record`
/// writes, but decoded leniently (`phase` as a plain string, unknown fields
/// ignored, everything defaulted) so a newer CLI's file never breaks an
/// older `labelle status` and vice versa.
pub const FileRecord = struct {
    phase: []const u8 = "",
    step: ?u64 = null,
    total: ?u64 = null,
    percent: ?f32 = null,
    detail: []const u8 = "",
    elapsed_ms: u64 = 0,
    exit_code: ?u8 = null,
    updated_at_ms: u64 = 0,
};

/// A build that stops writing for this long while non-terminal is flagged
/// as possibly dead (the reporter refreshes the file at least ~1/s).
const stale_after_ms: u64 = 10_000;

pub fn cmdStatus(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var dir: []const u8 = ".";
    var dir_set = false;
    var json = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("labelle status: unknown flag '{s}'\n", .{arg});
            std.debug.print("  usage: labelle status [dir] [--json]\n", .{});
            return error.InvalidArguments;
        } else {
            if (dir_set) {
                std.debug.print("labelle status: unexpected argument '{s}'\n", .{arg});
                return error.InvalidArguments;
            }
            dir = arg;
            dir_set = true;
        }
    }

    const io = config.globalIo();
    const found = try findNewestStatus(allocator, io, dir);
    defer if (found) |f| f.deinit(allocator);

    // Streaming writer: the positional variant would rewind a redirected
    // stdout to offset 0 on each construction (see progress.writeJsonLine).
    var out_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &out_buf);

    const f = found orelse {
        if (json) {
            w.interface.writeAll("{\"error\":\"not_found\"}\n") catch {};
        } else {
            w.interface.print(
                "labelle status: no build recorded under '{s}/.labelle/'\n" ++
                    "  run `labelle build` or `labelle run` first.\n",
                .{dir},
            ) catch {};
        }
        w.interface.flush() catch {};
        std.process.exit(1);
    };

    if (json) {
        const trimmed = std.mem.trim(u8, f.raw, &std.ascii.whitespace);
        w.interface.writeAll(trimmed) catch {};
        w.interface.writeAll("\n") catch {};
        w.interface.flush() catch {};
        return;
    }

    const now_ms_i = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const now_ms: u64 = if (now_ms_i > 0) @intCast(now_ms_i) else 0;
    try formatHuman(&w.interface, f.record, f.target, now_ms);
    w.interface.flush() catch {};
}

/// Render one record as the human `labelle status` report. Pure — takes
/// "now" so tests are deterministic.
pub fn formatHuman(
    w: *std.Io.Writer,
    rec: FileRecord,
    target: []const u8,
    now_ms: u64,
) !void {
    try w.print("labelle status: {s}", .{rec.phase});
    if (rec.exit_code) |code| try w.print(" (exit {d})", .{code});
    if (rec.step) |s| {
        if (rec.total) |t| try w.print(" [{d}/{d}]", .{ s, t }) else try w.print(" [{d}]", .{s});
    }
    if (rec.percent) |p| try w.print(" {d:.1}%", .{p});
    if (rec.detail.len > 0) try w.print(" — {s}", .{rec.detail});
    try w.writeAll("\n");

    const age_ms: u64 = if (now_ms > rec.updated_at_ms) now_ms - rec.updated_at_ms else 0;
    const terminal = std.mem.eql(u8, rec.phase, "done") or std.mem.eql(u8, rec.phase, "failed");
    try w.print("  elapsed {d:.1}s, updated {d:.1}s ago  (.labelle/{s})\n", .{
        @as(f64, @floatFromInt(rec.elapsed_ms)) / 1000.0,
        @as(f64, @floatFromInt(age_ms)) / 1000.0,
        target,
    });
    if (!terminal and age_ms > stale_after_ms) {
        try w.print(
            "  warning: no update for {d}s — the build may no longer be running\n",
            .{age_ms / 1000},
        );
    }
}

const Found = struct {
    /// Raw JSON file contents (owned).
    raw: []u8,
    /// Target dir basename, e.g. "bgfx_desktop" (owned).
    target: []u8,
    /// Views into a parsed copy — kept alive by `parsed`.
    record: FileRecord,
    parsed: std.json.Parsed(FileRecord),

    fn deinit(self: Found, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.raw);
        allocator.free(self.target);
    }
};

/// Scan `<dir>/.labelle/*/` for status files and return the one with the
/// newest `updated_at_ms` (unparseable/missing candidates are skipped).
fn findNewestStatus(allocator: std.mem.Allocator, io: std.Io, project_dir: []const u8) !?Found {
    const labelle_dir_path = try std.fs.path.join(allocator, &.{ project_dir, ".labelle" });
    defer allocator.free(labelle_dir_path);

    var labelle_dir = std.Io.Dir.cwd().openDir(io, labelle_dir_path, .{ .iterate = true }) catch return null;
    defer labelle_dir.close(io);

    var best: ?Found = null;
    errdefer if (best) |b| b.deinit(allocator);

    var iter = labelle_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const status_path = try std.fs.path.join(
            allocator,
            &.{ labelle_dir_path, entry.name, progress.status_file_name },
        );
        defer allocator.free(status_path);

        const raw = std.Io.Dir.cwd().readFileAlloc(io, status_path, allocator, .limited(64 * 1024)) catch continue;
        var keep_raw = false;
        defer if (!keep_raw) allocator.free(raw);

        const parsed = std.json.parseFromSlice(FileRecord, allocator, raw, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        var keep_parsed = false;
        defer if (!keep_parsed) parsed.deinit();

        const newer = if (best) |b| parsed.value.updated_at_ms > b.record.updated_at_ms else true;
        if (!newer) continue;

        const target = try allocator.dupe(u8, entry.name);
        if (best) |b| b.deinit(allocator);
        best = .{ .raw = raw, .target = target, .record = parsed.value, .parsed = parsed };
        keep_raw = true;
        keep_parsed = true;
    }
    return best;
}

// --- Tests ---

test {
    @import("zspec").runAll(@This());
}

pub const FormatHumanSpec = struct {
    test "in-flight compile shows phase, counts, percent, detail and target" {
        var buf: [1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try formatHuman(&w, .{
            .phase = "compile",
            .step = 34,
            .total = 210,
            .percent = 16.2,
            .detail = "Semantic Analysis",
            .elapsed_ms = 74_300,
            .updated_at_ms = 1_000_000,
        }, "bgfx_desktop", 1_000_400);
        const out = w.buffered();
        try std.testing.expect(std.mem.indexOf(u8, out, "compile [34/210] 16.2% — Semantic Analysis") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "elapsed 74.3s") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "(.labelle/bgfx_desktop)") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "warning") == null);
    }

    test "silent non-terminal build gets the stale warning" {
        var buf: [1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try formatHuman(&w, .{
            .phase = "compile",
            .elapsed_ms = 5000,
            .updated_at_ms = 1_000_000,
        }, "raylib_desktop", 1_060_000); // 60s later
        try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "may no longer be running") != null);
    }

    test "terminal done shows exit code and never warns" {
        var buf: [1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try formatHuman(&w, .{
            .phase = "done",
            .exit_code = 0,
            .elapsed_ms = 183_200,
            .updated_at_ms = 1_000_000,
        }, "sokol_desktop", 2_000_000); // ages ago
        const out = w.buffered();
        try std.testing.expect(std.mem.indexOf(u8, out, "done (exit 0)") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "warning") == null);
    }

    test "round-trips a record encoded by the reporter's own encoder" {
        var enc_buf: [1024]u8 = undefined;
        const line = try progress.encodeRecord(&enc_buf, .{
            .phase = .failed,
            .detail = "zig build failed",
            .exit_code = 2,
            .elapsed_ms = 900,
            .updated_at_ms = 42,
        });
        const parsed = try std.json.parseFromSlice(FileRecord, std.testing.allocator, line, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        try std.testing.expectEqualStrings("failed", parsed.value.phase);
        try std.testing.expectEqual(@as(?u8, 2), parsed.value.exit_code);

        var buf: [1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try formatHuman(&w, parsed.value, "bgfx_desktop", 42);
        try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "failed (exit 2) — zig build failed") != null);
    }
};
