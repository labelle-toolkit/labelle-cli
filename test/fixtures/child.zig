//! Child-process fixture for the runner's exit-status tests (labelle-cli#390).
//!
//! One argument selects the behaviour, so a test can spawn a real process
//! and read the real termination status back through `runner.*Inherit*`:
//!
//!   exit:<n>            exit with code n
//!   abort               abnormal termination (SIGABRT on POSIX)
//!   sleep:<ms>          stay alive for ms, then exit 0
//!   sleep-exit:<ms>:<n> stay alive for ms, then exit n
const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, std.heap.page_allocator);
    defer args.deinit();
    _ = args.skip();
    const spec = args.next() orelse return 64;

    if (std.mem.eql(u8, spec, "abort")) std.process.abort();
    if (std.mem.startsWith(u8, spec, "exit:")) return try std.fmt.parseInt(u8, spec["exit:".len..], 10);
    if (std.mem.startsWith(u8, spec, "sleep:")) {
        sleepMs(try std.fmt.parseInt(u64, spec["sleep:".len..], 10));
        return 0;
    }
    if (std.mem.startsWith(u8, spec, "sleep-exit:")) {
        var it = std.mem.splitScalar(u8, spec["sleep-exit:".len..], ':');
        const ms = try std.fmt.parseInt(u64, it.next() orelse return 64, 10);
        const code = try std.fmt.parseInt(u8, it.next() orelse return 64, 10);
        sleepMs(ms);
        return code;
    }
    return 64;
}

/// 0.16 has no std.Thread.sleep: libc nanosleep on POSIX, Win32 Sleep on
/// Windows (mirrors runner.zig's sleepNanos). The fixture links libc.
fn sleepMs(ms: u64) void {
    if (@import("builtin").os.tag == .windows) {
        const SleepFn = struct {
            extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
        };
        SleepFn.Sleep(@intCast(@min(ms, std.math.maxInt(u32))));
        return;
    }
    var req: std.c.timespec = .{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    var rem: std.c.timespec = undefined;
    while (std.c.nanosleep(&req, &rem) != 0) req = rem;
}
