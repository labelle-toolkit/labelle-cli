//! Generic JSON serialization engine for ECS save/load.
//!
//! Provides type-driven serialization (struct, enum, EnumSet, optional, primitives)
//! and entity ID remapping utilities. Game-specific logic (component lists, cleanup)
//! lives in the game's save_load script which imports this library.

const std = @import("std");
const sp = @import("save_policy.zig");

// ── JSON Serialization ──────────────────────────────────────────────────────

/// Serialize a value to a JSON writer. Handles structs, enums, EnumSets,
/// optionals, floats, ints, and bools. The `skipField` function is called
/// for struct fields to allow skipping runtime-derived fields (e.g. slices).
pub fn writeComponent(
    comptime T: type,
    value: *const T,
    writer: anytype,
    comptime skipField: fn (type, []const u8) bool,
) !void {
    const info = @typeInfo(T);

    if (comptime isEnumSet(T)) {
        return writeEnumSet(T, value, writer);
    }

    switch (info) {
        .@"struct" => |s| {
            try writer.writeAll("{");
            var first = true;
            inline for (s.fields) |field| {
                if (comptime skipField(T, field.name)) continue;
                if (!first) try writer.writeAll(",");
                try writer.writeAll("\"");
                try writer.writeAll(field.name);
                try writer.writeAll("\": ");
                const val = @field(value.*, field.name);
                try writeComponent(field.type, &val, writer, skipField);
                first = false;
            }
            try writer.writeAll("}");
        },
        .@"enum" => {
            try writer.writeAll("\"");
            try writer.writeAll(@tagName(value.*));
            try writer.writeAll("\"");
        },
        .optional => {
            if (value.*) |inner| {
                try writeComponent(@typeInfo(T).optional.child, &inner, writer, skipField);
            } else {
                try writer.writeAll("null");
            }
        },
        .float => {
            try std.fmt.format(writer, "{d:.6}", .{value.*});
        },
        .int, .comptime_int => {
            try std.fmt.format(writer, "{d}", .{value.*});
        },
        .bool => {
            try writer.writeAll(if (value.*) "true" else "false");
        },
        else => @compileError("writeComponent does not support type " ++ @typeName(T)),
    }
}

/// Deserialize a value from a parsed JSON value.
pub fn readComponent(comptime T: type, value: std.json.Value, comptime skipField: fn (type, []const u8) bool) !T {
    const info = @typeInfo(T);

    if (comptime isEnumSet(T)) {
        return readEnumSet(T, value);
    }

    switch (info) {
        .@"struct" => |s| {
            const obj = value.object;
            var result: T = undefined;
            inline for (s.fields) |field| {
                if (comptime skipField(T, field.name)) {
                    if (field.default_value_ptr) |dp| {
                        const typed: *const field.type = @ptrCast(@alignCast(dp));
                        @field(&result, field.name) = typed.*;
                    } else {
                        @field(&result, field.name) = std.mem.zeroes(field.type);
                    }
                } else if (obj.get(field.name)) |fv| {
                    @field(&result, field.name) = try readComponent(field.type, fv, skipField);
                } else if (field.default_value_ptr) |dp| {
                    const typed: *const field.type = @ptrCast(@alignCast(dp));
                    @field(&result, field.name) = typed.*;
                } else {
                    return error.MissingField;
                }
            }
            return result;
        },
        .@"enum" => {
            const name = value.string;
            return std.meta.stringToEnum(T, name) orelse error.InvalidEnumTag;
        },
        .optional => |opt| {
            if (value == .null) return null;
            return try readComponent(opt.child, value, skipField);
        },
        .float => {
            return jsonFloatAs(T, value);
        },
        .int, .comptime_int => {
            return switch (value) {
                .integer => @intCast(value.integer),
                .number_string => |s| std.fmt.parseInt(@TypeOf(@as(T, undefined)), s, 10) catch
                    return error.InvalidNumber,
                else => return error.InvalidNumber,
            };
        },
        .bool => {
            return value.bool;
        },
        else => @compileError("Unsupported type for deserialization: " ++ @typeName(T)),
    }
}

