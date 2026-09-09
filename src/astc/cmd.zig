//! `labelle astc [dir] [--block 8x8] [--quality fast]` — build-time ASTC
//! conversion (assembler#340 / epic labelle-gfx#269).
//!
//! Reads `project.labelle`, and for every **atlas** resource runs astcenc over
//! its `.texture` PNG to produce a co-located `<name>.astc` (cached by mtime).
//! Resource-level + packer-agnostic: it doesn't care whether the atlas came
//! from free-tex-packer (FP) or `labelle pack`.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("../cli/config.zig");
const project_config = @import("../cli/project_config.zig");
const asm_cache = @import("../cli/asm_cache.zig");
const util = @import("../cli/util.zig");
const lockfile = @import("../cli/lockfile.zig");
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
    \\  --allow-older-cli   proceed even when labelle.lock was written by a
    \\                      NEWER labelle than this binary (#353).
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
    // #353: the stale-CLI lock gate's escape hatch, accepted here too —
    // `labelle astc` is dispatched before pipeline.run, so it owns its own
    // copy of the flag (see the gate call below).
    var allow_older_cli = false;

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
        } else if (std.mem.eql(u8, arg, "--allow-older-cli")) {
            allow_older_cli = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usageErr("unknown option");
        } else {
            dir = arg;
        }
    }

    // Stale-CLI gate (#353): the standalone `labelle astc` is dispatched
    // before pipeline.run's gate, and ASTC encoding is exactly the
    // operation a stale binary silently mis-performs (per-atlas
    // `.astc_block` skipped → global block size → mangled art) — so it
    // enforces the lock itself.
    lockfile.enforceCliNotStale(allocator, dir, allow_older_cli) catch std.process.exit(1);

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
        // bgfx uploads any block it can name and validates none of them, so
        // an unsupported one renders garbage with no error at all — verified
        // on device with 6x6. See `BackendCaps.bgfx_4x4_8x8`.
        .bgfx => .bgfx_4x4_8x8,
        .wgpu => .full,
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

    // Collect EVERY atlas before converting any, so the clash check below
    // sees the whole set. The game's own resources and a pack's are equally
    // able to collide, and two manifests in one pack directory can collide
    // with each other, so a per-source check would leave holes.
    //
    // Pack/plugin-shipped atlases (labelle-cli#315, asset-plugins P1/P2):
    // packs and local plugins can declare their own `.resources`
    // (pack.labelle / plugin.labelle) — convert those too, or a compressed
    // target silently ships them as embedded PNG while the game's own
    // atlases ride ASTC (the invariant is: a resource behaves identically
    // whether declared by the game or by a pack). In-tree/local dirs only:
    // a REMOTE plugin's sources aren't materialized when this step runs
    // (pre-generate), so its atlases still ride the PNG fallback — a
    // documented limitation.
    var atlases: std.ArrayList(AtlasJob) = .empty;
    defer atlases.deinit(allocator);
    for (cfg.resources) |res| {
        if (res.kind() != .atlas) continue;
        try atlases.append(allocator, .{ .name = res.name, .base_dir = dir, .texture = res.texture, .opts = resourceOpts(res, opts, block_explicit, caps) });
    }
    for (cfg.plugins) |dep| {
        if (!dep.isLocal()) continue;
        // `resolve` (not `join`): an absolute `local:/…` path must be
        // preserved, not appended under the project dir — matches the plugin
        // resolution in cli/plugins.zig (codex review on #316).
        const pack_dir = try std.fs.path.resolve(allocator, &.{ dir, dep.localPath() });
        for ([_][]const u8{ "pack.labelle", "plugin.labelle" }) |manifest| {
            const resources = readDeclaredResources(allocator, pack_dir, manifest) orelse continue;
            for (resources) |res| {
                if (res.kind() != .atlas) continue;
                try atlases.append(allocator, .{ .name = res.name, .base_dir = pack_dir, .texture = res.texture, .opts = resourceOpts(res, opts, block_explicit, caps) });
            }
        }
    }

    // Two atlases may legitimately share one texture (different JSON views
    // of the same sheet), but they cannot ask for different blocks: they
    // compile to ONE `.astc`, so the second conversion overwrites the first
    // and one resource silently ships at a block it did not ask for. Refuse
    // instead of picking a winner.
    if (try conflictingBlockPin(allocator, atlases.items)) |clash| {
        std.debug.print(
            "labelle astc: atlases '{s}' and '{s}' both compile to '{s}' but pin different blocks " ++
                "({s} vs {s}) — pin the same block on both\n",
            .{ clash.first, clash.second, clash.out, clash.first_block.arg(), clash.second_block.arg() },
        );
        // A DISTINCT error, not `InvalidArgs`: the build pipeline treats a
        // failed conversion as non-fatal (it falls back to the source PNG),
        // which would let this rejection be logged and ignored — and worse,
        // a stale `.astc` from an earlier build would then be swapped in for
        // BOTH resources. A misconfiguration has to stop the build.
        return error.ConflictingAstcBlocks;
    }

    for (atlases.items) |job| {
        convertAtlas(allocator, astcenc, job.base_dir, job.texture, job.opts, &tally);
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

/// One atlas queued for conversion, from any source (the game's
/// `project.labelle` or a local pack/plugin manifest).
const AtlasJob = struct {
    name: []const u8,
    /// Directory `texture` is relative to — the project dir, or the pack's.
    base_dir: []const u8,
    texture: []const u8,
    opts: convert.Options,
};

/// Two queued atlases that compile to the same `.astc` but disagree on the
/// block — the pair whose outputs would clobber each other.
///
/// `out` is OWNED by the caller: the detector frees its key table on the way
/// out, so handing back a pointer into it would dangle (it printed as
/// garbage before this was an owned copy). `first`/`second` are borrowed
/// resource names, which outlive the call.
const BlockClash = struct {
    out: []u8,
    first: []const u8,
    second: []const u8,
    first_block: convert.BlockSize,
    second_block: convert.BlockSize,
};

/// The first pair of atlases writing one `.astc` with disagreeing blocks,
/// or null when every shared output agrees.
///
/// Keyed on the RESOLVED OUTPUT PATH, not on the declared texture string:
/// `shared.png` and `./shared.png` are different strings addressing the
/// same file, and two packs can reach the same texture by different
/// relative paths. The output path is what actually collides, so it is the
/// only correct key.
///
/// Compares the RESOLVED block (after precedence), not the raw pin: two
/// resources whose pins differ but which both fall back to the backend
/// default produce identical output and are fine.
fn conflictingBlockPin(allocator: std.mem.Allocator, jobs: []const AtlasJob) !?BlockClash {
    return conflictingBlockPinProbe(allocator, jobs, .{});
}

/// Injectable probe for collision-key tests (e.g. simulate a case-insensitive
/// destination on a case-sensitive host without a second mount).
const OutputFsProbe = struct {
    case_insensitive: ?*const fn (io: std.Io, dir: *const std.Io.Dir) bool = null,
};

const CasePolicyCache = std.StringHashMapUnmanaged(bool);

fn conflictingBlockPinProbe(allocator: std.mem.Allocator, jobs: []const AtlasJob, probe: OutputFsProbe) !?BlockClash {
    const io = config.globalIo();
    var seen: std.StringHashMapUnmanaged(struct { name: []const u8, block: convert.BlockSize }) = .empty;
    var case_policy: CasePolicyCache = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit(allocator);
        var policy_it = case_policy.keyIterator();
        while (policy_it.next()) |k| allocator.free(k.*);
        case_policy.deinit(allocator);
    }
    for (jobs) |job| {
        const src = try std.fs.path.join(allocator, &.{ job.base_dir, job.texture });
        defer allocator.free(src);
        const resolved = try std.fs.path.resolve(allocator, &.{src});
        defer allocator.free(resolved);
        const out = try convert.outputPath(allocator, resolved);
        defer allocator.free(out);

        const key = try outputCollisionKey(allocator, io, out, probe, &case_policy);
        defer allocator.free(key);

        if (seen.get(key)) |existing| {
            if (existing.block != job.opts.block) {
                const owned = try allocator.dupe(u8, out);
                return .{
                    .out = owned,
                    .first = existing.name,
                    .second = job.name,
                    .first_block = existing.block,
                    .second_block = job.opts.block,
                };
            }
            continue;
        }
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        try seen.put(allocator, owned_key, .{ .name = job.name, .block = job.opts.block });
    }
    return null;
}

