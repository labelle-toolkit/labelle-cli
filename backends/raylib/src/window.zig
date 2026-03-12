/// Raylib window backend — windowing lifecycle functions.
const rl = @import("raylib");

pub const ConfigFlags = struct {
    window_hidden: bool = false,
};

pub fn setConfigFlags(flags: ConfigFlags) void {
    if (flags.window_hidden) {
        rl.setConfigFlags(.{ .window_hidden = true });
    }
}

pub fn initWindow(width: i32, height: i32, title: [:0]const u8) void {
    rl.initWindow(width, height, title);
    rl.setExitKey(.escape);
}

pub fn closeWindow() void {
    rl.closeWindow();
}

pub fn windowShouldClose() bool {
    return rl.windowShouldClose();
}

pub fn setTargetFPS(fps: i32) void {
    rl.setTargetFPS(fps);
}

pub fn getFrameTime() f32 {
    return rl.getFrameTime();
}

pub fn beginDrawing() void {
    rl.beginDrawing();
}

pub fn endDrawing() void {
    rl.endDrawing();
}

pub fn clearBackground(r: u8, g: u8, b: u8, a: u8) void {
    rl.clearBackground(.{ .r = r, .g = g, .b = b, .a = a });
}

pub fn drawText(text: [:0]const u8, x: i32, y: i32, font_size: i32, r: u8, g: u8, b: u8, a: u8) void {
    rl.drawText(text, x, y, font_size, .{ .r = r, .g = g, .b = b, .a = a });
}

pub fn takeScreenshot(path: [:0]const u8) void {
    rl.takeScreenshot(path);
}
