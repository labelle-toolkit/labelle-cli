/// bgfx window backend — windowing lifecycle via GLFW + bgfx frame management.
const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("zglfw");
const zbgfx = @import("zbgfx");
const bgfx = zbgfx.bgfx;

pub const ConfigFlags = struct {
    window_hidden: bool = false,
};

var glfw_window: ?*glfw.Window = null;
var target_fps_val: i32 = 60;
var screen_w: i32 = 800;
var screen_h: i32 = 600;
var window_hidden: bool = false;
var clear_color: u32 = 0x1e1e2eff; // dark background RGBA

pub fn setConfigFlags(flags: ConfigFlags) void {
    window_hidden = flags.window_hidden;
}

pub fn initWindow(width: i32, height: i32, title: [:0]const u8) void {
    screen_w = width;
    screen_h = height;

    glfw.init() catch return;

    // Tell GLFW not to create an OpenGL context — bgfx manages its own
    glfw.windowHint(.client_api, .no_api);

    glfw_window = glfw.createWindow(
        @intCast(width),
        @intCast(height),
        title,
        null,
        null,
    ) catch return;

    const win = glfw_window orelse return;

    // Initialize bgfx
    var init: bgfx.Init = undefined;
    bgfx.initCtor(&init);

    init.type = .Count; // auto-select renderer
    init.resolution.width = @intCast(width);
    init.resolution.height = @intCast(height);
    init.resolution.reset = 0x00000080; // BGFX_RESET_VSYNC
    init.platformData.ndt = null;
    init.platformData.nwh = glfw.getCocoaWindow(win);
    init.platformData.context = null;
    init.platformData.queue = null;
    init.platformData.backBuffer = null;
    init.platformData.backBufferDS = null;
    init.platformData.type = .Default;

    _ = bgfx.init(&init);

    bgfx.setViewClear(0, 0x0001 | 0x0002, clear_color, 1.0, 0);
    bgfx.setViewRect(0, 0, 0, @intCast(width), @intCast(height));

    const input = @import("input");
    input.setWindow(win);
}

pub fn closeWindow() void {
    bgfx.shutdown();
    if (glfw_window) |win| win.destroy();
    glfw.terminate();
    glfw_window = null;
}

pub fn windowShouldClose() bool {
    if (glfw_window) |win| return win.shouldClose();
    return true;
}

pub fn setTargetFPS(fps: i32) void {
    target_fps_val = fps;
}

pub fn beginDrawing() void {
    const input = @import("input");
    input.newFrame();
    // Touch view 0 to ensure it's processed even if no draw calls occur
    bgfx.setViewRect(0, 0, 0, @intCast(screen_w), @intCast(screen_h));
}

pub fn endDrawing() void {
    _ = bgfx.frame(0);
}

pub fn clearBackground(r: u8, g: u8, b: u8, a: u8) void {
    clear_color = @as(u32, r) << 24 | @as(u32, g) << 16 | @as(u32, b) << 8 | @as(u32, a);
    bgfx.setViewClear(0, 0x0001 | 0x0002, clear_color, 1.0, 0);
}

pub fn drawText(text: [:0]const u8, x: i32, y: i32, font_size: i32, r: u8, g: u8, b: u8, a: u8) void {
    _ = text;
    _ = x;
    _ = y;
    _ = font_size;
    _ = r;
    _ = g;
    _ = b;
    _ = a;
    // bgfx debug text could be used here but requires setDebug(BGFX_DEBUG_TEXT)
}
