# RFC: Build Pipeline — Embed Scenes in Release, Skip Recompilation in Dev

Tracking issue: #105

## Status

Draft — open for discussion.

---

## Background

With the removal of comptime `.zon` scene loading (RFC-remove-comptime-scenes.md),
scenes are now `.jsonc` files loaded from disk at runtime via
`std.fs.cwd().openFile()`. This enables hot reload during development — the
`HotReloader` in `labelle-engine/jsonc/src/hot_reload.zig` detects mtime changes
and triggers a scene re-parse without recompilation.

However, shipping a compiled game with loose `.jsonc` files is problematic:

1. **Distribution** — the binary is not self-contained; scene/prefab files must
   be distributed alongside it.
2. **Tampering** — players can edit scene files to modify game behavior.
3. **Filesystem dependency** — the game requires working-directory-relative file
   access at runtime, which breaks in some packaging/installation scenarios.
4. **Inconsistency** — prefabs (`.zon`) are already `@import`'d at comptime and
   baked into the binary, but scenes are not.

---

## Proposal

Introduce a **dev / release split** in the CLI codegen pipeline so that:

- `labelle run` (dev) — scenes and prefabs are loaded from disk at runtime
  (current behavior). Hot reload works.
- `labelle build` or `labelle build --release` — scenes and prefabs are
  **embedded into the binary** at compile time. No loose data files in the
  output. Hot reload is disabled.

### What changes

The split affects three layers:

#### 1. CLI generator (`generator/src/main_zig.zig`)

The generated `main.zig` currently always emits runtime file loading:

```zig
// Current (runtime loading — always)
fn load(game: *AssembledGame) anyerror!void {
    return JsoncBridge.loadScene(game, "scenes/main.jsonc", "prefabs");
}
```

For release builds, the generator would instead emit:

```zig
// Release (embedded)
const scene_data = @embedFile("scenes/main.jsonc");
fn load(game: *AssembledGame) anyerror!void {
    return JsoncBridge.loadSceneFromMemory(game, scene_data, &embedded_prefabs);
}
```

The generator already knows the list of scene and prefab files from the scanner.
The mode would be determined by a flag passed through the build pipeline.

#### 2. Engine scene bridge (`jsonc_scene_bridge.zig`)

Add a `loadSceneFromMemory` entry point alongside the existing `loadScene`:

- `loadScene(game, path, prefab_dir)` — current behavior, reads files from disk.
- `loadSceneFromMemory(game, scene_bytes, prefab_map)` — parses from an
  in-memory buffer. The JSONC parser already works on `[]const u8` slices, so
  this is mostly plumbing.

Similarly, the `PrefabCache` would gain a comptime variant that holds embedded
prefab data instead of scanning a directory.

#### 3. CLI build orchestration (`src/cli.zig`)

The `labelle build` command already runs `zig build`. It would pass a build
option (e.g., `-Dembed_scenes=true`) to the generated `build.zig`, which
controls whether `@embedFile` paths are included in the module.

Alternatively, the generator could simply emit different `main.zig` code
depending on the build mode, avoiding the need for Zig build options entirely.

---

## Design decisions

### `@embedFile` vs. packed asset blob

| Approach | Pros | Cons |
|---|---|---|
| `@embedFile` per scene | Simple, no new tooling, Zig handles it | One `@embedFile` per file, binary has raw JSONC text |
| Single packed blob | One file, potential for compression | Needs a packing tool, index format, decompression at startup |

**Recommendation**: start with `@embedFile` — it is trivial to implement and
the JSONC files are small. A packed blob can be added later if binary size
becomes a concern.

### Prefab handling — move to runtime JSONC in dev mode

Prefabs are currently `.zon` files `@import`'d at comptime in the generated
`main.zig`:

```zig
const Prefabs = engine.PrefabRegistry(.{
    .player = @import("prefabs/player.zon"),
    .goblin = @import("prefabs/goblin.zon"),
});
```

This means **any prefab edit triggers a full recompile**, same as game scripts.
But the runtime infrastructure to load prefabs from disk already exists — the
`PrefabCache` inside `jsonc_scene_bridge.zig` loads `.jsonc` prefab files at
runtime when a scene references them via `"prefab": "player"`.