/// Hash-map key for one `.astc` output. Lexical `resolve` already folds
/// `./shared.png` spellings; this layer adds filesystem truth for symlink
/// aliases, case-insensitive spellings, and outputs that do not exist yet.
///
/// When the output (or every ancestor needed to reach it) is on disk,
/// `realPath` is used — on macOS that normalizes case to the stored name
/// when the file exists, but we do not assume that on every filesystem.
/// When intermediate dirs exist but the `.astc` does not, the nearest
/// existing ancestor is realpath'd and the tail is reattached. When nothing
/// exists yet, the lexical path is kept. On a case-insensitive destination
/// directory the basename is folded so `Rooms.astc` and `rooms.astc` share
/// a key; the probe runs in that directory (not a global `/tmp` cache).
fn outputCollisionKey(allocator: std.mem.Allocator, io: std.Io, lexical_out: []const u8, probe: OutputFsProbe, case_policy: *CasePolicyCache) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    if (cwd.realPathFileAlloc(io, lexical_out, allocator)) |real_z| {
        defer allocator.free(real_z);
        return foldBasenameIfNeeded(allocator, io, real_z, probe, case_policy);
    } else |_| {}

    if (resolveOutputSymlinkTail(allocator, io, lexical_out)) |symlinked| {
        defer allocator.free(symlinked);
        if (cwd.realPathFileAlloc(io, symlinked, allocator)) |real_z| {
            defer allocator.free(real_z);
            return foldBasenameIfNeeded(allocator, io, real_z, probe, case_policy);
        } else |_| {}
        const partial = try nearestExistingRealPath(allocator, io, symlinked);
        defer allocator.free(partial);
        return foldBasenameIfNeeded(allocator, io, partial, probe, case_policy);
    }

    const partial = try nearestExistingRealPath(allocator, io, lexical_out);
    defer allocator.free(partial);
    return foldBasenameIfNeeded(allocator, io, partial, probe, case_policy);
}

