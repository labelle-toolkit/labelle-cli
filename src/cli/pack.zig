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
    // The cwd, but ONLY when it is genuinely an ancestor of the input: for a
    // relative path that never climbs above it. An absolute input's
    // ancestors are already complete, and an input that escapes upward
    // (`../orphan/assets`) belongs to a different project — probing `.`
    // there would hand it this project's gfx pin, which is exactly the
    // wrong-project reading this lookup exists to avoid.
    if (!std.fs.path.isAbsolute(input_dir) and !escapesCwd(input_dir)) {
        try out.append(arena, ".");
    }
    return out.items;
}

/// Strip trailing slashes for path walking; keep filesystem roots intact
/// (`trimEnd` would turn `/` into "" and `C:/` into `C:`).
fn trimTrailingSlash(path: []const u8) []const u8 {
    if (path.len <= 1) return path;
    var end = path.len;
    while (end > 1) {
        const c = path[end - 1];
        if (c != '/' and !std.fs.path.isSep(c)) break;
        const without = path[0 .. end - 1];
        if (without.len == 0) return path[0..1];
        // Drive root: trimming "C:/" or "C:\" must not become "C:".
        if (without.len == 2 and without[1] == ':') return path[0..end];
        end -= 1;
    }
    return path[0..end];
}

/// Whether a relative path climbs above the working directory. Lexical on
/// purpose — `a/../b` stays inside, `../b` does not, and no filesystem
/// access is needed to tell them apart. Uses native path separators so
/// Windows parent-relative inputs like `..\shared\sprites` are recognized.
fn escapesCwd(rel: []const u8) bool {
    if (std.fs.path.isAbsolute(rel)) return false;
    var depth: i32 = 0;
    var it = std.fs.path.componentIterator(rel);
    while (it.next()) |comp| {
        const seg = comp.name;
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            depth -= 1;
            if (depth < 0) return true;
            continue;
        }
        depth += 1;
    }
    return false;
}

/// Prepare a path for ancestor walking: realpath the longest existing prefix
/// (following symlinks), then collapse `.` / `..` on the unresolved tail.
/// Lexical normalization alone is wrong for `link/../assets` when `link` is a
/// symlink — `..` must climb from the resolved target, not the lexical parent.
fn prepareLookupPath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const trimmed = trimTrailingSlash(path);
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const full_real = cwd.realPathFileAlloc(io, trimmed, arena) catch null;
    if (full_real) |real| return real[0 .. real.len];

    var comps: std.ArrayList([]const u8) = .empty;
    var prefixes: std.ArrayList([]const u8) = .empty;
    var it = std.fs.path.componentIterator(trimmed);
    while (it.next()) |comp| {
        if (comp.name.len == 0) continue;
        try comps.append(arena, comp.name);
        try prefixes.append(arena, comp.path);
    }
    if (comps.items.len == 0) return trimmed;

    var resolved: ?[]const u8 = null;
    var consumed: usize = 0;
    for (prefixes.items, 0..) |partial, i| {
        const partial_real = cwd.realPathFileAlloc(io, partial, arena) catch null;
        if (partial_real) |real| {
            resolved = real[0 .. real.len];
            consumed = i + 1;
        }
    }

    if (consumed >= comps.items.len) {
        return resolved orelse trimmed;
    }

    const tail = try std.fs.path.join(arena, comps.items[consumed..]);
    const base: []const u8 = resolved orelse ".";
    return std.fs.path.resolve(arena, &.{ base, tail });
}

