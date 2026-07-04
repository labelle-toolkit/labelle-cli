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

// ── Install (download + verify + extract, atomic) ──────────────────────

/// Ensure Zig `version` is installed in the managed cache. No-op if already
/// present. On a miss: download the archive + `.minisig`, verify the
/// signature, extract into a temp dir, then atomically rename into place so a
/// half-extracted toolchain is never observed as installed.
pub fn ensureInstalled(allocator: std.mem.Allocator, version: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const bin_path = try zig_cache.binaryPath(allocator, version);
    defer allocator.free(bin_path);
    if (cwd.access(io, bin_path, .{})) |_| return else |_| {}

    const dest_dir = try zig_cache.versionDir(allocator, version);
    defer allocator.free(dest_dir);

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

    // The archive unpacks a single `zig-<arch>-<os>-<ver>/` dir. Promote its
    // contents so the version dir is flat (the #280 seed contract). We extract
    // with strip-of-leading-component below, so `staging` already holds `zig`,
    // `lib/`, etc. directly — drop the downloaded archive + sig first.
    cwd.deleteFile(io, archive_path) catch {};
    cwd.deleteFile(io, sig_path) catch {};

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

    // Publish atomically. Remove any stale/partial dest first.
    cwd.deleteTree(io, dest_dir) catch {};
    if (std.fs.path.dirname(dest_dir)) |parent| cwd.createDirPath(io, parent) catch {};
    try cwd.rename(staging, cwd, dest_dir, io);

    std.debug.print("  installed at {s}\n", .{dest_dir});
}

/// `curl -fSL -o dest url`, mirroring `assembler.downloadAssembler` (partial
/// cleanup on failure). Fails with `error.ZigDownloadFailed`.
fn curlDownload(allocator: std.mem.Allocator, url: []const u8, dest: []const u8) !void {
    const io = config.globalIo();
    const result = util.runCmd(allocator, &.{ "curl", "-fSL", "-o", dest, url }) catch {
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
/// `zig-<arch>-<os>-<ver>/` component so `dest_dir` is flat. Unix uses
/// `tar -xJf --strip-components=1`; Windows uses PowerShell `Expand-Archive`
/// then flattens the one top-level dir.
fn extractArchive(allocator: std.mem.Allocator, archive_path: []const u8, dest_dir: []const u8) !void {
    if (is_windows) return extractZipWindows(allocator, archive_path, dest_dir);
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

    const ps = try std.fmt.allocPrint(allocator,
        \\Expand-Archive -LiteralPath '{s}' -DestinationPath '{s}' -Force
    , .{ archive_path, scratch });
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

    // Move the single `zig-*/` child's contents up into dest_dir.
    var sd = try cwd.openDir(io, scratch, .{ .iterate = true });
    defer sd.close(io);
    var it = sd.iterate();
    const top = (try it.next(io)) orelse return error.ZigArchiveLayoutUnexpected;
    const inner = try std.fs.path.join(allocator, &.{ scratch, top.name });
    defer allocator.free(inner);
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
