const std = @import("std");
const gen = @import("generator");
const util = @import("util.zig");
const config = @import("config.zig");

/// Ensure all dependencies declared in the project config are present in the local cache.
pub fn ensureCache(allocator: std.mem.Allocator, cfg: gen.ProjectConfig) !void {
    const missing = try gen.validateCache(allocator, cfg);
    defer {
        for (missing) |m| allocator.free(m);
        allocator.free(missing);
    }

    if (missing.len == 0) return;

    std.debug.print("labelle: populating package cache...\n", .{});

    const framework = [_]struct { name: []const u8, version: []const u8, dir: []const u8 }{
        .{ .name = "core", .version = cfg.core_version, .dir = "labelle-core" },
        .{ .name = "engine", .version = cfg.engine_version, .dir = "engine" },
        .{ .name = "gfx", .version = cfg.gfx_version, .dir = "labelle-gfx" },
    };

    for (framework) |pkg| {
        if (!try gen.isFrameworkCached(allocator, pkg.name, pkg.version)) {
            try fetchFrameworkWithFallback(allocator, pkg.name, pkg.version);
        }
    }

    const asm_ver = cfg.assembler_version orelse cfg.labelle_version;
    if (!try gen.isAssemblerCached(allocator, asm_ver)) {
        try fetchAssemblerWithFallback(allocator, asm_ver);
    }

    for (cfg.plugins) |plugin| {
        if (!try gen.isPluginCached(allocator, plugin)) {
            try fetchPluginWithFallback(allocator, plugin);
        }
    }

    try gen.patchCachedDeps(allocator, cfg);

    std.debug.print("  cache populated\n", .{});
}

/// Fetch a framework package: try monorepo first, then remote git clone.
pub fn fetchFrameworkWithFallback(allocator: std.mem.Allocator, name: []const u8, version: []const u8) !void {
    if (findRepoRoot(allocator)) |repo_root| {
        defer allocator.free(repo_root);
        const dir_name: []const u8 = if (std.mem.eql(u8, name, "core"))
            "labelle-core"
        else if (std.mem.eql(u8, name, "engine"))
            "engine"
        else if (std.mem.eql(u8, name, "gfx"))
            "labelle-gfx"
        else
            name;
        const src = try std.fs.path.join(allocator, &.{ repo_root, dir_name });
        defer allocator.free(src);

        if (util.dirExists(src)) {
            std.debug.print("  caching {s} {s} (local)\n", .{ name, version });
            try gen.populateFrameworkPackage(allocator, name, version, src);
            return;
        }
    }

    std.debug.print("  fetching {s} {s} (remote)...\n", .{ name, version });
    try gen.fetchFrameworkPackage(allocator, name, version);
}

/// Fetch assembler-bundled packages (backends, ecs, gui): try monorepo
/// first, then remote. The CLI no longer bundles any of these — see #147.
pub fn fetchAssemblerWithFallback(allocator: std.mem.Allocator, version: []const u8) !void {
    if (findRepoRoot(allocator)) |repo_root| {
        defer allocator.free(repo_root);
        const companion = try std.fs.path.join(allocator, &.{ repo_root, "labelle-assembler" });
        defer allocator.free(companion);

        if (util.dirExists(companion)) {
            std.debug.print("  caching assembler {s} (local)\n", .{version});
            try gen.populateAssemblerCache(allocator, version, companion);
            return;
        }
    }

    std.debug.print("  fetching assembler {s} (remote)...\n", .{version});
    try gen.fetchAssemblerPackages(allocator, version);
}

/// Fetch a plugin: try monorepo first, then remote git clone.
pub fn fetchPluginWithFallback(allocator: std.mem.Allocator, plugin: gen.PluginDep) !void {
    if (findRepoRoot(allocator)) |repo_root| {
        defer allocator.free(repo_root);
        const plugin_dir = try std.fmt.allocPrint(allocator, "labelle-{s}", .{plugin.name});
        defer allocator.free(plugin_dir);
        const src = try std.fs.path.join(allocator, &.{ repo_root, plugin_dir });
        defer allocator.free(src);

        if (util.dirExists(src)) {
            std.debug.print("  caching plugin {s} {s} (local)\n", .{ plugin.name, plugin.version });
            try gen.populatePlugin(allocator, plugin, src);
            return;
        }
    }

    std.debug.print("  fetching plugin {s} {s} (remote)...\n", .{ plugin.name, plugin.version });
    try gen.fetchPlugin(allocator, plugin);
}

/// Try to find the monorepo root by walking up from the CLI executable path.
fn findRepoRoot(allocator: std.mem.Allocator) ?[]const u8 {
    const io = config.globalIo();
    const exe_path = std.process.executablePathAlloc(io, allocator) catch return null;
    defer allocator.free(exe_path);

    var dir = std.fs.path.dirname(exe_path) orelse return null;
    var depth: u8 = 0;
    while (depth < 6) : (depth += 1) {
        const marker = std.fs.path.join(allocator, &.{ dir, "labelle-core" }) catch return null;
        defer allocator.free(marker);

        std.Io.Dir.cwd().access(io, marker, .{}) catch {
            dir = std.fs.path.dirname(dir) orelse return null;
            continue;
        };

        return allocator.dupe(u8, dir) catch return null;
    }

    return null;
}
