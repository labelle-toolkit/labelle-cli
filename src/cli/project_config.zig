//! CLI-owned `project.labelle` schema.
//!
//! Issue #217 makes `labelle-cli` a thin driver over the standalone
//! `labelle-assembler` binary — the CLI no longer compiles in the
//! assembler's `generator` module. The assembler still *owns* the
//! canonical `project.labelle` schema; this file is the minimal subset
//! the CLI itself needs to read.
//!
//! Why the CLI needs *any* of the schema: a handful of CLI-retained
//! commands (`build` / `run` / `upgrade` / the iOS + Android deploy
//! paths) parse `project.labelle` to drive orchestration the CLI owns —
//! target-dir naming (`<backend>_<platform>`), the compatibility-warning
//! pass, the iOS/Android `Info.plist` / manifest emission, lockfile
//! writing, docker target selection. None of that is code generation;
//! it is the CLI deciding *which assembler subcommand to run and with
//! what flags*, plus packaging steps the assembler never touches.
//!
//! These are PURE TYPES — no I/O, no templates. They mirror the
//! assembler's `src/config.zig` field-for-field for the fields the CLI
//! reads. The CLI parses project.labelle with `.ignore_unknown_fields
//! = true` (see `config.zig`), so the assembler can add fields without
//! breaking the CLI; only a field the CLI *uses* changing shape would
//! require a matching edit here.

const std = @import("std");

/// Graphics / windowing backend selection. `null` is a headless backend.
pub const Backend = enum { raylib, sokol, sdl, bgfx, wgpu, null };
pub const Platform = enum { desktop, ios, android, wasm };

/// Texture container a platform ships atlases in — `.png` (CPU-decoded) or
/// `.astc` (GPU-native, zero decode). Mirrors the assembler's `AssetFormat`
/// (the assembler does the catalog swap; the CLI reads this to know whether to
/// run `labelle astc` before generating). See labelle-gfx#269 / #340.
pub const AssetFormat = enum { png, astc };

/// Per-platform `AssetFormat` selection; default `.png` everywhere (opt-in).
pub const AssetCompression = struct {
    desktop: AssetFormat = .png,
    android: AssetFormat = .png,
    ios: AssetFormat = .png,
    web: AssetFormat = .png,

    pub fn formatFor(self: AssetCompression, platform: Platform) AssetFormat {
        return switch (platform) {
            .desktop => self.desktop,
            .android => self.android,
            .ios => self.ios,
            .wasm => self.web,
        };
    }
};
pub const EcsChoice = enum { mock, zig_ecs, zflecs, mr_ecs };

/// CLI version — injected from build.zig via build options.
pub const CLI_VERSION = @import("build_options").cli_version;

/// Library versions — from versions.zon, injected via build options.
/// These are the tested compatible versions for this CLI release.
pub const CORE_VERSION = @import("build_options").core_version;
pub const ENGINE_VERSION = @import("build_options").engine_version;
pub const GFX_VERSION = @import("build_options").gfx_version;
/// The bgfx backend package version paired with GFX_VERSION — the two
/// cross a shared backend contract and must be bumped together.
pub const BGFX_VERSION = @import("build_options").bgfx_version;

/// A plugin dependency declared in project.labelle.
pub const PluginDep = struct {
    name: []const u8,
    repo: []const u8 = "",
    version: []const u8 = "",
    /// Game states this plugin runs in. Empty = all states (plugin default).
    states: []const []const u8 = &.{},

    /// Returns true if this plugin uses a local path.
    /// Supports `local:../path` (relative to project) and `@libs/path`.
    pub fn isLocal(self: PluginDep) bool {
        return std.mem.startsWith(u8, self.repo, "local:") or
            std.mem.startsWith(u8, self.repo, "@");
    }

    /// Returns the local path portion of the repo string.
    pub fn localPath(self: PluginDep) []const u8 {
        if (std.mem.startsWith(u8, self.repo, "local:"))
            return self.repo["local:".len..];
        if (std.mem.startsWith(u8, self.repo, "@"))
            return self.repo["@".len..];
        return self.repo;
    }
};

// ── iOS Configuration ──────────────────────────────────────────────

pub const Orientation = enum { portrait, landscape, sensor_landscape, all };

