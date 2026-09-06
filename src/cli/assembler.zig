/// Subprocess wrapper for the standalone labelle-assembler binary.
///
/// Phase 2-4 of the assembler split (RFC #122). Resolves the external
/// assembler binary via three-tier priority:
///
///   1. `LABELLE_ASSEMBLER` env var — local dev override (always wins)
///   2. `assembler_version` in project.labelle — pinned version resolved
///      from the cache at `~/.labelle/assembler/<version>/labelle-assembler`
///      If not cached, auto-downloads from GitHub releases (Phase 4).
///   3. Absent — download `DEFAULT_ASSEMBLER_VERSION` from GitHub releases.
const std = @import("std");

/// Default assembler version the CLI resolves/downloads when a project
/// pins none (no `assembler_version` in project.labelle, no
/// `LABELLE_ASSEMBLER` override). Issue #217: the CLI no longer links the
/// assembler's `generator` module, so this is a pure runtime default —
/// it must name an assembler binary release whose subcommand protocol
/// the CLI's `assembler_proc` harness understands.
///
/// Must be >= the first release carrying the assembler subcommands the
/// CLI delegates (`install`/`clean`/`upgrade`/`init`), and >= 0.92.0 so
/// `init` scaffolds carry `.y_axis` + real curated package pins instead
/// of tag-stamped nonsense (labelle-cli#322 / assembler#629 — 0.40.0 sat
/// here untouched for months and every fresh `labelle init` scaffolded a
/// project the current assembler line refuses to build). The
/// released-path smoke test in ci.yml (init with NO local overrides →
/// generate → build) fails if this constant rots again.
pub const DEFAULT_ASSEMBLER_VERSION = "0.105.0";
const builtin = @import("builtin");
const asm_cache = @import("asm_cache.zig");
const compatibility = @import("compatibility.zig");
const config = @import("config.zig");
const launcher_manifest = @import("launcher_manifest.zig");
const util = @import("util.zig");
const runner = @import("runner.zig");

/// GitHub release URL template for assembler binaries.
const ASSEMBLER_RELEASE_BASE = "https://github.com/labelle-toolkit/labelle-assembler/releases/download";

/// The LAST assembler release published WITHOUT a `SHA256SUMS` manifest.
///
/// labelle-assembler#718/#720 added the manifest to the release workflow;
/// v0.105.0 (2026-09-06) was the last tag cut before that landed, so every
/// release AFTER this one ships one and no release up to and including it
/// does.
///
/// Spelled as "the last one without" rather than "the first one with" on
/// purpose: the first version WITH a manifest is whatever gets tagged next,
/// which is unknowable while writing this. `>` against this constant is
/// correct for any future version without needing an edit at release time —
/// a constant that must be updated by hand on the next release is a constant
/// that will be wrong on the next release.
///
/// This is the version FLOOR for the strip-attack defence in
/// `verifyAgainstManifest`; see the policy note there.
const LAST_UNVERIFIED_ASSEMBLER_VERSION = "0.105.0";

/// Look up the override path. Returns null if `LABELLE_ASSEMBLER` is
/// unset, in which case the CLI should use the in-process generator.
/// Returns the heap-allocated path string on success — caller owns it.
pub fn lookupOverride(allocator: std.mem.Allocator) !?[]u8 {
    return config.globalEnviron().getAlloc(allocator, "LABELLE_ASSEMBLER") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
}

