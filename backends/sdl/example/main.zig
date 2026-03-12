/// LaBelle v2 — SDL2 Backend Comprehensive Demo
///
/// Showcases all four backend modules (gfx, audio, input, window) with:
///   - Player movement (WASD / arrow keys)
///   - 3 patrolling enemies with alpha pulsing
///   - Static ground platforms
///   - Spinning color-cycling hexagon
///   - Orbiting circle using sin/cos
///   - Camera follow with smooth lerp + mouse-wheel zoom
///   - Gizmo overlay (toggle with G): bounding boxes, labels, velocity arrows, grid
///   - HUD layer (screen-space text, not affected by camera)
///   - Audio API demo (Space = sound, M = music toggle)
///   - Escape to quit, R to reset camera
const std = @import("std");
const gfx = @import("gfx");
const input = @import("input");
const audio = @import("audio");
const window = @import("window");
const sdl = @import("sdl");
const c = sdl.c;

// ── Constants ────────────────────────────────────────────────────────────

const SCREEN_W: i32 = 800;
const SCREEN_H: i32 = 600;
const PLAYER_SIZE: f32 = 60;
const PLAYER_SPEED: f32 = 200;
const ENEMY_RADIUS: f32 = 20;
const ENEMY_SPEED: f32 = 80;
const ORBIT_RADIUS: f32 = 80;
const ORBIT_SPEED: f32 = 2.0;
const HEXAGON_SIZE: f32 = 30;
const CAMERA_LERP: f32 = 0.08;
const ZOOM_SPEED: f32 = 0.1;
const MIN_ZOOM: f32 = 0.3;
const MAX_ZOOM: f32 = 3.0;
const GRID_SPACING: f32 = 100;

// ── Entity types ─────────────────────────────────────────────────────────

const Enemy = struct {
    x: f32,
    y: f32,
    min_x: f32,
    max_x: f32,
    vx: f32,
    alpha_phase: f32,
};

const Platform = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

// ── Application state ────────────────────────────────────────────────────

const State = struct {
    // Player
    player_x: f32 = 370,
    player_y: f32 = 300,
    player_vx: f32 = 0,
    player_vy: f32 = 0,
    player_moving: bool = false,
    player_color_phase: f32 = 0,

    // Enemies
    enemies: [3]Enemy = .{
        .{ .x = 150, .y = 400, .min_x = 50, .max_x = 300, .vx = ENEMY_SPEED, .alpha_phase = 0 },
        .{ .x = 500, .y = 200, .min_x = 400, .max_x = 700, .vx = -ENEMY_SPEED, .alpha_phase = 2.0 },
        .{ .x = 350, .y = 100, .min_x = 200, .max_x = 550, .vx = ENEMY_SPEED, .alpha_phase = 4.0 },
    },

    // Platforms
    platforms: [4]Platform = .{
        .{ .x = 0, .y = 500, .w = 800, .h = 40 }, // ground
        .{ .x = 100, .y = 380, .w = 200, .h = 20 }, // left ledge
        .{ .x = 500, .y = 300, .w = 200, .h = 20 }, // right ledge
        .{ .x = 280, .y = 180, .w = 240, .h = 20 }, // top ledge
    },

    // Spinning hexagon
    hex_angle: f32 = 0,
    hex_color_phase: f32 = 0,

    // Orbiter
    orbit_angle: f32 = 0,

    // Camera
    camera: gfx.Camera2D = .{
        .offset = .{ .x = @as(f32, @floatFromInt(SCREEN_W)) / 2.0, .y = @as(f32, @floatFromInt(SCREEN_H)) / 2.0 },
        .target = .{ .x = 400, .y = 300 },
        .rotation = 0,
        .zoom = 1.0,
    },

    // Toggles
    gizmos_on: bool = false,
    music_playing: bool = false,

    // Audio handles (0 = not loaded)
    sound_id: u32 = 0,
    music_id: u32 = 0,

    // Frame counter for FPS display
    frame_count: u64 = 0,
    time_accum: f32 = 0,
    display_fps: u32 = 60,

    // Atlas / animation
    atlas_texture: ?gfx.Texture = null,
    anim_state: AnimState = .idle,
    anim_timer: f32 = 0,
    anim_frame: usize = 0,
    facing_left: bool = false,

    // Fmt buffers for HUD text (static storage so pointers survive the frame)
    fps_buf: [64:0]u8 = undefined,
    pos_buf: [64:0]u8 = undefined,
    zoom_buf: [64:0]u8 = undefined,
    audio_buf: [64:0]u8 = undefined,
};

