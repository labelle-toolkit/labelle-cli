/// Package cache manager — resolves versioned dependencies to local paths.
///
/// Cache layout:
///   ~/.labelle/packages/
///     core/0.3.0/              (fetched from core repo)
///     engine/0.3.0/            (fetched from engine repo)
///     gfx/0.3.0/              (fetched from gfx repo)
///     plugins/{repo}/{version}/ (fetched from plugin repos)
///     cli/0.3.0/              (populated from CLI companion directory)
///       backends/raylib/
///       ecs/zig-ecs/
///
/// Overridable via LABELLE_HOME env var.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");

/// The default cache root directory name inside the user's home.
const DEFAULT_CACHE_DIR = ".labelle";
const PACKAGES_SUBDIR = "packages";

/// Resolve the cache root directory.
/// Priority: LABELLE_HOME env var > ~/.labelle/
pub fn getCacheRoot(allocator: std.mem.Allocator) ![]const u8 {
    // Check LABELLE_HOME env var first
    if (std.process.getEnvVarOwned(allocator, "LABELLE_HOME")) |home| {
        return home;
    } else |_| {}

    // Fall back to platform-appropriate home directory
    const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home_dir = std.process.getEnvVarOwned(allocator, home_env) catch |err| {
        std.debug.print("labelle: could not determine home directory ({s}): {any}\n", .{ home_env, err });
        return error.NoHomeDirectory;
    };
    defer allocator.free(home_dir);

    return try std.fs.path.join(allocator, &.{ home_dir, DEFAULT_CACHE_DIR });
}

/// Resolve the packages directory: ~/.labelle/packages/
pub fn getPackagesDir(allocator: std.mem.Allocator) ![]const u8 {
    const cache_root = try getCacheRoot(allocator);
    defer allocator.free(cache_root);
    return try std.fs.path.join(allocator, &.{ cache_root, PACKAGES_SUBDIR });
}

/// Resolve a framework package (core, engine, gfx) to its cached path.
/// Returns an absolute path like: ~/.labelle/packages/core/0.3.0
/// `project_dir` is used to resolve `local:` paths relative to the project (not CWD).
pub fn resolveFrameworkPackage(allocator: std.mem.Allocator, package: []const u8, version: []const u8, project_dir: ?[]const u8) ![]const u8 {
    if (config.isLocalVersion(version)) {
        return resolveLocalPath(allocator, config.localVersionPath(version), project_dir);
    }

    const packages_dir = try getPackagesDir(allocator);
    defer allocator.free(packages_dir);
    return try std.fs.path.join(allocator, &.{ packages_dir, package, version });
}

/// Resolve a CLI-bundled package (backend, ecs adapter) to its cached path.
/// Returns an absolute path like: ~/.labelle/packages/cli/0.3.0/backends/raylib
/// `project_dir` is used to resolve `local:` paths relative to the project (not CWD).
pub fn resolveCliPackage(allocator: std.mem.Allocator, cli_version: []const u8, project_dir: ?[]const u8, subpath: []const u8) ![]const u8 {
    if (config.isLocalVersion(cli_version)) {
        const local_path = config.localVersionPath(cli_version);
        const joined = try std.fs.path.join(allocator, &.{ local_path, subpath });
        defer allocator.free(joined);
        return resolveLocalPath(allocator, joined, project_dir);
    }

    const packages_dir = try getPackagesDir(allocator);
    defer allocator.free(packages_dir);
    return try std.fs.path.join(allocator, &.{ packages_dir, "cli", cli_version, subpath });
}

/// Resolve a plugin to its cached path.
/// Returns an absolute path like: ~/.labelle/packages/plugins/github.com/labelle-toolkit/labelle-physics/0.3.0
/// `project_dir` is used to resolve `local:` paths relative to the project (not CWD).
pub fn resolvePlugin(allocator: std.mem.Allocator, plugin: config.PluginDep, project_dir: ?[]const u8) ![]const u8 {
    if (plugin.isLocal()) {
        return resolveLocalPath(allocator, plugin.localPath(), project_dir);
    }

    const packages_dir = try getPackagesDir(allocator);
    defer allocator.free(packages_dir);
    return try std.fs.path.join(allocator, &.{ packages_dir, "plugins", plugin.repo, plugin.version });
}

