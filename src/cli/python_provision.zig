//! Standalone Python provisioning for the wasm toolchain.
//!
//! bgfx→wasm builds need Python: emsdk's activation can't populate the
//! emscripten sysroot without it, and `emcc` itself is a Python script (its
//! shebang is `env python3`). A typical Windows box has no Python (only the
//! Store stub); macOS usually ships `python3`, but a bare one may not.
//!
//! We ship ONE full `python-build-standalone` distro into `~/.labelle/python/`
//! and put it on the build env's PATH — it drives BOTH emsdk activation and
//! emcc. (The python.org *embeddable* distro is smaller but its `._pth`
//! sys.path isolation breaks emcc's `from tools import …`; verified during the
//! WI-0 spike — see RFC-windows-install.md.)
//!
//! Windows + macOS supported; the macOS path is written but not yet run on a
//! real Mac. Mirrors `zig_provision.zig`.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const util = @import("util.zig");
const asm_cache = @import("asm_cache.zig");

const is_windows = builtin.os.tag == .windows;
const path_sep: u8 = if (is_windows) ';' else ':';

// Pinned python-build-standalone release (install_only = relocatable, includes
// pip/venv). The archive's single top-level dir is `python/`, stripped on
// extract.
pub const PY_VERSION = "3.11.9";
const PY_RELEASE = "20240814";

/// Platform Python download: the build-standalone target triple + its pinned
/// SHA-256 (release `.sha256` sidecar). Verified before extraction (WI-6).
/// Comptime-resolved; `null` = no managed provisioning for this platform.
const PyDist = struct { triple: []const u8, sha256: []const u8 };

fn pyDist() ?PyDist {
    return switch (builtin.os.tag) {
        .windows => .{ .triple = "x86_64-pc-windows-msvc", .sha256 = "4c71d25731214b8a960d1d87510f24179d819249c5b434aaf7135818421b6215" },
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => .{ .triple = "aarch64-apple-darwin", .sha256 = "8760e908f25fdc8a01f4d1b101854ac047b4eacb723fb2593a168fb989c86eef" },
            .x86_64 => .{ .triple = "x86_64-apple-darwin", .sha256 = "76073305812c093ce840df9c4c17068aa69da8d951e7376ef48f43376986a13e" },
            else => null,
        },
        else => null,
    };
}

/// True when this platform has a pinned managed-Python distribution — i.e.
/// `labelle install python` can actually fix a missing interpreter here
/// (doctor's `fixable` flag keys off this, cli#291).
pub fn managedProvisioningSupported() bool {
    return pyDist() != null;
}

pub const Result = enum {
    /// Python is present (freshly provisioned or already there).
    ready,
    /// Printed guidance (unsupported platform) — user action needed.
    guided,
    /// Download / extract / verify failed.
    failed,
};

/// `<cacheRoot>/python` — the provisioned Python home. Caller owns.
pub fn pythonDir(allocator: std.mem.Allocator) ![]u8 {
    const root = try asm_cache.getCacheRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "python" });
}

/// The interpreter path inside a provisioned `<py_dir>`: `python.exe` (Windows,
/// at root) vs `bin/python3` (macOS/Linux).
fn interpreterPath(a: std.mem.Allocator, py_dir: []const u8) ?[]u8 {
    return if (is_windows)
        join(a, &.{ py_dir, "python.exe" })
    else
        join(a, &.{ py_dir, "bin", "python3" });
}

/// The provisioned interpreter if it exists on disk, else null. Caller owns.
pub fn findPythonExe(a: std.mem.Allocator) ?[]const u8 {
    const dir = pythonDir(a) catch return null;
    defer a.free(dir);
    const exe = interpreterPath(a, dir) orelse return null;
    if (util.fileExists(exe)) return exe;
    a.free(exe);
    return null;
}

/// True if a system Python usable by the wasm toolchain runs (exit 0).
/// On non-Windows this probes ONLY `python3` — the exact command the emsdk
/// launcher script and emcc's `env python3` shebang resolve — so the
/// preflight/doctor verdict reflects the interpreter activation will
/// actually use (a `python`-only box would pass a laxer probe and then die
/// inside emsdk). On Windows `emsdk.bat` resolves `python` itself, so both
/// spellings are accepted there. Running `--version` also distinguishes a
/// real interpreter from the Windows Store execution-alias stub, which
/// prints "Python was not found" and exits non-zero.
pub fn systemPythonOk(gpa: std.mem.Allocator) bool {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    if (is_windows) {
        return runOk(a, &.{ "python", "--version" }) or runOk(a, &.{ "python3", "--version" });
    }
    return runOk(a, &.{ "python3", "--version" });
}