/// Resolve `assembler_version = "local:<path>"`: build the sibling
/// labelle-assembler checkout and return the path to its binary.
/// `rel_path` is relative to `project_dir` (or absolute).
///
/// In a git worktree, `rel_path` is anchored at the main checkout instead
/// — `local:` paths describe sibling repos that sit next to the main
/// checkout, not next to the worktree. See resolveProjectRoot.
fn resolveLocalAssembler(allocator: std.mem.Allocator, rel_path: []const u8, project_dir: []const u8) ![]u8 {
    const io = config.globalIo();
    const source_dir = if (std.fs.path.isAbsolute(rel_path))
        try allocator.dupe(u8, rel_path)
    else blk: {
        const root = try resolveProjectRoot(allocator, project_dir);
        defer allocator.free(root);
        break :blk try std.fs.path.join(allocator, &.{ root, rel_path });
    };
    defer allocator.free(source_dir);

    const real_source = std.Io.Dir.cwd().realPathFileAlloc(io, source_dir, allocator) catch |err| {
        std.debug.print("labelle: local assembler path '{s}' does not exist: {any}\n", .{ source_dir, err });
        return error.AssemblerNotCached;
    };
    defer allocator.free(real_source);

    std.debug.print("labelle: building local assembler at {s}...\n", .{real_source});
    // Managed Zig (cli#279) — the local assembler checkout has no
    // project.labelle, so this resolves to the CLI's default Zig.
    const zig_exe = runner.resolveZigExe(allocator, real_source) catch |err| {
        std.debug.print("labelle: could not resolve managed Zig: {any}\n", .{err});
        return error.AssemblerNotCached;
    };
    defer allocator.free(zig_exe);
    const build_result = runner.runZig(allocator, real_source, &.{ zig_exe, "build" }) catch |err| {
        std.debug.print("labelle: failed to run 'zig build' in {s}: {any}\n", .{ real_source, err });
        return error.AssemblerNotCached;
    };
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);
    switch (build_result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("labelle: local assembler build failed (exit {d})\n{s}", .{ code, build_result.stderr });
            return error.AssemblerNotCached;
        },
        else => {
            std.debug.print("labelle: local assembler build terminated abnormally\n", .{});
            return error.AssemblerNotCached;
        },
    }

    const bin_path = try std.fs.path.join(allocator, &.{ real_source, "zig-out", "bin", exe_name });
    std.Io.Dir.cwd().access(io, bin_path, .{}) catch |err| {
        std.debug.print("labelle: local assembler binary not found at {s}: {any}\n", .{ bin_path, err });
        allocator.free(bin_path);
        return error.AssemblerNotCached;
    };
    return bin_path;
}

/// Platform/arch names used in the release URL.
fn osName() error{UnsupportedPlatform}![]const u8 {
    return switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => {
            std.debug.print("labelle: unsupported OS for assembler download: {s}\n", .{@tagName(builtin.os.tag)});
            return error.UnsupportedPlatform;
        },
    };
}

fn archName() error{UnsupportedPlatform}![]const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => {
            std.debug.print("labelle: unsupported architecture for assembler download: {s}\n", .{@tagName(builtin.cpu.arch)});
            return error.UnsupportedPlatform;
        },
    };
}

const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
const exe_name = "labelle-assembler" ++ exe_suffix;

/// Look up `asset`'s expected digest in a `SHA256SUMS` body.
///
/// The manifest is the plain `shasum`/coreutils format the release workflow
/// emits — `<64 hex>  <bare filename>`, two spaces — one line per published
/// binary. Matching on the exact filename (not a substring) matters: the
/// five asset names share a prefix, and `labelle-assembler-linux-x86_64`
/// is a substring of nothing else only by luck of the current naming.
fn digestFor(manifest: []const u8, asset: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len < 64 + 2 + 1) continue;
        const sep = std.mem.indexOf(u8, line, "  ") orelse continue;
        if (sep != 64) continue;
        const name = std.mem.trim(u8, line[sep + 2 ..], " \t\r");
        if (std.mem.eql(u8, name, asset)) return line[0..64];
    }
    return null;
}

