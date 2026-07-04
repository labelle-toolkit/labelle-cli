//! Managed Zig-toolchain resolver — the sibling of `assembler.zig`.
//!
//! Part of labelle-studio#25 (SUB1, labelle-cli#279). The CLI owns the Zig
//! toolchain the way it already owns `labelle-assembler`: read the required
//! version from the project, resolve it to a per-version cache under
//! `~/.labelle/`, download + **verify** + extract it if absent, and point
//! every `zig` spawn at the managed binary instead of PATH.
//!
//! This mirrors `assembler.zig` (`resolveAssembler`/`downloadAssembler`) with
//! `zig_cache.zig` playing the `asm_cache.zig` role. The one thing this
//! resolver adds that the assembler path lacks is **signature verification**:
//! downloads are checked against Zig's published minisign signature with the
//! well-known public key, in pure Zig (Ed25519 + Blake2b-512), before a
//! toolchain is considered installed. Verification is mandatory — a bad
//! signature deletes the download and fails closed.
//!
//! ## Version-resolution precedence (see `resolveRequiredVersion`)
//!
//!   1. `LABELLE_ZIG` env var — absolute path to a `zig`. Total override:
//!      skips version resolution *and* the cache entirely (folds in the
//!      superseded cli#203 option 1). Handled in `resolveZig`.
//!   2. `--zig <path>` flag — same, via `setFlagOverride` (cli#203 option 2).
//!      `LABELLE_ZIG` wins over the flag, matching the assembler env-override.
//!   3. `zig_version` pin in `project.labelle` (`launcher_manifest`).
//!   4. Engine-derived: map the pinned engine version (`project.labelle`
//!      `engine_version`, else `labelle.lock`) to its required Zig via
//!      `zigVersionForEngine`. Today the whole toolkit rides ONE Zig train
//!      (0.16.x), so the map returns `DEFAULT_ZIG_VERSION` for the current
//!      engine major — but the *source* is attributed to the engine so
//!      `toolchain which` reports it honestly, and the map is the seam where
//!      future engine-train divergence lands. NOTE: there is no first-class
//!      engine→Zig table in the toolkit yet (the engine's
//!      `minimum_zig_version` is not surfaced to the CLI at runtime); this
//!      map is the most-defensible stand-in. See PR notes.
//!   5. `DEFAULT_ZIG_VERSION` constant — kept in lockstep with the CLI's own
//!      build Zig and the SUB2/#280 bundled seed.

const std = @import("std");
const builtin = @import("builtin");
const zig_cache = @import("zig_cache.zig");
const config = @import("config.zig");
const launcher_manifest = @import("launcher_manifest.zig");
const util = @import("util.zig");

const is_windows = builtin.os.tag == .windows;

/// Default Zig version resolved/downloaded when a project pins none and no
/// engine mapping applies. Keep in lockstep with the CLI's own build Zig
/// (the toolkit rides one Zig train) and with the SUB2/#280 bundled seed.
pub const DEFAULT_ZIG_VERSION = "0.16.0";

// ── First-run seed (SUB2 / labelle-cli#280) ────────────────────────────
//
// The pre-seeded half of the hybrid: make first run work offline and
// instantly. When the cache lacks the DEFAULT toolchain, `ensureInstalled`
// extracts a bundled archive *instead of* downloading — the resulting tree is
// byte-identical in layout to a downloaded one, so nothing downstream can tell
// them apart. Only the default version is ever seeded; any other pinned
// version still downloads + verifies via the network path.

/// Env var the studio (SUB3/#26) sets to the absolute path of the bundled Zig
/// seed archive it ships as an installer resource. The PRIMARY seed mechanism
/// — the CLI does not hardcode the studio's bundle layout, it just consumes the
/// archive this points at.
pub const SEED_ENV = "LABELLE_ZIG_SEED";

/// Optional env var: absolute path to a minisign signature for the seed
/// archive. When set (or when a `<seed>.minisig` sits next to the archive) the
/// seed is verified before install — otherwise the seed is trusted by
/// provenance (it ships inside our eventually-signed installer). See PR notes
/// on the trust model.
pub const SEED_SIG_ENV = "LABELLE_ZIG_SEED_SIG";

/// Only the DEFAULT toolchain is ever seeded. Any other pinned version must
/// download + verify from the network so a seed can never masquerade as an
/// arbitrary requested version.
fn seedAllowedFor(version: []const u8) bool {
    return std.mem.eql(u8, version, DEFAULT_ZIG_VERSION);
}

/// The canonical seed filename for `version` on this host — the same name the
/// download path uses (`zig-<arch>-<os>-<ver>.<ext>`). This is what a
/// CLI-only distribution places under its `seeds/` dir. Caller owns the slice.
pub fn seedArchiveName(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "zig-{s}-{s}-{s}.{s}", .{
        try archName(), try osName(), version, archive_ext,
    });
}

/// Zig's published minisign public key (from ziglang.org/download). Pinned so
/// verification does not trust anything fetched at runtime. Base64 of
/// `signature_algorithm[2] || key_id[8] || ed25519_public_key[32]` (42 bytes).
pub const MINISIGN_PUBLIC_KEY = "RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U";

/// Official Zig release download root. NOT GitHub — Zig hosts releases on
/// ziglang.org (with community mirrors). The `.minisig` sits next to the
/// tarball at `<url>.minisig`.
pub const ZIG_DOWNLOAD_BASE = "https://ziglang.org/download";

/// Where the requested version came from — reported by `toolchain which`.
pub const VersionSource = enum {
    env_override, // LABELLE_ZIG (a path, not a version)
    flag_override, // --zig <path>
    project_pin, // zig_version in project.labelle
    engine_derived, // mapped from the pinned engine version
    default, // DEFAULT_ZIG_VERSION fallback

    pub fn label(self: VersionSource) []const u8 {
        return switch (self) {
            .env_override => "LABELLE_ZIG env override",
            .flag_override => "--zig flag override",
            .project_pin => "zig_version in project.labelle",
            .engine_derived => "derived from pinned engine version",
            .default => "CLI default",
        };
    }
};

pub const ResolvedVersion = struct {
    /// Heap-owned version string (e.g. "0.16.0"). Caller frees.
    version: []u8,
    source: VersionSource,
};

// ── Escape hatches (cli#203 options 1–2) ──────────────────────────────

/// `--zig <path>` override, set by the arg parser. Borrowed slice owned by
/// the caller (the argv lives for the whole process). `LABELLE_ZIG` wins.
var _flag_override: ?[]const u8 = null;

/// Record the `--zig <path>` flag. `path` must outlive all `resolveZig`
/// calls (argv-lifetime is fine). Pass null to clear (tests).
pub fn setFlagOverride(path: ?[]const u8) void {
    _flag_override = path;
}

/// Look up the `LABELLE_ZIG` path override. Heap-owned on success (caller
/// frees), null when unset. Mirrors `assembler.lookupOverride`.
pub fn lookupEnvOverride(allocator: std.mem.Allocator) !?[]u8 {
    return config.globalEnviron().getAlloc(allocator, "LABELLE_ZIG") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
}

// ── Host triple ────────────────────────────────────────────────────────

