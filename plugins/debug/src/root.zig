//! labelle-debug — Debug inspector plugin for LaBelle.

const std = @import("std");
const core = @import("labelle-core");
const engine = @import("labelle-engine");
const Position = core.Position;

var debug_visible: bool = false;
var show_entities: bool = false;
var show_perf: bool = true;
var time_scale_slider: f32 = 1.0;
var selected_entity: ?u32 = null;

/// Set to false to completely disable the debug inspector (e.g. for shipping builds).
/// Games can set this in setup: `@import("debug").enabled = false;`
pub var enabled: bool = true;

/// Key to toggle the debug inspector. Default: F12.
pub var toggle_key: engine.KeyboardKey = .f12;

const MAX_COMPONENTS: usize = 32;
var component_filters: [MAX_COMPONENTS]bool = [_]bool{false} ** MAX_COMPONENTS;

// State persistence
const STATE_FILE = "debug_state.ini";
var state_dirty: bool = false;

// FPS tracking
const FPS_HISTORY: usize = 120;
var frame_times: [FPS_HISTORY]f32 = [_]f32{0} ** FPS_HISTORY;
var frame_index: usize = 0;
var last_time: ?i64 = null;
var fps_avg: f32 = 0;
var fps_min: f32 = 0;
var fps_max: f32 = 0;
var frame_ms: f32 = 0;

fn updateFpsTracking() void {
    const now = std.time.milliTimestamp();
    if (last_time) |prev| {
        const delta_ms: f32 = @floatFromInt(now - prev);
        frame_times[frame_index] = delta_ms;
        frame_index = (frame_index + 1) % FPS_HISTORY;
        frame_ms = delta_ms;

        // Compute stats from history
        var sum: f32 = 0;
        var min: f32 = 9999;
        var max: f32 = 0;
        var count: usize = 0;
        for (frame_times) |t| {
            if (t > 0) {
                sum += t;
                if (t < min) min = t;
                if (t > max) max = t;
                count += 1;
            }
        }
        if (count > 0) {
            const avg = sum / @as(f32, @floatFromInt(count));
            fps_avg = if (avg > 0) 1000.0 / avg else 0;
            fps_min = if (max > 0) 1000.0 / max else 0;
            fps_max = if (min > 0) 1000.0 / min else 0;
        }
    }
    last_time = now;
}

