/// LaBelle v2 — WebGPU Backend Demo
///
/// A comprehensive example showcasing all WebGPU backend features:
///   - Procedural shapes: rectangles, circles, polygons, lines, triangles, text
///   - Camera with lerp follow, zoom, and reset
///   - Gizmo overlay (bounding boxes, labels, velocity arrows, grid)
///   - Audio: sound effects and music (WAV-based PCM mixer)
///   - Input: keyboard (WASD/arrows), mouse wheel zoom, toggles
///   - Animation: color cycling, alpha pulsing, rotation, orbital motion
///
/// Controls:
///   WASD / Arrow keys  — Move player
///   Space              — Play sound effect
///   G                  — Toggle gizmo overlay
///   M                  — Toggle music playback
///   R                  — Reset camera zoom and position
///   Escape             — Quit
///   Mouse wheel        — Zoom in/out
const std = @import("std");
const gfx = @import("gfx");
const window = @import("window");
const input = @import("input");
const audio = @import("audio");

// ── GLFW key codes ────────────────────────────────────────────────────

const KEY_W = 87;
const KEY_A = 65;
const KEY_S = 83;
const KEY_D = 68;
const KEY_R = 82;
const KEY_G = 71;
const KEY_M = 77;
const KEY_SPACE = 32;
const KEY_ESCAPE = 256;
const KEY_UP = 265;
const KEY_DOWN = 264;
const KEY_LEFT = 263;
const KEY_RIGHT = 262;

// ── Constants ─────────────────────────────────────────────────────────

const SCREEN_W = 800;
const SCREEN_H = 600;
const PLAYER_SPEED = 200.0;
const CAMERA_LERP = 0.08;
const ZOOM_SPEED = 0.1;
const MIN_ZOOM = 0.25;
const MAX_ZOOM = 4.0;
const ENEMY_SPEED = 80.0;
const ORBITER_SPEED = 1.5;
const ORBITER_RADIUS = 120.0;
const GRID_SPACING = 100.0;

// ── Entity state ──────────────────────────────────────────────────────

const Entity = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    vx: f32 = 0,
    vy: f32 = 0,
    name: [:0]const u8,
};

const EnemyPatrol = struct {
    entity: Entity,
    start_x: f32,
    end_x: f32,
    direction: f32 = 1.0,
};

// ── Game state ────────────────────────────────────────────────────────

var player = Entity{
    .x = 400,
    .y = 300,
    .w = 60,
    .h = 60,
    .name = "Player",
};

var enemies: [3]EnemyPatrol = .{
    .{
        .entity = .{ .x = 200, .y = 450, .w = 30, .h = 30, .name = "Enemy A" },
        .start_x = 100,
        .end_x = 350,
    },
    .{
        .entity = .{ .x = 500, .y = 200, .w = 30, .h = 30, .name = "Enemy B" },
        .start_x = 400,
        .end_x = 700,
    },
    .{
        .entity = .{ .x = 600, .y = 400, .w = 30, .h = 30, .name = "Enemy C" },
        .start_x = 500,
        .end_x = 750,
    },
};

const Platform = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

const platforms = [_]Platform{
    .{ .x = 50, .y = 520, .w = 300, .h = 20 },
    .{ .x = 400, .y = 480, .w = 250, .h = 20 },
    .{ .x = 150, .y = 350, .w = 200, .h = 20 },
    .{ .x = 500, .y = 300, .w = 180, .h = 20 },
    .{ .x = 0, .y = 580, .w = 800, .h = 20 }, // ground
};

var camera = gfx.Camera2D{
    .offset = .{ .x = @as(f32, SCREEN_W) / 2.0, .y = @as(f32, SCREEN_H) / 2.0 },
    .target = .{ .x = 400, .y = 300 },
    .rotation = 0,
    .zoom = 1.0,
};

var time: f32 = 0;
var show_gizmos: bool = false;
var music_playing: bool = false;
var player_moving: bool = false;

var sfx_id: u32 = 0;
var music_id: u32 = 0;

// ── Delta time (fixed step approximation) ─────────────────────────────

