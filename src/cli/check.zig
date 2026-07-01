//! `labelle check` — the Packs enforcement lint (labelle-cli#270).
//!
//! Thin CLI wrapper: parses the optional project directory and delegates
//! to the standalone `labelle-assembler check` subcommand, which owns the
//! AST/token scan (it already has the pack-scan + `pack.labelle` DAG
//! machinery). Mirrors how `generate`/`install` delegate — the CLI stays a
//! driver over the assembler binary.
//!
//! The delegation goes through `assembler_proc.runSubcommand(.., "check", ..)`,
//! so the per-subcommand protocol gate (`minProtocolFor("check") == 5`,
//! #273) rejects a protocol-<5 assembler with a clear "needs protocol >= 5
//! for check" message *before* the binary is invoked — an old assembler
//! never sees `check` as an "unknown subcommand".
//!
//! Part of the Packs initiative: RFC Flying-Platform/flying-platform-labelle#561
//! §6 "Enforcement"; umbrella labelle-engine#651.
//!
//! Exit code is the assembler's own (`assembler_proc` re-exits with the
//! child's code): 0 when clean, 1 when violations are found — so `labelle
//! check` drops straight into a CI gate.

const std = @import("std");
const assembler_proc = @import("assembler_proc.zig");

const usage =
    \\  usage: labelle check [dir]
    \\
    \\Lint packs for §6 convention violations (Packs RFC). Delegates to
    \\`labelle-assembler check`. Exits 0 when clean, 1 on violations.
    \\
;

/// Parsed `labelle check` arguments: the resolved project dir plus the
/// user flags to forward verbatim to the assembler's `check` subcommand.
const CheckArgs = struct {
    /// Project directory (single optional positional, default `.`).
    dir: []const u8 = ".",
    /// User-supplied flags forwarded to the assembler untouched.
    /// `--project-root` is deliberately absent — see `parseCheckArgs`.
    forwarded: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *CheckArgs, allocator: std.mem.Allocator) void {
        self.forwarded.deinit(allocator);
    }
};

const ParseError = error{ TooManyArguments, MissingProjectRootValue, OutOfMemory };

/// Parse `check`'s argv into a `CheckArgs`.
///
/// Rules (fixes the codex/CodeRabbit findings at the old check.zig:L46):
///   - At most ONE positional is accepted as the project dir; a second
///     positional is a `TooManyArguments` error.
///   - `--project-root` is *reserved*: the CLI injects its own single
///     `--project-root <dir>` around the delegated call, so forwarding a
///     user-supplied one would double-inject it. Both the space-separated
///     (`--project-root <dir>`) and `=value` (`--project-root=<dir>`)
///     forms are recognized and set `dir` instead of being re-forwarded.
///     Consuming the value also stops it being mistaken for the positional
///     dir (the old "misparse `--flag value`" bug — mirrors the
///     `expect_value` arity handling the android parser uses in cli.zig).
///   - Every other `-`/`--` token is forwarded untouched so future
///     assembler `check` flags need no CLI change. Value-bearing forwarded
///     flags should use the `--flag=value` form so the value can't be
///     mistaken for the positional dir.
fn parseCheckArgs(allocator: std.mem.Allocator, cmd_args: []const []const u8) ParseError!CheckArgs {
    var result = CheckArgs{};
    errdefer result.forwarded.deinit(allocator);
    var dir_set = false;

    var i: usize = 0;
    while (i < cmd_args.len) : (i += 1) {
        const arg = cmd_args[i];

        // Reserved: `--project-root <dir>` — consume the value as `dir`,
        // never forward it.
        if (std.mem.eql(u8, arg, "--project-root")) {
            i += 1;
            if (i >= cmd_args.len) return error.MissingProjectRootValue;
            result.dir = cmd_args[i];
            dir_set = true;
            continue;
        }
        // Reserved: `--project-root=<dir>`.
        if (std.mem.startsWith(u8, arg, "--project-root=")) {
            result.dir = arg["--project-root=".len..];
            dir_set = true;
            continue;
        }
        // Any other flag is forwarded verbatim.
        if (std.mem.startsWith(u8, arg, "-")) {
            try result.forwarded.append(allocator, arg);
            continue;
        }
        // Bare positional — the project dir. At most one.
        if (dir_set) return error.TooManyArguments;
        result.dir = arg;
        dir_set = true;
    }

    return result;
}

