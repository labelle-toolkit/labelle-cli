/// Subprocess wrapper for the standalone labelle-assembler binary.
///
/// Phase 2-4 of the assembler split (RFC #122). Resolves the external
/// assembler binary via three-tier priority:
///
///   1. `LABELLE_ASSEMBLER` env var — local dev override (always wins)
///   2. `assembler_version` in project.labelle — pinned version resolved
///      from the cache at `~/.labelle/assembler/<version>/labelle-assembler`
///      If not cached, auto-downloads from GitHub releases (Phase 4).
///   3. Absent — fall back to the bundled in-process generator
const std = @import("std");

/// Default assembler version pinned in newly scaffolded projects.
/// Bump this in lockstep with the labelle_assembler dep in build.zig.zon —
/// a stale value here would auto-download a binary whose ABI doesn't match
/// the bundled generator module the CLI is compiled against.
pub const DEFAULT_ASSEMBLER_VERSION = "0.8.0";
const builtin = @import("builtin");
const gen = @import("generator");
const launcher_manifest = @import("launcher_manifest.zig");
const util = @import("util.zig");
const runner = @import("runner.zig");

/// GitHub release URL template for assembler binaries.
const ASSEMBLER_RELEASE_BASE = "https://github.com/labelle-toolkit/labelle-assembler/releases/download";

/// Look up the override path. Returns null if `LABELLE_ASSEMBLER` is
/// unset, in which case the CLI should use the in-process generator.
/// Returns the heap-allocated path string on success — caller owns it.
pub fn lookupOverride(allocator: std.mem.Allocator) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, "LABELLE_ASSEMBLER") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
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
    const source_dir = if (std.fs.path.isAbsolute(rel_path))
        try allocator.dupe(u8, rel_path)
    else blk: {
        const root = try resolveProjectRoot(allocator, project_dir);
        defer allocator.free(root);
        break :blk try std.fs.path.join(allocator, &.{ root, rel_path });
    };
    defer allocator.free(source_dir);

    const real_source = std.fs.cwd().realpathAlloc(allocator, source_dir) catch |err| {
        std.debug.print("labelle: local assembler path '{s}' does not exist: {any}\n", .{ source_dir, err });
        return error.AssemblerNotCached;
    };
    defer allocator.free(real_source);

    std.debug.print("labelle: building local assembler at {s}...\n", .{real_source});
    const build_result = runner.runZig(allocator, real_source, &.{ "zig", "build" }) catch |err| {
        std.debug.print("labelle: failed to run 'zig build' in {s}: {any}\n", .{ real_source, err });
        return error.AssemblerNotCached;
    };
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);
    switch (build_result.term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("labelle: local assembler build failed (exit {d})\n{s}", .{ code, build_result.stderr });
            return error.AssemblerNotCached;
        },
        else => {
            std.debug.print("labelle: local assembler build terminated abnormally\n", .{});
            return error.AssemblerNotCached;
        },
    }

    const bin_path = try std.fs.path.join(allocator, &.{ real_source, "zig-out", "bin", exe_name });
    std.fs.cwd().access(bin_path, .{}) catch |err| {
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
        std.fs.cwd().makePath(dir) catch |err| {
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
        .Exited => |code| if (code != 0) {
            std.debug.print("labelle: download failed (HTTP error, exit code {d})\n", .{code});
            std.debug.print("  url: {s}\n", .{url});
            std.debug.print("  you can download manually and place it at: {s}\n", .{dest_path});
            // Clean up partial download
            std.fs.cwd().deleteFile(dest_path) catch {};
            return error.AssemblerDownloadFailed;
        },
        else => {
            std.debug.print("labelle: download process terminated abnormally\n", .{});
            std.fs.cwd().deleteFile(dest_path) catch {};
            return error.AssemblerDownloadFailed;
        },
    }

    // Make executable on Unix.
    if (builtin.os.tag != .windows) {
        const file = std.fs.cwd().openFile(dest_path, .{}) catch |err| {
            std.debug.print("labelle: could not open {s} for chmod: {any}\n", .{ dest_path, err });
            return;
        };
        defer file.close();
        file.chmod(0o755) catch |err| {
            std.debug.print("labelle: chmod failed for {s}: {any}\n", .{ dest_path, err });
        };
    }

    std.debug.print("  cached at {s}\n", .{dest_path});
}

