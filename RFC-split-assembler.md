# RFC: Split the assembler from the CLI (project-pinned, wrapper-style launcher)

Tracks #122.

## Status

Draft. Proposing the architectural shape and migration path; not yet
prescribing the wire protocol or distribution mechanism in detail — those
are called out as open questions at the bottom.

---

## Background

The `labelle` CLI binary currently bundles the code generator (the
"assembler") in-process. In practice this means users must reinstall the
CLI whenever the generator changes — even though the user-facing CLI
surface (commands, flags, UX) is relatively stable. Generator churn drives
almost all CLI reinstalls today.

There is also no way for two projects on the same machine to use different
generator versions, which is a footgun when working across multiple games
at different stages of migration (e.g. flying-platform on the latest, an
older demo still on the previous schema).

### Where the boundary already (almost) exists

The codebase already has most of the structural separation in place:

- `generator/` is its own Zig package with its own `build.zig.zon`
  (`name = .generator`, `version = "0.1.0"`).
- `generator/src/root.zig` exposes a clean public API:
  `generateMainZigFromTemplate`, `generateBuildZig`, `generateBuildZigZon`,
  `validateCache`, `getCacheRoot`, the `ProjectConfig` types, etc.
- `labelle-cli/build.zig.zon` (v1.28.0) consumes it via a path dependency:
  ```zon
  .generator = .{ .path = "generator" },
  ```
- `labelle-cli/build.zig` wires it in as a module both into the main CLI
  binary and into the test executable.

In other words, the generator is already a self-contained library — it's
just statically linked into the CLI binary today. The split is mostly a
matter of giving it its own entry point, defining a subprocess protocol,
and moving version resolution into a thin launcher.

---

## Proposal

Adopt a Gradle-wrapper-style architecture:

1. **`labelle-assembler`** — the existing `generator/` package, now also
   built as its own binary, versioned independently. Owns all code
   generation, `.labelle/` materialization, plugin manifest resolution,
   cache validation, and template rendering.

2. **`labelle` CLI** — becomes a thin, stable launcher. Its job is to:
   - Parse user-facing commands (`run`, `build`, `generate`, `init`,
     `clean`, `update`, `serve`, `install`, `docker`, etc.).
   - Read `project.labelle` and resolve the pinned assembler version.
   - Fetch and cache the matching assembler binary if not present.
   - Invoke the assembler with the resolved arguments.
   - Hand off to `zig build` (or `zig build run`) inside `.labelle/<target>/`
     after the assembler succeeds.

3. **`project.labelle`** gains an `assembler_version` field alongside the
   existing framework/engine/core/gfx pins:
   ```zon
   .{
       .name = "flying_platform",
       .assembler_version = "2.0.0",
       .engine_version = "1.16.0",
       .core_version = "1.8.0",
       .gfx_version = "1.2.0",
       // ...
   }
   ```

