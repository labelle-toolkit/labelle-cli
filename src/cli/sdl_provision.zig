//! SDL2 auto-provisioning for `labelle doctor --fix`.
//!
//! SDL2 is the one manual system dependency a labelle desktop game needs (the
//! raylib/sokol gamepad source + the sdl render backend). On Windows there is
//! no system package manager, so this module downloads the official MinGW dev
//! package into `~/.labelle/sdl2/` and arranges it exactly the way Zig's
//! linker wants (import lib + the DLL placed in the lib search dir, static
//! archives removed so the dynamic candidate wins). On Linux/macOS a system
//! install needs privileges we won't assume, so we print the one-liner.
//!
//! The cache layout produced here is the one `doctor.zig:findCachedSdl2Lib`
//! scans, and that a later phase wires into the build/run env automatically.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const util = @import("util.zig");
const asm_cache = @import("asm_cache.zig");

/// SDL2 release to fetch. Matches the version verified against the toolkit's
/// Windows backends.
pub const SDL2_VERSION = "2.30.11";

pub const Result = enum {
    /// SDL2 is available in the cache (freshly provisioned or already there).
    ready,
    /// Printed package-manager guidance (Linux/macOS) — user action needed.
    guided,
    /// Download/extract failed.
    failed,
};

/// Resolve the cache lib dir SDL2 is (or will be) provisioned into:
/// `~/.labelle/sdl2/SDL2-<ver>/x86_64-w64-mingw32/lib`. Caller owns the slice.
pub fn cachedLibDir(allocator: std.mem.Allocator) ![]u8 {
    const cache_root = try asm_cache.getCacheRoot(allocator);
    defer allocator.free(cache_root);
    return std.fs.path.join(allocator, &.{ cache_root, "sdl2", "SDL2-" ++ SDL2_VERSION, "x86_64-w64-mingw32", "lib" });
}

/// Ensure SDL2 is available, downloading it on Windows if needed.
pub fn provisionSdl2(gpa: std.mem.Allocator) Result {
    switch (builtin.os.tag) {
        .windows => return provisionWindows(gpa),
        .linux => {
            std.debug.print(
                \\
                \\  SDL2 must be installed via your system package manager:
                \\    sudo apt install libsdl2-dev libsdl2-mixer-dev    # Debian/Ubuntu
                \\    sudo dnf install SDL2-devel SDL2_mixer-devel      # Fedora
                \\    sudo pacman -S sdl2 sdl2_mixer                    # Arch
                \\
            , .{});
            return .guided;
        },
        .macos => {
            std.debug.print(
                \\
                \\  Install SDL2 via Homebrew:
                \\    brew install sdl2 sdl2_mixer
                \\
            , .{});
            return .guided;
        },
        else => return .failed,
    }
}

/// If SDL2 was provisioned into the cache (by `doctor --fix`) and the user
/// hasn't set `LABELLE_SDL2_LIB` themselves, inject it — plus prepend the dir
/// (which holds SDL2.dll) to PATH for runtime — into THIS process's
/// environment, so the `zig build` / game children spawned afterwards inherit
/// it. No-op off Windows, or when the cache is absent, or when the user
/// already set `LABELLE_SDL2_LIB`. This is what makes a desktop build/run
/// "just work" after a one-time `labelle doctor --fix`.
pub fn autoWireEnv(gpa: std.mem.Allocator) void {
    if (builtin.os.tag != .windows) return;
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();

    const lib_dir = cachedLibDir(a) catch return;
    const importlib = join(a, &.{ lib_dir, "libSDL2.dll.a" }) orelse return;
    if (!util.fileExists(importlib)) return; // nothing provisioned

    const env = config.globalEnviron();

    // LABELLE_SDL2_LIB — respect a user-provided value; otherwise point at the cache.
    const existing = env.getAlloc(a, "LABELLE_SDL2_LIB") catch null;
    if (existing == null or existing.?.len == 0) {
        setEnvW(a, "LABELLE_SDL2_LIB", lib_dir);
        std.debug.print("labelle: using cached SDL2 ({s})\n", .{lib_dir});
    }

    // PATH — prepend the cache lib dir (contains SDL2.dll) for runtime, once.
    const old_path = (env.getAlloc(a, "PATH") catch null) orelse "";
    if (std.mem.indexOf(u8, old_path, lib_dir) == null) {
        const new_path = std.fmt.allocPrint(a, "{s};{s}", .{ lib_dir, old_path }) catch return;
        setEnvW(a, "PATH", new_path);
    }
}

extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) i32;

/// Set an environment variable on the current process (Windows). Children
/// spawned with an inherited environment block pick up the new value.
fn setEnvW(a: std.mem.Allocator, name: []const u8, value: []const u8) void {
    const name_w = std.unicode.utf8ToUtf16LeAllocZ(a, name) catch return;
    const value_w = std.unicode.utf8ToUtf16LeAllocZ(a, value) catch return;
    _ = SetEnvironmentVariableW(name_w.ptr, value_w.ptr);
}

fn provisionWindows(gpa: std.mem.Allocator) Result {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const io = config.globalIo();

    const cache_root = asm_cache.getCacheRoot(a) catch return .failed;
    const sdl_base = join(a, &.{ cache_root, "sdl2" }) orelse return .failed;
    const extracted = join(a, &.{ sdl_base, "SDL2-" ++ SDL2_VERSION }) orelse return .failed;
    const mingw = join(a, &.{ extracted, "x86_64-w64-mingw32" }) orelse return .failed;
    const lib_dir = join(a, &.{ mingw, "lib" }) orelse return .failed;
    const importlib = join(a, &.{ lib_dir, "libSDL2.dll.a" }) orelse return .failed;
    const dll_in_lib = join(a, &.{ lib_dir, "SDL2.dll" }) orelse return .failed;

    if (util.fileExists(importlib) and util.fileExists(dll_in_lib)) {
        std.debug.print("  SDL2 already provisioned: {s}\n", .{lib_dir});
        return .ready;
    }

    std.Io.Dir.cwd().createDirPath(io, sdl_base) catch return .failed;

    const tarball = join(a, &.{ sdl_base, "SDL2-devel-mingw.tar.gz" }) orelse return .failed;
    const url = "https://github.com/libsdl-org/SDL/releases/download/release-" ++
        SDL2_VERSION ++ "/SDL2-devel-" ++ SDL2_VERSION ++ "-mingw.tar.gz";

    std.debug.print("  downloading SDL2 {s} (MinGW dev libs)...\n    {s}\n", .{ SDL2_VERSION, url });
    if (!runOk(a, &.{ "curl", "-fSL", "-o", tarball, url })) {
        std.debug.print("  download failed (is curl on PATH?).\n", .{});
        return .failed;
    }

    std.debug.print("  extracting...\n", .{});
    if (!runOk(a, &.{ "tar", "-xzf", tarball, "-C", sdl_base })) {
        std.debug.print("  extract failed (is tar on PATH?).\n", .{});
        return .failed;
    }

    // Arrange for Zig's dynamic linker: the resolver looks for SDL2.dll in the
    // library search dir (not the MinGW `libSDL2.dll.a`), and would otherwise
    // fall back to the static `libSDL2.a` (which drags in many Win32 libs).
    // Copy the DLL into lib/ and drop the static archives.
    const bin_dll = join(a, &.{ mingw, "bin", "SDL2.dll" }) orelse return .failed;
    copyFileVia(a, io, bin_dll, dll_in_lib);
    deleteIfPresent(io, join(a, &.{ lib_dir, "libSDL2.a" }));
    deleteIfPresent(io, join(a, &.{ lib_dir, "libSDL2_test.a" }));
    std.Io.Dir.cwd().deleteFile(io, tarball) catch {};

    if (util.fileExists(importlib) and util.fileExists(dll_in_lib)) {
        std.debug.print("  SDL2 ready: {s}\n", .{lib_dir});
        return .ready;
    }
    std.debug.print("  provisioning incomplete (unexpected package layout).\n", .{});
    return .failed;
}

// ── Helpers ─────────────────────────────────────────────────────────────

fn join(a: std.mem.Allocator, parts: []const []const u8) ?[]u8 {
    return std.fs.path.join(a, parts) catch null;
}

fn runOk(a: std.mem.Allocator, argv: []const []const u8) bool {
    const res = util.runCmd(a, argv) catch return false;
    return switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

/// Copy a file by reading then writing (avoids depending on a copyFile API
/// shape). SDL2.dll is a few MB; the 64 MiB limit is comfortable headroom.
fn copyFileVia(a: std.mem.Allocator, io: std.Io, src: []const u8, dst: []const u8) void {
    const data = std.Io.Dir.cwd().readFileAlloc(io, src, a, .limited(64 << 20)) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = data }) catch {};
}

fn deleteIfPresent(io: std.Io, path: ?[]const u8) void {
    if (path) |p| std.Io.Dir.cwd().deleteFile(io, p) catch {};
}
