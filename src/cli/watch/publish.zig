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
const tree = @import("tree.zig");

const is_windows = builtin.os.tag == .windows;

/// Checks a rebuild runs inside the publication (`Publisher.publish`), so
/// the publication is part of the rebuild's transaction (cli#474):
///
/// - `before_switch` after the copy, before `current` moves: a rebuild
///   cancelled while the copy ran stops here and publishes nothing;
/// - `before_advance` after the switch, before the generation file moves —
///   the commit point: the rebuild's last cancel check and the commit of
///   its staged `labelle.lock`, so a consumer that sees the new generation
///   also sees the lock it was built with. A failure here switches
///   `current` back, exactly as a failed generation write does.
pub const Gate = struct {
    ctx: *anyopaque,
    before_switch: *const fn (*anyopaque) anyerror!void,
    before_advance: *const fn (*anyopaque) anyerror!void,
};

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
    /// The published directory `current` names, and the one before it
    /// (kept: a request may still read it through a resolved path). Owned
    /// basenames under `root`; `null` until published.
    current_name: ?[]const u8 = null,
    previous_name: ?[]const u8 = null,
    /// Set once the non-atomic Windows fallback had to be used.
    fallback_noted: bool = false,
    /// The generation-file writer. A field only so a test can make it fail
    /// after the switch; production never overrides it.
    write_generation: *const fn (*Publisher, u64) anyerror!void = writeGeneration,

    /// Start a session at `root`: whatever an earlier session left there is
    /// removed first. The caller holds the root's `SessionLock`.
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
        if (self.current_name) |n| self.allocator.free(n);
        if (self.previous_name) |n| self.allocator.free(n);
        self.current_name = null;
        self.previous_name = null;
    }

    /// The generation the next `publish` writes.
    pub fn next(self: *const Publisher) u64 {
        return if (self.generation) |g| g + 1 else 0;
    }

    /// Publish the staged tree as the next generation (0 first), running
    /// `gate`'s checks at their points (`Gate`). On any error nothing
    /// observable changed: `current` and `generation` still name the
    /// previous publication. When the generation cannot be advanced after
    /// `current` was switched (the gate refused, or the generation write
    /// failed), `current` is switched BACK (or removed, before the first
    /// publication), so a consumer never sees a switched output under an
    /// old generation. Only if that rollback fails too does `current` keep
    /// the new output under the old generation — reported, and
    /// `generation` still moves, so the next publication never overwrites
    /// the directory being served.
    ///
    /// Every publication copies into a directory it CREATES (`freshDir`),
    /// never into one a failed cleanup left behind, so no stale file of an
    /// earlier attempt can go live with it (cli#474).
    pub fn publish(self: *Publisher, gate: ?Gate) !void {
        const io = config.globalIo();
        const a = self.allocator;
        const n = self.next();
        const name = try self.freshDir(n);
        var keep_name = false;
        defer if (!keep_name) a.free(name);
        const dest = try std.fs.path.join(a, &.{ self.root, name });
        defer a.free(dest);
        const restore = if (self.current_name) |cur| try std.fs.path.join(a, &.{ self.root, cur }) else null;
        defer if (restore) |r| a.free(r);
        {
            errdefer std.Io.Dir.cwd().deleteTree(io, dest) catch {};
            try copyTree(a, self.source, dest);
            if (gate) |g| try g.before_switch(g.ctx);
            try self.switchTo(name, dest, restore);
        }
        // The switch landed: the generation may now say so, once the gate
        // (the rebuild's commit point) agrees.
        const refused: ?anyerror = blk: {
            if (gate) |g| g.before_advance(g.ctx) catch |err| break :blk err;
            self.write_generation(self, n) catch |err| break :blk err;
            break :blk null;
        };
        if (refused) |err| {
            if (self.switchBack(dest)) {
                std.Io.Dir.cwd().deleteTree(io, dest) catch {};
                return err;
            } else |back_err| {
                std.debug.print("labelle: watch: generation {d} is served but its generation file could not be written ({s}), nor the output switched back ({s})\n", .{ n, @errorName(err), @errorName(back_err) });
            }
            self.advance(n, name);
            keep_name = true;
            return err;
        }
        self.advance(n, name);
        keep_name = true;
    }

    /// Record `name` as the published generation `n` and prune.
    fn advance(self: *Publisher, n: u64, name: []const u8) void {
        if (self.previous_name) |old| self.allocator.free(old);
        self.previous_name = self.current_name;
        self.current_name = name;
        self.generation = n;
        self.prune();
    }

    /// Create a directory for generation `n` that did not exist before:
    /// `published-<n>`, else `published-<n>-<k>` past any leftover of an
    /// earlier attempt (one a cleanup could not delete), which `prune`
    /// removes later. Returns its basename (owned).
    fn freshDir(self: *Publisher, n: u64) ![]const u8 {
        const io = config.globalIo();
        const a = self.allocator;
        var k: u32 = 0;
        while (k < 1000) : (k += 1) {
            const name = if (k == 0)
                try std.fmt.allocPrint(a, "published-{d}", .{n})
            else
                try std.fmt.allocPrint(a, "published-{d}-{d}", .{ n, k });
            errdefer a.free(name);
            const path = try std.fs.path.join(a, &.{ self.root, name });
            defer a.free(path);
            std.Io.Dir.cwd().createDir(io, path, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    a.free(name);
                    continue;
                },
                else => return err,
            };
            return name;
        }
        return error.PublishDirUnavailable;
    }

    /// Point `current` back at the last publication, or remove it when
    /// there is none. `from` is the directory it points at now.
    fn switchBack(self: *Publisher, from: []const u8) !void {
        const previous = self.current_name orelse {
            const io = config.globalIo();
            if (is_windows) {
                const link_w = try std.unicode.wtf8ToWtf16LeAllocZ(self.allocator, self.output_dir);
                defer self.allocator.free(link_w);
                if (k32.RemoveDirectoryW(link_w) == 0) return error.JunctionFailed;
            } else try std.Io.Dir.cwd().deleteFile(io, self.output_dir);
            return;
        };
        const dest = try std.fs.path.join(self.allocator, &.{ self.root, previous });
        defer self.allocator.free(dest);
        try self.switchTo(previous, dest, from);
    }

    /// Point `current` at `dest` (basename `name`). `restore` is where it
    /// points now, for the Windows fallback to put back on failure.
    fn switchTo(self: *Publisher, name: []const u8, dest: []const u8, restore: ?[]const u8) !void {
        if (is_windows) return self.retargetJunction(dest, restore);
        const io = config.globalIo();
        const tmp = try std.fmt.allocPrint(self.allocator, "{s}.tmp-{s}", .{ self.output_dir, name });
        defer self.allocator.free(tmp);
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        try std.Io.Dir.cwd().symLink(io, name, tmp, .{ .is_directory = true });
        errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), self.output_dir, io);
    }

    pub fn writeGeneration(self: *Publisher, n: u64) anyerror!void {
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

    /// Delete every published directory but the current and the previous
    /// one — leftovers of failed attempts included.
    fn prune(self: *Publisher) void {
        const io = config.globalIo();
        var dir = std.Io.Dir.cwd().openDir(io, self.root, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch return) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "published-")) continue;
            if (self.current_name) |n| if (std.mem.eql(u8, n, entry.name)) continue;
            if (self.previous_name) |n| if (std.mem.eql(u8, n, entry.name)) continue;
            // Best effort: a directory a consumer still holds open on
            // Windows is retried after the next publication.
            dir.deleteTree(io, entry.name) catch {};
        }
    }

    fn retargetJunction(self: *Publisher, dest: []const u8, restore: ?[]const u8) !void {
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
            var real: RealJunction = .{ .a = a, .link_w = link_w, .path = self.output_dir };
            return recreateJunction(real.ops(), dest, restore);
        };
    }
};

