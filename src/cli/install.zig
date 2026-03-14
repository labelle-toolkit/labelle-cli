const std = @import("std");
const gen = @import("generator");
const config = @import("config.zig");
const cache = @import("cache.zig");

/// Fetch and cache packages without modifying any project.
pub fn cmdInstall(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    if (cmd_args.len == 0) {
        const parsed = config.readProjectConfig(allocator, ".") catch {
            std.debug.print("labelle install: no project.labelle found. Usage:\n", .{});
            std.debug.print("  labelle install              — install deps for current project\n", .{});
            std.debug.print("  labelle install <version>    — cache all packages at a version\n", .{});
            std.debug.print("  labelle install core <ver>   — cache a specific package\n", .{});
            return error.MissingArgument;
        };
        try cache.ensureCache(allocator, parsed);
        std.debug.print("labelle: all packages cached\n", .{});
        return;
    }

    if (cmd_args.len == 1) {
        const version = cmd_args[0];
        std.debug.print("labelle: caching all packages at version {s}...\n", .{version});

        const packages = [_][]const u8{ "core", "engine", "gfx" };
        for (packages) |pkg| {
            if (!try gen.isFrameworkCached(allocator, pkg, version)) {
                std.debug.print("  fetching {s} {s}...\n", .{ pkg, version });
                try cache.fetchFrameworkWithFallback(allocator, pkg, version);
            } else {
                std.debug.print("  {s} {s} already cached\n", .{ pkg, version });
            }
        }

        if (!try gen.isCliCached(allocator, version)) {
            std.debug.print("  fetching cli {s}...\n", .{version});
            try cache.fetchCliWithFallback(allocator, version);
        } else {
            std.debug.print("  cli {s} already cached\n", .{version});
        }

        std.debug.print("labelle: done\n", .{});
        return;
    }

    const pkg_name = cmd_args[0];
    const version = cmd_args[1];

    if (std.mem.eql(u8, pkg_name, "core") or std.mem.eql(u8, pkg_name, "engine") or std.mem.eql(u8, pkg_name, "gfx")) {
        std.debug.print("labelle: fetching {s} {s}...\n", .{ pkg_name, version });
        try cache.fetchFrameworkWithFallback(allocator, pkg_name, version);
    } else if (std.mem.eql(u8, pkg_name, "cli")) {
        std.debug.print("labelle: fetching cli {s}...\n", .{version});
        try cache.fetchCliWithFallback(allocator, version);
    } else {
        std.debug.print("labelle install: unknown package '{s}'\n", .{pkg_name});
        std.debug.print("  known packages: core, engine, gfx, cli\n", .{});
        return error.UnknownPackage;
    }

    std.debug.print("labelle: done\n", .{});
}
