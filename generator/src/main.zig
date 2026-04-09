//! labelle-assembler — standalone binary entry point.
//!
//! Phase 1 of the assembler split (RFC #122 / PR #123). This binary
//! coexists with the in-process generator that the `labelle` CLI imports
//! as a Zig module via `b.dependency("generator", .{})`. Adding it here
//! is purely additive — no existing code path changes.
//!
//! The binary exposes a subprocess protocol the CLI launcher will adopt
//! in Phase 2 (opt-in via `LABELLE_ASSEMBLER` env var) and Phase 3
//! (project-pinned `assembler_version` in `project.labelle`).
//!
//! Cache prerequisite: this binary assumes the package cache is already
//! populated (engine/core/gfx packages available where the generator
//! expects them). The CLI handles cache management before invoking the
//! assembler. Running the binary directly is intended for testing the
//! CLI ↔ assembler boundary and for power users who manage their own
//! cache.

const std = @import("std");
const gen = @import("root.zig");

/// Wire protocol version for CLI ↔ assembler subprocess communication.
/// Bump when the command surface or output format changes in a way the
/// CLI launcher needs to detect. The launcher reads this via
/// `labelle-assembler --protocol-version` before invoking any subcommand.
pub const PROTOCOL_VERSION: u32 = 1;

const usage =
    \\labelle-assembler — code generator for the labelle game toolkit
    \\
    \\Usage:
    \\  labelle-assembler --protocol-version
    \\  labelle-assembler --help
    \\  labelle-assembler generate --project-root <path> [options]
    \\
    \\Subcommands:
    \\  generate    Materialize .labelle/<target>/ from project.labelle
    \\
    \\Generate options:
    \\  --project-root <path>   Path to game project (containing project.labelle)
    \\  --scene <name>          Override initial scene from project.labelle
    \\
    \\Notes:
    \\  This binary assumes the package cache is already populated. The
    \\  `labelle` CLI handles cache management before invoking the
    \\  assembler.
    \\
    \\See: https://github.com/labelle-toolkit/labelle-assembler
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip(); // program name

    const first = args.next() orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    };

    if (std.mem.eql(u8, first, "--protocol-version")) {
        // Protocol version goes to stdout so callers can capture it via
        // a normal pipe. Everything else goes to stderr.
        const stdout = std.fs.File.stdout();
        var buf: [16]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{d}\n", .{PROTOCOL_VERSION});
        try stdout.writeAll(msg);
        return;
    }

    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "help")) {
        std.debug.print("{s}", .{usage});
        return;
    }

    if (std.mem.eql(u8, first, "generate")) {
        try cmdGenerate(allocator, &args);
        return;
    }

    std.debug.print("labelle-assembler: unknown subcommand '{s}'\n\n{s}", .{ first, usage });
    std.process.exit(2);
}

fn cmdGenerate(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var project_root: ?[]const u8 = null;
    var scene_override: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--project-root")) {
            project_root = args.next() orelse {
                std.debug.print("labelle-assembler: --project-root requires a value\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--project-root=")) {
            project_root = arg["--project-root=".len..];
        } else if (std.mem.eql(u8, arg, "--scene")) {
            scene_override = args.next() orelse {
                std.debug.print("labelle-assembler: --scene requires a value\n", .{});
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--scene=")) {
            scene_override = arg["--scene=".len..];
        } else {
            std.debug.print("labelle-assembler generate: unknown flag '{s}'\n", .{arg});
            std.process.exit(2);
        }
    }

    const root = project_root orelse {
        std.debug.print("labelle-assembler generate: --project-root is required\n", .{});
        std.process.exit(2);
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var cfg = readProjectConfig(arena_alloc, root) catch |err| {
        std.debug.print("labelle-assembler: failed to read project.labelle in '{s}': {s}\n", .{ root, @errorName(err) });
        std.process.exit(1);
    };

    if (scene_override) |s| cfg.initial_scene = s;

    // Resolve GUI plugin (reads gui.labelle manifest from plugin directory)
    // and populates cfg.resolved_gui. Must run before gen.generate so the
    // generated build.zig/zon and main.zig include the GUI module wiring.
    gen.resolveGuiPlugin(arena_alloc, &cfg, root) catch |err| {
        std.debug.print("labelle-assembler: failed to resolve GUI plugin: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const output_dir = try std.fs.path.join(allocator, &.{ root, ".labelle" });
    defer allocator.free(output_dir);

    gen.generate(allocator, cfg, output_dir, root) catch |err| {
        std.debug.print("labelle-assembler: generate failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const target_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ @tagName(cfg.backend), @tagName(cfg.platform) });
    defer allocator.free(target_name);
    std.debug.print("labelle-assembler: generated .labelle/{s}/\n", .{target_name});

    // NOTE: build.zig.zon's `.fingerprint` field is left at the placeholder
    // value emitted by the generator template. The CLI patches it via a
    // post-generate `runner.fixFingerprint` pass that runs `zig build`,
    // parses Zig's "use this value: 0x..." error from stderr, and rewrites
    // the field. Until Phase 2 wires the launcher to do that post-step
    // around the subprocess invocation, callers of this binary must run
    // an equivalent fixFingerprint pass before `zig build` will succeed
    // against the generated tree. Tracked for follow-up.
}

/// Inline copy of `cli/config.zig:readProjectConfig`. Lives here so the
/// assembler binary doesn't pull in CLI-side modules. The CLI's version
/// will route through this binary in Phase 2; this duplication is
/// intentional and temporary.
fn readProjectConfig(allocator: std.mem.Allocator, project_dir: []const u8) !gen.ProjectConfig {
    @setEvalBranchQuota(10000);
    const labelle_path = try std.fs.path.join(allocator, &.{ project_dir, "project.labelle" });
    defer allocator.free(labelle_path);

    const source_raw = try std.fs.cwd().readFileAlloc(allocator, labelle_path, 1024 * 1024);
    defer allocator.free(source_raw);

    const source = try allocator.dupeZ(u8, source_raw);
    return try std.zon.parse.fromSlice(gen.ProjectConfig, allocator, source, null, .{});
}
