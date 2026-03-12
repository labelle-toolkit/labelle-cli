/// LaBelle v2 — Sokol Backend Comprehensive Demo
///
/// Showcases all four Sokol backend modules (gfx, input, audio, window) using
/// the callback-based architecture. Demonstrates:
///
///   - Player movement (WASD / arrow keys) with velocity and friction
///   - 3 patrolling enemies with alpha pulsing
///   - Ground platforms
///   - Spinning hexagon decoration with color cycling
///   - Blue circle orbiting the player
///   - Camera follow with lerp smoothing + mouse wheel zoom + R to reset
///   - Gizmo overlays toggled with G (bounding boxes, labels, velocity lines, grid)
///   - Audio: Space = play sound, M = toggle music
///   - HUD text overlays (screen-space, outside camera transform)
///
const std = @import("std");
const gfx = @import("gfx");
const input = @import("input");
const audio = @import("audio");
const window = @import("window");

// ── Key codes (from sokol Keycode enum) ────────────────────────────────────

const KEY_W: u32 = 87;
const KEY_A: u32 = 65;
const KEY_S: u32 = 83;
const KEY_D: u32 = 68;
const KEY_G: u32 = 71;
const KEY_M: u32 = 77;
const KEY_R: u32 = 82;
const KEY_SPACE: u32 = 32;
const KEY_UP: u32 = 265;
const KEY_DOWN: u32 = 264;
const KEY_LEFT: u32 = 263;
const KEY_RIGHT: u32 = 262;
const KEY_ESCAPE: u32 = 256;

// ── Constants ──────────────────────────────────────────────────────────────

const SCREEN_W: i32 = 800;
const SCREEN_H: i32 = 600;
const PLAYER_SIZE: f32 = 60;
const PLAYER_SPEED: f32 = 300.0;
const FRICTION: f32 = 0.88;
const CAMERA_LERP: f32 = 0.08;
const ZOOM_SPEED: f32 = 0.1;
const MIN_ZOOM: f32 = 0.3;
const MAX_ZOOM: f32 = 3.0;
const ENEMY_RADIUS: f32 = 25;
const ENEMY_COUNT: usize = 3;
const ORBITER_RADIUS: f32 = 15;
const ORBITER_DISTANCE: f32 = 100;
const ORBITER_SPEED: f32 = 2.0;
const HEX_RADIUS: f32 = 40;
const HEX_SPIN_SPEED: f32 = 1.5;
const PI: f32 = 3.14159265;

// ── Enemy state ────────────────────────────────────────────────────────────

const Enemy = struct {
    x: f32,
    y: f32,
    patrol_x_min: f32,
    patrol_x_max: f32,
    speed: f32,
    direction: f32, // 1.0 or -1.0
};

// ── Platform state ─────────────────────────────────────────────────────────

const Platform = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

// ── Application state (module-level for C-calling-convention callbacks) ────

var player_x: f32 = 400;
var player_y: f32 = 300;
var player_vx: f32 = 0;
var player_vy: f32 = 0;

var enemies: [ENEMY_COUNT]Enemy = .{
    .{ .x = 200, .y = 200, .patrol_x_min = 100, .patrol_x_max = 350, .speed = 120, .direction = 1.0 },
    .{ .x = 500, .y = 400, .patrol_x_min = 400, .patrol_x_max = 700, .speed = 80, .direction = -1.0 },
    .{ .x = 300, .y = 500, .patrol_x_min = 150, .patrol_x_max = 500, .speed = 150, .direction = 1.0 },
};

var platforms: [4]Platform = .{
    .{ .x = 0, .y = 550, .w = 800, .h = 50 }, // ground
    .{ .x = 150, .y = 430, .w = 200, .h = 20 }, // floating platform 1
    .{ .x = 450, .y = 350, .w = 200, .h = 20 }, // floating platform 2
    .{ .x = 50, .y = 250, .w = 150, .h = 20 }, // floating platform 3
};

var camera: gfx.Camera2D = .{
    .offset = .{ .x = @as(f32, @floatFromInt(SCREEN_W)) / 2.0, .y = @as(f32, @floatFromInt(SCREEN_H)) / 2.0 },
    .target = .{ .x = 400, .y = 300 },
    .rotation = 0,
    .zoom = 1.0,
};

