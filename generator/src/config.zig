/// Type definitions for the labelle-cli generator.
/// Pure types — no template or I/O dependencies.
const std = @import("std");

pub const Backend = enum { raylib, sokol, sdl, bgfx, wgpu };
pub const Platform = enum { desktop, ios, android, wasm };
pub const EcsChoice = enum { mock, zig_ecs, zflecs, mr_ecs };

/// CLI version — injected from root build.zig via build options.
pub const CLI_VERSION = @import("build_options").cli_version;

/// Library versions — from versions.zon, injected via build options.
/// These are the tested compatible versions for this CLI release.
pub const CORE_VERSION = @import("build_options").core_version;
pub const ENGINE_VERSION = @import("build_options").engine_version;
pub const GFX_VERSION = @import("build_options").gfx_version;

/// A plugin dependency declared in project.labelle.
/// Plugins are external packages with a repo URL and version tag.
/// Use `repo = "local:../../path"` for local development overrides.
pub const PluginDep = struct {
    name: []const u8,
    repo: []const u8 = "",
    version: []const u8 = "",
    /// Game states this plugin runs in. Empty = all states (plugin default).
    /// Overrides the plugin's own `Systems.game_states` if set.
    states: []const []const u8 = &.{},

    /// Returns true if this plugin uses a local path.
    /// Supports `local:../path` (relative to project) and `@libs/path` (inside project).
    pub fn isLocal(self: PluginDep) bool {
        return std.mem.startsWith(u8, self.repo, "local:") or
            std.mem.startsWith(u8, self.repo, "@");
    }

    /// Returns the local path portion of the repo string.
    /// `local:../foo` → `../foo`, `@libs/foo` → `libs/foo`.
    pub fn localPath(self: PluginDep) []const u8 {
        if (std.mem.startsWith(u8, self.repo, "local:"))
            return self.repo["local:".len..];
        if (std.mem.startsWith(u8, self.repo, "@"))
            return self.repo["@".len..];
        return self.repo;
    }
};

// ── iOS Configuration ──────────────────────────────────────────────

pub const Orientation = enum { portrait, landscape, all };

pub const IosConfig = struct {
    app_name: []const u8 = "",
    bundle_id: []const u8 = "",
    team_id: []const u8 = "",
    minimum_ios: []const u8 = "15.0",
    orientation: Orientation = .all,
    device_family: []const u8 = "1,2",
};

pub const LayerSpace = enum { world, screen };

pub const LayerDef = struct {
    name: []const u8,
    order: i8 = 0,
    space: LayerSpace = .world,
};

pub const ResourceDef = struct {
    name: []const u8,
    json: []const u8 = "",
    texture: []const u8 = "",
};

/// Returns true if a version string is a local path override.
pub fn isLocalVersion(version: []const u8) bool {
    return std.mem.startsWith(u8, version, "local:");
}

/// Returns the path portion of a "local:..." version string.
pub fn localVersionPath(version: []const u8) []const u8 {
    return version["local:".len..];
}

// ── GUI Plugin System ────────────────────────────────────────────────

/// GUI plugin reference as declared in project.labelle.
/// Parsed from ZON: `.gui = .{ .path = "../plugins/imgui" }` or
/// `.gui = .{ .package = "labelle_imgui", .version = "0.2.0" }`.
/// `.gui = .{ .plugin = "imgui" }` — references a declared plugin by name.
/// When null in ProjectConfig, means no GUI (StubGui).
pub const GuiPlugin = struct {
    path: ?[]const u8 = null,
    /// Reference a declared plugin by name (from .plugins list).
    plugin: ?[]const u8 = null,
    package: ?[]const u8 = null,
    version: ?[]const u8 = null,
    url: ?[]const u8 = null,
    hash: ?[]const u8 = null,
};

/// How a GUI plugin renders — determines whether a bridge is needed.
pub const RenderingMode = enum { render_interface, raw_backend };

