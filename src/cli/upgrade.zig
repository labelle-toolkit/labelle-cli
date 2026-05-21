const std = @import("std");
const project_config = @import("project_config.zig");
const assembler = @import("assembler.zig");
const config = @import("config.zig");
const assembler_proc = @import("assembler_proc.zig");
const util = @import("util.zig");

/// Bump version fields in project.labelle.
///
/// Issue #217 phase 1: framework/cli version bumps are delegated to the
/// standalone `labelle-assembler` binary (`labelle-assembler upgrade
/// ...`). Two cases stay CLI-owned because they touch `assembler_version`
/// — pinning the assembler *binary* version is a CLI-bootstrap concern,
/// and the assembler doesn't manage its own pin:
///   - `upgrade assembler [version]`
///   - `upgrade all` (which also bumps `assembler_version`)
/// Parsed `upgrade` command line: flags split out from positionals.
const UpgradeArgs = struct {
    /// Positional arguments with recognized flags removed.
    positionals: std.ArrayList([]const u8),
    /// `--force` / `-f` allows `upgrade all` to apply a version older
    /// than what the project currently pins (downgrades are skipped
    /// without it).
    force: bool,

    fn deinit(self: *UpgradeArgs, allocator: std.mem.Allocator) void {
        self.positionals.deinit(allocator);
    }
};

/// Split `cmd_args` into recognized flags and positional arguments.
///
/// `--force` / `-f` may appear anywhere (before or after the
/// subcommand); it is consumed here so it never leaks downstream as a
/// stray positional (where it could be mis-read as a package name or
/// an assembler version string).
fn parseUpgradeArgs(allocator: std.mem.Allocator, cmd_args: []const []const u8) !UpgradeArgs {
    var positionals: std.ArrayList([]const u8) = .empty;
    errdefer positionals.deinit(allocator);
    var force = false;
    for (cmd_args) |a| {
        if (std.mem.eql(u8, a, "--force") or std.mem.eql(u8, a, "-f")) {
            force = true;
        } else {
            try positionals.append(allocator, a);
        }
    }
    return .{ .positionals = positionals, .force = force };
}