/// Resolve a local path override relative to a project directory.
/// If project_dir is provided, joins it with the local path before resolving.
/// Falls back to CWD if project_dir is null.
fn resolveLocalPath(allocator: std.mem.Allocator, local_path: []const u8, project_dir: ?[]const u8) ![]const u8 {
    const resolve_path = if (std.fs.path.isAbsolute(local_path))
        try allocator.dupe(u8, local_path)
    else if (project_dir) |pd| blk: {
        const joined = try std.fs.path.join(allocator, &.{ pd, local_path });
        break :blk joined;
    } else try allocator.dupe(u8, local_path);
    defer allocator.free(resolve_path);

    return std.fs.cwd().realpathAlloc(allocator, resolve_path) catch {
        std.debug.print("labelle: warning: local path '{s}' does not exist\n", .{resolve_path});
        return try allocator.dupe(u8, resolve_path);
    };
}

/// Check if a framework package version is cached.
pub fn isFrameworkCached(allocator: std.mem.Allocator, package: []const u8, version: []const u8) !bool {
    if (config.isLocalVersion(version)) return true;

    const path = try resolveFrameworkPackage(allocator, package, version, null);
    defer allocator.free(path);
    return dirExists(path);
}

/// Check if a CLI package version is cached.
pub fn isCliCached(allocator: std.mem.Allocator, cli_version: []const u8) !bool {
    if (config.isLocalVersion(cli_version)) return true;

    const packages_dir = try getPackagesDir(allocator);
    defer allocator.free(packages_dir);
    const path = try std.fs.path.join(allocator, &.{ packages_dir, "cli", cli_version });
    defer allocator.free(path);
    return dirExists(path);
}

/// Check if a plugin version is cached.
pub fn isPluginCached(allocator: std.mem.Allocator, plugin: config.PluginDep) !bool {
    if (plugin.isLocal()) return true;

    const path = try resolvePlugin(allocator, plugin, null);
    defer allocator.free(path);
    return dirExists(path);
}

/// Populate the CLI cache from the companion directory.
/// The companion directory is expected to be a sibling of the CLI binary: ../packages/
/// Copies backends/ and ecs/ into ~/.labelle/packages/cli/{version}/
pub fn populateCliCache(allocator: std.mem.Allocator, cli_version: []const u8, companion_dir: []const u8) !void {
    const packages_dir = try getPackagesDir(allocator);
    defer allocator.free(packages_dir);

    const target = try std.fs.path.join(allocator, &.{ packages_dir, "cli", cli_version });
    defer allocator.free(target);

    const cwd = std.fs.cwd();

    // Create target directory
    cwd.makePath(target) catch |err| {
        std.debug.print("labelle: could not create cache directory '{s}': {any}\n", .{ target, err });
        return error.CachePopulationFailed;
    };

    // Symlink companion subdirectories
    const subdirs = [_][]const u8{ "backends", "ecs", "gui" };
    for (subdirs) |subdir| {
        const src_path = try std.fs.path.join(allocator, &.{ companion_dir, subdir });
        defer allocator.free(src_path);
        const dst_path = try std.fs.path.join(allocator, &.{ target, subdir });
        defer allocator.free(dst_path);

        symlinkToCache(allocator, src_path, dst_path) catch |err| {
            std.debug.print("labelle: could not link '{s}' to cache: {any}\n", .{ src_path, err });
            return error.CachePopulationFailed;
        };
    }
}

/// Validate that all dependencies in a project config are cached.
/// Returns a list of missing packages, or empty if all are cached.
pub fn validateCache(allocator: std.mem.Allocator, cfg: config.ProjectConfig) ![]const []const u8 {
    var missing: std.ArrayList([]const u8) = .{};

    // Framework packages
    const framework = [_]struct { name: []const u8, version: []const u8 }{
        .{ .name = "core", .version = cfg.core_version },
        .{ .name = "engine", .version = cfg.engine_version },
        .{ .name = "gfx", .version = cfg.gfx_version },
    };

    for (framework) |pkg| {
        if (!try isFrameworkCached(allocator, pkg.name, pkg.version)) {
            try missing.append(allocator, try std.fmt.allocPrint(allocator, "{s} {s}", .{ pkg.name, pkg.version }));
        }
    }

    // CLI-bundled packages
    if (!try isCliCached(allocator, cfg.labelle_version)) {
        try missing.append(allocator, try std.fmt.allocPrint(allocator, "cli {s}", .{cfg.labelle_version}));
    }

    // Plugins
    for (cfg.plugins) |plugin| {
        if (!try isPluginCached(allocator, plugin)) {
            try missing.append(allocator, try std.fmt.allocPrint(allocator, "plugin {s} {s}", .{ plugin.name, plugin.version }));
        }
    }

    return missing.toOwnedSlice(allocator);
}