/// True if a Python usable for the wasm build (emsdk activation + emcc) is
/// available — the managed one under `~/.labelle/python`, or a working system
/// `python`/`python3` on PATH. Lets the wasm build fail fast with an
/// actionable message instead of dying deep in emsdk activation.
pub fn isAvailable(gpa: std.mem.Allocator) bool {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    if (findPythonExe(a) != null) return true;
    return systemPythonOk(gpa);
}

/// Ensure a standalone Python exists, downloading it if the platform is
/// supported.
pub fn provisionPython(gpa: std.mem.Allocator) Result {
    if (pyDist() == null) {
        std.debug.print(
            \\
            \\  Managed Python auto-provisioning isn't available for this platform yet.
            \\  Install Python 3 yourself (emsdk + emcc need it) and ensure
            \\  `python3` is on PATH.
            \\
        , .{});
        return .guided;
    }
    return provisionInto(gpa);
}

fn provisionInto(gpa: std.mem.Allocator) Result {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const io = config.globalIo();
    const dist = pyDist().?;

    const cache_root = asm_cache.getCacheRoot(a) catch return .failed;
    const py_dir = join(a, &.{ cache_root, "python" }) orelse return .failed;
    const py_exe = interpreterPath(a, py_dir) orelse return .failed;

    if (util.fileExists(py_exe)) {
        // Validate, don't trust: a half-extracted prior attempt can leave the
        // interpreter present but broken, which would wedge provisioning
        // forever behind this early-exit. If it doesn't run, wipe and
        // reprovision (PR #291 review).
        if (runOk(a, &.{ py_exe, "--version" })) {
            std.debug.print("  Python {s} already provisioned: {s}\n", .{ PY_VERSION, py_dir });
            return .ready;
        }
        std.debug.print("  provisioned Python at {s} is broken — reprovisioning...\n", .{py_dir});
    }

    // Clean start so a partial prior extract can't leave a broken tree.
    std.Io.Dir.cwd().deleteTree(io, py_dir) catch {};
    std.Io.Dir.cwd().createDirPath(io, py_dir) catch return .failed;

    const archive = join(a, &.{ cache_root, "python-download.tar.gz" }) orelse return .failed;
    const url = std.fmt.allocPrint(
        a,
        "https://github.com/astral-sh/python-build-standalone/releases/download/" ++
            PY_RELEASE ++ "/cpython-" ++ PY_VERSION ++ "+" ++ PY_RELEASE ++ "-{s}-install_only.tar.gz",
        .{dist.triple},
    ) catch return .failed;

    std.debug.print("  downloading Python {s} (python-build-standalone)...\n    {s}\n", .{ PY_VERSION, url });
    // Bounded timeouts so a stalled mirror can't hang the install/preflight
    // (PR #291 review): 30s to connect, 10min for the whole ~25 MB transfer.
    if (!runOk(a, &.{ "curl", "-fSL", "--connect-timeout", "30", "--max-time", "600", "-o", archive, url })) {
        std.debug.print("  download failed (is curl on PATH?).\n", .{});
        return .failed;
    }

    // Integrity: verify the download against the pinned hash before extracting.
    const arc_data = std.Io.Dir.cwd().readFileAlloc(io, archive, a, .limited(256 << 20)) catch {
        std.debug.print("  could not read the download to verify it.\n", .{});
        return .failed;
    };
    if (!util.sha256Matches(arc_data, dist.sha256)) {
        std.debug.print("  checksum mismatch — refusing the Python download (expected {s}).\n", .{dist.sha256});
        std.Io.Dir.cwd().deleteFile(io, archive) catch {};
        return .failed;
    }

    std.debug.print("  extracting...\n", .{});
    if (!extractArchive(a, archive, py_dir)) {
        std.debug.print("  extract failed.\n", .{});
        return .failed;
    }
    std.Io.Dir.cwd().deleteFile(io, archive) catch {};

    if (!util.fileExists(py_exe) or !runOk(a, &.{ py_exe, "--version" })) {
        std.debug.print("  provisioning incomplete (python missing or won't run).\n", .{});
        return .failed;
    }

    std.debug.print("  Python {s} ready: {s}\n", .{ PY_VERSION, py_dir });
    return .ready;
}

/// Extract the `.tar.gz` so its contents land directly in `py_dir`
/// (`--strip-components=1` drops the leading `python/` wrapper).
fn extractArchive(a: std.mem.Allocator, archive: []const u8, py_dir: []const u8) bool {
    if (is_windows) {
        // Windows system bsdtar (NOT a PATH `tar`, often GNU tar).
        const sysroot = envOwned(a, "SystemRoot") orelse "C:\\Windows";
        const tar_exe = join(a, &.{ sysroot, "System32", "tar.exe" }) orelse return false;
        if (!util.fileExists(tar_exe)) return false;
        return runOk(a, &.{ tar_exe, "-xzf", archive, "-C", py_dir, "--strip-components=1" });
    }
    return runOk(a, &.{ "tar", "-xzf", archive, "-C", py_dir, "--strip-components=1" });
}

