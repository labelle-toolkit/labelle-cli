/// `labelle audit unification <project-dir>` — pre-flight check for the
/// unified scene/prefab loader (RFC #560 / engine issue #581).
///
/// Read-only checks are run against `<project-dir>/scenes/**/*.jsonc`
/// and `<project-dir>/prefabs/**/*.jsonc`:
///
///  1. **Effective-name collisions** (RFC #560 §"Resolution and naming")
///     The unified loader builds one flat name-keyed registry from both
///     directories. Every file's *effective name* is its top-level
///     `"name"` field if present, otherwise its filename basename
///     (without `.jsonc`). Two files resolving to the same effective
///     name is a load-time error after #561 — the audit surfaces those
///     pairs pre-flight so they can be resolved by rename or by
///     authoring a distinct `"name"` field.
///
///  2. **§B2 violations** (RFC #560 §B2)
///     Any prefab-*reference* entry — an object with `"prefab"` — that
///     also carries `"children"` is rejected by the unified loader at
///     parse time. "Authoring lets you nest; instantiating doesn't."
///     The audit walks every parsed object tree (root + every nested
///     value, including embedded entity arrays inside component fields)
///     and reports every such pair with a JSON-pointer-style path.
///
///  3. **Legacy unified-format patterns** (RFC #560 — precursor to
///     engine #592)
///     The engine still accepts three deprecated spellings with a
///     one-shot deprecation warning each (see
///     `labelle-engine/src/jsonc/unified_format.zig`). #592 will remove
///     them in v2.0; the audit surfaces them so projects can migrate
///     before that lands. Three patterns:
///       a. Top-level `"entities"` key — should be wrapped in
///          `"root": { "children": [...] }`.
///       b. `"components"` on a *prefab reference* entry — should be
///          renamed to `"overrides"`. (Distinct from §B2: §B2 is
///          `prefab` + `children`; this is `prefab` + `components`.)
///       c. Top-level `"assets"` key in a scene — silently ignored;
///          assets are inferred from sprite refs (RFC #563).
///
/// Exit codes:
///   0 — all checks pass
///   1 — one or more findings (formatted report on stdout). Legacy
///       findings are counted alongside the others: they're migration
///       debt the project owner needs to address before v2.0.
///   2 — IO error (could not open project / files / dirs)
///
/// Read-only. The audit never modifies project files.

const std = @import("std");
const config = @import("config.zig");

// ─────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────

const usage =
    \\  usage: labelle audit unification [dir]
    \\
    \\Pre-flight check for the unified scene/prefab loader (RFC #560).
    \\Walks <dir>/scenes/ and <dir>/prefabs/ and reports:
    \\  1. Effective-name collisions across the merged namespace.
    \\  2. §B2 violations — `prefab` + `children` on the same entry.
    \\  3. Legacy unified-format patterns slated for removal in
    \\     engine #592 (top-level "entities", "components" on a prefab
    \\     reference, top-level "assets").
    \\
    \\Exits 0 if clean, 1 if findings, 2 on IO error.
    \\
;

/// Dispatch table for `labelle audit <subcommand>`.
/// Today the only subcommand is `unification`. Adding a sibling later
/// (e.g. `audit assets`) means another arm here — the dispatch stays
/// shallow so help/usage doesn't sprawl.
pub fn cmdAudit(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    if (cmd_args.len == 0) {
        std.debug.print("labelle audit: missing subcommand\n", .{});
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
    const sub = cmd_args[0];
    if (std.mem.eql(u8, sub, "unification")) {
        return runUnificationAudit(allocator, cmd_args[1..]);
    }
    if (std.mem.eql(u8, sub, "help") or std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        std.debug.print("{s}", .{usage});
        return;
    }
    std.debug.print("labelle audit: unknown subcommand '{s}'\n", .{sub});
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}

fn runUnificationAudit(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    var project_dir: []const u8 = ".";
    var dir_set = false;
    for (cmd_args) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("labelle audit unification: unknown flag '{s}'\n", .{arg});
            std.debug.print("{s}", .{usage});
            std.process.exit(2);
        }
        if (dir_set) {
            std.debug.print("labelle audit unification: unexpected argument '{s}' (only one project dir accepted)\n", .{arg});
            std.debug.print("{s}", .{usage});
            std.process.exit(2);
        }
        project_dir = arg;
        dir_set = true;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const A = arena.allocator();

    var report = Report.init(A);

    runAuditOn(A, project_dir, &report) catch |err| {
        std.debug.print("labelle audit unification: could not read project '{s}': {s}\n", .{ project_dir, @errorName(err) });
        std.process.exit(2);
    };

    if (report.findings.items.len == 0) {
        std.debug.print(
            "labelle audit unification: clean ({d} file(s) scanned across scenes/ + prefabs/)\n",
            .{report.files_scanned},
        );
        return;
    }

    report.print(project_dir);
    std.process.exit(1);
}

// ─────────────────────────────────────────────────────────────────────
// Audit core — split so tests can drive it without going through main()
// ─────────────────────────────────────────────────────────────────────

const Finding = union(enum) {
    collision: CollisionFinding,
    b2: B2Finding,
    legacy_entities: LegacyEntitiesFinding,
    legacy_components_on_ref: LegacyComponentsOnRefFinding,
    legacy_assets: LegacyAssetsFinding,
};

const CollisionFinding = struct {
    effective_name: []const u8,
    /// All source paths (rel to project_dir) that resolved to the
    /// same effective name. >=2 entries by construction.
    paths: []const []const u8,
};

const B2Finding = struct {
    file: []const u8,
    /// JSON-pointer-style path to the offending object inside the
    /// parsed tree, e.g. `/root/children/3` or `/root` for a
    /// reference-mode root.
    json_pointer: []const u8,
    prefab_ref: []const u8,
};

