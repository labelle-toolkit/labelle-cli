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
///   - `upgrade all` (which also bumps `assembler_version`, then delegates
///     the backend pin to `labelle-assembler upgrade backend`, cli#471 D4)
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
    // `upgrade backend [ver]` needs an assembler that has it (protocol 7);
    // the gate says so in one line rather than the binary's "unknown
    // package".
    if (!is_assembler and !is_all) {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{ "--project-root", project_dir });
        try argv.appendSlice(allocator, args);
        const is_backend = args.len > 0 and std.mem.eql(u8, args[0], "backend");
        const bin = try assembler_proc.resolve(allocator, project_dir, if (is_backend) backend_gate else "upgrade");
        defer bin.deinit(allocator);
        return bin.run(allocator, "upgrade", argv.items);
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
        // gfx and the backend package share a backend contract and must move
        // TOGETHER (cli#339). The CLI no longer knows any backend (cli#471
        // D4): the backend pin is bumped by `labelle-assembler upgrade
        // backend`, which judges the pairing against its version floors,
        // AFTER the pins below are written (see `upgradeBackend`).
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
            // The backend step below runs under the assembler this pin names:
            // a pin left on an assembler without `upgrade backend` would make
            // it fail and roll everything back, so a pin that cannot be
            // located is an error here, before anything is written.
            if (!std.mem.eql(u8, old_asm, target) and findVersionValue(content, "assembler_version", old_asm) == null) {
                std.debug.print("labelle: could not locate the .assembler_version pin in project.labelle — nothing written (set it to {s} and re-run)\n", .{target});
                allocator.free(content);
                return error.AssemblerPinNotFound;
            }
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

        const original = try std.Io.Dir.cwd().readFileAlloc(config.globalIo(), labelle_path, allocator, .limited(1024 * 1024));
        defer allocator.free(original);
        try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = labelle_path, .data = content });
        allocator.free(content);
        try upgradeBackend(allocator, project_dir, labelle_path, original, force);
        std.debug.print("labelle: project.labelle updated\n", .{});
        std.debug.print("  run 'labelle generate' to regenerate build files\n", .{});
        return;
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

/// The `minProtocolFor` key of `upgrade backend` (protocol 7, cli#471 D2).
const backend_gate = "upgrade backend";