/// Verify `path`'s bytes against the release's `SHA256SUMS`.
///
/// ── The missing-manifest policy, which is the crux of this check ──
///
/// No release up to and including `LAST_UNVERIFIED_ASSEMBLER_VERSION` ships
/// a manifest, so "always fail closed" would brick every project pinned to
/// one of them — which is every project that exists today. "Always fail
/// open" is worse in the other direction: an attacker who can replace a
/// release asset can also DELETE the manifest, and a check that silently
/// skips when the manifest is absent can be turned off by the very
/// adversary it defends against (the classic strip attack).
///
/// So the policy is neither, and is keyed on the version:
///
///   * version >  LAST_UNVERIFIED  → a manifest MUST be present and MUST
///     match. Its absence is a hard failure, because for those releases
///     absence can only mean the workflow did not run as expected or
///     someone removed it. This is what closes the strip attack going
///     forward.
///   * version <= LAST_UNVERIFIED  → no manifest was ever published, so a
///     404 is expected and is NOT a failure. Warn once, loudly, and
///     proceed. These releases are unverifiable as a matter of historical
///     fact; pretending otherwise by failing would be a lie about security
///     that costs every existing user their build.
///
/// In BOTH cases, if a manifest IS present it is binding: a mismatch, or a
/// manifest that does not list this asset, fails. That way the older
/// releases start being verified the moment someone backfills a manifest
/// onto them, with no code change here.
fn verifyAgainstManifest(
    allocator: std.mem.Allocator,
    version: []const u8,
    asset: []const u8,
    path: []const u8,
) !void {
    const io = config.globalIo();
    const manifest_url = try std.fmt.allocPrint(allocator, "{s}/v{s}/SHA256SUMS", .{
        ASSEMBLER_RELEASE_BASE,
        version,
    });
    defer allocator.free(manifest_url);

    const manifest_path = try std.fmt.allocPrint(allocator, "{s}.sha256sums", .{path});
    defer allocator.free(manifest_path);
    defer std.Io.Dir.cwd().deleteFile(io, manifest_path) catch {};

    const expect_manifest = compatibility.parseVersion(LAST_UNVERIFIED_ASSEMBLER_VERSION)
        .olderThan(compatibility.parseVersion(version));

    const fetched = fetch: {
        const r = util.runCmd(allocator, &.{ "curl", "-fSL", "-o", manifest_path, manifest_url }) catch break :fetch false;
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
        break :fetch switch (r.term) {
            .exited => |code| code == 0,
            else => false,
        };
    };

    if (!fetched) {
        if (expect_manifest) {
            std.debug.print("labelle: SHA256SUMS is missing for assembler v{s} — refusing the download.\n", .{version});
            std.debug.print("  every assembler release after v{s} publishes one, so its absence means\n", .{LAST_UNVERIFIED_ASSEMBLER_VERSION});
            std.debug.print("  the release is incomplete or its assets were tampered with.\n", .{});
            std.debug.print("  url: {s}\n", .{manifest_url});
            return error.AssemblerChecksumUnavailable;
        }
        std.debug.print("labelle: WARNING — assembler v{s} predates published checksums; the download\n", .{version});
        std.debug.print("  could NOT be verified. Releases after v{s} are verified automatically.\n", .{LAST_UNVERIFIED_ASSEMBLER_VERSION});
        return;
    }

    const manifest = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(64 << 10)) catch {
        std.debug.print("labelle: could not read the downloaded SHA256SUMS — refusing the download.\n", .{});
        return error.AssemblerChecksumUnavailable;
    };
    defer allocator.free(manifest);

    const expected = digestFor(manifest, asset) orelse {
        std.debug.print("labelle: SHA256SUMS for v{s} does not list '{s}' — refusing the download.\n", .{ version, asset });
        return error.AssemblerChecksumMissingEntry;
    };

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(512 << 20)) catch {
        std.debug.print("labelle: could not read the download to verify it.\n", .{});
        return error.AssemblerDownloadFailed;
    };
    defer allocator.free(data);

    if (!util.sha256Matches(data, expected)) {
        std.debug.print("labelle: CHECKSUM MISMATCH for assembler v{s} — refusing the download.\n", .{version});
        std.debug.print("  expected {s} (from the release's SHA256SUMS)\n", .{expected});
        std.debug.print("  the downloaded bytes are not what the release publishes. Nothing was installed.\n", .{});
        return error.AssemblerChecksumMismatch;
    }

    std.debug.print("  checksum ok (SHA256SUMS)\n", .{});
}