const AnimState = enum { idle, walk, run, jump };
const Frame = struct { x: f32, y: f32, w: f32, h: f32 };

const idle_frames = [_]Frame{
    .{ .x = 1, .y = 1, .w = 32, .h = 32 },
    .{ .x = 35, .y = 1, .w = 32, .h = 32 },
    .{ .x = 1, .y = 1, .w = 32, .h = 32 },
    .{ .x = 35, .y = 1, .w = 32, .h = 32 },
};
const walk_frames = [_]Frame{
    .{ .x = 76, .y = 34, .w = 19, .h = 29 },
    .{ .x = 97, .y = 1, .w = 29, .h = 19 },
    .{ .x = 97, .y = 22, .w = 29, .h = 19 },
    .{ .x = 76, .y = 34, .w = 19, .h = 29 },
    .{ .x = 97, .y = 1, .w = 29, .h = 19 },
    .{ .x = 97, .y = 22, .w = 29, .h = 19 },
};
const run_frames = [_]Frame{
    .{ .x = 43, .y = 35, .w = 31, .h = 23 },
    .{ .x = 69, .y = 1, .w = 23, .h = 31 },
    .{ .x = 43, .y = 35, .w = 31, .h = 23 },
    .{ .x = 69, .y = 1, .w = 23, .h = 31 },
};
const jump_frames = [_]Frame{
    .{ .x = 97, .y = 43, .w = 23, .h = 19 },
    .{ .x = 22, .y = 35, .w = 19, .h = 25 },
    .{ .x = 1, .y = 35, .w = 19, .h = 27 },
    .{ .x = 22, .y = 35, .w = 19, .h = 25 },
};
const anim_durations = [4]f32{ 0.15, 0.1, 0.08, 0.12 };

fn getCurrentFrames() []const Frame {
    return switch (state.anim_state) {
        .idle => &idle_frames,
        .walk => &walk_frames,
        .run => &run_frames,
        .jump => &jump_frames,
    };
}

fn getAnimDuration() f32 {
    return anim_durations[@intFromEnum(state.anim_state)];
}

var state: State = .{};

// ── Helpers ──────────────────────────────────────────────────────────────

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn fmtZ(buf: []u8, comptime fmt: []const u8, args: anytype) [:0]const u8 {
    const written = std.fmt.bufPrint(buf, fmt, args) catch buf[0..0];
    // Ensure zero-termination using the sentinel already in the array type.
    // Since buf comes from a [N:0]u8 field, buf[written.len] is valid.
    buf[written.len] = 0;
    return buf[0..written.len :0];
}

fn sinF(angle: f32) f32 {
    return @sin(angle);
}

fn cosF(angle: f32) f32 {
    return @cos(angle);
}

/// Draw a regular polygon (n-gon) at (cx, cy) with given radius, rotation, and color.
/// Uses drawLine segments to form the outline.
fn drawPolygon(cx: f32, cy: f32, radius: f32, sides: u32, rotation: f32, tint: gfx.Color) void {
    const n: f32 = @floatFromInt(sides);
    var i: u32 = 0;
    while (i < sides) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const angle1 = rotation + fi * (2.0 * std.math.pi / n);
        const angle2 = rotation + (fi + 1.0) * (2.0 * std.math.pi / n);
        const x1 = cx + cosF(angle1) * radius;
        const y1 = cy + sinF(angle1) * radius;
        const x2 = cx + cosF(angle2) * radius;
        const y2 = cy + sinF(angle2) * radius;
        gfx.drawLine(x1, y1, x2, y2, 1.0, tint);
    }
}

