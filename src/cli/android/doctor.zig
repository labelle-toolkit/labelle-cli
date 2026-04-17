/// `labelle android doctor` — probe the Android SDK/NDK environment
/// and print a report of every required tool. Used as a self-service
/// debugging aid before `build` / `run` / `deploy` try to use the
/// toolchain and blow up with cryptic errors.
const std = @import("std");
const gen = @import("generator");
const android_sdk = @import("../android_sdk.zig");

pub fn runDoctor(allocator: std.mem.Allocator, android_cfg: ?gen.AndroidConfig) !void {
    // Every probe allocates path strings and the checks list; they all
    // live until the report is printed at the end of this function. An
    // arena matches that lifetime exactly and avoids tracking every
    // individual allocation through optional / catch-null branches.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const resolved = android_cfg orelse gen.AndroidConfig{};
    const info = try android_sdk.detect(arena_alloc, .{
        .target_sdk_version = resolved.target_sdk_version,
        // In doctor mode the NDK miss is still a hard failure — builds
        // will fail without it — but we surface every check first so
        // the user sees the full picture.
        .ndk_required = true,
    });

    std.debug.print(
        \\
        \\labelle android doctor
        \\======================
        \\  target SDK: {d}
        \\
    , .{info.target_sdk_version});

    var failures: u32 = 0;
    var optional_misses: u32 = 0;
    for (info.checks) |check| {
        if (check.path) |p| {
            std.debug.print("  [  OK  ] {s}\n           {s}\n", .{ check.name, p });
        } else if (check.required) {
            failures += 1;
            std.debug.print("  [ FAIL ] {s}\n", .{check.name});
            if (check.hint) |h| std.debug.print("           → {s}\n", .{h});
        } else {
            optional_misses += 1;
            std.debug.print("  [ WARN ] {s}\n", .{check.name});
            if (check.hint) |h| std.debug.print("           → {s}\n", .{h});
        }
    }

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("  All required Android tools are present.\n", .{});
        if (optional_misses > 0) {
            std.debug.print("  ({d} optional tool(s) missing — see WARN lines above.)\n", .{optional_misses});
        }
        std.debug.print("\n", .{});
    } else {
        std.debug.print("  {d} required tool(s) missing — see FAIL lines above.\n", .{failures});
        std.debug.print("  Install instructions: https://developer.android.com/tools\n\n", .{});
        return error.AndroidToolsMissing;
    }
}
