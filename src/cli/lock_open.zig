//! Opening an OS lock file inside a project tree safely, shared by the
//! watch session lock (`watch/session_lock.zig`, cli#476) and the project
//! lock around `labelle.lock` writes (`project_lock.zig`, cli#481).
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

/// This process's id: named in a lock's refusal, and part of a watch
/// session's private staged-lock name (cli#481).
pub fn ownPid() u64 {
    if (is_windows) return GetCurrentProcessId();
    if (builtin.os.tag == .linux) return @intCast(std.os.linux.getpid());
    return @intCast(std.c.getpid());
}

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
