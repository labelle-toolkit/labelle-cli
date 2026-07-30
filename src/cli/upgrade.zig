const std = @import("std");
const project_config = @import("project_config.zig");
const assembler = @import("assembler.zig");
const config = @import("config.zig");
const assembler_proc = @import("assembler_proc.zig");
const util = @import("util.zig");
const update_check = @import("update_check.zig");

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
    /// `--check` — report current pins vs latest WITHOUT touching
    /// project.labelle (labelle-cli#276).
    check: bool,
    /// `--json` — machine-readable output; implies `--check` (a tool asking
    /// for JSON must never trigger a mutating upgrade).
    json: bool,

    /// True when the invocation is a read-only pin check rather than a
    /// version bump.
    fn reportOnly(self: UpgradeArgs) bool {
        return self.check or self.json;
    }

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
    var check = false;
    var json = false;
    for (cmd_args) |a| {
        if (std.mem.eql(u8, a, "--force") or std.mem.eql(u8, a, "-f")) {
            force = true;
        } else if (std.mem.eql(u8, a, "--check")) {
            check = true;
        } else if (std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            // Reject unknown flags rather than treating them as a package /
            // version positional — a typo like `--chek` must not slip past
            // the read-only `--check` guard into the mutating upgrade path
            // (CodeRabbit, PR #299). Symmetric with parseUpdateArgs; the
            // errdefer above frees `positionals` on this early return.
            std.debug.print("labelle upgrade: unknown flag '{s}'\n", .{a});
            std.debug.print("  usage: labelle upgrade [dir] [pkg] [ver] [--check] [--json] [--force]\n", .{});
            return error.InvalidArguments;
        } else {
            try positionals.append(allocator, a);
        }
    }
    return .{ .positionals = positionals, .force = force, .check = check, .json = json };
}

