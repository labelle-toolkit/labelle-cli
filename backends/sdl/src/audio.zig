/// SDL2 audio backend — satisfies the engine AudioInterface(Impl) contract.
/// Implemented via SDL_mixer (Mix_* API).
const std = @import("std");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_mixer.h");
});

const MAX_SOUNDS = 256;
const MAX_MUSIC = 32;

var sounds: [MAX_SOUNDS]?*c.Mix_Chunk = [_]?*c.Mix_Chunk{null} ** MAX_SOUNDS;
var music_slots: [MAX_MUSIC]?*c.Mix_Music = [_]?*c.Mix_Music{null} ** MAX_MUSIC;
var next_sound_id: u32 = 1;
var next_music_id: u32 = 1;

var mixer_initialized: bool = false;

/// Scan for a null slot in the sounds array before bumping next_sound_id.
fn findFreeSoundSlot() ?u32 {
    // First try to recycle a previously-freed slot.
    for (1..next_sound_id) |i| {
        if (sounds[i] == null) return @intCast(i);
    }
    // No recycled slot — use the next fresh ID if within bounds.
    if (next_sound_id < MAX_SOUNDS) return next_sound_id;
    return null;
}

/// Scan for a null slot in the music_slots array before bumping next_music_id.
fn findFreeMusicSlot() ?u32 {
    for (1..next_music_id) |i| {
        if (music_slots[i] == null) return @intCast(i);
    }
    if (next_music_id < MAX_MUSIC) return next_music_id;
    return null;
}

/// Track which music id is currently playing (0 = none).
var current_music_id: u32 = 0;

fn ensureInit() bool {
    if (mixer_initialized) return true;
    // Open the default audio device: 44100 Hz, signed 16-bit, stereo, 2048-byte chunks.
    // MIX_DEFAULT_FORMAT is a C macro (AUDIO_S16SYS); use the SDL constant directly.
    if (c.Mix_OpenAudio(44100, c.AUDIO_S16SYS, 2, 2048) < 0) {
        std.log.err("Mix_OpenAudio failed: {s}", .{c.Mix_GetError()});
        return false;
    }
    // Allocate enough mixing channels for our sound slots.
    _ = c.Mix_AllocateChannels(@intCast(MAX_SOUNDS));
    mixer_initialized = true;
    return true;
}

// ── Sound effects ──────────────────────────────────────
// NOTE: SDL_mixer maps one dedicated channel per sound ID (channel = id - 1).
// Playing the same sound ID again restarts it on that channel; true concurrent
// plays of the same sound require allocating multiple IDs or using free channels.

pub fn loadSound(path: [:0]const u8) u32 {
    if (!ensureInit()) return 0;
    // Mix_LoadWAV is a C macro; expand it: Mix_LoadWAV_RW(SDL_RWFromFile(file, "rb"), 1)
    const rw = c.SDL_RWFromFile(path.ptr, "rb") orelse {
        std.log.err("SDL_RWFromFile failed for '{s}': {s}", .{ path, c.SDL_GetError() });
        return 0;
    };
    const chunk = c.Mix_LoadWAV_RW(rw, 1) orelse {
        std.log.err("Mix_LoadWAV_RW failed for '{s}': {s}", .{ path, c.Mix_GetError() });
        return 0;
    };
    const id = findFreeSoundSlot() orelse {
        c.Mix_FreeChunk(chunk);
        return 0;
    };
    sounds[id] = chunk;
    // Only bump the counter when we used a fresh (non-recycled) slot.
    if (id == next_sound_id) next_sound_id += 1;
    return id;
}

pub fn unloadSound(id: u32) void {
    if (id < MAX_SOUNDS) {
        if (sounds[id]) |chunk| {
            // Stop the dedicated channel before freeing
            const channel: c_int = @intCast(id - 1);
            if (c.Mix_Playing(channel) != 0) {
                _ = c.Mix_HaltChannel(channel);
            }
            c.Mix_FreeChunk(chunk);
            sounds[id] = null;
        }
    }
}

pub fn playSound(id: u32) void {
    if (id < MAX_SOUNDS) {
        if (sounds[id]) |chunk| {
            // Use dedicated channel: sound id N -> channel N-1
            const channel: c_int = @intCast(id - 1);
            _ = c.Mix_PlayChannel(channel, chunk, 0);
        }
    }
}

