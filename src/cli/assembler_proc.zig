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

/// Minimum assembler subcommand protocol this CLI requires. The CLI
/// delegates `install`/`clean`/`upgrade` (added at protocol 2),
/// `init` (protocol 3), and `add` (protocol 4); an older binary lacks
/// subcommands the CLI depends on. `resolve` checks this and fails early
/// with a clear message instead of letting a stale binary reject a
/// subcommand.
pub const REQUIRED_PROTOCOL: u32 = 4;

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
    errdefer allocator.free(path);
    try checkProtocol(allocator, path);
    return .{ .path = path };
}

/// Verify the resolved binary speaks a protocol this CLI understands.
/// `labelle-assembler --protocol-version` prints its integer protocol
/// to stdout; fail fast and legibly here rather than letting an
/// outdated binary reject a delegated subcommand opaquely.
fn checkProtocol(allocator: std.mem.Allocator, path: []const u8) !void {
    const res = std.process.run(allocator, config.globalIo(), .{
        .argv = &.{ path, "--protocol-version" },
    }) catch |err| {
        std.debug.print("labelle: could not query assembler protocol ('{s}'): {any}\n", .{ path, err });
        return error.AssemblerFailed;
    };
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    const reported = std.mem.trim(u8, res.stdout, " \t\r\n");
    const proto = std.fmt.parseInt(u32, reported, 10) catch {
        std.debug.print(
            "labelle: assembler '{s}' did not report a protocol version (too old?); this CLI needs protocol >= {d}\n",
            .{ path, REQUIRED_PROTOCOL },
        );
        return error.AssemblerFailed;
    };
    if (proto < REQUIRED_PROTOCOL) {
        std.debug.print(
            "labelle: assembler '{s}' speaks protocol {d}, but this CLI needs >= {d} — pin a newer 'assembler_version' in project.labelle\n",
            .{ path, proto, REQUIRED_PROTOCOL },
        );
        return error.AssemblerFailed;
    }
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

/// Run `labelle-assembler generate` against `project_dir`.
///
/// Issue #217 phase 2: the CLI's `generate` / `build` / `run` commands
/// delegate code generation to the assembler binary instead of calling
/// the in-process `generate()`. `build` / `run` then invoke `zig build`
/// (and launch the binary) themselves — those steps stay CLI-side because
/// the CLI owns docker orchestration, WASM serve, the iOS/Android deploy
/// paths and `--timeout`; only the generation step is delegated.
///
/// `platform` / `backend` are forwarded as plain strings (`@tagName` of
/// the CLI's enums) so this module needs no dependency on the assembler's
/// type definitions. The assembler validates them against its own enums.
///
/// The `--scene` flag is *not* forwarded to the assembler: PR #243 (cli#229
/// follow-through) removed the CLI's `cfg.initial_prefab` rewrite, but the
/// assembler still rewrites `cfg.initial_prefab = scene_override` when it
/// receives `--scene`, which re-introduces the same loading-scene-gate
/// bypass on the assembler side. The runtime `LABELLE_SCENE` env-var
/// injection (see cli.zig:~990) is now the sole mechanism for the
/// user-facing `--scene` flag; the assembler always compiles a stable
/// artifact with `initial_prefab` taken straight from `project.labelle`.
///
/// On a non-zero exit code, returns `error.AssemblerFailed`; the binary's
/// inherited stderr already explains the failure.
pub fn generate(
    asm_bin: Assembler,
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    platform: []const u8,
    backend: []const u8,
) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    try buildGenerateArgs(allocator, &args, project_dir, platform, backend);

    try asm_bin.run(allocator, "generate", args.items);
}

/// Build the argv slice for the assembler's `generate` subcommand.
/// Extracted so a test can assert the CLI never injects `--scene` into
/// the assembler invocation, even though the user-facing `--scene` flag
/// is still accepted by the CLI (it routes through `LABELLE_SCENE` env
/// injection at the spawn site instead — see cli.zig:~990).
fn buildGenerateArgs(
    allocator: std.mem.Allocator,
    args: *std.ArrayList([]const u8),
    project_dir: []const u8,
    platform: []const u8,
    backend: []const u8,
) !void {
    try args.appendSlice(allocator, &.{ "--project-root", project_dir });
    // Always forward platform/backend — the CLI may have mutated them
    // (e.g. `labelle ios` forces sokol+ios) and the binary must not
    // re-derive its own values from project.labelle.
    try args.appendSlice(allocator, &.{ "--platform", platform });
    try args.appendSlice(allocator, &.{ "--backend", backend });
}

const expect = @import("zspec").expect;

test {
    @import("zspec").runAll(@This());
}

/// Regression guard for the cli#229 follow-through (#2). PR #243 removed
/// the CLI's own `cfg.initial_prefab` rewrite when `--scene=X` was passed,
/// but the assembler binary *also* rewrites `cfg.initial_prefab =
/// scene_override` whenever it receives `--scene` — bypassing the
/// loading-scene gate exactly the same way the CLI rewrite used to.
///
/// Contract: even when the user passes `--scene=X` to the CLI, the
/// argv this module sends to `labelle-assembler generate` must NOT
/// contain `--scene`. The override travels at runtime via the
/// `LABELLE_SCENE` env var the CLI injects when it spawns the game.
pub const BuildGenerateArgsSpec = struct {
    pub const no_scene_forwarding = struct {
        test "argv to assembler never contains --scene" {
            const allocator = std.testing.allocator;
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(allocator);

            try buildGenerateArgs(allocator, &args, "/proj", "desktop", "raylib");

            for (args.items) |a| {
                try std.testing.expect(!std.mem.eql(u8, a, "--scene"));
            }
        }
    };

    pub const forwards_project_platform_backend = struct {
        test "argv carries --project-root, --platform, --backend" {
            const allocator = std.testing.allocator;
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(allocator);

            try buildGenerateArgs(allocator, &args, "/proj", "desktop", "raylib");

            const expected: []const []const u8 = &.{
                "--project-root", "/proj",
                "--platform",     "desktop",
                "--backend",      "raylib",
            };
            try std.testing.expectEqual(expected.len, args.items.len);
            for (expected, args.items) |want, got| {
                try std.testing.expectEqualStrings(want, got);
            }
        }
    };
};

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
            // stderr. Exit with its *exact* code so the CLI is a faithful
            // proxy for the delegated subcommand — returning a plain
            // `error.AssemblerFailed` would collapse every distinct
            // failure (usage error, config error, build failure) to a
            // single exit status 1.
            std.process.exit(code);
        },
        else => {
            std.debug.print("labelle: assembler '{s}' terminated abnormally\n", .{exe_path});
            return error.AssemblerFailed;
        },
    }
}
