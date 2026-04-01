/// Raylib audio backend — satisfies the engine AudioInterface(Impl) contract.
/// Manages a registry of loaded sounds and music streams.
const rl = @import("raylib");

const MAX_SOUNDS = 256;
const MAX_MUSIC = 32;

var sounds: [MAX_SOUNDS]?rl.Sound = [_]?rl.Sound{null} ** MAX_SOUNDS;
var music: [MAX_MUSIC]?rl.Music = [_]?rl.Music{null} ** MAX_MUSIC;
var next_sound_id: u32 = 1;
var next_music_id: u32 = 1;

// ── Sound effects ──────────────────────────────────────────

pub fn loadSound(path: [:0]const u8) u32 {
    const snd = rl.loadSound(path);
    if (snd.stream.buffer == null) return 0;
    const id = next_sound_id;
    if (id >= MAX_SOUNDS) return 0;
    sounds[id] = snd;
    next_sound_id += 1;
    return id;
}

pub fn unloadSound(id: u32) void {
    if (id < MAX_SOUNDS) {
        if (sounds[id]) |snd| {
            rl.unloadSound(snd);
            sounds[id] = null;
        }
    }
}

pub fn playSound(id: u32) void {
    if (id < MAX_SOUNDS) {
        if (sounds[id]) |snd| {
            rl.playSound(snd);
        }
    }
}

pub fn stopSound(id: u32) void {
    if (id < MAX_SOUNDS) {
        if (sounds[id]) |snd| {
            rl.stopSound(snd);
        }
    }
}

pub fn isSoundPlaying(id: u32) bool {
    if (id < MAX_SOUNDS) {
        if (sounds[id]) |snd| {
            return rl.isSoundPlaying(snd);
        }
    }
    return false;
}

pub fn setSoundVolume(id: u32, volume: f32) void {
    if (id < MAX_SOUNDS) {
        if (sounds[id]) |snd| {
            rl.setSoundVolume(snd, volume);
        }
    }
}

// ── Music (streaming) ──────────────────────────────────────

pub fn loadMusic(path: [:0]const u8) u32 {
    const mus = rl.loadMusicStream(path);
    if (mus.stream.buffer == null) return 0;
    const id = next_music_id;
    if (id >= MAX_MUSIC) return 0;
    music[id] = mus;
    next_music_id += 1;
    return id;
}

pub fn unloadMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music[id]) |mus| {
            rl.unloadMusicStream(mus);
            music[id] = null;
        }
    }
}

pub fn playMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music[id]) |mus| {
            rl.playMusicStream(mus);
        }
    }
}

pub fn stopMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music[id]) |mus| {
            rl.stopMusicStream(mus);
        }
    }
}

pub fn pauseMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music[id]) |mus| {
            rl.pauseMusicStream(mus);
        }
    }
}

pub fn resumeMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music[id]) |mus| {
            rl.resumeMusicStream(mus);
        }
    }
}

pub fn isMusicPlaying(id: u32) bool {
    if (id < MAX_MUSIC) {
        if (music[id]) |mus| {
            return rl.isMusicStreamPlaying(mus);
        }
    }
    return false;
}

pub fn setMusicVolume(id: u32, volume: f32) void {
    if (id < MAX_MUSIC) {
        if (music[id]) |mus| {
            rl.setMusicVolume(mus, volume);
        }
    }
}

pub fn updateMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music[id]) |mus| {
            rl.updateMusicStream(mus);
        }
    }
}

// ── Global ────────────────────────────────────────────────

pub fn setVolume(volume: f32) void {
    rl.setMasterVolume(volume);
}
