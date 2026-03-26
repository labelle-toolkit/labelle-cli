/// main.zig generator — shared sections + backend lifecycle template rendering.
const std = @import("std");
const tpl = @import("template.zig");
const config = @import("config.zig");

const ProjectConfig = config.ProjectConfig;
const PluginDep = config.PluginDep;
const LayerDef = config.LayerDef;
const ResourceDef = config.ResourceDef;

// ── Shared templates (embedded at comptime — backend-independent) ──────────
const shared_header = @embedFile("templates/shared/header.txt");
const shared_ecs_import_mock = @embedFile("templates/shared/ecs_import_mock.txt");
const shared_ecs_import_adapter = @embedFile("templates/shared/ecs_import_adapter.txt");
const shared_gui_stub = @embedFile("templates/shared/gui_stub.txt");
const shared_gui_backend = @embedFile("templates/shared/gui_backend.txt");
const shared_assembled_game = @embedFile("templates/shared/assembled_game.txt");
const shared_render_gizmos = @embedFile("templates/shared/render_gizmos.txt");

pub fn generateMainZig(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    lifecycle_tmpl: []const u8,
    script_names: []const []const u8,
    prefab_names: []const []const u8,
    scene_names: []const []const u8,
    jsonc_scene_names: []const []const u8,
    component_names: []const []const u8,
    hook_names: []const []const u8,
    enum_names: []const []const u8,
    view_names: []const []const u8,
    gizmo_names: []const []const u8,
) ![]const u8 {
    var buf = std.ArrayList(u8){};
    const w = buf.writer(allocator);

    // ── Shared sections (no longer duplicated per backend) ─────────────
    try w.writeAll(shared_header);

    switch (cfg.ecs) {
        .mock => try w.writeAll(shared_ecs_import_mock),
        .zig_ecs, .zflecs, .mr_ecs => try w.writeAll(shared_ecs_import_adapter),
    }

    if (cfg.hasGui()) {
        try w.writeAll(shared_gui_backend);
    } else {
        try w.writeAll(shared_gui_stub);
    }

    var ident_buf: [256]u8 = undefined;

    // Hook imports (hooks/ folder)
    if (hook_names.len > 0) {
        try w.writeAll("\n// --- Hook imports ---\n");
        for (hook_names) |name| {
            const ident = pathToIdent(name, &ident_buf);
            try w.print("const {s} = @import(\"hooks/{s}.zig\");\n", .{ ident, name });
        }
    }

    // Enum imports (enums/ folder)
    if (enum_names.len > 0) {
        try w.writeAll("\n// --- Enum imports ---\n");
        for (enum_names) |name| {
            const ident = pathToIdent(name, &ident_buf);
            try w.print("const {s} = @import(\"enums/{s}.zig\");\n", .{ ident, name });
        }
    }

    // Scene imports (comptime .zon scenes)
    if (scene_names.len > 0) {
        try w.writeAll("\n// --- Scene data (comptime) ---\n");
        for (scene_names) |name| {
            const ident = pathToIdent(name, &ident_buf);
            try w.print("const {s}_scene = @import(\"scenes/{s}.zon\");\n", .{ ident, name });
        }
    }

    // Note: JSONC scenes are loaded at runtime, not imported at comptime.
    // They are registered in the setup/init code via g.registerJsoncScene().

    try w.writeByte('\n');

    // GameLayers enum (generated from project.labelle layers)
    try w.writeAll("const gfx = @import(\"labelle-gfx\");\n\n");
    try generateGameLayers(cfg.layers, w);
    try w.writeByte('\n');

    // ResourceRegistry (atlas resources from project.labelle)
    if (cfg.resources.len > 0) {
        try generateResourceRegistry(cfg.resources, w);
        try w.writeAll("const Resources = ResourceRegistry;\n");
        try w.writeByte('\n');
    }

    // HookPayload — the unified hook event type for the game.
    // MergeHookPayloads is available in engine.core for games that want to
    // manually merge plugin hook payloads. Auto-merging is planned (#64).
    try w.writeAll("const AllHookPayloads = engine.HookPayload(EcsBackend.Entity);\n\n");

    // GameHooks — merge all hook files from hooks/ folder.
    if (hook_names.len == 0) {
        try w.writeAll("const GameHooks = struct {};\n\n");
    } else if (hook_names.len == 1) {
        const ident0 = pathToIdent(hook_names[0], &ident_buf);
        var pascal_buf: [128]u8 = undefined;
        const pascal = snakeToPascal(ident0, &pascal_buf);
        try w.print("const GameHooks = {s}.{s};\n\n", .{ ident0, pascal });
    } else {
        var pascal_buf: [128]u8 = undefined;
        try w.writeAll("const GameHooks = engine.MergeHooks(AllHookPayloads, .{");
        for (hook_names) |name| {
            const ident = pathToIdent(name, &ident_buf);
            const pascal = snakeToPascal(ident, &pascal_buf);
            try w.print(" *{s}.{s},", .{ ident, pascal });
        }
        try w.writeAll(" });\n\n");
    }

    try w.writeAll(shared_assembled_game);

    // PrefabRegistry
    if (prefab_names.len > 0) {
        try w.writeAll("const Prefabs = engine.PrefabRegistry(.{\n");
        for (prefab_names) |name| {
            const ident = pathToIdent(name, &ident_buf);
            try w.print("    .{s} = @import(\"prefabs/{s}.zon\"),\n", .{ ident, name });
        }
        try w.writeAll("});\n\n");
    } else {
        try w.writeAll("const Prefabs = engine.PrefabRegistry(.{});\n\n");
    }

    // ComponentRegistry (game-local components + auto-discovered plugin components)
    {
        const has_plugins = cfg.plugins.len > 0;

        if (has_plugins) {
            try w.writeAll("const Components = engine.ComponentRegistryWithPlugins(.{\n");
        } else {
            try w.writeAll("const Components = engine.ComponentRegistry(.{\n");
        }

        // Game-local components (take precedence over plugin components)
        var pascal_buf: [128]u8 = undefined;
        for (component_names) |name| {
            const ident = pathToIdent(name, &ident_buf);
            const pascal = snakeToPascal(ident, &pascal_buf);
            try w.print("    .{s} = @import(\"components/{s}.zig\").{s},\n", .{ pascal, name, pascal });
        }

        if (has_plugins) {
            // Plugin modules — ComponentRegistryWithPlugins auto-discovers
            // their Components declarations at comptime.
            try w.writeAll("}, .{\n");
            // Gfx is always available as a plugin source
            try w.writeAll("    @import(\"labelle-gfx\"),\n");
            for (cfg.plugins) |plugin| {
                try w.print("    @import(\"{s}\"),\n", .{plugin.name});
            }
            try w.writeAll("});\n\n");
        } else {
            try w.writeAll("});\n\n");
        }
    }

    // SystemRegistry — auto-discovers and dispatches plugin systems.
    // Plugins that export `pub const Systems` get their lifecycle functions
    // called automatically (setup, tick, postTick, drawGui, deinit).
    if (cfg.plugins.len > 0) {
        try w.writeAll("const PluginSystems = engine.SystemRegistry(.{\n");
        try w.writeAll("    @import(\"labelle-gfx\"),\n");
        for (cfg.plugins) |plugin| {
            try w.print("    @import(\"{s}\"),\n", .{plugin.name});
        }
        try w.writeAll("});\n\n");

        // Gizmo categories — auto-discovered from plugins via SystemRegistry
        try w.writeAll("const DiscoveredGizmoCategories = PluginSystems.gizmoCategories();\n\n");
    } else {
        try w.writeAll("const GizmoCatEntry = struct { name: []const u8, id: u8 };\n");
        try w.writeAll("const DiscoveredGizmoCategories: []const GizmoCatEntry = &.{};\n\n");
    }

    // AllScripts struct — shared by both ScriptRunner (comptime dispatch for game scripts)
    // and ScriptRegistry (scene scripts with init/update/deinit). Generated once, reused below.
    try w.writeAll("const AllScripts = struct {\n");
    for (script_names) |name| {
        if (std.mem.eql(u8, name, "context")) continue;
        const ident = pathToIdent(name, &ident_buf);
        try w.print("    pub const {s} = @import(\"scripts/{s}.zig\");\n", .{ ident, name });
    }
    try w.writeAll("};\n\n");

    // ScriptRegistry wraps AllScripts — only looks for init/update/deinit via @hasDecl.
    try w.writeAll("const Scripts = engine.ScriptRegistry(AllScripts);\n\n");

    // GameContext — shared state across scripts (optional context.zig)
    const has_context = hasName(script_names, "context");
    if (has_context) {
        try w.writeAll("const GameContext = @import(\"scripts/context.zig\").GameContext(EcsBackend);\n");
    } else {
        try w.writeAll("const GameContext = struct {};\n");
    }

    // ScriptRunner instantiation
    try w.writeAll("const Runner = engine.ScriptRunner(AllScripts, GameContext, EcsBackend);\n\n");

    // ViewRegistry (from views/ .zon files)
    if (view_names.len > 0) {
        try w.writeAll("const Views = engine.ViewRegistry(.{\n");
        for (view_names) |name| {
            const ident = pathToIdent(name, &ident_buf);
            try w.print("    .{s} = @import(\"views/{s}.zon\"),\n", .{ ident, name });
        }
        try w.writeAll("});\n\n");
    } else {
        try w.writeAll("const Views = engine.EmptyViewRegistry;\n\n");
    }

    // GizmoRegistry (from gizmos/ .zon files)
    if (gizmo_names.len > 0) {
        try w.writeAll("const Gizmos = engine.GizmoRegistry(.{\n");
        for (gizmo_names) |name| {
            const ident = pathToIdent(name, &ident_buf);
            try w.print("    .{s} = @import(\"gizmos/{s}.zon\"),\n", .{ ident, name });
        }
        try w.writeAll("});\n\n");
    }

    try w.writeAll(shared_render_gizmos);

    // ── Lifecycle (backend-specific, uses {{named}} variables) ─────────
    const tick_code = if (cfg.plugins.len > 0)
        "        const scaled_dt = dt * g.time_scale;\n" ++
        "        if (scaled_dt > 0) {\n" ++
        "            runner.tick(&g, scaled_dt);\n" ++
        "            PluginSystems.tick(&g, scaled_dt);\n" ++
        "            PluginSystems.postTick(&g, scaled_dt);\n" ++
        "        }\n" ++
        "        // Update profiling pointers (debug only)\n" ++
        "        if (comptime @TypeOf(runner).profiling_enabled) {\n" ++
        "            g.script_profile_ptr = @ptrCast(&runner.profile);\n" ++
        "            g.script_profile_count = @TypeOf(runner).script_count;\n" ++
        "        }\n" ++
        "        if (comptime PluginSystems.profiling_enabled) {\n" ++
        "            g.plugin_profile_ptr = @ptrCast(&PluginSystems.plugin_profile);\n" ++
        "            g.plugin_profile_count = PluginSystems.plugin_system_count;\n" ++
        "        }\n"
    else
        "        const scaled_dt = dt * g.time_scale;\n" ++
        "        if (scaled_dt > 0) {\n" ++
        "            runner.tick(&g, scaled_dt);\n" ++
        "        }\n" ++
        "        if (comptime @TypeOf(runner).profiling_enabled) {\n" ++
        "            g.script_profile_ptr = @ptrCast(&runner.profile);\n" ++
        "            g.script_profile_count = @TypeOf(runner).script_count;\n" ++
        "        }\n";

    const gui_draw_code = try buildGuiDrawCode(allocator, cfg, view_names);
    defer allocator.free(gui_draw_code);

    // Convert integers to strings using stack buffers
    var w_buf: [16]u8 = undefined;
    var h_buf: [16]u8 = undefined;
    var fps_buf: [16]u8 = undefined;
    const w_str = std.fmt.bufPrint(&w_buf, "{d}", .{cfg.width}) catch unreachable;
    const h_str = std.fmt.bufPrint(&h_buf, "{d}", .{cfg.height}) catch unreachable;
    const fps_str = std.fmt.bufPrint(&fps_buf, "{d}", .{cfg.target_fps}) catch unreachable;

    const hidden_setup: []const u8 = if (cfg.hidden)
        "    window.setConfigFlags(.{ .window_hidden = true });\n"
    else
        "";

    // Callback-based backends (sokol, or WASM): runner lives at module scope
    // so the frame callback can access it after main() returns.
    const use_callback_lifecycle = cfg.backend == .sokol or cfg.platform == .wasm;

    if (use_callback_lifecycle) {
        const module_vars = if (cfg.backend == .sokol) "var runner: Runner = undefined;\n" else "";
        const init_code = try buildCallbackInitCode(allocator, cfg, scene_names, jsonc_scene_names, gizmo_names);
        defer allocator.free(init_code);

        const platform_comment: []const u8 = switch (cfg.platform) {
            .ios => "iOS: sokol bindings accessed through engine.sokol (no direct sokol import)",
            .android => "Android: sokol handles the app lifecycle via NativeActivity",
            .wasm => "WASM: Emscripten drives the main loop via callbacks",
            .desktop => "",
        };
        const entry_comment: []const u8 = switch (cfg.platform) {
            .ios => "iOS entry — no main(), sokol handles the app lifecycle",
            .android => "Android entry — no main(), sokol handles the NativeActivity lifecycle",
            .wasm => "WASM entry — Emscripten drives the main loop via callbacks",
            .desktop => "",
        };

        // Sokol uses module_vars/init_code/cleanup_code; WASM raylib uses setup_code
        if (cfg.backend == .sokol) {
            const cleanup_code = try buildCallbackCleanupCode(allocator, cfg);
            defer allocator.free(cleanup_code);

            // Desktop: GPA with deinit; WASM: c_allocator (uses emscripten's malloc/free,
            // which respects ALLOW_MEMORY_GROWTH — page_allocator conflicts with emscripten)
            const is_wasm = cfg.platform == .wasm;
            const allocator_decl: []const u8 = if (is_wasm)
                "// Use c_allocator for Emscripten — delegates to emscripten's malloc/free\n// which respects ALLOW_MEMORY_GROWTH. GPA is incompatible with wasm32-emscripten.\nconst allocator = std.heap.c_allocator;"
            else
                "var gpa = std.heap.GeneralPurposeAllocator(.{}){};";
            const allocator_expr: []const u8 = if (is_wasm) "std.heap.c_allocator" else "gpa.allocator()";
            const allocator_cleanup: []const u8 = if (is_wasm) "" else "    _ = gpa.deinit();\n";

            try tpl.render(lifecycle_tmpl, .{
                .module_vars = module_vars,
                .width = w_str,
                .height = h_str,
                .title = cfg.title,
                .fps = fps_str,
                .init_code = init_code,
                .tick_code = tick_code,
                .gui_draw_code = gui_draw_code,
                .cleanup_code = cleanup_code,
                .platform_comment = platform_comment,
                .entry_comment = entry_comment,
                .hidden_setup = hidden_setup,
                .allocator_decl = allocator_decl,
                .allocator_expr = allocator_expr,
                .allocator_cleanup = allocator_cleanup,
            }, w);
        } else {
            // WASM raylib: template has module-level runner; use init_code (assignment, not declaration)
            try tpl.render(lifecycle_tmpl, .{
                .width = w_str,
                .height = h_str,
                .title = cfg.title,
                .fps = fps_str,
                .setup_code = init_code,
                .tick_code = tick_code,
                .gui_draw_code = gui_draw_code,
                .hidden_setup = hidden_setup,
            }, w);
        }
    } else {
        const setup_code = try buildSetupCode(allocator, cfg, scene_names, jsonc_scene_names, gizmo_names);
        defer allocator.free(setup_code);

        try tpl.render(lifecycle_tmpl, .{
            .width = w_str,
            .height = h_str,
            .title = cfg.title,
            .fps = fps_str,
            .setup_code = setup_code,
            .tick_code = tick_code,
            .gui_draw_code = gui_draw_code,
            .hidden_setup = hidden_setup,
        }, w);
    }

    return buf.toOwnedSlice(allocator);
}

