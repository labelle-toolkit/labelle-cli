# Migrating a project to labelle CLI 4.0

CLI 4.0 finishes [RFC #406](rfc-package-commands.md) with its last phase,
[RFC cli#471](https://github.com/labelle-toolkit/labelle-cli/issues/471): the
CLI core no longer knows any platform, backend or store. What it used to
hard-code now comes from two places:

- **The assembler** answers every backend and target question through
  `labelle-assembler describe`: which backend package the project resolves
  to, the generated target directory, the asset format, and whether the pair
  is supported.
- **Providers** own everything platform-specific: iOS comes from
  [labelle-ios](https://github.com/labelle-toolkit/labelle-ios), and SDL2 on
  Windows from the `sdl2` provider in
  [labelle-sdl](https://github.com/labelle-toolkit/labelle-sdl).

A `desktop` project on bgfx, raylib or sokol with `.gamepad = .none`, pinned
to assembler 0.118.0 or newer, needs no edit.

## Checklist

1. [Pin assembler 0.118.0 or newer](#1-pin-assembler-01180-or-newer).
2. [iOS: add labelle-ios](#2-ios-add-labelle-ios) if you build for `ios`.
3. [SDL2 on Windows: add the `sdl2` provider](#3-sdl2-add-the-sdl2-provider)
   if a Windows build links SDL2.
4. [Check the smaller changes](#4-also-changed).

## 1. Pin assembler 0.118.0 or newer

`generate`, `describe` and `upgrade backend` need assembler protocol 7, which
shipped in assembler 0.118.0. An older `.assembler_version` fails with a
one-line error that names `labelle upgrade assembler`.

```zig
.assembler_version = "0.120.0",
```

`labelle upgrade all` bumps the assembler first, then asks it to bump the
backend (`labelle-assembler upgrade backend`). If the assembler refuses,
`project.labelle` is restored, unless you pass `--force`.

## 2. iOS: add labelle-ios

The core `labelle ios` command, the simulator launch and the forced sokol
backend are gone. The `ios` target belongs to the labelle-ios provider:

```zig
.plugins = .{
    .{ .name = "ios", .repo = "github.com/labelle-toolkit/labelle-ios", .version = "0.1.0" },
},
```

Then use the normal commands: `labelle build|run|bundle --platform=ios`.

- `labelle ios …` is now an unknown command.
- The backend is no longer switched to sokol behind your back. Set
  `.backend = .sokol` (or a `.backend_package` whose manifest supports iOS)
  yourself; `describe` refuses an unsupported pair with its reason.
- iOS targets generate into `.labelle/<backend>_ios`.
- A leftover `.ios = .{ … }` block in `project.labelle` still parses and is
  ignored. labelle-ios reads its settings from `providers/ios.json`.

## 3. SDL2: add the `sdl2` provider

The CLI no longer downloads SDL2 on Windows, sets `LABELLE_SDL2_LIB`, or
copies `SDL2.dll` beside the game. Any of these replaces it:

- Add the provider. It provisions SDL2 on Windows and stages the DLLs, and
  does nothing on macOS or Linux:

  ```zig
  .{ .name = "sdl2", .repo = "github.com/labelle-toolkit/labelle-sdl", .version = "0.4.0" },
  ```

  `labelle sdl2 doctor` checks the install; `labelle sdl2 install` fetches it.
- Point `LABELLE_SDL2_LIB` at your own SDL2 MinGW `lib` directory.
- Turn the gamepad off with `.gamepad = .none`, if you don't use one.

Without any of them, a Windows build that needs SDL2 stops with one line:
`SDL2 not found: set LABELLE_SDL2_LIB or use .gamepad = .none`.
The core `labelle doctor` no longer mentions SDL2: `labelle sdl2 doctor`
reports it, and a plain `labelle doctor` runs that too once the project
lists `sdl2`.

## 4. Also changed

- **Target directory.** The generated directory is the one the assembler
  reports. For a third-party `.backend_package` without a matching
  `.backend`, that is `.labelle/<package>_<target>`, where 3.x wrongly used
  `.labelle/bgfx_<target>`.
- **Unknown targets.** The assembler judges them. A name no provider declares
  and the assembler can't generate for stops with describe's reason, for
  example: `backend 'bgfx' has no target 'probe-target': this assembler
  generates for desktop ios android wasm`.
- **`labelle astc --backend`** is accepted and ignored, with a deprecation
  line. Texture capabilities come from the project's backend package, and for
  the `.backend` shorthand `describe` locates it, so the declared default
  block is used instead of the conservative one.
- **`.platform`** must be an enum literal (`.platform = .desktop`); the CLI
  reads it as a target name.
- **`labelle doctor --fix`** has nothing left to fix in the core. It is
  forwarded to every provider doctor, as `labelle <namespace> doctor --fix`
  (`--json --fix` too). A provider's `doctor` must accept `--fix`, ignoring
  it when it has nothing to fix; one that rejects it fails its own check.
- **`labelle test`** always runs the generated tests in `.labelle/tests/`.
- **`--docker`** refuses macOS targets, including a bare `--docker` on a Mac
  (since 3.1). Linux and Windows cross builds are unchanged.

## Troubleshooting

| Message | Fix |
|---|---|
| `assembler … protocol … labelle upgrade assembler` | [Step 1](#1-pin-assembler-01180-or-newer) |
| `unknown command 'ios'` | [Step 2](#2-ios-add-labelle-ios) |
| `SDL2 not found: set LABELLE_SDL2_LIB …` | [Step 3](#3-sdl2-add-the-sdl2-provider) |
| `backend '…' cannot build target '…'` | Pick a backend that supports the target, or add the provider that owns it |