const DT = 1.0 / 60.0;

// ── Helper: lerp ──────────────────────────────────────────────────────

fn lerp(a: f32, b: f32, t_val: f32) f32 {
    return a + (b - a) * t_val;
}

// ── Update ────────────────────────────────────────────────────────────

fn update() void {
    time += DT;

    // --- Player movement ---
    var dx: f32 = 0;
    var dy: f32 = 0;

    if (input.isKeyDown(KEY_W) or input.isKeyDown(KEY_UP)) dy -= 1;
    if (input.isKeyDown(KEY_S) or input.isKeyDown(KEY_DOWN)) dy += 1;
    if (input.isKeyDown(KEY_A) or input.isKeyDown(KEY_LEFT)) dx -= 1;
    if (input.isKeyDown(KEY_D) or input.isKeyDown(KEY_RIGHT)) dx += 1;

    // Normalize diagonal movement
    const mag = @sqrt(dx * dx + dy * dy);
    if (mag > 0) {
        dx = dx / mag * PLAYER_SPEED * DT;
        dy = dy / mag * PLAYER_SPEED * DT;
    }

    player.vx = dx / DT;
    player.vy = dy / DT;
    player.x += dx;
    player.y += dy;
    player_moving = mag > 0;

    // Clamp player to world bounds
    player.x = std.math.clamp(player.x, 0, 800 - player.w);
    player.y = std.math.clamp(player.y, 0, 600 - player.h);

    // --- Enemy patrol ---
    for (&enemies) |*ep| {
        ep.entity.x += ENEMY_SPEED * ep.direction * DT;
        if (ep.entity.x >= ep.end_x) {
            ep.entity.x = ep.end_x;
            ep.direction = -1.0;
        } else if (ep.entity.x <= ep.start_x) {
            ep.entity.x = ep.start_x;
            ep.direction = 1.0;
        }
        ep.entity.vx = ENEMY_SPEED * ep.direction;
    }

    // --- Camera follow with lerp ---
    const target_x = player.x + player.w / 2.0;
    const target_y = player.y + player.h / 2.0;
    camera.target.x = lerp(camera.target.x, target_x, CAMERA_LERP);
    camera.target.y = lerp(camera.target.y, target_y, CAMERA_LERP);

    // Mouse wheel zoom
    const wheel = input.getMouseWheelMove();
    if (wheel != 0) {
        camera.zoom += wheel * ZOOM_SPEED;
        camera.zoom = std.math.clamp(camera.zoom, MIN_ZOOM, MAX_ZOOM);
    }

    // --- Input: toggle gizmos / music (manual edge-detection since GLFW
    // key callbacks may not be wired, so isKeyPressed may not fire) ---
    {
        const S = struct {
            var g_was_down: bool = false;
            var m_was_down: bool = false;
        };

        const g_down = input.isKeyDown(KEY_G);
        if (g_down and !S.g_was_down) {
            show_gizmos = !show_gizmos;
        }
        S.g_was_down = g_down;

        const m_down = input.isKeyDown(KEY_M);
        if (m_down and !S.m_was_down) {
            if (music_id != 0) {
                if (music_playing) {
                    audio.pauseMusic(music_id);
                    music_playing = false;
                } else {
                    audio.resumeMusic(music_id);
                    music_playing = true;
                }
            }
        }
        S.m_was_down = m_down;
    }

    // --- Input: play sound effect ---
    if (input.isKeyDown(KEY_SPACE)) {
        if (sfx_id != 0) {
            audio.playSound(sfx_id);
        }
    }

    // --- Input: reset camera ---
    if (input.isKeyDown(KEY_R)) {
        camera.zoom = 1.0;
        camera.target.x = player.x + player.w / 2.0;
        camera.target.y = player.y + player.h / 2.0;
    }

    // --- Update music stream ---
    if (music_id != 0) {
        audio.updateMusic(music_id);
    }
}

// ── Render: World space ───────────────────────────────────────────────