/// The three filesystem operations of the non-atomic junction fallback,
/// behind a seam so its failure handling is tested on every host.
pub const JunctionOps = struct {
    ctx: *anyopaque,
    /// Remove the (empty) junction directory.
    remove: *const fn (*anyopaque) anyerror!void,
    /// Create it as an empty directory (`error.PathAlreadyExists` if it is
    /// there).
    create: *const fn (*anyopaque) anyerror!void,
    /// Point it at `target`.
    set: *const fn (*anyopaque, []const u8) anyerror!void,
};

/// Recreate the junction pointing at `dest`. When a step after the removal
/// fails, the junction is put back to `restore` — the output it served —
/// so a failed switch never leaves `current` missing or pointing nowhere
/// (cli#474); `restore == null` (nothing published yet) leaves it absent.
pub fn recreateJunction(ops: JunctionOps, dest: []const u8, restore: ?[]const u8) !void {
    try ops.remove(ops.ctx);
    ops.create(ops.ctx) catch |err| {
        putBack(ops, restore);
        return err;
    };
    ops.set(ops.ctx, dest) catch |err| {
        putBack(ops, restore);
        return err;
    };
}

fn putBack(ops: JunctionOps, restore: ?[]const u8) void {
    const target = restore orelse {
        ops.remove(ops.ctx) catch {};
        return;
    };
    ops.create(ops.ctx) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            std.debug.print("labelle: watch: the output junction could not be restored ({s}); it is missing until the next publication\n", .{@errorName(err)});
            return;
        },
    };
    ops.set(ops.ctx, target) catch |err| {
        std.debug.print("labelle: watch: the output junction could not be restored ({s}); it is empty until the next publication\n", .{@errorName(err)});
    };
}

