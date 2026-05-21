const std = @import("std");
const assembler_proc = @import("assembler_proc.zig");

/// Remove unused cached package versions from ~/.labelle/packages/.
///
/// Issue #217 phase 1: delegated to the standalone `labelle-assembler`
/// binary (`labelle-assembler clean ...`). The CLI keeps the same
/// user-facing flags — `--dry-run` and `--project=<dir>` — and translates
/// `--project=` to the assembler's `--project-root`.
pub fn cmdClean(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    var dry_run = false;
    var project_dir: []const u8 = ".";
    for (cmd_args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.startsWith(u8, arg, "--project=")) {
            project_dir = arg["--project=".len..];
        } else {
            std.debug.print("labelle clean: unknown option '{s}'\n", .{arg});
            std.debug.print("  usage: labelle clean [--dry-run] [--project=<dir>]\n", .{});
            return error.InvalidArgument;
        }
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    if (dry_run) try argv.append(allocator, "--dry-run");
    try argv.appendSlice(allocator, &.{ "--project-root", project_dir });

    // `clean` can run from anywhere — pass project_dir so the assembler
    // resolver checks that project's pinned version; with no
    // project.labelle it falls back to the CLI-paired default.
    try assembler_proc.runSubcommand(allocator, project_dir, "clean", argv.items);
}