pub fn stopSound(id: u32) void {
    if (id < MAX_SOUNDS) {
        if (sounds[id] != null) {
            const channel: c_int = @intCast(id - 1);
            c.Mix_HaltChannel(channel);
        }
    }
}

pub fn isSoundPlaying(id: u32) bool {
    if (id < MAX_SOUNDS) {
        if (sounds[id] != null) {
            const channel: c_int = @intCast(id - 1);
            return c.Mix_Playing(channel) != 0;
        }
    }
    return false;
}

pub fn setSoundVolume(id: u32, volume: f32) void {
    if (id < MAX_SOUNDS) {
        if (sounds[id]) |chunk| {
            // SDL_mixer volume range: 0..128 (MIX_MAX_VOLUME)
            const vol: c_int = @intFromFloat(std.math.clamp(volume, 0.0, 1.0) * 128.0);
            _ = c.Mix_VolumeChunk(chunk, vol);
        }
    }
}

// ── Music (streaming) ──────────────────────────────────

pub fn loadMusic(path: [:0]const u8) u32 {
    if (!ensureInit()) return 0;
    const mus = c.Mix_LoadMUS(path.ptr) orelse {
        std.log.err("Mix_LoadMUS failed for '{s}': {s}", .{ path, c.Mix_GetError() });
        return 0;
    };
    const id = findFreeMusicSlot() orelse {
        c.Mix_FreeMusic(mus);
        return 0;
    };
    music_slots[id] = mus;
    if (id == next_music_id) next_music_id += 1;
    return id;
}

pub fn unloadMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music_slots[id]) |mus| {
            // Stop music if this is the currently-playing track before freeing
            if (current_music_id == id) {
                _ = c.Mix_HaltMusic();
                current_music_id = 0;
            }
            c.Mix_FreeMusic(mus);
            music_slots[id] = null;
        }
    }
}

pub fn playMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music_slots[id]) |mus| {
            if (c.Mix_PlayMusic(mus, -1) < 0) {
                std.log.err("Mix_PlayMusic failed: {s}", .{c.Mix_GetError()});
            } else {
                current_music_id = id;
            }
        }
    }
}

pub fn stopMusic(id: u32) void {
    // SDL_mixer has a single music channel — only act if this ID is the active track.
    if (current_music_id == id) {
        _ = c.Mix_HaltMusic();
        current_music_id = 0;
    }
}

pub fn pauseMusic(id: u32) void {
    if (current_music_id == id) {
        c.Mix_PauseMusic();
    }
}

pub fn resumeMusic(id: u32) void {
    if (current_music_id == id) {
        c.Mix_ResumeMusic();
    }
}

pub fn isMusicPlaying(id: u32) bool {
    if (current_music_id != id) return false;
    return c.Mix_PlayingMusic() != 0;
}

pub fn setMusicVolume(id: u32, volume: f32) void {
    if (current_music_id != id) return;
    const vol: c_int = @intFromFloat(std.math.clamp(volume, 0.0, 1.0) * 128.0);
    _ = c.Mix_VolumeMusic(vol);
}

pub fn updateMusic(id: u32) void {
    // SDL_mixer handles streaming internally — nothing to do.
    _ = id;
}

// ── Lifecycle ─────────────────────────────────────────

pub fn deinit() void {
    if (!mixer_initialized) return;

    // Free all loaded sound chunks
    for (1..MAX_SOUNDS) |i| {
        if (sounds[i]) |chunk| {
            c.Mix_FreeChunk(chunk);
            sounds[i] = null;
        }
    }
    // Free all loaded music
    for (1..MAX_MUSIC) |i| {
        if (music_slots[i]) |mus| {
            c.Mix_FreeMusic(mus);
            music_slots[i] = null;
        }
    }

    current_music_id = 0;
    next_sound_id = 1;
    next_music_id = 1;

    c.Mix_CloseAudio();
    c.SDL_QuitSubSystem(c.SDL_INIT_AUDIO);
    mixer_initialized = false;
}

// ── Global ────────────────────────────────────────────

pub fn setVolume(volume: f32) void {
    if (!ensureInit()) return;
    // Set master volume on all channels + music
    const vol: c_int = @intFromFloat(std.math.clamp(volume, 0.0, 1.0) * 128.0);
    _ = c.Mix_Volume(-1, vol); // -1 = all channels
    _ = c.Mix_VolumeMusic(vol);
}
