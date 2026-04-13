/// Sokol window backend — windowing lifecycle via sokol_app.
const builtin = @import("builtin");
const sokol = @import("sokol");
const sapp = sokol.app;
const sg = sokol.gfx;
const sgl = sokol.gl;
const sglue = sokol.glue;
const slog = sokol.log;

pub const ConfigFlags = struct {
    window_hidden: bool = false,
};

/// Set config flags before initialization.
/// Note: sokol_app does not natively support hidden windows. This is a
/// no-op stub for API compatibility; the flag is stored but has no effect
/// on the sokol backend (sokol_app always shows the window).
pub fn setConfigFlags(_: ConfigFlags) void {}

pub fn initGfx() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    sgl.setup(.{
        .logger = .{ .func = slog.func },
    });
}

pub fn shutdownGfx() void {
    sgl.shutdown();
    sg.shutdown();
}

pub fn width() i32 {
    return sapp.width();
}

pub fn height() i32 {
    return sapp.height();
}

/// Duration of the last frame in seconds.
/// Use this for dt in the frame callback instead of a hardcoded value.
pub fn frameDuration() f64 {
    return sapp.frameDuration();
}

pub fn beginFrame() sg.PassAction {
    sgl.defaults();
    var pass_action: sg.PassAction = .{};
    pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.95, .g = 0.95, .b = 0.95, .a = 1.0 },
    };
    return pass_action;
}

pub fn beginPass(pass_action: sg.PassAction) void {
    sg.beginPass(.{ .action = pass_action, .swapchain = sglue.swapchain() });
}

pub fn endFrame() void {
    sgl.draw();
    sg.endPass();
    sg.commit();
}

/// The sokol app descriptor type — re-exported so callers don't need to
/// import sokol directly (used by mobile sokol_main return type).
pub const Desc = sapp.Desc;

/// Build a sokol app descriptor without starting the event loop.
/// Used on mobile targets where sokol calls sokol_main() and reads its
/// return value as sapp_desc — the host must NOT call sapp_run() itself.
pub fn makeDesc(desc: struct {
    init_cb: *const fn () callconv(.c) void,
    frame_cb: *const fn () callconv(.c) void,
    cleanup_cb: *const fn () callconv(.c) void,
    event_cb: ?*const fn ([*c]const sapp.Event) callconv(.c) void = null,
    w: i32 = 800,
    h: i32 = 600,
    title: [:0]const u8 = "LaBelle v2",
}) sapp.Desc {
    // Android emulators typically support GLES 3.0 but not 3.1.
    // Sokol defaults to 3.1 on Android, which causes EGL_BAD_CONFIG on emulators.
    // Request 3.0 explicitly so the app works on both real devices and emulators.
    const is_android = comptime builtin.target.isAndroid();
    return .{
        .init_cb = desc.init_cb,
        .frame_cb = desc.frame_cb,
        .cleanup_cb = desc.cleanup_cb,
        .event_cb = desc.event_cb orelse null,
        .width = desc.w,
        .height = desc.h,
        .window_title = desc.title,
        .gl = if (is_android) .{ .major_version = 3, .minor_version = 0 } else .{},
        .high_dpi = true,
        .logger = .{ .func = slog.func },
    };
}

/// Run the sokol application loop with callbacks.
pub fn run(desc: struct {
    init_cb: *const fn () callconv(.c) void,
    frame_cb: *const fn () callconv(.c) void,
    cleanup_cb: *const fn () callconv(.c) void,
    event_cb: ?*const fn ([*c]const sapp.Event) callconv(.c) void = null,
    w: i32 = 800,
    h: i32 = 600,
    title: [:0]const u8 = "LaBelle v2",
}) void {
    sapp.run(makeDesc(desc));
}
