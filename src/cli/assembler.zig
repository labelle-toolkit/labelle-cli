/// Subprocess wrapper for the standalone labelle-assembler binary.
///
/// Phase 2 of the assembler split (RFC #122). Lets the CLI optionally
/// invoke an out-of-process assembler binary instead of importing the
/// generator module in-process. Selection is opt-in via the
/// `LABELLE_ASSEMBLER` environment variable — when unset, the CLI keeps
/// using the existing in-process call path with no behaviour change.
///
/// In Phase 3 this resolution will move from "env var" to "version pin
/// in project.labelle" via the launcher manifest parser, and the env
/// var will become the local-development override.
const std = @import("std");
const gen = @import("generator");

/// Look up the override path. Returns null if `LABELLE_ASSEMBLER` is
/// unset, in which case the CLI should use the in-process generator.
/// Returns the heap-allocated path string on success — caller owns it.
pub fn lookupOverride(allocator: std.mem.Allocator) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, "LABELLE_ASSEMBLER") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
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
