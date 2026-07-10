// ─────────────────────────────────────────────────────────────────────
// Test helpers — drive the byte-transform pipeline against an arena
// ─────────────────────────────────────────────────────────────────────
//
// Shared by `tests.zig` (legacy transforms 1-4) and `tests_rfc596.zig`
// (RFC #596 transforms 5-9). Moved verbatim from migrate.zig; only the
// `pub` qualifier + scanner/pipeline aliases are new wiring.

const std = @import("std");
const scanner = @import("scanner.zig");
const pipeline = @import("pipeline.zig");

const stripJsoncToJson = scanner.stripJsoncToJson;
const FileCounts = pipeline.FileCounts;
const TransformCtx = pipeline.TransformCtx;
const transformBytes = pipeline.transformBytes;

/// Run transforms 1-4 only on `src` (legacy mode — used by the existing
/// pre-RFC-#596 test suite, whose fixtures expect intermediate shapes
/// that the new transforms would further collapse).
pub fn applyAll(arena: std.mem.Allocator, src: []const u8) ![]u8 {
    return applyImpl(arena, src, "main", false);
}

/// Run every transform, including the RFC #596 set. Used by the new
/// transform-5-through-8 specs.
pub fn applyAllFull(arena: std.mem.Allocator, src: []const u8, basename: []const u8) ![]u8 {
    return applyImpl(arena, src, basename, true);
}

pub fn applyImpl(arena: std.mem.Allocator, src: []const u8, basename: []const u8, rfc596: bool) ![]u8 {
    var counts = FileCounts{};
    return applyImplCounts(arena, src, basename, rfc596, &counts);
}

/// Like `applyImpl` but writes the per-file transform counts into
/// `counts` so stat-accuracy specs can assert on them.
pub fn applyImplCounts(
    arena: std.mem.Allocator,
    src: []const u8,
    basename: []const u8,
    rfc596: bool,
    counts: *FileCounts,
) ![]u8 {
    const stripped = try stripJsoncToJson(arena, src);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, stripped, .{});
    defer parsed.deinit();
    var xrefs: std.StringHashMap(void) = .init(arena);
    const ctx = TransformCtx{
        .basename = basename,
        .xrefs = &xrefs,
        .rel_path = "<test>",
        .rfc596 = rfc596,
    };
    return try transformBytes(arena, src, parsed.value, ctx, counts);
}

/// Run every transform (RFC #596 included) and return the resulting
/// per-file counts alongside the transformed buffer.
pub fn applyAllFullCounts(
    arena: std.mem.Allocator,
    src: []const u8,
    basename: []const u8,
    counts: *FileCounts,
) ![]u8 {
    return applyImplCounts(arena, src, basename, true, counts);
}

/// Convenience for tests — runs `applyAll` (legacy 1-4 only) against an
/// arena so call sites don't have to track every intermediate
/// allocation produced by the byte-level edit pipeline. Returns the
/// final transformed buffer (lives inside the arena).
pub fn applyAllArena(arena: *std.heap.ArenaAllocator, src: []const u8) ![]const u8 {
    return try applyAll(arena.allocator(), src);
}

pub fn applyAllArenaFull(arena: *std.heap.ArenaAllocator, src: []const u8, basename: []const u8) ![]const u8 {
    return try applyAllFull(arena.allocator(), src, basename);
}
