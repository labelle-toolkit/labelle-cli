//! Where a prebuild step's stdout goes under `--progress=json` (cli#448).
//!
//! The NDJSON feed owns stdout, so a step's stdout is routed to the CLI's
//! stderr. The natural way is `StdIo.file = File.stderr()`, and that is
//! still what runs almost everywhere: POSIX dup2()s the descriptor, so the
//! child shares the CLI's open file and its offset, and a terminal stays a
//! terminal (line-buffered, coloured output).
//!
//! On Windows, Zig 0.16's spawn RE-OPENS a `.file` handle for the child
//! instead of duplicating it. A redirected stderr (`2> file`) then gives
//! the child a new file object whose offset starts at 0, and it overwrites
//! the start of the file. Only there, when stderr is a file or pipe and
//! not a console, the step's stdout becomes a pipe that `Relay` copies to
//! stderr:
//!
//! - **By whole lines.** A line is written with one streaming write (which
//!   appends at the shared offset), so the step's own stderr, which it
//!   writes directly, cannot splice into the middle of a long stdout line.
//!   A trailing partial line is flushed when the pipe ends; a line longer
//!   than `max_line` is flushed in pieces rather than buffered unboundedly.
//! - **Off the waiting thread.** The caller reaps the direct child while
//!   the relay runs on its own thread. A step that leaves a background
//!   process holding the pipe open never produces EOF, so once the child
//!   has exited `finish` gives the relay `drain_grace_ns` to empty what is
//!   already buffered and then detaches it rather than blocking the build.
//!   A detached relay keeps copying until the pipe really ends, then frees
//!   itself.
const std = @import("std");

pub const StdoutRoute = enum {
    /// Human/off mode: the step's stdout is the CLI's stdout.
    inherit,
    /// json mode: `StdIo.file = File.stderr()` (dup2 on POSIX; a console on
    /// Windows).
    stderr_file,
    /// json mode on Windows with a redirected stderr: pipe + `Relay`.
    relay,
};

/// The routing table. Pure, so the whole table is unit-tested.
pub fn stdoutRoute(route_to_stderr: bool, os: std.Target.Os.Tag, stderr_is_tty: bool) StdoutRoute {
    if (!route_to_stderr) return .inherit;
    if (os == .windows and !stderr_is_tty) return .relay;
    return .stderr_file;
}

/// How long `finish` waits, after the direct child exited, for the relay to
/// reach EOF before detaching it.
pub const drain_grace_ns: u64 = 500 * std.time.ns_per_ms;

/// A line longer than this is flushed without waiting for its newline.
pub const max_line: usize = 1 << 20;

const running: u8 = 0;
const finished: u8 = 1;
const detached: u8 = 2;

