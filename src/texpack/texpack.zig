//! In-house sprite-atlas packer. Scans a folder of PNGs, packs them
//! into a single sheet (MaxRects), and writes the `<name>.atlas.png` +
//! `<name>.atlas.json` pair labelle-engine's atlas loader consumes.
//!
//! Exposed as the `texpack` module so `labelle-cli` (build-time) and
//! `labelle-gui` (editor-time) share one implementation. v1 is minimal:
//! folder input, no trimming, no rotation, single packing heuristic.

const std = @import("std");
const maxrects = @import("maxrects.zig");
const atlas_json = @import("atlas_json.zig");

const c = @cImport({
    @cInclude("stb_image.h");
    @cInclude("stb_image_write.h");
});

pub const Options = struct {
    /// Transparent gap reserved to the right/bottom of each sprite, px.
    padding: i32 = 2,
    /// Hard cap on each sheet dimension. Packing fails past this.
    max_size: i32 = 4096,
    /// Crop each sprite's fully-transparent margin before packing, and
    /// record the crop in the sidecar (`trimmed` + `spriteSourceSize`)
    /// so the renderer can put the pixels back where the artist drew
    /// them. Off by default: it is only lossless against a renderer that
    /// APPLIES those offsets — labelle-gfx did not until the trim-offset
    /// fix, and against an older one a trimmed sheet silently re-centres
    /// every frame on its own silhouette.
    trim: bool = false,
};

pub const Result = struct {
    sheet_w: i32,
    sheet_h: i32,
    sprite_count: usize,
    /// Output paths, allocated — free with `deinit`.
    png_path: []u8,
    json_path: []u8,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.png_path);
        allocator.free(self.json_path);
    }
};

pub const Error = error{
    NoImagesFound,
    DecodeFailed,
    EncodeFailed,
    /// Sprites do not fit within `Options.max_size`.
    AtlasTooLarge,
};

const Sprite = struct {
    /// Source filename, used verbatim as the atlas JSON key. Owned.
    name: []u8,
    /// The rect that actually lands in the sheet — the trimmed size under
    /// `Options.trim`, the full canvas otherwise.
    w: i32,
    h: i32,
    /// The authored canvas size (the sidecar's `sourceSize`). Equal to
    /// `w`/`h` when nothing was cropped.
    src_w: i32,
    src_h: i32,
    /// Where `w`×`h` sits inside that canvas (the sidecar's
    /// `spriteSourceSize.x/y`). Zero when nothing was cropped.
    off_x: i32 = 0,
    off_y: i32 = 0,
    /// stb-allocated RGBA pixels of the FULL `src_w`×`src_h` canvas —
    /// freed via `stbi_image_free`. Trimming changes which sub-rect gets
    /// blitted, never the decoded buffer.
    pixels: [*c]u8,
    placed: maxrects.Rect = undefined,

    fn trimmed(self: Sprite) bool {
        return self.w != self.src_w or self.h != self.src_h;
    }
};

/// A sprite's placed rect within its authored canvas — the trim result.
const TrimRect = struct { x: i32, y: i32, w: i32, h: i32 };

/// The opaque bounds of an RGBA image: the smallest rect containing every
/// pixel with a non-zero alpha.
///
/// A fully transparent sprite has no such rect. Rather than emit a 0×0
/// frame — which would divide by zero in UV computation and give the
/// packer a degenerate rect — it keeps a single pixel at the origin. The
/// sprite stays invisible either way; this just keeps every downstream
/// consumer dealing in positive extents.
fn opaqueBounds(pixels: [*c]const u8, w: i32, h: i32) TrimRect {
    const uw: usize = @intCast(w);
    const uh: usize = @intCast(h);
    var min_x: usize = uw;
    var min_y: usize = uh;
    var max_x: usize = 0;
    var max_y: usize = 0;
    var found = false;
    var y: usize = 0;
    while (y < uh) : (y += 1) {
        var x: usize = 0;
        while (x < uw) : (x += 1) {
            if (pixels[(y * uw + x) * 4 + 3] == 0) continue;
            found = true;
            if (x < min_x) min_x = x;
            if (x > max_x) max_x = x;
            if (y < min_y) min_y = y;
            if (y > max_y) max_y = y;
        }
    }
    if (!found) return .{ .x = 0, .y = 0, .w = 1, .h = 1 };
    return .{
        .x = @intCast(min_x),
        .y = @intCast(min_y),
        .w = @intCast(max_x - min_x + 1),
        .h = @intCast(max_y - min_y + 1),
    };
}

