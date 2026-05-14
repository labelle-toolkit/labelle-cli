const std = @import("std");
const gen = @import("generator");
const assembler = @import("assembler.zig");
const config = @import("config.zig");

/// Bump version fields in project.labelle.
pub fn cmdUpgrade(allocator: std.mem.Allocator, project_dir: []const u8, cfg: gen.ProjectConfig, cmd_args: []const []const u8) !void {
    const labelle_path = try std.fs.path.join(allocator, &.{ project_dir, "project.labelle" });
    defer allocator.free(labelle_path);

    var content = try std.Io.Dir.cwd().readFileAlloc(config.globalIo(), labelle_path, allocator, .limited(1024 * 1024));

    if (cmd_args.len == 0) {
        std.debug.print("labelle: upgrading to compatible set (core={s}, engine={s}, gfx={s}, cli={s})...\n", .{ gen.CORE_VERSION, gen.ENGINE_VERSION, gen.GFX_VERSION, gen.CLI_VERSION });
        content = try replaceAndFree(allocator, content, "core_version", cfg.core_version, gen.CORE_VERSION);
        content = try replaceAndFree(allocator, content, "engine_version", cfg.engine_version, gen.ENGINE_VERSION);
        content = try replaceAndFree(allocator, content, "gfx_version", cfg.gfx_version, gen.GFX_VERSION);
        content = try replaceAndFree(allocator, content, "labelle_version", cfg.labelle_version, gen.CLI_VERSION);
    } else {
        const pkg = cmd_args[0];
        const default_version: []const u8 = if (std.mem.eql(u8, pkg, "core"))
            gen.CORE_VERSION
        else if (std.mem.eql(u8, pkg, "engine"))
            gen.ENGINE_VERSION
        else if (std.mem.eql(u8, pkg, "gfx"))
            gen.GFX_VERSION
        else if (std.mem.eql(u8, pkg, "assembler"))
            assembler.DEFAULT_ASSEMBLER_VERSION
        else
            gen.CLI_VERSION;
        const version = if (cmd_args.len > 1) cmd_args[1] else default_version;

        if (std.mem.eql(u8, pkg, "core")) {
            content = try replaceAndFree(allocator, content, "core_version", cfg.core_version, version);
        } else if (std.mem.eql(u8, pkg, "engine")) {
            content = try replaceAndFree(allocator, content, "engine_version", cfg.engine_version, version);
        } else if (std.mem.eql(u8, pkg, "gfx")) {
            content = try replaceAndFree(allocator, content, "gfx_version", cfg.gfx_version, version);
        } else if (std.mem.eql(u8, pkg, "labelle") or std.mem.eql(u8, pkg, "cli")) {
            content = try replaceAndFree(allocator, content, "labelle_version", cfg.labelle_version, version);
        } else if (std.mem.eql(u8, pkg, "assembler")) {
            // If assembler_version already exists, replace it; otherwise append it before the closing `}`
            if (std.mem.indexOf(u8, content, ".assembler_version")) |_| {
                const old_asm = cfg.assembler_version orelse "0.0.0";
                content = try replaceAndFree(allocator, content, "assembler_version", old_asm, version);
            } else {
                // Insert assembler_version before the final closing brace
                content = try insertBeforeClosingBrace(allocator, content, "assembler_version", version);
            }
        } else if (std.mem.eql(u8, pkg, "all")) {
            content = try replaceAndFree(allocator, content, "core_version", cfg.core_version, gen.CORE_VERSION);
            content = try replaceAndFree(allocator, content, "engine_version", cfg.engine_version, gen.ENGINE_VERSION);
            content = try replaceAndFree(allocator, content, "gfx_version", cfg.gfx_version, gen.GFX_VERSION);
            content = try replaceAndFree(allocator, content, "labelle_version", cfg.labelle_version, gen.CLI_VERSION);
            // Also upgrade assembler if it exists (or add it)
            if (std.mem.indexOf(u8, content, ".assembler_version")) |_| {
                const old_asm = cfg.assembler_version orelse "0.0.0";
                content = try replaceAndFree(allocator, content, "assembler_version", old_asm, assembler.DEFAULT_ASSEMBLER_VERSION);
            } else {
                content = try insertBeforeClosingBrace(allocator, content, "assembler_version", assembler.DEFAULT_ASSEMBLER_VERSION);
            }
        } else {
            std.debug.print("labelle upgrade: unknown package '{s}'\n", .{pkg});
            std.debug.print("  packages: core, engine, gfx, cli, assembler, all\n", .{});
            allocator.free(content);
            return error.UnknownPackage;
        }

        std.debug.print("labelle: upgrading {s} to {s}...\n", .{ pkg, version });
    }

    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{
        .sub_path = labelle_path,
        .data = content,
    });
    allocator.free(content);

    std.debug.print("labelle: project.labelle updated\n", .{});
    std.debug.print("  run 'labelle generate' to regenerate build files\n", .{});
}

fn replaceAndFree(allocator: std.mem.Allocator, old_content: []u8, field_name: []const u8, old_value: []const u8, new_value: []const u8) ![]u8 {
    errdefer allocator.free(old_content);
    const result = try replaceVersionField(allocator, old_content, field_name, old_value, new_value);
    allocator.free(old_content);
    return result;
}

fn replaceVersionField(allocator: std.mem.Allocator, content: []const u8, field_name: []const u8, old_value: []const u8, new_value: []const u8) ![]u8 {
    const search = try std.fmt.allocPrint(allocator, ".{s} = \"{s}\"", .{ field_name, old_value });
    defer allocator.free(search);
    const replace = try std.fmt.allocPrint(allocator, ".{s} = \"{s}\"", .{ field_name, new_value });
    defer allocator.free(replace);

    if (std.mem.indexOf(u8, content, search)) |idx| {
        var result: std.ArrayList(u8) = .empty;
        try result.appendSlice(allocator, content[0..idx]);
        try result.appendSlice(allocator, replace);
        try result.appendSlice(allocator, content[idx + search.len ..]);
        return result.toOwnedSlice(allocator);
    }

    return try allocator.dupe(u8, content);
}

/// Insert a new `.field = "value"` line before the final closing `}` in a ZON file.
/// Used when adding assembler_version to a project.labelle that doesn't have one yet.
fn insertBeforeClosingBrace(allocator: std.mem.Allocator, old_content: []u8, field_name: []const u8, value: []const u8) ![]u8 {
    errdefer allocator.free(old_content);

    const line = try std.fmt.allocPrint(allocator, "    .{s} = \"{s}\",\n", .{ field_name, value });
    defer allocator.free(line);

    // Find the last `}` in the content.
    if (std.mem.lastIndexOfScalar(u8, old_content, '}')) |idx| {
        var result: std.ArrayList(u8) = .empty;
        try result.appendSlice(allocator, old_content[0..idx]);
        try result.appendSlice(allocator, line);
        try result.appendSlice(allocator, old_content[idx..]);
        const owned = try result.toOwnedSlice(allocator);
        allocator.free(old_content);
        return owned;
    }

    // No closing brace found — return content unchanged.
    return old_content;
}