/// `upgrade all`'s backend half (cli#471 D4): `labelle-assembler upgrade
/// backend`, run by the assembler the just-written pins name, so the
/// backend is judged against the NEW core/gfx by that assembler's version
/// floors. It writes nothing for the `.backend` shorthand at its default,
/// a local checkout or a third-party package, and bumps an explicit
/// first-party pin to the assembler's default.
///
/// When it refuses (or cannot run), gfx must not stay advanced past a
/// backend that did not move (cli#339): `original` is written back and the
/// upgrade fails, unless `--force`, which keeps the other pins and warns.
fn upgradeBackend(allocator: std.mem.Allocator, project_dir: []const u8, labelle_path: []const u8, original: []const u8, force: bool) !void {
    const failed: ?anyerror = blk: {
        var bin = assembler_proc.resolve(allocator, project_dir, backend_gate) catch |err| break :blk err;
        defer bin.deinit(allocator);
        // A refusal is handled here (rollback), never a CLI exit mid-upgrade.
        bin.fatal_on_failure = false;
        bin.run(allocator, "upgrade", &.{ "--project-root", project_dir, "backend" }) catch |err| break :blk err;
        break :blk null;
    };
    const err = failed orelse return;
    if (force) {
        std.debug.print("labelle: warning: the backend pin was not upgraded ({s}); keeping the other pins (--force) — the backend and gfx may no longer build together\n", .{@errorName(err)});
        return;
    }
    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = labelle_path, .data = original });
    std.debug.print("labelle: the backend pin could not be upgraded with gfx ({s}) — project.labelle left unchanged (see above; pass --force to apply the other pins anyway)\n", .{@errorName(err)});
    return error.BackendUpgradeFailed;
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
///   - backend_package → unknown (the assembler owns backend versions,
///                       cli#471 D4: `labelle upgrade backend`); the pin is
///                       still reported — omitting it hid required
///                       coordinated gfx + backend bumps (cli#336).
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
    // The backend package has no entry in the bundled compatible set (the
    // assembler owns backend versions, cli#471 D4), but its pin MUST still
    // appear in the report — silently omitting it hid a required
    // coordinated bump when gfx crossed a backend-contract boundary
    // (cli#336).
    if (cfg.backend_package) |bp| {
        const pinned: ?[]const u8 = if (bp.version.len > 0) bp.version else null;
        // A repo-local override is flagged as such (codex P2 round 2 on
        // cli#339). `packageStatus`'s own isLocal() only inspects the
        // VERSION string; the backend's override lives in `repo`.
        if (bp.isLocal()) {
            var status = update_check.packageStatus(bp.name, pinned, null);
            status.@"error" = update_check.err_local_override;
            try packages.append(allocator, status);
        } else {
            var status = update_check.packageStatus(bp.name, pinned, null);
            status.@"error" = update_check.err_backend_untracked;
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

fn replaceAndFree(allocator: std.mem.Allocator, old_content: []u8, field_name: []const u8, old_value: []const u8, new_value: []const u8) ![]u8 {
    errdefer allocator.free(old_content);
    const result = try replaceVersionField(allocator, old_content, field_name, old_value, new_value);
    allocator.free(old_content);
    return result;
}

fn replaceVersionField(allocator: std.mem.Allocator, content: []const u8, field_name: []const u8, old_value: []const u8, new_value: []const u8) ![]u8 {
    const span = findVersionValue(content, field_name, old_value) orelse return allocator.dupe(u8, content);
    var result: std.ArrayList(u8) = .empty;
    try result.appendSlice(allocator, content[0..span.start]);
    try result.print(allocator, "\"{s}\"", .{new_value});
    try result.appendSlice(allocator, content[span.end..]);
    return result.toOwnedSlice(allocator);
}

/// Where `.<field> = "<value>"` puts its quoted value (quotes included),
/// whitespace-tolerant around `=` (`.assembler_version="0.117.0"` is valid
/// ZON too, Codex P2 on #517), or null when no such pin is spelled.
fn findVersionValue(content: []const u8, field_name: []const u8, value: []const u8) ?struct { start: usize, end: usize } {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, content, from, ".")) |dot| {
        from = dot + 1;
        const rest = content[dot + 1 ..];
        if (!std.mem.startsWith(u8, rest, field_name)) continue;
        var i = dot + 1 + field_name.len;
        // `.core_version` must not match `.core_version_extra`.
        if (i < content.len and (std.ascii.isAlphanumeric(content[i]) or content[i] == '_')) continue;
        while (i < content.len and std.ascii.isWhitespace(content[i])) i += 1;
        if (i >= content.len or content[i] != '=') continue;
        i += 1;
        while (i < content.len and std.ascii.isWhitespace(content[i])) i += 1;
        if (i >= content.len or content[i] != '"') continue;
        const body = content[i + 1 ..];
        if (!std.mem.startsWith(u8, body, value) or body.len <= value.len or body[value.len] != '"') continue;
        return .{ .start = i, .end = i + value.len + 2 };
    }
    return null;
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

test "replaceVersionField: a non-canonical spelling is rewritten (Codex P2 on #517)" {
    const a = testing.allocator;
    for ([_][]const u8{
        ".{ .assembler_version=\"0.117.0\" }",
        ".{ .assembler_version =\t\"0.117.0\" }",
        ".{\n    .assembler_version\n        = \"0.117.0\",\n}",
    }) |src| {
        const out = try replaceVersionField(a, src, "assembler_version", "0.117.0", "0.120.0");
        defer a.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "\"0.120.0\"") != null);
        try testing.expect(std.mem.indexOf(u8, out, "0.117.0") == null);
    }
    // A longer field name sharing the prefix, or another value, is left alone.
    const other = try replaceVersionField(a, ".{ .assembler_version_x = \"0.117.0\", .assembler_version = \"0.118.0\" }", "assembler_version", "0.117.0", "0.120.0");
    defer a.free(other);
    try testing.expect(std.mem.indexOf(u8, other, "0.120.0") == null);
    try testing.expect(findVersionValue(".{ .assembler_version = \"0.117.00\" }", "assembler_version", "0.117.0") == null);
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
