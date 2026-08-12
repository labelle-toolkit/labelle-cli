//! Emits the atlas sidecar JSON in TexturePacker JSON-hash format —
//! the shape labelle-engine's atlas loader (`src/atlas.zig`) consumes:
//! a `frames` object keyed by sprite name, plus a `meta` block whose
//! `size` the loader uses to derive a texture scale.

const std = @import("std");

pub const Frame = struct {
    /// Sprite key — the source filename, used verbatim as the JSON key.
    name: []const u8,
    /// Packed position + size within the sheet.
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    /// The authored canvas size (`sourceSize`). Defaults to the packed
    /// size, i.e. nothing was cropped.
    src_w: i32 = 0,
    src_h: i32 = 0,
    /// Where the packed rect sits inside that canvas
    /// (`spriteSourceSize.x/y`).
    off_x: i32 = 0,
    off_y: i32 = 0,

    fn canvasW(self: Frame) i32 {
        return if (self.src_w > 0) self.src_w else self.w;
    }

    fn canvasH(self: Frame) i32 {
        return if (self.src_h > 0) self.src_h else self.h;
    }

    /// TexturePacker's `trimmed` flag: true when the packed rect is
    /// smaller than the canvas it came from.
    fn isTrimmed(self: Frame) bool {
        return self.w != self.canvasW() or self.h != self.canvasH();
    }
};

/// Serialize `frames` into TexturePacker JSON-hash text. No rotation, so
/// `rotated` is always false; a frame that left `src_*`/`off_*` at their
/// defaults is untrimmed and emits `sourceSize` == `frame` size with zero
/// offsets, exactly as before trimming existed. Caller owns the returned
/// slice.
pub fn emit(
    allocator: std.mem.Allocator,
    frames: []const Frame,
    sheet_w: i32,
    sheet_h: i32,
    image_name: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\n  \"frames\": {\n");
    for (frames, 0..) |f, i| {
        try w.writeAll("    ");
        try writeJsonString(w, f.name);
        try w.writeAll(": {\n");
        try w.print(
            "      \"frame\": {{ \"x\": {d}, \"y\": {d}, \"w\": {d}, \"h\": {d} }},\n",
            .{ f.x, f.y, f.w, f.h },
        );
        try w.writeAll("      \"rotated\": false,\n");
        try w.print("      \"trimmed\": {s},\n", .{if (f.isTrimmed()) "true" else "false"});
        try w.print(
            "      \"spriteSourceSize\": {{ \"x\": {d}, \"y\": {d}, \"w\": {d}, \"h\": {d} }},\n",
            .{ f.off_x, f.off_y, f.w, f.h },
        );
        try w.print("      \"sourceSize\": {{ \"w\": {d}, \"h\": {d} }},\n", .{ f.canvasW(), f.canvasH() });
        try w.writeAll("      \"pivot\": { \"x\": 0.5, \"y\": 0.5 }\n");
        try w.writeAll(if (i + 1 < frames.len) "    },\n" else "    }\n");
    }
    try w.writeAll("  },\n  \"meta\": {\n");
    try w.writeAll("    \"app\": \"labelle-texpack\",\n");
    try w.writeAll("    \"format\": \"RGBA8888\",\n");
    try w.writeAll("    \"image\": ");
    try writeJsonString(w, image_name);
    try w.writeAll(",\n");
    try w.print("    \"size\": {{ \"w\": {d}, \"h\": {d} }},\n", .{ sheet_w, sheet_h });
    try w.writeAll("    \"scale\": \"1\"\n");
    try w.writeAll("  }\n}\n");

    var list = aw.toArrayList();
    return list.toOwnedSlice(allocator);
}

/// Write `s` as a quoted, escaped JSON string.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11, 12, 14...31 => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

const zspec = @import("zspec");
const expect = zspec.expect;

test {
    zspec.runAll(@This());
}

pub const Emit = struct {
    test "emits parseable TexturePacker JSON-hash" {
        const alloc = std.testing.allocator;
        const frames = [_]Frame{
            .{ .name = "hero.png", .x = 0, .y = 0, .w = 32, .h = 48 },
            .{ .name = "tile/grass.png", .x = 34, .y = 0, .w = 16, .h = 16 },
        };
        const json = try emit(alloc, &frames, 64, 64, "world.atlas.png");
        defer alloc.free(json);

        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        const root = parsed.value.object;

        const frames_obj = root.get("frames").?.object;
        try expect.equal(frames_obj.count(), @as(usize, 2));

        const grass = frames_obj.get("tile/grass.png").?.object;
        const frame = grass.get("frame").?.object;
        try expect.equal(frame.get("x").?.integer, @as(i64, 34));
        try expect.equal(frame.get("w").?.integer, @as(i64, 16));
        try expect.toBeFalse(grass.get("rotated").?.bool);

        const size = root.get("meta").?.object.get("size").?.object;
        try expect.equal(size.get("w").?.integer, @as(i64, 64));
    }
};
