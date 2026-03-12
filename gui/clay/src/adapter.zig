/// Clay GUI adapter — satisfies the engine GuiInterface contract.
/// Wraps clay-zig-bindings (zclay) for the Clay UI layout library.
///
/// Clay is a layout-based immediate-mode UI library. Game code accesses
/// the full Clay API through the GuiBackend type exposed by GuiInterface.
const zclay = @import("zclay");

pub fn begin() void {
    zclay.beginLayout();
}

pub fn end() void {
    _ = zclay.endLayout();
}

pub fn wantsMouse() bool {
    return zclay.pointerOver(.{ .id = 0 });
}

pub fn wantsKeyboard() bool {
    // Clay doesn't have text input focus tracking
    return false;
}

/// Re-export the full zclay API for game code to use directly.
pub const Clay = zclay;
