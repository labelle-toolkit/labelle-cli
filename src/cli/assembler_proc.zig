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
const supervise = @import("supervise.zig");
const assembler = @import("assembler.zig");
const progress = @import("progress.zig");

/// Global floor: every subcommand the CLI delegates needs at least this
/// protocol (`install`/`clean`/`upgrade` arrived at protocol 2, `init` at
/// protocol 3). Crucially, this floor also gates the *auto-downloaded*
/// `DEFAULT_ASSEMBLER_VERSION` (see `assembler.resolveDefault`): a fresh
/// install with no project pin runs the default binary, so raising this
/// number would reject that default before ANY command can run — a breaking
/// change for every existing user. Keep the floor at what the paired default
/// speaks (protocol 3) and gate newer subcommands per-command via
/// `minProtocolFor` instead of bumping this.
pub const MIN_PROTOCOL: u32 = 3;

/// The first assembler protocol with `describe` and `generate --target`.
pub const describe_protocol: u32 = 7;

/// Per-subcommand minimum protocol. Most subcommands need only the global
/// floor (`MIN_PROTOCOL`); a subcommand that depends on an assembler feature
/// added after the paired default declares a higher minimum here. Modelling
/// this as a small lookup (rather than one global constant) means gating a
/// new subcommand is a one-line entry that never raises the floor for
/// existing commands or the auto-downloaded default.
///
/// Extensible: adding a new gated subcommand is a one-line entry here.
///
/// `generate` and `describe` need protocol 7 (RFC cli#471 D4): the CLI no
/// longer knows any backend, so the generated target dir, the backend's
/// name and whether it supports the target come only from `describe`, and
/// `generate` takes the target through `--target`. The paired default
/// (`DEFAULT_ASSEMBLER_VERSION`) speaks it; an older project pin is refused
/// with one line naming `labelle upgrade assembler`.
fn minProtocolFor(subcommand: []const u8) u32 {
    const Gate = struct { name: []const u8, min: u32 };
    const gates = [_]Gate{
        .{ .name = "add", .min = 4 }, // Packs scaffold (#271)
        .{ .name = "check", .min = 5 }, // Packs §6 lint (#273)
        .{ .name = "generate", .min = describe_protocol }, // cli#471 D4
        .{ .name = "describe", .min = describe_protocol }, // cli#471 D1/D4
        // Not a subcommand: `upgrade backend [ver]` (cli#471 D2), which
        // `labelle upgrade` resolves the assembler under before delegating.
        .{ .name = "upgrade backend", .min = describe_protocol },
    };
    for (gates) |g| {
        if (std.mem.eql(u8, g.name, subcommand)) return g.min;
    }
    return MIN_PROTOCOL;
}

/// A located assembler binary, ready to be invoked. Returned by `resolve`
/// so a caller that runs several subcommands can resolve once and reuse.
pub const Assembler = struct {
    /// Absolute path to the `labelle-assembler` executable. Heap-owned.
    path: []u8,
    /// The protocol the binary reported (`--protocol-version`) when it was
    /// resolved; 0 when unknown. Lets a caller gate an optional feature
    /// (e.g. `describe`, protocol 7 — cli#471 D3) without a second spawn.
    protocol: u32 = 0,
    /// A failing subcommand ends the CLI with the assembler's exit code
    /// (`progress.fatalExit`). A watched rebuild clears it: a failed
    /// regeneration must fail that rebuild and keep the session alive, and
    /// the session's cleanup must still run.
    fatal_on_failure: bool = true,

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
        return spawnAndWait(allocator, self.path, subcommand, args, self.fatal_on_failure);
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
/// `subcommand` is the assembler subcommand about to be delegated; it
/// selects the minimum protocol via `minProtocolFor` (so `add` can require
/// a newer binary than `generate` without raising the global floor).
///
/// Caller owns the returned `Assembler` and must `deinit` it.
pub fn resolve(allocator: std.mem.Allocator, project_dir: []const u8, subcommand: []const u8) !Assembler {
    const path = try assembler.resolveAssembler(allocator, project_dir) orelse
        try assembler.resolveDefault(allocator);
    errdefer allocator.free(path);
    const protocol = try checkProtocol(allocator, path, subcommand);
    return .{ .path = path, .protocol = protocol };
}

/// Verify the resolved binary speaks a protocol high enough for
/// `subcommand`. `labelle-assembler --protocol-version` prints its integer
/// protocol to stdout; fail fast and legibly here rather than letting an
/// outdated binary reject a delegated subcommand opaquely. The required
/// minimum is per-subcommand (`minProtocolFor`) so newer subcommands don't
/// reject a binary that older subcommands (and the auto-downloaded default)
/// still work with. Returns the reported protocol.
fn checkProtocol(allocator: std.mem.Allocator, path: []const u8, subcommand: []const u8) !u32 {
    const required = minProtocolFor(subcommand);
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
            "labelle: assembler '{s}' did not report a protocol version (too old?); '{s}' needs protocol >= {d}\n",
            .{ path, subcommand, required },
        );
        return error.AssemblerFailed;
    };
    if (proto < required) {
        std.debug.print(
            "labelle: '{s}' needs assembler protocol >= {d}, but '{s}' speaks {d} — run `labelle upgrade assembler` (or pin a newer 'assembler_version' in project.labelle)\n",
            .{ subcommand, required, path, proto },
        );
        return error.AssemblerFailed;
    }
    return proto;
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
    const asm_bin = try resolve(allocator, project_dir, subcommand);
    defer asm_bin.deinit(allocator);
    try asm_bin.run(allocator, subcommand, args);
}

