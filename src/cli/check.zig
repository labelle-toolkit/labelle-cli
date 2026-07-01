//! `labelle check` — the Packs enforcement lint (labelle-cli#270).
//!
//! Thin CLI wrapper: parses the optional project directory and delegates
//! to the standalone `labelle-assembler check` subcommand, which owns the
//! AST/token scan (it already has the pack-scan + `pack.labelle` DAG
//! machinery). Mirrors how `generate`/`install` delegate — the CLI stays a
//! driver over the assembler binary.
//!
//! Part of the Packs initiative: RFC Flying-Platform/flying-platform-labelle#561
//! §6 "Enforcement"; umbrella labelle-engine#651.
//!
//! Exit code is the assembler's own (`assembler_proc` re-exits with the
//! child's code): 0 when clean, 1 when violations are found — so `labelle
//! check` drops straight into a CI gate.

const std = @import("std");
const assembler_proc = @import("assembler_proc.zig");

/// Handle `labelle check [dir]`. `cmd_args` is everything after the
/// `check` token. The single optional positional is the project directory
/// (default `.`); any flags are forwarded to the assembler untouched so
/// future `check` flags need no CLI change.
pub fn cmdCheck(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    var dir: []const u8 = ".";
    var dir_set = false;

    var forwarded: std.ArrayList([]const u8) = .empty;
    defer forwarded.deinit(allocator);

    for (cmd_args) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            try forwarded.append(allocator, arg);
        } else if (!dir_set) {
            dir = arg;
            dir_set = true;
        } else {
            std.debug.print("labelle check: unexpected argument '{s}'\n", .{arg});
            std.debug.print("  usage: labelle check [dir]\n", .{});
            return error.TooManyArguments;
        }
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "--project-root", dir });
    try argv.appendSlice(allocator, forwarded.items);

    try assembler_proc.runSubcommand(allocator, dir, "check", argv.items);
}
