const std = @import("std");
const Allocator = std.mem.Allocator;

/// A parsed ZON value — the runtime representation of any .zon expression.
pub const Value = union(enum) {
    /// .{ .key = value, ... }
    object: Object,
    /// .{ val1, val2, ... }
    array: Array,
    /// "hello"
    string: []const u8,
    /// 42, -20
    integer: i64,
    /// 0.9, 3.14
    float: f64,
    /// .hydroponics, .static
    enum_literal: []const u8,
    /// true / false
    boolean: bool,
    /// null
    null_value: void,

    pub const Object = struct {
        entries: []Entry,

        pub const Entry = struct {
            key: []const u8,
            value: Value,
        };

        pub fn get(self: Object, key: []const u8) ?Value {
            for (self.entries) |entry| {
                if (std.mem.eql(u8, entry.key, key)) return entry.value;
            }
            return null;
        }

        pub fn getObject(self: Object, key: []const u8) ?Object {
            const val = self.get(key) orelse return null;
            return switch (val) {
                .object => |o| o,
                else => null,
            };
        }

        pub fn getArray(self: Object, key: []const u8) ?Array {
            const val = self.get(key) orelse return null;
            return switch (val) {
                .array => |a| a,
                else => null,
            };
        }

        pub fn getString(self: Object, key: []const u8) ?[]const u8 {
            const val = self.get(key) orelse return null;
            return switch (val) {
                .string => |s| s,
                else => null,
            };
        }

        pub fn getInteger(self: Object, key: []const u8) ?i64 {
            const val = self.get(key) orelse return null;
            return switch (val) {
                .integer => |i| i,
                else => null,
            };
        }

        pub fn getFloat(self: Object, key: []const u8) ?f64 {
            const val = self.get(key) orelse return null;
            return switch (val) {
                .float => |f| f,
                else => null,
            };
        }

        pub fn getEnum(self: Object, key: []const u8) ?[]const u8 {
            const val = self.get(key) orelse return null;
            return switch (val) {
                .enum_literal => |e| e,
                else => null,
            };
        }

        pub fn getBool(self: Object, key: []const u8) ?bool {
            const val = self.get(key) orelse return null;
            return switch (val) {
                .boolean => |b| b,
                else => null,
            };
        }
    };

    pub const Array = struct {
        items: []Value,

        pub fn len(self: Array) usize {
            return self.items.len;
        }
    };

    pub fn asObject(self: Value) ?Object {
        return switch (self) {
            .object => |o| o,
            else => null,
        };
    }

    pub fn asArray(self: Value) ?Array {
        return switch (self) {
            .array => |a| a,
            else => null,
        };
    }

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asInteger(self: Value) ?i64 {
        return switch (self) {
            .integer => |i| i,
            else => null,
        };
    }

    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .float => |f| f,
            else => null,
        };
    }

    pub fn asEnum(self: Value) ?[]const u8 {
        return switch (self) {
            .enum_literal => |e| e,
            else => null,
        };
    }

    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .boolean => |b| b,
            else => null,
        };
    }
};

pub const ParseError = error{
    UnexpectedCharacter,
    UnexpectedEof,
    InvalidNumber,
    InvalidEscape,
    UnterminatedString,
    ExpectedDot,
    ExpectedOpenBrace,
    ExpectedEquals,
    ExpectedCommaOrCloseBrace,
    OutOfMemory,
};

pub const Location = struct {
    line: usize,
    column: usize,
    offset: usize,
};

