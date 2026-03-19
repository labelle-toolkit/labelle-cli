/// Dear ImGui GUI adapter — satisfies the engine GuiInterface contract.
///
/// This plugin is backend-agnostic. The bridge adapter (e.g., rlimgui_bridge)
/// provides the extern functions that connect ImGui to a specific backend.
///
/// Game code accesses the full ImGui API through GuiBackend.ig (the cimgui module).
pub const ig = @import("cimgui");

// These externs are provided by the bridge adapter (rlImGui for raylib, sokol-imgui for sokol, etc.)
extern fn rlImGuiSetup(dark_theme: bool) void;
extern fn rlImGuiBegin() void;
extern fn rlImGuiEnd() void;
extern fn rlImGuiShutdown() void;

pub fn init() void {
    rlImGuiSetup(true);
}

pub fn shutdown() void {
    rlImGuiShutdown();
}

pub fn begin() void {
    rlImGuiBegin();
}

pub fn end() void {
    rlImGuiEnd();
}

pub fn wantsMouse() bool {
    const io = ig.igGetIO();
    return io.*.WantCaptureMouse;
}

pub fn wantsKeyboard() bool {
    const io = ig.igGetIO();
    return io.*.WantCaptureKeyboard;
}
