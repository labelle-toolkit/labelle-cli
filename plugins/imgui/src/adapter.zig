/// Dear ImGui GUI adapter — satisfies the engine GuiInterface contract
/// including the standard widget API for debug tooling.
///
/// Game code accesses the full ImGui API through GuiBackend.ig (the cimgui module).
pub const ig = @import("cimgui");

// Bridge contract
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

// ── Standard widget API (for GuiInterface) ─────────────────

pub fn beginWindow(name: [*:0]const u8) bool {
    return ig.igBegin(name, null, 0);
}

pub fn endWindow() void {
    ig.igEnd();
}

pub fn separator() void {
    ig.igSeparator();
}

pub fn spacing() void {
    ig.igSpacing();
}

pub fn sameLine() void {
    ig.igSameLine();
}

pub fn label(str: [*:0]const u8) void {
    ig.igTextUnformatted(str);
}

pub fn textFmt(fmt: [*:0]const u8, args: anytype) void {
    @call(.auto, ig.igText, .{fmt} ++ args);
}

pub fn button(str: [*:0]const u8) bool {
    return ig.igButton(str);
}

pub fn checkbox(str: [*:0]const u8, val: *bool) bool {
    return ig.igCheckbox(str, val);
}

pub fn sliderFloat(str: [*:0]const u8, val: *f32, min: f32, max: f32) bool {
    return ig.igSliderFloat(str, val, min, max);
}

pub fn treeNode(str: [*:0]const u8) bool {
    return ig.igTreeNodeEx(str, 0);
}

pub fn treePop() void {
    ig.igTreePop();
}

pub fn beginTable(str: [*:0]const u8, columns: i32) bool {
    return ig.igBeginTable(str, columns, 0);
}

pub fn endTable() void {
    ig.igEndTable();
}

pub fn tableNextRow() void {
    ig.igTableNextRow();
}

pub fn tableNextColumn() bool {
    return ig.igTableNextColumn();
}
