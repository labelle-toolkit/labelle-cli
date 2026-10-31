//! Resolve the prebuilt `astcenc` binary for build-time ASTC conversion
//! (assembler#340), mirroring how the CLI resolves the assembler binary:
//! cache under `<labelle-home>/astcenc/<version>/`, downloading the ARM-software
//! release archive on first use. Shelling out to a prebuilt binary (vs.
//! vendoring astcenc's multi-file C++/per-ISA build) matches the existing
//! external-asset-tool pattern and keeps the toolchain light.
//!
//! Pure parts (asset-suffix / URL / candidate-names / version-dir) take their
//! inputs explicitly so they're host-testable; `ensure` does download + extract.

const std = @import("std");
const builtin = @import("builtin");
const util = @import("../cli/util.zig");
const cache_publish = @import("../cli/cache_publish.zig");

/// Pinned astcenc release. ARM-software tags releases WITHOUT a `v` prefix
/// (e.g. `5.5.0`), and the archive embeds the same version in its name.
pub const DEFAULT_VERSION = "5.5.0";

const RELEASE_BASE = "https://github.com/ARM-software/astc-encoder/releases/download";

/// Test-only: serve releases from here (a `file://` fixture) instead of
/// `RELEASE_BASE`. Production code never sets it.
var release_base_override: ?[]const u8 = null;

/// The platform fragment in an astcenc release asset name. macOS ships a single
/// universal binary; Linux/Windows split by arch. Pure — caller passes the
/// target so tests don't depend on the host.
pub fn assetSuffix(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) error{UnsupportedPlatform}![]const u8 {
    return switch (os) {
        .macos => "macos-universal",
        .linux => switch (arch) {
            .x86_64 => "linux-x64",
            .aarch64 => "linux-arm64",
            else => error.UnsupportedPlatform,
        },
        .windows => switch (arch) {
            .x86_64 => "windows-x64",
            .aarch64 => "windows-arm64",
            else => error.UnsupportedPlatform,
        },
        else => error.UnsupportedPlatform,
    };
}

/// The `bin/`-relative binary names to look for, in preference order. CRITICAL:
/// the macOS universal archive ships a single `astcenc`, but the Linux/Windows
/// archives ship ISA-specific builds (`astcenc-sse2`/`-sse4.1`/`-avx2`, or
/// `-neon` on arm64) with NO plain `astcenc`. We prefer the SAFEST build that
/// always runs (sse2 on any x86-64) so the tool never SIGILLs on an older CPU —
/// astcenc is fast enough that the ISA tier barely matters for a build step.
pub fn candidateNames(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) []const []const u8 {
    return switch (os) {
        .macos => &.{"astcenc"},
        .windows => switch (arch) {
            .aarch64 => &.{"astcenc-neon.exe"},
            else => &.{ "astcenc-sse2.exe", "astcenc-sse4.1.exe", "astcenc-avx2.exe" },
        },
        else => switch (arch) { // linux + any other unix
            .aarch64 => &.{"astcenc-neon"},
            else => &.{ "astcenc-sse2", "astcenc-sse4.1", "astcenc-avx2" },
        },
    };
}

/// `https://.../<version>/astcenc-<version>-<suffix>.zip`. Caller owns the slice.
pub fn releaseUrl(allocator: std.mem.Allocator, version: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/astcenc-{s}-{s}.zip", .{ release_base_override orelse RELEASE_BASE, version, version, suffix });
}

/// `<cache_root>/astcenc/<version>` — the archive extracts its own `bin/...`
/// under here. Caller owns the slice.
pub fn versionDir(allocator: std.mem.Allocator, cache_root: []const u8, version: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ cache_root, "astcenc", version });
}

/// First candidate binary that exists under `<ver_dir>/bin/`, or null. Caller
/// owns the returned slice.
fn resolveExisting(allocator: std.mem.Allocator, ver_dir: []const u8) !?[]u8 {
    for (candidateNames(builtin.os.tag, builtin.cpu.arch)) |name| {
        const p = try std.fs.path.join(allocator, &.{ ver_dir, "bin", name });
        if (util.fileExists(p)) return p;
        allocator.free(p);
    }
    return null;
}

