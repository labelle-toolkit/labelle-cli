# RFC: Package-provided commands and build hooks

- Status: Proposed
- Tracking: https://github.com/labelle-toolkit/labelle-cli/issues/406
- First provider (packaging): https://github.com/labelle-toolkit/labelle-cli/issues/405 (see `rfc-android-packaging.md`)
- First provider (runtime): https://github.com/labelle-toolkit/labelle-bgfx/issues/149
- Web phase, first step: https://github.com/labelle-toolkit/labelle-cli/issues/407
- Backend-agnostic assembler: https://github.com/labelle-toolkit/labelle-assembler/issues/378
- Save storage seam: https://github.com/labelle-toolkit/labelle-engine/issues/893

## Summary

Let packages contribute CLI commands and lifecycle hooks, the way gems contribute rake tasks to a Rails app. `labelle android …` would come from the `labelle-android` package, `labelle steam upload` from a future `labelle-steam` package, and so on. The CLI discovers them from the project's pinned packages and dispatches to them.

**Mandate: the CLI is agnostic.** Apart from the host desktop target (see [Core scope](#core-scope)), the CLI source contains no platform, store or package name. This is the assembler's agnosticism mandate (labelle-assembler#378 and #619) applied to the CLI.

This RFC specifies the model, the contracts and the migration order. It does not implement anything.

## Problem

- **Platform code is hardcoded in the CLI.** `src/cli.zig` has dedicated `ios` and `android` branches, and `src/cli/` carries `android/`, `android_sdk.zig`, `ios.zig`, `emsdk_*.zig` and `sdl_provision.zig`. About 35 files under `src/` mention android, ios or emsdk (around 500 mentions of `android` alone).
- **Version coupling.** Android commands must match the runtime glue and manifest of the Android code the project pins, but they ship with the CLI. A fix on either side needs a CLI release. The ASTC capability table goes further and hardcodes a backend's release history: `bgfxWebSamples8x8` in `src/astc/cmd.zig` checks for bgfx ≥ 0.28.1 (#407).
- **Duplication.** At least five APK packaging paths exist: the CLI, the assembler's `package_apk.txt`, the Gradle export, and two scripts in labelle-bgfx (#405). The Android runtime glue is duplicated across backends (labelle-bgfx#149).
- **New targets and stores keep arriving:** Steam, itch.io, iOS, consoles. Each would otherwise grow the CLI. Console SDKs are under NDA, so they *cannot* live in a public CLI at all.

The plugin manifest (`RFC-plugin-manifest.md`) already solved the same inversion for convention directories: plugins declare what they need and the CLI stops knowing about them. This RFC extends that approach to commands, hooks and targets.

## Model: a package has up to three parts

| Package | Runtime | Build hooks | Commands |
| --- | --- | --- | --- |
| android | NativeActivity glue, gamepad, AAudio, video decode | APK/AAB packaging, manifest, signing | `run`, `doctor`, `studio` |
| web | IndexedDB storage backend | HTML/loading shell, compression, size stamping | `serve` |
| steam | Steamworks: achievements, overlay, optional Steam Cloud backend | ship `steam_api` and `steam_appid.txt` in the bundle | `upload`, `doctor` |
| itch | none | none | `publish` (butler) |
| ios | UIKit glue | Xcode project, signing | `run`, `doctor`, `xcode` |

- The **runtime** part is an ordinary labelle plugin; this RFC doesn't change it.
- The **build hooks** and **commands** parts are new.

## Core scope

Some things stay in the CLI, because they are the baseline every project needs with zero packages:

- **The host desktop target:** build, run and bundle for macOS, Windows and Linux (`bundle.zig`, `app_icon.zig`, `linux_desktop.zig`, `launcher_manifest.zig`). It's plain `zig build` with no foreign SDK. Store packages attach to its `bundle` step, so it must be stable core, not a package.
- **Project lifecycle:** `init`, `generate`, `build`, `run`, `test`, `update`, `add`, `plugins`, `doctor` (aggregation), `help`.
- **The generic machinery this RFC adds:** manifest reading, resolution, dispatch, hook execution, the tool cache and the command contract.

Everything that needs a foreign SDK or toolchain (android, ios, web/emsdk), a store, or is backend-specific (e.g. SDL provisioning belongs to the SDL backend package) is a package.

### Default packages

As with Rails' default gems, `labelle init` adds **`labelle-web`** to every new project. It is still a separately versioned package, and a desktop-only game can drop it. labelle-studio's web preview depends on `labelle-web` explicitly and builds through `labelle build --platform=wasm`.

**The CLI does not know this name.** The default set is data, not code:
- the package index publishes a `defaults` list, and `labelle init` adds whatever it names;
- offline, `init` falls back to the scaffold template, a data file outside `src/` whose pins the release workflow already stamps.

So the guard over `src/` and the default package don't conflict.

**The target name stays `wasm`.** `project_config.Platform` and `--platform` use `wasm` today, and `labelle-web` declares the target `wasm`, so no rename or alias is needed. Per the breaking migration below, the one migration step for an existing web project is to add and pin `labelle-web`. After that, `--platform=wasm` resolves to the provider.

## What the CLI knows (generic only)

### 1. Manifest additions

Extend `plugin.labelle` (bump `manifest_version`) with optional fields:

```zig
.{
    .name = "labelle-android",
    .manifest_version = 2,
    .namespace = "android",
    .commands = .{
        .{ .name = "run", .main = "tools/run.zig", .help = "Build, install and launch on a device" },
        .{ .name = "doctor", .main = "tools/doctor.zig", .help = "Check the SDK, NDK and device setup", .needs_project = false },
    },
    .hooks = .{
        .{ .step = .package, .target = "android", .when = .replace, .main = "tools/package.zig" },
    },
    .targets = .{ "android" },
    .command_contract = ">=1.0.0 <2.0.0",
}
```

The field names are illustrative; the serialization is an implementation decision. The semantics are what matter:
- `namespace` owns the `labelle <namespace> …` subcommands.
- `commands` are tools built from the package's own source.
- `hooks` attach to built-in lifecycle steps.
- `targets` are the values `--platform` accepts because this package is installed.
- `command_contract` is the contract range the package was written against. It is **required** whenever `commands`, `hooks` or `targets` is present; a manifest that declares any of them without it is rejected at resolve time.
- `needs_project = false` marks a command that may run outside a project (see the projectless context below). It defaults to `true`.
- `namespace` may not be a built-in command name (`run`, `build`, `help`, …). Reserved names are rejected at resolve time with a clear error, rather than silently becoming unreachable.

### 2. Command contract (versioned)

- **Input:** the CLI passes a context to every command and hook, via arguments or a small JSON file in the environment:
  - project dir and resolved target;
  - optimize mode and the lock file;
  - output dir and the Zig executable;
  - progress protocol handles and a credentials helper (keychain/env).
- **Output:** an exit code, plus the existing progress/JSON output protocol.
- **Projectless context:** for a `needs_project = false` command run outside a project, `project dir`, `target` and `lock` are explicitly `null` in the context. The optimize mode defaults to Debug, and the Zig executable is the bootstrap version the provider metadata declares (see [Resolution](#resolution)). Running a `needs_project = true` command outside a project fails with "run this inside a labelle project" before anything is fetched or built.
- **Versioning:** the CLI declares the single contract version it implements (e.g. `1.0.0`, a constant in the CLI).
  - At resolve time, every provider's `command_contract` range must include it, or resolution **fails before anything runs**, naming the package, its range and the CLI's version.
  - This is **new, fatal behaviour**. It deliberately does not reuse the existing compatibility paths: `depCompatWarn` and the `core_compat` check in `src/cli/compatibility.zig` both warn and proceed.

### 3. Lifecycle hook points

- **Named after steps, never platforms:** `generate`, `build`, `bundle`, `package`, `run`.
- **How a package attaches:** each hook names a step and a `target`.
  - `before` and `after` (like rake's `enhance`) may attach to **any** target, including core-owned `desktop`, **without claiming it**.
  - `replace` is allowed only for a target the package itself declares in `targets`.
- **Example:** a steam package adds `steam_api64.dll` to the normal `labelle bundle` without owning `bundle`.

### 4. Output layout

The CLI owns a stable layout, e.g. `zig-out/bundle/<target>/…` and `zig-out/package/<target>/…`, which packages read and write. `steam upload` and `itch publish` both consume the output of `labelle bundle` instead of each re-deriving it.

### 5. Aggregation

`labelle help` lists package commands under their namespace. `labelle doctor` runs each package's `doctor` command if it declares one.

## Execution

- **Compile on first use.** The CLI is a prebuilt binary and packages are Zig source, so a command's `main` is compiled with the project's pinned Zig the first time it runs, then cached by command entry point, package content hash, resolved dependency graph, Zig version, host OS/architecture/ABI, command-contract version, and effective build options. Different commands and projects must not accidentally reuse an incompatible executable. Local package edits invalidate the cache by content, not version label. Tools compile for the host, not the game target.
- **Cost:** a few seconds on first use; later runs use the cache.
- **Windows:** package tools must build and run there too, and CI for provider packages must cover it.
- **Trust, inside a project:** the package is declared in `project.labelle` and pinned by hash in `labelle.lock`, exactly like every dependency the game build already compiles and runs. Package commands add no new trust boundary there.
- **Trust, outside a project:** there is no project pin, so the index is a new trust boundary.
  - Index entries carry a content hash for each release. The CLI verifies the fetched archive against it before building, as `zig fetch` does.
  - The index is served over HTTPS from the same origin as CLI releases and is written only by the providers' release workflows.
  - The first time an unpinned package would run, the CLI asks for confirmation, showing the package, version, source URL and hash (`--yes` for CI).
  - Once confirmed, it records the pin in a global lock (`~/.labelle/global.lock`); later runs use that pin until `labelle update` moves it.
  - Signing releases (beyond hash integrity) is an open question.

## Resolution

- **Inside a project:** providers come from `project.labelle` and `labelle.lock`, so each project gets the versions it's locked to, like a Gemfile.
- **No project yet:** on a fresh machine, e.g. `labelle android doctor`, a small generic **package index** answers "who provides namespace `android`" and fetches the **newest release whose `command_contract` range includes this CLI's contract version**. Its latest release is used only if it's compatible, so an older CLI keeps working after a provider moves to the next contract major. There is no list of names in the code. The resolved provider metadata declares an exact supported Zig bootstrap version; the generic CLI toolchain installer provisions it before compiling the host tool. This metadata is readable without executing provider code. Missing toolchains in offline mode produce an actionable error. Record the resolved provider and compiler versions locally so the next invocation reuses them until an explicit update. No project or project lock is required for this bootstrap.
- **Dispatch order in `src/cli.zig`:**
  1. built-in commands;
  2. package namespaces;
  3. the existing directory shorthand;
  4. the "unknown command" error.

  Namespaces can never shadow built-in commands.
- **`--platform=<t>`** dispatches to the package that declares target `<t>`. The set of platforms comes from the installed packages, not the CLI. This is the biggest change, and it must line up with labelle-assembler#378.
- **Conflicts:** two providers of the same namespace or target is a resolve-time error, not "last one wins". So is a namespace that collides with a built-in command.

## Runtime seams (not CLI, but same rule)

Runtime services follow the same single-provider rule through engine seams. For example, save storage (labelle-engine#893):
- the target's default applies (files on desktop, IndexedDB on web) unless a package claims the slot;
- a double claim is an error;
- save_slots and any storage package depend only on the seam, never on each other.

Steam's first version needs no storage code at all. Steam Auto-Cloud syncs the game's per-user save directory, which only has to be stable (FP#773, `LABELLE_DATA_DIR`).

## Enforcement

- **A guard test in CI** fails the build if platform, store or package names (`android`, `ios`, `steam`, `emsdk`, …) appear in `src/`. It is modelled on labelle-bgfx's `heap_guard_test`.
- **The allowlist:** host OS names (`macos`, `windows`, `linux`) are permanently allowed. Everything else sits on an explicit, shrinking migration allowlist.

## Migration

1. **#405:** a single APK packaging path, which becomes the code that moves in step 3.
2. **labelle-bgfx#149:** create `labelle-android` with the shared runtime pieces (services first, then an optional NativeActivity shell with renderer callbacks).
3. **The mechanism:** manifest fields, contract, dispatch, hooks, cache and index. `labelle-android` is the first provider; `src/cli/android/` and `android_sdk.zig` move there. This is a breaking migration: existing projects explicitly add and pin the provider and update configuration and commands. There is no forwarding shim, automatic provider injection, or compatibility window.
4. **Web, as the second provider and a default package:**
   - first #407: move the backend × platform ASTC table and the bgfx version check into backend manifests;
   - then `labelle-web` takes the `emsdk_*` files, `serve.zig`, the HTML/loading shell (#401/#402), compression and size stamping, and the IndexedDB backend;
   - emscripten linking stays with the backend packages.
5. **iOS** (`ios.zig`) moves the same way, and `sdl_provision.zig` moves to the SDL backend package. `docker.zig` is to be decided.
6. **Steam:** the first store package, confirming the contract generalises. It hooks into desktop `bundle` and provides `labelle steam upload` and `labelle steam doctor`.

The guard's allowlist shrinks at every step, and after step 5 only host OS names remain. Existing web projects explicitly add `labelle-web` and migrate `--platform=wasm` and `labelle wasm ...` to the new provider target/commands. Do not retain legacy aliases. Publish migration instructions with the breaking release; old configurations are unsupported until migrated.

## Acceptance checks

- A project with `labelle-android` pinned runs `labelle android run` from the package's pinned version. Changing the pin changes the command without a CLI release.
- A project without it gets a clear "no provider for namespace `android`; add labelle-android" message, never a run fallthrough.
- `labelle help` and `labelle doctor` show package commands and checks.
- The guard test passes with only host OS names allowed, once step 5 is done.
- Package commands work on Windows, macOS and Linux runners.
- Two tools in one package, and the same tool under distinct compiler/dependency inputs, use distinct cache entries; unchanged inputs reuse the executable.
- On a fresh host without a project or Zig installation, a projectless diagnostic provisions its declared compiler and runs. Offline missing-toolchain failure is clear.
- Explicitly migrated projects run with pinned providers; unmigrated configurations fail clearly without legacy forwarding or implicit package injection.
- A provider whose `command_contract` excludes the CLI's version fails at resolve time, naming both versions, and nothing is built or run.
- A projectless command verifies the archive hash and asks for confirmation before its first run.
- After adding `labelle-web`, `labelle build --platform=wasm` works under the unchanged target name. Without it, the command fails clearly, naming the provider to add.

## Open questions

- **Hook ordering:** when several packages attach to the same step, is it declared priority or dependency order?
- **Package index:** its exact format and hosting (an R2 JSON next to the CLI releases?). The integrity and selection rules above apply regardless.
- **Signing:** should provider releases be signed, or is hash integrity plus a trusted index origin enough?
- **Contract surface:** does the credentials helper belong in the contract, or does each package handle its own secrets?
- **Proprietary SDKs** (Steamworks, consoles): only bring-your-own, with `doctor` pointing to the local SDK path, as with the Spine license?
- **Tool builds:** should the tool cache be project-local or global? Either placement must use the complete cache identity specified above.
