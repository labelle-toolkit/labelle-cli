/// WebGPU audio backend — satisfies the engine AudioInterface(Impl) contract.
/// WebGPU has no audio API. This implements a simple WAV-based PCM mixer
/// using standard file I/O for loading and a software mixing approach only.
///
/// The mixer keeps track of per-sound / per-music playback cursors and can
/// produce interleaved stereo PCM output buffers when requested by the
/// engine. It does not directly talk to any platform audio APIs (CoreAudio,
/// WASAPI, ALSA) and does not maintain a ring buffer or callback at this
/// layer; higher-level code is responsible for feeding mixed samples to the
/// actual audio device.
///
/// Playback calls track state so the engine's AudioInterface contract is
/// satisfied and games can query isSoundPlaying / isMusicPlaying correctly.
///
/// ## Thread safety
///
/// `mixOutput` is designed to be called from the platform audio callback thread
/// (CoreAudio render callback, WASAPI buffer event, ALSA write thread, etc.).
/// All other public functions (`loadSound`, `playSound`, `unloadSound`, etc.)
/// are called from the main/game thread.
///
/// **Known race condition:** `unloadSound` / `unloadMusic` free the sample
/// buffer immediately while `mixOutput` may be reading it concurrently.
/// TODO: Replace immediate free with a "pending_free" flag — `unloadSound`
/// sets the flag and `mixOutput` performs the actual deallocation when it
/// observes the flag, ensuring the buffer is not freed mid-read.
const std = @import("std");

// ── Limits ────────────────────────────────────────────────────────────

const MAX_SOUNDS = 256;
const MAX_MUSIC = 32;
const SAMPLE_RATE = 44100;
const CHANNELS = 2;

// ── Sound slot ────────────────────────────────────────────────────────

const SoundSlot = struct {
    /// Raw PCM samples (interleaved stereo, f32).
    samples: ?[]f32 = null,
    sample_count: usize = 0,
    /// Current playback cursor (sample-frame index).
    cursor: usize = 0,
    playing: bool = false,
    volume: f32 = 1.0,
    looping: bool = false,
};

const MusicSlot = struct {
    /// Decoded PCM buffer (loaded fully for simplicity; streaming TODO).
    samples: ?[]f32 = null,
    sample_count: usize = 0,
    cursor: usize = 0,
    playing: bool = false,
    paused: bool = false,
    volume: f32 = 1.0,
    /// When true (default), music loops back to the beginning on completion.
    looping: bool = true,
};

var sounds: [MAX_SOUNDS]SoundSlot = [_]SoundSlot{.{}} ** MAX_SOUNDS;
var musics: [MAX_MUSIC]MusicSlot = [_]MusicSlot{.{}} ** MAX_MUSIC;
var next_sound_id: u32 = 1;
var next_music_id: u32 = 1;
var master_volume: f32 = 1.0;

// ── WAV loader (minimal, 16-bit PCM only) ─────────────────────────────