pub fn cmdUpgrade(allocator: std.mem.Allocator, project_dir: []const u8, cfg: project_config.ProjectConfig, cmd_args: []const []const u8) !void {
    var parsed_args = try parseUpgradeArgs(allocator, cmd_args);
    defer parsed_args.deinit(allocator);
    const args = parsed_args.positionals.items;
    const force = parsed_args.force;

    // Read-only pin check (labelle-cli#276): report current pins vs the
    // versions this CLI targets WITHOUT rewriting project.labelle. `--json`
    // implies `--check`, so a machine consumer never triggers a mutation.
    if (parsed_args.reportOnly()) {
        return cmdUpgradeCheck(allocator, project_dir, cfg, parsed_args.json);
    }

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

        // gfx and the bgfx backend share a backend contract (PostPass,
        // gfx 1.27+): advancing one without the other produces a project
        // that no longer builds. Bump the backend pin together with gfx
        // (codex P1 on cli#339). Non-bgfx or local-override backends are
        // skipped with a note — the set only tracks bgfx.
        if (cfg.backend_package) |bp| {
            if (std.mem.eql(u8, bp.name, "bgfx") and bp.version.len > 0 and !bp.isLocal()) {
                const bgfx_target = pickTarget("backend_package.version", bp.version, project_config.BGFX_VERSION, force);
                content = try replaceBackendVersion(allocator, content, bp.version, bgfx_target);
                std.debug.print("labelle: backend package bgfx -> {s} (paired with gfx {s})\n", .{ bgfx_target, gfx_target });
            } else if (bp.version.len > 0) {
                std.debug.print("labelle: note: backend package '{s}' is not in the compatible set — pin left at {s}\n", .{ bp.name, bp.version });
            }
        }

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

/// `labelle upgrade [dir] --check [--json]` (labelle-cli#276): report the
/// project's current pins vs the versions this CLI targets (its bundled
/// compatible set — the same set `upgrade all` would apply) WITHOUT touching
/// project.labelle. This is a read-only mode over what `upgrade` already
/// knows; no network is required.
///
/// `latest` sources (all baked into this CLI at build time):
///   - core/engine/gfx → versions.zon (`project_config.*_VERSION`)
///   - labelle         → this CLI's own version (`CLI_VERSION`)
///   - assembler       → `DEFAULT_ASSEMBLER_VERSION`
///   - backend_package → unknown (not in the bundled set); the pin is still
///                       reported — omitting it hid required coordinated
///                       gfx+bgfx bumps (cli#336).
///   - plugins         → unknown (the CLI has no plugin-latest registry); the
///                       pin is still reported so studio can display it.
///
/// Emits `{ "cli": null, "packages": [...] }` under `--json` (studio#7).
/// Exits 2 when any pin is behind its target, else 0.
fn cmdUpgradeCheck(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    cfg: project_config.ProjectConfig,
    json: bool,
) !void {
    var packages: std.ArrayList(update_check.PackageStatus) = .empty;
    errdefer packages.deinit(allocator);

    // Order mirrors the issue: core/engine/gfx/assembler/labelle + plugins.
    try packages.append(allocator, update_check.packageStatus("core", cfg.core_version, project_config.CORE_VERSION));
    try packages.append(allocator, update_check.packageStatus("engine", cfg.engine_version, project_config.ENGINE_VERSION));
    try packages.append(allocator, update_check.packageStatus("gfx", cfg.gfx_version, project_config.GFX_VERSION));
    // The backend package (bgfx et al.) has no entry in the bundled
    // compatible set, but its pin MUST still appear in the report —
    // silently omitting it hid a required coordinated bump when gfx
    // crossed a backend-contract boundary (cli#336).
    if (cfg.backend_package) |bp| {
        const pinned: ?[]const u8 = if (bp.version.len > 0) bp.version else null;
        // bgfx is part of the compatible set (paired with gfx across the
        // shared backend contract); other backends have no tracked latest.
        if (std.mem.eql(u8, bp.name, "bgfx")) {
            try packages.append(allocator, update_check.packageStatus(bp.name, pinned, project_config.BGFX_VERSION));
        } else {
            var status = update_check.packageStatus(bp.name, pinned, null);
            status.@"error" = if (bp.isLocal())
                update_check.err_local_override
            else
                update_check.err_backend_untracked;
            try packages.append(allocator, status);
        }
    }
    try packages.append(allocator, update_check.packageStatus("labelle", cfg.labelle_version, project_config.CLI_VERSION));
    try packages.append(allocator, update_check.packageStatus("assembler", cfg.assembler_version, assembler.DEFAULT_ASSEMBLER_VERSION));
    for (cfg.plugins) |p| {
        // Empty version string → not pinned to a specific version.
        const pinned: ?[]const u8 = if (p.version.len > 0) p.version else null;
        // The CLI can't resolve a plugin's latest offline, so `latest` is
        // null (checked=false); the pin is still surfaced for studio.
        var status = update_check.packageStatus(p.name, pinned, null);
        // A `local:`/`@` plugin repo is a dev override — flag it distinctly
        // so studio can tell "local checkout" from "remote, latest unknown".
        if (p.isLocal()) status.@"error" = update_check.err_local_override;
        try packages.append(allocator, status);
    }

    const report = update_check.Report{ .cli = null, .packages = packages.items };

    var out_buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(config.globalIo(), &out_buf);
    if (json) {
        update_check.writeJson(&w.interface, report) catch {};
    } else {
        update_check.writeHumanPackages(&w.interface, project_dir, packages.items) catch {};
    }
    w.interface.flush() catch {};

    const code = update_check.exitCode(report);
    packages.deinit(allocator); // free before a possible std.process.exit
    if (code != 0) std.process.exit(code);
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

/// Replace `.version = "<old>"` INSIDE the `.backend_package = .{...}`
/// struct only. A whole-file `replaceVersionField(".version", ...)` would
/// also hit plugin pins that share the same field name; anchoring the
/// search at the `.backend_package` key keeps the edit scoped.
fn replaceBackendVersion(allocator: std.mem.Allocator, old_content: []u8, old_value: []const u8, new_value: []const u8) ![]u8 {
    errdefer allocator.free(old_content);
    const anchor = std.mem.indexOf(u8, old_content, ".backend_package") orelse return old_content;
    const search = try std.fmt.allocPrint(allocator, ".version = \"{s}\"", .{old_value});
    defer allocator.free(search);
    const rel = std.mem.indexOf(u8, old_content[anchor..], search) orelse return old_content;
    const idx = anchor + rel;
    const replace = try std.fmt.allocPrint(allocator, ".version = \"{s}\"", .{new_value});
    defer allocator.free(replace);
    var result: std.ArrayList(u8) = .empty;
    try result.appendSlice(allocator, old_content[0..idx]);
    try result.appendSlice(allocator, replace);
    try result.appendSlice(allocator, old_content[idx + search.len ..]);
    const owned = try result.toOwnedSlice(allocator);
    allocator.free(old_content);
    return owned;
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

test "replaceBackendVersion edits only the backend_package pin, not plugin pins" {
    // A bare `.version = "x"` search would also hit plugin pins that
    // share the field name; the anchor keeps the edit scoped (codex P1
    // on cli#339: `upgrade all` must move bgfx together with gfx).
    const src = try testing.allocator.dupe(u8,
        \\.{
        \\    .backend_package = .{ .name = "bgfx", .repo = "r", .version = "0.13.3" },
        \\    .plugins = .{
        \\        .{ .name = "fsm", .repo = "r2", .version = "0.13.3" },
        \\    },
        \\}
    );
    const out = try replaceBackendVersion(testing.allocator, src, "0.13.3", "0.13.5");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, ".name = \"bgfx\", .repo = \"r\", .version = \"0.13.5\"") != null);
    // The plugin pin with the same version string is untouched.
    try testing.expect(std.mem.indexOf(u8, out, ".name = \"fsm\", .repo = \"r2\", .version = \"0.13.3\"") != null);
}

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
    // same guard so a newer assembler pin is not silently downgraded to
    // DEFAULT_ASSEMBLER_VERSION. (Version-independent: the old form pinned
    // "0.40.0" == the then-default, which only passed by coincidence and
    // broke the moment the stale constant was bumped — labelle-cli#322.)
    try testing.expectEqualStrings("99.0.0", pickTarget("assembler_version", "99.0.0", assembler.DEFAULT_ASSEMBLER_VERSION, false));
    // An OLDER pin is moved forward to the paired default. ("0.0.0" — a
    // clearly-minimal sentinel, not a real historical version that could
    // read as meaningful.)
    try testing.expectEqualStrings(assembler.DEFAULT_ASSEMBLER_VERSION, pickTarget("assembler_version", "0.0.0", assembler.DEFAULT_ASSEMBLER_VERSION, false));
}