In fact, **prefabs are already runtime JSONC in practice**. The flying-platform
game has 24 `.jsonc` prefab files, all loaded at runtime by `PrefabCache`.
The generator finds no `.zon` prefabs and emits `PrefabRegistry(.{})` — an
empty struct doing nothing. The comptime prefab path is dead weight.

This is not a migration — it is already done at the game level. The only
cleanup needed is in the toolchain:

#### Cleanup

1. Remove `PrefabRegistry` generation from `main_zig.zig` (lines 133–143)
2. Remove or deprecate `PrefabRegistry` type from engine
3. Stop scanning for `.zon` prefabs in the generator's `copyAndScan`
4. `PrefabCache` is already the single prefab loading mechanism

#### Release mode

For release builds, prefab `.jsonc` files get `@embedFile`'d alongside scenes.
`PrefabCache` gains a comptime variant that reads from embedded memory instead
of disk — same approach as scenes.

### Build mode detection

Two options:

1. **Generator-time**: the CLI knows whether the user ran `labelle run` vs
   `labelle build --release` and emits different `main.zig` code.
2. **Zig build-time**: the generated `build.zig` exposes a `-Dembed_scenes`
   option and the generated code uses `if (build_options.embed_scenes)`.

Option 1 is simpler and avoids conditional compilation in generated code.
Option 2 allows toggling without re-running the generator.

**Recommendation**: Option 1 — the generator already regenerates on every
invocation, so the extra flexibility of Option 2 is not needed.

---

## Precompiling the engine and core

### The question

Can we compile `labelle-core` and `labelle-engine` once, cache them as `.a`
(static library) files, and link them into game builds without recompiling?
This would make game script changes compile in seconds instead of rebuilding
the entire dependency tree.

### How it works today

The generated `build.zig` consumes everything as **Zig source modules**:

```zig
const engine_dep = b.dependency("engine", .{ .target = target, .optimize = optimize });
const engine_mod = engine_dep.module("engine");
// → engine source is recompiled from scratch on every build
```

Zig's `.zig-cache/` provides incremental caching — so the second build is
faster than the first. But the build system still walks the full dependency
graph every time to determine staleness, and any change to game code that
touches engine generics triggers re-monomorphization.

### The comptime problem

The engine makes heavy use of comptime generics:

```zig
pub fn JsoncSceneBridge(comptime GameType: type, comptime Components: type) type { ... }
pub fn Mixin(comptime Game: type) type { ... }
pub fn Game(comptime Components: type, comptime Scripts: type, ...) type { ... }
```

These types are **monomorphized at compile time** based on each game's concrete
component/script types. A precompiled `.a` file cannot contain this generic
code — the compiler needs the game's types to instantiate it.

This means the engine **cannot be fully precompiled** as a static library
without changing its architecture.

### What CAN be precompiled

Not all engine code is generic. The dependency tree has layers:

| Layer | Generic? | Precompilable? |
|---|---|---|
| `labelle-core` (math, Position, types) | No | **Yes** |
| `labelle-gfx` (sprite/shape types) | No | **Yes** |
| JSONC parser (`jsonc/`) | No | **Yes** |
| Backend C libs (raylib, sokol) | No | **Yes** (already `.a` via Zig) |
| ECS adapter | Partially | Partially |
| Engine game loop, scene bridge, mixins | **Heavily generic** | No |
| **Plugins** (debug, imgui, nuklear) | **Heavily generic** | **No** |

Plugins use `game: anytype` and comptime introspection throughout — they
iterate over the game's component registry at compile time, access game-specific
types, and use `inline for` over component names. For example, the debug plugin
calls `@TypeOf(game.*).ComponentRegistry`, `Reg.names()`, and `Reg.getType(name)`
to render the entity browser. This means plugins must be compiled together with
the game, same as the generic engine code.

The non-generic parts — core, gfx, JSONC parser, C backends — could be
precompiled into static libraries and linked directly. This skips their
compilation entirely when only game scripts change.

### Proposed approach: hybrid source + precompiled

