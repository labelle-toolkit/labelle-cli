const std = @import("std");
const zspec = @import("zspec");
const generate = @import("generator");

test {
    zspec.runAll(@This());
}

// Minimal lifecycle templates for testing (mustache format — no shared sections)
const raylib_lifecycle =
    \\const screen_w: u32 = {{width}};
    \\const screen_h: u32 = {{height}};
    \\const screen_title = "{{title}}";
    \\const target_fps: u32 = {{fps}};
    \\pub fn main() !void {
    \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    \\    const allocator = gpa.allocator();
    \\{{hidden_setup}}    var hooks = GameHooks{};
    \\    var g = AssembledGame.init(allocator);
    \\    g.setHooks(&hooks);
    \\    g.renderer.setScreenHeight(@as(f32, @floatFromInt(screen_h)));
    \\{{setup_code}}
    \\    while (!window.windowShouldClose()) {
    \\        const dt: f32 = 0.016;
    \\{{tick_code}}        g.tick(dt);
    \\        g.render();
    \\{{gui_draw_code}}    }
    \\}
    \\
;

const sokol_lifecycle =
    \\var g: AssembledGame = undefined;
    \\var hooks: GameHooks = .{};
    \\var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    \\{{module_vars}}const screen_w: u32 = {{width}};
    \\const screen_h: u32 = {{height}};
    \\const screen_title = "{{title}}";
    \\const target_fps: u32 = {{fps}};
    \\export fn init() callconv(.c) void {
    \\{{hidden_setup}}    const allocator = gpa.allocator();
    \\    g = AssembledGame.init(allocator);
    \\    g.setHooks(&hooks);
    \\    g.renderer.setScreenHeight(@as(f32, @floatFromInt(screen_h)));
    \\{{init_code}}}
    \\export fn frame() callconv(.c) void {
    \\    const dt: f32 = 0.016;
    \\{{tick_code}}    g.tick(dt);
    \\    g.render();
    \\{{gui_draw_code}}}
    \\export fn cleanup() callconv(.c) void {
    \\{{cleanup_code}}    g.deinit();
    \\    _ = gpa.deinit();
    \\}
    \\
;

const empty_names: []const []const u8 = &.{};

// ── build.zig.zon generation ─────────────────────────────────────────

pub const BUILD_ZIG_ZON = struct {
    test "contains raylib dep for raylib backend" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, null, null);
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_raylib") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_sokol") == null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_zig_ecs") == null);
    }

    test "contains zig_ecs dep when selected" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .zig_ecs,
        }, null, null);
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_raylib") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_zig_ecs") != null);
    }

    test "contains sdl dep for sdl backend" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sdl,
            .ecs = .mock,
        }, null, null);
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_sdl") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_raylib") == null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_sokol") == null);
    }

    test "contains bgfx dep for bgfx backend" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .bgfx,
            .ecs = .mock,
        }, null, null);
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_bgfx") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_raylib") == null);
    }

    test "contains wgpu dep for wgpu backend" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .wgpu,
            .ecs = .mock,
        }, null, null);
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_wgpu") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_raylib") == null);
    }

    test "uses config.version instead of hardcoded version" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .version = "1.2.3",
        }, null, null);
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, ".version = \"1.2.3\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, ".version = \"0.1.0\"") == null);
    }

    test "defaults to version 0.1.0" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, null, null);
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, ".version = \"0.1.0\"") != null);
    }

    test "uses path deps by default" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, null, null);
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, ".path =") != null);
    }
};

// ── build.zig generation ─────────────────────────────────────────────

pub const BUILD_ZIG = struct {
    test "links raylib artifact" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        });
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "linkLibrary") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "raylib") != null);
    }

    test "links sokol_clib artifact" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        });
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "linkLibrary") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "sokol_clib") != null);
    }

    test "wires sdl backend modules" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sdl,
            .ecs = .mock,
        });
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_sdl") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "backend_gfx") != null);
    }

    test "links bgfx and glfw artifacts" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .bgfx,
            .ecs = .mock,
        });
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_bgfx") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "bgfx_artifact") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "glfw_artifact") != null);
    }

    test "links wgpu glfw artifact" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .wgpu,
            .ecs = .mock,
        });
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_wgpu") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "glfw_artifact") != null);
    }

    test "gui=clay wires gui_backend" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .gui = .clay,
        });
        defer std.testing.allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "gui_mod") != null);
    }
};

// ── Plugin wiring ────────────────────────────────────────────────────

