const std = @import("std");
const gen = @import("generator");

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
        \\  run [dir] [--timeout=<dur>] [--scene=<name>] [--platform=<p>] [--optimize=<mode>] [--docker] [--target=<t>]  Generate + build + run (default)
        \\  targets              List available build targets
        \\  install [pkg] [ver]  Fetch packages into cache
        \\  upgrade [dir] [pkg] [ver]  Bump versions in project.labelle
        \\  update [ver] [--no-path]  Update the labelle CLI itself
        \\  clean [--dry-run] [--project=dir]  Remove unused cached package versions
        \\  help                 Show this help
        \\  version              Show CLI version
        \\
        \\Examples:
        \\  labelle init my-game
        \\  labelle generate
        \\  labelle run
        \\  labelle run --timeout=30s
        \\  labelle run --scene=settings_menu
        \\  labelle generate --platform=wasm
        \\  labelle build --platform=wasm
        \\  labelle build --optimize=ReleaseFast
        \\  labelle build ../my-game
        \\  labelle build --docker
        \\  labelle build --docker --target=x86_64-windows
        \\  labelle run --docker
        \\  labelle install 0.2.0
        \\  labelle upgrade core 0.2.0
        \\
    , .{gen.CLI_VERSION});
}

pub fn printVersion() void {
    std.debug.print("labelle v{s}\n", .{gen.CLI_VERSION});
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
