/// `labelle migrate unified [dir]` — auto-fix the legacy unified-format
/// patterns the audit detects, with **comment preservation**.
///
/// Companion to `labelle audit unification` (cli#232/#236/#237 — see
/// `audit.zig`). The audit flags legacy spellings the unified loader
/// still accepts with a one-shot warn each; engine #592 / #594 / #596
/// will remove them in v2.0. This subcommand mechanically transforms
/// them in place so projects can move to the canonical flat form
/// without hand-edits across hundreds of files.
///
/// The eight transforms (idempotent — running twice on the same file
/// produces no further changes):
///
///   1. **`legacy_entities`** — top-level `"entities"` key. Rename to
///      `"children"` (post-#594 flat form drops the `"root"` wrapper).
///
///   2. **`legacy_components_on_ref`** — `"components"` on a prefab
///      *reference* (an object with a `"prefab"` sibling). Rename the
///      key to `"overrides"`. Inline-mode entities (no `"prefab"` —
///      `"components"` is the canonical shape there) are left alone.
///
///   3. **`legacy_assets`** — top-level `"assets"` array. The engine
///      ignores it (RFC #563 derives assets from sprite refs); delete
///      the line entirely, fixing up trailing commas.
///
///   4. **`legacy_root_wrapper`** — top-level `"root":` object. Lift
///      its contents to the file's top level and reduce indentation on
///      every inner line by one level (four spaces).
///
///   5. **`legacy_overrides_wrapper`** (RFC #596) — `"overrides": {...}`
///      on a prefab reference. Lift the inner PascalCase keys to be
///      direct siblings of `"prefab"`.
///
///   6. **`legacy_components_wrapper`** (RFC #596) — `"components":
///      {...}` on an INLINE entity (no `"prefab"` sibling). Lift the
///      inner PascalCase keys to the entity's top level. Distinguished
///      from transform 2 by the absence of `prefab`.
///
///   7. **`legacy_name_field`** (RFC #596) — top-level `"name": "X"`.
///      If X matches the file's basename it is dropped (the engine now
///      uses basename as identity). If X differs, it migrates into
///      `"meta": {"name": "X"}` and the migrator emits a one-line
///      warning when any other file references the declared name —
///      those references must be hand-fixed (option (b) of the RFC's
///      "cross-reference handling" choices).
///
///   8. **`legacy_file_object_no_root`** (RFC #596) — wrapping object
///      with only `"children": [...]` (no entity-shape sibling keys)
///      collapses to a top-level array, dropping the now-redundant
///      braces. Files with a true root entity (PascalCase components on
///      the wrapping object) stay objects.
///
/// **Comment-preserving strategy.** A naive re-serialize would round-
/// trip through `std.json.Value` and lose every JSONC comment plus
/// reorder unchanged keys. Instead this module operates on the **raw
/// bytes** of the file, locating the target keys with a small JSONC-
/// aware scanner (strings/escape sequences/comments are respected) and
/// splicing edits in place. The original whitespace, comment lines,
/// key ordering, and trailing punctuation are preserved everywhere the
/// migrator does *not* touch.
///
/// CLI shape:
///   labelle migrate unified [dir]
///   labelle migrate unified [dir] --dry-run
///
/// Exit codes:
///   0 — clean (everything migrated or already on the flat form)
///   1 — parse failure on at least one file, or write failure

const std = @import("std");
const config = @import("config.zig");

// ─────────────────────────────────────────────────────────────────────
// Entry point — dispatch + CLI flags
// ─────────────────────────────────────────────────────────────────────

const usage =
    \\  usage: labelle migrate unified [dir] [--dry-run]
    \\
    \\Auto-fix the legacy unified-format patterns the
    \\`labelle audit unification` subcommand detects:
    \\
    \\  Pre-#594 (root wrapper era):
    \\    1. top-level "entities" → top-level "children"
    \\    2. "components" on a prefab reference → "overrides"
    \\    3. top-level "assets" (ignored by engine) → removed
    \\    4. top-level "root" wrapper → contents lifted to top level
    \\
    \\  RFC #596 (flatten wrappers + bundle shape):
    \\    5. "overrides": { X, Y } on a prefab ref → X, Y as siblings
    \\    6. "components": { X, Y } inline entity → X, Y as siblings
    \\    7. top-level "name": "X" matching basename → dropped
    \\       top-level "name": "X" differing → meta.name = "X"
    \\    8. wrapping object { children: [...] } → top-level [ ... ]
    \\
    \\Comments and unchanged keys are preserved byte-for-byte (the
    \\migrator operates on raw bytes, not a re-serialized parse).
    \\
    \\Exits 0 on success (clean or migrated), 1 on parse / write error.
    \\
;

pub fn cmdMigrate(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    if (cmd_args.len == 0) {
        std.debug.print("labelle migrate: missing subcommand\n", .{});
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    }
    const sub = cmd_args[0];
    if (std.mem.eql(u8, sub, "help") or std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        std.debug.print("{s}", .{usage});
        return;
    }
    if (!std.mem.eql(u8, sub, "unified")) {
        std.debug.print("labelle migrate: unknown subcommand '{s}'\n", .{sub});
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    }
    return runUnifiedMigrate(allocator, cmd_args[1..]);
}

fn runUnifiedMigrate(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    var project_dir: []const u8 = ".";
    var dir_set = false;
    var dry_run = false;
    for (cmd_args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("labelle migrate unified: unknown flag '{s}'\n", .{arg});
            std.debug.print("{s}", .{usage});
            std.process.exit(1);
        }
        if (dir_set) {
            std.debug.print("labelle migrate unified: unexpected argument '{s}' (only one project dir accepted)\n", .{arg});
            std.debug.print("{s}", .{usage});
            std.process.exit(1);
        }
        project_dir = arg;
        dir_set = true;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const A = arena.allocator();

    var summary = Summary{};
    runMigrateOn(A, project_dir, dry_run, &summary) catch |err| {
        std.debug.print("labelle migrate unified: failed on project '{s}': {s}\n", .{ project_dir, @errorName(err) });
        std.process.exit(1);
    };

    summary.print(project_dir, dry_run);
    if (summary.parse_errors > 0 or summary.write_errors > 0) std.process.exit(1);
}

// ─────────────────────────────────────────────────────────────────────
// Migrator core
// ─────────────────────────────────────────────────────────────────────

/// Per-run counts surfaced to the user. The audit's "expected counts"
/// for a given project map 1:1 onto these:
///
///   audit.legacy_entities         ↔ summary.entities_renames
///   audit.legacy_components_on_ref ↔ summary.components_renames
///   audit.legacy_assets            ↔ summary.assets_deletes
///   audit.legacy_root_wrapper      ↔ summary.root_wrappers_lifted
///   audit.legacy_overrides_wrapper ↔ summary.overrides_lifts
///   audit.legacy_components_wrapper ↔ summary.components_lifts
///   audit.legacy_file_object_no_root ↔ summary.file_as_array_collapses
///   audit.legacy_name_field         ↔ summary.name_field_drops + summary.name_field_meta_moves
pub const Summary = struct {
    files_scanned: usize = 0,
    files_modified: usize = 0,
    files_clean: usize = 0,
    entities_renames: usize = 0,
    components_renames: usize = 0,
    assets_deletes: usize = 0,
    root_wrappers_lifted: usize = 0,
    // RFC #596 transforms.
    overrides_lifts: usize = 0,
    components_lifts: usize = 0,
    file_as_array_collapses: usize = 0,
    name_field_drops: usize = 0,
    name_field_meta_moves: usize = 0,
    name_field_xref_warnings: usize = 0,
    parse_errors: usize = 0,
    write_errors: usize = 0,

    fn print(self: *const Summary, project_dir: []const u8, dry_run: bool) void {
        const lifted = if (dry_run) "would be lifted" else "lifted";
        const removed = if (dry_run) "would be removed" else "removed";
        const renamed = if (dry_run) "would be renamed" else "renamed";
        const collapsed = if (dry_run) "would be collapsed" else "collapsed";
        const moved = if (dry_run) "would be moved" else "moved";
        const dropped = if (dry_run) "would be dropped" else "dropped";
        const modified = if (dry_run) "would be modified" else "modified";
        std.debug.print("labelle migrate unified: {s}\n", .{project_dir});
        std.debug.print("  {d} root wrapper{s} {s}\n", .{
            self.root_wrappers_lifted,
            if (self.root_wrappers_lifted == 1) "" else "s",
            lifted,
        });
        std.debug.print("  {d} legacy 'assets' key{s} {s}\n", .{
            self.assets_deletes,
            if (self.assets_deletes == 1) "" else "s",
            removed,
        });
        std.debug.print("  {d} 'entities' → 'children' rename{s} {s}\n", .{
            self.entities_renames,
            if (self.entities_renames == 1) "" else "s",
            renamed,
        });
        std.debug.print("  {d} 'components' → 'overrides' rename{s} {s}\n", .{
            self.components_renames,
            if (self.components_renames == 1) "" else "s",
            renamed,
        });
        std.debug.print("  {d} 'overrides' wrapper{s} {s}\n", .{
            self.overrides_lifts,
            if (self.overrides_lifts == 1) "" else "s",
            lifted,
        });
        std.debug.print("  {d} 'components' wrapper{s} {s}\n", .{
            self.components_lifts,
            if (self.components_lifts == 1) "" else "s",
            lifted,
        });
        std.debug.print("  {d} file{s} {s} to bundle array\n", .{
            self.file_as_array_collapses,
            if (self.file_as_array_collapses == 1) "" else "s",
            collapsed,
        });
        std.debug.print("  {d} redundant 'name' field{s} {s}\n", .{
            self.name_field_drops,
            if (self.name_field_drops == 1) "" else "s",
            dropped,
        });
        std.debug.print("  {d} divergent 'name' field{s} {s} into 'meta.name'\n", .{
            self.name_field_meta_moves,
            if (self.name_field_meta_moves == 1) "" else "s",
            moved,
        });
        if (self.name_field_xref_warnings > 0) {
            std.debug.print("  {d} divergent-name file{s} have cross-references that need manual review\n", .{
                self.name_field_xref_warnings,
                if (self.name_field_xref_warnings == 1) "" else "s",
            });
        }
        std.debug.print("  files {s}: {d}\n", .{ modified, self.files_modified });
        std.debug.print("  files clean:        {d}\n", .{self.files_clean});
        if (self.parse_errors > 0) std.debug.print("  parse errors:       {d}\n", .{self.parse_errors});
        if (self.write_errors > 0) std.debug.print("  write errors:       {d}\n", .{self.write_errors});
    }
};

fn runMigrateOn(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    dry_run: bool,
    summary: *Summary,
) !void {
    // First pass: collect every prefab reference (`{prefab: "X"}`) in
    // the project so transform 8 can flag divergent-name files whose
    // declared `name` is referenced elsewhere by that name. The check is
    // best-effort — if the scan fails, transform 8 still runs but won't
    // emit the cross-reference warning.
    var xrefs: std.StringHashMap(void) = .init(arena);
    inline for (.{ "scenes", "prefabs" }) |subdir| {
        collectPrefabRefs(arena, project_dir, subdir, &xrefs) catch {};
    }
    inline for (.{ "scenes", "prefabs" }) |subdir| {
        try walkAndMigrate(arena, project_dir, subdir, dry_run, &xrefs, summary);
    }
}

/// Walk a subdir and accumulate every `{prefab: "<name>"}` string-
/// referenced name into `xrefs`. Used by transform 8 to detect the case
/// where a file declares `name: "<X>"` that differs from its basename
/// AND other files reference it as `{prefab: "<X>"}` — those references
/// must be updated by hand (or the file renamed). The migrator can't
/// auto-resolve the ambiguity, so it just emits a warning per file.
/// Walks `<project_dir>/<subdir>` and collects every `{prefab: "X"}` xref
/// into `xrefs` (which lives in the main `arena`). Uses a per-file temp
/// arena that is reset after each file so the raw bytes + JSONC-stripped
/// buffer + parsed JSON tree for one file don't accumulate in the main
/// arena across N files — on a 1000-file project that would otherwise be
/// N file buffers + N parsed trees held simultaneously until the migrator
/// finishes. The only thing that survives the per-file reset is the xref
/// name string, which `collectPrefabRefsFromValue` dupes into `arena`
/// before returning. Future contributors: if you add anything that
/// outlives one file iteration, dupe it into `arena` here too.
fn collectPrefabRefs(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    subdir: []const u8,
    xrefs: *std.StringHashMap(void),
) !void {
    const io = config.globalIo();
    const full = try std.fs.path.join(arena, &.{ project_dir, subdir });
    var dir = std.Io.Dir.cwd().openDir(io, full, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var temp_arena = std.heap.ArenaAllocator.init(arena);
    defer temp_arena.deinit();
    try walkSubdirRefs(arena, &temp_arena, &dir, xrefs);
}

fn walkSubdirRefs(
    arena: std.mem.Allocator,
    temp_arena: *std.heap.ArenaAllocator,
    dir: *std.Io.Dir,
    xrefs: *std.StringHashMap(void),
) !void {
    const io = config.globalIo();
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer sub.close(io);
                try walkSubdirRefs(arena, temp_arena, &sub, xrefs);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".jsonc")) continue;
                const temp = temp_arena.allocator();
                const raw = dir.readFileAlloc(io, entry.name, temp, .limited(1024 * 1024)) catch {
                    _ = temp_arena.reset(.retain_capacity);
                    continue;
                };
                scanPrefabRefs(arena, temp, raw, xrefs) catch {};
                _ = temp_arena.reset(.retain_capacity);
            },
            else => {},
        }
    }
}

