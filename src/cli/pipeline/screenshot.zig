//! The post-run `--screenshot` report: where the capture actually
//! landed, reconciled onto the requested path when the CLI can (cli#356).
const std = @import("std");
const config = @import("../config.zig");
const screenshot_format = @import("../screenshot_format.zig");

/// Extensions a backend may append to the requested screenshot path instead of
/// honoring it verbatim. bgfx writes TGA and appends `.tga` to whatever it is
/// given, so `--screenshot=shot.png` lands at `shot.png.tga` (labelle-bgfx#57).
///
/// The append itself lives in the backend, out of this repo's reach — so once
/// the run is over `ScreenshotProbe.report` finishes the job here instead,
/// re-encoding the capture into the requested format and dropping the
/// doubly-named intermediate (cli#356, `screenshot_format.zig`). Every entry
/// must stay decodable by the vendored stb build (`stb_image_impl.c`).
const screenshot_suffixes = [_][]const u8{ ".tga", ".png", ".bmp" };

/// Pre-run fingerprint of one candidate path. Existence alone is not enough to
/// claim "this run wrote it" — a file left by an EARLIER run would be reported
/// as a fresh capture even when the current one failed, and a stale file at the
/// exact requested path would mask a newly written suffixed one. So compare
/// size+mtime across the run and treat only a created-or-changed file as ours.
const FileStamp = struct {
    existed: bool = false,
    size: u64 = 0,
    mtime_ns: i128 = 0,

    fn take(path: []const u8) FileStamp {
        const st = std.Io.Dir.cwd().statFile(config.globalIo(), path, .{}) catch return .{};
        return .{ .existed = true, .size = st.size, .mtime_ns = st.mtime.nanoseconds };
    }

    /// True when `after` represents a file this run created or rewrote.
    fn changed(before: FileStamp, after: FileStamp) bool {
        if (!after.existed) return false;
        if (!before.existed) return true;
        return before.size != after.size or before.mtime_ns != after.mtime_ns;
    }
};

/// Where a screenshot might land, fingerprinted before the game runs.
///
/// The CLI only forwards `LABELLE_SCREENSHOT_PATH`; the backend owns the real
/// filename and the CLI never verified the result, so a capture written to a
/// different path read as "no screenshot was produced" — the misreading this
/// exists to prevent.
///
/// `run_cwd` is the directory the game runs in, which is NOT the user's cwd:
/// normally `.labelle/<target>/` (so saves land where `zig build run` put
/// them), but `project_dir` under `--docker`. A relative `--screenshot=shot.png`
/// is resolved by the game against that cwd, so that is where to look and what
/// to print — an unqualified relative path would send the user to the wrong
/// directory.
pub const ScreenshotProbe = struct {
    /// Path as the user typed it.
    requested: []const u8,
    /// `requested` resolved against the game's cwd (owned).
    resolved: []const u8,
    /// Index 0 is `resolved`; the rest follow `screenshot_suffixes`.
    before: [1 + screenshot_suffixes.len]FileStamp = @splat(.{}),

    pub fn init(allocator: std.mem.Allocator, requested: []const u8, run_cwd: []const u8) ?ScreenshotProbe {
        const resolved: []const u8 = if (std.fs.path.isAbsolute(requested))
            allocator.dupe(u8, requested) catch return null
        else
            std.fs.path.join(allocator, &.{ run_cwd, requested }) catch return null;

        var probe: ScreenshotProbe = .{ .requested = requested, .resolved = resolved };
        for (0..probe.before.len) |i| {
            const path = probe.candidatePath(allocator, i) orelse continue;
            defer allocator.free(path);
            probe.before[i] = FileStamp.take(path);
        }
        return probe;
    }

    pub fn deinit(self: ScreenshotProbe, allocator: std.mem.Allocator) void {
        allocator.free(self.resolved);
    }

    /// Candidate `i`: 0 is the resolved path itself, then one per suffix.
    fn candidatePath(self: ScreenshotProbe, allocator: std.mem.Allocator, i: usize) ?[]u8 {
        if (i == 0) return allocator.dupe(u8, self.resolved) catch null;
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ self.resolved, screenshot_suffixes[i - 1] }) catch null;
    }

    /// Report where the screenshot ACTUALLY landed, after the game has exited.
    pub fn report(self: ScreenshotProbe, allocator: std.mem.Allocator) void {
        var stale_exact = false;
        for (0..self.before.len) |i| {
            const path = self.candidatePath(allocator, i) orelse continue;
            defer allocator.free(path);
            const after = FileStamp.take(path);
            if (!FileStamp.changed(self.before[i], after)) {
                // Pre-existing and untouched. Worth calling out only for the
                // exact path, where its presence is actively misleading.
                if (i == 0 and after.existed) stale_exact = true;
                continue;
            }
            self.reconcile(allocator, path);
            return;
        }

        std.debug.print("labelle: warning: no screenshot was written (looked for '{s}'", .{self.resolved});
        for (screenshot_suffixes) |suffix| std.debug.print(", '{s}{s}'", .{ self.resolved, suffix });
        std.debug.print(")\n", .{});
        if (stale_exact) {
            std.debug.print("  note: '{s}' exists but is unchanged — it is left over from an earlier run, not this one\n", .{self.resolved});
        }
        std.debug.print("  hint: capture needs a native surface on some backends — a headless bgfx device has no backbuffer to read back\n\n", .{});
    }

    /// The capture landed at `written`. Put it on the requested path when
    /// the CLI can (cli#356) — a same-format move, or a decode/re-encode
    /// through the vendored stb — then print where the file REALLY is.
    ///
    /// Every branch prints exactly one `screenshot written to` line naming
    /// the path that now holds the capture, so the line stays the
    /// authoritative one a script can parse.
    fn reconcile(self: ScreenshotProbe, allocator: std.mem.Allocator, written: []const u8) void {
        const plan = screenshot_format.plan(self.resolved, written);
        switch (plan) {
            .honored => std.debug.print("labelle: screenshot written to '{s}'\n", .{written}),
            .keep => {
                std.debug.print("labelle: screenshot written to '{s}'\n", .{written});
                if (screenshot_format.formatFromPath(self.resolved) == null) {
                    std.debug.print("  note: the backend appended its own extension — '{s}' names no image format, so the capture was left as written\n", .{self.resolved});
                } else {
                    std.debug.print("  note: the backend wrote a format this CLI cannot decode — the requested path '{s}' was not written\n", .{self.resolved});
                }
            },
            .move, .transcode => {
                screenshot_format.apply(allocator, plan, self.resolved, written) catch |err| {
                    // The capture still exists where the backend put it, so
                    // report THAT path — the old pre-#356 behaviour, which is
                    // the honest fallback when the conversion cannot happen.
                    std.debug.print("labelle: screenshot written to '{s}'\n", .{written});
                    std.debug.print("  note: the backend did not honor '{s}' and the CLI could not rewrite it ({s})\n", .{ self.resolved, @errorName(err) });
                    return;
                };
                std.debug.print("labelle: screenshot written to '{s}'\n", .{self.resolved});
                switch (plan) {
                    .move => std.debug.print("  note: the backend wrote '{s}'; moved onto the requested path\n", .{written}),
                    .transcode => |t| std.debug.print("  note: the backend wrote {s} to '{s}'; re-encoded as {s} at the requested path\n", .{ t.from.label(), written, t.to.label() }),
                    else => unreachable,
                }
            },
        }
    }
};

