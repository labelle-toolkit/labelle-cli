/// labelle-cli generator — reads project.labelle, outputs .labelle/ assembler files.
/// Thin orchestrator that delegates to focused submodules.
const std = @import("std");

// ── Submodules ─────────────────────────────────────────────────────────
const config = @import("config.zig");
const cache = @import("cache.zig");
const scanner = @import("scanner.zig");
const main_zig = @import("main_zig.zig");
pub const script_scanner = @import("script_scanner.zig");
const build_files = @import("build_files.zig");
pub const template = @import("template.zig");
pub const plugin_manifest = @import("plugin_manifest.zig");
const gui_resolve = @import("gui_resolve.zig");

// Force test discovery for files that aren't transitively reached by
// any compiled function path during `addTest` runs.
test {
    _ = @import("plugin_manifest.zig");
}

// ── Re-exports (preserve public API for tests and consumers) ──────────
pub const Backend = config.Backend;
pub const Platform = config.Platform;
pub const EcsChoice = config.EcsChoice;
pub const GuiPlugin = config.GuiPlugin;
pub const ResolvedGui = config.ResolvedGui;
pub const RenderingMode = config.RenderingMode;
pub const GuiLifecycle = config.GuiLifecycle;
pub const PluginDep = config.PluginDep;
pub const IosConfig = config.IosConfig;
pub const Orientation = config.Orientation;
pub const LayerSpace = config.LayerSpace;
pub const LayerDef = config.LayerDef;
pub const ResourceDef = config.ResourceDef;
pub const ProjectConfig = config.ProjectConfig;
pub const CLI_VERSION = config.CLI_VERSION;
pub const CORE_VERSION = config.CORE_VERSION;
pub const ENGINE_VERSION = config.ENGINE_VERSION;
pub const GFX_VERSION = config.GFX_VERSION;
pub const isLocalVersion = config.isLocalVersion;

pub const resolveGuiPlugin = gui_resolve.resolveGuiPlugin;

pub const generateMainZigFromTemplate = main_zig.generateMainZigFromTemplate;
pub const generateBuildZig = build_files.generateBuildZig;
pub const generateBuildZigZon = build_files.generateBuildZigZon;
pub const deps_linker = build_files.deps_linker;

pub const validateCache = cache.validateCache;
pub const getCacheRoot = cache.getCacheRoot;
pub const getPackagesDir = cache.getPackagesDir;
pub const populateCliCache = cache.populateCliCache;
pub const populateFrameworkPackage = cache.populateFrameworkPackage;
pub const populatePlugin = cache.populatePlugin;
pub const isFrameworkCached = cache.isFrameworkCached;
pub const isCliCached = cache.isCliCached;
pub const isPluginCached = cache.isPluginCached;
pub const fetchFrameworkPackage = cache.fetchFrameworkPackage;
pub const fetchPlugin = cache.fetchPlugin;
pub const fetchCliPackages = cache.fetchCliPackages;
pub const R2_BASE_URL = cache.R2_BASE_URL;
pub const patchCachedDeps = cache.patchCachedDeps;
pub const resolvePlugin = cache.resolvePlugin;

