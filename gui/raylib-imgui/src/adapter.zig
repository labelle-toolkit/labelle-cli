/// Dear ImGui GUI adapter for raylib — satisfies the engine GuiInterface contract.
/// Uses rlImGui for the raylib+ImGui integration and cimgui for the widget API.
///
/// Game code accesses the full ImGui API through GuiBackend.ig (the cimgui module).
pub const ig = @import("cimgui");

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