Split the generated `build.zig` into two layers:

1. **Precompiled layer** — core, gfx, JSONC parser, backend C libs compiled
   once into `.a` files cached in `.labelle/cache/libs/`. Only rebuilt when
   the engine version changes or the target/optimize options change.

2. **Source layer** — engine (generic), game scripts, generated `main.zig`
   compiled from source every time. Links against the precompiled `.a` files.

```
.labelle/
  cache/
    libs/
      labelle-core-aarch64-macos-debug.a      ← compiled once
      labelle-gfx-aarch64-macos-debug.a       ← compiled once
      jsonc-aarch64-macos-debug.a             ← compiled once
      raylib-aarch64-macos-debug.a            ← compiled once (already works this way)
  raylib_desktop/
    main.zig                                   ← compiled from source (game-specific)
    build.zig                                  ← links precompiled .a + compiles engine+game
```

The cache key would be: `{package_version}-{target}-{optimize}`. When any of
those change, the `.a` is rebuilt.

### Implementation

The generated `build.zig` would:

1. Check if a cached `.a` exists for core/gfx/jsonc at the right version+target
2. If yes: `exe.addObjectFile(.{ .cwd_relative = "cache/libs/labelle-core-....a" })`
3. If no: build from source as today, then cache the result

This requires the non-generic packages to expose a `build.zig` that can
produce a static library artifact, not just a module. Core and gfx may already
do this or can be trivially extended.

### Impact

| Scenario | Today | With precompiled cache |
|---|---|---|
| First build (cold cache) | ~same | ~same (builds + caches) |
| Game script change | Rebuilds everything | **Engine/core skipped, only game code compiles** |
| Engine version bump | Rebuilds everything | Rebuilds + re-caches engine |
| Target change (e.g. WASM) | Rebuilds everything | Rebuilds + re-caches for new target |

The biggest win is the **game script change** case — the most common dev loop.
Instead of recompiling core + gfx + jsonc + engine + game, you only compile
engine (generic parts) + game.

### Limitations

- The engine's generic code (`Game`, `Mixin`, `JsoncSceneBridge`) cannot be
  precompiled. This is the largest chunk of engine code. Replacing comptime
  generics with runtime polymorphism (vtables) is **not desirable** — the
  comptime approach lets Zig inline across the engine/game boundary and
  eliminate dynamic dispatch. For a game engine running thousands of entities
  per frame, that performance matters. We accept that generic engine code
  recompiles with the game.
- Zig's build system doesn't natively support "output a .a from a dependency
  and cache it externally." This would require custom build logic in the CLI
  or a wrapper build step.
- Cross-target builds (e.g. building for WASM and desktop) need separate
  cached artifacts per target.

---

## Scope

### In scope

- `@embedFile` embedding of `.jsonc` scene files in release builds
- `loadSceneFromMemory` engine entry point
- Generator-time dev/release code path split
- Remove dead `PrefabRegistry` generation from codegen
- Prefab `.jsonc` embedding via `@embedFile` in release builds
- Codegen fingerprinting to skip regeneration when inputs are unchanged
- Binary mtime check to skip compilation when no `.zig` source changed
- Merge the two `zig build` invocations into a single `zig build run`
- Incremental scene/asset sync (copy only changed files)
- Precompiled `.a` caching for non-generic packages (core, gfx, jsonc, backends)

### Out of scope

- Asset embedding (images, audio) — separate concern, typically handled by the
  backend/renderer
- Compression or binary packing — future optimization
- Obfuscation or encryption of embedded data
- File watching / daemon mode (e.g., `labelle watch` that stays running and
  re-launches on changes) — future enhancement
- Reducing engine comptime generics — the generics exist for performance
  (inlining, zero-cost dispatch); replacing them with vtables would hurt
  runtime performance for the sake of compile times

---

## Migration

No breaking changes. The default behavior (`labelle run`) remains unchanged.
`labelle build` gains embedded scenes automatically. Game authors do not need
to modify their projects.

---

## Dev mode: skip unnecessary work on `labelle run`

### The problem today

