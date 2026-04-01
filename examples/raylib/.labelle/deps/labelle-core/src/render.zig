/// RenderInterface — comptime validator for renderer implementations.
/// Lives in core so both engine and plugins can reference it.
const std = @import("std");

/// What kind of visual an entity has.
pub const VisualType = enum {
    none,
    sprite,
    shape,
    text,
};

/// RenderInterface — validates that a renderer implementation satisfies the engine's contract.
/// The assembler fills the Impl slot at build time (e.g. GfxRenderer from labelle-gfx).
///
/// **Coordinate convention:** The engine and all game code use Y-up coordinates
/// (origin at bottom-left). Renderer implementations receive positions in Y-up
/// space and must convert to screen coordinates (Y-down) before drawing. Use
/// `coordinates.gameToScreen` for the conversion. The `setScreenHeight` method
/// provides the screen height needed for the transform.
pub fn RenderInterface(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "init")) @compileError("Renderer must define 'init(allocator) -> Self'");
        if (!@hasDecl(Impl, "deinit")) @compileError("Renderer must define 'deinit'");
        if (!@hasDecl(Impl, "trackEntity")) @compileError("Renderer must define 'trackEntity'");
        if (!@hasDecl(Impl, "untrackEntity")) @compileError("Renderer must define 'untrackEntity'");
        if (!@hasDecl(Impl, "markPositionDirty")) @compileError("Renderer must define 'markPositionDirty'");
        if (!@hasDecl(Impl, "markVisualDirty")) @compileError("Renderer must define 'markVisualDirty'");
        if (!@hasDecl(Impl, "sync")) @compileError("Renderer must define 'sync'");
        if (!@hasDecl(Impl, "render")) @compileError("Renderer must define 'render'");
        if (!@hasDecl(Impl, "setScreenHeight")) @compileError("Renderer must define 'setScreenHeight'");
        if (!@hasDecl(Impl, "clear")) @compileError("Renderer must define 'clear'");
        // Renderer must export component types so the engine can use them
        if (!@hasDecl(Impl, "Sprite")) @compileError("Renderer must export 'Sprite' component type");
        if (!@hasDecl(Impl, "Shape")) @compileError("Renderer must export 'Shape' component type");
    }
    return struct {
        pub const Implementation = Impl;
    };
}

/// StubRender — no-op renderer for engine-only testing (zero gfx dependencies).
pub fn StubRender(comptime Entity: type) type {
    return struct {
        const Self = @This();

        pub const Sprite = struct {
            sprite_name: []const u8 = "",
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        pub const Shape = struct {
            shape: union(enum) {
                rectangle: struct { width: f32 = 10, height: f32 = 10 },
                circle: struct { radius: f32 = 10 },
            } = .{ .rectangle = .{} },
            color: struct { r: u8 = 255, g: u8 = 255, b: u8 = 255, a: u8 = 255 } = .{},
            visible: bool = true,
            z_index: i16 = 0,
            layer: enum { default } = .default,
        };

        pub const Text = struct {
            text: [:0]const u8 = "",
            visible: bool = true,
            z_index: i16 = 0,
        };

        pub const Icon = struct {
            name: []const u8 = "",
            visible: bool = true,
        };

        tracked_count: usize = 0,
        render_count: usize = 0,

        pub fn init(_: std.mem.Allocator) Self {
            return .{};
        }

        pub fn deinit(_: *Self) void {}

        pub fn trackEntity(self: *Self, _: Entity, _: VisualType) void {
            self.tracked_count += 1;
        }

        pub fn untrackEntity(self: *Self, _: Entity) void {
            if (self.tracked_count > 0) self.tracked_count -= 1;
        }

        pub fn markPositionDirty(_: *Self, _: Entity) void {}

        pub fn markPositionDirtyWithChildren(_: *Self, comptime _: type, _: anytype, _: Entity) void {}

        pub fn updateHierarchyFlag(_: *Self, _: Entity, _: bool) void {}

        pub fn markVisualDirty(_: *Self, _: Entity) void {}

        pub fn sync(_: *Self, comptime _: type, _: anytype) void {}

        pub fn render(self: *Self) void {
            self.render_count += 1;
        }

        pub fn setScreenHeight(_: *Self, _: f32) void {}

        pub fn clear(self: *Self) void {
            self.tracked_count = 0;
        }

        pub fn renderGizmoDraws(_: *Self, _: []const @import("gizmos.zig").GizmoDraw) void {}

        pub fn hasEntity(_: *const Self, _: Entity) bool {
            return false;
        }
    };
}