var frame_counter: u32 = 0;
var color_phase: f32 = 0;
var hex_rotation: f32 = 0;
var orbiter_angle: f32 = 0;
var gizmos_visible: bool = false;
var music_playing: bool = false;

var sound_id: u32 = 0;
var music_id: u32 = 0;

// ── Atlas / animation state ───────────────────────────────────────────────

var atlas_texture: ?gfx.Texture = null;

const AnimState = enum { idle, walk, run, jump };

var anim_state: AnimState = .idle;
var anim_timer: f32 = 0;
var anim_frame: usize = 0;
var facing_left: bool = false;

// Frame rectangles for each animation (source rects in atlas, non-trimmed only for simplicity)
const Frame = struct { x: f32, y: f32, w: f32, h: f32 };

// idle: 4 frames at (1,1), (35,1), (1,1), (35,1) — all 32x32
const idle_frames = [_]Frame{
    .{ .x = 1, .y = 1, .w = 32, .h = 32 },
    .{ .x = 35, .y = 1, .w = 32, .h = 32 },
    .{ .x = 1, .y = 1, .w = 32, .h = 32 },
    .{ .x = 35, .y = 1, .w = 32, .h = 32 },
};
// walk: 6 frames (some trimmed, use full 32x32 source area for simplicity)
const walk_frames = [_]Frame{
    .{ .x = 76, .y = 34, .w = 19, .h = 29 },
    .{ .x = 97, .y = 1, .w = 29, .h = 19 }, // rotated
    .{ .x = 97, .y = 22, .w = 29, .h = 19 }, // rotated
    .{ .x = 76, .y = 34, .w = 19, .h = 29 },
    .{ .x = 97, .y = 1, .w = 29, .h = 19 }, // rotated
    .{ .x = 97, .y = 22, .w = 29, .h = 19 }, // rotated
};
// run: 4 frames
const run_frames = [_]Frame{
    .{ .x = 43, .y = 35, .w = 31, .h = 23 }, // rotated
    .{ .x = 69, .y = 1, .w = 23, .h = 31 },
    .{ .x = 43, .y = 35, .w = 31, .h = 23 }, // rotated
    .{ .x = 69, .y = 1, .w = 23, .h = 31 },
};
// jump: 4 frames
const jump_frames = [_]Frame{
    .{ .x = 97, .y = 43, .w = 23, .h = 19 }, // rotated
    .{ .x = 22, .y = 35, .w = 19, .h = 25 },
    .{ .x = 1, .y = 35, .w = 19, .h = 27 },
    .{ .x = 22, .y = 35, .w = 19, .h = 25 },
};

const anim_durations = [4]f32{ 0.15, 0.1, 0.08, 0.12 };

fn getCurrentFrames() []const Frame {
    return switch (anim_state) {
        .idle => &idle_frames,
        .walk => &walk_frames,
        .run => &run_frames,
        .jump => &jump_frames,
    };
}

fn getAnimDuration() f32 {
    return anim_durations[@intFromEnum(anim_state)];
}

// ── Init callback ──────────────────────────────────────────────────────────

fn init() callconv(.c) void {
    window.initGfx();
    gfx.setScreenSize(SCREEN_W, SCREEN_H);

    // Load character atlas
    atlas_texture = gfx.loadTexture("assets/characters.bmp") catch null;

    // Attempt to load audio assets (gracefully handles missing files)
    sound_id = audio.loadSound("assets/jump.wav");
    music_id = audio.loadMusic("assets/music.wav");
}

// ── Frame callback ─────────────────────────────────────────────────────────

