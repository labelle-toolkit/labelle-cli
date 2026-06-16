//! Build-time ASTC conversion (assembler#340 / epic labelle-gfx#269).
//!
//! Turns an atlas PNG into a GPU-native `.astc` blob by shelling out to a
//! prebuilt `astcenc`, so the engine uploads the compressed blocks with **zero
//! CPU decode** (the runtime loader is labelle-gfx#270 + assembler#343). This
//! operates at the **project.labelle resource level** — over each declared
//! atlas PNG — so it's *packer-agnostic*: it works for free-tex-packer atlases
//! (e.g. flying-platform-labelle) and `labelle pack` outputs alike, rather than
//! hooking into any one packer.
//!
//! This module is the conversion CORE: pure command/path/cache logic that is
//! host-testable, plus a thin `convert` wrapper that runs the binary. The
//! astcenc-binary resolution (download + cache, mirroring the assembler binary)
//! and the build-pipeline wiring land in follow-up slices.

const std = @import("std");

/// ASTC block size — bigger block = fewer bits/pixel = smaller file & GPU
/// footprint, at lower quality. 8x8 (2 bpp) is the sprite-atlas default
/// (visually lossless for game art; see the #339 spike). 4x4 (8 bpp) is the
/// highest quality, for pixel/UI art. Tag names are exactly astcenc's block
/// arguments, so `arg()` is just `@tagName`.
pub const BlockSize = enum {
    @"4x4",
    @"5x5",
    @"6x6",
    @"8x8",
    @"10x10",
    @"12x12",

    pub fn arg(self: BlockSize) []const u8 {
        return @tagName(self);
    }

    /// Parse a `project.labelle` block-size string (e.g. `"8x8"`). Null if it
    /// isn't one of the supported sizes.
    pub fn parse(s: []const u8) ?BlockSize {
        inline for (@typeInfo(BlockSize).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @field(BlockSize, f.name);
        }
        return null;
    }
};

/// astcenc effort/quality preset. `-fast` is a good default — encode time is
/// tiny (~0.16 s for a 4K atlas, measured in #339) and quality is plenty for
/// 2D sprite art.
pub const Quality = enum {
    fastest,
    fast,
    medium,
    thorough,

    pub fn arg(self: Quality) []const u8 {
        return switch (self) {
            .fastest => "-fastest",
            .fast => "-fast",
            .medium => "-medium",
            .thorough => "-thorough",
        };
    }
};

/// Colorspace mode passed to astcenc. Sprite atlases are sRGB-encoded and the
/// renderer samples them byte-for-byte into a passthrough framebuffer (verified
/// in the #339 spike), so `srgb` (`-cs`) is the default.
pub const ColorSpace = enum {
    srgb,
    linear,

    pub fn arg(self: ColorSpace) []const u8 {
        return switch (self) {
            .srgb => "-cs",
            .linear => "-cl",
        };
    }
};

pub const Options = struct {
    block: BlockSize = .@"8x8",
    quality: Quality = .fast,
    colorspace: ColorSpace = .srgb,
};

/// Map an atlas source path to its `.astc` sibling, co-located with the source:
/// `assets/background.png` → `assets/background.astc`. A non-`.png` path just
/// gets `.astc` appended after stripping any extension-less tail is avoided —
/// we only strip a trailing `.png`. Caller owns the returned slice.
pub fn outputPath(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    const stem = if (std.ascii.endsWithIgnoreCase(src, ".png"))
        src[0 .. src.len - ".png".len]
    else
        src;
    return std.fmt.allocPrint(allocator, "{s}.astc", .{stem});
}

/// Build the astcenc argv:  `astcenc -cs <src.png> <out.astc> 8x8 -fast`.
/// Elements borrow the inputs; the caller owns (and frees) the outer slice.
pub fn buildArgs(
    allocator: std.mem.Allocator,
    astcenc_path: []const u8,
    src_png: []const u8,
    out_astc: []const u8,
    opts: Options,
) ![]const []const u8 {
    const args = try allocator.alloc([]const u8, 6);
    args[0] = astcenc_path;
    args[1] = opts.colorspace.arg();
    args[2] = src_png;
    args[3] = out_astc;
    args[4] = opts.block.arg();
    args[5] = opts.quality.arg();
    return args;
}