/// Generate all assembler files into output_dir/.labelle/{backend}_{platform}/.
pub fn generate(allocator: std.mem.Allocator, cfg: ProjectConfig, output_dir: []const u8, game_dir: []const u8) !void {
    const cwd = std.fs.cwd();

    // Target subfolder: .labelle/raylib_desktop/, .labelle/sokol_ios/, etc.
    const target_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ @tagName(cfg.backend), @tagName(cfg.platform) });
    defer allocator.free(target_name);
    const target_dir = try std.fs.path.join(allocator, &.{ output_dir, target_name });
    defer allocator.free(target_dir);
    try cwd.makePath(target_dir);

    // Load backend lifecycle template
    const backend_tmpl = try loadBackendTemplate(allocator, game_dir, cfg);
    defer allocator.free(backend_tmpl);

    // Copy game folders into target dir and scan file stems in one pass.
    // Folders that need scanning use copyAndScan; assets is copy-only.
    const prefab_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "prefabs", ".jsonc");
    defer scanner.freeNames(allocator, prefab_names);

    const jsonc_scene_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "scenes", ".jsonc");
    defer scanner.freeNames(allocator, jsonc_scene_names);

    // Copy all script files (including subdirectories) into target dir.
    // Then use ScriptScanner to parse directory-based state binding.
    const script_names_unused = try scanner.copyAndScan(allocator, game_dir, target_dir, "scripts", ".zig");
    scanner.freeNames(allocator, script_names_unused);

    const scripts_target = try std.fs.path.join(allocator, &.{ target_dir, "scripts" });
    defer allocator.free(scripts_target);
    var script_scan = script_scanner.ScriptScanner.init(allocator, cfg.states);
    defer script_scan.deinit();
    try script_scan.scanDir(scripts_target);
    const script_entries = script_scan.getEntries();

    const component_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "components", ".zig");
    defer scanner.freeNames(allocator, component_names);

    const hook_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "hooks", ".zig");
    defer scanner.freeNames(allocator, hook_names);

    const event_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "events", ".zig");
    defer scanner.freeNames(allocator, event_names);

    const enum_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "enums", ".zig");
    defer scanner.freeNames(allocator, enum_names);

    const view_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "views", ".zon");
    defer scanner.freeNames(allocator, view_names);

    const gizmo_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "gizmos", ".zon");
    defer scanner.freeNames(allocator, gizmo_names);

    // Copy-only folders (no scanning needed)
    try scanner.copyDirRecursive(allocator, game_dir, target_dir, "assets");

    // ── Plugin-declared convention directories ────────────────────────
    // Each plugin in cfg.plugins may ship a `plugin.labelle` manifest at
    // its root that declares additional directories the CLI should copy
    // and/or scan from the game project. See
    // `docs/RFC-plugin-manifest.md` for the design.
    //
    // The manifest is read regardless of `plugin.states` (game-state
    // gating affects runtime, not generate-time layout). Missing source
    // directories are silently tolerated, matching the behavior of the
    // hardcoded scans above.
    //
    // Duplicate directory declarations across plugins are a hard error
    // (RFC E3). A single name can be claimed by exactly one plugin to
    // keep the "who owns this directory" story unambiguous and prevent
    // conflicting copy passes.
    //
    // All manifests are loaded first and kept alive until every copy
    // pass has run, so the duplicate-detection hash map (which stores
    // slices into parsed manifest memory) stays valid across plugins.
    //
    // Pre-reserve capacity up front so the per-plugin append cannot
    // fail. If we used a fallible append, a successful loadOptional
    // followed by an OOM-on-resize would leak the parsed manifest
    // (it wouldn't have made it into the cleanup list).
    var loaded_manifests = std.ArrayListUnmanaged(plugin_manifest.PluginManifest){};
    defer {
        for (loaded_manifests.items) |*m| m.deinit();
        loaded_manifests.deinit(allocator);
    }
    try loaded_manifests.ensureTotalCapacity(allocator, cfg.plugins.len);

    var owner_of_dir = std.StringHashMapUnmanaged([]const u8){};
    defer owner_of_dir.deinit(allocator);

    for (cfg.plugins) |plugin| {
        const maybe_manifest = try plugin_manifest.loadOptional(allocator, plugin, game_dir);
        const manifest = maybe_manifest orelse continue;
        // Capacity was reserved above — this cannot fail, so there's
        // no window where `manifest` is owned but outside the cleanup
        // list's reach.
        loaded_manifests.appendAssumeCapacity(manifest);

        for (manifest.convention_dirs) |dir| {
            // Duplicate detection is *cross-plugin only*. A single plugin
            // is allowed to declare the same directory name in multiple
            // convention_dirs entries with different extensions — that's
            // the RFC Q3 multi-extension pattern (e.g. a plugin wanting
            // both .zig and .zon files under state_machines/). Only error
            // when a different plugin already claimed the name.
            if (owner_of_dir.get(dir.name)) |prev_owner| {
                if (!std.mem.eql(u8, prev_owner, plugin.name)) {
                    std.debug.print(
                        "labelle: two plugins want the same convention directory '{s}':\n  - plugin '{s}' already declared it\n  - plugin '{s}' is trying to declare it again\n  each plugin must use a unique directory name\n",
                        .{ dir.name, prev_owner, plugin.name },
                    );
                    return error.PluginManifestDuplicateDir;
                }
                // Same plugin re-declaring the name (multi-extension) —
                // don't overwrite the claim, just keep going and let the
                // copy pass below handle it.
            } else {
                try owner_of_dir.put(allocator, dir.name, plugin.name);
            }

            switch (dir.mode) {
                .copy_and_scan => {
                    // `extension` is required for copy_and_scan and is
                    // validated by plugin_manifest.loadFromDir at load
                    // time, so .? here is safe.
                    const ext = dir.extension.?;
                    const names = try scanner.copyAndScan(
                        allocator,
                        game_dir,
                        target_dir,
                        dir.name,
                        ext,
                    );
                    // v1: name list is computed but not exposed to codegen.
                    // Future RFC will decide how plugins drive main.zig
                    // generation from these names.
                    scanner.freeNames(allocator, names);
                },
                .copy_only => {
                    try scanner.copyDirRecursive(
                        allocator,
                        game_dir,
                        target_dir,
                        dir.name,
                    );
                },
            }
        }
    }

    // Generate build.zig.zon
    const zon = try build_files.generateBuildZigZon(allocator, cfg, target_dir, output_dir, game_dir);
    defer allocator.free(zon);
    try scanner.writeFile(target_dir, "build.zig.zon", zon);

    // Generate build.zig
    const build_zig = try build_files.generateBuildZig(allocator, cfg);
    defer allocator.free(build_zig);
    try scanner.writeFile(target_dir, "build.zig", build_zig);

    // Generate main.zig — load engine template from codegen/ directory
    const engine_template = try loadEngineTemplate(allocator, game_dir, cfg);
    defer allocator.free(engine_template);
    const main_zig_content = try main_zig.generateMainZigFromTemplate(allocator, engine_template, cfg, backend_tmpl, script_entries, prefab_names, jsonc_scene_names, component_names, hook_names, event_names, enum_names, view_names, gizmo_names);
    defer allocator.free(main_zig_content);
    try scanner.writeFile(target_dir, "main.zig", main_zig_content);
}