const RealJunction = struct {
    a: std.mem.Allocator,
    link_w: [:0]const u16,
    path: []const u8,

    fn ops(self: *RealJunction) JunctionOps {
        return .{ .ctx = self, .remove = remove, .create = create, .set = set };
    }
    fn remove(ctx: *anyopaque) anyerror!void {
        const self: *RealJunction = @ptrCast(@alignCast(ctx));
        if (k32.RemoveDirectoryW(self.link_w) == 0) return error.JunctionFailed;
    }
    fn create(ctx: *anyopaque) anyerror!void {
        const self: *RealJunction = @ptrCast(@alignCast(ctx));
        try std.Io.Dir.cwd().createDir(config.globalIo(), self.path, .default_dir);
    }
    fn set(ctx: *anyopaque, target: []const u8) anyerror!void {
        const self: *RealJunction = @ptrCast(@alignCast(ctx));
        try setJunction(self.a, self.link_w, target);
    }
};

/// Copy the tree at `src` into `dest` (created). A symbolic link is copied
/// AS a link, never followed, so a link back to an ancestor cannot make the
/// copy recurse. A link whose target lies inside `src` is written relative
/// to its own directory (an absolute one is made relative), so it names the
/// published file, never the mutable staging tree or a host path. A link
/// whose target lies outside `src` — relative or absolute — is skipped with
/// a warning; so is a link that cannot be created (Windows without the
/// privilege).
///
/// An entry the directory listing reports as `.unknown` (NFS, FUSE and
/// other filesystems without `d_type`) is resolved with a `stat` of the
/// entry itself (`tree.entryKind`), so a directory is still copied as a
/// directory and a link as a link (cli#474).
pub fn copyTree(a: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
    return copyTreeWithin(a, src, src, dest, listedKind);
}

/// What the listing reports; a test substitutes `.unknown` for every
/// entry to stand in for a filesystem without `d_type`.
const KindFn = *const fn (std.Io.Dir.Entry) std.Io.File.Kind;

fn listedKind(entry: std.Io.Dir.Entry) std.Io.File.Kind {
    return entry.kind;
}

fn copyTreeWithin(a: std.mem.Allocator, top: []const u8, src: []const u8, dest: []const u8, listed: KindFn) !void {
    const io = config.globalIo();
    try std.Io.Dir.cwd().createDirPath(io, dest);
    var dir = try std.Io.Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |raw| {
        var entry = raw;
        entry.kind = listed(raw);
        const from = try std.fs.path.join(a, &.{ src, entry.name });
        defer a.free(from);
        const to = try std.fs.path.join(a, &.{ dest, entry.name });
        defer a.free(to);
        switch (try tree.entryKind(io, dir, entry)) {
            .directory => try copyTreeWithin(a, top, from, to, listed),
            .sym_link => copyLink(a, top, from, to) catch |err| {
                std.debug.print("labelle: watch: symbolic link '{s}' not published ({s})\n", .{ from, @errorName(err) });
            },
            else => try std.Io.Dir.cwd().copyFile(from, std.Io.Dir.cwd(), to, io, .{}),
        }
    }
}

