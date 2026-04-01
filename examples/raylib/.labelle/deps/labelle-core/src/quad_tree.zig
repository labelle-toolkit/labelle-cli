//! QuadTree spatial partitioning data structure
//!
//! Provides O(log n) spatial queries for points in 2D space.
//! Used for efficient entity lookups and collision detection.

const std = @import("std");
const Position = @import("position.zig").Position;

/// Axis-aligned bounding box
pub const Rectangle = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub const zero = Rectangle{ .x = 0, .y = 0, .width = 0, .height = 0 };

    pub fn fromPosition(pos: Position, width: f32, height: f32) Rectangle {
        return .{ .x = pos.x, .y = pos.y, .width = width, .height = height };
    }

    pub fn centered(pos: Position, width: f32, height: f32) Rectangle {
        return .{
            .x = pos.x - width / 2,
            .y = pos.y - height / 2,
            .width = width,
            .height = height,
        };
    }

    pub fn center(self: Rectangle) Position {
        return .{ .x = self.x + self.width / 2, .y = self.y + self.height / 2 };
    }

    pub fn position(self: Rectangle) Position {
        return .{ .x = self.x, .y = self.y };
    }

    pub fn contains(self: Rectangle, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.width and
            py >= self.y and py < self.y + self.height;
    }

    pub fn containsPosition(self: Rectangle, pos: Position) bool {
        return self.contains(pos.x, pos.y);
    }

    pub fn intersects(self: Rectangle, other: Rectangle) bool {
        return !(other.x >= self.x + self.width or
            other.x + other.width <= self.x or
            other.y >= self.y + self.height or
            other.y + other.height <= self.y);
    }
};

/// A point with an associated identifier
pub fn EntityPoint(comptime T: type) type {
    return struct {
        id: T,
        pos: Position,

        const Self = @This();

        pub fn init(id: T, x: f32, y: f32) Self {
            return .{ .id = id, .pos = .{ .x = x, .y = y } };
        }

        pub fn fromPosition(id: T, pos: Position) Self {
            return .{ .id = id, .pos = pos };
        }
    };
}

/// QuadTree node for internal storage
fn QuadTreeNode(comptime T: type, comptime capacity: u32) type {
    const Point = EntityPoint(T);

    return struct {
        total_elements: u32 = 0,
        points: [capacity]Point = undefined,
        boundary: Rectangle,
        divided: bool = false,
        nw: u32 = 0,
        ne: u32 = 0,
        sw: u32 = 0,
        se: u32 = 0,
    };
}

/// QuadTree configuration
pub const QuadTreeConfig = struct {
    capacity: u32 = 4,
    gutter: f32 = 120.0,
};

