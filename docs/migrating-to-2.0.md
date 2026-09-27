# Migrating a project to labelle CLI 2.0

CLI 2.0 no longer builds Android or wasm by itself. Every target except
`desktop` now comes from a **provider package** that the project pins, like
any other plugin ([RFC #406](rfc-package-commands.md), cli#405):

| Target | Provider package (`.plugins` name) | Repository | Namespace |
|---|---|---|---|
| `android` | `android` | `github.com/labelle-toolkit/labelle-android` | `labelle android …` |
| `wasm` | `web` | `github.com/labelle-toolkit/labelle-web` | `labelle web …` |

The [provider registry](https://github.com/labelle-toolkit/labelle-registry/blob/main/providers.json)
is the source of truth for which package owns which target and which
releases exist. If you build a target whose provider is missing, the CLI looks
the owner up there and prints the exact `.plugins` line to add (see
[Troubleshooting](#troubleshooting)).

A 1.x project that is not migrated still builds for `desktop`, but
`--platform=android`, `--platform=wasm`, `labelle wasm serve/export` and
`labelle android …` fail until it is. This guide covers the whole change.
Flying Platform's migration
([moca-tecnologia/flying-platform-labelle#956](https://github.com/moca-tecnologia/flying-platform-labelle/pull/956))
is the worked example quoted throughout.

## Checklist

1. [Bump the pins](#1-bump-the-pins): `.labelle_version = "2.0.0"`, `.assembler_version` ≥ 0.116.
2. [Check `.backend`](#2-check-backend): a project that declares none now builds with bgfx.
3. [Add the providers](#3-add-the-providers-to-plugins) you need to `.plugins`.
4. [Pin them](#4-pin-them-labelleproviderslock): `labelle providers resolve`, then `--accept`; commit `labelle.providers.lock`.
5. [Move the Android packaging keys](#5-move-the-android-packaging-keys) out of `.android` into `providers/android.json`, mapped with [`.provider_config`](#6-provider_config).
6. [Update CI and fresh clones](#7-ci-and-fresh-clones): run `labelle providers fetch`.
7. [Replace the removed commands](#8-commands-that-moved) (`labelle wasm serve/export`, projectless `labelle android doctor`).
8. [Run `labelle doctor`](#9-labelle-doctor), which now also runs the provider doctors.

## 1. Bump the pins

```zig
.labelle_version = "2.0.0",
.assembler_version = "0.116.1", // or newer
```

- **Assembler ≥ 0.116.** 0.116.0 removed the generated APK packaging step
  (the `android` provider packages the APK now) and rejects the old `.android`
  packaging keys ([step 5](#5-move-the-android-packaging-keys)). Use 0.116.1
  or newer: 0.116.0 fails to install into a clean labelle home. Older
  assemblers do not know `.provider_config` or manifest-v2 plugins.
- `labelle upgrade all` bumps `.labelle_version`, `.assembler_version` and the
  core/engine/gfx pins to this CLI's tested set in one go. It does not do the
  provider migration below; that part is a project edit.
- The CLI warns while `.labelle_version` is still on 1.x
  (`cli 1.67.0 is behind this CLI's tested cli line (2.0.0)`) and links this
  guide.

Flying Platform went from `.assembler_version = "0.115.0"` to `"0.116.1"` and
from `.labelle_version = "1.67.0"` to `"2.0.0"`.

## 2. Check `.backend`

With the 2.0 CLI's assembler line (0.117.x, the default for new projects), a
project that declares **no** `.backend` builds with **bgfx**; the old default
was raylib. To keep raylib, say so:

```zig
.backend = .raylib,
```

A project that already declares `.backend` is unaffected. For Android, the
packager is verified end to end on bgfx; use labelle-bgfx ≥ 0.30.0, whose build
hook links one copy of the `labelle_android` JNI helpers (older bgfx fails the
`libgame.so` link with duplicate `labelle_android_*` symbols).

## 3. Add the providers to `.plugins`

Add only the targets you build. Use the `github.com/` repository form and an
exact version; the registry lists the releases (`labelle providers resolve`
prints them too):

```zig
.plugins = .{
    // ... your existing plugins ...
    .{ .name = "android", .repo = "github.com/labelle-toolkit/labelle-android", .version = "0.2.1" },
    .{ .name = "web", .repo = "github.com/labelle-toolkit/labelle-web", .version = "0.2.0" },
},
```

The `.plugins` name must be exactly the registry package name (`android`,
`web`): it is also the provider's name in `.provider_config` and the lock.
Target names do not change: `--platform=android` and `--platform=wasm` work as
before once their provider is pinned.

To develop a provider, pin a local checkout instead
(`.{ .name = "android", .repo = "local:../labelle-android" }`); local
packages need no lock entry.

## 4. Pin them: `labelle.providers.lock`

A remote provider's code runs only when `labelle.providers.lock` pins it
(repository, commit and archive sha256 from the registry). Pinning is always
explicit and reviewed:

```sh
labelle providers resolve            # preview: shows each release, commit, sha256, targets
labelle providers resolve --accept   # verify the archives and write labelle.providers.lock
git add labelle.providers.lock
```

`--accept` refuses anything that differs from the preview it follows. Commit
the lock: it is what every other checkout and CI builds against. Re-run both
steps whenever you change a provider's `.version`. See
[provider GitHub pins](provider-github-pins.md) for the details.

Flying Platform's lock after `--accept`:

```json
{
  "schema_version": 1,
  "providers": [
    { "package": "android", "repo": "labelle-toolkit/labelle-android", "version": "0.2.1",
      "commit": "e14fa5bd8e60b67b5f712b6f3de7059515ae3922",
      "sha256": "7479b6989ebb0194da8fcad5e4f4ffc6600f8c92b4f6a199888fa52b1e023470" },
    { "package": "web", "repo": "labelle-toolkit/labelle-web", "version": "0.2.0",
      "commit": "1d669eea770ec74108f2bc30fa5a0aed5d5a27ad",
      "sha256": "d9cf119d545f30c04935ee652bd77c8c718c47e4549f6023ba29ade2a7fe7e8e" }
  ]
}
```

## 5. Move the Android packaging keys

APK packaging moved from the CLI to the `android` provider, and so did its
settings. Only three keys stay in `project.labelle`'s `.android` block, because
the assembler reads them when it generates the game:

| Stays in `.android` | Why |
|---|---|
| `immersive_mode` | emitted into the generated `main.zig` (the provider also reads it for the fullscreen theme) |
| `target_sdk_version` | the NDK link level of the generated `build.zig` |
| `load_assets_from_apk` | APK asset loading at acquisition (not supported by the provider packager yet) |

Everything else moves to `providers/android.json`: `app_name`,
`package_name`, `min_sdk_version`, `orientation`, `debuggable`,
`version_name`, and the new `abis`, `signing` and `deploy`. Assembler ≥ 0.116
refuses a moved key with a hint naming it:

```
`.android.package_name` is no longer read from project.labelle: move package_name to providers/android.json (labelle-android provider; see labelle-cli#405)
```

`providers/android.json` is schema v1 of the labelle-android provider; its
[README](https://github.com/labelle-toolkit/labelle-android#providersandroidjson-schema-v1)
is the reference. In short:

| Key | Required | Default | Notes |
|---|---|---|---|
| `schema_version` | yes | | `1` |
| `package_name` | yes | | `[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+` |
| `app_name` | no | project `.title` | |
| `min_sdk_version` | no | `28` | at least 28 |
| `target_sdk_version` | no | `34` | the APK manifest's; at least `min_sdk_version` |
| `orientation` | no | `"all"` | a string now: `portrait`, `landscape`, `sensor_landscape`, `all` |
| `debuggable` | no | `false` | on-device verification only |
| `version_name` | no | `"1.0"` | `versionCode` comes from `labelle bundle --build-number` |
| `abis` | no | `["arm64-v8a"]` | exactly that in v1 |
| `signing` | no | debug keystore | passwords as `env:VAR` or `file:PATH`, never literals |
| `deploy` | no | | `repo` (`owner/name`) and `channel` for `labelle android deploy` |

The parse is strict: unknown or duplicate keys fail before the provider does
anything. Without `signing`, the provider signs with the same debug keystore
the 1.x CLI used (`~/.labelle/android-debug.keystore`), so `adb install -r`
keeps updating an app a 1.x CLI installed. `target_sdk_version` may appear in
both places: `.android` sets the NDK link level, the JSON sets the APK
manifest; keep them equal unless you mean otherwise.

Flying Platform, before:

```zig
.android = .{
    .immersive_mode = true,
    .app_name = "Flying Platform",
    .package_name = "com.labelle.flying_platform",
    .orientation = .landscape,
},
```

After (`project.labelle`):

```zig
.android = .{
    .immersive_mode = true,
},
```

and `providers/android.json`, keeping the effective values the 1.x CLI used
(defaults written out):

```json
{
  "schema_version": 1,
  "package_name": "com.labelle.flying_platform",
  "app_name": "Flying Platform",
  "min_sdk_version": 28,
  "target_sdk_version": 34,
  "orientation": "landscape",
  "debuggable": false,
  "version_name": "1.0"
}
```

Its APK came out byte-for-byte the same size (40,218,789 bytes, same entries,
same `aapt dump badging`) as the 1.x CLI's.

## 6. `.provider_config`

A provider reads its settings file only when `project.labelle` maps it:

```zig
.provider_config = .{
    .{ .package = "android", .file = "providers/android.json" },
},
```

Each entry names a package already in `.plugins` and a project-relative JSON
file. The CLI checks the mapping and the JSON before any provider runs; the
provider validates the contents. The `web` provider needs no file (all its
keys, `build_dir`, `port` and `open_browser`, are optional); map one only if
you want them. See [provider configuration](provider-configuration.md).

## 7. CI and fresh clones

No normal command downloads a provider. On a fresh clone, a CI runner or an
emptied cache, fetch the pinned archives once, after installing the CLI and
before any other `labelle` command:

```sh
labelle providers fetch
```

It downloads exactly what `labelle.providers.lock` pins, verifies each sha256,
never reads the registry and never changes the lock. (A bare `labelle install`
in the project does the same.) Without it every command that reads the project
fails with `ProviderArchiveMissing`, desktop `generate` included.

Flying Platform's CI adds this step to every job:

```yaml
- name: Fetch pinned provider archives
  run: labelle providers fetch
```

and its Android job checks the SDK before building:

```yaml
- name: Check Android packaging tools
  run: labelle android doctor
- name: Build Android APK (ReleaseFast)
  run: labelle build --platform=android --optimize=ReleaseFast
```

The APK is now `.labelle/<backend>_android/zig-out/apk/game.apk` (produced by
the provider's after-build `package` hook), with the unstripped library under
`zig-out/apk/symbols/arm64-v8a/`. For wasm, the `web` provider's after-build
`shell` hook stages the sized loading page into `.labelle/<backend>_wasm/zig-out/web/`.

## 8. Commands that moved

| 1.x | 2.0 |
|---|---|
| `labelle build --platform=android` | unchanged (needs the `android` provider); now also packages the APK |
| `labelle run --platform=android` | unchanged; the provider installs and launches the APK on a device |
| `labelle bundle --platform=android` | unchanged; release APK in `zig-out/bundle/android/` |
| `labelle android doctor` outside a project | `labelle android doctor` inside a project that pins `android` |
| `labelle wasm serve` | `labelle run --platform=wasm`, or `labelle web serve` for an existing build |
| `labelle wasm export` | `labelle bundle --platform=wasm`, or `labelle web export` |

The legacy `labelle wasm serve/export` verbs still exist, but they need a
provider for target `wasm`, and a provider that replaces `run` for `wasm` (as
`web` does) refuses them because it cannot receive their flags. Inside a
project, `labelle help` lists every pinned provider's commands under
"Project package commands", and `labelle targets` lists the targets they own.

## 9. `labelle doctor`

`labelle doctor` checks the core build requirements and then, inside a
project, runs each pinned provider's `doctor` command (`labelle android
doctor`, …), exiting non-zero if any check fails. `labelle doctor --core-only`
skips the providers.

## Troubleshooting

**`no provider for target 'android' in this project`.** The provider is not in
`.plugins` (or not pinned). The CLI looks the target up in the provider
registry and prints the entry to add, for example:

```
labelle: no provider for target 'android' in this project; add and pin the package that declares target 'android'
  (registry: android)
  the provider registry lists package 'android' 0.2.1 as the provider of target 'android'. To use it:
    1. add it to .plugins in project.labelle:
         .{ .name = "android", .repo = "github.com/labelle-toolkit/labelle-android", .version = "0.2.1" },
    2. labelle providers resolve            # preview the pin
    3. labelle providers resolve --accept   # verify it and write labelle.providers.lock (commit it;
                                            # fresh clones and CI run `labelle providers fetch`)
  If --accept reports UnsupportedContract, that release needs a newer CLI: choose an older release.
```

The lookup reads registry metadata only (nothing is pinned, cached or run)
and gives up after a few seconds. A project that last accepted from its own
`providers.json` (a fork URL or a local file) is answered by that source,
never the public registry. `LABELLE_OFFLINE=1` skips any download; then, or
when no registry can be read, the last accepted copy is used if it names the
owner, and otherwise the steps are generic and say why. The failure itself is
the same either way.

Two limitations: the registry does not say which CLI a release needs, so if
`--accept` reports `UnsupportedContract`, choose an older release of the
package. And the record of a custom registry source lives in `.labelle/`;
deleting that directory makes the hint ask the public registry again until
you re-run `labelle providers resolve <source> --accept`.

**`target 'android' is declared by remote package 'android', which is unpinned`.**
The package is in `.plugins` but not in `labelle.providers.lock`: run
`labelle providers resolve`, then `--accept`.

**`ProviderArchiveMissing` … run `labelle providers fetch`.** A fresh clone or
CI runner: see [step 7](#7-ci-and-fresh-clones).

**`no registry release of 'android' matches the project's .repo … and .version …`.**
The `.version` is not a published release; pick one `labelle providers
resolve` lists.

**`.android.<key>` is no longer read from project.labelle.** See
[step 5](#5-move-the-android-packaging-keys).

**`legacy wasm serve/export cannot invoke run replacement 'web/serve'`.** Use
`labelle run --platform=wasm` / `labelle bundle --platform=wasm` or
`labelle web serve` / `labelle web export` ([step 8](#8-commands-that-moved)).

**Older CLIs reject the providers.** CLI 1.x reserves the `android` namespace
and cannot build a project pinned this way; everyone building the project needs
CLI ≥ 2.0.0 (`labelle update`).