/// Pull every `{prefab: "<name>"}` reference out of one file's raw
/// JSONC bytes and insert the `<name>` strings into `xrefs`. Uses the
/// shared JSONC pre-stripper + `std.json` so comments don't confuse the
/// scan; we don't care about structural context (a `prefab:` key inside
/// a deeply-nested object is still a valid reference).
///
/// `temp` is reset by the caller after each file — raw bytes, the
/// stripped JSON buffer, and the parsed tree all live in `temp`. Only
/// xref name strings get duped into `arena` (the long-lived one that
/// owns `xrefs`).
fn scanPrefabRefs(
    arena: std.mem.Allocator,
    temp: std.mem.Allocator,
    raw: []const u8,
    xrefs: *std.StringHashMap(void),
) !void {
    const stripped = try stripJsoncToJson(temp, raw);
    var parsed = std.json.parseFromSlice(std.json.Value, temp, stripped, .{}) catch return;
    defer parsed.deinit();
    try collectPrefabRefsFromValue(arena, parsed.value, xrefs);
}

fn collectPrefabRefsFromValue(
    arena: std.mem.Allocator,
    value: std.json.Value,
    xrefs: *std.StringHashMap(void),
) !void {
    switch (value) {
        .object => |obj| {
            if (obj.get("prefab")) |pv| {
                if (pv == .string) {
                    // Dedup before duping: the value lives in the
                    // per-file temp arena and will vanish on reset, so
                    // the key MUST be duped into `arena` — but only on
                    // first sight, otherwise we leak a copy per
                    // reference across the project.
                    if (!xrefs.contains(pv.string)) {
                        const name_copy = try arena.dupe(u8, pv.string);
                        try xrefs.put(name_copy, {});
                    }
                }
            }
            var it = obj.iterator();
            while (it.next()) |kv| {
                try collectPrefabRefsFromValue(arena, kv.value_ptr.*, xrefs);
            }
        },
        .array => |arr| {
            for (arr.items) |item| try collectPrefabRefsFromValue(arena, item, xrefs);
        },
        else => {},
    }
}

fn walkAndMigrate(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    subdir: []const u8,
    dry_run: bool,
    xrefs: *const std.StringHashMap(void),
    summary: *Summary,
) !void {
    const io = config.globalIo();
    const full = try std.fs.path.join(arena, &.{ project_dir, subdir });
    var dir = std.Io.Dir.cwd().openDir(io, full, .{ .iterate = true }) catch |err| switch (err) {
        // A missing scenes/ or prefabs/ is fine — tiny fixtures often
        // have only one of the two. The migrator just contributes zero
        // findings for that subdir; no error.
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var rel_buf: std.ArrayList(u8) = .empty;
    try rel_buf.appendSlice(arena, subdir);
    try walkSubdir(arena, &dir, full, &rel_buf, dry_run, xrefs, summary);
}

fn walkSubdir(
    arena: std.mem.Allocator,
    dir: *std.Io.Dir,
    abs_dir: []const u8,
    rel_buf: *std.ArrayList(u8),
    dry_run: bool,
    xrefs: *const std.StringHashMap(void),
    summary: *Summary,
) !void {
    const io = config.globalIo();
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const saved_rel = rel_buf.items.len;
        defer rel_buf.shrinkRetainingCapacity(saved_rel);
        try rel_buf.append(arena, std.fs.path.sep);
        try rel_buf.appendSlice(arena, entry.name);

        switch (entry.kind) {
            .directory => {
                var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer sub.close(io);
                const sub_abs = try std.fs.path.join(arena, &.{ abs_dir, entry.name });
                try walkSubdir(arena, &sub, sub_abs, rel_buf, dry_run, xrefs, summary);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".jsonc")) continue;
                try migrateFile(arena, dir, entry.name, rel_buf.items, dry_run, xrefs, summary);
            },
            else => {},
        }
    }
}

fn migrateFile(
    arena: std.mem.Allocator,
    dir: *std.Io.Dir,
    entry_name: []const u8,
    rel_path: []const u8,
    dry_run: bool,
    xrefs: *const std.StringHashMap(void),
    summary: *Summary,
) !void {
    const io = config.globalIo();
    summary.files_scanned += 1;

    const raw = dir.readFileAlloc(io, entry_name, arena, .limited(1024 * 1024)) catch |err| {
        std.debug.print("labelle migrate unified: could not read '{s}': {s}\n", .{ rel_path, @errorName(err) });
        summary.parse_errors += 1;
        return;
    };

    // Parse the JSONC-stripped form once up-front so transforms can
    // consult a structural view (top-level keys, prefab-ref objects)
    // without re-implementing JSONC tokenization.
    const stripped = stripJsoncToJson(arena, raw) catch {
        std.debug.print("labelle migrate unified: could not pre-strip '{s}'\n", .{rel_path});
        summary.parse_errors += 1;
        return;
    };
    var parsed = std.json.parseFromSlice(std.json.Value, arena, stripped, .{}) catch |err| {
        std.debug.print("labelle migrate unified: could not parse '{s}': {s}\n", .{ rel_path, @errorName(err) });
        summary.parse_errors += 1;
        return;
    };
    defer parsed.deinit();

    const basename = basenameNoExt(entry_name);
    var counts = FileCounts{};
    const ctx = TransformCtx{
        .basename = basename,
        .xrefs = xrefs,
        .rel_path = rel_path,
    };
    const out = try transformBytes(arena, raw, parsed.value, ctx, &counts);

    summary.entities_renames += counts.entities_renames;
    summary.components_renames += counts.components_renames;
    summary.assets_deletes += counts.assets_deletes;
    summary.root_wrappers_lifted += counts.root_wrappers_lifted;
    summary.overrides_lifts += counts.overrides_lifts;
    summary.components_lifts += counts.components_lifts;
    summary.file_as_array_collapses += counts.file_as_array_collapses;
    summary.name_field_drops += counts.name_field_drops;
    summary.name_field_meta_moves += counts.name_field_meta_moves;
    summary.name_field_xref_warnings += counts.name_field_xref_warnings;

    if (counts.totalEdits() == 0) {
        summary.files_clean += 1;
        return;
    }

    summary.files_modified += 1;
    if (dry_run) return;

    dir.writeFile(io, .{ .sub_path = entry_name, .data = out }) catch |err| {
        std.debug.print("labelle migrate unified: could not write '{s}': {s}\n", .{ rel_path, @errorName(err) });
        summary.write_errors += 1;
    };
}

const FileCounts = struct {
    entities_renames: usize = 0,
    components_renames: usize = 0,
    assets_deletes: usize = 0,
    root_wrappers_lifted: usize = 0,
    overrides_lifts: usize = 0,
    components_lifts: usize = 0,
    file_as_array_collapses: usize = 0,
    name_field_drops: usize = 0,
    name_field_meta_moves: usize = 0,
    name_field_xref_warnings: usize = 0,

    fn totalEdits(self: FileCounts) usize {
        return self.entities_renames +
            self.components_renames +
            self.assets_deletes +
            self.root_wrappers_lifted +
            self.overrides_lifts +
            self.components_lifts +
            self.file_as_array_collapses +
            self.name_field_drops +
            self.name_field_meta_moves;
    }
};

// ─────────────────────────────────────────────────────────────────────
// Byte-oriented transform pipeline
// ─────────────────────────────────────────────────────────────────────

/// Context shared by transforms 5-8 (RFC #596). `basename` is the file
/// name without `.jsonc`. `xrefs` holds every `{prefab: "<name>"}`
/// string seen across the project (built by the first scan pass) — used
/// by transform 8 to warn when a divergent `name:` is referenced by
/// other files. `rel_path` is the project-relative path used in user-
/// facing warnings. `rfc596` gates the new transforms 5-8 — legacy unit
/// tests for transforms 1-4 pass `false` so their fixtures (which would
/// otherwise be further collapsed by transforms 7/8) keep their pre-
/// RFC-596 expected shape.
const TransformCtx = struct {
    basename: []const u8,
    xrefs: *const std.StringHashMap(void),
    rel_path: []const u8,
    rfc596: bool = true,
};