/// Pack every PNG in `input_dir` into an atlas written to `out_dir` as
/// `<name>.atlas.png` + `<name>.atlas.json`.
pub fn packDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_dir: []const u8,
    out_dir: []const u8,
    name: []const u8,
    opts: Options,
) !Result {
    var sprites = try decodeFolder(allocator, io, input_dir, opts.trim);
    defer {
        // Free the stb pixels + names before the list buffer — once
        // `deinit` runs, `sprites.items` is undefined.
        freeSprites(allocator, sprites.items);
        sprites.deinit(allocator);
    }
    if (sprites.items.len == 0) return Error.NoImagesFound;

    // Largest-first placement — MaxRects packs big rects better when
    // they go down before the small ones fill the gaps.
    std.mem.sort(Sprite, sprites.items, {}, sizeDesc);

    const sheet = try packAll(allocator, sprites.items, opts);

    const png_bytes = try renderSheetPng(allocator, sprites.items, sheet.w, sheet.h);
    defer allocator.free(png_bytes);

    const png_name = try std.fmt.allocPrint(allocator, "{s}.atlas.png", .{name});
    defer allocator.free(png_name);
    const json_name = try std.fmt.allocPrint(allocator, "{s}.atlas.json", .{name});
    defer allocator.free(json_name);

    // Stable JSON frame order regardless of the size-sorted placement.
    std.mem.sort(Sprite, sprites.items, {}, nameAsc);
    var frames = try allocator.alloc(atlas_json.Frame, sprites.items.len);
    defer allocator.free(frames);
    for (sprites.items, 0..) |s, i| {
        frames[i] = .{
            .name = s.name,
            .x = s.placed.x,
            .y = s.placed.y,
            .w = s.w,
            .h = s.h,
            .src_w = s.src_w,
            .src_h = s.src_h,
            .off_x = s.off_x,
            .off_y = s.off_y,
        };
    }
    const json_bytes = try atlas_json.emit(allocator, frames, sheet.w, sheet.h, png_name);
    defer allocator.free(json_bytes);

    const png_path = try std.fs.path.join(allocator, &.{ out_dir, png_name });
    errdefer allocator.free(png_path);
    const json_path = try std.fs.path.join(allocator, &.{ out_dir, json_name });
    errdefer allocator.free(json_path);

    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = png_path, .data = png_bytes });
    try cwd.writeFile(io, .{ .sub_path = json_path, .data = json_bytes });

    return .{
        .sheet_w = sheet.w,
        .sheet_h = sheet.h,
        .sprite_count = sprites.items.len,
        .png_path = png_path,
        .json_path = json_path,
    };
}

fn sizeDesc(_: void, a: Sprite, b: Sprite) bool {
    const am = @max(a.w, a.h);
    const bm = @max(b.w, b.h);
    if (am != bm) return am > bm;
    // Stable tie-break on name so pack order is deterministic regardless
    // of filesystem iteration order.
    return std.mem.lessThan(u8, a.name, b.name);
}

fn nameAsc(_: void, a: Sprite, b: Sprite) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn freeSprites(allocator: std.mem.Allocator, sprites: []Sprite) void {
    for (sprites) |s| {
        c.stbi_image_free(s.pixels);
        allocator.free(s.name);
    }
}

/// Decode every `.png` under `input_dir`, recursing into sub-folders.
/// Each sprite's key is its path relative to `input_dir` (`/`-separated)
/// so files sharing a basename across sub-folders stay distinct — and
/// that path-style key is what the engine's atlas loader already
/// accepts. Skips our own `.atlas.png` outputs.
fn decodeFolder(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_dir: []const u8,
    trim: bool,
) !std.ArrayList(Sprite) {
    var sprites: std.ArrayList(Sprite) = .empty;
    errdefer {
        freeSprites(allocator, sprites.items);
        sprites.deinit(allocator);
    }
    try scanInto(allocator, io, input_dir, "", trim, &sprites);
    return sprites;
}

/// Recursive worker for `decodeFolder`. `rel` is the directory being
/// scanned, relative to `input_dir` (empty at the top level).
fn scanInto(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_dir: []const u8,
    rel: []const u8,
    trim: bool,
    sprites: *std.ArrayList(Sprite),
) !void {
    const dir_path = if (rel.len == 0)
        input_dir
    else
        try std.fs.path.join(allocator, &.{ input_dir, rel });
    defer if (rel.len != 0) allocator.free(dir_path);

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        // The entry's key/path relative to the input root.
        const rel_key = if (rel.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel, entry.name });
        errdefer allocator.free(rel_key);

        if (entry.kind == .directory) {
            try scanInto(allocator, io, input_dir, rel_key, trim, sprites);
            allocator.free(rel_key);
            continue;
        }
        if (entry.kind != .file or rel_key.len < 4 or
            !std.ascii.eqlIgnoreCase(rel_key[rel_key.len - 4 ..], ".png") or
            std.ascii.endsWithIgnoreCase(rel_key, ".atlas.png"))
        {
            allocator.free(rel_key);
            continue;
        }

        const path = try std.fs.path.join(allocator, &.{ input_dir, rel_key });
        defer allocator.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(bytes);

        var w: c_int = 0;
        var h: c_int = 0;
        var ch: c_int = 0;
        const pixels = c.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &ch, 4);
        if (pixels == null or w <= 0 or h <= 0) return Error.DecodeFailed;
        errdefer c.stbi_image_free(pixels);

        // Trimming is decided here, at decode, so the packer only ever
        // sees the rect it will place — the sheet-size search and the
        // blit both read `w`/`h` and need them already cropped.
        const bounds: TrimRect = if (trim)
            opaqueBounds(pixels, @intCast(w), @intCast(h))
        else
            .{ .x = 0, .y = 0, .w = @intCast(w), .h = @intCast(h) };

        // `rel_key` ownership transfers to the Sprite on success.
        try sprites.append(allocator, .{
            .name = rel_key,
            .w = bounds.w,
            .h = bounds.h,
            .src_w = @intCast(w),
            .src_h = @intCast(h),
            .off_x = bounds.x,
            .off_y = bounds.y,
            .pixels = pixels,
        });
    }
}

