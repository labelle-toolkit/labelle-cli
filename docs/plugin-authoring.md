# Authoring a labelle plugin

**Audience:** you're writing a new plugin for the labelle toolkit, or porting an older one that still ships a game-side "bridge" script.

**Outcome:** by the end you'll have a plugin that exports ECS components *and* behavior, gets its lifecycle auto-wired by the assembler, and needs zero glue code in the game repo that consumes it.

> **Background:** this guide is the practitioner's companion to
> [RFC-plugin-controllers](https://github.com/labelle-toolkit/flying-platform-labelle/blob/main/docs/RFC-plugin-controllers.md)
> (issue #208). The RFC explains *why* the controller contract exists —
> this doc covers how to write one.

---

## Mental model

A labelle plugin has three layers, and the line between them matters:

| Layer         | What it is                                  | Who owns lifetime          |
|---------------|---------------------------------------------|-----------------------------|
| **Components** | Data attached to entities (ECS).            | The game's save file.       |
| **Controller** | The plugin's behavior, state, and API.      | The assembler (scene-load). |
| **Plugin scripts** | Per-frame work the Controller needs.    | The assembler (tick loop).  |

Two rules fall out of this split:

1. **Components are the unit of saveable state.** Anything that survives a save/load cycle belongs on a component.
2. **Controllers are the unit of behavior.** Anything that allocates, ticks, or decides belongs on the Controller — never in a game-side script that re-creates plugin state.

If you find yourself writing a `scripts/playing/0X_<myplugin>_bridge.zig` in the game, you're doing it wrong. The static rule in
[`scripts/rules/no_plugin_bridges.zig`](https://github.com/labelle-toolkit/flying-platform-labelle/blob/main/scripts/rules/no_plugin_bridges.zig)
enforces this at CI time: any file under `scripts/` that imports a plugin and owns a module-level `var` of a plugin-owned state type fails the build.

---

## Repository layout

A plugin's repo looks like this:

```
my-plugin/
├── build.zig
├── build.zig.zon
├── plugin.labelle              # manifest (optional but recommended)
├── src/
│   ├── root.zig                # exports Controller, Components
│   ├── controller.zig          # the Controller itself
│   └── components.zig          # ECS components the plugin defines
└── scripts/                    # optional — only if you need per-frame work
    └── playing/
        └── 01_my_tick.zig      # one-line `Controller.advance(...)` style
```

The `scripts/` directory is a **reserved convention name**: the assembler auto-discovers it and copies every `.zig` into the generated build tree under `.labelle/<target>/scripts/.plugin_<name>/`. You don't need a `convention_dirs` entry for it.

---

## Step 1 — the manifest

Ship a `plugin.labelle` at the repo root:

```zon
.{
    .name = "my_plugin",
    .manifest_version = 1,
    .convention_dirs = .{},
}
```

The manifest is optional — a plugin without one still works via auto-discovery — but declaring `manifest_version = 1` explicitly opts you into the version handshake, future-proofing against a breaking schema bump.

If your plugin introduces its own convention directory (e.g. `state_machines/` for labelle-fsm), add a `convention_dirs` entry. See
[RFC: Plugin Manifest](./RFC-plugin-manifest.md) for the field reference.

**Controller discovery does not go through the manifest.** The assembler scans your plugin's root module at comptime for `pub const Controller`. Manifest controls directory layout; Zig code controls behavior.

---

## Step 2 — the Controller export

Export a `pub const Controller` from your plugin's root module. The minimum shape is:

```zig
// src/root.zig
pub const Controller = @import("controller.zig").Controller;
```

```zig
// src/controller.zig
pub const Controller = struct {
    /// Optional. Runs once on scene-load after the world is built.
    pub fn setup(game: anytype) !void { /* allocate state */ }

    /// Optional. Runs once on scene-unload before the world is torn down.
    pub fn deinit(game: anytype) void { /* free state */ }

    // Public API — re-exported to game scripts as `my_plugin.Controller.*`
    pub fn doSomething(game: anytype, entity: anytype, /* ... */) Result { /* ... */ }
};
```

Rules:

- **`setup` / `deinit` are both optional.** Omit whichever you don't need. The assembler uses `@hasDecl` to decide.
- **Public methods take `game: anytype`.** The assembler doesn't plumb a concrete game type through — you read state via `game.active_world.ecs_backend`, `game.allocator`, `game.getPosition(entity)`, etc.
- **Return a `Result`.** Four-variant union recommended — `.accepted`, `.redundant`, `.deferred: Reason`, `.rejected: Reason`. This composes naturally with `WorkerController.apply`'s result and lets callers react uniformly. See [RFC §3](https://github.com/labelle-toolkit/flying-platform-labelle/blob/main/docs/RFC-plugin-controllers.md#3-public-api-export).
- **The Controller is the sole writer of its state.** Game scripts read freely, but writes go through the Controller's public API. No bridge, no reaching in.

---

## Step 3 — state storage

Two patterns, in order of preference:

### Primary: singleton ECS component

Store state inside a transient ECS component, created in `setup`, torn down in `deinit`, looked up through the active world's backend. This is the pattern pathfinder uses today, and it's the recommended default.

Why: it keeps controller state inside the existing world abstraction, so multi-world features (background sim, split-screen, UI scenes) can be added later without re-architecting every plugin.

```zig
pub const ControllerState = struct {
    pub const save_policy: @import("labelle-core").SavePolicy = .transient;
    state_ptr: usize = 0, // type-erased *State
};

const State = struct {
    /* allocator, maps, ring buffers, ... */
};

pub const Controller = struct {
    pub fn setup(game: anytype) !void {
        const st = try game.allocator.create(State);
        st.* = State.init(game.allocator);
        const entity = game.createEntity();
        game.active_world.ecs_backend.addComponent(entity, ControllerState{
            .state_ptr = @intFromPtr(st),
        });
    }

    pub fn deinit(game: anytype) void {
        const entity = findStateEntity(game) orelse return;
        if (game.active_world.ecs_backend.getComponent(entity, ControllerState)) |cs| {
            if (cs.state_ptr != 0) {
                const st: *State = @ptrFromInt(cs.state_ptr);
                st.deinit();
                game.allocator.destroy(st);
            }
        }
    }

    fn findState(game: anytype) ?*State {
        const entity = findStateEntity(game) orelse return null;
        const cs = game.active_world.ecs_backend.getComponent(entity, ControllerState) orelse return null;
        if (cs.state_ptr == 0) return null;
        return @ptrFromInt(cs.state_ptr);
    }
};
```

Mark the component `.transient` — state is rebuilt on every scene load, it should **never** hit the save file. Expose `ControllerState` through `pub const Components` on your root module so the CLI auto-registers it like any other plugin component.

### Fallback: module-level pointer

For controllers with no per-world state (or where multi-world is explicitly out of scope), a module-level pointer is acceptable:

```zig
var g_state: ?*State = null;

pub fn setup(game: anytype) !void {
    g_state = try game.allocator.create(State);
    g_state.?.* = try State.init(game.allocator);
}

pub fn deinit(game: anytype) void {
    if (g_state) |s| {
        s.deinit();
        game.allocator.destroy(s);
        g_state = null;
    }
}
```

Always `?*State`, never `var state: State = .{}`. The pointer form keeps allocation explicit and lets `deinit` null it back out, which matters if the plugin is re-initialized after a scene swap.

### What not to do

```zig
// ❌ Module-level var typed with the plugin's state struct.
// Trips the no_plugin_bridges CI rule if it lives under scripts/.
var state: MyPluginState = .{};

// ❌ `pub` state. Cross-plugin coupling goes through hooks, not direct access.
pub var g_state: ?*State = null;

// ❌ Forgetting to mark ControllerState .transient. Save file will break.
pub const ControllerState = struct { state_ptr: usize = 0 };
```

---

## Step 4 — per-frame work (optional)

Controllers are event-driven by default — game scripts call `Controller.do_x(...)` and the method mutates state synchronously. Plugins with per-frame follow-up (ticking a pathfinder, flushing a command log, running a behavior-tree layer) expose that as a regular method on the Controller and ship a one-line script to invoke it:

```zig
// In Controller:
pub fn advance(game: anytype, dt: f32) void { /* ... */ }
```

```zig
// In libs/my_plugin/scripts/playing/01_my_tick.zig:
const my_plugin = @import("my_plugin");

pub fn tick(game: anytype, dt: f32) void {
    my_plugin.Controller.advance(game, dt);
}
```

### Tick ordering

The assembler emits two ordered blocks into the generated tick:

1. **Game scripts**, sorted by the numeric prefix (`01_`, `02_`, …) inside the game's own `scripts/playing/`.
2. **Plugin scripts**, per-plugin in the order they appear in `project.labelle`'s `.plugins` array. Within a plugin, its own `scripts/playing/*.zig` are numeric-prefix-ordered.

This means:

- Game scripts emit intents during the frame (`navigate`, `enqueue_command`, …).
- Plugin scripts process the accumulated state at end of frame (`advance`, `flush`, …).
- No prefix collisions between game and plugin scripts — each lives in its own namespace.
- Reordering plugins is a one-line edit to `project.labelle`.

If your plugin has no per-frame work (event-driven only — worker_controller, fsm), ship no `scripts/` directory. Only `setup` / `deinit` get auto-wired.

---

## Step 5 — components and the save contract

A plugin typically exports a `Components` struct from its root module so the assembler picks them up:

```zig
// src/root.zig
pub const Components = struct {
    pub const MyMarker = components.MyMarker;
    pub const MyData   = components.MyData;
    pub const ControllerState = controller_mod.ControllerState;
};
```

Each component declares its save policy:

```zig
// Saveable — survives save/load. Use for state that represents the
// player's game.
pub const MyData = struct {
    pub const save = @import("labelle-core").save_policy.Saveable(.saveable, @This(), .{});
    value: u32,
};

// Transient — skipped by save/load. Use for Controller-owned state.
pub const ControllerState = struct {
    pub const save_policy: @import("labelle-core").SavePolicy = .transient;
    state_ptr: usize = 0,
};
```

Rule of thumb: if the player would notice it missing after a reload, it's saveable. If it's a heap allocation the Controller rebuilds on `setup`, it's transient.

For components that reference an entity (a `Parent`, a `target` entity, etc.), declare the reference field in `.entity_refs` so save/load can remap IDs:

```zig
pub const save = save_policy.Saveable(.saveable, @This(), .{
    .entity_refs = &.{"target"},
});
target: Entity,
```

---

## Step 6 — calling the Controller from game scripts

From a game script, import the plugin and call through `Controller`:

```zig
// scripts/playing/03_worker_movement.zig
const pathfinder = @import("pathfinder");

pub fn tick(game: anytype, dt: f32) void {
    _ = dt;
    // ...decide to start navigating...
    switch (pathfinder.Controller.navigate(game, worker, target, @src())) {
        .accepted, .redundant => {},
        .deferred => |r| game.log.debug("defer: {}", .{r}),
        .rejected => |r| game.log.err("reject: {}", .{r}),
    }
}
```

Side effects live on the caller side of `.accepted` / `.redundant`; on `.deferred` / `.rejected` the caller backs off so the controller can reject or retry cleanly. This shape is the same one `WorkerController.apply` uses — scripts that drive both (most do) can fold the responses together.

---

## Walk-through: the pathfinder plugin

Pathfinder is the canonical example because it exercises every layer: setup / deinit, a public API, per-frame work, and a singleton-component state store. Read these files in order:

1. **`libs/pathfinder/plugin.labelle`** — manifest opts in to the version handshake. Nothing else; `scripts/` is auto-discovered.
2. **`libs/pathfinder/src/root.zig`** — re-exports the `Controller`, `Components`, and the legacy `PathfinderContext` alias kept for one release's migration grace.
3. **`libs/pathfinder/src/controller.zig`** — `ControllerState` singleton component, `setup` / `deinit`, public API (`navigate`, `cancel`, `findClosestNode`, `distance`), and `advance` for per-frame work.
4. **`libs/pathfinder/scripts/playing/01_advance.zig`** — the one-line plugin-shipped script that invokes `Controller.advance(game, dt)`.
5. **`scripts/playing/01_pathfinder_dispatch.zig`** (game side) — translates the game's request-packet components (`NavigationIntent`, `NeedsClosestNode`) into `Controller.navigate` / `Controller.findClosestNode` calls. No state lives here.

Before the migration there was a 580-line `scripts/playing/01_pathfinder_bridge.zig` in the game repo that re-derived the library's mutator API. It drifted (missing Y-filter in nearest-node search, missing node-ID writeback, divergent `processNeedsClosestNode`) and caused real gameplay bugs. All of that is now gone — the game-side code is purely dispatch.

---

## Checklist for a new plugin

- [ ] `plugin.labelle` at the repo root with `manifest_version = 1`.
- [ ] `pub const Controller` exported from `src/root.zig`, with at minimum one public method.
- [ ] If the plugin holds state: singleton `ControllerState` component, `.transient`, pointer-typed `state_ptr`.
- [ ] `setup` allocates and attaches state; `deinit` frees it. Both idempotent across scene reloads.
- [ ] Public methods take `game: anytype`, return a four-variant `Result`, and `findState(game)` up front.
- [ ] If per-frame work is needed: one-line `scripts/playing/<N>_<verb>.zig` invoking the Controller method.
- [ ] Components exported through `pub const Components` on the root module, each declaring its save policy.
- [ ] No game-side `scripts/` file imports your plugin *and* owns a module-level `var` of a plugin-owned type. Run `zig run scripts/rules/no_plugin_bridges.zig` locally to confirm.
- [ ] The plugin compiles and runs against the assembler from `labelle run`.

---

## Further reading

- [RFC-plugin-controllers](https://github.com/labelle-toolkit/flying-platform-labelle/blob/main/docs/RFC-plugin-controllers.md) — why this contract exists and how it evolved.
- [RFC-plugin-manifest](./RFC-plugin-manifest.md) — the `plugin.labelle` manifest schema.
- [`examples/plugin-controllers/`](https://github.com/labelle-toolkit/labelle-assembler/tree/main/examples/plugin-controllers) in labelle-assembler — the minimal end-to-end working example. Smallest thing you can copy and modify.
- [`scripts/rules/README.md`](https://github.com/labelle-toolkit/flying-platform-labelle/blob/main/scripts/rules/README.md) — the runtime-rule vs. static-rule split; `no_plugin_bridges.zig` is the CI-level guardrail.
- [`libs/pathfinder/`](https://github.com/labelle-toolkit/flying-platform-labelle/tree/main/libs/pathfinder) — canonical Controller implementation.
- [`libs/worker_controller/`](https://github.com/labelle-toolkit/flying-platform-labelle/tree/main/libs/worker_controller) — Controller with no per-frame work (pure event handler).