4. **Cache layout** — assembler binaries are cached at
   `~/.labelle/assembler/<version>/labelle-assembler` (matching the Zig
   cache shape proposed in #106).

End state: `labelle` is installed once and rarely updated. Generator
upgrades happen by bumping `assembler_version` in `project.labelle`.
Different projects use different assembler versions on the same machine
without conflict.

---

## What needs to move

### Becomes part of `labelle-assembler`

Everything currently re-exported from `generator/src/root.zig`:

- `config.zig` — `ProjectConfig`, `Backend`, `Platform`, `EcsChoice`,
  version constants, `isLocalVersion`.
- `cache.zig` — `validateCache`, `getCacheRoot`, `getPackagesDir`,
  `populateCliCache`.
- `scanner.zig`, `script_scanner.zig` — source-tree scanning.
- `main_zig.zig` — `generateMainZigFromTemplate`.
- `build_files.zig` — `generateBuildZig`, `generateBuildZigZon`,
  `deps_linker`.
- `plugin_manifest.zig`, `template.zig`, `templates/`.

Plus a new `generator/src/main.zig` exposing the subprocess entry point.

### Stays in `labelle` CLI

- `src/cli/init.zig` — project scaffolding (no generation needed).
- `src/cli/runner.zig` — top-level command dispatch.
- `src/cli/clean.zig` — `.labelle/` cleanup.
- `src/cli/install.zig`, `src/cli/update.zig`, `src/cli/upgrade.zig` —
  CLI self-management.
- `src/cli/docker.zig`, `src/cli/serve.zig`, `src/cli/ios.zig` —
  platform/runtime delegation.
- `src/cli/help.zig`, `src/cli/util.zig`, `src/cli/lockfile.zig`.
- `src/cli/cache.zig`, `src/cli/compatibility.zig`, `src/cli/gui_resolve.zig`,
  `src/cli/config.zig` — these need to be audited; some logic may need to
  move to the assembler if it depends on the generator API.

### New: assembler resolver

A new module in the CLI (`src/cli/assembler.zig`) that:

- Reads the `assembler_version` field from `project.labelle`.
- Checks `~/.labelle/assembler/<version>/` for a cached binary.
- Downloads and verifies the binary if missing.
- Spawns it with the user's command and forwards stdout/stderr/exit code.

---

## Wire protocol (sketch)

The CLI ↔ assembler boundary becomes a stable API surface. Two reasonable
shapes:

**Option A: subprocess + plain CLI args.** Simple, debuggable, language-
agnostic. The CLI invokes:
```
labelle-assembler generate --project-root <path> --target raylib_desktop --scene main
```
The assembler exits 0 on success, non-zero with a structured error code on
failure. Stdout is forwarded to the user; stderr carries diagnostics.

**Option B: subprocess + JSON IPC.** The CLI sends a structured request on
stdin, receives a structured response on stdout. Better for capturing
progress events and structured errors, more painful to debug by hand.

Recommendation: start with Option A. It's the path of least resistance,
and the existing `generator/src/root.zig` API maps cleanly onto subcommands.
If we later want richer interaction (progress streams, IDE integrations),
we can layer a JSON mode on top without breaking the simple path.

Whichever we pick, the protocol needs explicit versioning (e.g.
`labelle-assembler --protocol-version`) so the launcher can detect
incompatible pairings before invoking.

---

## Migration

The split should be invisible to existing projects on day one:

1. **Phase 1 — extract.** Add `generator/src/main.zig`, build the assembler
   as a standalone binary, define the Option A protocol. CLI still imports
   the generator in-process; nothing changes for users.

2. **Phase 2 — invoke.** CLI gains the ability to spawn an external
   assembler binary (via `LABELLE_ASSEMBLER` env var or `--assembler-path`
   flag). Used internally for testing the boundary. Default behaviour
   unchanged.

3. **Phase 3 — pin.** Add the `assembler_version` field to `project.labelle`
   (optional). When present, the CLI resolves it via the cache and invokes
   the external binary. When absent, falls back to the bundled in-process
   generator.

4. **Phase 4 — distribute.** Publish assembler binaries via GitHub releases
   (one per generator version). CLI fetches and caches them on demand.

5. **Phase 5 — flip the default.** New projects scaffold with
   `assembler_version` pinned. Existing projects continue to work without
   the field. Eventually deprecate the bundled in-process generator.

Each phase ships independently and is reversible.

---

## Pairs naturally with

- **#106 — Auto-download Zig toolchain.** Same wrapper-style fetching, same
  cache root (`~/.labelle/`). Once both land, the CLI is a tiny stable
  bootstrapper that resolves *both* Zig and assembler versions from
  `project.labelle`. The user installs `labelle` once and never thinks
  about toolchain versioning again.
- **#73 — Hardlink game files instead of copying.** The hardlinking logic
  lives in the generator and would move with it; nothing about the split
  blocks #73.
- **#40 — Cache: patched build.zig.zon for cached packages.** Same
  observation: cache logic stays in the assembler.

---

## Open questions

- **Distribution.** GitHub releases per generator version? A dedicated
  index? How are versions discovered (e.g. `labelle assembler list`)?
  How are binaries verified — checksums in a manifest, signed releases?
- **Bootstrapping.** What does `labelle init` look like when there's no
  `project.labelle` yet? Does the CLI ship with a default
  `assembler_version` baked in, or does `init` reach out to the network on
  first run?
- **Plugin resolution.** Plugins are currently resolved by the generator.
  Do plugin definitions live with the assembler version (so a project
  pinned to assembler 2.0 sees the 2.0 plugin schema), or stay project-
  local? Probably the former, but worth confirming against #77 and the
  plugin manifest RFC.
- **Compatibility matrix.** With independent versioning, we now have an
  N×M matrix of (CLI version × assembler version × engine version × core
  version). How do we surface incompatible combinations to users *before*
  they hit a confusing build failure? The existing `compatibility.zig`
  module is a starting point.
- **Local development.** When hacking on the generator itself, devs need
  to point the CLI at a local checkout. `LABELLE_ASSEMBLER=/path/to/binary`
  is the obvious answer; worth confirming it composes cleanly with
  `--engine-path` and friends.
- **Windows.** Subprocess + binary distribution needs to work cleanly on
  Windows. Path handling in the cache and binary naming
  (`labelle-assembler.exe`) are the obvious gotchas.
