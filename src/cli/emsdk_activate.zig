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

    const located = (try locateFetchedEmsdk(allocator, build_dir)) orelse return;
    defer allocator.free(located);

    // Canonicalize to an ABSOLUTE path. `activateStep` sets the child cwd to
    // `pkg` and execs the launcher (argv[0]); a RELATIVE launcher would resolve
    // against pkg itself → a nonexistent nested `pkg/<relative>/emsdk` → ENOENT
    // → activation silently skips and the wasm build still dies with #492. The
    // common `labelle build --platform wasm` reaches here with a relative
    // build_dir → relative pkg, so this matters. `located` exists (we just
    // found it), so realPath resolves. The absolute path also keys the advisory
    // lock canonically, so relative-vs-absolute spellings share one lock. (F1/F2)
    const pkg = try cwd.realPathFileAlloc(io, located, allocator);
    defer allocator.free(pkg);

    const emcc_path = try std.fs.path.join(allocator, &.{ pkg, emsdk_cache.emcc_relpath });
    defer allocator.free(emcc_path);
    // `.emscripten` (EM_CONFIG) at the pkg root is the activation-completion
    // marker: `emsdk install` can create `upstream/.../emcc` before `activate`
    // writes this file. Treating the checkout as done on `emcc` alone would let
    // a half-activated (interrupted-after-install) tree fast-path forever while
    // the build still fails — so the done-check requires BOTH. (F3)
    const marker_path = try std.fs.path.join(allocator, &.{ pkg, emsdk_cache.em_config_name });
    defer allocator.free(marker_path);
    // Fast path: already fully activated (emcc + marker present), no lock.
    if (isActivated(io, cwd, emcc_path, marker_path)) return;

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
    if (isActivated(io, cwd, emcc_path, marker_path)) return;

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

    // Sanity: emcc AND the `.emscripten` marker must exist now, else the build
    // will still fail — surface why.
    if (!isActivated(io, cwd, emcc_path, marker_path)) {
        std.debug.print("labelle: emsdk {s} activated but '{s}' or '{s}' is still missing under {s}\n", .{ version, emsdk_cache.emcc_relpath, emsdk_cache.em_config_name, pkg });
        return error.EmsdkActivationIncomplete;
    }
    std.debug.print("  emcc ready ({s})\n", .{emcc_path});
}

/// A checkout is fully activated only when BOTH `emcc` (from `emsdk install`)
/// AND the `.emscripten` EM_CONFIG marker (from `emsdk activate`) exist — an
/// interrupted activation can leave `emcc` present with no marker, which must
/// re-activate rather than fast-path forever. (F3)
fn isActivated(io: std.Io, cwd: std.Io.Dir, emcc_path: []const u8, marker_path: []const u8) bool {
    if (std.meta.isError(cwd.access(io, emcc_path, .{}))) return false;
    if (std.meta.isError(cwd.access(io, marker_path, .{}))) return false;
    return true;
}

