const std = @import("std");
const assembler_proc = @import("assembler_proc.zig");
const project_config = @import("project_config.zig");

/// Scaffold a new project directory by delegating to the assembler binary.
///
/// Issue #217 phase 3: new-project scaffolding moved into the standalone
/// `labelle-assembler` binary (`labelle-assembler init <name> [dir] ...`).
/// `project.labelle` is the assembler's schema and the scaffolded version
/// pins are the assembler's defaults, so the assembler owns the command.
/// The CLI forwards argv verbatim, plus one flag (below).
///
/// Argument forwarding: the assembler's `init` takes `<name> [dir]` plus
/// the same `--backend` / `--ecs` / `--gui` / `--*-version` flags the CLI
/// used to parse in-process. Passing `cmd_args` through unchanged keeps
/// `labelle init ...` behavior identical.
///
/// Default versions: the assembler stamps its own pinned
/// `core`/`engine`/`gfx` versions, and the `assembler_version` field
/// defaults to the resolved binary's own version. A
/// `--assembler-version=X` flag still overrides it.
///
/// `labelle_version` is the exception: the CLI running `init` is the one
/// the project was made with, so it passes its own version as
/// `--labelle-version` unless the user gave one. The assembler's built-in
/// fallback is a curated constant that lags CLI releases, so a fresh
/// project would otherwise pin an older CLI major and warn on every run.
///
/// Resolution: `init` runs before any project exists, so there is no
/// `project.labelle` to read an `assembler_version` pin from. `resolve`
/// is given `"."` and falls through to the CLI-paired default assembler
/// (downloaded if absent).
pub fn cmdInit(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    const args = try withCliVersion(allocator, cmd_args, project_config.CLI_VERSION);
    defer freeArgs(allocator, args, cmd_args);
    try assembler_proc.runSubcommand(allocator, ".", "init", args);
}

const labelle_version_flag = "--labelle-version";

/// `cmd_args` plus `--labelle-version=<cli_version>`, unless the user
/// already passed `--labelle-version` (either `=X` or as a separate
/// argument). Returns `cmd_args` itself when nothing is added.
fn withCliVersion(allocator: std.mem.Allocator, cmd_args: []const []const u8, cli_version: []const u8) ![]const []const u8 {
    for (cmd_args) |arg| {
        if (std.mem.eql(u8, arg, labelle_version_flag) or
            std.mem.startsWith(u8, arg, labelle_version_flag ++ "=")) return cmd_args;
    }
    const out = try allocator.alloc([]const u8, cmd_args.len + 1);
    errdefer allocator.free(out);
    @memcpy(out[0..cmd_args.len], cmd_args);
    out[cmd_args.len] = try std.fmt.allocPrint(allocator, labelle_version_flag ++ "={s}", .{cli_version});
    return out;
}

fn freeArgs(allocator: std.mem.Allocator, args: []const []const u8, cmd_args: []const []const u8) void {
    if (args.ptr == cmd_args.ptr) return;
    allocator.free(args[args.len - 1]);
    allocator.free(args);
}

pub const InitCliVersionSpec = struct {
    test "init: passes the running CLI's version as --labelle-version" {
        const a = std.testing.allocator;
        const in = [_][]const u8{ "foo", "--ecs=zig_ecs" };
        const out = try withCliVersion(a, &in, "2.0.0");
        defer freeArgs(a, out, &in);
        try std.testing.expectEqual(@as(usize, 3), out.len);
        try std.testing.expectEqualStrings("foo", out[0]);
        try std.testing.expectEqualStrings("--ecs=zig_ecs", out[1]);
        try std.testing.expectEqualStrings("--labelle-version=2.0.0", out[2]);
    }

    test "init: a user --labelle-version wins, in either spelling" {
        const a = std.testing.allocator;
        const eq = [_][]const u8{ "foo", "--labelle-version=1.9.0" };
        const eq_out = try withCliVersion(a, &eq, "2.0.0");
        defer freeArgs(a, eq_out, &eq);
        try std.testing.expect(eq_out.ptr == (&eq).ptr);

        const sep = [_][]const u8{ "foo", "--labelle-version", "1.9.0" };
        const sep_out = try withCliVersion(a, &sep, "2.0.0");
        defer freeArgs(a, sep_out, &sep);
        try std.testing.expect(sep_out.ptr == (&sep).ptr);
    }
};
