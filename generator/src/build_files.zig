/// build.zig and build.zig.zon generators for the labelle-cli assembler.
const std = @import("std");
const tpl = @import("template.zig");
const config = @import("config.zig");
const cache = @import("cache.zig");
pub const deps_linker = @import("deps_linker.zig");

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
    } else if (cfg.platform == .ios) {
        try tpl.writeSection(build_zig_tmpl, "header_ios", w);
    } else {
        try tpl.writeSection(build_zig_tmpl, "header", w);
    }

    if (cfg.platform == .ios) {
        // Emit target alias for ECS adapters, plugins, and GUI that use `target` variable
        if (cfg.plugins.len > 0 or cfg.ecs != .mock or cfg.hasGui()) {
            try tpl.writeSection(build_zig_tmpl, "ios_target_alias", w);
        }
        try tpl.writeSection(build_zig_tmpl, "ios_deps", w);
    } else {
        try tpl.writeSection(build_zig_tmpl, "deps", w);
    }

    // Plugin dep/module declarations (for all declared plugins)
    for (cfg.plugins) |plugin| {
        if (cfg.platform == .ios) {
            // Pass iOS SDK path to plugins so C dependencies can find system headers
            try w.print("    const plugin_{s}_dep = b.dependency(\"labelle_{s}\", .{{ .target = target, .optimize = optimize, .ios_sdk_path = @as(?[]const u8, sdk_path) }});\n", .{ plugin.name, plugin.name });
        } else {
            try w.print("    const plugin_{s}_dep = b.dependency(\"labelle_{s}\", .{{ .target = target, .optimize = optimize }});\n", .{ plugin.name, plugin.name });
        }
        try w.print("    const plugin_{s}_mod = plugin_{s}_dep.module(\"labelle_{s}\");\n", .{ plugin.name, plugin.name, plugin.name });
    }

    // Backend dep — always the standard backend (never a merged GUI+backend package)
    switch (cfg.backend) {
        .raylib => try tpl.writeSection(build_zig_tmpl, "backend_raylib", w),
        .sokol => {
            if (cfg.platform == .wasm) {
                try tpl.writeSection(build_zig_tmpl, "backend_sokol_wasm", w);
            } else if (cfg.platform == .ios) {
                try tpl.writeSection(build_zig_tmpl, "backend_sokol_ios", w);
            } else {
                try tpl.writeSection(build_zig_tmpl, "backend_sokol", w);
            }
        },
        .sdl => try tpl.writeSection(build_zig_tmpl, "backend_sdl", w),
        .bgfx => try tpl.writeSection(build_zig_tmpl, "backend_bgfx", w),
        .wgpu => try tpl.writeSection(build_zig_tmpl, "backend_wgpu", w),
    }

    switch (cfg.ecs) {
        .mock => {},
        .zig_ecs => try tpl.renderSection(build_zig_tmpl, "ecs_adapter", .{ .ecs_dep_name = "labelle_zig_ecs" }, w),
        .zflecs => try tpl.renderSection(build_zig_tmpl, "ecs_adapter", .{ .ecs_dep_name = "labelle_zflecs" }, w),
        .mr_ecs => try tpl.renderSection(build_zig_tmpl, "ecs_adapter", .{ .ecs_dep_name = "labelle_mr_ecs" }, w),
    }

    // GUI plugin dep (manifest-driven — no switch on GUI type)
    if (cfg.resolved_gui) |gui| {
        const gui_mod_name = try std.fmt.allocPrint(allocator, "labelle_{s}", .{gui.name});
        defer allocator.free(gui_mod_name);
        try tpl.renderSection(build_zig_tmpl, "gui_backend", .{ .gui_dep_name = "labelle_gui", .gui_mod_name = gui_mod_name }, w);
    }

    // Inject shared modules into plugins — ensures all plugins use the same
    // package instances and have access to engine subsystems (#42, #61).
    if (cfg.plugins.len > 0) {
        try w.writeByte('\n');
        for (cfg.plugins) |plugin| {
            // Core + gfx + engine — use overrideImport to avoid GPA leaks
            try w.print("    overrideImport(plugin_{s}_mod, \"labelle-core\", core_mod);\n", .{plugin.name});
            try w.print("    overrideImport(plugin_{s}_mod, \"labelle-gfx\", gfx_mod);\n", .{plugin.name});
            try w.print("    overrideImport(plugin_{s}_mod, \"labelle-engine\", engine_mod);\n", .{plugin.name});

            // ECS backend
            if (cfg.ecs != .mock) {
                try w.print("    overrideImport(plugin_{s}_mod, \"ecs_backend\", ecs_mod);\n", .{plugin.name});
            }

            // Backend modules
            try w.print("    overrideImport(plugin_{s}_mod, \"backend_gfx\", backend_gfx);\n", .{plugin.name});
            try w.print("    overrideImport(plugin_{s}_mod, \"backend_input\", backend_input);\n", .{plugin.name});
            try w.print("    overrideImport(plugin_{s}_mod, \"backend_audio\", backend_audio);\n", .{plugin.name});
            try w.print("    overrideImport(plugin_{s}_mod, \"backend_window\", backend_window);\n", .{plugin.name});

            // GUI backend
            if (cfg.hasGui()) {
                try w.print("    overrideImport(plugin_{s}_mod, \"gui_backend\", gui_mod);\n", .{plugin.name});
            }
        }
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
        if (cfg.hasGui()) {
            try tpl.writeSection(build_zig_tmpl, "wasm_exe_gui_import", w);
        }

        try tpl.writeSection(build_zig_tmpl, "wasm_exe_end", w);

        switch (cfg.backend) {
            .raylib => try tpl.writeSection(build_zig_tmpl, "link_raylib_wasm", w),
            .sokol => try tpl.writeSection(build_zig_tmpl, "link_sokol_wasm", w),
            else => {},
        }

        // Link bridge artifact for WASM (raw_backend GUIs)
        if (cfg.resolved_gui) |gui| {
            if (gui.rendering == .raw_backend and gui.bridge_dir != null) {
                try tpl.renderSection(build_zig_tmpl, "gui_bridge", .{ .bridge_artifact_name = gui.bridge_artifact }, w);
                try tpl.writeSection(build_zig_tmpl, "link_gui_bridge_wasm", w);
            }
        }

        try tpl.writeSection(build_zig_tmpl, "wasm_footer", w);
    } else if (cfg.platform == .ios) {
        // iOS: build executable for simulator, link frameworks manually
        try tpl.writeSection(build_zig_tmpl, "ios_exe_start", w);

        for (cfg.plugins) |plugin| {
            try w.print("                .{{ .name = \"{s}\", .module = plugin_{s}_mod }},\n", .{ plugin.name, plugin.name });
        }

        if (cfg.ecs != .mock) {
            try tpl.writeSection(build_zig_tmpl, "ios_exe_ecs_import", w);
        }
        if (cfg.hasGui()) {
            try tpl.writeSection(build_zig_tmpl, "ios_exe_gui_import", w);
        }

        try tpl.writeSection(build_zig_tmpl, "ios_exe_end", w);
        try tpl.writeSection(build_zig_tmpl, "ios_link", w);

        // Bridge artifact (raw_backend GUIs)
        if (cfg.resolved_gui) |gui| {
            if (gui.rendering == .raw_backend and gui.bridge_dir != null) {
                try tpl.renderSection(build_zig_tmpl, "gui_bridge", .{ .bridge_artifact_name = gui.bridge_artifact }, w);
                try tpl.writeSection(build_zig_tmpl, "ios_link_gui_bridge", w);
            }
        }

        try tpl.writeSection(build_zig_tmpl, "ios_footer", w);
    } else {
        // Desktop: build as executable, link natively
        try tpl.writeSection(build_zig_tmpl, "exe_start", w);

        for (cfg.plugins) |plugin| {
            try w.print("                .{{ .name = \"{s}\", .module = plugin_{s}_mod }},\n", .{ plugin.name, plugin.name });
        }

        if (cfg.ecs != .mock) {
            try tpl.writeSection(build_zig_tmpl, "exe_ecs_import", w);
        }
        if (cfg.hasGui()) {
            try tpl.writeSection(build_zig_tmpl, "exe_gui_import", w);
        }

        try tpl.writeSection(build_zig_tmpl, "exe_end", w);

        // Link backend artifact
        switch (cfg.backend) {
            .raylib => try tpl.writeSection(build_zig_tmpl, "link_raylib", w),
            .sokol => try tpl.writeSection(build_zig_tmpl, "link_sokol", w),
            .sdl => try tpl.writeSection(build_zig_tmpl, "link_sdl", w),
            .bgfx => try tpl.writeSection(build_zig_tmpl, "link_bgfx", w),
            .wgpu => try tpl.writeSection(build_zig_tmpl, "link_wgpu", w),
        }

        // Bridge artifact (raw_backend GUIs) — declare + link
        if (cfg.resolved_gui) |gui| {
            if (gui.rendering == .raw_backend and gui.bridge_dir != null) {
                try tpl.renderSection(build_zig_tmpl, "gui_bridge", .{ .bridge_artifact_name = gui.bridge_artifact }, w);
                try tpl.writeSection(build_zig_tmpl, "link_gui_bridge", w);
            }
        }

        try tpl.writeSection(build_zig_tmpl, "footer", w);
    }

    return buf.toOwnedSlice(allocator);
}

