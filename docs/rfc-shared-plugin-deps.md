# RFC: Shared Framework Dependencies for Plugins

**Issue**: #42
**Status**: Draft
**Author**: Claude + Alexandre

## Summary

Plugins that depend on `labelle-core` (or other framework packages) currently resolve their own copy via `build.zig.zon`, creating duplicate packages with incompatible types. The CLI assembler should inject shared framework dependencies into plugins so all code uses the same package instances.

## Problem

Zig treats each resolved package as a distinct type namespace. When both the game and a plugin resolve `labelle-core` independently:

```
game → labelle-core (local:../labelle-core)
plugin → labelle-core (URL v0.2.0 from cache)
```

The `Position` type from the plugin is a **different type** than `Position` from the game, even with identical layout. This causes compile errors when passing values between them.

### Current workaround

Plugins must manually point their `build.zig.zon` to the same local `labelle-core`:

```zon
.@"labelle-core" = .{ .path = "../../../labelle-core" },
```

This is fragile, assumes a specific directory layout, and breaks for remote plugins.

## Proposal

### Option A: CLI injects shared deps into plugin modules (Recommended)

The CLI already controls how plugin modules are wired into the build. Instead of letting Zig resolve the plugin's `build.zig.zon` deps independently, the CLI should:

1. Resolve `labelle-core` once (from `project.labelle`'s `core_version`)
2. When generating `build.zig`, pass the shared `labelle-core` module to each plugin module as an import override

The generated `build.zig` would look like:

```zig
// Shared framework modules (resolved once by the CLI)
// Dependency key: underscore style ("labelle_core")
// Module import name: hyphen style ("labelle-core")
const core_dep = b.dependency("labelle_core", .{ .target = target, .optimize = optimize });
const core_mod = core_dep.module("labelle-core");

// Plugin — use shared core, not its own
const plugin_pathfinder_dep = b.dependency("labelle_pathfinder", .{ .target = target, .optimize = optimize });
const plugin_pathfinder_mod = plugin_pathfinder_dep.module("labelle_pathfinder");
plugin_pathfinder_mod.addImport("labelle-core", core_mod);  // Override plugin's own resolution
```

The key is `addImport` — this replaces the plugin module's existing import of the same name with the shared one. Since Zig modules resolve `@import("labelle-core")` via the import table on the module itself, calling `addImport("labelle-core", core_mod)` on the exported module replaces the entry, and all source files within that module see the shared instance.

**Important**: This works because Zig's `addImport` operates on the module's import table, not on individual source files. When a plugin's `build.zig` calls `pathfinder_mod.addImport("labelle-core", its_own_core_mod)`, it sets an import table entry. The CLI's subsequent `addImport("labelle-core", shared_core_mod)` overwrites that same entry. All `@import("labelle-core")` calls within the module resolve through this single table entry.

**Caveat**: If a plugin's `build.zig` creates **multiple internal modules** and wires `labelle-core` to each independently, the CLI would need to override each module. However, the plugin packaging contract (see below) requires plugins to export a single root module, so the CLI only needs to override imports on that one module.

The plugin's `build.zig.zon` still declares `labelle-core` (so `zig build test` works standalone), but at assembly time the CLI substitutes the shared instance.

**Pros**:
- Single source of truth for framework versions
- Plugins don't need to know about the game's directory layout
- Works for both local and remote plugins
- No changes needed to plugin `build.zig.zon` files

**Cons**:
- Requires the CLI to know which deps are "shared" (see shared deps table below)
- Plugin's `build.zig.zon` still lists the dep (for standalone testing), but it's overridden at assembly time
- Plugins must follow the packaging contract (single exported root module)

### Option B: Plugins omit framework deps entirely (not viable)

This option would have plugins omit `labelle-core` from their `build.zig.zon` and receive it purely from the host via `addImport`. This is **not viable** with Zig's current package system:

- `b.dependency()` requires a matching key in `build.zig.zon`, so plugins cannot call `b.dependency("labelle-core", ...)` without declaring it
- Without the declaration, `zig build test` fails — plugins cannot be built or tested standalone
- The only way to receive an externally-provided module is through `addImport` on an already-exported module, which is exactly what Option A does

**Conclusion**: Option A is strictly superior — plugins keep their `build.zig.zon` declarations for standalone use, and the CLI overrides them at assembly time.

### Option C: Zig package deduplication (future)

Zig may eventually support package deduplication by content hash. This would solve the problem at the build system level.

**Pros**: No CLI changes needed
**Cons**: Not available today, unclear timeline

## Recommended approach

**Option A** is the most practical:

1. The CLI already generates `build.zig` — adding `addImport` overrides is straightforward
2. Plugins keep working standalone (their `build.zig.zon` deps are used for `zig build test`)
3. At assembly time, the CLI ensures all code shares the same `labelle-core`

## Shared dependencies

Any framework package whose types cross plugin boundaries must be shared. A type crosses the boundary when it appears in a plugin's `Components` struct, in function signatures called by the game, or in data structures passed between the game and plugin.

The full set:

| Dependency key | Module import name | Why shared |
|---|---|---|
| `labelle_core` | `labelle-core` | `Position`, `Color`, and other core types used across all plugins |
| `labelle_gfx` | `labelle-gfx` | `Fade`, `Flash`, and other effect components — `labelle-gfx` is passed to `ComponentRegistryWithPlugins` in generated `main.zig` |
| `labelle_engine` | `labelle-engine` | Engine types (e.g. `Entity`, `EcsBackend`) if plugins depend on the engine directly |
| `zig_utils` | `zig_utils` | `Vector2` and math types used by plugins that depend on zig-utils |

**How to determine if a dep needs sharing**: If plugin source files `@import("foo")` and the game also `@import("foo")`, and values of types from `foo` are passed between them (via components, function args, or return types), then `foo` must be shared. Internal-only deps (e.g. `zspec` for tests) do not need sharing.

**Naming convention**: dependency keys in `build.zig.zon` and `b.dependency()` use underscores (`labelle_core`). Module import names used in `@import()` and `addImport()` use hyphens (`labelle-core`) or underscores (`zig_utils`) — matching whatever the package declares as its module name. These must be kept consistent across the generated `build.zig`.

**Dynamic detection**: Rather than hardcoding the shared dep list, the CLI could inspect each plugin's `build.zig.zon` for known framework package names. Initially, a static list is simpler. The list should be maintained in the CLI config and extended as new framework packages are added.

## Plugin packaging contract

For Option A to work reliably, plugins must follow a packaging contract:

1. **Single root module**: A plugin's `build.zig` must export exactly one module (e.g. `labelle_pathfinder`) via `b.addModule()`. This is the module the CLI retrieves with `dep.module("labelle_<name>")` and applies `addImport` overrides to.

2. **Framework imports via `@import`**: The root module must use standard `@import("labelle-core")` for framework deps. The CLI overrides these imports at assembly time. The plugin must not resolve framework deps through any mechanism other than the module import table (e.g. no hardcoded paths in source).

3. **`Components` declaration**: If the plugin provides ECS components, it must export `pub const Components = struct { ... }` from its root module, listing all component types. The engine's `ComponentRegistryWithPlugins` discovers these at comptime.

4. **Standalone testing**: The plugin's `build.zig.zon` declares all framework deps (so `zig build test` works), and its `build.zig` wires them to the root module. At assembly time, the CLI's `addImport` overrides these with shared instances.

Example plugin `build.zig` (pathfinder):
```zig
const pathfinder_mod = b.addModule("labelle_pathfinder", .{
    .root_source_file = b.path("src/root.zig"),
});
pathfinder_mod.addImport("labelle-core", labelle_core_mod);  // overridden by CLI at assembly time
pathfinder_mod.addImport("zig_utils", zig_utils_mod);        // overridden by CLI at assembly time
```

## Implementation plan

1. In `build_files.zig`, after creating each plugin module, emit `addImport` overrides for all shared framework deps (`labelle-core`, `labelle-gfx`, `zig_utils`, and `labelle-engine` if applicable)
2. Add a static list of shared framework deps to the generator config, mapping dependency keys to module import names
3. Only emit `addImport` for deps that the plugin actually declares in its `build.zig.zon` (avoid overriding non-existent imports)
4. Test with both local (`@libs/`) and remote plugins
5. Verify `addImport` override propagation: confirm that calling `addImport` on the exported module replaces the plugin's internally-wired import
6. Update plugin development docs with the packaging contract and assembly-time override explanation

## Validation checklist

Before merging, verify:

- [ ] A plugin using `labelle-core` via URL in `build.zig.zon` compiles without type mismatches when assembled by the CLI
- [ ] `@typeof(plugin_position) == @typeof(game_position)` holds at comptime (same `Position` type)
- [ ] Plugin still builds standalone with `zig build test` (its own `build.zig.zon` deps are used)
- [ ] Local plugins (`@libs/foo`) receive the override
- [ ] Remote plugins (URL-based) receive the override
- [ ] Removing the local path workaround from `libs/pathfinder/build.zig.zon` (reverting to URL) still compiles
- [ ] `addImport` on the exported module correctly overrides the plugin's internally-wired `labelle-core` (not just the module declaration, but actual `@import` resolution)
- [ ] Plugins with multiple shared deps (e.g. `labelle-core` + `zig_utils`) get all overrides applied

## Migration

- No breaking changes to existing plugins
- Plugins with local path workarounds can revert to URL deps in their `build.zig.zon`
- The CLI handles the override transparently
