// Repro and fix validation for the build-menu anchor drift bug:
// flying-platform-labelle pins an imgui window to a fixed world
// position. On desktop the window stays put; on Android it drifted
// frame-to-frame because `worldToScreen` returns design-space coords
// while imgui expects framebuffer-space coords (labelle-gfx#253).
//
// This script validates the fix: the window and magenta dot are
// positioned via `cam.worldToFramebuffer` (framebuffer-space). The
// old `worldToScreen` result is logged alongside for comparison.
//
// Three visuals to compare on the screen:
//   1. The world entity's actual rendered position (the small
//      filled rectangle drawn by the world renderer at world coords
//      (200, 100)).
//   2. A magenta dot drawn via imgui's foreground draw list at the
//      anchor my math computes — i.e., where I think the world
//      entity is on the screen.
//   3. The "Anchor Test" imgui window pinned to that same anchor.
//
// If (1), (2), and (3) all line up, the math is correct. If they
// drift apart — especially during camera pan — the math has a gap.
//
// The camera auto-pans left-right on its own so you don't need to
// manually drag anything (no input wiring on this fixture). Slow
// 0.25 Hz oscillation (4-second period), ±150 world units.

const std = @import("std");
const ig = @import("gui_backend").ig;

// World position of the rectangle's top-left corner.
const RECT_X: f32 = 200;
const RECT_Y: f32 = 100;
const RECT_W: f32 = 60;
const RECT_H: f32 = 40;
// Anchor at the rect's center. World is Y-up but a Shape rect's
// Position is its TOP-LEFT in screen Y-down (the renderer flips
// world Y → screen Y), so the rect extends *downward in screen* =
// *decreasing world Y*. Center world Y = top - H/2, not + H/2.
const FIXED_WORLD_X: f32 = RECT_X + RECT_W * 0.5;
const FIXED_WORLD_Y: f32 = RECT_Y - RECT_H * 0.5;

const PAN_AMPLITUDE: f32 = 150.0;
const PAN_FREQ_HZ: f32 = 0.25; // 4-second period

var t_seconds: f32 = 0;

pub fn tick(game: anytype, dt: f32) void {
    t_seconds += dt;
    const cam = game.getCamera();
    const phase = std.math.sin(t_seconds * PAN_FREQ_HZ * std.math.tau);
    cam.x = FIXED_WORLD_X + PAN_AMPLITUDE * phase;
    cam.y = FIXED_WORLD_Y;
}

pub fn drawGui(game: anytype) void {
    const cam = game.getCamera();
    const sc = cam.worldToScreen(FIXED_WORLD_X, FIXED_WORLD_Y);

    // Use the new `worldToFramebuffer` helper instead of re-deriving
    // the design→physical transform inline. Mirrors the renderer's
    // pillarbox/letterbox math via the backend's `designToPhysical`,
    // so the imgui anchor lands on the same physical pixel as the
    // world-rendered entity. See labelle-gfx#253.
    const fb = cam.worldToFramebuffer(FIXED_WORLD_X, FIXED_WORLD_Y);
    const anchor_x = fb.x;
    const anchor_y = fb.y;

    const display = ig.igGetIO().*.DisplaySize;
    const vp = cam.getViewportDimensions();

    // Throttle the log to once per ~60 frames so logcat doesn't drown.
    // Logs both sc (design-space worldToScreen) and fb (framebuffer-space
    // worldToFramebuffer) for side-by-side comparison across platforms.
    {
        const Pulse = struct { var n: u32 = 0; };
        Pulse.n +%= 1;
        if (Pulse.n % 60 == 0) {
            game.log.info(
                "[anchor_test] frame={d} cam=({d:.1},{d:.1}) sc=({d:.1},{d:.1}) fb=({d:.1},{d:.1}) imgui_display=({d:.1},{d:.1}) cam_vp=({d:.1},{d:.1})",
                .{
                    Pulse.n,
                    cam.x,        cam.y,
                    sc.x,         sc.y,
                    fb.x,         fb.y,
                    display.x,    display.y,
                    vp.width,     vp.height,
                },
            );
        }
    }

    // Magenta dot at the corrected anchor. Should overlay the green
    // rectangle if the math matches what the renderer does.
    {
        const dl = ig.igGetForegroundDrawList();
        if (dl != null) {
            ig.ImDrawList_AddCircleFilled(
                dl,
                .{ .x = anchor_x, .y = anchor_y },
                10.0,
                0xFFFF00FF, // ABGR magenta
                16,
            );
        }
    }

    ig.igSetNextWindowPosEx(
        .{ .x = anchor_x, .y = anchor_y },
        ig.ImGuiCond_Always,
        .{ .x = 0.5, .y = 0.5 },
    );
    ig.igSetNextWindowBgAlpha(0.6);

    const flags: c_int =
        ig.ImGuiWindowFlags_NoTitleBar |
        ig.ImGuiWindowFlags_NoResize |
        ig.ImGuiWindowFlags_NoMove |
        ig.ImGuiWindowFlags_NoCollapse |
        ig.ImGuiWindowFlags_NoSavedSettings |
        ig.ImGuiWindowFlags_AlwaysAutoResize;

    if (ig.igBegin("Anchor Test", null, flags)) {
        // Two buttons mirroring Place / Cancel — same shape that
        // exhibits the drift in the real game.
        _ = ig.igButton("Place");
        ig.igSameLine();
        _ = ig.igButton("Cancel");
    }
    ig.igEnd();
}