pub const Relay = struct {
    io: std.Io,
    pipe: std.Io.File,
    sink: std.Io.File,
    line: std.ArrayList(u8) = .empty,
    sink_ok: bool = true,
    state: std.atomic.Value(u8) = .init(running),
    thread: std.Thread = undefined,

    const gpa = std.heap.smp_allocator;

    /// Take ownership of `pipe` and start copying it to `sink` on a new
    /// thread. On error nothing was started and `pipe` is still the
    /// caller's.
    pub fn start(io: std.Io, pipe: std.Io.File, sink: std.Io.File) !*Relay {
        const self = try gpa.create(Relay);
        errdefer gpa.destroy(self);
        self.* = .{ .io = io, .pipe = pipe, .sink = sink };
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
        return self;
    }

    /// Call once the direct child has exited. Joins the relay if the pipe
    /// ends within `grace_ns`; otherwise detaches it. `self` is invalid
    /// afterwards either way.
    pub fn finish(self: *Relay, grace_ns: u64) void {
        const step_ns = 10 * std.time.ns_per_ms;
        var waited: u64 = 0;
        while (self.state.load(.acquire) == running and waited < grace_ns) : (waited += step_ns) {
            sleep(self.io, step_ns);
        }
        if (self.state.cmpxchgStrong(running, detached, .acq_rel, .acquire) == null) {
            // Still running: a descendant holds the pipe. The thread frees
            // itself when the pipe finally ends.
            self.thread.detach();
            return;
        }
        self.thread.join();
        self.line.deinit(gpa);
        gpa.destroy(self);
    }

    /// Copy the whole pipe on the calling thread, then release it. The
    /// fallback when no thread could be started.
    pub fn runInline(io: std.Io, pipe: std.Io.File, sink: std.Io.File) void {
        var self: Relay = .{ .io = io, .pipe = pipe, .sink = sink };
        self.pump();
        self.line.deinit(gpa);
    }

    fn threadMain(self: *Relay) void {
        self.pump();
        if (self.state.cmpxchgStrong(running, finished, .acq_rel, .acquire) != null) {
            // `finish` already detached us: nobody will join, so clean up.
            self.line.deinit(gpa);
            gpa.destroy(self);
        }
    }

    fn pump(self: *Relay) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = self.pipe.readStreaming(self.io, &.{&buf}) catch break;
            self.feed(buf[0..n]);
        }
        self.write(self.line.items);
        self.line.clearRetainingCapacity();
        self.pipe.close(self.io);
    }

    /// Buffer `bytes` and write out every complete line, each in one write.
    fn feed(self: *Relay, bytes: []const u8) void {
        self.line.appendSlice(gpa, bytes) catch {
            // Out of memory: keep the bytes flowing, unaligned.
            self.write(self.line.items);
            self.line.clearRetainingCapacity();
            self.write(bytes);
            return;
        };
        const end = if (std.mem.lastIndexOfScalar(u8, self.line.items, '\n')) |i| i + 1 else if (self.line.items.len >= max_line) self.line.items.len else return;
        self.writeLines(self.line.items[0..end]);
        const rest = self.line.items.len - end;
        std.mem.copyForwards(u8, self.line.items[0..rest], self.line.items[end..]);
        self.line.shrinkRetainingCapacity(rest);
    }

    /// One write per line, so another writer can only land between lines.
    fn writeLines(self: *Relay, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            const end = if (std.mem.indexOfScalar(u8, rest, '\n')) |i| i + 1 else rest.len;
            self.write(rest[0..end]);
            rest = rest[end..];
        }
    }

    fn write(self: *Relay, bytes: []const u8) void {
        if (!self.sink_ok or bytes.len == 0) return;
        self.sink.writeStreamingAll(self.io, bytes) catch {
            // The sink is gone: keep draining so the child never blocks.
            self.sink_ok = false;
        };
    }
};

fn sleep(io: std.Io, ns: u64) void {
    io.sleep(.fromNanoseconds(@intCast(ns)), .awake) catch {};
}

// ── Tests ────────────────────────────────────────────────────────────

test {
    @import("zspec").runAll(@This());
}

pub const StdoutRouteSpec = struct {
    test "human and off modes inherit stdout on every OS and terminal" {
        for ([_]std.Target.Os.Tag{ .windows, .linux, .macos }) |os| {
            for ([_]bool{ true, false }) |tty| {
                try std.testing.expectEqual(StdoutRoute.inherit, stdoutRoute(false, os, tty));
            }
        }
    }
    test "json mode relays only on Windows with a redirected stderr" {
        try std.testing.expectEqual(StdoutRoute.relay, stdoutRoute(true, .windows, false));
    }
    test "json mode keeps a Windows console as the stderr file" {
        try std.testing.expectEqual(StdoutRoute.stderr_file, stdoutRoute(true, .windows, true));
    }
    test "json mode on POSIX always hands over the stderr file (dup2)" {
        for ([_]std.Target.Os.Tag{ .linux, .macos }) |os| {
            for ([_]bool{ true, false }) |tty| {
                try std.testing.expectEqual(StdoutRoute.stderr_file, stdoutRoute(true, os, tty));
            }
        }
    }
};
