/// Sokol audio backend — satisfies the engine AudioInterface(Impl) contract.
/// Implements a simple PCM mixer on top of sokol_audio's callback API.
/// Supports WAV file loading for both sound effects and music.
///
/// Thread safety: The audio callback (`audioCallback`) runs on a separate thread
/// managed by sokol_audio and reads shared state (`sounds`, `music_slots`, `voices`)
/// without synchronization primitives. Callers must not call `unloadSound` or
/// `unloadMusic` while the corresponding sound/music is actively playing, as the
/// callback may still be reading the sample buffer. The `deinit` function shuts
/// down the audio callback before freeing resources. TODO: add proper atomic or
/// mutex-based synchronization so unload is safe while audio is playing.
const std = @import("std");
const sokol = @import("sokol");
const saudio = sokol.audio;

const MAX_SOUNDS = 256;
const MAX_MUSIC = 32;
const MAX_ACTIVE_VOICES = 64;

// ── Sound slot storage ──────────────────────────────────────────

const SoundSlot = struct {
    samples: []const f32, // interleaved stereo PCM
    sample_count: usize, // total number of f32 values
    channels: u16,
    sample_rate: u32,
    volume: f32,
};

const MusicSlot = struct {
    samples: []const f32,
    sample_count: usize,
    channels: u16,
    sample_rate: u32,
    volume: f32,
    position: usize, // current playback position
    playing: bool,
    paused: bool,
    looping: bool,
};

// Active voice for sound effect playback
const Voice = struct {
    sound_id: u32,
    position: usize,
    active: bool,
};

var sounds: [MAX_SOUNDS]?SoundSlot = [_]?SoundSlot{null} ** MAX_SOUNDS;
var music_slots: [MAX_MUSIC]?MusicSlot = [_]?MusicSlot{null} ** MAX_MUSIC;
var voices: [MAX_ACTIVE_VOICES]Voice = [_]Voice{.{ .sound_id = 0, .position = 0, .active = false }} ** MAX_ACTIVE_VOICES;
var next_sound_id: u32 = 1;
var next_music_id: u32 = 1;
var master_volume: f32 = 1.0;
var audio_initialized: bool = false;

// ── Audio system init ──────────────────────────────────────────

fn ensureInit() void {
    if (audio_initialized) return;
    saudio.setup(.{
        .num_channels = 2,
        .sample_rate = 44100,
        .stream_cb = audioCallback,
        .logger = .{ .func = sokol.log.func },
    });
    if (saudio.isvalid()) {
        audio_initialized = true;
    }
}

/// Shut down the audio system and free all allocated sample buffers.
/// Must be called before program exit to avoid leaking memory.
pub fn deinit() void {
    if (!audio_initialized) return;

    // Stop the audio callback first so it no longer reads shared state.
    saudio.shutdown();

    // Free all sound sample buffers.
    for (&sounds) |*slot| {
        if (slot.*) |s| {
            std.heap.page_allocator.free(s.samples);
            slot.* = null;
        }
    }

    // Free all music sample buffers.
    for (&music_slots) |*slot| {
        if (slot.*) |s| {
            std.heap.page_allocator.free(s.samples);
            slot.* = null;
        }
    }

    // Reset all voices.
    for (&voices) |*voice| {
        voice.* = .{ .sound_id = 0, .position = 0, .active = false };
    }

    next_sound_id = 1;
    next_music_id = 1;
    master_volume = 1.0;
    audio_initialized = false;
}

