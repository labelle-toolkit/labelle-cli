# RFC: Runtime Scene Loading & Hot Reload

## Problem Statement

Scenes are currently defined in `.zon` files that are `@import`ed at compile time. Every scene edit — moving an item, adjusting a camera, adding an entity — triggers a full recompile of the game. This makes level design iteration painfully slow, especially as scenes grow in complexity.

The comptime approach also means:
- No tooling can edit scenes without understanding Zig's comptime evaluation
- Scene data is baked into the binary — no way to ship scene updates without recompiling
- Hot reload is impossible since there's no runtime scene representation separate from compiled code

## Goals

1. **Runtime scene loading** — parse scene files from disk at load time, not compile time
2. **Hot reload** — detect scene file changes and reload without restarting the game
3. **Preserve developer experience** — scene files should remain human-readable and easy to edit
4. **Maintain type safety** — component instantiation should catch errors early, even without comptime
5. **Performance** — scene loading should be fast enough to not break the game loop during hot reload

## Non-Goals

- Full visual scene editor (future work, but this RFC enables it)
- Hot reload of scripts/Zig code (requires recompilation, out of scope)
- Networked scene streaming

## Decisions

### Scene File Format: JSONC

**JSONC** (JSON with `//` line comments, `/* */` block comments, and trailing commas).

Why not ZON:
- ZON is Zig-specific — no external tooling will ever support it
- ZON spec may change across Zig versions
- `.enum_literal` syntax (`.dynamic`, `.hydroponics`) has no equivalent in other tools

Why JSONC over plain JSON:
- Comments are essential for scene files (labeling entity groups, explaining layout)
- Trailing commas produce cleaner diffs

Why not YAML/TOML/XML:
- YAML: whitespace-sensitive, implicit type coercion (`yes`→`true`, Norway problem), massive spec
- TOML: breaks down with deep nesting (scene data is 4-5 levels deep)
- XML: verbose, closing tags, no native arrays

Enum values become strings in JSONC (`"dynamic"` not `.dynamic`). The deserializer handles both.

### Component Instantiation: Comptime-Generated Deserializers

Use `@typeInfo` at comptime to auto-generate `Value → T` deserializer for each registered component type. Handles structs (with defaults), enums, tagged unions, ints, floats, bools, strings, slices, and optionals. Integer-to-float coercion is automatic.

### Prefab Resolution: Runtime

Prefabs are runtime files, same as scenes. They benefit equally from hot reload. A level designer repositioning prefab children shouldn't need a recompile.

### Scene Composition

Scenes support two composition mechanisms:

**`include`** — merge entities from fragment files:
```jsonc
{
    "name": "main",
    "include": ["scenes/floor1.json", "scenes/floor2.json"],
    "entities": [...]
}
```

**`children`** — prefabs can define child entities:
```jsonc
// prefabs/water_well.json
{
    "components": { "Room": {} },
    "children": [
        { "prefab": "water_well_workstation", "components": { "Position": { "x": 78, "y": 47 } } },
        { "prefab": "movement_node", "components": { "Position": { "x": 23, "y": 93 } } }
    ]
}
```

The unified model:
```
Scene       = name + camera + include[] + entities[]
Fragment    = include[] + entities[]                  (loaded via include)
Prefab      = components + children[] + includes[]    (entity template with composition)
Entity      = prefab? + components + children[]       (instance)
```

Include depth is capped at 16 levels to prevent infinite loops.

### Hot Reload Strategy

Start with manual reload (F5 keypress), then add mtime-based file watching. Full scene reload on change (teardown → re-read → rebuild). Arena-swapped memory management ensures clean reload with no leaks.

The watcher monitors both scene files and prefab files — editing a prefab triggers a full scene reload.

### No Backward Compatibility

Clean break. Comptime scenes are removed, not deprecated. Runtime JSONC is the only scene format. No migration tooling, no dual mode.

## Proposed Architecture

```
Scene File (.json on disk)
    │
    ▼
JSONC Parser ─── ParsedValue (generic key-value tree)
    │
    ▼
Component Registry ─── maps "Position" → Position.deserialize(parsed_data)
    │
    ▼
Scene Loader ─── creates entities, resolves refs, merges prefabs, expands children
    │
    ▼
Runtime Scene (entities + components ready for ECS)
```

### Key Changes to Engine

1. **New: `scene/src/jsonc_parser.zig`** — JSONC parser, returns generic `Value` tree
2. **New: `scene/src/component_registry.zig`** — string → typed deserializer map, auto-generated via `@typeInfo`
3. **Modified: `scene/src/loader.zig`** — accepts `Value` instead of comptime `.zon` data, handles `include` and `children`
4. **New: `scene/src/hot_reload.zig`** — file watcher + arena-swapped reload orchestrator
5. **New: `game/state_mixin.zig`** — game state machine
6. **Modified: `game.zig`** — adds `reloadCurrentScene()`, game state, state-scoped script execution

### Entity References

Entity references (`{ "ref": { "entity": "player" } }`) work the same way — resolved in Phase 2 after all entities are created. The parsed `Value` tree preserves the reference structure, so no special parser work is needed. Resolution logic belongs in the ECS bridge during engine integration.

### Error Handling