/// Zig's os name in the release triple. Zig switched the archive naming from
/// `zig-<os>-<arch>-<ver>` (≤0.14.0) to `zig-<arch>-<os>-<ver>` (0.14.1+); the
/// toolkit rides 0.16.x, so we build the modern arch-first form.
fn osName() error{UnsupportedPlatform}![]const u8 {
    return switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => {
            std.debug.print("labelle: unsupported OS for Zig download: {s}\n", .{@tagName(builtin.os.tag)});
            return error.UnsupportedPlatform;
        },
    };
}

fn archName() error{UnsupportedPlatform}![]const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => {
            std.debug.print("labelle: unsupported architecture for Zig download: {s}\n", .{@tagName(builtin.cpu.arch)});
            return error.UnsupportedPlatform;
        },
    };
}

/// Archive extension for the host: `.zip` on Windows, `.tar.xz` elsewhere.
const archive_ext = if (is_windows) "zip" else "tar.xz";

/// Build the release archive URL for `version`, e.g.
/// `https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz`.
/// Caller owns the returned slice.
pub fn archiveUrl(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/zig-{s}-{s}-{s}.{s}", .{
        ZIG_DOWNLOAD_BASE, version, try archName(), try osName(), version, archive_ext,
    });
}

// ── Version resolution ───────────────────────────────────────────────

/// Map a pinned engine version to its required Zig version. The toolkit
/// currently ships every package (engine included) on a single Zig train, so
/// any engine on the 1.x major maps to `DEFAULT_ZIG_VERSION`. Returns null for
/// an unrecognized engine so the caller falls through to the default.
///
/// This is the seam where future divergence lands: when an engine 2.x train
/// requires a different Zig, add an arm here. Kept intentionally small rather
/// than fabricating a speculative table.
pub fn zigVersionForEngine(engine_version: []const u8) ?[]const u8 {
    const major = util.parseVersion(engine_version) / 1_000_000;
    return switch (major) {
        1 => DEFAULT_ZIG_VERSION,
        else => null,
    };
}

/// Resolve the Zig VERSION the project requires and where it came from.
/// Does not consult the path overrides (those short-circuit in `resolveZig`);
/// this is the version-only chain: project pin → engine-derived → default.
/// Caller owns `result.version`.
pub fn resolveRequiredVersion(allocator: std.mem.Allocator, project_dir: []const u8) !ResolvedVersion {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const manifest = try launcher_manifest.readLauncherManifest(a, project_dir);

    // 3. Explicit zig_version pin.
    if (manifest) |m| {
        if (m.zig_version) |v| {
            if (v.len > 0) return .{ .version = try allocator.dupe(u8, v), .source = .project_pin };
        }
    }

    // 4. Engine-derived. Prefer project.labelle's engine_version, else the
    //    resolved engine in labelle.lock.
    const engine_version: ?[]const u8 = blk: {
        if (manifest) |m| if (m.engine_version) |ev| if (ev.len > 0) break :blk ev;
        break :blk readLockEngineVersion(a, project_dir);
    };
    if (engine_version) |ev| {
        if (zigVersionForEngine(ev)) |zv| {
            return .{ .version = try allocator.dupe(u8, zv), .source = .engine_derived };
        }
    }

    // 5. Default.
    return .{ .version = try allocator.dupe(u8, DEFAULT_ZIG_VERSION), .source = .default };
}

/// Minimal `labelle.lock` shape: only `.resolved.engine.version`. Returns an
/// arena-owned slice (borrowed from `allocator`), or null if absent/unparsable.
fn readLockEngineVersion(allocator: std.mem.Allocator, project_dir: []const u8) ?[]const u8 {
    @setEvalBranchQuota(10000);
    const lock_path = std.fs.path.join(allocator, &.{ project_dir, "labelle.lock" }) catch return null;
    const raw = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), lock_path, allocator, .limited(1024 * 1024)) catch return null;
    const raw_z = allocator.dupeZ(u8, raw) catch return null;

    const LockShape = struct {
        resolved: ?struct {
            engine: ?struct { version: []const u8 = "" } = null,
        } = null,
    };
    const parsed = std.zon.parse.fromSliceAlloc(LockShape, allocator, raw_z, null, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    const resolved = parsed.resolved orelse return null;
    const engine = resolved.engine orelse return null;
    if (engine.version.len == 0) return null;
    return engine.version;
}

// ── Resolve to a managed binary path ───────────────────────────────────

/// Resolve the `zig` binary every spawn should use, downloading + verifying +
/// extracting the required version on a cache miss. Precedence:
///   1. `LABELLE_ZIG` env path (wins over everything).
///   2. `--zig <path>` flag.
///   3. managed cache for `resolveRequiredVersion(project_dir)`.
/// Caller owns the returned slice.
pub fn resolveZig(allocator: std.mem.Allocator, project_dir: []const u8) ![]u8 {
    if (try lookupEnvOverride(allocator)) |path| return path;
    if (_flag_override) |path| return allocator.dupe(u8, path);

    const resolved = try resolveRequiredVersion(allocator, project_dir);
    defer allocator.free(resolved.version);

    const bin_path = try zig_cache.binaryPath(allocator, resolved.version);
    errdefer allocator.free(bin_path);

    std.Io.Dir.cwd().access(config.globalIo(), bin_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            ensureInstalled(allocator, resolved.version) catch |dl_err| {
                std.debug.print(
                    \\
                    \\labelle: could not provision Zig {s}.
                    \\  A working Zig toolchain is required to build. Options:
                    \\    - set LABELLE_ZIG=/path/to/zig (or pass --zig /path/to/zig)
                    \\    - run: labelle install zig {s}
                    \\    - pin a different zig_version in project.labelle
                    \\
                , .{ resolved.version, resolved.version });
                allocator.free(bin_path);
                return dl_err;
            };
        },
        else => {
            allocator.free(bin_path);
            return err;
        },
    };
    return bin_path;
}

// ── Seed lookup (SUB2 / #280) ──────────────────────────────────────────

/// Locate a bundled seed archive for `version`, or null to fall through to the
/// network download. Resolution order (exactly as the ticket specifies):
///   1. `LABELLE_ZIG_SEED` env — absolute path to an archive (studio's hook).
///   2. `seeds/<zig-<arch>-<os>-<ver>.<ext>>` next to the CLI executable.
///   3. none → null.
/// Caller owns the returned slice. This is the env/exe-reading shell; the pure
/// resolution logic lives in `resolveSeedArchive` for testability.
fn locateSeedArchive(allocator: std.mem.Allocator, version: []const u8) !?[]u8 {
    const env_seed = config.globalEnviron().getAlloc(allocator, SEED_ENV) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
    defer if (env_seed) |s| allocator.free(s);

    // The `seeds/` dir sits next to the executable. If the exe path can't be
    // resolved (rare), just skip step 2 rather than failing the whole install.
    const exe_dir = std.process.executableDirPathAlloc(config.globalIo(), allocator) catch null;
    defer if (exe_dir) |d| allocator.free(d);

    return resolveSeedArchive(allocator, version, env_seed, exe_dir);
}