pub const IosConfig = struct {
    app_name: []const u8 = "",
    bundle_id: []const u8 = "",
    team_id: []const u8 = "",
    minimum_ios: []const u8 = "15.0",
    orientation: Orientation = .all,
    device_family: []const u8 = "1,2",
};

// ── Android Configuration ──────────────────────────────────────────

pub const AndroidConfig = struct {
    app_name: []const u8 = "",
    package_name: []const u8 = "", // e.g. "com.labelle.mygame"
    min_sdk_version: u32 = 28, // Android 9 (Pie) — NativeActivity + GLES3
    target_sdk_version: u32 = 34, // Android 14
    orientation: Orientation = .all,
    /// Launch the game fullscreen with the status bar and title bar hidden.
    immersive_mode: bool = false,
};

pub const LayerSpace = enum { world, screen, screen_fill };

pub const LayerDef = struct {
    name: []const u8,
    order: i8 = 0,
    space: LayerSpace = .world,
};

/// Half-open codepoint range `[first, last)` baked into a font atlas.
pub const CodepointRange = struct {
    first: u32,
    last: u32,
};

/// Bake-time parameters for a font resource.
pub const FontBakeParams = struct {
    pixel_height: f32 = 16,
    ranges: []const CodepointRange = &.{ .{ .first = 0x20, .last = 0x7F } },
    atlas_width: u32 = 512,
    atlas_height: u32 = 512,
};

/// Discriminator for `ResourceDef`.
pub const ResourceKind = enum {
    atlas,
    sound,
    font,
    invalid,
};

/// Sentinel returned by `ResourceDef.validate`.
pub const ResourceValidationError = enum {
    ok,
    no_path,
    multiple_paths,
    atlas_incomplete,
    font_params_misplaced,
};

