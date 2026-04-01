/// Comptime-validated input interface.
/// The assembler provides the concrete Impl (raylib, sokol, etc.).
/// Both engine and plugins use this for zero-cost dispatch.
///
/// **Coordinate convention:** Mouse and touch positions returned by backend
/// implementations are in screen coordinates (Y-down, origin at top-left).
/// Callers should use `coordinates.screenToGame` to convert these to game
/// coordinates (Y-up) before using them in game logic.
pub fn InputInterface(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "isKeyDown")) @compileError("Input impl must define 'isKeyDown'");
        if (!@hasDecl(Impl, "isKeyPressed")) @compileError("Input impl must define 'isKeyPressed'");
    }

    return struct {
        pub const Implementation = Impl;

        // ── Keyboard ──────────────────────────────────────────────

        pub inline fn isKeyDown(key: u32) bool {
            return Impl.isKeyDown(key);
        }

        pub inline fn isKeyPressed(key: u32) bool {
            return Impl.isKeyPressed(key);
        }

        pub inline fn isKeyReleased(key: u32) bool {
            if (@hasDecl(Impl, "isKeyReleased")) return Impl.isKeyReleased(key);
            return false;
        }

        // ── Mouse ─────────────────────────────────────────────────

        pub inline fn getMouseX() f32 {
            if (@hasDecl(Impl, "getMouseX")) return Impl.getMouseX();
            return 0;
        }

        pub inline fn getMouseY() f32 {
            if (@hasDecl(Impl, "getMouseY")) return Impl.getMouseY();
            return 0;
        }

        pub inline fn isMouseButtonDown(button: u32) bool {
            if (@hasDecl(Impl, "isMouseButtonDown")) return Impl.isMouseButtonDown(button);
            return false;
        }

        pub inline fn isMouseButtonPressed(button: u32) bool {
            if (@hasDecl(Impl, "isMouseButtonPressed")) return Impl.isMouseButtonPressed(button);
            return false;
        }

        pub inline fn isMouseButtonReleased(button: u32) bool {
            if (@hasDecl(Impl, "isMouseButtonReleased")) return Impl.isMouseButtonReleased(button);
            return false;
        }

        pub inline fn getMouseWheelMove() f32 {
            if (@hasDecl(Impl, "getMouseWheelMove")) return Impl.getMouseWheelMove();
            return 0;
        }

        // ── Touch ─────────────────────────────────────────────────

        pub inline fn getTouchCount() u32 {
            if (@hasDecl(Impl, "getTouchCount")) return Impl.getTouchCount();
            return 0;
        }

        pub inline fn getTouchX(index: u32) f32 {
            if (@hasDecl(Impl, "getTouchX")) return Impl.getTouchX(index);
            return 0;
        }

        pub inline fn getTouchY(index: u32) f32 {
            if (@hasDecl(Impl, "getTouchY")) return Impl.getTouchY(index);
            return 0;
        }

        pub inline fn getTouchId(index: u32) u64 {
            if (@hasDecl(Impl, "getTouchId")) return Impl.getTouchId(index);
            return 0;
        }

        // ── Gamepad ───────────────────────────────────────────────

        pub inline fn isGamepadAvailable(gamepad: u32) bool {
            if (@hasDecl(Impl, "isGamepadAvailable")) return Impl.isGamepadAvailable(gamepad);
            return false;
        }

        pub inline fn isGamepadButtonDown(gamepad: u32, button: u32) bool {
            if (@hasDecl(Impl, "isGamepadButtonDown")) return Impl.isGamepadButtonDown(gamepad, button);
            return false;
        }

        pub inline fn isGamepadButtonPressed(gamepad: u32, button: u32) bool {
            if (@hasDecl(Impl, "isGamepadButtonPressed")) return Impl.isGamepadButtonPressed(gamepad, button);
            return false;
        }

        pub inline fn getGamepadAxisValue(gamepad: u32, axis: u32) f32 {
            if (@hasDecl(Impl, "getGamepadAxisValue")) return Impl.getGamepadAxisValue(gamepad, axis);
            return 0;
        }

        // ── Gestures ─────────────────────────────────────────────

        /// Poll/update gesture recognition state. Mobile backends with
        /// touch-gesture support implement this; others safely no-op.
        pub inline fn updateGestures(dt: f32) void {
            if (@hasDecl(Impl, "updateGestures")) Impl.updateGestures(dt);
        }
    };
}

/// Stub input for testing — all methods return false/zero.
pub const StubInput = struct {
    pub fn isKeyDown(_: u32) bool { return false; }
    pub fn isKeyPressed(_: u32) bool { return false; }
    pub fn isKeyReleased(_: u32) bool { return false; }
    pub fn getMouseX() f32 { return 0; }
    pub fn getMouseY() f32 { return 0; }
    pub fn isMouseButtonDown(_: u32) bool { return false; }
    pub fn isMouseButtonPressed(_: u32) bool { return false; }
    pub fn isMouseButtonReleased(_: u32) bool { return false; }
    pub fn getMouseWheelMove() f32 { return 0; }
    pub fn getTouchCount() u32 { return 0; }
    pub fn getTouchX(_: u32) f32 { return 0; }
    pub fn getTouchY(_: u32) f32 { return 0; }
    pub fn getTouchId(_: u32) u64 { return 0; }
    pub fn isGamepadAvailable(_: u32) bool { return false; }
    pub fn isGamepadButtonDown(_: u32, _: u32) bool { return false; }
    pub fn isGamepadButtonPressed(_: u32, _: u32) bool { return false; }
    pub fn getGamepadAxisValue(_: u32, _: u32) f32 { return 0; }
};
