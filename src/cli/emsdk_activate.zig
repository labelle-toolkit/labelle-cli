//! Activate the FETCHED zig-package emsdk in place — the remaining half of
//! labelle-assembler#492 (the CLI sibling of `emsdk_toolchain.zig`).
//!
//! `emsdk_toolchain.ensureInstalled` fetches + activates a MANAGED emsdk under
//! `~/.labelle/emsdk/` and `runner.buildWasmEnv` wires EMSDK/EM_CONFIG/PATH onto
//! the `zig build` spawn. That covers a build whose `emcc` resolves via
//! PATH/env — but the assembler-generated backend hooks (bgfx/sokol/raylib)
//! DON'T: they link via `b.dependency("emsdk").path("upstream/emscripten/emcc")`,
//! i.e. the emsdk git checkout Zig fetched into the project-local
//! `<build_dir>/zig-pkg/<hash>/` (or the global package cache). That package is
//! FETCHED but NOT ACTIVATED — `emcc` is materialized only by `emsdk install` +
//! `emsdk activate` — so a fresh `labelle build --platform wasm` dies with
//! `FileNotFound` on `upstream/emscripten/emcc` (labelle-assembler#492). No
//! amount of managed-emsdk env wiring fixes it because the hook ignores
//! EMSDK/PATH. So we mirror the docker path's `activate_emsdk` snippet
//! (`docker.zig`) on the HOST: locate the fetched package and run activation IN
//! PLACE so the subsequent `zig build` finds `emcc`.

const std = @import("std");
const builtin = @import("builtin");
const emsdk_cache = @import("emsdk_cache.zig");
const zig_cache = @import("zig_cache.zig");
const config = @import("config.zig");
const emsdk_toolchain = @import("emsdk_toolchain.zig");

const is_windows = builtin.os.tag == .windows;

/// Auto-activate the fetched zig-package emsdk for a wasm build (the remaining
/// half of labelle-assembler#492). Call AFTER dependencies are fetched (e.g.
/// after the fingerprint `zig build --list-steps` pass) and BEFORE the real
/// `zig build`, on the host wasm path only.
///
/// Best-effort by contract: idempotent (skips when `emcc` already exists),
/// serialized behind an fs2 advisory lock (concurrent builds don't race), and
/// NON-fatal — on any failure (package not yet fetched, no network, activation
/// error) it logs and returns so the build still surfaces the clear #492
/// fallback error. `version` is the PINNED emsdk version (never `latest`), so
/// activation is deterministic.
pub fn activateFetchedEmsdk(allocator: std.mem.Allocator, build_dir: []const u8, version: []const u8) void {
    activateFetchedEmsdkImpl(allocator, build_dir, version) catch |err| {
        std.debug.print(
            "labelle: emsdk auto-activation skipped ({any}); if the wasm build cannot find emcc, see labelle-assembler#492\n",
            .{err},
        );
    };
}

