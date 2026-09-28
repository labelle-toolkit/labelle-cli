//! "Last successful output" publication for a watch session (RFC cli#466
//! §3.4, contract §2 `run.watch`). A rebuild writes into the ordinary
//! staging tree; only once it has FULLY succeeded does the session publish:
//!
//! 1. copy the staged tree into a fresh `<root>/published-<n>/`;
//! 2. switch `<root>/current` (the `run.watch.output_dir` the running
//!    replacement serves) to it in one atomic step;
//! 3. only then advance `<root>/generation` (write a temporary file, then
//!    rename it over the old one).
//!
//! A consumer that polls `generation` and then reads `current` therefore
//! never sees a generation whose output is not complete, and a failed
//! rebuild — which never reaches `publish` — leaves both untouched.
//!
//! The switch is atomic on every host:
//! - POSIX: `current` is a relative symbolic link; a new link is created
//!   under a temporary name and renamed over it (`rename(2)` replaces the
//!   old link atomically).
//! - Windows: `current` is a directory junction (no privilege needed, unlike
//!   a symbolic link) whose reparse data is REWRITTEN IN PLACE with
//!   `FSCTL_SET_REPARSE_POINT`, one filesystem operation: a path lookup
//!   resolves either the old or the new target. Should the in-place rewrite
//!   be refused, the junction is removed and recreated, which is not atomic
//!   and is reported once.
//!
//! The previous published directory is kept (a request may still be
//! reading it through a resolved path); older ones are deleted after each
//! publication, and the whole `<root>` when the session ends.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");

const is_windows = builtin.os.tag == .windows;

pub const Publisher = struct {
    allocator: std.mem.Allocator,
    /// Absolute session directory; owned.
    root: []const u8,
    /// Absolute staged output tree a rebuild writes; borrowed.
    source: []const u8,
    /// `<root>/current`, the `run.watch.output_dir`; owned.
    output_dir: []const u8,
    /// `<root>/generation`, the `run.watch.generation_file`; owned.
    generation_file: []const u8,
    /// The last published generation; `null` before the first.
    generation: ?u64 = null,
    /// Set once the non-atomic Windows fallback had to be used.
    fallback_noted: bool = false,

    /// Start a session at `root`: whatever an earlier session left there is
    /// removed first.
    pub fn init(allocator: std.mem.Allocator, root: []const u8, source: []const u8) !Publisher {
        const io = config.globalIo();
        std.Io.Dir.cwd().deleteTree(io, root) catch {};
        try std.Io.Dir.cwd().createDirPath(io, root);
        const owned_root = try allocator.dupe(u8, root);
        errdefer allocator.free(owned_root);
        const output_dir = try std.fs.path.join(allocator, &.{ root, "current" });
        errdefer allocator.free(output_dir);
        const generation_file = try std.fs.path.join(allocator, &.{ root, "generation" });
        return .{ .allocator = allocator, .root = owned_root, .source = source, .output_dir = output_dir, .generation_file = generation_file };
    }

    /// Release the paths; `remove` also deletes the session directory.
    pub fn deinit(self: *Publisher, remove: bool) void {
        if (remove) std.Io.Dir.cwd().deleteTree(config.globalIo(), self.root) catch |err| {
            std.debug.print("labelle: could not remove the watch session directory '{s}': {s}\n", .{ self.root, @errorName(err) });
        };
        self.allocator.free(self.root);
        self.allocator.free(self.output_dir);
        self.allocator.free(self.generation_file);
    }

    /// The generation the next `publish` writes.
    pub fn next(self: *const Publisher) u64 {
        return if (self.generation) |g| g + 1 else 0;
    }

    /// Publish the staged tree as the next generation (0 first). On any
    /// error nothing observable changed: `current` and `generation` still
    /// name the previous publication.
    pub fn publish(self: *Publisher) !void {
        const io = config.globalIo();
        const a = self.allocator;
        const n = self.next();
        const name = try std.fmt.allocPrint(a, "published-{d}", .{n});
        defer a.free(name);
        const dest = try std.fs.path.join(a, &.{ self.root, name });
        defer a.free(dest);
        std.Io.Dir.cwd().deleteTree(io, dest) catch {};
        {
            errdefer std.Io.Dir.cwd().deleteTree(io, dest) catch {};
            try copyTree(a, self.source, dest);
            try self.switchTo(name, dest);
        }
        // The switch landed: the generation may now say so.
        try self.writeGeneration(n);
        self.generation = n;
        self.prune(n);
    }

    fn switchTo(self: *Publisher, name: []const u8, dest: []const u8) !void {
        if (is_windows) return self.retargetJunction(dest);
        const io = config.globalIo();
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.tmp-{s}", .{ self.output_dir, name });
        defer self.allocator.free(tmp);
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        try std.Io.Dir.cwd().symLink(io, name, tmp, .{ .is_directory = true });
        errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), self.output_dir, io);
    }

    fn writeGeneration(self: *Publisher, n: u64) !void {
        const io = config.globalIo();
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.generation_file});
        defer self.allocator.free(tmp);
        var buf: [24]u8 = undefined;
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = try std.fmt.bufPrint(&buf, "{d}\n", .{n}) });
        // Windows refuses to replace a file another process holds open
        // without delete sharing (a consumer mid-read): retry briefly.
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), self.generation_file, io) catch |err| {
                if (attempt < 100 and (err == error.AccessDenied or err == error.PermissionDenied or err == error.FileBusy or err == error.AntivirusInterference)) {
                    io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
                    continue;
                }
                return err;
            };
            return;
        }
    }

    /// Delete every published directory older than the previous one.
    fn prune(self: *Publisher, n: u64) void {
        if (n < 2) return;
        const io = config.globalIo();
        var dir = std.Io.Dir.cwd().openDir(io, self.root, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch return) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "published-")) continue;
            const k = std.fmt.parseInt(u64, entry.name["published-".len..], 10) catch continue;
            // Best effort: a directory a consumer still holds open on
            // Windows is retried after the next publication.
            if (k + 1 < n) dir.deleteTree(io, entry.name) catch {};
        }
    }

    fn retargetJunction(self: *Publisher, dest: []const u8) !void {
        const io = config.globalIo();
        const a = self.allocator;
        const link_w = try std.unicode.wtf8ToWtf16LeAllocZ(a, self.output_dir);
        defer a.free(link_w);
        const fresh = if (std.Io.Dir.cwd().access(io, self.output_dir, .{})) |_| false else |_| true;
        if (fresh) try std.Io.Dir.cwd().createDir(io, self.output_dir, .default_dir);
        setJunction(a, link_w, dest) catch |err| {
            if (fresh) return err;
            // The in-place rewrite was refused: recreate the junction.
            if (!self.fallback_noted) std.debug.print("labelle: note: the output junction could not be switched in place ({s}); recreating it (not atomic)\n", .{@errorName(err)});
            self.fallback_noted = true;
            if (k32.RemoveDirectoryW(link_w) == 0) return error.JunctionFailed;
            try std.Io.Dir.cwd().createDir(io, self.output_dir, .default_dir);
            try setJunction(a, link_w, dest);
        };
    }
};