/// Populate a framework package (core, engine, gfx) into the cache from a source directory.
/// Creates a symlink from the cache location to the source directory.
pub fn populateFrameworkPackage(allocator: std.mem.Allocator, package: []const u8, version: []const u8, source_dir: []const u8) !void {
    const target = try resolveFrameworkPackage(allocator, package, version, null);
    defer allocator.free(target);
    try symlinkToCache(allocator, source_dir, target);
}

/// Populate a plugin into the cache from a source directory.
/// Creates a symlink from the cache location to the source directory.
pub fn populatePlugin(allocator: std.mem.Allocator, plugin: config.PluginDep, source_dir: []const u8) !void {
    const target = try resolvePlugin(allocator, plugin, null);
    defer allocator.free(target);
    try symlinkToCache(allocator, source_dir, target);
}

// ── Remote fetching ──────────────────────────────────────────────────

/// Known GitHub repos for first-party framework packages.
const FRAMEWORK_REPOS = [_]struct { name: []const u8, repo: []const u8 }{
    .{ .name = "core", .repo = "github.com/labelle-toolkit/labelle-core" },
    .{ .name = "engine", .repo = "github.com/labelle-toolkit/labelle-engine" },
    .{ .name = "gfx", .repo = "github.com/labelle-toolkit/labelle-gfx" },
};

/// R2 base URL for CLI releases (binary + bundled packages).
pub const R2_BASE_URL = "https://releases.labelle.games/cli";

/// Fetch a framework package from its git repo at a given version tag.
/// Clones into the cache directory.
pub fn fetchFrameworkPackage(allocator: std.mem.Allocator, package: []const u8, version: []const u8) !void {
    // Find the repo URL
    var repo_url: ?[]const u8 = null;
    for (FRAMEWORK_REPOS) |fw| {
        if (std.mem.eql(u8, fw.name, package)) {
            repo_url = fw.repo;
            break;
        }
    }

    if (repo_url == null) {
        std.debug.print("labelle: unknown framework package '{s}'\n", .{package});
        return error.UnknownPackage;
    }

    const target = try resolveFrameworkPackage(allocator, package, version, null);
    defer allocator.free(target);

    const git_url = try std.fmt.allocPrint(allocator, "https://{s}.git", .{repo_url.?});
    defer allocator.free(git_url);

    const tag = try std.fmt.allocPrint(allocator, "v{s}", .{version});
    defer allocator.free(tag);

    try gitCloneShallow(allocator, git_url, tag, target);
}

/// Fetch a plugin from its git repo at a given version tag.
pub fn fetchPlugin(allocator: std.mem.Allocator, plugin: config.PluginDep) !void {
    const target = try resolvePlugin(allocator, plugin, null);
    defer allocator.free(target);

    const git_url = try std.fmt.allocPrint(allocator, "https://{s}.git", .{plugin.repo});
    defer allocator.free(git_url);

    const tag = try std.fmt.allocPrint(allocator, "v{s}", .{plugin.version});
    defer allocator.free(tag);

    try gitCloneShallow(allocator, git_url, tag, target);
}

/// Fetch CLI-bundled packages (backends, ecs, gui) into the cache.
/// Clones from the labelle-cli repo at the matching tag.
/// These packages are bundled with the CLI and normally populated from the companion directory.
/// Remote fetching is a fallback for when the companion directory is not available.
pub fn fetchCliPackages(allocator: std.mem.Allocator, cli_version: []const u8) !void {
    const packages_dir = try getPackagesDir(allocator);
    defer allocator.free(packages_dir);

    const target = try std.fs.path.join(allocator, &.{ packages_dir, "cli", cli_version });
    defer allocator.free(target);

    const git_url = "https://github.com/labelle-toolkit/labelle-cli.git";
    const tag = try std.fmt.allocPrint(allocator, "v{s}", .{cli_version});
    defer allocator.free(tag);

    const tmp_dir = try getTempPath(allocator, "labelle-cli-fetch", cli_version);
    defer allocator.free(tmp_dir);

    // Clean up any previous attempt
    std.fs.cwd().deleteTree(tmp_dir) catch {};

    gitCloneShallow(allocator, git_url, tag, tmp_dir) catch {
        std.debug.print("labelle: could not fetch cli packages at v{s}\n", .{cli_version});
        std.debug.print("  cli-bundled packages (backends, ecs, gui) ship with the CLI binary.\n", .{});
        std.debug.print("  run 'labelle update' to get the latest CLI with bundled packages.\n", .{});
        return error.FetchFailed;
    };

    // Copy backends/, ecs/, gui/ from the clone into the cache
    const cwd = std.fs.cwd();
    cwd.makePath(target) catch {};

    const subdirs = [_][]const u8{ "backends", "ecs", "gui" };
    for (subdirs) |subdir| {
        const src = try std.fs.path.join(allocator, &.{ tmp_dir, subdir });
        defer allocator.free(src);
        const dst = try std.fs.path.join(allocator, &.{ target, subdir });
        defer allocator.free(dst);

        copyDirRecursive(allocator, src, dst) catch |err| {
            std.debug.print("labelle: warning: could not copy {s}: {any}\n", .{ subdir, err });
        };
    }

    // Clean up temp clone
    std.fs.cwd().deleteTree(tmp_dir) catch {};
}

