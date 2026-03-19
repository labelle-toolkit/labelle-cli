/// Nuklear GUI adapter — satisfies the engine GuiInterface contract.
///
/// This plugin is backend-agnostic. The bridge adapter (e.g., nuklear_raylib_bridge)
/// provides the extern functions that connect Nuklear to a specific backend
/// via the `nk_bridge_*` symbol contract.
///
/// Game code accesses the Nuklear context through GuiBackend.getContext().
pub const nk = @import("nuklear");

// Bridge contract: these symbols must be provided by the bridge adapter.
extern fn nk_bridge_init() void;
extern fn nk_bridge_begin() void;
extern fn nk_bridge_end() void;
extern fn nk_bridge_shutdown() void;
extern fn nk_bridge_get_context() *nk.c.nk_context;

pub fn init() void {
    nk_bridge_init();
}

pub fn shutdown() void {
    nk_bridge_shutdown();
}

pub fn begin() void {
    nk_bridge_begin();
}

pub fn end() void {
    nk_bridge_end();
}

/// Get the raw Nuklear context for direct API calls.
pub fn getContext() *nk.c.nk_context {
    return nk_bridge_get_context();
}

pub fn wantsMouse() bool {
    const nk_ctx = nk_bridge_get_context();
    return nk.c.nk_item_is_any_active(nk_ctx) != 0;
}

pub fn wantsKeyboard() bool {
    return false;
}