/// Prepend the provisioned Python's dir to THIS process's PATH so the `zig
/// build` children (emsdk activation + emcc's `env python3` shebang) resolve
/// `python3`. No-op when Python isn't provisioned or it's already on PATH.
/// (macOS with a system `python3` doesn't need this — it only matters when we
/// provisioned our own.)
pub fn autoWireEnv(gpa: std.mem.Allocator) void {
    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();

    const py_exe = findPythonExe(a) orelse return; // nothing provisioned
    // Windows: dirname → `<py>` (holds python.exe). macOS/Linux: dirname →
    // `<py>/bin` (holds python3) — exactly the dir we want on PATH.
    const bin_dir = std.fs.path.dirname(py_exe) orelse return;

    // Wire the TLS trust store BEFORE the PATH short-circuit below, so a build
    // where the Python dir is already on PATH still gets SSL_CERT_FILE.
    if (is_windows) wireCertBundle(a, bin_dir);

    const env = config.globalEnviron();
    const old_path = (env.getAlloc(a, "PATH") catch null) orelse "";
    var seg_it = std.mem.splitScalar(u8, old_path, path_sep);
    while (seg_it.next()) |seg| {
        const present = if (is_windows) util.windowsPathEql(seg, bin_dir) else std.mem.eql(u8, seg, bin_dir);
        if (present) return; // already present
    }
    const new_path = std.fmt.allocPrint(a, "{s}{c}{s}", .{ bin_dir, path_sep, old_path }) catch return;
    setPathEnv(a, new_path);
    std.debug.print("labelle: using provisioned Python ({s})\n", .{bin_dir});
}

// ── Helpers ─────────────────────────────────────────────────────────────

/// Windows only. Zig's `std.http` package fetch and emsdk activation validate
/// TLS against the Windows certificate store, which is unpopulated on a fresh
/// machine — so a clean-box wasm build dies with `CertificateBundleLoadFailure`
/// (and emsdk's node download with `CERTIFICATE_VERIFY_FAILED`) before any
/// compilation. Point `SSL_CERT_FILE` — which zig's `Certificate.Bundle.rescan`
/// and emsdk's Python both honor — at the CA bundle already shipped inside the
/// provisioned Python (pip's vendored certifi), so every child `zig`/`emsdk`
/// process (including the nested assembler build) has a trust store. Respects a
/// user-set `SSL_CERT_FILE`; no-op if the bundle isn't found.
fn wireCertBundle(a: std.mem.Allocator, python_root: []const u8) void {
    const env = config.globalEnviron();
    if (env.getAlloc(a, "SSL_CERT_FILE") catch null) |existing| {
        if (existing.len > 0) return; // don't clobber the user's bundle
    }
    const bundle = join(a, &.{ python_root, "Lib", "site-packages", "pip", "_vendor", "certifi", "cacert.pem" }) orelse return;
    if (!util.fileExists(bundle)) return;
    setEnvVar(a, "SSL_CERT_FILE", bundle);
    std.debug.print("labelle: using CA bundle for TLS ({s})\n", .{bundle});
}

fn join(a: std.mem.Allocator, parts: []const []const u8) ?[]u8 {
    return std.fs.path.join(a, parts) catch null;
}

fn envOwned(a: std.mem.Allocator, key: []const u8) ?[]u8 {
    const env = config.globalEnviron();
    return env.getAlloc(a, key) catch null;
}

fn runOk(a: std.mem.Allocator, argv: []const []const u8) bool {
    const res = util.runCmd(a, argv) catch return false;
    return switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

fn setPathEnv(a: std.mem.Allocator, value: []const u8) void {
    setEnvVar(a, "PATH", value);
}

/// Set an env var on the current process so spawned children inherit it.
/// Windows uses the Win32 env block; POSIX uses libc `setenv` (the CLI links
/// libc).
fn setEnvVar(a: std.mem.Allocator, name: []const u8, value: []const u8) void {
    if (is_windows) {
        const name_w = std.unicode.utf8ToUtf16LeAllocZ(a, name) catch return;
        const value_w = std.unicode.utf8ToUtf16LeAllocZ(a, value) catch return;
        _ = SetEnvironmentVariableW(name_w.ptr, value_w.ptr);
    } else {
        const name_z = a.dupeZ(u8, name) catch return;
        const value_z = a.dupeZ(u8, value) catch return;
        _ = setenv(name_z.ptr, value_z.ptr, 1);
    }
}

extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) i32;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