// ============================================================
// build.zig.zon generator
// ============================================================

pub fn generateBuildZigZon(allocator: std.mem.Allocator, cfg: ProjectConfig, target_dir: ?[]const u8, output_dir: ?[]const u8, project_dir: ?[]const u8) ![]const u8 {
    var buf = std.ArrayList(u8){};
    const w = buf.writer(allocator);

    // Create deps/ hardlinks in .labelle/deps/ (shared across targets)
    const deps_parent = output_dir orelse target_dir;
    const resolved_deps: ?[]const deps_linker.DepEntry = if (deps_parent != null and project_dir != null)
        deps_linker.createDepsLinks(allocator, cfg, deps_parent.?, project_dir.?) catch null
    else
        null;

    var hash: u64 = 0x517cc1b727220a95;
    for (cfg.name) |c| {
        hash = hash *% 0x100000001b3 +% c;
    }
    var hash_buf: [16]u8 = undefined;
    const hash_str = std.fmt.bufPrint(&hash_buf, "{x}", .{hash}) catch unreachable;

    try tpl.renderSection(build_zig_zon_tmpl, "header", .{ .hash = hash_str, .version = cfg.version }, w);

    if (resolved_deps) |deps| {
        defer deps_linker.freeDepEntries(allocator, deps);
        // Deps are at .labelle/deps/, zon is at .labelle/<target>/
        const prefix = if (output_dir != null and target_dir != null) "../deps" else "deps";
        for (deps) |dep| {
            try w.print("        .{s} = .{{\n", .{dep.zon_name});
            try w.print("            .path = \"{s}/{s}\",\n", .{ prefix, dep.link_name });
            try w.writeAll("        },\n");
        }
    } else {
        // Fallback: relative paths (for tests without target_dir)
        try generateZonPathsFallback(allocator, cfg, target_dir, project_dir, w);
    }

    if (cfg.platform == .wasm) {
        try tpl.writeSection(build_zig_zon_tmpl, "dep_emsdk", w);
    }

    try tpl.writeSection(build_zig_zon_tmpl, "footer", w);

    return buf.toOwnedSlice(allocator);
}

