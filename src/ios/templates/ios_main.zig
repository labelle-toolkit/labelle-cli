//! iOS Main Entry Point for labelle-engine games
//!
//! This file provides the sokol_app callbacks for iOS:
//! - init: Initialize graphics
//! - frame: Update and render each frame
//! - event: Handle touch and keyboard input
//! - cleanup: Free resources on app termination
//!
//! Touch events are tracked and accessible via getTouchCount/getTouch.
//!
//! Note: This is a standalone sokol demo. Full labelle-engine integration
//! requires fixing the raylib iOS dependency in labelle-gfx.

const std = @import("std");

// Sokol bindings - for iOS with Metal backend
const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;

// ============================================================================
// Touch Input Types (placeholder until issue #218 is implemented)
// ============================================================================

pub const TouchPhase = enum {
    began,
    moved,
    ended,
    cancelled,
};

pub const Touch = struct {
    id: u64,
    x: f32,
    y: f32,
    phase: TouchPhase,
};

const MAX_TOUCHES = 10;

// ============================================================================
// Global State
// ============================================================================

const State = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    initialized: bool = false,
    frame_count: u32 = 0,

    // Touch input state
    touches: [MAX_TOUCHES]Touch = undefined,
    touch_count: u32 = 0,

    // Screen dimensions (updated on resize)
    screen_width: f32 = 0,
    screen_height: f32 = 0,

    // Clear color (changes with touch)
    clear_r: f32 = 0.2,
    clear_g: f32 = 0.3,
    clear_b: f32 = 0.4,
};

var state: State = .{};

// ============================================================================
// Sokol App Callbacks
// ============================================================================

/// Initialize the graphics system
export fn init() callconv(.c) void {
    // Initialize sokol_gfx with Metal backend (automatic on iOS)
    sg.setup(.{
        .environment = sokol.glue.environment(),
        .logger = .{ .func = sokol.log.func },
    });

    // Store initial screen dimensions
    state.screen_width = @floatFromInt(sapp.width());
    state.screen_height = @floatFromInt(sapp.height());

    // Initialize touch state
    for (&state.touches) |*touch| {
        touch.* = .{ .id = 0, .x = 0, .y = 0, .phase = .ended };
    }
    state.touch_count = 0;

    state.initialized = true;

    std.log.info("labelle_ios initialized", .{});
    std.log.info("Screen size: {d:.0}x{d:.0}", .{ state.screen_width, state.screen_height });
}

/// Called every frame - update game state and render
export fn frame() callconv(.c) void {
    if (!state.initialized) return;

    state.frame_count += 1;

    // Update screen dimensions (may change on rotation)
    state.screen_width = @floatFromInt(sapp.width());
    state.screen_height = @floatFromInt(sapp.height());

    // Update clear color based on touch (visual feedback)
    if (state.touch_count > 0) {
        // Normalize first touch position to color
        const touch = state.touches[0];
        state.clear_r = touch.x / state.screen_width;
        state.clear_g = touch.y / state.screen_height;
        state.clear_b = 0.5;
    } else {
        // Default color when no touch
        state.clear_r = 0.2;
        state.clear_g = 0.3;
        state.clear_b = 0.4;
    }

    // Clear per-frame touch state (touches that ended last frame)
    var i: u32 = 0;
    while (i < state.touch_count) {
        if (state.touches[i].phase == .ended or state.touches[i].phase == .cancelled) {
            // Remove this touch by shifting remaining touches
            var j = i;
            while (j + 1 < state.touch_count) : (j += 1) {
                state.touches[j] = state.touches[j + 1];
            }
            state.touch_count -= 1;
        } else {
            i += 1;
        }
    }

    // Begin render pass with dynamic clear color
    var pass_action: sg.PassAction = .{};
    pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{
            .r = state.clear_r,
            .g = state.clear_g,
            .b = state.clear_b,
            .a = 1.0,
        },
    };

    sg.beginPass(.{
        .action = pass_action,
        .swapchain = sokol.glue.swapchain(),
    });

    // End render pass and commit
    sg.endPass();
    sg.commit();
}

/// Handle input events (touch, keyboard)
export fn event(ev: ?*const sapp.Event) callconv(.c) void {
    const e = ev orelse return;

    switch (e.type) {
        // Touch events
        .TOUCHES_BEGAN => handleTouchEvent(e, .began),
        .TOUCHES_MOVED => handleTouchEvent(e, .moved),
        .TOUCHES_ENDED => handleTouchEvent(e, .ended),
        .TOUCHES_CANCELLED => handleTouchEvent(e, .cancelled),

        // Keyboard (for simulator testing)
        .KEY_DOWN => {
            if (e.key_code == .ESCAPE) {
                sapp.quit();
            }
        },

        // Window resize (device rotation)
        .RESIZED => {
            state.screen_width = @floatFromInt(sapp.width());
            state.screen_height = @floatFromInt(sapp.height());
            std.log.info("Screen resized to {d:.0}x{d:.0}", .{ state.screen_width, state.screen_height });
        },

        // App lifecycle
        .SUSPENDED => {
            std.log.info("App suspended", .{});
        },
        .RESUMED => {
            std.log.info("App resumed", .{});
        },

        else => {},
    }
}

/// Cleanup resources on app termination
export fn cleanup() callconv(.c) void {
    std.log.info("labelle_ios cleanup", .{});
    sg.shutdown();
}

// ============================================================================
// Touch Handling
// ============================================================================

fn handleTouchEvent(e: *const sapp.Event, phase: TouchPhase) void {
    // Process each touch in the event
    var i: u32 = 0;
    while (i < e.num_touches) : (i += 1) {
        const sokol_touch = e.touches[i];
        if (!sokol_touch.changed) continue;

        const touch = Touch{
            .id = sokol_touch.identifier,
            .x = sokol_touch.pos_x,
            .y = sokol_touch.pos_y,
            .phase = phase,
        };

        // Find existing touch with same ID or add new one
        var found = false;
        for (state.touches[0..state.touch_count]) |*existing| {
            if (existing.id == touch.id) {
                existing.* = touch;
                found = true;
                break;
            }
        }

        if (!found and state.touch_count < MAX_TOUCHES) {
            state.touches[state.touch_count] = touch;
            state.touch_count += 1;
        }

        // Log touch event
        std.log.debug("Touch {s}: id={d} pos=({d:.1}, {d:.1})", .{
            @tagName(phase),
            touch.id,
            touch.x,
            touch.y,
        });
    }
}

// ============================================================================
// Public API for Game Integration
// ============================================================================

/// Get current touch count
pub fn getTouchCount() u32 {
    return state.touch_count;
}

/// Get touch at index
pub fn getTouch(index: u32) ?Touch {
    if (index < state.touch_count) {
        return state.touches[index];
    }
    return null;
}

/// Get screen dimensions
pub fn getScreenSize() struct { width: f32, height: f32 } {
    return .{ .width = state.screen_width, .height = state.screen_height };
}

// ============================================================================
// Entry Point
// ============================================================================

/// Entry point - uses sokol's SOKOL_NO_ENTRY mode via sapp.run()
/// sokol-zig defines SOKOL_NO_ENTRY for all non-Android platforms,
/// so we call sapp.run() ourselves rather than exporting sokol_main.
pub fn main() void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        .width = 390,
        .height = 844,
        .window_title = "Labelle iOS",
        .high_dpi = true,
        .fullscreen = true,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = sokol.log.func },
    });
}