fn renderWorld() void {
    // --- Ground platforms (gray) ---
    for (platforms) |p| {
        gfx.drawRectangleRec(
            .{ .x = p.x, .y = p.y, .width = p.w, .height = p.h },
            gfx.color(100, 100, 100, 255),
        );
    }

    // --- Enemies (red circles with alpha pulsing) ---
    for (&enemies) |*ep| {
        const pulse = (@sin(time * 3.0 + ep.entity.x * 0.1) + 1.0) / 2.0;
        const alpha: u8 = @intFromFloat(128.0 + pulse * 127.0);
        const cx = ep.entity.x + ep.entity.w / 2.0;
        const cy = ep.entity.y + ep.entity.h / 2.0;
        gfx.drawCircle(cx, cy, ep.entity.w / 2.0, gfx.color(255, 60, 60, alpha));
    }

    // --- Player (green rectangle, color cycles when moving) ---
    {
        var pr: u8 = 30;
        var pg: u8 = 200;
        var pb: u8 = 60;
        if (player_moving) {
            // Cycle green channel with time
            const cycle = (@sin(time * 8.0) + 1.0) / 2.0;
            pg = @intFromFloat(120.0 + cycle * 135.0);
            pb = @intFromFloat(30.0 + cycle * 80.0);
            pr = @intFromFloat(20.0 + cycle * 40.0);
        }
        gfx.drawRectangleRec(
            .{ .x = player.x, .y = player.y, .width = player.w, .height = player.h },
            gfx.color(pr, pg, pb, 255),
        );
    }

    // --- Spinning hexagon (center of world) ---
    {
        const hex_x: f32 = 400;
        const hex_y: f32 = 250;
        const hex_radius: f32 = 40;
        const rotation = time * 60.0; // degrees per second
        // Color shifts over time
        const cr: u8 = @intFromFloat((@sin(time * 1.0) + 1.0) / 2.0 * 200.0 + 55.0);
        const cg: u8 = @intFromFloat((@sin(time * 1.3 + 1.0) + 1.0) / 2.0 * 200.0 + 55.0);
        const cb: u8 = @intFromFloat((@sin(time * 1.7 + 2.0) + 1.0) / 2.0 * 200.0 + 55.0);
        gfx.drawPoly(hex_x, hex_y, 6, hex_radius, rotation, gfx.color(cr, cg, cb, 220));
    }

    // --- Orbiter (blue circle on sin/cos path) ---
    {
        const orbit_cx: f32 = 600;
        const orbit_cy: f32 = 250;
        const ox = orbit_cx + @cos(time * ORBITER_SPEED) * ORBITER_RADIUS;
        const oy = orbit_cy + @sin(time * ORBITER_SPEED) * ORBITER_RADIUS;
        // Draw orbit path as dashed circle (8 line segments)
        {
            const segments: u32 = 32;
            var i: u32 = 0;
            while (i < segments) : (i += 2) {
                const a0 = (@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments))) * 2.0 * std.math.pi;
                const a1 = (@as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segments))) * 2.0 * std.math.pi;
                gfx.drawLine(
                    orbit_cx + @cos(a0) * ORBITER_RADIUS,
                    orbit_cy + @sin(a0) * ORBITER_RADIUS,
                    orbit_cx + @cos(a1) * ORBITER_RADIUS,
                    orbit_cy + @sin(a1) * ORBITER_RADIUS,
                    1.0,
                    gfx.color(40, 80, 180, 80),
                );
            }
        }
        gfx.drawCircle(ox, oy, 14, gfx.color(60, 120, 255, 240));
    }

    // --- Decorative triangle ---
    gfx.drawTriangle(
        100, 150,
        140, 200,
        60, 200,
        gfx.color(255, 200, 50, 200),
    );
}

// ── Render: Gizmos (world space) ──────────────────────────────────────

