//! `labelle pack` — pack a folder of PNGs into a sprite atlas.
//!
//! Usage: labelle pack <input-dir> [-o <name>] [--out-dir <dir>]
//!                      [--padding <n>] [--max-size <n>] [--trim]
//!
//! Writes `<name>.atlas.png` + `<name>.atlas.json` (labelle-cli#213).
//! Replaces the external `npx free-tex-packer-cli` step.

const std = @import("std");
const texpack = @import("../texpack/texpack.zig");
const config = @import("config.zig");
const compatibility = @import("compatibility.zig");

/// First labelle-gfx minor train whose renderer APPLIES trim offsets
/// (`SourceRect.pivotOrigin`). Below it, a trimmed atlas draws every frame
/// centred on its own silhouette instead of on the canvas the artist
/// authored — a silent per-frame position error, with nothing logged and
/// nothing failing. Must match the release that actually ships the fix.
const TRIM_AWARE_GFX_MAJOR: u32 = 1;
const TRIM_AWARE_GFX_MINOR: u32 = 31;

/// True when `pinned` is a gfx release that predates trim-offset support.
fn rendererIgnoresTrim(pinned: []const u8) bool {
    const v = compatibility.parseVersion(pinned);
    return v.major < TRIM_AWARE_GFX_MAJOR or
        (v.major == TRIM_AWARE_GFX_MAJOR and v.minor < TRIM_AWARE_GFX_MINOR);
}

/// Warn when `--trim` is used in a project pinned to a gfx that ignores trim
/// offsets. Best-effort: `labelle pack` is usable outside a project, so an
/// unreadable `project.labelle` (or an unpinned gfx) skips the check rather
/// than failing the pack.
fn warnIfRendererIgnoresTrim(gpa: std.mem.Allocator) void {
    // Arena for the parsed config, matching `cmdAstc`: the ZON parse
    // allocates a string per field and this function only needs one of
    // them, so a single arena free beats tracking them individually.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // `gfx_version` is never null — it defaults to the CLI's own paired
    // version when project.labelle omits the pin, which is the right proxy
    // for "what this project will build against".
    const cfg = config.readProjectConfigQuiet(arena.allocator(), ".") catch return;
    const pinned = cfg.gfx_version;
    if (!rendererIgnoresTrim(pinned)) return;
    std.debug.print(
        \\labelle pack: WARNING — this project pins labelle-gfx {s}, which does NOT
        \\  apply trim offsets (needs {d}.{d}+). A trimmed atlas will render with every
        \\  frame centred on its own silhouette, shifting sprites frame to frame. Bump
        \\  the gfx pin, or pack without --trim.
        \\
    , .{ pinned, TRIM_AWARE_GFX_MAJOR, TRIM_AWARE_GFX_MINOR });
}

const usage =
    \\usage: labelle pack <input-dir> [options]
    \\  -o, --name <name>    atlas base name (default: input folder name)
    \\      --out-dir <dir>  where to write the atlas (default: alongside input)
    \\      --padding <n>    gap between sprites in px (default: 2)
    \\      --max-size <n>   max sheet dimension in px (default: 4096)
    \\      --trim           crop transparent margins (needs a renderer that
    \\                       applies trim offsets — labelle-gfx 1.31+)
    \\
;

pub fn cmdPack(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    var input_dir: ?[]const u8 = null;
    var name_opt: ?[]const u8 = null;
    var out_dir_opt: ?[]const u8 = null;
    var padding: i32 = 2;
    var max_size: i32 = 4096;
    var trim = false;

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
        } else if (std.mem.eql(u8, arg, "--trim")) {
            trim = true;
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

    if (trim) warnIfRendererIgnoresTrim(allocator);

    const result = texpack.packDir(allocator, config.globalIo(), in, out_dir, name, .{
        .padding = padding,
        .max_size = max_size,
        .trim = trim,
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

test "rendererIgnoresTrim: gfx trains before the fix are flagged" {
    // The whole point of the warning: on these, `--trim` produces an atlas
    // that renders subtly wrong with no error anywhere.
    try std.testing.expect(rendererIgnoresTrim("1.30.0"));
    try std.testing.expect(rendererIgnoresTrim("1.28.5"));
    try std.testing.expect(rendererIgnoresTrim("0.9.0"));
}

test "rendererIgnoresTrim: the fix train and later are fine" {
    try std.testing.expect(!rendererIgnoresTrim("1.31.0"));
    try std.testing.expect(!rendererIgnoresTrim("1.32.1"));
    // A future major carries the fix forward.
    try std.testing.expect(!rendererIgnoresTrim("2.0.0"));
}