pub const PLUGINS = struct {
    test "no plugins excludes pathfinding/physics from build.zig.zon" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{},
        }, null, null);
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_pathfinding") == null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_physics") == null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_tasks") == null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_core") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_gfx") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "engine") != null);
    }

    test "no plugins excludes pathfinding/physics from build.zig" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{},
        });
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_pathfinding") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_physics") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_tasks") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "pf_mod") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "physics_mod") == null);
    }

    test "plugins enabled includes pathfinding/physics in build.zig.zon" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "pathfinding", .repo = "github.com/labelle-toolkit/labelle-pathfinding", .version = "0.1.0" },
                .{ .name = "physics", .repo = "github.com/labelle-toolkit/labelle-physics", .version = "0.1.0" },
            },
        }, null, null);
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_pathfinding") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_physics") != null);
    }

    test "plugins enabled includes pathfinding/physics in build.zig" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "pathfinding", .repo = "github.com/labelle-toolkit/labelle-pathfinding", .version = "0.1.0" },
                .{ .name = "physics", .repo = "github.com/labelle-toolkit/labelle-physics", .version = "0.1.0" },
            },
        });
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_pathfinding") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_physics") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "plugin_pathfinding_mod") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "plugin_physics_mod") != null);
    }

    test "single plugin only includes that plugin" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "pathfinding", .repo = "github.com/labelle-toolkit/labelle-pathfinding", .version = "0.1.0" },
            },
        }, null, null);
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_pathfinding") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_physics") == null);
    }
};

// ── main.zig generation ──────────────────────────────────────────────

pub const MAIN_ZIG = struct {
    test "uses MockEcsBackend for mock ecs" {
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "MockEcsBackend") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@import(\"ecs_backend\")") == null);
    }

    test "uses EcsAdapter for real ecs" {
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .zflecs,
        }, raylib_lifecycle, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "EcsAdapter") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "ecs_backend") != null);
    }

    test "contains window dimensions" {
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .title = "My Game",
            .width = 1024,
            .height = 768,
            .target_fps = 120,
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "1024") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "768") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "120") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "My Game") != null);
    }

    test "gui=none uses StubGui" {
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .gui = .none,
        }, raylib_lifecycle, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "StubGui") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "gui_backend") == null);
    }

    test "gui=clay wires gui_backend in zon and main.zig" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .gui = .clay,
        }, null, null);
        defer std.testing.allocator.free(zon);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_clay") != null);

        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .gui = .clay,
        }, raylib_lifecycle, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "gui_backend") != null);
    }

    test "sets renderer screen height" {
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .height = 768,
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "setScreenHeight") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "768") != null);
    }

    test "sdl generates loop-based main" {
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sdl,
            .ecs = .mock,
        }, raylib_lifecycle, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub fn main()") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "MockEcsBackend") != null);
    }
};

// ── Sokol backend ────────────────────────────────────────────────────

pub const SOKOL = struct {
    test "sets renderer screen height" {
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .height = 600,
            .backend = .sokol,
            .ecs = .mock,
        }, sokol_lifecycle, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "setScreenHeight") != null);
    }

    test "generates callback-style main" {
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, sokol_lifecycle, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "export fn init() callconv(.c)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "export fn frame() callconv(.c)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "export fn cleanup() callconv(.c)") != null);
    }

    test "uses module-level runner var" {
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, sokol_lifecycle, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var runner: Runner = undefined;") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "runner = Runner.init(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "runner.deinit()") != null);
    }

    test "initial_scene overrides default scene_names[0]" {
        const scenes = &[_][]const u8{ "intro", "main_menu", "gameplay" };
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .initial_scene = "main_menu",
        }, sokol_lifecycle, empty_names, empty_names, scenes, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.setScene(\"main_menu\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.setScene(\"intro\")") == null);
    }
};

// ── Scripts ──────────────────────────────────────────────────────────

pub const SCRIPTS = struct {
    test "generates AllScripts struct" {
        const scripts = &[_][]const u8{ "movement", "spawn", "gui" };
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, scripts, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const AllScripts = struct {") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const movement = @import(\"scripts/movement.zig\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const spawn = @import(\"scripts/spawn.zig\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const gui = @import(\"scripts/gui.zig\")") != null);
    }

    test "uses ScriptRunner for dispatch" {
        const scripts = &[_][]const u8{ "movement", "spawn" };
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, scripts, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const Runner = engine.ScriptRunner(AllScripts, GameContext, EcsBackend)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "Runner.init(allocator, &g.ecs_backend)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "runner.setup(&g)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "runner.tick(&g, dt)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "runner.deinit()") != null);
    }

    test "detects context.zig for GameContext" {
        const scripts = &[_][]const u8{ "context", "movement" };
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, scripts, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const GameContext = @import(\"scripts/context.zig\").GameContext(EcsBackend)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const context =") == null);
    }

    test "uses empty struct when no context.zig" {
        const scripts = &[_][]const u8{"movement"};
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, scripts, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const GameContext = struct {}") != null);
    }
};