/// Runtime ZON parser. Parses the subset of ZON used by labelle scene/prefab files.
pub const Parser = struct {
    source: []const u8,
    pos: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, source: []const u8) Parser {
        return .{
            .source = source,
            .pos = 0,
            .allocator = allocator,
        };
    }

    /// Parse the entire source as a ZON value.
    pub fn parse(self: *Parser) ParseError!Value {
        self.skipWhitespaceAndComments();
        const value = try self.parseValue();
        self.skipWhitespaceAndComments();
        return value;
    }

    /// Parse a file from disk.
    pub fn parseFile(allocator: Allocator, path: []const u8) !Value {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const source = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
        var parser = Parser.init(allocator, source);
        return parser.parse();
    }

    pub fn getLocation(self: *const Parser) Location {
        var line: usize = 1;
        var col: usize = 1;
        for (self.source[0..self.pos]) |c| {
            if (c == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        return .{ .line = line, .column = col, .offset = self.pos };
    }

    fn parseValue(self: *Parser) ParseError!Value {
        self.skipWhitespaceAndComments();
        if (self.pos >= self.source.len) return error.UnexpectedEof;

        const c = self.source[self.pos];

        // String
        if (c == '"') return self.parseString();

        // Dot-prefixed: struct/tuple literal (.{), enum literal (.name)
        if (c == '.') return self.parseDotValue();

        // Number (digit or minus)
        if (c == '-' or std.ascii.isDigit(c)) return self.parseNumber();

        // Keywords: true, false, null
        if (std.ascii.isAlphabetic(c)) return self.parseKeyword();

        return error.UnexpectedCharacter;
    }

    fn parseDotValue(self: *Parser) ParseError!Value {
        // Consume '.'
        self.pos += 1;
        if (self.pos >= self.source.len) return error.UnexpectedEof;

        if (self.source[self.pos] == '{') {
            return self.parseStructOrTuple();
        }

        // Enum literal: .identifier
        return self.parseEnumLiteral();
    }

    fn parseStructOrTuple(self: *Parser) ParseError!Value {
        // Consume '{'
        self.pos += 1;
        self.skipWhitespaceAndComments();

        if (self.pos >= self.source.len) return error.UnexpectedEof;

        // Empty: .{}
        if (self.source[self.pos] == '}') {
            self.pos += 1;
            return Value{ .object = .{ .entries = &.{} } };
        }

        // Peek: if next non-whitespace is '.identifier =', it's an object.
        // Otherwise it's a tuple (array).
        if (self.source[self.pos] == '.') {
            // Could be object (.key = ...) or tuple of enum/struct (.val, ...)
            // Look ahead for '=' after identifier
            if (self.looksLikeObjectEntry()) {
                return self.parseObject();
            }
        }

        // It's a tuple/array
        return self.parseTupleArray();
    }

    fn looksLikeObjectEntry(self: *Parser) bool {
        var look = self.pos;
        if (look >= self.source.len or self.source[look] != '.') return false;
        look += 1;

        // Skip identifier
        while (look < self.source.len and (std.ascii.isAlphanumeric(self.source[look]) or self.source[look] == '_')) {
            look += 1;
        }

        // Skip whitespace
        while (look < self.source.len and (self.source[look] == ' ' or self.source[look] == '\t' or self.source[look] == '\n' or self.source[look] == '\r')) {
            look += 1;
        }

        return look < self.source.len and self.source[look] == '=';
    }

    fn parseObject(self: *Parser) ParseError!Value {
        var entries: std.ArrayList(Value.Object.Entry) = .{};

        while (true) {
            self.skipWhitespaceAndComments();
            if (self.pos >= self.source.len) return error.UnexpectedEof;
            if (self.source[self.pos] == '}') {
                self.pos += 1;
                const owned = try entries.toOwnedSlice(self.allocator);
                return Value{ .object = .{ .entries = owned } };
            }

            // Expect '.key'
            if (self.source[self.pos] != '.') return error.ExpectedDot;
            self.pos += 1;

            const key = self.readIdentifier();
            if (key.len == 0) return error.UnexpectedCharacter;

            self.skipWhitespaceAndComments();

            // Expect '='
            if (self.pos >= self.source.len or self.source[self.pos] != '=') return error.ExpectedEquals;
            self.pos += 1;

            self.skipWhitespaceAndComments();

            const value = try self.parseValue();

            try entries.append(self.allocator, .{ .key = key, .value = value });

            self.skipWhitespaceAndComments();

            // Expect ',' or '}'
            if (self.pos < self.source.len and self.source[self.pos] == ',') {
                self.pos += 1;
            }
        }
    }

    fn parseTupleArray(self: *Parser) ParseError!Value {
        var items: std.ArrayList(Value) = .{};

        while (true) {
            self.skipWhitespaceAndComments();
            if (self.pos >= self.source.len) return error.UnexpectedEof;
            if (self.source[self.pos] == '}') {
                self.pos += 1;
                const owned = try items.toOwnedSlice(self.allocator);
                return Value{ .array = .{ .items = owned } };
            }

            const value = try self.parseValue();
            try items.append(self.allocator, value);

            self.skipWhitespaceAndComments();

            // Expect ',' or '}'
            if (self.pos < self.source.len and self.source[self.pos] == ',') {
                self.pos += 1;
            }
        }
    }

    fn parseEnumLiteral(self: *Parser) ParseError!Value {
        const name = self.readIdentifier();
        if (name.len == 0) return error.UnexpectedCharacter;
        return Value{ .enum_literal = name };
    }

    fn parseString(self: *Parser) ParseError!Value {
        // Consume opening '"'
        self.pos += 1;

        var result: std.ArrayList(u8) = .{};

        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '"') {
                self.pos += 1;
                const owned = try result.toOwnedSlice(self.allocator);
                return Value{ .string = owned };
            }
            if (c == '\\') {
                self.pos += 1;
                if (self.pos >= self.source.len) return error.InvalidEscape;
                const escaped = self.source[self.pos];
                switch (escaped) {
                    'n' => try result.append(self.allocator, '\n'),
                    't' => try result.append(self.allocator, '\t'),
                    'r' => try result.append(self.allocator, '\r'),
                    '\\' => try result.append(self.allocator, '\\'),
                    '"' => try result.append(self.allocator, '"'),
                    else => return error.InvalidEscape,
                }
                self.pos += 1;
                continue;
            }
            try result.append(self.allocator, c);
            self.pos += 1;
        }
        return error.UnterminatedString;
    }

    fn parseNumber(self: *Parser) ParseError!Value {
        const start = self.pos;
        var is_float = false;

        // Optional minus
        if (self.pos < self.source.len and self.source[self.pos] == '-') {
            self.pos += 1;
        }

        // Integer part
        if (self.pos >= self.source.len or !std.ascii.isDigit(self.source[self.pos])) {
            return error.InvalidNumber;
        }
        while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
            self.pos += 1;
        }

        // Fractional part
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            // Look ahead: if next char is a digit, it's a float.
            if (self.pos + 1 < self.source.len and std.ascii.isDigit(self.source[self.pos + 1])) {
                is_float = true;
                self.pos += 1; // consume '.'
                while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
                    self.pos += 1;
                }
            }
        }

        const num_str = self.source[start..self.pos];

        if (is_float) {
            const f = std.fmt.parseFloat(f64, num_str) catch return error.InvalidNumber;
            return Value{ .float = f };
        } else {
            const i = std.fmt.parseInt(i64, num_str, 10) catch return error.InvalidNumber;
            return Value{ .integer = i };
        }
    }

    fn parseKeyword(self: *Parser) ParseError!Value {
        const ident = self.readIdentifier();
        if (std.mem.eql(u8, ident, "true")) return Value{ .boolean = true };
        if (std.mem.eql(u8, ident, "false")) return Value{ .boolean = false };
        if (std.mem.eql(u8, ident, "null")) return Value{ .null_value = {} };
        return error.UnexpectedCharacter;
    }

    fn readIdentifier(self: *Parser) []const u8 {
        const start = self.pos;
        while (self.pos < self.source.len and
            (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_'))
        {
            self.pos += 1;
        }
        return self.source[start..self.pos];
    }

    fn skipWhitespaceAndComments(self: *Parser) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
                continue;
            }
            // Line comment
            if (c == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
                self.pos += 2;
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.pos += 1;
                }
                continue;
            }
            break;
        }
    }
};