/// Pure seed resolution over injected inputs (no process env / exe lookup) so
/// tests can drive every branch. `env_seed` is the `LABELLE_ZIG_SEED` value
/// (null if unset); `exe_dir` is the CLI executable's directory (null if
/// unresolvable). Returns an allocated path to an EXISTING archive, or null.
fn resolveSeedArchive(
    allocator: std.mem.Allocator,
    version: []const u8,
    env_seed: ?[]const u8,
    exe_dir: ?[]const u8,
) !?[]u8 {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    // 1. LABELLE_ZIG_SEED — the studio's primary hook. Set-but-missing is a
    //    misconfiguration; warn and fall through rather than failing (an
    //    offline default build can still succeed via the exe-adjacent seed).
    if (env_seed) |p| {
        if (p.len > 0) {
            if (cwd.access(io, p, .{})) |_| {
                return try allocator.dupe(u8, p);
            } else |_| {
                std.debug.print("labelle: {s}={s} does not exist; ignoring seed\n", .{ SEED_ENV, p });
            }
        }
    }

    // 2. `seeds/` next to the CLI executable (CLI-only distribution).
    if (exe_dir) |dir| {
        const name = try seedArchiveName(allocator, version);
        defer allocator.free(name);
        const cand = try std.fs.path.join(allocator, &.{ dir, "seeds", name });
        if (cwd.access(io, cand, .{})) |_| {
            return cand;
        } else |_| allocator.free(cand);
    }

    // 3. No seed — caller downloads.
    return null;
}

/// Locate a signature for the seed archive, or null when unsigned. Order:
///   1. `LABELLE_ZIG_SEED_SIG` env.
///   2. `<seed>.minisig` adjacent to the archive.
/// Caller owns the returned slice.
fn locateSeedSig(allocator: std.mem.Allocator, seed_path: []const u8) !?[]u8 {
    const env_sig = config.globalEnviron().getAlloc(allocator, SEED_SIG_ENV) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
    defer if (env_sig) |s| allocator.free(s);
    return resolveSeedSig(allocator, seed_path, env_sig);
}

/// Pure signature resolution over an injected `env_sig` value (testable).
fn resolveSeedSig(allocator: std.mem.Allocator, seed_path: []const u8, env_sig: ?[]const u8) !?[]u8 {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    if (env_sig) |p| {
        if (p.len > 0) {
            if (cwd.access(io, p, .{})) |_| return try allocator.dupe(u8, p) else |_| {}
        }
    }

    const adjacent = try std.fmt.allocPrint(allocator, "{s}.minisig", .{seed_path});
    if (cwd.access(io, adjacent, .{})) |_| {
        return adjacent;
    } else |_| allocator.free(adjacent);

    return null;
}

// ── Install (download + verify + extract, atomic) ──────────────────────

/// Ensure Zig `version` is installed in the managed cache. No-op if already
/// present. On a miss for the DEFAULT version, extract from a bundled seed if
/// one is reachable (offline first-run, #280); otherwise download the archive +
/// `.minisig`, verify the signature, and install. Either way the toolchain is
/// staged in a temp dir then atomically renamed into place so a half-extracted
/// toolchain is never observed as installed.
pub fn ensureInstalled(allocator: std.mem.Allocator, version: []const u8) !void {
    // #280: only the DEFAULT toolchain is ever seeded. Resolving the seed
    // before staging keeps `ensureInstalledWithSeed` free of env/exe lookups.
    const seed: ?[]u8 = if (seedAllowedFor(version))
        try locateSeedArchive(allocator, version)
    else
        null;
    defer if (seed) |s| allocator.free(s);
    return ensureInstalledWithSeed(allocator, version, seed);
}

/// Install `version` into the cache, extracting from `seed` when non-null
/// (offline path) or downloading + verifying when null (network path). Shares
/// one stage-then-publish scaffold so a seeded tree is byte-identical to a
/// downloaded one. Split from `ensureInstalled` so tests can drive the seed
/// path with a fixture archive and no env/network.
fn ensureInstalledWithSeed(allocator: std.mem.Allocator, version: []const u8, seed: ?[]const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const bin_path = try zig_cache.binaryPath(allocator, version);
    defer allocator.free(bin_path);
    // Fast path: already installed, no lock contention.
    if (cwd.access(io, bin_path, .{})) |_| return else |_| {}

    const dest_dir = try zig_cache.versionDir(allocator, version);
    defer allocator.free(dest_dir);

    // Serialize installs of the SAME version across processes with a
    // per-version advisory lock. Without it, two concurrent `labelle`
    // processes could each stage + publish, and the loser's
    // `deleteTree(dest_dir)` would nuke the winner's already-published
    // toolchain out from under a running build. The lock releases when the
    // holding process exits (even on crash). See labelle-cli#279 review.
    const zroot = try zig_cache.zigRoot(allocator);
    defer allocator.free(zroot);
    cwd.createDirPath(io, zroot) catch {};
    const lock_path = try std.fmt.allocPrint(allocator, "{s}{c}{s}.lock", .{ zroot, std.fs.path.sep, version });
    defer allocator.free(lock_path);
    const lock_file = cwd.createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive }) catch |err| {
        std.debug.print("labelle: could not acquire install lock {s}: {any}\n", .{ lock_path, err });
        return error.ZigInstallLockFailed;
    };
    defer lock_file.close(io); // releases the advisory lock

    // Double-checked: another process may have finished installing while we
    // were blocked on the lock. If so, we're done — never re-download or
    // touch the published dir.
    if (cwd.access(io, bin_path, .{})) |_| return else |_| {}

    // Stage everything under a temp sibling of the version dir. The suffix
    // only needs to avoid collisions with a concurrent/stale staging dir, not
    // be cryptographic — 0.16 has no std.crypto.random, so seed a PRNG from a
    // stack address mixed with the dest path.
    var prng = std.Random.DefaultPrng.init(@intFromPtr(&dest_dir) ^ std.hash.Wyhash.hash(0, dest_dir));
    const staging = try std.fmt.allocPrint(allocator, "{s}.tmp-{d}", .{ dest_dir, prng.random().int(u32) });
    defer allocator.free(staging);
    cwd.deleteTree(io, staging) catch {};
    try cwd.createDirPath(io, staging);
    defer cwd.deleteTree(io, staging) catch {};

    if (seed) |seed_path| {
        // ── Offline seed path (#280) ──────────────────────────────────
        // The seed is the same official Zig archive the download path would
        // fetch. We extract it straight into staging (no copy) so the
        // published tree is byte-identical to a downloaded one.
        std.debug.print("labelle: seeding Zig {s} (offline) from {s}\n", .{ version, seed_path });

        // Trust model: the seed ships inside our (eventually-signed)
        // installer, so it is trusted by provenance and typically carries no
        // separate minisig — verification is OPTIONAL here. But if a signature
        // IS shipped (env or adjacent `.minisig`), verify it and fail closed
        // on a bad one. This never weakens the download path's mandatory check.
        if (try locateSeedSig(allocator, seed_path)) |sig_path| {
            defer allocator.free(sig_path);
            std.debug.print("  verifying seed signature...\n", .{});
            verifyArchive(allocator, seed_path, sig_path) catch |err| {
                std.debug.print("labelle: Zig {s} seed signature verification FAILED — refusing to install\n", .{version});
                return err;
            };
            std.debug.print("  signature ok\n", .{});
        }

        std.debug.print("  extracting...\n", .{});
        try extractArchive(allocator, seed_path, staging);
    } else {
        // ── Network download + verify path (#279) ─────────────────────
        const url = try archiveUrl(allocator, version);
        defer allocator.free(url);
        const archive_name = try std.fmt.allocPrint(allocator, "zig-{s}.{s}", .{ version, archive_ext });
        defer allocator.free(archive_name);
        const archive_path = try std.fs.path.join(allocator, &.{ staging, archive_name });
        defer allocator.free(archive_path);
        const sig_path = try std.fmt.allocPrint(allocator, "{s}.minisig", .{archive_path});
        defer allocator.free(sig_path);
        const sig_url = try std.fmt.allocPrint(allocator, "{s}.minisig", .{url});
        defer allocator.free(sig_url);

        std.debug.print("labelle: downloading Zig {s}...\n", .{version});
        std.debug.print("  url: {s}\n", .{url});
        try curlDownload(allocator, url, archive_path);
        try curlDownload(allocator, sig_url, sig_path);

        std.debug.print("  verifying signature...\n", .{});
        verifyArchive(allocator, archive_path, sig_path) catch |err| {
            std.debug.print("labelle: Zig {s} signature verification FAILED — refusing to install\n", .{version});
            return err;
        };
        std.debug.print("  signature ok\n", .{});

        std.debug.print("  extracting...\n", .{});
        try extractArchive(allocator, archive_path, staging);

        // The archive unpacks a single `zig-<arch>-<os>-<ver>/` dir. Promote
        // its contents so the version dir is flat (the #280 seed contract).
        // `extractArchive` strips the leading component, so `staging` already
        // holds `zig`, `lib/`, etc. directly — drop the downloaded archive +
        // sig so only the flattened toolchain is published.
        cwd.deleteFile(io, archive_path) catch {};
        cwd.deleteFile(io, sig_path) catch {};
    }

    // Sanity: the binary must exist in staging before we publish.
    const staged_bin = try std.fs.path.join(allocator, &.{ staging, zig_cache.zig_exe_name });
    defer allocator.free(staged_bin);
    cwd.access(io, staged_bin, .{}) catch {
        std.debug.print("labelle: extracted archive has no '{s}' at its root\n", .{zig_cache.zig_exe_name});
        return error.ZigArchiveLayoutUnexpected;
    };
    if (!is_windows) {
        if (cwd.openFile(io, staged_bin, .{})) |file| {
            defer file.close(io);
            file.setPermissions(io, .fromMode(0o755)) catch {};
        } else |_| {}
    }

    // Publish atomically. We hold the install lock and re-checked above that
    // `bin_path` is absent, so any `dest_dir` here is an INCOMPLETE leftover
    // from a crashed prior install (no working `zig` inside it → no build can
    // be using it). Removing it is safe; a fully-published toolchain is never
    // reached here because the lock + double-check returned early.
    cwd.deleteTree(io, dest_dir) catch {};
    if (std.fs.path.dirname(dest_dir)) |parent| cwd.createDirPath(io, parent) catch {};
    try cwd.rename(staging, cwd, dest_dir, io);

    std.debug.print("  installed at {s}\n", .{dest_dir});
}