/// QuadTree for efficient spatial partitioning and queries
pub fn QuadTree(comptime T: type, comptime config: QuadTreeConfig) type {
    const Point = EntityPoint(T);
    const Node = QuadTreeNode(T, config.capacity);

    return struct {
        const Self = @This();

        nodes: std.ArrayListUnmanaged(Node),

        lowest_x: f32 = 0.0,
        lowest_y: f32 = 0.0,
        highest_x: f32 = 0.0,
        highest_y: f32 = 0.0,

        original_boundary: Rectangle,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, boundary: Rectangle) !Self {
            var qt = Self{
                .nodes = .empty,
                .original_boundary = boundary,
                .allocator = allocator,
                .lowest_x = std.math.inf(f32),
                .lowest_y = std.math.inf(f32),
                .highest_x = -std.math.inf(f32),
                .highest_y = -std.math.inf(f32),
            };
            try qt.nodes.append(allocator, .{ .boundary = boundary });
            return qt;
        }

        pub fn deinit(self: *Self) void {
            self.nodes.deinit(self.allocator);
        }

        pub fn clear(self: *Self) !void {
            try self.resize(self.original_boundary);
        }

        pub fn resize(self: *Self, boundary: Rectangle) !void {
            self.nodes.clearRetainingCapacity();
            self.lowest_x = std.math.inf(f32);
            self.lowest_y = std.math.inf(f32);
            self.highest_x = -std.math.inf(f32);
            self.highest_y = -std.math.inf(f32);
            self.original_boundary = boundary;
            try self.nodes.append(self.allocator, .{ .boundary = boundary });
        }

        pub fn resetWithBoundaries(self: *Self, positions: []const Position) !void {
            self.nodes.clearRetainingCapacity();
            self.lowest_x = std.math.inf(f32);
            self.lowest_y = std.math.inf(f32);
            self.highest_x = -std.math.inf(f32);
            self.highest_y = -std.math.inf(f32);

            for (positions) |pos| {
                if (pos.x < self.lowest_x) self.lowest_x = pos.x;
                if (pos.y < self.lowest_y) self.lowest_y = pos.y;
                if (pos.x > self.highest_x) self.highest_x = pos.x;
                if (pos.y > self.highest_y) self.highest_y = pos.y;
            }

            try self.nodes.append(self.allocator, .{ .boundary = .{
                .x = self.lowest_x - config.gutter,
                .y = self.lowest_y - config.gutter,
                .width = (self.highest_x - self.lowest_x) + config.gutter * 2,
                .height = (self.highest_y - self.lowest_y) + config.gutter * 2,
            } });
        }

        pub fn reset(self: *Self) !void {
            const boundary = Rectangle{
                .x = self.lowest_x - config.gutter,
                .y = self.lowest_y - config.gutter,
                .width = (self.highest_x - self.lowest_x) + config.gutter * 2,
                .height = (self.highest_y - self.lowest_y) + config.gutter * 2,
            };
            self.nodes.clearRetainingCapacity();
            self.lowest_x = std.math.inf(f32);
            self.lowest_y = std.math.inf(f32);
            self.highest_x = -std.math.inf(f32);
            self.highest_y = -std.math.inf(f32);
            try self.nodes.append(self.allocator, .{ .boundary = boundary });
        }

        pub fn insert(self: *Self, point: Point) bool {
            if (point.pos.x < self.lowest_x) self.lowest_x = point.pos.x;
            if (point.pos.y < self.lowest_y) self.lowest_y = point.pos.y;
            if (point.pos.x > self.highest_x) self.highest_x = point.pos.x;
            if (point.pos.y > self.highest_y) self.highest_y = point.pos.y;
            return self.insertAt(point, 0);
        }

        pub fn insertAt(self: *Self, point: Point, node_idx: u32) bool {
            if (!self.nodes.items[node_idx].boundary.containsPosition(point.pos)) {
                return false;
            }

            if (self.nodes.items[node_idx].total_elements < config.capacity and !self.nodes.items[node_idx].divided) {
                self.nodes.items[node_idx].points[self.nodes.items[node_idx].total_elements] = point;
                self.nodes.items[node_idx].total_elements += 1;
                return true;
            }

            if (!self.nodes.items[node_idx].divided) {
                self.subdivide(node_idx) catch |err| {
                    std.log.err("Error subdividing: {}\n", .{err});
                    return false;
                };
            }

            if (self.insertAt(point, self.nodes.items[node_idx].nw)) return true;
            if (self.insertAt(point, self.nodes.items[node_idx].ne)) return true;
            if (self.insertAt(point, self.nodes.items[node_idx].sw)) return true;
            if (self.insertAt(point, self.nodes.items[node_idx].se)) return true;

            return false;
        }

        fn subdivide(self: *Self, node_idx: u32) !void {
            const boundary = self.nodes.items[node_idx].boundary;
            const half_width = boundary.width / 2.0;
            const half_height = boundary.height / 2.0;
            const x = boundary.x;
            const y = boundary.y;

            self.nodes.items[node_idx].nw = @intCast(self.nodes.items.len);
            try self.nodes.append(self.allocator, .{ .boundary = .{ .x = x, .y = y, .width = half_width, .height = half_height } });

            self.nodes.items[node_idx].ne = @intCast(self.nodes.items.len);
            try self.nodes.append(self.allocator, .{ .boundary = .{ .x = x + half_width, .y = y, .width = half_width, .height = half_height } });

            self.nodes.items[node_idx].sw = @intCast(self.nodes.items.len);
            try self.nodes.append(self.allocator, .{ .boundary = .{ .x = x, .y = y + half_height, .width = half_width, .height = half_height } });

            self.nodes.items[node_idx].se = @intCast(self.nodes.items.len);
            try self.nodes.append(self.allocator, .{ .boundary = .{ .x = x + half_width, .y = y + half_height, .width = half_width, .height = half_height } });

            self.nodes.items[node_idx].divided = true;
        }

        pub fn queryRect(self: *Self, range: Rectangle, buffer: *std.ArrayListUnmanaged(Point)) !void {
            try self.queryRectAt(range, buffer, 0);
        }

        fn queryRectAt(self: *Self, range: Rectangle, buffer: *std.ArrayListUnmanaged(Point), node_idx: u32) !void {
            if (!self.nodes.items[node_idx].boundary.intersects(range)) {
                return;
            }

            for (0..self.nodes.items[node_idx].total_elements) |i| {
                const p = self.nodes.items[node_idx].points[i];
                if (range.containsPosition(p.pos)) {
                    try buffer.append(self.allocator, p);
                }
            }

            if (self.nodes.items[node_idx].divided) {
                try self.queryRectAt(range, buffer, self.nodes.items[node_idx].nw);
                try self.queryRectAt(range, buffer, self.nodes.items[node_idx].ne);
                try self.queryRectAt(range, buffer, self.nodes.items[node_idx].sw);
                try self.queryRectAt(range, buffer, self.nodes.items[node_idx].se);
            }
        }

        pub fn queryRadius(self: *Self, center: Position, radius: f32, buffer: *std.ArrayListUnmanaged(Point)) !void {
            const range = Rectangle{
                .x = center.x - radius,
                .y = center.y - radius,
                .width = radius * 2,
                .height = radius * 2,
            };
            try self.queryRadiusAt(range, center, radius * radius, buffer, 0);
        }

        fn queryRadiusAt(self: *Self, range: Rectangle, center: Position, radius_sq: f32, buffer: *std.ArrayListUnmanaged(Point), node_idx: u32) !void {
            if (!self.nodes.items[node_idx].boundary.intersects(range)) {
                return;
            }

            for (0..self.nodes.items[node_idx].total_elements) |i| {
                const p = self.nodes.items[node_idx].points[i];
                if (p.pos.distanceSquared(center) <= radius_sq) {
                    try buffer.append(self.allocator, p);
                }
            }

            if (self.nodes.items[node_idx].divided) {
                try self.queryRadiusAt(range, center, radius_sq, buffer, self.nodes.items[node_idx].nw);
                try self.queryRadiusAt(range, center, radius_sq, buffer, self.nodes.items[node_idx].ne);
                try self.queryRadiusAt(range, center, radius_sq, buffer, self.nodes.items[node_idx].sw);
                try self.queryRadiusAt(range, center, radius_sq, buffer, self.nodes.items[node_idx].se);
            }
        }

        pub fn queryNearest(self: *Self, pos: Position, max_distance: f32) ?Point {
            var nearest: ?Point = null;
            var nearest_dist: f32 = max_distance;
            self.findNearestAt(pos, &nearest, &nearest_dist, 0);
            return nearest;
        }

        fn findNearestAt(self: *Self, pos: Position, nearest: *?Point, nearest_dist: *f32, node_idx: u32) void {
            for (0..self.nodes.items[node_idx].total_elements) |i| {
                const p = self.nodes.items[node_idx].points[i];
                const dist = p.pos.distance(pos);
                if (dist < nearest_dist.*) {
                    nearest_dist.* = dist;
                    nearest.* = p;
                }
            }

            if (self.nodes.items[node_idx].divided) {
                const children = [4]u32{
                    self.nodes.items[node_idx].nw,
                    self.nodes.items[node_idx].ne,
                    self.nodes.items[node_idx].sw,
                    self.nodes.items[node_idx].se,
                };
                for (children) |child_idx| {
                    if (self.minDistToBounds(pos, child_idx) < nearest_dist.*) {
                        self.findNearestAt(pos, nearest, nearest_dist, child_idx);
                    }
                }
            }
        }

        fn minDistToBounds(self: *Self, pos: Position, node_idx: u32) f32 {
            const bounds = self.nodes.items[node_idx].boundary;
            const closest_x = std.math.clamp(pos.x, bounds.x, bounds.x + bounds.width);
            const closest_y = std.math.clamp(pos.y, bounds.y, bounds.y + bounds.height);
            const dx = closest_x - pos.x;
            const dy = closest_y - pos.y;
            return @sqrt(dx * dx + dy * dy);
        }

        pub fn hasPointInRect(self: *Self, range: Rectangle) bool {
            return self.hasPointInRectAt(range, 0);
        }

        fn hasPointInRectAt(self: *Self, range: Rectangle, node_idx: u32) bool {
            if (!self.nodes.items[node_idx].boundary.intersects(range)) {
                return false;
            }

            for (0..self.nodes.items[node_idx].total_elements) |i| {
                const p = self.nodes.items[node_idx].points[i];
                if (range.containsPosition(p.pos)) {
                    return true;
                }
            }

            if (self.nodes.items[node_idx].divided) {
                if (self.hasPointInRectAt(range, self.nodes.items[node_idx].nw)) return true;
                if (self.hasPointInRectAt(range, self.nodes.items[node_idx].ne)) return true;
                if (self.hasPointInRectAt(range, self.nodes.items[node_idx].sw)) return true;
                if (self.hasPointInRectAt(range, self.nodes.items[node_idx].se)) return true;
            }

            return false;
        }

        pub fn remove(self: *Self, id: T) bool {
            return self.removeAt(id, 0);
        }

        fn removeAt(self: *Self, id: T, node_idx: u32) bool {
            var i: u32 = 0;
            while (i < self.nodes.items[node_idx].total_elements) {
                if (std.meta.eql(self.nodes.items[node_idx].points[i].id, id)) {
                    self.nodes.items[node_idx].total_elements -= 1;
                    if (i < self.nodes.items[node_idx].total_elements) {
                        self.nodes.items[node_idx].points[i] = self.nodes.items[node_idx].points[self.nodes.items[node_idx].total_elements];
                    }
                    return true;
                }
                i += 1;
            }

            if (self.nodes.items[node_idx].divided) {
                if (self.removeAt(id, self.nodes.items[node_idx].nw)) return true;
                if (self.removeAt(id, self.nodes.items[node_idx].ne)) return true;
                if (self.removeAt(id, self.nodes.items[node_idx].sw)) return true;
                if (self.removeAt(id, self.nodes.items[node_idx].se)) return true;
            }

            return false;
        }

        pub fn update(self: *Self, id: T, new_pos: Position) bool {
            if (self.remove(id)) {
                return self.insert(.{ .id = id, .pos = new_pos });
            }
            return false;
        }

        pub fn count(self: *Self) usize {
            return self.countAt(0);
        }

        fn countAt(self: *Self, node_idx: u32) usize {
            var total: usize = self.nodes.items[node_idx].total_elements;

            if (self.nodes.items[node_idx].divided) {
                total += self.countAt(self.nodes.items[node_idx].nw);
                total += self.countAt(self.nodes.items[node_idx].ne);
                total += self.countAt(self.nodes.items[node_idx].sw);
                total += self.countAt(self.nodes.items[node_idx].se);
            }

            return total;
        }
    };
}
