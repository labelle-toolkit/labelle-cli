//! Shared project schema, mirrored by the CLI and assembler.
const std = @import("std");

pub const Entry = struct { package: []const u8, file: []const u8 };

/// Validate the `.provider_config` subtree of a project.labelle `source`.
/// `labelle_path` non-null prints a diagnostic naming the project file and
/// the offending mapping before returning the error (the verbose
/// `config.readProjectConfig` path, codex #460): without it a bad mapping
/// made `build`/`generate`/`run` exit 1 with no message.
pub fn validateProject(a: std.mem.Allocator, source: [:0]const u8, labelle_path: ?[]const u8) !void {
    const entries = try parseReporting(a, source, labelle_path);
    defer std.zon.parse.free(a, entries);
    if (entries.len == 0) return;
    // Validate before parsing the full ProjectConfig, whose static defaults
    // cannot be safely released with zon.parse.free on a later rejection.
    const References = struct { plugins: []const struct { name: []const u8 } = &.{} };
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(a);
    const refs = std.zon.parse.fromSliceAlloc(References, a, source, &diag, .{ .ignore_unknown_fields = true }) catch |err| {
        if (labelle_path) |path| std.debug.print("labelle: could not parse '{s}': {any}\n{f}", .{ path, err, &diag });
        return err;
    };
    defer std.zon.parse.free(a, refs);
    var bad: usize = 0;
    validateAt(entries, refs.plugins, &bad) catch |err| {
        if (labelle_path) |path| report(path, err, bad, entries[bad]);
        return err;
    };
}

/// The whole file is not valid ZON: same wording as the full-project parse.
fn syntaxError(labelle_path: ?[]const u8) error{ParseZon} {
    if (labelle_path) |path| std.debug.print("labelle: could not parse '{s}': error.ParseZon\n", .{path});
    return error.ParseZon;
}

fn report(labelle_path: []const u8, err: anyerror, index: usize, entry: Entry) void {
    std.debug.print("labelle: invalid .provider_config in '{s}': ", .{labelle_path});
    switch (err) {
        error.InvalidProviderConfigPackage => std.debug.print("entry #{d} has an empty .package", .{index + 1}),
        error.InvalidProviderConfigPath => std.debug.print(
            "package '{s}' has invalid .file '{s}' (must be a relative path inside the project using '/' separators, with no '..' or empty segments, '\\' or ':')",
            .{ entry.package, entry.file },
        ),
        error.DuplicateProviderConfig => std.debug.print("package '{s}' is mapped more than once", .{entry.package}),
        error.UndeclaredProviderConfig => std.debug.print("package '{s}' is not declared in .plugins", .{entry.package}),
        else => std.debug.print("entry #{d}", .{index + 1}),
    }
    std.debug.print(" ({s})\n", .{@errorName(err)});
}

pub fn validate(entries: []const Entry, plugins: anytype) !void {
    var bad: usize = 0;
    return validateAt(entries, plugins, &bad);
}

/// `validate`, also storing the index of the rejected entry in `bad`.
fn validateAt(entries: []const Entry, plugins: anytype, bad: *usize) !void {
    for (entries, 0..) |entry, i| {
        bad.* = i;
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
    return parseReporting(a, source, null);
}

/// `parse`; a non-null `labelle_path` prints why the subtree was rejected.
fn parseReporting(a: std.mem.Allocator, source: [:0]const u8, labelle_path: ?[]const u8) ![]const Entry {
    var transferred = false;
    var ast = try std.zig.Ast.parse(a, source, .zon);
    defer if (!transferred) ast.deinit(a);
    if (ast.errors.len != 0) return syntaxError(labelle_path);
    var zoir = try std.zig.ZonGen.generate(a, ast, .{ .parse_str_lits = false });
    defer if (!transferred) zoir.deinit(a);
    if (zoir.hasCompileErrors()) return syntaxError(labelle_path);
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
            return std.zon.parse.fromZoirNodeAlloc([]const Entry, a, ast, zoir, fields.vals.at(@intCast(i)), &diag, .{}) catch |err| {
                if (labelle_path) |path| std.debug.print(
                    "labelle: invalid .provider_config in '{s}': malformed mapping record; each entry must be .{{ .package = \"<plugin>\", .file = \"<relative path>\" }} ({s})\n{f}",
                    .{ path, @errorName(err), &diag },
                );
                return err;
            };
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
    // The package rule is exact match against a declared plugin, nothing
    // narrower: a digit-leading name the scanner accepts (sanitize.zig) is
    // valid once declared, and only its absence from `.plugins` rejects it.
    const digit_led = [_]Entry{.{ .package = "3d_renderer", .file = "providers/renderer.json" }};
    try validate(&digit_led, &[_]struct { name: []const u8 }{.{ .name = "3d_renderer" }});
    try std.testing.expectError(error.UndeclaredProviderConfig, validate(&digit_led, &plugins));
    try std.testing.expectError(error.InvalidProviderConfigPackage, validate(&.{.{ .package = "", .file = "providers/x.json" }}, &plugins));
    for ([_][]const u8{ "", "../escape.json", "/absolute", "C:/absolute", "a\\b.json", "a//b.json" }) |path| {
        try std.testing.expectError(error.InvalidProviderConfigPath, validate(&.{.{ .package = "fixture", .file = path }}, &plugins));
    }
}
