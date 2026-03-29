# RFC: Decouple CLI Generator from Engine Version

Tracking issue: #107

## Status

Draft — open for discussion.

---

## Background

The `labelle` CLI generates Zig source code (`main.zig`, `build.zig`) that
is tightly coupled to the current engine API. The generator references **53
engine API surface points** — type constructors, instance methods, template
fragments — all hardcoded to the current engine version.

This means:
- **CLI v1.22 can only build projects using engine ~v1.10.x**
- A project pinned to an older engine version cannot be built with a newer CLI
- Upgrading the CLI forces upgrading the engine
- Old projects rot — they require the exact CLI version they were created with
- The online editor (#105) and auto-Zig toolchain (#106) make this worse:
  a hosted build server must match CLI and engine versions per project

---

## The coupling today

The generator (`generator/src/main_zig.zig`) produces Zig code that directly
calls engine types and methods. Examples:

```zig
// Generated main.zig — hardcoded to current engine API

// Type constructors (11 distinct types)
const AssembledGame = engine.GameConfig(Renderer, EcsBackend, ...);
const Components = engine.ComponentRegistryWithPlugins(.{ ... }, .{ ... });
const PluginSystems = engine.SystemRegistry(.{ ... });
const JsoncBridge = engine.JsoncSceneBridgeWithGizmos(AssembledGame, Components, Gizmos);
const Prefabs = engine.PrefabRegistry(.{});
const Scripts = engine.ScriptRegistry(AllScripts);
const Views = engine.ViewRegistry(.{ ... });
const Gizmos = engine.GizmoRegistry(.{ ... });
const HookPayload = engine.HookPayload(EcsBackend.Entity);

// Instance methods (13+ methods on the game instance)
g.registerSceneSimple("main", loader_fn);
g.setScene("main");
g.setState("running");
g.guiBegin();
g.renderAllViews(Views);
g.guiEnd();

// Script runner (9 methods)
var runner = Runner.init(allocator, &g.active_world.ecs_backend);
runner.setup(&g);
runner.tick(&g, scaled_dt);
runner.drawGui(&g);

// Plugin systems (9 methods)
PluginSystems.setup(&g);
PluginSystems.tick(&g, scaled_dt);
PluginSystems.postTick(&g, scaled_dt);
PluginSystems.drawGui(&g);
```

If any of these signatures change in a new engine version — a parameter
added, a type renamed, a method split — the generated code breaks.

### Full API surface (53 points)

| Category | Count | Examples |
|---|---|---|
| Type constructors | 11 | `GameConfig`, `ComponentRegistry`, `SystemRegistry`, `ScriptRunner` |
| Game instance methods | 13 | `setScene`, `setState`, `guiBegin`, `renderAllViews`, `time_scale` |
| ScriptRunner methods | 9 | `init`, `tick`, `drawGui`, `profile`, `profiling_enabled` |
| PluginSystems methods | 9 | `setup`, `tick`, `postTick`, `drawGui`, `gizmoCategories` |
| Scene/Hook types | 5 | `JsoncSceneBridge`, `HookPayload`, `MergeHooks` |
| GUI/Renderer/Window | 4 | `GfxRenderer`, `LayerConfig`, `GuiBackend.init`, `window.setConfigFlags` |
| Core types | 2 | `StderrLogSink`, `MockEcsBackend` |

---

## Problem scenarios

### 1. Old project, new CLI

Developer updates their CLI (`labelle update`) to get new features or bug
fixes. Their project still pins `engine = "1.8.0"`. The new CLI generates
code that calls APIs added in engine 1.10 (e.g., `JsoncSceneBridge`,
`SystemRegistry`). The project fails to compile.

### 2. Engine breaking change

Engine 1.12 renames `GameConfig` to `Game` or changes its parameter order.
CLI v1.24 is updated to match. All projects on engine <1.12 now fail with
the new CLI, even though the engine they pin is still valid.

### 3. Online editor / build server

The build server (#105) hosts multiple projects at different engine versions.
Today it would need a separate CLI binary per engine version. This is
operationally painful.

### 4. Team version drift

Developer A has CLI v1.20, developer B has CLI v1.22. They work on the same
project. Developer B's generated `.labelle/` directory has different code
than A's. Builds break depending on who last ran `labelle generate`.

---

## Proposal

### Approach: engine ships its own codegen templates

Instead of the CLI hardcoding templates, the **engine package itself**
provides the templates and codegen rules for its version. The CLI becomes
a generic orchestrator that reads templates from the engine.

```
labelle-engine/
  codegen/
    main.zig.template      ← how to generate main.zig for this engine version
    manifest.zon            ← declares capabilities, required inputs, API version
```

The CLI's job becomes:
1. Scan the project (scripts, components, scenes, prefabs, etc.)
2. Read the template manifest from the resolved engine package
3. Feed scanned data into the engine's templates
4. Output the generated files

This inverts the dependency:

```
Before:  CLI ──knows──▶ Engine API (hardcoded)
After:   CLI ──reads──▶ Engine templates (engine provides them)
```

### How the manifest works

Each engine version ships a `codegen/manifest.zon` that declares:

```zon
.{
    .codegen_api = 1,              // codegen protocol version
    .min_cli_version = "1.20.0",   // minimum CLI that supports this protocol
    .templates = .{
        .main_zig = "main.zig.template",
        .build_zig = "build.zig.template",
    },
    .capabilities = .{
        .jsonc_scenes = true,
        .comptime_scenes = false,
        .plugin_systems = true,
        .gizmo_registry = true,
        .state_machine = true,
    },
}
```

The CLI reads `codegen_api` to know which template protocol to use. If
`codegen_api` is higher than what the CLI supports, it tells the user to
update their CLI. If it's lower, the CLI uses backward-compatible rendering.

### Template format

Templates use a simple interpolation format. The CLI provides variables
from the project scan, and the template produces Zig code:

```
// main.zig.template (shipped with engine 1.10.x)
{{header}}

const engine = @import("labelle-engine");
const gfx = @import("labelle-gfx");

{{component_registry}}
{{system_registry}}
{{script_registry}}

const AssembledGame = engine.GameConfig(
    Renderer, EcsBackend, BackendInput, BackendAudio,
    GuiBackend, *GameHooks, LogSink, Components,
    DiscoveredGizmoCategories,
);

{{scene_loaders}}
{{lifecycle}}
```

The CLI resolves `{{component_registry}}` by iterating scanned components
and emitting the right code. The template controls the structure; the CLI
provides the data.

When engine 1.12 renames `GameConfig` to `Game`, it ships updated
templates. The CLI doesn't need to change — it just feeds the same
scanned data into the new templates.

### What stays in the CLI

The CLI keeps responsibility for:
- **Project scanning** — finding scripts, components, scenes, prefabs,
  hooks, enums, views, gizmos
- **Dependency resolution** — resolving package versions, managing cache
- **Build orchestration** — invoking `zig build`, managing the build pipeline
- **Template rendering** — reading templates and interpolating variables

The CLI does NOT keep:
- **Knowledge of engine API signatures** — that's in the templates
- **Knowledge of what types exist** — the manifest declares capabilities
- **Lifecycle ordering** — the template controls setup/tick/draw order

### Codegen API versioning

The `codegen_api` version in the manifest is a simple integer:

| `codegen_api` | What changed |
|---|---|
| 1 | Initial format — basic variable interpolation |
| 2 | Added loop constructs for plugins |
| 3 | Added conditional blocks for capabilities |

The CLI supports a range: e.g., CLI v1.30 supports `codegen_api` 1–3.
If the engine ships `codegen_api` 4, the CLI says "please update."

This is a coarse-grained contract. The engine can change any API it wants
between versions — the templates absorb the change. The `codegen_api` only
changes when the template *format* changes (new interpolation features),
not when the engine *API* changes.

---

## Migration path

This is a large architectural change. A phased approach:

### Phase 1: Extract templates from CLI (no engine change)

Move the current hardcoded templates from `generator/src/templates/` into
a separate directory structure that matches what the engine would ship.
The CLI reads them from the local engine package instead of from embedded
`@embedFile`s.

This is a pure refactor — same output, different source for templates.
Validates the template rendering pipeline without changing the engine.

### Phase 2: Engine ships its own templates

Add `codegen/` to `labelle-engine` with `manifest.zon` and templates.
The CLI detects the `codegen/` directory in the resolved engine package
and uses it. Falls back to built-in templates if `codegen/` is missing
(backward compatibility with older engine versions).

### Phase 3: Remove hardcoded templates from CLI

Once all supported engine versions ship their own templates, remove the
built-in templates from the CLI. The CLI becomes a pure orchestrator.

### Phase 4: Older engine support

The CLI can now build projects against any engine version that ships
`codegen/` templates. A project pinned to engine 1.10 uses 1.10's
templates. A project pinned to engine 1.14 uses 1.14's templates.
Same CLI binary, different generated code.

---

## Design decisions

### Why not a separate assembler/builder repo?

It's tempting to extract the codegen into its own `labelle-assembler` repo.
But this makes the coupling **worse**, not better:

| Option | Repos to update on engine API change | Coupling |
|---|---|---|
| Templates in engine | 1 (engine) | API + template in same commit |
| Templates in CLI (today) | 2 (engine + CLI) | CLI must track engine changes |
| Templates in new assembler repo | 3 (engine + assembler + CLI) | Three-way lockstep |

A separate repo means the engine author changes an API in `labelle-engine`,
then must open a second PR in `labelle-assembler` to update the templates,
and the CLI must know which assembler version matches which engine version.
That's strictly more fragmentation and coordination for zero benefit.

**The right answer is: templates live in `labelle-engine/codegen/`.** No new
repos. The engine author changes an API and updates the template in the same
commit, same PR, same review. The CLI doesn't need to know or care.

```
labelle-engine/          ← existing repo, no new repos
  src/                   ← engine source (existing)
  codegen/               ← NEW: main.zig template for the CLI generator
    manifest.zon
    main.zig.template    ← engine API knowledge (GameConfig, ScriptRunner, etc.)
  jsonc/                 ← JSONC parser (existing)
  scene/                 ← scene module (existing)
```

Note: `build.zig` generation stays in the CLI — it contains platform and
backend knowledge (iOS SDK, Emscripten, linking) that the engine should
not know about.

### Why not versioned codegen in the CLI?

Alternative: the CLI contains multiple codegen backends, one per engine
version range (e.g., `codegen_v1_8.zig`, `codegen_v1_10.zig`).

This doesn't scale. Every engine release requires a CLI update. The CLI
binary grows with every supported version. And the CLI must be released
in lockstep with the engine — exactly the coupling we're trying to break.

### Why not a stable engine API?

Alternative: freeze the engine's public API and never break it.

This is unrealistic for a pre-1.0 project that's actively evolving.
The engine needs freedom to change type signatures, rename things, add
parameters, restructure modules. Freezing the API would halt engine
development.

The template approach gives the engine full freedom to change its API
while maintaining CLI compatibility.

### Template ownership: engine owns `main.zig`, CLI owns `build.zig`

Not all generated code depends on the engine API. The two main outputs
have very different coupling:

**`main.zig`** — engine-coupled. References `GameConfig(...)`,
`ScriptRunner(...)`, `SystemRegistry(...)`, `JsoncSceneBridge(...)`,
lifecycle ordering (`setup` → `tick` → `drawGui`), profiling hooks, etc.
This is the code that breaks when engine APIs change. **This template
moves to the engine.**

**`build.zig`** — platform/backend-coupled. Contains iOS SDK path
resolution, Emscripten linking, backend artifact wiring (`raylib`,
`sokol`, `sdl`, `bgfx`, `wgpu`), ECS adapter dependencies, plugin
module injection, GUI bridge linking. The engine knows nothing about
platforms or backends. **This template stays in the CLI.**

```
labelle-engine/codegen/              ← engine ships these
  manifest.zon                        ← capabilities, codegen_api version
  main.zig.template                   ← how to assemble the game (engine API)

labelle-cli/generator/src/templates/ ← CLI keeps these
  build_zig.txt                       ← how to build (platforms, backends, linking)
  build_zig_zon.txt                   ← dependency declarations
```

This split is clean because:
- The engine author changes an API → updates `main.zig.template` in the
  same commit
- The CLI author adds a new backend or platform → updates `build_zig.txt`
  without touching the engine
- Neither needs to know about the other's concerns

### Why templates in the engine, not in the project?

The `main.zig` template belongs to the engine because it encodes engine
API knowledge. If it were in the project, every project would need to
update templates on engine upgrade — that's just moving the coupling.

The engine author updates templates alongside API changes. Projects
just pin an engine version and get matching templates.

---

## Impact on other RFCs

### #105 — Build pipeline (embed scenes, skip recompilation)

The dev/release codegen split becomes a template concern. The engine's
templates would have conditional blocks:

```
{{#if release_mode}}
const scene_data = @embedFile("scenes/main.jsonc");
{{else}}
fn loadScene(game) { return JsoncBridge.loadScene(game, "scenes/main.jsonc", "prefabs"); }
{{/if}}
```

### #106 — Auto Zig toolchain

No direct impact. The Zig version is still pinned and managed by the CLI.

### #77 — Chrome extension

No direct impact. The extension talks to the CLI, which generates code
using the engine's templates.

### Online editor / build server

Major benefit. The build server runs one CLI binary and can build projects
at any engine version. No need to maintain multiple CLI versions per
engine version.

---

## Scope

### In scope

- Template format specification and renderer in the CLI
- `codegen/manifest.zon` specification for the engine
- Migration of current hardcoded templates to engine-shipped templates
- Backward compatibility: CLI falls back to built-in templates for engines
  without `codegen/`
- `codegen_api` versioning protocol

### Out of scope

- Changing engine APIs — this RFC is about decoupling, not redesigning
- Template language beyond simple interpolation + conditionals + loops
- User-editable templates (game authors customizing generated code)

---

## Related RFCs and issues

- **#105 / `docs/rfc-embed-scenes-release.md`**: build pipeline. The
  dev/release split becomes a template-level concern.
- **#106 / `docs/rfc-auto-zig-toolchain.md`**: auto Zig. Unaffected —
  Zig version management is orthogonal to codegen.
- **#77**: Chrome extension. Unaffected — the extension calls the CLI.

---

## Open questions

1. **Template language**: should templates use a custom interpolation format,
   or an existing one (e.g., Mustache, Handlebars)? Custom is simpler to
   implement in Zig but less familiar. A minimal `{{var}}`, `{{#if}}`,
   `{{#each}}` subset covers all current needs.
2. **Template testing**: how do we test that engine templates produce valid
   Zig code? The engine CI should generate + compile a test project using
   its own templates.
3. **Multiple backend templates**: should the engine ship separate templates
   per backend (raylib, sokol, sdl), or one template with backend
   conditionals? Currently the CLI has separate template sections per
   backend.
4. ~~**Who owns `build.zig` templates?**~~ Resolved: `build.zig` stays in the
   CLI (platform/backend knowledge), `main.zig` moves to the engine (API
   knowledge). See "Template ownership" section above.
5. **Transition period**: how long should the CLI maintain built-in fallback
   templates for engines without `codegen/`? One major version cycle?
