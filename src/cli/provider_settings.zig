//! Shared project schema, mirrored by the CLI and assembler.
const std = @import("std");

pub const Entry = struct { package: []const u8, file: []const u8 };

pub fn validateProject(a: std.mem.Allocator, source: [:0]const u8) !void {
    const entries = try parse(a, source);
    defer std.zon.parse.free(a, entries);
    if (entries.len == 0) return;
    // Validate before parsing the full ProjectConfig, whose static defaults
    // cannot be safely released with zon.parse.free on a later rejection.
    const References = struct { plugins: []const struct { name: []const u8 } = &.{} };
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(a);
    const refs = try std.zon.parse.fromSliceAlloc(References, a, source, &diag, .{ .ignore_unknown_fields = true });
    defer std.zon.parse.free(a, refs);
    try validate(entries, refs.plugins);
}

pub fn validate(entries: []const Entry, plugins: anytype) !void {
    for (entries, 0..) |entry, i| {
        if (entry.package.len == 0) return error.InvalidProviderConfigPackage;
        if (entry.file.len == 0 or entry.file[0] == '/' or std.mem.indexOfAny(u8, entry.file, "\\:\x00") != null)
            return error.InvalidProviderConfigPath;
        var parts = std.mem.splitScalar(u8, entry.file, '/');
        while (parts.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, "..")) return error.InvalidProviderConfigPath;
        }
        for (entries[0..i]) |previous| if (std.mem.eql(u8, previous.package, entry.package)) return error.DuplicateProviderConfig;
        var declared = false;
        for (plugins) |plugin| if (std.mem.eql(u8, plugin.name, entry.package)) {
            declared = true;
        };
        if (!declared) return error.UndeclaredProviderConfig;
    }
}

/// Strictly parse this subtree even when a caller ignores other project fields.
/// Caller frees the returned entries with std.zon.parse.free.
pub fn parse(a: std.mem.Allocator, source: [:0]const u8) ![]const Entry {
    var transferred = false;
    var ast = try std.zig.Ast.parse(a, source, .zon);
    defer if (!transferred) ast.deinit(a);
    if (ast.errors.len != 0) return error.ParseZon;
    var zoir = try std.zig.ZonGen.generate(a, ast, .{ .parse_str_lits = false });
    defer if (!transferred) zoir.deinit(a);
    if (zoir.hasCompileErrors()) return error.ParseZon;
    const fields = switch (std.zig.Zoir.Node.Index.root.get(zoir)) {
        .struct_literal => |fields| fields,
        else => return &.{}, // The owning project parser diagnoses the root.
    };
    for (fields.names, 0..) |name, i| {
        if (std.mem.eql(u8, name.get(zoir), "provider_config")) {
            // Diagnostics takes ownership of the AST/ZOIR and any error text.
            // Passing null leaks unexpected-field diagnostics in Zig 0.16.
            var diag: std.zon.parse.Diagnostics = .{};
            transferred = true;
            defer diag.deinit(a);
            return std.zon.parse.fromZoirNodeAlloc([]const Entry, a, ast, zoir, fields.vals.at(@intCast(i)), &diag, .{});
        }
    }
    return &.{};
}

test "provider settings: strict mapping, declarations and portable paths" {
    const a = std.testing.allocator;
    const entries = try parse(a, ".{ .unrelated = true, .provider_config = .{ .{ .package = \"fixture\", .file = \"providers/settings.json\" } } }");
    defer std.zon.parse.free(a, entries);
    const plugins = [_]struct { name: []const u8 }{.{ .name = "fixture" }};
    try validate(entries, &plugins);
    try std.testing.expectError(error.ParseZon, parse(a, ".{ .provider_config = .{ .{ .package = \"fixture\", .file = \"x\", .typo = true } } }"));
    try std.testing.expectError(error.DuplicateProviderConfig, validate(&.{ entries[0], entries[0] }, &plugins));
    try std.testing.expectError(error.UndeclaredProviderConfig, validate(entries, plugins[0..0]));
    try std.testing.expectError(error.InvalidProviderConfigPackage, validate(&.{.{ .package = "", .file = "x.json" }}, &plugins));
    // Any declared plugin name is a valid package; only an exact match counts.
    const numeric = [_]struct { name: []const u8 }{.{ .name = "3d_renderer" }};
    try validate(&.{.{ .package = "3d_renderer", .file = "providers/3d.json" }}, &numeric);
    try std.testing.expectError(error.UndeclaredProviderConfig, validate(&.{.{ .package = "3d_renderer", .file = "providers/3d.json" }}, &plugins));
    for ([_][]const u8{ "", "../escape.json", "/absolute", "C:/absolute", "a\\b.json", "a//b.json" }) |path| {
        try std.testing.expectError(error.InvalidProviderConfigPath, validate(&.{.{ .package = "fixture", .file = path }}, &plugins));
    }
}
