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

The key is `addImport` — this overrides the plugin's own `labelle-core` resolution with the shared one, ensuring type compatibility. The plugin's `build.zig.zon` still declares `labelle-core` (so `zig build test` works standalone), but at assembly time the CLI substitutes the shared instance.

**Pros**:
- Single source of truth for framework versions
- Plugins don't need to know about the game's directory layout
- Works for both local and remote plugins
- No changes needed to plugin `build.zig.zon` files

**Cons**:
- Requires the CLI to know which deps are "shared" (currently just `labelle-core`)
- Plugin's `build.zig.zon` still lists the dep (for standalone testing), but it's overridden at assembly time

### Option B: Plugins declare framework deps as peer dependencies

**Note**: This option is not viable with Zig's current package system. `b.dependency()` requires a matching key in `build.zig.zon`, so plugins cannot omit the declaration and still resolve the dependency. The only way to receive an externally-provided module is through the host's `addImport` mechanism — which is exactly what Option A does.

This option is listed for completeness but is **not recommended**.

**Cons**: Not possible without `build.zig.zon` entry; plugins can't be built/tested standalone

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

Any framework package whose types cross plugin boundaries must be shared. The full set:

| Dependency key | Module import name | Why shared |
|---|---|---|
| `labelle_core` | `labelle-core` | `Position`, `Color`, and other core types used across all plugins |
| `labelle_gfx` | `labelle-gfx` | `Fade`, `Flash`, and other effect components that may be set by plugins |
| `zig_utils` | `zig_utils` | `Vector2` and math types used by plugins that depend on zig-utils |

**Naming convention**: dependency keys in `build.zig.zon` and `b.dependency()` use underscores (`labelle_core`). Module import names used in `@import()` and `addImport()` use hyphens (`labelle-core`). These must be kept consistent across the generated `build.zig`.

Only deps whose types are passed between the game and plugin code need sharing. Internal-only deps (e.g. `zspec` for tests) do not.

## Implementation plan

1. In `build_files.zig`, after creating each plugin module, emit `addImport("labelle-core", core_mod)` to override the plugin's own resolution
2. Add a list of "shared framework deps" to the generator config (initially just `labelle-core`)
3. Test with both local (`@libs/`) and remote plugins
4. Update plugin development docs to explain the assembly-time override

## Validation checklist

Before merging, verify:

- [ ] A plugin using `labelle-core` via URL in `build.zig.zon` compiles without type mismatches when assembled by the CLI
- [ ] `@typeof(plugin_position) == @typeof(game_position)` holds at comptime (same `Position` type)
- [ ] Plugin still builds standalone with `zig build test` (its own `build.zig.zon` deps are used)
- [ ] Local plugins (`@libs/foo`) receive the override
- [ ] Remote plugins (URL-based) receive the override
- [ ] Removing the local path workaround from `libs/pathfinder/build.zig.zon` (reverting to URL) still compiles

## Migration

- No breaking changes to existing plugins
- Plugins with local path workarounds can revert to URL deps in their `build.zig.zon`
- The CLI handles the override transparently