Every `labelle run` unconditionally executes three expensive steps, even when
nothing has changed (`src/cli.zig` lines 390–454):

```
1. Regenerate   — copy ALL files (scripts, scenes, components, prefabs, assets)
                  + generate build.zig and main.zig                    [I/O heavy]
2. zig build    — invoke the Zig build system                          [redundant]
3. zig build run — invoke the Zig build system AGAIN, then launch      [builds twice]
```

Even if the developer only changed a `.jsonc` scene file (which is loaded at
runtime and never compiled), the CLI still copies every file, regenerates all
build files, and invokes `zig build` twice.

Step 2 (`zig build` on line 411) and step 3 (`zig build run` on line 454) both
invoke the Zig build system. The separate `zig build` exists for error
reporting — if it fails, the CLI prints the error and stops. But this means
every successful run pays for two full build-system invocations.

### What should happen

```
labelle run
  ├─ Has project.labelle or codegen inputs changed?
  │    NO  → skip regeneration
  │    YES → regenerate
  ├─ Has any .zig source changed since last successful build?
  │    NO  → skip compilation, launch existing binary
  │    YES → zig build run (single invocation — builds + runs)
  └─ launch
```

### Proposed changes

#### 1. Skip regeneration when codegen inputs are unchanged

The generator copies and scans these directories:

| Directory | Extension | Triggers codegen? | Triggers recompilation? |
|---|---|---|---|
| `scripts/` | `.zig` | Yes | Yes |
| `components/` | `.zig` | Yes | Yes |
| `hooks/` | `.zig` | Yes | Yes |
| `enums/` | `.zig` | Yes | Yes |
| `views/` | `.zon` | Yes | Yes (comptime import) |
| `gizmos/` | `.zon` | Yes | Yes (comptime import) |
| `prefabs/` | `.jsonc` | Copy only | **No** (already runtime loaded via PrefabCache) |
| `scenes/` | `.jsonc` | Copy only | **No** (runtime loaded) |
| `assets/` | `*` | Copy only | **No** (runtime loaded) |

Note: the generator still scans for `.zon` prefabs and emits a
`PrefabRegistry`, but in practice game projects already use `.jsonc` prefabs
loaded at runtime by `PrefabCache`. The `PrefabRegistry` generation is dead
code that should be removed.
| `project.labelle` | — | Yes | Yes |

**Strategy**: compute a lightweight fingerprint (concatenation of mtime + size
for all codegen-triggering files). Store it in `.labelle/.gen_fingerprint`.
On the next run, if the fingerprint matches, skip regeneration entirely.

For scenes and assets (runtime-only files), they still need to be copied to
`.labelle/<target>/` so the binary can find them at runtime. But this can be
a fast incremental sync (only copy changed files) rather than a full directory
copy every time.

#### 2. Skip compilation when no Zig source changed

After regeneration (or skip), check whether any `.zig` file in
`.labelle/<target>/` is newer than the output binary. If not, the binary is
up to date — skip straight to launch.

```zig
fn binaryIsUpToDate(target_dir: []const u8) bool {
    const binary_mtime = getMtime(target_dir ++ "/zig-out/bin/<name>");
    // Walk .zig files in target_dir, return false if any is newer
    ...
}
```

This avoids invoking `zig build` at all when only scene/asset files changed.
The hot reloader in the engine handles those changes at runtime.

#### 3. Merge the two `zig build` invocations

Currently:
```zig
// line 411 — build only, capture output for error reporting
const build_result = try runner.runZig(allocator, target_dir, &.{ "zig", "build" });
// line 454 — build + run, inherits stdio
const run_result = try runner.runZigInherit(allocator, target_dir, &.{ "zig", "build", "run" }, timeout_ns);
```

Replace with a single `zig build run` that inherits stdio. If it fails during
the build phase, Zig already prints the errors to stderr — the separate
`zig build` call is not needed.

If we want to distinguish build errors from runtime errors (different exit
behavior), we can check the exit code or parse stderr, but a single invocation
halves the build-system overhead.

### Expected result

