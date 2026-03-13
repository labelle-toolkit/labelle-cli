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
// Shared framework modules (resolved once)
const core_dep = b.dependency("labelle_core", .{ ... });
const core_mod = core_dep.module("labelle-core");

// Plugin — use shared core, not its own
const plugin_pathfinder_dep = b.dependency("labelle_pathfinder", .{ ... });
const plugin_pathfinder_mod = plugin_pathfinder_dep.module("labelle_pathfinder");
plugin_pathfinder_mod.addImport("labelle-core", core_mod);  // Override
```

The key is `addImport` — this overrides the plugin's own `labelle-core` resolution with the shared one, ensuring type compatibility.

**Pros**:
- Single source of truth for framework versions
- Plugins don't need to know about the game's directory layout
- Works for both local and remote plugins
- No changes needed to plugin `build.zig.zon` files

**Cons**:
- Requires the CLI to know which deps are "shared" (currently just `labelle-core`)
- Plugin's `build.zig.zon` still lists the dep (for standalone testing), but it's overridden at assembly time

### Option B: Plugins declare framework deps as peer dependencies

Plugins would not declare `labelle-core` in their `build.zig.zon` at all. Instead, their `build.zig` would accept it as an external module:

```zig
// Plugin build.zig
pub fn build(b: *std.Build) void {
    // labelle-core provided by the host (CLI assembler)
    const core_mod = b.dependency("labelle-core", .{}).module("labelle-core");
    // ...
}
```

**Pros**: Clean separation
**Cons**: Plugins can't be built/tested standalone without a wrapper

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

The initial set of shared deps to inject:

| Dependency | Why shared |
|---|---|
| `labelle-core` | `Position`, `Color`, and other core types used across all plugins |

`zig-utils` may also need sharing if plugins use `Vector2` or other types that cross plugin boundaries.

## Implementation plan

1. In `build_files.zig`, after creating each plugin module, emit `addImport("labelle-core", core_mod)` to override the plugin's own resolution
2. Add a list of "shared framework deps" to the generator config (initially just `labelle-core`)
3. Test with both local (`@libs/`) and remote plugins
4. Update plugin development docs to explain the assembly-time override

## Migration

- No breaking changes to existing plugins
- Plugins with local path workarounds can revert to URL deps in their `build.zig.zon`
- The CLI handles the override transparently