/// Resolve a usable astcenc path: the cached binary if present, else download +
/// extract the release archive into the cache and return that. `cache_root` is
/// the labelle home (e.g. from `asm_cache.getCacheRoot`). Caller owns the slice.
///
/// Concurrency-safe across processes sharing one labelle home (CI shell runners
/// run several jobs at once): the zip is downloaded and extracted into a UNIQUE
/// staging sibling of the version dir, and the finished tree is published with
/// one directory rename (`cache_publish.publishDir`). The version dir therefore
/// either does not exist or holds a complete, executable install — a reader
/// never sees a half-extracted `bin/`. An `InstallLock` makes one process do
/// the download while the others wait and then reuse it.
pub fn ensure(allocator: std.mem.Allocator, cache_root: []const u8, version: []const u8) ![]u8 {
    const io = util_io();
    const cwd = std.Io.Dir.cwd();
    const ver_dir = try versionDir(allocator, cache_root, version);
    defer allocator.free(ver_dir);

    if (try resolveExisting(allocator, ver_dir)) |p| return p;

    const suffix = assetSuffix(builtin.os.tag, builtin.cpu.arch) catch {
        std.debug.print("labelle: no prebuilt astcenc for this platform; install astcenc {s} under {s}/bin/\n", .{ version, ver_dir });
        return error.AstcencUnavailable;
    };
    const url = try releaseUrl(allocator, version, suffix);
    defer allocator.free(url);

    var lock = cache_publish.InstallLock.acquire(allocator, ver_dir) catch return error.AstcencDownloadFailed;
    defer lock.release();
    // Double-checked: a concurrent labelle may have published it while we
    // waited for the lock.
    if (try resolveExisting(allocator, ver_dir)) |p| return p;

    const staging = try cache_publish.tempSibling(allocator, ver_dir, "tmp");
    defer allocator.free(staging);
    cwd.createDirPath(io, staging) catch |err| {
        std.debug.print("labelle: could not create {s}: {s}\n", .{ staging, @errorName(err) });
        return error.AstcencDownloadFailed;
    };
    // Removed on every exit; after a successful publish it no longer exists.
    defer cwd.deleteTree(io, staging) catch {};

    const zip_path = try std.fs.path.join(allocator, &.{ staging, "astcenc.zip" });
    defer allocator.free(zip_path);

    std.debug.print("labelle: downloading astcenc {s}...\n  url: {s}\n", .{ version, url });
    if (!runOk(allocator, &.{ "curl", "-fSL", "--connect-timeout", "30", "--max-time", "600", "-o", zip_path, url })) {
        std.debug.print("labelle: astcenc download failed (curl). Install astcenc under {s}/bin/\n", .{ver_dir});
        return error.AstcencDownloadFailed;
    }
    // Extract: `unzip` on unix (GNU tar can't read zips), bsdtar on Windows
    // (where `unzip` isn't shipped but `tar` reads zips since Win10).
    //
    // On Windows resolve bsdtar by ABSOLUTE path (<SystemRoot>\System32\tar.exe)
    // rather than a bare `tar`: when labelle runs from a Git Bash / MSYS / Cygwin
    // shell, that environment's GNU `tar` shadows the System32 bsdtar on PATH, and
    // GNU tar can't read a zip ("This does not look like a tar archive") — so the
    // extract would fail only for those users. The absolute path always hits the
    // libarchive-backed system tar. If SystemRoot is unset it tries the stock
    // C:\Windows\System32\tar.exe, then bare `tar` (`unsetRootTar`).
    const extracted = if (builtin.os.tag == .windows) blk: {
        const tar_exe = windowsTarPath(allocator) catch |err| switch (err) {
            // The bare-`tar` fallback exists ONLY for an unset/invalid
            // SystemRoot+windir (the same cases `envVarOwnedOptional` collapses
            // to null). Everything else — OOM first and foremost — propagates,
            // so a real failure isn't silently masked by running whatever `tar`
            // is on PATH (reintroducing the Git Bash GNU-tar shadowing bug).
            error.EnvironmentVariableMissing, error.InvalidWtf8 => try unsetRootTar(allocator),
            else => return err,
        };
        defer allocator.free(tar_exe);
        break :blk runOk(allocator, &.{ tar_exe, "-xf", zip_path, "-C", staging });
    } else runOk(allocator, &.{ "unzip", "-o", "-q", zip_path, "-d", staging });
    if (!extracted) {
        std.debug.print("labelle: astcenc extract failed. Install astcenc under {s}/bin/\n", .{ver_dir});
        return error.AstcencExtractFailed;
    }
    // Only the extracted tree is published, not the archive.
    cwd.deleteFile(io, zip_path) catch {};

    {
        const staged_bin = (try resolveExisting(allocator, staging)) orelse {
            std.debug.print("labelle: astcenc binary not found after extracting {s}\n", .{url});
            return error.AstcencExtractFailed;
        };
        defer allocator.free(staged_bin);
        // Executable BEFORE publishing: once the version dir exists another
        // labelle may run the binary straight away.
        if (builtin.os.tag != .windows) {
            if (cwd.openFile(io, staged_bin, .{})) |f| {
                defer f.close(io);
                f.setPermissions(io, .fromMode(0o755)) catch {};
            } else |_| {}
        }
    }

    _ = cache_publish.publishDir(allocator, staging, ver_dir, HasBinary{}) catch |err| {
        std.debug.print("labelle: could not move the extracted astcenc into {s}: {s}\n", .{ ver_dir, @errorName(err) });
        return error.AstcencExtractFailed;
    };
    const bin = (try resolveExisting(allocator, ver_dir)) orelse {
        std.debug.print("labelle: astcenc binary missing from {s} after install\n", .{ver_dir});
        return error.AstcencExtractFailed;
    };
    std.debug.print("  cached at {s}\n", .{bin});
    return bin;
}

