/// SDL2 window backend — windowing lifecycle functions.
const c = @import("sdl").c;
const audio = @import("audio");
const gfx = @import("gfx");
const input = @import("input");

pub const ConfigFlags = struct {
    window_hidden: bool = false,
};

var sdl_window: ?*c.SDL_Window = null;
var should_close: bool = false;
var target_fps_val: i32 = 60;
var last_frame_time: u64 = 0;
var window_hidden: bool = false;

pub fn setConfigFlags(flags: ConfigFlags) void {
    window_hidden = flags.window_hidden;
}

pub fn initWindow(width: i32, height: i32, title: [:0]const u8) void {
    _ = c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO);
    const window_flags: u32 = if (window_hidden) c.SDL_WINDOW_HIDDEN else c.SDL_WINDOW_SHOWN;
    sdl_window = c.SDL_CreateWindow(
        title.ptr,
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        width,
        height,
        window_flags,
    );
    if (sdl_window) |win| {
        const renderer = c.SDL_CreateRenderer(win, -1, c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC);
        gfx.sdl_renderer = renderer;
        gfx.setScreenSize(width, height);
    }
    last_frame_time = c.SDL_GetPerformanceCounter();
}

pub fn closeWindow() void {
    audio.deinit(); // close mixer before SDL_Quit
    gfx.cleanup(); // release textures before destroying the renderer
    if (gfx.sdl_renderer) |r| c.SDL_DestroyRenderer(r);
    if (sdl_window) |w| c.SDL_DestroyWindow(w);
    c.SDL_Quit();
    gfx.sdl_renderer = null;
    sdl_window = null;
}

pub fn windowShouldClose() bool {
    return should_close;
}

pub fn setTargetFPS(fps: i32) void {
    target_fps_val = fps;
}

pub fn beginDrawing() void {
    input.newFrame();
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event) != 0) {
        if (event.type == c.SDL_QUIT) {
            should_close = true;
        }
        input.handleEvent(&event);
    }
}

pub fn endDrawing() void {
    if (gfx.sdl_renderer) |r| c.SDL_RenderPresent(r);

    // Frame timing
    if (target_fps_val > 0) {
        const freq = c.SDL_GetPerformanceFrequency();
        const now = c.SDL_GetPerformanceCounter();
        const elapsed = now - last_frame_time;
        const target_ticks = freq / @as(u64, @intCast(target_fps_val));
        if (elapsed < target_ticks) {
            const delay_ms: u32 = @intCast((target_ticks - elapsed) * 1000 / freq);
            c.SDL_Delay(delay_ms);
        }
        last_frame_time = c.SDL_GetPerformanceCounter();
    }
}

pub fn clearBackground(r: u8, g: u8, b: u8, a: u8) void {
    if (gfx.sdl_renderer) |ren| {
        _ = c.SDL_SetRenderDrawColor(ren, r, g, b, a);
        _ = c.SDL_RenderClear(ren);
    }
}

pub fn drawText(text: [:0]const u8, x: i32, y: i32, font_size: i32, r: u8, g: u8, b: u8, a: u8) void {
    gfx.drawText(text, @floatFromInt(x), @floatFromInt(y), @floatFromInt(font_size), gfx.color(r, g, b, a));
}