Runtime parsing means runtime errors are possible (typos, missing components, type mismatches). The system should:
- Report clear errors with file name, line number, and field path
- In dev mode: log errors and skip the broken entity (don't crash)
- In release mode: fail fast with a clear message

## Decision: Global Scripts with Game States

**Scripts are no longer declared per-scene.** All scripts are registered globally at startup. On each tick, only scripts matching the current game state execute.

**Script-to-state binding is convention-based** — the directory structure defines which states a script runs in:

```
scripts/
├── save_load.zig                   # root = runs in ALL states
├── playing/
│   ├── 01_pathfinder_bridge.zig    # only in "playing", runs first
│   ├── navigation/
│   │   ├── 02_nav_orchestrator.zig # organizational subdir, same state
│   │   └── 03_worker_movement.zig
│   ├── production/
│   │   ├── 04_workstation_readiness.zig
│   │   └── 05_production_system.zig
│   └── gizmos/
│       ├── tendable_gizmos.zig     # no prefix = after numbered, alphabetical
│       └── item_gizmos.zig
├── playing+paused/
│   └── camera_control.zig          # in "playing" AND "paused"
├── menu/
│   └── menu_system.zig
└── paused/
    └── pause_overlay.zig
```

**Convention rules:**
- `scripts/*.zig` → runs in all states (global)
- `scripts/<state>/*.zig` → runs only in that state
- `scripts/<state1>+<state2>/*.zig` → runs in multiple states
- `scripts/<state>/subdir/*.zig` → organizational subdirectories, same state as parent (recursive)
- The `+` separator avoids symlinks or file duplication
- Only the first-level directory under `scripts/` defines the state — deeper directories are purely organizational
- Numeric prefix controls execution order: `01_foo.zig` before `02_bar.zig`, prefix stripped from script name
- Scripts without a prefix sort after numbered ones, alphabetically
- Duplicate numeric prefixes within the same state scope (including across organizational subdirs) are a **build error**
- Same prefix numbers in different state scopes are allowed

**States are defined in `project.labelle`:**
```
.states = .{ "menu", "playing", "paused" },
```
First element is the initial state. Default (if omitted): `.states = .{ "running" }`.

State names must be lowercase alphanumeric with underscores only (`[a-z0-9_]+`). No spaces, no special characters. This ensures they work as directory names on all platforms.

The assembler scans the `scripts/` directory structure at build time and generates the registration code. No config files, no annotations in script source code.

**What this means for scene files:**
- Scenes no longer have a `scripts` field
- Scenes define entities only
- Simpler scene files, fewer "forgot to add the script" bugs
- Hot reload of scenes doesn't need to rewire scripts — they're always registered

## Prerequisite: Game States

Labelle currently has no game state system. It has `time_scale` (0 = paused) and scene switching, but no state machine. This needs to be added to the engine.

### Design

**Engine additions (`labelle-engine/src/game/state_mixin.zig`):**
- `game.state` — current state (string), initially the first element of `.states`
- `game.setState(new_state)` — transition immediately, fires script init/deinit
- `game.queueStateChange(new_state)` — deferred transition (next frame)
- State transitions emit hooks: `state_before_change`, `state_after_change`
- Scripts get `init` called on state entry, `deinit` on state exit, `init` again on re-entry

**Tick behavior:**
```
for each registered script:
    if script.states contains game.state:
        script.update(game, dt)
```

Scripts in `scripts/` root (no state filter) run in all states.

### Relationship to scenes

Game states and scenes are **orthogonal**:
- A scene defines what entities exist
- A game state defines what scripts run
- Changing scene doesn't change state (and vice versa)
- You can be in state `"playing"` with scene `"level_1"` or `"level_2"`
- You can be in state `"paused"` and still be in the `"level_1"` scene (pause overlay renders on top)

This separation means scene hot reload only touches entities — the script system is unaffected.

## POC Results

All POCs live in `v2/poc/runtime-scenes/`. **247 tests passing.**

| POC | Module | Tests | What it proves |
|-----|--------|-------|----------------|
| 1 | `parser.zig` | 16 | Runtime ZON parser — parses all real scene/prefab files |
| 2 | `deserialize.zig` | 35 | `@typeInfo`-generated deserializers — structs, enums, unions, floats, bools, slices |
| 3 | `scene_loader.zig` | 48 | End-to-end scene loading — prefab merging, children composition, includes, real file loading |
| 4 | `hot_reload.zig` | 55 | Mtime polling, arena-swapped reload, prefab change detection, simulated game loop |
| 5 | `jsonc_parser.zig` | 67 | JSONC parser producing same `Value` tree — plugs into same deserializer and scene loader |
| 6 | `game_state.zig` | 12 | State machine with script scoping, init/deinit lifecycle, queued transitions |
| 7 | `script_scanner.zig` | 14 | Convention-based directory scanning, numeric ordering, recursive subdirs, duplicate detection |

Key validations:
- POC 5 proves JSONC and ZON are interchangeable — same `Value` tree, same downstream pipeline
- POC 3 loads the real `flying-platform-labelle/scenes/main.zon` with all prefabs merged from disk
- POC 4 demonstrates 100 consecutive reloads with no memory leaks (arena swap)
- POC 7 catches duplicate sort orders at build time with clear error messages

## Open Questions

1. Should entity IDs be stable across reloads (for debugging/tooling)?
2. What's the performance budget for scene parsing? (Target: <16ms for typical scenes)

## Implementation Order

1. Add `.states` field to `project.labelle` (default: `"running"`)
2. Add `game.state`, `setState()`, `queueStateChange()`, hooks to engine
3. Add JSONC parser to engine's scene module
4. Add runtime component deserializer (comptime-generated from registry)
5. Replace scene loader — `Value` tree input, `include`, `children`, prefab merging
6. Add hot reload orchestrator to engine
7. Update labelle-cli assembler to scan `scripts/` directory structure and generate state-scoped registration
8. Modify tick loop to check state before calling script update
9. Remove comptime scene loading, `.zon` scene support, and `scripts` field from scenes
10. Convert example games to JSONC scenes + script directories