fn loadWav(path: [:0]const u8) ?[]f32 {
    const file = std.fs.cwd().openFile(std.mem.span(path), .{}) catch return null;
    defer file.close();

    const stat = file.stat() catch return null;
    const file_size = stat.size;
    if (file_size < 12) return null;

    const file_buf = std.heap.page_allocator.alloc(u8, file_size) catch return null;
    defer std.heap.page_allocator.free(file_buf);

    const bytes_read = file.readAll(file_buf) catch return null;
    if (bytes_read != file_size) return null;

    // Validate RIFF/WAVE header (first 12 bytes)
    if (!std.mem.eql(u8, file_buf[0..4], "RIFF") or !std.mem.eql(u8, file_buf[8..12], "WAVE")) {
        return null;
    }

    // Scan chunks starting at offset 12 to find "fmt " and "data".
    var num_channels: u16 = 0;
    var bits_per_sample: u16 = 0;
    var fmt_found = false;
    var data_offset: usize = 0;
    var data_size: u32 = 0;
    var data_found = false;

    var pos: usize = 12;
    while (pos + 8 <= bytes_read) {
        const chunk_id = file_buf[pos..][0..4];
        const chunk_size = std.mem.readInt(u32, file_buf[pos + 4 ..][0..4], .little);
        const chunk_data_start = pos + 8;

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            if (chunk_size < 16 or chunk_data_start + 16 > bytes_read) return null;
            const fmt = file_buf[chunk_data_start..];
            const audio_format = std.mem.readInt(u16, fmt[0..2], .little);
            if (audio_format != 1) return null; // Only PCM (format 1) supported
            num_channels = std.mem.readInt(u16, fmt[2..4], .little);
            bits_per_sample = std.mem.readInt(u16, fmt[14..16], .little);
            fmt_found = true;
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            data_offset = chunk_data_start;
            data_size = chunk_size;
            data_found = true;
        }

        if (fmt_found and data_found) break;

        // Advance to next chunk (chunks are 2-byte aligned)
        pos = chunk_data_start + chunk_size;
        if (pos % 2 != 0) pos += 1; // Pad byte
    }

    if (!fmt_found or !data_found) return null;
    if (bits_per_sample != 16) return null; // Only 16-bit PCM supported
    if (num_channels == 0 or num_channels > 2) return null;

    const actual_data_size: usize = @min(@as(usize, data_size), bytes_read - data_offset);
    const raw_buf = file_buf[data_offset .. data_offset + actual_data_size];

    const sample_count: usize = actual_data_size / (@as(usize, bits_per_sample) / 8);

    // Convert to interleaved stereo f32
    const frame_count = sample_count / @as(usize, num_channels);
    const out_samples = frame_count * CHANNELS;
    const pcm = std.heap.page_allocator.alloc(f32, out_samples) catch return null;

    var i: usize = 0;
    while (i < frame_count) : (i += 1) {
        // Read source sample(s)
        var left: f32 = 0;
        var right: f32 = 0;
        const src_idx = i * @as(usize, num_channels);
        if (src_idx < sample_count) {
            const byte_off = src_idx * 2;
            if (byte_off + 1 < raw_buf.len) {
                const s16 = std.mem.readInt(i16, raw_buf[byte_off..][0..2], .little);
                left = @as(f32, @floatFromInt(s16)) / 32768.0;
            }
        }
        if (num_channels >= 2 and (src_idx + 1) < sample_count) {
            const byte_off = (src_idx + 1) * 2;
            if (byte_off + 1 < raw_buf.len) {
                const s16 = std.mem.readInt(i16, raw_buf[byte_off..][0..2], .little);
                right = @as(f32, @floatFromInt(s16)) / 32768.0;
            }
        } else {
            right = left; // Mono -> duplicate to both channels
        }

        pcm[i * CHANNELS + 0] = left;
        pcm[i * CHANNELS + 1] = right;
    }

    return pcm;
}

// ── Sound effects ──────────────────────────────────────────────────────

pub fn loadSound(path: [:0]const u8) u32 {
    const id = next_sound_id;
    if (id >= MAX_SOUNDS) return 0;

    const pcm = loadWav(path) orelse return 0;
    sounds[id] = .{
        .samples = pcm,
        .sample_count = pcm.len,
        .cursor = 0,
        .playing = false,
        .volume = 1.0,
        .looping = false,
    };
    next_sound_id += 1;
    return id;
}

pub fn unloadSound(id: u32) void {
    if (id >= MAX_SOUNDS) return;
    if (sounds[id].samples) |s| {
        std.heap.page_allocator.free(s);
    }
    sounds[id] = .{};
}

pub fn playSound(id: u32) void {
    if (id != 0 and id < MAX_SOUNDS and sounds[id].samples != null) {
        sounds[id].cursor = 0;
        sounds[id].playing = true;
    }
}

pub fn stopSound(id: u32) void {
    if (id < MAX_SOUNDS) {
        sounds[id].playing = false;
        sounds[id].cursor = 0;
    }
}

pub fn isSoundPlaying(id: u32) bool {
    if (id < MAX_SOUNDS) return sounds[id].playing;
    return false;
}

pub fn setSoundVolume(id: u32, volume: f32) void {
    if (id < MAX_SOUNDS) {
        sounds[id].volume = std.math.clamp(volume, 0.0, 1.0);
    }
}

