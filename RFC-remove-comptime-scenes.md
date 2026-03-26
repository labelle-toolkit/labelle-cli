# RFC: Remove Comptime Scene Loading and .zon Scene Support

Part of #96 (final breaking change in runtime scenes RFC #87).

## Status

Research complete. This document catalogues every file that needs modification
in both the CLI generator and the engine to remove comptime .zon scenes and
make runtime JSONC the only scene format.

---

## Background

The engine now has full runtime scene infrastructure:
- JSONC parser (`labelle-engine/jsonc/`)
- Runtime `Value` type and component deserializer
- Runtime scene loader (`jsonc/src/scene_loader.zig`) that loads `.jsonc` files,
  resolves prefabs from a `PrefabCache`, supports includes and nested entities
- Game state machine (`game/state_mixin.zig`) with state-scoped script execution
- Convention-based script scanner in the CLI (`generator/src/script_scanner.zig`)

Scripts are now globally registered via directory convention (not per-scene).
The `.scripts` field in scene definitions is obsolete.

---

## What the comptime scene system looks like today

### Scene .zon format (comptime)

```zon
.{
    .name = "game",
    .scripts = .{ "scene_menu" },         // <-- obsolete, scripts are global now
    .gui_views = .{ "hud" },
    .entities = .{
        .{
            .components = .{
                .Position = .{ .x = 350, .y = 250 },
                .Shape = .{ .shape = .{ .rectangle = .{ .width = 100, .height = 100 } } },
            },
        },
    },
}
```

### CLI codegen flow (current)

1. `scanner.copyAndScan` copies `scenes/*.zon` into `.labelle/<target>/scenes/`
   and returns scene name stems.

2. `main_zig.zig` generates:
   - **Scene imports**: `const game_scene = @import("scenes/game.zon");`
   - **SceneLoader type**: `const Loader = engine.SceneLoader(AssembledGame, Prefabs, Components, Scripts);`
   - **Registration**: `g.registerSceneSimple("game", Loader.sceneLoaderFn(game_scene));`
   - **Initial scene**: `try g.setScene("game");`

3. At runtime the engine's comptime `SceneLoader` (`scene/src/loader.zig`):
   - Reads `.scripts` field at comptime via `Scripts.getScriptFnsList()`
   - Reads `.entities` inline at comptime, iterates with `inline for`
   - Resolves entity references, prefab merging, parent-child all at comptime
   - Calls `game.setActiveScene()` with `script_names` from the `.scripts` field

### Engine types involved

- `scene/src/loader.zig` -- `SceneLoader`, `SceneLoaderWithGizmos`, `SimpleSceneLoader`
  - `sceneLoaderFn()` wraps comptime data into a `fn(*GameType) anyerror!void`
  - Reads `.scripts` from scene data, passes to `game.setActiveScene()`
- `scene/src/core.zig` -- `Scene(Entity)` struct
  - Has `scripts: []const ScriptFns` field (populated from comptime .scripts)
  - `initScripts()`, `update()`, `deinit()` iterate this field
- `scene/src/script.zig` -- `ScriptRegistry`, `ScriptFns`, `NoScripts`
  - `getScriptFnsList()` resolves comptime script name tuples to function pointers
- `scene/src/types.zig` -- `RefInfo`, `extractRefInfo`, `isReference`
  - All comptime-only: `comptime val: anytype` parameters
- `scene/src/entity_writer.zig` -- writes components from comptime .zon
- `scene/src/prefab.zig` -- `PrefabRegistry` (comptime .zon prefabs)
- `game.zig` -- `active_scene_script_names` field, `getActiveScriptNames()`
- `game/scene_mixin.zig` -- `setActiveScene()` accepts `script_names` param

---

## Files that need modification

### CLI Generator (`labelle-cli/generator/`)

| File | Change |
|------|--------|
| `src/root.zig` | Remove `copyAndScan` for `scenes` (.zon). Add `copyDirRecursive` for `scenes` (.jsonc) or stop copying scenes entirely (they are loaded at runtime from `assets/`). |
| `src/main_zig.zig` | **Remove**: Scene .zon `@import` generation (lines 71-77). **Remove**: `SceneLoader`/`SceneLoaderWithGizmos` instantiation and `registerSceneSimple` calls in `buildSetupCode` and `buildCallbackInitCode`. **Remove**: `scene_names` parameter from `generateMainZig`. **Add**: Runtime scene directory path configuration so the game knows where to find `.jsonc` scene files at runtime. |
| `src/config.zig` | `initial_scene` field semantics change: instead of selecting from scanned .zon stems, it names the first `.jsonc` scene file to load. Consider whether this field is still needed or whether it becomes a runtime config. |
| `test/tests.zig` | Update all scene-related tests: "loads scenes", "initial_scene overrides", "initial_scene=null falls back", "scene names with slashes". Tests should verify new runtime loading codegen instead of comptime @import patterns. |

### Engine (`labelle-engine/`)

