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
        \\  generate [dir] [--scene=<name>] [--platform=<p>] [--optimize=<mode>]  Generate .labelle/ assembler files
        \\  build [dir] [--scene=<name>] [--platform=<p>] [--optimize=<mode>] [--docker] [--target=<t>]  Generate + build the project
        \\  run [dir] [--timeout=<dur>] [--scene=<name>] [--platform=<p>] [--optimize=<mode>] [--docker] [--target=<t>] [--screenshot=<path> [--after=<dur>]] [--headless] [--uncapped] [--ticks=<N>] [--profile] [-- <args>...]  Generate + build + run (default; `--screenshot` captures one frame; `--headless` runs windowless, `--uncapped` removes the frame sleep, `--ticks=<N>` exits after N frames — last two imply `--headless`; `--profile` enables the engine frame profiler (per-script/per-plugin ms to the log); `--` forwards trailing args to the game)
        \\  wasm serve [dir] [--port <n>] [--no-build] [--no-open]  Build the WASM target, serve it locally (default port 8080), open the browser
        \\  targets              List available build targets
        \\  install [pkg] [ver]  Fetch packages into cache
        \\  install assembler <ver>  Download and cache an assembler binary
        \\  assembler list       List cached assembler versions
        \\  upgrade [dir] [pkg] [ver]  Bump versions in project.labelle (pkg: core, engine, gfx, cli, assembler, all)
        \\  update [ver] [--no-path]  Update the labelle CLI itself
        \\  clean [--dry-run] [--project=dir]  Remove unused cached package versions
        \\  test [dir] [--verbose] [--no-libs]  Run inline `test` blocks across the project source tree
        \\  audit unification [dir]  Pre-flight check for the unified scene/prefab loader (RFC #560)
        \\  migrate unified [dir] [--dry-run]  Auto-fix legacy unified-format patterns (RFC #594 / engine#592)
        \\  help                 Show this help
        \\  version              Show CLI version
        \\
        \\Examples:
        \\  labelle init my-game
        \\  labelle generate
        \\  labelle run
        \\  labelle run --timeout=30s
        \\  labelle run --scene=settings_menu
        \\  labelle run --screenshot=/tmp/shot.png --after=2s
        \\  labelle run --headless --uncapped --ticks=600
        \\  labelle run --headless --uncapped --profile
        \\  labelle generate --platform=wasm
        \\  labelle build --platform=wasm
        \\  labelle wasm serve
        \\  labelle wasm serve --port 3000
        \\  labelle wasm serve --no-build
        \\  labelle wasm serve --no-open
        \\  labelle build --optimize=ReleaseFast
        \\  labelle build ../my-game
        \\  labelle build --docker
        \\  labelle build --docker --target=x86_64-windows
        \\  labelle run --docker
        \\  labelle run -- --preview-mode 127.0.0.1:54321
        \\  labelle install 0.2.0
        \\  labelle upgrade core 0.2.0
        \\  labelle test
        \\  labelle test ../my-game --verbose
        \\  labelle test --no-libs
        \\  labelle audit unification
        \\  labelle audit unification ../my-game
        \\  labelle migrate unified
        \\  labelle migrate unified --dry-run
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
