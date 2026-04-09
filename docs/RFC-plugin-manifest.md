# RFC: Plugin Manifest — letting plugins extend project layout

**Status:** Ready for implementation
**Scope:** `labelle-cli` generator — add a general-purpose `plugin.labelle` manifest
**Prerequisite for:** `labelle-fsm` and any future plugin that introduces its own convention directory

---

## Problem

The labelle-cli generator hardcodes every convention directory in `generator/src/root.zig`:

```zig
const prefab_names     = try scanner.copyAndScan(allocator, game_dir, target_dir, "prefabs",    ".jsonc");
const jsonc_scene_names = try scanner.copyAndScan(allocator, game_dir, target_dir, "scenes",    ".jsonc");
const script_names      = try scanner.copyAndScan(allocator, game_dir, target_dir, "scripts",   ".zig");
const component_names   = try scanner.copyAndScan(allocator, game_dir, target_dir, "components",".zig");
const hook_names        = try scanner.copyAndScan(allocator, game_dir, target_dir, "hooks",     ".zig");
const event_names       = try scanner.copyAndScan(allocator, game_dir, target_dir, "events",    ".zig");
const enum_names        = try scanner.copyAndScan(allocator, game_dir, target_dir, "enums",     ".zig");
const view_names        = try scanner.copyAndScan(allocator, game_dir, target_dir, "views",     ".zon");
const gizmo_names       = try scanner.copyAndScan(allocator, game_dir, target_dir, "gizmos",    ".zon");
try scanner.copyDirRecursive(allocator, game_dir, target_dir, "assets");
```

This works fine for **first-class labelle-engine concepts** (components, hooks, events, scripts, scenes, prefabs, assets). Every labelle game uses those — hardcoding them is appropriate.

The problem arises when a **plugin** wants to introduce its own convention directory. A motivating example:

- `labelle-fsm` (RFC in progress) wants game projects to put state-machine definitions in a `state_machines/` directory.
- If we hardcode `state_machines/` in the CLI, we promote a plugin-level concept to the CLI's core vocabulary. A game that never uses labelle-fsm still has "state_machines" baked into its build pipeline.
- If we don't hardcode it, the directory is silently ignored — files in `state_machines/` never get copied to `.labelle/<backend>_<platform>/` and any `@import` from a script/hook fails.

More plugins will hit this in the future: `labelle-dialogue` might want `dialogue_trees/`, `labelle-quests` might want `quests/`, a behavior-tree plugin might want `behaviors/`. Each one would require a CLI release to add its directory to the hardcoded list. That's a dependency inversion — the CLI ends up knowing about every plugin that exists.

**Precedent for manifest-based plugin integration already exists.** GUI plugins ship a `gui.labelle` manifest that declares their render mode, lifecycle hooks, and bridge requirements. The CLI reads it at generate time and wires the plugin up accordingly. Extending the same idea to general-purpose plugins is a natural move, not a new architectural direction.

## Goals

- **G1.** A plugin can declare additional convention directories (name + extension + scan/copy mode) in a manifest file shipped alongside its `build.zig`.
- **G2.** The CLI reads every declared plugin's manifest during `generate`, and extends its copy/scan list accordingly. The hardcoded list stays as-is for first-class engine concepts.
- **G3.** Plugins without a manifest continue to work unchanged. `labelle-pathfinder` ships no manifest today and should not need one after this RFC.
- **G4.** Manifest errors (missing file when declared, malformed ZON, duplicate directory names across plugins) produce clear error messages at generate time, not cryptic build failures.
- **G5.** The existing `gui.labelle` manifest keeps working. GUI plugins are a special case that may eventually migrate to a unified `plugin.labelle` but this RFC does not require it.

## Non-goals

- **NG1.** No runtime plugin loading. Everything is resolved at `labelle generate` time.
- **NG2.** No plugin discovery from outside `project.labelle`. Plugins must still be declared in the game's `.plugins` list — this RFC does not introduce automatic scanning of `../plugins/` or similar.
- **NG3.** No code generation from plugin manifests in v1. The CLI reads `convention_dirs` and copies/scans, but does not (yet) generate imports or registries from plugin-declared content. That is future work.
- **NG4.** No replacing `gui.labelle`. GUI plugins keep their existing manifest. Migration may happen later but is out of scope here.