/// Apply every transform to `src` and return a new owned buffer.
///
/// Pass order (matters — earlier passes set up the structural shape the
/// later passes expect to find):
///
///   1. root-wrapper lift (legacy #594). Runs first so the post-lift
///      top level becomes visible to subsequent top-level transforms.
///   2. assets-delete — top-level only.
///   3. entities → children rename — top-level only.
///   4. components → overrides on prefab refs — walks the whole tree.
///   5. RFC #596: lift `overrides` block (walks the whole tree). Must
///      run AFTER pass 4 has converted components→overrides — otherwise
///      we'd miss the legacy `components`-on-ref entries.
///   6. RFC #596: lift inline `components` block (walks the whole
///      tree). Independent of pass 5; ordering between them doesn't
///      matter, but it must run after pass 4 (so the `components` keys
///      that pass 4 renames don't get accidentally lifted here).
///   7. RFC #596: top-level `name:` → `meta.name` or drop. MUST run
///      BEFORE pass 8 — pass 8 collapses the wrapping object and there
///      is no longer anywhere to place a separate `name` key.
///   8. RFC #596: collapse wrapping object to bundle array.
///
/// Each pass re-parses the working buffer to refresh structural info,
/// then locates the target key in the raw JSONC bytes. Idempotency
/// follows from each pass being a no-op on already-flat files. Tests
/// verify a second run produces byte-identical output.
fn transformBytes(
    arena: std.mem.Allocator,
    src: []const u8,
    parsed_value: std.json.Value,
    ctx: TransformCtx,
    counts: *FileCounts,
) ![]u8 {
    _ = parsed_value;
    var current = try arena.dupe(u8, src);

    // Pass 1 — top-level "root" wrapper lift.
    {
        const stripped = try stripJsoncToJson(arena, current);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, stripped, .{});
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("root")) |rv| {
                if (rv == .object) {
                    if (liftTopLevelRoot(arena, current)) |out| {
                        current = out;
                        counts.root_wrappers_lifted += 1;
                    }
                }
            }
        }
    }

    // Pass 2 — top-level "assets" key delete.
    {
        const stripped = try stripJsoncToJson(arena, current);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, stripped, .{});
        defer parsed.deinit();
        if (parsed.value == .object and parsed.value.object.get("assets") != null) {
            if (deleteTopLevelKey(arena, current, "assets")) |out| {
                current = out;
                counts.assets_deletes += 1;
            }
        }
    }

    // Pass 3 — top-level "entities" → "children" rename.
    {
        const stripped = try stripJsoncToJson(arena, current);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, stripped, .{});
        defer parsed.deinit();
        if (parsed.value == .object and parsed.value.object.get("entities") != null) {
            if (renameTopLevelKey(arena, current, "entities", "children")) |out| {
                current = out;
                counts.entities_renames += 1;
            }
        }
    }

    // Pass 4 — every "components" key on a prefab-ref object → "overrides".
    // Loops until no further renames are made; each rename invalidates
    // byte offsets so we re-scan after each edit. Bounded by the number
    // of prefab refs in the file (worst case O(n²) walks; n is small).
    while (true) {
        const stripped = try stripJsoncToJson(arena, current);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, stripped, .{});
        defer parsed.deinit();
        const edited = renameOneComponentsOnRef(arena, current, parsed.value) catch null;
        if (edited) |out| {
            current = out;
            counts.components_renames += 1;
            continue;
        }
        break;
    }

    if (!ctx.rfc596) return current;

    // Pass 5 — RFC #596: lift `overrides` block (`{prefab, overrides:
    // {X, Y}}` → `{prefab, X, Y}`). Loops until fixed point; one lift
    // per iteration.
    while (true) {
        const stripped = try stripJsoncToJson(arena, current);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, stripped, .{});
        defer parsed.deinit();
        const edited = liftOneOverridesBlock(arena, current, parsed.value) catch null;
        if (edited) |out| {
            current = out;
            counts.overrides_lifts += 1;
            continue;
        }
        break;
    }

    // Pass 6 — RFC #596: lift inline `components` block (`{components:
    // {X, Y}, ...}` → `{X, Y, ...}`). Targets objects WITHOUT a sibling
    // `prefab` key (pass 4 already renamed those, so by the time we get
    // here the only remaining `components` keys are inline-mode ones).
    while (true) {
        const stripped = try stripJsoncToJson(arena, current);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, stripped, .{});
        defer parsed.deinit();
        const edited = liftOneComponentsBlock(arena, current, parsed.value) catch null;
        if (edited) |out| {
            current = out;
            counts.components_lifts += 1;
            continue;
        }
        break;
    }

    // Pass 7 — RFC #596: top-level `name:` → `meta.name` or drop. Runs
    // BEFORE pass 8 (file-as-array collapse) — once the wrapping object
    // is gone there's no top level to host a `name` or `meta` key. If a
    // bundle header (`{meta: ...}`) is needed, transform 8 picks up
    // whatever `meta:` pass 7 left behind and emits it as the array's
    // first element.
    {
        const stripped = try stripJsoncToJson(arena, current);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, stripped, .{});
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("name")) |nv| {
                if (nv == .string) {
                    const name = nv.string;
                    if (std.mem.eql(u8, name, ctx.basename)) {
                        // Redundant — drop.
                        if (deleteTopLevelKey(arena, current, "name")) |out| {
                            current = out;
                            counts.name_field_drops += 1;
                        }
                    } else {
                        // Divergent — move to meta.name. If `meta:`
                        // already exists, merge into it; otherwise rename
                        // the `name:` key and wrap its value in `{}`.
                        const has_meta = parsed.value.object.get("meta") != null;
                        if (moveNameToMeta(arena, current, name, has_meta)) |out| {
                            current = out;
                            counts.name_field_meta_moves += 1;
                            if (ctx.xrefs.contains(name)) {
                                counts.name_field_xref_warnings += 1;
                                std.debug.print(
                                    "labelle migrate unified: WARNING: '{s}' declared name \"{s}\" differs from basename \"{s}\" AND is referenced as {{prefab: \"{s}\"}} elsewhere — those references must be updated to \"{s}\" (or rename the file to \"{s}.jsonc\")\n",
                                    .{ ctx.rel_path, name, ctx.basename, name, ctx.basename, name },
                                );
                            }
                        }
                    }
                }
            }
        }
    }

    // Pass 8 — RFC #596: collapse file-level wrapping object to a top-
    // level array when its only entity-bearing key is `children:`. A
    // file like `{ children: [...] }` (post-pass-7, so `name:` is
    // already either dropped or migrated into `meta:`) becomes `[...]`,
    // with an optional `{meta: ...}` header element if a `meta:` block
    // was present.
    {
        const stripped = try stripJsoncToJson(arena, current);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, stripped, .{});
        defer parsed.deinit();
        if (shouldCollapseFileToArray(parsed.value)) {
            if (collapseFileToArray(arena, current, parsed.value)) |out| {
                current = out;
                counts.file_as_array_collapses += 1;
            }
        }
    }

    return current;
}

/// Strip `.jsonc` (or `.json`) extension from `entry_name`, returning
/// the basename used by both the audit's "name vs basename" check and
/// transform 8's bundle-header heuristic.
fn basenameNoExt(entry_name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, entry_name, '.')) |dot| {
        return entry_name[0..dot];
    }
    return entry_name;
}

// ─────────────────────────────────────────────────────────────────────
// JSONC-aware byte scanner
// ─────────────────────────────────────────────────────────────────────

/// Outcome of `findTopLevelKey`. `key_start` points at the opening `"`
/// of the key string; `key_end` is one past its closing `"`. `colon`
/// points at the `:` byte that follows. `value_start` is the index of
/// the first non-whitespace value byte. `entry_start` is the position
/// of the first byte of the "key entry" — including leading whitespace
/// from the previous newline. `entry_end` is the index just past the
/// value's last byte, **excluding** any trailing comma. `comma_after`
/// is the index of the `,` that separates this entry from the next
/// sibling (or `null` if this is the last entry of the object).
const KeyLoc = struct {
    /// Index of the opening `"` of the key.
    key_start: usize,
    /// One past the closing `"` of the key.
    key_end: usize,
    /// Index of the `:` between key and value.
    colon: usize,
    /// Index of the first byte of the value (whitespace-skipped).
    value_start: usize,
    /// One past the last byte of the value.
    value_end: usize,
    /// Index of the `,` that follows this entry (if any).
    comma_after: ?usize,
    /// Index of the start-of-line of the entry (the previous `\n`+1,
    /// or the `{`+1 if this is the first sibling).
    line_start: usize,
};

/// Locate `key` as a *top-level* key in the file's outer `{ ... }`.
/// Returns `null` if not present. Strings, line/block comments are
/// respected by the scanner so a `"key"` inside a JSON string won't
/// be misidentified.
fn findTopLevelKey(src: []const u8, key: []const u8) ?KeyLoc {
    // Skip whitespace/comments to find the opening `{`.
    var i: usize = skipWsAndComments(src, 0);
    if (i >= src.len or src[i] != '{') return null;
    i += 1;

    while (true) {
        i = skipWsAndComments(src, i);
        if (i >= src.len) return null;
        if (src[i] == '}') return null;
        if (src[i] != '"') return null; // malformed; bail
        const k_start = i;
        const k_end = findStringEnd(src, k_start);
        const this_key = src[k_start + 1 .. k_end - 1];

        // Find `:`
        var j = skipWsAndComments(src, k_end);
        if (j >= src.len or src[j] != ':') return null;
        const colon_pos = j;
        j += 1;
        j = skipWsAndComments(src, j);
        const value_start = j;
        const value_end = skipValue(src, value_start);
        var k = skipWsAndComments(src, value_end);
        var comma: ?usize = null;
        if (k < src.len and src[k] == ',') {
            comma = k;
            k += 1;
        }

        if (std.mem.eql(u8, this_key, key)) {
            // Find line_start: walk back to the previous '\n'+1.
            var ls: usize = k_start;
            while (ls > 0 and src[ls - 1] != '\n') ls -= 1;
            return KeyLoc{
                .key_start = k_start,
                .key_end = k_end,
                .colon = colon_pos,
                .value_start = value_start,
                .value_end = value_end,
                .comma_after = comma,
                .line_start = ls,
            };
        }

        i = k;
    }
}

/// Return the index of the character just past the closing `"` of the
/// string starting at `start` (which must point at `"`).
fn findStringEnd(src: []const u8, start: usize) usize {
    std.debug.assert(src[start] == '"');
    var i: usize = start + 1;
    while (i < src.len) {
        const c = src[i];
        if (c == '\\' and i + 1 < src.len) {
            i += 2;
            continue;
        }
        if (c == '"') return i + 1;
        i += 1;
    }
    return src.len;
}

/// Skip past one JSON value starting at `start`. Returns the index
/// just past its last byte. Handles objects/arrays via brace counting
/// (still honoring strings and comments inside), and scalars via a
/// terminator-set.
fn skipValue(src: []const u8, start: usize) usize {
    var i = start;
    if (i >= src.len) return i;
    switch (src[i]) {
        '"' => return findStringEnd(src, i),
        '{', '[' => return skipContainer(src, i),
        else => {
            // Scalar — number / true / false / null. Read until we
            // hit a structural terminator at the current bracket depth.
            while (i < src.len) : (i += 1) {
                const c = src[i];
                if (c == ',' or c == '}' or c == ']' or c == '\n' or c == ' ' or c == '\t' or c == '\r') return i;
                if (c == '/' and i + 1 < src.len and (src[i + 1] == '/' or src[i + 1] == '*')) return i;
            }
            return i;
        },
    }
}

/// Skip a `{ ... }` or `[ ... ]` container starting at `start` (which
/// must point at `{` or `[`). Returns the index just past the matching
/// closing brace. Respects strings and JSONC comments inside.
fn skipContainer(src: []const u8, start: usize) usize {
    var depth: usize = 0;
    var i = start;
    while (i < src.len) {
        const c = src[i];
        if (c == '"') {
            i = findStringEnd(src, i);
            continue;
        }
        if (c == '/' and i + 1 < src.len) {
            if (src[i + 1] == '/') {
                while (i < src.len and src[i] != '\n') i += 1;
                continue;
            }
            if (src[i + 1] == '*') {
                i += 2;
                while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
                i = @min(src.len, i + 2);
                continue;
            }
        }
        if (c == '{' or c == '[') depth += 1;
        if (c == '}' or c == ']') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
        i += 1;
    }
    return i;
}

/// Skip whitespace and JSONC comments starting at `i`. Returns the
/// index of the first significant byte (or `src.len`).
fn skipWsAndComments(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len) {
            if (src[i + 1] == '/') {
                while (i < src.len and src[i] != '\n') i += 1;
                continue;
            }
            if (src[i + 1] == '*') {
                i += 2;
                while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
                i = @min(src.len, i + 2);
                continue;
            }
        }
        break;
    }
    return i;
}

// ─────────────────────────────────────────────────────────────────────
// Transform A — delete a top-level key (used for "assets")
// ─────────────────────────────────────────────────────────────────────

/// Delete the entire line(s) of a top-level key entry, including its
/// value and the surrounding comma. Returns a new owned buffer, or
/// `null` if the key was not found.
///
/// Trailing-comma policy: if the deleted entry was followed by a `,`
/// we drop the comma along with the entry. If it was the LAST entry
/// (no trailing comma), we drop the preceding comma instead — failing
/// to do that would leave the previous sibling with a now-illegal
/// trailing comma. The hunt-back walks past whitespace + `/* */` block
/// comments + `//` line comments to find a `,` and rewinds to just
/// before it.
fn deleteTopLevelKey(arena: std.mem.Allocator, src: []const u8, key: []const u8) ?[]u8 {
    const loc = findTopLevelKey(src, key) orelse return null;

    var cut_start: usize = loc.line_start;
    var cut_end: usize = loc.value_end;

    if (loc.comma_after) |c| {
        // Has trailing comma — eat from line start through end-of-line
        // after the comma.
        cut_end = c + 1;
        // Extend to end-of-line so we delete the entire visual line.
        while (cut_end < src.len and src[cut_end] != '\n') cut_end += 1;
        if (cut_end < src.len and src[cut_end] == '\n') cut_end += 1;
    } else {
        // Last entry — rewind cut_start to *before* the preceding `,`
        // so the previous sibling no longer has a trailing comma.
        var p: isize = @intCast(loc.line_start);
        p -= 1;
        while (p >= 0) : (p -= 1) {
            const c = src[@intCast(p)];
            if (c == ' ' or c == '\t' or c == '\r') continue;
            if (c == '\n') {
                // We just stepped into the end of the preceding line.
                // If that line is a pure `//` line-comment (only
                // whitespace before the `//`), skip the entire line so
                // the comment text isn't interpreted as code. The next
                // outer `p -= 1` will land us on the `\n` of the line
                // before that.
                const newline_idx: usize = @intCast(p);
                // Find the start of this line (the one whose `\n` we
                // are sitting on).
                var ls: usize = newline_idx;
                while (ls > 0 and src[ls - 1] != '\n') ls -= 1;
                // Scan from `ls` looking for `//` after only whitespace.
                var s: usize = ls;
                while (s < newline_idx and (src[s] == ' ' or src[s] == '\t')) s += 1;
                if (s + 1 < newline_idx and src[s] == '/' and src[s + 1] == '/') {
                    // Jump to just before the line start; outer step
                    // moves us one further (onto the prior `\n`).
                    p = @as(isize, @intCast(ls));
                    // After `continue` the for-loop runs `p -= 1`, so
                    // we want p such that p-1 lands on the byte just
                    // before `ls`. That means p = ls.
                }
                continue;
            }
            if (c == '/' and p > 0 and src[@intCast(p - 1)] == '*') {
                // Walk back through a block comment. On entry `p` is at
                // the `/` of `*/`. After this block the next outer
                // iteration's `p -= 1` must land us on the byte BEFORE
                // the `/` of `/*` — i.e. we want `p` (post-decrement) to
                // be `(index of /*-slash) - 1`. The inner loop ends with
                // `p` at the `*` of `/*`, so step one further back to
                // the `/` and let the outer step take us past it.
                p -= 2;
                while (p >= 1 and !(src[@intCast(p - 1)] == '/' and src[@intCast(p)] == '*')) p -= 1;
                if (p >= 1) p -= 1;
                continue;
            }
            if (c == ',') {
                cut_start = @intCast(p);
                break;
            }
            break; // no preceding comma — this is the only key
        }
        // Extend cut_end to end-of-line.
        while (cut_end < src.len and src[cut_end] != '\n') cut_end += 1;
        if (cut_end < src.len and src[cut_end] == '\n') cut_end += 1;
    }

    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena, src[0..cut_start]) catch return null;
    out.appendSlice(arena, src[cut_end..]) catch return null;
    return out.toOwnedSlice(arena) catch null;
}