fn copyLink(a: std.mem.Allocator, top: []const u8, from: []const u8, to: []const u8) !void {
    const io = config.globalIo();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().readLink(io, from, &buf);
    const link_dir = std.fs.path.dirname(from) orelse ".";
    const resolved = try std.fs.path.resolve(a, &.{ link_dir, buf[0..n] });
    defer a.free(resolved);
    if (!within(top, resolved)) return error.LinkLeavesTheStagedTree;
    // Inside the staged tree. An absolute target would keep pointing into
    // the MUTABLE staging tree (and name a host path), so every link is
    // written relative to its own directory: in the copy, which mirrors the
    // staged tree, it names the same file of the published generation.
    const target = if (std.fs.path.isAbsolute(buf[0..n])) try std.fs.path.relative(a, link_dir, null, link_dir, resolved) else try a.dupe(u8, buf[0..n]);
    defer a.free(target);
    const is_dir = if (std.Io.Dir.cwd().statFile(io, from, .{})) |st| st.kind == .directory else |_| false;
    try std.Io.Dir.cwd().symLink(io, if (target.len == 0) "." else target, to, .{ .is_directory = is_dir });
}

/// True when `path` is `top` or lies beneath it (pure path math; both are
/// resolved, `top` absolute).
pub fn within(top: []const u8, path: []const u8) bool {
    const t = std.mem.trimEnd(u8, top, "/\\");
    if (path.len < t.len) return false;
    const head = path[0..t.len];
    const same = if (is_windows) std.ascii.eqlIgnoreCase(head, t) else std.mem.eql(u8, head, t);
    if (!same) return false;
    return path.len == t.len or std.fs.path.isSep(path[t.len]);
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

    try p.publish(null);
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
    try p.publish(null);
    try p.publish(null);
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
    try p.publish(null);
    // The staged tree vanished (a build that wiped its output and died).
    try tmp.dir.deleteTree(io, "stage");
    try std.testing.expectError(error.FileNotFound, p.publish(null));
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

test "publish: a generation that cannot be advanced switches the output back" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "stage");
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/index.txt", .data = "zero" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const stage = try std.fs.path.join(a, &.{ base, "stage" });
    defer a.free(stage);
    const root = try std.fs.path.join(a, &.{ base, "session" });
    defer a.free(root);
    const Fail = struct {
        fn write(_: *Publisher, _: u64) anyerror!void {
            return error.SharingViolation;
        }
    };
    var p = try Publisher.init(a, root, stage);
    defer p.deinit(true);
    // Before the first publication: `current` is removed again.
    p.write_generation = Fail.write;
    try std.testing.expectError(error.SharingViolation, p.publish(null));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "session/current/index.txt", .{}));
    try std.testing.expectEqual(@as(?u64, null), p.generation);
    p.write_generation = Publisher.writeGeneration;
    try p.publish(null);
    // After it: `current` goes back to generation 0, whose file still says 0.
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/index.txt", .data = "one" });
    p.write_generation = Fail.write;
    try std.testing.expectError(error.SharingViolation, p.publish(null));
    {
        const got = try readCurrent(a, &p, "index.txt");
        defer a.free(got);
        try std.testing.expectEqualStrings("zero", got);
        const g = try readGeneration(a, &p);
        defer a.free(g);
        try std.testing.expectEqualStrings("0\n", g);
    }
    try std.testing.expectEqual(@as(?u64, 0), p.generation);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "session/published-1", .{}));
    // The next attempt publishes normally.
    p.write_generation = Publisher.writeGeneration;
    try p.publish(null);
    const got = try readCurrent(a, &p, "index.txt");
    defer a.free(got);
    try std.testing.expectEqualStrings("one", got);
}

