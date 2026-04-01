const position = @import("position.zig");
const Position = position.Position;

/// Standalone gizmo draw command — ephemeral debug drawings collected per frame.
/// Backend-agnostic: uses packed u32 ARGB color, simple float coordinates.
pub const GizmoDraw = struct {
    kind: Kind,
    x1: f32 = 0,
    y1: f32 = 0,
    x2: f32 = 0, // width for rect, radius for circle, end_x for line/arrow
    y2: f32 = 0, // height for rect, end_y for line/arrow
    color: u32 = 0xFF00FF00, // default green (ARGB)
    group: []const u8 = "",
    space: Space = .world,
    /// Category index for per-category enable/disable. 0 = "all" (uncategorized).
    category: u8 = 0,

    pub const Kind = enum { line, rect, circle, arrow, text };
    pub const Space = enum { world, screen };
};

/// Marker component for gizmo entities. Gizmo positions are resolved
/// from parent entity position + offset during rendering.
pub fn GizmoComponent(comptime Entity: type) type {
    return struct {
        parent_entity: ?Entity = null,
        offset_x: f32 = 0,
        offset_y: f32 = 0,
        visibility: GizmoVisibility = .always,
        group: []const u8 = "",
    };
}

/// Visibility modes for entity-bound gizmos.
pub const GizmoVisibility = enum {
    always, // Show whenever gizmos are enabled
    selected_only, // Only show when parent entity is selected
    never, // Never show (disabled)
};

/// Comptime-validated debug draw interface for gizmos.
/// Plugins use this to draw debug visualizations (grid overlays, path lines, etc.)
/// without depending on the engine or any graphics backend.
///
/// The assembler provides the concrete Impl; in tests, StubGizmos is used.
pub fn GizmoInterface(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "drawLine")) @compileError("Gizmo impl must define 'drawLine'");
        if (!@hasDecl(Impl, "drawRect")) @compileError("Gizmo impl must define 'drawRect'");
    }

    return struct {
        pub const Implementation = Impl;

        pub inline fn drawLine(x1: f32, y1: f32, x2: f32, y2: f32, color: u32) void {
            Impl.drawLine(x1, y1, x2, y2, color);
        }

        pub inline fn drawRect(x: f32, y: f32, w: f32, h: f32, color: u32) void {
            Impl.drawRect(x, y, w, h, color);
        }

        pub inline fn drawCircle(x: f32, y: f32, radius: f32, color: u32) void {
            if (@hasDecl(Impl, "drawCircle")) {
                Impl.drawCircle(x, y, radius, color);
            }
        }

        pub inline fn drawText(x: f32, y: f32, text: []const u8, color: u32) void {
            if (@hasDecl(Impl, "drawText")) {
                Impl.drawText(x, y, text, color);
            }
        }

        /// Helper: draw an arrow from (x1,y1) to (x2,y2) with arrowhead.
        pub inline fn drawArrow(x1: f32, y1: f32, x2: f32, y2: f32, color: u32) void {
            Impl.drawLine(x1, y1, x2, y2, color);
            // Simple arrowhead: two short lines from endpoint
            const dx = x2 - x1;
            const dy = y2 - y1;
            const len = @sqrt(dx * dx + dy * dy);
            if (len < 0.001) return;
            const nx = dx / len;
            const ny = dy / len;
            const head_size: f32 = 8;
            const px = -ny; // perpendicular
            const py = nx;
            Impl.drawLine(x2, y2, x2 - nx * head_size + px * head_size * 0.5, y2 - ny * head_size + py * head_size * 0.5, color);
            Impl.drawLine(x2, y2, x2 - nx * head_size - px * head_size * 0.5, y2 - ny * head_size - py * head_size * 0.5, color);
        }

        /// Helper: draw a line between two Positions.
        pub inline fn drawLineBetween(a: Position, b: Position, color: u32) void {
            Impl.drawLine(a.x, a.y, b.x, b.y, color);
        }
    };
}

/// Stub gizmos for testing — records draw calls for assertions.
pub const StubGizmos = struct {
    var line_count: u32 = 0;
    var rect_count: u32 = 0;
    var circle_count: u32 = 0;
    var text_count: u32 = 0;

    pub fn drawLine(_: f32, _: f32, _: f32, _: f32, _: u32) void {
        line_count += 1;
    }

    pub fn drawRect(_: f32, _: f32, _: f32, _: f32, _: u32) void {
        rect_count += 1;
    }

    pub fn drawCircle(_: f32, _: f32, _: f32, _: u32) void {
        circle_count += 1;
    }

    pub fn drawText(_: f32, _: f32, _: []const u8, _: u32) void {
        text_count += 1;
    }

    pub fn reset() void {
        line_count = 0;
        rect_count = 0;
        circle_count = 0;
        text_count = 0;
    }

    pub fn getLineCount() u32 {
        return line_count;
    }

    pub fn getRectCount() u32 {
        return rect_count;
    }

    pub fn getCircleCount() u32 {
        return circle_count;
    }

    pub fn getTextCount() u32 {
        return text_count;
    }
};