const SheetSize = struct { w: i32, h: i32 };

/// Find the smallest power-of-two sheet that fits every sprite, recording
/// each sprite's placement in `sprites[i].placed`.
///
/// Squares are tried first (the cheap search), then each axis is halved
/// for as long as the sprites still fit. Halving matters because square-
/// only sizing quantises to 4x the area: a sheet needing 2.1M px of
/// sprites can only round up to 2048x2048 (4.19M) when 2048x1024 (2.10M)
/// would hold it — a doubling of texture memory for nothing. Non-square
/// power-of-two sheets are what TexturePacker already emitted and what
/// the engine's atlas loader has always read via `meta.size`.
///
/// Padding sits *between* sprites, never at the outer sheet edges, so a
/// single N×N sprite still fits an N×N max-size sheet. We model this by
/// growing the packing bin by `padding` on the right/bottom: each sprite
/// reserves `padding` of trailing gap, and a sprite flush against the
/// sheet edge spends that gap in the extra bin margin instead.
fn packAll(allocator: std.mem.Allocator, sprites: []Sprite, opts: Options) !SheetSize {
    // Start estimate: a square whose area covers the bare sprite area,
    // never smaller than the largest single sprite. This is only a
    // lower-bound starting point — `tryPack` is authoritative and the
    // loop below grows the bin on failure. Padding is deliberately
    // excluded from the area term so a single max-size sprite (whose
    // padded area would otherwise overshoot `max_size`) is not skipped.
    var total_area: i64 = 0;
    var max_dim: i32 = 1;
    for (sprites) |s| {
        total_area += @as(i64, s.w) * @as(i64, s.h);
        // The sprite itself must fit the sheet; trailing padding may
        // overflow into the bin margin, so don't count it here.
        max_dim = @max(max_dim, @max(s.w, s.h));
    }
    var size: i32 = 1;
    while (size < max_dim or @as(i64, size) * @as(i64, size) < total_area) {
        size *= 2;
    }

    while (size <= opts.max_size) : (size *= 2) {
        if (try tryPack(allocator, sprites, size, size, opts.padding)) {
            return shrink(allocator, sprites, .{ .w = size, .h = size }, opts.padding);
        }
    }
    return Error.AtlasTooLarge;
}

/// Halve either axis of an already-fitting sheet for as long as the
/// sprites still fit, smaller axis first so the result is as square as the
/// content allows.
///
/// A failed `tryPack` leaves `sprites[i].placed` holding the placements of
/// a partial run, so the winning size is always re-packed last — the
/// caller blits from `placed` and must not see a rejected layout.
fn shrink(allocator: std.mem.Allocator, sprites: []Sprite, from: SheetSize, padding: i32) !SheetSize {
    // Both axis orders, smallest area wins. A single greedy order is not
    // just suboptimal, it can be 2x off: halving one axis may block a
    // halving of the other that would have gone further. Three sprites of
    // 8x11, 2x6 and 7x14 at padding 0 stall at 32x16 going height-first,
    // while width-first reaches 8x32 — the same sprites in half the
    // texture. Neither order dominates, so try both.
    const by_height = try shrinkGreedy(allocator, sprites, from, padding, .height);
    const by_width = try shrinkGreedy(allocator, sprites, from, padding, .width);
    const best = if (area(by_width) < area(by_height)) by_width else by_height;

    // Restore the winning layout. UNCONDITIONAL: each greedy pass ends on
    // a REJECTED attempt, and the loser ran last, so `sprites[i].placed`
    // never holds the winner's layout at this point. Kept out of an
    // `assert` so the re-pack still runs in release builds, where asserts
    // compile away.
    const refit = try tryPack(allocator, sprites, best.w, best.h, padding);
    if (!refit) return Error.AtlasTooLarge;
    return best;
}

fn area(s: SheetSize) i64 {
    return @as(i64, s.w) * @as(i64, s.h);
}

