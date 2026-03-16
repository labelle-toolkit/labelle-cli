/// build.zig and build.zig.zon generators for the labelle-cli assembler.
const std = @import("std");
const tpl = @import("template.zig");
const config = @import("config.zig");
const cache = @import("cache.zig");

const ProjectConfig = config.ProjectConfig;

// Build file templates
const build_zig_tmpl = @embedFile("templates/build_zig.txt");
const build_zig_zon_tmpl = @embedFile("templates/build_zig_zon.txt");

// ============================================================
// build.zig generator
// ============================================================

pub fn generateBuildZig(allocator: std.mem.Allocator, cfg: ProjectConfig) ![]const u8 {
    var buf = std.ArrayList(u8){};
    const w = buf.writer(allocator);

    if (cfg.platform == .wasm) {
        try tpl.writeSection(build_zig_tmpl, "header_wasm", w);
        try tpl.writeSection(build_zig_tmpl, "wasm_target", w);
    } else {
        try tpl.writeSection(build_zig_tmpl, "header", w);
    }

    try tpl.writeSection(build_zig_tmpl, "deps", w);

    // Plugin dep/module declarations (for all declared plugins)
    for (cfg.plugins) |plugin| {
        try w.print("    const plugin_{s}_dep = b.dependency(\"labelle_{s}\", .{{ .target = target, .optimize = optimize }});\n", .{ plugin.name, plugin.name });
        try w.print("    const plugin_{s}_mod = plugin_{s}_dep.module(\"labelle_{s}\");\n", .{ plugin.name, plugin.name, plugin.name });
    }

    // Shared framework dep overrides — ensures plugins use the same package
    // instances as the game, preventing type mismatches (RFC #42).
    if (cfg.plugins.len > 0) {
        try w.writeByte('\n');
        for (cfg.plugins) |plugin| {
            try w.print("    plugin_{s}_mod.addImport(\"labelle-core\", core_mod);\n", .{plugin.name});
            try w.print("    plugin_{s}_mod.addImport(\"labelle-gfx\", gfx_mod);\n", .{plugin.name});
        }
    }

    // For imgui, the imgui dep provides ALL backend modules + gui — no separate backend dep.
    if (cfg.gui == .imgui) {
        switch (cfg.backend) {
            .raylib => try tpl.writeSection(build_zig_tmpl, "backend_imgui_raylib", w),
            .sokol => try tpl.writeSection(build_zig_tmpl, "backend_imgui_sokol", w),
            .sdl, .bgfx, .wgpu => {}, // TODO: imgui integration for these backends
        }
    } else {
        switch (cfg.backend) {
            .raylib => try tpl.writeSection(build_zig_tmpl, "backend_raylib", w),
            .sokol => try tpl.writeSection(build_zig_tmpl, "backend_sokol", w),
            .sdl => try tpl.writeSection(build_zig_tmpl, "backend_sdl", w),
            .bgfx => try tpl.writeSection(build_zig_tmpl, "backend_bgfx", w),
            .wgpu => try tpl.writeSection(build_zig_tmpl, "backend_wgpu", w),
        }
    }

    switch (cfg.ecs) {
        .mock => {},
        .zig_ecs => try tpl.renderSection(build_zig_tmpl, "ecs_adapter", .{ .ecs_dep_name = "labelle_zig_ecs" }, w),
        .zflecs => try tpl.renderSection(build_zig_tmpl, "ecs_adapter", .{ .ecs_dep_name = "labelle_zflecs" }, w),
        .mr_ecs => try tpl.renderSection(build_zig_tmpl, "ecs_adapter", .{ .ecs_dep_name = "labelle_mr_ecs" }, w),
    }

    switch (cfg.gui) {
        .none, .imgui => {}, // imgui gui comes from the backend dep
        .simple => try tpl.renderSection(build_zig_tmpl, "gui_backend", .{ .gui_dep_name = "labelle_simple_gui" }, w),
        .clay => try tpl.renderSection(build_zig_tmpl, "gui_backend", .{ .gui_dep_name = "labelle_clay" }, w),
    }

    if (cfg.platform == .wasm) {
        // WASM: import emsdk helpers from backend
        switch (cfg.backend) {
            .raylib => try tpl.writeSection(build_zig_tmpl, "wasm_emsdk_raylib", w),
            .sokol => try tpl.writeSection(build_zig_tmpl, "wasm_emsdk_sokol", w),
            else => {},
        }

        // WASM: build as library, link via emcc
        try tpl.writeSection(build_zig_tmpl, "wasm_exe_start", w);

        for (cfg.plugins) |plugin| {
            try w.print("                .{{ .name = \"{s}\", .module = plugin_{s}_mod }},\n", .{ plugin.name, plugin.name });
        }

        if (cfg.ecs != .mock) {
            try tpl.writeSection(build_zig_tmpl, "wasm_exe_ecs_import", w);
        }
        if (cfg.gui != .none) {
            try tpl.writeSection(build_zig_tmpl, "wasm_exe_gui_import", w);
        }

        try tpl.writeSection(build_zig_tmpl, "wasm_exe_end", w);

        switch (cfg.backend) {
            .raylib => try tpl.writeSection(build_zig_tmpl, "link_raylib_wasm", w),
            .sokol => try tpl.writeSection(build_zig_tmpl, "link_sokol_wasm", w),
            else => {},
        }

        try tpl.writeSection(build_zig_tmpl, "wasm_footer", w);
    } else {
        // Desktop: build as executable, link natively
        try tpl.writeSection(build_zig_tmpl, "exe_start", w);

        for (cfg.plugins) |plugin| {
            try w.print("                .{{ .name = \"{s}\", .module = plugin_{s}_mod }},\n", .{ plugin.name, plugin.name });
        }

        if (cfg.ecs != .mock) {
            try tpl.writeSection(build_zig_tmpl, "exe_ecs_import", w);
        }
        if (cfg.gui != .none) {
            try tpl.writeSection(build_zig_tmpl, "exe_gui_import", w);
        }

        try tpl.writeSection(build_zig_tmpl, "exe_end", w);

        if (cfg.gui == .imgui) {
            switch (cfg.backend) {
                .raylib => try tpl.writeSection(build_zig_tmpl, "link_imgui_raylib", w),
                .sokol => try tpl.writeSection(build_zig_tmpl, "link_imgui_sokol", w),
                .sdl, .bgfx, .wgpu => {},
            }
        } else {
            switch (cfg.backend) {
                .raylib => try tpl.writeSection(build_zig_tmpl, "link_raylib", w),
                .sokol => try tpl.writeSection(build_zig_tmpl, "link_sokol", w),
                .sdl => try tpl.writeSection(build_zig_tmpl, "link_sdl", w),
                .bgfx => try tpl.writeSection(build_zig_tmpl, "link_bgfx", w),
                .wgpu => try tpl.writeSection(build_zig_tmpl, "link_wgpu", w),
            }
        }

        try tpl.writeSection(build_zig_tmpl, "footer", w);
    }

    return buf.toOwnedSlice(allocator);
}