/// Locate the fetched emsdk package dir — a directory that directly contains
/// the emsdk launcher, i.e. the checkout `b.dependency("emsdk")` resolves to.
/// Searches, in order:
///   1. `<build_dir>/zig-pkg/` — the project-local vendored package dir the
///      assembler-generated build uses.
///   2. `<zig-global-cache>/p/<hash>/` — the shared package cache, resolved
///      PRECISELY from the emsdk dep hash in the target's generated
///      `build.zig.zon` (labelle-cli#294), falling back to a heuristic scan
///      only when that metadata can't be read.
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

        // Precise resolution (labelle-cli#294): the emsdk dep's `.hash` in the
        // target's generated build.zig.zon IS exactly the `<gc>/p/<hash>/`
        // package-cache subdir name, so we can point at the SAME checkout the
        // build's `b.dependency("emsdk")` link step resolves — deterministically,
        // instead of guessing the first emsdk-shaped dir. If the hash is known
        // but its dir isn't a (fully-fetched) emsdk checkout, we return null
        // rather than heuristically activating a DIFFERENT, wrong checkout.
        if (readEmsdkDepHash(allocator, build_dir)) |hash| {
            defer allocator.free(hash);
            const cand = try std.fs.path.join(allocator, &.{ root, hash });
            if (try isEmsdkDir(cand)) return cand;
            allocator.free(cand);
            return null;
        }

        // Metadata unreadable (no build.zig.zon / older assembler layout / no
        // emsdk dep entry): last-resort heuristic pick of the first emsdk-shaped
        // dir under the global cache — could be an older/unrelated checkout, so
        // warn loudly. (F4 mitigation, retained for the metadata-missing case.)
        if (try findEmsdkUnder(allocator, root)) |p| {
            std.debug.print(
                "labelle: could not read the emsdk dep hash from <build_dir>/build.zig.zon; falling back to a heuristic pick from the global package cache ({s}) — if the wasm build activates the wrong emsdk, see labelle-cli#294\n",
                .{p},
            );
            return p;
        }
    } else |_| {}
    return null;
}

/// Read the `emsdk` dependency's package `.hash` from the target's generated
/// `<build_dir>/build.zig.zon`. That hash is exactly the `<gc>/p/<hash>/`
/// package-cache subdir name, so it resolves the fetched checkout precisely
/// (labelle-cli#294). Returns a heap-owned hash (caller frees), or null when
/// the file/dep/hash is absent, unparsable, or not a safe single path
/// component. Best-effort: never errors (the caller falls back).
fn readEmsdkDepHash(allocator: std.mem.Allocator, build_dir: []const u8) ?[]u8 {
    @setEvalBranchQuota(10000);
    const zon_path = std.fs.path.join(allocator, &.{ build_dir, "build.zig.zon" }) catch return null;
    defer allocator.free(zon_path);
    const raw = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), zon_path, allocator, .limited(1 << 20)) catch return null;
    defer allocator.free(raw);
    const raw_z = allocator.dupeZ(u8, raw) catch return null;
    defer allocator.free(raw_z);

    // Partial shape: `ignore_unknown_fields` skips every other manifest field
    // (name, version, fingerprint, paths) and every non-emsdk dependency, as
    // well as the emsdk dep's own `.url`/`.lazy` — we want only `.hash`.
    const ZonShape = struct {
        dependencies: ?struct {
            emsdk: ?struct { hash: []const u8 = "" } = null,
        } = null,
    };
    const parsed = std.zon.parse.fromSliceAlloc(ZonShape, allocator, raw_z, null, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer std.zon.parse.free(allocator, parsed);

    const deps = parsed.dependencies orelse return null;
    const emsdk = deps.emsdk orelse return null;
    if (!isSafeCacheHash(emsdk.hash)) return null;
    return allocator.dupe(u8, emsdk.hash) catch return null;
}