pub const Systems = struct {
    pub fn setup(game: anytype) void {
        loadDebugState(game);
    }

    pub fn drawGui(game: anytype) void {
        if (!enabled) return;

        const Gui = @TypeOf(game.*).Gui;
        if (!Gui.supportsWidgets()) return;

        var dirty = false;

        // F12 toggles visibility
        if (game.isKeyPressed(toggle_key)) {
            debug_visible = !debug_visible;
            dirty = true;
        }

        // Always track FPS even when hidden
        updateFpsTracking();

        // Save before early return so F12-to-hide is persisted
        if (dirty and !debug_visible) {
            saveDebugState(game);
            return;
        }

        if (!debug_visible) return;

        if (Gui.beginWindow("Debug Inspector")) {
            // ── FPS (always visible) ──
            var fps_buf: [64]u8 = undefined;
            Gui.label(std.fmt.bufPrintZ(&fps_buf, "FPS: {d:.0} | Frame: {d:.1}ms", .{ fps_avg, frame_ms }) catch "?");

            if (show_perf) {
                var perf_buf: [64]u8 = undefined;
                Gui.label(std.fmt.bufPrintZ(&perf_buf, "Min: {d:.0} Avg: {d:.0} Max: {d:.0}", .{ fps_min, fps_avg, fps_max }) catch "?");

                // Mini frame time graph via text bars
                var graph_buf: [64]u8 = undefined;
                const bar_len: usize = 40;
                var bar: [bar_len]u8 = undefined;
                const max_ms: f32 = 33.3; // 30 FPS = one full bar
                for (0..bar_len) |i| {
                    const idx = (frame_index + FPS_HISTORY - bar_len + i) % FPS_HISTORY;
                    const t = frame_times[idx];
                    const ratio = @min(t / max_ms, 1.0);
                    bar[i] = if (ratio > 0.8) '!' else if (ratio > 0.5) '#' else if (ratio > 0.2) '=' else '.';
                }
                bar[bar_len - 1] = 0;
                Gui.label(std.fmt.bufPrintZ(&graph_buf, "[{s}]", .{bar[0 .. bar_len - 1 :0]}) catch "?");
            }
            // Script profiling (debug builds only)
            if (game.script_profile_ptr) |ptr| {
                const ProfileEntry = struct { name: []const u8, tick_ns: u64, draw_gui_ns: u64 };
                const entries: [*]const ProfileEntry = @ptrCast(@alignCast(ptr));
                const count = game.script_profile_count;

                Gui.spacing();
                Gui.label("Scripts:");
                for (0..count) |i| {
                    const e = entries[i];
                    const tick_us = @as(f64, @floatFromInt(e.tick_ns)) / 1000.0;
                    const gui_us = @as(f64, @floatFromInt(e.draw_gui_ns)) / 1000.0;
                    var sbuf: [96]u8 = undefined;
                    Gui.label(std.fmt.bufPrintZ(&sbuf, "  {s}: tick={d:.0}us gui={d:.0}us", .{ e.name, tick_us, gui_us }) catch "?");
                }
            }

            if (game.plugin_profile_ptr) |ptr| {
                const PluginEntry = struct { name: []const u8, tick_ns: u64, post_tick_ns: u64, draw_gui_ns: u64 };
                const entries: [*]const PluginEntry = @ptrCast(@alignCast(ptr));
                const count = game.plugin_profile_count;

                Gui.spacing();
                Gui.label("Plugins:");
                for (0..count) |i| {
                    const e = entries[i];
                    const tick_us = @as(f64, @floatFromInt(e.tick_ns)) / 1000.0;
                    const post_us = @as(f64, @floatFromInt(e.post_tick_ns)) / 1000.0;
                    const gui_us = @as(f64, @floatFromInt(e.draw_gui_ns)) / 1000.0;
                    var sbuf: [128]u8 = undefined;
                    Gui.label(std.fmt.bufPrintZ(&sbuf, "  {s}: tick={d:.0}us post={d:.0}us gui={d:.0}us", .{ e.name, tick_us, post_us, gui_us }) catch "?");
                }
            }

            {
                const prev = show_perf;
                _ = Gui.checkbox("Show Performance", &show_perf);
                if (show_perf != prev) dirty = true;
            }

            Gui.separator();

            // ── Stats ──
            if (Gui.treeNode("Stats")) {
                var buf: [64]u8 = undefined;
                Gui.label(std.fmt.bufPrintZ(&buf, "Entities: {d}", .{game.active_world.ecs_backend.entityCount()}) catch "?");
                var frame_buf: [64]u8 = undefined;
                Gui.label(std.fmt.bufPrintZ(&frame_buf, "Frame: {d}", .{game.frame_number}) catch "?");
                Gui.treePop();
            }

            Gui.separator();

            // ── Time Control ──
            if (game.isPaused()) {
                if (Gui.button("Resume")) game.resume_();
            } else {
                if (Gui.button("Pause")) game.pause();
            }
            Gui.sameLine();
            if (Gui.button("0.25x")) { game.setTimeScale(0.25); dirty = true; }
            Gui.sameLine();
            if (Gui.button("0.5x")) { game.setTimeScale(0.5); dirty = true; }
            Gui.sameLine();
            if (Gui.button("1x")) { game.setTimeScale(1.0); dirty = true; }
            Gui.sameLine();
            if (Gui.button("2x")) { game.setTimeScale(2.0); dirty = true; }

            time_scale_slider = game.getTimeScale();
            _ = Gui.sliderFloat("Time Scale", &time_scale_slider, 0, 3);
            if (time_scale_slider != game.getTimeScale()) {
                game.setTimeScale(time_scale_slider);
                dirty = true;
            }

            Gui.separator();

            if (Gui.treeNode("Gizmos")) {
                var gizmos_on = game.gizmos_enabled;
                if (Gui.checkbox("Master Toggle", &gizmos_on)) {
                    game.gizmos_enabled = gizmos_on;
                    dirty = true;
                }

                // Category 0 = uncategorized (always present)
                var cat0_enabled = game.isGizmoCategoryEnabled(0);
                if (Gui.checkbox("Uncategorized", &cat0_enabled)) {
                    game.setGizmoCategory(0, cat0_enabled);
                    dirty = true;
                }

                // Auto-discovered categories from plugins
                const categories = @TypeOf(game.*).gizmo_categories;
                for (categories) |cat| {
                    var cat_on = game.isGizmoCategoryEnabled(cat.id);
                    var name_buf: [64]u8 = undefined;
                    const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{cat.name}) catch "?";
                    if (Gui.checkbox(name_z, &cat_on)) {
                        game.setGizmoCategory(cat.id, cat_on);
                        dirty = true;
                    }
                }

                Gui.treePop();
            }

            Gui.separator();
            {
                const prev = show_entities;
                _ = Gui.checkbox("Entity Browser", &show_entities);
                if (show_entities != prev) dirty = true;
            }
        }
        Gui.endWindow();

        if (dirty) state_dirty = true;
        if (state_dirty) {
            saveDebugState(game);
            state_dirty = false;
        }

        if (show_entities) {
            drawEntityBrowser(game, Gui);
            drawEntityDetail(game, Gui);
        }
    }
};

