const std = @import("std");
const gen = @import("generator");
const config = @import("config.zig");

/// Remove unused cached package versions from ~/.labelle/packages/.
pub fn cmdClean(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    var dry_run = false;
    var project_dir: []const u8 = ".";
    for (cmd_args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.startsWith(u8, arg, "--project=")) {
            project_dir = arg["--project=".len..];
        } else {
            std.debug.print("labelle clean: unknown option '{s}'\n", .{arg});
            std.debug.print("  usage: labelle clean [--dry-run] [--project=<dir>]\n", .{});
            return error.InvalidArgument;
        }
    }

    const packages_dir = gen.getPackagesDir(allocator) catch {
        std.debug.print("labelle: could not determine packages directory\n", .{});
        return;
    };
    defer allocator.free(packages_dir);

    std.debug.print("labelle: scanning {s}...\n", .{packages_dir});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var kept = std.StringHashMap(std.StringHashMap(void)).init(arena_alloc);

    const pkg_names = [_][]const u8{ "core", "engine", "gfx", "cli" };
    const default_versions = [_][]const u8{ gen.CORE_VERSION, gen.ENGINE_VERSION, gen.GFX_VERSION, gen.CLI_VERSION };

    for (pkg_names, 0..) |name, i| {
        var version_set = std.StringHashMap(void).init(arena_alloc);
        try version_set.put(default_versions[i], {});
        try kept.put(name, version_set);
    }

    var project_arena = std.heap.ArenaAllocator.init(allocator);
    defer project_arena.deinit();
    if (config.readProjectConfigQuiet(project_arena.allocator(), project_dir)) |cfg| {
        const project_refs = [_]struct { name: []const u8, version: []const u8 }{
            .{ .name = "core", .version = cfg.core_version },
            .{ .name = "engine", .version = cfg.engine_version },
            .{ .name = "gfx", .version = cfg.gfx_version },
            .{ .name = "cli", .version = cfg.labelle_version },
        };
        for (project_refs) |ref| {
            if (gen.isLocalVersion(ref.version)) continue;
            if (kept.getPtr(ref.name)) |set| {
                try set.put(ref.version, {});
            }
        }
        std.debug.print("  found project.labelle in '{s}'\n", .{project_dir});
    } else |_| {
        std.debug.print("  no project.labelle found — keeping CLI default versions only\n", .{});
    }

    var removed_count: u32 = 0;

    for (pkg_names) |pkg_name| {
        const pkg_dir_path = std.fs.path.join(arena_alloc, &.{ packages_dir, pkg_name }) catch continue;

        var pkg_dir = std.fs.cwd().openDir(pkg_dir_path, .{ .iterate = true }) catch continue;
        defer pkg_dir.close();

        const version_set = kept.get(pkg_name) orelse continue;

        var iter = pkg_dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .directory and entry.kind != .sym_link) continue;

            if (version_set.contains(entry.name)) continue;

            if (dry_run) {
                std.debug.print("  would remove {s}/{s}\n", .{ pkg_name, entry.name });
            } else {
                const full_path = std.fs.path.join(arena_alloc, &.{ pkg_dir_path, entry.name }) catch continue;

                if (entry.kind == .sym_link) {
                    std.fs.cwd().deleteFile(full_path) catch |err| {
                        std.debug.print("  could not remove {s}/{s}: {any}\n", .{ pkg_name, entry.name, err });
                        continue;
                    };
                } else {
                    std.fs.cwd().deleteTree(full_path) catch |err| {
                        std.debug.print("  could not remove {s}/{s}: {any}\n", .{ pkg_name, entry.name, err });
                        continue;
                    };
                }
                std.debug.print("  removed {s}/{s}\n", .{ pkg_name, entry.name });
            }
            removed_count += 1;
        }
    }

    if (removed_count == 0) {
        std.debug.print("  nothing to clean\n", .{});
    } else if (dry_run) {
        std.debug.print("  {d} version(s) would be removed (use without --dry-run to delete)\n", .{removed_count});
    } else {
        std.debug.print("  cleaned {d} old version(s)\n", .{removed_count});
    }
}