/// `curl -fSL -o dest url`, mirroring `assembler.downloadAssembler` (partial
/// cleanup on failure). Fails with `error.ZigDownloadFailed`.
fn curlDownload(allocator: std.mem.Allocator, url: []const u8, dest: []const u8) !void {
    const io = config.globalIo();
    // `--connect-timeout` bounds the TCP handshake; `--max-time` bounds the
    // whole transfer so a stalled mirror can't hang `labelle build` forever.
    // 600s is a generous ceiling for the ~50MB archive on a slow link (cli#279 review).
    const result = util.runCmd(allocator, &.{
        "curl", "-fSL", "--connect-timeout", "30", "--max-time", "600", "-o", dest, url,
    }) catch {
        std.debug.print("labelle: download failed (is curl installed?)\n  url: {s}\n", .{url});
        return error.ZigDownloadFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("labelle: download failed (HTTP error, exit {d})\n  url: {s}\n", .{ code, url });
            std.Io.Dir.cwd().deleteFile(io, dest) catch {};
            return error.ZigDownloadFailed;
        },
        else => {
            std.debug.print("labelle: download process terminated abnormally\n  url: {s}\n", .{url});
            std.Io.Dir.cwd().deleteFile(io, dest) catch {};
            return error.ZigDownloadFailed;
        },
    }
}

/// Read the archive + its `.minisig` and verify against `MINISIGN_PUBLIC_KEY`.
fn verifyArchive(allocator: std.mem.Allocator, archive_path: []const u8, sig_path: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const archive = try cwd.readFileAlloc(io, archive_path, allocator, .limited(512 * 1024 * 1024));
    defer allocator.free(archive);
    const sig_text = try cwd.readFileAlloc(io, sig_path, allocator, .limited(64 * 1024));
    defer allocator.free(sig_text);
    try verifyMinisign(MINISIGN_PUBLIC_KEY, archive, sig_text);
}

// ── Minisign verification (pure Zig: Ed25519 + Blake2b-512) ────────────

pub const MinisignError = error{
    MinisignMalformedPublicKey,
    MinisignMalformedSignature,
    MinisignKeyIdMismatch,
    MinisignUnsupportedAlgorithm,
    ZigSignatureInvalid,
};

