const std = @import("std");
const config = @import("config.zig");

pub fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(config.globalIo(), path, .{}) catch return false;
    return true;
}

pub fn dirExists(path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(config.globalIo(), path, .{}) catch return false;
    return stat.kind == .directory;
}

/// True if `data`'s SHA-256 equals the lowercase-hex `expected` (64 chars).
/// Pure — verifies provisioned-toolchain downloads before use.
pub fn sha256Matches(data: []const u8, expected_hex: []const u8) bool {
    if (expected_hex.len != 64) return false;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hexchars = "0123456789abcdef";
    var hex: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        hex[i * 2] = hexchars[b >> 4];
        hex[i * 2 + 1] = hexchars[b & 0x0f];
    }
    return std.mem.eql(u8, &hex, expected_hex);
}

test "sha256Matches verifies known vectors" {
    // SHA-256("abc") and SHA-256("")
    try std.testing.expect(sha256Matches("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
    try std.testing.expect(sha256Matches("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
    // wrong digest and wrong length both reject
    try std.testing.expect(!sha256Matches("abc", "0000000000000000000000000000000000000000000000000000000000000000"));
    try std.testing.expect(!sha256Matches("abc", "abcd"));
}

/// Get a platform-aware temporary file path.
pub fn getTempFilePath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const builtin = @import("builtin");
    const env = config.globalEnviron();
    const tmp_base: []const u8 = if (builtin.os.tag == .windows)
        env.getAlloc(allocator, "TEMP") catch
            env.getAlloc(allocator, "TMP") catch
            try allocator.dupe(u8, "C:\\Windows\\Temp")
    else
        try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmp_base);

    return try std.fs.path.join(allocator, &.{ tmp_base, name });
}

pub fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(allocator, config.globalIo(), .{
        .argv = argv,
    });
}

/// Sanitize a project name into the desktop-executable name the
/// assembler bakes into `build.zig` (labelle-assembler#362). The
/// assembler now names the desktop binary after the project so a running
/// game is identifiable by `pgrep -f <name>` instead of every project
/// building to an indistinguishable `zig-out/bin/game`. The `--docker`
/// run path execs the built binary by absolute path, so it must derive
/// the same name to locate it.
///
/// Keeps only `[A-Za-z0-9_-]` (byte-identical to the assembler's
/// `sanitizeExeName`); every other byte is dropped, falling back to
/// `"game"` when the result is empty. Caller owns the returned slice.
pub fn sanitizeExeName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (name) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (ok) try buf.append(allocator, c);
    }
    if (buf.items.len == 0) {
        // Allocate the fallback BEFORE freeing `buf`: if `dupe` OOMs, the
        // `errdefer` frees `buf` (once). Freeing `buf` first would let the
        // `errdefer` deinit it a second time on that OOM — a double free.
        const fallback = try allocator.dupe(u8, "game");
        buf.deinit(allocator);
        return fallback;
    }
    return buf.toOwnedSlice(allocator);
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
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    if (cwd.readFileAlloc(io, path, allocator, .limited(256 * 1024))) |content| {
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

    const file = cwd.openFile(io, path, .{ .mode = .read_write }) catch
        cwd.createFile(io, path, .{}) catch return false;
    defer file.close(io);

    // Use a small writer buffer; append-only short writes.
    var buf: [256]u8 = undefined;
    var w = file.writer(io, &buf);
    // Seek to end via positional length.
    const end = file.length(io) catch return false;
    w.seekTo(end) catch return false;
    w.interface.writeAll("\n# Added by labelle CLI\n") catch return false;
    w.interface.writeAll(line) catch return false;
    w.interface.writeAll("\n") catch return false;
    w.interface.flush() catch return false;
    return true;
}

/// Parse a duration string like "500ms", "30s", "2m", or bare "30" (seconds).
///
/// `ms` is matched before the single-char suffixes so that the help
/// text in `--after=<dur>` (which advertises `500ms`) actually works;
/// without this branch the trailing `s` would parse as seconds and the
/// leading `500m` would fail integer parsing.
pub fn parseDuration(input: []const u8) ?u64 {
    if (input.len == 0) return null;

    if (std.mem.endsWith(u8, input, "ms")) {
        const num_str = input[0 .. input.len - 2];
        const ms = std.fmt.parseInt(u64, num_str, 10) catch return null;
        return std.math.mul(u64, ms, std.time.ns_per_ms) catch return null;
    }

    const last = input[input.len - 1];
    const multiplier: u64 = switch (last) {
        's' => std.time.ns_per_s,
        'm' => std.time.ns_per_min,
        else => {
            const secs = std.fmt.parseInt(u64, input, 10) catch return null;
            return std.math.mul(u64, secs, std.time.ns_per_s) catch return null;
        },
    };

    const num_str = input[0 .. input.len - 1];
    const val = std.fmt.parseInt(u64, num_str, 10) catch return null;
    return std.math.mul(u64, val, multiplier) catch return null;
}

// --- Tests ---

/// `sanitizeExeName` must stay byte-identical to the assembler's helper
/// of the same name (labelle-assembler#362), so the docker run path
/// resolves the same `zig-out/bin/<name>` the build.zig produced.
pub const SanitizeExeName = struct {
    test "passes through a clean name" {
        const got = try sanitizeExeName(std.testing.allocator, "energy_flow");
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("energy_flow", got);
    }

    test "keeps hyphens and digits" {
        const got = try sanitizeExeName(std.testing.allocator, "my-game-2");
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("my-game-2", got);
    }

    test "drops spaces and punctuation" {
        const got = try sanitizeExeName(std.testing.allocator, "energy flow!");
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("energyflow", got);
    }

    test "falls back to game when nothing survives" {
        const got = try sanitizeExeName(std.testing.allocator, "!!!");
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings("game", got);
    }
};