/// Draw a filled polygon by drawing horizontal-ish line fans from center.
fn drawFilledPolygon(cx: f32, cy: f32, radius: f32, sides: u32, rotation: f32, tint: gfx.Color) void {
    // Approximate fill: draw lines from center to each vertex
    const n: f32 = @floatFromInt(sides);
    // Draw triangles as line fans from center
    var i: u32 = 0;
    while (i < sides) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const angle1 = rotation + fi * (2.0 * std.math.pi / n);
        const angle2 = rotation + (fi + 1.0) * (2.0 * std.math.pi / n);
        // Fill triangle (cx,cy)-(x1,y1)-(x2,y2) with lines
        const steps: u32 = 20;
        var s: u32 = 0;
        while (s <= steps) : (s += 1) {
            const t: f32 = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
            const ax = cx + cosF(angle1) * radius * t;
            const ay = cy + sinF(angle1) * radius * t;
            const bx = cx + cosF(angle2) * radius * t;
            const by = cy + sinF(angle2) * radius * t;
            gfx.drawLine(ax, ay, bx, by, 1.0, tint);
        }
    }
}

// ── Update ───────────────────────────────────────────────────────────────

fn update(dt: f32) void {
    // -- Player input --
    state.player_vx = 0;
    state.player_vy = 0;
    state.player_moving = false;

    if (input.isKeyDown(c.SDL_SCANCODE_W) or input.isKeyDown(c.SDL_SCANCODE_UP)) {
        state.player_vy = -PLAYER_SPEED;
        state.player_moving = true;
    }
    if (input.isKeyDown(c.SDL_SCANCODE_S) or input.isKeyDown(c.SDL_SCANCODE_DOWN)) {
        state.player_vy = PLAYER_SPEED;
        state.player_moving = true;
    }
    if (input.isKeyDown(c.SDL_SCANCODE_A) or input.isKeyDown(c.SDL_SCANCODE_LEFT)) {
        state.player_vx = -PLAYER_SPEED;
        state.player_moving = true;
    }
    if (input.isKeyDown(c.SDL_SCANCODE_D) or input.isKeyDown(c.SDL_SCANCODE_RIGHT)) {
        state.player_vx = PLAYER_SPEED;
        state.player_moving = true;
    }

    state.player_x += state.player_vx * dt;
    state.player_y += state.player_vy * dt;

    // Player color cycling when moving
    if (state.player_moving) {
        state.player_color_phase += dt * 4.0;
    }

    // -- Toggle gizmos --
    if (input.isKeyPressed(c.SDL_SCANCODE_G)) {
        state.gizmos_on = !state.gizmos_on;
    }

    // -- Reset camera --
    if (input.isKeyPressed(c.SDL_SCANCODE_R)) {
        state.camera.zoom = 1.0;
    }

    // -- Audio controls --
    if (input.isKeyPressed(c.SDL_SCANCODE_SPACE)) {
        if (state.sound_id != 0) {
            audio.playSound(state.sound_id);
        }
    }
    if (input.isKeyPressed(c.SDL_SCANCODE_M)) {
        if (state.music_id != 0) {
            if (state.music_playing) {
                audio.stopMusic(state.music_id);
                state.music_playing = false;
            } else {
                audio.playMusic(state.music_id);
                state.music_playing = true;
            }
        }
    }

    // -- Escape to quit --
    if (input.isKeyPressed(c.SDL_SCANCODE_ESCAPE)) {
        // Signal quit by moving window state (no direct setShouldClose; we just exit)
        // The windowShouldClose check already covers SDL_QUIT events.
        // We can call closeWindow in the main loop exit path.
        return; // handled in main loop
    }

    // -- Enemy patrol --
    for (&state.enemies) |*enemy| {
        enemy.x += enemy.vx * dt;
        if (enemy.x > enemy.max_x) {
            enemy.x = enemy.max_x;
            enemy.vx = -enemy.vx;
        }
        if (enemy.x < enemy.min_x) {
            enemy.x = enemy.min_x;
            enemy.vx = -enemy.vx;
        }
        // Alpha pulsing
        enemy.alpha_phase += dt * 3.0;
    }

    // -- Spinning hexagon --
    state.hex_angle += dt * 1.5;
    state.hex_color_phase += dt * 2.0;

    // -- Orbiter --
    state.orbit_angle += ORBIT_SPEED * dt;

    // -- Camera follow with lerp --
    const player_center_x = state.player_x + PLAYER_SIZE / 2.0;
    const player_center_y = state.player_y + PLAYER_SIZE / 2.0;
    state.camera.target.x = lerp(state.camera.target.x, player_center_x, CAMERA_LERP);
    state.camera.target.y = lerp(state.camera.target.y, player_center_y, CAMERA_LERP);

    // -- Mouse wheel zoom --
    const wheel = input.getMouseWheelMove();
    if (wheel != 0) {
        state.camera.zoom += wheel * ZOOM_SPEED;
        if (state.camera.zoom < MIN_ZOOM) state.camera.zoom = MIN_ZOOM;
        if (state.camera.zoom > MAX_ZOOM) state.camera.zoom = MAX_ZOOM;
    }

    // -- Animation state --
    const speed_sq = state.player_vx * state.player_vx + state.player_vy * state.player_vy;
    const new_anim: AnimState = if (speed_sq > 40000) .run else if (speed_sq > 100) .walk else .idle;
    if (new_anim != state.anim_state) {
        state.anim_state = new_anim;
        state.anim_frame = 0;
        state.anim_timer = 0;
    }
    if (state.player_vx > 10) state.facing_left = false;
    if (state.player_vx < -10) state.facing_left = true;
    state.anim_timer += dt;
    if (state.anim_timer >= getAnimDuration()) {
        state.anim_timer -= getAnimDuration();
        const frames = getCurrentFrames();
        state.anim_frame = (state.anim_frame + 1) % frames.len;
    }

    // -- FPS counter --
    state.frame_count += 1;
    state.time_accum += dt;
    if (state.time_accum >= 1.0) {
        state.display_fps = @intCast(state.frame_count);
        state.frame_count = 0;
        state.time_accum -= 1.0;
    }
}