/// A Zig package hash is a single path component drawn from the multihash
/// base64url alphabet (`[A-Za-z0-9_-]`). Reject anything else so a hostile or
/// malformed build.zig.zon can't turn `<gc>/p/<hash>` into a traversal
/// (`../…`) or an absolute path. Empty is rejected.
fn isSafeCacheHash(hash: []const u8) bool {
    if (hash.len == 0) return false;
    for (hash) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// True when `cand` is a fetched emsdk checkout — a dir that contains BOTH the
/// `emsdk` launcher and `emsdk.py` (the emsdk-repo signature, so a same-named
/// dir from another package can't false-match). Never errors.
fn isEmsdkDir(cand: []const u8) !bool {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const launcher = try std.fs.path.join(std.heap.page_allocator, &.{ cand, emsdk_cache.emsdk_launcher_name });
    defer std.heap.page_allocator.free(launcher);
    const emsdk_py = try std.fs.path.join(std.heap.page_allocator, &.{ cand, "emsdk.py" });
    defer std.heap.page_allocator.free(emsdk_py);
    if (std.meta.isError(cwd.access(io, launcher, .{}))) return false;
    if (std.meta.isError(cwd.access(io, emsdk_py, .{}))) return false;
    return true;
}

/// Scan the immediate subdirs of `root` for an emsdk checkout. Returns the
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
        if (try isEmsdkDir(cand)) return cand;
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
    /// The launcher (argv[0], or argv[2] under the Windows `cmd /c` wrapper)
    /// the last step exec'd with — captured so a test can assert it is an
    /// ABSOLUTE path (the child cwd is `pkg`, so a relative launcher fails to
    /// resolve). Owned by `page_allocator`; freed/replaced on the next exec.
    var last_launcher: ?[]u8 = null;
    /// When true, `activate` writes only `emcc` and NOT the `.emscripten`
    /// marker — simulating an activation interrupted after `install`. (F3)
    var skip_marker: bool = false;

    fn reset() void {
        saw_clone = false;
        saw_install = false;
        saw_activate = false;
        if (last_launcher) |l| std.heap.page_allocator.free(l);
        last_launcher = null;
        skip_marker = false;
    }

    fn exec(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) anyerror!emsdk_toolchain.ExecResult {
        for (argv) |a| {
            if (std.mem.eql(u8, a, "clone")) saw_clone = true;
            if (std.mem.eql(u8, a, "install")) saw_install = true;
            if (std.mem.eql(u8, a, "activate")) saw_activate = true;
        }
        // Launcher is argv[2] under the Windows `cmd /c <launcher>` wrapper,
        // argv[0] otherwise.
        const launcher_idx: usize = if (is_windows and argv.len >= 3 and std.mem.eql(u8, argv[0], "cmd")) 2 else 0;
        if (argv.len > launcher_idx) {
            if (last_launcher) |l| std.heap.page_allocator.free(l);
            last_launcher = try std.heap.page_allocator.dupe(u8, argv[launcher_idx]);
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
            // Real `emsdk activate` also writes the `.emscripten` EM_CONFIG
            // marker at the emsdk root; mirror that so the done-check + the
            // idempotent fast path see what a real activation produces. (F3)
            if (!skip_marker) {
                const marker = try std.fs.path.join(allocator, &.{ dir, emsdk_cache.em_config_name });
                defer allocator.free(marker);
                std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "# emscripten config\n" }) catch {};
            }
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

/// Stage an emsdk-shaped checkout (launcher + `emsdk.py`) directly at `pkg`.
/// Used to place a fetched emsdk under `<gc>/p/<hash>/` for the precise
/// global-cache resolution tests (labelle-cli#294).
fn stageEmsdkAt(alloc: std.mem.Allocator, pkg: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, pkg);
    const launcher = try std.fs.path.join(alloc, &.{ pkg, emsdk_cache.emsdk_launcher_name });
    defer alloc.free(launcher);
    try cwd.writeFile(io, .{ .sub_path = launcher, .data = "#!/bin/sh\n" });
    const py = try std.fs.path.join(alloc, &.{ pkg, "emsdk.py" });
    defer alloc.free(py);
    try cwd.writeFile(io, .{ .sub_path = py, .data = "# emsdk\n" });
}

/// Write a minimal assembler-shaped `build.zig.zon` under `build_dir` whose
/// `emsdk` dependency carries `hash`, mirroring what the generated wasm target
/// emits. Includes decoy fields/deps so the parse exercises
/// `ignore_unknown_fields`.
fn writeTargetZon(alloc: std.mem.Allocator, build_dir: []const u8, hash: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, build_dir);
    const zon = try std.fmt.allocPrint(alloc,
        \\.{{
        \\    .name = .labelle_target,
        \\    .version = "0.0.0",
        \\    .fingerprint = 0x1234abcd,
        \\    .dependencies = .{{
        \\        .@"labelle-core" = .{{ .path = "../deps/labelle-core" }},
        \\        .emsdk = .{{
        \\            .url = "git+https://github.com/emscripten-core/emsdk#4.0.9",
        \\            .hash = "{s}",
        \\        }},
        \\    }},
        \\    .paths = .{{""}},
        \\}}
        \\
    , .{hash});
    defer alloc.free(zon);
    const zon_path = try std.fs.path.join(alloc, &.{ build_dir, "build.zig.zon" });
    defer alloc.free(zon_path);
    try cwd.writeFile(io, .{ .sub_path = zon_path, .data = zon });
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