/// The nearest directory at or above `input_dir` holding a `project.labelle`,
/// or null if there is none. `labelle pack` takes an arbitrary input path,
/// so the owning project is the one the SPRITES belong to — not whatever
/// happens to sit in the shell's cwd. Reading the wrong project's gfx pin
/// is worse than reading none: it can wave through a trimmed atlas that
/// the actual target's older renderer will position incorrectly.
fn findProjectRoot(arena: std.mem.Allocator, input_dir: []const u8) ?[]const u8 {
    const io = config.globalIo();
    const prepared = prepareLookupPath(arena, input_dir) catch return null;
    const candidates = candidateRoots(arena, prepared) catch return null;
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
fn trimWarningProjectRoot(arena: std.mem.Allocator, input_dir: []const u8, out_dir: []const u8) ?[]const u8 {
    const in_norm = trimTrailingSlash(input_dir);
    const out_norm = trimTrailingSlash(out_dir);

    if (findProjectRoot(arena, in_norm)) |root| return root;
    if (std.mem.eql(u8, in_norm, out_norm)) return null;

    // The atlas is *consumed* by the output directory's project. When the
    // sprites live outside any project but `--out-dir` points inside one,
    // the output's gfx pin is the one that determines whether trim offsets
    // will be applied.
    return findProjectRoot(arena, out_norm);
}

const TRIM_WARNING_FMT =
    \\labelle pack: WARNING — this project pins labelle-gfx {s}, which does NOT
    \\  apply trim offsets (needs {d}.{d}.{d}+). A trimmed atlas will render with every
    \\  frame centred on its own silhouette, shifting sprites frame to frame. Bump
    \\  the gfx pin, or pack without --trim.
    \\
;

fn warnIfRendererIgnoresTrimTo(
    gpa: std.mem.Allocator,
    input_dir: []const u8,
    out_dir: []const u8,
    writer: anytype,
) !bool {
    // Arena for the parsed config, matching `cmdAstc`: the ZON parse
    // allocates a string per field and this function only needs one of
    // them, so a single arena free beats tracking them individually.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const root = trimWarningProjectRoot(arena.allocator(), input_dir, out_dir) orelse return false;

    // `gfx_version` is never null — it defaults to the CLI's own paired
    // version when project.labelle omits the pin, which is the right proxy
    // for "what this project will build against".
    const cfg = config.readProjectConfigQuiet(arena.allocator(), root) catch return false;
    const pinned = cfg.gfx_version;
    if (!rendererIgnoresTrim(pinned)) return false;
    try writer.print(TRIM_WARNING_FMT, .{ pinned, TRIM_AWARE_GFX.major, TRIM_AWARE_GFX.minor, TRIM_AWARE_GFX.patch });
    return true;
}

fn warnIfRendererIgnoresTrim(gpa: std.mem.Allocator, input_dir: []const u8, out_dir: []const u8) void {
    const DebugWriter = struct {
        fn print(_: @This(), comptime fmt: []const u8, args: anytype) !void {
            std.debug.print(fmt, args);
        }
    };
    _ = warnIfRendererIgnoresTrimTo(gpa, input_dir, out_dir, DebugWriter{}) catch {};
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
    const in_trimmed = trimTrailingSlash(in);
    const name = name_opt orelse std.fs.path.basename(in_trimmed);
    const out_dir = out_dir_opt orelse (std.fs.path.dirname(in_trimmed) orelse ".");

    if (trim) warnIfRendererIgnoresTrim(allocator, in_trimmed, out_dir);

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

test "trimTrailingSlash: preserves the filesystem root" {
    try std.testing.expectEqualStrings("/", trimTrailingSlash("/"));
    try std.testing.expectEqualStrings("/games/fp", trimTrailingSlash("/games/fp/"));
    // Windows drive roots must not collapse to drive-relative "C:".
    try std.testing.expectEqualStrings("C:/", trimTrailingSlash("C:/"));
    try std.testing.expectEqualStrings("C:/games/fp", trimTrailingSlash("C:/games/fp/"));
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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try packTestBase(a, tmp);
    const nested = try std.fs.path.join(a, &.{ root, "assets/raw/ship" });
    try tmp.dir.createDirPath(io, "assets/raw/ship");
    try tmp.dir.writeFile(io, .{ .sub_path = "project.labelle", .data = ".{ .name = \"x\" }\n" });

    // From the project dir itself, and from several levels below it.
    const from_root = findProjectRoot(a, root) orelse return error.TestExpectedProjectRoot;
    try expectCanonicallyEqual(a, root, from_root);
    const from_nested = findProjectRoot(a, nested) orelse return error.TestExpectedProjectRoot;
    try expectCanonicallyEqual(a, root, from_nested);

    // A directory with no project.labelle above it yields null rather than
    // reading someone else's project.
    var orphan_tmp = std.testing.tmpDir(.{});
    defer orphan_tmp.cleanup();
    const orphan = try packTestBase(a, orphan_tmp);
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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try packTestBase(a, tmp);
    const nested = try std.fs.path.join(a, &.{ root, "assets/raw/ship" });
    try tmp.dir.createDirPath(io, "assets/raw/ship");
    try tmp.dir.writeFile(io, .{
        .sub_path = "project.labelle",
        .data = ".{ .name = \"x\", .backend = .bgfx, .gfx_version = \"1.30.0\" }\n",
    });

    const found = findProjectRoot(a, nested) orelse return error.TestExpectedProjectRoot;
    try expectCanonicallyEqual(a, root, found);
    const cfg = try config.readProjectConfigQuiet(a, found);
    try std.testing.expectEqualStrings("1.30.0", cfg.gfx_version);
    try std.testing.expect(rendererIgnoresTrim(cfg.gfx_version));
}

fn countSubstr(hay: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, hay, pos, needle)) |at| {
        count += 1;
        pos = at + needle.len;
    }
    return count;
}