/// Halve `first` for as long as the sprites fit, then the other axis,
/// repeating until neither budges.
fn shrinkGreedy(
    allocator: std.mem.Allocator,
    sprites: []Sprite,
    from: SheetSize,
    padding: i32,
    first: enum { width, height },
) !SheetSize {
    var best = from;
    while (true) {
        const halved_first = switch (first) {
            .height => try halve(allocator, sprites, &best, .height, padding),
            .width => try halve(allocator, sprites, &best, .width, padding),
        };
        if (halved_first) continue;
        const halved_other = switch (first) {
            .height => try halve(allocator, sprites, &best, .width, padding),
            .width => try halve(allocator, sprites, &best, .height, padding),
        };
        if (!halved_other) break;
    }
    return best;
}

/// Try halving one axis of `size`. Returns whether it stuck.
fn halve(
    allocator: std.mem.Allocator,
    sprites: []Sprite,
    size: *SheetSize,
    axis: enum { width, height },
    padding: i32,
) !bool {
    const dim = switch (axis) {
        .width => size.w,
        .height => size.h,
    };
    if (dim <= 1) return false;
    const smaller = @divExact(dim, 2);
    const w = if (axis == .width) smaller else size.w;
    const h = if (axis == .height) smaller else size.h;
    if (!try tryPack(allocator, sprites, w, h, padding)) return false;
    size.* = .{ .w = w, .h = h };
    return true;
}

/// Attempt to place all sprites into a `sheet_w`×`sheet_h` sheet. The
/// packing bin is grown by `padding` on each axis so trailing
/// inter-sprite gaps of edge sprites land in the margin rather than
/// shrinking usable area. On success every `sprites[i].placed` holds the
/// sprite's rect; on failure the caller retries with a different bin.
fn tryPack(allocator: std.mem.Allocator, sprites: []Sprite, sheet_w: i32, sheet_h: i32, padding: i32) !bool {
    var packer = try maxrects.Packer.init(allocator, sheet_w + padding, sheet_h + padding);
    defer packer.deinit();

    for (sprites) |*s| {
        const slot = try packer.insert(s.w + padding, s.h + padding) orelse return false;
        // The sprite occupies only `w`×`h`; the extra `padding` is the
        // gap to its right/bottom neighbour. Reject placements whose
        // sprite body would spill past the actual sheet edge.
        if (slot.x + s.w > sheet_w or slot.y + s.h > sheet_h) return false;
        s.placed = .{ .x = slot.x, .y = slot.y, .w = s.w, .h = s.h };
    }
    return true;
}

/// Blit every sprite into a transparent sheet and PNG-encode it.
fn renderSheetPng(
    allocator: std.mem.Allocator,
    sprites: []const Sprite,
    sheet_w: i32,
    sheet_h: i32,
) ![]u8 {
    const sw: usize = @intCast(sheet_w);
    const sh: usize = @intCast(sheet_h);
    const sheet = try allocator.alloc(u8, sw * sh * 4);
    defer allocator.free(sheet);
    @memset(sheet, 0);

    for (sprites) |s| {
        const spw: usize = @intCast(s.w);
        const sph: usize = @intCast(s.h);
        const dx: usize = @intCast(s.placed.x);
        const dy: usize = @intCast(s.placed.y);
        // The decoded buffer is always the FULL canvas, so the source
        // stride is `src_w` and each row starts at the trim offset. With
        // no trimming these collapse to `spw` and 0.
        const src_stride: usize = @intCast(s.src_w);
        const ox: usize = @intCast(s.off_x);
        const oy: usize = @intCast(s.off_y);
        var row: usize = 0;
        while (row < sph) : (row += 1) {
            const dst = ((dy + row) * sw + dx) * 4;
            const src = ((oy + row) * src_stride + ox) * 4;
            @memcpy(sheet[dst .. dst + spw * 4], s.pixels[src .. src + spw * 4]);
        }
    }

    var sink: PngSink = .{ .list = .empty, .allocator = allocator };
    errdefer sink.list.deinit(allocator);
    const ok = c.stbi_write_png_to_func(
        pngWrite,
        &sink,
        sheet_w,
        sheet_h,
        4,
        sheet.ptr,
        sheet_w * 4,
    );
    if (ok == 0 or sink.failed) return Error.EncodeFailed;
    return sink.list.toOwnedSlice(allocator);
}

const PngSink = struct {
    list: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    failed: bool = false,
};

/// stb_image_write callback — appends each chunk to the sink's buffer.
fn pngWrite(ctx: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
    const sink: *PngSink = @ptrCast(@alignCast(ctx.?));
    if (sink.failed or size <= 0) return;
    const bytes: [*]const u8 = @ptrCast(data.?);
    sink.list.appendSlice(sink.allocator, bytes[0..@intCast(size)]) catch {
        sink.failed = true;
    };
}

const zspec = @import("zspec");
const expect = zspec.expect;

