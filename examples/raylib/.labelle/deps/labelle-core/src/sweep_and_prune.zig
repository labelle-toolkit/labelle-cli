//! Sweep and Prune (Sort and Sweep) broad-phase collision detection
//!
//! Efficient O(n log n) algorithm for finding overlapping axis-aligned bounding boxes.
//! Best suited for scenes with many objects where most don't overlap.

const std = @import("std");
const Position = @import("position.zig").Position;

/// Axis-aligned bounding box
pub const AABB = struct {
    id: u32,
    pos: Position,
    half_width: f32,
    half_height: f32,

    pub fn init(id: u32, center: Position, half_width: f32, half_height: f32) AABB {
        return .{ .id = id, .pos = center, .half_width = half_width, .half_height = half_height };
    }

    pub fn minX(self: AABB) f32 {
        return self.pos.x - self.half_width;
    }
    pub fn maxX(self: AABB) f32 {
        return self.pos.x + self.half_width;
    }
    pub fn minY(self: AABB) f32 {
        return self.pos.y - self.half_height;
    }
    pub fn maxY(self: AABB) f32 {
        return self.pos.y + self.half_height;
    }

    pub fn overlaps(self: AABB, other: AABB) bool {
        return self.minX() < other.maxX() and
            self.maxX() > other.minX() and
            self.minY() < other.maxY() and
            self.maxY() > other.minY();
    }
};

/// A collision pair (consistently ordered for deduplication)
pub const CollisionPair = struct {
    a: u32,
    b: u32,

    pub fn init(id_a: u32, id_b: u32) CollisionPair {
        return if (id_a < id_b)
            .{ .a = id_a, .b = id_b }
        else
            .{ .a = id_b, .b = id_a };
    }
};

/// Generic sweep and prune collision detection system
pub fn SweepAndPrune(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Entity = struct {
            id: T,
            pos: Position,
            half_width: f32,
            half_height: f32,

            pub fn minX(self: Entity) f32 {
                return self.pos.x - self.half_width;
            }
            pub fn maxX(self: Entity) f32 {
                return self.pos.x + self.half_width;
            }
            pub fn minY(self: Entity) f32 {
                return self.pos.y - self.half_height;
            }
            pub fn maxY(self: Entity) f32 {
                return self.pos.y + self.half_height;
            }

            pub fn overlaps(self: Entity, other: Entity) bool {
                return self.minX() < other.maxX() and
                    self.maxX() > other.minX() and
                    self.minY() < other.maxY() and
                    self.maxY() > other.minY();
            }
        };

        pub const Pair = struct {
            a: T,
            b: T,
        };

        entities: std.ArrayListUnmanaged(Entity),
        sorted_indices: std.ArrayListUnmanaged(usize),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .entities = .empty,
                .sorted_indices = .empty,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.entities.deinit(self.allocator);
            self.sorted_indices.deinit(self.allocator);
        }

        pub fn clear(self: *Self) void {
            self.entities.clearRetainingCapacity();
            self.sorted_indices.clearRetainingCapacity();
        }

        pub fn add(self: *Self, id: T, pos: Position, half_width: f32, half_height: f32) !void {
            try self.entities.append(self.allocator, .{
                .id = id,
                .pos = pos,
                .half_width = half_width,
                .half_height = half_height,
            });
        }

        pub fn updatePosition(self: *Self, id: T, new_pos: Position) void {
            for (self.entities.items) |*entity| {
                if (std.meta.eql(entity.id, id)) {
                    entity.pos = new_pos;
                    return;
                }
            }
        }

        pub fn remove(self: *Self, id: T) bool {
            for (self.entities.items, 0..) |entity, i| {
                if (std.meta.eql(entity.id, id)) {
                    _ = self.entities.swapRemove(i);
                    return true;
                }
            }
            return false;
        }

        pub fn findCollisions(self: *Self, pairs: *std.ArrayListUnmanaged(Pair)) !void {
            const n = self.entities.items.len;
            if (n < 2) return;

            self.sorted_indices.clearRetainingCapacity();
            try self.sorted_indices.ensureTotalCapacity(self.allocator, n);
            for (0..n) |i| {
                try self.sorted_indices.append(self.allocator, i);
            }

            const entities = self.entities.items;
            std.mem.sort(usize, self.sorted_indices.items, entities, struct {
                fn lessThan(ents: []const Entity, a: usize, b: usize) bool {
                    return ents[a].minX() < ents[b].minX();
                }
            }.lessThan);

            for (self.sorted_indices.items, 0..) |i, idx| {
                const entity_a = entities[i];
                const max_x_a = entity_a.maxX();

                for (self.sorted_indices.items[idx + 1 ..]) |j| {
                    const entity_b = entities[j];
                    if (entity_b.minX() >= max_x_a) break;

                    if (entity_a.overlaps(entity_b)) {
                        try pairs.append(self.allocator, .{
                            .a = entity_a.id,
                            .b = entity_b.id,
                        });
                    }
                }
            }
        }

        pub fn queryRect(self: *Self, center: Position, half_width: f32, half_height: f32, results: *std.ArrayListUnmanaged(T)) !void {
            const query = Entity{
                .id = undefined,
                .pos = center,
                .half_width = half_width,
                .half_height = half_height,
            };

            for (self.entities.items) |entity| {
                if (query.overlaps(entity)) {
                    try results.append(self.allocator, entity.id);
                }
            }
        }

        pub fn queryRadius(self: *Self, center: Position, radius: f32, results: *std.ArrayListUnmanaged(T)) !void {
            const radius_sq = radius * radius;

            for (self.entities.items) |entity| {
                const dx = @abs(entity.pos.x - center.x);
                const dy = @abs(entity.pos.y - center.y);

                if (dx > radius + entity.half_width or dy > radius + entity.half_height) {
                    continue;
                }

                const closest_x = std.math.clamp(center.x, entity.minX(), entity.maxX());
                const closest_y = std.math.clamp(center.y, entity.minY(), entity.maxY());

                const dist_sq = (closest_x - center.x) * (closest_x - center.x) +
                    (closest_y - center.y) * (closest_y - center.y);

                if (dist_sq <= radius_sq) {
                    try results.append(self.allocator, entity.id);
                }
            }
        }
    };
}

/// Simple sweep and prune for AABBs (non-generic version)
pub fn sweepAndPrune(
    boxes: []const AABB,
    pairs: *std.ArrayListUnmanaged(CollisionPair),
    allocator: std.mem.Allocator,
) !void {
    const n = boxes.len;
    if (n < 2) return;

    var indices = try allocator.alloc(usize, n);
    defer allocator.free(indices);
    for (0..n) |i| indices[i] = i;

    std.mem.sort(usize, indices, boxes, struct {
        fn lessThan(b: []const AABB, a: usize, c: usize) bool {
            return b[a].minX() < b[c].minX();
        }
    }.lessThan);

    for (indices, 0..) |i, idx| {
        const box_a = boxes[i];
        const max_x_a = box_a.maxX();

        for (indices[idx + 1 ..]) |j| {
            const box_b = boxes[j];
            if (box_b.minX() >= max_x_a) break;

            if (box_a.overlaps(box_b)) {
                try pairs.append(allocator, CollisionPair.init(box_a.id, box_b.id));
            }
        }
    }
}
