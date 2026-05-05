# imgui-anchor-test

Minimal reproduction for an imgui-anchor drift bug observed on
Android in `flying-platform-labelle`'s build menu (Place/Cancel
buttons that pin to a slot's screen-space center keep moving on
Android while staying stable on desktop).

## What it does

A single world entity sits at `(200, 100)`. The camera auto-pans
±150 world units at 0.25 Hz so the anchor drift is observable
without input wiring.

Each frame an imgui window is pinned to the rect's center using the
corrected `worldToFramebuffer` helper (see labelle-gfx#253):

```zig
const fb = cam.worldToFramebuffer(FIXED_WORLD_X, FIXED_WORLD_Y);
ig.igSetNextWindowPosEx(
    .{ .x = fb.x, .y = fb.y },
    ig.ImGuiCond_Always,
    .{ .x = 0.5, .y = 0.5 }, // pivot at window center
);
```

A magenta dot is drawn at the same `fb` coordinate via the imgui
foreground draw list for eyeball comparison against the world-
rendered green rect.

The window contains two buttons (`Place`, `Cancel`) — same shape as
the build menu that exhibited the drift.

A throttled log line each ~60 frames prints `cam`, `sc`
(design-space `worldToScreen` for comparison), `fb`
(framebuffer-space `worldToFramebuffer` — the actual anchor), `imgui
DisplaySize`, and `camera viewport` so the two platforms can be
compared side-by-side.

## Running

```bash
# Desktop (sokol)
labelle run

# Android — connect a device first
labelle android run

# Android logcat filter
adb logcat -s labelle | grep anchor_test
```

## Expected vs observed

With labelle-gfx#253 applied (i.e., `worldToFramebuffer` present):

- **Desktop:** the magenta dot and `Anchor Test` window stay glued
  to the green rect through the full auto-pan cycle.
- **Android:** same — the dot and window stay glued (the drift seen
  before #253 is gone).

If drift reappears, inspect the log:

- `sc` vs `fb` — if they differ only by the design→physical scale,
  the transform is working; if they are identical, `worldToFramebuffer`
  is falling back to `worldToScreen`.
- `imgui_display` vs `cam_vp` — if these disagree on Android, imgui
  is seeing a different coordinate system than the renderer.
