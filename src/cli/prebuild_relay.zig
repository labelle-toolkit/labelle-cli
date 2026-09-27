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
const builtin = @import("builtin");

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

/// Ownership protocol for a threaded `Relay` (the heap object `self`):
///
/// - `state` starts `running`; `start`'s caller owns `self`.
/// - The worker, at EOF, does ONE cmpxchg `running -> finished`. On success
///   it never touches `self` again (the owner frees it). On failure the
///   state was `detached`, ownership is the worker's, and it frees `self`.
/// - `finish` (the owner) either sees `finished` and joins + frees, or
///   detaches the thread through a LOCAL copy of the handle FIRST and only
///   then publishes `running -> detached`. If that cmpxchg succeeds,
///   ownership has passed to the worker and `finish` returns without
///   touching `self`; if it fails, the worker already published
///   `finished`, so `finish` still owns `self` and frees it (the thread is
///   already detached, so it is not joined).
///
/// So exactly one side frees `self`, and neither side reads it after the
/// cmpxchg that hands it over.
const running: u8 = 0;
const finished: u8 = 1;
const detached: u8 = 2;

pub const Relay = struct {
    io: std.Io,
    pipe: std.Io.File,
    sink: std.Io.File,
    gpa: std.mem.Allocator,
    line: std.ArrayList(u8) = .empty,
    sink_ok: bool = true,
    state: std.atomic.Value(u8) = .init(running),
    thread: std.Thread = undefined,
    /// Test-only interleaving hooks; always null in the CLI.
    hooks: ?*TestHooks = null,

    pub const TestHooks = struct {
        /// Runs in `finish` between detaching the thread and publishing
        /// `detached` (while `finish` still owns `self`).
        after_detach: ?*const fn (*TestHooks, *Relay) void = null,
        /// Set by the worker as its very last action, after any free.
        worker_done: std.atomic.Value(bool) = .init(false),
        /// The write end the test closes to make the worker hit EOF.
        write_end: ?std.Io.File = null,
    };

    /// Take ownership of `pipe` and start copying it to `sink` on a new
    /// thread. On error nothing was started and `pipe` is still the
    /// caller's. `gpa` must be thread-safe: the worker may free `self`.
    pub fn start(gpa: std.mem.Allocator, io: std.Io, pipe: std.Io.File, sink: std.Io.File) !*Relay {
        return startWithHooks(gpa, io, pipe, sink, null);
    }

    fn startWithHooks(gpa: std.mem.Allocator, io: std.Io, pipe: std.Io.File, sink: std.Io.File, hooks: ?*TestHooks) !*Relay {
        const self = try gpa.create(Relay);
        errdefer gpa.destroy(self);
        self.* = .{ .io = io, .pipe = pipe, .sink = sink, .gpa = gpa, .hooks = hooks };
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
        return self;
    }

    /// Call once the direct child has exited. Joins the relay if the pipe
    /// ends within `grace_ns`; otherwise detaches it. `self` is invalid
    /// afterwards either way (protocol above).
    pub fn finish(self: *Relay, grace_ns: u64) void {
        const step_ns = 10 * std.time.ns_per_ms;
        var waited: u64 = 0;
        while (self.state.load(.acquire) == running and waited < grace_ns) : (waited += step_ns) {
            sleep(self.io, step_ns);
        }
        if (self.state.load(.acquire) == running) {
            // A descendant still holds the pipe. Detach through a local
            // copy BEFORE handing `self` to the worker.
            const thread = self.thread;
            thread.detach();
            if (self.hooks) |h| if (h.after_detach) |f| f(h, self);
            if (self.state.cmpxchgStrong(running, detached, .acq_rel, .acquire) == null) {
                return; // The worker owns `self` now; do not touch it.
            }
            // The worker finished in between: `self` is still ours.
            self.destroy();
            return;
        }
        self.thread.join();
        self.destroy();
    }

    /// Copy the whole pipe on the calling thread, then release it. The
    /// fallback when no thread could be started.
    pub fn runInline(gpa: std.mem.Allocator, io: std.Io, pipe: std.Io.File, sink: std.Io.File) void {
        var self: Relay = .{ .io = io, .pipe = pipe, .sink = sink, .gpa = gpa };
        self.pump();
        self.line.deinit(gpa);
    }

    fn destroy(self: *Relay) void {
        const gpa = self.gpa;
        self.line.deinit(gpa);
        gpa.destroy(self);
    }

    fn threadMain(self: *Relay) void {
        const hooks = self.hooks; // `self` may be gone by the end.
        self.pump();
        if (self.state.cmpxchgStrong(running, finished, .acq_rel, .acquire) != null) {
            // `finish` handed `self` over (`detached`): nobody else frees it.
            self.destroy();
        }
        if (hooks) |h| h.worker_done.store(true, .release);
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
        self.line.appendSlice(self.gpa, bytes) catch {
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

/// The `finish`/worker ownership handover (protocol above), with each
/// interleaving forced deterministically. `std.testing.allocator` fails
/// the test on a leak or a double free, and poisons freed memory, so a
/// read of `self` after the other side freed it would surface too.
/// POSIX-only: the fixture needs a raw pipe; the protocol has no OS branch.
pub const RelayOwnershipSpec = struct {
    const Fixture = struct {
        hooks: Relay.TestHooks = .{},
        relay: *Relay = undefined,

        fn begin(f: *Fixture) !void {
            if (builtin.os.tag == .windows) return error.SkipZigTest;
            const fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
            const read_end: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
            f.hooks.write_end = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
            f.relay = try Relay.startWithHooks(std.testing.allocator, std.testing.io, read_end, std.Io.File.stderr(), &f.hooks);
        }

        /// EOF for the worker.
        fn closeWriteEnd(h: *Relay.TestHooks) void {
            if (h.write_end) |w| w.close(std.testing.io);
            h.write_end = null;
        }

        /// The worker's last action has run; it holds nothing any more.
        fn awaitWorker(f: *Fixture) void {
            while (!f.hooks.worker_done.load(.acquire)) sleep(std.testing.io, std.time.ns_per_ms);
        }
    };

    test "EOF right after finish published detached: the worker frees, exactly once" {
        var f: Fixture = .{};
        try f.begin();
        f.relay.finish(0); // Pipe still open: detach and hand `self` over.
        Fixture.closeWriteEnd(&f.hooks); // Now the worker hits EOF and frees.
        f.awaitWorker();
    }

    test "EOF between detach and publish: finish keeps ownership and frees" {
        const Hook = struct {
            fn afterDetach(h: *Relay.TestHooks, r: *Relay) void {
                Fixture.closeWriteEnd(h);
                // Let the worker publish `finished` before `finish` tries
                // to publish `detached`.
                while (r.state.load(.acquire) != finished) sleep(std.testing.io, std.time.ns_per_ms);
            }
        };
        var f: Fixture = .{};
        f.hooks.after_detach = Hook.afterDetach;
        try f.begin();
        f.relay.finish(0);
        f.awaitWorker();
    }

    test "EOF within the grace period: finish joins and frees" {
        var f: Fixture = .{};
        try f.begin();
        Fixture.closeWriteEnd(&f.hooks);
        f.relay.finish(10 * std.time.ns_per_s);
        try std.testing.expect(f.hooks.worker_done.load(.acquire));
    }
};
