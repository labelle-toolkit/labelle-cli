//! `labelle pack` — pack a folder of PNGs into a sprite atlas.
//!
//! Usage: labelle pack <input-dir> [-o <name>] [--out-dir <dir>]
//!                      [--padding <n>] [--max-size <n>]
//!
//! Writes `<name>.atlas.png` + `<name>.atlas.json` (labelle-cli#213).
//! Replaces the external `npx free-tex-packer-cli` step.

const std = @import("std");
const texpack = @import("../texpack/texpack.zig");
const config = @import("config.zig");

const usage =
    \\usage: labelle pack <input-dir> [options]
    \\  -o, --name <name>    atlas base name (default: input folder name)
    \\      --out-dir <dir>  where to write the atlas (default: alongside input)
    \\      --padding <n>    gap between sprites in px (default: 2)
    \\      --max-size <n>   max sheet dimension in px (default: 4096)
    \\
;

pub fn cmdPack(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    var input_dir: ?[]const u8 = null;
    var name_opt: ?[]const u8 = null;
    var out_dir_opt: ?[]const u8 = null;
    var padding: i32 = 2;
    var max_size: i32 = 4096;

    var i: usize = 0;
    while (i < cmd_args.len) : (i += 1) {
        const arg = cmd_args[i];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--name")) {
            name_opt = nextValue(cmd_args, &i) orelse return usageErr("missing value for --name");
        } else if (std.mem.eql(u8, arg, "--out-dir")) {
            out_dir_opt = nextValue(cmd_args, &i) orelse return usageErr("missing value for --out-dir");
        } else if (std.mem.eql(u8, arg, "--padding")) {
            const v = nextValue(cmd_args, &i) orelse return usageErr("missing value for --padding");
            padding = std.fmt.parseInt(i32, v, 10) catch return usageErr("--padding must be an integer");
            if (padding < 0) return usageErr("--padding must be >= 0");
        } else if (std.mem.eql(u8, arg, "--max-size")) {
            const v = nextValue(cmd_args, &i) orelse return usageErr("missing value for --max-size");
            max_size = std.fmt.parseInt(i32, v, 10) catch return usageErr("--max-size must be an integer");
            if (max_size <= 0) return usageErr("--max-size must be > 0");
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErr2("unknown option", arg);
        } else if (input_dir == null) {
            input_dir = arg;
        } else {
            return usageErr2("unexpected extra argument", arg);
        }
    }

    const in = input_dir orelse {
        std.debug.print("labelle pack: missing <input-dir>\n{s}", .{usage});
        return error.InvalidArgs;
    };

    // Trim a trailing slash so basename/dirname behave as expected.
    const in_trimmed = std.mem.trimEnd(u8, in, "/");
    const name = name_opt orelse std.fs.path.basename(in_trimmed);
    const out_dir = out_dir_opt orelse (std.fs.path.dirname(in_trimmed) orelse ".");

    const result = texpack.packDir(allocator, config.globalIo(), in, out_dir, name, .{
        .padding = padding,
        .max_size = max_size,
    }) catch |err| {
        switch (err) {
            error.FileNotFound => std.debug.print("labelle pack: input directory not found: {s}\n", .{in}),
            error.NoImagesFound => std.debug.print("labelle pack: no .png files in {s}\n", .{in}),
            error.AtlasTooLarge => std.debug.print(
                "labelle pack: sprites don't fit within {d}x{d} — raise --max-size\n",
                .{ max_size, max_size },
            ),
            error.DecodeFailed => std.debug.print("labelle pack: failed to decode a PNG in {s}\n", .{in}),
            error.EncodeFailed => std.debug.print("labelle pack: failed to encode the atlas PNG\n", .{}),
            else => std.debug.print("labelle pack: {s}\n", .{@errorName(err)}),
        }
        return err;
    };
    defer result.deinit(allocator);

    std.debug.print(
        "labelle: packed {d} sprite(s) into {d}x{d}\n  {s}\n  {s}\n",
        .{ result.sprite_count, result.sheet_w, result.sheet_h, result.png_path, result.json_path },
    );
}

/// Advance `i` to the next arg and return it, or null if there is none.
fn nextValue(cmd_args: []const []const u8, i: *usize) ?[]const u8 {
    if (i.* + 1 >= cmd_args.len) return null;
    i.* += 1;
    return cmd_args[i.*];
}

fn usageErr(msg: []const u8) error{InvalidArgs} {
    std.debug.print("labelle pack: {s}\n{s}", .{ msg, usage });
    return error.InvalidArgs;
}

fn usageErr2(msg: []const u8, arg: []const u8) error{InvalidArgs} {
    std.debug.print("labelle pack: {s}: {s}\n{s}", .{ msg, arg, usage });
    return error.InvalidArgs;
}