/// Copy the tree at `src` into `dest` (created). Symbolic links are
/// followed: the published tree is self-contained.
pub fn copyTree(a: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
    const io = config.globalIo();
    try std.Io.Dir.cwd().createDirPath(io, dest);
    var dir = try std.Io.Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const from = try std.fs.path.join(a, &.{ src, entry.name });
        defer a.free(from);
        const to = try std.fs.path.join(a, &.{ dest, entry.name });
        defer a.free(to);
        switch (entry.kind) {
            .directory => try copyTree(a, from, to),
            else => std.Io.Dir.cwd().copyFile(from, std.Io.Dir.cwd(), to, io, .{}) catch |err| switch (err) {
                error.IsDir => try copyTree(a, from, to),
                else => return err,
            },
        }
    }
}

// ── Windows junctions ─────────────────────────────────────────────────

const k32 = struct {
    const HANDLE = std.os.windows.HANDLE;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) HANDLE;
    extern "kernel32" fn DeviceIoControl(h: HANDLE, code: u32, in: ?*const anyopaque, in_len: u32, out: ?*anyopaque, out_len: u32, returned: ?*u32, overlapped: ?*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) c_int;
    extern "kernel32" fn RemoveDirectoryW(name: [*:0]const u16) callconv(.winapi) c_int;
    const GENERIC_WRITE: u32 = 0x40000000;
    const FILE_SHARE_ALL: u32 = 0x1 | 0x2 | 0x4;
    const OPEN_EXISTING: u32 = 3;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x00200000;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
    const FSCTL_SET_REPARSE_POINT: u32 = 0x000900A4;
    const IO_REPARSE_TAG_MOUNT_POINT: u32 = 0xA0000003;
};