test "publish: links inside the staged tree are copied as links; relative ones leaving it are skipped" {
    if (is_windows) return error.SkipZigTest; // links need a privilege there
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "stage/sub");
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/sub/file.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/secret.txt", .data = "host" });
    // Inside: a cycle back to an ancestor, and a sibling file.
    try tmp.dir.symLink(io, "..", "stage/sub/loop", .{ .is_directory = true });
    try tmp.dir.symLink(io, "file.txt", "stage/sub/alias.txt", .{});
    // Outside: relative targets that leave the staged tree.
    try tmp.dir.symLink(io, "../../outside/secret.txt", "stage/sub/escape.txt", .{});
    try tmp.dir.symLink(io, "../outside", "stage/escape-dir", .{ .is_directory = true });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const stage = try std.fs.path.join(a, &.{ base, "stage" });
    defer a.free(stage);
    const out = try std.fs.path.join(a, &.{ base, "out" });
    defer a.free(out);
    try copyTree(a, stage, out);
    var buf: [64]u8 = undefined;
    const n = try tmp.dir.readLink(io, "out/sub/loop", &buf);
    try std.testing.expectEqualStrings("..", buf[0..n]);
    const m = try tmp.dir.readLink(io, "out/sub/alias.txt", &buf);
    try std.testing.expectEqualStrings("file.txt", buf[0..m]);
    try tmp.dir.access(io, "out/sub/file.txt", .{});
    // Absolute links: into the tree becomes relative; out of it, skipped.
    const abs_inside = try std.fs.path.join(a, &.{ stage, "sub", "file.txt" });
    defer a.free(abs_inside);
    const abs_outside = try std.fs.path.join(a, &.{ base, "outside", "secret.txt" });
    defer a.free(abs_outside);
    try tmp.dir.symLink(io, abs_inside, "stage/abs-in.txt", .{});
    try tmp.dir.symLink(io, abs_outside, "stage/abs-out.txt", .{});
    const out2 = try std.fs.path.join(a, &.{ base, "out2" });
    defer a.free(out2);
    try copyTree(a, stage, out2);
    const k = try tmp.dir.readLink(io, "out2/abs-in.txt", &buf);
    try std.testing.expectEqualStrings("sub" ++ std.fs.path.sep_str ++ "file.txt", buf[0..k]);
    const via = try tmp.dir.readFileAlloc(io, "out2/abs-in.txt", a, .limited(16));
    defer a.free(via);
    try std.testing.expectEqualStrings("x", via);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "out2/abs-out.txt", .{ .follow_symlinks = false }));
    // Skipped: no link, and no rewritten absolute path either.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "out/sub/escape.txt", .{ .follow_symlinks = false }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "out/escape-dir", .{ .follow_symlinks = false }));
}

test "publish: the containment check is pure path math" {
    const top = if (is_windows) "C:\\stage" else "/stage";
    const inside = if (is_windows) "C:\\stage\\sub" else "/stage/sub";
    const sibling = if (is_windows) "C:\\stage2" else "/stage2";
    const parent = if (is_windows) "C:\\" else "/";
    try std.testing.expect(within(top, top));
    try std.testing.expect(within(top, inside));
    try std.testing.expect(!within(top, sibling));
    try std.testing.expect(!within(top, parent));
}

test "publish: a leftover directory of the same generation is never merged into (cli#474)" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "stage");
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/index.txt", .data = "zero" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const stage = try std.fs.path.join(a, &.{ base, "stage" });
    defer a.free(stage);
    const root = try std.fs.path.join(a, &.{ base, "session" });
    defer a.free(root);
    var p = try Publisher.init(a, root, stage);
    defer p.deinit(true);
    try p.publish(null);
    // What a failed cleanup of an earlier attempt at generation 1 left:
    // a stale file that must never go live.
    try tmp.dir.createDirPath(io, "session/published-1");
    try tmp.dir.writeFile(io, .{ .sub_path = "session/published-1/stale.txt", .data = "stale" });
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/index.txt", .data = "one" });
    try p.publish(null);
    try std.testing.expectEqual(@as(?u64, 1), p.generation);
    // Published into a directory of its own...
    try std.testing.expectEqualStrings("published-1-1", p.current_name.?);
    const got = try readCurrent(a, &p, "index.txt");
    defer a.free(got);
    try std.testing.expectEqualStrings("one", got);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "session/current/stale.txt", .{}));
    // ...and the leftover is pruned; the previous generation is kept.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "session/published-1", .{}));
    try tmp.dir.access(io, "session/published-0/index.txt", .{});
}