// ── Music (streaming) ──────────────────────────────────────────────────

pub fn loadMusic(path: [:0]const u8) u32 {
    const id = next_music_id;
    if (id >= MAX_MUSIC) return 0;

    const pcm = loadWav(path) orelse return 0;
    musics[id] = .{
        .samples = pcm,
        .sample_count = pcm.len,
        .cursor = 0,
        .playing = false,
        .paused = false,
        .volume = 1.0,
    };
    next_music_id += 1;
    return id;
}

pub fn unloadMusic(id: u32) void {
    if (id >= MAX_MUSIC) return;
    if (musics[id].samples) |s| {
        std.heap.page_allocator.free(s);
    }
    musics[id] = .{};
}

pub fn playMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (musics[id].samples == null) return;
        musics[id].cursor = 0;
        musics[id].playing = true;
        musics[id].paused = false;
    }
}

pub fn stopMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        musics[id].playing = false;
        musics[id].paused = false;
        musics[id].cursor = 0;
    }
}

pub fn pauseMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        musics[id].paused = true;
    }
}

pub fn resumeMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        musics[id].paused = false;
    }
}

pub fn isMusicPlaying(id: u32) bool {
    if (id < MAX_MUSIC) return musics[id].playing and !musics[id].paused;
    return false;
}

pub fn setMusicVolume(id: u32, volume: f32) void {
    if (id < MAX_MUSIC) {
        musics[id].volume = std.math.clamp(volume, 0.0, 1.0);
    }
}

pub fn updateMusic(id: u32) void {
    // State check only — cursor advancement is handled by mixOutput which is
    // called from the platform audio callback.  Advancing here as well would
    // cause double-speed playback.
    if (id >= MAX_MUSIC) return;
    const slot = &musics[id];
    if (!slot.playing or slot.paused) return;

    // Check if playback finished (non-looping case handled by mixOutput setting
    // playing=false).  Nothing else to do — mixOutput owns the cursor.
}

// ── Global ────────────────────────────────────────────────────────────

pub fn setVolume(volume: f32) void {
    master_volume = std.math.clamp(volume, 0.0, 1.0);
}

/// Software mixer: mix all active sounds and music into an output buffer.
/// Called by the platform audio callback (CoreAudio/WASAPI/ALSA).
/// `output` is interleaved stereo f32, `frame_count` is number of stereo frames.
pub fn mixOutput(output: []f32, frame_count: usize) void {
    const total_samples = frame_count * CHANNELS;
    const mix_samples = @min(total_samples, output.len);
    // Zero output
    @memset(output[0..mix_samples], 0);

    // Mix sounds
    for (&sounds) |*slot| {
        if (!slot.playing) continue;
        const samples = slot.samples orelse continue;
        var i: usize = 0;
        while (i < mix_samples and slot.cursor + i < slot.sample_count) : (i += 1) {
            output[i] += samples[slot.cursor + i] * slot.volume * master_volume;
        }
        slot.cursor += i; // Advance by actual samples consumed, not total_samples
        if (slot.cursor >= slot.sample_count) {
            if (slot.looping) {
                slot.cursor = 0;
            } else {
                slot.playing = false;
                slot.cursor = 0;
            }
        }
    }

    // Mix music
    for (&musics) |*slot| {
        if (!slot.playing or slot.paused) continue;
        const samples = slot.samples orelse continue;
        var i: usize = 0;
        while (i < mix_samples and slot.cursor + i < slot.sample_count) : (i += 1) {
            output[i] += samples[slot.cursor + i] * slot.volume * master_volume;
        }
        slot.cursor += i; // Advance by actual samples consumed, not total_samples
        if (slot.cursor >= slot.sample_count) {
            if (slot.looping) {
                slot.cursor = 0;
            } else {
                slot.playing = false;
                slot.cursor = 0;
            }
        }
    }

    // Clamp output to [-1, 1]
    for (output[0..mix_samples]) |*s| {
        s.* = std.math.clamp(s.*, -1.0, 1.0);
    }
}
