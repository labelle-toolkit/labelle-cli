const std = @import("std");
const parser = @import("parser.zig");
const Value = parser.Value;
const Allocator = std.mem.Allocator;

pub const DeserializeError = error{
    TypeMismatch,
    MissingRequiredField,
    UnknownEnumValue,
    UnknownUnionField,
    OutOfMemory,
};

/// Deserialize a parsed ZON Value into a concrete Zig type T.
/// Uses @typeInfo at comptime to generate the mapping automatically.
pub fn deserialize(comptime T: type, value: Value, allocator: Allocator) DeserializeError!T {
    return deserializeInner(T, value, allocator);
}

fn deserializeInner(comptime T: type, value: Value, allocator: Allocator) DeserializeError!T {
    const info = @typeInfo(T);

    switch (info) {
        .@"struct" => return deserializeStruct(T, value, allocator),
        .@"enum" => return deserializeEnum(T, value),
        .@"union" => return deserializeUnion(T, value, allocator),
        .optional => |opt| {
            if (value == .null_value) return null;
            return try deserializeInner(opt.child, value, allocator);
        },
        .bool => {
            if (value.asBool()) |b| return b;
            return error.TypeMismatch;
        },
        .int => return deserializeInt(T, value),
        .float => return deserializeFloat(T, value),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                // []const u8 — string
                if (value.asString()) |s| return s;
                return error.TypeMismatch;
            }
            if (ptr.size == .slice) {
                // []const SomeType — deserialize from array
                return deserializeSlice(ptr.child, value, allocator);
            }
            return error.TypeMismatch;
        },
        else => return error.TypeMismatch,
    }
}

fn deserializeStruct(comptime T: type, value: Value, allocator: Allocator) DeserializeError!T {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.TypeMismatch,
    };

    const fields = @typeInfo(T).@"struct".fields;
    var result: T = undefined;

    inline for (fields) |field| {
        if (obj.get(field.name)) |field_value| {
            @field(result, field.name) = try deserializeInner(field.type, field_value, allocator);
        } else if (field.default_value_ptr) |default_ptr| {
            const ptr: *const field.type = @ptrCast(@alignCast(default_ptr));
            @field(result, field.name) = ptr.*;
        } else {
            return error.MissingRequiredField;
        }
    }

    return result;
}

fn deserializeEnum(comptime T: type, value: Value) DeserializeError!T {
    const name = switch (value) {
        .enum_literal => |e| e,
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const fields = @typeInfo(T).@"enum".fields;
    inline for (fields) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            return @enumFromInt(field.value);
        }
    }

    return error.UnknownEnumValue;
}

fn deserializeUnion(comptime T: type, value: Value, allocator: Allocator) DeserializeError!T {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.TypeMismatch,
    };

    // A tagged union in ZON is represented as .{ .variant_name = payload }
    // The object should have exactly one entry.
    if (obj.entries.len != 1) return error.TypeMismatch;

    const entry = obj.entries[0];
    const union_info = @typeInfo(T).@"union";

    inline for (union_info.fields) |field| {
        if (std.mem.eql(u8, entry.key, field.name)) {
            if (field.type == void) {
                return @unionInit(T, field.name, {});
            }
            const payload = try deserializeInner(field.type, entry.value, allocator);
            return @unionInit(T, field.name, payload);
        }
    }

    return error.UnknownUnionField;
}

fn deserializeInt(comptime T: type, value: Value) DeserializeError!T {
    switch (value) {
        .integer => |i| return @intCast(i),
        .float => |f| return @intFromFloat(f),
        else => return error.TypeMismatch,
    }
}

fn deserializeFloat(comptime T: type, value: Value) DeserializeError!T {
    switch (value) {
        .float => |f| return @floatCast(f),
        .integer => |i| return @floatFromInt(i),
        else => return error.TypeMismatch,
    }
}

fn deserializeSlice(comptime Child: type, value: Value, allocator: Allocator) DeserializeError![]const Child {
    const arr = switch (value) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    const result = allocator.alloc(Child, arr.items.len) catch return error.OutOfMemory;
    for (arr.items, 0..) |item, i| {
        result[i] = try deserializeInner(Child, item, allocator);
    }
    return result;
}

