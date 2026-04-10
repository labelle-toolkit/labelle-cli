/// GUI plugin resolver — reads gui.labelle manifest and populates resolved_gui on ProjectConfig.
///
/// Lives in the generator package because the fields it produces
/// (`resolved_gui`) are consumed by the generator's `generate()` function.
/// Both the in-process CLI import path and the standalone
/// `labelle-assembler` binary call this through `root.zig`'s re-export.
const std = @import("std");
const config = @import("config.zig");
const cache = @import("cache.zig");

/// Resolve the GUI plugin reference in the config.
/// Reads gui.labelle from the plugin directory, validates the bridge for
/// the selected backend, and populates cfg.resolved_gui.
pub fn resolveGuiPlugin(allocator: std.mem.Allocator, cfg: *config.ProjectConfig, project_dir: []const u8) !void {
    const gui_ref = cfg.gui orelse return; // null = no GUI

    // Resolve plugin directory
    const plugin_dir = try resolvePluginDir(allocator, gui_ref, cfg.*, project_dir);

    // Read and parse gui.labelle manifest
    const manifest_path = try std.fs.path.join(allocator, &.{ plugin_dir, "gui.labelle" });
    defer allocator.free(manifest_path);

    const manifest_raw = std.fs.cwd().readFileAlloc(allocator, manifest_path, 64 * 1024) catch |err| {
        std.debug.print("labelle: could not read GUI manifest '{s}': {any}\n", .{ manifest_path, err });
        std.debug.print("  hint: GUI plugins must contain a gui.labelle manifest file\n", .{});
        return error.GuiManifestNotFound;
    };
    defer allocator.free(manifest_raw);

    const manifest_z = try allocator.dupeZ(u8, manifest_raw);
    // Do NOT defer-free manifest_z — the ZON parser returns string slices
    // that reference this buffer. It must stay alive as long as resolved_gui.
    errdefer allocator.free(manifest_z);

    const manifest = std.zon.parse.fromSlice(GuiLabelle, allocator, manifest_z, null, .{}) catch |err| {
        std.debug.print("labelle: could not parse GUI manifest '{s}': {any}\n", .{ manifest_path, err });
        return error.GuiManifestParseError;
    };

    // Resolve bridge directory for raw_backend GUIs
    var bridge_dir: ?[]const u8 = null;
    if (manifest.rendering == .raw_backend) {
        const bridges = manifest.bridges orelse {
            std.debug.print("labelle: GUI plugin '{s}' declares raw_backend rendering but has no bridges\n", .{manifest.name});
            return error.GuiMissingBridges;
        };

        const bridge_def = getBridgeForBackend(bridges, cfg.backend) orelse {
            std.debug.print("labelle: GUI plugin '{s}' requires a bridge for backend '{s}', but none is declared in gui.labelle.\n", .{ manifest.name, @tagName(cfg.backend) });
            std.debug.print("  available bridges:", .{});
            printAvailableBridges(bridges);
            std.debug.print("\n", .{});
            return error.GuiMissingBridge;
        };

        if (bridge_def.path) |rel_path| {
            // Local bridge path (relative to plugin directory)
            bridge_dir = try std.fs.path.resolve(allocator, &.{ plugin_dir, rel_path });
        } else {
            std.debug.print("labelle: GUI plugin '{s}' bridge for '{s}' has no .path (remote bridge resolution not yet supported)\n", .{ manifest.name, @tagName(cfg.backend) });
            return error.GuiBridgeResolutionNotSupported;
        }

        if (bridge_def.adapter.len == 0) {
            std.debug.print("labelle: GUI plugin '{s}' bridge for '{s}' has empty .adapter name\n", .{ manifest.name, @tagName(cfg.backend) });
            return error.GuiBridgeMissingAdapter;
        }

        cfg.resolved_gui = .{
            .name = manifest.name,
            .rendering = manifest.rendering,
            .lifecycle = manifest.lifecycle,
            .plugin_dir = plugin_dir,
            .bridge_dir = bridge_dir,
            .bridge_artifact = bridge_def.adapter,
        };
    } else {
        cfg.resolved_gui = .{
            .name = manifest.name,
            .rendering = manifest.rendering,
            .lifecycle = manifest.lifecycle,
            .plugin_dir = plugin_dir,
        };
    }
}

/// Resolve the plugin directory from a GuiPlugin reference.
fn resolvePluginDir(allocator: std.mem.Allocator, ref: config.GuiPlugin, cfg: config.ProjectConfig, project_dir: []const u8) ![]const u8 {
    if (ref.path) |rel_path| {
        // Local path — resolve relative to project directory
        return std.fs.path.resolve(allocator, &.{ project_dir, rel_path });
    }
    if (ref.plugin) |name| {
        // Reference a declared plugin by name — resolve from the plugin cache
        for (cfg.plugins) |plugin| {
            if (std.mem.eql(u8, plugin.name, name)) {
                return cache.resolvePlugin(allocator, plugin, project_dir);
            }
        }
        std.debug.print("labelle: GUI references plugin '{s}', but no plugin with that name is declared in .plugins\n", .{name});
        return error.GuiPluginNotFound;
    }
    // TODO: support .package + .version (cache lookup) and .url + .hash (fetch)
    std.debug.print("labelle: GUI plugin reference must include .path or .plugin\n", .{});
    return error.GuiPluginResolutionNotSupported;
}

// ── gui.labelle manifest types (ZON-parseable) ──────────────────────

const BridgeDef = struct {
    adapter: []const u8 = "",
    path: ?[]const u8 = null,
};

const Bridges = struct {
    raylib: ?BridgeDef = null,
    sokol: ?BridgeDef = null,
    sdl: ?BridgeDef = null,
    bgfx: ?BridgeDef = null,
    wgpu: ?BridgeDef = null,
};

const LibraryDef = struct {
    package: []const u8 = "",
};

const GuiLabelle = struct {
    name: []const u8,
    library: LibraryDef = .{},
    rendering: config.RenderingMode,
    lifecycle: config.GuiLifecycle = .{},
    bridges: ?Bridges = null,
};

fn getBridgeForBackend(bridges: Bridges, backend: config.Backend) ?BridgeDef {
    return switch (backend) {
        .raylib => bridges.raylib,
        .sokol => bridges.sokol,
        .sdl => bridges.sdl,
        .bgfx => bridges.bgfx,
        .wgpu => bridges.wgpu,
    };
}

fn printAvailableBridges(bridges: Bridges) void {
    var first = true;
    inline for (.{ "raylib", "sokol", "sdl", "bgfx", "wgpu" }) |name| {
        if (@field(bridges, name) != null) {
            if (!first) std.debug.print(",", .{});
            std.debug.print(" {s}", .{name});
            first = false;
        }
    }
}
