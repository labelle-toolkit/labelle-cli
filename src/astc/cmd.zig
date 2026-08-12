//! `labelle astc [dir] [--block 8x8] [--quality fast]` — build-time ASTC
//! conversion (assembler#340 / epic labelle-gfx#269).
//!
//! Reads `project.labelle`, and for every **atlas** resource runs astcenc over
//! its `.texture` PNG to produce a co-located `<name>.astc` (cached by mtime).
//! Resource-level + packer-agnostic: it doesn't care whether the atlas came
//! from free-tex-packer (FP) or `labelle pack`.

const std = @import("std");
const config = @import("../cli/config.zig");
const project_config = @import("../cli/project_config.zig");
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
    \\An individual atlas can pin its own block in project.labelle
    \\(`.astc_block = .@"4x4"` on the resource); an explicit --block here
    \\overrides every such pin.
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
    return std.meta.stringToEnum(convert.Quality, s);
}

/// Whether the existing `.astc` at `out` was encoded at `block` (bytes 4/5 of
/// the ASTC header). Returns false if it's missing/short/unreadable so the
/// caller re-encodes. (Quality isn't recoverable from the header — a `--quality`
/// change still needs a clean rebuild; block is the format-determining param.)
/// Reads only the 16-byte header — not the whole blob (CodeRabbit on #316: the
/// old readFileAlloc buffered up to 64 MiB per cached atlas into the command
/// arena, accumulating until exit).
fn existingBlockMatches(out: []const u8, block: convert.BlockSize) bool {
    const io = config.globalIo();
    const f = std.Io.Dir.cwd().openFile(io, out, .{}) catch return false;
    defer f.close(io);
    var header: [16]u8 = undefined;
    const n = f.readPositionalAll(io, &header, 0) catch return false;
    if (n < 16) return false;
    const d = block.dims();
    return header[4] == d.x and header[5] == d.y;
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
    // Whether the user pinned `--block` explicitly. When they didn't, we pick a
    // backend-safe default below (sokol can only load 4×4); when they did, we
    // validate it against the backend instead of silently emitting an
    // unloadable file.
    var block_explicit = false;

    var i: usize = 0;
    while (i < cmd_args.len) : (i += 1) {
        const arg = cmd_args[i];
        if (std.mem.eql(u8, arg, "--block")) {
            i += 1;
            if (i >= cmd_args.len) return usageErr("--block needs a value (e.g. 8x8)");
            opts.block = convert.BlockSize.parse(cmd_args[i]) orelse return usageErr("unsupported --block size");
            block_explicit = true;
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

    // The target backend constrains which block sizes are loadable at runtime.
    // sokol ships ASTC 4×4 only — an 8×8 atlas parses but fails to upload
    // (error.LoadFailed), which on FP left the game stuck on the loading scene.
    // Default to a backend-safe block when the user didn't pin one; reject an
    // explicit block the backend can't load rather than baking a dud.
    const caps: convert.BackendCaps = switch (cfg.backend) {
        .sokol => .sokol_4x4_only,
        .raylib => .raylib_4x4_8x8,
        .bgfx, .wgpu => .full,
        // sdl/null aren't ASTC upload targets; the gfx seam falls back to PNG
        // decode if they ever see a compressed blob, so leave block unconstrained.
        .sdl, .null => .full,
    };
    if (block_explicit) {
        if (!caps.supports(opts.block)) {
            std.debug.print(
                "labelle astc: backend '{s}' cannot upload ASTC {s} (try {s})\n",
                .{ @tagName(cfg.backend), opts.block.arg(), caps.defaultBlock().arg() },
            );
            return error.InvalidArgs;
        }
    } else {
        opts.block = caps.defaultBlock();
    }

    // Resolve the astcenc binary (download + cache on first use).
    const cache_root = try asm_cache.getCacheRoot(allocator);
    defer allocator.free(cache_root);
    const astcenc = try astcenc_bin.ensure(allocator, cache_root, astcenc_bin.DEFAULT_VERSION);
    defer allocator.free(astcenc);

    var tally = Tally{};

    for (cfg.resources) |res| {
        if (res.kind() != .atlas) continue;
        convertAtlas(allocator, astcenc, dir, res.texture, resourceOpts(res, opts, block_explicit, caps), &tally);
    }

    // Pack/plugin-shipped atlases (labelle-cli#315, asset-plugins P1/P2): packs
    // and local plugins can declare their own `.resources` (pack.labelle /
    // plugin.labelle) — convert those atlases too, or a compressed target
    // silently ships them as embedded PNG while the game's own atlases ride
    // ASTC (the invariant is: a resource behaves identically whether declared
    // by the game or by a pack). In-tree/local dirs only: a REMOTE plugin's
    // sources aren't materialized when this step runs (pre-generate), so its
    // atlases still ride the PNG fallback — a documented limitation.
    for (cfg.plugins) |dep| {
        if (!dep.isLocal()) continue;
        // `resolve` (not `join`): an absolute `local:/…` path must be
        // preserved, not appended under the project dir — matches the plugin
        // resolution in cli/plugins.zig (codex review on #316).
        const pack_dir = try std.fs.path.resolve(allocator, &.{ dir, dep.localPath() });
        defer allocator.free(pack_dir);
        for ([_][]const u8{ "pack.labelle", "plugin.labelle" }) |manifest| {
            const resources = readDeclaredResources(allocator, pack_dir, manifest) orelse continue;
            for (resources) |res| {
                if (res.kind() != .atlas) continue;
                convertAtlas(allocator, astcenc, pack_dir, res.texture, resourceOpts(res, opts, block_explicit, caps), &tally);
            }
        }
    }

    std.debug.print("labelle astc: {d} converted, {d} up-to-date, {d} failed\n", .{ tally.converted, tally.cached, tally.failed });
    if (tally.failed > 0) return error.AstcConversionFailed;
}

const Tally = struct {
    converted: usize = 0,
    cached: usize = 0,
    failed: usize = 0,
};

/// Per-resource conversion options: the command-wide `base` with this
/// atlas's own `astc_block` applied.
///
/// Precedence is explicit-flag → per-atlas → backend default. An explicit
/// `--block` is a manual override of the whole run (you asked for this
/// block, you get it everywhere), so it beats the manifest; without it,
/// an atlas that pinned a block gets it. A pinned block the backend
/// cannot upload is DROPPED with a warning rather than failing the build:
/// unlike the flag case there is no interactive user to correct, and a
/// silently unloadable atlas leaves the game stuck on the loading scene.
fn resourceOpts(
    res: project_config.ResourceDef,
    base: convert.Options,
    block_explicit: bool,
    caps: convert.BackendCaps,
) convert.Options {
    if (block_explicit) return base;
    const pinned = res.astc_block orelse return base;
    if (!caps.supports(pinned)) {
        std.debug.print(
            "labelle astc: atlas '{s}' pins ASTC {s}, which this backend cannot upload — using {s}\n",
            .{ res.name, pinned.arg(), base.block.arg() },
        );
        return base;
    }
    var opts = base;
    opts.block = pinned;
    return opts;
}

/// Convert one atlas texture (path relative to `base_dir`) to its co-located
/// `.astc` sibling, honouring the mtime + block-size cache. Shared by the
/// game-resource and pack/plugin-resource loops.
fn convertAtlas(
    allocator: std.mem.Allocator,
    astcenc: []const u8,
    base_dir: []const u8,
    texture: []const u8,
    opts: convert.Options,
    tally: *Tally,
) void {
    const src = std.fs.path.join(allocator, &.{ base_dir, texture }) catch {
        tally.failed += 1;
        return;
    };
    defer allocator.free(src);
    const out = convert.outputPath(allocator, src) catch {
        tally.failed += 1;
        return;
    };
    defer allocator.free(out);

    // Up-to-date only if the output is newer than the source AND was
    // encoded at the requested block size — otherwise a `--block` change
    // would silently keep the stale format (the mtime alone can't see it).
    if (!convert.needsReencode(Stat, src, out) and existingBlockMatches(out, opts.block)) {
        tally.cached += 1;
        return;
    }

    const args = convert.buildArgs(allocator, astcenc, src, out, opts) catch {
        tally.failed += 1;
        return;
    };
    defer allocator.free(args);
    const r = util.runCmd(allocator, args) catch {
        std.debug.print("labelle astc: failed to run astcenc on {s}\n", .{src});
        tally.failed += 1;
        return;
    };
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    const ok = switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (ok) {
        std.debug.print("  {s} -> {s} ({s})\n", .{ src, out, opts.block.arg() });
        tally.converted += 1;
    } else {
        std.debug.print("labelle astc: astcenc failed on {s}\n{s}\n", .{ src, r.stderr });
        tally.failed += 1;
    }
}

/// The `.resources` a pack/plugin manifest declares (asset-plugins P1/P2), or
/// null when the manifest doesn't exist, doesn't parse, or declares none.
/// Mirrors `readProjectConfigImpl`'s lenient posture (`ignore_unknown_fields`:
/// the assembler owns these schemas; the CLI reads just the one field it needs).
fn readDeclaredResources(
    allocator: std.mem.Allocator,
    pack_dir: []const u8,
    manifest: []const u8,
) ?[]const project_config.ResourceDef {
    const ManifestResources = struct {
        resources: []const project_config.ResourceDef = &.{},
    };
    const path = std.fs.path.join(allocator, &.{ pack_dir, manifest }) catch return null;
    defer allocator.free(path);
    const raw = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, allocator, .limited(1024 * 1024)) catch return null;
    defer allocator.free(raw);
    const source = allocator.dupeZ(u8, raw) catch return null;
    const parsed = std.zon.parse.fromSliceAlloc(ManifestResources, allocator, source, null, .{
        .ignore_unknown_fields = true,
    }) catch {
        std.debug.print("labelle astc: could not parse {s} — skipping its resources\n", .{path});
        return null;
    };
    if (parsed.resources.len == 0) return null;
    return parsed.resources;
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

/// An atlas resource pinning `block`, for the precedence tests.
fn atlasPinning(block: ?convert.BlockSize) project_config.ResourceDef {
    return .{
        .name = "characters",
        .json = "assets/characters.json",
        .texture = "assets/characters.png",
        .astc_block = block,
    };
}

test "resourceOpts: an atlas without a pin keeps the run-wide block" {
    const base = convert.Options{ .block = .@"8x8" };
    const opts = resourceOpts(atlasPinning(null), base, false, .full);
    try std.testing.expectEqual(convert.BlockSize.@"8x8", opts.block);
}

test "resourceOpts: a pinned block wins over the backend default" {
    // The whole point of the knob: characters at 4x4 while the rest of
    // the project stays on the 8x8 default.
    const base = convert.Options{ .block = .@"8x8" };
    const opts = resourceOpts(atlasPinning(.@"4x4"), base, false, .full);
    try std.testing.expectEqual(convert.BlockSize.@"4x4", opts.block);
}

test "resourceOpts: an explicit --block overrides every pin" {
    const base = convert.Options{ .block = .@"6x6" };
    const opts = resourceOpts(atlasPinning(.@"4x4"), base, true, .full);
    try std.testing.expectEqual(convert.BlockSize.@"6x6", opts.block);
}

test "resourceOpts: a pin the backend cannot upload degrades to the default" {
    // sokol loads 4x4 only. A pin it can't upload must NOT be baked: the
    // atlas would parse and then fail to upload, stranding the game on
    // the loading scene. Fall back rather than ship a dud.
    const base = convert.Options{ .block = .@"4x4" };
    const opts = resourceOpts(atlasPinning(.@"8x8"), base, false, .sokol_4x4_only);
    try std.testing.expectEqual(convert.BlockSize.@"4x4", opts.block);
}

test "resourceOpts: quality and other options are carried through unchanged" {
    const base = convert.Options{ .block = .@"8x8", .quality = .thorough };
    const opts = resourceOpts(atlasPinning(.@"4x4"), base, false, .full);
    try std.testing.expectEqual(convert.Quality.thorough, opts.quality);
}