/// Run `labelle-assembler generate` against `project_dir`.
///
/// Issue #217 phase 2: the CLI's `generate` / `build` / `run` commands
/// delegate code generation to the assembler binary instead of calling
/// the in-process `generate()`. `build` / `run` then invoke `zig build`
/// (and launch the binary) themselves — those steps stay CLI-side because
/// the CLI owns docker orchestration, the watch supervision, the legacy
/// deploy path and `--timeout`; only the generation step is delegated.
///
/// The target is forwarded as a plain string (`--target`, protocol 7); the
/// assembler validates it. No backend is forwarded (RFC cli#471 D4): the
/// assembler reads the project's own `.backend` / `.backend_package`.
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
    target: []const u8,
) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);

    try buildGenerateArgs(allocator, &args, project_dir, target);

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
    target: []const u8,
) !void {
    try args.appendSlice(allocator, &.{ "--project-root", project_dir });
    // Always forward the RESOLVED target (`--platform=<t>` may differ from
    // what project.labelle declares). Never a backend (RFC cli#471 D4).
    try args.appendSlice(allocator, &.{ "--target", target });
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

            try buildGenerateArgs(allocator, &args, "/proj", "desktop");

            for (args.items) |a| {
                try std.testing.expect(!std.mem.eql(u8, a, "--scene"));
            }
        }
    };

    pub const forwards_project_and_target = struct {
        test "argv carries --project-root and --target, never --backend (cli#471 D4)" {
            const allocator = std.testing.allocator;
            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(allocator);

            try buildGenerateArgs(allocator, &args, "/proj", "desktop");

            const expected: []const []const u8 = &.{
                "--project-root", "/proj",
                "--target",       "desktop",
            };
            try std.testing.expectEqual(expected.len, args.items.len);
            for (expected, args.items) |want, got| {
                try std.testing.expectEqualStrings(want, got);
            }
        }
    };
};

/// Codex review (#272): the `add` subcommand needs a newer assembler
/// (protocol 4) than the global floor, but that requirement must NOT be
/// raised globally — the auto-downloaded `DEFAULT_ASSEMBLER_VERSION` only
/// speaks the floor (protocol 3), so a global bump breaks every fresh
/// install before any command runs. These specs pin the per-subcommand
/// map: `add` gates at 4, `check` gates at 5, the floor commands stay at 3,
/// and an unknown subcommand falls back to the floor.
pub const MinProtocolForSpec = struct {
    pub const add_gates_higher = struct {
        test "add requires protocol 4" {
            try std.testing.expectEqual(@as(u32, 4), minProtocolFor("add"));
        }
    };

    pub const check_gates_higher = struct {
        test "check requires protocol 5" {
            try std.testing.expectEqual(@as(u32, 5), minProtocolFor("check"));
        }
    };

    pub const describe_gates = struct {
        test "generate and describe require protocol 7 (cli#471 D4)" {
            try std.testing.expectEqual(@as(u32, 7), minProtocolFor("generate"));
            try std.testing.expectEqual(@as(u32, 7), minProtocolFor("describe"));
            try std.testing.expectEqual(@as(u32, 7), minProtocolFor("upgrade backend"));
        }
    };

    pub const floor_commands = struct {
        test "install/clean/upgrade/init stay at the floor" {
            for ([_][]const u8{ "install", "clean", "upgrade", "init" }) |cmd| {
                try std.testing.expectEqual(MIN_PROTOCOL, minProtocolFor(cmd));
            }
        }
    };

    pub const unknown_falls_back = struct {
        test "unknown subcommand uses the floor" {
            try std.testing.expectEqual(MIN_PROTOCOL, minProtocolFor("does-not-exist"));
        }
    };

    pub const gate_exceeds_floor = struct {
        test "a protocol-3 binary would be rejected for add and generate but not install" {
            const proto: u32 = 3;
            try std.testing.expect(proto < minProtocolFor("add"));
            try std.testing.expect(proto < minProtocolFor("generate"));
            try std.testing.expect(proto >= minProtocolFor("install"));
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
    fatal_on_failure: bool,
) !void {
    const io = config.globalIo();

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe_path);
    try argv.append(allocator, subcommand);
    try argv.appendSlice(allocator, args);

    var child = supervise.spawn(io, .{
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
            if (!fatal_on_failure) {
                std.debug.print("labelle: assembler {s} failed (exit {d})\n", .{ subcommand, code });
                return error.AssemblerFailed;
            }
            // The assembler already printed a diagnostic on its inherited
            // stderr. Exit with its *exact* code so the CLI is a faithful
            // proxy for the delegated subcommand — returning a plain
            // `error.AssemblerFailed` would collapse every distinct
            // failure (usage error, config error, build failure) to a
            // single exit status 1. `progress.fatalExit` (cli#284) first
            // marks any active build-status file `failed` — a bare
            // process-exit would skip the errdefer that does that and
            // leave the status file claiming the build is still alive.
            // The detail names the delegated stage (cli#318) so feed
            // consumers learn e.g. "assembler generate failed"; stderr is
            // inherited (not captured), so the child's own diagnostic line
            // is not available here without log scraping.
            var detail_buf: [progress.max_detail_len]u8 = undefined;
            const detail = std.fmt.bufPrint(
                &detail_buf,
                "assembler {s} failed",
                .{subcommand},
            ) catch "assembler failed";
            progress.fatalExit(code, detail);
        },
        else => {
            std.debug.print("labelle: assembler '{s}' terminated abnormally\n", .{exe_path});
            return error.AssemblerFailed;
        },
    }
}