test "activateFetchedEmsdk canonicalizes a RELATIVE build_dir to an absolute launcher (F1 regression)" {
    const alloc = testing.allocator;
    const io = config.globalIo();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = buf[0..n];

    // Save + restore the process cwd around the chdir this test needs to make
    // `build_dir` genuinely relative. Hold the original cwd as a dir handle
    // (the special cwd() handle can't realPath) and fchdir back. The restore
    // defer is registered AFTER tmp.cleanup, so (LIFO) cwd is restored before
    // the tmp tree is deleted.
    var orig_dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    defer orig_dir.close(io);
    defer std.process.setCurrentDir(io, orig_dir) catch {};

    asm_cache.setCacheRootOverride(root);
    defer asm_cache.clearCacheRootOverride();
    StepRecorder.reset();
    emsdk_toolchain.setExecOverrideForTest(StepRecorder.exec);
    defer emsdk_toolchain.setExecOverrideForTest(null);

    // Stage the fetched pkg under an ABSOLUTE build dir first...
    const abs_build_dir = try std.fs.path.join(alloc, &.{ root, "build" });
    defer alloc.free(abs_build_dir);
    const pkg = try stageFetchedEmsdkPkg(alloc, abs_build_dir);
    defer alloc.free(pkg);

    // ...then chdir into `root` and drive activation with a RELATIVE build_dir,
    // exactly like `labelle build --platform wasm` from a project directory.
    try std.process.setCurrentPath(io, root);
    activateFetchedEmsdk(alloc, "build", DEFAULT_EMSDK_VERSION);

    // Pre-fix, the launcher exec'd was the RELATIVE `build/zig-pkg/.../emsdk`,
    // which the child (cwd=pkg) resolved against pkg → ENOENT → silent skip
    // (no steps ran). The fix canonicalizes pkg to absolute, so the launcher is
    // absolute and resolves regardless of the child cwd.
    try testing.expect(StepRecorder.saw_install);
    try testing.expect(StepRecorder.saw_activate);
    try testing.expect(StepRecorder.last_launcher != null);
    try testing.expect(std.fs.path.isAbsolute(StepRecorder.last_launcher.?));
}

test "activateFetchedEmsdk re-activates a half-activated checkout (emcc present, .emscripten absent) (F3 regression)" {
    const alloc = testing.allocator;
    const io = config.globalIo();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
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

    // Simulate an activation interrupted after `install`: `emcc` exists but the
    // `.emscripten` EM_CONFIG marker was never written.
    const em_dir = try std.fs.path.join(alloc, &.{ pkg, "upstream", "emscripten" });
    defer alloc.free(em_dir);
    try std.Io.Dir.cwd().createDirPath(io, em_dir);
    const emcc = try std.fs.path.join(alloc, &.{ em_dir, emsdk_cache.emcc_name });
    defer alloc.free(emcc);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = emcc, .data = "#!/bin/sh\n" });

    // Pre-fix (emcc-only done-check) this fast-paths as "done" and runs no
    // steps; post-fix the missing marker forces a re-activation.
    activateFetchedEmsdk(alloc, build_dir, DEFAULT_EMSDK_VERSION);
    try testing.expect(StepRecorder.saw_install);
    try testing.expect(StepRecorder.saw_activate);

    // The re-activation wrote the marker, so the NEXT call fast-paths (both
    // emcc and `.emscripten` present now).
    StepRecorder.reset();
    activateFetchedEmsdk(alloc, build_dir, DEFAULT_EMSDK_VERSION);
    try testing.expect(!StepRecorder.saw_install);
    try testing.expect(!StepRecorder.saw_activate);
}