fn frame() callconv(.c) void {
    const dt: f32 = 1.0 / 60.0;
    frame_counter +%= 1;
    color_phase += dt * 2.0;

    // Update screen size from actual window dimensions
    gfx.setScreenSize(window.width(), window.height());

    // ── Input ──────────────────────────────────────────────────────────

    // Player movement (WASD + arrow keys)
    if (input.isKeyDown(KEY_W) or input.isKeyDown(KEY_UP)) player_vy -= PLAYER_SPEED * dt;
    if (input.isKeyDown(KEY_S) or input.isKeyDown(KEY_DOWN)) player_vy += PLAYER_SPEED * dt;
    if (input.isKeyDown(KEY_A) or input.isKeyDown(KEY_LEFT)) player_vx -= PLAYER_SPEED * dt;
    if (input.isKeyDown(KEY_D) or input.isKeyDown(KEY_RIGHT)) player_vx += PLAYER_SPEED * dt;

    // Gizmo toggle
    if (input.isKeyPressed(KEY_G)) gizmos_visible = !gizmos_visible;

    // Camera zoom reset
    if (input.isKeyPressed(KEY_R)) {
        camera.zoom = 1.0;
        camera.target = .{ .x = player_x, .y = player_y };
    }

    // Audio controls
    if (input.isKeyPressed(KEY_SPACE)) {
        if (sound_id != 0) audio.playSound(sound_id);
    }
    if (input.isKeyPressed(KEY_M)) {
        if (music_id != 0) {
            if (music_playing) {
                audio.stopMusic(music_id);
                music_playing = false;
            } else {
                audio.playMusic(music_id);
                music_playing = true;
            }
        }
    }

    // Mouse wheel zoom
    const wheel = input.getMouseWheelMove();
    if (wheel != 0) {
        camera.zoom += wheel * ZOOM_SPEED;
        camera.zoom = std.math.clamp(camera.zoom, MIN_ZOOM, MAX_ZOOM);
    }

    // ── Update ─────────────────────────────────────────────────────────

    // Apply friction and update player position
    player_vx *= FRICTION;
    player_vy *= FRICTION;
    player_x += player_vx * dt;
    player_y += player_vy * dt;

    // Update enemies (horizontal patrol)
    for (&enemies) |*enemy| {
        enemy.x += enemy.speed * enemy.direction * dt;
        if (enemy.x > enemy.patrol_x_max) {
            enemy.x = enemy.patrol_x_max;
            enemy.direction = -1.0;
        } else if (enemy.x < enemy.patrol_x_min) {
            enemy.x = enemy.patrol_x_min;
            enemy.direction = 1.0;
        }
    }

    // Spin the hexagon
    hex_rotation += HEX_SPIN_SPEED * dt;

    // Orbit the blue circle around the player
    orbiter_angle += ORBITER_SPEED * dt;
    if (orbiter_angle > 2.0 * PI) orbiter_angle -= 2.0 * PI;

    // Update animation state based on speed
    const speed_sq = player_vx * player_vx + player_vy * player_vy;
    const new_state: AnimState = if (speed_sq > 40000) .run else if (speed_sq > 400) .walk else .idle;
    if (new_state != anim_state) {
        anim_state = new_state;
        anim_frame = 0;
        anim_timer = 0;
    }

    // Update facing direction
    if (player_vx > 10) facing_left = false;
    if (player_vx < -10) facing_left = true;

    // Advance animation timer
    anim_timer += dt;
    if (anim_timer >= getAnimDuration()) {
        anim_timer -= getAnimDuration();
        const frames = getCurrentFrames();
        anim_frame = (anim_frame + 1) % frames.len;
    }

    // Camera follow with lerp
    camera.target.x += (player_x - camera.target.x) * CAMERA_LERP;
    camera.target.y += (player_y - camera.target.y) * CAMERA_LERP;

    // ── Render ─────────────────────────────────────────────────────────

    const pass_action = window.beginFrame();
    window.beginPass(pass_action);

    // ── World-space drawing (camera transform) ─────────────────────────

    gfx.beginMode2D(camera);

    // Draw platforms (gray)
    for (&platforms) |*plat| {
        gfx.drawRectangleRec(.{ .x = plat.x, .y = plat.y, .width = plat.w, .height = plat.h }, gfx.color(120, 120, 120, 255));
    }

    // Draw enemies (red circles with alpha pulsing)
    for (&enemies, 0..) |*enemy, i| {
        const pulse = @sin(color_phase * 3.0 + @as(f32, @floatFromInt(i)) * 1.5);
        const alpha: u8 = @intFromFloat(std.math.clamp(180.0 + pulse * 75.0, 100.0, 255.0));
        gfx.drawCircle(enemy.x, enemy.y, ENEMY_RADIUS, gfx.color(220, 40, 40, alpha));
    }

    // Draw spinning hexagon at a fixed world position
    drawHexagon(600, 150, HEX_RADIUS, hex_rotation);

    // Draw orbiter (blue circle orbiting the player)
    const orb_x = player_x + @cos(orbiter_angle) * ORBITER_DISTANCE;
    const orb_y = player_y + @sin(orbiter_angle) * ORBITER_DISTANCE;
    gfx.drawCircle(orb_x, orb_y, ORBITER_RADIUS, gfx.color(60, 120, 255, 200));

    // Draw player — atlas sprite if loaded, fallback to colored rectangle
    if (atlas_texture) |tex| {
        const frames = getCurrentFrames();
        const f = frames[anim_frame % frames.len];
        const scale: f32 = 3.0; // scale 32x32 up to 96x96
        const draw_w = f.w * scale;
        const draw_h = f.h * scale;
        // Flip horizontally when facing left by negating source width
        const src_w: f32 = if (facing_left) -f.w else f.w;
        gfx.drawTexturePro(
            tex,
            .{ .x = f.x, .y = f.y, .width = src_w, .height = f.h }, // source
            .{ .x = player_x - draw_w / 2, .y = player_y - draw_h / 2, .width = draw_w, .height = draw_h }, // dest
            .{ .x = 0, .y = 0 }, // origin
            0, // rotation
            gfx.white, // tint
        );
    } else {
        // Fallback: green rectangle
        const speed = @sqrt(player_vx * player_vx + player_vy * player_vy);
        const green_intensity: u8 = @intFromFloat(std.math.clamp(180.0 + speed * 0.3, 180.0, 255.0));
        const blue_component: u8 = @intFromFloat(std.math.clamp(speed * 0.5, 0.0, 120.0));
        gfx.drawRectangleRec(
            .{ .x = player_x - PLAYER_SIZE / 2, .y = player_y - PLAYER_SIZE / 2, .width = PLAYER_SIZE, .height = PLAYER_SIZE },
            gfx.color(30, green_intensity, blue_component, 255),
        );
    }

    // ── Gizmo overlays (world-space) ───────────────────────────────────

    if (gizmos_visible) {
        drawGizmos();
    }

    gfx.endMode2D();

    // ── HUD drawing (screen-space, no camera) ──────────────────────────

    drawHud();

    window.endFrame();

    // Clear per-frame edge-triggered input state (pressed/released) AFTER
    // all input checks are done, so events that arrived between frames are
    // visible for exactly one frame.
    input.newFrame();
}

