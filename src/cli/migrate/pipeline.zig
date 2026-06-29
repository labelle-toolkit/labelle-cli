// ─────────────────────────────────────────────────────────────────────
// Byte-oriented transform pipeline + counts model
// ─────────────────────────────────────────────────────────────────────
//
// `transformBytes` is the orchestrating dispatcher: it runs the nine
// transforms (A–I, defined in `transforms.zig` / `transforms_meta.zig`)
// in the required pass order over a file's raw JSONC bytes. `Summary` /
// `FileCounts` are the per-run / per-file counts surfaced to the user.

const std = @import("std");
const scanner = @import("scanner.zig");
const transforms = @import("transforms.zig");
const transforms_meta = @import("transforms_meta.zig");

const stripJsoncToJson = scanner.stripJsoncToJson;

// ─────────────────────────────────────────────────────────────────────
// Migrator counts model
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
    directives_to_meta_moves: usize = 0,
    parse_errors: usize = 0,
    write_errors: usize = 0,

    pub fn print(self: *const Summary, project_dir: []const u8, dry_run: bool) void {
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
        std.debug.print("  {d} file-level directive{s} {s} into 'meta'\n", .{
            self.directives_to_meta_moves,
            if (self.directives_to_meta_moves == 1) "" else "s",
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

pub const FileCounts = struct {
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
    directives_to_meta_moves: usize = 0,

    pub fn totalEdits(self: FileCounts) usize {
        return self.entities_renames +
            self.components_renames +
            self.assets_deletes +
            self.root_wrappers_lifted +
            self.overrides_lifts +
            self.components_lifts +
            self.file_as_array_collapses +
            self.name_field_drops +
            self.name_field_meta_moves +
            self.directives_to_meta_moves;
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
pub const TransformCtx = struct {
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
///   8. RFC #596 (update): file-level engine directives (`initial_state`,
///      `scripts`, `include`) and any other unknown lowercase top-level
///      key move into a `meta:` block. Must run BEFORE pass 9 — pass 9
///      collapses the wrapping object, so this is the last chance to
///      route directives into a header-bearing element.
///   9. RFC #596: collapse wrapping object to bundle array. When a
///      `meta:` block is present it is emitted as the bundle's first
///      element `{ "meta": {...} }`.
///
/// Each pass re-parses the working buffer to refresh structural info,
/// then locates the target key in the raw JSONC bytes. Idempotency
/// follows from each pass being a no-op on already-flat files. Tests
/// verify a second run produces byte-identical output.
pub fn transformBytes(
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
                    if (transforms.liftTopLevelRoot(arena, current)) |out| {
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
            if (transforms.deleteTopLevelKey(arena, current, "assets")) |out| {
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
            if (transforms.renameTopLevelKey(arena, current, "entities", "children")) |out| {
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
        const edited = transforms.renameOneComponentsOnRef(arena, current, parsed.value) catch null;
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
        const edited = transforms.liftOneOverridesBlock(arena, current, parsed.value) catch null;
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
        const edited = transforms.liftOneComponentsBlock(arena, current, parsed.value) catch null;
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
                        if (transforms.deleteTopLevelKey(arena, current, "name")) |out| {
                            current = out;
                            counts.name_field_drops += 1;
                        }
                    } else {
                        // Divergent — move to meta.name. If `meta:`
                        // already exists, merge into it; otherwise rename
                        // the `name:` key and wrap its value in `{}`.
                        const has_meta = parsed.value.object.get("meta") != null;
                        if (transforms_meta.moveNameToMeta(arena, current, name, has_meta)) |out| {
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

    // Pass 8 — RFC #596 update: file-level engine directives →
    // `meta:` block. Looks for `initial_state`, `scripts`, `include`,
    // and any other lowercase non-structural top-level key on a file
    // shaped like `{ ...directives, children?: [...], no PascalCase }`.
    // Each such key is moved into a `meta:` block (created if absent,
    // merged into otherwise). Runs in a fixed-point loop because each
    // edit invalidates byte offsets.
    while (true) {
        const stripped = try stripJsoncToJson(arena, current);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, stripped, .{});
        defer parsed.deinit();
        const edited = transforms_meta.moveOneDirectiveToMeta(arena, current, parsed.value) catch null;
        if (edited) |out| {
            current = out;
            counts.directives_to_meta_moves += 1;
            continue;
        }
        break;
    }

    // Pass 9 — RFC #596: collapse file-level wrapping object to a top-
    // level array when its only entity-bearing key is `children:`. A
    // file like `{ children: [...] }` (post-pass-7/8, so `name:` and
    // directives are already dropped or migrated into `meta:`) becomes
    // `[...]`, with an optional `{meta: ...}` header element if a
    // `meta:` block was present. Edge case: file with ONLY `meta:` (no
    // `children:`) becomes `[ {meta: ...} ]` — a bundle with just the
    // header.
    {
        const stripped = try stripJsoncToJson(arena, current);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, stripped, .{});
        defer parsed.deinit();
        if (transforms_meta.shouldCollapseFileToArray(parsed.value)) {
            if (transforms_meta.collapseFileToArray(arena, current, parsed.value)) |out| {
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
pub fn basenameNoExt(entry_name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, entry_name, '.')) |dot| {
        return entry_name[0..dot];
    }
    return entry_name;
}