test {
    // Pull in the per-file specs of the sibling modules, then run this
    // file's own. `maxrects`/`atlas_json` are already imported above.
    zspec.runAll(@This());
}

/// Encode a solid-color `w`×`h` RGBA image to PNG bytes (test fixture).
fn encodeSolidPng(allocator: std.mem.Allocator, w: i32, h: i32, rgba: [4]u8) ![]u8 {
    const px = try allocator.alloc(u8, @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4);
    defer allocator.free(px);
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        px[i + 0] = rgba[0];
        px[i + 1] = rgba[1];
        px[i + 2] = rgba[2];
        px[i + 3] = rgba[3];
    }
    var sink: PngSink = .{ .list = .empty, .allocator = allocator };
    errdefer sink.list.deinit(allocator);
    const ok = c.stbi_write_png_to_func(pngWrite, &sink, w, h, 4, px.ptr, w * 4);
    if (ok == 0 or sink.failed) return error.EncodeFailed;
    return sink.list.toOwnedSlice(allocator);
}

/// Encode a `canvas_w`×`canvas_h` transparent RGBA image with one opaque
/// `rect_w`×`rect_h` block at (`off_x`, `off_y`) — a sprite with a
/// transparent margin for the trimmer to find (test fixture).
fn encodePaddedPng(
    allocator: std.mem.Allocator,
    canvas_w: i32,
    canvas_h: i32,
    off_x: i32,
    off_y: i32,
    rect_w: i32,
    rect_h: i32,
    rgba: [4]u8,
) ![]u8 {
    const cw: usize = @intCast(canvas_w);
    const ch: usize = @intCast(canvas_h);
    const px = try allocator.alloc(u8, cw * ch * 4);
    defer allocator.free(px);
    @memset(px, 0);
    var y: usize = @intCast(off_y);
    while (y < @as(usize, @intCast(off_y + rect_h))) : (y += 1) {
        var x: usize = @intCast(off_x);
        while (x < @as(usize, @intCast(off_x + rect_w))) : (x += 1) {
            const i = (y * cw + x) * 4;
            px[i + 0] = rgba[0];
            px[i + 1] = rgba[1];
            px[i + 2] = rgba[2];
            px[i + 3] = rgba[3];
        }
    }
    var sink: PngSink = .{ .list = .empty, .allocator = allocator };
    errdefer sink.list.deinit(allocator);
    const ok = c.stbi_write_png_to_func(pngWrite, &sink, canvas_w, canvas_h, 4, px.ptr, canvas_w * 4);
    if (ok == 0 or sink.failed) return error.EncodeFailed;
    return sink.list.toOwnedSlice(allocator);
}