// ─────────────────────────────────────────────────────────────────────
// Transform B — rename a top-level key (used for "entities" → "children")
// ─────────────────────────────────────────────────────────────────────

fn renameTopLevelKey(
    arena: std.mem.Allocator,
    src: []const u8,
    old: []const u8,
    new: []const u8,
) ?[]u8 {
    const loc = findTopLevelKey(src, old) orelse return null;
    // The "key" bytes between the quotes:
    //   key_start = position of opening `"`
    //   key_end   = one past closing `"`
    // The unquoted key occupies key_start+1 .. key_end-1.
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena, src[0 .. loc.key_start + 1]) catch return null;
    out.appendSlice(arena, new) catch return null;
    out.appendSlice(arena, src[loc.key_end - 1 ..]) catch return null;
    return out.toOwnedSlice(arena) catch null;
}

// ─────────────────────────────────────────────────────────────────────
// Transform C — lift `"root": { ... }` wrapper to top level
// ─────────────────────────────────────────────────────────────────────

/// Lift the contents of a top-level `"root": { ... }` object up to
/// the file's top level and de-indent each inner line by four spaces.
///
/// The shape we expect:
/// ```jsonc
/// {
///   "name": "main",
///   "root": {
///     "children": [ ... ]
///   }
/// }
/// ```
/// becomes:
/// ```jsonc
/// {
///   "name": "main",
///   "children": [ ... ]
/// }
/// ```
///
/// Implementation strategy:
///   1. Find the `"root"` key entry via `findTopLevelKey`.
///   2. The value bytes (between the inner `{` and matching `}`) are
///      the new top-level entries.
///   3. Splice: replace `"root": { …inner… }` with `…inner_dedented…`.
///   4. If `"root"` had a trailing comma after `}`, drop it iff the
///      lifted entries already end on `}` of the outer object.
fn liftTopLevelRoot(arena: std.mem.Allocator, src: []const u8) ?[]u8 {
    const loc = findTopLevelKey(src, "root") orelse return null;

    // The value must be an object — caller already checked via the
    // parsed JSON, but defend here in case of weirdness.
    if (loc.value_start >= src.len or src[loc.value_start] != '{') return null;
    // value_end points to one past the matching `}` of the value.
    const inner_open = loc.value_start; // byte at `{`
    const inner_close = loc.value_end - 1; // byte at `}`
    if (inner_close <= inner_open or src[inner_close] != '}') return null;

    // The amount we dedent each inner line by is the indent of the
    // `"root":` line itself — that puts every inner line at the same
    // column as `"root"` was, i.e. at sibling level with `"name"` etc.
    const outer_indent = loc.key_start - loc.line_start;

    // Inner body lives between the bytes just after `{` and just
    // before `}`.
    const inner_body = src[inner_open + 1 .. inner_close];

    // Trim a leading `\n` from inner_body so the lifted content starts
    // on its own line (the `\n` after `{` is no longer needed since
    // we're removing the `{`).
    var body = inner_body;
    if (body.len > 0 and body[0] == '\n') body = body[1..];

    // The closing `}` of the inner object was preceded by an indent
    // line like "    " (the outer-indent run). Strip that trailing
    // whitespace-only run so we don't emit a blank-ish line where the
    // close brace used to sit.
    if (body.len > 0 and body[body.len - 1] != '\n') {
        var t: usize = body.len;
        while (t > 0 and (body[t - 1] == ' ' or body[t - 1] == '\t')) t -= 1;
        body = body[0..t];
    }
    // After the trim above, `body` typically ends in `\n` (the newline
    // that separated the last inner entry from the close brace's
    // indent). Drop that final newline too — the splice_end below
    // starts at the close brace's `}` which is followed by its own
    // newline; keeping both would inject a blank line where the close
    // brace used to sit.
    if (body.len > 0 and body[body.len - 1] == '\n') body = body[0 .. body.len - 1];

    var dedented: std.ArrayList(u8) = .empty;
    dedentBy(arena, &dedented, body, outer_indent) catch return null;

    // Splice from the `"root":` line's indent run (line_start) through
    // the `}` of root's value (and the trailing comma if any). When the
    // `"root"` entry HAD a trailing comma (i.e. it is NOT the last key
    // of the outer object), we must re-emit that comma after the lifted
    // body — otherwise the last lifted entry runs into the next sibling
    // with no separator, producing invalid JSON. We append the comma to
    // the dedented body so it lands on the same line as the last inner
    // entry: `"children": []` becomes `"children": [],`.
    const splice_start: usize = loc.line_start;
    var splice_end: usize = loc.value_end;
    if (loc.comma_after) |c| {
        splice_end = c + 1;
        dedented.append(arena, ',') catch return null;
    }

    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena, src[0..splice_start]) catch return null;
    out.appendSlice(arena, dedented.items) catch return null;
    out.appendSlice(arena, src[splice_end..]) catch return null;
    return out.toOwnedSlice(arena) catch null;
}

/// Append `body` to `out`, removing up to `unit` leading spaces from
/// every line. Preserves blank lines as-is so authors don't lose
/// vertical structure.
fn dedentBy(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: []const u8,
    unit: usize,
) !void {
    var i: usize = 0;
    while (i < body.len) {
        // Strip up to `unit` leading spaces.
        var stripped: usize = 0;
        while (stripped < unit and i < body.len and body[i] == ' ') {
            stripped += 1;
            i += 1;
        }
        // Copy the rest of the line up to and including `\n`.
        while (i < body.len) {
            try out.append(arena, body[i]);
            if (body[i] == '\n') {
                i += 1;
                break;
            }
            i += 1;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Transform D — rename `"components"` → `"overrides"` on prefab refs
// ─────────────────────────────────────────────────────────────────────

/// Walk the parsed tree; find the first object that has *both* a
/// `"prefab"` (string) sibling and a `"components"` sibling. Locate
/// that `"components"` key in the raw bytes and rename it in place.
/// Returns the edited buffer, or `null` if no such object exists.
/// Callers loop on this so each renaming step works against a freshly
/// re-parsed tree (byte offsets shift after each edit).
fn renameOneComponentsOnRef(
    arena: std.mem.Allocator,
    src: []const u8,
    parsed_value: std.json.Value,
) !?[]u8 {
    // Walk parsed JSON to determine WHETHER a target exists (cheap,
    // exact). Then walk the raw bytes to locate it.
    if (!treeHasComponentsOnRef(parsed_value)) return null;
    return findAndRenameComponentsOnRef(arena, src);
}

fn treeHasComponentsOnRef(value: std.json.Value) bool {
    switch (value) {
        .object => |obj| {
            const has_prefab = blk: {
                const v = obj.get("prefab") orelse break :blk false;
                break :blk v == .string;
            };
            const has_components = obj.get("components") != null;
            if (has_prefab and has_components) return true;
            var it = obj.iterator();
            while (it.next()) |kv| {
                if (treeHasComponentsOnRef(kv.value_ptr.*)) return true;
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (treeHasComponentsOnRef(item)) return true;
            }
        },
        else => {},
    }
    return false;
}

/// Byte-level walker: locate the first object literal `{ ... }` that
/// contains both a `"prefab"` (string-valued) and a `"components"`
/// sibling key, and return the buffer with that `"components"` key
/// renamed to `"overrides"`.
fn findAndRenameComponentsOnRef(arena: std.mem.Allocator, src: []const u8) ?[]u8 {
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == '"') {
            i = findStringEnd(src, i);
            continue;
        }
        if (src[i] == '/' and i + 1 < src.len) {
            if (src[i + 1] == '/') {
                while (i < src.len and src[i] != '\n') i += 1;
                continue;
            }
            if (src[i + 1] == '*') {
                i += 2;
                while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
                i = @min(src.len, i + 2);
                continue;
            }
        }
        if (src[i] == '{') {
            const obj_end = skipContainer(src, i);
            if (objectHasPrefabStringAndComponents(src, i, obj_end)) |components_key_loc| {
                var out: std.ArrayList(u8) = .empty;
                out.appendSlice(arena, src[0 .. components_key_loc + 1]) catch return null;
                out.appendSlice(arena, "overrides") catch return null;
                out.appendSlice(arena, src[components_key_loc + 1 + "components".len ..]) catch return null;
                return out.toOwnedSlice(arena) catch null;
            }
            i += 1;
            continue;
        }
        i += 1;
    }
    return null;
}

/// Scan one object literal (delimited by `[start_brace, end_one_past)`)
/// for sibling keys `"prefab"` (string-valued) and `"components"`. If
/// both are present, return the byte index of the opening `"` of the
/// `"components"` key. Skips into nested `{...}` and `[...]` so they
/// don't contaminate the sibling check.
fn objectHasPrefabStringAndComponents(src: []const u8, start_brace: usize, end_one_past: usize) ?usize {
    var i = start_brace + 1; // past `{`
    var prefab_is_string = false;
    var components_pos: ?usize = null;

    while (i < end_one_past) {
        i = skipWsAndComments(src, i);
        if (i >= end_one_past) break;
        if (src[i] == '}') break;
        if (src[i] != '"') {
            // Malformed for our purposes; bail.
            return null;
        }
        const k_start = i;
        const k_end = findStringEnd(src, k_start);
        const key = src[k_start + 1 .. k_end - 1];
        var j = skipWsAndComments(src, k_end);
        if (j >= end_one_past or src[j] != ':') return null;
        j += 1;
        j = skipWsAndComments(src, j);
        const v_start = j;
        const v_end = skipValue(src, v_start);

        if (std.mem.eql(u8, key, "prefab")) {
            if (v_start < src.len and src[v_start] == '"') prefab_is_string = true;
        } else if (std.mem.eql(u8, key, "components")) {
            components_pos = k_start;
        }

        // Skip past the value and optional trailing comma.
        var k = skipWsAndComments(src, v_end);
        if (k < end_one_past and src[k] == ',') k += 1;
        i = k;
    }

    if (prefab_is_string and components_pos != null) return components_pos;
    return null;
}

// ─────────────────────────────────────────────────────────────────────
// Transform E (RFC #596) — lift `overrides` wrapper on prefab refs
// ─────────────────────────────────────────────────────────────────────

/// `{prefab: "x", overrides: {Position: {...}, Image: {...}}}` →
/// `{prefab: "x", Position: {...}, Image: {...}}`.
///
/// Top-down driver: locate the first object that has both `prefab` and
/// `overrides`; rewrite its bytes by splicing out the wrapping key/value
/// and de-indenting the contents one level. Loops until no candidates
/// remain (each rewrite invalidates byte offsets).
fn liftOneOverridesBlock(
    arena: std.mem.Allocator,
    src: []const u8,
    parsed_value: std.json.Value,
) !?[]u8 {
    if (!treeHasWrapperOnRef(parsed_value, "overrides")) return null;
    return findAndLiftWrapper(arena, src, .{ .wrapper = "overrides", .require_sibling_prefab = true });
}

// ─────────────────────────────────────────────────────────────────────
// Transform F (RFC #596) — lift inline `components` wrapper
// ─────────────────────────────────────────────────────────────────────

/// `{components: {X, Y}, ...}` → `{X, Y, ...}`. Matches objects that
/// have a `components` key but NOT a `prefab` sibling — that case is
/// handled by transform 4 (which renames it to `overrides`) and then by
/// transform 5 (which lifts the `overrides` block). The "no prefab"
/// filter prevents this pass from re-lifting what transform 5 already
/// took care of.
fn liftOneComponentsBlock(
    arena: std.mem.Allocator,
    src: []const u8,
    parsed_value: std.json.Value,
) !?[]u8 {
    if (!treeHasInlineComponentsWrapper(parsed_value)) return null;
    return findAndLiftWrapper(arena, src, .{ .wrapper = "components", .require_sibling_prefab = false });
}

fn treeHasWrapperOnRef(value: std.json.Value, wrapper: []const u8) bool {
    switch (value) {
        .object => |obj| {
            const has_prefab = blk: {
                const v = obj.get("prefab") orelse break :blk false;
                break :blk v == .string;
            };
            if (has_prefab) {
                if (obj.get(wrapper)) |wv| {
                    if (wv == .object) return true;
                }
            }
            var it = obj.iterator();
            while (it.next()) |kv| {
                if (treeHasWrapperOnRef(kv.value_ptr.*, wrapper)) return true;
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (treeHasWrapperOnRef(item, wrapper)) return true;
            }
        },
        else => {},
    }
    return false;
}

fn treeHasInlineComponentsWrapper(value: std.json.Value) bool {
    switch (value) {
        .object => |obj| {
            const has_prefab = obj.get("prefab") != null;
            if (!has_prefab) {
                if (obj.get("components")) |cv| {
                    if (cv == .object) return true;
                }
            }
            var it = obj.iterator();
            while (it.next()) |kv| {
                if (treeHasInlineComponentsWrapper(kv.value_ptr.*)) return true;
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (treeHasInlineComponentsWrapper(item)) return true;
            }
        },
        else => {},
    }
    return false;
}

const WrapperSpec = struct {
    wrapper: []const u8,
    require_sibling_prefab: bool,
};

/// Byte-level walker shared by transforms 5 (overrides) and 6 (inline
/// components). Locate the first object literal `{ ... }` whose direct
/// children match `spec`, then lift `wrapper:`'s inner object's contents
/// to be siblings of the wrapper key.
fn findAndLiftWrapper(arena: std.mem.Allocator, src: []const u8, spec: WrapperSpec) ?[]u8 {
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == '"') {
            i = findStringEnd(src, i);
            continue;
        }
        if (src[i] == '/' and i + 1 < src.len) {
            if (src[i + 1] == '/') {
                while (i < src.len and src[i] != '\n') i += 1;
                continue;
            }
            if (src[i + 1] == '*') {
                i += 2;
                while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
                i = @min(src.len, i + 2);
                continue;
            }
        }
        if (src[i] == '{') {
            const obj_end = skipContainer(src, i);
            if (objectHasWrapper(src, i, obj_end, spec)) |key_loc| {
                if (liftWrapperAt(arena, src, i, obj_end, key_loc)) |out| return out;
            }
            i += 1;
            continue;
        }
        i += 1;
    }
    return null;
}

