/// Type definitions for the labelle-cli generator.
/// Pure types — no template or I/O dependencies.
const std = @import("std");

pub const Backend = enum { raylib, sokol, sdl, bgfx, wgpu };
pub const Platform = enum { desktop, ios, android, wasm };
pub const EcsChoice = enum { mock, zig_ecs, zflecs, mr_ecs };
pub const GuiChoice = enum { none, simple, clay, imgui };

/// CLI version — injected from root build.zig via build options.
pub const CLI_VERSION = @import("build_options").cli_version;

/// A plugin dependency declared in project.labelle.
/// Plugins are external packages with a repo URL and version tag.
/// Use `repo = "local:../../path"` for local development overrides.
pub const PluginDep = struct {
    name: []const u8,
    repo: []const u8 = "",
    version: []const u8 = "",

    /// Returns true if this plugin uses a local path override.
    pub fn isLocal(self: PluginDep) bool {
        return std.mem.startsWith(u8, self.repo, "local:");
    }

    /// Returns the local path (after the "local:" prefix).
    pub fn localPath(self: PluginDep) []const u8 {
        return self.repo["local:".len..];
    }
};

/// Components exported by each plugin — auto-registered in ComponentRegistry
/// when the plugin is declared in project.labelle.
/// Format: .{ .pascal_name = "Name", .module = "module-path" }.
pub const PluginComponent = struct {
    pascal_name: []const u8,
    module: []const u8,
};

/// Returns known components for first-party plugins (matched by name).
/// Third-party plugins declare their own components via their package.
pub fn pluginComponents(plugin: PluginDep) []const PluginComponent {
    if (std.mem.eql(u8, plugin.name, "physics")) {
        return &.{
            .{ .pascal_name = "RigidBody", .module = "labelle-physics" },
            .{ .pascal_name = "Velocity", .module = "labelle-physics" },
            .{ .pascal_name = "Collider", .module = "labelle-physics" },
            .{ .pascal_name = "Touching", .module = "labelle-physics" },
        };
    }
    return &.{};
}

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
    gui: GuiChoice = .none,
    layers: []const LayerDef = &.{
        .{ .name = "background", .order = 0, .space = .screen },
        .{ .name = "world", .order = 1, .space = .world },
        .{ .name = "ui", .order = 2, .space = .screen },
    },

    // Framework version pinning
    core_version: []const u8 = CLI_VERSION,
    engine_version: []const u8 = CLI_VERSION,
    gfx_version: []const u8 = CLI_VERSION,
    labelle_version: []const u8 = CLI_VERSION,

    /// Explicit initial scene name. When set, the generator uses this for the first
    /// `g.setScene()` call instead of relying on filesystem scan order (scene_names[0]).
    initial_scene: ?[]const u8 = null,
    /// Sprite atlas resources — each entry declares a named atlas with frame data and texture.
    resources: []const ResourceDef = &.{},
    /// When true, the window is created hidden (no visible window). Useful for headless testing in CI.
    hidden: bool = false,
    /// Plugins — each declares its repo and version. Empty = no plugin deps.
    plugins: []const PluginDep = &.{},

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
};