/// (3a) Top-level `"entities"` key — legacy scene shape. Engine v2.0
/// (#592) will reject this; today it loads with a one-shot warn.
/// Replacement: wrap the array in `"root": { "children": [...] }`.
const LegacyEntitiesFinding = struct {
    file: []const u8,
    /// Always `/entities` by construction (top-level key), kept as a
    /// field for symmetry with the other finding types and to make a
    /// future hoisted-array variant (#592 follow-up) trivial to add.
    json_pointer: []const u8,
};

/// (3b) `"components"` on a prefab *reference* entry (an object with
/// `"prefab"`). Distinct from §B2 (prefab + children); this is
/// prefab + components, which the engine accepts as a legacy synonym
/// for `"overrides"`. #592 will remove the synonym in v2.0.
const LegacyComponentsOnRefFinding = struct {
    file: []const u8,
    /// JSON-pointer to the offending reference entry (the object
    /// carrying both `prefab` and `components`), e.g.
    /// `/root/children/2`.
    json_pointer: []const u8,
    prefab_ref: []const u8,
    /// True iff `"overrides"` was *also* present on the same entry.
    /// When true, the engine takes overrides and warns; when false,
    /// the engine falls back to components and warns. The audit
    /// surfaces both so the project owner can migrate either way.
    overrides_also_present: bool,
};

/// (3c) Top-level `"assets"` key in a scene/prefab file. The unified
/// loader infers assets from sprite references (RFC #563) and ignores
/// this field silently today; #592 will remove the field entirely.
const LegacyAssetsFinding = struct {
    file: []const u8,
    json_pointer: []const u8,
};

const FileEntry = struct {
    /// Path relative to the project root (e.g. `scenes/foo.jsonc`).
    rel_path: []const u8,
    /// Effective name = file's top-level `"name"` field, falling back
    /// to basename(rel_path) without `.jsonc`.
    effective_name: []const u8,
    /// `name` was supplied explicitly (vs derived from basename).
    name_from_field: bool,
};

const Report = struct {
    allocator: std.mem.Allocator,
    findings: std.ArrayList(Finding),
    files_scanned: usize,

    fn init(allocator: std.mem.Allocator) Report {
        return .{
            .allocator = allocator,
            .findings = .empty,
            .files_scanned = 0,
        };
    }

    fn add(self: *Report, f: Finding) !void {
        try self.findings.append(self.allocator, f);
    }

    fn print(self: *const Report, project_dir: []const u8) void {
        std.debug.print(
            "labelle audit unification: {d} finding(s) in '{s}'\n\n",
            .{ self.findings.items.len, project_dir },
        );

        var n_collisions: usize = 0;
        var n_b2: usize = 0;
        var n_legacy_entities: usize = 0;
        var n_legacy_components: usize = 0;
        var n_legacy_assets: usize = 0;
        for (self.findings.items) |f| switch (f) {
            .collision => n_collisions += 1,
            .b2 => n_b2 += 1,
            .legacy_entities => n_legacy_entities += 1,
            .legacy_components_on_ref => n_legacy_components += 1,
            .legacy_assets => n_legacy_assets += 1,
        };

        if (n_collisions > 0) {
            std.debug.print("─── Effective-name collisions ({d}) ───\n", .{n_collisions});
            std.debug.print("  Two or more files resolve to the same registry key under the\n", .{});
            std.debug.print("  unified scenes/+prefabs/ flat namespace.\n", .{});
            std.debug.print("  Fix: rename one file, or add a distinct `\"name\": \"...\"` field.\n", .{});
            std.debug.print("  See: RFC-UNIFY-SCENES-AND-PREFABS.md §\"Resolution and naming\"\n\n", .{});
            for (self.findings.items) |f| switch (f) {
                .collision => |c| {
                    std.debug.print("  effective_name: \"{s}\"\n", .{c.effective_name});
                    for (c.paths) |p| std.debug.print("    {s}\n", .{p});
                    std.debug.print("\n", .{});
                },
                else => {},
            };
        }

        if (n_b2 > 0) {
            std.debug.print("─── §B2 violations ({d}) ───\n", .{n_b2});
            std.debug.print("  Prefab-reference entries that also declare `children`.\n", .{});
            std.debug.print("  The unified loader rejects this shape at parse time —\n", .{});
            std.debug.print("  authoring lets you nest; instantiating doesn't.\n", .{});
            std.debug.print("  Fix: move the children into the referenced prefab's own file,\n", .{});
            std.debug.print("  or replace the reference with an inline `components` entry.\n", .{});
            std.debug.print("  See: RFC-UNIFY-SCENES-AND-PREFABS.md §B2\n\n", .{});
            for (self.findings.items) |f| switch (f) {
                .b2 => |b| {
                    std.debug.print("  {s}  (at {s})\n", .{ b.file, b.json_pointer });
                    std.debug.print("    prefab: \"{s}\"\n\n", .{b.prefab_ref});
                },
                else => {},
            };
        }

        if (n_legacy_entities > 0) {
            std.debug.print("─── Legacy \"entities\" key ({d}) ───\n", .{n_legacy_entities});
            std.debug.print("  [unified-format] legacy \"entities\" key: wrap the entity array\n", .{});
            std.debug.print("  in a \"root\" block and rename it to \"children\" (RFC #560)\n", .{});
            std.debug.print("  Engine v2.0 (#592) will remove this fallback.\n\n", .{});
            for (self.findings.items) |f| switch (f) {
                .legacy_entities => |le| {
                    std.debug.print("  {s}  (at {s})\n\n", .{ le.file, le.json_pointer });
                },
                else => {},
            };
        }

        if (n_legacy_components > 0) {
            std.debug.print("─── Legacy \"components\" on prefab reference ({d}) ───\n", .{n_legacy_components});
            std.debug.print("  [unified-format] legacy \"components\" on a prefab reference:\n", .{});
            std.debug.print("  rename it to \"overrides\" (RFC #560). When both are present,\n", .{});
            std.debug.print("  \"overrides\" wins — remove \"components\".\n", .{});
            std.debug.print("  Engine v2.0 (#592) will remove the synonym.\n\n", .{});
            for (self.findings.items) |f| switch (f) {
                .legacy_components_on_ref => |lc| {
                    if (lc.overrides_also_present) {
                        std.debug.print("  {s}  (at {s})  [overrides also present]\n", .{ lc.file, lc.json_pointer });
                    } else {
                        std.debug.print("  {s}  (at {s})\n", .{ lc.file, lc.json_pointer });
                    }
                    std.debug.print("    prefab: \"{s}\"\n\n", .{lc.prefab_ref});
                },
                else => {},
            };
        }

        if (n_legacy_assets > 0) {
            std.debug.print("─── Legacy \"assets\" key ({d}) ───\n", .{n_legacy_assets});
            std.debug.print("  [unified-format] legacy \"assets\" key is ignored — assets\n", .{});
            std.debug.print("  are inferred from sprite references (RFC #560, #563).\n", .{});
            std.debug.print("  Engine v2.0 (#592) will remove the field entirely.\n\n", .{});
            for (self.findings.items) |f| switch (f) {
                .legacy_assets => |la| {
                    std.debug.print("  {s}  (at {s})\n\n", .{ la.file, la.json_pointer });
                },
                else => {},
            };
        }
    }
};