/// Check if a name exists in a name list.
fn hasName(names: []const []const u8, target: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, target)) return true;
    }
    return false;
}

/// Build the setup code block for {{setup_code}} (loop-based backends).
fn buildSetupCode(allocator: std.mem.Allocator, cfg: ProjectConfig, scene_names: []const []const u8, jsonc_scene_names: []const []const u8, gizmo_names: []const []const u8) ![]const u8 {
    var buf = std.ArrayList(u8){};
    const w = buf.writer(allocator);

    if (cfg.resolved_gui) |gui| {
        if (gui.lifecycle.init) {
            try w.writeAll("    GuiBackend.init();\n");
        }
        if (gui.lifecycle.shutdown) {
            try w.writeAll("    defer GuiBackend.shutdown();\n\n");
        }
    }

    // ScriptRunner owns all per-script state + shared context
    try w.writeAll("    var runner = Runner.init(allocator, &g.active_world.ecs_backend);\n");
    try w.writeAll("    defer runner.deinit();\n\n");

    const has_any_scenes = scene_names.len > 0 or jsonc_scene_names.len > 0;

    if (scene_names.len > 0) {
        if (gizmo_names.len > 0) {
            try w.writeAll("    const Loader = engine.SceneLoaderWithGizmos(AssembledGame, Prefabs, Components, Scripts, Gizmos);\n");
        } else {
            try w.writeAll("    const Loader = engine.SceneLoader(AssembledGame, Prefabs, Components, Scripts);\n");
        }
        var ident_buf: [256]u8 = undefined;
        for (scene_names) |name| {
            const ident = pathToIdent(name, &ident_buf);
            try w.print("    g.registerSceneSimple(\"{s}\", Loader.sceneLoaderFn({s}_scene));\n", .{ name, ident });
        }
    }

    // Register runtime JSONC scenes (loaded from disk at runtime)
    if (jsonc_scene_names.len > 0) {
        try w.writeAll("\n    // Runtime JSONC scenes\n");
        for (jsonc_scene_names) |name| {
            try w.print("    g.registerJsoncScene(\"{s}\", \"scenes/{s}.jsonc\", \"prefabs\");\n", .{ name, name });
        }
    }

    if (has_any_scenes) {
        // Determine initial scene: config override > first comptime > first jsonc
        const initial = cfg.initial_scene orelse (if (scene_names.len > 0) scene_names[0] else jsonc_scene_names[0]);
        try w.print("    try g.setScene(\"{s}\");\n", .{initial});
        try w.writeByte('\n');
    }

    try w.writeAll("    runner.setup(&g);\n");

    if (cfg.plugins.len > 0) {
        try w.writeAll("    PluginSystems.setup(&g);\n");
        try w.writeAll("    defer PluginSystems.deinit();\n");
    }

    return buf.toOwnedSlice(allocator);
}

