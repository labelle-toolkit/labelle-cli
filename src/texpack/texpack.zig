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
    w: i32,
    h: i32,
    /// stb-allocated RGBA pixels — freed via `stbi_image_free`.
    pixels: [*c]u8,
    placed: maxrects.Rect = undefined,
};

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
    var sprites = try decodeFolder(allocator, io, input_dir);
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
        frames[i] = .{ .name = s.name, .x = s.placed.x, .y = s.placed.y, .w = s.w, .h = s.h };
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
    return @max(a.w, a.h) > @max(b.w, b.h);
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
) !std.ArrayList(Sprite) {
    var sprites: std.ArrayList(Sprite) = .empty;
    errdefer {
        freeSprites(allocator, sprites.items);
        sprites.deinit(allocator);
    }
    try scanInto(allocator, io, input_dir, "", &sprites);
    return sprites;
}

/// Recursive worker for `decodeFolder`. `rel` is the directory being
/// scanned, relative to `input_dir` (empty at the top level).
fn scanInto(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_dir: []const u8,
    rel: []const u8,
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
            try scanInto(allocator, io, input_dir, rel_key, sprites);
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

        // `rel_key` ownership transfers to the Sprite on success.
        try sprites.append(allocator, .{
            .name = rel_key,
            .w = @intCast(w),
            .h = @intCast(h),
            .pixels = pixels,
        });
    }
}

const SheetSize = struct { w: i32, h: i32 };

/// Find the smallest square power-of-two sheet that fits every sprite,
/// recording each sprite's placement in `sprites[i].placed`.
fn packAll(allocator: std.mem.Allocator, sprites: []Sprite, opts: Options) !SheetSize {
    // Start estimate: a square that comfortably covers the total padded
    // area, never smaller than the largest single sprite.
    var total_area: i64 = 0;
    var max_dim: i32 = 1;
    for (sprites) |s| {
        const pw = s.w + opts.padding;
        const ph = s.h + opts.padding;
        total_area += @as(i64, pw) * @as(i64, ph);
        max_dim = @max(max_dim, @max(pw, ph));
    }
    var size: i32 = 1;
    while (size < max_dim or @as(i64, size) * @as(i64, size) < total_area) {
        size *= 2;
    }

    while (size <= opts.max_size) : (size *= 2) {
        if (try tryPack(allocator, sprites, size, opts.padding)) {
            return .{ .w = size, .h = size };
        }
    }
    return Error.AtlasTooLarge;
}

/// Attempt to place all sprites into a `size`×`size` bin. On success
/// every `sprites[i].placed` holds the sprite's rect; on failure the
/// caller retries with a larger bin.
fn tryPack(allocator: std.mem.Allocator, sprites: []Sprite, size: i32, padding: i32) !bool {
    var packer = try maxrects.Packer.init(allocator, size, size);
    defer packer.deinit();

    for (sprites) |*s| {
        const slot = try packer.insert(s.w + padding, s.h + padding) orelse return false;
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
        var row: usize = 0;
        while (row < sph) : (row += 1) {
            const dst = ((dy + row) * sw + dx) * 4;
            const src = row * spw * 4;
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