/// Run both audit checks over `<project_dir>/scenes/` and
/// `<project_dir>/prefabs/`. The recommended caller is
/// `cmdAudit`/`runUnificationAudit`; tests call this directly with a
/// tmp dir and inspect the populated `Report`.
fn runAuditOn(arena: std.mem.Allocator, project_dir: []const u8, report: *Report) !void {
    var files: std.ArrayList(FileEntry) = .empty;

    inline for (.{ "scenes", "prefabs" }) |subdir| {
        try collectAndCheckSubdir(arena, project_dir, subdir, &files, report);
    }

    report.files_scanned = files.items.len;
    try detectCollisions(arena, files.items, report);
}

fn collectAndCheckSubdir(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    subdir: []const u8,
    files: *std.ArrayList(FileEntry),
    report: *Report,
) !void {
    const io = config.globalIo();
    const full = try std.fs.path.join(arena, &.{ project_dir, subdir });

    var dir = std.Io.Dir.cwd().openDir(io, full, .{ .iterate = true }) catch |err| switch (err) {
        // It's fine for a project to lack one of the dirs — single-scene
        // fixtures often have no prefabs/. Empty contribution to the
        // registry, no error.
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var rel_buf: std.ArrayList(u8) = .empty;
    try rel_buf.appendSlice(arena, subdir);
    try walkSubdir(arena, &dir, &rel_buf, files, report);
}

fn walkSubdir(
    arena: std.mem.Allocator,
    dir: *std.Io.Dir,
    rel_buf: *std.ArrayList(u8),
    files: *std.ArrayList(FileEntry),
    report: *Report,
) !void {
    const io = config.globalIo();
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const saved_len = rel_buf.items.len;
        defer rel_buf.shrinkRetainingCapacity(saved_len);

        try rel_buf.append(arena, std.fs.path.sep);
        try rel_buf.appendSlice(arena, entry.name);

        switch (entry.kind) {
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch |err| {
                    // Propagate so the top-level catch in runUnificationAudit
                    // exits with code 2 instead of silently producing a
                    // clean-looking but partial scan.
                    std.debug.print("labelle audit unification: could not open '{s}': {s}\n", .{ rel_buf.items, @errorName(err) });
                    return err;
                };
                defer sub.close(io);
                try walkSubdir(arena, &sub, rel_buf, files, report);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".jsonc")) continue;
                const rel_path = try arena.dupe(u8, rel_buf.items);
                try inspectFile(arena, dir, entry.name, rel_path, files, report);
            },
            else => {},
        }
    }
}

fn inspectFile(
    arena: std.mem.Allocator,
    dir: *std.Io.Dir,
    entry_name: []const u8,
    rel_path: []const u8,
    files: *std.ArrayList(FileEntry),
    report: *Report,
) !void {
    const io = config.globalIo();

    // 1 MiB cap — scenes and prefabs are author-written JSON; in
    // practice the largest in-tree file is well under 64 KiB. This
    // mirrors `prefab_cache.zig`'s engine-side bound so we don't
    // diverge.
    //
    // IO and parse failures are propagated rather than swallowed so
    // the audit cannot exit 0-clean on a partial scan: a broken file
    // is treated as a hard error (exit code 2) per the documented
    // exit-code contract at the top of this file.
    const raw = dir.readFileAlloc(io, entry_name, arena, .limited(1024 * 1024)) catch |err| {
        std.debug.print("labelle audit unification: could not read '{s}': {s}\n", .{ rel_path, @errorName(err) });
        return err;
    };

    const stripped = try stripJsoncToJson(arena, raw);

    var parsed = std.json.parseFromSlice(std.json.Value, arena, stripped, .{}) catch |err| {
        std.debug.print("labelle audit unification: could not parse '{s}': {s}\n", .{ rel_path, @errorName(err) });
        return err;
    };
    defer parsed.deinit();

    // Effective-name extraction (RFC §"Effective name"). Dupe both
    // candidate strings into the arena: `entry_name` lives on the
    // iterator's internal buffer (invalidated on the next `iter.next`)
    // and `parsed.value.string` is freed when `parsed.deinit()` runs
    // at end-of-scope.
    var entry = FileEntry{
        .rel_path = rel_path,
        .effective_name = try arena.dupe(u8, basenameWithoutExt(entry_name)),
        .name_from_field = false,
    };
    if (parsed.value == .object) {
        if (parsed.value.object.get("name")) |name_val| {
            if (name_val == .string) {
                entry.effective_name = try arena.dupe(u8, name_val.string);
                entry.name_from_field = true;
            }
        }
    }
    try files.append(arena, entry);

    // Top-level legacy keys (3a, 3c). These checks operate on the
    // root object only — `"entities"` and `"assets"` are file-level
    // keys; the engine's `fileChildren` / `warnLegacyAssets` mirror
    // the same shape.
    //
    // RFC #560 — engine #592 will remove these in v2.0.
    if (parsed.value == .object) {
        const file_obj = parsed.value.object;
        if (file_obj.get("entities") != null) {
            try report.add(.{ .legacy_entities = .{
                .file = rel_path,
                .json_pointer = try arena.dupe(u8, "/entities"),
            } });
        }
        if (file_obj.get("assets") != null) {
            try report.add(.{ .legacy_assets = .{
                .file = rel_path,
                .json_pointer = try arena.dupe(u8, "/assets"),
            } });
        }
    }

    // §B2 walk + legacy-components-on-ref walk. Both are tree walks
    // over the same parsed object; co-locating the legacy walk keeps
    // the recursion in one place and avoids re-parsing.
    var path_buf: std.ArrayList(u8) = .empty;
    try walkB2(arena, parsed.value, rel_path, &path_buf, report);

    var path_buf2: std.ArrayList(u8) = .empty;
    try walkLegacyComponentsOnRef(arena, parsed.value, rel_path, &path_buf2, report);
}