const Capture = struct {
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    fn print(self: @This(), comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.gpa, fmt, args);
        defer self.gpa.free(s);
        try self.buf.appendSlice(self.gpa, s);
    }
};

/// Cwd-relative path to a `std.testing.tmpDir` fixture (see `config.zig` tests).
fn packTestBase(arena: std.mem.Allocator, tmp: std.testing.TmpDir) ![]const u8 {
    return std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
}

fn canonicalPath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    return cwd.realPathFileAlloc(io, path, arena) catch std.fs.path.resolve(arena, &.{path});
}

fn expectPathsEqual(arena: std.mem.Allocator, want: []const u8, got: []const u8) !void {
    const a = try std.fs.path.resolve(arena, &.{want});
    const b = try std.fs.path.resolve(arena, &.{got});
    try std.testing.expectEqualStrings(a, b);
}

fn expectCanonicallyEqual(arena: std.mem.Allocator, want: []const u8, got: []const u8) !void {
    try std.testing.expectEqualStrings(try canonicalPath(arena, want), try canonicalPath(arena, got));
}

test "trim guard: falls back to the --out-dir project when input has none" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try packTestBase(a, tmp);
    const orphan = try std.fs.path.join(a, &.{ base, "orphan-sprites" });
    const out_assets = try std.fs.path.join(a, &.{ base, "out-proj/assets" });

    try tmp.dir.createDirPath(io, "orphan-sprites");
    try tmp.dir.createDirPath(io, "out-proj/assets");
    try tmp.dir.writeFile(io, .{
        .sub_path = "out-proj/project.labelle",
        .data = ".{ .name = \"x\", .backend = .bgfx, .gfx_version = \"1.30.0\" }\n",
    });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const did_warn = try warnIfRendererIgnoresTrimTo(alloc, orphan, out_assets, Capture{ .buf = &buf, .gpa = alloc });
    try std.testing.expect(did_warn);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "WARNING") != null);
    try std.testing.expectEqual(@as(usize, 1), countSubstr(buf.items, "WARNING"));
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "labelle-gfx 1.30.0") != null);
}