/// Download an assembler binary from GitHub releases and cache it.
///
/// URL pattern: https://github.com/labelle-toolkit/labelle-assembler/releases/download/v<version>/labelle-assembler-<os>-<arch>
///
/// The binary is saved to `~/.labelle/assembler/<version>/labelle-assembler`
/// and made executable on Unix.
///
/// The download is verified against the release's `SHA256SUMS` before it is
/// put in place. HTTPS and a version pin authenticate the HOST, not the
/// bytes, and GitHub release assets are MUTABLE — an asset can be deleted
/// and re-uploaded under the same name on an existing tag — so without this
/// the CLI would `chmod +x` and execute whatever arrived
/// (labelle-assembler#616).
///
/// Staging matters as much as the check. The bytes land on a `.part` sibling
/// and are moved to `dest_path` ONLY after they verify, because `dest_path`
/// is not a scratch location: it is the cache slot, and every caller decides
/// "already downloaded?" by `access()`ing exactly that path. Writing the
/// unverified download there directly — as this function used to — means a
/// failed verification would leave a file that the NEXT run treats as a good
/// cache hit and never re-downloads or re-checks. So a rejected download
/// must leave nothing at `dest_path`: nothing cached, nothing executable.
pub fn downloadAssembler(allocator: std.mem.Allocator, version: []const u8, dest_path: []const u8) !void {
    const io = config.globalIo();
    const asset = try std.fmt.allocPrint(allocator, "labelle-assembler-{s}-{s}", .{
        try osName(),
        try archName(),
    });
    defer allocator.free(asset);
    const url = try std.fmt.allocPrint(allocator, "{s}/v{s}/{s}", .{
        ASSEMBLER_RELEASE_BASE,
        version,
        asset,
    });
    defer allocator.free(url);

    std.debug.print("labelle: downloading assembler v{s}...\n", .{version});
    std.debug.print("  url: {s}\n", .{url});

    // Ensure the parent directory exists.
    if (std.fs.path.dirname(dest_path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
            std.debug.print("labelle: could not create directory {s}: {any}\n", .{ dir, err });
            return error.AssemblerDownloadFailed;
        };
    }

    // Staging path: everything below writes HERE, never to dest_path, until
    // the bytes have been verified. See the doc comment above.
    const part_path = try std.fmt.allocPrint(allocator, "{s}.part", .{dest_path});
    defer allocator.free(part_path);
    defer std.Io.Dir.cwd().deleteFile(io, part_path) catch {};

    // Use curl with -L to follow redirects (GitHub releases redirect to S3).
    const result = util.runCmd(allocator, &.{ "curl", "-fSL", "-o", part_path, url }) catch {
        std.debug.print("labelle: download failed (is curl installed?)\n", .{});
        std.debug.print("  url: {s}\n", .{url});
        std.debug.print("  you can download manually and place it at: {s}\n", .{dest_path});
        return error.AssemblerDownloadFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("labelle: download failed (HTTP error, exit code {d})\n", .{code});
            std.debug.print("  url: {s}\n", .{url});
            std.debug.print("  you can download manually and place it at: {s}\n", .{dest_path});
            // The partial download is on `part_path` and the deferred
            // cleanup above removes it; dest_path was never written.
            return error.AssemblerDownloadFailed;
        },
        else => {
            std.debug.print("labelle: download process terminated abnormally\n", .{});
            return error.AssemblerDownloadFailed;
        },
    }

    // Integrity gate — before anything is moved into the cache slot or made
    // executable. Mirrors how `python_provision.zig` verifies its download
    // before extracting, except the expected digest comes from the release's
    // own manifest rather than a pinned constant (a pinned constant per
    // assembler version would need a CLI release for every assembler
    // release).
    try verifyAgainstManifest(allocator, version, asset, part_path);

    // Verified: move the staged bytes into the cache slot. Only now does
    // `dest_path` exist, so a caller's `access()` cache-hit check can never
    // see an unverified binary.
    std.Io.Dir.cwd().rename(part_path, std.Io.Dir.cwd(), dest_path, io) catch |err| {
        std.debug.print("labelle: could not move the verified download into place: {any}\n", .{err});
        std.debug.print("  staged at: {s}\n", .{part_path});
        return error.AssemblerDownloadFailed;
    };

    // Make executable on Unix.
    if (builtin.os.tag != .windows) {
        const file = std.Io.Dir.cwd().openFile(io, dest_path, .{}) catch |err| {
            std.debug.print("labelle: could not open {s} for chmod: {any}\n", .{ dest_path, err });
            return;
        };
        defer file.close(io);
        file.setPermissions(io, .fromMode(0o755)) catch |err| {
            std.debug.print("labelle: chmod failed for {s}: {any}\n", .{ dest_path, err });
        };
    }

    std.debug.print("  cached at {s}\n", .{dest_path});
}

/// Resolve the default assembler version. Downloads it if not cached.
/// Used when no assembler_version is configured in project.labelle.
/// Caller owns the returned slice and must free it.
pub fn resolveDefault(allocator: std.mem.Allocator) ![]u8 {
    const io = config.globalIo();
    const cache_root = try asm_cache.getCacheRoot(allocator);
    defer allocator.free(cache_root);

    const asm_path = try std.fs.path.join(allocator, &.{ cache_root, "assembler", DEFAULT_ASSEMBLER_VERSION, exe_name });

    std.Io.Dir.cwd().access(io, asm_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("labelle: no assembler_version in project.labelle — downloading default v{s}...\n", .{DEFAULT_ASSEMBLER_VERSION});
            downloadAssembler(allocator, DEFAULT_ASSEMBLER_VERSION, asm_path) catch |dl_err| {
                std.debug.print(
                    \\
                    \\labelle: could not download assembler v{s}.
                    \\  Add assembler_version to project.labelle or set LABELLE_ASSEMBLER env var.
                    \\  run: labelle install assembler {s}
                    \\
                , .{ DEFAULT_ASSEMBLER_VERSION, DEFAULT_ASSEMBLER_VERSION });
                allocator.free(asm_path);
                return dl_err;
            };
        },
        else => {
            allocator.free(asm_path);
            return err;
        },
    };

    return asm_path;
}

