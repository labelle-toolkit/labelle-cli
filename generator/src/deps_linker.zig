/// deps_linker — creates a deps/ directory with hardlinked copies of resolved packages.
/// Replaces long relative paths in build.zig.zon with short "deps/<name>" paths.
///
/// Uses hardlinks for files (works on all platforms without admin) and
/// creates directory structure manually. Falls back to file copy if
/// hardlinks fail (e.g. cross-device).
const std = @import("std");
const config = @import("config.zig");
const cache = @import("cache.zig");

const ProjectConfig = config.ProjectConfig;

pub const DepEntry = struct {
    zon_name: []const u8,
    link_name: []const u8,
    abs_path: []const u8,
};

pub fn createDepsLinks(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    target_dir: []const u8,
    project_dir: []const u8,
) ![]const DepEntry {
    var deps = std.ArrayList(DepEntry){};

    const core_path = try cache.resolveFrameworkPackage(allocator, "core", cfg.core_version, project_dir);
    try deps.append(allocator, .{ .zon_name = try allocator.dupe(u8, "labelle_core"), .link_name = try allocator.dupe(u8, "labelle-core"), .abs_path = core_path });

    const gfx_path = try cache.resolveFrameworkPackage(allocator, "gfx", cfg.gfx_version, project_dir);
    try deps.append(allocator, .{ .zon_name = try allocator.dupe(u8, "labelle_gfx"), .link_name = try allocator.dupe(u8, "labelle-gfx"), .abs_path = gfx_path });

    const engine_path = try cache.resolveFrameworkPackage(allocator, "engine", cfg.engine_version, project_dir);
    try deps.append(allocator, .{ .zon_name = try allocator.dupe(u8, "engine"), .link_name = try allocator.dupe(u8, "labelle-engine"), .abs_path = engine_path });

    for (cfg.plugins) |plugin| {
        const plugin_path = try cache.resolvePlugin(allocator, plugin, project_dir);
        const zon_name = try std.fmt.allocPrint(allocator, "labelle_{s}", .{plugin.name});
        const link_name = try std.fmt.allocPrint(allocator, "labelle-{s}", .{plugin.name});
        try deps.append(allocator, .{ .zon_name = zon_name, .link_name = link_name, .abs_path = plugin_path });
    }

    {
        const backend_name = @tagName(cfg.backend);
        var subpath_buf: [128]u8 = undefined;
        const subpath = std.fmt.bufPrint(&subpath_buf, "backends/{s}", .{backend_name}) catch unreachable;
        const backend_path = try cache.resolveCliPackage(allocator, cfg.labelle_version, project_dir, subpath);
        const zon_name = try std.fmt.allocPrint(allocator, "labelle_{s}", .{backend_name});
        const link_name = try std.fmt.allocPrint(allocator, "labelle-{s}", .{backend_name});
        try deps.append(allocator, .{ .zon_name = zon_name, .link_name = link_name, .abs_path = backend_path });
    }

    switch (cfg.ecs) {
        .mock => {},
        .zig_ecs, .zflecs, .mr_ecs => {
            const ecs_dep_name: []const u8 = switch (cfg.ecs) {
                .zig_ecs => "labelle_zig_ecs",
                .zflecs => "labelle_zflecs",
                .mr_ecs => "labelle_mr_ecs",
                .mock => unreachable,
            };
            const ecs_dir: []const u8 = switch (cfg.ecs) {
                .zig_ecs => "zig-ecs",
                .zflecs => "zflecs",
                .mr_ecs => "mr-ecs",
                .mock => unreachable,
            };
            var subpath_buf: [128]u8 = undefined;
            const subpath = std.fmt.bufPrint(&subpath_buf, "ecs/{s}", .{ecs_dir}) catch unreachable;
            const ecs_path = try cache.resolveCliPackage(allocator, cfg.labelle_version, project_dir, subpath);
            const ecs_link_name: []const u8 = switch (cfg.ecs) {
                .zig_ecs => "labelle-zig-ecs",
                .zflecs => "labelle-zflecs",
                .mr_ecs => "labelle-mr-ecs",
                .mock => unreachable,
            };
            try deps.append(allocator, .{ .zon_name = try allocator.dupe(u8, ecs_dep_name), .link_name = try allocator.dupe(u8, ecs_link_name), .abs_path = ecs_path });
        },
    }

    if (cfg.resolved_gui) |gui| {
        try deps.append(allocator, .{ .zon_name = try allocator.dupe(u8, "labelle_gui"), .link_name = try allocator.dupe(u8, "labelle-gui"), .abs_path = try allocator.dupe(u8, gui.plugin_dir) });
        if (gui.bridge_dir) |bd| {
            try deps.append(allocator, .{ .zon_name = try allocator.dupe(u8, "gui_bridge"), .link_name = try allocator.dupe(u8, "gui-bridge"), .abs_path = try allocator.dupe(u8, bd) });
        }
    }

    // Create deps/ directory with hardlinked copies
    const cwd = std.fs.cwd();
    const deps_dir = try std.fs.path.join(allocator, &.{ target_dir, "deps" });
    defer allocator.free(deps_dir);

    cwd.deleteTree(deps_dir) catch {};
    try cwd.makePath(deps_dir);

    for (deps.items) |dep| {
        const dest = try std.fs.path.join(allocator, &.{ deps_dir, dep.link_name });
        defer allocator.free(dest);

        const abs = cwd.realpathAlloc(allocator, dep.abs_path) catch dep.abs_path;
        defer if (abs.ptr != dep.abs_path.ptr) allocator.free(abs);

        try hardlinkTree(allocator, abs, dest);
    }

    return deps.toOwnedSlice(allocator);
}

