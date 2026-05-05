# imgui-anchor-test

Minimal reproduction for an imgui-anchor drift bug observed on
Android in `flying-platform-labelle`'s build menu (Place/Cancel
buttons that pin to a slot's screen-space center keep moving on
Android while staying stable on desktop).

## What it does

A single world entity sits at `(200, 100)`. Each frame, an imgui
window is pinned to that world position's screen-space coordinate
using the same idiom the real game uses:

```zig
const sc = cam.worldToScreen(FIXED_WORLD_X, FIXED_WORLD_Y);
ig.igSetNextWindowPosEx(
    .{ .x = sc.x, .y = sc.y },
    ig.ImGuiCond_Always,
    .{ .x = 0.5, .y = 0.5 }, // pivot at window center
);
```

The window contains two buttons (`Place`, `Cancel`) — same shape
that drifts in the real game.

A throttled log line each ~60 frames prints `anchor`, `imgui
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

- **Desktop:** the `Anchor Test` window stays glued to the same
  pixel position frame after frame; logged `anchor` is constant.
- **Android (observed bug):** the window drifts even though
  `FIXED_WORLD_X/Y` are constants. Inspect the log to see whether
  `anchor`, `imgui_display`, or `cam_vp` is fluctuating.

## Diagnostic value

If `anchor` is itself drifting, the bug is in
`worldToScreen` / camera state on Android. If `anchor` is stable
but the window renders elsewhere, the bug is in imgui's window
positioning vs DPI scale. If `imgui_display` ≠ `cam_vp`, the two
coordinate systems disagree — anchor in render-target pixels gets
interpreted as imgui display units (or vice versa).