test "parseUpgradeArgs strips --check and reports report-only mode" {
    var parsed = try parseUpgradeArgs(testing.allocator, &.{"--check"});
    defer parsed.deinit(testing.allocator);
    try testing.expect(parsed.check);
    try testing.expect(!parsed.json);
    try testing.expect(parsed.reportOnly());
    try testing.expectEqual(@as(usize, 0), parsed.positionals.items.len);
}

test "parseUpgradeArgs: --json implies report-only" {
    var parsed = try parseUpgradeArgs(testing.allocator, &.{"--json"});
    defer parsed.deinit(testing.allocator);
    try testing.expect(parsed.json);
    try testing.expect(parsed.reportOnly());
}

test "parseUpgradeArgs strips --check/--json but keeps subcommand positional" {
    // `upgrade all --check --json` must leave `all` as the sole positional
    // so the (short-circuited) subcommand path never sees the flags.
    var parsed = try parseUpgradeArgs(testing.allocator, &.{ "all", "--check", "--json" });
    defer parsed.deinit(testing.allocator);
    try testing.expect(parsed.check and parsed.json);
    try testing.expectEqual(@as(usize, 1), parsed.positionals.items.len);
    try testing.expectEqualStrings("all", parsed.positionals.items[0]);
}

test "parseUpgradeArgs: --force is independent of report-only" {
    var parsed = try parseUpgradeArgs(testing.allocator, &.{"--force"});
    defer parsed.deinit(testing.allocator);
    try testing.expect(parsed.force);
    try testing.expect(!parsed.reportOnly());
}

test "parseUpgradeArgs rejects an unknown flag instead of taking it as a positional" {
    // Without the reject branch `--jso` becomes a positional and the
    // command proceeds to the mutating path — CodeRabbit PR #299.
    try testing.expectError(error.InvalidArguments, parseUpgradeArgs(testing.allocator, &.{"--jso"}));
}

test "parseUpgradeArgs rejects an unknown flag even before a valid subcommand" {
    // `--chek all` must not run the mutating `upgrade all`; the typo is
    // rejected before the subcommand is ever reached.
    try testing.expectError(error.InvalidArguments, parseUpgradeArgs(testing.allocator, &.{ "--chek", "all" }));
}