// ── Draw (world space) ───────────────────────────────────────────────────

fn drawWorld() void {
    // -- Grid (background layer) --
    const grid_color = gfx.color(60, 60, 80, 100);
    const world_min_x: f32 = -500;
    const world_max_x: f32 = 1300;
    const world_min_y: f32 = -300;
    const world_max_y: f32 = 900;

    // Vertical lines
    var gx: f32 = world_min_x;
    while (gx <= world_max_x) : (gx += GRID_SPACING) {
        gfx.drawLine(gx, world_min_y, gx, world_max_y, 1.0, grid_color);
    }
    // Horizontal lines
    var gy: f32 = world_min_y;
    while (gy <= world_max_y) : (gy += GRID_SPACING) {
        gfx.drawLine(world_min_x, gy, world_max_x, gy, 1.0, grid_color);
    }

    // -- Platforms (world layer) --
    const platform_color = gfx.color(140, 140, 150, 255);
    for (state.platforms) |plat| {
        gfx.drawRectangleRec(.{ .x = plat.x, .y = plat.y, .width = plat.w, .height = plat.h }, platform_color);
    }

    // -- Enemies (world layer) --
    for (&state.enemies) |*enemy| {
        const alpha_val: f32 = (sinF(enemy.alpha_phase) + 1.0) / 2.0; // 0..1
        const a: u8 = @intFromFloat(100.0 + alpha_val * 155.0); // 100..255
        gfx.drawCircle(enemy.x, enemy.y, ENEMY_RADIUS, gfx.color(220, 50, 50, a));
    }

    // -- Player (world layer) — atlas sprite or fallback rectangle --
    if (state.atlas_texture) |tex| {
        const frames = getCurrentFrames();
        const f = frames[state.anim_frame % frames.len];
        const scale: f32 = 3.0;
        const draw_w = f.w * scale;
        const draw_h = f.h * scale;
        const src_w: f32 = if (state.facing_left) -f.w else f.w;
        gfx.drawTexturePro(
            tex,
            .{ .x = f.x, .y = f.y, .width = src_w, .height = f.h },
            .{ .x = state.player_x, .y = state.player_y, .width = draw_w, .height = draw_h },
            .{ .x = 0, .y = 0 },
            0,
            gfx.color(255, 255, 255, 255),
        );
    } else {
        const green_shift: u8 = @intFromFloat(180.0 + sinF(state.player_color_phase) * 75.0);
        const player_color = gfx.color(30, green_shift, 50, 255);
        gfx.drawRectangleRec(.{
            .x = state.player_x,
            .y = state.player_y,
            .width = PLAYER_SIZE,
            .height = PLAYER_SIZE,
        }, player_color);
    }

    // -- Spinning hexagon (effects layer) --
    const hex_cx: f32 = 650;
    const hex_cy: f32 = 120;
    const hr: u8 = @intFromFloat(128.0 + sinF(state.hex_color_phase) * 127.0);
    const hg: u8 = @intFromFloat(128.0 + sinF(state.hex_color_phase + 2.0) * 127.0);
    const hb: u8 = @intFromFloat(128.0 + sinF(state.hex_color_phase + 4.0) * 127.0);
    drawFilledPolygon(hex_cx, hex_cy, HEXAGON_SIZE, 6, state.hex_angle, gfx.color(hr, hg, hb, 220));
    drawPolygon(hex_cx, hex_cy, HEXAGON_SIZE, 6, state.hex_angle, gfx.color(255, 255, 255, 180));

    // -- Orbiter (effects layer) --
    const player_center_x = state.player_x + PLAYER_SIZE / 2.0;
    const player_center_y = state.player_y + PLAYER_SIZE / 2.0;
    const orb_x = player_center_x + cosF(state.orbit_angle) * ORBIT_RADIUS;
    const orb_y = player_center_y + sinF(state.orbit_angle) * ORBIT_RADIUS;
    gfx.drawCircle(orb_x, orb_y, 12, gfx.color(80, 160, 255, 200));
    // Trail dots
    var ti: u32 = 1;
    while (ti <= 5) : (ti += 1) {
        const trail_angle = state.orbit_angle - @as(f32, @floatFromInt(ti)) * 0.3;
        const tx = player_center_x + cosF(trail_angle) * ORBIT_RADIUS;
        const ty = player_center_y + sinF(trail_angle) * ORBIT_RADIUS;
        const trail_alpha: u8 = @intFromFloat(200.0 - @as(f32, @floatFromInt(ti)) * 35.0);
        gfx.drawCircle(tx, ty, 5, gfx.color(60, 120, 220, trail_alpha));
    }

    // -- Gizmo overlay (when toggled) --
    if (state.gizmos_on) {
        drawGizmos();
    }
}

