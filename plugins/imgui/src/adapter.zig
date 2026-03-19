/// Dear ImGui GUI adapter — satisfies the engine GuiInterface contract.
///
/// This plugin is backend-agnostic. The bridge adapter (e.g., rlimgui_bridge,
/// sokol_imgui_bridge) provides the extern functions that connect ImGui to a
/// specific backend via the `imgui_bridge_*` symbol contract.
///
/// Game code accesses the full ImGui API through GuiBackend.ig (the cimgui module).
pub const ig = @import("cimgui");

// Bridge contract: these symbols must be provided by the bridge adapter.
// Each bridge (raylib, sokol, etc.) exports these with its own backend-specific implementation.
extern fn imgui_bridge_setup(dark_theme: bool) void;
extern fn imgui_bridge_begin() void;
extern fn imgui_bridge_end() void;
extern fn imgui_bridge_shutdown() void;

pub fn init() void {
    imgui_bridge_setup(true);
}

pub fn shutdown() void {
    imgui_bridge_shutdown();
}

pub fn begin() void {
    imgui_bridge_begin();
}

pub fn end() void {
    imgui_bridge_end();
}

pub fn wantsMouse() bool {
    const io = ig.igGetIO();
    return io.*.WantCaptureMouse;
}

pub fn wantsKeyboard() bool {
    const io = ig.igGetIO();
    return io.*.WantCaptureKeyboard;
}