test "readEmsdkDepHash extracts the emsdk dep hash from the target build.zig.zon (#294)" {
    const alloc = testing.allocator;
    const io = config.globalIo();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = buf[0..n];

    const build_dir = try std.fs.path.join(alloc, &.{ root, "target" });
    defer alloc.free(build_dir);

    const want = "N-V-__8AAJl1DwBezhYo_VE6f53mPVm00R-Fk28NPW7P14EQ";
    try writeTargetZon(alloc, build_dir, want);

    const got = readEmsdkDepHash(alloc, build_dir) orelse return error.NoHash;
    defer alloc.free(got);
    try testing.expectEqualStrings(want, got);

    // No build.zig.zon at all → null (caller falls back to the heuristic).
    const missing_dir = try std.fs.path.join(alloc, &.{ root, "no-zon" });
    defer alloc.free(missing_dir);
    try std.Io.Dir.cwd().createDirPath(io, missing_dir);
    try testing.expect(readEmsdkDepHash(alloc, missing_dir) == null);
}

test "isSafeCacheHash accepts multihash names and rejects traversal (#294)" {
    try testing.expect(isSafeCacheHash("N-V-__8AAJl1DwBezhYo_VE6f53mPVm00R-Fk28NPW7P14EQ"));
    try testing.expect(!isSafeCacheHash(""));
    try testing.expect(!isSafeCacheHash("../../etc/passwd"));
    try testing.expect(!isSafeCacheHash("has/slash"));
    try testing.expect(!isSafeCacheHash("has.dot"));
}

test "activateFetchedEmsdk resolves the EXACT global-cache dir from the dep hash, not the first emsdk-shaped dir (#294)" {
    const alloc = testing.allocator;
    const io = config.globalIo();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = buf[0..n];

    asm_cache.setCacheRootOverride(root);
    defer asm_cache.clearCacheRootOverride();
    StepRecorder.reset();
    emsdk_toolchain.setExecOverrideForTest(StepRecorder.exec);
    defer emsdk_toolchain.setExecOverrideForTest(null);

    // build_dir has NO project-local zig-pkg/, forcing the global-cache path.
    const build_dir = try std.fs.path.join(alloc, &.{ root, "target" });
    defer alloc.free(build_dir);

    const p_root = try std.fs.path.join(alloc, &.{ root, zig_cache.GLOBAL_CACHE_SUBDIR, "p" });
    defer alloc.free(p_root);

    // A DECOY emsdk checkout that would win a first-match heuristic scan (its
    // name sorts before the real hash), plus the CORRECT checkout named by the
    // dep hash. The precise fix must pick the latter.
    const decoy = try std.fs.path.join(alloc, &.{ p_root, "AAAA-decoy-emsdk" });
    defer alloc.free(decoy);
    try stageEmsdkAt(alloc, decoy);

    const want_hash = "N-V-__8AAJl1DwBezhYo_VE6f53mPVm00R-Fk28NPW7P14EQ";
    const correct = try std.fs.path.join(alloc, &.{ p_root, want_hash });
    defer alloc.free(correct);
    try stageEmsdkAt(alloc, correct);

    try writeTargetZon(alloc, build_dir, want_hash);

    activateFetchedEmsdk(alloc, build_dir, DEFAULT_EMSDK_VERSION);
    try testing.expect(StepRecorder.saw_install);
    try testing.expect(StepRecorder.saw_activate);

    // Activation ran IN the hash-named dir (StepRecorder writes emcc under the
    // activated pkg), and NOT in the decoy.
    const correct_emcc = try std.fs.path.join(alloc, &.{ correct, emsdk_cache.emcc_relpath });
    defer alloc.free(correct_emcc);
    try std.Io.Dir.cwd().access(io, correct_emcc, .{});

    const decoy_emcc = try std.fs.path.join(alloc, &.{ decoy, emsdk_cache.emcc_relpath });
    defer alloc.free(decoy_emcc);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, decoy_emcc, .{}));
}