/// Update an existing component in-place from JSON, skipping runtime-derived fields.
pub fn readComponentInto(comptime T: type, comp: *T, value: std.json.Value, comptime skipField: fn (type, []const u8) bool) !void {
    if (comptime isEnumSet(T)) {
        comp.* = readEnumSet(T, value);
        return;
    }
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => {
            const obj = value.object;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (comptime skipField(T, field.name)) continue;
                if (obj.get(field.name)) |fv| {
                    @field(comp, field.name) = try readComponent(field.type, fv, skipField);
                }
            }
        },
        else => comp.* = try readComponent(T, value, skipField),
    }
}

// ── EnumSet Serialization ───────────────────────────────────────────────────

fn writeEnumSet(comptime T: type, value: *const T, writer: anytype) !void {
    try writer.writeAll("[");
    var first = true;
    var iter = value.iterator();
    while (iter.next()) |item| {
        if (!first) try writer.writeAll(",");
        try writer.writeAll("\"");
        try writer.writeAll(@tagName(item));
        try writer.writeAll("\"");
        first = false;
    }
    try writer.writeAll("]");
}

fn readEnumSet(comptime T: type, value: std.json.Value) T {
    var result = T{};
    for (value.array.items) |elem| {
        if (std.meta.stringToEnum(T.Key, elem.string)) |key| {
            result.insert(key);
        }
    }
    return result;
}

// ── Entity ID Remapping ─────────────────────────────────────────────────────

pub fn remapId(id: u64, id_map: *const std.AutoHashMap(u64, u64)) u64 {
    return id_map.get(id) orelse id;
}

pub fn remapOptId(id: ?u64, id_map: *const std.AutoHashMap(u64, u64)) ?u64 {
    if (id) |i| return id_map.get(i) orelse i;
    return null;
}

/// Auto-remap entity ID fields, respecting remap_exclude.
/// Works with both new-style Saveable and legacy entity_ref_fields.
pub fn remapEntityRefs(comptime T: type, comp: *T, id_map: *const std.AutoHashMap(u64, u64)) void {
    const ref_fields = comptime sp.getEntityRefFields(T);
    inline for (ref_fields) |field_name| {
        if (comptime sp.isRemapExcluded(T, field_name)) {
            // Excluded fields are never remapped — they may hold sentinel
            // values or non-entity data that must be preserved as-is.
            continue;
        } else {
            const FieldType = @TypeOf(@field(comp, field_name));
            if (FieldType == u64) {
                @field(comp, field_name) = remapId(@field(comp, field_name), id_map);
            } else if (FieldType == ?u64) {
                @field(comp, field_name) = remapOptId(@field(comp, field_name), id_map);
            }
        }
    }
}

/// Legacy compatibility — same as remapEntityRefs.
pub const remapEntityRefsAuto = remapEntityRefs;

/// Auto-detect skipField based on save declarations (new or legacy style).
pub fn autoSkipField(T: type, field_name: []const u8) bool {
    return sp.shouldSkipField(T, field_name);
}

// ── Entity Ref Array Serialization ──────────────────────────────────────────

/// Write entity ref array fields ([]const u64 slices) as a JSON object.
pub fn writeRefArrays(comptime T: type, value: *const T, writer: anytype) !void {
    const arr_fields = comptime sp.getRefArrayFields(T);
    if (arr_fields.len == 0) return;
    try writer.writeAll("{");
    var first = true;
    inline for (arr_fields) |field_name| {
        if (!first) try writer.writeAll(",");
        try writer.writeAll("\"");
        try writer.writeAll(field_name);
        try writer.writeAll("\": [");
        const slice = @field(value.*, field_name);
        for (slice, 0..) |id, i| {
            if (i > 0) try writer.writeAll(",");
            try std.fmt.format(writer, "{d}", .{id});
        }
        try writer.writeAll("]");
        first = false;
    }
    try writer.writeAll("}");
}