/// Look at the siblings inside the object delimited by `[start_brace,
/// end_one_past)`. If a wrapper-key matching `spec` exists (and the
/// optional `prefab` sibling rule is satisfied) — and its value is an
/// object — return the byte index of the wrapper key's opening `"`. The
/// scan ignores keys inside nested containers so we don't pick up
/// inherited keys like a `components` deep inside a storages array.
fn objectHasWrapper(src: []const u8, start_brace: usize, end_one_past: usize, spec: WrapperSpec) ?usize {
    var i = start_brace + 1;
    var prefab_is_string = false;
    var wrapper_pos: ?usize = null;

    while (i < end_one_past) {
        i = skipWsAndComments(src, i);
        if (i >= end_one_past) break;
        if (src[i] == '}') break;
        if (src[i] != '"') return null;
        const k_start = i;
        const k_end = findStringEnd(src, k_start);
        const key = src[k_start + 1 .. k_end - 1];
        var j = skipWsAndComments(src, k_end);
        if (j >= end_one_past or src[j] != ':') return null;
        j += 1;
        j = skipWsAndComments(src, j);
        const v_start = j;
        const v_end = skipValue(src, v_start);

        if (std.mem.eql(u8, key, "prefab")) {
            if (v_start < src.len and src[v_start] == '"') prefab_is_string = true;
        } else if (std.mem.eql(u8, key, spec.wrapper)) {
            // Wrapper must be object-valued and non-empty for a lift to
            // produce siblings. An empty object `{}` still triggers a
            // lift — the splice removes the wrapper line entirely.
            if (v_start < src.len and src[v_start] == '{') {
                wrapper_pos = k_start;
            }
        }

        var k = skipWsAndComments(src, v_end);
        if (k < end_one_past and src[k] == ',') k += 1;
        i = k;
    }

    if (wrapper_pos == null) return null;
    if (spec.require_sibling_prefab and !prefab_is_string) return null;
    if (!spec.require_sibling_prefab and prefab_is_string) return null;
    return wrapper_pos;
}

/// Splice the wrapper entry out of an object, lifting its inner-object
/// contents to be siblings. Strategy mirrors `liftTopLevelRoot`: locate
/// the wrapper-key line, dedent each line of the wrapper's value, splice
/// in the dedented body, and rebuild the trailing-comma chain so the
/// surrounding object remains valid JSON.
fn liftWrapperAt(
    arena: std.mem.Allocator,
    src: []const u8,
    start_brace: usize,
    end_one_past: usize,
    wrapper_key_start: usize,
) ?[]u8 {
    _ = end_one_past;
    // Locate full wrapper KeyLoc by re-scanning from the wrapper key.
    const k_start = wrapper_key_start;
    const k_end = findStringEnd(src, k_start);
    var j = skipWsAndComments(src, k_end);
    if (j >= src.len or src[j] != ':') return null;
    const colon = j;
    j += 1;
    j = skipWsAndComments(src, j);
    const v_start = j;
    if (v_start >= src.len or src[v_start] != '{') return null;
    const v_end = skipValue(src, v_start);
    // value_end points one past the matching `}`.
    const inner_open = v_start;
    const inner_close = v_end - 1;
    if (inner_close <= inner_open or src[inner_close] != '}') return null;

    // Locate trailing comma + line_start (same as findTopLevelKey's
    // KeyLoc structure).
    var k = skipWsAndComments(src, v_end);
    var comma_after: ?usize = null;
    if (k < src.len and src[k] == ',') {
        comma_after = k;
        k += 1;
    }
    // line_start: walk back from k_start to the previous '\n'+1, or to
    // just past the opening `{` of the containing object if there's no
    // newline in between (single-line entries like
    // `{ "prefab": "x", "overrides": { ... } }`).
    var line_start: usize = k_start;
    while (line_start > 0 and src[line_start - 1] != '\n' and line_start - 1 > start_brace) line_start -= 1;
    const has_leading_newline = line_start > 0 and src[line_start - 1] == '\n';

    _ = colon;

    // Compute dedent width: the difference between the inner body's
    // indent (its first non-empty line's leading-space count) and the
    // wrapper key's column. Both inner indent and wrapper column are
    // absolute (number of leading spaces). The dedent equals the
    // single-step increment between them (typically 4 — one level).
    // For single-line wrappers the inner body has no indent to strip.
    const wrapper_column: usize = blk: {
        if (!has_leading_newline) break :blk 0;
        var w: usize = 0;
        var p = line_start;
        while (p < k_start and src[p] == ' ') : (p += 1) w += 1;
        break :blk w;
    };
    const inner_first_indent: usize = blk: {
        if (!has_leading_newline) break :blk 0;
        // Scan inner_body for the first non-blank line's leading-space
        // run. `inner_body` defined later — re-locate the open brace.
        const inner_open_local = v_start;
        const inner_close_local = v_end - 1;
        const body_local = src[inner_open_local + 1 .. inner_close_local];
        var i: usize = 0;
        // Skip blank lines (whitespace-only + `\n`).
        while (i < body_local.len) {
            const line_start_local = i;
            while (i < body_local.len and body_local[i] != '\n') i += 1;
            const line = body_local[line_start_local..i];
            var s: usize = 0;
            while (s < line.len and (line[s] == ' ' or line[s] == '\t')) s += 1;
            if (s < line.len) break :blk s;
            if (i < body_local.len) i += 1;
        }
        break :blk wrapper_column;
    };
    const outer_indent: usize = if (inner_first_indent > wrapper_column)
        inner_first_indent - wrapper_column
    else
        0;

    const inner_body = src[inner_open + 1 .. inner_close];

    // Detect inline (single-line) wrapper: the inner body has no
    // newlines AND the wrapper's `}` is on the same line as the `{`.
    const inline_wrapper = std.mem.indexOfScalar(u8, inner_body, '\n') == null;

    var rebuilt: std.ArrayList(u8) = .empty;
    if (inline_wrapper) {
        // Trim outer whitespace from the body so we get `Position: {x:
        // 1}` rather than `   Position: {x: 1}   `.
        var body = inner_body;
        var lo: usize = 0;
        while (lo < body.len and (body[lo] == ' ' or body[lo] == '\t')) lo += 1;
        var hi: usize = body.len;
        while (hi > lo and (body[hi - 1] == ' ' or body[hi - 1] == '\t')) hi -= 1;
        body = body[lo..hi];
        if (body.len == 0) {
            // Empty `overrides: {}` — drop the wrapper entry entirely.
            return spliceDropEntry(arena, src, line_start, k_start, v_end, comma_after, has_leading_newline);
        }
        rebuilt.appendSlice(arena, body) catch return null;
    } else {
        // Multi-line wrapper. Dedent inner body by `outer_indent` and
        // splice in place of the wrapper entry.
        var body = inner_body;
        if (body.len > 0 and body[0] == '\n') body = body[1..];
        // Trim trailing whitespace + newline before the close brace.
        if (body.len > 0 and body[body.len - 1] != '\n') {
            var t: usize = body.len;
            while (t > 0 and (body[t - 1] == ' ' or body[t - 1] == '\t')) t -= 1;
            body = body[0..t];
        }
        if (body.len > 0 and body[body.len - 1] == '\n') body = body[0 .. body.len - 1];
        if (body.len == 0) {
            return spliceDropEntry(arena, src, line_start, k_start, v_end, comma_after, has_leading_newline);
        }
        dedentBy(arena, &rebuilt, body, outer_indent) catch return null;
    }

    // Splice from wrapper-line start (or just past the key in inline-
    // case) through `v_end` (which is one past wrapper's `}`).
    var splice_start: usize = line_start;
    var splice_end: usize = v_end;
    if (!has_leading_newline) {
        // Inline: keep the line intact, replace just `"wrapper": { ... }`
        splice_start = k_start;
    }
    if (comma_after) |c| {
        splice_end = c + 1;
        rebuilt.append(arena, ',') catch return null;
    }

    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena, src[0..splice_start]) catch return null;
    out.appendSlice(arena, rebuilt.items) catch return null;
    out.appendSlice(arena, src[splice_end..]) catch return null;
    return out.toOwnedSlice(arena) catch null;
}