| Scenario | Before | After |
|---|---|---|
| No changes | regen + 2x zig build + run | **just launch** |
| Scene/prefab/asset change | regen + 2x zig build + run | **copy changed files + launch** |
| Script/component change | regen + 2x zig build + run | regen + 1x zig build run |
| project.labelle change | regen + 2x zig build + run | regen + 1x zig build run |

The common dev loop (edit scene → test) goes from ~seconds of unnecessary
build overhead to near-instant launch.

---

## Online editor: WASM builds with user-editable scenes

### The opportunity

With scenes and prefabs as runtime JSONC, an online game editor becomes
viable with **zero server-side compilation** for content changes:

1. **Server precompiles one WASM binary** per game project (scripts +
   components + engine). This is the expensive step — but it only happens
   when Zig source changes.
2. **Users edit scenes and prefabs** through a web GUI (visual editor or
   JSONC text editor).
3. **Browser loads the precompiled WASM + the user's JSONC files** — no
   server round-trip needed for content iteration.

The compile/content boundary maps perfectly to the dev/release split:

| Layer | Changes by | Requires compilation? | Handled by |
|---|---|---|---|
| Engine + plugins | Framework devs | Yes | Precompiled, cached |
| Game scripts + components | Game developer | Yes | Server-side `zig build` on change |
| Scenes + prefabs (JSONC) | **Anyone (level designer, player)** | **No** | Client-side, immediate |
| Assets (images, audio) | Artist | No | Uploaded, served as static files |

### How it would work

```
┌─────────────────────────────────────────────────────┐
│  Online Editor (browser)                            │
│                                                     │
│  ┌──────────────┐  ┌─────────────────────────────┐  │
│  │ Scene Editor  │  │ Game Preview (WASM)         │  │
│  │              │  │                             │  │
│  │ Edit JSONC   │──│ Reload scene from memory    │  │
│  │ prefabs,     │  │ via loadSceneFromMemory()   │  │
│  │ entities,    │  │                             │  │
│  │ positions    │  │ Pre-compiled .wasm binary   │  │
│  └──────────────┘  └─────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
                           │
                     No server call
                     for scene edits
```

### WASM filesystem challenge

The engine currently loads scenes via `std.fs.cwd().openFile()`. In
Emscripten, this maps to a virtual filesystem (MEMFS/IDBFS). There are
several ways to feed JSONC data to the WASM binary:

**Option A: Emscripten virtual filesystem**

Pre-populate Emscripten's MEMFS with scene/prefab files before the game
starts. The JavaScript loader writes files into the virtual FS, and the
engine's `openFile()` calls work unchanged.

```javascript
// JS loader — write scene data into Emscripten's virtual FS
FS.writeFile('/scenes/main.jsonc', sceneJsoncString);
FS.writeFile('/prefabs/worker.jsonc', prefabJsoncString);
// Then start the WASM module — engine reads files normally
Module.callMain();
```

Pros: zero engine changes, `openFile()` works as-is.
Cons: requires Emscripten FS setup in the JS loader.

**Option B: `loadSceneFromMemory()` via JS bridge**

The `loadSceneFromMemory()` entry point (proposed for release builds)
can also serve the online editor. JavaScript passes scene data directly
into WASM memory, bypassing the filesystem entirely.

```javascript
// JS calls into WASM with scene data as a byte buffer
const sceneBytes = new TextEncoder().encode(sceneJsoncString);
const ptr = Module._malloc(sceneBytes.length);
Module.HEAPU8.set(sceneBytes, ptr);
Module._loadSceneFromMemory(ptr, sceneBytes.length);
Module._free(ptr);
```

Pros: no filesystem dependency, works with any WASM runtime.
Cons: requires a C-ABI export wrapper in the engine.

**Recommendation**: Option A for the initial version — it works with the
existing engine code. Option B is cleaner long-term and aligns with the
`loadSceneFromMemory()` work already planned for release builds.

### Two tiers of users

The online editor serves two distinct user profiles with different needs:

**Content creators** (level designers, modders, game jam participants):
- Edit scenes and prefabs only (JSONC)
- Zero compilation — changes are instant in the browser
- No toolchain install required
- This is the majority of users in a collaborative or modding context

