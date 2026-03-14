const std = @import("std");

pub fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn dirExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Get a platform-aware temporary file path.
pub fn getTempFilePath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const builtin = @import("builtin");
    const tmp_base: []const u8 = if (builtin.os.tag == .windows)
        std.process.getEnvVarOwned(allocator, "TEMP") catch
            std.process.getEnvVarOwned(allocator, "TMP") catch
            try allocator.dupe(u8, "C:\\Windows\\Temp")
    else
        try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmp_base);

    return try std.fs.path.join(allocator, &.{ tmp_base, name });
}

pub fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.Child.RunResult {
    return std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
}

/// Parse semantic version string into a comparable number.
/// "1.2.3" -> 1*1000000 + 2*1000 + 3 = 1002003
pub fn parseVersion(version: []const u8) u32 {
    var parts: [3]u32 = .{ 0, 0, 0 };
    var part_idx: u8 = 0;

    for (version) |c| {
        if (c == '.') {
            part_idx += 1;
            if (part_idx >= 3) break;
        } else if (c >= '0' and c <= '9') {
            parts[part_idx] = parts[part_idx] * 10 + (c - '0');
        }
    }

    return parts[0] * 1_000_000 + parts[1] * 1_000 + parts[2];
}

/// Check if a PATH string contains a specific directory as an exact segment.
pub fn pathContainsDir(path_var: []const u8, dir: []const u8) bool {
    var iter = std.mem.splitScalar(u8, path_var, ':');
    while (iter.next()) |segment| {
        if (std.mem.eql(u8, segment, dir)) return true;
        if (segment.len > 0 and segment[segment.len - 1] == '/' and
            std.mem.eql(u8, segment[0 .. segment.len - 1], dir)) return true;
    }
    return false;
}

/// Case-insensitive path comparison for Windows, normalizing both slash styles.
pub fn windowsPathEql(a: []const u8, b: []const u8) bool {
    const a_trimmed = if (a.len > 0 and (a[a.len - 1] == '/' or a[a.len - 1] == '\\')) a[0 .. a.len - 1] else a;
    const b_trimmed = if (b.len > 0 and (b[b.len - 1] == '/' or b[b.len - 1] == '\\')) b[0 .. b.len - 1] else b;
    if (a_trimmed.len != b_trimmed.len) return false;
    for (a_trimmed, 0..) |ac, i| {
        const bc = b_trimmed[i];
        const an = if (ac == '\\') @as(u8, '/') else std.ascii.toLower(ac);
        const bn = if (bc == '\\') @as(u8, '/') else std.ascii.toLower(bc);
        if (an != bn) return false;
    }
    return true;
}

/// Escape a string for use inside PowerShell single-quoted strings.
pub fn escapePowerShellString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var count: usize = 0;
    for (input) |c| {
        if (c == '\'') count += 1;
    }
    if (count == 0) return try allocator.dupe(u8, input);

    var result = try allocator.alloc(u8, input.len + count);
    var j: usize = 0;
    for (input) |c| {
        if (c == '\'') {
            result[j] = '\'';
            j += 1;
        }
        result[j] = c;
        j += 1;
    }
    return result;
}

/// Append a line to a shell profile file if it's not already present.
pub fn appendToProfile(allocator: std.mem.Allocator, path: []const u8, line: []const u8, bin_dir: []const u8) bool {
    if (std.fs.cwd().readFileAlloc(allocator, path, 256 * 1024)) |content| {
        defer allocator.free(content);
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |file_line| {
            const trimmed = std.mem.trim(u8, file_line, &std.ascii.whitespace);
            if (std.mem.startsWith(u8, trimmed, "#")) continue;
            if (std.mem.eql(u8, trimmed, line)) return false;
            if ((std.mem.startsWith(u8, trimmed, "export PATH=") or std.mem.startsWith(u8, trimmed, "PATH=")) and
                std.mem.indexOf(u8, trimmed, bin_dir) != null) return false;
        }
    } else |_| {}

    const file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch
        std.fs.cwd().createFile(path, .{}) catch return false;
    defer file.close();

    file.seekFromEnd(0) catch return false;
    file.writeAll("\n# Added by labelle CLI\n") catch return false;
    file.writeAll(line) catch return false;
    file.writeAll("\n") catch return false;
    return true;
}

/// Parse a duration string like "30s", "2m", or bare "30" (seconds).
pub fn parseDuration(input: []const u8) ?u64 {
    if (input.len == 0) return null;

    const last = input[input.len - 1];
    const multiplier: u64 = switch (last) {
        's' => std.time.ns_per_s,
        'm' => std.time.ns_per_min,
        else => {
            const secs = std.fmt.parseInt(u64, input, 10) catch return null;
            return secs * std.time.ns_per_s;
        },
    };

    const num_str = input[0 .. input.len - 1];
    const val = std.fmt.parseInt(u64, num_str, 10) catch return null;
    return val * multiplier;
}