/// Whether `out_astc` must be (re)encoded from `src_png`: true if the output is
/// missing or older than the source. Cheap mtime check — good enough for a
/// build cache (a content hash is a later refinement). `Stat` is a comptime
/// namespace exposing `fn mtime(path) ?i128`, injected so the decision logic is
/// host-testable without touching the filesystem (the real one stats via Io).
pub fn needsReencode(
    comptime Stat: type,
    src_png: []const u8,
    out_astc: []const u8,
) bool {
    const src_mtime = Stat.mtime(src_png) orelse return true; // can't stat source → attempt encode
    const out_mtime = Stat.mtime(out_astc) orelse return true; // output missing → encode
    return out_mtime < src_mtime; // stale output → re-encode
}

// ── Tests (pure) ─────────────────────────────────────────────────────────────

test "BlockSize.parse round-trips supported sizes and rejects others" {
    try std.testing.expectEqual(BlockSize.@"8x8", BlockSize.parse("8x8").?);
    try std.testing.expectEqual(BlockSize.@"4x4", BlockSize.parse("4x4").?);
    try std.testing.expectEqual(BlockSize.@"12x12", BlockSize.parse("12x12").?);
    try std.testing.expect(BlockSize.parse("7x7") == null);
    try std.testing.expect(BlockSize.parse("") == null);
    try std.testing.expectEqualStrings("8x8", BlockSize.@"8x8".arg());
}

test "Quality/ColorSpace map to astcenc flags" {
    try std.testing.expectEqualStrings("-fast", (Quality.fast).arg());
    try std.testing.expectEqualStrings("-thorough", (Quality.thorough).arg());
    try std.testing.expectEqualStrings("-cs", (ColorSpace.srgb).arg());
    try std.testing.expectEqualStrings("-cl", (ColorSpace.linear).arg());
}

test "outputPath swaps .png for .astc, co-located" {
    const a = std.testing.allocator;
    const o1 = try outputPath(a, "assets/background.png");
    defer a.free(o1);
    try std.testing.expectEqualStrings("assets/background.astc", o1);

    // Case-insensitive .PNG, and a path without .png just appends.
    const o2 = try outputPath(a, "x/Y.PNG");
    defer a.free(o2);
    try std.testing.expectEqualStrings("x/Y.astc", o2);
}

test "buildArgs produces the canonical astcenc command" {
    const a = std.testing.allocator;
    const args = try buildArgs(a, "/bin/astcenc", "in.png", "in.astc", .{ .block = .@"8x8", .quality = .fast, .colorspace = .srgb });
    defer a.free(args);
    try std.testing.expectEqual(@as(usize, 6), args.len);
    try std.testing.expectEqualStrings("/bin/astcenc", args[0]);
    try std.testing.expectEqualStrings("-cs", args[1]);
    try std.testing.expectEqualStrings("in.png", args[2]);
    try std.testing.expectEqualStrings("in.astc", args[3]);
    try std.testing.expectEqualStrings("8x8", args[4]);
    try std.testing.expectEqualStrings("-fast", args[5]);
}

test "needsReencode: missing output / stale output / up-to-date" {
    const FakeStat = struct {
        // Map a couple of paths to fixed mtimes for the decision logic.
        fn mtime(path: []const u8) ?i128 {
            if (std.mem.eql(u8, path, "src.png")) return 100;
            if (std.mem.eql(u8, path, "fresh.astc")) return 200; // newer than source
            if (std.mem.eql(u8, path, "stale.astc")) return 50; // older than source
            return null; // anything else "doesn't exist"
        }
    };
    try std.testing.expect(needsReencode(FakeStat, "src.png", "missing.astc")); // no output
    try std.testing.expect(needsReencode(FakeStat, "src.png", "stale.astc")); // older
    try std.testing.expect(!needsReencode(FakeStat, "src.png", "fresh.astc")); // up to date
    try std.testing.expect(needsReencode(FakeStat, "gone.png", "fresh.astc")); // can't stat source
}
