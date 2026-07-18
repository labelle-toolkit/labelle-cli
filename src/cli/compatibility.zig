const std = @import("std");
const project_config = @import("project_config.zig");
const progress = @import("progress.zig");

/// Validate that declared dependency versions are compatible with each other.
pub fn validateCompatibility(cfg: project_config.ProjectConfig) void {
    validateStates(cfg.states);

    // Validate backend+platform combination
    if (cfg.platform == .wasm and cfg.backend != .raylib and cfg.backend != .sokol and cfg.backend != .bgfx) {
        std.debug.print("labelle: error: WASM builds are only supported with raylib, sokol, or bgfx backends (got {s})\n", .{@tagName(cfg.backend)});
        std.debug.print("  hint: set backend = \"raylib\", \"sokol\", or \"bgfx\" in project.labelle\n\n", .{});
        progress.fatalExit(1, "compatibility check failed: wasm requires a raylib, sokol, or bgfx backend");
    }

    const is_local = project_config.isLocalVersion;
    var warnings: u8 = 0;

    // core / engine / gfx / cli version on INDEPENDENT minor trains (e.g. core
    // 1.21, engine 1.65, gfx 1.19 are all current + mutually compatible). The
    // assembler unifies every package onto the project's core at build time (the
    // "core diamond"), so source-compatibility — not matching minors — is what
    // matters. Only a MAJOR-version divergence is a real break (a 2.x package
    // against a 1.x core), so that's all we warn on. The curated tested set lives
    // in `versions.zon` (what `labelle upgrade all` targets); a per-package
    // declared-core check (read each package's own core pin) is the planned
    // stronger follow-up.
    const core_major = if (!is_local(cfg.core_version)) parseVersion(cfg.core_version).major else null;

    const Dep = struct { name: []const u8, version: []const u8 };
    const deps = [_]Dep{
        .{ .name = "engine", .version = cfg.engine_version },
        .{ .name = "gfx", .version = cfg.gfx_version },
        .{ .name = "cli", .version = cfg.labelle_version },
    };
    if (core_major) |cmaj| {
        for (deps) |d| {
            if (is_local(d.version)) continue;
            if (parseVersion(d.version).major != cmaj) {
                std.debug.print("labelle: warning: {s} {s} may be incompatible with core {s}\n", .{ d.name, d.version, cfg.core_version });
                std.debug.print("  major versions should match (minor versions are independent across packages)\n", .{});
                std.debug.print("  hint: run `labelle upgrade all`\n\n", .{});
                warnings += 1;
            }
        }
        for (cfg.plugins) |plugin| {
            if (plugin.isLocal()) continue;
            if (pluginCompatWarn(plugin.version, cmaj)) {
                std.debug.print("labelle: warning: plugin {s} {s} may be incompatible with core {s}\n", .{ plugin.name, plugin.version, cfg.core_version });
                std.debug.print("  major versions should match (minor versions are independent across packages)\n", .{});
                std.debug.print("  hint: update the plugin version in project.labelle\n\n", .{});
                warnings += 1;
            }
        }
    }

    if (warnings > 0) {
        std.debug.print("labelle: {d} compatibility warning(s) — proceeding anyway\n\n", .{warnings});
    }
}

/// Validate game state names declared in project.labelle. Each fatalExit
/// detail carries the specific rule that failed (cli#318) so the progress
/// feed's terminal record is renderable on its own.
fn validateStates(states: []const []const u8) void {
    if (states.len == 0) {
        std.debug.print("labelle: error: .states must contain at least one state\n", .{});
        std.debug.print("  hint: remove .states to use the default (\"running\"), or add at least one state name\n\n", .{});
        progress.fatalExit(1, "compatibility check failed: .states must contain at least one state");
    }

    for (states) |name| {
        if (name.len == 0) {
            std.debug.print("labelle: error: state name cannot be empty\n", .{});
            progress.fatalExit(1, "compatibility check failed: state name cannot be empty");
        }
        // First character must be [a-z_] — digits would produce invalid Zig identifiers in codegen
        if (name[0] >= '0' and name[0] <= '9') {
            std.debug.print("labelle: error: state name \"{s}\" cannot start with a digit\n", .{name});
            std.debug.print("  hint: prefix with a letter (e.g., \"level_1\" not \"1_level\")\n\n", .{});
            progress.fatalExit(1, "compatibility check failed: state name cannot start with a digit");
        }
        for (name) |c| {
            if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_')) {
                std.debug.print("labelle: error: invalid state name \"{s}\" — must be lowercase alphanumeric with underscores [a-z0-9_]\n", .{name});
                std.debug.print("  hint: rename to a valid identifier (e.g., \"main_menu\" not \"Main Menu\")\n\n", .{});
                progress.fatalExit(1, "compatibility check failed: invalid state name (want [a-z0-9_])");
            }
        }
    }

    // Check for duplicate state names
    for (states, 0..) |name, i| {
        for (states[i + 1 ..]) |other| {
            if (std.mem.eql(u8, name, other)) {
                std.debug.print("labelle: error: duplicate state name \"{s}\" in .states\n", .{name});
                progress.fatalExit(1, "compatibility check failed: duplicate state name");
            }
        }
    }
}

/// Decide whether a plugin version should emit a compat warning against the
/// given core MAJOR version.
///
/// Independent-versioning model (the toolkit packages each version on their own
/// minor train): only a MAJOR divergence is a real break. 0.x plugins are
/// "pre-stable" by convention and live on a separate train from a 1.x+ core, so
/// they're always skipped (see labelle-cli#230). A declared compat range from
/// `plugin.labelle` would supersede this and is the planned stronger follow-up.
fn pluginCompatWarn(plugin_version: []const u8, core_major: u32) bool {
    const plugin = parseVersion(plugin_version);
    if (plugin.major == 0) return false; // pre-stable train, skip
    return plugin.major != core_major;
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

// ── Tests ────────────────────────────────────────────────────────────

test "pluginCompatWarn: 0.x plugin vs 1.x core — no warning (issue #230)" {
    try std.testing.expect(!pluginCompatWarn("0.5.0", 1));
    try std.testing.expect(!pluginCompatWarn("0.6.1", 1));
}

test "pluginCompatWarn: 1.x plugin vs 1.x core — no warning regardless of minor (independent minors)" {
    // The key change: a minor mismatch is NOT a warning anymore. core 1.21 +
    // plugin 1.13 are both major 1 → compatible under independent versioning.
    try std.testing.expect(!pluginCompatWarn("1.14.0", 1));
    try std.testing.expect(!pluginCompatWarn("1.13.0", 1));
    try std.testing.expect(!pluginCompatWarn("1.65.0", 1));
}

test "pluginCompatWarn: major mismatch still warns" {
    try std.testing.expect(pluginCompatWarn("2.0.0", 1));
    try std.testing.expect(pluginCompatWarn("1.0.0", 2));
}

test "pluginCompatWarn: 0.100.x plugin is still treated as 0.x (no warn)" {
    try std.testing.expect(!pluginCompatWarn("0.100.0", 1));
}
