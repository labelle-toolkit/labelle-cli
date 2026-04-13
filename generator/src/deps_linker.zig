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

    // Rewrite relative .path deps in local plugins' build.zig.zon files.
    // After hardlinking, the paths still point relative to the original location
    // which is wrong from .labelle/deps/. Resolve each path against the original
    // abs location and recompute the relative path from the new dest location.
    for (cfg.plugins) |plugin| {
        if (!plugin.isLocal()) continue;

        const link_name = try std.fmt.allocPrint(allocator, "labelle-{s}", .{plugin.name});
        defer allocator.free(link_name);

        const dest = try std.fs.path.join(allocator, &.{ deps_dir, link_name });
        defer allocator.free(dest);

        const plugin_path = try cache.resolvePlugin(allocator, plugin, project_dir);
        defer allocator.free(plugin_path);

        const abs_src = cwd.realpathAlloc(allocator, plugin_path) catch continue;
        defer allocator.free(abs_src);

        const abs_dest = cwd.realpathAlloc(allocator, dest) catch continue;
        defer allocator.free(abs_dest);

        try rewriteZonPaths(allocator, abs_src, abs_dest);
    }

    // Also rewrite GUI plugin/bridge paths — the GUI is resolved separately
    // from cfg.plugins but may also have local .path deps.
    // rewriteZonPaths is a no-op if no .path entries exist, so always safe to call.
    if (cfg.resolved_gui) |gui| {
        try rewriteLocalDep(allocator, cwd, gui.plugin_dir, deps_dir, "labelle-gui");
        if (gui.bridge_dir) |bd|
            try rewriteLocalDep(allocator, cwd, bd, deps_dir, "gui-bridge");
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

/// Resolve src/dest to absolute paths and call rewriteZonPaths.
fn rewriteLocalDep(allocator: std.mem.Allocator, cwd: std.fs.Dir, src_path: []const u8, deps_dir: []const u8, link_name: []const u8) !void {
    const dest = try std.fs.path.join(allocator, &.{ deps_dir, link_name });
    defer allocator.free(dest);
    const abs_src = cwd.realpathAlloc(allocator, src_path) catch return;
    defer allocator.free(abs_src);
    const abs_dest = cwd.realpathAlloc(allocator, dest) catch return;
    defer allocator.free(abs_dest);
    try rewriteZonPaths(allocator, abs_src, abs_dest);
}

/// Rewrite relative `.path` dependencies in a hardlinked build.zig.zon.
/// `src_dir` is the original absolute path of the package.
/// `dest_dir` is the new absolute path under .labelle/deps/.
///
/// For each `.path = "../some/dep"` entry, resolves it against src_dir to get
/// the absolute target, then computes the relative path from dest_dir.
/// Writes via a temp file + rename to avoid corrupting the original hardlinked file.
fn rewriteZonPaths(allocator: std.mem.Allocator, src_dir: []const u8, dest_dir: []const u8) !void {
    const zon_path = try std.fs.path.join(allocator, &.{ dest_dir, "build.zig.zon" });
    defer allocator.free(zon_path);

    const content = std.fs.cwd().readFileAlloc(allocator, zon_path, 256 * 1024) catch |err| {
        std.debug.print("labelle: warning: could not read {s}: {any}\n", .{ zon_path, err });
        return;
    };
    defer allocator.free(content);

    // Quick check: skip files without relative .path deps
    if (std.mem.indexOf(u8, content, ".path") == null) return;

    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        // Look for `.path` token
        if (i + 5 <= content.len and std.mem.eql(u8, content[i..][0..5], ".path")) {
            const prefix_start = i;
            var j = i + 5;
            // skip whitespace after `.path`
            while (j < content.len and (content[j] == ' ' or content[j] == '\t')) j += 1;
            // expect `=`
            if (j < content.len and content[j] == '=') {
                j += 1;
                // skip whitespace after `=`
                while (j < content.len and (content[j] == ' ' or content[j] == '\t')) j += 1;
                // expect opening quote
                if (j < content.len and content[j] == '"') {
                    j += 1;
                    const path_start = j;
                    while (j < content.len and content[j] != '"') j += 1;
                    const rel_path = content[path_start..j];
                    if (j < content.len) j += 1; // skip closing quote
                    i = j;

                    // Only rewrite relative paths (starting with . or ..)
                    if (rel_path.len > 0 and rel_path[0] == '.') {
                        // Resolve against original source directory
                        const abs_target = try std.fs.path.join(allocator, &.{ src_dir, rel_path });
                        defer allocator.free(abs_target);

                        // Compute relative path from dest directory using std.fs.path
                        const new_rel = try computeRelativePath(allocator, dest_dir, abs_target);
                        defer allocator.free(new_rel);

                        try result.appendSlice(allocator, ".path = \"");
                        try result.appendSlice(allocator, new_rel);
                        try result.append(allocator, '"');
                        continue;
                    }
                    // Not relative — emit original text
                    try result.appendSlice(allocator, content[prefix_start..i]);
                    continue;
                }
            }
            // Not a `.path = "..."` pattern — emit as-is
            try result.appendSlice(allocator, content[prefix_start..j]);
            i = j;
            continue;
        }
        try result.append(allocator, content[i]);
        i += 1;
    }

    // Only write if changed
    if (!std.mem.eql(u8, content, result.items)) {
        const cwd = std.fs.cwd();

        // Delete the hardlink first so we never rewrite the original package file.
        cwd.deleteFile(zon_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        // Write via temp file + rename for atomicity.
        const tmp_path = try std.fs.path.join(allocator, &.{ dest_dir, "build.zig.zon.tmp" });
        defer allocator.free(tmp_path);

        cwd.deleteFile(tmp_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        const file = try cwd.createFile(tmp_path, .{});
        defer file.close();
        try file.writeAll(result.items);

        try cwd.rename(tmp_path, zon_path);
    }
}

/// Compute a relative path from `from_dir` to `to_path`.
/// Uses std.fs.path.relative for cross-platform correctness, then
/// normalizes to forward slashes for ZON portability.
fn computeRelativePath(allocator: std.mem.Allocator, from_dir: []const u8, to_path: []const u8) ![]u8 {
    // Resolve `..` components in to_path before computing relative path.
    const resolved_to = try std.fs.path.resolve(allocator, &.{to_path});
    defer allocator.free(resolved_to);

    const rel = try std.fs.path.relative(allocator, from_dir, resolved_to);

    // ZON files should always use forward slashes.
    if (comptime @import("builtin").os.tag == .windows) {
        for (rel) |*c| if (c.* == '\\') {
            c.* = '/';
        };
    }
    return rel;
}

// ── Tests ────────────────────────────────────────────────────────────

test "computeRelativePath: sibling directories" {
    const alloc = std.testing.allocator;
    const result = try computeRelativePath(alloc, "/home/user/project/.labelle/deps/labelle-needs_machine", "/home/user/labelle-fsm");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("../../../../labelle-fsm", result);
}

test "computeRelativePath: same parent" {
    const alloc = std.testing.allocator;
    const result = try computeRelativePath(alloc, "/a/b/deps/pkg1", "/a/b/deps/pkg2");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("../pkg2", result);
}

test "computeRelativePath: child directory" {
    const alloc = std.testing.allocator;
    const result = try computeRelativePath(alloc, "/a/b", "/a/b/c/d");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("c/d", result);
}

test "computeRelativePath: resolves dot-dot in target" {
    const alloc = std.testing.allocator;
    const result = try computeRelativePath(alloc, "/a/b", "/a/b/c/../d");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("d", result);
}

test "rewriteZonPaths: rewrites relative path deps" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("project/libs/needs_machine");
    try tmp.dir.makePath("project/.labelle/deps/labelle-needs_machine");
    try tmp.dir.makePath("labelle-fsm");

    const zon_content =
        \\.{
        \\    .name = .test_pkg,
        \\    .dependencies = .{
        \\        .@"labelle-fsm" = .{
        \\            .path = "../../../labelle-fsm",
        \\        },
        \\        .@"labelle-core" = .{
        \\            .url = "https://example.com/core.tar.gz",
        \\            .hash = "abc123",
        \\        },
        \\    },
        \\}
    ;

    const dest_zon = try tmp.dir.createFile("project/.labelle/deps/labelle-needs_machine/build.zig.zon", .{});
    defer dest_zon.close();
    try dest_zon.writeAll(zon_content);

    const src_abs = try tmp.dir.realpathAlloc(alloc, "project/libs/needs_machine");
    defer alloc.free(src_abs);
    const dest_abs = try tmp.dir.realpathAlloc(alloc, "project/.labelle/deps/labelle-needs_machine");
    defer alloc.free(dest_abs);

    try rewriteZonPaths(alloc, src_abs, dest_abs);

    const result = try tmp.dir.readFileAlloc(alloc, "project/.labelle/deps/labelle-needs_machine/build.zig.zon", 64 * 1024);
    defer alloc.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, ".url = \"https://example.com/core.tar.gz\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"../../../labelle-fsm\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, ".path = \"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "../../../../labelle-fsm") != null);
}

test "rewriteZonPaths: skips files without .path deps" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    try tmp.dir.makePath("dest");

    const zon_content =
        \\.{
        \\    .name = .test_pkg,
        \\    .dependencies = .{
        \\        .@"labelle-core" = .{
        \\            .url = "https://example.com/core.tar.gz",
        \\            .hash = "abc123",
        \\        },
        \\    },
        \\}
    ;

    const dest_zon = try tmp.dir.createFile("dest/build.zig.zon", .{});
    defer dest_zon.close();
    try dest_zon.writeAll(zon_content);

    const src_abs = try tmp.dir.realpathAlloc(alloc, "src");
    defer alloc.free(src_abs);
    const dest_abs = try tmp.dir.realpathAlloc(alloc, "dest");
    defer alloc.free(dest_abs);

    try rewriteZonPaths(alloc, src_abs, dest_abs);

    const result = try tmp.dir.readFileAlloc(alloc, "dest/build.zig.zon", 64 * 1024);
    defer alloc.free(result);
    try std.testing.expectEqualStrings(zon_content, result);
}