/// When the output basename is a symlink (even dangling), follow it so
/// `foo.astc -> shared.astc` shares a key with `shared.astc`.
fn resolveOutputSymlinkTail(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    const parent = std.fs.path.dirname(path) orelse return null;
    if (parent.len == 0) return null;
    const base = std.fs.path.basename(path);
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, parent, .{}) catch return null;
    defer dir.close(io);
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_len = dir.readLink(io, base, &link_buf) catch return null;
    const target = link_buf[0..link_len];
    if (std.fs.path.isAbsolute(target)) return allocator.dupe(u8, target) catch null;
    return std.fs.path.resolve(allocator, &.{ parent, target }) catch null;
}

/// When the `.astc` itself is missing, walk upward to the nearest existing
/// ancestor, realpath it (resolving symlink aliases), then reattach the
/// missing tail. A symlinked `linked/missing/` therefore shares a key with
/// `assets/missing/`; when no ancestor exists, the lexical path is kept
/// (covers `/p/foo.astc` unit-test fixtures).
fn nearestExistingRealPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    var cursor = std.fs.path.dirname(path) orelse return try allocator.dupe(u8, path);
    if (cursor.len == 0) return try allocator.dupe(u8, path);

    var tail: std.ArrayList([]const u8) = .empty;
    defer tail.deinit(allocator);

    while (true) {
        if (cursor.len == 0) return try allocator.dupe(u8, path);
        cwd.access(io, cursor, .{}) catch {
            try tail.append(allocator, std.fs.path.basename(cursor));
            const parent = std.fs.path.dirname(cursor) orelse return try allocator.dupe(u8, path);
            cursor = parent;
            continue;
        };
        const real_ancestor = cwd.realPathFileAlloc(io, cursor, allocator) catch return try allocator.dupe(u8, path);
        defer allocator.free(real_ancestor);

        var result = try allocator.dupe(u8, real_ancestor);
        var i = tail.items.len;
        while (i > 0) {
            i -= 1;
            const joined = try std.fs.path.join(allocator, &.{ result, tail.items[i] });
            allocator.free(result);
            result = joined;
        }
        const with_base = try std.fs.path.join(allocator, &.{ result, std.fs.path.basename(path) });
        allocator.free(result);
        return with_base;
    }
}

