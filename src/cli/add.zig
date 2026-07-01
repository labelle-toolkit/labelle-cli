const std = @import("std");
const assembler_proc = @import("assembler_proc.zig");
const config = @import("config.zig");

/// Scaffold a pack or a feature-unit by delegating to the assembler binary.
///
/// Packs initiative (umbrella labelle-engine#651, RFC-packs §7, #271).
/// `labelle add pack <name>` / `labelle add feature <kind> <name>` scaffold
/// the two authoring units the Packs RFC defines. Like `labelle init`, the
/// heavy lifting is assembler knowledge — the `pack.labelle` schema and the
/// game-root convention layout are the assembler's — so the CLI is a thin
/// forwarder: it hands `add ...` to `labelle-assembler add ...` verbatim
/// and propagates the exit code.
///
/// `cmd_args` is `["pack", name]` or `["feature", kind, name]` (plus any
/// flags), collected unchanged by the cli.zig arg parser. The assembler
/// validates the shape and prints diagnostics.
///
/// Resolution: `add` runs inside an existing project, so `resolve` reads
/// the pinned `assembler_version` from `./project.labelle` (falling back to
/// the CLI-paired default when there is none). The `add` subcommand needs
/// assembler protocol >= 4.
///
/// Project guard: `add` is dispatched from cli.zig's standalone-command
/// switch, so it never passes through the `readProjectConfig` guard that
/// project-scoped commands (`generate`/`build`/`run`) use. Without an
/// explicit check here, `labelle add pack foo` run in the wrong cwd (home
/// dir, a mistyped path) would scaffold `packs/`/`components/`/`scripts/`
/// THERE. Require a `project.labelle` in cwd first and emit the same
/// "No project.labelle found" error the project-scoped guard does.
pub fn cmdAdd(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    if (!config.projectExists(".")) {
        config.printNoProjectError(".");
        // Match the project-scoped guard's non-zero outcome without a
        // Zig error-return trace (same pattern as `android doctor`).
        std.process.exit(1);
    }
    try assembler_proc.runSubcommand(allocator, ".", "add", cmd_args);
}