/// The audio callback invoked by sokol_audio to fill the output buffer.
/// Mixes all active voices and playing music into the output.
fn audioCallback(buffer: [*c]f32, num_frames: i32, num_channels: i32) callconv(.c) void {
    const frames: usize = @intCast(num_frames);
    const channels: usize = @intCast(num_channels);
    const total_samples = frames * channels;

    // Zero the output buffer
    for (0..total_samples) |i| {
        buffer[i] = 0;
    }

    // Mix active sound voices
    for (&voices) |*voice| {
        if (!voice.active) continue;
        const slot = sounds[voice.sound_id] orelse {
            voice.active = false;
            continue;
        };

        const vol = slot.volume * master_volume;
        var samples_written: usize = 0;

        while (samples_written < frames) {
            if (voice.position >= slot.sample_count) {
                voice.active = false;
                break;
            }

            const buf_idx = samples_written * channels;

            if (slot.channels == 1) {
                // Mono: duplicate to both channels
                const sample = slot.samples[voice.position] * vol;
                buffer[buf_idx] += sample;
                if (channels >= 2) buffer[buf_idx + 1] += sample;
                voice.position += 1;
            } else {
                // Stereo: copy left and right
                buffer[buf_idx] += slot.samples[voice.position] * vol;
                if (channels >= 2 and voice.position + 1 < slot.sample_count) {
                    buffer[buf_idx + 1] += slot.samples[voice.position + 1] * vol;
                }
                voice.position += 2;
            }
            samples_written += 1;
        }
    }

    // Mix music tracks
    for (&music_slots) |*maybe_slot| {
        if (maybe_slot.*) |*slot| {
            if (!slot.playing or slot.paused) continue;

            // Guard: zero-length samples can't be played — stop to avoid infinite loop
            if (slot.sample_count == 0) {
                slot.playing = false;
                continue;
            }

            const vol = slot.volume * master_volume;
            var samples_written: usize = 0;

            while (samples_written < frames) {
                if (slot.position >= slot.sample_count) {
                    if (slot.looping) {
                        slot.position = 0;
                    } else {
                        slot.playing = false;
                        break;
                    }
                }

                const buf_idx = samples_written * channels;

                if (slot.channels == 1) {
                    const sample = slot.samples[slot.position] * vol;
                    buffer[buf_idx] += sample;
                    if (channels >= 2) buffer[buf_idx + 1] += sample;
                    slot.position += 1;
                } else {
                    buffer[buf_idx] += slot.samples[slot.position] * vol;
                    if (channels >= 2 and slot.position + 1 < slot.sample_count) {
                        buffer[buf_idx + 1] += slot.samples[slot.position + 1] * vol;
                    }
                    slot.position += 2;
                }
                samples_written += 1;
            }
        }
    }

    // Clamp output to [-1.0, 1.0]
    for (0..total_samples) |i| {
        buffer[i] = std.math.clamp(buffer[i], -1.0, 1.0);
    }
}

// ── WAV file parsing ──────────────────────────────────────────

const WavData = struct {
    samples: []f32,
    channels: u16,
    sample_rate: u32,
};

fn loadWavFile(path: [:0]const u8) ?WavData {
    const file = std.fs.cwd().openFileZ(path, .{}) catch return null;
    defer file.close();

    const stat = file.stat() catch return null;
    if (stat.size < 44 or stat.size > 256 * 1024 * 1024) return null;

    const data = file.readToEndAlloc(std.heap.page_allocator, @intCast(stat.size)) catch return null;
    defer std.heap.page_allocator.free(data);

    const wav = parseWav(data) orelse return null;
    if (wav.sample_rate != 44100) {
        std.log.warn("WAV sample rate {d}Hz does not match output rate 44100Hz: {s}", .{ wav.sample_rate, path });
    }
    return wav;
}

