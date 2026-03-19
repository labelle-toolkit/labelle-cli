# RFC: GUI as External Plugin System

## Problem Statement

The current GUI integration in labelle-cli violates the **Open/Closed Principle**. Adding a new GUI requires modifying multiple files:

1. **`config.zig`** — `GuiChoice` is a hardcoded enum (`none, simple, clay, imgui`)
2. **`build_files.zig`** — `switch(cfg.gui)` to pick build template sections and dependency names
3. **`main_zig.zig`** — `switch(cfg.gui)` for stub vs backend import, `init()/shutdown()` calls, lifecycle code generation

### The Merged Backend Problem

ImGui is currently shipped as a **merged package** (`labelle_raylib_imgui`, `labelle_sokol_imgui`) that bundles both the GUI library and the backend renderer into one dependency. This causes:

- **Version lock-in** — the merged package pins its own backend version. If a game wants raylib 5.5 but `raylib-imgui` only supports 5.0, the game must downgrade. The GUI choice should never dictate the rendering backend version.
- **Circular dependency risk** — the GUI package bundles the backend, and the assembler needs to wire the backend independently. The dependency arrow goes both ways conceptually, making clean assembly impossible.
- **Combinatorial explosion** — every new backend or GUI requires a new merged package. That's `N backends × M GUIs` packages instead of `N + M`.

### Cleanup

`simple-gui` is no longer maintained and should be removed.

## Proposal: Three-Layer Separation

Instead of merging GUI and backend into one package, separate them into three independent layers:

```
backend (raylib)       → version owned by the project
gui library (cimgui)   → version owned by the GUI plugin
bridge adapter         → thin glue, depends on both
```

The backend and GUI library version independently. The bridge adapter is the only piece that needs compatibility with both. It does not own either dependency — it receives them.

### Two Categories of GUI Plugin

| Category | Example | How it renders | Bridge needed? |
|----------|---------|---------------|----------------|
| **Render-interface** | Clay | Through the engine's `RenderInterface` | No — works with any backend automatically |
| **Raw-backend** | ImGui, Nuklear | Direct access to backend rendering context | Yes — thin adapter per backend |

Render-interface GUIs are fully portable. Raw-backend GUIs trade portability for power — they need a bridge per backend, but can use the full backend API (e.g., ImGui submitting its own draw commands through raylib).

## GUI Plugin Manifest: `gui.labelle`

Each GUI plugin ships a `gui.labelle` manifest that declares its build requirements. The CLI reads this manifest instead of switching on an enum.

### Render-interface GUI (no bridge needed)

```zon
// gui/clay/gui.labelle
.{
    .name = "clay",
    .library = .{ .package = "zclay" },
    .rendering = .render_interface,
}
```

### Raw-backend GUI (bridge per backend)

```zon
// gui/imgui/gui.labelle
.{
    .name = "imgui",
    .library = .{ .package = "cimgui" },
    .rendering = .raw_backend,
    .lifecycle = .{ .init = true, .shutdown = true },
    .bridges = .{
        .raylib = .{ .adapter = "rlimgui_bridge" },
        .sokol  = .{ .adapter = "sokol_imgui_bridge" },
    },
}
```

### Manifest Fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Plugin identifier |
| `library` | Yes | The GUI library dependency (package name, or url+hash) |
| `rendering` | Yes | `.render_interface` or `.raw_backend` |
| `lifecycle` | No | Declares `init`/`shutdown` hooks. Default: none |
| `bridges` | Only if `raw_backend` | Map of backend → bridge adapter package |

## How the Assembler Wires It

### Game configuration

The game declares its GUI choice in `project.labelle` as a package reference, not an enum value:

```zon
// project.labelle
.{
    .name = "my_game",
    .backend = .raylib,
    .gui = .{
        .package = "labelle_imgui",
        .version = "0.2.0",
    },
}
```

Or via git URL for third-party plugins:

```zon
.gui = .{
    .url = "https://github.com/someone/labelle-nuklear/archive/v0.1.0.tar.gz",
    .hash = "...",
},
```

Or omitted / set to `"none"` for games that don't need GUI (injects `StubGui`).

### Assembly flow

1. CLI fetches the GUI plugin package (same mechanism as any labelle dependency)
2. Reads `gui.labelle` manifest inside the package
3. Branches on `rendering`:
   - **`.render_interface`** → add library as dependency, wire module to `GuiInterface` slot. Done.
   - **`.raw_backend`** → add library as dependency, look up `bridges[project.backend]`, add bridge adapter as a separate dependency that imports both the backend and the GUI library
4. If `lifecycle.init` is set, generates `GuiBackend.init()` / `defer GuiBackend.shutdown()` in the setup phase
5. GUI draw lifecycle (`guiBegin`/`guiEnd`/`renderAllViews`) is generated as today — driven by presence of a non-stub GUI, not by GUI type

### Missing bridge = clear error

If a game picks `imgui` + `wgpu` and no bridge exists for that combination, the CLI emits a clear error at generation time:

```
error: GUI plugin 'imgui' requires a bridge for backend 'wgpu', but none is declared in gui.labelle.
Available bridges: raylib, sokol
```