fn foldBasenameIfNeeded(allocator: std.mem.Allocator, io: std.Io, path: []const u8, probe: OutputFsProbe, case_policy: *CasePolicyCache) ![]u8 {
    const parent = std.fs.path.dirname(path) orelse return try allocator.dupe(u8, path);
    if (parent.len == 0) return try allocator.dupe(u8, path);
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, parent, .{ .iterate = true }) catch return try allocator.dupe(u8, path);
    defer dir.close(io);
    const is_case_insensitive = if (case_policy.get(parent)) |cached|
        cached
    else blk: {
        const measured = resolveDirCaseInsensitive(io, &dir, probe);
        const owned_parent = try allocator.dupe(u8, parent);
        errdefer allocator.free(owned_parent);
        try case_policy.put(allocator, owned_parent, measured);
        break :blk measured;
    };
    if (!is_case_insensitive) return try allocator.dupe(u8, path);
    const base = std.fs.path.basename(path);
    const fold_source = canonicalExistingBasename(allocator, io, &dir, base) orelse base;
    defer if (fold_source.ptr != base.ptr) allocator.free(fold_source);
    const folded = try foldUnicodeBasenameAlloc(allocator, fold_source);
    defer allocator.free(folded);
    return std.fs.path.join(allocator, &.{ parent, folded });
}

/// When `basename` already exists under a case or Unicode alias, return the
/// on-disk spelling so folding matches the destination filesystem.
fn canonicalExistingBasename(allocator: std.mem.Allocator, io: std.Io, dir: *const std.Io.Dir, basename: []const u8) ?[]u8 {
    const opened = dir.openFile(io, basename, .{}) catch return null;
    defer opened.close(io);
    const st = opened.stat(io) catch return null;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.inode == st.inode) return allocator.dupe(u8, entry.name) catch null;
    }
    return null;
}

fn foldUnicodeBasenameAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var buf: [std.fs.max_name_bytes]u8 = undefined;
    const folded = try foldUnicodeBasename(&buf, name);
    return try allocator.dupe(u8, folded);
}

fn foldUnicodeBasename(output: []u8, input: []const u8) ![]const u8 {
    var out_i: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(input[i]) catch break;
        if (i + seq_len > input.len) break;
        const cp = std.unicode.utf8Decode(input[i .. i + seq_len]) catch break;
        const lower = unicodeToFoldedLower(cp);
        const encoded_len = std.unicode.utf8Encode(lower, output[out_i..]) catch return error.OutOfSpace;
        out_i += encoded_len;
        i += seq_len;
    }
    return output[0..out_i];
}

fn unicodeToFoldedLower(cp: u21) u21 {
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    return switch (cp) {
        0x00C0...0x00D6 => cp + 32,
        0x00D8...0x00DE => cp + 32,
        else => cp,
    };
}

fn resolveDirCaseInsensitive(io: std.Io, dir: *const std.Io.Dir, probe: OutputFsProbe) bool {
    if (probe.case_insensitive) |override| return override(io, dir);
    return dirPathIsCaseInsensitive(io, dir);
}

/// Create a uniquely named exclusive probe in `dir`; if the lowercase spelling
/// opens the uppercase file, that directory's volume is case-insensitive.
/// Only probe files created by this call are removed — preexisting names are
/// never deleted.
fn dirPathIsCaseInsensitive(io: std.Io, dir: *const std.Io.Dir) bool {
    return measureDirCaseInsensitive(io, dir, ".labelle-ci");
}

var case_probe_serial: std.atomic.Value(u64) = .init(0);

