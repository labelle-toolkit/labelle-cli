/// Dear ImGui GUI adapter for sokol — satisfies the engine GuiInterface contract.
/// Uses sokol_imgui for rendering and cimgui for the widget API.
///
/// Game code accesses the full ImGui API through GuiBackend.ig (the cimgui module).
const sokol = @import("sokol");
const simgui = sokol.imgui;
const sapp = sokol.app;
pub const ig = @import("cimgui");

pub fn init() void {
    simgui.setup(.{
        .ini_filename = null,
        .no_default_font = false,
    });
}

pub fn shutdown() void {
    simgui.shutdown();
}

pub fn begin() void {
    simgui.newFrame(.{
        .width = sapp.width(),
        .height = sapp.height(),
        .delta_time = sapp.frameDuration(),
        .dpi_scale = sapp.dpiScale(),
    });
}

pub fn end() void {
    simgui.render();
}

pub fn handleEvent(ev: [*c]const sapp.Event) bool {
    return simgui.handleEvent(ev.*);
}

pub fn wantsMouse() bool {
    const io = ig.igGetIO();
    return io.*.WantCaptureMouse;
}

pub fn wantsKeyboard() bool {
    const io = ig.igGetIO();
    return io.*.WantCaptureKeyboard;
}