fn renderGizmos() void {
    if (!show_gizmos) return;

    // Grid overlay
    {
        var gx: f32 = 0;
        while (gx <= 800) : (gx += GRID_SPACING) {
            gfx.drawLine(gx, 0, gx, 600, 1.0, gfx.color(255, 255, 255, 30));
        }
        var gy: f32 = 0;
        while (gy <= 600) : (gy += GRID_SPACING) {
            gfx.drawLine(0, gy, 800, gy, 1.0, gfx.color(255, 255, 255, 30));
        }
    }

    // Player bounding box
    drawBoundingBox(player.x, player.y, player.w, player.h, gfx.color(0, 255, 0, 180));
    // Player name label
    gfx.drawText(player.name, player.x, player.y - 14, 10, gfx.color(0, 255, 0, 200));
    // Player velocity arrow
    if (player_moving) {
        drawVelocityArrow(
            player.x + player.w / 2.0,
            player.y + player.h / 2.0,
            player.vx,
            player.vy,
            gfx.color(0, 255, 0, 150),
        );
    }

    // Enemy gizmos
    for (&enemies) |*ep| {
        const e = &ep.entity;
        drawBoundingBox(e.x, e.y, e.w, e.h, gfx.color(255, 60, 60, 150));
        gfx.drawText(e.name, e.x, e.y - 14, 10, gfx.color(255, 100, 100, 200));
        drawVelocityArrow(
            e.x + e.w / 2.0,
            e.y + e.h / 2.0,
            e.vx,
            0,
            gfx.color(255, 60, 60, 120),
        );
        // Patrol range indicator
        gfx.drawLine(
            ep.start_x,
            e.y + e.h + 4,
            ep.end_x,
            e.y + e.h + 4,
            1.0,
            gfx.color(255, 60, 60, 80),
        );
    }
}

fn drawBoundingBox(x: f32, y: f32, w: f32, h: f32, col: gfx.Color) void {
    gfx.drawLine(x, y, x + w, y, 1.0, col); // top
    gfx.drawLine(x + w, y, x + w, y + h, 1.0, col); // right
    gfx.drawLine(x + w, y + h, x, y + h, 1.0, col); // bottom
    gfx.drawLine(x, y + h, x, y, 1.0, col); // left
}

fn drawVelocityArrow(cx: f32, cy: f32, vx: f32, vy: f32, col: gfx.Color) void {
    const scale = 0.15;
    const end_x = cx + vx * scale;
    const end_y = cy + vy * scale;
    gfx.drawLine(cx, cy, end_x, end_y, 2.0, col);
    // Arrowhead (small triangle at end)
    const dx = end_x - cx;
    const dy = end_y - cy;
    const mag = @sqrt(dx * dx + dy * dy);
    if (mag > 2.0) {
        const nx = dx / mag;
        const ny = dy / mag;
        const arrow_size: f32 = 6.0;
        const px = -ny * arrow_size; // perpendicular
        const py = nx * arrow_size;
        gfx.drawTriangle(
            end_x,
            end_y,
            end_x - nx * arrow_size + px,
            end_y - ny * arrow_size + py,
            end_x - nx * arrow_size - px,
            end_y - ny * arrow_size - py,
            col,
        );
    }
}

// ── Render: HUD (screen space, no camera) ─────────────────────────────