No silent failures, no broken builds.

## Plugin Resolution: Local and Remote

GUI plugins must work both as **local paths** (development, monorepo) and **remote packages** (published, distributed). The CLI resolves the plugin the same way regardless of source — it just needs a directory with a `gui.labelle` manifest.

### Local path

For development or monorepo setups, the game points to a local directory:

```zon
.gui = .{ .path = "../my-gui-plugin" },
```

The CLI reads `gui.labelle` from that path directly. No fetching, no cache. The bridge adapters in the manifest can also use local paths:

```zon
// gui.labelle inside a local plugin
.{
    .name = "imgui",
    .library = .{ .package = "cimgui" },
    .rendering = .raw_backend,
    .lifecycle = .{ .init = true, .shutdown = true },
    .bridges = .{
        .raylib = .{ .adapter = "rlimgui_bridge", .path = "./bridges/raylib" },
        .sokol  = .{ .adapter = "sokol_imgui_bridge", .path = "./bridges/sokol" },
    },
}
```

This is essential for:
- **Plugin development** — iterate on the GUI plugin without publishing
- **Monorepo workflows** — GUI plugin lives alongside the game
- **Forking/patching** — override a published plugin with a local copy

### Remote package

For published plugins, the game uses URL + hash:

```zon
.gui = .{
    .url = "https://github.com/someone/labelle-nuklear/archive/v0.1.0.tar.gz",
    .hash = "...",
},
```

Or package name + version (resolved from labelle's package registry/cache):

```zon
.gui = .{
    .package = "labelle_imgui",
    .version = "0.2.0",
},
```

The CLI fetches the package, caches it, and reads `gui.labelle` from the cached directory.

### Resolution order

The CLI resolves GUI plugins in this order:

1. **`.path`** — use local directory as-is
2. **`.package` + `.version`** — look up in labelle package cache
3. **`.url` + `.hash`** — fetch and cache

The same resolution applies to bridge adapter packages declared in the manifest. Bridges can mix local and remote — e.g., a remote GUI plugin with a locally patched bridge.

## External Plugin Hosting

GUI plugins can live in **any repository**. The CLI doesn't need to know about them in advance — it just fetches the package and reads the manifest.

Bridge adapters can live:
- **In the GUI plugin repo** (convenient for the plugin author to maintain)
- **In a separate repo** (useful if the bridge is community-maintained)
- **In labelle-cli** (for first-party bridges shipped with the toolkit)

The manifest points to bridge packages by coordinates (path, URL, or package name), so any arrangement works.

### Example: Third-party Nuklear plugin

A community member creates `labelle-nuklear` in their own repo:

```
labelle-nuklear/
├── gui.labelle          # manifest
├── build.zig
├── build.zig.zon
├── src/
│   └── adapter.zig      # satisfies GuiInterface contract
└── bridges/
    └── raylib/
        ├── build.zig
        └── src/
            └── bridge.zig  # thin glue: zig-nuklear + raylib
```

Games use it remotely:

```zon
.gui = .{
    .url = "https://github.com/someone/labelle-nuklear/archive/v0.1.0.tar.gz",
    .hash = "...",
},
```

Or locally during development:

```zon
.gui = .{ .path = "../labelle-nuklear" },
```

## Impact

### No changes to engine or labelle-core

- `GuiInterface(Impl)` and `StubGui` in labelle-core stay exactly as they are
- `gui_mixin.zig` in the engine (`guiBegin`, `guiEnd`, `renderAllViews`) stays the same
- The comptime slot architecture means engine and core are already closed for modification — the OCP violation is only in the CLI's generator code

### What changes in labelle-cli

**Removed:**
- `GuiChoice` enum from `config.zig`
- All `switch(cfg.gui)` blocks in `build_files.zig` and `main_zig.zig`
- `simple-gui` packages (`simple-raylib`, `simple-sokol`) — no longer maintained
- Merged backend packages (`labelle_raylib_imgui`, `labelle_sokol_imgui`)

**Added:**
- `gui.labelle` manifest parser
- Generic GUI wiring logic in the generator (reads manifest, resolves bridge)
- Bridge adapter packages for imgui (replacing merged packages):
  - `rlimgui_bridge` — imports raylib + cimgui, provides glue
  - `sokol_imgui_bridge` — imports sokol + cimgui, provides glue

**Unchanged:**
- Game-facing API — games still call `g.guiBegin()`, `g.guiEnd()`, etc.

## Open Questions

1. **Bridge discovery** — Should the manifest embed bridge package coordinates directly, or should there be a registry/convention the CLI can search? Direct embedding is simpler but requires the GUI plugin author to know about all supported backends upfront.

2. **Bridge API contract** — Should bridges satisfy a formal interface (like `GuiInterface`), or is the contract implicit (the bridge just needs to export the right symbols)? A formal `BridgeInterface(GuiLib, Backend)` in labelle-core would catch integration errors at compile time.

3. **Version compatibility matrix** — How should the CLI handle version mismatches between a bridge and its backend/GUI library? Options: bridge declares compatible version ranges in its manifest, or rely on Zig build errors to surface incompatibilities.