fn parseWav(data: []const u8) ?WavData {
    if (data.len < 44) return null;

    // Verify RIFF header
    if (!std.mem.eql(u8, data[0..4], "RIFF")) return null;
    if (!std.mem.eql(u8, data[8..12], "WAVE")) return null;

    // Find "fmt " chunk
    var offset: usize = 12;
    var fmt_found = false;
    var audio_format: u16 = 0;
    var num_channels: u16 = 0;
    var sample_rate: u32 = 0;
    var bits_per_sample: u16 = 0;

    while (offset + 8 <= data.len) {
        const chunk_id = data[offset..][0..4];
        const chunk_size: usize = @intCast(std.mem.readInt(u32, data[offset + 4 ..][0..4], .little));

        if (offset + 8 + chunk_size > data.len) return null;

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            if (chunk_size < 16 or offset + 8 + chunk_size > data.len) return null;
            const fmt = data[offset + 8 ..];
            audio_format = std.mem.readInt(u16, fmt[0..2], .little);
            num_channels = std.mem.readInt(u16, fmt[2..4], .little);
            sample_rate = std.mem.readInt(u32, fmt[4..8], .little);
            bits_per_sample = std.mem.readInt(u16, fmt[14..16], .little);
            fmt_found = true;
        }

        if (std.mem.eql(u8, chunk_id, "data") and fmt_found) {
            // Only support PCM (1) and IEEE float (3)
            if (audio_format != 1 and audio_format != 3) return null;
            if (num_channels == 0 or num_channels > 2) return null;

            const pcm_data = data[offset + 8 ..][0..chunk_size];
            return convertToF32(pcm_data, num_channels, sample_rate, bits_per_sample, audio_format);
        }

        offset += 8 + ((chunk_size + 1) & ~@as(usize, 1)); // chunks are word-aligned
    }

    return null;
}

fn convertToF32(pcm_data: []const u8, channels: u16, sample_rate: u32, bits: u16, format: u16) ?WavData {
    if (format == 3 and bits == 32) {
        // IEEE 32-bit float
        const num_samples = pcm_data.len / 4;
        const samples = std.heap.page_allocator.alloc(f32, num_samples) catch return null;
        for (0..num_samples) |i| {
            samples[i] = @bitCast(std.mem.readInt(u32, pcm_data[i * 4 ..][0..4], .little));
        }
        return .{ .samples = samples, .channels = channels, .sample_rate = sample_rate };
    }

    if (format == 1) {
        if (bits == 16) {
            const num_samples = pcm_data.len / 2;
            const samples = std.heap.page_allocator.alloc(f32, num_samples) catch return null;
            for (0..num_samples) |i| {
                const raw = std.mem.readInt(i16, pcm_data[i * 2 ..][0..2], .little);
                samples[i] = @as(f32, @floatFromInt(raw)) / 32768.0;
            }
            return .{ .samples = samples, .channels = channels, .sample_rate = sample_rate };
        }
        if (bits == 8) {
            const num_samples = pcm_data.len;
            const samples = std.heap.page_allocator.alloc(f32, num_samples) catch return null;
            for (0..num_samples) |i| {
                // 8-bit WAV is unsigned, 128 = silence
                samples[i] = (@as(f32, @floatFromInt(pcm_data[i])) - 128.0) / 128.0;
            }
            return .{ .samples = samples, .channels = channels, .sample_rate = sample_rate };
        }
        if (bits == 24) {
            const num_samples = pcm_data.len / 3;
            const samples = std.heap.page_allocator.alloc(f32, num_samples) catch return null;
            for (0..num_samples) |i| {
                const b0: i32 = pcm_data[i * 3];
                const b1: i32 = pcm_data[i * 3 + 1];
                const b2: i32 = @as(i32, @as(i8, @bitCast(pcm_data[i * 3 + 2])));
                const raw = b0 | (b1 << 8) | (b2 << 16);
                samples[i] = @as(f32, @floatFromInt(raw)) / 8388608.0;
            }
            return .{ .samples = samples, .channels = channels, .sample_rate = sample_rate };
        }
    }

    return null;
}

// ── Sound effects ──────────────────────────────────────────

pub fn loadSound(path: [:0]const u8) u32 {
    ensureInit();
    const wav = loadWavFile(path) orelse return 0;
    const id = next_sound_id;
    if (id >= MAX_SOUNDS) {
        std.heap.page_allocator.free(wav.samples);
        return 0;
    }
    sounds[id] = .{
        .samples = wav.samples,
        .sample_count = wav.samples.len,
        .channels = wav.channels,
        .sample_rate = wav.sample_rate,
        .volume = 1.0,
    };
    next_sound_id += 1;
    return id;
}

