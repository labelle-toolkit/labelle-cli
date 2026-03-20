//! labelle-debug — Debug inspector plugin for LaBelle.

const std = @import("std");
const core = @import("labelle-core");
const Position = core.Position;

var show_entities: bool = false;
var time_scale_slider: f32 = 1.0;
var selected_entity: ?u32 = null;

const MAX_COMPONENTS: usize = 32;
var component_filters: [MAX_COMPONENTS]bool = [_]bool{false} ** MAX_COMPONENTS;

pub const Systems = struct {
    pub fn drawGui(game: anytype) void {
        const Gui = @TypeOf(game.*).Gui;
        if (!Gui.supportsWidgets()) return;

        if (Gui.beginWindow("Debug Inspector")) {
            // ── Stats ──
            if (Gui.treeNode("Stats")) {
                var buf: [64]u8 = undefined;
                Gui.label(std.fmt.bufPrintZ(&buf, "Entities: {d}", .{game.ecs_backend.entityCount()}) catch "?");
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
            if (Gui.button("0.25x")) game.setTimeScale(0.25);
            Gui.sameLine();
            if (Gui.button("0.5x")) game.setTimeScale(0.5);
            Gui.sameLine();
            if (Gui.button("1x")) game.setTimeScale(1.0);
            Gui.sameLine();
            if (Gui.button("2x")) game.setTimeScale(2.0);

            time_scale_slider = game.getTimeScale();
            _ = Gui.sliderFloat("Time Scale", &time_scale_slider, 0, 3);
            if (time_scale_slider != game.getTimeScale()) {
                game.setTimeScale(time_scale_slider);
            }

            Gui.separator();

            var gizmos_on = game.gizmos_enabled;
            if (Gui.checkbox("Show Gizmos", &gizmos_on)) {
                game.gizmos_enabled = gizmos_on;
            }

            Gui.separator();
            _ = Gui.checkbox("Entity Browser", &show_entities);
        }
        Gui.endWindow();

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
        // Filters
        Gui.label("Filter:");
        inline for (comp_names, 0..) |name, i| {
            if (i < MAX_COMPONENTS) {
                _ = Gui.checkbox(@ptrCast(name), &component_filters[i]);
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

            var iter = game.ecs_backend.query(.{Position});
            defer deinitIter(&iter, game.allocator);

            var count: usize = 0;
            while (iter.next()) |result| {
                if (count >= 50) break;

                const entity = result.entity;
                const pos: *const Position = result.comp_0;

                // Apply filters
                var passes = true;
                inline for (comp_names, 0..) |name, i| {
                    if (i < MAX_COMPONENTS and component_filters[i]) {
                        if (!Reg.entityHasNamed(&game.ecs_backend, entity, name)) {
                            passes = false;
                        }
                    }
                }
                if (!passes) continue;

                Gui.tableNextRow();

                // ID
                _ = Gui.tableNextColumn();
                var id_buf: [16]u8 = undefined;
                Gui.label(std.fmt.bufPrintZ(&id_buf, "{d}", .{entity}) catch "?");

                // Position
                _ = Gui.tableNextColumn();
                var pos_buf: [48]u8 = undefined;
                Gui.label(std.fmt.bufPrintZ(&pos_buf, "({d:.0}, {d:.0})", .{ pos.x, pos.y }) catch "?");

                // Component tags
                _ = Gui.tableNextColumn();
                var tags_buf: [256]u8 = undefined;
                var tags_len: usize = 0;

                inline for (comp_names) |name| {
                    if (Reg.entityHasNamed(&game.ecs_backend, entity, name)) {
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

                // Select button
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
        Gui.label(std.fmt.bufPrintZ(&total_buf, "Total: {d}", .{game.ecs_backend.entityCount()}) catch "?");
    }
    Gui.endWindow();
}

fn drawEntityDetail(game: anytype, comptime Gui: type) void {
    const entity = selected_entity orelse return;
    const Reg = @TypeOf(game.*).ComponentRegistry;
    const comp_names = comptime Reg.names();

    if (!game.ecs_backend.entityExists(entity)) {
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

        // Position (always show)
        if (game.ecs_backend.getComponent(entity, Position)) |pos| {
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
            if (game.ecs_backend.getComponent(entity, T)) |comp| {
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
        // Skip internal fields (prefixed with _)
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
        // Mock ECS: deinit(self) only
        iter.deinit();
    } else {
        // Real ECS: deinit(self, allocator)
        iter.deinit(alloc);
    }
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
