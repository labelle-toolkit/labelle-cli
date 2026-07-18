const std = @import("std");
const assembler = @import("assembler.zig");
const assembler_proc = @import("assembler_proc.zig");
const zig_toolchain = @import("zig_toolchain.zig");
const emsdk_toolchain = @import("emsdk_toolchain.zig");
const python_provision = @import("python_provision.zig");

/// Fetch and cache packages without modifying any project.
///
/// Issue #217 phase 1: package-cache work is delegated to the standalone
/// `labelle-assembler` binary (`labelle-assembler install ...`). The one
/// exception is `install assembler <version>`, which downloads the
/// assembler *binary* itself — a CLI-owned bootstrap concern the
/// assembler can't perform for itself.
pub fn cmdInstall(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    // `labelle install assembler <version>` — CLI bootstrap. Stays here.
    if (cmd_args.len >= 1 and std.mem.eql(u8, cmd_args[0], "assembler")) {
        if (cmd_args.len < 2) {
            std.debug.print("labelle install assembler: missing version argument\n", .{});
            std.debug.print("  usage: labelle install assembler <version>\n", .{});
            std.debug.print("  example: labelle install assembler 1.0.0\n", .{});
            return error.MissingArgument;
        }
        return assembler.cmdInstallAssembler(allocator, cmd_args[1]);
    }

    // `labelle install zig <version>` — CLI bootstrap (cli#279). Download +
    // verify + extract a managed Zig into `~/.labelle/zig/<version>/`.
    if (cmd_args.len >= 1 and std.mem.eql(u8, cmd_args[0], "zig")) {
        if (cmd_args.len < 2) {
            std.debug.print("labelle install zig: missing version argument\n", .{});
            std.debug.print("  usage: labelle install zig <version>\n", .{});
            std.debug.print("  example: labelle install zig {s}\n", .{zig_toolchain.DEFAULT_ZIG_VERSION});
            return error.MissingArgument;
        }
        return zig_toolchain.cmdInstallZig(allocator, cmd_args[1]);
    }

    // `labelle install python [version]` — CLI bootstrap (cli#291). Download +
    // verify + extract a managed python-build-standalone into
    // `~/.labelle/python/`. The version is PINNED (per-platform checksums are
    // baked in), so unlike zig/emsdk the argument is optional and only
    // accepted when it matches the pin — arbitrary versions have no verified
    // checksum to install against.
    if (cmd_args.len >= 1 and std.mem.eql(u8, cmd_args[0], "python")) {
        if (cmd_args.len >= 2 and !std.mem.eql(u8, cmd_args[1], python_provision.PY_VERSION)) {
            std.debug.print("labelle install python: only the pinned version {s} is supported (checksums are baked per release)\n", .{python_provision.PY_VERSION});
            return error.InvalidArgument;
        }
        return switch (python_provision.provisionPython(allocator)) {
            .ready => {},
            .guided => {},
            .failed => error.ProvisionFailed,
        };
    }

    // `labelle install emsdk <version>` — CLI bootstrap (cli#283). Fetch +
    // verify + **activate** a managed emsdk into `~/.labelle/emsdk/<version>/`.
    if (cmd_args.len >= 1 and std.mem.eql(u8, cmd_args[0], "emsdk")) {
        if (cmd_args.len < 2) {
            std.debug.print("labelle install emsdk: missing version argument\n", .{});
            std.debug.print("  usage: labelle install emsdk <version>\n", .{});
            std.debug.print("  example: labelle install emsdk {s}\n", .{emsdk_toolchain.DEFAULT_EMSDK_VERSION});
            return error.MissingArgument;
        }
        return emsdk_toolchain.cmdInstallEmsdk(allocator, cmd_args[1]);
    }

    // Every other form delegates to the assembler binary.
    //
    //   labelle install               → install deps for current project
    //   labelle install <version>     → cache core/engine/gfx at a version
    //   labelle install <pkg> <ver>   → cache one package
    //
    // The assembler `install` subcommand takes the project form via
    // `--project-root`; the version/package forms are bare positionals.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    if (cmd_args.len == 0) {
        // No args — install the current project's deps. The assembler
        // needs `--project-root` to find project.labelle.
        try argv.appendSlice(allocator, &.{ "--project-root", "." });
    } else {
        try argv.appendSlice(allocator, cmd_args);
    }

    try assembler_proc.runSubcommand(allocator, ".", "install", argv.items);
}