/// Verify `file_data` against a minisign signature `sig_text`, using the
/// base64 minisign public key `pub_key_b64`.
///
/// Minisign layout:
///   - public key b64 → algo[2] "Ed" || key_id[8] || ed25519_pub[32]  (42 B)
///   - .minisig line 2 b64 → algo[2] || key_id[8] || ed25519_sig[64]  (74 B)
///       algo "ED" = prehashed: the signed message is Blake2b-512(file).
///       algo "Ed" = legacy: the signed message is the file bytes.
///   - .minisig line 4 b64 → global sig[64] over (sig[64] || trusted_comment)
/// Zig signs with the prehashed "ED" variant. We verify BOTH the file
/// signature and the trusted-comment global signature (the latter binds the
/// human-readable comment to the key). Fails closed on any mismatch.
pub fn verifyMinisign(pub_key_b64: []const u8, file_data: []const u8, sig_text: []const u8) !void {
    const b64 = std.base64.standard.Decoder;

    // Decode public key (42 bytes).
    var pk_buf: [42]u8 = undefined;
    {
        const n = b64.calcSizeForSlice(pub_key_b64) catch return MinisignError.MinisignMalformedPublicKey;
        if (n != pk_buf.len) return MinisignError.MinisignMalformedPublicKey;
        b64.decode(&pk_buf, pub_key_b64) catch return MinisignError.MinisignMalformedPublicKey;
    }
    const pk_key_id = pk_buf[2..10];
    const ed_pub_bytes: [32]u8 = pk_buf[10..42].*;

    // Parse the signature file lines. Line 2 = signature, line 4 = global sig,
    // line 3 = trusted comment (prefix "trusted comment: ").
    var lines = std.mem.splitScalar(u8, sig_text, '\n');
    _ = lines.next(); // line 1: untrusted comment
    const sig_line = std.mem.trim(u8, lines.next() orelse return MinisignError.MinisignMalformedSignature, " \t\r");
    const tc_line = std.mem.trim(u8, lines.next() orelse return MinisignError.MinisignMalformedSignature, " \t\r");
    const gsig_line = std.mem.trim(u8, lines.next() orelse return MinisignError.MinisignMalformedSignature, " \t\r");

    const tc_prefix = "trusted comment: ";
    if (!std.mem.startsWith(u8, tc_line, tc_prefix)) return MinisignError.MinisignMalformedSignature;
    const trusted_comment = tc_line[tc_prefix.len..];

    // Decode signature blob (74 bytes: algo[2] || key_id[8] || sig[64]).
    var sig_buf: [74]u8 = undefined;
    {
        const n = b64.calcSizeForSlice(sig_line) catch return MinisignError.MinisignMalformedSignature;
        if (n != sig_buf.len) return MinisignError.MinisignMalformedSignature;
        b64.decode(&sig_buf, sig_line) catch return MinisignError.MinisignMalformedSignature;
    }
    const algo = sig_buf[0..2];
    const sig_key_id = sig_buf[2..10];
    const ed_sig_bytes: [64]u8 = sig_buf[10..74].*;

    if (!std.mem.eql(u8, pk_key_id, sig_key_id)) return MinisignError.MinisignKeyIdMismatch;

    const Ed25519 = std.crypto.sign.Ed25519;
    const public_key = Ed25519.PublicKey.fromBytes(ed_pub_bytes) catch return MinisignError.MinisignMalformedPublicKey;
    const signature = Ed25519.Signature.fromBytes(ed_sig_bytes);

    // Build the signed message per algorithm.
    if (std.mem.eql(u8, algo, "ED")) {
        var hash: [64]u8 = undefined;
        std.crypto.hash.blake2.Blake2b512.hash(file_data, &hash, .{});
        signature.verify(&hash, public_key) catch return MinisignError.ZigSignatureInvalid;
    } else if (std.mem.eql(u8, algo, "Ed")) {
        signature.verify(file_data, public_key) catch return MinisignError.ZigSignatureInvalid;
    } else {
        return MinisignError.MinisignUnsupportedAlgorithm;
    }

    // Verify the global signature over (sig[64] || trusted_comment). This
    // binds the trusted comment (which names the file + timestamp) to the key.
    var gsig_bytes: [64]u8 = undefined;
    {
        const n = b64.calcSizeForSlice(gsig_line) catch return MinisignError.MinisignMalformedSignature;
        if (n != gsig_bytes.len) return MinisignError.MinisignMalformedSignature;
        b64.decode(&gsig_bytes, gsig_line) catch return MinisignError.MinisignMalformedSignature;
    }
    var global_msg: std.ArrayList(u8) = .empty;
    defer global_msg.deinit(std.heap.page_allocator);
    global_msg.appendSlice(std.heap.page_allocator, &ed_sig_bytes) catch return error.OutOfMemory;
    global_msg.appendSlice(std.heap.page_allocator, trusted_comment) catch return error.OutOfMemory;
    const global_sig = Ed25519.Signature.fromBytes(gsig_bytes);
    global_sig.verify(global_msg.items, public_key) catch return MinisignError.ZigSignatureInvalid;
}

// ── Extraction ─────────────────────────────────────────────────────────

/// Extract `archive_path` into `dest_dir`, stripping the single leading
/// `zig-<arch>-<os>-<ver>/` component so `dest_dir` is flat. Dispatch is by
/// the archive's EXTENSION (not the host): `.zip` → PowerShell `Expand-Archive`
/// + flatten, everything else → `tar -xJf --strip-components=1`. A downloaded
/// archive is `.zip` on Windows and `.tar.xz` elsewhere, so this preserves
/// #279's behavior while letting a #280 seed be unpacked by its real format.
fn extractArchive(allocator: std.mem.Allocator, archive_path: []const u8, dest_dir: []const u8) !void {
    if (std.mem.endsWith(u8, archive_path, ".zip")) return extractZipWindows(allocator, archive_path, dest_dir);
    return extractTarXz(allocator, archive_path, dest_dir);
}

/// `tar -xJf <archive> -C <dest> --strip-components=1`.
fn extractTarXz(allocator: std.mem.Allocator, archive_path: []const u8, dest_dir: []const u8) !void {
    const result = util.runCmd(allocator, &.{
        "tar", "-xJf", archive_path, "-C", dest_dir, "--strip-components=1",
    }) catch {
        std.debug.print("labelle: extraction failed (is tar installed?)\n", .{});
        return error.ZigExtractFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("labelle: tar extraction failed (exit {d})\n{s}\n", .{ code, result.stderr });
            return error.ZigExtractFailed;
        },
        else => return error.ZigExtractFailed,
    }
}

/// Windows: `Expand-Archive` cannot strip a leading dir, so unzip into a
/// scratch subdir then move the single top-level entry's children up.
fn extractZipWindows(allocator: std.mem.Allocator, archive_path: []const u8, dest_dir: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const scratch = try std.fs.path.join(allocator, &.{ dest_dir, "__unzip" });
    defer allocator.free(scratch);
    cwd.createDirPath(io, scratch) catch {};

    // Escape embedded single quotes (`'` → `''`) so a path like
    // `C:\Users\O'Neil\...` (or a LABELLE_HOME with a quote) can't break out
    // of the single-quoted PowerShell string arg (cli#279 review).
    const archive_q = try util.escapePowerShellString(allocator, archive_path);
    defer allocator.free(archive_q);
    const scratch_q = try util.escapePowerShellString(allocator, scratch);
    defer allocator.free(scratch_q);
    const ps = try std.fmt.allocPrint(allocator,
        \\Expand-Archive -LiteralPath '{s}' -DestinationPath '{s}' -Force
    , .{ archive_q, scratch_q });
    defer allocator.free(ps);
    const result = util.runCmd(allocator, &.{ "powershell", "-NoProfile", "-Command", ps }) catch {
        return error.ZigExtractFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ZigExtractFailed,
        else => return error.ZigExtractFailed,
    }

    // Find the single `zig-*/` release dir by kind+prefix (not by assuming the
    // first iterated entry — a stray desktop.ini/Thumbs.db would mis-select).
    // Scope the dir handles so they close BEFORE deleteTree(scratch) below;
    // an open iterate handle on Windows would block the tree removal.
    const inner = blk: {
        var sd = try cwd.openDir(io, scratch, .{ .iterate = true });
        defer sd.close(io);
        var it = sd.iterate();
        while (try it.next(io)) |e| {
            if (e.kind == .directory and std.mem.startsWith(u8, e.name, "zig-"))
                break :blk try std.fs.path.join(allocator, &.{ scratch, e.name });
        }
        return error.ZigArchiveLayoutUnexpected;
    };
    defer allocator.free(inner);

    {
        var id = try cwd.openDir(io, inner, .{ .iterate = true });
        defer id.close(io);
        var iit = id.iterate();
        while (try iit.next(io)) |entry| {
            const from = try std.fs.path.join(allocator, &.{ inner, entry.name });
            defer allocator.free(from);
            const to = try std.fs.path.join(allocator, &.{ dest_dir, entry.name });
            defer allocator.free(to);
            try cwd.rename(from, cwd, to, io);
        }
    }
    cwd.deleteTree(io, scratch) catch {};
}