/// Lifecycle hooks declared by a GUI plugin.
pub const GuiLifecycle = struct {
    init: bool = false,
    shutdown: bool = false,
};

/// Resolved GUI plugin — populated by the CLI after parsing project.labelle
/// and reading the plugin's gui.labelle manifest. Generators use this,
/// not the raw GuiPlugin reference.
pub const ResolvedGui = struct {
    name: []const u8,
    rendering: RenderingMode,
    lifecycle: GuiLifecycle = .{},
    plugin_dir: []const u8,
    /// Absolute path to bridge directory (raw_backend only).
    bridge_dir: ?[]const u8 = null,
    /// Bridge artifact name (e.g., "rlimgui_bridge", "nuklear_raylib_bridge").
    bridge_artifact: []const u8 = "",
};

pub const ProjectConfig = struct {
    name: []const u8,
    description: []const u8 = "",
    version: []const u8 = "0.1.0",
    title: []const u8 = "LaBelle v2",
    width: u32 = 800,
    height: u32 = 600,
    target_fps: u32 = 60,
    backend: Backend = .raylib,
    platform: Platform = .desktop,
    ecs: EcsChoice = .mock,
    /// GUI plugin reference — parsed from project.labelle.
    /// null means no GUI (StubGui injected).
    gui: ?GuiPlugin = null,
    layers: []const LayerDef = &.{
        .{ .name = "background", .order = 0, .space = .screen },
        .{ .name = "world", .order = 1, .space = .world },
        .{ .name = "ui", .order = 2, .space = .screen },
    },

    // Framework version pinning (defaults from versions.zon)
    core_version: []const u8 = CORE_VERSION,
    engine_version: []const u8 = ENGINE_VERSION,
    gfx_version: []const u8 = GFX_VERSION,
    labelle_version: []const u8 = CLI_VERSION,

    /// Explicit initial scene name. When set, the generator uses this for the first
    /// `g.setScene()` call instead of relying on filesystem scan order (scene_names[0]).
    initial_scene: ?[]const u8 = null,
    /// Sprite atlas resources — each entry declares a named atlas with frame data and texture.
    resources: []const ResourceDef = &.{},
    /// When true, the window is created hidden (no visible window). Useful for headless testing in CI.
    hidden: bool = false,
    /// When true, embed scene files into the binary via @embedFile (for release builds).
    /// Plugins — each declares its repo and version. Empty = no plugin deps.
    plugins: []const PluginDep = &.{},

    /// Game states for the state machine. Scripts in `scripts/<state>/` only run
    /// when that state is active. First element is the initial state.
    /// Defaults to a single "running" state when omitted.
    states: []const []const u8 = &.{"running"},

    /// iOS configuration — parsed from project.labelle `.ios` section.
    /// Defaults to null (derived from project name/title when absent).
    ios: ?IosConfig = null,

    /// Pinned assembler version (Phase 3 of RFC #122).
    /// When set, the CLI resolves the assembler binary from the cache at
    /// `~/.labelle/assembler/<version>/labelle-assembler` instead of using
    /// the in-process generator. The LABELLE_ASSEMBLER env var overrides this.
    assembler_version: ?[]const u8 = null,

    /// Resolved GUI plugin — populated by the CLI after reading gui.labelle manifest.
    /// NOT parsed from ZON. Generators check this field, not `gui`.
    resolved_gui: ?ResolvedGui = null,

    /// Check if a plugin is enabled by name.
    pub fn hasPlugin(self: ProjectConfig, name: []const u8) bool {
        for (self.plugins) |p| {
            if (std.mem.eql(u8, p.name, name)) return true;
        }
        return false;
    }

    /// Get a plugin by name.
    pub fn getPlugin(self: ProjectConfig, name: []const u8) ?PluginDep {
        for (self.plugins) |p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    /// Returns true if a GUI plugin is resolved and active.
    pub fn hasGui(self: ProjectConfig) bool {
        return self.resolved_gui != null;
    }
};