test "trim guard: input-project precedence even when --out-dir is another project" {
    // Input pins a trim-aware gfx; output pins an old one. This must not
    // warn: the sprites "belong to" the input project when one exists.
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try packTestBase(a, tmp);
    const in_sprites = try std.fs.path.join(a, &.{ base, "in-proj/assets/raw/ship" });
    const out_assets = try std.fs.path.join(a, &.{ base, "out-proj/assets" });

    try tmp.dir.createDirPath(io, "in-proj/assets/raw/ship");
    try tmp.dir.createDirPath(io, "out-proj/assets");
    try tmp.dir.writeFile(io, .{
        .sub_path = "in-proj/project.labelle",
        .data = ".{ .name = \"in\", .backend = .bgfx, .gfx_version = \"1.31.0\" }\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "out-proj/project.labelle",
        .data = ".{ .name = \"out\", .backend = .bgfx, .gfx_version = \"1.30.0\" }\n",
    });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const did_warn = try warnIfRendererIgnoresTrimTo(alloc, in_sprites, out_assets, Capture{ .buf = &buf, .gpa = alloc });
    try std.testing.expect(!did_warn);
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "trim guard: no duplicate warning when input and output share a project" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try packTestBase(a, tmp);
    const in_abs = try std.fs.path.join(a, &.{ base, "proj/sprites" });
    const out_abs = try std.fs.path.join(a, &.{ base, "proj/assets" });

    try tmp.dir.createDirPath(io, "proj/sprites");
    try tmp.dir.createDirPath(io, "proj/assets");
    try tmp.dir.writeFile(io, .{
        .sub_path = "proj/project.labelle",
        .data = ".{ .name = \"x\", .backend = .bgfx, .gfx_version = \"1.30.0\" }\n",
    });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const did_warn = try warnIfRendererIgnoresTrimTo(alloc, in_abs, out_abs, Capture{ .buf = &buf, .gpa = alloc });
    try std.testing.expect(did_warn);
    try std.testing.expectEqual(@as(usize, 1), countSubstr(buf.items, "WARNING"));
}

test "trim guard: input-project precedence warns even if --out-dir is trim-aware" {
    // Input pins an old gfx; output pins a trim-aware one. Still warn: the
    // input project owns the sprites when it exists.
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try packTestBase(a, tmp);
    const in_sprites = try std.fs.path.join(a, &.{ base, "in-proj/assets/raw/ship" });
    const out_assets = try std.fs.path.join(a, &.{ base, "out-proj/assets" });

    try tmp.dir.createDirPath(io, "in-proj/assets/raw/ship");
    try tmp.dir.createDirPath(io, "out-proj/assets");
    try tmp.dir.writeFile(io, .{
        .sub_path = "in-proj/project.labelle",
        .data = ".{ .name = \"in\", .backend = .bgfx, .gfx_version = \"1.30.0\" }\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "out-proj/project.labelle",
        .data = ".{ .name = \"out\", .backend = .bgfx, .gfx_version = \"1.31.0\" }\n",
    });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const did_warn = try warnIfRendererIgnoresTrimTo(alloc, in_sprites, out_assets, Capture{ .buf = &buf, .gpa = alloc });
    try std.testing.expect(did_warn);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "labelle-gfx 1.30.0") != null);
    try std.testing.expectEqual(@as(usize, 1), countSubstr(buf.items, "WARNING"));
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

test "candidateRoots: an input that climbs above the CWD does not use it" {
    // `labelle pack ../orphan/assets --trim` must not read THIS project's
    // gfx pin: those sprites belong to a different project, and answering
    // from the wrong one is the failure this lookup exists to prevent.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try candidateRoots(a, "../orphan/assets");
    for (got) |g| try std.testing.expect(!std.mem.eql(u8, g, "."));

    // A path that dips and comes back stays inside, so the cwd is still a
    // legitimate ancestor.
    const inside = try candidateRoots(a, "assets/../assets/raw");
    try std.testing.expectEqualStrings(".", inside[inside.len - 1]);
}