pub const Trimming = struct {
    /// Write one padded fixture into a scratch dir and pack it.
    /// `sub` keeps concurrent specs off each other's directories.
    fn packOne(
        allocator: std.mem.Allocator,
        io: std.Io,
        sub: []const u8,
        png: []const u8,
        opts: Options,
    ) !struct { result: Result, work: []const u8 } {
        const cwd = std.Io.Dir.cwd();
        cwd.deleteTree(io, sub) catch {};
        try cwd.createDirPath(io, sub);
        const path = try std.fs.path.join(allocator, &.{ sub, "pad.png" });
        defer allocator.free(path);
        try cwd.writeFile(io, .{ .sub_path = path, .data = png });
        return .{ .result = try packDir(allocator, io, sub, sub, "sheet", opts), .work = sub };
    }

    test "--trim crops the transparent margin and records where it was" {
        const allocator = std.testing.allocator;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const cwd = std.Io.Dir.cwd();

        // 40x30 canvas, opaque 10x8 block at (12, 9).
        const png = try encodePaddedPng(allocator, 40, 30, 12, 9, 10, 8, .{ 255, 0, 0, 255 });
        defer allocator.free(png);
        const work = ".zig-cache/texpack-trim";
        const packed_result = try packOne(allocator, io, work, png, .{ .trim = true });
        defer packed_result.result.deinit(allocator);
        defer cwd.deleteTree(io, work) catch {};

        const json = try cwd.readFileAlloc(io, packed_result.result.json_path, allocator, .limited(1 << 20));
        defer allocator.free(json);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        const f = parsed.value.object.get("frames").?.object.get("pad.png").?.object;

        // The sheet holds only the opaque block...
        const frame = f.get("frame").?.object;
        try expect.equal(frame.get("w").?.integer, @as(i64, 10));
        try expect.equal(frame.get("h").?.integer, @as(i64, 8));
        // ...and the sidecar remembers the canvas it came out of, so the
        // renderer can put it back. Without these three the crop is a
        // silent position change, not a storage optimisation.
        try expect.toBeTrue(f.get("trimmed").?.bool);
        const sss = f.get("spriteSourceSize").?.object;
        try expect.equal(sss.get("x").?.integer, @as(i64, 12));
        try expect.equal(sss.get("y").?.integer, @as(i64, 9));
        const src = f.get("sourceSize").?.object;
        try expect.equal(src.get("w").?.integer, @as(i64, 40));
        try expect.equal(src.get("h").?.integer, @as(i64, 30));
    }

    test "--trim blits the cropped sub-rect, not the canvas corner" {
        // The blit reads from the FULL decoded canvas at the trim offset.
        // Getting that stride/offset wrong yields a sheet of transparent
        // pixels that no JSON assertion would catch.
        const allocator = std.testing.allocator;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const cwd = std.Io.Dir.cwd();

        const png = try encodePaddedPng(allocator, 40, 30, 12, 9, 10, 8, .{ 255, 0, 0, 255 });
        defer allocator.free(png);
        const work = ".zig-cache/texpack-trim-blit";
        const packed_result = try packOne(allocator, io, work, png, .{ .trim = true });
        defer packed_result.result.deinit(allocator);
        defer cwd.deleteTree(io, work) catch {};

        const png_bytes = try cwd.readFileAlloc(io, packed_result.result.png_path, allocator, .limited(1 << 24));
        defer allocator.free(png_bytes);
        var dw: c_int = 0;
        var dh: c_int = 0;
        var dch: c_int = 0;
        const pixels = c.stbi_load_from_memory(png_bytes.ptr, @intCast(png_bytes.len), &dw, &dh, &dch, 4);
        try expect.notToBeNull(pixels);
        defer c.stbi_image_free(pixels);

        // Every pixel of the packed 10x8 rect is the opaque red block.
        const sw: usize = @intCast(dw);
        var y: usize = 0;
        var opaque_count: usize = 0;
        while (y < 8) : (y += 1) {
            var x: usize = 0;
            while (x < 10) : (x += 1) {
                const i = (y * sw + x) * 4;
                try expect.equal(pixels[i + 0], @as(u8, 255));
                try expect.equal(pixels[i + 3], @as(u8, 255));
                opaque_count += 1;
            }
        }
        try expect.equal(opaque_count, @as(usize, 80));
    }

    test "trimming is off by default — the canvas is packed whole" {
        // The regression guard for every existing caller: without the
        // flag, a padded sprite keeps its margin and its zero offsets.
        const allocator = std.testing.allocator;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const cwd = std.Io.Dir.cwd();

        const png = try encodePaddedPng(allocator, 40, 30, 12, 9, 10, 8, .{ 255, 0, 0, 255 });
        defer allocator.free(png);
        const work = ".zig-cache/texpack-notrim";
        const packed_result = try packOne(allocator, io, work, png, .{});
        defer packed_result.result.deinit(allocator);
        defer cwd.deleteTree(io, work) catch {};

        const json = try cwd.readFileAlloc(io, packed_result.result.json_path, allocator, .limited(1 << 20));
        defer allocator.free(json);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        const f = parsed.value.object.get("frames").?.object.get("pad.png").?.object;

        try expect.equal(f.get("frame").?.object.get("w").?.integer, @as(i64, 40));
        try expect.toBeFalse(f.get("trimmed").?.bool);
        try expect.equal(f.get("spriteSourceSize").?.object.get("x").?.integer, @as(i64, 0));
        try expect.equal(f.get("sourceSize").?.object.get("w").?.integer, @as(i64, 40));
    }

    test "a fully transparent sprite keeps a 1x1 frame instead of 0x0" {
        const allocator = std.testing.allocator;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const cwd = std.Io.Dir.cwd();

        // No opaque pixel anywhere: a 0x0 crop would divide by zero in UV
        // computation downstream.
        const png = try encodePaddedPng(allocator, 16, 16, 0, 0, 0, 0, .{ 0, 0, 0, 0 });
        defer allocator.free(png);
        const work = ".zig-cache/texpack-empty";
        const packed_result = try packOne(allocator, io, work, png, .{ .trim = true });
        defer packed_result.result.deinit(allocator);
        defer cwd.deleteTree(io, work) catch {};

        const json = try cwd.readFileAlloc(io, packed_result.result.json_path, allocator, .limited(1 << 20));
        defer allocator.free(json);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        const frame = parsed.value.object.get("frames").?.object.get("pad.png").?.object.get("frame").?.object;
        try expect.equal(frame.get("w").?.integer, @as(i64, 1));
        try expect.equal(frame.get("h").?.integer, @as(i64, 1));
    }
};