// ============================================================
// build.zig.zon generator
// ============================================================

pub fn generateBuildZigZon(allocator: std.mem.Allocator, cfg: ProjectConfig, target_dir: ?[]const u8, project_dir: ?[]const u8) ![]const u8 {
    var buf = std.ArrayList(u8){};
    const w = buf.writer(allocator);

    // Resolve target dir to absolute for relative path computation
    const abs_target: ?[]const u8 = if (target_dir) |td|
        std.fs.cwd().realpathAlloc(allocator, td) catch null
    else
        null;
    defer if (abs_target) |at| allocator.free(at);

    var hash: u64 = 0x517cc1b727220a95;
    for (cfg.name) |c| {
        hash = hash *% 0x100000001b3 +% c;
    }
    var hash_buf: [16]u8 = undefined;
    const hash_str = std.fmt.bufPrint(&hash_buf, "{x}", .{hash}) catch unreachable;

    try tpl.renderSection(build_zig_zon_tmpl, "header", .{ .hash = hash_str, .version = cfg.version }, w);

    // Resolve framework package paths via cache, then make relative to target dir
    const core_path_abs = try cache.resolveFrameworkPackage(allocator, "core", cfg.core_version, project_dir);
    defer allocator.free(core_path_abs);
    const core_path = try relativePath(allocator, abs_target, core_path_abs);
    defer allocator.free(core_path);

    const gfx_path_abs = try cache.resolveFrameworkPackage(allocator, "gfx", cfg.gfx_version, project_dir);
    defer allocator.free(gfx_path_abs);
    const gfx_path = try relativePath(allocator, abs_target, gfx_path_abs);
    defer allocator.free(gfx_path);

    const engine_path_abs = try cache.resolveFrameworkPackage(allocator, "engine", cfg.engine_version, project_dir);
    defer allocator.free(engine_path_abs);
    const engine_path = try relativePath(allocator, abs_target, engine_path_abs);
    defer allocator.free(engine_path);

    try tpl.renderSection(build_zig_zon_tmpl, "dep_core_path", .{
        .core_path = core_path,
        .gfx_path = gfx_path,
        .engine_path = engine_path,
    }, w);

    // Plugin deps (for all declared plugins)
    for (cfg.plugins) |plugin| {
        const plugin_path_abs = try cache.resolvePlugin(allocator, plugin, project_dir);
        defer allocator.free(plugin_path_abs);
        const plugin_path = try relativePath(allocator, abs_target, plugin_path_abs);
        defer allocator.free(plugin_path);

        try w.print("        .labelle_{s} = .{{\n", .{plugin.name});
        try w.print("            .path = \"{s}\",\n", .{plugin_path});
        try w.writeAll("        },\n");
    }

    // Backend dep — resolved from CLI cache
    // For imgui with raylib/sokol, the imgui variant replaces the normal backend dep and provides GUI.
    const use_imgui_backend = cfg.gui == .imgui and (cfg.backend == .raylib or cfg.backend == .sokol);
    if (use_imgui_backend) {
        const gui_dep_name: []const u8 = if (cfg.backend == .raylib) "labelle_raylib_imgui" else "labelle_sokol_imgui";
        const gui_dir: []const u8 = if (cfg.backend == .raylib) "raylib-imgui" else "sokol-imgui";

        var gui_subpath_buf: [128]u8 = undefined;
        const gui_subpath = std.fmt.bufPrint(&gui_subpath_buf, "gui/{s}", .{gui_dir}) catch unreachable;
        const gui_path_abs = try cache.resolveCliPackage(allocator, cfg.labelle_version, project_dir, gui_subpath);
        defer allocator.free(gui_path_abs);
        const gui_path = try relativePath(allocator, abs_target, gui_path_abs);
        defer allocator.free(gui_path);

        try tpl.renderSection(build_zig_zon_tmpl, "dep_gui_path", .{
            .gui_dep_name = gui_dep_name,
            .gui_path = gui_path,
        }, w);
    } else {
        const backend_name = @tagName(cfg.backend);
        var section_buf: [64]u8 = undefined;
        const section = std.fmt.bufPrint(&section_buf, "dep_{s}_path", .{backend_name}) catch unreachable;

        var backend_subpath_buf: [128]u8 = undefined;
        const backend_subpath = std.fmt.bufPrint(&backend_subpath_buf, "backends/{s}", .{backend_name}) catch unreachable;
        const backend_path_abs = try cache.resolveCliPackage(allocator, cfg.labelle_version, project_dir, backend_subpath);
        defer allocator.free(backend_path_abs);
        const backend_path = try relativePath(allocator, abs_target, backend_path_abs);
        defer allocator.free(backend_path);

        try tpl.renderSection(build_zig_zon_tmpl, section, .{ .backend_path = backend_path }, w);
    }

    // ECS adapter dep — resolved from CLI cache
    switch (cfg.ecs) {
        .mock => {},
        .zig_ecs, .zflecs, .mr_ecs => {
            const ecs_dep_name: []const u8 = switch (cfg.ecs) {
                .zig_ecs => "labelle_zig_ecs",
                .zflecs => "labelle_zflecs",
                .mr_ecs => "labelle_mr_ecs",
                .mock => unreachable,
            };
            const ecs_dir: []const u8 = switch (cfg.ecs) {
                .zig_ecs => "zig-ecs",
                .zflecs => "zflecs",
                .mr_ecs => "mr-ecs",
                .mock => unreachable,
            };

            var ecs_subpath_buf: [128]u8 = undefined;
            const ecs_subpath = std.fmt.bufPrint(&ecs_subpath_buf, "ecs/{s}", .{ecs_dir}) catch unreachable;
            const ecs_path_abs = try cache.resolveCliPackage(allocator, cfg.labelle_version, project_dir, ecs_subpath);
            defer allocator.free(ecs_path_abs);
            const ecs_path = try relativePath(allocator, abs_target, ecs_path_abs);
            defer allocator.free(ecs_path);

            try tpl.renderSection(build_zig_zon_tmpl, "dep_ecs_path", .{
                .ecs_dep_name = ecs_dep_name,
                .ecs_path = ecs_path,
            }, w);
        },
    }

    // GUI dep (non-imgui)
    switch (cfg.gui) {
        .none, .imgui => {},
        .simple, .clay => {
            const gui_dep_name: []const u8 = if (cfg.gui == .simple) "labelle_simple_gui" else "labelle_clay";
            const gui_dir: []const u8 = if (cfg.gui == .simple) "simple-raylib" else "clay";

            var gui_subpath_buf: [128]u8 = undefined;
            const gui_subpath = std.fmt.bufPrint(&gui_subpath_buf, "gui/{s}", .{gui_dir}) catch unreachable;
            const gui_path_abs = try cache.resolveCliPackage(allocator, cfg.labelle_version, project_dir, gui_subpath);
            defer allocator.free(gui_path_abs);
            const gui_path = try relativePath(allocator, abs_target, gui_path_abs);
            defer allocator.free(gui_path);

            try tpl.renderSection(build_zig_zon_tmpl, "dep_gui_path", .{
                .gui_dep_name = gui_dep_name,
                .gui_path = gui_path,
            }, w);
        },
    }

    // WASM: emscripten SDK dependency (required by raylib's emccStep)
    if (cfg.platform == .wasm) {
        try tpl.writeSection(build_zig_zon_tmpl, "dep_emsdk", w);
    }

    try tpl.writeSection(build_zig_zon_tmpl, "footer", w);

    return buf.toOwnedSlice(allocator);
}

/// Compute a relative path from `from_dir` to `to_path`.
/// If from_dir is null, returns a copy of to_path (absolute).
/// Both must be absolute paths when from_dir is provided. Returns an allocator-owned string.
fn relativePath(allocator: std.mem.Allocator, from_dir: ?[]const u8, to_path: []const u8) ![]const u8 {
    if (from_dir == null) return try allocator.dupe(u8, to_path);
    return std.fs.path.relative(allocator, from_dir.?, to_path);
}