fn basenameWithoutExt(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, ".jsonc")) return name[0 .. name.len - ".jsonc".len];
    return name;
}

/// Append `token` to `buf`, escaping the two characters that have
/// special meaning in JSON Pointer reference tokens (RFC 6901):
///   '~' → "~0"
///   '/' → "~1"
/// The order matters: escape '~' first so the '0'/'1' we introduce for
/// '/' cannot be mistaken for a pre-existing '~' escape.
fn appendJsonPointerToken(
    arena: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    token: []const u8,
) !void {
    for (token) |c| switch (c) {
        '~' => try buf.appendSlice(arena, "~0"),
        '/' => try buf.appendSlice(arena, "~1"),
        else => try buf.append(arena, c),
    };
}

// ─────────────────────────────────────────────────────────────────────
// Check 1 — effective-name collisions
// ─────────────────────────────────────────────────────────────────────

/// Group `files` by effective name and emit a collision finding for
/// every group with >=2 members. Order is determined by directory
/// iteration; the collision finding lists every contributor.
fn detectCollisions(arena: std.mem.Allocator, files: []const FileEntry, report: *Report) !void {
    var groups = std.StringHashMap(std.ArrayList([]const u8)).init(arena);
    for (files) |f| {
        const gop = try groups.getOrPut(f.effective_name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, f.rel_path);
    }

    var it = groups.iterator();
    while (it.next()) |kv| {
        const paths = kv.value_ptr.items;
        if (paths.len < 2) continue;
        try report.add(.{ .collision = .{
            .effective_name = kv.key_ptr.*,
            .paths = try arena.dupe([]const u8, paths),
        } });
    }
}

// ─────────────────────────────────────────────────────────────────────
// Check 2 — §B2 violations (prefab + children on the same entry)
// ─────────────────────────────────────────────────────────────────────

/// Recursive walker over the parsed JSON tree. Records a §B2 finding
/// for any object that has both `"prefab"` (a string) and `"children"`
/// (any type) as siblings.
///
/// `path_buf` accumulates a JSON-pointer-style location so reports
/// pinpoint the exact offending entry (e.g. `/root/children/3`). It is
/// restored to its pre-call length on every return.
fn walkB2(
    arena: std.mem.Allocator,
    value: std.json.Value,
    file: []const u8,
    path_buf: *std.ArrayList(u8),
    report: *Report,
) error{OutOfMemory}!void {
    switch (value) {
        .object => |obj| {
            // Check this node first.
            const has_prefab = obj.get("prefab") != null;
            const has_children = obj.get("children") != null;
            if (has_prefab and has_children) {
                const prefab_name = blk: {
                    const v = obj.get("prefab").?;
                    if (v == .string) break :blk v.string;
                    break :blk "<non-string>";
                };
                const ptr = if (path_buf.items.len == 0)
                    try arena.dupe(u8, "/")
                else
                    try arena.dupe(u8, path_buf.items);
                try report.add(.{ .b2 = .{
                    .file = file,
                    .json_pointer = ptr,
                    .prefab_ref = try arena.dupe(u8, prefab_name),
                } });
            }

            // Recurse into all sibling values.
            var it = obj.iterator();
            while (it.next()) |kv| {
                const saved = path_buf.items.len;
                defer path_buf.shrinkRetainingCapacity(saved);
                try path_buf.append(arena, '/');
                // Per RFC 6901: '~' → "~0", '/' → "~1" in reference tokens.
                // Object keys can legitimately contain these characters
                // (e.g. resource paths in override blocks), so unescaped
                // appends would produce ambiguous pointers.
                try appendJsonPointerToken(arena, path_buf, kv.key_ptr.*);
                try walkB2(arena, kv.value_ptr.*, file, path_buf, report);
            }
        },
        .array => |arr| {
            for (arr.items, 0..) |item, i| {
                const saved = path_buf.items.len;
                defer path_buf.shrinkRetainingCapacity(saved);
                var buf: [32]u8 = undefined;
                const idx = std.fmt.bufPrint(&buf, "/{d}", .{i}) catch unreachable;
                try path_buf.appendSlice(arena, idx);
                try walkB2(arena, item, file, path_buf, report);
            }
        },
        else => {},
    }
}

// ─────────────────────────────────────────────────────────────────────
// Check 3 — Legacy unified-format patterns (precursor to engine #592)
// ─────────────────────────────────────────────────────────────────────