/// Resolve the assembler binary path using priority:
///   1. LABELLE_ASSEMBLER env var (local dev override)
///   2. assembler_version from project.labelle (pinned, resolved from cache)
///      If not cached, auto-downloads from GitHub releases.
///   3. null — caller should use resolveDefault() as fallback
///
/// Caller owns the returned slice and must free it.
pub fn resolveAssembler(allocator: std.mem.Allocator, project_dir: []const u8) !?[]u8 {
    const io = config.globalIo();
    // 1. Env var override always takes priority.
    if (try lookupOverride(allocator)) |path| return path;

    // 2. Check project.labelle for assembler_version.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const manifest = try launcher_manifest.readLauncherManifest(arena.allocator(), project_dir) orelse return null;
    const pinned_version = manifest.assembler_version orelse return null;

    // 2a. `local:<path>` — dev-mode pointer at a sibling labelle-assembler
    // checkout. Build it on demand (idempotent when up to date) and run
    // the binary out of its zig-out/bin/. Avoids the URL/hash cache path
    // entirely so monorepo-style edits round-trip without a release.
    if (std.mem.startsWith(u8, pinned_version, "local:")) {
        return try resolveLocalAssembler(allocator, pinned_version["local:".len..], project_dir);
    }

    // Resolve from cache: ~/.labelle/assembler/<version>/labelle-assembler
    const cache_root = try asm_cache.getCacheRoot(allocator);
    defer allocator.free(cache_root);

    const asm_path = try std.fs.path.join(allocator, &.{ cache_root, "assembler", pinned_version, exe_name });

    // Verify the binary exists; if not, auto-download it.
    std.Io.Dir.cwd().access(io, asm_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // Phase 4: auto-download instead of just erroring.
            std.debug.print("labelle: assembler v{s} not cached, downloading...\n", .{pinned_version});
            downloadAssembler(allocator, pinned_version, asm_path) catch {
                // Download failed — fall back to the manual install message.
                std.debug.print(
                    \\
                    \\labelle: assembler version {s} not found in cache.
                    \\  expected: {s}
                    \\  run: labelle install assembler {s}
                    \\
                , .{ pinned_version, asm_path, pinned_version });
                allocator.free(asm_path);
                return error.AssemblerNotCached;
            };
        },
        else => {
            allocator.free(asm_path);
            return err;
        },
    };

    return asm_path;
}

/// Explicitly install (download + cache) an assembler version.
/// Called by `labelle install assembler <version>`.
pub fn cmdInstallAssembler(allocator: std.mem.Allocator, version: []const u8) !void {
    const io = config.globalIo();
    const cache_root = try asm_cache.getCacheRoot(allocator);
    defer allocator.free(cache_root);

    const asm_path = try std.fs.path.join(allocator, &.{ cache_root, "assembler", version, exe_name });
    defer allocator.free(asm_path);

    // Check if already cached.
    std.Io.Dir.cwd().access(io, asm_path, .{}) catch {
        // Not cached — download it.
        try downloadAssembler(allocator, version, asm_path);
        std.debug.print("labelle: assembler v{s} installed\n", .{version});
        return;
    };

    std.debug.print("labelle: assembler v{s} already cached at {s}\n", .{ version, asm_path });
}

/// List cached assembler versions by scanning ~/.labelle/assembler/.
pub fn cmdListAssemblers(allocator: std.mem.Allocator) !void {
    const io = config.globalIo();
    const cache_root = try asm_cache.getCacheRoot(allocator);
    defer allocator.free(cache_root);

    const asm_dir = try std.fs.path.join(allocator, &.{ cache_root, "assembler" });
    defer allocator.free(asm_dir);

    var dir = std.Io.Dir.cwd().openDir(io, asm_dir, .{ .iterate = true }) catch {
        std.debug.print("labelle: no cached assembler versions found\n", .{});
        std.debug.print("  cache directory: {s}\n", .{asm_dir});
        return;
    };
    defer dir.close(io);

    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (count == 0) {
                std.debug.print("Cached assembler versions:\n", .{});
            }
            // Verify the binary actually exists inside the version directory.
            const bin_path = try std.fs.path.join(allocator, &.{ asm_dir, entry.name, exe_name });
            defer allocator.free(bin_path);
            const exists = blk: {
                std.Io.Dir.cwd().access(io, bin_path, .{}) catch break :blk false;
                break :blk true;
            };
            if (exists) {
                std.debug.print("  {s}\n", .{entry.name});
            } else {
                std.debug.print("  {s} (incomplete — binary missing)\n", .{entry.name});
            }
            count += 1;
        }
    }

    if (count == 0) {
        std.debug.print("labelle: no cached assembler versions found\n", .{});
        std.debug.print("  cache directory: {s}\n", .{asm_dir});
    }
}