// ── Cleanup callback ───────────────────────────────────────────────────────

fn cleanup() callconv(.c) void {
    if (atlas_texture) |tex| gfx.unloadTexture(tex);
    if (sound_id != 0) audio.unloadSound(sound_id);
    if (music_id != 0) audio.unloadMusic(music_id);
    audio.deinit();
    window.shutdownGfx();
}

// ── Event callback ─────────────────────────────────────────────────────────

fn event(ev: [*c]const input.Event) callconv(.c) void {
    input.handleEvent(ev);
}

// ── Hexagon drawing ────────────────────────────────────────────────────────

fn drawHexagon(cx: f32, cy: f32, radius: f32, rotation: f32) void {
    // Color cycle based on rotation
    const hue = @mod(rotation * 0.5, 1.0);
    const r: u8 = @intFromFloat(std.math.clamp((@abs(hue * 6.0 - 3.0) - 1.0) * 255.0, 0.0, 255.0));
    const g: u8 = @intFromFloat(std.math.clamp((2.0 - @abs(hue * 6.0 - 2.0)) * 255.0, 0.0, 255.0));
    const b: u8 = @intFromFloat(std.math.clamp((2.0 - @abs(hue * 6.0 - 4.0)) * 255.0, 0.0, 255.0));
    const hex_color = gfx.color(r, g, b, 220);

    // Draw hexagon as 6 triangles (lines between vertices)
    const sides = 6;
    var i: usize = 0;
    while (i < sides) : (i += 1) {
        const angle1 = rotation + @as(f32, @floatFromInt(i)) * (2.0 * PI / @as(f32, @floatFromInt(sides)));
        const angle2 = rotation + @as(f32, @floatFromInt(i + 1)) * (2.0 * PI / @as(f32, @floatFromInt(sides)));

        const x1 = cx + @cos(angle1) * radius;
        const y1 = cy + @sin(angle1) * radius;
        const x2 = cx + @cos(angle2) * radius;
        const y2 = cy + @sin(angle2) * radius;

        // Fill triangle from center
        gfx.drawLine(cx, cy, x1, y1, 2, hex_color);
        gfx.drawLine(x1, y1, x2, y2, 2, hex_color);
        gfx.drawLine(x2, y2, cx, cy, 2, hex_color);
    }
}

