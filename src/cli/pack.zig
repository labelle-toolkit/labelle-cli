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
const project_config = @import("project_config.zig");

/// First labelle-gfx release whose renderer APPLIES trim offsets
/// (`SourceRect.pivotOrigin`). Below it, a trimmed atlas draws every frame
/// centred on its own silhouette instead of on the canvas the artist
/// authored — a silent per-frame position error, with nothing logged and
/// nothing failing.
///
/// The fix ships as a PATCH on the 1.30 line, so this has to be compared
/// down to the patch: 1.30.0 ignores trim offsets and 1.30.1 applies them,
/// and a gate that stopped at the minor could not tell them apart. Keep in
/// step with the actual release.
const TRIM_AWARE_GFX: compatibility.Version = .{ .major = 1, .minor = 30, .patch = 1 };

/// True when `pinned` is a gfx release that predates trim-offset support.
///
/// A `local:` pin has no semver train to compare — it parses as 0.0, which
/// would read as "ancient" and warn on every pack. A local checkout is the
/// one case where the developer knows what they are building against, so
/// say nothing rather than cry wolf.
fn rendererIgnoresTrim(pinned: []const u8) bool {
    if (project_config.isLocalVersion(pinned)) return false;
    return compatibility.parseVersion(pinned).olderThan(TRIM_AWARE_GFX);
}

/// Every directory to check for a `project.labelle`, nearest first: the
/// input, then each ancestor.
///
/// Split from the probing so the walk is testable without a filesystem or a
/// working-directory change. It needs to be: the subtle half is the tail.
/// A RELATIVE input bottoms out BEFORE the working directory itself —
/// `dirname("assets")` is null — so `assets/raw/ship` never reaches `.`
/// unless it is appended explicitly. That is the commonest invocation of
/// all (`labelle pack assets/raw/x` from the project root), and omitting it
/// made the lookup return null everywhere, silently disabling the --trim
/// warning. A silent guard is worse than no guard: it reads as "checked".
fn candidateRoots(arena: std.mem.Allocator, input_dir: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var dir: []const u8 = input_dir;
    while (true) {
        try out.append(arena, dir);
        const parent = std.fs.path.dirname(dir) orelse break;
        if (parent.len == 0 or parent.len == dir.len) break;
        dir = parent;
    }
    // The cwd, for relative inputs only — an absolute input's ancestors are
    // already complete, and `.` would be an unrelated directory.
    if (!std.fs.path.isAbsolute(input_dir)) try out.append(arena, ".");
    return out.items;
}

/// The nearest directory at or above `input_dir` holding a `project.labelle`,
/// or null if there is none. `labelle pack` takes an arbitrary input path,
/// so the owning project is the one the SPRITES belong to — not whatever
/// happens to sit in the shell's cwd. Reading the wrong project's gfx pin
/// is worse than reading none: it can wave through a trimmed atlas that
/// the actual target's older renderer will position incorrectly.
fn findProjectRoot(arena: std.mem.Allocator, input_dir: []const u8) ?[]const u8 {
    const io = config.globalIo();
    const candidates = candidateRoots(arena, input_dir) catch return null;
    for (candidates) |dir| {
        const probe = std.fs.path.join(arena, &.{ dir, "project.labelle" }) catch return null;
        if (std.Io.Dir.cwd().statFile(io, probe, .{})) |_| return dir else |_| {}
    }
    return null;
}

/// Warn when `--trim` is used in a project pinned to a gfx that ignores trim
/// offsets. Best-effort: `labelle pack` is usable outside a project, so no
/// discoverable `project.labelle` (or an unreadable one) skips the check
/// rather than failing the pack.
fn warnIfRendererIgnoresTrim(gpa: std.mem.Allocator, input_dir: []const u8) void {
    // Arena for the parsed config, matching `cmdAstc`: the ZON parse
    // allocates a string per field and this function only needs one of
    // them, so a single arena free beats tracking them individually.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const root = findProjectRoot(arena.allocator(), input_dir) orelse return;

    // `gfx_version` is never null — it defaults to the CLI's own paired
    // version when project.labelle omits the pin, which is the right proxy
    // for "what this project will build against".
    const cfg = config.readProjectConfigQuiet(arena.allocator(), root) catch return;
    const pinned = cfg.gfx_version;
    if (!rendererIgnoresTrim(pinned)) return;
    std.debug.print(
        \\labelle pack: WARNING — this project pins labelle-gfx {s}, which does NOT
        \\  apply trim offsets (needs {d}.{d}.{d}+). A trimmed atlas will render with every
        \\  frame centred on its own silhouette, shifting sprites frame to frame. Bump
        \\  the gfx pin, or pack without --trim.
        \\
    , .{ pinned, TRIM_AWARE_GFX.major, TRIM_AWARE_GFX.minor, TRIM_AWARE_GFX.patch });
}

const usage =
    \\usage: labelle pack <input-dir> [options]
    \\  -o, --name <name>    atlas base name (default: input folder name)
    \\      --out-dir <dir>  where to write the atlas (default: alongside input)
    \\      --padding <n>    gap between sprites in px (default: 2)
    \\      --max-size <n>   max sheet dimension in px (default: 4096)
    \\      --trim           crop transparent margins (needs a renderer that
    \\                       applies trim offsets — labelle-gfx 1.30.1+)
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

    if (trim) warnIfRendererIgnoresTrim(allocator, in);

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