/// Build the GUI draw code for {{gui_draw_code}}.
fn buildGuiDrawCode(allocator: std.mem.Allocator, cfg: ProjectConfig, view_names: []const []const u8) ![]const u8 {
    var buf = std.ArrayList(u8){};
    const w = buf.writer(allocator);

    if (cfg.hasGui()) {
        try w.writeAll("        g.guiBegin();\n");
        if (view_names.len > 0) {
            try w.writeAll("        g.renderAllViews(Views);\n");
        }
        try w.writeAll("        runner.drawGui(&g);\n");
        if (cfg.plugins.len > 0) {
            try w.writeAll("        PluginSystems.drawGui(&g);\n");
        }
        try w.writeAll("        g.guiEnd();\n");
    }

    return buf.toOwnedSlice(allocator);
}

// ============================================================
// Callback-lifecycle code builders (sokol — init/frame/cleanup callbacks)
// ============================================================

/// Init code for callback-based backends (inside a `!void` helper, can use try).
fn buildCallbackInitCode(allocator: std.mem.Allocator, cfg: ProjectConfig, scene_names: []const []const u8, jsonc_scene_names: []const []const u8, gizmo_names: []const []const u8) ![]const u8 {
    var buf = std.ArrayList(u8){};
    const w = buf.writer(allocator);

    if (cfg.resolved_gui) |gui| {
        if (gui.lifecycle.init) {
            try w.writeAll("    GuiBackend.init();\n");
        }
    }

    try w.writeAll("    runner = Runner.init(allocator, &g.active_world.ecs_backend);\n");

    const has_any_scenes = scene_names.len > 0 or jsonc_scene_names.len > 0;

    if (scene_names.len > 0) {
        if (gizmo_names.len > 0) {
            try w.writeAll("    const Loader = engine.SceneLoaderWithGizmos(AssembledGame, Prefabs, Components, Scripts, Gizmos);\n");
        } else {
            try w.writeAll("    const Loader = engine.SceneLoader(AssembledGame, Prefabs, Components, Scripts);\n");
        }
        var ident_buf: [256]u8 = undefined;
        for (scene_names) |name| {
            const ident = pathToIdent(name, &ident_buf);
            try w.print("    g.registerSceneSimple(\"{s}\", Loader.sceneLoaderFn({s}_scene));\n", .{ name, ident });
        }
    }

    // Register runtime JSONC scenes (loaded from disk at runtime)
    if (jsonc_scene_names.len > 0) {
        try w.writeAll("\n    // Runtime JSONC scenes\n");
        for (jsonc_scene_names) |name| {
            try w.print("    g.registerJsoncScene(\"{s}\", \"scenes/{s}.jsonc\", \"prefabs\");\n", .{ name, name });
        }
    }

    if (has_any_scenes) {
        const initial = cfg.initial_scene orelse (if (scene_names.len > 0) scene_names[0] else jsonc_scene_names[0]);
        try w.print("    g.setScene(\"{s}\") catch @panic(\"failed to set initial scene\");\n", .{initial});
    }

    try w.writeAll("    runner.setup(&g);\n");

    if (cfg.plugins.len > 0) {
        try w.writeAll("    PluginSystems.setup(&g);\n");
    }

    return buf.toOwnedSlice(allocator);
}