fn renderHud() void {
    // Title
    gfx.drawText("LaBelle v2 - WebGPU Demo", 10, 10, 20, gfx.white);

    // Controls help
    gfx.drawText("WASD: Move  G: Gizmos  M: Music  R: Reset  Esc: Quit", 10, 36, 10, gfx.color(180, 180, 180, 200));

    // Status line
    {
        const zoom_pct: i32 = @intFromFloat(camera.zoom * 100.0);
        _ = zoom_pct;
        // Since drawText takes [:0]const u8 and we cannot do runtime formatting
        // easily without an allocator, show static indicators.
        if (show_gizmos) {
            gfx.drawText("[GIZMOS ON]", 10, 56, 12, gfx.color(0, 255, 0, 200));
        }
        if (music_playing) {
            gfx.drawText("[MUSIC ON]", 130, 56, 12, gfx.color(100, 180, 255, 200));
        }
    }

    // FPS placeholder (static text since we lack runtime formatting without allocator)
    gfx.drawText("60 FPS", SCREEN_W - 80, 10, 14, gfx.color(200, 200, 100, 220));

    // Crosshair at screen center
    const cx = @as(f32, SCREEN_W) / 2.0;
    const cy = @as(f32, SCREEN_H) / 2.0;
    gfx.drawLine(cx - 8, cy, cx + 8, cy, 1.0, gfx.color(255, 255, 255, 60));
    gfx.drawLine(cx, cy - 8, cx, cy + 8, 1.0, gfx.color(255, 255, 255, 60));

    // Minimap outline (bottom-right)
    const mm_x: f32 = SCREEN_W - 170;
    const mm_y: f32 = SCREEN_H - 130;
    const mm_w: f32 = 160;
    const mm_h: f32 = 120;
    // Background
    gfx.drawRectangleRec(
        .{ .x = mm_x, .y = mm_y, .width = mm_w, .height = mm_h },
        gfx.color(20, 20, 30, 180),
    );
    // Border
    drawBoundingBox(mm_x, mm_y, mm_w, mm_h, gfx.color(100, 100, 120, 200));

    // Minimap entities (scaled down: world 800x600 -> minimap 160x120)
    const sx = mm_w / 800.0;
    const sy = mm_h / 600.0;

    // Platforms on minimap
    for (platforms) |p| {
        gfx.drawRectangleRec(
            .{ .x = mm_x + p.x * sx, .y = mm_y + p.y * sy, .width = p.w * sx, .height = @max(p.h * sy, 1.0) },
            gfx.color(80, 80, 80, 200),
        );
    }

    // Player on minimap
    gfx.drawRectangleRec(
        .{ .x = mm_x + player.x * sx, .y = mm_y + player.y * sy, .width = @max(player.w * sx, 3.0), .height = @max(player.h * sy, 3.0) },
        gfx.color(0, 200, 60, 255),
    );

    // Enemies on minimap
    for (&enemies) |*ep| {
        gfx.drawCircle(
            mm_x + ep.entity.x * sx + ep.entity.w * sx / 2.0,
            mm_y + ep.entity.y * sy + ep.entity.h * sy / 2.0,
            2.0,
            gfx.color(255, 60, 60, 255),
        );
    }

    // Camera viewport indicator on minimap
    {
        const half_w = (@as(f32, SCREEN_W) / 2.0) / camera.zoom;
        const half_h = (@as(f32, SCREEN_H) / 2.0) / camera.zoom;
        const vx = mm_x + (camera.target.x - half_w) * sx;
        const vy = mm_y + (camera.target.y - half_h) * sy;
        const vw = (half_w * 2.0) * sx;
        const vh = (half_h * 2.0) * sy;
        drawBoundingBox(vx, vy, vw, vh, gfx.color(255, 255, 0, 120));
    }
}

// ── Main ──────────────────────────────────────────────────────────────

pub fn main() void {
    // --- Initialize window ---
    window.initWindow(SCREEN_W, SCREEN_H, "LaBelle v2 \xe2\x80\x94 WebGPU Backend Demo");
    window.setTargetFPS(60);
    gfx.setScreenSize(SCREEN_W, SCREEN_H);

    // --- Load audio assets (best-effort, files may not exist) ---
    sfx_id = audio.loadSound("assets/jump.wav");
    music_id = audio.loadMusic("assets/bgm.wav");

    // Auto-play music if loaded
    if (music_id != 0) {
        audio.playMusic(music_id);
        audio.setMusicVolume(music_id, 0.5);
        music_playing = true;
    }

    // --- Main loop ---
    while (!window.windowShouldClose()) {
        // Check for quit
        if (input.isKeyDown(KEY_ESCAPE)) break;

        // --- Update ---
        update();

        // --- Render ---
        window.beginDrawing();
        window.clearBackground(30, 30, 46, 255);

        // World-space rendering (affected by camera)
        gfx.beginMode2D(camera);
        renderWorld();
        renderGizmos();
        gfx.endMode2D();

        // Screen-space HUD (no camera transform)
        renderHud();

        window.endDrawing();
    }

    // --- Cleanup ---
    if (sfx_id != 0) audio.unloadSound(sfx_id);
    if (music_id != 0) audio.unloadMusic(music_id);
    window.closeWindow();
}