fn drawEntityBrowser(game: anytype, comptime Gui: type) void {
    const Reg = @TypeOf(game.*).ComponentRegistry;
    const comp_names = comptime Reg.names();

    if (Gui.beginWindow("Entity Browser")) {
        Gui.label("Filter:");
        inline for (comp_names, 0..) |name, i| {
            if (i < MAX_COMPONENTS) {
                const prev = component_filters[i];
                _ = Gui.checkbox(@ptrCast(name), &component_filters[i]);
                if (component_filters[i] != prev) state_dirty = true;
                if ((i + 1) % 4 != 0 and i + 1 < comp_names.len) Gui.sameLine();
            }
        }

        Gui.separator();

        if (Gui.beginTable("entities", 4)) {
            Gui.tableNextRow();
            _ = Gui.tableNextColumn();
            Gui.label("ID");
            _ = Gui.tableNextColumn();
            Gui.label("Position");
            _ = Gui.tableNextColumn();
            Gui.label("Components");
            _ = Gui.tableNextColumn();
            Gui.label("");

            var iter = game.active_world.ecs_backend.query(.{Position});
            defer deinitIter(&iter, game.allocator);

            var count: usize = 0;
            while (iter.next()) |result| {
                if (count >= 50) break;

                const entity = result.entity;
                const pos: *const Position = result.comp_0;

                var passes = true;
                inline for (comp_names, 0..) |name, i| {
                    if (i < MAX_COMPONENTS and component_filters[i]) {
                        if (!Reg.entityHasNamed(&game.active_world.ecs_backend, entity, name)) {
                            passes = false;
                        }
                    }
                }
                if (!passes) continue;

                Gui.tableNextRow();

                _ = Gui.tableNextColumn();
                var id_buf: [16]u8 = undefined;
                Gui.label(std.fmt.bufPrintZ(&id_buf, "{d}", .{entity}) catch "?");

                _ = Gui.tableNextColumn();
                var pos_buf: [48]u8 = undefined;
                Gui.label(std.fmt.bufPrintZ(&pos_buf, "({d:.0}, {d:.0})", .{ pos.x, pos.y }) catch "?");

                _ = Gui.tableNextColumn();
                var tags_buf: [256]u8 = undefined;
                var tags_len: usize = 0;

                inline for (comp_names) |name| {
                    if (Reg.entityHasNamed(&game.active_world.ecs_backend, entity, name)) {
                        if (tags_len + name.len + 1 < tags_buf.len) {
                            @memcpy(tags_buf[tags_len .. tags_len + name.len], name);
                            tags_len += name.len;
                            tags_buf[tags_len] = ' ';
                            tags_len += 1;
                        }
                    }
                }
                if (tags_len > 0) {
                    tags_buf[tags_len] = 0;
                    Gui.label(@ptrCast(tags_buf[0..tags_len :0]));
                }

                _ = Gui.tableNextColumn();
                var sel_buf: [24]u8 = undefined;
                const sel_label = std.fmt.bufPrintZ(&sel_buf, "Select##{d}", .{entity}) catch "?";
                if (Gui.button(sel_label)) {
                    selected_entity = entity;
                }

                count += 1;
            }
            Gui.endTable();
        }

        var total_buf: [48]u8 = undefined;
        Gui.label(std.fmt.bufPrintZ(&total_buf, "Total: {d}", .{game.active_world.ecs_backend.entityCount()}) catch "?");
    }
    Gui.endWindow();
}