// === Pretty printer for debugging ===

pub fn printValue(writer: anytype, value: Value, indent: usize) !void {
    switch (value) {
        .object => |obj| {
            if (obj.entries.len == 0) {
                try writer.writeAll(".{}");
                return;
            }
            try writer.writeAll(".{\n");
            for (obj.entries) |entry| {
                try writeIndent(writer, indent + 1);
                try writer.print(".{s} = ", .{entry.key});
                try printValue(writer, entry.value, indent + 1);
                try writer.writeAll(",\n");
            }
            try writeIndent(writer, indent);
            try writer.writeAll("}");
        },
        .array => |arr| {
            if (arr.items.len == 0) {
                try writer.writeAll(".{}");
                return;
            }
            try writer.writeAll(".{\n");
            for (arr.items) |item| {
                try writeIndent(writer, indent + 1);
                try printValue(writer, item, indent + 1);
                try writer.writeAll(",\n");
            }
            try writeIndent(writer, indent);
            try writer.writeAll("}");
        },
        .string => |s| try writer.print("\"{s}\"", .{s}),
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .enum_literal => |e| try writer.print(".{s}", .{e}),
        .boolean => |b| try writer.print("{}", .{b}),
        .null_value => try writer.writeAll("null"),
    }
}

fn writeIndent(writer: anytype, level: usize) !void {
    for (0..level) |_| {
        try writer.writeAll("    ");
    }
}