/// Shallow clone a git repo at a specific tag into the target directory.
fn gitCloneShallow(allocator: std.mem.Allocator, repo_url: []const u8, tag: []const u8, target: []const u8) !void {
    // Ensure parent directory exists
    if (std.fs.path.dirname(target)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "git", "clone", "--depth", "1", "--branch", tag, repo_url, target,
        },
    }) catch |err| {
        std.debug.print("labelle: git clone failed (is git installed?): {any}\n", .{err});
        return error.FetchFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("labelle: git clone failed:\n{s}\n", .{result.stderr});
            return error.FetchFailed;
        },
        else => {
            std.debug.print("labelle: git clone terminated abnormally\n", .{});
            return error.FetchFailed;
        },
    }

    // Remove .git directory to save space
    const git_dir = try std.fs.path.join(allocator, &.{ target, ".git" });
    defer allocator.free(git_dir);
    std.fs.cwd().deleteTree(git_dir) catch {};
}

// ── Internal helpers ─────────────────────────────────────────────────

/// Create a symlink from cache target to source directory.
/// The source_dir must be an absolute path (resolved via realpath).
/// Creates parent directories as needed.
fn symlinkToCache(allocator: std.mem.Allocator, source_dir: []const u8, target: []const u8) !void {
    const cwd = std.fs.cwd();

    // Resolve source to absolute path
    const abs_source = cwd.realpathAlloc(allocator, source_dir) catch |err| {
        std.debug.print("labelle: source directory not found '{s}': {any}\n", .{ source_dir, err });
        return error.CachePopulationFailed;
    };
    defer allocator.free(abs_source);

    // Ensure parent directory exists
    if (std.fs.path.dirname(target)) |parent| {
        cwd.makePath(parent) catch |err| {
            std.debug.print("labelle: could not create cache directory '{s}': {any}\n", .{ parent, err });
            return error.CachePopulationFailed;
        };
    }

    // Create symlink (absolute target → source), fall back to copy on failure
    // (Windows requires admin/Developer Mode for symlinks)
    cwd.symLink(abs_source, target, .{ .is_directory = true }) catch |err| {
        if (err == error.PathAlreadyExists) {
            // Verify the existing entry points to the expected source
            var link_buf: [std.fs.max_path_bytes]u8 = undefined;
            const existing = std.fs.readLinkAbsolute(target, &link_buf) catch return; // not a symlink, assume OK
            if (!std.mem.eql(u8, existing, abs_source)) {
                std.debug.print("labelle: warning: cache entry '{s}' points to '{s}', expected '{s}'\n", .{ target, existing, abs_source });
                // Remove stale link and recreate
                cwd.deleteFile(target) catch return;
                cwd.symLink(abs_source, target, .{ .is_directory = true }) catch return;
            }
            return;
        }
        // Fall back to copying the directory
        copyDirRecursive(allocator, abs_source, target) catch |copy_err| {
            std.debug.print("labelle: could not link or copy '{s}' to '{s}': {any}\n", .{ abs_source, target, copy_err });
            return error.CachePopulationFailed;
        };
    };
}

/// Get a platform-aware temporary directory path.
/// Uses TEMP/TMP on Windows, /tmp on Unix.
fn getTempPath(allocator: std.mem.Allocator, prefix: []const u8, suffix: []const u8) ![]const u8 {
    const tmp_base = if (builtin.os.tag == .windows)
        std.process.getEnvVarOwned(allocator, "TEMP") catch
            std.process.getEnvVarOwned(allocator, "TMP") catch
            try allocator.dupe(u8, "C:\\Windows\\Temp")
    else
        try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmp_base);

    return try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}-{s}", .{ tmp_base, prefix, suffix });
}

fn dirExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

// ── Cache patching ───────────────────────────────────────────────────