// ── Subcommands ─────────────────────────────────────────────────────────

/// `labelle install zig <version>` — force download+verify+install.
pub fn cmdInstallZig(allocator: std.mem.Allocator, version: []const u8) !void {
    const bin_path = try zig_cache.binaryPath(allocator, version);
    defer allocator.free(bin_path);
    if (std.Io.Dir.cwd().access(config.globalIo(), bin_path, .{})) |_| {
        std.debug.print("labelle: Zig {s} already installed at {s}\n", .{ version, bin_path });
        return;
    } else |_| {}
    try ensureInstalled(allocator, version);
    std.debug.print("labelle: Zig {s} installed\n", .{version});
}

/// `labelle toolchain list` — cached versions under `<root>/<subdir>/`.
pub fn cmdToolchainList(allocator: std.mem.Allocator) !void {
    const io = config.globalIo();
    const root = try zig_cache.zigRoot(allocator);
    defer allocator.free(root);
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch {
        std.debug.print("labelle: no cached Zig toolchains\n  cache directory: {s}\n", .{root});
        return;
    };
    defer dir.close(io);
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (count == 0) std.debug.print("Cached Zig toolchains:\n", .{});
        const bin = try std.fs.path.join(allocator, &.{ root, entry.name, zig_cache.zig_exe_name });
        defer allocator.free(bin);
        const ok = blk: {
            std.Io.Dir.cwd().access(io, bin, .{}) catch break :blk false;
            break :blk true;
        };
        if (ok) std.debug.print("  {s}\n", .{entry.name}) else std.debug.print("  {s} (incomplete)\n", .{entry.name});
        count += 1;
    }
    if (count == 0) std.debug.print("labelle: no cached Zig toolchains\n  cache directory: {s}\n", .{root});
}

/// `labelle toolchain which` — report the version, its source, and resolved
/// path for the project in `project_dir` (no download).
pub fn cmdToolchainWhich(allocator: std.mem.Allocator, project_dir: []const u8) !void {
    const io = config.globalIo();
    // Path overrides short-circuit — report them explicitly.
    if (try lookupEnvOverride(allocator)) |path| {
        defer allocator.free(path);
        std.debug.print("zig: {s}\n  source: {s}\n", .{ path, VersionSource.env_override.label() });
        return;
    }
    if (_flag_override) |path| {
        std.debug.print("zig: {s}\n  source: {s}\n", .{ path, VersionSource.flag_override.label() });
        return;
    }
    const resolved = try resolveRequiredVersion(allocator, project_dir);
    defer allocator.free(resolved.version);
    const bin = try zig_cache.binaryPath(allocator, resolved.version);
    defer allocator.free(bin);
    const installed = blk: {
        std.Io.Dir.cwd().access(io, bin, .{}) catch break :blk false;
        break :blk true;
    };
    std.debug.print("zig: {s}\n  version: {s}\n  source: {s}\n  installed: {s}\n", .{
        bin, resolved.version, resolved.source.label(), if (installed) "yes" else "no (will download on next build)",
    });
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;
const asm_cache = @import("asm_cache.zig");

test "archiveUrl builds the modern arch-os triple on ziglang.org" {
    const alloc = testing.allocator;
    const url = try archiveUrl(alloc, "0.16.0");
    defer alloc.free(url);
    // Host-specific, so assert the invariant pieces.
    try testing.expect(std.mem.startsWith(u8, url, "https://ziglang.org/download/0.16.0/zig-"));
    try testing.expect(std.mem.indexOf(u8, url, "-0.16.0.") != null);
    try testing.expect(std.mem.endsWith(u8, url, if (is_windows) ".zip" else ".tar.xz"));
    // arch precedes os (0.14.1+ scheme): the arch token appears before the os token.
    const arch = try archName();
    const os = try osName();
    const arch_idx = std.mem.indexOf(u8, url, arch).?;
    const os_idx = std.mem.indexOf(u8, url, os).?;
    try testing.expect(arch_idx < os_idx);
}

test "zigVersionForEngine maps the 1.x train to the default; unknown -> null" {
    try testing.expectEqualStrings(DEFAULT_ZIG_VERSION, zigVersionForEngine("1.65.0").?);
    try testing.expect(zigVersionForEngine("2.0.0") == null);
}

test "resolveRequiredVersion: no project -> default" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(config.globalIo(), &buf);

    const r = try resolveRequiredVersion(alloc, buf[0..n]);
    defer alloc.free(r.version);
    try testing.expectEqualStrings(DEFAULT_ZIG_VERSION, r.version);
    try testing.expectEqual(VersionSource.default, r.source);
}

