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
/// The nine transforms (idempotent — running twice on the same file
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
///   8. **file-level directives → meta header** (RFC #596 update) —
///      top-level `initial_state`, `scripts`, `include` (engine-known
///      directives) and any other lowercase non-structural key move into
///      a `"meta": {...}` block at the file level so transform 9 can
///      emit them as the bundle's first element. Runs only on files
///      with `children:` (or after rename, post-transform 1) and no
///      PascalCase top-level keys — for true single-root entities,
///      directives at the file level are out of scope here.
///
///   9. **`legacy_file_object_no_root`** (RFC #596) — wrapping object
///      with `"children": [...]` (no entity-shape sibling keys)
///      collapses to a top-level array, dropping the now-redundant
///      braces. If a sibling `meta:` block exists (typically populated
///      by transform 7 and/or 8) it lands as the bundle's first
///      element: `[ { meta: {...} }, ...children-items ]`. Files with
///      a true root entity (PascalCase components on the wrapping
///      object) stay objects.
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
///
/// **Module layout** (split for readability; see cli#... refactor):
///   migrate.zig            — this file: CLI dispatch + run orchestration
///   migrate/scanner.zig    — JSONC byte scanner + JSONC→JSON pre-stripper
///   migrate/transforms.zig — byte transforms A–F
///   migrate/transforms_meta.zig — RFC #596 meta/directive transforms G–I
///   migrate/pipeline.zig   — transform dispatcher + Summary/FileCounts
///   migrate/walk.zig       — directory traversal + xref pre-scan
///   migrate/tests*.zig     — zspec spec namespaces

const std = @import("std");

const pipeline = @import("migrate/pipeline.zig");
const walk = @import("migrate/walk.zig");

const Summary = pipeline.Summary;

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
    \\    8. file-level directives (initial_state, scripts, include) →
    \\       merged into meta: block
    \\    9. wrapping object { meta?, children: [...] } → top-level
    \\       [ {meta: {...}}?, ...children-items ]
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
// Migrator core — two-pass run orchestration
// ─────────────────────────────────────────────────────────────────────

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
        walk.collectPrefabRefs(arena, project_dir, subdir, &xrefs) catch {};
    }
    inline for (.{ "scenes", "prefabs" }) |subdir| {
        try walk.walkAndMigrate(arena, project_dir, subdir, dry_run, &xrefs, summary);
    }
}

// ─────────────────────────────────────────────────────────────────────
// Test surface — re-export the spec namespaces consumed by the cli test
// runner (`src/cli.zig`'s `zspec.runAll(@This())`). They live in the
// `migrate/tests*.zig` submodules; re-exporting here keeps the same
// `migrate.<Spec>` paths the runner already references.
// ─────────────────────────────────────────────────────────────────────

const tests = @import("migrate/tests.zig");

// Mirrors the original migrate.zig: when `zig test` collects this file
// (reachable from the cli test root), this block runs zspec over every
// spec namespace re-exported below — including the RFC #596 specs, which
// cli.zig does NOT surface to its own runAll walk.
test {
    @import("zspec").runAll(@This());
}

pub const TransformRootWrapperSpec = tests.TransformRootWrapperSpec;
pub const DeleteTopLevelKeyBlockCommentSpec = tests.DeleteTopLevelKeyBlockCommentSpec;
pub const TransformEntitiesRenameSpec = tests.TransformEntitiesRenameSpec;
pub const TransformComponentsOnRefSpec = tests.TransformComponentsOnRefSpec;
pub const TransformAssetsDeleteSpec = tests.TransformAssetsDeleteSpec;
pub const IdempotencySpec = tests.IdempotencySpec;
pub const MixedFileSpec = tests.MixedFileSpec;

// RFC #596 spec namespaces. These lived in the original migrate.zig and
// were collected by `zig test` (reachable through this module from the
// cli test root), so re-export them to preserve the exact test set.
const tests_rfc596 = @import("migrate/tests_rfc596.zig");

pub const TransformLiftOverridesSpec = tests_rfc596.TransformLiftOverridesSpec;
pub const TransformLiftComponentsSpec = tests_rfc596.TransformLiftComponentsSpec;
pub const TransformNameFieldSpec = tests_rfc596.TransformNameFieldSpec;
pub const PrefabGuardConsistencySpec = tests_rfc596.PrefabGuardConsistencySpec;
pub const TransformFileAsArraySpec = tests_rfc596.TransformFileAsArraySpec;
pub const TransformDirectivesToMetaHeaderSpec = tests_rfc596.TransformDirectivesToMetaHeaderSpec;
pub const Rfc596IdempotencySpec = tests_rfc596.Rfc596IdempotencySpec;
pub const Rfc596MixedFileSpec = tests_rfc596.Rfc596MixedFileSpec;
pub const PreScanXrefsSpec = tests_rfc596.PreScanXrefsSpec;