## Proposed manifest: `plugin.labelle`

A plugin that wants to extend project layout ships a `plugin.labelle` file at its repository root, next to `build.zig`.

### Minimal example (labelle-fsm)

```zon
// labelle-fsm/plugin.labelle
.{
    .name = "fsm",
    .manifest_version = 1,
    .convention_dirs = .{
        .{
            .name = "state_machines",
            .extension = ".zig",
            .mode = .copy_and_scan,
        },
    },
}
```

### Field reference

| Field               | Type        | Required | Description                                                                 |
|---------------------|-------------|----------|-----------------------------------------------------------------------------|
| `name`              | `[]const u8`| yes      | Plugin name. Must match the `name` in `project.labelle`'s `.plugins` entry. |
| `manifest_version`  | `u8`        | yes      | Schema version. `1` for this RFC. Forward-compat hook.                      |
| `convention_dirs`   | list        | no       | Directories the plugin wants the CLI to copy from the game repo.            |

Each `convention_dirs` entry:

| Field         | Type           | Required                         | Description                                                                 |
|---------------|----------------|----------------------------------|-----------------------------------------------------------------------------|
| `name`        | `[]const u8`   | yes                              | Directory name, relative to the game project root (e.g., `"state_machines"`). Must be a safe single segment — no `..`, no path separators, no absolute paths. |
| `extension`   | `?[]const u8`  | only when `mode = .copy_and_scan`| File extension to scan (e.g., `".zig"`, `".jsonc"`). `.copy_only` entries omit this field. `loadFromDir` errors with `PluginManifestMissingExtension` if a `copy_and_scan` entry is missing its extension. |
| `mode`        | enum           | yes                              | `.copy_and_scan` (copies files + returns name list) or `.copy_only` (copies files recursively, no scanning — like `assets/`). |

### Mode semantics

- **`.copy_and_scan`** — mirrors the existing `scanner.copyAndScan` path. Every file matching `extension` under `<game_dir>/<name>/` is copied to `<target_dir>/<name>/`, and the file stems are returned as a name list. This is what `components/`, `hooks/`, `events/`, etc. already do. For v1 the name list is computed and stored but *not* exposed for codegen — that's future work (NG3).
- **`.copy_only`** — mirrors `scanner.copyDirRecursive` used today for `assets/`. Files are copied, no scanning, no name list.

### Missing directories are silently tolerated

If a game project doesn't have a directory a plugin declares, it is **not an error**. This matches existing CLI behavior: `scanner.copyAndScan` and `scanner.copyDirRecursive` both silently no-op on `error.FileNotFound` today, so a game that doesn't have `components/`, `hooks/`, or `assets/` builds fine.

A plugin that needs its directory to be non-empty for runtime correctness should perform that check in its own initialization code, not at generate time.

## Integration in the generator

The `generator/src/root.zig` flow gains one step after the existing hardcoded scans:

```zig
// ... existing hardcoded scans for prefabs, scenes, components, hooks, events, enums, etc ...

// Plugin-declared convention directories
for (cfg.plugins) |plugin| {
    const manifest = try plugin_manifest.loadOptional(allocator, plugin, project_dir);
    defer if (manifest) |m| m.deinit(allocator);

    if (manifest) |m| {
        for (m.convention_dirs) |dir| {
            switch (dir.mode) {
                .copy_and_scan => {
                    const names = try scanner.copyAndScan(
                        allocator,
                        game_dir,
                        target_dir,
                        dir.name,
                        dir.extension,
                    );
                    defer scanner.freeNames(allocator, names);
                    // v1: names computed but not exposed to codegen (NG3)
                    // Missing source dirs silently no-op via copyAndScan.
                },
                .copy_only => {
                    try scanner.copyDirRecursive(allocator, game_dir, target_dir, dir.name);
                    // Missing source dirs silently no-op via copyDirRecursive.
                },
            }
        }
    }
}
```

### New module: `generator/src/plugin_manifest.zig`

