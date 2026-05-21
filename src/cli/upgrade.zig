const std = @import("std");
const project_config = @import("project_config.zig");
const assembler = @import("assembler.zig");
const config = @import("config.zig");
const assembler_proc = @import("assembler_proc.zig");

/// Bump version fields in project.labelle.
///
/// Issue #217 phase 1: framework/cli version bumps are delegated to the
/// standalone `labelle-assembler` binary (`labelle-assembler upgrade
/// ...`). Two cases stay CLI-owned because they touch `assembler_version`
/// — pinning the assembler *binary* version is a CLI-bootstrap concern,
/// and the assembler doesn't manage its own pin:
///   - `upgrade assembler [version]`
///   - `upgrade all` (which also bumps `assembler_version`)
pub fn cmdUpgrade(allocator: std.mem.Allocator, project_dir: []const u8, cfg: project_config.ProjectConfig, cmd_args: []const []const u8) !void {
    const is_assembler = cmd_args.len > 0 and std.mem.eql(u8, cmd_args[0], "assembler");
    const is_all = cmd_args.len > 0 and std.mem.eql(u8, cmd_args[0], "all");

    // Everything except `assembler` / `all` delegates to the binary.
    if (!is_assembler and !is_all) {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{ "--project-root", project_dir });
        try argv.appendSlice(allocator, cmd_args);
        return assembler_proc.runSubcommand(allocator, project_dir, "upgrade", argv.items);
    }

    // ── CLI-owned: cases that touch assembler_version ────────────────
    const labelle_path = try std.fs.path.join(allocator, &.{ project_dir, "project.labelle" });
    defer allocator.free(labelle_path);

    var content = try std.Io.Dir.cwd().readFileAlloc(config.globalIo(), labelle_path, allocator, .limited(1024 * 1024));

    if (is_all) {
        std.debug.print("labelle: upgrading to compatible set (core={s}, engine={s}, gfx={s}, cli={s})...\n", .{ project_config.CORE_VERSION, project_config.ENGINE_VERSION, project_config.GFX_VERSION, project_config.CLI_VERSION });
        content = try replaceAndFree(allocator, content, "core_version", cfg.core_version, project_config.CORE_VERSION);
        content = try replaceAndFree(allocator, content, "engine_version", cfg.engine_version, project_config.ENGINE_VERSION);
        content = try replaceAndFree(allocator, content, "gfx_version", cfg.gfx_version, project_config.GFX_VERSION);
        content = try replaceAndFree(allocator, content, "labelle_version", cfg.labelle_version, project_config.CLI_VERSION);
        // Also upgrade assembler if it exists (or add it).
        if (std.mem.indexOf(u8, content, ".assembler_version")) |_| {
            const old_asm = cfg.assembler_version orelse "0.0.0";
            content = try replaceAndFree(allocator, content, "assembler_version", old_asm, assembler.DEFAULT_ASSEMBLER_VERSION);
        } else {
            content = try insertBeforeClosingBrace(allocator, content, "assembler_version", assembler.DEFAULT_ASSEMBLER_VERSION);
        }
        std.debug.print("labelle: upgrading all to compatible set...\n", .{});
    } else {
        // is_assembler
        const version = if (cmd_args.len > 1) cmd_args[1] else assembler.DEFAULT_ASSEMBLER_VERSION;
        if (std.mem.indexOf(u8, content, ".assembler_version")) |_| {
            const old_asm = cfg.assembler_version orelse "0.0.0";
            content = try replaceAndFree(allocator, content, "assembler_version", old_asm, version);
        } else {
            content = try insertBeforeClosingBrace(allocator, content, "assembler_version", version);
        }
        std.debug.print("labelle: upgrading assembler to {s}...\n", .{version});
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