// ── Prefabs & Scenes ─────────────────────────────────────────────────

pub const PREFABS_AND_SCENES = struct {
    test "builds PrefabRegistry from scanned prefabs" {
        const prefabs = &[_][]const u8{ "enemy", "player" };
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_names, prefabs, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "PrefabRegistry") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".player = @import(\"prefabs/player.zon\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".enemy = @import(\"prefabs/enemy.zon\")") != null);
    }

    test "loads scenes" {
        const scenes = &[_][]const u8{"game_scene"};
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_names, empty_names, scenes, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "game_scene_scene = @import(\"scenes/game_scene.zon\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "SceneLoader(AssembledGame, Prefabs, Components, Scripts)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerSceneSimple(\"game_scene\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.setScene(\"game_scene\")") != null);
    }

    test "initial_scene overrides default scene_names[0]" {
        const scenes = &[_][]const u8{ "alpha", "beta", "gamma" };
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .initial_scene = "beta",
        }, raylib_lifecycle, empty_names, empty_names, scenes, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerSceneSimple(\"alpha\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerSceneSimple(\"beta\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerSceneSimple(\"gamma\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.setScene(\"beta\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.setScene(\"alpha\")") == null);
    }

    test "initial_scene=null falls back to scene_names[0]" {
        const scenes = &[_][]const u8{ "alpha", "beta" };
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_names, empty_names, scenes, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.setScene(\"alpha\")") != null);
    }
};

// ── Views ────────────────────────────────────────────────────────────

pub const VIEWS = struct {
    test "generates ViewRegistry from scanned views" {
        const views = &[_][]const u8{ "hud", "inventory" };
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, views, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const Views = engine.ViewRegistry(.{") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".hud = @import(\"views/hud.zon\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".inventory = @import(\"views/inventory.zon\")") != null);
    }

    test "auto-renders views in GUI section" {
        const views = &[_][]const u8{"hud"};
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .gui = .simple,
        }, raylib_lifecycle, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, views, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.guiBegin()") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.renderAllViews(Views)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.guiEnd()") != null);
    }

    test "uses EmptyViewRegistry when no views" {
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const Views = engine.EmptyViewRegistry") != null);
    }
};

// ── Layers & Resources ───────────────────────────────────────────────

pub const LAYERS = struct {
    test "generates GameLayers from project config" {
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .layers = &.{
                .{ .name = "bg", .order = 0, .space = .screen },
                .{ .name = "world", .order = 1, .space = .world },
                .{ .name = "hud", .order = 2, .space = .screen },
            },
        }, raylib_lifecycle, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const GameLayers = enum(u8)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "bg,") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "world,") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "hud,") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".bg => .{ .order = 0, .space = .screen }") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".world => .{ .order = 1, .space = .world }") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "GfxRenderer(BackendGfx, GameLayers,") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "config.GameLayers") == null);
    }
};

pub const RESOURCES = struct {
    test "generates ResourceRegistry from resource config" {
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "characters", .json = "assets/characters_frames.zon", .texture = "assets/characters.png" },
                .{ .name = "tiles", .json = "assets/tiles_frames.zon", .texture = "assets/tiles.png" },
            },
        }, raylib_lifecycle, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const ResourceRegistry = struct {") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const characters = engine.ComptimeAtlas(@import(\"assets/characters_frames.zon\"))") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const tiles = engine.ComptimeAtlas(@import(\"assets/tiles_frames.zon\"))") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".characters = \"assets/characters.png\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".tiles = \"assets/tiles.png\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const names: [2][]const u8") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const Resources = ResourceRegistry;") != null);
    }

    test "omits ResourceRegistry when no resources" {
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "ResourceRegistry") == null);
    }
};

// ── Hidden window flag ───────────────────────────────────────────────

pub const HIDDEN_WINDOW = struct {
    test "hidden=true generates window hidden flag in raylib" {
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .hidden = true,
        }, raylib_lifecycle, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "window.setConfigFlags(.{ .window_hidden = true })") != null);
    }

    test "hidden=false does not generate window hidden flag" {
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .hidden = false,
        }, raylib_lifecycle, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "window_hidden") == null);
    }

    test "hidden=true generates window hidden flag in sokol" {
        const main_zig = try generate.generateMainZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .hidden = true,
        }, sokol_lifecycle, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "window.setConfigFlags(.{ .window_hidden = true })") != null);
    }
};
