//! MaxRects bin packer (Best Short Side Fit heuristic).
//!
//! Places axis-aligned rectangles into a fixed-size bin without
//! overlap. Reference: Jukka Jylänki, "A Thousand Ways to Pack the
//! Bin" (2010), §3.4. No rotation — v1 packs sprites upright.

const std = @import("std");

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    fn right(r: Rect) i32 {
        return r.x + r.w;
    }
    fn bottom(r: Rect) i32 {
        return r.y + r.h;
    }

    /// True when `inner` is fully contained in `outer` (inclusive).
    fn contains(outer: Rect, inner: Rect) bool {
        return inner.x >= outer.x and inner.y >= outer.y and
            inner.right() <= outer.right() and inner.bottom() <= outer.bottom();
    }

    /// True when the two rects share any interior area.
    fn intersects(a: Rect, b: Rect) bool {
        return a.x < b.right() and a.right() > b.x and
            a.y < b.bottom() and a.bottom() > b.y;
    }
};

pub const Packer = struct {
    bin_w: i32,
    bin_h: i32,
    free: std.ArrayList(Rect),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, bin_w: i32, bin_h: i32) !Packer {
        var free: std.ArrayList(Rect) = .empty;
        try free.append(allocator, .{ .x = 0, .y = 0, .w = bin_w, .h = bin_h });
        return .{
            .bin_w = bin_w,
            .bin_h = bin_h,
            .free = free,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Packer) void {
        self.free.deinit(self.allocator);
    }

    /// Place a `w`×`h` rectangle. Returns its position in the bin, or
    /// `null` when it does not fit anywhere in the remaining space.
    pub fn insert(self: *Packer, w: i32, h: i32) !?Rect {
        const best = self.findFreeNode(w, h) orelse return null;
        try self.placeRect(best);
        return best;
    }

    /// Best Short Side Fit: among free nodes the rect fits in, pick the
    /// one minimizing the smaller leftover side; tie-break on the larger.
    fn findFreeNode(self: *Packer, w: i32, h: i32) ?Rect {
        var best: ?Rect = null;
        var best_short: i32 = std.math.maxInt(i32);
        var best_long: i32 = std.math.maxInt(i32);

        for (self.free.items) |node| {
            if (node.w < w or node.h < h) continue;
            const leftover_h = node.w - w;
            const leftover_v = node.h - h;
            const short_fit = @min(leftover_h, leftover_v);
            const long_fit = @max(leftover_h, leftover_v);
            if (short_fit < best_short or (short_fit == best_short and long_fit < best_long)) {
                best = .{ .x = node.x, .y = node.y, .w = w, .h = h };
                best_short = short_fit;
                best_long = long_fit;
            }
        }
        return best;
    }

    /// Carve `placed` out of every overlapping free node, then prune
    /// free nodes that became fully contained in another.
    fn placeRect(self: *Packer, placed: Rect) !void {
        var i: usize = 0;
        while (i < self.free.items.len) {
            const node = self.free.items[i];
            if (try self.splitFreeNode(node, placed)) {
                _ = self.free.swapRemove(i);
            } else {
                i += 1;
            }
        }
        self.pruneFreeList();
    }

    /// If `placed` overlaps `node`, append the (up to four) sub-rects of
    /// `node` not covered by `placed` and return true. Otherwise false.
    fn splitFreeNode(self: *Packer, node: Rect, placed: Rect) !bool {
        if (!node.intersects(placed)) return false;

        // Left/right slabs.
        if (placed.x > node.x and placed.x < node.right()) {
            try self.free.append(self.allocator, .{
                .x = node.x,
                .y = node.y,
                .w = placed.x - node.x,
                .h = node.h,
            });
        }
        if (placed.right() < node.right() and placed.right() > node.x) {
            try self.free.append(self.allocator, .{
                .x = placed.right(),
                .y = node.y,
                .w = node.right() - placed.right(),
                .h = node.h,
            });
        }
        // Top/bottom slabs.
        if (placed.y > node.y and placed.y < node.bottom()) {
            try self.free.append(self.allocator, .{
                .x = node.x,
                .y = node.y,
                .w = node.w,
                .h = placed.y - node.y,
            });
        }
        if (placed.bottom() < node.bottom() and placed.bottom() > node.y) {
            try self.free.append(self.allocator, .{
                .x = node.x,
                .y = placed.bottom(),
                .w = node.w,
                .h = node.bottom() - placed.bottom(),
            });
        }
        return true;
    }

    /// Drop any free node fully contained inside another.
    fn pruneFreeList(self: *Packer) void {
        var i: usize = 0;
        while (i < self.free.items.len) {
            var j: usize = i + 1;
            var removed_i = false;
            while (j < self.free.items.len) {
                const a = self.free.items[i];
                const b = self.free.items[j];
                if (b.contains(a)) {
                    _ = self.free.swapRemove(i);
                    removed_i = true;
                    break;
                }
                if (a.contains(b)) {
                    _ = self.free.swapRemove(j);
                } else {
                    j += 1;
                }
            }
            if (!removed_i) i += 1;
        }
    }
};

const zspec = @import("zspec");
const expect = zspec.expect;

test {
    zspec.runAll(@This());
}

pub const Packing = struct {
    test "places every rect inside the bin without overlap" {
        var packer = try Packer.init(std.testing.allocator, 128, 128);
        defer packer.deinit();

        const sizes = [_][2]i32{
            .{ 40, 40 }, .{ 30, 60 }, .{ 50, 20 }, .{ 25, 25 },
            .{ 60, 30 }, .{ 16, 16 }, .{ 48, 48 }, .{ 32, 24 },
        };
        var placed: [sizes.len]Rect = undefined;
        for (sizes, 0..) |s, i| {
            placed[i] = (try packer.insert(s[0], s[1])) orelse return error.UnexpectedNoFit;
        }

        for (placed, 0..) |r, i| {
            try expect.toBeTrue(r.x >= 0 and r.y >= 0);
            try expect.toBeTrue(r.right() <= 128 and r.bottom() <= 128);
            for (placed[i + 1 ..]) |other| {
                try expect.toBeFalse(r.intersects(other));
            }
        }
    }

    test "insert returns null when the rect cannot fit" {
        var packer = try Packer.init(std.testing.allocator, 64, 64);
        defer packer.deinit();

        try expect.notToBeNull(try packer.insert(64, 64));
        // Bin is now fully consumed.
        try expect.toBeNull(try packer.insert(1, 1));
    }

    test "a rect larger than the bin never fits" {
        var packer = try Packer.init(std.testing.allocator, 32, 32);
        defer packer.deinit();
        try expect.toBeNull(try packer.insert(33, 10));
    }
};