fn measureDirCaseInsensitive(io: std.Io, dir: *const std.Io.Dir, tag: []const u8) bool {
    var suffix_buf: [32]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buf, "{x}", .{case_probe_serial.fetchAdd(1, .monotonic)}) catch return false;

    var upper_buf: [std.fs.max_name_bytes]u8 = undefined;
    const upper = std.fmt.bufPrint(&upper_buf, "{s}-{s}-UPPER", .{ tag, suffix }) catch return false;

    var lower_buf: [std.fs.max_name_bytes]u8 = undefined;
    const lower = std.fmt.bufPrint(&lower_buf, "{s}-{s}-upper", .{ tag, suffix }) catch return false;

    dir.deleteFile(io, upper) catch {};
    dir.deleteFile(io, lower) catch {};
    dir.writeFile(io, .{ .sub_path = upper, .data = "x", .flags = .{ .exclusive = true } }) catch return false;
    defer dir.deleteFile(io, upper) catch {};

    const opened = dir.openFile(io, lower, .{}) catch return false;
    opened.close(io);
    return true;
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

test "conflictingBlockPin: same texture with different blocks is rejected" {
    // Both compile to one `.astc`, so the second conversion would
    // overwrite the first and one atlas would silently ship at the wrong
    // block — the failure this guard exists to prevent.
    const jobs = [_]AtlasJob{
        .{ .name = "sheet_a", .base_dir = "/p", .texture = "shared.png", .opts = .{ .block = .@"4x4" } },
        .{ .name = "sheet_b", .base_dir = "/p", .texture = "shared.png", .opts = .{ .block = .@"8x8" } },
    };
    const clash = (try conflictingBlockPin(std.testing.allocator, &jobs)).?;
    defer std.testing.allocator.free(clash.out);
    try std.testing.expectEqualStrings("sheet_a", clash.first);
    try std.testing.expectEqualStrings("sheet_b", clash.second);
    try std.testing.expectEqual(convert.BlockSize.@"4x4", clash.first_block);
    try std.testing.expectEqual(convert.BlockSize.@"8x8", clash.second_block);
}

test "conflictingBlockPin: path aliases for one file still clash" {
    // `shared.png` and `./shared.png` are different strings addressing the
    // same file. Keying on the raw texture string let their pins overwrite
    // each other silently; the key is the resolved OUTPUT path.
    const jobs = [_]AtlasJob{
        .{ .name = "a", .base_dir = "/p", .texture = "shared.png", .opts = .{ .block = .@"4x4" } },
        .{ .name = "b", .base_dir = "/p", .texture = "./shared.png", .opts = .{ .block = .@"8x8" } },
    };
    if (try conflictingBlockPin(std.testing.allocator, &jobs)) |c| std.testing.allocator.free(c.out) else return error.TestExpectedClash;

    // Same file reached from different base dirs, via a relative hop.
    const across = [_]AtlasJob{
        .{ .name = "game", .base_dir = "/p", .texture = "assets/x.png", .opts = .{ .block = .@"4x4" } },
        .{ .name = "pack", .base_dir = "/p/packs/sky", .texture = "../../assets/x.png", .opts = .{ .block = .@"8x8" } },
    };
    if (try conflictingBlockPin(std.testing.allocator, &across)) |c| std.testing.allocator.free(c.out) else return error.TestExpectedClash;
}

test "conflictingBlockPin: a pack manifest's own atlases are checked too" {
    // The clash check used to run only over the game's resources, so two
    // atlases inside one pack (or across pack.labelle and plugin.labelle in
    // the same directory) could clobber each other unnoticed.
    const jobs = [_]AtlasJob{
        .{ .name = "sky__a", .base_dir = "/p/packs/sky", .texture = "assets/bg.png", .opts = .{ .block = .@"4x4" } },
        .{ .name = "sky__b", .base_dir = "/p/packs/sky", .texture = "assets/bg.png", .opts = .{ .block = .@"6x6" } },
    };
    const clash = (try conflictingBlockPin(std.testing.allocator, &jobs)).?;
    defer std.testing.allocator.free(clash.out);
    try std.testing.expectEqualStrings("sky__a", clash.first);
}

test "conflictingBlockPin: same output with the same block is fine" {
    // Sharing a texture is legitimate (two JSON views of one sheet). Only
    // DISAGREEMENT is a problem.
    const jobs = [_]AtlasJob{
        .{ .name = "a", .base_dir = "/p", .texture = "shared.png", .opts = .{ .block = .@"4x4" } },
        .{ .name = "b", .base_dir = "/p", .texture = "shared.png", .opts = .{ .block = .@"4x4" } },
    };
    try std.testing.expect((try conflictingBlockPin(std.testing.allocator, &jobs)) == null);
}