/// A runtime component registry that maps string names to typed deserializers.
/// Built at comptime from a tuple of (name, type) pairs.
pub fn ComponentRegistry(comptime components: anytype) type {
    return struct {
        const Self = @This();

        /// Deserialize a component by name from a parsed Value.
        /// Returns the component as bytes (type-erased) allocated on the given allocator.
        pub fn deserializeByName(name: []const u8, value: Value, allocator: Allocator) DeserializeError!?TypeErasedComponent {
            inline for (components) |entry| {
                if (std.mem.eql(u8, name, entry.name)) {
                    const T = entry.type;
                    const comp = try deserialize(T, value, allocator);
                    const slice = allocator.alloc(T, 1) catch return error.OutOfMemory;
                    slice[0] = comp;
                    const bytes: [*]u8 = @ptrCast(slice.ptr);
                    return TypeErasedComponent{
                        .name = entry.name,
                        .data = bytes[0..@sizeOf(T)],
                        .size = @sizeOf(T),
                    };
                }
            }
            return null; // Unknown component
        }

        /// Deserialize a component by its concrete type.
        pub fn deserializeTyped(comptime T: type, value: Value, allocator: Allocator) DeserializeError!T {
            return deserialize(T, value, allocator);
        }

        /// Check if a component name is registered.
        pub fn has(name: []const u8) bool {
            inline for (components) |entry| {
                if (std.mem.eql(u8, name, entry.name)) return true;
            }
            return false;
        }

        /// Get the number of registered components.
        pub fn count() usize {
            return components.len;
        }

        /// Get the list of registered component names.
        pub fn names() [components.len][]const u8 {
            var result: [components.len][]const u8 = undefined;
            inline for (components, 0..) |entry, i| {
                result[i] = entry.name;
            }
            return result;
        }
    };
}

pub const TypeErasedComponent = struct {
    name: []const u8,
    data: []u8,
    size: usize,

    /// Cast the type-erased data back to a concrete type.
    pub fn as(self: TypeErasedComponent, comptime T: type) *const T {
        return @ptrCast(@alignCast(self.data.ptr));
    }
};

/// Helper to define a component entry for the registry.
pub fn component(comptime name: []const u8, comptime T: type) struct { name: []const u8, type: type } {
    return .{ .name = name, .type = T };
}

// ======================== Tests ========================

const Position = struct {
    x: i32 = 0,
    y: i32 = 0,
};

const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
};

const BodyType = enum {
    static,
    dynamic,
    kinematic,
};

const RigidBody = struct {
    body_type: BodyType = .static,
};

const ShapeKind = union(enum) {
    circle: struct { radius: f32 },
    rectangle: struct { width: f32, height: f32 },
};

const Shape = struct {
    shape: ShapeKind,
    color: Color = .{},
};

const Collider = struct {
    shape: ShapeKind,
    restitution: f32 = 0.0,
    friction: f32 = 0.0,
};

const WorkstationType = enum {
    hydroponics,
    water_well,
    butcher,
};

const Workstation = struct {
    workstation_type: WorkstationType,
    process_duration: i32 = 1,
};

const TendableWorkstation = struct {
    maintenance_per_work: f32 = 0.0,
    work_ready_threshold: f32 = 0.0,
    max_level: i32 = 1,
};

const Storage = struct {
    accepted_items: AcceptedItems = .{},
};

const AcceptedItems = struct {
    Water: bool = false,
    Vegetable: bool = false,
    Flour: bool = false,
};

const Worker = struct {};

const Eis = struct {};
const Eos = struct {};

test "deserialize Position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser.Parser.init(alloc, ".{ .x = 50, .y = 100 }");
    const val = try p.parse();
    const pos = try deserialize(Position, val, alloc);
    try std.testing.expectEqual(@as(i32, 50), pos.x);
    try std.testing.expectEqual(@as(i32, 100), pos.y);
}

test "deserialize Position with defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser.Parser.init(alloc, ".{ .x = 42 }");
    const val = try p.parse();
    const pos = try deserialize(Position, val, alloc);
    try std.testing.expectEqual(@as(i32, 42), pos.x);
    try std.testing.expectEqual(@as(i32, 0), pos.y); // default
}