/// Cleanup code for callback-based backends (in cleanup() C callback).
fn buildCallbackCleanupCode(allocator: std.mem.Allocator, cfg: ProjectConfig) ![]const u8 {
    var buf = std.ArrayList(u8){};
    const w = buf.writer(allocator);

    if (cfg.resolved_gui) |gui| {
        if (gui.lifecycle.shutdown) {
            try w.writeAll("    GuiBackend.shutdown();\n");
        }
    }

    if (cfg.plugins.len > 0) {
        try w.writeAll("    PluginSystems.deinit();\n");
    }

    try w.writeAll("    runner.deinit();\n");

    return buf.toOwnedSlice(allocator);
}

/// Convert a path-style name to a valid Zig identifier: "enemies/goblin" -> "enemies_goblin".
/// Top-level names (no slashes) pass through unchanged.
fn pathToIdent(name: []const u8, buf: *[256]u8) []const u8 {
    if (name.len > buf.len) {
        std.debug.print("labelle: path too long for identifier (max {d} chars): '{s}'\n", .{ buf.len, name });
        @panic("path exceeds identifier buffer size");
    }
    var i: usize = 0;
    for (name) |c| {
        buf[i] = if (c == '/') '_' else c;
        i += 1;
    }
    return buf[0..i];
}