// ── Gizmo drawing ──────────────────────────────────────────────────────────

fn drawGizmos() void {
    const gizmo_color = gfx.color(255, 255, 0, 180);
    const label_color = gfx.color(255, 255, 100, 255);
    const grid_color = gfx.color(200, 200, 200, 60);
    const velocity_color = gfx.color(0, 255, 100, 200);

    // Grid overlay (every 100 pixels)
    {
        const grid_step: f32 = 100.0;
        const grid_extent: f32 = 2000.0;
        var gx: f32 = -grid_extent;
        while (gx <= grid_extent) : (gx += grid_step) {
            gfx.drawLine(gx, -grid_extent, gx, grid_extent, 1, grid_color);
        }
        var gy: f32 = -grid_extent;
        while (gy <= grid_extent) : (gy += grid_step) {
            gfx.drawLine(-grid_extent, gy, grid_extent, gy, 1, grid_color);
        }
    }

    // Player bounding box
    gfx.drawLine(
        player_x - PLAYER_SIZE / 2,
        player_y - PLAYER_SIZE / 2,
        player_x + PLAYER_SIZE / 2,
        player_y - PLAYER_SIZE / 2,
        1,
        gizmo_color,
    );
    gfx.drawLine(
        player_x + PLAYER_SIZE / 2,
        player_y - PLAYER_SIZE / 2,
        player_x + PLAYER_SIZE / 2,
        player_y + PLAYER_SIZE / 2,
        1,
        gizmo_color,
    );
    gfx.drawLine(
        player_x + PLAYER_SIZE / 2,
        player_y + PLAYER_SIZE / 2,
        player_x - PLAYER_SIZE / 2,
        player_y + PLAYER_SIZE / 2,
        1,
        gizmo_color,
    );
    gfx.drawLine(
        player_x - PLAYER_SIZE / 2,
        player_y + PLAYER_SIZE / 2,
        player_x - PLAYER_SIZE / 2,
        player_y - PLAYER_SIZE / 2,
        1,
        gizmo_color,
    );

    // Player label
    gfx.drawText("Player", player_x - 20, player_y - PLAYER_SIZE / 2 - 14, 12, label_color);

    // Player velocity direction line
    if (@abs(player_vx) > 1.0 or @abs(player_vy) > 1.0) {
        const vel_scale: f32 = 0.5;
        gfx.drawLine(
            player_x,
            player_y,
            player_x + player_vx * vel_scale,
            player_y + player_vy * vel_scale,
            2,
            velocity_color,
        );
    }

    // Enemy bounding boxes and labels
    for (&enemies, 0..) |*enemy, i| {
        // Bounding circle approximated as box
        gfx.drawLine(enemy.x - ENEMY_RADIUS, enemy.y - ENEMY_RADIUS, enemy.x + ENEMY_RADIUS, enemy.y - ENEMY_RADIUS, 1, gizmo_color);
        gfx.drawLine(enemy.x + ENEMY_RADIUS, enemy.y - ENEMY_RADIUS, enemy.x + ENEMY_RADIUS, enemy.y + ENEMY_RADIUS, 1, gizmo_color);
        gfx.drawLine(enemy.x + ENEMY_RADIUS, enemy.y + ENEMY_RADIUS, enemy.x - ENEMY_RADIUS, enemy.y + ENEMY_RADIUS, 1, gizmo_color);
        gfx.drawLine(enemy.x - ENEMY_RADIUS, enemy.y + ENEMY_RADIUS, enemy.x - ENEMY_RADIUS, enemy.y - ENEMY_RADIUS, 1, gizmo_color);

        // Enemy label
        const labels = [_][:0]const u8{ "Enemy 0", "Enemy 1", "Enemy 2" };
        if (i < labels.len) {
            gfx.drawText(labels[i], enemy.x - 24, enemy.y - ENEMY_RADIUS - 14, 12, label_color);
        }

        // Patrol direction arrow
        gfx.drawLine(
            enemy.x,
            enemy.y,
            enemy.x + enemy.direction * 40,
            enemy.y,
            2,
            velocity_color,
        );
    }

    // Hexagon label
    gfx.drawText("Hexagon", 576, 100, 12, label_color);

    // Orbiter label
    const orb_x = player_x + @cos(orbiter_angle) * ORBITER_DISTANCE;
    const orb_y = player_y + @sin(orbiter_angle) * ORBITER_DISTANCE;
    gfx.drawText("Orbiter", orb_x - 24, orb_y - ORBITER_RADIUS - 14, 12, label_color);
}

