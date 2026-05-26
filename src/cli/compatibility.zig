const std = @import("std");
const project_config = @import("project_config.zig");

/// Validate that declared dependency versions are compatible with each other.
pub fn validateCompatibility(cfg: project_config.ProjectConfig) void {
    validateStates(cfg.states);

    // Validate backend+platform combination
    if (cfg.platform == .wasm and cfg.backend != .raylib and cfg.backend != .sokol) {
        std.debug.print("labelle: error: WASM builds are only supported with raylib or sokol backends (got {s})\n", .{@tagName(cfg.backend)});
        std.debug.print("  hint: set backend = \"raylib\" or backend = \"sokol\" in project.labelle\n\n", .{});
        std.process.exit(1);
    }

    const is_local = project_config.isLocalVersion;
    var warnings: u8 = 0;

    const core_mm = if (!is_local(cfg.core_version)) parseMajorMinor(cfg.core_version) else null;
    const engine_mm = if (!is_local(cfg.engine_version)) parseMajorMinor(cfg.engine_version) else null;
    const gfx_mm = if (!is_local(cfg.gfx_version)) parseMajorMinor(cfg.gfx_version) else null;
    const cli_mm = if (!is_local(cfg.labelle_version)) parseMajorMinor(cfg.labelle_version) else null;

    if (core_mm != null and engine_mm != null and core_mm.? != engine_mm.?) {
        std.debug.print("labelle: warning: engine {s} may be incompatible with core {s}\n", .{ cfg.engine_version, cfg.core_version });
        std.debug.print("  engine depends on core — their major.minor versions should match\n", .{});
        std.debug.print("  hint: run `labelle upgrade all`\n\n", .{});
        warnings += 1;
    }

    if (core_mm != null and gfx_mm != null and core_mm.? != gfx_mm.?) {
        std.debug.print("labelle: warning: gfx {s} may be incompatible with core {s}\n", .{ cfg.gfx_version, cfg.core_version });
        std.debug.print("  gfx depends on core — their major.minor versions should match\n", .{});
        std.debug.print("  hint: run `labelle upgrade gfx` or `labelle upgrade all`\n\n", .{});
        warnings += 1;
    }

    if (core_mm != null and cli_mm != null and core_mm.? != cli_mm.?) {
        std.debug.print("labelle: warning: cli {s} backends may be incompatible with core {s}\n", .{ cfg.labelle_version, cfg.core_version });
        std.debug.print("  backend adapters implement core interfaces — their major.minor versions should match\n", .{});
        std.debug.print("  hint: run `labelle upgrade cli` or `labelle upgrade all`\n\n", .{});
        warnings += 1;
    }

    for (cfg.plugins) |plugin| {
        if (plugin.isLocal()) continue;
        if (core_mm) |cmm| {
            if (pluginCompatWarn(plugin.version, cmm)) {
                std.debug.print("labelle: warning: plugin {s} {s} may be incompatible with core {s}\n", .{ plugin.name, plugin.version, cfg.core_version });
                std.debug.print("  plugins depend on core — their major.minor versions should match\n", .{});
                std.debug.print("  hint: update the plugin version in project.labelle\n\n", .{});
                warnings += 1;
            }
        }
    }

    if (warnings > 0) {
        std.debug.print("labelle: {d} compatibility warning(s) — proceeding anyway\n\n", .{warnings});
    }
}

/// Validate game state names declared in project.labelle.
fn validateStates(states: []const []const u8) void {
    if (states.len == 0) {
        std.debug.print("labelle: error: .states must contain at least one state\n", .{});
        std.debug.print("  hint: remove .states to use the default (\"running\"), or add at least one state name\n\n", .{});
        std.process.exit(1);
    }

    for (states) |name| {
        if (name.len == 0) {
            std.debug.print("labelle: error: state name cannot be empty\n", .{});
            std.process.exit(1);
        }
        // First character must be [a-z_] — digits would produce invalid Zig identifiers in codegen
        if (name[0] >= '0' and name[0] <= '9') {
            std.debug.print("labelle: error: state name \"{s}\" cannot start with a digit\n", .{name});
            std.debug.print("  hint: prefix with a letter (e.g., \"level_1\" not \"1_level\")\n\n", .{});
            std.process.exit(1);
        }
        for (name) |c| {
            if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_')) {
                std.debug.print("labelle: error: invalid state name \"{s}\" — must be lowercase alphanumeric with underscores [a-z0-9_]\n", .{name});
                std.debug.print("  hint: rename to a valid identifier (e.g., \"main_menu\" not \"Main Menu\")\n\n", .{});
                std.process.exit(1);
            }
        }
    }

    // Check for duplicate state names
    for (states, 0..) |name, i| {
        for (states[i + 1 ..]) |other| {
            if (std.mem.eql(u8, name, other)) {
                std.debug.print("labelle: error: duplicate state name \"{s}\" in .states\n", .{name});
                std.process.exit(1);
            }
        }
    }
}