/// Write ref array fields without outer braces — for embedding in a shared JSON object.
pub fn writeRefArrayFields(comptime T: type, value: *const T, writer: anytype) !void {
    const arr_fields = comptime sp.getRefArrayFields(T);
    if (arr_fields.len == 0) return;
    var first = true;
    inline for (arr_fields) |field_name| {
        if (!first) try writer.writeAll(",");
        try writer.writeAll("\"");
        try writer.writeAll(field_name);
        try writer.writeAll("\": [");
        const slice = @field(value.*, field_name);
        for (slice, 0..) |id, i| {
            if (i > 0) try writer.writeAll(",");
            try std.fmt.format(writer, "{d}", .{id});
        }
        try writer.writeAll("]");
        first = false;
    }
}

/// Check if a type has entity ref array fields.
pub fn hasRefArrayFields(comptime T: type) bool {
    return comptime sp.getRefArrayFields(T).len > 0;
}

/// Read entity ref array fields from a JSON object, allocate slices from arena,
/// remap entity IDs, and set the fields on the component.
pub fn readRefArrays(
    comptime T: type,
    comp: *T,
    json_obj: std.json.ObjectMap,
    id_map: *const std.AutoHashMap(u64, u64),
    arena: std.mem.Allocator,
) !void {
    const arr_fields = comptime sp.getRefArrayFields(T);
    if (arr_fields.len == 0) return;
    inline for (arr_fields) |field_name| {
        if (json_obj.get(field_name)) |arr_val| {
            const items = arr_val.array.items;
            const slice = try arena.alloc(u64, items.len);
            for (items, 0..) |item, i| {
                const saved_id: u64 = @intCast(item.integer);
                slice[i] = remapId(saved_id, id_map);
            }
            @field(comp, field_name) = slice;
        }
    }
}

// ── Utility ─────────────────────────────────────────────────────────────────

/// Extract the short name from a fully-qualified type name (last segment after '.').
pub fn componentName(comptime T: type) []const u8 {
    const full = @typeName(T);
    const idx = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[idx + 1 ..];
}

/// Parse a JSON value as the given float type, handling float, integer, and number_string.
pub fn jsonFloatAs(comptime T: type, value: std.json.Value) T {
    return switch (value) {
        .float => @floatCast(value.float),
        .integer => @floatFromInt(value.integer),
        .number_string => |s| std.fmt.parseFloat(T, s) catch 0.0,
        else => 0.0,
    };
}

/// Parse a JSON value as f32. Convenience wrapper for backward compat.
pub fn jsonFloat(value: std.json.Value) f32 {
    return jsonFloatAs(f32, value);
}

/// Check if a type is an EnumSet (has Key, MaskInt, insert declarations).
pub fn isEnumSet(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    return @hasDecl(T, "Key") and @hasDecl(T, "MaskInt") and @hasDecl(T, "insert");
}

/// Check if a u64 is in a set.
pub fn isInSet(id: u64, set: []const u64) bool {
    for (set) |sid| {
        if (sid == id) return true;
    }
    return false;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn noSkip(_: type, _: []const u8) bool {
    return false;
}

const TestEnum = enum { alpha, beta, gamma };

const TestStruct = struct {
    x: f32 = 0,
    y: f32 = 0,
    name: TestEnum = .alpha,
    active: bool = false,
    count: u32 = 0,
    opt: ?u64 = null,
};

test "roundtrip: struct serialization" {
    const value = TestStruct{ .x = 1.5, .y = -3.0, .name = .beta, .active = true, .count = 42, .opt = 100 };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    try writeComponent(TestStruct, &value, buf.writer(testing.allocator), noSkip);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.items, .{});
    defer parsed.deinit();

    const restored = try readComponent(TestStruct, parsed.value, noSkip);
    try testing.expectApproxEqAbs(@as(f32, 1.5), restored.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, -3.0), restored.y, 0.01);
    try testing.expectEqual(TestEnum.beta, restored.name);
    try testing.expect(restored.active);
    try testing.expectEqual(@as(u32, 42), restored.count);
    try testing.expectEqual(@as(?u64, 100), restored.opt);
}