/// Free all DepEntry fields and the slice itself.
pub fn freeDepEntries(allocator: std.mem.Allocator, deps: []const DepEntry) void {
    for (deps) |dep| {
        allocator.free(dep.zon_name);
        allocator.free(dep.link_name);
        allocator.free(dep.abs_path);
    }
    allocator.free(deps);
}

/// Recursively hardlink a directory tree. Creates directories, hardlinks files.
/// Falls back to copy for files that can't be hardlinked (cross-device).
fn hardlinkTree(allocator: std.mem.Allocator, src_path: []const u8, dest_path: []const u8) !void {
    const cwd = std.fs.cwd();
    try cwd.makePath(dest_path);

    var src_dir = try cwd.openDir(src_path, .{ .iterate = true });
    defer src_dir.close();

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        const src_sub = try std.fs.path.join(allocator, &.{ src_path, entry.name });
        defer allocator.free(src_sub);
        const dest_sub = try std.fs.path.join(allocator, &.{ dest_path, entry.name });
        defer allocator.free(dest_sub);

        switch (entry.kind) {
            .directory => {
                // Skip .zig-cache and zig-out inside packages
                if (std.mem.eql(u8, entry.name, ".zig-cache") or
                    std.mem.eql(u8, entry.name, "zig-out") or
                    std.mem.eql(u8, entry.name, ".git"))
                    continue;

                try hardlinkTree(allocator, src_sub, dest_sub);
            },
            .file => {
                try hardlinkOrCopy(src_sub, dest_sub);
            },
            .sym_link => {
                // Read symlink target and recreate it
                var target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const target = src_dir.readLink(entry.name, &target_buf) catch continue;
                cwd.symLink(target, dest_sub, .{}) catch {};
            },
            else => {},
        }
    }
}

/// Create a hardlink, falling back to copy if hardlinks aren't supported
/// (cross-device, Windows without NTFS, etc).
/// Create a hardlink, falling back to copy. Works on macOS, Linux, and Windows.
/// Hardlinks share disk space (zero cost) and work without admin privileges.
fn hardlinkOrCopy(src: []const u8, dest: []const u8) !void {
    const cwd = std.fs.cwd();
    const builtin = @import("builtin");

    if (comptime builtin.os.tag == .windows) {
        // Windows: use CreateHardLinkW from kernel32
        windowsHardLink(src, dest) catch {
            try cwd.copyFile(src, cwd, dest, .{});
        };
    } else {
        // POSIX: link() syscall
        std.posix.link(src, dest) catch {
            try cwd.copyFile(src, cwd, dest, .{});
        };
    }
}

/// Windows hardlink via kernel32.CreateHardLinkW.
/// Works on NTFS without admin privileges.
fn windowsHardLink(src: []const u8, dest: []const u8) !void {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag != .windows) unreachable;

    const windows = std.os.windows;
    const src_w = try windows.sliceToPrefixedFileW(null, src);
    const dest_w = try windows.sliceToPrefixedFileW(null, dest);

    const result = CreateHardLinkW(dest_w.span().ptr, src_w.span().ptr, null);
    if (result == 0) return error.PermissionDenied;
}

extern "kernel32" fn CreateHardLinkW(
    lpFileName: [*:0]const u16,
    lpExistingFileName: [*:0]const u16,
    lpSecurityAttributes: ?*anyopaque,
) callconv(.winapi) c_int;