test "publish: the gate runs after the copy and after the switch; a refusal publishes nothing (cli#474)" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "stage");
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/index.txt", .data = "zero" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const stage = try std.fs.path.join(a, &.{ base, "stage" });
    defer a.free(stage);
    const root = try std.fs.path.join(a, &.{ base, "session" });
    defer a.free(root);
    var p = try Publisher.init(a, root, stage);
    defer p.deinit(true);
    try p.publish(null);
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/index.txt", .data = "one" });

    const Probe = struct {
        p: *Publisher,
        refuse_switch: bool = false,
        refuse_advance: bool = false,
        /// What `current` served, and the generation file said, at each check.
        at_switch: [8]u8 = undefined,
        at_switch_len: usize = 0,
        at_advance: [8]u8 = undefined,
        at_advance_len: usize = 0,
        generation_at_advance: [8]u8 = undefined,
        generation_at_advance_len: usize = 0,
        fn served(self: *@This(), out: *[8]u8, len: *usize) void {
            const bytes = readCurrent(std.testing.allocator, self.p, "index.txt") catch return;
            defer std.testing.allocator.free(bytes);
            @memcpy(out[0..bytes.len], bytes);
            len.* = bytes.len;
        }
        fn beforeSwitch(ctx: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.served(&self.at_switch, &self.at_switch_len);
            if (self.refuse_switch) return error.Canceled;
        }
        fn beforeAdvance(ctx: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.served(&self.at_advance, &self.at_advance_len);
            const g = readGeneration(std.testing.allocator, self.p) catch return;
            defer std.testing.allocator.free(g);
            @memcpy(self.generation_at_advance[0..g.len], g);
            self.generation_at_advance_len = g.len;
            if (self.refuse_advance) return error.LockCommitFailed;
        }
        fn gate(self: *@This()) Gate {
            return .{ .ctx = self, .before_switch = beforeSwitch, .before_advance = beforeAdvance };
        }
    };
    // Refused before the switch (a cancel during the copy): the old output
    // is still served, and no directory is left.
    var probe: Probe = .{ .p = &p, .refuse_switch = true };
    try std.testing.expectError(error.Canceled, p.publish(probe.gate()));
    try std.testing.expectEqualStrings("zero", probe.at_switch[0..probe.at_switch_len]);
    try std.testing.expectEqual(@as(usize, 0), probe.at_advance_len);
    try std.testing.expectEqual(@as(?u64, 0), p.generation);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "session/published-1", .{}));
    // Refused at the commit point: the check ran with the NEW output
    // switched in and the OLD generation still current; the output is
    // switched back.
    probe = .{ .p = &p, .refuse_advance = true };
    try std.testing.expectError(error.LockCommitFailed, p.publish(probe.gate()));
    try std.testing.expectEqualStrings("zero", probe.at_switch[0..probe.at_switch_len]);
    try std.testing.expectEqualStrings("one", probe.at_advance[0..probe.at_advance_len]);
    try std.testing.expectEqualStrings("0\n", probe.generation_at_advance[0..probe.generation_at_advance_len]);
    try std.testing.expectEqual(@as(?u64, 0), p.generation);
    {
        const got = try readCurrent(a, &p, "index.txt");
        defer a.free(got);
        try std.testing.expectEqualStrings("zero", got);
        const g = try readGeneration(a, &p);
        defer a.free(g);
        try std.testing.expectEqualStrings("0\n", g);
    }
    // Agreed: published.
    probe = .{ .p = &p };
    try p.publish(probe.gate());
    try std.testing.expectEqual(@as(?u64, 1), p.generation);
    const got = try readCurrent(a, &p, "index.txt");
    defer a.free(got);
    try std.testing.expectEqualStrings("one", got);
}