/// Drop an entire wrapper entry (for the `overrides: {}` / `components:
/// {}` empty-block case). Handles the trailing-comma fixup so the
/// preceding sibling stays well-formed. `key_start` is the index of the
/// opening `"` of the wrapper key — used for the inline (no leading
/// newline) case where the cut start must be the key, not the line
/// start of the surrounding entity object.
fn spliceDropEntry(
    arena: std.mem.Allocator,
    src: []const u8,
    line_start: usize,
    key_start: usize,
    v_end: usize,
    comma_after: ?usize,
    has_leading_newline: bool,
) ?[]u8 {
    var cut_start: usize = if (has_leading_newline) line_start else key_start;
    var cut_end: usize = v_end;
    if (comma_after) |c| {
        // There's a trailing comma after the wrapper. Eat it (and the
        // rest of the line if we're in line-based mode).
        cut_end = c + 1;
        if (has_leading_newline) {
            while (cut_end < src.len and src[cut_end] != '\n') cut_end += 1;
            if (cut_end < src.len and src[cut_end] == '\n') cut_end += 1;
        }
    } else {
        // No trailing comma — wrapper is the LAST entry. Rewind past
        // the preceding `,` to drop the now-redundant separator on the
        // previous sibling.
        var p: isize = @intCast(cut_start);
        p -= 1;
        while (p >= 0) : (p -= 1) {
            const c = src[@intCast(p)];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') continue;
            if (c == ',') {
                cut_start = @intCast(p);
                break;
            }
            break;
        }
        if (has_leading_newline) {
            while (cut_end < src.len and src[cut_end] != '\n') cut_end += 1;
            if (cut_end < src.len and src[cut_end] == '\n') cut_end += 1;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena, src[0..cut_start]) catch return null;
    out.appendSlice(arena, src[cut_end..]) catch return null;
    return out.toOwnedSlice(arena) catch null;
}

// ─────────────────────────────────────────────────────────────────────
// Transform G (RFC #596) — top-level `name:` → `meta.name` or drop
// ─────────────────────────────────────────────────────────────────────

/// Move a top-level `name: "<X>"` field into `meta.name`. Two shapes:
///   1. `meta:` already exists — for now we just rename the `name:` key
///      to `meta.name`-style by emitting a `meta: { name: "<X>" }`
///      wrapper alongside the existing meta block (we don't merge, just
///      ensure both are valid keys — but JSON doesn't allow duplicate
///      keys, so the proper fix is to actually merge). The `has_meta`
///      branch falls back to leaving the existing meta alone and only
///      drops the bare `name:` — this is a conservative choice; the
///      audit will re-flag the divergent name on the next pass and a
///      human can hand-merge.
///   2. No `meta:` — rename the `name:` key in place to `meta`, and
///      wrap its string value `"<X>"` as `{ "name": "<X>" }`. Cheap and
///      preserves the original line structure.
fn moveNameToMeta(arena: std.mem.Allocator, src: []const u8, name_value: []const u8, has_meta: bool) ?[]u8 {
    _ = name_value;
    if (has_meta) {
        // Conservative: leave the existing `meta:` block alone (merging
        // is structurally risky to do byte-level). Just drop the bare
        // `name:` so the audit only re-fires for divergent-name files
        // that actually NEED human attention. This case is also rare
        // enough across FP / bouncing-ball that the simpler behaviour
        // is preferable to a half-correct merge. If/when we see a real
        // case in the smoke run we'll extend this.
        return deleteTopLevelKey(arena, src, "name");
    }
    // Find the `"name"` key; rewrite as `"meta": { "name": "<X>" }`.
    const loc = findTopLevelKey(src, "name") orelse return null;
    if (loc.value_start >= src.len or src[loc.value_start] != '"') return null;
    const v_end = loc.value_end; // one past the value's closing `"`
    // Re-emit:
    //   <before key_start> "meta": { "name": <orig value string> } <after v_end>
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena, src[0..loc.key_start]) catch return null;
    out.appendSlice(arena, "\"meta\": { \"name\": ") catch return null;
    out.appendSlice(arena, src[loc.value_start..v_end]) catch return null;
    out.appendSlice(arena, " }") catch return null;
    out.appendSlice(arena, src[v_end..]) catch return null;
    return out.toOwnedSlice(arena) catch null;
}

// ─────────────────────────────────────────────────────────────────────
// Transform H (RFC #596) — collapse file-level wrapping object to array
// ─────────────────────────────────────────────────────────────────────

/// File top-level is `{...}` whose only entity-bearing key is
/// `children:` (no `prefab`, no PascalCase components, no `meta`).
///
/// We conservatively REJECT collapse when the file still has a `meta:`
/// sibling: the RFC says that becomes the bundle header
/// (`[{meta:...}, ...]`), but the byte-edit shape for "lift meta out
/// of the wrapping object, emit as array's first element, then collapse
/// the rest" is materially more complex than the no-meta case. For
/// PRs in flight (FP / bouncing-ball / assembler-example) the
/// divergent-name files are rare enough that landing the meta-header
/// emission can be a follow-up — the audit catches the missing
/// collapse, the user re-runs the migrator after the follow-up lands.
/// Until then, divergent-name files end up with `{meta: ..., children:
/// [...]}` which is still RFC-#596-shape-valid (it's just a non-bundle
/// shape).
fn shouldCollapseFileToArray(value: std.json.Value) bool {
    if (value != .object) return false;
    const obj = value.object;
    const has_children = obj.get("children") != null;
    if (!has_children) return false;
    // Reject anything that adds semantic content the array form can't
    // represent: components (PascalCase keys), prefab references, meta
    // (would need a header element — out of scope here), or any other
    // structural key we don't recognise (e.g. an `include:` declared by
    // a plugin). Only `children:` on its own qualifies.
    var it = obj.iterator();
    while (it.next()) |kv| {
        const k = kv.key_ptr.*;
        if (std.mem.eql(u8, k, "children")) continue;
        return false;
    }
    return true;
}

/// Rewrite `{...children: [...]...}` to `[...]`. Pre-{ content stays as
/// header (typically: nothing, or a leading `//` file note). Between-`{`-
/// and-`"children":` content is preserved if it's comment-only — we walk
/// each line and keep any line whose only non-whitespace is a `//` or
/// `/* */` comment, dropping the lines that hold the just-dropped/just-
/// moved siblings (e.g. the empty trailing comma after `name:` got
/// removed by pass 7).
fn collapseFileToArray(arena: std.mem.Allocator, src: []const u8, parsed_value: std.json.Value) ?[]u8 {
    _ = parsed_value;
    // Find the file's outer `{` and matching `}`.
    const file_start = skipWsAndComments(src, 0);
    if (file_start >= src.len or src[file_start] != '{') return null;
    const file_end = skipContainer(src, file_start);
    if (file_end > src.len or src[file_end - 1] != '}') return null;

    // Find the `children` key.
    const loc = findTopLevelKey(src, "children") orelse return null;
    if (loc.value_start >= src.len or src[loc.value_start] != '[') return null;
    // The array literal occupies [value_start, value_end).
    const arr_start = loc.value_start;
    const arr_end = loc.value_end;

    // Leading content (BEFORE the outer `{`) — kept verbatim.
    const pre_header = src[0..file_start];

    // Footer: bytes after the outer `}` (typically a trailing newline).
    const footer = if (file_end < src.len) src[file_end..] else "";

    // Between-brace comment harvest: walk every line of src between
    // `file_start+1` and `loc.line_start` (i.e. between `{` and the
    // start-of-line of the `children:` key). If a line is whitespace-
    // only OR starts with a comment marker after only whitespace, we
    // keep it (de-indented by the outer indent). Lines containing
    // actual JSON (the now-removed/already-processed siblings, if any
    // somehow survived) get dropped — though `shouldCollapseFileToArray`
    // already gated this so there shouldn't be any.
    var harvested: std.ArrayList(u8) = .empty;
    // Skip the `{\n` byte first.
    var p: usize = file_start + 1;
    while (p < loc.line_start) {
        // Determine the start of this line.
        const line_begin = p;
        // Find the end of this line (one past `\n`, or src.len).
        var line_end: usize = p;
        while (line_end < loc.line_start and src[line_end] != '\n') line_end += 1;
        if (line_end < loc.line_start) line_end += 1; // include `\n`
        const line = src[line_begin..line_end];
        // Skip leading whitespace.
        var s: usize = 0;
        while (s < line.len and (line[s] == ' ' or line[s] == '\t')) s += 1;
        if (s == line.len) {
            // Whitespace-only line; skip.
        } else if (s + 1 < line.len and line[s] == '/' and (line[s + 1] == '/' or line[s + 1] == '*')) {
            // Comment line — keep, dedented by the outer indent
            // (matches the `[` of the array, which lives at column 0
            // post-collapse).
            // The outer indent equals the column of `"children":`.
            const outer_indent = blk: {
                var w: usize = 0;
                var q = loc.line_start;
                while (q < loc.key_start and src[q] == ' ') : (q += 1) w += 1;
                break :blk w;
            };
            var stripped: usize = 0;
            while (stripped < outer_indent and stripped < s) : (stripped += 1) {}
            harvested.appendSlice(arena, line[stripped..]) catch return null;
        } else {
            // Non-comment, non-whitespace line — predicate-gated, so
            // this shouldn't normally happen. Drop conservatively.
        }
        p = line_end;
    }
    const header = pre_header;

    // Body: dedent the array by one indent level if the inner body uses
    // a non-zero indent (the wrapping `{` added 4 spaces to every line).
    // We measure by looking at the column of `[` in the `children:`
    // line and shifting every line of the array's interior by that
    // amount minus the file's base indent (0 — top level).
    var dedent: usize = 0;
    var q: usize = loc.line_start;
    while (q < loc.key_start and src[q] == ' ') : (q += 1) dedent += 1;

    // Build dedented array.
    var body = src[arr_start..arr_end];
    var dedented: std.ArrayList(u8) = .empty;
    if (dedent == 0) {
        dedented.appendSlice(arena, body) catch return null;
    } else {
        // The first line (`[` and same-line tail) shouldn't be dedented
        // — it has no leading spaces. Subsequent lines (after each
        // `\n`) get their leading-space run trimmed by `dedent`.
        // Append the first line up to and including the first `\n`.
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            dedented.append(arena, body[i]) catch return null;
            if (body[i] == '\n') {
                i += 1;
                break;
            }
        }
        // Remaining lines.
        while (i < body.len) {
            var stripped: usize = 0;
            while (stripped < dedent and i < body.len and body[i] == ' ') {
                stripped += 1;
                i += 1;
            }
            while (i < body.len) {
                dedented.append(arena, body[i]) catch return null;
                if (body[i] == '\n') {
                    i += 1;
                    break;
                }
                i += 1;
            }
        }
        _ = &body;
    }

    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena, header) catch return null;
    out.appendSlice(arena, harvested.items) catch return null;
    out.appendSlice(arena, dedented.items) catch return null;
    out.appendSlice(arena, footer) catch return null;
    return out.toOwnedSlice(arena) catch null;
}

// ─────────────────────────────────────────────────────────────────────
// JSONC → JSON pre-stripper (copied from audit.zig — keeps this module
// self-contained, and the two stay in sync via the shared tests).
// ─────────────────────────────────────────────────────────────────────

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
                i += 2;
                while (i < src.len and src[i] != '\n') i += 1;
                continue;
            }
            if (src[i + 1] == '*') {
                i += 2;
                while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
                i = @min(src.len, i + 2);
                continue;
            }
        }
        if (c == ',') {
            var j = i + 1;
            while (j < src.len) : (j += 1) {
                const cc = src[j];
                if (cc == ' ' or cc == '\t' or cc == '\n' or cc == '\r') continue;
                if (cc == '/' and j + 1 < src.len and (src[j + 1] == '/' or src[j + 1] == '*')) {
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

/// Run transforms 1-4 only on `src` (legacy mode — used by the existing
/// pre-RFC-#596 test suite, whose fixtures expect intermediate shapes
/// that the new transforms would further collapse).
fn applyAll(arena: std.mem.Allocator, src: []const u8) ![]u8 {
    return applyImpl(arena, src, "main", false);
}

/// Run every transform, including the RFC #596 set. Used by the new
/// transform-5-through-8 specs.
fn applyAllFull(arena: std.mem.Allocator, src: []const u8, basename: []const u8) ![]u8 {
    return applyImpl(arena, src, basename, true);
}

fn applyImpl(arena: std.mem.Allocator, src: []const u8, basename: []const u8, rfc596: bool) ![]u8 {
    const stripped = try stripJsoncToJson(arena, src);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, stripped, .{});
    defer parsed.deinit();
    var counts = FileCounts{};
    var xrefs: std.StringHashMap(void) = .init(arena);
    const ctx = TransformCtx{
        .basename = basename,
        .xrefs = &xrefs,
        .rel_path = "<test>",
        .rfc596 = rfc596,
    };
    return try transformBytes(arena, src, parsed.value, ctx, &counts);
}

/// Convenience for tests — runs `applyAll` (legacy 1-4 only) against an
/// arena so call sites don't have to track every intermediate
/// allocation produced by the byte-level edit pipeline. Returns the
/// final transformed buffer (lives inside the arena).
fn applyAllArena(arena: *std.heap.ArenaAllocator, src: []const u8) ![]const u8 {
    return try applyAll(arena.allocator(), src);
}

fn applyAllArenaFull(arena: *std.heap.ArenaAllocator, src: []const u8, basename: []const u8) ![]const u8 {
    return try applyAllFull(arena.allocator(), src, basename);
}

pub const TransformRootWrapperSpec = struct {
    pub const lifts_simple_wrapper = struct {
        test "lifts `\"root\": { \"children\": [] }` and de-indents" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"root\": {\n" ++
                "        \"children\": []\n" ++
                "    }\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            const expected =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"children\": []\n" ++
                "}\n";
            try std.testing.expectEqualStrings(expected, out);
        }
    };

    pub const preserves_comments = struct {
        test "comments on lifted children survive" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    // top-level note stays put\n" ++
                "    \"root\": {\n" ++
                "        // inner note moves up one indent\n" ++
                "        \"children\": [\n" ++
                "            { \"prefab\": \"x\" } // inline note\n" ++
                "        ]\n" ++
                "    }\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            // The three comments must all still appear, verbatim.
            try std.testing.expect(std.mem.indexOf(u8, out, "// top-level note stays put") != null);
            try std.testing.expect(std.mem.indexOf(u8, out, "// inner note moves up one indent") != null);
            try std.testing.expect(std.mem.indexOf(u8, out, "// inline note") != null);
            // And the `"root"` wrapper is gone.
            try std.testing.expect(std.mem.indexOf(u8, out, "\"root\"") == null);
        }
    };

    pub const root_in_middle_of_metadata = struct {
        // Regression for cursor[bot] finding: when `"root"` is not the
        // LAST top-level key (i.e. has a trailing comma) the lift used to
        // consume the comma but never re-emit it, producing invalid JSON
        // like `..."children": []"metadata": "x"...`.
        test "root in middle of metadata keys produces valid JSON" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"root\": {\n" ++
                "        \"children\": []\n" ++
                "    },\n" ++
                "    \"metadata\": \"x\"\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            // Must round-trip through the JSON parser.
            const stripped = try stripJsoncToJson(arena.allocator(), out);
            var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
            defer parsed.deinit();
            const obj = parsed.value.object;
            try std.testing.expect(obj.get("root") == null);
            try std.testing.expect(obj.get("children") != null);
            try std.testing.expectEqualStrings("main", obj.get("name").?.string);
            try std.testing.expectEqualStrings("x", obj.get("metadata").?.string);
        }

        test "root in middle with trailing comma on its own line" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"root\": {\n" ++
                "        \"children\": []\n" ++
                "    }\n" ++
                "    ,\n" ++
                "    \"metadata\": \"x\"\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            const stripped = try stripJsoncToJson(arena.allocator(), out);
            var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
            defer parsed.deinit();
            const obj = parsed.value.object;
            try std.testing.expect(obj.get("root") == null);
            try std.testing.expect(obj.get("children") != null);
            try std.testing.expectEqualStrings("x", obj.get("metadata").?.string);
        }

        // Adversarial: root not last, a `//` line comment between two
        // outer-level keys, and a `/* */` block comment elsewhere. The
        // whole file must round-trip through the JSON parser after the
        // lift.
        test "root in middle with mixed line + block comments around" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    // line note between name and root\n" ++
                "    \"root\": {\n" ++
                "        /* inside-root block note */\n" ++
                "        \"children\": []\n" ++
                "    },\n" ++
                "    \"metadata\": \"x\"\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            const stripped = try stripJsoncToJson(arena.allocator(), out);
            var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
            defer parsed.deinit();
            const obj = parsed.value.object;
            try std.testing.expect(obj.get("root") == null);
            try std.testing.expect(obj.get("children") != null);
            try std.testing.expectEqualStrings("main", obj.get("name").?.string);
            try std.testing.expectEqualStrings("x", obj.get("metadata").?.string);
        }

        test "root in middle with line comment between `}` and next key" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"root\": {\n" ++
                "        \"children\": []\n" ++
                "    }, // close root\n" ++
                "    \"metadata\": \"x\"\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            const stripped = try stripJsoncToJson(arena.allocator(), out);
            var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
            defer parsed.deinit();
            const obj = parsed.value.object;
            try std.testing.expect(obj.get("root") == null);
            try std.testing.expect(obj.get("children") != null);
            try std.testing.expectEqualStrings("x", obj.get("metadata").?.string);
        }
    };
};

