/// labelle-cli generator — reads project.labelle, outputs .labelle/ assembler files.
/// Thin orchestrator that delegates to focused submodules.
const std = @import("std");

// ── Submodules ─────────────────────────────────────────────────────────
const config = @import("config.zig");
const cache = @import("cache.zig");
const scanner = @import("scanner.zig");
const main_zig = @import("main_zig.zig");
const build_files = @import("build_files.zig");

// ── Re-exports (preserve public API for tests and consumers) ──────────
pub const Backend = config.Backend;
pub const Platform = config.Platform;
pub const EcsChoice = config.EcsChoice;
pub const GuiChoice = config.GuiChoice;
pub const PluginDep = config.PluginDep;
pub const LayerSpace = config.LayerSpace;
pub const LayerDef = config.LayerDef;
pub const ResourceDef = config.ResourceDef;
pub const ProjectConfig = config.ProjectConfig;
pub const CLI_VERSION = config.CLI_VERSION;
pub const CORE_VERSION = config.CORE_VERSION;
pub const ENGINE_VERSION = config.ENGINE_VERSION;
pub const GFX_VERSION = config.GFX_VERSION;
pub const isLocalVersion = config.isLocalVersion;

pub const generateMainZig = main_zig.generateMainZig;
pub const generateBuildZig = build_files.generateBuildZig;
pub const generateBuildZigZon = build_files.generateBuildZigZon;

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
    const prefab_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "prefabs", ".zon");
    defer scanner.freeNames(allocator, prefab_names);

    const scene_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "scenes", ".zon");
    defer scanner.freeNames(allocator, scene_names);

    const script_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "scripts", ".zig");
    defer scanner.freeNames(allocator, script_names);

    const component_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "components", ".zig");
    defer scanner.freeNames(allocator, component_names);

    const hook_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "hooks", ".zig");
    defer scanner.freeNames(allocator, hook_names);

    const enum_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "enums", ".zig");
    defer scanner.freeNames(allocator, enum_names);

    const view_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "views", ".zon");
    defer scanner.freeNames(allocator, view_names);

    const gizmo_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "gizmos", ".zon");
    defer scanner.freeNames(allocator, gizmo_names);

    // Copy-only folders (no scanning needed)
    try scanner.copyDirRecursive(allocator, game_dir, target_dir, "assets");

    // Generate build.zig.zon
    const zon = try build_files.generateBuildZigZon(allocator, cfg, target_dir, game_dir);
    defer allocator.free(zon);
    try scanner.writeFile(target_dir, "build.zig.zon", zon);

    // Generate build.zig
    const build_zig = try build_files.generateBuildZig(allocator, cfg);
    defer allocator.free(build_zig);
    try scanner.writeFile(target_dir, "build.zig", build_zig);

    // Generate main.zig — uses ScriptRunner for comptime dispatch
    const main_zig_content = try main_zig.generateMainZig(allocator, cfg, backend_tmpl, script_names, prefab_names, scene_names, component_names, hook_names, enum_names, view_names, gizmo_names);
    defer allocator.free(main_zig_content);
    try scanner.writeFile(target_dir, "main.zig", main_zig_content);
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