test "conflictingBlockPin: distinct textures never clash" {
    const jobs = [_]AtlasJob{
        .{ .name = "a", .base_dir = "/p", .texture = "a.png", .opts = .{ .block = .@"4x4" } },
        .{ .name = "b", .base_dir = "/p", .texture = "b.png", .opts = .{ .block = .@"8x8" } },
    };
    try std.testing.expect((try conflictingBlockPin(std.testing.allocator, &jobs)) == null);
}

test "conflictingBlockPin: symlinked texture dirs share one output" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/shared.png", .data = "x" });
    try tmp.dir.symLink(io, "assets", "linked", .{ .is_directory = true });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const jobs = [_]AtlasJob{
        .{ .name = "via_assets", .base_dir = base, .texture = "assets/shared.png", .opts = .{ .block = .@"4x4" } },
        .{ .name = "via_link", .base_dir = base, .texture = "linked/shared.png", .opts = .{ .block = .@"8x8" } },
    };
    const clash = (try conflictingBlockPin(a, &jobs)).?;
    defer a.free(clash.out);
    try std.testing.expectEqualStrings("via_assets", clash.first);
    try std.testing.expectEqualStrings("via_link", clash.second);
}

test "conflictingBlockPin: existing .astc reached through a symlink alias clashes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/shared.png", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/shared.astc", .data = "\x00\x00\x00\x00\x04\x04\x00\x00" });
    try tmp.dir.symLink(io, "assets", "linked", .{ .is_directory = true });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const jobs = [_]AtlasJob{
        .{ .name = "canonical", .base_dir = base, .texture = "assets/shared.png", .opts = .{ .block = .@"4x4" } },
        .{ .name = "alias", .base_dir = base, .texture = "linked/shared.png", .opts = .{ .block = .@"8x8" } },
    };
    const clash = (try conflictingBlockPin(a, &jobs)).?;
    defer a.free(clash.out);
    try std.testing.expectEqualStrings("canonical", clash.first);
    try std.testing.expectEqualStrings("alias", clash.second);
}

test "conflictingBlockPin: not-yet-created outputs through symlink aliases clash" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/shared.png", .data = "x" });
    try tmp.dir.symLink(io, "assets", "linked", .{ .is_directory = true });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const jobs = [_]AtlasJob{
        .{ .name = "a", .base_dir = base, .texture = "assets/shared.png", .opts = .{ .block = .@"4x4" } },
        .{ .name = "b", .base_dir = base, .texture = "linked/shared.png", .opts = .{ .block = .@"8x8" } },
    };
    const clash = (try conflictingBlockPin(a, &jobs)).?;
    defer a.free(clash.out);
    try std.testing.expectEqual(convert.BlockSize.@"4x4", clash.first_block);
    try std.testing.expectEqual(convert.BlockSize.@"8x8", clash.second_block);
}

test "conflictingBlockPin: matching blocks through symlink aliases are fine" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/shared.png", .data = "x" });
    try tmp.dir.symLink(io, "assets", "linked", .{ .is_directory = true });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const jobs = [_]AtlasJob{
        .{ .name = "a", .base_dir = base, .texture = "assets/shared.png", .opts = .{ .block = .@"8x8" } },
        .{ .name = "b", .base_dir = base, .texture = "linked/shared.png", .opts = .{ .block = .@"8x8" } },
    };
    try std.testing.expect((try conflictingBlockPin(a, &jobs)) == null);
}

/// Test-only measurement of a directory's case policy. Uses a separate probe
/// tag from production so tests never gate on `dirPathIsCaseInsensitive`.
fn testEstablishDirCaseInsensitive(io: std.Io, dir: *const std.Io.Dir) bool {
    return measureDirCaseInsensitive(io, dir, ".labelle-fs-test");
}