```zig
pub const ConventionDirMode = enum { copy_and_scan, copy_only };

pub const ConventionDir = struct {
    name: []const u8,
    /// Required when `mode == .copy_and_scan`, null when `.copy_only`.
    /// Enforced by `loadFromDir` — missing extension on a copy_and_scan
    /// entry returns `error.PluginManifestMissingExtension`.
    extension: ?[]const u8 = null,
    mode: ConventionDirMode,
};

pub const PluginManifest = struct {
    name: []const u8,
    manifest_version: u8,
    convention_dirs: []const ConventionDir = &.{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PluginManifest) void { ... }
};

/// Returns null if the plugin has no plugin.labelle file. Errors on parse failure.
pub fn loadOptional(
    allocator: std.mem.Allocator,
    plugin: config.PluginDep,
    project_dir: []const u8,
) !?PluginManifest { ... }

/// Validates that `name` in the manifest matches the plugin's declared name,
/// and that `manifest_version` is supported by this CLI release.
pub fn validate(self: PluginManifest, expected_name: []const u8) !void { ... }
```

## Error handling

Three classes of error, each with a specific message:

### E1. Manifest parse failure

```
labelle: failed to parse plugin.labelle for plugin 'fsm' at /path/to/labelle-fsm/plugin.labelle:
  line 5: expected ',' after convention_dirs entry
  (see docs/RFC-plugin-manifest.md for the manifest schema)
```

### E2. Name mismatch

```
labelle: plugin.labelle name mismatch
  project.labelle declares plugin 'fsm'
  but its plugin.labelle has name = 'state_machines'
  at /path/to/labelle-fsm/plugin.labelle
```

### E3. Duplicate convention directory

```
labelle: two plugins want the same convention directory 'state_machines':
  - plugin 'fsm' declares it (extension .zig, copy_and_scan)
  - plugin 'fsm_experimental' declares it (extension .zig, copy_and_scan)
  each plugin must use a unique directory name
```

### E4. Reserved directory name

```
labelle: plugin 'fsm' tried to declare convention_dir 'components'
  but 'components' is reserved for first-class engine concepts.
  reserved names: assets, components, enums, events, gizmos, hooks,
                  prefabs, scenes, scripts, views
  pick a different directory name for this plugin.
```

### E5. Manifest version unknown

```
labelle: plugin 'fsm' requires manifest_version 2
  but this labelle-cli release supports up to manifest_version 1
  upgrade labelle-cli or downgrade the plugin
```

## Interaction with existing `gui.labelle`

GUI plugins keep shipping `gui.labelle`. The new `plugin.labelle` is orthogonal — a GUI plugin that also wanted to declare a convention directory would ship both manifests. Most GUI plugins won't need `plugin.labelle` at all (they don't introduce new project-layout directories, they integrate via the rendering pipeline).

If in the future we want to unify the two, we can introduce a `plugin.labelle` with a `.gui` sub-field and deprecate `gui.labelle`. That migration is its own RFC.

## Versioning strategy

The `manifest_version` field is a `u8` that:

- **v1** = this RFC. Supports `name` and `convention_dirs` (each with `name`, `extension`, `mode`).
- Future versions may add fields. The CLI refuses to load a manifest with a version higher than it knows about (E5), so plugins using new features fail cleanly against old CLIs instead of being silently partially-loaded.
- Dropping a field or changing semantics bumps the version.
- Adding a new optional field does not bump the version (forward-compatible within a major version).

## Closed decisions

### Q1. Codegen hooks in v1? — **Defer.**

v1 copies and scans. The name list returned by `copyAndScan` is computed but not exposed to `generateMainZigFromTemplate`. If a future plugin needs to drive codegen (e.g. "generate an import in main.zig for every file in `dialogue_trees/`"), that's a separate RFC. Open questions for that future RFC: how do two plugins compose? what's the failure mode when two plugins generate conflicting imports? Out of scope here.

### Q2. Manifest location — **Plugin root.**

`plugin.labelle` lives next to `build.zig` / `build.zig.zon`, the same way `gui.labelle` does in `labelle-imgui/`. Resolver path is `<plugin_path>/plugin.labelle`. No directory walks, no ambiguity, matches existing precedent.

