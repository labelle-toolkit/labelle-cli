const std = @import("std");
const assembler_proc = @import("assembler_proc.zig");

/// Scaffold a new project directory by delegating to the assembler binary.
///
/// Issue #217 phase 3: new-project scaffolding moved into the standalone
/// `labelle-assembler` binary (`labelle-assembler init <name> [dir] ...`).
/// `project.labelle` is the assembler's schema and the scaffolded version
/// pins are the assembler's defaults, so the assembler owns the command.
/// The CLI just forwards argv verbatim.
///
/// Argument forwarding: the assembler's `init` takes `<name> [dir]` plus
/// the same `--backend` / `--ecs` / `--gui` / `--*-version` flags the CLI
/// used to parse in-process. Passing `cmd_args` through unchanged keeps
/// `labelle init ...` behavior identical.
///
/// Default versions: the CLI no longer supplies them — the assembler
/// stamps its own pinned `core`/`engine`/`gfx`/`cli` versions, and the
/// `assembler_version` field defaults to the resolved binary's own
/// version. A `--assembler-version=X` flag still overrides it.
///
/// Resolution: `init` runs before any project exists, so there is no
/// `project.labelle` to read an `assembler_version` pin from. `resolve`
/// is given `"."` and falls through to the CLI-paired default assembler
/// (downloaded if absent).
pub fn cmdInit(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    try assembler_proc.runSubcommand(allocator, ".", "init", cmd_args);
}