pub const ResourceDef = struct {
    name: []const u8,

    // ── Atlas (JSON sprite map + PNG/RGBA texture)
    json: []const u8 = "",
    texture: []const u8 = "",

    // ── Sound — `.wav` / `.ogg` path relative to the project root.
    sound: []const u8 = "",

    // ── Font — `.ttf` / `.otf` path.
    font: []const u8 = "",

    /// Bake parameters for font resources. Ignored on atlas/sound entries.
    font_params: ?FontBakeParams = null,

    /// Eager (`false`) vs lazy (`true`) decode; `null` lets the assembler pick.
    lazy: ?bool = null,

    /// Classify which kind of asset this resource declares.
    pub fn kind(self: ResourceDef) ResourceKind {
        const has_atlas = self.json.len > 0 or self.texture.len > 0;
        const has_sound = self.sound.len > 0;
        const has_font = self.font.len > 0;
        const count: u8 = @as(u8, @intFromBool(has_atlas)) + @intFromBool(has_sound) + @intFromBool(has_font);
        if (count != 1) return .invalid;
        if (has_atlas) {
            if (self.json.len == 0 or self.texture.len == 0) return .invalid;
            return .atlas;
        }
        if (has_sound) return .sound;
        return .font;
    }

    /// Structured validation result.
    pub fn validate(self: ResourceDef) ResourceValidationError {
        const has_atlas = self.json.len > 0 or self.texture.len > 0;
        const has_sound = self.sound.len > 0;
        const has_font = self.font.len > 0;
        const count: u8 = @as(u8, @intFromBool(has_atlas)) + @intFromBool(has_sound) + @intFromBool(has_font);
        if (count == 0) return .no_path;
        if (count > 1) return .multiple_paths;
        if (has_atlas and (self.json.len == 0 or self.texture.len == 0)) return .atlas_incomplete;
        if (self.font_params != null and !has_font) return .font_params_misplaced;
        return .ok;
    }
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

/// Resolved GUI plugin. The CLI never populates this — GUI resolution is
/// owned by the assembler's `generate` subcommand. It is kept here only
/// so `ProjectConfig` matches the assembler's schema shape; the field is
/// always `null` in the CLI.
pub const ResolvedGui = struct {
    name: []const u8,
    rendering: RenderingMode,
    lifecycle: GuiLifecycle = .{},
    plugin_dir: []const u8,
    bridge_dir: ?[]const u8 = null,
    bridge_artifact: []const u8 = "",
};

/// Gamepad opt-out, mirroring assembler `src/config.zig` (gamepad: .auto | .none).
pub const GamepadMode = enum { auto, none };

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
    /// Gamepad input mode (assembler#274 opt-out flag): `.auto` (default)
    /// pulls the shared SDL gamepad source into raylib/sokol desktop
    /// builds; `.none` disables it (and drops the SDL2 link dependency).
    gamepad: GamepadMode = .auto,
    /// GUI plugin reference — parsed from project.labelle.
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

    /// The graphics backend package (e.g. bgfx), pinned like a plugin.
    /// The assembler is the primary consumer; the CLI parses it so
    /// `upgrade --check` can REPORT the pin instead of silently omitting
    /// it from the version report (cli#336). Shape matches `PluginDep`
    /// (`.name` / `.repo` / `.version`).
    backend_package: ?PluginDep = null,

    /// Explicit initial prefab name. RFC #560 / issue #565 (unify scenes
    /// and prefabs) renamed `.initial_scene` to `.initial_prefab`. The
    /// legacy `.initial_scene` field below is still accepted for backward
    /// compatibility but is deprecated; `initial_prefab` wins when both
    /// are set. Mirrors `labelle-assembler` `src/config.zig`.
    initial_prefab: ?[]const u8 = null,
    /// Deprecated legacy alias for `initial_prefab`. Still accepted in
    /// `project.labelle` so existing projects keep parsing; when both are
    /// set, `initial_prefab` wins. Prefer reading
    /// `resolvedInitialPrefab()` instead of this field directly.
    initial_scene: ?[]const u8 = null,
    /// Sprite atlas / sound / font resources.
    resources: []const ResourceDef = &.{},
    /// Per-platform texture-compression selection (read by `build`/`run` to
    /// auto-run `labelle astc` before generating; the assembler does the
    /// catalog `.png → .astc` swap). Default `.png` everywhere.
    asset_compression: AssetCompression = .{},
    /// When true, the window is created hidden (headless CI).
    hidden: bool = false,
    /// Plugins — each declares its repo and version.
    plugins: []const PluginDep = &.{},

    /// Game states for the state machine. First element is the initial state.
    states: []const []const u8 = &.{"running"},

    /// iOS configuration — parsed from project.labelle `.ios` section.
    ios: ?IosConfig = null,

    /// Android configuration — parsed from project.labelle `.android` section.
    android: ?AndroidConfig = null,

    /// Pinned assembler version (RFC #122). When set, the CLI resolves the
    /// assembler binary from the cache instead of the paired default.
    assembler_version: ?[]const u8 = null,

    /// Resolved GUI plugin — NOT parsed from ZON, NOT populated by the CLI.
    /// Owned by the assembler; kept here only for schema-shape parity.
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

    /// Returns the effective initial-prefab name, preferring the new
    /// `initial_prefab` field and falling back to the deprecated
    /// `initial_scene` legacy alias. `initial_prefab` wins when both are
    /// set. Mirrors `labelle-assembler` `src/config.zig`.
    pub fn resolvedInitialPrefab(self: ProjectConfig) ?[]const u8 {
        return self.initial_prefab orelse self.initial_scene;
    }

    /// Normalizes the deprecated `initial_scene` alias into
    /// `initial_prefab` and clears the legacy field. Emits a deprecation
    /// warning when the legacy alias was present. RFC #560 / issue #565.
    pub fn normalizeInitialPrefab(self: *ProjectConfig) void {
        if (self.initial_scene) |legacy| {
            if (self.initial_prefab == null) {
                std.debug.print(
                    "project.labelle: `.initial_scene` is deprecated; rename it to `.initial_prefab` (`.initial_scene` will be removed in a future release)\n",
                    .{},
                );
                self.initial_prefab = legacy;
            } else {
                std.debug.print(
                    "project.labelle: both `.initial_prefab` and `.initial_scene` are set; `.initial_scene` is deprecated and ignored\n",
                    .{},
                );
            }
            self.initial_scene = null;
        }
    }
};

test "AssetCompression.formatFor + default png" {
    const def = AssetCompression{};
    inline for (.{ Platform.desktop, .android, .ios, .wasm }) |p|
        try @import("std").testing.expectEqual(AssetFormat.png, def.formatFor(p));
    const m = AssetCompression{ .android = .astc, .desktop = .astc };
    try @import("std").testing.expectEqual(AssetFormat.astc, m.formatFor(.android));
    try @import("std").testing.expectEqual(AssetFormat.png, m.formatFor(.wasm));
}
