const std = @import("std");
const project_config = @import("project_config.zig");

pub fn printHelp() void {
    std.debug.print(
        \\Labelle CLI v{s}
        \\
        \\Usage: labelle <command> [options]
        \\
        \\Commands:
        \\  init <name> [dir]    Create a new labelle project
        \\  add pack <name>      Scaffold a pack (packs/<name>/ + pack.labelle)
        \\  add feature <kind> <name>  Scaffold a feature-unit (kind: need, role, status)
        \\  generate [dir] [--scene=<name>] [--platform=<p>] [--optimize=<mode>]  Generate .labelle/ assembler files
        \\  build [dir] [--scene=<name>] [--platform=<p>] [--optimize=<mode>] [--progress=<m>] [--docker] [--target=<t>] [--linux-desktop]  Generate + build the project (`--progress=json` streams NDJSON progress records on stdout; modes: human, json, off; a desktop build on Linux — or anywhere with `--linux-desktop` — also writes `zig-out/<exe>.desktop` + `zig-out/<exe>.png`, ready for `desktop-file-install`)
        \\  run [dir] [--timeout=<dur>] [--scene=<name>] [--platform=<p>] [--optimize=<mode>] [--progress=<m>] [--docker] [--target=<t>] [--screenshot=<path> [--after=<dur>]] [--headless] [--uncapped] [--ticks=<N>] [--profile] [-- <args>...]  Generate + build + run (default; `--screenshot` captures one frame to <path> and honors the extension you asked for (.png/.bmp/.tga/.jpg): a backend that writes another format (bgfx writes TGA) is re-encoded by the CLI after the run, and the `screenshot written to` line it prints is authoritative; a RELATIVE path resolves against the game's cwd — `.labelle/<target>/`, or the project dir under `--docker` — not your shell's; `--headless` runs windowless, `--uncapped` removes the frame sleep, `--ticks=<N>` exits after N frames — last two imply `--headless`; `--profile` enables the engine frame profiler (per-script/per-plugin ms to the log); on a provider target the package's `run` replacement launches the game and receives the env-based options (`--scene`, `--profile`, `--screenshot`/`--after`) as `run.env` — it decides how they reach the game, so a `--screenshot` path may be a path on a device; `--` forwards trailing args to the game; the CLI exits with the game's own status — 128+signal for a crash, and 0 when `--timeout` itself ends the run — so a crash never reads as success; `--progress=json` streams NDJSON progress records on stdout, but pure NDJSON is guaranteed for `build` ONLY — during `run` the game's own stdout shares the stream, so consumers must skip non-JSON lines or read .labelle/<target>/.build-progress.json instead)
        \\  run --watch [dir] [--platform=<t>] [--optimize=<mode>] [-- <args>...]  Build once, then keep the target's watch-capable run replacement (a `replace run` hook declaring `.watch = true`, provider contract >= 1.3.0) running while every source change rebuilds; only a fully successful rebuild is published to the replacement (the last good output stays served otherwise); a change to its provider, backend, target, optimize mode or settings asks you to restart; refused before any build for a target without one (`desktop` included)
        \\  pack <input-dir> [options]  Pack PNGs into a sprite atlas
        \\  bundle [dir] [--optimize=<mode>] [--output <dir>] [--build-number <n>] [--platform=<t>] [--progress=<m>]  Generate + build the resolved target, then package it. For `desktop`: wrap the exe in a self-contained macOS `<Title>.app` (Info.plist + AppIcon.icns from `.app_icon`, the project's `assets/` staged into Contents/Resources and a launcher that runs the game from there — cli#364; default output `.labelle/<backend>_desktop/zig-out/bundle/desktop/`; `CFBundleVersion` is `<major+1>.<minor>.<patch>` of `.version` so it always increases with the release — cli#363 — unless `--build-number <n>` (positive integer or `a.b.c`, at most 4/2/2 digits per component) pins it; macOS only — see cli#359). For a provider target (`--platform=<t>`): the provider's `replace` hook on `bundle` packages it into `zig-out/bundle/<t>/`, on any host (docs/provider-targets.md). Pinned provider packages may attach `before`/`after` hooks to the `generate`/`build`/`bundle`/`run` steps (see docs/provider-hooks.md)
        \\  status [dir] [--json]  Print the current/last build progress from .labelle/<target>/.build-progress.json (works from a second shell while a build runs)
        \\  targets              List the targets `--platform` accepts here: `desktop` (core) plus every target a pinned provider package declares (docs/provider-targets.md)
        \\  install [pkg] [ver]  Fetch packages into cache (a bare `install` in a project with labelle.providers.lock also runs `providers fetch`)
        \\  install assembler <ver>  Download and cache an assembler binary
        \\  install zig <ver>    Provision a managed Zig toolchain into ~/.labelle
        \\  assembler list       List cached assembler versions
        \\  upgrade [dir] [pkg] [ver] [--check] [--json]  Bump versions in project.labelle (pkg: core, engine, gfx, cli, assembler, all); `--check` reports pins vs latest WITHOUT writing (exit 2 = updates available), `--json` emits a machine-readable report (implies --check)
        \\  update [ver] [--no-path] [--check] [--json]  Update the labelle CLI itself; `--check` reports installed vs latest WITHOUT installing (exit 2 = update available), `--json` emits a machine-readable report (implies --check)
        \\  clean [--dry-run] [--project=dir]  Remove unused cached package versions
        \\  test [dir] [--verbose] [--no-libs]  Run inline `test` blocks across the project source tree, then the game-side `tests/` through the generated build — which is REGENERATED first, every time, so an edited, added, deleted or renamed test is what runs (a failed regenerate fails the command; the previously generated tests are never run in its place). `--no-libs` skips only the source-tree walk. The final line counts test TARGETS; the per-test count is Zig's own summary above it
        \\  audit unification [dir]  Pre-flight check for the unified scene/prefab loader (RFC #560)
        \\  migrate unified [dir] [--dry-run]  Auto-fix legacy unified-format patterns (RFC #594 / engine#592)
        \\  check [dir]          Lint packs for §6 convention violations (Packs RFC)
        \\  plugins [dir]        List attached plugins with version, license, and author
        \\  providers resolve [providers.json] [--accept] [--offline]  Preview or pin GitHub providers for this project
        \\  providers fetch [--offline]  Inside a project, download the provider archives its labelle.providers.lock pins (only verified bytes are cached, each archive atomically; no registry, no lock change); `--offline` only verifies the cache
        \\  doctor [dir] [--fix] [--json] [--core-only] [--zig <path>]  Check build requirements (SDL2, Zig, emsdk), then, inside a project, run each pinned provider's `doctor` command (as `labelle <ns> doctor`, by namespace; exit non-zero if any check fails); `--fix` provisions, `--json` emits a capability report (core only), `--core-only` skips the providers, `--zig <path>` (or `--zig=<path>`) checks and builds the provider doctors with that compiler, as `labelle build` takes it (`LABELLE_ZIG` still wins)
        \\  help                 Show this help
        \\  version              Show CLI version
        \\
        \\Targets (`--platform=<t>`):
        \\  `desktop` is the only target the CLI itself owns. Since 2.0 every other target
        \\  (android, wasm, ...) comes from a provider package pinned in the project's
        \\  `.plugins` + labelle.providers.lock: `labelle targets` lists what this project
        \\  has, and a target without its provider fails naming the package to add
        \\  (looked up in the provider registry; `LABELLE_OFFLINE=1` skips the lookup).
        \\  Upgrading a 1.x project: docs/migrating-to-2.0.md
        \\  (https://github.com/labelle-toolkit/labelle-cli/blob/main/docs/migrating-to-2.0.md)
        \\
        \\Legacy `wasm` commands (not built in since 2.0: both need a pinned provider of target `wasm`):
        \\  wasm serve [dir] [--port <n>] [--no-build] [--no-open] [--watch] [--progress=<m>]  Build the `wasm` target, serve it locally (default port 8080), open the browser (`--watch` rebuilds + live-reloads on source changes)
        \\  wasm export [dir] [--output <dir>] [--zip] [--platform <itch|github-pages>] [--no-build] [--progress=<m>]  Build the `wasm` target and package a deployment-ready dir (default ./release; `--zip` archives it; `--platform` adds host-specific touches; best-effort `wasm-opt -O3`)
        \\  A provider that replaces `run` for `wasm` (the registry's `web` package does) refuses
        \\  `wasm serve/export`: use its own commands instead (`labelle web serve`, `labelle web
        \\  export`, listed under "Project package commands" inside the project) or
        \\  `labelle run --platform=wasm` / `labelle bundle --platform=wasm`.
        \\
        \\`wasm` toolchain installers (standalone: they work anywhere, with or without a provider;
        \\a `wasm` build still needs the provider):
        \\  install emsdk <ver>  Provision the emsdk toolchain a `wasm` build compiles with into ~/.labelle
        \\  install python       Provision managed Python for `wasm` builds (pinned version, ~25 MB)
        \\
        \\Build flags (generate / build / run / astc):
        \\  --allow-older-cli    Build anyway when labelle.lock says the project was locked by a
        \\                       NEWER labelle than this binary. Without it that is a hard error
        \\                       (#353): an older CLI skips project.labelle fields it doesn't know
        \\                       — e.g. a per-atlas `.astc_block` — and silently ships wrong art.
        \\                       `LABELLE_ALLOW_OLDER_CLI=1` is the equivalent env form and applies
        \\                       to every command.
        \\
        \\Examples:
        \\  labelle init my-game
        \\  labelle add pack citizens
        \\  labelle add feature need boredom
        \\  labelle generate
        \\  labelle run
        \\  labelle run --timeout=30s
        \\  labelle run --scene=settings_menu
        \\  labelle build --progress=json
        \\  labelle status
        \\  labelle status --json
        \\  labelle run --screenshot=/tmp/shot.png --after=2s
        \\  labelle run --headless --uncapped --ticks=600
        \\  labelle run --headless --uncapped --profile
        \\  labelle build --optimize=ReleaseFast
        \\  labelle build --linux-desktop
        \\  labelle build --allow-older-cli
        \\  labelle bundle
        \\  labelle bundle --optimize=ReleaseFast --output ./dist
        \\  labelle bundle --build-number 42
        \\  labelle build ../my-game
        \\  labelle build --docker
        \\  labelle build --docker --target=x86_64-windows
        \\  labelle run --docker
        \\  labelle run -- --preview-mode 127.0.0.1:54321
        \\  labelle install 0.2.0
        \\  labelle upgrade core 0.2.0
        \\  labelle update --check
        \\  labelle update --check --json
        \\  labelle upgrade --check
        \\  labelle upgrade --check --json
        \\  labelle test
        \\  labelle test ../my-game --verbose
        \\  labelle test --no-libs
        \\  labelle audit unification
        \\  labelle audit unification ../my-game
        \\  labelle migrate unified
        \\  labelle migrate unified --dry-run
        \\  labelle plugins
        \\  labelle targets
        \\  labelle providers resolve
        \\  labelle providers resolve --accept
        \\  labelle providers fetch
        \\
        \\Examples with a provider target (each needs that target's pinned provider):
        \\  labelle build --platform=wasm
        \\  labelle run --platform=wasm
        \\  labelle bundle --platform=wasm
        \\  labelle build --platform=android
        \\  labelle run --platform=android
        \\
    , .{project_config.CLI_VERSION});
}

pub fn printVersion() void {
    std.debug.print("labelle v{s}\n", .{project_config.CLI_VERSION});
}