/// The junction fallback's filesystem, in memory: whether the junction
/// directory exists and where it points, with scripted failures.
const FakeJunction = struct {
    exists: bool = true,
    target: ?[]const u8 = null,
    fail_create: u32 = 0,
    fail_set_to: ?[]const u8 = null,

    fn ops(self: *FakeJunction) JunctionOps {
        return .{ .ctx = self, .remove = remove, .create = create, .set = set };
    }
    fn remove(ctx: *anyopaque) anyerror!void {
        const self: *FakeJunction = @ptrCast(@alignCast(ctx));
        if (!self.exists) return error.FileNotFound;
        self.exists = false;
        self.target = null;
    }
    fn create(ctx: *anyopaque) anyerror!void {
        const self: *FakeJunction = @ptrCast(@alignCast(ctx));
        if (self.exists) return error.PathAlreadyExists;
        if (self.fail_create != 0) {
            self.fail_create -= 1;
            return error.AccessDenied;
        }
        self.exists = true;
    }
    fn set(ctx: *anyopaque, target: []const u8) anyerror!void {
        const self: *FakeJunction = @ptrCast(@alignCast(ctx));
        if (!self.exists) return error.FileNotFound;
        if (self.fail_set_to) |bad| if (std.mem.eql(u8, bad, target)) return error.JunctionFailed;
        self.target = target;
    }
};

test "publish: a junction recreate that fails puts the previous junction back (cli#474)" {
    // The recreate itself.
    var ok: FakeJunction = .{ .target = "old" };
    try recreateJunction(ok.ops(), "new", "old");
    try std.testing.expectEqualStrings("new", ok.target.?);
    // Pointing the recreated junction at the new output fails: it serves
    // the previous output again, not nothing.
    var bad_set: FakeJunction = .{ .target = "old", .fail_set_to = "new" };
    try std.testing.expectError(error.JunctionFailed, recreateJunction(bad_set.ops(), "new", "old"));
    try std.testing.expect(bad_set.exists);
    try std.testing.expectEqualStrings("old", bad_set.target.?);
    // Recreating the directory fails once: the restore recreates it.
    var bad_create: FakeJunction = .{ .target = "old", .fail_create = 1 };
    try std.testing.expectError(error.AccessDenied, recreateJunction(bad_create.ops(), "new", "old"));
    try std.testing.expect(bad_create.exists);
    try std.testing.expectEqualStrings("old", bad_create.target.?);
    // Before the first publication there is nothing to restore: no
    // junction is left behind.
    var first: FakeJunction = .{ .fail_set_to = "new" };
    try std.testing.expectError(error.JunctionFailed, recreateJunction(first.ops(), "new", null));
    try std.testing.expect(!first.exists);
}

fn alwaysUnknown(_: std.Io.Dir.Entry) std.Io.File.Kind {
    return .unknown;
}

test "publish: entries a filesystem lists as .unknown are resolved with a stat (cli#474)" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "stage/sub/deeper");
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/index.txt", .data = "top" });
    try tmp.dir.writeFile(io, .{ .sub_path = "stage/sub/deeper/leaf.txt", .data = "leaf" });
    const links = !is_windows; // links need a privilege there
    if (links) try tmp.dir.symLink(io, "index.txt", "stage/alias.txt", .{});
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const stage = try std.fs.path.join(a, &.{ base, "stage" });
    defer a.free(stage);
    const out = try std.fs.path.join(a, &.{ base, "out" });
    defer a.free(out);
    // Every entry listed as `.unknown`, as NFS or FUSE may: directories are
    // still recursed into (copying one "as a file" failed publication),
    // files copied, links kept as links.
    try copyTreeWithin(a, stage, stage, out, alwaysUnknown);
    const leaf = try tmp.dir.readFileAlloc(io, "out/sub/deeper/leaf.txt", a, .limited(16));
    defer a.free(leaf);
    try std.testing.expectEqualStrings("leaf", leaf);
    const top = try tmp.dir.readFileAlloc(io, "out/index.txt", a, .limited(16));
    defer a.free(top);
    try std.testing.expectEqualStrings("top", top);
    if (links) {
        var buf: [64]u8 = undefined;
        const n = try tmp.dir.readLink(io, "out/alias.txt", &buf);
        try std.testing.expectEqualStrings("index.txt", buf[0..n]);
    }
}
