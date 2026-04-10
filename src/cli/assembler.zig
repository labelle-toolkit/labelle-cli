/// Subprocess wrapper for the standalone labelle-assembler binary.
///
/// Phase 2-3 of the assembler split (RFC #122). Resolves the external
/// assembler binary via three-tier priority:
///
///   1. `LABELLE_ASSEMBLER` env var — local dev override (always wins)
///   2. `assembler_version` in project.labelle — pinned version resolved
///      from the cache at `~/.labelle/assembler/<version>/labelle-assembler`
///   3. Absent — fall back to the bundled in-process generator
///
/// When an `assembler_version` is pinned but the cached binary is missing,
/// the CLI prints an actionable error and returns `error.AssemblerNotCached`.
const std = @import("std");
const gen = @import("generator");
const launcher_manifest = @import("launcher_manifest.zig");

/// Look up the override path. Returns null if `LABELLE_ASSEMBLER` is
/// unset, in which case the CLI should use the in-process generator.
/// Returns the heap-allocated path string on success — caller owns it.
pub fn lookupOverride(allocator: std.mem.Allocator) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, "LABELLE_ASSEMBLER") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
}

/// Resolve the assembler binary path using three-tier priority:
///   1. LABELLE_ASSEMBLER env var (local dev override)
///   2. assembler_version from project.labelle (pinned, resolved from cache)
///   3. null (use in-process generator)
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

    // Resolve from cache: ~/.labelle/assembler/<version>/labelle-assembler
    const cache_root = try gen.getCacheRoot(allocator);
    defer allocator.free(cache_root);

    const exe_name = "labelle-assembler" ++ if (comptime @import("builtin").os.tag == .windows) ".exe" else "";
    const asm_path = try std.fs.path.join(allocator, &.{ cache_root, "assembler", pinned_version, exe_name });

    // Verify the binary exists.
    std.fs.cwd().access(asm_path, .{}) catch {
        std.debug.print(
            \\labelle: assembler version {s} not found in cache.
            \\  expected: {s}
            \\  run: labelle install assembler {s}
            \\
        , .{ pinned_version, asm_path, pinned_version });
        allocator.free(asm_path);
        return error.AssemblerNotCached;
    };

    return asm_path;
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