// Issue #217 phase 2: `generate` subprocess invocation moved to the
// shared harness `cli/assembler_proc.zig` (`assembler_proc.generate`).
// This module keeps only the bootstrap concern — locating/downloading the
// assembler binary — which the harness builds on via `resolveAssembler` /
// `resolveDefault`.

/// If `project_dir` is a git worktree, return the path of the main checkout.
/// Otherwise return a copy of `project_dir` unchanged.
///
/// Worktree detection: `<project_dir>/.git` exists as a regular file (not a
/// directory). The file is a linkfile starting with `gitdir: <path>` where
/// `<path>` matches `<main>/.git/worktrees/<name>`. We validate this exact
/// shape — git uses `.git` linkfiles for other layouts (submodules end in
/// `/.git/modules/<name>`, `--separate-git-dir` can land anywhere) and
/// stripping three dirname levels would return the wrong directory.
///
/// `gitdir:` values can be either absolute or relative — git itself supports
/// both. Relative values are resolved against the directory containing the
/// `.git` file (i.e. project_dir).
///
/// Linkfiles are typically a single line but can carry additional keys like
/// `commondir:` — only the first line is parsed.
///
/// On any error (no .git, parse failure, non-worktree layout, etc.) returns
/// project_dir unchanged so non-git callers and the main checkout keep
/// their existing behavior.
///
/// Mirrors labelle-assembler/src/cache.zig:resolveProjectRoot — duplicated
/// rather than imported to avoid coupling the CLI release cycle to a
/// specific labelle_assembler version bump.
fn resolveProjectRoot(allocator: std.mem.Allocator, project_dir: []const u8) ![]u8 {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const git_path = try std.fs.path.join(allocator, &.{ project_dir, ".git" });
    defer allocator.free(git_path);

    const stat = cwd.statFile(io, git_path, .{}) catch return allocator.dupe(u8, project_dir);
    if (stat.kind != .file) return allocator.dupe(u8, project_dir);

    const content = cwd.readFileAlloc(io, git_path, allocator, .limited(4096)) catch
        return allocator.dupe(u8, project_dir);
    defer allocator.free(content);

    const eol = std.mem.indexOfAny(u8, content, "\r\n") orelse content.len;
    const first_line = std.mem.trim(u8, content[0..eol], " \t");

    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, first_line, prefix)) return allocator.dupe(u8, project_dir);

    const gitdir_raw = std.mem.trim(u8, first_line[prefix.len..], " \t");
    if (gitdir_raw.len == 0) return allocator.dupe(u8, project_dir);

    var gitdir_owned: ?[]u8 = null;
    defer if (gitdir_owned) |b| allocator.free(b);
    const gitdir = if (std.fs.path.isAbsolute(gitdir_raw)) gitdir_raw else blk: {
        const joined = try std.fs.path.join(allocator, &.{ project_dir, gitdir_raw });
        gitdir_owned = joined;
        break :blk joined;
    };

    const wt_dir = std.fs.path.dirname(gitdir) orelse return allocator.dupe(u8, project_dir);
    if (!std.mem.eql(u8, std.fs.path.basename(wt_dir), "worktrees"))
        return allocator.dupe(u8, project_dir);

    const dot_git = std.fs.path.dirname(wt_dir) orelse return allocator.dupe(u8, project_dir);
    if (!std.mem.eql(u8, std.fs.path.basename(dot_git), ".git"))
        return allocator.dupe(u8, project_dir);

    const main_checkout = std.fs.path.dirname(dot_git) orelse return allocator.dupe(u8, project_dir);
    // realPathFileAlloc returns [:0]u8 (allocation size = len+1); the
    // function's []u8 return type would coerce away the sentinel, leaving
    // callers to free a 99-byte slice for a 100-byte allocation. Re-dupe
    // into a plain []u8 so DebugAllocator's size check is satisfied.
    const canon = cwd.realPathFileAlloc(io, main_checkout, allocator) catch return allocator.dupe(u8, main_checkout);
    defer allocator.free(canon);
    return allocator.dupe(u8, canon);
}

// ── Tests ────────────────────────────────────────────────────────────

const zspec = @import("zspec");

test {
    zspec.runAll(@This());
}