test "deserialize negative integers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser.Parser.init(alloc, ".{ .x = -20, .y = 0 }");
    const val = try p.parse();
    const pos = try deserialize(Position, val, alloc);
    try std.testing.expectEqual(@as(i32, -20), pos.x);
}

test "deserialize Color" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser.Parser.init(alloc, ".{ .r = 255, .g = 100, .b = 100 }");
    const val = try p.parse();
    const color = try deserialize(Color, val, alloc);
    try std.testing.expectEqual(@as(u8, 255), color.r);
    try std.testing.expectEqual(@as(u8, 100), color.g);
}

test "deserialize enum field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser.Parser.init(alloc, ".{ .body_type = .dynamic }");
    const val = try p.parse();
    const rb = try deserialize(RigidBody, val, alloc);
    try std.testing.expectEqual(BodyType.dynamic, rb.body_type);
}

test "deserialize tagged union (circle)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser.Parser.init(alloc, ".{ .circle = .{ .radius = 30 } }");
    const val = try p.parse();
    const shape = try deserialize(ShapeKind, val, alloc);
    switch (shape) {
        .circle => |c| try std.testing.expectApproxEqAbs(@as(f32, 30.0), c.radius, 0.001),
        else => return error.TypeMismatch,
    }
}

test "deserialize tagged union (rectangle)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser.Parser.init(alloc, ".{ .rectangle = .{ .width = 780, .height = 20 } }");
    const val = try p.parse();
    const shape = try deserialize(ShapeKind, val, alloc);
    switch (shape) {
        .rectangle => |r| {
            try std.testing.expectApproxEqAbs(@as(f32, 780.0), r.width, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 20.0), r.height, 0.001);
        },
        else => return error.TypeMismatch,
    }
}

test "deserialize Shape with nested union and struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser.Parser.init(alloc,
        \\.{ .shape = .{ .circle = .{ .radius = 30 } }, .color = .{ .r = 255, .g = 100, .b = 100 } }
    );
    const val = try p.parse();
    const shape = try deserialize(Shape, val, alloc);
    switch (shape.shape) {
        .circle => |c| try std.testing.expectApproxEqAbs(@as(f32, 30.0), c.radius, 0.001),
        else => return error.TypeMismatch,
    }
    try std.testing.expectEqual(@as(u8, 255), shape.color.r);
    try std.testing.expectEqual(@as(u8, 100), shape.color.g);
    try std.testing.expectEqual(@as(u8, 100), shape.color.b);
}

test "deserialize Collider with floats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser.Parser.init(alloc,
        \\.{
        \\    .shape = .{ .circle = .{ .radius = 30 } },
        \\    .restitution = 0.9,
        \\    .friction = 0.1,
        \\}
    );
    const val = try p.parse();
    const col = try deserialize(Collider, val, alloc);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), col.restitution, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), col.friction, 0.001);
}

test "deserialize Workstation with enum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser.Parser.init(alloc,
        \\.{ .workstation_type = .hydroponics, .process_duration = 3 }
    );
    const val = try p.parse();
    const ws = try deserialize(Workstation, val, alloc);
    try std.testing.expectEqual(WorkstationType.hydroponics, ws.workstation_type);
    try std.testing.expectEqual(@as(i32, 3), ws.process_duration);
}

test "deserialize TendableWorkstation with floats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser.Parser.init(alloc,
        \\.{ .maintenance_per_work = 0.3, .work_ready_threshold = 0.5, .max_level = 5 }
    );
    const val = try p.parse();
    const tws = try deserialize(TendableWorkstation, val, alloc);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), tws.maintenance_per_work, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), tws.work_ready_threshold, 0.001);
    try std.testing.expectEqual(@as(i32, 5), tws.max_level);
}

test "deserialize Storage with bool map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser.Parser.init(alloc,
        \\.{ .accepted_items = .{ .Water = true } }
    );
    const val = try p.parse();
    const storage = try deserialize(Storage, val, alloc);
    try std.testing.expectEqual(true, storage.accepted_items.Water);
    try std.testing.expectEqual(false, storage.accepted_items.Vegetable); // default
}

