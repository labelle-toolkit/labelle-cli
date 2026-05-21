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
        const plugin_mm = parseMajorMinor(plugin.version);
        if (core_mm != null and plugin_mm != core_mm.?) {
            std.debug.print("labelle: warning: plugin {s} {s} may be incompatible with core {s}\n", .{ plugin.name, plugin.version, cfg.core_version });
            std.debug.print("  plugins depend on core — their major.minor versions should match\n", .{});
            std.debug.print("  hint: update the plugin version in project.labelle\n\n", .{});
            warnings += 1;
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

/// Parse a semver string into a major.minor comparable value.
fn parseMajorMinor(version: []const u8) u32 {
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

    return parts[0] * 100 + parts[1];
}