// ======================== Tests ========================
// Note: Tests use an arena allocator to avoid tedious per-allocation cleanup.

test "parse empty object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = Parser.init(alloc, ".{}");
    const val = try p.parse();
    const obj = val.asObject().?;
    try std.testing.expectEqual(@as(usize, 0), obj.entries.len);
}

test "parse simple object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = Parser.init(alloc, ".{ .x = 100, .y = 200 }");
    const val = try p.parse();
    const obj = val.asObject().?;
    try std.testing.expectEqual(@as(i64, 100), obj.getInteger("x").?);
    try std.testing.expectEqual(@as(i64, 200), obj.getInteger("y").?);
}

test "parse negative integers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = Parser.init(alloc, ".{ .x = -20, .y = 0 }");
    const val = try p.parse();
    const obj = val.asObject().?;
    try std.testing.expectEqual(@as(i64, -20), obj.getInteger("x").?);
    try std.testing.expectEqual(@as(i64, 0), obj.getInteger("y").?);
}

test "parse floats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = Parser.init(alloc, ".{ .restitution = 0.9, .friction = 0.1 }");
    const val = try p.parse();
    const obj = val.asObject().?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), obj.getFloat("restitution").?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), obj.getFloat("friction").?, 0.001);
}

test "parse string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = Parser.init(alloc, ".{ .name = \"main\" }");
    const val = try p.parse();
    const obj = val.asObject().?;
    try std.testing.expectEqualStrings("main", obj.getString("name").?);
}

test "parse enum literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = Parser.init(alloc, ".{ .body_type = .static }");
    const val = try p.parse();
    const obj = val.asObject().?;
    try std.testing.expectEqualStrings("static", obj.getEnum("body_type").?);
}

test "parse boolean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = Parser.init(alloc, ".{ .visible = true, .hidden = false }");
    const val = try p.parse();
    const obj = val.asObject().?;
    try std.testing.expectEqual(true, obj.getBool("visible").?);
    try std.testing.expectEqual(false, obj.getBool("hidden").?);
}

test "parse tuple/array of strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = Parser.init(alloc,
        \\.{ "hello", "world" }
    );
    const val = try p.parse();
    const arr = val.asArray().?;
    try std.testing.expectEqual(@as(usize, 2), arr.len());
    try std.testing.expectEqualStrings("hello", arr.items[0].asString().?);
    try std.testing.expectEqualStrings("world", arr.items[1].asString().?);
}