fn drawEntityDetail(game: anytype, comptime Gui: type) void {
    const entity = selected_entity orelse return;
    const Reg = @TypeOf(game.*).ComponentRegistry;
    const comp_names = comptime Reg.names();

    if (!game.active_world.ecs_backend.entityExists(entity)) {
        selected_entity = null;
        return;
    }

    if (Gui.beginWindow("Entity Detail")) {
        var id_buf: [32]u8 = undefined;
        Gui.label(std.fmt.bufPrintZ(&id_buf, "Entity: {d}", .{entity}) catch "?");

        if (Gui.button("Deselect")) {
            selected_entity = null;
        }

        Gui.separator();

        // Position (always show, not in registry)
        if (game.active_world.ecs_backend.getComponent(entity, Position)) |pos| {
            if (Gui.treeNode("Position")) {
                var buf: [64]u8 = undefined;
                Gui.label(std.fmt.bufPrintZ(&buf, "x: {d:.2}", .{pos.x}) catch "?");
                var buf2: [64]u8 = undefined;
                Gui.label(std.fmt.bufPrintZ(&buf2, "y: {d:.2}", .{pos.y}) catch "?");
                Gui.treePop();
            }
        }

        // Each registered component
        inline for (comp_names) |name| {
            const T = Reg.getType(name);
            if (game.active_world.ecs_backend.getComponent(entity, T)) |comp| {
                if (Gui.treeNode(@ptrCast(name))) {
                    showStructFields(Gui, comp, T);
                    Gui.treePop();
                }
            }
        }
    }
    Gui.endWindow();
}

/// Display all fields of a struct in the GUI.
fn showStructFields(comptime Gui: type, ptr: anytype, comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .@"struct") return;

    inline for (info.@"struct".fields) |field| {
        if (field.name[0] == '_') continue;

        var buf: [128]u8 = undefined;
        const value = @field(ptr.*, field.name);
        const label = formatField(&buf, field.name, field.type, value) catch "?";
        Gui.label(label);
    }
}

/// Deinit a query iterator — handles both mock (0 args) and real ECS (1 arg: allocator).
fn deinitIter(iter: anytype, alloc: anytype) void {
    const DeinitFn = @TypeOf(@TypeOf(iter.*).deinit);
    const params = @typeInfo(DeinitFn).@"fn".params;
    if (params.len == 1) {
        iter.deinit();
    } else {
        iter.deinit(alloc);
    }
}

/// Log a warning through the game's log sink if available, otherwise stderr.
fn logWarn(game: anytype, comptime fmt: []const u8, args: anytype) void {
    const Game = @TypeOf(game.*);
    if (@hasField(Game, "log")) {
        game.log.warn("[debug] " ++ fmt, args);
    } else {
        std.debug.print("debug-plugin: " ++ fmt ++ "\n", args);
    }
}

// ── Gizmo state persistence ──────────────────────────────────────────

fn loadDebugState(game: anytype) void {
    const file = std.fs.cwd().openFile(STATE_FILE, .{}) catch |err| {
        if (err != error.FileNotFound) {
            logWarn(game, "could not open state file: {any}", .{err});
        }
        return;
    };
    defer file.close();

    var buf: [4096]u8 = undefined;
    const len = file.readAll(&buf) catch |err| {
        logWarn(game, "could not read state file: {any}", .{err});
        return;
    };
    applyDebugState(game, buf[0..len]);
}