test "resolveRequiredVersion: explicit zig_version pin wins" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(config.globalIo(), .{
        .sub_path = "project.labelle",
        .data = ".{ .name = \"t\", .zig_version = \"0.15.2\", .engine_version = \"1.65.0\" }",
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(config.globalIo(), &buf);

    const r = try resolveRequiredVersion(alloc, buf[0..n]);
    defer alloc.free(r.version);
    try testing.expectEqualStrings("0.15.2", r.version);
    try testing.expectEqual(VersionSource.project_pin, r.source);
}

test "resolveRequiredVersion: engine_version derives when no explicit pin" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(config.globalIo(), .{
        .sub_path = "project.labelle",
        .data = ".{ .name = \"t\", .engine_version = \"1.65.0\" }",
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(config.globalIo(), &buf);

    const r = try resolveRequiredVersion(alloc, buf[0..n]);
    defer alloc.free(r.version);
    try testing.expectEqualStrings(DEFAULT_ZIG_VERSION, r.version);
    try testing.expectEqual(VersionSource.engine_derived, r.source);
}

test "resolveRequiredVersion: falls back to labelle.lock engine version" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(config.globalIo(), .{
        .sub_path = "project.labelle",
        .data = ".{ .name = \"t\" }",
    });
    try tmp.dir.writeFile(config.globalIo(), .{
        .sub_path = "labelle.lock",
        .data = ".{ .resolved = .{ .engine = .{ .version = \"1.65.0\" } } }",
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(config.globalIo(), &buf);

    const r = try resolveRequiredVersion(alloc, buf[0..n]);
    defer alloc.free(r.version);
    try testing.expectEqual(VersionSource.engine_derived, r.source);
    try testing.expectEqualStrings(DEFAULT_ZIG_VERSION, r.version);
}

test "resolveZig: --zig flag override returns the path verbatim; env wins over flag" {
    const alloc = testing.allocator;
    setFlagOverride("/opt/custom/zig");
    defer setFlagOverride(null);
    const p = try resolveZig(alloc, ".");
    defer alloc.free(p);
    // No LABELLE_ZIG in the test environ, so the flag wins.
    try testing.expectEqualStrings("/opt/custom/zig", p);
}

test "the pinned minisign public key parses to 42 bytes with algo 'Ed'" {
    const b64 = std.base64.standard.Decoder;
    var pk: [42]u8 = undefined;
    const n = try b64.calcSizeForSlice(MINISIGN_PUBLIC_KEY);
    try testing.expectEqual(@as(usize, 42), n);
    try b64.decode(&pk, MINISIGN_PUBLIC_KEY);
    try testing.expectEqualStrings("Ed", pk[0..2]);
}

// Sign a test file with our OWN Ed25519 key and hand-assemble a minisign
// signature (prehashed "ED"), then verify accept/reject. This exercises the
// parser + Ed25519 + Blake2b path without needing Zig's private key.
const MiniFixture = struct {
    pub_b64: []u8,
    sig_text: []u8,

    fn make(alloc: std.mem.Allocator, file_data: []const u8, kp: std.crypto.sign.Ed25519.KeyPair) !MiniFixture {
        const Enc = std.base64.standard.Encoder;
        const key_id = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };

        // public key blob: "Ed" || key_id || pub[32]
        var pk_blob: [42]u8 = undefined;
        @memcpy(pk_blob[0..2], "Ed");
        @memcpy(pk_blob[2..10], &key_id);
        @memcpy(pk_blob[10..42], &kp.public_key.bytes);
        const pub_b64 = try alloc.alloc(u8, Enc.calcSize(pk_blob.len));
        _ = Enc.encode(pub_b64, &pk_blob);

        // prehashed signature over Blake2b512(file)
        var hash: [64]u8 = undefined;
        std.crypto.hash.blake2.Blake2b512.hash(file_data, &hash, .{});
        const sig = try kp.sign(&hash, null);
        var sig_blob: [74]u8 = undefined;
        @memcpy(sig_blob[0..2], "ED");
        @memcpy(sig_blob[2..10], &key_id);
        @memcpy(sig_blob[10..74], &sig.toBytes());
        var sig_b64: [100]u8 = undefined;
        const sig_b64_s = Enc.encode(&sig_b64, &sig_blob);

        const trusted_comment = "timestamp:1 file:test hashed";
        // global signature over sig[64] || trusted_comment
        var gmsg: [64 + trusted_comment.len]u8 = undefined;
        @memcpy(gmsg[0..64], &sig.toBytes());
        @memcpy(gmsg[64..], trusted_comment);
        const gsig = try kp.sign(&gmsg, null);
        var gsig_b64: [100]u8 = undefined;
        const gsig_b64_s = Enc.encode(&gsig_b64, &gsig.toBytes());

        const sig_text = try std.fmt.allocPrint(alloc,
            "untrusted comment: x\n{s}\ntrusted comment: {s}\n{s}\n",
            .{ sig_b64_s, trusted_comment, gsig_b64_s },
        );
        return .{ .pub_b64 = pub_b64, .sig_text = sig_text };
    }

    fn deinit(self: *MiniFixture, alloc: std.mem.Allocator) void {
        alloc.free(self.pub_b64);
        alloc.free(self.sig_text);
    }
};

test "verifyMinisign: accepts a valid signature, rejects a tampered file" {
    const alloc = testing.allocator;
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{7} ** 32);
    const file_data = "the labelle managed zig archive bytes";

    var fx = try MiniFixture.make(alloc, file_data, kp);
    defer fx.deinit(alloc);

    // Known-good: verifies.
    try verifyMinisign(fx.pub_b64, file_data, fx.sig_text);

    // Tampered payload: same signature, different bytes → reject.
    try testing.expectError(MinisignError.ZigSignatureInvalid, verifyMinisign(fx.pub_b64, "tampered!!!", fx.sig_text));
}

test "verifyMinisign: rejects a signature from the wrong key" {
    const alloc = testing.allocator;
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{11} ** 32);
    const other = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{22} ** 32);
    const file_data = "payload";

    var fx = try MiniFixture.make(alloc, file_data, kp);
    defer fx.deinit(alloc);

    // Re-encode a DIFFERENT public key with the same key_id → algo/key_id
    // parse fine but the ed25519 verify fails.
    const Enc = std.base64.standard.Encoder;
    var pk_blob: [42]u8 = undefined;
    @memcpy(pk_blob[0..2], "Ed");
    @memcpy(pk_blob[2..10], &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    @memcpy(pk_blob[10..42], &other.public_key.bytes);
    var wrong_pub: [56]u8 = undefined;
    const wrong_pub_s = Enc.encode(&wrong_pub, &pk_blob);

    try testing.expectError(MinisignError.ZigSignatureInvalid, verifyMinisign(wrong_pub_s, file_data, fx.sig_text));
}

test "verifyMinisign: key_id mismatch is caught before crypto" {
    const alloc = testing.allocator;
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic([_]u8{33} ** 32);
    var fx = try MiniFixture.make(alloc, "x", kp);
    defer fx.deinit(alloc);
    // Zig's real key has a different key_id than our fixture's {1..8}.
    try testing.expectError(MinisignError.MinisignKeyIdMismatch, verifyMinisign(MINISIGN_PUBLIC_KEY, "x", fx.sig_text));
}

// ── Seed tests (SUB2 / #280) ───────────────────────────────────────────

/// realPath of a fresh tmp dir into `buf`; returns the slice. Shared setup for
/// the seed tests, which all need an absolute scratch root to build fixtures in.
fn tmpBase(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPath(config.globalIo(), buf);
    return buf[0..n];
}

/// Write a zero-byte file at absolute `path` (its parent must exist).
fn touch(path: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = path, .data = "" });
}

test "seedAllowedFor: only the DEFAULT version is ever seeded" {
    try testing.expect(seedAllowedFor(DEFAULT_ZIG_VERSION));
    try testing.expect(!seedAllowedFor("0.15.2"));
    try testing.expect(!seedAllowedFor("0.17.0"));
}

test "seedArchiveName matches the downloaded archive's basename" {
    const alloc = testing.allocator;
    const name = try seedArchiveName(alloc, "0.16.0");
    defer alloc.free(name);
    const url = try archiveUrl(alloc, "0.16.0");
    defer alloc.free(url);
    // The seed a CLI-only distribution ships in `seeds/` is the SAME archive
    // the download path would fetch — so its name is the URL's basename.
    try testing.expectEqualStrings(std.fs.path.basename(url), name);
}

test "resolveSeedArchive: LABELLE_ZIG_SEED path wins when it exists" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try tmpBase(&tmp, &buf);

    const seed = try std.fs.path.join(alloc, &.{ base, "custom-seed.tar.xz" });
    defer alloc.free(seed);
    try touch(seed);

    const got = try resolveSeedArchive(alloc, DEFAULT_ZIG_VERSION, seed, null);
    defer if (got) |g| alloc.free(g);
    try testing.expect(got != null);
    try testing.expectEqualStrings(seed, got.?);
}