/// Convert snake_case to PascalCase: "rigid_body" -> "RigidBody", "health" -> "Health".
fn snakeToPascal(name: []const u8, pascal_buf: *[128]u8) []const u8 {
    var i: usize = 0;
    var capitalize_next = true;
    for (name) |c| {
        if (c == '_') {
            capitalize_next = true;
        } else {
            if (i >= pascal_buf.len) break;
            pascal_buf[i] = if (capitalize_next) std.ascii.toUpper(c) else c;
            i += 1;
            capitalize_next = false;
        }
    }
    return pascal_buf[0..i];
}

/// Generate the GameLayers enum from project.labelle layer definitions.
fn generateGameLayers(layers: []const LayerDef, w: anytype) !void {
    try w.writeAll("const GameLayers = enum(u8) {\n");
    for (layers) |layer| {
        try w.print("    {s},\n", .{layer.name});
    }
    try w.writeAll("\n    pub fn config(self: GameLayers) gfx.LayerConfig {\n");
    try w.writeAll("        return switch (self) {\n");
    for (layers) |layer| {
        try w.print("            .{s} => .{{ .order = {d}, .space = .{s} }},\n", .{
            layer.name,
            layer.order,
            @tagName(layer.space),
        });
    }
    try w.writeAll("        };\n");
    try w.writeAll("    }\n");
    try w.writeAll("};\n");
}

/// Generate the ResourceRegistry from project.labelle resource definitions.
/// Each resource maps a name to a ComptimeAtlas loaded from a .zon frame file,
/// plus the texture path for the backend to load at runtime.
fn generateResourceRegistry(resources: []const ResourceDef, w: anytype) !void {
    try w.writeAll("const ResourceRegistry = struct {\n");
    for (resources) |res| {
        try w.print("    pub const {s} = engine.ComptimeAtlas(@import(\"{s}\"));\n", .{ res.name, res.json });
    }
    try w.writeAll("\n    pub const textures = .{\n");
    for (resources) |res| {
        try w.print("        .{s} = \"{s}\",\n", .{ res.name, res.texture });
    }
    try w.writeAll("    };\n");
    try w.print("\n    pub const names: [{d}][]const u8 = .{{\n", .{resources.len});
    for (resources) |res| {
        try w.print("        \"{s}\",\n", .{res.name});
    }
    try w.writeAll("    };\n");
    try w.writeAll("};\n");
}
