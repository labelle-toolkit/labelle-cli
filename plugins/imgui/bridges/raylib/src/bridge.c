/// Raylib bridge for Dear ImGui — re-exports rlImGui functions under the
/// generic imgui_bridge_* symbol contract expected by the imgui adapter.

// rlImGui provides these symbols (compiled from rlImGui.cpp)
extern void rlImGuiSetup(int dark_theme);
extern void rlImGuiBegin(void);
extern void rlImGuiEnd(void);
extern void rlImGuiShutdown(void);

// Generic bridge contract — called by the imgui adapter
void imgui_bridge_setup(int dark_theme) {
    rlImGuiSetup(dark_theme);
}

void imgui_bridge_begin(void) {
    rlImGuiBegin();
}

void imgui_bridge_end(void) {
    rlImGuiEnd();
}

void imgui_bridge_shutdown(void) {
    rlImGuiShutdown();
}
