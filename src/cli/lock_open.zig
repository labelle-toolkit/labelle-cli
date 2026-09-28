//! Opening a file the CLI writes inside a project tree safely: the watch
//! session lock (`watch/session_lock.zig`, cli#476), the project lock and
//! the lock files written under it (`project_lock.zig`, cli#481).
//!
//! A lock file lives in the project tree, and a symbolic link planted there
//! (a damaged or untrusted checkout) must never make a command truncate or
//! write the file it names: the path is opened WITHOUT following a link and
//! must be a regular file.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");

const is_windows = builtin.os.tag == .windows;

/// Open (or create) `lock_path` for reading and writing, never through a
/// symbolic link: an existing entry is opened without following links and
/// must be a regular file; a missing one is created exclusively, which
/// fails on any entry — a dangling link included — that appears meanwhile.
/// `error.LockNotRegular`: a link, a directory, or an entry that kept
/// changing under us; the caller prints its own diagnostic.
pub fn openRegular(lock_path: []const u8) !std.Io.File {
    const io = config.globalIo();
    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        // Windows: Zig 0.16 opens a no-follow handle (the reparse point
        // itself) without synchronous I/O, so its reads panic; the entry is
        // checked with a no-follow stat instead, then opened normally.
        // POSIX: O_NOFOLLOW, then the handle's own stat.
        if (is_windows) {
            const st = std.Io.Dir.cwd().statFile(io, lock_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (st) |entry| if (entry.kind != .file) return error.LockNotRegular;
        }
        const file = std.Io.Dir.cwd().openFile(io, lock_path, .{ .mode = .read_write, .follow_symlinks = is_windows, .allow_directory = false }) catch |err| switch (err) {
            error.FileNotFound => {
                return std.Io.Dir.cwd().createFile(io, lock_path, .{ .read = true, .truncate = false, .exclusive = true }) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => continue,
                    else => return create_err,
                };
            },
            error.SymLinkLoop, error.IsDir, error.NotDir => return error.LockNotRegular,
            else => return err,
        };
        errdefer file.close(io);
        const st = try file.stat(io);
        if (st.kind != .file) return error.LockNotRegular;
        return file;
    }
    return error.LockNotRegular;
}

/// Write `data` to `path` through `openRegular`: never through a symbolic
/// link planted at the path (cli#481). Replaces the file's contents.
pub fn writeRegular(path: []const u8, data: []const u8) !void {
    const io = config.globalIo();
    const file = openRegular(path) catch |err| switch (err) {
        error.LockNotRegular => {
            std.debug.print("labelle: '{s}' is not a regular file (a symbolic link or a directory); remove it and run again\n", .{path});
            return error.NotRegularFile;
        },
        else => return err,
    };
    defer file.close(io);
    try file.setLength(io, 0);
    try file.writePositionalAll(io, data, 0);
}
