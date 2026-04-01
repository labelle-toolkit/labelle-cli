/// Comptime-validated audio interface.
/// The assembler provides the concrete Impl (raylib, sokol, miniaudio, etc.).
/// Both engine and plugins use this for zero-cost dispatch.
pub fn AudioInterface(comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "playSound")) @compileError("Audio impl must define 'playSound'");
        if (!@hasDecl(Impl, "stopSound")) @compileError("Audio impl must define 'stopSound'");
    }

    return struct {
        pub const Implementation = Impl;

        // ── Sound effects ──────────────────────────────────────────

        pub inline fn loadSound(path: [:0]const u8) u32 {
            if (@hasDecl(Impl, "loadSound")) return Impl.loadSound(path);
            return 0;
        }

        pub inline fn unloadSound(id: u32) void {
            if (@hasDecl(Impl, "unloadSound")) Impl.unloadSound(id);
        }

        pub inline fn playSound(id: u32) void {
            Impl.playSound(id);
        }

        pub inline fn stopSound(id: u32) void {
            Impl.stopSound(id);
        }

        pub inline fn isSoundPlaying(id: u32) bool {
            if (@hasDecl(Impl, "isSoundPlaying")) return Impl.isSoundPlaying(id);
            return false;
        }

        pub inline fn setSoundVolume(id: u32, volume: f32) void {
            if (@hasDecl(Impl, "setSoundVolume")) Impl.setSoundVolume(id, volume);
        }

        // ── Music (streaming) ──────────────────────────────────────

        pub inline fn loadMusic(path: [:0]const u8) u32 {
            if (@hasDecl(Impl, "loadMusic")) return Impl.loadMusic(path);
            return 0;
        }

        pub inline fn unloadMusic(id: u32) void {
            if (@hasDecl(Impl, "unloadMusic")) Impl.unloadMusic(id);
        }

        pub inline fn playMusic(id: u32) void {
            if (@hasDecl(Impl, "playMusic")) Impl.playMusic(id);
        }

        pub inline fn stopMusic(id: u32) void {
            if (@hasDecl(Impl, "stopMusic")) Impl.stopMusic(id);
        }

        pub inline fn pauseMusic(id: u32) void {
            if (@hasDecl(Impl, "pauseMusic")) Impl.pauseMusic(id);
        }

        pub inline fn resumeMusic(id: u32) void {
            if (@hasDecl(Impl, "resumeMusic")) Impl.resumeMusic(id);
        }

        pub inline fn isMusicPlaying(id: u32) bool {
            if (@hasDecl(Impl, "isMusicPlaying")) return Impl.isMusicPlaying(id);
            return false;
        }

        pub inline fn setMusicVolume(id: u32, volume: f32) void {
            if (@hasDecl(Impl, "setMusicVolume")) Impl.setMusicVolume(id, volume);
        }

        /// Must be called each frame to keep music streams fed.
        pub inline fn updateMusic(id: u32) void {
            if (@hasDecl(Impl, "updateMusic")) Impl.updateMusic(id);
        }

        // ── Global ────────────────────────────────────────────────

        pub inline fn setVolume(volume: f32) void {
            if (@hasDecl(Impl, "setVolume")) Impl.setVolume(volume);
        }

        /// Must be called each frame to keep music streams fed and
        /// perform any per-frame audio housekeeping.
        pub inline fn update() void {
            if (@hasDecl(Impl, "update")) Impl.update();
        }
    };
}

/// Stub audio for testing — all methods are no-ops.
pub const StubAudio = struct {
    pub fn playSound(_: u32) void {}
    pub fn stopSound(_: u32) void {}
    pub fn setVolume(_: f32) void {}
    pub fn loadSound(_: [:0]const u8) u32 { return 0; }
    pub fn unloadSound(_: u32) void {}
    pub fn isSoundPlaying(_: u32) bool { return false; }
    pub fn setSoundVolume(_: u32, _: f32) void {}
    pub fn loadMusic(_: [:0]const u8) u32 { return 0; }
    pub fn unloadMusic(_: u32) void {}
    pub fn playMusic(_: u32) void {}
    pub fn stopMusic(_: u32) void {}
    pub fn pauseMusic(_: u32) void {}
    pub fn resumeMusic(_: u32) void {}
    pub fn isMusicPlaying(_: u32) bool { return false; }
    pub fn setMusicVolume(_: u32, _: f32) void {}
    pub fn updateMusic(_: u32) void {}
    pub fn update() void {}
};