test "parse nested objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = Parser.init(alloc,
        \\.{ .components = .{ .Position = .{ .x = 50, .y = 100 } } }
    );
    const val = try p.parse();
    const obj = val.asObject().?;
    const components = obj.getObject("components").?;
    const position = components.getObject("Position").?;
    try std.testing.expectEqual(@as(i64, 50), position.getInteger("x").?);
    try std.testing.expectEqual(@as(i64, 100), position.getInteger("y").?);
}

test "parse array of objects (entity list)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = Parser.init(alloc,
        \\.{
        \\    .{ .prefab = "worker", .components = .{ .Position = .{ .x = 0, .y = 0 } } },
        \\    .{ .prefab = "worker", .components = .{ .Position = .{ .x = 50, .y = 0 } } },
        \\}
    );
    const val = try p.parse();
    const arr = val.asArray().?;
    try std.testing.expectEqual(@as(usize, 2), arr.len());

    const first = arr.items[0].asObject().?;
    try std.testing.expectEqualStrings("worker", first.getString("prefab").?);
    const pos = first.getObject("components").?.getObject("Position").?;
    try std.testing.expectEqual(@as(i64, 0), pos.getInteger("x").?);

    const second = arr.items[1].asObject().?;
    const pos2 = second.getObject("components").?.getObject("Position").?;
    try std.testing.expectEqual(@as(i64, 50), pos2.getInteger("x").?);
}

test "parse comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = Parser.init(alloc,
        \\.{
        \\    // This is a comment
        \\    .name = "main",
        \\    // Another comment
        \\    .x = 42,
        \\}
    );
    const val = try p.parse();
    const obj = val.asObject().?;
    try std.testing.expectEqualStrings("main", obj.getString("name").?);
    try std.testing.expectEqual(@as(i64, 42), obj.getInteger("x").?);
}

test "parse full scene structure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = Parser.init(alloc,
        \\.{
        \\    .name = "main",
        \\    .scripts = .{
        \\        "pathfinder_bridge",
        \\        "camera_control",
        \\    },
        \\    .entities = .{
        \\        .{ .prefab = "ship_carcase", .components = .{ .Position = .{ .x = 0, .y = 0 } } },
        \\        .{ .prefab = "worker", .components = .{ .Position = .{ .x = 50, .y = 93 } } },
        \\    },
        \\}
    );
    const val = try p.parse();
    const scene = val.asObject().?;

    try std.testing.expectEqualStrings("main", scene.getString("name").?);

    const scripts = scene.getArray("scripts").?;
    try std.testing.expectEqual(@as(usize, 2), scripts.len());
    try std.testing.expectEqualStrings("pathfinder_bridge", scripts.items[0].asString().?);
    try std.testing.expectEqualStrings("camera_control", scripts.items[1].asString().?);

    const entities = scene.getArray("entities").?;
    try std.testing.expectEqual(@as(usize, 2), entities.len());
    try std.testing.expectEqualStrings("ship_carcase", entities.items[0].asObject().?.getString("prefab").?);

    const worker_pos = entities.items[1].asObject().?.getObject("components").?.getObject("Position").?;
    try std.testing.expectEqual(@as(i64, 50), worker_pos.getInteger("x").?);
    try std.testing.expectEqual(@as(i64, 93), worker_pos.getInteger("y").?);
}

test "parse prefab with enums and floats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = Parser.init(alloc,
        \\.{
        \\    .components = .{
        \\        .Workstation = .{
        \\            .workstation_type = .hydroponics,
        \\            .process_duration = 3,
        \\        },
        \\        .TendableWorkstation = .{
        \\            .maintenance_per_work = 0.3,
        \\            .work_ready_threshold = 0.5,
        \\            .max_level = 5,
        \\        },
        \\    },
        \\}
    );
    const val = try p.parse();
    const root = val.asObject().?;
    const components = root.getObject("components").?;

    const ws = components.getObject("Workstation").?;
    try std.testing.expectEqualStrings("hydroponics", ws.getEnum("workstation_type").?);
    try std.testing.expectEqual(@as(i64, 3), ws.getInteger("process_duration").?);

    const tws = components.getObject("TendableWorkstation").?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), tws.getFloat("maintenance_per_work").?, 0.001);
    try std.testing.expectEqual(@as(i64, 5), tws.getInteger("max_level").?);
}