/// Resolve the default assembler version. Downloads it if not cached.
/// Used when no assembler_version is configured in project.labelle.
/// Caller owns the returned slice and must free it.
pub fn resolveDefault(allocator: std.mem.Allocator) ![]u8 {
    const cache_root = try gen.getCacheRoot(allocator);
    defer allocator.free(cache_root);

    const asm_path = try std.fs.path.join(allocator, &.{ cache_root, "assembler", DEFAULT_ASSEMBLER_VERSION, exe_name });

    std.fs.cwd().access(asm_path, .{}) catch |err| switch (err) {
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
    const cache_root = try gen.getCacheRoot(allocator);
    defer allocator.free(cache_root);

    const asm_path = try std.fs.path.join(allocator, &.{ cache_root, "assembler", pinned_version, exe_name });

    // Verify the binary exists; if not, auto-download it.
    std.fs.cwd().access(asm_path, .{}) catch |err| switch (err) {
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
    const cache_root = try gen.getCacheRoot(allocator);
    defer allocator.free(cache_root);

    const asm_path = try std.fs.path.join(allocator, &.{ cache_root, "assembler", version, exe_name });
    defer allocator.free(asm_path);

    // Check if already cached.
    std.fs.cwd().access(asm_path, .{}) catch {
        // Not cached — download it.
        try downloadAssembler(allocator, version, asm_path);
        std.debug.print("labelle: assembler v{s} installed\n", .{version});
        return;
    };

    std.debug.print("labelle: assembler v{s} already cached at {s}\n", .{ version, asm_path });
}

/// List cached assembler versions by scanning ~/.labelle/assembler/.
pub fn cmdListAssemblers(allocator: std.mem.Allocator) !void {
    const cache_root = try gen.getCacheRoot(allocator);
    defer allocator.free(cache_root);

    const asm_dir = try std.fs.path.join(allocator, &.{ cache_root, "assembler" });
    defer allocator.free(asm_dir);

    var dir = std.fs.cwd().openDir(asm_dir, .{ .iterate = true }) catch {
        std.debug.print("labelle: no cached assembler versions found\n", .{});
        std.debug.print("  cache directory: {s}\n", .{asm_dir});
        return;
    };
    defer dir.close();

    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            if (count == 0) {
                std.debug.print("Cached assembler versions:\n", .{});
            }
            // Verify the binary actually exists inside the version directory.
            const bin_path = try std.fs.path.join(allocator, &.{ asm_dir, entry.name, exe_name });
            defer allocator.free(bin_path);
            const exists = blk: {
                std.fs.cwd().access(bin_path, .{}) catch break :blk false;
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

/// Spawn `labelle-assembler generate` against the given project and
/// inherit stdio so the user sees the binary's diagnostics directly.
/// Forwards the same overrides the in-process path applies (scene,
/// platform, backend) so the binary produces identical output.
///
/// On a non-zero exit code, returns `error.AssemblerFailed`. The
/// binary's stderr already explains what went wrong.
pub fn spawnGenerate(
    allocator: std.mem.Allocator,
    exe_path: []const u8,
    project_dir: []const u8,
    scene_override: ?[]const u8,
    platform: gen.Platform,
    backend: gen.Backend,
) !void {
    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, &.{ exe_path, "generate", "--project-root", project_dir });

    if (scene_override) |s| try argv.appendSlice(allocator, &.{ "--scene", s });

    // Always forward platform/backend so the binary doesn't have to
    // re-derive what the CLI may have already mutated (e.g. for the
    // `labelle ios` subcommand which forces sokol+ios).
    try argv.appendSlice(allocator, &.{ "--platform", @tagName(platform) });
    try argv.appendSlice(allocator, &.{ "--backend", @tagName(backend) });

    var child: std.process.Child = .init(argv.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("labelle: assembler '{s}' exited with code {d}\n", .{ exe_path, code });
            return error.AssemblerFailed;
        },
        else => {
            std.debug.print("labelle: assembler '{s}' terminated abnormally\n", .{exe_path});
            return error.AssemblerFailed;
        },
    }
}

/// If `project_dir` is a git worktree, return the path of the main checkout.
/// Otherwise return a copy of `project_dir` unchanged.
///
/// Worktree detection: `<project_dir>/.git` exists as a regular file (not a
/// directory). The file is a single-line linkfile: `gitdir: <abs>/.git/worktrees/<name>`.
/// The main checkout is three `dirname` steps above that gitdir value
/// (strip `<name>`, then `worktrees`, then `.git`).
///
/// On any error (no .git, parse failure, etc.) returns project_dir unchanged
/// so non-git callers and the main checkout keep their existing behavior.
///
/// Mirrors labelle-assembler/src/cache.zig:resolveProjectRoot — duplicated
/// rather than imported to avoid coupling the CLI release cycle to a
/// specific labelle_assembler version bump.
fn resolveProjectRoot(allocator: std.mem.Allocator, project_dir: []const u8) ![]u8 {
    const git_path = try std.fs.path.join(allocator, &.{ project_dir, ".git" });
    defer allocator.free(git_path);

    const stat = std.fs.cwd().statFile(git_path) catch return allocator.dupe(u8, project_dir);
    if (stat.kind != .file) return allocator.dupe(u8, project_dir);

    const content = std.fs.cwd().readFileAlloc(allocator, git_path, 4096) catch
        return allocator.dupe(u8, project_dir);
    defer allocator.free(content);

    const line = std.mem.trim(u8, content, " \t\r\n");
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, line, prefix)) return allocator.dupe(u8, project_dir);

    const gitdir = std.mem.trim(u8, line[prefix.len..], " \t");
    if (gitdir.len == 0) return allocator.dupe(u8, project_dir);

    var path = gitdir;
    var i: u8 = 0;
    while (i < 3) : (i += 1) {
        path = std.fs.path.dirname(path) orelse return allocator.dupe(u8, project_dir);
    }
    return allocator.dupe(u8, path);
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

        try tmp.dir.makePath("project/.git");
        const project_abs = try tmp.dir.realpathAlloc(alloc, "project");
        defer alloc.free(project_abs);

        const root = try resolveProjectRoot(alloc, project_abs);
        defer alloc.free(root);

        try std.testing.expectEqualStrings(project_abs, root);
    }

    test "worktree linkfile resolves to main checkout" {
        const alloc = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.makePath("main/.git/worktrees/wt");
        try tmp.dir.makePath("wt");

        const main_abs = try tmp.dir.realpathAlloc(alloc, "main");
        defer alloc.free(main_abs);
        const wt_abs = try tmp.dir.realpathAlloc(alloc, "wt");
        defer alloc.free(wt_abs);

        const linkfile = try std.fmt.allocPrint(alloc, "gitdir: {s}/.git/worktrees/wt\n", .{main_abs});
        defer alloc.free(linkfile);
        const f = try tmp.dir.createFile("wt/.git", .{});
        defer f.close();
        try f.writeAll(linkfile);

        const root = try resolveProjectRoot(alloc, wt_abs);
        defer alloc.free(root);

        try std.testing.expectEqualStrings(main_abs, root);
    }

    test "not a git repo returns project_dir unchanged" {
        const alloc = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.makePath("plain");
        const plain_abs = try tmp.dir.realpathAlloc(alloc, "plain");
        defer alloc.free(plain_abs);

        const root = try resolveProjectRoot(alloc, plain_abs);
        defer alloc.free(root);

        try std.testing.expectEqualStrings(plain_abs, root);
    }

    test "malformed linkfile returns project_dir unchanged" {
        const alloc = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.makePath("wt");
        const wt_abs = try tmp.dir.realpathAlloc(alloc, "wt");
        defer alloc.free(wt_abs);

        const f = try tmp.dir.createFile("wt/.git", .{});
        defer f.close();
        try f.writeAll("not a gitdir line\n");

        const root = try resolveProjectRoot(alloc, wt_abs);
        defer alloc.free(root);

        try std.testing.expectEqualStrings(wt_abs, root);
    }
};