fn activateFetchedEmsdkImpl(allocator: std.mem.Allocator, build_dir: []const u8, version: []const u8) !void {
    // `version` reaches `emsdk install/activate <ver>` as an argument; guard it
    // the same way `emsdk_toolchain.ensureInstalled` does.
    if (!emsdk_toolchain.isSafeVersion(version)) return error.EmsdkInvalidVersion;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const pkg = (try locateFetchedEmsdk(allocator, build_dir)) orelse return;
    defer allocator.free(pkg);

    const emcc_path = try std.fs.path.join(allocator, &.{ pkg, emsdk_cache.emcc_relpath });
    defer allocator.free(emcc_path);
    // Fast path: already activated (emcc present), no lock contention.
    if (cwd.access(io, emcc_path, .{})) |_| return else |_| {}

    // Serialize activation of the SAME package across processes with an
    // advisory lock (mirrors `ensureInstalled`): two concurrent `labelle wasm`
    // builds could otherwise run `emsdk install` in the same dir at once. Key
    // the lock on a hash of the package path so distinct projects/caches don't
    // block each other. The lock releases when the holder exits.
    const eroot = try emsdk_cache.emsdkRoot(allocator);
    defer allocator.free(eroot);
    cwd.createDirPath(io, eroot) catch {};
    const lock_path = try std.fmt.allocPrint(allocator, "{s}{c}pkg-{x}.lock", .{ eroot, std.fs.path.sep, std.hash.Wyhash.hash(0, pkg) });
    defer allocator.free(lock_path);
    const lock_file = cwd.createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive }) catch |err| {
        std.debug.print("labelle: could not acquire emsdk activation lock {s}: {any}\n", .{ lock_path, err });
        return error.EmsdkInstallLockFailed;
    };
    defer lock_file.close(io); // releases the advisory lock

    // Double-checked: another process may have finished activating while we
    // were blocked on the lock.
    if (cwd.access(io, emcc_path, .{})) |_| return else |_| {}

    // Zig marks fetched package dirs read-only; `emsdk install` must create
    // `upstream/`, `node/`, `.emscripten` under this tree. Make it writable +
    // the launcher executable (both best-effort).
    makeTreeWritable(pkg);
    const launcher = try std.fs.path.join(allocator, &.{ pkg, emsdk_cache.emsdk_launcher_name });
    defer allocator.free(launcher);
    if (!is_windows) {
        if (cwd.openFile(io, launcher, .{})) |file| {
            defer file.close(io);
            file.setPermissions(io, .fromMode(0o755)) catch {};
        } else |_| {}
    }

    std.debug.print("labelle: activating fetched emsdk {s} for wasm (labelle-assembler#492)...\n", .{version});
    std.debug.print("  {s}\n", .{pkg});
    std.debug.print("  emsdk install {s}...\n", .{version});
    try emsdk_toolchain.activateStep(allocator, launcher, pkg, "install", version);
    std.debug.print("  emsdk activate {s}...\n", .{version});
    try emsdk_toolchain.activateStep(allocator, launcher, pkg, "activate", version);

    // Sanity: emcc must exist now, else the build will still fail — surface why.
    cwd.access(io, emcc_path, .{}) catch {
        std.debug.print("labelle: emsdk {s} activated but '{s}' is still missing under {s}\n", .{ version, emsdk_cache.emcc_relpath, pkg });
        return error.EmsdkActivationIncomplete;
    };
    std.debug.print("  emcc ready ({s})\n", .{emcc_path});
}

/// Locate the fetched emsdk package dir — a directory that directly contains
/// the emsdk launcher, i.e. the checkout `b.dependency("emsdk")` resolves to.
/// Searches, in order:
///   1. `<build_dir>/zig-pkg/` — the project-local vendored package dir the
///      assembler-generated build uses.
///   2. `<zig-global-cache>/p/` — the shared package cache fallback.
/// Returns the first match (heap-owned; caller frees), or null when none is
/// found (not fetched yet / unusual layout). Never errors on a missing dir.
fn locateFetchedEmsdk(allocator: std.mem.Allocator, build_dir: []const u8) !?[]u8 {
    {
        const root = try std.fs.path.join(allocator, &.{ build_dir, "zig-pkg" });
        defer allocator.free(root);
        if (try findEmsdkUnder(allocator, root)) |p| return p;
    }
    if (zig_cache.globalCacheDir(allocator)) |gc| {
        defer allocator.free(gc);
        const root = try std.fs.path.join(allocator, &.{ gc, "p" });
        defer allocator.free(root);
        if (try findEmsdkUnder(allocator, root)) |p| return p;
    } else |_| {}
    return null;
}