/// `publishDir` validator: the version dir holds one of the candidate binaries.
const HasBinary = struct {
    pub fn valid(_: HasBinary, dir: []const u8) bool {
        const p = resolveExisting(std.heap.page_allocator, dir) catch return false;
        if (p) |path| {
            std.heap.page_allocator.free(path);
            return true;
        }
        return false;
    }
};

fn util_io() std.Io {
    return @import("../cli/config.zig").globalIo();
}

/// `<SystemRoot>\System32\tar.exe` — the libarchive-backed bsdtar shipped with
/// Windows 10+. Resolving it absolutely sidesteps a Git Bash / MSYS GNU `tar`
/// that may shadow it on PATH (GNU tar can't read zips). Caller owns the slice.
fn windowsTarPath(allocator: std.mem.Allocator) ![]u8 {
    const env = @import("../cli/config.zig").globalEnviron();
    // `SystemRoot` is the canonical var (e.g. C:\Windows); `windir` is its
    // historical alias. Try both before giving up.
    const root = env.getAlloc(allocator, "SystemRoot") catch |err| switch (err) {
        // Only fall through to the `windir` alias when SystemRoot is unset or
        // invalid UTF-8 (the cases `envVarOwnedOptional` treats as "not set").
        // OOM and any other error propagate rather than masking a corrupt
        // environment behind the alias lookup.
        error.EnvironmentVariableMissing, error.InvalidWtf8 => try env.getAlloc(allocator, "windir"),
        else => return err,
    };
    defer allocator.free(root);
    return std.fmt.allocPrint(allocator, "{s}\\System32\\tar.exe", .{root});
}

/// The tar to use when SystemRoot/windir are unset: the stock
/// `C:\Windows\System32\tar.exe` bsdtar if it is there (the usual location,
/// and what an empty environment — e.g. under `zig build test` — still has),
/// else bare `tar`. Caller owns the slice.
fn unsetRootTar(allocator: std.mem.Allocator) ![]u8 {
    const stock = "C:\\Windows\\System32\\tar.exe";
    if (util.fileExists(stock)) return allocator.dupe(u8, stock);
    return allocator.dupe(u8, "tar");
}