// ── Gizmo overlay ────────────────────────────────────────────────────────

fn drawGizmos() void {
    const gizmo_color = gfx.color(255, 255, 0, 180);
    const label_color = gfx.color(255, 255, 100, 220);

    // Player bounding box + label
    drawBoundingBox(state.player_x, state.player_y, PLAYER_SIZE, PLAYER_SIZE, gizmo_color);
    gfx.drawText("PLAYER", state.player_x, state.player_y - 14, 10, label_color);

    // Player velocity arrow
    if (state.player_moving) {
        const pcx = state.player_x + PLAYER_SIZE / 2.0;
        const pcy = state.player_y + PLAYER_SIZE / 2.0;
        const arrow_scale: f32 = 0.3;
        gfx.drawLine(pcx, pcy, pcx + state.player_vx * arrow_scale, pcy + state.player_vy * arrow_scale, 2.0, gfx.color(0, 255, 0, 200));
    }

    // Enemy bounding boxes + labels + velocity arrows
    for (&state.enemies, 0..) |*enemy, idx| {
        const ex = enemy.x - ENEMY_RADIUS;
        const ey = enemy.y - ENEMY_RADIUS;
        const sz = ENEMY_RADIUS * 2.0;
        drawBoundingBox(ex, ey, sz, sz, gfx.color(255, 100, 100, 180));

        var label_buf: [32:0]u8 = undefined;
        const label = fmtZ(&label_buf, "ENEMY {d}", .{idx});
        gfx.drawText(label, enemy.x - 20, enemy.y - ENEMY_RADIUS - 14, 10, label_color);

        // Velocity arrow
        const arrow_scale: f32 = 0.4;
        gfx.drawLine(enemy.x, enemy.y, enemy.x + enemy.vx * arrow_scale, enemy.y, 2.0, gfx.color(255, 100, 100, 200));
    }

    // Platform labels
    for (state.platforms, 0..) |plat, idx| {
        var label_buf: [32:0]u8 = undefined;
        const label = fmtZ(&label_buf, "PLAT {d}", .{idx});
        gfx.drawText(label, plat.x + 4, plat.y - 12, 10, gfx.color(180, 180, 200, 180));
    }

    // Hexagon bounding box
    drawBoundingBox(650 - HEXAGON_SIZE, 120 - HEXAGON_SIZE, HEXAGON_SIZE * 2, HEXAGON_SIZE * 2, gfx.color(200, 100, 255, 150));
    gfx.drawText("HEXAGON", 650 - 25, 120 - HEXAGON_SIZE - 14, 10, label_color);
}