/// Scan the immediate subdirs of `root` for an emsdk checkout — a dir that
/// contains BOTH the `emsdk` launcher and `emsdk.py` (the emsdk-repo signature,
/// so a same-named dir from another package can't false-match). Returns the
/// first match (heap-owned), or null. A missing/unopenable `root` yields null.
fn findEmsdkUnder(allocator: std.mem.Allocator, root: []const u8) !?[]u8 {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, root, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const cand = try std.fs.path.join(allocator, &.{ root, entry.name });
        const launcher = try std.fs.path.join(allocator, &.{ cand, emsdk_cache.emsdk_launcher_name });
        defer allocator.free(launcher);
        const emsdk_py = try std.fs.path.join(allocator, &.{ cand, "emsdk.py" });
        defer allocator.free(emsdk_py);
        const has_launcher = !std.meta.isError(cwd.access(io, launcher, .{}));
        const has_py = !std.meta.isError(cwd.access(io, emsdk_py, .{}));
        if (has_launcher and has_py) return cand;
        allocator.free(cand);
    }
    return null;
}

/// Best-effort: add owner rwx to `root` and every directory beneath it so an
/// `emsdk install` can create files under Zig's read-only package tree. Only
/// directories are touched — creating new files needs a writable PARENT dir;
/// pre-activation regular files staying read-only doesn't block that. Never
/// fails the caller. No-op on Windows (fetched package files aren't marked
/// read-only via POSIX mode bits there).
fn makeTreeWritable(root: []const u8) void {
    if (!is_windows) {
        const io = config.globalIo();
        const cwd = std.Io.Dir.cwd();
        var dir = cwd.openDir(io, root, .{ .iterate = true }) catch return;
        defer dir.close(io);
        dir.setPermissions(io, .fromMode(0o755)) catch {};
        var walker = dir.walk(std.heap.page_allocator) catch return;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            entry.dir.setFilePermissions(io, entry.basename, .fromMode(0o755), .{}) catch {};
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const asm_cache = @import("asm_cache.zig");
const DEFAULT_EMSDK_VERSION = emsdk_toolchain.DEFAULT_EMSDK_VERSION;

/// Records which emsdk steps ran and, on `activate`, materializes the `emcc`
/// file in the target dir so the post-activation sanity check + the idempotent
/// fast path see exactly what a real activation would produce. Mirrors the
/// recorder in `emsdk_toolchain.zig`, scoped to the in-place activation.
const StepRecorder = struct {
    var saw_clone: bool = false;
    var saw_install: bool = false;
    var saw_activate: bool = false;

    fn reset() void {
        saw_clone = false;
        saw_install = false;
        saw_activate = false;
    }

    fn exec(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) anyerror!emsdk_toolchain.ExecResult {
        for (argv) |a| {
            if (std.mem.eql(u8, a, "clone")) saw_clone = true;
            if (std.mem.eql(u8, a, "install")) saw_install = true;
            if (std.mem.eql(u8, a, "activate")) saw_activate = true;
        }
        if (saw_activate) {
            const dir = cwd orelse return .{ .exit_code = 1 };
            const io = config.globalIo();
            const em_dir = try std.fs.path.join(allocator, &.{ dir, "upstream", "emscripten" });
            defer allocator.free(em_dir);
            std.Io.Dir.cwd().createDirPath(io, em_dir) catch {};
            const emcc = try std.fs.path.join(allocator, &.{ em_dir, emsdk_cache.emcc_name });
            defer allocator.free(emcc);
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = emcc, .data = "#!/bin/sh\n" }) catch {};
        }
        return .{ .exit_code = 0 };
    }
};

/// Stage a fetched-but-UNACTIVATED emsdk checkout under
/// `<build_dir>/zig-pkg/<hash>/` (launcher + `emsdk.py`, no `upstream/`), the
/// exact shape `locateFetchedEmsdk` looks for. Returns the owned pkg path.
fn stageFetchedEmsdkPkg(alloc: std.mem.Allocator, build_dir: []const u8) ![]u8 {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const pkg = try std.fs.path.join(alloc, &.{ build_dir, "zig-pkg", "N-V-fakeemsdkhash" });
    try cwd.createDirPath(io, pkg);
    const launcher = try std.fs.path.join(alloc, &.{ pkg, emsdk_cache.emsdk_launcher_name });
    defer alloc.free(launcher);
    try cwd.writeFile(io, .{ .sub_path = launcher, .data = "#!/bin/sh\n" });
    const py = try std.fs.path.join(alloc, &.{ pkg, "emsdk.py" });
    defer alloc.free(py);
    try cwd.writeFile(io, .{ .sub_path = py, .data = "# emsdk\n" });
    return pkg;
}