test "parse deeply nested storages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = Parser.init(alloc,
        \\.{
        \\    .components = .{
        \\        .Workstation = .{
        \\            .storages = .{
        \\                .{
        \\                    .components = .{
        \\                        .Position = .{ .x = 42, .y = -20 },
        \\                        .Storage = .{ .accepted_items = .{ .Water = true } },
        \\                        .Eis = .{},
        \\                    },
        \\                },
        \\            },
        \\        },
        \\    },
        \\}
    );
    const val = try p.parse();
    const root = val.asObject().?;
    const ws = root.getObject("components").?.getObject("Workstation").?;
    const storages = ws.getArray("storages").?;
    try std.testing.expectEqual(@as(usize, 1), storages.len());

    const storage_comps = storages.items[0].asObject().?.getObject("components").?;
    const pos = storage_comps.getObject("Position").?;
    try std.testing.expectEqual(@as(i64, 42), pos.getInteger("x").?);
    try std.testing.expectEqual(@as(i64, -20), pos.getInteger("y").?);

    const accepted = storage_comps.getObject("Storage").?.getObject("accepted_items").?;
    try std.testing.expectEqual(true, accepted.getBool("Water").?);

    const eis = storage_comps.getObject("Eis").?;
    try std.testing.expectEqual(@as(usize, 0), eis.entries.len);
}

test "parse bouncing ball components (union-like nested objects)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var p = Parser.init(alloc,
        \\.{
        \\    .components = .{
        \\        .Shape = .{ .shape = .{ .circle = .{ .radius = 30 } }, .color = .{ .r = 255, .g = 100, .b = 100 } },
        \\        .RigidBody = .{ .body_type = .dynamic },
        \\        .Collider = .{
        \\            .shape = .{ .circle = .{ .radius = 30 } },
        \\            .restitution = 0.9,
        \\            .friction = 0.1,
        \\        },
        \\    },
        \\}
    );
    const val = try p.parse();
    const components = val.asObject().?.getObject("components").?;

    // Shape
    const shape = components.getObject("Shape").?;
    const circle = shape.getObject("shape").?.getObject("circle").?;
    try std.testing.expectEqual(@as(i64, 30), circle.getInteger("radius").?);
    const color = shape.getObject("color").?;
    try std.testing.expectEqual(@as(i64, 255), color.getInteger("r").?);

    // RigidBody
    const rb = components.getObject("RigidBody").?;
    try std.testing.expectEqualStrings("dynamic", rb.getEnum("body_type").?);

    // Collider
    const collider = components.getObject("Collider").?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), collider.getFloat("restitution").?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), collider.getFloat("friction").?, 0.001);
}

test "parse mixed tuple (objects and strings)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // This is like a scripts tuple that mixes with entity objects — edge case
    var p = Parser.init(alloc,
        \\.{
        \\    .{ .prefab = "movement_node", .components = .{ .Position = .{ .x = 20, .y = 93 } } },
        \\    .{ .prefab = "movement_node", .components = .{ .Position = .{ .x = 73, .y = 93 } } },
        \\}
    );
    const val = try p.parse();
    const arr = val.asArray().?;
    try std.testing.expectEqual(@as(usize, 2), arr.len());
    try std.testing.expectEqualStrings("movement_node", arr.items[0].asObject().?.getString("prefab").?);
    try std.testing.expectEqual(@as(i64, 73), arr.items[1].asObject().?.getObject("components").?.getObject("Position").?.getInteger("x").?);
}