/// Fallback: compute relative paths when deps/ symlinks aren't available.
fn generateZonPathsFallback(allocator: std.mem.Allocator, cfg: ProjectConfig, target_dir: ?[]const u8, project_dir: ?[]const u8, w: anytype) !void {
    const abs_target: ?[]const u8 = if (target_dir) |td|
        std.fs.cwd().realpathAlloc(allocator, td) catch null
    else
        null;
    defer if (abs_target) |at| allocator.free(at);

    const core_abs = try cache.resolveFrameworkPackage(allocator, "core", cfg.core_version, project_dir);
    defer allocator.free(core_abs);
    const core_path = try relativePath(allocator, abs_target, core_abs);
    defer allocator.free(core_path);
    const gfx_abs = try cache.resolveFrameworkPackage(allocator, "gfx", cfg.gfx_version, project_dir);
    defer allocator.free(gfx_abs);
    const gfx_path = try relativePath(allocator, abs_target, gfx_abs);
    defer allocator.free(gfx_path);
    const engine_abs = try cache.resolveFrameworkPackage(allocator, "engine", cfg.engine_version, project_dir);
    defer allocator.free(engine_abs);
    const engine_path = try relativePath(allocator, abs_target, engine_abs);
    defer allocator.free(engine_path);

    try tpl.renderSection(build_zig_zon_tmpl, "dep_core_path", .{ .core_path = core_path, .gfx_path = gfx_path, .engine_path = engine_path }, w);

    for (cfg.plugins) |plugin| {
        const p_abs = try cache.resolvePlugin(allocator, plugin, project_dir);
        defer allocator.free(p_abs);
        const p = try relativePath(allocator, abs_target, p_abs);
        defer allocator.free(p);
        try w.print("        .labelle_{s} = .{{ .path = \"{s}\" }},\n", .{ plugin.name, p });
    }

    {
        const bn = @tagName(cfg.backend);
        var sb: [64]u8 = undefined;
        const section = std.fmt.bufPrint(&sb, "dep_{s}_path", .{bn}) catch unreachable;
        var spb: [128]u8 = undefined;
        const sp = std.fmt.bufPrint(&spb, "backends/{s}", .{bn}) catch unreachable;
        const bp_abs = try cache.resolveCliPackage(allocator, cfg.labelle_version, project_dir, sp);
        defer allocator.free(bp_abs);
        const bp = try relativePath(allocator, abs_target, bp_abs);
        defer allocator.free(bp);
        try tpl.renderSection(build_zig_zon_tmpl, section, .{ .backend_path = bp }, w);
    }

    switch (cfg.ecs) {
        .mock => {},
        .zig_ecs, .zflecs, .mr_ecs => {
            const dn: []const u8 = switch (cfg.ecs) { .zig_ecs => "labelle_zig_ecs", .zflecs => "labelle_zflecs", .mr_ecs => "labelle_mr_ecs", .mock => unreachable };
            const dd: []const u8 = switch (cfg.ecs) { .zig_ecs => "zig-ecs", .zflecs => "zflecs", .mr_ecs => "mr-ecs", .mock => unreachable };
            var spb: [128]u8 = undefined;
            const sp = std.fmt.bufPrint(&spb, "ecs/{s}", .{dd}) catch unreachable;
            const ep_abs = try cache.resolveCliPackage(allocator, cfg.labelle_version, project_dir, sp);
            defer allocator.free(ep_abs);
            const ep = try relativePath(allocator, abs_target, ep_abs);
            defer allocator.free(ep);
            try tpl.renderSection(build_zig_zon_tmpl, "dep_ecs_path", .{ .ecs_dep_name = dn, .ecs_path = ep }, w);
        },
    }

    if (cfg.resolved_gui) |gui| {
        const gp = try relativePath(allocator, abs_target, gui.plugin_dir);
        defer allocator.free(gp);
        try tpl.renderSection(build_zig_zon_tmpl, "dep_gui_path", .{ .gui_dep_name = "labelle_gui", .gui_path = gp }, w);
        if (gui.bridge_dir) |bd| {
            const bp = try relativePath(allocator, abs_target, bd);
            defer allocator.free(bp);
            try tpl.renderSection(build_zig_zon_tmpl, "dep_gui_bridge_path", .{ .bridge_path = bp }, w);
        }
    }
}

/// Compute a relative path from `from_dir` to `to_path`.
/// If from_dir is null, returns a copy of to_path (absolute).
/// Both must be absolute paths when from_dir is provided. Returns an allocator-owned string.
fn relativePath(allocator: std.mem.Allocator, from_dir: ?[]const u8, to_path: []const u8) ![]const u8 {
    if (from_dir == null) return try allocator.dupe(u8, to_path);
    return std.fs.path.relative(allocator, from_dir.?, to_path);
}
