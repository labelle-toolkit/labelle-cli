/// Comptime-validated GUI interface.
/// The assembler provides the concrete Impl (Clay, ImGui, Nuklear, etc.).
/// Both engine and plugins use this for zero-cost dispatch.
///
/// Required: begin(), end()
/// Optional: all widget methods — backends implement what they support.
/// Plugins call the standard API without knowing which library renders them.
pub fn GuiInterface(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "begin")) @compileError("GUI impl must define 'begin'");
        if (!@hasDecl(Impl, "end")) @compileError("GUI impl must define 'end'");
    }

    return struct {
        /// The raw backend type — game code can access library-specific APIs.
        pub const GuiBackend = Impl;

        // ── Lifecycle ──────────────────────────────────────────────

        pub inline fn begin() void {
            Impl.begin();
        }

        pub inline fn end() void {
            Impl.end();
        }

        // ── Input passthrough ──────────────────────────────────────

        pub inline fn wantsMouse() bool {
            if (@hasDecl(Impl, "wantsMouse")) return Impl.wantsMouse();
            return false;
        }

        pub inline fn wantsKeyboard() bool {
            if (@hasDecl(Impl, "wantsKeyboard")) return Impl.wantsKeyboard();
            return false;
        }

        // ── Windows ────────────────────────────────────────────────

        /// Begin a named window. Returns true if visible (content should be rendered).
        pub inline fn beginWindow(name: [*:0]const u8) bool {
            if (@hasDecl(Impl, "beginWindow")) return Impl.beginWindow(name);
            return false;
        }

        pub inline fn endWindow() void {
            if (@hasDecl(Impl, "endWindow")) Impl.endWindow();
        }

        // ── Layout ─────────────────────────────────────────────────

        pub inline fn separator() void {
            if (@hasDecl(Impl, "separator")) Impl.separator();
        }

        pub inline fn spacing() void {
            if (@hasDecl(Impl, "spacing")) Impl.spacing();
        }

        pub inline fn sameLine() void {
            if (@hasDecl(Impl, "sameLine")) Impl.sameLine();
        }

        // ── Text ───────────────────────────────────────────────────

        pub inline fn label(str: [*:0]const u8) void {
            if (@hasDecl(Impl, "label")) Impl.label(str);
        }

        pub inline fn textFmt(fmt: [*:0]const u8, args: anytype) void {
            if (@hasDecl(Impl, "textFmt")) {
                @call(.auto, Impl.textFmt, .{fmt} ++ args);
            }
        }

        // ── Widgets ────────────────────────────────────────────────

        pub inline fn button(str: [*:0]const u8) bool {
            if (@hasDecl(Impl, "button")) return Impl.button(str);
            return false;
        }

        pub inline fn checkbox(str: [*:0]const u8, val: *bool) bool {
            if (@hasDecl(Impl, "checkbox")) return Impl.checkbox(str, val);
            return false;
        }

        pub inline fn sliderFloat(str: [*:0]const u8, val: *f32, min: f32, max: f32) bool {
            if (@hasDecl(Impl, "sliderFloat")) return Impl.sliderFloat(str, val, min, max);
            return false;
        }

        pub inline fn sliderInt(str: [*:0]const u8, val: *i32, min: i32, max: i32) bool {
            if (@hasDecl(Impl, "sliderInt")) return Impl.sliderInt(str, val, min, max);
            return false;
        }

        // ── Tree / collapsing sections ─────────────────────────────

        pub inline fn treeNode(str: [*:0]const u8) bool {
            if (@hasDecl(Impl, "treeNode")) return Impl.treeNode(str);
            return false;
        }

        pub inline fn treePop() void {
            if (@hasDecl(Impl, "treePop")) Impl.treePop();
        }

        // ── Tables ─────────────────────────────────────────────────

        pub inline fn beginTable(str: [*:0]const u8, columns: i32) bool {
            if (@hasDecl(Impl, "beginTable")) return Impl.beginTable(str, columns);
            return false;
        }

        pub inline fn endTable() void {
            if (@hasDecl(Impl, "endTable")) Impl.endTable();
        }

        pub inline fn tableNextRow() void {
            if (@hasDecl(Impl, "tableNextRow")) Impl.tableNextRow();
        }

        pub inline fn tableNextColumn() bool {
            if (@hasDecl(Impl, "tableNextColumn")) return Impl.tableNextColumn();
            return false;
        }

        // ── Dev overlay (legacy) ──────────────────────────────────

        pub inline fn devOverlay(fps: i32, entity_count: u32, draw_calls: u32) void {
            if (@hasDecl(Impl, "devOverlay")) Impl.devOverlay(fps, entity_count, draw_calls);
        }

        // ── Capability check ──────────────────────────────────────

        /// Returns true if the backend supports standard widget rendering.
        /// Debug plugins can check this to know if they can render.
        pub fn supportsWidgets() bool {
            return @hasDecl(Impl, "beginWindow") and
                @hasDecl(Impl, "button") and
                @hasDecl(Impl, "label");
        }
    };
}

/// Stub GUI for testing — all methods are no-ops.
pub const StubGui = struct {
    pub fn begin() void {}
    pub fn end() void {}
    pub fn wantsMouse() bool {
        return false;
    }
    pub fn wantsKeyboard() bool {
        return false;
    }
};