test "roundtrip: null optional" {
    const value = TestStruct{ .opt = null };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    try writeComponent(TestStruct, &value, buf.writer(testing.allocator), noSkip);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.items, .{});
    defer parsed.deinit();

    const restored = try readComponent(TestStruct, parsed.value, noSkip);
    try testing.expectEqual(@as(?u64, null), restored.opt);
}

test "roundtrip: enum" {
    const value = TestEnum.gamma;

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    try writeComponent(TestEnum, &value, buf.writer(testing.allocator), noSkip);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.items, .{});
    defer parsed.deinit();

    const restored = try readComponent(TestEnum, parsed.value, noSkip);
    try testing.expectEqual(TestEnum.gamma, restored);
}

test "roundtrip: EnumSet" {
    const Set = std.EnumSet(TestEnum);
    var value = Set{};
    value.insert(.alpha);
    value.insert(.gamma);

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    try writeComponent(Set, &value, buf.writer(testing.allocator), noSkip);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.items, .{});
    defer parsed.deinit();

    const restored = try readComponent(Set, parsed.value, noSkip);
    try testing.expect(restored.contains(.alpha));
    try testing.expect(!restored.contains(.beta));
    try testing.expect(restored.contains(.gamma));
}

const SkipStruct = struct {
    a: u32 = 0,
    b: u32 = 99,
};

fn skipB(_: type, name: []const u8) bool {
    return std.mem.eql(u8, name, "b");
}

test "skipField: skipped fields get defaults" {
    const value = SkipStruct{ .a = 5, .b = 10 };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    try writeComponent(SkipStruct, &value, buf.writer(testing.allocator), skipB);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.items, .{});
    defer parsed.deinit();

    const restored = try readComponent(SkipStruct, parsed.value, skipB);
    try testing.expectEqual(@as(u32, 5), restored.a);
    try testing.expectEqual(@as(u32, 99), restored.b);
}

test "readComponentInto: partial update" {
    var existing = TestStruct{ .x = 1.0, .y = 2.0, .count = 10 };

    const json_str = "{\"x\": 5.0, \"count\": 20}";
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_str, .{});
    defer parsed.deinit();

    try readComponentInto(TestStruct, &existing, parsed.value, noSkip);
    try testing.expectApproxEqAbs(@as(f32, 5.0), existing.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 2.0), existing.y, 0.01);
    try testing.expectEqual(@as(u32, 20), existing.count);
}

test "remapId" {
    var map = std.AutoHashMap(u64, u64).init(testing.allocator);
    defer map.deinit();
    try map.put(10, 20);
    try map.put(30, 40);

    try testing.expectEqual(@as(u64, 20), remapId(10, &map));
    try testing.expectEqual(@as(u64, 40), remapId(30, &map));
    try testing.expectEqual(@as(u64, 99), remapId(99, &map));

    try testing.expectEqual(@as(?u64, 20), remapOptId(@as(?u64, 10), &map));
    try testing.expectEqual(@as(?u64, null), remapOptId(@as(?u64, null), &map));
}

test "remapEntityRefs: with remap_exclude" {
    const Comp = struct {
        pub const save = sp.Saveable(.saveable, @This(), .{
            .entity_refs = &.{ "target", "sentinel_field" },
            .remap_exclude = &.{"sentinel_field"},
        });
        target: u64 = 0,
        sentinel_field: ?u64 = null,
    };

    var map = std.AutoHashMap(u64, u64).init(testing.allocator);
    defer map.deinit();
    try map.put(10, 100);

    // Normal field remaps, excluded field is never touched
    var c1 = Comp{ .target = 10, .sentinel_field = 10 };
    remapEntityRefs(Comp, &c1, &map);
    try testing.expectEqual(@as(u64, 100), c1.target);
    try testing.expectEqual(@as(?u64, 10), c1.sentinel_field); // excluded — never remapped

    // Excluded field with sentinel — always preserved
    var c2 = Comp{ .target = 10, .sentinel_field = 999 };
    remapEntityRefs(Comp, &c2, &map);
    try testing.expectEqual(@as(u64, 100), c2.target);
    try testing.expectEqual(@as(?u64, 999), c2.sentinel_field); // excluded — preserved

    // Excluded field null — preserved
    var c3 = Comp{ .target = 10, .sentinel_field = null };
    remapEntityRefs(Comp, &c3, &map);
    try testing.expectEqual(@as(u64, 100), c3.target);
    try testing.expectEqual(@as(?u64, null), c3.sentinel_field);
}