/// Recursive walker that flags any object with BOTH `"prefab"` (a
/// string) and `"components"` as siblings — i.e. a prefab *reference*
/// carrying the legacy override-key spelling. The engine's
/// `entityPatch` accessor treats `"components"` here as a synonym for
/// `"overrides"` and warns once; #592 will remove the synonym.
///
/// Distinct from §B2 (which fires on `prefab` + `children`): the two
/// can co-occur on the same entry — both findings will be raised.
///
/// `path_buf` accumulates a JSON-pointer-style location, mirroring
/// `walkB2`. Restored on every return so siblings see a clean buffer.
fn walkLegacyComponentsOnRef(
    arena: std.mem.Allocator,
    value: std.json.Value,
    file: []const u8,
    path_buf: *std.ArrayList(u8),
    report: *Report,
) error{OutOfMemory}!void {
    switch (value) {
        .object => |obj| {
            const prefab_v = obj.get("prefab");
            const has_components = obj.get("components") != null;
            if (prefab_v != null and prefab_v.? == .string and has_components) {
                const prefab_name = prefab_v.?.string;
                const ptr = if (path_buf.items.len == 0)
                    try arena.dupe(u8, "/")
                else
                    try arena.dupe(u8, path_buf.items);
                try report.add(.{ .legacy_components_on_ref = .{
                    .file = file,
                    .json_pointer = ptr,
                    .prefab_ref = try arena.dupe(u8, prefab_name),
                    .overrides_also_present = obj.get("overrides") != null,
                } });
            }

            var it = obj.iterator();
            while (it.next()) |kv| {
                const saved = path_buf.items.len;
                defer path_buf.shrinkRetainingCapacity(saved);
                try path_buf.append(arena, '/');
                try appendJsonPointerToken(arena, path_buf, kv.key_ptr.*);
                try walkLegacyComponentsOnRef(arena, kv.value_ptr.*, file, path_buf, report);
            }
        },
        .array => |arr| {
            for (arr.items, 0..) |item, i| {
                const saved = path_buf.items.len;
                defer path_buf.shrinkRetainingCapacity(saved);
                var buf: [32]u8 = undefined;
                const idx = std.fmt.bufPrint(&buf, "/{d}", .{i}) catch unreachable;
                try path_buf.appendSlice(arena, idx);
                try walkLegacyComponentsOnRef(arena, item, file, path_buf, report);
            }
        },
        else => {},
    }
}

// ─────────────────────────────────────────────────────────────────────
// JSONC → JSON pre-stripper
// ─────────────────────────────────────────────────────────────────────