// ── HUD drawing (screen-space) ─────────────────────────────────────────────

fn drawHud() void {
    const white = gfx.color(240, 240, 240, 255);
    const dim = gfx.color(180, 180, 180, 200);

    // Title
    gfx.drawText("LaBelle v2 - Sokol Demo", 10, 10, 20, white);

    // Controls help
    gfx.drawText("WASD/Arrows: Move", 10, 40, 14, dim);
    gfx.drawText("Mouse Wheel: Zoom", 10, 58, 14, dim);
    gfx.drawText("G: Toggle Gizmos", 10, 76, 14, dim);
    gfx.drawText("R: Reset Camera", 10, 94, 14, dim);
    gfx.drawText("Space: Play Sound", 10, 112, 14, dim);
    gfx.drawText("M: Toggle Music", 10, 130, 14, dim);
    gfx.drawText("ESC: Quit", 10, 148, 14, dim);

    // Status line
    const sw: f32 = @floatFromInt(window.width());
    gfx.drawText(if (gizmos_visible) "Gizmos: ON" else "Gizmos: OFF", sw - 140, 10, 14, dim);
    gfx.drawText(if (music_playing) "Music: ON" else "Music: OFF", sw - 140, 28, 14, dim);

    // Zoom indicator
    var zoom_buf: [32]u8 = undefined;
    const zoom_pct: u32 = @intFromFloat(camera.zoom * 100);
    const zoom_text = formatZoom(&zoom_buf, zoom_pct);
    gfx.drawText(zoom_text, sw - 140, 46, 14, dim);
}

/// Simple integer-to-string formatter for the zoom display.
/// Avoids std.fmt which may pull in too much for a demo.
fn formatZoom(buf: *[32]u8, pct: u32) [:0]const u8 {
    // Write "Zoom: NNN%\0" into buf
    const prefix = "Zoom: ";
    var pos: usize = 0;
    for (prefix) |c| {
        buf[pos] = c;
        pos += 1;
    }

    // Convert integer to digits
    var val = pct;
    if (val == 0) {
        buf[pos] = '0';
        pos += 1;
    } else {
        var digits: [10]u8 = undefined;
        var dcount: usize = 0;
        while (val > 0) {
            digits[dcount] = @intCast(val % 10 + '0');
            dcount += 1;
            val /= 10;
        }
        // Reverse
        var d: usize = 0;
        while (d < dcount) : (d += 1) {
            buf[pos] = digits[dcount - 1 - d];
            pos += 1;
        }
    }

    buf[pos] = '%';
    pos += 1;
    buf[pos] = 0;

    return buf[0..pos :0];
}

// ── Entry point ────────────────────────────────────────────────────────────

pub fn main() void {
    window.run(.{
        .init_cb = &init,
        .frame_cb = &frame,
        .cleanup_cb = &cleanup,
        .event_cb = &event,
        .w = SCREEN_W,
        .h = SCREEN_H,
        .title = "LaBelle v2 — Sokol Backend Demo",
    });
}
