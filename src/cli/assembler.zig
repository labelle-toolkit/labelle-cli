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
pub const DEFAULT_ASSEMBLER_VERSION = "0.97.1";
const builtin = @import("builtin");
const asm_cache = @import("asm_cache.zig");
const config = @import("config.zig");
const launcher_manifest = @import("launcher_manifest.zig");
const util = @import("util.zig");
const runner = @import("runner.zig");

/// GitHub release URL template for assembler binaries.
const ASSEMBLER_RELEASE_BASE = "https://github.com/labelle-toolkit/labelle-assembler/releases/download";

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

/// Download an assembler binary from GitHub releases and cache it.
///
/// URL pattern: https://github.com/labelle-toolkit/labelle-assembler/releases/download/v<version>/labelle-assembler-<os>-<arch>
///
/// The binary is saved to `~/.labelle/assembler/<version>/labelle-assembler`
/// and made executable on Unix.
pub fn downloadAssembler(allocator: std.mem.Allocator, version: []const u8, dest_path: []const u8) !void {
    const io = config.globalIo();
    const url = try std.fmt.allocPrint(allocator, "{s}/v{s}/labelle-assembler-{s}-{s}", .{
        ASSEMBLER_RELEASE_BASE,
        version,
        try osName(),
        try archName(),
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

    // Use curl with -L to follow redirects (GitHub releases redirect to S3).
    const result = util.runCmd(allocator, &.{ "curl", "-fSL", "-o", dest_path, url }) catch {
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
            // Clean up partial download
            std.Io.Dir.cwd().deleteFile(io, dest_path) catch {};
            return error.AssemblerDownloadFailed;
        },
        else => {
            std.debug.print("labelle: download process terminated abnormally\n", .{});
            std.Io.Dir.cwd().deleteFile(io, dest_path) catch {};
            return error.AssemblerDownloadFailed;
        },
    }

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
