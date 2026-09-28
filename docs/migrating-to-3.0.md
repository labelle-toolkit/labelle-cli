# Migrating a project to labelle CLI 3.0

CLI 3.0 finishes the web phase of [RFC #406](rfc-package-commands.md)
([RFC cli#466](https://github.com/labelle-toolkit/labelle-cli/issues/466)).
The CLI core no longer knows how to build, serve or package for the browser.
The `wasm` target, its emscripten toolchain (emsdk), the local server and the
export all come from the **`web` provider**
([labelle-toolkit/labelle-web](https://github.com/labelle-toolkit/labelle-web))
0.3.0 or newer.

If your project doesn't build for `wasm`, the only 3.0 changes that can affect
you are [`--docker`](#--docker) and the [`labelle doctor --json`
document](#labelle-doctor). A `desktop` project needs no edit.

A project that already builds for `wasm` with `web` 0.3.x on CLI 2.1 is
already migrated: it keeps building unchanged on 3.0. Flying Platform's
migration
([moca-tecnologia/flying-platform-labelle#959](https://github.com/moca-tecnologia/flying-platform-labelle/pull/959))
is the worked example.

## Checklist

1. [Pin `web` 0.3.0 or newer](#1-pin-web-030-or-newer) and bump `.labelle_version`.
2. [Replace the removed commands](#2-removed-commands).
3. [Drop the removed escape hatches](#3-removed-escape-hatches-and-settings)
   (`--emcc`, `LABELLE_EMSDK`, `.emsdk_version`) and move the emsdk choice
   into the provider's settings.
4. [Remove manual emsdk steps from CI](#4-ci-and-fresh-clones), and cache the
   provider's toolchain instead.
5. [Stop using `--docker` for `wasm`](#--docker).
6. [Check `labelle doctor`](#labelle-doctor) and any tool that reads
   `labelle doctor --json`.

## 1. Pin `web` 0.3.0 or newer

`web` 0.3.0 speaks provider contract 1.3, which CLI 2.1.0 introduced. It
provisions emsdk, defaults `wasm` builds to ReleaseSafe and serves with browser
live reload. `web` 0.2.x relied on the CLI to activate emsdk. On 3.0 nothing
does that for it, so a 0.2.x build fails at the assembler's emsdk preflight.

```zig
.labelle_version = "3.0.0",
.plugins = .{
    .{ .name = "web", .repo = "github.com/labelle-toolkit/labelle-web", .version = "0.3.1" },
    // ...
},
```

Then pin it and commit the lock:

```sh
labelle providers resolve            # preview
labelle providers resolve --accept   # write labelle.providers.lock
```

The target name is unchanged: `--platform=wasm` still means `wasm`.

## 2. Removed commands

| Removed in 3.0 | Use instead |
|---|---|
| `labelle wasm serve` | `labelle run --platform=wasm` (build, then serve), or `labelle web serve` for an existing build |
| `labelle wasm serve --watch` | `labelle run --platform=wasm --watch` |
| `labelle wasm serve --port N --no-open` | `labelle run --platform=wasm -- --port=N --no-open`, or `labelle web serve --port=N --no-open` |
| `labelle wasm export` | `labelle bundle --platform=wasm`, or `labelle web export [--output=DIR] [--zip] [--platform=itch\|github-pages]` |
| `labelle wasm serve\|export --no-build` | `labelle web serve` / `labelle web export`, which act on an existing build |
| `labelle install emsdk <ver>` | `labelle web toolchain install [<ver>]` (inside the project) |
| `labelle toolchain emsdk [dir]` | `labelle web toolchain which` (inside the project) |

`labelle wasm …` is now an ordinary unknown command. `wasm` is no longer a
reserved word, so a package may declare it as a namespace. `labelle install
python` stays: `.prebuild` steps and provider commands and hooks use the
managed interpreter.

The `web` commands are project-scoped (RFC cli#466 D10): run them inside the
project that pins `web`.

## 3. Removed escape hatches and settings

| Removed | Replacement |
|---|---|
| `--emcc <path>` | An activated emsdk in `EMSDK`, or `emsdk.root` in the provider settings |
| `LABELLE_EMSDK` | The same |
| `.emsdk_version` in `project.labelle` | `emsdk.version` in the provider settings |

The CLI no longer reads any of these, and nothing warns you that one is set.
Remove `.emsdk_version` from `project.labelle` and move its value into the
provider's settings. Those live in a JSON file that the project maps with
`.provider_config`:

```zig
.provider_config = .{
    .{ .package = "web", .file = "providers/web.json" },
},
```

```json
{ "schema_version": 1, "emsdk": { "version": "4.0.9", "source": "managed", "root": null } }
```

`emsdk.source` is `managed` (the default), `inherited`, `root` or `package`.
The [labelle-web README](https://github.com/labelle-toolkit/labelle-web#emscripten-toolchain)
describes each one. An `EMSDK` that points at an activated emsdk is passed
through in `managed` mode as well.

The ReleaseSafe default for `wasm` builds is now the provider's manifest
`.target_defaults`. An explicit `--optimize` still wins.

## 4. CI and fresh clones

- Delete any manual `./emsdk install` / `./emsdk activate` loops over
  `zig-pkg/*/emsdk`. The provider's `toolchain` hook provisions emsdk before
  generation.
- The managed emsdk lives in the provider's persistent cache,
  `<LABELLE_HOME>/providers/<canonical provider id>/` (about 1 GB). Cache that
  directory between CI runs instead of `~/.labelle/emsdk/`.
- The old CLI cache `~/.labelle/emsdk/` is neither migrated nor deleted.
  Remove it yourself once no CLI 2.x project on the machine needs it.
- A fresh checkout still runs `labelle providers fetch` (or `labelle
  install`) once, to download the pinned provider archives.
- With `LABELLE_OFFLINE=1`, a cached emsdk is reused. A missing one fails in
  the provider's `toolchain` hook, naming the version.

## `--docker`

`--docker` now builds the core `desktop` target only (RFC cli#466 D5). A
provider target's hooks, their environment contributions and the toolchain
they provision all run on the host, and the container sees none of them. So
`--docker` with a provider target (`--platform=wasm`, `--platform=android`,
…) is refused before anything runs:

```
labelle: --docker builds the `desktop` target only; target 'wasm' comes from a provider, whose hooks and toolchain run on this host
  build it without --docker (docs/migrating-to-3.0.md)
```

Build those targets without `--docker`. `labelle build --docker
[--target=<triple>]` for `desktop` is unchanged.

## `labelle doctor`

The core no longer checks emsdk. It reports only what it owns. The pinned
`web` provider's doctor reports the rest: its `labelle web doctor` rows are
shown after the core checks.

`labelle doctor --json` changed shape:

- The core's capabilities are now `zig` (required) and `python` (optional,
  `required: false`, fixable through `labelle install python`).
- The `wasm` capability (`python`, `emsdk` and `git` items) is the `web`
  provider's. It appears only inside a project that pins `web`, and the core
  no longer emits one of its own.

Tools that looked for a core `wasm` capability outside a project, such as
labelle-studio's toolchain gate, must read it from a project that pins `web`
(RFC cli#466 D12 tracks the Studio follow-up).

## Also changed

- The CLI no longer keeps its own list of backends that can build for `wasm`.
  The assembler checks this when it generates (RFC cli#466 D13): the
  project's required capabilities against the backend manifest's
  `.capabilities`, and the manifest's `.platforms.<platform>` entry. A backend
  without `wasm` support fails with the assembler's diagnostic, for example
  `backend provider '…' does not support capability 'wasm' required by this project`.
- `labelle run --platform=wasm` without a provider `replace run` hook is
  refused before the build (`NoRunReplacement`), like every other provider
  target. `web` 0.3.x declares one.

## Troubleshooting

**`labelle: unknown command 'wasm'`.** See [removed commands](#2-removed-commands).

**The build fails at the assembler's emsdk preflight, or emcc is not found.**
The project still pins `web` 0.2.x. Pin 0.3.0 or newer
([step 1](#1-pin-web-030-or-newer)).

**`--docker builds the desktop target only`.** Build without `--docker`
([`--docker`](#--docker)).

**`no provider for target 'wasm'`.** The project doesn't pin `web` yet. See
[Migrating to 2.0](migrating-to-2.0.md#3-add-the-providers-to-plugins).