fn runOk(allocator: std.mem.Allocator, argv: []const []const u8) bool {
    const r = util.runCmd(allocator, argv) catch return false;
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    return switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

// ── Tests (pure suffix/url/candidate/path logic) ─────────────────────────────

test "assetSuffix maps platforms" {
    try std.testing.expectEqualStrings("macos-universal", try assetSuffix(.macos, .aarch64));
    try std.testing.expectEqualStrings("linux-x64", try assetSuffix(.linux, .x86_64));
    try std.testing.expectEqualStrings("linux-arm64", try assetSuffix(.linux, .aarch64));
    try std.testing.expectEqualStrings("windows-x64", try assetSuffix(.windows, .x86_64));
    try std.testing.expectError(error.UnsupportedPlatform, assetSuffix(.freestanding, .x86_64));
    try std.testing.expectError(error.UnsupportedPlatform, assetSuffix(.linux, .arm));
}

test "candidateNames: macOS single, x64 ISA tiers (sse2 first), arm64 neon, .exe on Windows" {
    try std.testing.expectEqualStrings("astcenc", candidateNames(.macos, .aarch64)[0]);
    const lx = candidateNames(.linux, .x86_64);
    try std.testing.expectEqualStrings("astcenc-sse2", lx[0]); // safest first
    try std.testing.expectEqual(@as(usize, 3), lx.len);
    try std.testing.expectEqualStrings("astcenc-neon", candidateNames(.linux, .aarch64)[0]);
    try std.testing.expectEqualStrings("astcenc-sse2.exe", candidateNames(.windows, .x86_64)[0]);
}

test "releaseUrl + versionDir shapes" {
    const a = std.testing.allocator;
    const url = try releaseUrl(a, "5.5.0", "linux-x64");
    defer a.free(url);
    try std.testing.expectEqualStrings(
        "https://github.com/ARM-software/astc-encoder/releases/download/5.5.0/astcenc-5.5.0-linux-x64.zip",
        url,
    );
    const vd = try versionDir(a, "/home/u/.labelle", "5.5.0");
    defer a.free(vd);
    try std.testing.expect(std.mem.endsWith(u8, vd, "5.5.0"));
    try std.testing.expect(std.mem.indexOf(u8, vd, "astcenc") != null);
}

// ── Concurrency (shared labelle home, CI shell runners) ─────────────────────

const ConcurrentEnsure = struct {
    const version = "0.0.1-fixture";

    fn fileUrl(a: std.mem.Allocator, abs: []const u8) ![]u8 {
        const fwd = try a.dupe(u8, abs);
        defer a.free(fwd);
        std.mem.replaceScalar(u8, fwd, '\\', '/');
        return if (fwd.len > 0 and fwd[0] == '/')
            std.fmt.allocPrint(a, "file://{s}", .{fwd})
        else
            std.fmt.allocPrint(a, "file:///{s}", .{fwd});
    }

    /// Zip `<src>/bin` into `zip_path`: bsdtar on Windows/macOS, `zip` on
    /// Linux (GNU tar cannot write zips). Null if no tool is available.
    fn makeZip(a: std.mem.Allocator, src: []const u8, zip_path: []const u8) !bool {
        if (builtin.os.tag == .windows) {
            const tar_exe = windowsTarPath(a) catch try unsetRootTar(a);
            defer a.free(tar_exe);
            return runOk(a, &.{ tar_exe, "-a", "-cf", zip_path, "-C", src, "bin" });
        }
        if (builtin.os.tag == .macos) return runOk(a, &.{ "tar", "-a", "-cf", zip_path, "-C", src, "bin" });
        // `zip` stores paths relative to its cwd; -j would flatten, so cd via sh.
        const script = try std.fmt.allocPrint(a, "cd '{s}' && zip -q -r '{s}' bin", .{ src, zip_path });
        defer a.free(script);
        return runOk(a, &.{ "sh", "-c", script });
    }

    const Worker = struct {
        root: []const u8,
        failures: *std.atomic.Value(u32),
        fn run(w: Worker) void {
            const p = ensure(std.heap.page_allocator, w.root, version) catch |err| {
                std.debug.print("concurrent astcenc ensure failed: {s}\n", .{@errorName(err)});
                _ = w.failures.fetchAdd(1, .monotonic);
                return;
            };
            std.heap.page_allocator.free(p);
        }
    };
};

test "astcenc ensure: parallel installs into one labelle home all succeed with a complete tree" {
    const a = std.testing.allocator;
    const io = util_io();
    const cwd = std.Io.Dir.cwd();
    const version = ConcurrentEnsure.version;
    const suffix = assetSuffix(builtin.os.tag, builtin.cpu.arch) catch return error.SkipZigTest;
    if (!runOk(a, &.{ "curl", "--version" })) return error.SkipZigTest;
    if (builtin.os.tag == .linux and !runOk(a, &.{ "unzip", "-v" })) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    // Fixture archive: bin/<every candidate name>, served as
    // <rel>/<version>/astcenc-<version>-<suffix>.zip.
    const src = try std.fs.path.join(a, &.{ root, "src" });
    defer a.free(src);
    const src_bin = try std.fs.path.join(a, &.{ src, "bin" });
    defer a.free(src_bin);
    try cwd.createDirPath(io, src_bin);
    const payload = try a.alloc(u8, 2 << 20);
    defer a.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 5);
    for (candidateNames(builtin.os.tag, builtin.cpu.arch)) |name| {
        const p = try std.fs.path.join(a, &.{ src_bin, name });
        defer a.free(p);
        try cwd.writeFile(io, .{ .sub_path = p, .data = payload });
    }
    const rel_ver = try std.fs.path.join(a, &.{ root, "rel", version });
    defer a.free(rel_ver);
    try cwd.createDirPath(io, rel_ver);
    const zip_name = try std.fmt.allocPrint(a, "astcenc-{s}-{s}.zip", .{ version, suffix });
    defer a.free(zip_name);
    const zip_path = try std.fs.path.join(a, &.{ rel_ver, zip_name });
    defer a.free(zip_path);
    if (!(try ConcurrentEnsure.makeZip(a, src, zip_path))) return error.SkipZigTest;

    const rel = try std.fs.path.join(a, &.{ root, "rel" });
    defer a.free(rel);
    const base = try ConcurrentEnsure.fileUrl(a, rel);
    defer a.free(base);
    release_base_override = base;
    defer release_base_override = null;

    const home = try std.fs.path.join(a, &.{ root, "home" });
    defer a.free(home);
    var failures: std.atomic.Value(u32) = .init(0);
    var threads: [6]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, ConcurrentEnsure.Worker.run, .{ConcurrentEnsure.Worker{ .root = home, .failures = &failures }});
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u32, 0), failures.load(.monotonic));

    // Every candidate is complete (no truncated binary from a racing extract).
    const ver_dir = try versionDir(a, home, version);
    defer a.free(ver_dir);
    for (candidateNames(builtin.os.tag, builtin.cpu.arch)) |name| {
        const p = try std.fs.path.join(a, &.{ ver_dir, "bin", name });
        defer a.free(p);
        const got = try cwd.readFileAlloc(io, p, a, .limited(8 << 20));
        defer a.free(got);
        try std.testing.expectEqualSlices(u8, payload, got);
    }
    // Only the version dir and its lock remain under <home>/astcenc, and the
    // archive was not published into the version dir.
    const parent = std.fs.path.dirname(ver_dir).?;
    var dir = try cwd.openDir(io, parent, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        const ok = std.mem.eql(u8, e.name, version) or std.mem.eql(u8, e.name, version ++ ".lock");
        if (!ok) std.debug.print("leftover under astcenc/: {s}\n", .{e.name});
        try std.testing.expect(ok);
    }
    const zip_in_cache = try std.fs.path.join(a, &.{ ver_dir, "astcenc.zip" });
    defer a.free(zip_in_cache);
    try std.testing.expect(!util.fileExists(zip_in_cache));
}
