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
        \\  build [dir] [--scene=<name>] [--platform=<p>] [--optimize=<mode>] [--progress=<m>] [--docker] [--target=<t>]  Generate + build the project (`--progress=json` streams NDJSON progress records on stdout; modes: human, json, off)
        \\  run [dir] [--timeout=<dur>] [--scene=<name>] [--platform=<p>] [--optimize=<mode>] [--progress=<m>] [--docker] [--target=<t>] [--screenshot=<path> [--after=<dur>]] [--headless] [--uncapped] [--ticks=<N>] [--profile] [-- <args>...]  Generate + build + run (default; `--screenshot` captures one frame to <path> and honors the extension you asked for (.png/.bmp/.tga/.jpg): a backend that writes another format (bgfx writes TGA) is re-encoded by the CLI after the run, and the `screenshot written to` line it prints is authoritative; a RELATIVE path resolves against the game's cwd — `.labelle/<target>/`, or the project dir under `--docker` — not your shell's; `--headless` runs windowless, `--uncapped` removes the frame sleep, `--ticks=<N>` exits after N frames — last two imply `--headless`; `--profile` enables the engine frame profiler (per-script/per-plugin ms to the log); `--` forwards trailing args to the game; `--progress=json` streams NDJSON progress records on stdout, but pure NDJSON is guaranteed for `build` ONLY — during `run` the game's own stdout shares the stream, so consumers must skip non-JSON lines or read .labelle/<target>/.build-progress.json instead)
        \\  bundle [dir] [--optimize=<mode>] [--output <dir>] [--progress=<m>]  Generate + build the desktop target, then wrap the exe in a macOS `<Title>.app` (Info.plist + AppIcon.icns from `.app_icon`, so the Dock/Finder show the project icon; default output `.labelle/<backend>_desktop/zig-out/`; macOS only — see cli#359)
        \\  status [dir] [--json]  Print the current/last build progress from .labelle/<target>/.build-progress.json (works from a second shell while a build runs)
        \\  wasm serve [dir] [--port <n>] [--no-build] [--no-open] [--watch] [--progress=<m>]  Build the WASM target, serve it locally (default port 8080), open the browser (`--watch` rebuilds + live-reloads on source changes)
        \\  wasm export [dir] [--output <dir>] [--zip] [--platform <itch|github-pages>] [--no-build] [--progress=<m>]  Build the WASM target and package a deployment-ready dir (default ./release; `--zip` archives it; `--platform` adds host-specific touches; best-effort `wasm-opt -O3`)
        \\  targets              List available build targets
        \\  install [pkg] [ver]  Fetch packages into cache
        \\  install assembler <ver>  Download and cache an assembler binary
        \\  install <zig|emsdk> <ver>  Provision a managed build toolchain into ~/.labelle
        \\  install python       Provision managed Python for wasm builds (pinned version, ~25 MB)
        \\  assembler list       List cached assembler versions
        \\  upgrade [dir] [pkg] [ver] [--check] [--json]  Bump versions in project.labelle (pkg: core, engine, gfx, cli, assembler, all); `--check` reports pins vs latest WITHOUT writing (exit 2 = updates available), `--json` emits a machine-readable report (implies --check)
        \\  update [ver] [--no-path] [--check] [--json]  Update the labelle CLI itself; `--check` reports installed vs latest WITHOUT installing (exit 2 = update available), `--json` emits a machine-readable report (implies --check)
        \\  clean [--dry-run] [--project=dir]  Remove unused cached package versions
        \\  test [dir] [--verbose] [--no-libs]  Run inline `test` blocks across the project source tree
        \\  audit unification [dir]  Pre-flight check for the unified scene/prefab loader (RFC #560)
        \\  migrate unified [dir] [--dry-run]  Auto-fix legacy unified-format patterns (RFC #594 / engine#592)
        \\  check [dir]          Lint packs for §6 convention violations (Packs RFC)
        \\  plugins [dir]        List attached plugins with version, license, and author
        \\  doctor [dir] [--fix] [--json]  Check build requirements (SDL2, Zig, emsdk); `--fix` provisions, `--json` emits a capability report
        \\  help                 Show this help
        \\  version              Show CLI version
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
        \\  labelle generate --platform=wasm
        \\  labelle build --platform=wasm
        \\  labelle wasm serve
        \\  labelle wasm serve --port 3000
        \\  labelle wasm serve --no-build
        \\  labelle wasm serve --no-open
        \\  labelle wasm serve --watch
        \\  labelle wasm export
        \\  labelle wasm export --output ./release --zip
        \\  labelle wasm export --platform github-pages
        \\  labelle build --optimize=ReleaseFast
        \\  labelle bundle
        \\  labelle bundle --optimize=ReleaseFast --output ./dist
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
        \\
    , .{project_config.CLI_VERSION});
}

pub fn printVersion() void {
    std.debug.print("labelle v{s}\n", .{project_config.CLI_VERSION});
}

pub fn printTargets() void {
    std.debug.print(
        \\Available backends:
        \\  raylib     Raylib (desktop, web)
        \\  sokol      Sokol (desktop, web)
        \\  sdl        SDL2 (desktop)
        \\  bgfx       BGFX (desktop)
        \\  wgpu       WebGPU (desktop, web)
        \\
        \\Available ECS adapters:
        \\  zig_ecs    zig-ecs
        \\  zflecs     zflecs (Flecs)
        \\  mr_ecs     mr-ecs
        \\
        \\Set backend/ecs in your project.labelle file.
        \\
    , .{});
}