test "resolveSeedArchive: env precedence — env wins over exe seeds/" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try tmpBase(&tmp, &buf);

    // Env archive.
    const env_seed = try std.fs.path.join(alloc, &.{ base, "env-seed.tar.xz" });
    defer alloc.free(env_seed);
    try touch(env_seed);

    // Also a valid exe-adjacent seeds/<name> — must be ignored while env wins.
    const name = try seedArchiveName(alloc, DEFAULT_ZIG_VERSION);
    defer alloc.free(name);
    const seeds_dir = try std.fs.path.join(alloc, &.{ base, "seeds" });
    defer alloc.free(seeds_dir);
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), seeds_dir);
    const exe_seed = try std.fs.path.join(alloc, &.{ seeds_dir, name });
    defer alloc.free(exe_seed);
    try touch(exe_seed);

    const got = try resolveSeedArchive(alloc, DEFAULT_ZIG_VERSION, env_seed, base);
    defer if (got) |g| alloc.free(g);
    try testing.expectEqualStrings(env_seed, got.?);
}

test "resolveSeedArchive: falls back to seeds/ next to the exe" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try tmpBase(&tmp, &buf);

    const name = try seedArchiveName(alloc, DEFAULT_ZIG_VERSION);
    defer alloc.free(name);
    const seeds_dir = try std.fs.path.join(alloc, &.{ base, "seeds" });
    defer alloc.free(seeds_dir);
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), seeds_dir);
    const exe_seed = try std.fs.path.join(alloc, &.{ seeds_dir, name });
    defer alloc.free(exe_seed);
    try touch(exe_seed);

    // No env; exe_dir = base → resolves to base/seeds/<name>.
    const got = try resolveSeedArchive(alloc, DEFAULT_ZIG_VERSION, null, base);
    defer if (got) |g| alloc.free(g);
    try testing.expectEqualStrings(exe_seed, got.?);
}

test "resolveSeedArchive: env set but missing falls through (does not fail)" {
    const alloc = testing.allocator;
    // Env points at a non-existent archive, no exe seeds/ → null, not an error.
    const got = try resolveSeedArchive(alloc, DEFAULT_ZIG_VERSION, "/no/such/seed.tar.xz", null);
    try testing.expect(got == null);
}

test "resolveSeedArchive: no env + no exe seeds/ -> null (falls through to download)" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try tmpBase(&tmp, &buf); // exists, but has no seeds/ subdir

    const got = try resolveSeedArchive(alloc, DEFAULT_ZIG_VERSION, null, base);
    try testing.expect(got == null);
}

test "resolveSeedSig: env sig wins; else adjacent .minisig; else null" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try tmpBase(&tmp, &buf);

    const seed = try std.fs.path.join(alloc, &.{ base, "seed.tar.xz" });
    defer alloc.free(seed);
    try touch(seed);

    // Unsigned seed → null.
    try testing.expect((try resolveSeedSig(alloc, seed, null)) == null);

    // Adjacent `<seed>.minisig` → picked up.
    const adjacent = try std.fmt.allocPrint(alloc, "{s}.minisig", .{seed});
    defer alloc.free(adjacent);
    try touch(adjacent);
    {
        const got = try resolveSeedSig(alloc, seed, null);
        defer if (got) |g| alloc.free(g);
        try testing.expectEqualStrings(adjacent, got.?);
    }

    // Explicit env sig overrides the adjacent one.
    const env_sig = try std.fs.path.join(alloc, &.{ base, "explicit.minisig" });
    defer alloc.free(env_sig);
    try touch(env_sig);
    {
        const got = try resolveSeedSig(alloc, seed, env_sig);
        defer if (got) |g| alloc.free(g);
        try testing.expectEqualStrings(env_sig, got.?);
    }
}

/// Build a minimal Zig-shaped seed archive (`zig-fixture/zig` + `.../lib/std.zig`)
/// at `archive_path` using the host `tar`. Returns error.SkipZigTest when tar/xz
/// is unavailable (or on Windows) so the suite stays green without the tools —
/// the same tar+xz the download path already depends on.
fn makeSeedFixture(alloc: std.mem.Allocator, src_dir: []const u8, archive_path: []const u8) !void {
    if (is_windows) return error.SkipZigTest;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const top = try std.fs.path.join(alloc, &.{ src_dir, "zig-fixture" });
    defer alloc.free(top);
    const libdir = try std.fs.path.join(alloc, &.{ top, "lib" });
    defer alloc.free(libdir);
    try cwd.createDirPath(io, libdir);

    const zbin = try std.fs.path.join(alloc, &.{ top, "zig" });
    defer alloc.free(zbin);
    try cwd.writeFile(io, .{ .sub_path = zbin, .data = "#!/bin/sh\necho 0.16.0\n" });
    const zstd = try std.fs.path.join(alloc, &.{ libdir, "std.zig" });
    defer alloc.free(zstd);
    try cwd.writeFile(io, .{ .sub_path = zstd, .data = "// fixture std\n" });

    const res = util.runCmd(alloc, &.{ "tar", "-cJf", archive_path, "-C", src_dir, "zig-fixture" }) catch return error.SkipZigTest;
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }
}

test "ensureInstalledWithSeed: DEFAULT seed extracts to the downloaded layout, no network" {
    const alloc = testing.allocator;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try tmpBase(&tmp, &buf);

    // Build a Zig-shaped seed archive (skips cleanly if tar/xz is absent).
    const src = try std.fs.path.join(alloc, &.{ base, "src" });
    defer alloc.free(src);
    try cwd.createDirPath(io, src);
    const seed = try std.fs.path.join(alloc, &.{ base, "seed.tar.xz" });
    defer alloc.free(seed);
    try makeSeedFixture(alloc, src, seed);

    // Point the shared cache root at <base>/home and install FROM the seed.
    // No env, no network — the seed path is exercised directly.
    const home = try std.fs.path.join(alloc, &.{ base, "home" });
    defer alloc.free(home);
    asm_cache.setCacheRootOverride(home);
    defer asm_cache.clearCacheRootOverride();

    try ensureInstalledWithSeed(alloc, DEFAULT_ZIG_VERSION, seed);

    // The published tree must match the EXACT cache paths #279 asserts: the
    // binary sits directly in the flat version dir, with lib/ beside it.
    const bin = try zig_cache.binaryPath(alloc, DEFAULT_ZIG_VERSION);
    defer alloc.free(bin);
    try cwd.access(io, bin, .{}); // <root>/zig/0.16.0/zig

    const vdir = try zig_cache.versionDir(alloc, DEFAULT_ZIG_VERSION);
    defer alloc.free(vdir);
    const lib_std = try std.fs.path.join(alloc, &.{ vdir, "lib", "std.zig" });
    defer alloc.free(lib_std);
    try cwd.access(io, lib_std, .{}); // flattened: lib/ directly under the version dir

    // The leading `zig-fixture/` component was stripped — no nested release dir
    // (this is what makes a seeded tree indistinguishable from a downloaded one).
    const nested = try std.fs.path.join(alloc, &.{ vdir, "zig-fixture" });
    defer alloc.free(nested);
    try testing.expectError(error.FileNotFound, cwd.access(io, nested, .{}));

    // Idempotent: a second call is a no-op fast-path (already installed).
    try ensureInstalledWithSeed(alloc, DEFAULT_ZIG_VERSION, seed);
}