/// Load the engine's main.zig template from the codegen/ directory.
fn loadEngineTemplate(allocator: std.mem.Allocator, game_dir: []const u8, cfg: ProjectConfig) ![]const u8 {
    const engine_path = try cache.resolveFrameworkPackage(allocator, "engine", cfg.engine_version, game_dir);
    defer allocator.free(engine_path);

    const tmpl_path = try std.fs.path.join(allocator, &.{ engine_path, "codegen", "main.zig.template" });
    defer allocator.free(tmpl_path);

    return std.fs.cwd().readFileAlloc(allocator, tmpl_path, 256 * 1024) catch |err| {
        std.debug.print("labelle: could not read engine template '{s}': {any}\n", .{ tmpl_path, err });
        return error.EngineTemplateNotFound;
    };
}

/// Load the backend+platform lifecycle template from the CLI cache.
fn loadBackendTemplate(allocator: std.mem.Allocator, game_dir: []const u8, cfg: ProjectConfig) ![]const u8 {
    const backend_name = @tagName(cfg.backend);
    const platform_name = if (cfg.backend == .sokol and (cfg.platform == .ios or cfg.platform == .android))
        "mobile"
    else if (cfg.backend == .sokol and cfg.platform == .wasm)
        "desktop" // sokol uses a single template for desktop and wasm
    else
        @tagName(cfg.platform);
    const tmpl_filename = try std.fmt.allocPrint(allocator, "{s}.txt", .{platform_name});
    defer allocator.free(tmpl_filename);

    // Resolve backend path from CLI cache
    var backend_subpath_buf: [128]u8 = undefined;
    const backend_subpath = std.fmt.bufPrint(&backend_subpath_buf, "backends/{s}", .{backend_name}) catch unreachable;
    const backend_path = try cache.resolveCliPackage(allocator, cfg.labelle_version, game_dir, backend_subpath);
    defer allocator.free(backend_path);

    const tmpl_path = try std.fs.path.join(allocator, &.{ backend_path, "templates", tmpl_filename });
    defer allocator.free(tmpl_path);

    return std.fs.cwd().readFileAlloc(allocator, tmpl_path, 64 * 1024) catch |err| {
        std.debug.print("labelle: could not read backend template '{s}': {any}\n", .{ tmpl_path, err });
        return error.TemplateNotFound;
    };
}
