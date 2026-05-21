//! Reusable CLI → assembler subprocess-invocation helper.
//!
//! Issue #217 makes `labelle-cli` a thin driver over the standalone
//! `labelle-assembler` binary: the CLI parses argv, locates the binary,
//! and forwards a subcommand to it as a subprocess. This module is the
//! one place that knows how to do that — phase 1 uses it for the cache
//! commands (`install` / `clean` / `upgrade`); later phases reuse it for
//! `generate` / `build` / `run` / `init`.
//!
//! What it does:
//!   - locates the assembler binary (env var > project.labelle pin >
//!     CLI-paired default), via `assembler.zig`'s existing resolver,
//!   - spawns `labelle-assembler <subcommand> [args...]` with inherited
//!     stdio (the binary's output streams straight to the user),
//!   - waits and maps the child's exit code onto a Zig error so callers
//!     can propagate failure.
//!
//! Bootstrap caveat: the assembler can't fetch itself, so the CLI must
//! locate the binary before delegating. `assembler.resolveAssembler`
//! reads `assembler_version` from project.labelle. Cache commands may run
//! with no project.labelle in cwd (e.g. `labelle clean` from anywhere);
//! in that case `resolveAssembler` returns null and we fall back to
//! `assembler.resolveDefault`, which resolves/downloads the assembler
//! version paired with this CLI build (`assembler.DEFAULT_ASSEMBLER_VERSION`).
//! See `runSubcommand` for the exact resolution order.

const std = @import("std");
const config = @import("config.zig");
const assembler = @import("assembler.zig");

/// A located assembler binary, ready to be invoked. Returned by `resolve`
/// so a caller that runs several subcommands can resolve once and reuse.
pub const Assembler = struct {
    /// Absolute path to the `labelle-assembler` executable. Heap-owned.
    path: []u8,

    /// Free the owned path.
    pub fn deinit(self: Assembler, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }

    /// Run `labelle-assembler <subcommand> [args...]` with inherited
    /// stdio. See `runSubcommand` for exit-code semantics.
    pub fn run(
        self: Assembler,
        allocator: std.mem.Allocator,
        subcommand: []const u8,
        args: []const []const u8,
    ) !void {
        return spawnAndWait(allocator, self.path, subcommand, args);
    }
};

/// Locate the assembler binary.
///
/// Resolution order (delegated to `assembler.zig`):
///   1. `LABELLE_ASSEMBLER` env var — local-dev override.
///   2. `assembler_version` in `<project_dir>/project.labelle` — the
///      pinned version, resolved from (or downloaded into) the cache.
///   3. No project / no pin — the assembler version paired with this CLI
///      build (`assembler.DEFAULT_ASSEMBLER_VERSION`), downloaded if absent.
///
/// `project_dir` is where the CLI looks for `project.labelle`. Pass `"."`
/// for commands that may run outside a project (the resolver tolerates a
/// missing manifest and falls through to step 3).
///
/// Caller owns the returned `Assembler` and must `deinit` it.
pub fn resolve(allocator: std.mem.Allocator, project_dir: []const u8) !Assembler {
    const path = try assembler.resolveAssembler(allocator, project_dir) orelse
        try assembler.resolveDefault(allocator);
    return .{ .path = path };
}

/// One-shot convenience: locate the assembler and run a single subcommand.
/// Equivalent to `resolve` + `Assembler.run` + `deinit`.
///
/// On a non-zero exit code, returns `error.AssemblerFailed`; the binary's
/// own stderr (inherited) already explains the failure.
pub fn runSubcommand(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    subcommand: []const u8,
    args: []const []const u8,
) !void {
    const asm_bin = try resolve(allocator, project_dir);
    defer asm_bin.deinit(allocator);
    try asm_bin.run(allocator, subcommand, args);
}

/// Spawn `exe_path <subcommand> [args...]`, inherit stdio, wait, and map
/// the result onto a Zig error. Shared by `Assembler.run` and
/// `runSubcommand`.
fn spawnAndWait(
    allocator: std.mem.Allocator,
    exe_path: []const u8,
    subcommand: []const u8,
    args: []const []const u8,
) !void {
    const io = config.globalIo();

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe_path);
    try argv.append(allocator, subcommand);
    try argv.appendSlice(allocator, args);

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        std.debug.print("labelle: could not launch assembler '{s}': {any}\n", .{ exe_path, err });
        return error.AssemblerFailed;
    };

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            // The assembler already printed a diagnostic on its inherited
            // stderr; surface the code so the CLI exits non-zero too.
            return error.AssemblerFailed;
        },
        else => {
            std.debug.print("labelle: assembler '{s}' terminated abnormally\n", .{exe_path});
            return error.AssemblerFailed;
        },
    }
}
