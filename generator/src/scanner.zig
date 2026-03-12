/// File scanning and directory copy utilities for the labelle-cli generator.
const std = @import("std");

pub fn freeNames(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

/// Copy files from src_base/folder to dst_base/folder and return sorted file stems
/// matching the given extension. Combines the old copyDir + scanFiles in one pass.
pub fn copyAndScan(allocator: std.mem.Allocator, src_base: []const u8, dst_base: []const u8, folder: []const u8, ext: []const u8) ![][]const u8 {
    const cwd = std.fs.cwd();

    const src_path = try std.fs.path.join(allocator, &.{ src_base, folder });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ dst_base, folder });
    defer allocator.free(dst_path);

    try cwd.makePath(dst_path);

    var names: std.ArrayList([]const u8) = .{};
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var src_dir = cwd.openDir(src_path, .{ .iterate = true }) catch return names.toOwnedSlice(allocator);
    defer src_dir.close();
    var dst_dir = try cwd.openDir(dst_path, .{});
    defer dst_dir.close();

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, ".bridge.zig")) continue;

        // Copy file
        const content = try src_dir.readFileAlloc(allocator, entry.name, 1024 * 1024);
        defer allocator.free(content);
        const out_file = try dst_dir.createFile(entry.name, .{});
        defer out_file.close();
        try out_file.writeAll(content);

        // Collect stem if extension matches
        if (std.mem.endsWith(u8, entry.name, ext)) {
            const stem = try allocator.dupe(u8, entry.name[0 .. entry.name.len - ext.len]);
            try names.append(allocator, stem);
        }
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    return names.toOwnedSlice(allocator);
}

pub fn writeFile(dir_path: []const u8, filename: []const u8, content: []const u8) !void {
    const cwd = std.fs.cwd();
    var dir = try cwd.openDir(dir_path, .{});
    defer dir.close();
    const file = try dir.createFile(filename, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Copy a subdirectory from src_base/folder to dst_base/folder.
/// Copies all files (non-recursive, skips directories and .bridge.zig).
pub fn copyDir(allocator: std.mem.Allocator, src_base: []const u8, dst_base: []const u8, folder: []const u8) !void {
    const cwd = std.fs.cwd();

    const src_path = try std.fs.path.join(allocator, &.{ src_base, folder });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ dst_base, folder });
    defer allocator.free(dst_path);

    try cwd.makePath(dst_path);

    var src_dir = cwd.openDir(src_path, .{ .iterate = true }) catch return; // skip if doesn't exist
    defer src_dir.close();
    var dst_dir = try cwd.openDir(dst_path, .{});
    defer dst_dir.close();

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, ".bridge.zig")) continue; // skip old bridge files

        const content = try src_dir.readFileAlloc(allocator, entry.name, 1024 * 1024);
        defer allocator.free(content);

        const out_file = try dst_dir.createFile(entry.name, .{});
        defer out_file.close();
        try out_file.writeAll(content);
    }
}

/// Recursively copy a directory tree from src_base/folder to dst_base/folder.
/// Copies all files and subdirectories. Used for assets which have nested folders.
pub fn copyDirRecursive(allocator: std.mem.Allocator, src_base: []const u8, dst_base: []const u8, folder: []const u8) !void {
    const cwd = std.fs.cwd();

    const src_path = try std.fs.path.join(allocator, &.{ src_base, folder });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ dst_base, folder });
    defer allocator.free(dst_path);

    try cwd.makePath(dst_path);

    var src_dir = cwd.openDir(src_path, .{ .iterate = true }) catch return;
    defer src_dir.close();

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const content = try src_dir.readFileAlloc(allocator, entry.name, 10 * 1024 * 1024);
                defer allocator.free(content);

                var dst_dir = try cwd.openDir(dst_path, .{});
                defer dst_dir.close();
                const out_file = try dst_dir.createFile(entry.name, .{});
                defer out_file.close();
                try out_file.writeAll(content);
            },
            .directory => {
                const sub_folder = try std.fs.path.join(allocator, &.{ folder, entry.name });
                defer allocator.free(sub_folder);
                try copyDirRecursive(allocator, src_base, dst_base, sub_folder);
            },
            else => {},
        }
    }
}