/// Parse a debug_state.ini string and apply values to game + module state.
fn applyDebugState(game: anytype, content: []const u8) void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t\r");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        const on = std.mem.eql(u8, val, "1");

        if (std.mem.eql(u8, key, "gizmos_enabled")) {
            game.gizmos_enabled = on;
        } else if (std.mem.eql(u8, key, "debug_visible")) {
            debug_visible = on;
        } else if (std.mem.eql(u8, key, "show_perf")) {
            show_perf = on;
        } else if (std.mem.eql(u8, key, "show_entities")) {
            show_entities = on;
        } else if (std.mem.eql(u8, key, "time_scale")) {
            const scale = std.fmt.parseFloat(f32, val) catch continue;
            game.setTimeScale(scale);
        } else if (std.mem.startsWith(u8, key, "category_")) {
            const id_str = key["category_".len..];
            const id = std.fmt.parseInt(u8, id_str, 10) catch continue;
            game.setGizmoCategory(id, on);
        } else if (std.mem.startsWith(u8, key, "filter_")) {
            const id_str = key["filter_".len..];
            const id = std.fmt.parseInt(usize, id_str, 10) catch continue;
            if (id < MAX_COMPONENTS) component_filters[id] = on;
        }
    }
}

fn saveDebugState(game: anytype) void {
    var buf: [4096]u8 = undefined;
    const len = serializeDebugState(game, &buf);

    const file = std.fs.cwd().createFile(STATE_FILE, .{}) catch |err| {
        logWarn(game, "could not create state file: {any}", .{err});
        return;
    };
    defer file.close();
    file.writeAll(buf[0..len]) catch |err| {
        logWarn(game, "could not write state file: {any}", .{err});
    };
}