/// The post-run screenshot report end to end (cli#356): a backend that
/// appended its own extension is reconciled onto the requested path.
///
/// Drives the REAL `ScreenshotProbe` — pre-run fingerprint, suffix scan,
/// change detection, reconcile — rather than `screenshot_format` alone, so
/// the wiring between them is covered too. `report` prints to stderr, so
/// the `labelle: screenshot written to ...` lines in the test log are the
/// actual user-facing output.
pub const ScreenshotProbeSpec = struct {
    /// `ScreenshotProbe` resolves relative paths against the game's cwd and
    /// then works from the process cwd, and `std.testing.tmpDir` creates its
    /// directory under a cwd-relative `.zig-cache/tmp/`, so a cwd-relative
    /// `run_cwd` addresses exactly the files the tmp dir holds.
    fn runCwd(allocator: std.mem.Allocator, tmp: std.testing.TmpDir) ![]u8 {
        return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    }

    test "a .png request the backend answered with .png.tga lands as a PNG" {
        const a = std.testing.allocator;
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const run_cwd = try runCwd(a, tmp);
        defer a.free(run_cwd);

        // Fingerprint BEFORE the "run", exactly as the pipeline does.
        const probe = ScreenshotProbe.init(a, "shot.png", run_cwd).?;
        defer probe.deinit(a);

        // The "backend" writes TGA under the doubly-wrong name.
        try screenshot_format.writeTestFixture(a, tmp.dir, "shot.png.tga", .tga);

        probe.report(a);

        const out = try tmp.dir.readFileAlloc(io, "shot.png", a, .unlimited);
        defer a.free(out);
        try std.testing.expect(std.mem.startsWith(u8, out, "\x89PNG\r\n\x1a\n"));
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "shot.png.tga", .{}));
    }

    test "a capture left over from an earlier run is not reconciled" {
        const a = std.testing.allocator;
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const run_cwd = try runCwd(a, tmp);
        defer a.free(run_cwd);

        // Stale file exists BEFORE the probe fingerprints it, and the "run"
        // writes nothing. Touching it would turn a failed capture into a
        // report of a screenshot this run never took.
        try screenshot_format.writeTestFixture(a, tmp.dir, "shot.png.tga", .tga);
        const probe = ScreenshotProbe.init(a, "shot.png", run_cwd).?;
        defer probe.deinit(a);

        probe.report(a);

        _ = try tmp.dir.statFile(io, "shot.png.tga", .{});
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "shot.png", .{}));
    }

    test "an extension-less request is left where the backend put it" {
        const a = std.testing.allocator;
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const run_cwd = try runCwd(a, tmp);
        defer a.free(run_cwd);

        const probe = ScreenshotProbe.init(a, "shot", run_cwd).?;
        defer probe.deinit(a);

        try screenshot_format.writeTestFixture(a, tmp.dir, "shot.tga", .tga);

        probe.report(a);

        // Nothing was asked for, so `shot.tga` is the better name of the two.
        _ = try tmp.dir.statFile(io, "shot.tga", .{});
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "shot", .{}));
    }
};
