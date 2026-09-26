//! Helpers shared by the pipeline's watched-rebuild tests
//! (`watch.zig`, `watch_replan_tests.zig`).
const std = @import("std");
const provider_hooks = @import("../provider_hooks.zig");

/// A hook site with no providers, for the rebuild tests: the plans are
/// what the tests supply; nothing here reaches a compiler or a lock.
pub fn testSite(a: std.mem.Allocator, project: []const u8) provider_hooks.Site {
    return .{
        .a = a,
        .backing = a,
        .providers = &.{},
        .root = project,
        .cfg = .{ .name = "game" },
        .target = "wasm",
        .optimize = .ReleaseSafe,
        .progress = .off,
        .reporter = null,
    };
}
