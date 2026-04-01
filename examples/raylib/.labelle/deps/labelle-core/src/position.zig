const std = @import("std");
const save_policy = @import("save_policy.zig");

pub const Position = struct {
    pub const save = save_policy.Saveable(.saveable, @This(), .{});

    x: f32 = 0,
    y: f32 = 0,

    pub const zero = Position{ .x = 0, .y = 0 };
    pub const one = Position{ .x = 1, .y = 1 };

    pub fn add(self: Position, other: Position) Position {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn move(self: *Position, dx: f32, dy: f32) void {
        self.x += dx;
        self.y += dy;
    }

    pub fn sub(self: Position, other: Position) Position {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn scale(self: Position, scalar: f32) Position {
        return .{ .x = self.x * scalar, .y = self.y * scalar };
    }

    pub fn mul(self: Position, other: Position) Position {
        return .{ .x = self.x * other.x, .y = self.y * other.y };
    }

    pub fn div(self: Position, other: Position) Position {
        return .{ .x = self.x / other.x, .y = self.y / other.y };
    }

    pub fn negate(self: Position) Position {
        return .{ .x = -self.x, .y = -self.y };
    }

    pub fn length(self: Position) f32 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    pub fn lengthSquared(self: Position) f32 {
        return self.x * self.x + self.y * self.y;
    }

    pub fn normalize(self: Position) Position {
        const len = self.length();
        if (len == 0) return self;
        return self.scale(1.0 / len);
    }

    pub fn distance(self: Position, other: Position) f32 {
        return self.sub(other).length();
    }

    pub fn distanceSquared(self: Position, other: Position) f32 {
        return self.sub(other).lengthSquared();
    }

    pub fn dot(self: Position, other: Position) f32 {
        return self.x * other.x + self.y * other.y;
    }

    pub fn cross(self: Position, other: Position) f32 {
        return self.x * other.y - self.y * other.x;
    }

    pub fn lerp(self: Position, other: Position, t: f32) Position {
        return .{
            .x = self.x + (other.x - self.x) * t,
            .y = self.y + (other.y - self.y) * t,
        };
    }

    pub fn rotate(self: Position, radians: f32) Position {
        const cos_a = @cos(radians);
        const sin_a = @sin(radians);
        return .{
            .x = self.x * cos_a - self.y * sin_a,
            .y = self.x * sin_a + self.y * cos_a,
        };
    }

    pub fn perpendicular(self: Position) Position {
        return .{ .x = -self.y, .y = self.x };
    }

    pub fn angle(self: Position) f32 {
        return std.math.atan2(self.y, self.x);
    }

    pub fn angleTo(self: Position, other: Position) f32 {
        return other.sub(self).angle();
    }

    pub fn clamp(self: Position, min: Position, max: Position) Position {
        return .{
            .x = std.math.clamp(self.x, min.x, max.x),
            .y = std.math.clamp(self.y, min.y, max.y),
        };
    }

    pub fn clampLength(self: Position, min_len: f32, max_len: f32) Position {
        const len = self.length();
        if (len == 0) return self;
        const clamped = std.math.clamp(len, min_len, max_len);
        return self.scale(clamped / len);
    }

    pub fn abs(self: Position) Position {
        return .{ .x = @abs(self.x), .y = @abs(self.y) };
    }

    pub fn floor(self: Position) Position {
        return .{ .x = @floor(self.x), .y = @floor(self.y) };
    }

    pub fn ceil(self: Position) Position {
        return .{ .x = @ceil(self.x), .y = @ceil(self.y) };
    }

    pub fn round(self: Position) Position {
        return .{ .x = @round(self.x), .y = @round(self.y) };
    }

    pub fn eql(self: Position, other: Position) bool {
        return self.x == other.x and self.y == other.y;
    }

    pub fn eqlApprox(self: Position, other: Position, epsilon: f32) bool {
        return @abs(self.x - other.x) <= epsilon and @abs(self.y - other.y) <= epsilon;
    }

    pub fn format(
        self: Position,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("Position({d:.2}, {d:.2})", .{ self.x, self.y });
    }
};

/// Integer position for pixel-perfect positioning
pub const PositionI = struct {
    x: i32 = 0,
    y: i32 = 0,

    pub const zero = PositionI{ .x = 0, .y = 0 };
    pub const one = PositionI{ .x = 1, .y = 1 };

    pub fn add(self: PositionI, other: PositionI) PositionI {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn sub(self: PositionI, other: PositionI) PositionI {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn scale(self: PositionI, scalar: i32) PositionI {
        return .{ .x = self.x * scalar, .y = self.y * scalar };
    }

    pub fn negate(self: PositionI) PositionI {
        return .{ .x = -self.x, .y = -self.y };
    }

    pub fn mul(self: PositionI, other: PositionI) PositionI {
        return .{ .x = self.x * other.x, .y = self.y * other.y };
    }

    pub fn eql(self: PositionI, other: PositionI) bool {
        return self.x == other.x and self.y == other.y;
    }

    pub fn lengthSquared(self: PositionI) i64 {
        const x: i64 = self.x;
        const y: i64 = self.y;
        return x * x + y * y;
    }

    pub fn distanceSquared(self: PositionI, other: PositionI) i64 {
        return self.sub(other).lengthSquared();
    }

    pub fn toPosition(self: PositionI) Position {
        return .{
            .x = @floatFromInt(self.x),
            .y = @floatFromInt(self.y),
        };
    }

    pub fn fromPosition(pos: Position) PositionI {
        return .{
            .x = @intFromFloat(@round(pos.x)),
            .y = @intFromFloat(@round(pos.y)),
        };
    }

    pub fn format(
        self: PositionI,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("PositionI({d}, {d})", .{ self.x, self.y });
    }
};