test "escapesCwd: only a net-upward path escapes" {
    try std.testing.expect(escapesCwd(".."));
    try std.testing.expect(escapesCwd("../orphan/assets"));
    try std.testing.expect(escapesCwd("a/../../b"));
    try std.testing.expect(!escapesCwd("assets/raw"));
    try std.testing.expect(!escapesCwd("./assets"));
    try std.testing.expect(!escapesCwd("a/../b"));
}

test "escapesCwd: windows-style parent-relative paths" {
    if (@import("builtin").os.tag != .windows) return;
    try std.testing.expect(escapesCwd("..\\shared\\sprites"));
    try std.testing.expect(!escapesCwd("assets\\raw"));
    try std.testing.expect(!escapesCwd("a\\..\\b"));
}

test "prepareLookupPath: collapses dot segments that escape cwd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const got = try prepareLookupPath(a, "tmp/../../atlas");
    try expectPathsEqual(a, "../atlas", got);
    const inside = try prepareLookupPath(a, "assets/../assets/raw");
    try expectPathsEqual(a, "assets/raw", inside);
}

test "findProjectRoot: filesystem root does not fall back to cwd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // trimTrailingSlash must keep "/" so lookup probes the root, not cwd.
    try std.testing.expect(findProjectRoot(arena.allocator(), "/") == null);
}

test "candidateRoots: dot-segment escape does not probe cwd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const normalized = try prepareLookupPath(a, "tmp/../../atlas");
    const got = try candidateRoots(a, normalized);
    for (got) |g| try std.testing.expect(!std.mem.eql(u8, g, "."));
}

test "trim guard: dot-segment out-dir escape does not use cwd project" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try packTestBase(a, tmp);
    const orphan = try std.fs.path.join(a, &.{ base, "orphan-sprites" });
    // Lexical dirname chain dips through proj-a/tmp/..; normalized it reaches proj-b.
    const out_escaping = try std.fs.path.join(a, &.{ base, "proj-a/tmp/../../proj-b/outside-atlas" });

    try tmp.dir.createDirPath(io, "orphan-sprites");
    try tmp.dir.createDirPath(io, "proj-a/tmp");
    try tmp.dir.createDirPath(io, "proj-b/outside-atlas");
    try tmp.dir.writeFile(io, .{
        .sub_path = "proj-a/project.labelle",
        .data = ".{ .name = \"a\", .backend = .bgfx, .gfx_version = \"1.31.0\" }\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "proj-b/project.labelle",
        .data = ".{ .name = \"b\", .backend = .bgfx, .gfx_version = \"1.30.0\" }\n",
    });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const did_warn = try warnIfRendererIgnoresTrimTo(alloc, orphan, out_escaping, Capture{ .buf = &buf, .gpa = alloc });
    try std.testing.expect(did_warn);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "labelle-gfx 1.30.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "labelle-gfx 1.31.0") == null);
}

test "trim guard: symlinked out-dir resolves to the target project" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try packTestBase(a, tmp);
    const orphan = try std.fs.path.join(a, &.{ base, "orphan-sprites" });
    const out_via_symlink = try std.fs.path.join(a, &.{ base, "proj-a/assets/atlases" });

    try tmp.dir.createDirPath(io, "orphan-sprites");
    try tmp.dir.createDirPath(io, "proj-a");
    try tmp.dir.createDirPath(io, "proj-b/assets");
    try tmp.dir.writeFile(io, .{
        .sub_path = "proj-a/project.labelle",
        .data = ".{ .name = \"a\", .backend = .bgfx, .gfx_version = \"1.31.0\" }\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "proj-b/project.labelle",
        .data = ".{ .name = \"b\", .backend = .bgfx, .gfx_version = \"1.30.0\" }\n",
    });
    try tmp.dir.symLink(io, "../proj-b/assets", "proj-a/assets", .{ .is_directory = true });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const did_warn = try warnIfRendererIgnoresTrimTo(alloc, orphan, out_via_symlink, Capture{ .buf = &buf, .gpa = alloc });
    try std.testing.expect(did_warn);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "labelle-gfx 1.30.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "labelle-gfx 1.31.0") == null);
}