/// Handle `labelle check [dir]`. `cmd_args` is everything after the
/// `check` token. The single optional positional is the project directory
/// (default `.`); any flags are forwarded to the assembler untouched so
/// future `check` flags need no CLI change.
pub fn cmdCheck(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    var parsed = parseCheckArgs(allocator, cmd_args) catch |err| switch (err) {
        error.TooManyArguments => {
            std.debug.print("labelle check: too many arguments (only one project dir accepted)\n", .{});
            std.debug.print("{s}", .{usage});
            return error.TooManyArguments;
        },
        error.MissingProjectRootValue => {
            std.debug.print("labelle check: --project-root requires a value\n", .{});
            std.debug.print("{s}", .{usage});
            return error.MissingProjectRootValue;
        },
        error.OutOfMemory => return err,
    };
    defer parsed.deinit(allocator);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    // The CLI injects its own single `--project-root` — reserved out of
    // `forwarded` by `parseCheckArgs` so it is never double-injected.
    try argv.appendSlice(allocator, &.{ "--project-root", parsed.dir });
    try argv.appendSlice(allocator, parsed.forwarded.items);

    // Route through the subcommand-aware resolver so the protocol-5 gate
    // (`assembler_proc.minProtocolFor("check")`) rejects an old assembler
    // up front instead of letting it fail with "unknown subcommand".
    try assembler_proc.runSubcommand(allocator, parsed.dir, "check", argv.items);
}

// ─────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────

const expect = @import("zspec").expect;

test {
    @import("zspec").runAll(@This());
}

pub const ParseCheckArgsSpec = struct {
    pub const dir_extraction = struct {
        test "defaults to '.' with no args" {
            var parsed = try parseCheckArgs(std.testing.allocator, &.{});
            defer parsed.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(".", parsed.dir);
            try expect.equal(parsed.forwarded.items.len, @as(usize, 0));
        }

        test "takes the sole positional as the dir" {
            var parsed = try parseCheckArgs(std.testing.allocator, &.{"sub/proj"});
            defer parsed.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("sub/proj", parsed.dir);
            try expect.equal(parsed.forwarded.items.len, @as(usize, 0));
        }
    };

    pub const flag_forwarding = struct {
        test "forwards unknown flags untouched, keeping the positional dir" {
            var parsed = try parseCheckArgs(std.testing.allocator, &.{ "proj", "--verbose", "--strict" });
            defer parsed.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("proj", parsed.dir);
            try expect.equal(parsed.forwarded.items.len, @as(usize, 2));
            try std.testing.expectEqualStrings("--verbose", parsed.forwarded.items[0]);
            try std.testing.expectEqualStrings("--strict", parsed.forwarded.items[1]);
        }

        test "a flag before the positional dir does not swallow it" {
            var parsed = try parseCheckArgs(std.testing.allocator, &.{ "--verbose", "proj" });
            defer parsed.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("proj", parsed.dir);
            try expect.equal(parsed.forwarded.items.len, @as(usize, 1));
            try std.testing.expectEqualStrings("--verbose", parsed.forwarded.items[0]);
        }
    };

    pub const project_root_reservation = struct {
        test "space-separated --project-root sets dir and is not forwarded" {
            var parsed = try parseCheckArgs(std.testing.allocator, &.{ "--project-root", "elsewhere" });
            defer parsed.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("elsewhere", parsed.dir);
            try expect.equal(parsed.forwarded.items.len, @as(usize, 0));
        }

        test "--project-root=value form sets dir and is not forwarded" {
            var parsed = try parseCheckArgs(std.testing.allocator, &.{"--project-root=elsewhere"});
            defer parsed.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("elsewhere", parsed.dir);
            try expect.equal(parsed.forwarded.items.len, @as(usize, 0));
        }

        test "--project-root value is not mistaken for a positional dir" {
            // The value 'elsewhere' must be consumed by the flag, leaving
            // the later real positional to fill `dir` (not error as a
            // second positional).
            var parsed = try parseCheckArgs(std.testing.allocator, &.{ "--project-root", "elsewhere", "--verbose" });
            defer parsed.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("elsewhere", parsed.dir);
            try expect.equal(parsed.forwarded.items.len, @as(usize, 1));
            try std.testing.expectEqualStrings("--verbose", parsed.forwarded.items[0]);
        }

        test "missing value after --project-root is an error" {
            try std.testing.expectError(error.MissingProjectRootValue, parseCheckArgs(std.testing.allocator, &.{"--project-root"}));
        }
    };

    pub const too_many_positionals = struct {
        test "a second positional is rejected" {
            try std.testing.expectError(error.TooManyArguments, parseCheckArgs(std.testing.allocator, &.{ "one", "two" }));
        }
    };
};