test "activateFetchedEmsdk activates the fetched zig-package emsdk in place, idempotently" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(config.globalIo(), &buf);
    const root = buf[0..n];

    asm_cache.setCacheRootOverride(root);
    defer asm_cache.clearCacheRootOverride();
    StepRecorder.reset();
    emsdk_toolchain.setExecOverrideForTest(StepRecorder.exec);
    defer emsdk_toolchain.setExecOverrideForTest(null);

    const build_dir = try std.fs.path.join(alloc, &.{ root, "build" });
    defer alloc.free(build_dir);
    const pkg = try stageFetchedEmsdkPkg(alloc, build_dir);
    defer alloc.free(pkg);

    // Not activated yet: emcc absent.
    const emcc_path = try std.fs.path.join(alloc, &.{ pkg, emsdk_cache.emcc_relpath });
    defer alloc.free(emcc_path);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(config.globalIo(), emcc_path, .{}));

    activateFetchedEmsdk(alloc, build_dir, DEFAULT_EMSDK_VERSION);

    // The #492 fix: install + activate ran IN PLACE (no clone — the package is
    // already fetched), and emcc now exists where the build's link step looks.
    try testing.expect(!StepRecorder.saw_clone);
    try testing.expect(StepRecorder.saw_install);
    try testing.expect(StepRecorder.saw_activate);
    try std.Io.Dir.cwd().access(config.globalIo(), emcc_path, .{});

    // Idempotent: a second call is a no-op fast path (emcc already present).
    StepRecorder.reset();
    activateFetchedEmsdk(alloc, build_dir, DEFAULT_EMSDK_VERSION);
    try testing.expect(!StepRecorder.saw_install);
    try testing.expect(!StepRecorder.saw_activate);
}

test "activateFetchedEmsdk is a no-op (no steps, no error) when no emsdk package is fetched" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(config.globalIo(), &buf);
    const root = buf[0..n];

    asm_cache.setCacheRootOverride(root);
    defer asm_cache.clearCacheRootOverride();
    StepRecorder.reset();
    emsdk_toolchain.setExecOverrideForTest(StepRecorder.exec);
    defer emsdk_toolchain.setExecOverrideForTest(null);

    // build_dir has no zig-pkg/ at all — nothing to locate.
    const build_dir = try std.fs.path.join(alloc, &.{ root, "empty-build" });
    defer alloc.free(build_dir);
    std.Io.Dir.cwd().createDirPath(config.globalIo(), build_dir) catch {};

    activateFetchedEmsdk(alloc, build_dir, DEFAULT_EMSDK_VERSION);
    try testing.expect(!StepRecorder.saw_install);
    try testing.expect(!StepRecorder.saw_activate);
}

test "activateFetchedEmsdk ignores an unsafe version without running any step" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(config.globalIo(), &buf);
    const root = buf[0..n];

    asm_cache.setCacheRootOverride(root);
    defer asm_cache.clearCacheRootOverride();
    StepRecorder.reset();
    emsdk_toolchain.setExecOverrideForTest(StepRecorder.exec);
    defer emsdk_toolchain.setExecOverrideForTest(null);

    const build_dir = try std.fs.path.join(alloc, &.{ root, "build" });
    defer alloc.free(build_dir);
    const pkg = try stageFetchedEmsdkPkg(alloc, build_dir);
    defer alloc.free(pkg);

    // Unsafe version rejected before spawning `emsdk` (guarded, non-fatal).
    activateFetchedEmsdk(alloc, build_dir, "../../etc");
    try testing.expect(!StepRecorder.saw_install);
    try testing.expect(!StepRecorder.saw_activate);
}