/// Decide whether a plugin version should emit a compat warning against
/// the given core major.minor value.
///
/// 0.x plugins are "pre-stable" by toolkit convention and live on a
/// separate version train from a 1.x+ core, so the major.minor equality
/// check does not apply to them — they are always skipped here. See
/// https://github.com/labelle-toolkit/labelle-cli/issues/230. A declared
/// compat range from `plugin.labelle` would supersede this skip and is
/// tracked as the proper long-term fix.
fn pluginCompatWarn(plugin_version: []const u8, core_mm: u32) bool {
    const plugin = parseVersion(plugin_version);
    // Skip the check for 0.x plugins entirely (pre-stable train).
    // Test the major directly — the major*100+minor encoding collides
    // for e.g. 0.100 vs 1.0, so we can't recover major from the composite.
    if (plugin.major == 0) return false;
    return (plugin.major * 100 + plugin.minor) != core_mm;
}

/// Parse a semver string into its major/minor components.
fn parseVersion(version: []const u8) struct { major: u32, minor: u32 } {
    var parts: [3]u32 = .{ 0, 0, 0 };
    var part_idx: u8 = 0;

    for (version) |c| {
        if (c == '.') {
            part_idx += 1;
            if (part_idx >= 3) break;
        } else if (c >= '0' and c <= '9') {
            parts[part_idx] = parts[part_idx] * 10 + (c - '0');
        }
    }

    return .{ .major = parts[0], .minor = parts[1] };
}

/// Parse a semver string into a major.minor comparable value.
///
/// Note: the major*100+minor encoding is ambiguous (0.100 collides with 1.0).
/// Callers that need to distinguish 0.x from 1.x should use `parseVersion`.
fn parseMajorMinor(version: []const u8) u32 {
    const v = parseVersion(version);
    return v.major * 100 + v.minor;
}

// ── Tests ────────────────────────────────────────────────────────────

test "pluginCompatWarn: 0.x plugin vs 1.x core — no warning (issue #230)" {
    const core_mm = parseMajorMinor("1.14.1");
    try std.testing.expect(!pluginCompatWarn("0.5.0", core_mm));
    try std.testing.expect(!pluginCompatWarn("0.6.1", core_mm));
}

test "pluginCompatWarn: 0.x plugin vs 0.x core with matching minor — no warning" {
    const core_mm = parseMajorMinor("0.5.0");
    try std.testing.expect(!pluginCompatWarn("0.5.2", core_mm));
}

test "pluginCompatWarn: 0.x plugin vs 0.x core with mismatched minor — no warning (0.x always skipped)" {
    const core_mm = parseMajorMinor("0.5.0");
    try std.testing.expect(!pluginCompatWarn("0.6.0", core_mm));
    try std.testing.expect(!pluginCompatWarn("0.3.0", core_mm));
}

test "pluginCompatWarn: 1.x plugin matches 1.x core — no warning" {
    const core_mm = parseMajorMinor("1.14.1");
    try std.testing.expect(!pluginCompatWarn("1.14.0", core_mm));
    try std.testing.expect(!pluginCompatWarn("1.14.5", core_mm));
}

test "pluginCompatWarn: 1.x plugin mismatched with 1.x core — warns" {
    const core_mm = parseMajorMinor("1.14.1");
    try std.testing.expect(pluginCompatWarn("1.13.0", core_mm));
    try std.testing.expect(pluginCompatWarn("1.15.0", core_mm));
    try std.testing.expect(pluginCompatWarn("2.0.0", core_mm));
}

test "pluginCompatWarn: 0.100.x plugin is still treated as 0.x (no warn vs 1.x core)" {
    // Regression: parseMajorMinor("0.100.0") encodes as 100, which would
    // collide with 1.0 under a naive `< 100` check. Major must be tested
    // directly.
    const core_mm = parseMajorMinor("1.14.1");
    try std.testing.expect(!pluginCompatWarn("0.100.0", core_mm));
    // Also confirm against a 1.0 core where the encoded values would match.
    const core_10 = parseMajorMinor("1.0.0");
    try std.testing.expect(!pluginCompatWarn("0.100.0", core_10));
}