test "dirPathIsCaseInsensitive: matches independent filesystem measurement" {
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const expected = testEstablishDirCaseInsensitive(io, &tmp.dir);
    try std.testing.expectEqual(expected, dirPathIsCaseInsensitive(io, &tmp.dir));
}

test "dirPathIsCaseInsensitive: leaves no probe files behind on miss" {
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    _ = dirPathIsCaseInsensitive(io, &tmp.dir);
    var it = tmp.dir.iterate();
    while (try it.next(io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, ".labelle-ci-"));
    }
}

test "conflictingBlockPin: case-only aliases follow filesystem case policy" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fs_ci = testEstablishDirCaseInsensitive(io, &tmp.dir);
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/Rooms.png", .data = "x" });
    if (!fs_ci) try tmp.dir.writeFile(io, .{ .sub_path = "assets/rooms.png", .data = "y" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const jobs = [_]AtlasJob{
        .{ .name = "upper", .base_dir = base, .texture = "assets/Rooms.png", .opts = .{ .block = .@"4x4" } },
        .{ .name = "lower", .base_dir = base, .texture = "assets/rooms.png", .opts = .{ .block = .@"8x8" } },
    };
    if (fs_ci) {
        const clash = (try conflictingBlockPin(a, &jobs)).?;
        defer a.free(clash.out);
        try std.testing.expectEqualStrings("upper", clash.first);
        try std.testing.expectEqualStrings("lower", clash.second);
    } else {
        try std.testing.expect((try conflictingBlockPin(a, &jobs)) == null);
    }
}

test "conflictingBlockPin: case aliases with matching blocks are fine on case-insensitive volumes" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fs_ci = testEstablishDirCaseInsensitive(io, &tmp.dir);
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/Rooms.png", .data = "x" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const jobs = [_]AtlasJob{
        .{ .name = "upper", .base_dir = base, .texture = "assets/Rooms.png", .opts = .{ .block = .@"4x4" } },
        .{ .name = "lower", .base_dir = base, .texture = "assets/rooms.png", .opts = .{ .block = .@"4x4" } },
    };
    if (fs_ci) {
        try std.testing.expect((try conflictingBlockPin(a, &jobs)) == null);
    } else {
        try tmp.dir.writeFile(io, .{ .sub_path = "assets/rooms.png", .data = "y" });
        try std.testing.expect((try conflictingBlockPin(a, &jobs)) == null);
    }
}

test "conflictingBlockPin: multi-level missing outputs through symlink aliases clash" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/shared.png", .data = "x" });
    try tmp.dir.symLink(io, "assets", "linked", .{ .is_directory = true });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const jobs = [_]AtlasJob{
        .{ .name = "via_assets", .base_dir = base, .texture = "assets/missing/deep/shared.png", .opts = .{ .block = .@"4x4" } },
        .{ .name = "via_link", .base_dir = base, .texture = "linked/missing/deep/shared.png", .opts = .{ .block = .@"8x8" } },
    };
    const clash = (try conflictingBlockPin(a, &jobs)).?;
    defer a.free(clash.out);
    try std.testing.expectEqualStrings("via_assets", clash.first);
    try std.testing.expectEqualStrings("via_link", clash.second);
}

test "nearestExistingRealPath: walks past missing dirs and resolves symlink aliases" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.symLink(io, "assets", "linked", .{ .is_directory = true });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const missing = try std.fs.path.join(a, &.{ base, "linked/missing/deep/out.astc" });
    defer a.free(missing);
    const resolved = try nearestExistingRealPath(a, io, missing);
    defer a.free(resolved);
    const expected = try std.fs.path.join(a, &.{ base, "assets/missing/deep/out.astc" });
    defer a.free(expected);
    try std.testing.expectEqualStrings(expected, resolved);
}

fn probeAlwaysCaseInsensitive(_: std.Io, _: *const std.Io.Dir) bool {
    return true;
}

fn probeAlwaysCaseSensitive(_: std.Io, _: *const std.Io.Dir) bool {
    return false;
}

