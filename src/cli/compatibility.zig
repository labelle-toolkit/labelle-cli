const std = @import("std");
const gen = @import("generator");

/// Validate that declared dependency versions are compatible with each other.
pub fn validateCompatibility(cfg: gen.ProjectConfig) void {
    const is_local = gen.isLocalVersion;
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