fn drawBoundingBox(x: f32, y: f32, w: f32, h: f32, tint: gfx.Color) void {
    // Top
    gfx.drawLine(x, y, x + w, y, 1.0, tint);
    // Bottom
    gfx.drawLine(x, y + h, x + w, y + h, 1.0, tint);
    // Left
    gfx.drawLine(x, y, x, y + h, 1.0, tint);
    // Right
    gfx.drawLine(x + w, y, x + w, y + h, 1.0, tint);
}

// ── Draw (screen space / HUD) ───────────────────────────────────────────

fn drawHUD() void {
    const white = gfx.color(255, 255, 255, 255);
    const dim = gfx.color(180, 180, 180, 200);
    const highlight = gfx.color(100, 255, 150, 255);

    // Title
    gfx.drawText("LaBelle v2 - SDL2 Backend Demo", 10, 10, 20, highlight);

    // FPS
    const fps_text = fmtZ(&state.fps_buf, "FPS: {d}", .{state.display_fps});
    gfx.drawText(fps_text, 10, 36, 14, white);

    // Player position
    const pos_text = fmtZ(&state.pos_buf, "Pos: {d},{d}", .{
        @as(i32, @intFromFloat(state.player_x)),
        @as(i32, @intFromFloat(state.player_y)),
    });
    gfx.drawText(pos_text, 10, 54, 14, white);

    // Zoom
    const zoom_pct: i32 = @intFromFloat(state.camera.zoom * 100.0);
    const zoom_text = fmtZ(&state.zoom_buf, "Zoom: {d}%", .{zoom_pct});
    gfx.drawText(zoom_text, 10, 72, 14, white);

    // Audio state
    const audio_label: [:0]const u8 = if (state.music_id != 0)
        (if (state.music_playing) "Music: PLAYING" else "Music: STOPPED")
    else
        "Music: (no file)";
    gfx.drawText(audio_label, 10, 90, 14, white);

    // Gizmo state
    const gizmo_label: [:0]const u8 = if (state.gizmos_on) "Gizmos: ON" else "Gizmos: OFF";
    gfx.drawText(gizmo_label, 10, 108, 14, white);

    // Controls help (bottom-left)
    const base_y: f32 = @as(f32, @floatFromInt(SCREEN_H)) - 100;
    gfx.drawText("--- Controls ---", 10, base_y, 12, dim);
    gfx.drawText("WASD/Arrows: Move", 10, base_y + 16, 12, dim);
    gfx.drawText("Mouse Wheel: Zoom", 10, base_y + 30, 12, dim);
    gfx.drawText("G: Toggle Gizmos", 10, base_y + 44, 12, dim);
    gfx.drawText("R: Reset Camera Zoom", 10, base_y + 58, 12, dim);
    gfx.drawText("Space: Play Sound  M: Toggle Music", 10, base_y + 72, 12, dim);
    gfx.drawText("Escape: Quit", 10, base_y + 86, 12, dim);
}

// ── Entry point ──────────────────────────────────────────────────────────

pub fn main() void {
    // Initialize window and renderer
    window.initWindow(SCREEN_W, SCREEN_H, "LaBelle v2 - SDL2 Backend Demo");
    window.setTargetFPS(60);

    // Load character atlas
    state.atlas_texture = gfx.loadTexture("assets/characters.bmp") catch null;

    // Attempt to load audio assets (gracefully returns 0 if files not found)
    state.sound_id = audio.loadSound("assets/jump.wav");
    state.music_id = audio.loadMusic("assets/music.ogg");

    const dt: f32 = 1.0 / 60.0;

    // Main loop
    while (!window.windowShouldClose()) {
        // Check escape before/after input polling
        if (input.isKeyPressed(c.SDL_SCANCODE_ESCAPE)) break;

        window.beginDrawing();
        window.clearBackground(30, 30, 46, 255);

        // Update game state
        update(dt);

        // World-space rendering (affected by camera)
        gfx.beginMode2D(state.camera);
        drawWorld();
        gfx.endMode2D();

        // Screen-space HUD (not affected by camera)
        drawHUD();

        window.endDrawing();
    }

    // Cleanup
    if (state.atlas_texture) |tex| gfx.unloadTexture(tex);
    if (state.sound_id != 0) audio.unloadSound(state.sound_id);
    if (state.music_id != 0) audio.unloadMusic(state.music_id);
    window.closeWindow();
}
