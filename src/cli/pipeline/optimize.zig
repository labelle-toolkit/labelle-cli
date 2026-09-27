//! The effective optimize mode of a build (contract §1 `.target_defaults`):
//! an explicit `--optimize` always wins; else the target owner's declared
//! default; else the core's own fallback for the target, if any; else none
//! (Zig's default). Recomputed from the providers of every plan, so a
//! replan picks up an edited default. The wire `optimize` every hook
//! receives is this value (Debug when there is none).
const std = @import("std");
const contract = @import("../provider_contract.zig");
const provider_targets = @import("../provider_targets.zig");
const dispatch = @import("../provider_dispatch.zig");

pub const Source = enum { flag, target_default, core_fallback, none };

pub const Effective = struct {
    mode: ?[]const u8,
    source: Source,
};

/// Pure. `core_fallback` is the core's legacy per-target default, applied
/// only when neither the user nor the owner chose.
pub fn effective(flag: ?[]const u8, owner_default: ?contract.Optimize, core_fallback: ?[]const u8) Effective {
    if (flag) |mode| return .{ .mode = mode, .source = .flag };
    if (owner_default) |mode| return .{ .mode = @tagName(mode), .source = .target_default };
    if (core_fallback) |mode| return .{ .mode = mode, .source = .core_fallback };
    return .{ .mode = null, .source = .none };
}

/// The default the owner of `target` among `providers` declares, if any.
/// The core target has no owner and so no provider default.
pub fn ownerDefault(providers: []const dispatch.Provider, target: []const u8) ?contract.Optimize {
    const owner = provider_targets.ownerOf(providers, target) orelse return null;
    return owner.meta.defaultOptimize(target);
}

test "pipeline optimize: flag, then the owner's default, then the core fallback" {
    // The explicit flag wins over everything, even when it names Debug.
    const flag = effective("Debug", .ReleaseSafe, "ReleaseSafe");
    try std.testing.expectEqualStrings("Debug", flag.mode.?);
    try std.testing.expectEqual(Source.flag, flag.source);
    // The owner's default wins over the core fallback: the source says which
    // rule produced the value, not only what it is.
    const owned = effective(null, .ReleaseFast, "ReleaseSafe");
    try std.testing.expectEqualStrings("ReleaseFast", owned.mode.?);
    try std.testing.expectEqual(Source.target_default, owned.source);
    const same = effective(null, .ReleaseSafe, "ReleaseSafe");
    try std.testing.expectEqual(Source.target_default, same.source);
    const fallback = effective(null, null, "ReleaseSafe");
    try std.testing.expectEqual(Source.core_fallback, fallback.source);
    const none = effective(null, null, null);
    try std.testing.expect(none.mode == null);
    try std.testing.expectEqual(Source.none, none.source);
}

test "pipeline optimize: only the target's owner supplies a default" {
    const owner: dispatch.Provider = .{
        .dep = .{ .name = "owner", .repo = "local:../owner", .version = "1.0.0" },
        .dir = "/owner",
        .meta = .{ .name = "owner", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0", .targets = &.{"probe-target"}, .target_defaults = &.{.{ .target = "probe-target", .optimize = .ReleaseSmall }} },
        .verified = true,
    };
    try std.testing.expectEqual(contract.Optimize.ReleaseSmall, ownerDefault(&.{owner}, "probe-target").?);
    try std.testing.expect(ownerDefault(&.{owner}, "desktop") == null);
    try std.testing.expect(ownerDefault(&.{}, "probe-target") == null);
}