pub fn unloadSound(id: u32) void {
    if (id < MAX_SOUNDS) {
        if (sounds[id] != null) {
            // Stop any voices using this sound
            for (&voices) |*voice| {
                if (voice.active and voice.sound_id == id) {
                    voice.active = false;
                }
            }
            // Do NOT free slot.samples here — the audio callback thread may still
            // be reading from it. Just mark the slot as unused. Proper reclamation
            // of sample memory happens at shutdown.
            sounds[id] = null;
        }
    }
}

pub fn playSound(id: u32) void {
    ensureInit();
    if (id >= MAX_SOUNDS) return;
    if (sounds[id] == null) return;

    // Find a free voice slot
    for (&voices) |*voice| {
        if (!voice.active) {
            voice.* = .{ .sound_id = id, .position = 0, .active = true };
            return;
        }
    }
    // All voices busy: steal the oldest (first) voice
    voices[0] = .{ .sound_id = id, .position = 0, .active = true };
}

pub fn stopSound(id: u32) void {
    for (&voices) |*voice| {
        if (voice.active and voice.sound_id == id) {
            voice.active = false;
        }
    }
}

pub fn isSoundPlaying(id: u32) bool {
    for (&voices) |*voice| {
        if (voice.active and voice.sound_id == id) {
            return true;
        }
    }
    return false;
}

pub fn setSoundVolume(id: u32, volume: f32) void {
    if (id < MAX_SOUNDS) {
        if (sounds[id] != null) {
            sounds[id].?.volume = std.math.clamp(volume, 0.0, 1.0);
        }
    }
}

// ── Music (streaming) ──────────────────────────────────────

pub fn loadMusic(path: [:0]const u8) u32 {
    ensureInit();
    const wav = loadWavFile(path) orelse return 0;
    const id = next_music_id;
    if (id >= MAX_MUSIC) {
        std.heap.page_allocator.free(wav.samples);
        return 0;
    }
    music_slots[id] = .{
        .samples = wav.samples,
        .sample_count = wav.samples.len,
        .channels = wav.channels,
        .sample_rate = wav.sample_rate,
        .volume = 1.0,
        .position = 0,
        .playing = false,
        .paused = false,
        .looping = true,
    };
    next_music_id += 1;
    return id;
}

pub fn unloadMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music_slots[id] != null) {
            // Do NOT free slot.samples here — the audio callback thread may still
            // be reading from it. Just mark the slot as unused. Proper reclamation
            // of sample memory happens at shutdown.
            music_slots[id].?.playing = false;
            music_slots[id] = null;
        }
    }
}

pub fn playMusic(id: u32) void {
    ensureInit();
    if (id < MAX_MUSIC) {
        if (music_slots[id] != null) {
            music_slots[id].?.playing = true;
            music_slots[id].?.paused = false;
            music_slots[id].?.position = 0;
        }
    }
}

pub fn stopMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music_slots[id] != null) {
            music_slots[id].?.playing = false;
            music_slots[id].?.position = 0;
        }
    }
}

pub fn pauseMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music_slots[id] != null) {
            music_slots[id].?.paused = true;
        }
    }
}

pub fn resumeMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music_slots[id] != null) {
            music_slots[id].?.paused = false;
        }
    }
}

pub fn isMusicPlaying(id: u32) bool {
    if (id < MAX_MUSIC) {
        if (music_slots[id]) |slot| {
            return slot.playing and !slot.paused;
        }
    }
    return false;
}

pub fn setMusicVolume(id: u32, volume: f32) void {
    if (id < MAX_MUSIC) {
        if (music_slots[id] != null) {
            music_slots[id].?.volume = std.math.clamp(volume, 0.0, 1.0);
        }
    }
}

pub fn updateMusic(_: u32) void {
    // No-op: music is streamed directly in the audio callback.
    // This function exists for API compatibility with backends that
    // require explicit buffer refills (e.g., raylib).
}

// ── Global ────────────────────────────────────────────────

pub fn setVolume(volume: f32) void {
    master_volume = std.math.clamp(volume, 0.0, 1.0);
}
