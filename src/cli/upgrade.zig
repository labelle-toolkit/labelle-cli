const std = @import("std");
const gen = @import("generator");

/// Bump version fields in project.labelle.
pub fn cmdUpgrade(allocator: std.mem.Allocator, project_dir: []const u8, cfg: gen.ProjectConfig, cmd_args: []const []const u8) !void {
    const labelle_path = try std.fs.path.join(allocator, &.{ project_dir, "project.labelle" });
    defer allocator.free(labelle_path);

    var content = try std.fs.cwd().readFileAlloc(allocator, labelle_path, 1024 * 1024);
    errdefer allocator.free(content);

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
        } else if (std.mem.eql(u8, pkg, "all")) {
            content = try replaceAndFree(allocator, content, "core_version", cfg.core_version, gen.CORE_VERSION);
            content = try replaceAndFree(allocator, content, "engine_version", cfg.engine_version, gen.ENGINE_VERSION);
            content = try replaceAndFree(allocator, content, "gfx_version", cfg.gfx_version, gen.GFX_VERSION);
            content = try replaceAndFree(allocator, content, "labelle_version", cfg.labelle_version, gen.CLI_VERSION);
        } else {
            std.debug.print("labelle upgrade: unknown package '{s}'\n", .{pkg});
            std.debug.print("  packages: core, engine, gfx, cli, all\n", .{});
            allocator.free(content);
            return error.UnknownPackage;
        }

        std.debug.print("labelle: upgrading {s} to {s}...\n", .{ pkg, version });
    }

    const file = try std.fs.cwd().createFile(labelle_path, .{});
    defer file.close();
    try file.writeAll(content);
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
        var result = std.ArrayList(u8){};
        try result.appendSlice(allocator, content[0..idx]);
        try result.appendSlice(allocator, replace);
        try result.appendSlice(allocator, content[idx + search.len ..]);
        return result.toOwnedSlice(allocator);
    }

    return try allocator.dupe(u8, content);
}