/// Point the (existing, empty) directory `link_w` at the absolute `target`
/// as a junction, replacing any junction data it already has.
fn setJunction(a: std.mem.Allocator, link_w: [:0]const u16, target: []const u8) !void {
    const windows_target = try a.dupe(u8, target);
    defer a.free(windows_target);
    std.mem.replaceScalar(u8, windows_target, '/', '\\');
    const print = try std.unicode.wtf8ToWtf16LeAlloc(a, windows_target);
    defer a.free(print);
    const substitute_text = try std.mem.concat(a, u8, &.{ "\\??\\", windows_target });
    defer a.free(substitute_text);
    const substitute = try std.unicode.wtf8ToWtf16LeAlloc(a, substitute_text);
    defer a.free(substitute);
    const sub_bytes: u16 = @intCast(substitute.len * 2);
    const print_bytes: u16 = @intCast(print.len * 2);
    const data_len: u16 = 8 + sub_bytes + 2 + print_bytes + 2;
    const buf = try a.alloc(u8, 8 + @as(usize, data_len));
    defer a.free(buf);
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], k32.IO_REPARSE_TAG_MOUNT_POINT, .little);
    std.mem.writeInt(u16, buf[4..6], data_len, .little);
    std.mem.writeInt(u16, buf[8..10], 0, .little);
    std.mem.writeInt(u16, buf[10..12], sub_bytes, .little);
    std.mem.writeInt(u16, buf[12..14], sub_bytes + 2, .little);
    std.mem.writeInt(u16, buf[14..16], print_bytes, .little);
    @memcpy(buf[16..][0..sub_bytes], std.mem.sliceAsBytes(substitute));
    @memcpy(buf[16 + sub_bytes + 2 ..][0..print_bytes], std.mem.sliceAsBytes(print));
    const h = k32.CreateFileW(link_w.ptr, k32.GENERIC_WRITE, k32.FILE_SHARE_ALL, null, k32.OPEN_EXISTING, k32.FILE_FLAG_OPEN_REPARSE_POINT | k32.FILE_FLAG_BACKUP_SEMANTICS, null);
    if (@intFromPtr(h) == std.math.maxInt(usize)) return error.JunctionFailed;
    defer _ = k32.CloseHandle(h);
    var returned: u32 = 0;
    if (k32.DeviceIoControl(h, k32.FSCTL_SET_REPARSE_POINT, buf.ptr, @intCast(buf.len), null, 0, &returned, null) == 0) return error.JunctionFailed;
}

// ── Tests ─────────────────────────────────────────────────────────────

fn readCurrent(a: std.mem.Allocator, p: *const Publisher, rel: []const u8) ![]u8 {
    const path = try std.fs.path.join(a, &.{ p.output_dir, rel });
    defer a.free(path);
    return std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, a, .limited(1024));
}

fn readGeneration(a: std.mem.Allocator, p: *const Publisher) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(config.globalIo(), p.generation_file, a, .limited(64));
}

test "publish: each generation is a complete copy; the output switches before the generation advances" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "stage/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/index.txt", .data = "one" });
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/sub/deep.txt", .data = "deep" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const stage = try std.fs.path.join(a, &.{ base, "stage" });
    defer a.free(stage);
    const root = try std.fs.path.join(a, &.{ base, "session" });
    defer a.free(root);
    // A stale session directory is cleared.
    try tmp.dir.createDirPath(io, "session/published-7");
    var p = try Publisher.init(a, root, stage);
    defer p.deinit(true);
    try std.testing.expectEqual(@as(u64, 0), p.next());

    try p.publish();
    {
        const got = try readCurrent(a, &p, "index.txt");
        defer a.free(got);
        try std.testing.expectEqualStrings("one", got);
        const deep = try readCurrent(a, &p, "sub/deep.txt");
        defer a.free(deep);
        try std.testing.expectEqualStrings("deep", deep);
        const g = try readGeneration(a, &p);
        defer a.free(g);
        try std.testing.expectEqualStrings("0\n", g);
    }
    // The staging tree is rewritten by the next build: the published copy
    // does not move until the next publish.
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/index.txt", .data = "two" });
    {
        const got = try readCurrent(a, &p, "index.txt");
        defer a.free(got);
        try std.testing.expectEqualStrings("one", got);
    }
    try p.publish();
    try p.publish();
    {
        const got = try readCurrent(a, &p, "index.txt");
        defer a.free(got);
        try std.testing.expectEqualStrings("two", got);
        const g = try readGeneration(a, &p);
        defer a.free(g);
        try std.testing.expectEqualStrings("2\n", g);
    }
    // Only the current and the previous generation are kept.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "session/published-0", .{}));
    try tmp.dir.access(io, "session/published-1", .{});
    try tmp.dir.access(io, "session/published-2", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "session/published-7", .{}));
}

test "publish: a publication that fails leaves the served output and the generation untouched" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "stage");
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/index.txt", .data = "good" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const stage = try std.fs.path.join(a, &.{ base, "stage" });
    defer a.free(stage);
    const root = try std.fs.path.join(a, &.{ base, "session" });
    defer a.free(root);
    var p = try Publisher.init(a, root, stage);
    defer p.deinit(true);
    try p.publish();
    // The staged tree vanished (a build that wiped its output and died).
    try tmp.dir.deleteTree(io, "stage");
    try std.testing.expectError(error.FileNotFound, p.publish());
    try std.testing.expectEqual(@as(?u64, 0), p.generation);
    const got = try readCurrent(a, &p, "index.txt");
    defer a.free(got);
    try std.testing.expectEqualStrings("good", got);
    const g = try readGeneration(a, &p);
    defer a.free(g);
    try std.testing.expectEqualStrings("0\n", g);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "session/published-1", .{}));
    // The session end removes everything.
    p.deinit(true);
    p = try Publisher.init(a, root, stage);
    try std.testing.expectEqual(@as(?u64, null), p.generation);
}