pub const NonSquareSheets = struct {
    test "the shrink search beats a single greedy axis order" {
        // Codex's counterexample on #349: halving height first stalls at
        // 32x16, while width-first fits the same three sprites in 8x32 —
        // half the texture. Whichever order the search prefers, it must
        // not return the larger of the two.
        const allocator = std.testing.allocator;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const cwd = std.Io.Dir.cwd();
        const work = ".zig-cache/texpack-shrink-order";
        cwd.deleteTree(io, work) catch {};
        try cwd.createDirPath(io, work);
        defer cwd.deleteTree(io, work) catch {};

        const fixtures = [_]struct { name: []const u8, w: i32, h: i32 }{
            .{ .name = "a.png", .w = 8, .h = 11 },
            .{ .name = "b.png", .w = 2, .h = 6 },
            .{ .name = "c.png", .w = 7, .h = 14 },
        };
        for (fixtures) |fx| {
            const png = try encodeSolidPng(allocator, fx.w, fx.h, .{ 255, 0, 0, 255 });
            defer allocator.free(png);
            const path = try std.fs.path.join(allocator, &.{ work, fx.name });
            defer allocator.free(path);
            try cwd.writeFile(io, .{ .sub_path = path, .data = png });
        }

        const result = try packDir(allocator, io, work, work, "sheet", .{ .padding = 0 });
        defer result.deinit(allocator);

        // 32x16 = 512 is what the height-first-only greedy returned.
        const sheet_area = @as(i64, result.sheet_w) * @as(i64, result.sheet_h);
        try expect.toBeTrue(sheet_area <= 256);
    }

    test "a wide sprite set packs into a non-square sheet" {
        // Square-only sizing quantises to 4x the area. These four 64x8
        // strips need 256x8; the old packer rounded to 64x64. Halving the
        // unused axis is what keeps a mostly-flat atlas from paying for
        // empty rows of texture memory.
        const allocator = std.testing.allocator;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const cwd = std.Io.Dir.cwd();
        const work = ".zig-cache/texpack-nonsquare";
        cwd.deleteTree(io, work) catch {};
        try cwd.createDirPath(io, work);
        defer cwd.deleteTree(io, work) catch {};

        for (0..4) |i| {
            const png = try encodeSolidPng(allocator, 64, 8, .{ 255, 0, 0, 255 });
            defer allocator.free(png);
            const name = try std.fmt.allocPrint(allocator, "strip{d}.png", .{i});
            defer allocator.free(name);
            const path = try std.fs.path.join(allocator, &.{ work, name });
            defer allocator.free(path);
            try cwd.writeFile(io, .{ .sub_path = path, .data = png });
        }

        const result = try packDir(allocator, io, work, work, "sheet", .{ .padding = 0 });
        defer result.deinit(allocator);
        try expect.toBeTrue(result.sheet_h < result.sheet_w);
        // And the placements survived the shrink search: a rejected
        // attempt must not leave its partial layout behind.
        const json = try cwd.readFileAlloc(io, result.json_path, allocator, .limited(1 << 20));
        defer allocator.free(json);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        var it = parsed.value.object.get("frames").?.object.iterator();
        while (it.next()) |entry| {
            const f = entry.value_ptr.object.get("frame").?.object;
            try expect.toBeTrue(f.get("x").?.integer + f.get("w").?.integer <= result.sheet_w);
            try expect.toBeTrue(f.get("y").?.integer + f.get("h").?.integer <= result.sheet_h);
        }
    }
};