**Game developers** (programmers writing game logic):
- Edit Zig scripts, components, hooks, enums
- Requires compilation — Zig source must be built into WASM
- Today this means installing the CLI and Zig locally

The question is: can game developers also work from the browser, without
installing anything?

### Server-side builds for script changes

Yes — if the server has Zig + `labelle` installed. When a developer changes
a script in the browser editor, the server runs the build:

```
┌─────────────┐                    ┌────────────────────────┐
│ Browser      │  scene edit ──────▶│  No build needed       │
│              │  (JSONC)           │  Instant preview       │
│              │                    └────────────────────────┘
│              │
│              │  script edit ─────▶┌────────────────────────┐
│              │  (.zig)            │  Build server           │
│              │                    │                        │
│              │                    │  1. Receive .zig diff  │
│              │◀── new .wasm ──────│  2. labelle build      │
│              │    (~seconds)      │     --platform=wasm    │
│              │                    │  3. Return .wasm       │
└─────────────┘                    └────────────────────────┘
```

The build server would:

1. Maintain a project workspace per user/project
2. Keep the `.zig-cache` warm (incremental builds)
3. Keep precompiled `.a` files for core/gfx/jsonc (from the caching strategy
   described earlier in this RFC)
4. On script change: apply the diff, run `labelle build --platform=wasm`,
   return the new `.wasm` to the browser
5. Cache the `.wasm` output — if the same user edits only scenes next, serve
   the cached binary

With precompiled non-generic packages cached on the server, the build only
needs to compile the generic engine + game scripts — the fastest possible
incremental build.

### Cloud IDE: full development environment in the browser

For the full game developer experience, a cloud IDE approach provides
everything without local installation:

```
┌──────────────────────────────────────────────────────────────┐
│  Browser                                                      │
│                                                                │
│  ┌─────────────────────┐  ┌────────────────────────────────┐  │
│  │ Code Editor          │  │ Game Preview                    │  │
│  │                     │  │                                │  │
│  │ • scripts/*.zig     │  │ WASM build rendered in canvas  │  │
│  │ • components/*.zig  │  │                                │  │
│  │ • scenes/*.jsonc    │  │ Live reload for scene edits    │  │
│  │ • prefabs/*.jsonc   │  │ Rebuild on script edits        │  │
│  │ • project.labelle   │  │                                │  │
│  └─────────────────────┘  └────────────────────────────────┘  │
│                                                                │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │ Terminal (optional)                                      │  │
│  │ $ labelle run --platform=wasm                           │  │
│  │ $ labelle build --release                               │  │
│  └─────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────┴──────────┐
                    │ Cloud workspace     │
                    │                    │
                    │ • Zig 0.15.2       │
                    │ • labelle CLI      │
                    │ • Project files    │
                    │ • .zig-cache       │
                    │ • Precompiled .a   │
                    │   cache            │
                    └────────────────────┘
```

#### Implementation options

**Option 1: Custom cloud IDE**