/// Serialize debug state into a buffer. Returns bytes written.
fn serializeDebugState(game: anytype, buf: *[4096]u8) usize {
    var pos: usize = 0;

    const fields = .{
        .{ "debug_visible", debug_visible },
        .{ "show_perf", show_perf },
        .{ "show_entities", show_entities },
        .{ "gizmos_enabled", game.gizmos_enabled },
    };
    inline for (fields) |f| {
        const line = std.fmt.bufPrint(buf[pos..], "{s}={s}\n", .{ f[0], if (f[1]) "1" else "0" }) catch return pos;
        pos += line.len;
    }

    // Time scale
    {
        const line = std.fmt.bufPrint(buf[pos..], "time_scale={d:.2}\n", .{game.getTimeScale()}) catch return pos;
        pos += line.len;
    }

    // Gizmo categories
    {
        const line = std.fmt.bufPrint(buf[pos..], "category_0={s}\n", .{if (game.isGizmoCategoryEnabled(0)) "1" else "0"}) catch return pos;
        pos += line.len;
    }
    const categories = @TypeOf(game.*).gizmo_categories;
    for (categories) |cat| {
        const line = std.fmt.bufPrint(buf[pos..], "category_{d}={s}\n", .{ cat.id, if (game.isGizmoCategoryEnabled(cat.id)) "1" else "0" }) catch return pos;
        pos += line.len;
    }

    // Component filters
    for (0..MAX_COMPONENTS) |i| {
        if (component_filters[i]) {
            const line = std.fmt.bufPrint(buf[pos..], "filter_{d}=1\n", .{i}) catch return pos;
            pos += line.len;
        }
    }

    return pos;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

const GizmoCategoryEntry = struct { name: []const u8, id: u8 };

const MockGame = struct {
    gizmos_enabled: bool = true,
    time_scale: f32 = 1.0,
    category_enabled: [32]bool = [_]bool{true} ** 32,

    pub const gizmo_categories = [_]GizmoCategoryEntry{
        .{ .name = "Workers", .id = 1 },
        .{ .name = "Navigation", .id = 2 },
    };

    pub fn setTimeScale(self: *MockGame, scale: f32) void {
        self.time_scale = scale;
    }
    pub fn getTimeScale(self: *const MockGame) f32 {
        return self.time_scale;
    }
    pub fn setGizmoCategory(self: *MockGame, cat: u8, on: bool) void {
        if (cat < 32) self.category_enabled[cat] = on;
    }
    pub fn isGizmoCategoryEnabled(self: *const MockGame, cat: u8) bool {
        if (cat >= 32) return false;
        return self.category_enabled[cat];
    }
};

fn resetModuleState() void {
    debug_visible = false;
    show_perf = true;
    show_entities = false;
    component_filters = [_]bool{false} ** MAX_COMPONENTS;
}

test "roundtrip: save then load restores state" {
    resetModuleState();
    var game = MockGame{};

    // Set non-default state
    debug_visible = true;
    show_perf = false;
    show_entities = true;
    game.gizmos_enabled = false;
    game.time_scale = 0.5;
    game.setGizmoCategory(0, false);
    game.setGizmoCategory(1, false);
    game.setGizmoCategory(2, true);
    component_filters[3] = true;
    component_filters[7] = true;

    // Serialize
    var buf: [4096]u8 = undefined;
    const len = serializeDebugState(&game, &buf);
    const content = buf[0..len];

    // Reset everything
    resetModuleState();
    game = MockGame{};

    // Deserialize
    applyDebugState(&game, content);

    try testing.expect(debug_visible == true);
    try testing.expect(show_perf == false);
    try testing.expect(show_entities == true);
    try testing.expect(game.gizmos_enabled == false);
    try testing.expectApproxEqAbs(@as(f32, 0.5), game.time_scale, 0.01);
    try testing.expect(game.category_enabled[0] == false);
    try testing.expect(game.category_enabled[1] == false);
    try testing.expect(game.category_enabled[2] == true);
    try testing.expect(component_filters[3] == true);
    try testing.expect(component_filters[7] == true);
    try testing.expect(component_filters[0] == false);

    resetModuleState();
}

test "CRLF line endings are handled" {
    resetModuleState();
    var game = MockGame{};

    const content = "debug_visible=1\r\nshow_perf=0\r\ngizmos_enabled=0\r\ntime_scale=2.00\r\n";
    applyDebugState(&game, content);

    try testing.expect(debug_visible == true);
    try testing.expect(show_perf == false);
    try testing.expect(game.gizmos_enabled == false);
    try testing.expectApproxEqAbs(@as(f32, 2.0), game.time_scale, 0.01);

    resetModuleState();
}

test "unknown keys are ignored" {
    resetModuleState();
    var game = MockGame{};

    const content = "debug_visible=1\nfoo_bar=1\nunknown=hello\nshow_perf=0\n";
    applyDebugState(&game, content);

    try testing.expect(debug_visible == true);
    try testing.expect(show_perf == false);
    // game state unchanged for unknown keys
    try testing.expect(game.gizmos_enabled == true);

    resetModuleState();
}

test "empty content does nothing" {
    resetModuleState();
    var game = MockGame{};
    game.gizmos_enabled = false;

    applyDebugState(&game, "");

    try testing.expect(game.gizmos_enabled == false);
    try testing.expect(debug_visible == false);

    resetModuleState();
}

fn formatField(buf: []u8, name: []const u8, comptime T: type, value: T) ![:0]u8 {
    return switch (@typeInfo(T)) {
        .float => std.fmt.bufPrintZ(buf, "{s}: {d:.3}", .{ name, value }),
        .int, .comptime_int => std.fmt.bufPrintZ(buf, "{s}: {d}", .{ name, value }),
        .bool => std.fmt.bufPrintZ(buf, "{s}: {s}", .{ name, if (value) "true" else "false" }),
        .@"enum" => std.fmt.bufPrintZ(buf, "{s}: {s}", .{ name, @tagName(value) }),
        else => std.fmt.bufPrintZ(buf, "{s}: ({s})", .{ name, @typeName(T) }),
    };
}