test "activateFetchedEmsdk does NOT heuristically activate a wrong checkout when the hash dir is absent (#294)" {
    const alloc = testing.allocator;
    const io = config.globalIo();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = buf[0..n];

    asm_cache.setCacheRootOverride(root);
    defer asm_cache.clearCacheRootOverride();
    StepRecorder.reset();
    emsdk_toolchain.setExecOverrideForTest(StepRecorder.exec);
    defer emsdk_toolchain.setExecOverrideForTest(null);

    const build_dir = try std.fs.path.join(alloc, &.{ root, "target" });
    defer alloc.free(build_dir);

    const p_root = try std.fs.path.join(alloc, &.{ root, zig_cache.GLOBAL_CACHE_SUBDIR, "p" });
    defer alloc.free(p_root);

    // Only a DECOY (wrong) checkout is present; the dep-hash dir is absent.
    const decoy = try std.fs.path.join(alloc, &.{ p_root, "AAAA-decoy-emsdk" });
    defer alloc.free(decoy);
    try stageEmsdkAt(alloc, decoy);

    // The zon names a hash whose cache dir was never fetched.
    try writeTargetZon(alloc, build_dir, "N-V-__8AAJl1DwBezhYo_VE6f53mPVm00R-Fk28NPW7P14EQ");

    // Metadata WAS read (hash known) → we must NOT fall back to the decoy.
    activateFetchedEmsdk(alloc, build_dir, DEFAULT_EMSDK_VERSION);
    try testing.expect(!StepRecorder.saw_install);
    try testing.expect(!StepRecorder.saw_activate);

    const decoy_emcc = try std.fs.path.join(alloc, &.{ decoy, emsdk_cache.emcc_relpath });
    defer alloc.free(decoy_emcc);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, decoy_emcc, .{}));
}

test "activateFetchedEmsdk falls back to the heuristic when no build.zig.zon metadata is present (#294)" {
    const alloc = testing.allocator;
    const io = config.globalIo();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = buf[0..n];

    asm_cache.setCacheRootOverride(root);
    defer asm_cache.clearCacheRootOverride();
    StepRecorder.reset();
    emsdk_toolchain.setExecOverrideForTest(StepRecorder.exec);
    defer emsdk_toolchain.setExecOverrideForTest(null);

    // build_dir exists but has neither zig-pkg/ NOR a build.zig.zon.
    const build_dir = try std.fs.path.join(alloc, &.{ root, "target" });
    defer alloc.free(build_dir);
    try std.Io.Dir.cwd().createDirPath(io, build_dir);

    const p_root = try std.fs.path.join(alloc, &.{ root, zig_cache.GLOBAL_CACHE_SUBDIR, "p" });
    defer alloc.free(p_root);
    const only = try std.fs.path.join(alloc, &.{ p_root, "N-V-someemsdk" });
    defer alloc.free(only);
    try stageEmsdkAt(alloc, only);

    // No dep-hash metadata to read → last-resort heuristic pick still activates
    // the single emsdk-shaped dir (the retained F4 fallback).
    activateFetchedEmsdk(alloc, build_dir, DEFAULT_EMSDK_VERSION);
    try testing.expect(StepRecorder.saw_install);
    try testing.expect(StepRecorder.saw_activate);

    const only_emcc = try std.fs.path.join(alloc, &.{ only, emsdk_cache.emcc_relpath });
    defer alloc.free(only_emcc);
    try std.Io.Dir.cwd().access(io, only_emcc, .{});
}
