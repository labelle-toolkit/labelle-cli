/// WebGPU window backend — windowing lifecycle via GLFW + wgpu frame management.
const glfw = @import("zglfw");

// TODO: wire wgpu import once surface/device setup is implemented
// const wgpu = @import("wgpu");

pub const ConfigFlags = struct {
    window_hidden: bool = false,
};

var glfw_window: ?*glfw.Window = null;
var target_fps_val: i32 = 60;
var screen_w: i32 = 800;
var screen_h: i32 = 600;
var window_hidden: bool = false;

pub fn setConfigFlags(flags: ConfigFlags) void {
    window_hidden = flags.window_hidden;
}

pub fn initWindow(width: i32, height: i32, title: [:0]const u8) void {
    screen_w = width;
    screen_h = height;

    glfw.init(.{}) catch return;

    // WebGPU uses GLFW without OpenGL context
    glfw_window = glfw.Window.create(
        @intCast(width),
        @intCast(height),
        title,
        null,
        null,
        .{ .client_api = .no_api, .visible = !window_hidden },
    ) catch return;

    // TODO: Create wgpu surface from GLFW native window handle
    // TODO: Request adapter → device → queue
    // TODO: Configure surface format and present mode
    // TODO: Create render pipelines (shape + sprite)

    const input = @import("input");
    if (glfw_window) |win| {
        input.setWindow(win);
    }
}

pub fn closeWindow() void {
    // TODO: Destroy wgpu resources (pipelines, buffers, device, surface, instance)
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
    // TODO: Get current surface texture, create render pass encoder
}

pub fn endDrawing() void {
    // TODO: End render pass, submit command buffer, present surface
    if (glfw_window) |win| win.swapBuffers();
}

pub fn clearBackground(r: u8, g: u8, b: u8, a: u8) void {
    // wgpu clear is set via render pass load operation
    _ = r;
    _ = g;
    _ = b;
    _ = a;
    // TODO: Store clear color for next beginDrawing pass action
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
    // TODO: Font rendering via wgpu (requires font atlas pipeline)
}