Build a purpose-built web IDE for labelle:
- Monaco editor (VS Code's editor component) for Zig and JSONC
- Custom scene editor panel with visual entity placement
- WebSocket connection to a per-user container running `labelle`
- WASM preview panel that hot-reloads on scene changes and rebuilds on
  script changes

Pros: tailored UX, integrated scene editor, full control.
Cons: significant frontend engineering, must maintain the IDE.

**Option 2: Gitpod / GitHub Codespaces with labelle pre-installed**

Use an existing cloud IDE platform with a devcontainer that has Zig +
labelle pre-installed:

```dockerfile
# .devcontainer/Dockerfile
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y \
    libgl1-mesa-dev libx11-dev libxcursor-dev libxrandr-dev \
    libxinerama-dev libxi-dev libxext-dev libxfixes-dev \
    libwayland-dev libxkbcommon-dev libasound2-dev
# Install Zig
RUN curl -L https://ziglang.org/download/0.15.2/... | tar xJ -C /usr/local
# Install labelle CLI
RUN curl -L https://labelle-releases.example.com/cli/latest/labelle-linux-x86_64 \
    -o /usr/local/bin/labelle && chmod +x /usr/local/bin/labelle
```

Developers open the repo in Codespaces, everything is pre-configured.
The WASM build can be previewed via port forwarding or a simple HTTP
server.

Pros: zero custom IDE work, familiar VS Code interface, Git integration.
Cons: no custom scene editor (just text editing), depends on third-party
platform, cost per workspace.

**Option 3: Hybrid — Codespaces for scripts + custom scene editor**

Use Codespaces/Gitpod as the compilation backend, but overlay a custom
scene/prefab editor that talks to the same workspace:

- Content creators use the visual scene editor (no Codespaces needed —
  pure client-side JSONC editing)
- Game developers open Codespaces for script work, get full terminal +
  IDE
- Both share the same project repo and see each other's changes

This separates the "needs a compiler" and "doesn't need a compiler"
workflows cleanly.

**Recommendation**: start with Option 2 (Codespaces/Gitpod) — it's the
fastest path to "zero local install" for developers. Add a custom scene
editor frontend later for the content-creator tier. Option 3 is the
eventual goal.

### Server architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        CDN / Edge                            │
│  Static assets: editor app, cached .wasm binaries, assets   │
└──────────────────────────┬──────────────────────────────────┘
                           │
            ┌──────────────┼──────────────┐
            │              │              │
            ▼              ▼              ▼
   ┌──────────────┐ ┌───────────┐ ┌──────────────┐
   │ Scene editor  │ │ Code      │ │ Build        │
   │ (static SPA)  │ │ editor    │ │ service      │
   │               │ │ (Cloud    │ │              │
   │ JSONC editing │ │  IDE or   │ │ Receives     │
   │ No backend    │ │  custom)  │ │ .zig diffs   │
   │ needed        │ │           │ │ Returns .wasm│
   └──────────────┘ └─────┬─────┘ └──────┬───────┘
                          │               │
                          ▼               ▼
                    ┌─────────────────────────┐
                    │ Project storage          │
                    │                         │
                    │ • Git repo (scripts,    │
                    │   components, scenes)   │
                    │ • Asset storage (S3/R2) │
                    │ • WASM cache per commit │
                    └─────────────────────────┘
```

Key design points:

- **WASM binaries are cached per Git commit hash** of the Zig source files.
  If only scenes changed, the cached WASM is reused.
- **Scene/prefab JSONC files are stored separately** from the WASM binary —
  they're loaded at runtime, so they can change independently.
- **The build service is stateless** — it pulls the project from storage,
  builds, caches the output, returns it. Can scale horizontally.
- **Precompiled `.a` cache is shared** across projects using the same engine
  version — a build server that has already compiled core/gfx/jsonc for
  `wasm32-emscripten-debug` can reuse those artifacts for any project.

### What this enables

- **Online level editor** — drag entities, edit components, see changes
  instantly in the WASM preview. No install, no compiler.
- **Online game development** — edit Zig scripts in a cloud IDE, server
  compiles and returns the WASM binary. No local toolchain needed.
- **Modding support** — ship the WASM binary, let players create custom
  scenes and prefabs.
- **Collaborative editing** — multiple users edit scenes via a shared
  backend, each seeing live updates in their browser.
- **Game jam template** — precompile a starter project, participants only
  touch JSONC files to build levels. Developers can also edit scripts via
  the cloud IDE if needed.
- **Education** — students start building games in the browser immediately,
  no environment setup. The cloud IDE handles compilation; the scene editor
  lets them see results instantly.

---

## CI: keeping release builds honest

The current CI (`ci.yml`) tests the dev path end-to-end: init a project,
generate, and compile. But release mode is never exercised — the `release.yml`
workflow only builds the CLI binary itself, not a game project. This means the
embed codepath could break silently while all dev-mode work stays green.

### What CI needs to cover

The `versions-integration` job in `ci.yml` already does:

```
labelle init test_game → labelle generate → zig build
```

We extend this to also run a **release build** of the same test project:

```
labelle build --release   (or: labelle generate --release → zig build -Doptimize=ReleaseSafe)
```

This verifies:
1. The generator emits valid `@embedFile` code for all scenes/prefabs
2. The embedded binary compiles without errors
3. The binary is self-contained (no loose `.jsonc` files needed)

### Proposed CI addition

Add a `release-integration` job to `ci.yml` that runs on every PR:

```yaml
release-integration:
  name: Release Build Integration Test
  runs-on: ubuntu-latest
  steps:
    - name: Checkout labelle-cli
      uses: actions/checkout@v4
      with:
        path: labelle-cli

    - name: Checkout sibling dependencies
      uses: actions/checkout@v4
      with:
        repository: labelle-toolkit/labelle-core
        path: labelle-core

    - uses: actions/checkout@v4
      with:
        repository: labelle-toolkit/labelle-engine
        path: labelle-engine

    - uses: actions/checkout@v4
      with:
        repository: labelle-toolkit/labelle-gfx
        path: labelle-gfx

    - name: Setup Zig
      uses: mlugg/setup-zig@v2
      with:
        version: 0.15.2

    - name: Install system dependencies
      run: |
        sudo apt-get update
        sudo apt-get install -y \
          libgl1-mesa-dev libx11-dev libxcursor-dev libxrandr-dev \
          libxinerama-dev libxi-dev libxext-dev libxfixes-dev \
          libwayland-dev libxkbcommon-dev libasound2-dev

    - name: Build CLI
      run: cd labelle-cli && zig build

    - name: Init, generate, and build a release project
      run: |
        mkdir -p test-projects && cd test-projects
        ../labelle-cli/zig-out/bin/labelle init test_game --backend=raylib --ecs=zig_ecs \
          --core-version="local:../../labelle-core" \
          --engine-version="local:../../labelle-engine" \
          --gfx-version="local:../../labelle-gfx" \
          --labelle-version="local:../../labelle-cli"
        cd test_game

        # Dev build (existing coverage)
        ../../labelle-cli/zig-out/bin/labelle generate
        cd .labelle/raylib_desktop && zig build && cd ../..

        # Release build (new coverage)
        ../../labelle-cli/zig-out/bin/labelle build --release

    - name: Verify release binary is self-contained
      run: |
        # The release binary should exist and not require loose scene files
        BINARY=test-projects/test_game/.labelle/raylib_desktop/zig-out/bin/test_game
        test -f "$BINARY" || (echo "Release binary not found" && exit 1)

        # Removing scene files should NOT break the binary (scenes are embedded)
        rm -rf test-projects/test_game/.labelle/raylib_desktop/scenes/
        # Binary should still start (will exit quickly without a display, but shouldn't crash on missing files)
        timeout 2 "$BINARY" 2>&1 || true
```

### Why this matters

Without this, the workflow is:
1. Develop features using `labelle run` (dev mode) — CI stays green
2. Ship a release — embed codepath hasn't been tested in weeks — breaks

With the release-integration job, every PR proves that both dev and release
paths produce a working build.

---

## Open questions

1. Should `labelle build` (without `--release`) also embed scenes, or only
   `labelle build --release`? Embedding by default on any `build` seems
   reasonable since builds produce distributable artifacts.
2. Should the hot reloader be compiled out entirely in release mode, or just
   disabled? Compiling it out saves binary size; keeping it allows runtime
   toggling for debugging shipped builds.
3. Should `.zon` prefab support be removed entirely from the scanner, or kept
   for backwards compatibility with projects that haven't migrated yet?
4. For the binary-up-to-date check, should we rely on mtime comparison alone
   or also hash file contents? Mtime is fast but can miss changes (e.g.,
   `touch` without actual edits) or give false positives (copy that preserves
   mtime). In practice, mtime is sufficient for a dev workflow.
5. Should the fingerprint file (`.labelle/.gen_fingerprint`) be gitignored?
   It is machine-local state and should not be committed.
6. For precompiled libraries, should the CLI manage the cache, or should this
   be done via Zig's build system (custom build steps that produce and
   consume `.a` artifacts)? Zig's `.zig-cache` already caches compilation
   units, but it's opaque and tied to the build graph — an explicit
   `.labelle/cache/libs/` is more controllable and survives regeneration.