| File | Change |
|------|--------|
| `scene/src/core.zig` | **Remove** `scripts: []const ScriptFns` field from `Scene(Entity)`. Remove `initScripts()`, remove script iteration from `update()` and `deinit()`. Scene scripts are now handled by ScriptRunner's state-scoping, not per-scene. |
| `scene/src/loader.zig` | **Remove entirely** or gut: `SceneLoader`, `SceneLoaderWithGizmos`, `SimpleSceneLoader` are all comptime-only. The runtime equivalent is `jsonc/src/scene_loader.zig`. |
| `scene/src/types.zig` | **Remove** comptime reference resolution (`isReference`, `extractRefInfo`, `getEntityId`, `generateAutoId`). Runtime references use string-based lookup in the JSONC loader. Keep `ReferenceContext`, `PendingReference`, `PendingParentRef` if the runtime loader reuses them. |
| `scene/src/entity_writer.zig` | **Remove** -- comptime entity component writer. Runtime equivalent uses `Value`-based component deserializer. |
| `scene/src/script.zig` | **Remove** `ScriptRegistry.getScriptFnsList()` (resolves comptime scene `.scripts` tuples). Keep `ScriptRegistry` itself since it is still used by ScriptRunner for comptime script dispatch. Keep `ScriptFns`, `NoScripts`. |
| `scene/src/prefab.zig` | Keep `PrefabRegistry` for now -- comptime prefabs (.zon) are a separate concern from scenes. They may migrate to runtime later but that is out of scope. |
| `scene/src/root.zig` | Update re-exports: remove `SceneLoader`, `SceneLoaderWithGizmos`, `SimpleSceneLoader`. |
| `src/scene.zig` | Update re-exports to match root.zig changes. |
| `src/root.zig` | Remove `SceneLoader`, `SceneLoaderWithGizmos`, `SimpleSceneLoader` from engine public API. |
| `src/game.zig` | **Remove** `active_scene_script_names` field. **Remove** `getActiveScriptNames()`. Update `setActiveScene()` signature to drop `script_names` parameter. Script filtering is now handled by `game_states` declarations in script modules + `game_state` field. |
| `src/game/scene_mixin.zig` | Update `setActiveScene()` to drop `script_names`. |
| `src/script_runner.zig` | Remove the `getActiveFilter` / `getActiveScriptNames` check that reads per-scene script names. Script filtering now uses only `game_states` + `game_state`. |
| `test/scene_test.zig` | Update tests -- remove any that test comptime .zon scene loading. |
| `scene/test/loader_test.zig` | **Remove entirely** -- tests the comptime SceneLoader. |

---

## New codegen pattern (what replaces the old)

### Before (comptime .zon)

```zig
// Scene imports
const game_scene = @import("scenes/game.zon");

// In setup:
const Loader = engine.SceneLoader(AssembledGame, Prefabs, Components, Scripts);
g.registerSceneSimple("game", Loader.sceneLoaderFn(game_scene));
try g.setScene("game");
```

### After (runtime JSONC)

Scenes are `.jsonc` files in `assets/scenes/`. The engine loads them at runtime:

```zig
// In setup (no scene @imports, no SceneLoader type):
try g.loadScene("assets/scenes/game.jsonc");
// or:
try g.setInitialScene("game");  // loads assets/scenes/game.jsonc by convention
```

The exact API depends on engine-side changes (a new `loadScene` method on Game
that wraps `jsonc.scene_loader.loadScene` + component deserialization + entity
creation). This is engine work tracked separately.

---

## Backwards compatibility concerns

1. **All existing games break.** Scene `.zon` files must be converted to `.jsonc`.
   The RFC explicitly says "no migration tooling, no dual mode."

2. **Prefabs remain .zon (comptime)** for now. Only scenes move to runtime JSONC.
   `PrefabRegistry` stays unchanged. The runtime `PrefabCache` in the JSONC
   loader handles runtime prefab references from within JSONC scenes.

3. **Script filtering changes.** Previously: scene `.scripts` field listed which
   scripts run. Now: scripts declare `pub const game_states = .{ "playing" };`
   and the ScriptRunner filters by `game.game_state`. Games must add state
   declarations to their scripts.

4. **Scene scripts (init/update/deinit on scene lifecycle)** previously lived in
   `Scene.scripts`. With the removal, scene lifecycle hooks move to the
   game state machine -- entering a state triggers script init, leaving triggers
   deinit.

5. **gui_views field** in scene .zon is also comptime. Need to decide whether
   views are associated with states or loaded from JSONC scene metadata.

---

## Safe incremental changes (this PR)

This PR does NOT break existing games. It makes preparatory changes:

1. **Engine: Remove `scripts` field from `Scene(Entity)` in `scene/src/core.zig`.**
   Scene scripts are now globally registered. The `scripts` field, `initScripts()`,
   and script iteration in `update()`/`deinit()` are vestigial -- the ScriptRunner
   handles all script execution. The Scene struct becomes a pure entity container.

2. **Engine: Remove `getScriptFnsList` from `ScriptRegistry`.**
   This method exists only to resolve the comptime `.scripts` tuple from scene
   .zon files. `ScriptRegistry` itself stays (used by ScriptRunner).

3. **Engine: Remove `scene_script_names` from `sceneLoaderFn` in the comptime loader.**
   Pass `null` for `script_names` in `setActiveScene()` since script filtering
   is now state-based, not scene-based.

4. **Engine: Remove `active_scene_script_names` from Game and related accessors.**
   Script filtering now uses `game_states` exclusively.

These changes decouple the scene system from script ownership, which is the
prerequisite for removing comptime scenes entirely in a follow-up PR.