test "remapEntityRefs: legacy style" {
    const LegacyComp = struct {
        pub const save_policy: sp.SavePolicy = .saveable;
        pub const entity_ref_fields = .{ "owner", "target" };
        owner: u64 = 0,
        target: ?u64 = null,
    };

    var map = std.AutoHashMap(u64, u64).init(testing.allocator);
    defer map.deinit();
    try map.put(5, 50);

    var c = LegacyComp{ .owner = 5, .target = 5 };
    remapEntityRefs(LegacyComp, &c, &map);
    try testing.expectEqual(@as(u64, 50), c.owner);
    try testing.expectEqual(@as(?u64, 50), c.target);
}

test "autoSkipField: new style" {
    const Comp = struct {
        pub const save = sp.Saveable(.saveable, @This(), .{
            .skip = &.{"cache"},
        });
        value: u32 = 0,
        cache: u32 = 0,
    };

    try testing.expect(autoSkipField(Comp, "cache"));
    try testing.expect(!autoSkipField(Comp, "value"));
}

test "autoSkipField: legacy style" {
    const Comp = struct {
        pub const skip_fields = .{"cache"};
        value: u32 = 0,
        cache: u32 = 0,
    };

    try testing.expect(autoSkipField(Comp, "cache"));
    try testing.expect(!autoSkipField(Comp, "value"));
}

test "hasRefArrayFields: new style" {
    const WithArrays = struct {
        pub const save = sp.Saveable(.saveable, @This(), .{
            .ref_arrays = &.{"children"},
            .skip = &.{"children"},
        });
        children: []const u64 = &.{},
    };
    const WithoutArrays = struct {
        pub const save = sp.Saveable(.saveable, @This(), .{});
        value: u32 = 0,
    };

    try testing.expect(hasRefArrayFields(WithArrays));
    try testing.expect(!hasRefArrayFields(WithoutArrays));
}

test "componentName" {
    try testing.expect(std.mem.eql(u8, "TestStruct", componentName(TestStruct)));
}

test "jsonFloat: handles int and float" {
    const int_val = std.json.Value{ .integer = 5 };
    try testing.expectApproxEqAbs(@as(f32, 5.0), jsonFloat(int_val), 0.01);

    const float_val = std.json.Value{ .float = 3.14 };
    try testing.expectApproxEqAbs(@as(f32, 3.14), jsonFloat(float_val), 0.01);
}

test "roundtrip: Saveable component with autoSkipField" {
    const Workstation = struct {
        pub const save = sp.Saveable(.saveable, @This(), .{
            .skip = &.{"cached"},
            .entity_refs = &.{"owner"},
        });
        name: u32 = 0,
        owner: u64 = 0,
        cached: u32 = 99,
    };

    const value = Workstation{ .name = 42, .owner = 10, .cached = 777 };

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(testing.allocator);
    try writeComponent(Workstation, &value, buf.writer(testing.allocator), autoSkipField);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.items, .{});
    defer parsed.deinit();

    var restored = try readComponent(Workstation, parsed.value, autoSkipField);
    try testing.expectEqual(@as(u32, 42), restored.name);
    try testing.expectEqual(@as(u64, 10), restored.owner);
    try testing.expectEqual(@as(u32, 99), restored.cached); // default, not 777

    // Remap entity refs
    var map = std.AutoHashMap(u64, u64).init(testing.allocator);
    defer map.deinit();
    try map.put(10, 200);
    remapEntityRefs(Workstation, &restored, &map);
    try testing.expectEqual(@as(u64, 200), restored.owner);
}