pub const PackDir = struct {
    test "packs a folder into a valid atlas pair" {
        const allocator = std.testing.allocator;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const cwd = std.Io.Dir.cwd();
        const work = ".zig-cache/texpack-itest";
        cwd.deleteTree(io, work) catch {};
        try cwd.createDirPath(io, work);
        defer cwd.deleteTree(io, work) catch {};

        // Three differently-sized fixtures with distinct colors.
        const fixtures = [_]struct { name: []const u8, w: i32, h: i32, rgba: [4]u8 }{
            .{ .name = "red.png", .w = 30, .h = 20, .rgba = .{ 255, 0, 0, 255 } },
            .{ .name = "green.png", .w = 16, .h = 40, .rgba = .{ 0, 255, 0, 255 } },
            .{ .name = "blue.png", .w = 24, .h = 24, .rgba = .{ 0, 0, 255, 255 } },
        };
        for (fixtures) |fx| {
            const png = try encodeSolidPng(allocator, fx.w, fx.h, fx.rgba);
            defer allocator.free(png);
            const path = try std.fs.path.join(allocator, &.{ work, fx.name });
            defer allocator.free(path);
            try cwd.writeFile(io, .{ .sub_path = path, .data = png });
        }

        const result = try packDir(allocator, io, work, work, "sheet", .{});
        defer result.deinit(allocator);
        try expect.equal(result.sprite_count, @as(usize, 3));

        // The JSON sidecar parses and every frame stays inside the sheet.
        const json = try cwd.readFileAlloc(io, result.json_path, allocator, .limited(1 << 20));
        defer allocator.free(json);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        const frames = parsed.value.object.get("frames").?.object;
        try expect.equal(frames.count(), @as(usize, 3));

        var rects: [3]maxrects.Rect = undefined;
        var it = frames.iterator();
        var n: usize = 0;
        while (it.next()) |entry| : (n += 1) {
            const f = entry.value_ptr.object.get("frame").?.object;
            rects[n] = .{
                .x = @intCast(f.get("x").?.integer),
                .y = @intCast(f.get("y").?.integer),
                .w = @intCast(f.get("w").?.integer),
                .h = @intCast(f.get("h").?.integer),
            };
            try expect.toBeTrue(rects[n].x >= 0 and rects[n].y >= 0);
            try expect.toBeTrue(rects[n].x + rects[n].w <= result.sheet_w);
            try expect.toBeTrue(rects[n].y + rects[n].h <= result.sheet_h);
        }
        // No two packed sprites overlap.
        for (rects, 0..) |a, i| {
            for (rects[i + 1 ..]) |b| {
                const disjoint = a.x + a.w <= b.x or b.x + b.w <= a.x or
                    a.y + a.h <= b.y or b.y + b.h <= a.y;
                try expect.toBeTrue(disjoint);
            }
        }

        // The atlas PNG decodes and matches the reported sheet size.
        const png_bytes = try cwd.readFileAlloc(io, result.png_path, allocator, .limited(1 << 24));
        defer allocator.free(png_bytes);
        var dw: c_int = 0;
        var dh: c_int = 0;
        var dch: c_int = 0;
        const pixels = c.stbi_load_from_memory(png_bytes.ptr, @intCast(png_bytes.len), &dw, &dh, &dch, 4);
        try expect.notToBeNull(pixels);
        defer c.stbi_image_free(pixels);
        try expect.equal(@as(i32, @intCast(dw)), result.sheet_w);
        try expect.equal(@as(i32, @intCast(dh)), result.sheet_h);
    }

    test "a single max-size sprite exactly fills the sheet" {
        const allocator = std.testing.allocator;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const cwd = std.Io.Dir.cwd();
        const work = ".zig-cache/texpack-itest-maxfill";
        cwd.deleteTree(io, work) catch {};
        try cwd.createDirPath(io, work);
        defer cwd.deleteTree(io, work) catch {};

        // A 256×256 sprite must pack into a 256-max-size sheet even with
        // padding: edge padding must not eat into usable sheet area.
        const png = try encodeSolidPng(allocator, 256, 256, .{ 1, 2, 3, 255 });
        defer allocator.free(png);
        const path = try std.fs.path.join(allocator, &.{ work, "full.png" });
        defer allocator.free(path);
        try cwd.writeFile(io, .{ .sub_path = path, .data = png });

        const result = try packDir(allocator, io, work, work, "sheet", .{
            .padding = 2,
            .max_size = 256,
        });
        defer result.deinit(allocator);
        try expect.equal(result.sprite_count, @as(usize, 1));
        try expect.equal(result.sheet_w, @as(i32, 256));
        try expect.equal(result.sheet_h, @as(i32, 256));
    }

    test "reports NoImagesFound for an empty folder" {
        const allocator = std.testing.allocator;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const cwd = std.Io.Dir.cwd();
        const work = ".zig-cache/texpack-itest-empty";
        cwd.deleteTree(io, work) catch {};
        try cwd.createDirPath(io, work);
        defer cwd.deleteTree(io, work) catch {};

        try expect.toReturnError(packDir(allocator, io, work, work, "sheet", .{}), Error.NoImagesFound);
    }

    test "recurses sub-folders and keys sprites by relative path" {
        const allocator = std.testing.allocator;
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();

        const cwd = std.Io.Dir.cwd();
        const work = ".zig-cache/texpack-itest-nested";
        cwd.deleteTree(io, work) catch {};
        try cwd.createDirPath(io, work);
        try cwd.createDirPath(io, work ++ "/anim");
        defer cwd.deleteTree(io, work) catch {};

        // One PNG at the root, one inside a sub-folder. Both basenames
        // are `frame.png` — only the relative-path key keeps them apart.
        const fixtures = [_]struct { path: []const u8, key: []const u8 }{
            .{ .path = work ++ "/frame.png", .key = "frame.png" },
            .{ .path = work ++ "/anim/frame.png", .key = "anim/frame.png" },
        };
        for (fixtures) |fx| {
            const png = try encodeSolidPng(allocator, 20, 20, .{ 255, 255, 255, 255 });
            defer allocator.free(png);
            try cwd.writeFile(io, .{ .sub_path = fx.path, .data = png });
        }

        const result = try packDir(allocator, io, work, work, "sheet", .{});
        defer result.deinit(allocator);
        try expect.equal(result.sprite_count, @as(usize, 2));

        const json = try cwd.readFileAlloc(io, result.json_path, allocator, .limited(1 << 20));
        defer allocator.free(json);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
        defer parsed.deinit();
        const frames = parsed.value.object.get("frames").?.object;
        try expect.equal(frames.count(), @as(usize, 2));
        for (fixtures) |fx| {
            try expect.notToBeNull(frames.get(fx.key));
        }
    }
};