pub fn cmdUpgrade(allocator: std.mem.Allocator, project_dir: []const u8, cfg: project_config.ProjectConfig, cmd_args: []const []const u8) !void {
    var parsed_args = try parseUpgradeArgs(allocator, cmd_args);
    defer parsed_args.deinit(allocator);
    const args = parsed_args.positionals.items;
    const force = parsed_args.force;

    // Subcommand is the first positional (flags already stripped), so
    // `--force` may appear before or after it.
    const is_assembler = args.len > 0 and std.mem.eql(u8, args[0], "assembler");
    const is_all = args.len > 0 and std.mem.eql(u8, args[0], "all");

    // Everything except `assembler` / `all` delegates to the binary.
    if (!is_assembler and !is_all) {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{ "--project-root", project_dir });
        try argv.appendSlice(allocator, args);
        return assembler_proc.runSubcommand(allocator, project_dir, "upgrade", argv.items);
    }

    // ── CLI-owned: cases that touch assembler_version ────────────────
    const labelle_path = try std.fs.path.join(allocator, &.{ project_dir, "project.labelle" });
    defer allocator.free(labelle_path);

    var content = try std.Io.Dir.cwd().readFileAlloc(config.globalIo(), labelle_path, allocator, .limited(1024 * 1024));

    if (is_all) {
        std.debug.print("labelle: attempting to upgrade to compatible set (core={s}, engine={s}, gfx={s}, cli={s}, assembler={s})...\n", .{ project_config.CORE_VERSION, project_config.ENGINE_VERSION, project_config.GFX_VERSION, project_config.CLI_VERSION, assembler.DEFAULT_ASSEMBLER_VERSION });

        // Never silently downgrade a project. If the compatible-set target is
        // older than the current pin, skip it (and warn) unless --force.
        const core_target = pickTarget("core_version", cfg.core_version, project_config.CORE_VERSION, force);
        const engine_target = pickTarget("engine_version", cfg.engine_version, project_config.ENGINE_VERSION, force);
        const gfx_target = pickTarget("gfx_version", cfg.gfx_version, project_config.GFX_VERSION, force);
        const cli_target = pickTarget("labelle_version", cfg.labelle_version, project_config.CLI_VERSION, force);

        content = try replaceAndFree(allocator, content, "core_version", cfg.core_version, core_target);
        content = try replaceAndFree(allocator, content, "engine_version", cfg.engine_version, engine_target);
        content = try replaceAndFree(allocator, content, "gfx_version", cfg.gfx_version, gfx_target);
        content = try replaceAndFree(allocator, content, "labelle_version", cfg.labelle_version, cli_target);
        // Also upgrade assembler if it exists (or add it). This goes
        // through the same downgrade guard as the other fields so a
        // project pinned to a newer assembler is never silently moved
        // backwards to DEFAULT_ASSEMBLER_VERSION.
        const asm_target = if (std.mem.indexOf(u8, content, ".assembler_version")) |_| blk: {
            const old_asm = cfg.assembler_version orelse "0.0.0";
            const target = pickTarget("assembler_version", old_asm, assembler.DEFAULT_ASSEMBLER_VERSION, force);
            content = try replaceAndFree(allocator, content, "assembler_version", old_asm, target);
            break :blk target;
        } else blk: {
            // No existing pin to downgrade — just add the default.
            content = try insertBeforeClosingBrace(allocator, content, "assembler_version", assembler.DEFAULT_ASSEMBLER_VERSION);
            break :blk assembler.DEFAULT_ASSEMBLER_VERSION;
        };

        // Report the versions actually applied — these may differ from
        // the compatible set above when the downgrade guard kept a
        // newer pin in place.
        std.debug.print("labelle: applied versions: core={s}, engine={s}, gfx={s}, cli={s}, assembler={s}\n", .{ core_target, engine_target, gfx_target, cli_target, asm_target });
    } else {
        // is_assembler — `args` has flags stripped, so a trailing
        // `--force` can't be mis-read as the version string.
        const version = if (args.len > 1) args[1] else assembler.DEFAULT_ASSEMBLER_VERSION;
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

/// Resolve the version to apply for one field of `upgrade all`.
///
/// `upgrade all` pulls its "compatible set" from the CLI's bundled
/// `versions.zon`. That file can lag behind the project's actual pins
/// (see issue #223), so applying it blindly can *downgrade* a working
/// project to versions that no longer build.
///
/// Guard: if `target` is older than `current`, do not move backwards —
/// keep `current` and print a loud warning. `--force` overrides this.
fn pickTarget(field_name: []const u8, current: []const u8, target: []const u8, force: bool) []const u8 {
    if (util.parseVersion(target) < util.parseVersion(current)) {
        if (force) {
            std.debug.print(
                "labelle: warning: forcing {s} downgrade {s} -> {s} (--force)\n",
                .{ field_name, current, target },
            );
            return target;
        }
        std.debug.print(
            "labelle: warning: skipping {s} downgrade {s} -> {s} " ++
                "(compatible set is older than your pin; keeping {s}). " ++
                "Pass --force to downgrade anyway.\n",
            .{ field_name, current, target, current },
        );
        return current;
    }
    return target;
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

// ── Tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "parseUpgradeArgs strips --force and keeps positionals" {
    var parsed = try parseUpgradeArgs(testing.allocator, &.{ "all", "--force" });
    defer parsed.deinit(testing.allocator);
    try testing.expect(parsed.force);
    try testing.expectEqual(@as(usize, 1), parsed.positionals.items.len);
    try testing.expectEqualStrings("all", parsed.positionals.items[0]);
}

test "parseUpgradeArgs strips -f short flag" {
    var parsed = try parseUpgradeArgs(testing.allocator, &.{ "-f", "all" });
    defer parsed.deinit(testing.allocator);
    try testing.expect(parsed.force);
    try testing.expectEqual(@as(usize, 1), parsed.positionals.items.len);
    try testing.expectEqualStrings("all", parsed.positionals.items[0]);
}

test "parseUpgradeArgs recognizes --force before subcommand" {
    // `--force` before `all`: subcommand detection must still see `all`
    // as the first positional, not be confused by flag placement.
    var parsed = try parseUpgradeArgs(testing.allocator, &.{ "--force", "all" });
    defer parsed.deinit(testing.allocator);
    try testing.expect(parsed.force);
    try testing.expectEqualStrings("all", parsed.positionals.items[0]);
}

test "parseUpgradeArgs keeps --force out of assembler version slot" {
    // `upgrade assembler --force` must not leave `--force` as args[1],
    // where it would be written as the assembler version string.
    var parsed = try parseUpgradeArgs(testing.allocator, &.{ "assembler", "--force" });
    defer parsed.deinit(testing.allocator);
    try testing.expect(parsed.force);
    try testing.expectEqual(@as(usize, 1), parsed.positionals.items.len);
    try testing.expectEqualStrings("assembler", parsed.positionals.items[0]);
}

test "parseUpgradeArgs leaves non-flag positionals intact" {
    var parsed = try parseUpgradeArgs(testing.allocator, &.{ "assembler", "1.2.3" });
    defer parsed.deinit(testing.allocator);
    try testing.expect(!parsed.force);
    try testing.expectEqual(@as(usize, 2), parsed.positionals.items.len);
    try testing.expectEqualStrings("1.2.3", parsed.positionals.items[1]);
}

test "pickTarget keeps newer pin and skips downgrade" {
    // Project pinned newer than the compatible set — guard keeps the pin.
    try testing.expectEqualStrings("2.0.0", pickTarget("core_version", "2.0.0", "1.0.0", false));
}

test "pickTarget applies upgrade when target is newer" {
    try testing.expectEqualStrings("2.0.0", pickTarget("core_version", "1.0.0", "2.0.0", false));
}

test "pickTarget --force overrides the downgrade guard" {
    try testing.expectEqualStrings("1.0.0", pickTarget("core_version", "2.0.0", "1.0.0", true));
}

test "pickTarget guards assembler_version downgrade" {
    // Regression: `upgrade all` must route assembler_version through the
    // same guard so a newer assembler pin is not silently downgraded.
    try testing.expectEqualStrings("0.40.0", pickTarget("assembler_version", "0.40.0", assembler.DEFAULT_ASSEMBLER_VERSION, false));
}