pub const ResolveProjectRoot = struct {
    test "main checkout (.git is a directory) returns project_dir unchanged" {
        const alloc = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const io = config.globalIo();
        try tmp.dir.createDirPath(io, "project/.git");
        const project_abs = try tmp.dir.realPathFileAlloc(io, "project", alloc);
        defer alloc.free(project_abs);

        const root = try resolveProjectRoot(alloc, project_abs);
        defer alloc.free(root);

        try std.testing.expectEqualStrings(project_abs, root);
    }

    test "worktree linkfile resolves to main checkout" {
        const alloc = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const io = config.globalIo();
        try tmp.dir.createDirPath(io, "main/.git/worktrees/wt");
        try tmp.dir.createDirPath(io, "wt");

        const main_abs = try tmp.dir.realPathFileAlloc(io, "main", alloc);
        defer alloc.free(main_abs);
        const wt_abs = try tmp.dir.realPathFileAlloc(io, "wt", alloc);
        defer alloc.free(wt_abs);

        const linkfile = try std.fmt.allocPrint(alloc, "gitdir: {s}/.git/worktrees/wt\n", .{main_abs});
        defer alloc.free(linkfile);
        try tmp.dir.writeFile(io, .{ .sub_path = "wt/.git", .data = linkfile });

        const root = try resolveProjectRoot(alloc, wt_abs);
        defer alloc.free(root);

        try std.testing.expectEqualStrings(main_abs, root);
    }

    test "not a git repo returns project_dir unchanged" {
        const alloc = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const io = config.globalIo();
        try tmp.dir.createDirPath(io, "plain");
        const plain_abs = try tmp.dir.realPathFileAlloc(io, "plain", alloc);
        defer alloc.free(plain_abs);

        const root = try resolveProjectRoot(alloc, plain_abs);
        defer alloc.free(root);

        try std.testing.expectEqualStrings(plain_abs, root);
    }

    test "malformed linkfile returns project_dir unchanged" {
        const alloc = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const io = config.globalIo();
        try tmp.dir.createDirPath(io, "wt");
        const wt_abs = try tmp.dir.realPathFileAlloc(io, "wt", alloc);
        defer alloc.free(wt_abs);

        try tmp.dir.writeFile(io, .{ .sub_path = "wt/.git", .data = "not a gitdir line\n" });

        const root = try resolveProjectRoot(alloc, wt_abs);
        defer alloc.free(root);

        try std.testing.expectEqualStrings(wt_abs, root);
    }

    test "submodule .git linkfile returns project_dir unchanged" {
        const alloc = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const io = config.globalIo();
        try tmp.dir.createDirPath(io, "super/.git/modules/sub");
        try tmp.dir.createDirPath(io, "super/sub");

        const super_abs = try tmp.dir.realPathFileAlloc(io, "super", alloc);
        defer alloc.free(super_abs);
        const sub_abs = try tmp.dir.realPathFileAlloc(io, "super/sub", alloc);
        defer alloc.free(sub_abs);

        const linkfile = try std.fmt.allocPrint(alloc, "gitdir: {s}/.git/modules/sub\n", .{super_abs});
        defer alloc.free(linkfile);
        try tmp.dir.writeFile(io, .{ .sub_path = "super/sub/.git", .data = linkfile });

        const root = try resolveProjectRoot(alloc, sub_abs);
        defer alloc.free(root);

        try std.testing.expectEqualStrings(sub_abs, root);
    }

    test "relative gitdir is resolved against project_dir" {
        const alloc = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const io = config.globalIo();
        try tmp.dir.createDirPath(io, "main/.git/worktrees/wt");
        try tmp.dir.createDirPath(io, "main/wt");

        const main_abs = try tmp.dir.realPathFileAlloc(io, "main", alloc);
        defer alloc.free(main_abs);
        const wt_abs = try tmp.dir.realPathFileAlloc(io, "main/wt", alloc);
        defer alloc.free(wt_abs);

        try tmp.dir.writeFile(io, .{ .sub_path = "main/wt/.git", .data = "gitdir: ../.git/worktrees/wt\n" });

        const root = try resolveProjectRoot(alloc, wt_abs);
        defer alloc.free(root);

        try std.testing.expectEqualStrings(main_abs, root);
    }

    test "linkfile with extra keys (commondir) parses first line only" {
        const alloc = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const io = config.globalIo();
        try tmp.dir.createDirPath(io, "main/.git/worktrees/wt");
        try tmp.dir.createDirPath(io, "wt");

        const main_abs = try tmp.dir.realPathFileAlloc(io, "main", alloc);
        defer alloc.free(main_abs);
        const wt_abs = try tmp.dir.realPathFileAlloc(io, "wt", alloc);
        defer alloc.free(wt_abs);

        const linkfile = try std.fmt.allocPrint(
            alloc,
            "gitdir: {s}/.git/worktrees/wt\ncommondir: {s}/.git\n",
            .{ main_abs, main_abs },
        );
        defer alloc.free(linkfile);
        try tmp.dir.writeFile(io, .{ .sub_path = "wt/.git", .data = linkfile });

        const root = try resolveProjectRoot(alloc, wt_abs);
        defer alloc.free(root);

        try std.testing.expectEqualStrings(main_abs, root);
    }
};