pub const DeleteTopLevelKeyBlockCommentSpec = struct {
    // Regression for cursor[bot] finding: the backward walk that looks
    // for the preceding comma when the target key is the LAST entry used
    // to land one byte too late after skipping a `/* ... */` block. The
    // outer `p -= 1` from the for-loop then put `p` on the `/` of `/*`,
    // which broke the walk early and left the preceding sibling with a
    // dangling `,` — producing invalid JSON.
    test "deletes last key preceded by a block comment" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    /* trailing note */\n" ++
            "    \"assets\": [\"a\"]\n" ++
            "}\n";
        const out = try applyAllArena(&arena, src);
        // Pre-fix the backward walk lost the preceding `,` because it
        // landed on the `/` of `/*` and broke. The trailing comma after
        // `"main"` MUST be removed — otherwise the raw .jsonc parses as
        // {"name":"main",} which is illegal JSON (the JSONC-stripper
        // happens to forgive trailing commas, but a strict reader does
        // not).
        try std.testing.expect(std.mem.indexOf(u8, out, "\"assets\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"main\",") == null);
        // And it must round-trip through the JSON parser too.
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("main", parsed.value.object.get("name").?.string);
    }

    // Regression for cursor[bot] finding: the backward walk that looks
    // for the preceding comma when the target key is the LAST entry
    // claims (per its doc) to skip "whitespace + comments", but only
    // handled `/* ... */` block comments — never `//` line comments. A
    // `//` comment sitting on its own line between the preceding comma
    // and the deleted key made the walk hit the comment text and break
    // before finding the comma — leaving a dangling trailing comma on
    // the preceding sibling and producing invalid strict JSON.
    test "deletes last key preceded by a `//` line comment" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    // trailing note\n" ++
            "    \"assets\": [\"a\"]\n" ++
            "}\n";
        const out = try applyAllArena(&arena, src);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"assets\"") == null);
        // Trailing comma on `"main"` must be gone.
        try std.testing.expect(std.mem.indexOf(u8, out, "\"main\",") == null);
        // Round-trip through the JSON parser to be safe.
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("main", parsed.value.object.get("name").?.string);
    }

    // Adversarial: both kinds of comments interleaved before the
    // deleted last-key.
    test "deletes last key preceded by mixed `//` and `/* */` comments" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    // line note\n" ++
            "    /* block note */\n" ++
            "    \"assets\": [\"a\"]\n" ++
            "}\n";
        const out = try applyAllArena(&arena, src);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"assets\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"main\",") == null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("main", parsed.value.object.get("name").?.string);
    }
};

pub const TransformEntitiesRenameSpec = struct {
    test "top-level `entities` becomes `children`" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    \"entities\": [\n" ++
            "        { \"prefab\": \"x\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArena(&arena, src);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"children\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"entities\"") == null);
    }
};

pub const TransformComponentsOnRefSpec = struct {
    pub const renames_when_prefab_sibling = struct {
        test "`components` next to `prefab` becomes `overrides`" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"children\": [\n" ++
                "        { \"prefab\": \"x\", \"components\": { \"Position\": { \"x\": 1 } } }\n" ++
                "    ]\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\"") != null);
            // No more `"components"` key (the value's nested keys
            // happen not to use the word, so a substring search is OK).
            try std.testing.expect(std.mem.indexOf(u8, out, "\"components\"") == null);
        }
    };

    pub const leaves_inline_components_alone = struct {
        test "inline `components` without `prefab` is the canonical shape and stays" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"children\": [\n" ++
                "        { \"components\": { \"Position\": { \"x\": 1 } } }\n" ++
                "    ]\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            try std.testing.expect(std.mem.indexOf(u8, out, "\"components\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\"") == null);
        }
    };
};

pub const TransformAssetsDeleteSpec = struct {
    pub const deletes_with_trailing_comma = struct {
        test "drops `\"assets\": [...]` line entirely" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"assets\": [\"a\", \"b\"],\n" ++
                "    \"children\": []\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            try std.testing.expect(std.mem.indexOf(u8, out, "\"assets\"") == null);
            try std.testing.expect(std.mem.indexOf(u8, out, "\"children\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, out, "\"name\"") != null);
        }
    };

    pub const deletes_when_last_key = struct {
        test "drops preceding comma when `assets` is the last entry" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"assets\": [\"a\"]\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            // Must still parse as valid JSON (no dangling comma).
            const stripped = try stripJsoncToJson(arena.allocator(), out);
            var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
            defer parsed.deinit();
            try std.testing.expect(parsed.value.object.get("assets") == null);
            try std.testing.expectEqualStrings("main", parsed.value.object.get("name").?.string);
        }
    };
};

pub const IdempotencySpec = struct {
    test "running the migrator twice produces the same bytes" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    \"assets\": [\"a\"],\n" ++
            "    \"root\": {\n" ++
            "        \"children\": [\n" ++
            "            { \"prefab\": \"x\", \"components\": { \"Position\": { \"x\": 1 } } }\n" ++
            "        ]\n" ++
            "    }\n" ++
            "}\n";
        const once = try applyAllArena(&arena, src);
        const twice = try applyAllArena(&arena, once);
        try std.testing.expectEqualStrings(once, twice);
    }
};

pub const MixedFileSpec = struct {
    test "all four transforms in one file" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    \"assets\": [\"a\"],\n" ++
            "    \"root\": {\n" ++
            "        \"entities\": [\n" ++
            "            { \"prefab\": \"x\", \"components\": { \"Position\": { \"x\": 1 } } }\n" ++
            "        ]\n" ++
            "    }\n" ++
            "}\n";
        const out = try applyAllArena(&arena, src);

        // Must parse + have the expected post-migration shape.
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expect(obj.get("assets") == null);
        try std.testing.expect(obj.get("root") == null);
        try std.testing.expect(obj.get("entities") == null);
        try std.testing.expect(obj.get("children") != null);
        const child0 = obj.get("children").?.array.items[0].object;
        try std.testing.expect(child0.get("components") == null);
        try std.testing.expect(child0.get("overrides") != null);
    }
};

// ─────────────────────────────────────────────────────────────────────
// RFC #596 — Transform 5: lift `overrides` block on prefab refs
// ─────────────────────────────────────────────────────────────────────

pub const TransformLiftOverridesSpec = struct {
    test "single-line overrides on a prefab ref" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "[\n" ++
            "    { \"prefab\": \"rabbit\", \"overrides\": { \"Position\": { \"x\": 400, \"y\": 0 } } }\n" ++
            "]\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"prefab\": \"rabbit\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"Position\"") != null);
        // Must parse cleanly.
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        const entry = parsed.value.array.items[0].object;
        try std.testing.expect(entry.get("overrides") == null);
        try std.testing.expectEqualStrings("rabbit", entry.get("prefab").?.string);
        try std.testing.expect(entry.get("Position") != null);
    }

    test "multi-line overrides on a prefab ref preserves comments" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "[\n" ++
            "    {\n" ++
            "        \"prefab\": \"kitchen\",\n" ++
            "        // overrides block has an inner comment\n" ++
            "        \"overrides\": {\n" ++
            "            // explanatory note\n" ++
            "            \"Position\": { \"x\": 156, \"y\": 93 }\n" ++
            "        }\n" ++
            "    }\n" ++
            "]\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "// explanatory note") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"Position\"") != null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        const entry = parsed.value.array.items[0].object;
        try std.testing.expect(entry.get("Position") != null);
    }

    test "empty overrides block is dropped entirely" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "[\n" ++
            "    { \"prefab\": \"x\", \"overrides\": {} }\n" ++
            "]\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\"") == null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        const entry = parsed.value.array.items[0].object;
        try std.testing.expectEqualStrings("x", entry.get("prefab").?.string);
        try std.testing.expect(entry.get("overrides") == null);
    }

    test "multiple overrides across siblings all lifted" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "[\n" ++
            "    { \"prefab\": \"a\", \"overrides\": { \"Position\": { \"x\": 1 } } },\n" ++
            "    { \"prefab\": \"b\", \"overrides\": { \"Position\": { \"x\": 2 } } },\n" ++
            "    { \"prefab\": \"c\", \"overrides\": { \"Position\": { \"x\": 3 } } }\n" ++
            "]\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\"") == null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        const items = parsed.value.array.items;
        try std.testing.expectEqual(@as(usize, 3), items.len);
        for (items) |it| {
            try std.testing.expect(it.object.get("overrides") == null);
            try std.testing.expect(it.object.get("Position") != null);
        }
    }
};

// ─────────────────────────────────────────────────────────────────────
// RFC #596 — Transform 6: lift inline `components` block
// ─────────────────────────────────────────────────────────────────────