test "conflictingBlockPin: injected case-insensitive probe clashes case aliases" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/Rooms.png", .data = "x" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const jobs = [_]AtlasJob{
        .{ .name = "upper", .base_dir = base, .texture = "assets/Rooms.png", .opts = .{ .block = .@"4x4" } },
        .{ .name = "lower", .base_dir = base, .texture = "assets/rooms.png", .opts = .{ .block = .@"8x8" } },
    };
    const probe: OutputFsProbe = .{ .case_insensitive = probeAlwaysCaseInsensitive };
    const clash = (try conflictingBlockPinProbe(a, &jobs, probe)).?;
    defer a.free(clash.out);
    try std.testing.expectEqualStrings("upper", clash.first);
    try std.testing.expectEqualStrings("lower", clash.second);
}

test "conflictingBlockPin: dangling output symlink aliases share one key" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/shared.png", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/foo.png", .data = "x" });
    // `shared.astc` does not exist yet; astcenc would follow this link and write there.
    try tmp.dir.symLink(io, "shared.astc", "assets/foo.astc", .{});
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const jobs = [_]AtlasJob{
        .{ .name = "canonical", .base_dir = base, .texture = "assets/shared.png", .opts = .{ .block = .@"4x4" } },
        .{ .name = "via_symlink", .base_dir = base, .texture = "assets/foo.png", .opts = .{ .block = .@"8x8" } },
    };
    const clash = (try conflictingBlockPin(a, &jobs)).?;
    defer a.free(clash.out);
    try std.testing.expectEqualStrings("canonical", clash.first);
    try std.testing.expectEqualStrings("via_symlink", clash.second);
}

test "conflictingBlockPin: non-ASCII case aliases follow filesystem case policy" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fs_ci = testEstablishDirCaseInsensitive(io, &tmp.dir);
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/\u{00c4}.png", .data = "x" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const jobs = [_]AtlasJob{
        .{ .name = "upper", .base_dir = base, .texture = "assets/\u{00c4}.png", .opts = .{ .block = .@"4x4" } },
        .{ .name = "lower", .base_dir = base, .texture = "assets/\u{00e4}.png", .opts = .{ .block = .@"8x8" } },
    };
    if (fs_ci) {
        const clash = (try conflictingBlockPin(a, &jobs)).?;
        defer a.free(clash.out);
        try std.testing.expectEqualStrings("upper", clash.first);
        try std.testing.expectEqualStrings("lower", clash.second);
    } else {
        try tmp.dir.writeFile(io, .{ .sub_path = "assets/\u{00e4}.png", .data = "y" });
        try std.testing.expect((try conflictingBlockPin(a, &jobs)) == null);
    }
}

test "conflictingBlockPin: injected case-sensitive probe keeps case aliases distinct" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/Rooms.png", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "assets/rooms.png", .data = "b" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const jobs = [_]AtlasJob{
        .{ .name = "upper", .base_dir = base, .texture = "assets/Rooms.png", .opts = .{ .block = .@"4x4" } },
        .{ .name = "lower", .base_dir = base, .texture = "assets/rooms.png", .opts = .{ .block = .@"8x8" } },
    };
    const probe: OutputFsProbe = .{ .case_insensitive = probeAlwaysCaseSensitive };
    try std.testing.expect((try conflictingBlockPinProbe(a, &jobs, probe)) == null);
}

test "BackendCaps: bgfx rejects blocks it cannot actually upload" {
    // bgfx names every ASTC block in a `TextureFormat` but validates none
    // against the runtime, so an unsupported one renders garbage with a clean
    // log — measured on an Adreno 610 with 6x6. Only the two blocks verified
    // on hardware are accepted.
    const caps: convert.BackendCaps = .bgfx_4x4_8x8;
    try std.testing.expect(caps.supports(.@"4x4"));
    try std.testing.expect(caps.supports(.@"8x8"));
    try std.testing.expect(!caps.supports(.@"6x6"));
    try std.testing.expect(!caps.supports(.@"5x5"));
    try std.testing.expect(!caps.supports(.@"12x12"));
    // And an atlas pinning one of those is dropped to the default rather than
    // baked into an unloadable file.
    const base = convert.Options{ .block = .@"8x8" };
    const opts = resourceOpts(atlasPinning(.@"6x6"), base, false, caps);
    try std.testing.expectEqual(convert.BlockSize.@"8x8", opts.block);
}
