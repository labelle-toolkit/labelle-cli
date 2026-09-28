//! Test helpers shared by the `watch/` modules' tests.
const std = @import("std");
const tree = @import("tree.zig");
const TreeSignature = tree.TreeSignature;
const pathKey = tree.pathKey;

/// A distinct synthetic tree signature per label, for the baseline tests.
pub fn testSig(label: []const u8) TreeSignature {
    var sig = TreeSignature{};
    sig.mix(label, label.len, 0);
    return sig;
}

/// A scripted rebuild for the baseline tests: the sorted path keys that
/// changed while it ran.
pub fn testDelta(comptime paths: []const []const u8) [paths.len]u64 {
    var keys: [paths.len]u64 = undefined;
    for (paths, 0..) |path, i| keys[i] = pathKey(path);
    std.mem.sort(u64, &keys, {}, std.sort.asc(u64));
    return keys;
}