pub const TransformLiftComponentsSpec = struct {
    test "single-line inline components" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "[\n" ++
            "    { \"components\": { \"BuildIntent\": { \"room_type\": \"stair_room\" } } }\n" ++
            "]\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        try std.testing.expect(std.mem.indexOf(u8, out, "\"components\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"BuildIntent\"") != null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        const entry = parsed.value.array.items[0].object;
        try std.testing.expect(entry.get("components") == null);
        try std.testing.expect(entry.get("BuildIntent") != null);
    }

    test "multi-line inline components with multiple PascalCase keys" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"components\": {\n" ++
            "        \"Workstation\": { \"kind\": \"kitchen\" },\n" ++
            "        \"Image\": { \"sprite\": \"kitchen\" },\n" ++
            "        \"Position\": { \"x\": 100, \"y\": 50 }\n" ++
            "    }\n" ++
            "}\n";
        // Use a basename other than "main" so transform 7+8 don't apply.
        const out = try applyAllArenaFull(&arena, src, "no_collapse_basename_xyz");
        try std.testing.expect(std.mem.indexOf(u8, out, "\"components\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"Workstation\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"Image\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"Position\"") != null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expect(obj.get("components") == null);
        try std.testing.expect(obj.get("Workstation") != null);
        try std.testing.expect(obj.get("Image") != null);
        try std.testing.expect(obj.get("Position") != null);
    }

    test "components NOT lifted when prefab sibling exists (pass 4 + 5 handle it)" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        // This is the legacy "components-on-ref" case: pass 4 renames
        // `components` to `overrides`, then pass 5 lifts that. The
        // result should not have either `components` OR `overrides`,
        // and Position should be a direct sibling of prefab.
        const src =
            "[\n" ++
            "    { \"prefab\": \"x\", \"components\": { \"Position\": { \"x\": 1 } } }\n" ++
            "]\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        try std.testing.expect(std.mem.indexOf(u8, out, "\"components\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\"") == null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        const entry = parsed.value.array.items[0].object;
        try std.testing.expectEqualStrings("x", entry.get("prefab").?.string);
        try std.testing.expect(entry.get("Position") != null);
    }

    test "deep-nested inline components (storages array) lifted recursively" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        // Mimics the butcher_workstation shape: outer inline components,
        // inner storage entries each with their own inline components.
        const src =
            "{\n" ++
            "    \"components\": {\n" ++
            "        \"Workstation\": {\n" ++
            "            \"storages\": [\n" ++
            "                { \"components\": { \"Position\": { \"x\": -62 }, \"Eis\": {} } },\n" ++
            "                { \"components\": { \"Position\": { \"x\": -34 }, \"Eis\": {} } }\n" ++
            "            ]\n" ++
            "        }\n" ++
            "    }\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "no_collapse_xyz");
        // No more `components` wrappers anywhere.
        try std.testing.expect(std.mem.indexOf(u8, out, "\"components\"") == null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expect(obj.get("Workstation") != null);
        const storages = obj.get("Workstation").?.object.get("storages").?.array;
        for (storages.items) |slot| {
            try std.testing.expect(slot.object.get("components") == null);
            try std.testing.expect(slot.object.get("Position") != null);
            try std.testing.expect(slot.object.get("Eis") != null);
        }
    }
};

// ─────────────────────────────────────────────────────────────────────
// RFC #596 — Transform 7: top-level `name:` → `meta.name` or drop
// ─────────────────────────────────────────────────────────────────────

pub const TransformNameFieldSpec = struct {
    test "name matching basename is dropped" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        // basename "colony" matches name "colony" — should drop.
        // We pick a structure where pass 8 will ALSO fire (children-only
        // wrapping object) to assert both behaviors integrate.
        const src =
            "{\n" ++
            "    \"name\": \"colony\",\n" ++
            "    \"children\": [\n" ++
            "        { \"prefab\": \"x\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "colony");
        // `name:` dropped, file collapsed to array.
        try std.testing.expect(std.mem.indexOf(u8, out, "\"name\"") == null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        // Should now be a top-level array.
        try std.testing.expect(parsed.value == .array);
    }

    test "name differing from basename moves to meta.name" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        // basename "demo_scene", declared name "Production Demo" —
        // divergent. Should rewrite to `{meta: {name: "Production
        // Demo"}, ...}`.
        const src =
            "{\n" ++
            "    \"name\": \"Production Demo\",\n" ++
            "    \"children\": []\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "demo_scene");
        // `name:` no longer top-level; `meta:` block present.
        try std.testing.expect(std.mem.indexOf(u8, out, "\"meta\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "Production Demo") != null);
        // Should NOT collapse (has a meta sibling), so still an object.
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        const meta = parsed.value.object.get("meta").?.object;
        try std.testing.expectEqualStrings("Production Demo", meta.get("name").?.string);
    }

    test "no name field — pass 7 is a no-op" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"children\": [\n" ++
            "        { \"prefab\": \"x\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        // No name field; output still parseable and collapsed to array.
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
    }
};

// ─────────────────────────────────────────────────────────────────────
// RFC #596 — Transform 8: file-as-array bundle
// ─────────────────────────────────────────────────────────────────────

pub const TransformFileAsArraySpec = struct {
    test "wrapping object with only `children:` collapses to array" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"children\": [\n" ++
            "        { \"prefab\": \"a\" },\n" ++
            "        { \"prefab\": \"b\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
        try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    }

    test "wrapping object with `name:` matching basename + `children:` collapses" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    \"children\": []\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
        try std.testing.expectEqual(@as(usize, 0), parsed.value.array.items.len);
    }

    test "object with PascalCase root key does NOT collapse" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        // A true root entity (has components on it) — must NOT collapse
        // because the file IS a single root entity.
        const src =
            "{\n" ++
            "    \"Workstation\": { \"kind\": \"kitchen\" },\n" ++
            "    \"children\": [\n" ++
            "        { \"prefab\": \"slot\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "kitchen");
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        try std.testing.expect(parsed.value.object.get("Workstation") != null);
    }

    test "leading comments above wrapping object are preserved" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "// header comment\n" ++
            "// another\n" ++
            "{\n" ++
            "    \"children\": [\n" ++
            "        { \"prefab\": \"x\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "main");
        try std.testing.expect(std.mem.indexOf(u8, out, "// header comment") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "// another") != null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
    }
};

// ─────────────────────────────────────────────────────────────────────
// RFC #596 — End-to-end + idempotency
// ─────────────────────────────────────────────────────────────────────

pub const Rfc596IdempotencySpec = struct {
    test "running migrator twice on a fully migrated file is a no-op" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        // Already in the RFC-#596 final shape.
        const src =
            "[\n" ++
            "    { \"prefab\": \"a\", \"Position\": { \"x\": 1 } },\n" ++
            "    { \"prefab\": \"b\", \"Position\": { \"x\": 2 } }\n" ++
            "]\n";
        const once = try applyAllArenaFull(&arena, src, "main");
        const twice = try applyAllArenaFull(&arena, once, "main");
        try std.testing.expectEqualStrings(once, twice);
        // And running the legacy migrator on the same input is also a
        // no-op.
        try std.testing.expectEqualStrings(src, once);
    }

    test "running migrator twice on a legacy file lands at fixed point" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        // Pre-#594 shape (root wrapper + entities + components-on-ref +
        // assets) PLUS post-#594 legacy patterns (overrides wrapper,
        // inline components wrapper, divergent name).
        const src =
            "{\n" ++
            "    \"name\": \"colony\",\n" ++
            "    \"assets\": [\"a\"],\n" ++
            "    \"root\": {\n" ++
            "        \"entities\": [\n" ++
            "            { \"prefab\": \"x\", \"components\": { \"Position\": { \"x\": 1 } } },\n" ++
            "            { \"components\": { \"BuildIntent\": { \"r\": 1 } } }\n" ++
            "        ]\n" ++
            "    }\n" ++
            "}\n";
        const once = try applyAllArenaFull(&arena, src, "colony");
        const twice = try applyAllArenaFull(&arena, once, "colony");
        try std.testing.expectEqualStrings(once, twice);
    }
};

pub const Rfc596MixedFileSpec = struct {
    test "all 8 transforms in one legacy file, end-to-end" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    // file-level note\n" ++
            "    \"name\": \"colony\",\n" ++
            "    \"assets\": [\"a\"],\n" ++
            "    \"root\": {\n" ++
            "        \"entities\": [\n" ++
            "            { \"prefab\": \"x\", \"components\": { \"Position\": { \"x\": 1 } } },\n" ++
            "            { \"components\": { \"BuildIntent\": { \"r\": 1 } } }\n" ++
            "        ]\n" ++
            "    }\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "colony");

        // Comment must survive every transform.
        try std.testing.expect(std.mem.indexOf(u8, out, "// file-level note") != null);

        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
        try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
        const first = parsed.value.array.items[0].object;
        try std.testing.expectEqualStrings("x", first.get("prefab").?.string);
        try std.testing.expect(first.get("Position") != null);
        try std.testing.expect(first.get("components") == null);
        try std.testing.expect(first.get("overrides") == null);
        const second = parsed.value.array.items[1].object;
        try std.testing.expect(second.get("BuildIntent") != null);
        try std.testing.expect(second.get("components") == null);
    }

    test "comments at every legal position survive end-to-end" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "// header\n" ++
            "{\n" ++
            "    // before name\n" ++
            "    \"name\": \"demo\",\n" ++
            "    // before children\n" ++
            "    \"children\": [\n" ++
            "        // before first entry\n" ++
            "        { \"prefab\": \"x\", \"overrides\": { /* inner */ \"Position\": { \"x\": 1 } } }\n" ++
            "        // after last entry\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArenaFull(&arena, src, "demo");
        try std.testing.expect(std.mem.indexOf(u8, out, "// header") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "// before first entry") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "// after last entry") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "/* inner */") != null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .array);
    }
};

pub const PreScanXrefsSpec = struct {
    test "scanPrefabRefs dedups: N files referencing the same prefab yield ONE xref entry" {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var temp_arena = std.heap.ArenaAllocator.init(arena);
        defer temp_arena.deinit();

        var xrefs: std.StringHashMap(void) = .init(arena);

        // Five "files" all referencing the same prefab name "Hero". After
        // resetting the temp arena between each file, the xref name must
        // survive (duped into main arena) AND only one entry must exist
        // (dedup via xrefs.contains in collectPrefabRefsFromValue).
        const files = [_][]const u8{
            "[{ \"prefab\": \"Hero\" }]",
            "[{ \"prefab\": \"Hero\", \"overrides\": { \"Position\": { \"x\": 1 } } }]",
            "{ \"children\": [{ \"prefab\": \"Hero\" }] }",
            "[{ \"prefab\": \"Hero\" }, { \"prefab\": \"Hero\" }]", // intra-file dup too
            "[{ \"prefab\": \"Hero\" }]",
        };
        for (files) |raw| {
            try scanPrefabRefs(arena, temp_arena.allocator(), raw, &xrefs);
            _ = temp_arena.reset(.retain_capacity);
        }

        try std.testing.expectEqual(@as(u32, 1), xrefs.count());
        try std.testing.expect(xrefs.contains("Hero"));
    }

    test "scanPrefabRefs collects multiple distinct prefabs and dedups each" {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var temp_arena = std.heap.ArenaAllocator.init(arena);
        defer temp_arena.deinit();

        var xrefs: std.StringHashMap(void) = .init(arena);

        const files = [_][]const u8{
            "[{ \"prefab\": \"Hero\" }, { \"prefab\": \"Goblin\" }]",
            "[{ \"prefab\": \"Hero\" }]", // duplicate of Hero
            "[{ \"prefab\": \"Sword\" }]",
            "[{ \"prefab\": \"Goblin\" }]", // duplicate of Goblin
        };
        for (files) |raw| {
            try scanPrefabRefs(arena, temp_arena.allocator(), raw, &xrefs);
            _ = temp_arena.reset(.retain_capacity);
        }

        try std.testing.expectEqual(@as(u32, 3), xrefs.count());
        try std.testing.expect(xrefs.contains("Hero"));
        try std.testing.expect(xrefs.contains("Goblin"));
        try std.testing.expect(xrefs.contains("Sword"));
    }

    test "xref keys survive temp-arena reset (lifetime check)" {
        // Regression guard: if a future contributor accidentally dupes
        // the xref key into the temp arena instead of the main arena,
        // the key bytes will be invalidated by the reset and this test
        // will read garbage on the contains() lookup.
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var temp_arena = std.heap.ArenaAllocator.init(arena);
        defer temp_arena.deinit();

        var xrefs: std.StringHashMap(void) = .init(arena);

        // Use a long name so a stale pointer is less likely to land on
        // identical bytes by coincidence.
        try scanPrefabRefs(arena, temp_arena.allocator(), "[{ \"prefab\": \"VeryLongPrefabNameForLifetimeCheck\" }]", &xrefs);
        _ = temp_arena.reset(.retain_capacity);

        // Fill temp with unrelated bytes to clobber any released pages.
        const noise = try temp_arena.allocator().alloc(u8, 4096);
        @memset(noise, 0xAA);

        try std.testing.expectEqual(@as(u32, 1), xrefs.count());
        try std.testing.expect(xrefs.contains("VeryLongPrefabNameForLifetimeCheck"));
    }
};