/// The download-integrity gate (labelle-assembler#616): manifest parsing and
/// the missing-manifest version policy, which is the part with a real
/// decision in it. The end-to-end path is exercised by the released-path
/// smoke test in ci.yml.
pub const DownloadVerification = struct {
    test "digestFor: matches the exact asset name and returns its digest" {
        const manifest =
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  labelle-assembler-linux-aarch64\n" ++
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  labelle-assembler-linux-x86_64\n" ++
            "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  labelle-assembler-windows-x86_64\n";

        try std.testing.expectEqualStrings(
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            digestFor(manifest, "labelle-assembler-linux-x86_64").?,
        );
        try std.testing.expectEqualStrings(
            "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            digestFor(manifest, "labelle-assembler-windows-x86_64").?,
        );
    }

    test "digestFor: an asset the manifest does not list yields null (never a near-miss)" {
        const manifest =
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  labelle-assembler-linux-x86_64\n";
        // Not listed at all.
        try std.testing.expect(digestFor(manifest, "labelle-assembler-macos-aarch64") == null);
        // A PREFIX of a listed name must not match — the five asset names
        // share a prefix, so a substring search here would hand back the
        // wrong platform's digest instead of failing.
        try std.testing.expect(digestFor(manifest, "labelle-assembler-linux") == null);
        try std.testing.expect(digestFor(manifest, "labelle-assembler") == null);
    }

    test "digestFor: tolerates CRLF and a trailing newline, rejects malformed lines" {
        const crlf = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd  labelle-assembler-macos-x86_64\r\n";
        try std.testing.expectEqualStrings(
            "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            digestFor(crlf, "labelle-assembler-macos-x86_64").?,
        );
        // Single space (not the two-space text form) is not accepted, so a
        // manifest in an unexpected shape fails closed rather than matching
        // something approximate.
        try std.testing.expect(digestFor(
            "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd labelle-assembler-macos-x86_64\n",
            "labelle-assembler-macos-x86_64",
        ) == null);
        // Short/garbage lines are skipped, not misread.
        try std.testing.expect(digestFor("garbage\n\n", "labelle-assembler-macos-x86_64") == null);
    }

    test "the missing-manifest floor: newer than the last unverified release REQUIRES a manifest" {
        // This is the strip-attack defence. Everything strictly newer than
        // LAST_UNVERIFIED_ASSEMBLER_VERSION ships SHA256SUMS, so a 404 there
        // must be fatal — otherwise deleting the manifest disables the check.
        const floor = compatibility.parseVersion(LAST_UNVERIFIED_ASSEMBLER_VERSION);
        for ([_][]const u8{ "0.105.1", "0.106.0", "0.200.0", "1.0.0" }) |v| {
            try std.testing.expect(floor.olderThan(compatibility.parseVersion(v)));
        }
    }

    test "the missing-manifest floor: the last unverified release and older do NOT require one" {
        // These releases genuinely never published a manifest. Failing them
        // closed would brick every project pinned to one, so they warn and
        // proceed; a manifest, if one is ever backfilled, still binds.
        const floor = compatibility.parseVersion(LAST_UNVERIFIED_ASSEMBLER_VERSION);
        for ([_][]const u8{ "0.105.0", "0.104.0", "0.99.2", "0.1.0" }) |v| {
            try std.testing.expect(!floor.olderThan(compatibility.parseVersion(v)));
        }
        // The default the CLI ships with is on the unverified side today —
        // i.e. this change does not break the out-of-the-box path.
        try std.testing.expect(!floor.olderThan(compatibility.parseVersion(DEFAULT_ASSEMBLER_VERSION)));
    }

    test "a prerelease of the first verified version still requires a manifest" {
        // `0.106.0-rc1` is newer than 0.105.0, so it is on the verified side.
        const floor = compatibility.parseVersion(LAST_UNVERIFIED_ASSEMBLER_VERSION);
        try std.testing.expect(floor.olderThan(compatibility.parseVersion("0.106.0-rc1")));
    }

    test "sha256Matches is what the gate compares with (digest wiring sanity)" {
        // Guards the hex-case assumption: the manifest is lowercase hex and
        // util.sha256Matches only accepts lowercase.
        try std.testing.expect(util.sha256Matches("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
        try std.testing.expect(!util.sha256Matches("abc", "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"));
    }
};