/// Strip JSONC-only constructs (`//` line comments, `/* */` block
/// comments, and trailing commas before `]` / `}`) so the result can
/// be fed to `std.json.parseFromSlice`. Strings (incl. escape
/// sequences) are preserved untouched. Not a full validator — this is
/// a *normalizer*; malformed JSON downstream surfaces from the json
/// parser with a useful message.
fn stripJsoncToJson(arena: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);
    try out.ensureTotalCapacity(arena, src.len);

    var i: usize = 0;
    var in_string = false;
    while (i < src.len) {
        const c = src[i];
        if (in_string) {
            try out.append(arena, c);
            if (c == '\\' and i + 1 < src.len) {
                // Forward the next char verbatim — covers \", \\, \n,
                // \uXXXX, etc. without needing to interpret them.
                try out.append(arena, src[i + 1]);
                i += 2;
                continue;
            }
            if (c == '"') in_string = false;
            i += 1;
            continue;
        }
        if (c == '"') {
            in_string = true;
            try out.append(arena, c);
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len) {
            if (src[i + 1] == '/') {
                // Line comment — drop to end-of-line.
                i += 2;
                while (i < src.len and src[i] != '\n') i += 1;
                continue;
            }
            if (src[i + 1] == '*') {
                // Block comment — drop to closing `*/`.
                i += 2;
                while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
                i = @min(src.len, i + 2);
                continue;
            }
        }
        if (c == ',') {
            // Trailing comma: peek past whitespace and any comments —
            // if the next significant character is `]` or `}`, drop
            // this comma.
            var j = i + 1;
            while (j < src.len) : (j += 1) {
                const cc = src[j];
                if (cc == ' ' or cc == '\t' or cc == '\n' or cc == '\r') continue;
                if (cc == '/' and j + 1 < src.len and (src[j + 1] == '/' or src[j + 1] == '*')) {
                    // Skip an embedded comment as we peek.
                    if (src[j + 1] == '/') {
                        while (j < src.len and src[j] != '\n') j += 1;
                    } else {
                        j += 2;
                        while (j + 1 < src.len and !(src[j] == '*' and src[j + 1] == '/')) j += 1;
                        j += 1;
                    }
                    continue;
                }
                break;
            }
            if (j < src.len and (src[j] == ']' or src[j] == '}')) {
                i += 1;
                continue;
            }
        }
        try out.append(arena, c);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

// ─────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────

const expect = @import("zspec").expect;

test {
    @import("zspec").runAll(@This());
}

pub const StripJsoncToJsonSpec = struct {
    pub const passes_pure_json = struct {
        test "round-trips a comment-free object" {
            const src =
                \\{"a": 1, "b": "two"}
            ;
            const out = try stripJsoncToJson(std.testing.allocator, src);
            defer std.testing.allocator.free(out);
            try std.testing.expectEqualStrings(src, out);
        }
    };

    pub const strips_line_comments = struct {
        test "drops `//` to end-of-line, keeps the newline" {
            const src =
                \\{"a": 1, // trailing comment
                \\ "b": 2}
            ;
            const out = try stripJsoncToJson(std.testing.allocator, src);
            defer std.testing.allocator.free(out);
            // Easiest spec: result must parse as JSON and have a=1 b=2.
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
            defer parsed.deinit();
            try expect.equal(parsed.value.object.get("a").?.integer, @as(i64, 1));
            try expect.equal(parsed.value.object.get("b").?.integer, @as(i64, 2));
        }
    };

    pub const strips_block_comments = struct {
        test "drops `/* ... */` spans" {
            const src =
                \\{"a": 1, /* block
                \\  spanning */ "b": 2}
            ;
            const out = try stripJsoncToJson(std.testing.allocator, src);
            defer std.testing.allocator.free(out);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
            defer parsed.deinit();
            try expect.equal(parsed.value.object.get("b").?.integer, @as(i64, 2));
        }
    };

    pub const strips_trailing_commas = struct {
        test "drops trailing comma before `}` and `]`" {
            const src =
                \\{"xs": [1, 2, 3,], "y": 4,}
            ;
            const out = try stripJsoncToJson(std.testing.allocator, src);
            defer std.testing.allocator.free(out);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
            defer parsed.deinit();
            try expect.equal(parsed.value.object.get("y").?.integer, @as(i64, 4));
            try expect.equal(parsed.value.object.get("xs").?.array.items.len, @as(usize, 3));
        }
    };

    pub const preserves_strings = struct {
        test "does not touch `//` inside a string" {
            const src =
                \\{"url": "https://example.com/path"}
            ;
            const out = try stripJsoncToJson(std.testing.allocator, src);
            defer std.testing.allocator.free(out);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings("https://example.com/path", parsed.value.object.get("url").?.string);
        }

        test "does not touch `,]` inside a string" {
            const src =
                \\{"s": "a,]b"}
            ;
            const out = try stripJsoncToJson(std.testing.allocator, src);
            defer std.testing.allocator.free(out);
            var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
            defer parsed.deinit();
            try std.testing.expectEqualStrings("a,]b", parsed.value.object.get("s").?.string);
        }
    };
};

pub const BasenameWithoutExtSpec = struct {
    test "strips `.jsonc`" {
        try std.testing.expectEqualStrings("foo", basenameWithoutExt("foo.jsonc"));
    }

    test "leaves non-jsonc names alone" {
        try std.testing.expectEqualStrings("foo.txt", basenameWithoutExt("foo.txt"));
    }
};

// Set up an isolated tmp project, write `scenes/` + `prefabs/`
// fixtures, run the full audit, return the resulting Report.
//
// Each entry in `files` is `path -> contents`; path is relative to the
// project root and must use forward slashes.
const TmpProject = struct {
    tmp: std.testing.TmpDir,
    abs_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    abs_path: []const u8 = "",

    fn deinit(self: *TmpProject) void {
        self.tmp.cleanup();
    }

    fn realPath(self: *TmpProject) ![]const u8 {
        if (self.abs_path.len != 0) return self.abs_path;
        const n = try self.tmp.dir.realPath(config.globalIo(), &self.abs_path_buf);
        self.abs_path = self.abs_path_buf[0..n];
        return self.abs_path;
    }

    fn write(self: *TmpProject, rel_path: []const u8, contents: []const u8) !void {
        const io = config.globalIo();
        // Materialize any leading directories.
        if (std.fs.path.dirname(rel_path)) |parent| {
            try self.tmp.dir.createDirPath(io, parent);
        }
        try self.tmp.dir.writeFile(io, .{ .sub_path = rel_path, .data = contents });
    }
};

fn runAuditForTest(project: *TmpProject) !struct { arena: *std.heap.ArenaAllocator, report: Report } {
    const arena_ptr = try std.testing.allocator.create(std.heap.ArenaAllocator);
    arena_ptr.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    const A = arena_ptr.allocator();
    var report = Report.init(A);
    const path = try project.realPath();
    try runAuditOn(A, path, &report);
    return .{ .arena = arena_ptr, .report = report };
}

fn freeAuditResult(r: anytype) void {
    r.arena.deinit();
    std.testing.allocator.destroy(r.arena);
}

pub const RunAuditOnSpec = struct {
    pub const clean_projects = struct {
        test "scenes/main + prefabs/worker is clean" {
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            try p.write("scenes/main.jsonc",
                \\{
                \\  "name": "main",
                \\  "root": { "children": [{ "prefab": "worker" }] }
                \\}
            );
            try p.write("prefabs/worker.jsonc",
                \\{ "root": { "components": { "Position": { "x": 0, "y": 0 } } } }
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            try expect.equal(result.report.findings.items.len, @as(usize, 0));
            try expect.equal(result.report.files_scanned, @as(usize, 2));
        }

        test "missing prefabs/ dir is not an error" {
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            try p.write("scenes/main.jsonc",
                \\{ "name": "main", "root": {} }
            );
            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);
            try expect.equal(result.report.findings.items.len, @as(usize, 0));
        }
    };

    pub const collisions = struct {
        test "scenes/foo + prefabs/foo collide on basename" {
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            try p.write("scenes/foo.jsonc",
                \\{ "root": {} }
            );
            try p.write("prefabs/foo.jsonc",
                \\{ "root": {} }
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            try expect.equal(result.report.findings.items.len, @as(usize, 1));
            switch (result.report.findings.items[0]) {
                .collision => |c| {
                    try std.testing.expectEqualStrings("foo", c.effective_name);
                    try expect.equal(c.paths.len, @as(usize, 2));
                },
                else => return error.TestFailed,
            }
        }

        test "explicit name field creates a cross-file collision" {
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            // scenes/menu.jsonc has its name overridden to "alpha"; a
            // prefab named alpha.jsonc collides on the override.
            try p.write("scenes/menu.jsonc",
                \\{ "name": "alpha", "root": {} }
            );
            try p.write("prefabs/alpha.jsonc",
                \\{ "root": {} }
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            try expect.equal(result.report.findings.items.len, @as(usize, 1));
            switch (result.report.findings.items[0]) {
                .collision => |c| {
                    try std.testing.expectEqualStrings("alpha", c.effective_name);
                },
                else => return error.TestFailed,
            }
        }

        test "nested folders contribute to the same flat namespace" {
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            try p.write("prefabs/rooms/lab.jsonc",
                \\{ "root": {} }
            );
            try p.write("prefabs/debug/lab.jsonc",
                \\{ "root": {} }
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            try expect.equal(result.report.findings.items.len, @as(usize, 1));
            switch (result.report.findings.items[0]) {
                .collision => |c| {
                    try std.testing.expectEqualStrings("lab", c.effective_name);
                    try expect.equal(c.paths.len, @as(usize, 2));
                },
                else => return error.TestFailed,
            }
        }
    };

    pub const b2_violations = struct {
        test "child entry with prefab+children is flagged" {
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            try p.write("scenes/bad.jsonc",
                \\{
                \\  "name": "bad",
                \\  "root": {
                \\    "children": [
                \\      { "prefab": "worker", "children": [{ "components": {} }] }
                \\    ]
                \\  }
                \\}
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            try expect.equal(result.report.findings.items.len, @as(usize, 1));
            switch (result.report.findings.items[0]) {
                .b2 => |b| {
                    try std.testing.expectEqualStrings("worker", b.prefab_ref);
                    // Path lands inside /root/children/0.
                    try std.testing.expect(std.mem.indexOf(u8, b.json_pointer, "/root/children/0") != null);
                },
                else => return error.TestFailed,
            }
        }

        test "reference-mode root with children is flagged at /root" {
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            try p.write("scenes/bad.jsonc",
                \\{
                \\  "name": "bad",
                \\  "root": { "prefab": "x", "children": [] }
                \\}
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            try expect.equal(result.report.findings.items.len, @as(usize, 1));
            switch (result.report.findings.items[0]) {
                .b2 => |b| try std.testing.expectEqualStrings("/root", b.json_pointer),
                else => return error.TestFailed,
            }
        }

        test "multiple violations in one project are all reported" {
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            try p.write("scenes/one.jsonc",
                \\{
                \\  "name": "one",
                \\  "root": {
                \\    "children": [
                \\      { "prefab": "a", "children": [] },
                \\      { "prefab": "b", "children": [] }
                \\    ]
                \\  }
                \\}
            );
            try p.write("scenes/two.jsonc",
                \\{
                \\  "name": "two",
                \\  "root": { "prefab": "c", "children": [] }
                \\}
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            // 2 from one.jsonc + 1 from two.jsonc.
            var n_b2: usize = 0;
            for (result.report.findings.items) |f| switch (f) {
                .b2 => n_b2 += 1,
                else => {},
            };
            try expect.equal(n_b2, @as(usize, 3));
        }
    };

    pub const both_checks_fire = struct {
        test "collision + b2 in the same project both surface" {
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            // Collision pair.
            try p.write("scenes/foo.jsonc",
                \\{ "root": {} }
            );
            try p.write("prefabs/foo.jsonc",
                \\{ "root": {} }
            );
            // §B2 violation.
            try p.write("scenes/bad.jsonc",
                \\{
                \\  "name": "bad",
                \\  "root": { "children": [{ "prefab": "x", "children": [] }] }
                \\}
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            var n_coll: usize = 0;
            var n_b2: usize = 0;
            for (result.report.findings.items) |f| switch (f) {
                .collision => n_coll += 1,
                .b2 => n_b2 += 1,
                else => {},
            };
            try expect.equal(n_coll, @as(usize, 1));
            try expect.equal(n_b2, @as(usize, 1));
        }
    };

    pub const legacy_entities_key = struct {
        test "top-level entities array is flagged" {
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            try p.write("scenes/old.jsonc",
                \\{
                \\  "name": "old",
                \\  "entities": [
                \\    { "components": { "Position": { "x": 0, "y": 0 } } }
                \\  ]
                \\}
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            try expect.equal(result.report.findings.items.len, @as(usize, 1));
            switch (result.report.findings.items[0]) {
                .legacy_entities => |le| {
                    try std.testing.expectEqualStrings("/entities", le.json_pointer);
                    // file path is project-relative under scenes/.
                    try std.testing.expect(std.mem.indexOf(u8, le.file, "old.jsonc") != null);
                },
                else => return error.TestFailed,
            }
        }

        test "entities arrays in two files surface two findings (arena dedup)" {
            // Drives the same `inspectFile` -> Dir.iterate() path that
            // PR #232's arena-dup fix protects: each entry_name lives on
            // the iterator's transient buffer. If we ever regress on
            // duplication here, file paths would alias and one of the
            // two findings would lose its file string.
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            try p.write("scenes/a.jsonc",
                \\{ "entities": [] }
            );
            try p.write("scenes/b.jsonc",
                \\{ "entities": [] }
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            var n: usize = 0;
            var saw_a = false;
            var saw_b = false;
            for (result.report.findings.items) |f| switch (f) {
                .legacy_entities => |le| {
                    n += 1;
                    if (std.mem.indexOf(u8, le.file, "a.jsonc") != null) saw_a = true;
                    if (std.mem.indexOf(u8, le.file, "b.jsonc") != null) saw_b = true;
                },
                else => {},
            };
            try expect.equal(n, @as(usize, 2));
            try std.testing.expect(saw_a);
            try std.testing.expect(saw_b);
        }
    };

    pub const legacy_components_on_ref = struct {
        test "prefab + components (no overrides) is flagged" {
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            try p.write("scenes/main.jsonc",
                \\{
                \\  "name": "main",
                \\  "root": {
                \\    "children": [
                \\      { "prefab": "worker", "components": { "Position": { "x": 0, "y": 0 } } }
                \\    ]
                \\  }
                \\}
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            try expect.equal(result.report.findings.items.len, @as(usize, 1));
            switch (result.report.findings.items[0]) {
                .legacy_components_on_ref => |lc| {
                    try std.testing.expectEqualStrings("worker", lc.prefab_ref);
                    try std.testing.expect(!lc.overrides_also_present);
                    try std.testing.expect(std.mem.indexOf(u8, lc.json_pointer, "/root/children/0") != null);
                },
                else => return error.TestFailed,
            }
        }

        test "prefab + components + overrides flags both keys on one entry" {
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            try p.write("scenes/main.jsonc",
                \\{
                \\  "name": "main",
                \\  "root": {
                \\    "children": [
                \\      {
                \\        "prefab": "worker",
                \\        "overrides": { "Position": { "x": 1, "y": 2 } },
                \\        "components": { "Health": { "hp": 100 } }
                \\      }
                \\    ]
                \\  }
                \\}
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            try expect.equal(result.report.findings.items.len, @as(usize, 1));
            switch (result.report.findings.items[0]) {
                .legacy_components_on_ref => |lc| {
                    try std.testing.expectEqualStrings("worker", lc.prefab_ref);
                    try std.testing.expect(lc.overrides_also_present);
                },
                else => return error.TestFailed,
            }
        }

        test "components on an INLINE entry (no prefab) is not a legacy finding" {
            // Inline entries (no `prefab`) legitimately use `components`.
            // The legacy synonym only applies to *reference* entries.
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            try p.write("scenes/main.jsonc",
                \\{
                \\  "name": "main",
                \\  "root": {
                \\    "children": [
                \\      { "components": { "Position": { "x": 0, "y": 0 } } }
                \\    ]
                \\  }
                \\}
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            try expect.equal(result.report.findings.items.len, @as(usize, 0));
        }

        test "§B2 and legacy-components-on-ref can co-fire on the same entry" {
            // prefab + children + components — both walks should
            // report against the same offending entry.
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            try p.write("scenes/bad.jsonc",
                \\{
                \\  "name": "bad",
                \\  "root": {
                \\    "children": [
                \\      {
                \\        "prefab": "x",
                \\        "children": [],
                \\        "components": { "Position": { "x": 0, "y": 0 } }
                \\      }
                \\    ]
                \\  }
                \\}
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            var n_b2: usize = 0;
            var n_legacy: usize = 0;
            for (result.report.findings.items) |f| switch (f) {
                .b2 => n_b2 += 1,
                .legacy_components_on_ref => n_legacy += 1,
                else => {},
            };
            try expect.equal(n_b2, @as(usize, 1));
            try expect.equal(n_legacy, @as(usize, 1));
        }

        test "two files with legacy components each surface two findings" {
            // Arena/dedup coverage across files — see the
            // legacy_entities sibling test for the rationale.
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            try p.write("scenes/a.jsonc",
                \\{ "root": { "children": [{ "prefab": "p", "components": {} }] } }
            );
            try p.write("scenes/b.jsonc",
                \\{ "root": { "children": [{ "prefab": "q", "components": {} }] } }
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            var n: usize = 0;
            var saw_a = false;
            var saw_b = false;
            for (result.report.findings.items) |f| switch (f) {
                .legacy_components_on_ref => |lc| {
                    n += 1;
                    if (std.mem.indexOf(u8, lc.file, "a.jsonc") != null) saw_a = true;
                    if (std.mem.indexOf(u8, lc.file, "b.jsonc") != null) saw_b = true;
                },
                else => {},
            };
            try expect.equal(n, @as(usize, 2));
            try std.testing.expect(saw_a);
            try std.testing.expect(saw_b);
        }
    };

    pub const legacy_assets_key = struct {
        test "top-level assets is flagged" {
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            try p.write("scenes/main.jsonc",
                \\{
                \\  "name": "main",
                \\  "assets": { "sprites": ["foo.png"] },
                \\  "root": { "children": [] }
                \\}
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            try expect.equal(result.report.findings.items.len, @as(usize, 1));
            switch (result.report.findings.items[0]) {
                .legacy_assets => |la| {
                    try std.testing.expectEqualStrings("/assets", la.json_pointer);
                    try std.testing.expect(std.mem.indexOf(u8, la.file, "main.jsonc") != null);
                },
                else => return error.TestFailed,
            }
        }

        test "two files with assets each surface two findings (arena dedup)" {
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            try p.write("scenes/a.jsonc",
                \\{ "assets": {}, "root": {} }
            );
            try p.write("scenes/b.jsonc",
                \\{ "assets": {}, "root": {} }
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            var n: usize = 0;
            var saw_a = false;
            var saw_b = false;
            for (result.report.findings.items) |f| switch (f) {
                .legacy_assets => |la| {
                    n += 1;
                    if (std.mem.indexOf(u8, la.file, "a.jsonc") != null) saw_a = true;
                    if (std.mem.indexOf(u8, la.file, "b.jsonc") != null) saw_b = true;
                },
                else => {},
            };
            try expect.equal(n, @as(usize, 2));
            try std.testing.expect(saw_a);
            try std.testing.expect(saw_b);
        }
    };

    pub const all_legacy_in_one_file = struct {
        test "entities + assets + components-on-ref all surface from one file" {
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            try p.write("scenes/legacy.jsonc",
                \\{
                \\  "name": "legacy",
                \\  "assets": {},
                \\  "entities": [
                \\    { "prefab": "worker", "components": { "Position": { "x": 0, "y": 0 } } }
                \\  ]
                \\}
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            var n_entities: usize = 0;
            var n_assets: usize = 0;
            var n_components: usize = 0;
            for (result.report.findings.items) |f| switch (f) {
                .legacy_entities => n_entities += 1,
                .legacy_assets => n_assets += 1,
                .legacy_components_on_ref => n_components += 1,
                else => {},
            };
            try expect.equal(n_entities, @as(usize, 1));
            try expect.equal(n_assets, @as(usize, 1));
            try expect.equal(n_components, @as(usize, 1));
        }
    };

    pub const unified_shape_is_clean = struct {
        test "fully unified file with overrides reports no legacy findings" {
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            try p.write("scenes/main.jsonc",
                \\{
                \\  "name": "main",
                \\  "root": {
                \\    "children": [
                \\      { "prefab": "worker", "overrides": { "Position": { "x": 0, "y": 0 } } },
                \\      { "components": { "Position": { "x": 1, "y": 1 } } }
                \\    ]
                \\  }
                \\}
            );
            try p.write("prefabs/worker.jsonc",
                \\{ "root": { "components": { "Position": { "x": 0, "y": 0 } } } }
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            // No findings of any flavor.
            try expect.equal(result.report.findings.items.len, @as(usize, 0));
        }
    };

    pub const passes_realistic_clean = struct {
        test "prefab without name field, scene with name field — no collision" {
            var p = TmpProject{ .tmp = std.testing.tmpDir(.{}) };
            defer p.deinit();
            try p.write("scenes/main.jsonc",
                \\{
                \\  "name": "main",
                \\  // a trailing comment
                \\  "root": {
                \\    "children": [
                \\      { "prefab": "worker", "overrides": { "Position": { "x": 0, "y": 0 } } },
                \\    ]
                \\  }
                \\}
            );
            try p.write("prefabs/worker.jsonc",
                \\{ "root": { "components": { "Position": { "x": 0, "y": 0 } } } }
            );

            const result = try runAuditForTest(&p);
            defer freeAuditResult(result);

            try expect.equal(result.report.findings.items.len, @as(usize, 0));
        }
    };
};
