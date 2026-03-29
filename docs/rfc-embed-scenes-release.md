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

In fact, `Prefabs` / `PrefabRegistry` is now dead code in the JSONC scene path.
After the comptime scene removal (RFC-remove-comptime-scenes.md), nothing in the
generated code actually uses `Prefabs` — it is declared but never referenced.
The JSONC bridge's `PrefabCache` has fully replaced it.

**Proposal**: remove the comptime `PrefabRegistry` from codegen entirely and
move prefabs to `.jsonc` format (or keep `.zon` but load them from disk via
`PrefabCache`). This gives prefabs the same dev/release treatment as scenes:

- **Dev mode** (`labelle run`): prefabs loaded from disk via `PrefabCache`.
  Editing a prefab requires no recompilation — the hot reloader detects the
  change and the scene bridge re-parses.
- **Release mode** (`labelle build`): prefab files embedded via `@embedFile`,
  `PrefabCache` reads from memory instead of disk.

The `PrefabCache.get()` method already tries `.jsonc` first (line 95 of
`jsonc_scene_bridge.zig`). To also support `.zon` files at runtime, we would
need a small `.zon` parser or simply require prefabs to be `.jsonc` going
forward. Since scenes are already JSONC, standardizing on one format is
cleaner.

#### Migration path

1. Remove `PrefabRegistry` generation from `main_zig.zig` (lines 133–143)
2. Remove `PrefabRegistry` type from engine (or keep for backwards compat)
3. Convert existing `.zon` prefab files to `.jsonc`
4. `PrefabCache` becomes the single prefab loading mechanism for both dev
   and release
5. Generator stops `@import`'ing prefab `.zon` files — prefabs no longer
   trigger recompilation in dev mode

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

## Scope

### In scope

- `@embedFile` embedding of `.jsonc` scene files in release builds
- `loadSceneFromMemory` engine entry point
- Generator-time dev/release code path split
- Migrate prefabs from comptime `.zon` to runtime `.jsonc`
- Remove `PrefabRegistry` from codegen (dead code in JSONC scene path)
- Prefab embedding via `@embedFile` in release builds
- Codegen fingerprinting to skip regeneration when inputs are unchanged
- Binary mtime check to skip compilation when no `.zig` source changed
- Merge the two `zig build` invocations into a single `zig build run`
- Incremental scene/asset sync (copy only changed files)

### Out of scope

- Asset embedding (images, audio) — separate concern, typically handled by the
  backend/renderer
- Compression or binary packing — future optimization
- Obfuscation or encryption of embedded data
- File watching / daemon mode (e.g., `labelle watch` that stays running and
  re-launches on changes) — future enhancement

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
| `prefabs/` | `.zon` → `.jsonc` | ~~Yes~~ Copy only | ~~Yes~~ **No** (after migration to runtime) |
| `scenes/` | `.jsonc` | Copy only | **No** (runtime loaded) |
| `assets/` | `*` | Copy only | **No** (runtime loaded) |

Note: prefabs currently trigger recompilation because they are `.zon` files
`@import`'d at comptime. After the migration proposed in this RFC, they
become runtime-loaded `.jsonc` files — same as scenes.
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
3. Should the prefab `.zon` → `.jsonc` migration be a breaking change (remove
   `.zon` support) or should `PrefabCache` support both formats during a
   transition period?
4. For the binary-up-to-date check, should we rely on mtime comparison alone
   or also hash file contents? Mtime is fast but can miss changes (e.g.,
   `touch` without actual edits) or give false positives (copy that preserves
   mtime). In practice, mtime is sufficient for a dev workflow.
5. Should the fingerprint file (`.labelle/.gen_fingerprint`) be gitignored?
   It is machine-local state and should not be committed.