test "rendererIgnoresTrim: releases before the fix are flagged" {
    // The whole point of the warning: on these, `--trim` produces an atlas
    // that renders subtly wrong with no error anywhere.
    try std.testing.expect(rendererIgnoresTrim("1.30.0"));
    try std.testing.expect(rendererIgnoresTrim("1.28.5"));
    try std.testing.expect(rendererIgnoresTrim("0.9.0"));
}

test "rendererIgnoresTrim: the fix is a PATCH, so the patch must be compared" {
    // 1.30.0 and 1.30.1 differ only in the patch. A major/minor-only gate
    // read them as identical and waved 1.30.0 through — silently producing
    // the exact defect --trim is guarded against.
    try std.testing.expect(rendererIgnoresTrim("1.30.0"));
    try std.testing.expect(!rendererIgnoresTrim("1.30.1"));
    try std.testing.expect(!rendererIgnoresTrim("1.30.2"));
}

test "rendererIgnoresTrim: a local gfx checkout is never flagged" {
    // `local:` has no semver train; parsing it yields 0.0, which would warn
    // on every pack against a local gfx that may well carry the fix.
    try std.testing.expect(!rendererIgnoresTrim("local:../labelle-gfx"));
}

test "rendererIgnoresTrim: later releases are fine" {
    try std.testing.expect(!rendererIgnoresTrim("1.31.0"));
    try std.testing.expect(!rendererIgnoresTrim("1.32.1"));
    // A future major carries the fix forward.
    try std.testing.expect(!rendererIgnoresTrim("2.0.0"));
}

test "findProjectRoot: walks up from the input dir to the owning project" {
    // Regression guard: this returned null for every input at one point,
    // which silently disabled the --trim warning everywhere. A guard that
    // never fires is worse than no guard, because it reads as "checked".
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const root = ".zig-cache/findroot-probe";
    const nested = root ++ "/assets/raw/ship";
    cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, nested);
    defer cwd.deleteTree(io, root) catch {};
    try cwd.writeFile(io, .{ .sub_path = root ++ "/project.labelle", .data = ".{ .name = \"x\" }\n" });

    // From the project dir itself, and from several levels below it.
    const from_root = findProjectRoot(a, root) orelse return error.TestExpectedProjectRoot;
    try std.testing.expect(std.mem.endsWith(u8, from_root, "findroot-probe"));
    const from_nested = findProjectRoot(a, nested) orelse return error.TestExpectedProjectRoot;
    try std.testing.expect(std.mem.endsWith(u8, from_nested, "findroot-probe"));

    // A directory with no project.labelle above it yields null rather than
    // reading someone else's project.
    const orphan = ".zig-cache/findroot-orphan";
    cwd.deleteTree(io, orphan) catch {};
    try cwd.createDirPath(io, orphan);
    defer cwd.deleteTree(io, orphan) catch {};
    try std.testing.expect(findProjectRoot(a, orphan) == null);
}

test "the trim guard reads the gfx pin from the discovered project" {
    // Pins the whole chain: discover the root from a nested input, parse the
    // config there, and read `gfx_version` out of it. Each link worked in
    // isolation while the guard as a whole silently did nothing.
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const root = ".zig-cache/trimguard-probe";
    const nested = root ++ "/assets/raw/ship";
    cwd.deleteTree(io, root) catch {};
    try cwd.createDirPath(io, nested);
    defer cwd.deleteTree(io, root) catch {};
    try cwd.writeFile(io, .{
        .sub_path = root ++ "/project.labelle",
        .data = ".{ .name = \"x\", .backend = .bgfx, .gfx_version = \"1.30.0\" }\n",
    });

    const found = findProjectRoot(a, nested) orelse return error.TestExpectedProjectRoot;
    const cfg = try config.readProjectConfigQuiet(a, found);
    try std.testing.expectEqualStrings("1.30.0", cfg.gfx_version);
    try std.testing.expect(rendererIgnoresTrim(cfg.gfx_version));
}

test "candidateRoots: a relative input ends at the CWD" {
    // The regression that silently disabled the --trim warning: walking up
    // from `assets/raw/ship` stops at `assets`, so `.` must be appended or
    // a project sitting in the working directory is never found — which is
    // where it sits for the commonest invocation of all.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try candidateRoots(a, "assets/raw/ship");
    const want = [_][]const u8{ "assets/raw/ship", "assets/raw", "assets", "." };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);

    // A single-segment relative input is the tightest case: its only
    // ancestor IS the cwd.
    const one = try candidateRoots(a, "assets");
    try std.testing.expectEqual(@as(usize, 2), one.len);
    try std.testing.expectEqualStrings("assets", one[0]);
    try std.testing.expectEqualStrings(".", one[1]);
}

test "candidateRoots: an absolute input walks to the root and stops" {
    // No `.` for absolute inputs — the ancestor chain is already complete,
    // and the working directory would be an unrelated project.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try candidateRoots(a, "/games/fp/assets/raw");
    try std.testing.expectEqualStrings("/games/fp/assets/raw", got[0]);
    try std.testing.expectEqualStrings("/games/fp/assets", got[1]);
    try std.testing.expectEqualStrings("/games/fp", got[2]);
    try std.testing.expectEqualStrings("/games", got[3]);
    for (got) |g| try std.testing.expect(!std.mem.eql(u8, g, "."));
}
