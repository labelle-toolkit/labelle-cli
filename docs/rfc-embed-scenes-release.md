# RFC: Embed JSONC Scenes and Prefabs in Release Builds

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

### Prefab handling

Prefabs are currently `.zon` files `@import`'d at comptime. This already
embeds them. However, there is a broader initiative to move prefabs to `.jsonc`
as well (for consistency with scenes and to enable hot reload of prefabs).

If/when prefabs become `.jsonc`, they would follow the same embed strategy as
scenes. This RFC's design accommodates that path.

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
- Prefab embedding if prefabs are `.jsonc` at that point

### Out of scope

- Asset embedding (images, audio) — separate concern, typically handled by the
  backend/renderer
- Compression or binary packing — future optimization
- Obfuscation or encryption of embedded data

---

## Migration

No breaking changes. The default behavior (`labelle run`) remains unchanged.
`labelle build` gains embedded scenes automatically. Game authors do not need
to modify their projects.

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
3. When prefabs move to `.jsonc`, should they follow this same RFC or get a
   separate one?
