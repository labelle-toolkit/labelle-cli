//! `labelle astc [dir] [--block 8x8] [--quality fast]` — build-time ASTC
//! conversion (assembler#340 / epic labelle-gfx#269).
//!
//! Reads `project.labelle`, and for every **atlas** resource runs astcenc over
//! its `.texture` PNG to produce a co-located `<name>.astc` (cached by mtime).
//! Resource-level + packer-agnostic: it doesn't care whether the atlas came
//! from free-tex-packer (FP) or `labelle pack`.

const std = @import("std");
const config = @import("../cli/config.zig");
const asm_cache = @import("../cli/asm_cache.zig");
const util = @import("../cli/util.zig");
const convert = @import("convert.zig");
const astcenc_bin = @import("astcenc_bin.zig");

const usage =
    \\Usage: labelle astc [dir] [--block <4x4|6x6|8x8|...>] [--quality <fastest|fast|medium|thorough>]
    \\
    \\Converts each atlas texture declared in project.labelle to a co-located
    \\<name>.astc (GPU-native, zero runtime decode). Default block 8x8, quality fast.
    \\
;

/// Filesystem mtime probe for the re-encode cache decision (injected into the
/// pure `convert.needsReencode`).
const Stat = struct {
    pub fn mtime(path: []const u8) ?i128 {
        const st = std.Io.Dir.cwd().statFile(config.globalIo(), path, .{}) catch return null;
        return @intCast(st.mtime.nanoseconds);
    }
};

fn parseQuality(s: []const u8) ?convert.Quality {
    inline for (@typeInfo(convert.Quality).@"enum".fields) |f| {
        if (std.mem.eql(u8, s, f.name)) return @field(convert.Quality, f.name);
    }
    return null;
}

pub fn cmdAstc(gpa: std.mem.Allocator, cmd_args: []const []const u8) !void {
    // One arena for the whole command: the parsed ProjectConfig + every path
    // join / subprocess buffer frees in a single deinit (the config strings
    // outlive each loop iteration and std.zon.parse.free is finicky on some
    // fields, so an arena is the clean lifetime model here).
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var dir: []const u8 = ".";
    var opts = convert.Options{};

    var i: usize = 0;
    while (i < cmd_args.len) : (i += 1) {
        const arg = cmd_args[i];
        if (std.mem.eql(u8, arg, "--block")) {
            i += 1;
            if (i >= cmd_args.len) return usageErr("--block needs a value (e.g. 8x8)");
            opts.block = convert.BlockSize.parse(cmd_args[i]) orelse return usageErr("unsupported --block size");
        } else if (std.mem.eql(u8, arg, "--quality")) {
            i += 1;
            if (i >= cmd_args.len) return usageErr("--quality needs a value");
            opts.quality = parseQuality(cmd_args[i]) orelse return usageErr("unknown --quality");
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErr("unknown option");
        } else {
            dir = arg;
        }
    }

    const cfg = config.readProjectConfigQuiet(allocator, dir) catch {
        std.debug.print("labelle astc: could not read project.labelle in '{s}'\n", .{dir});
        return error.InvalidArgs;
    };

    // Resolve the astcenc binary (download + cache on first use).
    const cache_root = try asm_cache.getCacheRoot(allocator);
    defer allocator.free(cache_root);
    const astcenc = try astcenc_bin.ensure(allocator, cache_root, astcenc_bin.DEFAULT_VERSION);
    defer allocator.free(astcenc);

    var converted: usize = 0;
    var cached: usize = 0;
    var failed: usize = 0;

    for (cfg.resources) |res| {
        if (res.kind() != .atlas) continue;

        const src = try std.fs.path.join(allocator, &.{ dir, res.texture });
        defer allocator.free(src);
        const out = try convert.outputPath(allocator, src);
        defer allocator.free(out);

        if (!convert.needsReencode(Stat, src, out)) {
            cached += 1;
            continue;
        }

        const args = try convert.buildArgs(allocator, astcenc, src, out, opts);
        defer allocator.free(args);
        const r = util.runCmd(allocator, args) catch {
            std.debug.print("labelle astc: failed to run astcenc on {s}\n", .{src});
            failed += 1;
            continue;
        };
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
        const ok = switch (r.term) {
            .exited => |c| c == 0,
            else => false,
        };
        if (ok) {
            std.debug.print("  {s} -> {s} ({s})\n", .{ src, out, opts.block.arg() });
            converted += 1;
        } else {
            std.debug.print("labelle astc: astcenc failed on {s}\n{s}\n", .{ src, r.stderr });
            failed += 1;
        }
    }

    std.debug.print("labelle astc: {d} converted, {d} up-to-date, {d} failed\n", .{ converted, cached, failed });
    if (failed > 0) return error.AstcConversionFailed;
}

fn usageErr(msg: []const u8) error{InvalidArgs} {
    std.debug.print("labelle astc: {s}\n{s}", .{ msg, usage });
    return error.InvalidArgs;
}

test "parseQuality maps presets and rejects junk" {
    try std.testing.expectEqual(convert.Quality.fast, parseQuality("fast").?);
    try std.testing.expectEqual(convert.Quality.thorough, parseQuality("thorough").?);
    try std.testing.expect(parseQuality("turbo") == null);
}