/// Patch build.zig.zon files in cached packages to rewrite sibling path deps
/// (e.g. `../labelle-core`) to point to other cached packages.
/// Must be called after all framework packages are cached.
pub fn patchCachedDeps(allocator: std.mem.Allocator, cfg: config.ProjectConfig) !void {
    // Only patch non-local packages
    const packages = [_]struct { name: []const u8, version: []const u8 }{
        .{ .name = "engine", .version = cfg.engine_version },
        .{ .name = "gfx", .version = cfg.gfx_version },
    };

    for (packages) |pkg| {
        if (config.isLocalVersion(pkg.version)) continue;

        const pkg_dir = try resolveFrameworkPackage(allocator, pkg.name, pkg.version, null);
        defer allocator.free(pkg_dir);

        // Never patch symlinked packages — they point to local repos that must not be mutated.
        if (isSymlink(pkg_dir)) continue;

        // Patch the main build.zig.zon (root: core is sibling → "../labelle-core")
        try patchZonFile(allocator, pkg_dir, "build.zig.zon", false);

        // Patch subpackage build.zig.zon files (scene/, camera/, etc.)
        // Subpackages are one level deeper → "../../labelle-core"
        var dir = std.fs.cwd().openDir(pkg_dir, .{ .iterate = true }) catch continue;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;
            const sub_zon = try std.fs.path.join(allocator, &.{ pkg_dir, entry.name, "build.zig.zon" });
            defer allocator.free(sub_zon);
            if (std.fs.cwd().access(sub_zon, .{})) |_| {
                const sub_dir = try std.fs.path.join(allocator, &.{ pkg_dir, entry.name });
                defer allocator.free(sub_dir);
                try patchZonFile(allocator, sub_dir, "build.zig.zon", true);
            } else |_| {}
        }
    }
}

/// Patch a single build.zig.zon file in the global cache, rewriting
/// labelle-core path deps to work after deps_linker hardlinks the package
/// into .labelle/deps/ alongside core. In the deps layout, packages are
/// siblings, so core is at "../labelle-core" from a root package or
/// "../../labelle-core" from a subpackage (scene/, camera/).
fn patchZonFile(allocator: std.mem.Allocator, dir_path: []const u8, filename: []const u8, is_subpackage: bool) !void {
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, filename });
    defer allocator.free(file_path);

    const content = std.fs.cwd().readFileAlloc(allocator, file_path, 256 * 1024) catch return;
    defer allocator.free(content);

    // After deps_linker, all packages are siblings under .labelle/deps/.
    // Root build.zig.zon: core is at "../labelle-core"
    // Subpackage build.zig.zon (scene/, camera/): core is at "../../labelle-core"
    const target = if (is_subpackage) "../../labelle-core" else "../labelle-core";

    // Normalize all core path variants to the correct target for this depth.
    // Use a placeholder to avoid "../labelle-core" matching inside "../../labelle-core".
    var result = try allocator.dupe(u8, content);
    const step1 = try replaceAll(allocator, result, "../../labelle-core", "\x00CORE_REF\x00");
    allocator.free(result);
    const step2 = try replaceAll(allocator, step1, "../labelle-core", "\x00CORE_REF\x00");
    allocator.free(step1);
    const step3 = try replaceAll(allocator, step2, "\x00CORE_REF\x00", target);
    allocator.free(step2);
    result = step3;

    // Only write if changed
    if (!std.mem.eql(u8, content, result)) {
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(result);
    }
    allocator.free(result);
}

/// Simple string replace-all helper.
fn replaceAll(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    var list = std.ArrayList(u8){};
    var i: usize = 0;
    while (i < haystack.len) {
        if (i + needle.len <= haystack.len and std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
            try list.appendSlice(allocator, replacement);
            i += needle.len;
        } else {
            try list.append(allocator, haystack[i]);
            i += 1;
        }
    }
    return list.toOwnedSlice(allocator);
}

/// Check if a path is a symlink.
fn isSymlink(path: []const u8) bool {
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.fs.readLinkAbsolute(path, &link_buf) catch return false;
    return true;
}

/// Recursively copy a directory tree.
pub fn copyDirRecursive(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const cwd = std.fs.cwd();
    cwd.makePath(dst) catch {};

    var src_dir = try cwd.openDir(src, .{ .iterate = true });
    defer src_dir.close();

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        const src_sub = try std.fs.path.join(allocator, &.{ src, entry.name });
        defer allocator.free(src_sub);
        const dst_sub = try std.fs.path.join(allocator, &.{ dst, entry.name });
        defer allocator.free(dst_sub);

        switch (entry.kind) {
            .directory => try copyDirRecursive(allocator, src_sub, dst_sub),
            .file => {
                cwd.copyFile(src_sub, cwd, dst_sub, .{}) catch |err| {
                    std.debug.print("labelle: could not copy '{s}': {any}\n", .{ src_sub, err });
                    return err;
                };
            },
            else => {},
        }
    }
}