test "findProjectRoot: symlinked path with nonexistent leaf" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try packTestBase(a, tmp);
    const out_leaf = try std.fs.path.join(a, &.{ base, "proj-a/assets/new-atlas" });

    try tmp.dir.createDirPath(io, "proj-a");
    try tmp.dir.createDirPath(io, "proj-b/assets");
    try tmp.dir.writeFile(io, .{
        .sub_path = "proj-a/project.labelle",
        .data = ".{ .name = \"a\", .backend = .bgfx, .gfx_version = \"1.31.0\" }\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "proj-b/project.labelle",
        .data = ".{ .name = \"b\", .backend = .bgfx, .gfx_version = \"1.30.0\" }\n",
    });
    try tmp.dir.symLink(io, "../proj-b/assets", "proj-a/assets", .{ .is_directory = true });

    const want = try std.fs.path.join(a, &.{ base, "proj-b" });
    const found = findProjectRoot(a, out_leaf) orelse return error.TestExpectedProjectRoot;
    try expectCanonicallyEqual(a, want, found);
}

test "findProjectRoot: symlink parent segment resolves before dot collapse" {
    // `link -> ../proj-b/assets` then `link/../assets/leaf` must land in
    // proj-b, not lexical proj-a/assets (which would pick proj-a's gfx pin).
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try packTestBase(a, tmp);
    const via_parent = try std.fs.path.join(a, &.{ base, "proj-a/link/../assets/leaf" });

    try tmp.dir.createDirPath(io, "proj-a");
    try tmp.dir.createDirPath(io, "proj-b/assets");
    try tmp.dir.writeFile(io, .{
        .sub_path = "proj-a/project.labelle",
        .data = ".{ .name = \"a\", .backend = .bgfx, .gfx_version = \"1.31.0\" }\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "proj-b/project.labelle",
        .data = ".{ .name = \"b\", .backend = .bgfx, .gfx_version = \"1.30.0\" }\n",
    });
    try tmp.dir.symLink(io, "../proj-b/assets", "proj-a/link", .{ .is_directory = true });

    const want = try std.fs.path.join(a, &.{ base, "proj-b" });
    const found = findProjectRoot(a, via_parent) orelse return error.TestExpectedProjectRoot;
    try expectCanonicallyEqual(a, want, found);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const orphan = try std.fs.path.join(a, &.{ base, "orphan-sprites" });
    try tmp.dir.createDirPath(io, "orphan-sprites");
    const did_warn = try warnIfRendererIgnoresTrimTo(alloc, orphan, via_parent, Capture{ .buf = &buf, .gpa = alloc });
    try std.testing.expect(did_warn);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "labelle-gfx 1.30.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "labelle-gfx 1.31.0") == null);
}

test "findProjectRoot: symlink parent segment with native windows separators" {
    if (@import("builtin").os.tag != .windows) return;

    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try packTestBase(a, tmp);
    const via_parent = try std.fs.path.join(a, &.{ base, "proj-a\\link\\..\\assets\\leaf" });

    try tmp.dir.createDirPath(io, "proj-a");
    try tmp.dir.createDirPath(io, "proj-b/assets");
    try tmp.dir.writeFile(io, .{
        .sub_path = "proj-a/project.labelle",
        .data = ".{ .name = \"a\", .backend = .bgfx, .gfx_version = \"1.31.0\" }\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "proj-b/project.labelle",
        .data = ".{ .name = \"b\", .backend = .bgfx, .gfx_version = \"1.30.0\" }\n",
    });
    try tmp.dir.symLink(io, "../proj-b/assets", "proj-a/link", .{ .is_directory = true });

    const want = try std.fs.path.join(a, &.{ base, "proj-b" });
    const found = findProjectRoot(a, via_parent) orelse return error.TestExpectedProjectRoot;
    try expectCanonicallyEqual(a, want, found);
}