### Q3. Multiple extensions per entry — **One extension per entry.**

If a plugin needs both `.zig` and `.zon` files in the same directory, it declares two `convention_dirs` entries with the same `name` and different extensions. Two entries is clearer than a `extensions: []const []const u8` field.

### Q4. `optional` field — **Dropped entirely.**

Originally proposed as a per-entry bool to control whether a missing source directory should error. Discovered during implementation that the existing CLI silently no-ops on missing convention directories: `scanner.copyAndScan` and `scanner.copyDirRecursive` both swallow `error.FileNotFound` (`generator/src/scanner.zig:50, 152`). A game today can omit `components/`, `hooks/`, `assets/` entirely and the CLI doesn't complain.

The `optional` field would introduce a stricter behavior than the rest of the CLI uses, which is inconsistent and surprising. Dropped to match existing convention. A plugin that genuinely needs a non-empty directory at runtime can validate that itself, in its own initialization code, not at generate time.

### Q5. Interaction with `plugin.states` — **Manifest processed regardless of `states`.**

The existing `states` field on `PluginDep` restricts which game states the plugin's runtime code activates in (debug-only plugins, etc.). That is a runtime concern. The manifest is read and its `convention_dirs` are copied at `labelle generate` time unconditionally — because the build is one binary and `states` only gates which scripts tick. Documentation in the implementation will call this out to avoid confusion.

### Q6. Name collisions with reserved (hardcoded) directories — **Hard error in `loadOptional`.**

Reserved names a plugin manifest cannot declare:

```
assets, components, enums, events, gizmos, hooks,
prefabs, scenes, scripts, views
```

This list is the full set of hardcoded `copyAndScan` / `copyDirRecursive` calls in `generator/src/root.zig`. If a plugin declares any of these as a `convention_dir.name`, `loadOptional` returns an error with the reserved list inline so the plugin author can pick a different name.

### Bonus: ZON parsing approach — **`std.zon.parseFromSlice` with a typed `PluginManifest` struct.**

Same approach as `ProjectConfig` parsing today (`labelle-cli/src/cli/`). Forward-compatibility comes from the explicit `manifest_version` field, not from lenient parsing.

## Rollout

1. **Add `plugin_manifest.zig`** to `generator/src/` with `PluginManifest`, `loadOptional`, `validate`, and the error messages listed above.
2. **Extend `root.zig`** with the plugin-manifest scan loop after the hardcoded scans.
3. **Tests** — unit tests for parse success, parse failure, name mismatch, duplicate dir across plugins, reserved dir, unsafe dir name (path traversal), missing extension on copy_and_scan, unknown manifest version, forward-compat `ignore_unknown_fields`.
4. **Integration test** — a fake plugin with a manifest declaring `state_machines/`, a fake game project with and without the directory, verify copy/scan behavior.
5. **Documentation** — add a "Plugin Manifest" section to the CLI README explaining the schema and the reserved-name list.
6. **Ship** as a CLI minor version bump (e.g., 0.5.0 → 0.6.0). No backwards incompatibility — plugins without a manifest continue to work.
7. **Unblock `labelle-fsm`** — it can now ship its manifest declaring `state_machines/` as a convention dir.

## Success criteria

- [ ] A plugin shipping a valid `plugin.labelle` with `convention_dirs` has its declared directories copied/scanned during `labelle generate`.
- [ ] A plugin without `plugin.labelle` continues to work unchanged (no manifest warning, no failure).
- [ ] Parse errors produce messages that include the plugin name, file path, and a hint at the schema.
- [ ] Duplicate directory declarations across plugins fail with a clear message listing both plugins.
- [ ] A plugin trying to declare a reserved name (`components`, `hooks`, etc.) fails with a message listing the reserved names.
- [ ] An unknown `manifest_version` fails with a message telling the user to upgrade the CLI or downgrade the plugin.
- [ ] The `gui.labelle` path continues to work unchanged — GUI plugins are unaffected.
- [ ] `labelle-fsm` can declare `state_machines/` via this manifest and its files land in the generated project.