test "deserialize empty struct (marker component)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser.Parser.init(alloc, ".{}");
    const val = try p.parse();
    _ = try deserialize(Worker, val, alloc);
    _ = try deserialize(Eis, val, alloc);
}

test "integer to float coercion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // In ZON, "30" parses as integer, but radius is f32 — should coerce
    var p = parser.Parser.init(alloc, ".{ .circle = .{ .radius = 30 } }");
    const val = try p.parse();
    const shape = try deserialize(ShapeKind, val, alloc);
    switch (shape) {
        .circle => |c| try std.testing.expectApproxEqAbs(@as(f32, 30.0), c.radius, 0.001),
        else => return error.TypeMismatch,
    }
}

// === Component Registry Tests ===

const TestRegistry = ComponentRegistry(.{
    component("Position", Position),
    component("Color", Color),
    component("RigidBody", RigidBody),
    component("Shape", Shape),
    component("Collider", Collider),
    component("Workstation", Workstation),
    component("TendableWorkstation", TendableWorkstation),
    component("Storage", Storage),
    component("Worker", Worker),
    component("Eis", Eis),
    component("Eos", Eos),
});

test "registry: has component" {
    try std.testing.expect(TestRegistry.has("Position"));
    try std.testing.expect(TestRegistry.has("Shape"));
    try std.testing.expect(TestRegistry.has("Worker"));
    try std.testing.expect(!TestRegistry.has("NonExistent"));
}

test "registry: count and names" {
    try std.testing.expectEqual(@as(usize, 11), TestRegistry.count());
    const all_names = TestRegistry.names();
    try std.testing.expectEqualStrings("Position", all_names[0]);
    try std.testing.expectEqualStrings("Eos", all_names[10]);
}

test "registry: deserialize by name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser.Parser.init(alloc, ".{ .x = 42, .y = 99 }");
    const val = try p.parse();

    const result = try TestRegistry.deserializeByName("Position", val, alloc);
    try std.testing.expect(result != null);
    const pos = result.?.as(Position);
    try std.testing.expectEqual(@as(i32, 42), pos.x);
    try std.testing.expectEqual(@as(i32, 99), pos.y);
}

test "registry: deserialize unknown returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser.Parser.init(alloc, ".{}");
    const val = try p.parse();

    const result = try TestRegistry.deserializeByName("UnknownComponent", val, alloc);
    try std.testing.expect(result == null);
}

test "registry: deserialize entity components from parsed scene data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Simulate what loading an entity from a scene would look like
    var p = parser.Parser.init(alloc,
        \\.{
        \\    .Position = .{ .x = 400, .y = 580 },
        \\    .Shape = .{ .shape = .{ .rectangle = .{ .width = 780, .height = 20 } }, .color = .{ .r = 80, .g = 80, .b = 100 } },
        \\    .RigidBody = .{ .body_type = .static },
        \\    .Collider = .{
        \\        .shape = .{ .rectangle = .{ .width = 780, .height = 20 } },
        \\        .restitution = 0.9,
        \\        .friction = 0.1,
        \\    },
        \\}
    );
    const val = try p.parse();
    const components_obj = val.asObject().?;

    // Iterate over all component entries and deserialize each one
    var count: usize = 0;
    for (components_obj.entries) |entry| {
        if (try TestRegistry.deserializeByName(entry.key, entry.value, alloc)) |comp| {
            _ = comp;
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 4), count);

    // Verify specific components
    const pos_result = (try TestRegistry.deserializeByName("Position", components_obj.get("Position").?, alloc)).?;
    const pos = pos_result.as(Position);
    try std.testing.expectEqual(@as(i32, 400), pos.x);
    try std.testing.expectEqual(@as(i32, 580), pos.y);

    const rb_result = (try TestRegistry.deserializeByName("RigidBody", components_obj.get("RigidBody").?, alloc)).?;
    const rb = rb_result.as(RigidBody);
    try std.testing.expectEqual(BodyType.static, rb.body_type);

    const col_result = (try TestRegistry.deserializeByName("Collider", components_obj.get("Collider").?, alloc)).?;
    const col = col_result.as(Collider);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), col.restitution, 0.001);
}
