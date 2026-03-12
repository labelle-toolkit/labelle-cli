/// bgfx audio backend — satisfies the engine AudioInterface(Impl) contract.
/// bgfx has no audio; this implements a minimal WAV decoder + PCM mixer
/// and exposes a software PCM mixer; actual device / ring-buffer output
/// (if any) is handled by higher-level platform code.
///
/// Thread safety:
/// `mixAudio` is designed to be called from an audio callback thread (e.g. the
/// platform's audio device callback). It reads shared state from `sounds` and
/// `music_slots` arrays and advances playback positions.
///
/// WARNING: `unloadSound` and `unloadMusic` currently have a race condition with
/// `mixAudio` — they free PCM data and reset slots while `mixAudio` may be
/// reading from them on the audio callback thread. Calling unload while the mixer
/// is active can cause use-after-free or null pointer dereference.
///
/// TODO: Add proper synchronization (mutex around slot access, or a lock-free
/// command queue) to make unload safe to call while the audio callback is active.
const std = @import("std");

const MAX_SOUNDS = 256;
const MAX_MUSIC = 32;

// ── WAV PCM data ─────────────────────────────────────────────────────

const PcmData = struct {
    samples: []const i16, // interleaved stereo PCM
    channels: u16,
    sample_rate: u32,
    frame_count: u32, // total frames (samples / channels)
    raw_alloc: []u8, // backing allocation for cleanup
};

// ── Sound state ──────────────────────────────────────────────────────

const SoundSlot = struct {
    pcm: ?PcmData = null,
    playing: bool = false,
    position: u32 = 0, // current frame position
    volume: f32 = 1.0,
};

const MusicSlot = struct {
    pcm: ?PcmData = null,
    playing: bool = false,
    paused: bool = false,
    position: u32 = 0,
    volume: f32 = 1.0,
    looping: bool = true,
};

var sounds: [MAX_SOUNDS]SoundSlot = [_]SoundSlot{.{}} ** MAX_SOUNDS;
var music_slots: [MAX_MUSIC]MusicSlot = [_]MusicSlot{.{}} ** MAX_MUSIC;
var next_sound_id: u32 = 1;
var next_music_id: u32 = 1;
var master_volume: f32 = 1.0;

// ── WAV decoder ──────────────────────────────────────────────────────

const WavHeader = extern struct {
    riff: [4]u8, // "RIFF"
    file_size: u32,
    wave: [4]u8, // "WAVE"
};

fn decodeWav(file_data: []const u8) ?PcmData {
    if (file_data.len < @sizeOf(WavHeader) + 8) return null;

    // Validate RIFF/WAVE header
    if (!std.mem.eql(u8, file_data[0..4], "RIFF")) return null;
    if (!std.mem.eql(u8, file_data[8..12], "WAVE")) return null;

    // Parse chunks to find fmt and data
    var channels: u16 = 0;
    var sample_rate: u32 = 0;
    var bits_per_sample: u16 = 0;
    var data_offset: usize = 0;
    var data_size: u32 = 0;
    var audio_format: u16 = 0;

    var offset: usize = 12; // skip RIFF header
    while (offset + 8 <= file_data.len) {
        const chunk_id = file_data[offset .. offset + 4];
        const chunk_size: usize = @intCast(std.mem.readInt(u32, file_data[offset + 4 ..][0..4], .little));

        // Validate chunk data fits within file bounds
        if (offset + 8 + chunk_size > file_data.len) break;

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            if (chunk_size < 16) return null;
            // Ensure fmt chunk has enough bytes for all fields we read (offset+24 from chunk start)
            if (offset + 24 > file_data.len) return null;
            audio_format = std.mem.readInt(u16, file_data[offset + 8 ..][0..2], .little);
            channels = std.mem.readInt(u16, file_data[offset + 10 ..][0..2], .little);
            sample_rate = std.mem.readInt(u32, file_data[offset + 12 ..][0..4], .little);
            bits_per_sample = std.mem.readInt(u16, file_data[offset + 22 ..][0..2], .little);
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            data_offset = offset + 8;
            data_size = @intCast(chunk_size);
        }

        const advance = 8 + chunk_size;
        if (offset + advance > file_data.len) break;
        offset += advance;
        // Chunks are 2-byte aligned
        if (chunk_size % 2 != 0) {
            if (offset + 1 > file_data.len) break;
            offset += 1;
        }
    }

    // Only support PCM format (1) with 16-bit samples
    if (audio_format != 1) return null;
    if (bits_per_sample != 16) return null;
    if (channels == 0 or channels > 2) return null;
    if (data_offset == 0 or data_size == 0) return null;
    if (data_offset + data_size > file_data.len) {
        // Clamp to available data
        data_size = @intCast(file_data.len - data_offset);
    }

    const data_size_usize: usize = @intCast(data_size);
    const sample_count: usize = data_size_usize / 2; // 16-bit samples
    const frame_count: u32 = @intCast(sample_count / channels);

    // Ensure PCM data is properly aligned for i16 before reinterpreting
    if (data_offset % @alignOf(i16) != 0) return null;

    // Reinterpret the raw bytes as i16 samples (WAV is always little-endian)
    const samples_ptr: [*]const i16 = @ptrCast(@alignCast(file_data[data_offset..].ptr));

    return PcmData{
        .samples = samples_ptr[0..sample_count],
        .channels = channels,
        .sample_rate = sample_rate,
        .frame_count = frame_count,
        .raw_alloc = &.{}, // will be set by caller
    };
}

fn loadWavFile(path: [:0]const u8) ?struct { pcm: PcmData, alloc: []u8 } {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    const stat = file.stat() catch return null;
    const file_size = stat.size;
    if (file_size == 0) return null;

    const allocator = std.heap.page_allocator;
    const data = allocator.alloc(u8, file_size) catch return null;

    const bytes_read = file.readAll(data) catch {
        allocator.free(data);
        return null;
    };
    if (bytes_read < 44) { // minimum WAV size
        allocator.free(data);
        return null;
    }

    var pcm = decodeWav(data[0..bytes_read]) orelse {
        allocator.free(data);
        return null;
    };
    pcm.raw_alloc = data;

    return .{ .pcm = pcm, .alloc = data };
}

// ── Sound effects ──────────────────────────────────────────

/// Find a free sound slot, scanning for recycled (unloaded) slots first,
/// then falling back to the next unused ID.
fn findFreeSoundSlot() ?u32 {
    // Scan for recycled slots (start from 1; slot 0 is reserved/unused)
    for (1..next_sound_id) |i| {
        if (sounds[i].pcm == null) {
            return @intCast(i);
        }
    }
    // Fall back to the next never-used slot
    if (next_sound_id < MAX_SOUNDS) {
        const id = next_sound_id;
        next_sound_id += 1;
        return id;
    }
    return null;
}

pub fn loadSound(path: [:0]const u8) u32 {
    const result = loadWavFile(path) orelse return 0;

    const id = findFreeSoundSlot() orelse {
        std.heap.page_allocator.free(result.alloc);
        return 0;
    };

    sounds[id] = .{
        .pcm = result.pcm,
        .playing = false,
        .position = 0,
        .volume = 1.0,
    };
    return id;
}

pub fn unloadSound(id: u32) void {
    if (id < MAX_SOUNDS) {
        if (sounds[id].pcm) |pcm| {
            if (pcm.raw_alloc.len > 0) {
                std.heap.page_allocator.free(pcm.raw_alloc);
            }
        }
        sounds[id] = .{};
    }
}

pub fn playSound(id: u32) void {
    if (id < MAX_SOUNDS) {
        sounds[id].playing = true;
        sounds[id].position = 0;
    }
}

pub fn stopSound(id: u32) void {
    if (id < MAX_SOUNDS) {
        sounds[id].playing = false;
        sounds[id].position = 0;
    }
}

pub fn isSoundPlaying(id: u32) bool {
    if (id < MAX_SOUNDS) {
        return sounds[id].playing;
    }
    return false;
}

pub fn setSoundVolume(id: u32, volume: f32) void {
    if (id < MAX_SOUNDS) {
        sounds[id].volume = std.math.clamp(volume, 0.0, 1.0);
    }
}

// ── Music (streaming) ──────────────────────────────────────

/// Find a free music slot, scanning for recycled (unloaded) slots first,
/// then falling back to the next unused ID.
fn findFreeMusicSlot() ?u32 {
    for (1..next_music_id) |i| {
        if (music_slots[i].pcm == null) {
            return @intCast(i);
        }
    }
    if (next_music_id < MAX_MUSIC) {
        const id = next_music_id;
        next_music_id += 1;
        return id;
    }
    return null;
}

pub fn loadMusic(path: [:0]const u8) u32 {
    const result = loadWavFile(path) orelse return 0;

    const id = findFreeMusicSlot() orelse {
        std.heap.page_allocator.free(result.alloc);
        return 0;
    };

    music_slots[id] = .{
        .pcm = result.pcm,
        .playing = false,
        .paused = false,
        .position = 0,
        .volume = 1.0,
        .looping = true,
    };
    return id;
}

pub fn unloadMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music_slots[id].pcm) |pcm| {
            if (pcm.raw_alloc.len > 0) {
                std.heap.page_allocator.free(pcm.raw_alloc);
            }
        }
        music_slots[id] = .{};
    }
}

pub fn playMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        music_slots[id].playing = true;
        music_slots[id].paused = false;
        music_slots[id].position = 0;
    }
}

pub fn stopMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        music_slots[id].playing = false;
        music_slots[id].paused = false;
        music_slots[id].position = 0;
    }
}

pub fn pauseMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music_slots[id].playing) {
            music_slots[id].paused = true;
        }
    }
}

pub fn resumeMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music_slots[id].paused) {
            music_slots[id].paused = false;
        }
    }
}

pub fn isMusicPlaying(id: u32) bool {
    if (id < MAX_MUSIC) {
        return music_slots[id].playing and !music_slots[id].paused;
    }
    return false;
}

pub fn setMusicVolume(id: u32, volume: f32) void {
    if (id < MAX_MUSIC) {
        music_slots[id].volume = std.math.clamp(volume, 0.0, 1.0);
    }
}

pub fn updateMusic(id: u32) void {
    // Music playback position is advanced exclusively in `mixAudio`,
    // which is driven by the audio device callback. This function is
    // kept for API compatibility but intentionally does nothing to
    // avoid frame-rate-based timing drift and duplicate advancement.
    _ = id;
}

// ── PCM mixer ────────────────────────────────────────────────────────

/// Mix all active sounds and music into a stereo i16 output buffer.
/// Called by the platform audio callback to fill the output device.
///
/// NOTE: This function reads/writes shared `sounds`/`music_slots` state.
/// Currently assumes single-threaded ownership (main thread only).
/// If called from an audio callback thread, synchronization (mutex or
/// lock-free command queue) must be added to avoid data races.
pub fn mixAudio(output: []i16, frames_requested: u32) void {
    const frame_count = @min(frames_requested, @as(u32, @intCast(output.len / 2)));

    // Clear output buffer
    const clear_len: usize = @as(usize, frame_count) * 2;
    @memset(output[0..clear_len], 0);

    // Mix active sounds
    for (0..MAX_SOUNDS) |i| {
        var slot = &sounds[i];
        if (!slot.playing) continue;
        const pcm = slot.pcm orelse continue;

        const vol = slot.volume * master_volume;
        mixPcmInto(output, frame_count, pcm, &slot.position, vol, false);

        if (slot.position >= pcm.frame_count) {
            slot.playing = false;
            slot.position = 0;
        }
    }

    // Mix active music
    for (0..MAX_MUSIC) |i| {
        var slot = &music_slots[i];
        if (!slot.playing or slot.paused) continue;
        const pcm = slot.pcm orelse continue;

        const vol = slot.volume * master_volume;
        mixPcmInto(output, frame_count, pcm, &slot.position, vol, slot.looping);

        if (!slot.looping and slot.position >= pcm.frame_count) {
            slot.playing = false;
            slot.position = 0;
        }
    }
}

fn mixPcmInto(
    output: []i16,
    frame_count: u32,
    pcm: PcmData,
    position: *u32,
    volume: f32,
    looping: bool,
) void {
    var pos = position.*;
    var frame: u32 = 0;

    while (frame < frame_count) : (frame += 1) {
        if (pos >= pcm.frame_count) {
            if (looping) {
                pos = 0;
            } else {
                break;
            }
        }

        const sample_idx: usize = @as(usize, pos) * @as(usize, pcm.channels);
        const left: f32 = @floatFromInt(pcm.samples[sample_idx]);
        const right: f32 = if (pcm.channels >= 2)
            @floatFromInt(pcm.samples[sample_idx + 1])
        else
            left; // mono: duplicate to both channels

        const out_idx: usize = @as(usize, frame) * 2;
        const mixed_l = @as(f32, @floatFromInt(output[out_idx])) + left * volume;
        const mixed_r = @as(f32, @floatFromInt(output[out_idx + 1])) + right * volume;

        // Clamp to i16 range
        output[out_idx] = @intFromFloat(std.math.clamp(mixed_l, -32768.0, 32767.0));
        output[out_idx + 1] = @intFromFloat(std.math.clamp(mixed_r, -32768.0, 32767.0));

        pos += 1;
    }

    position.* = pos;
}

// ── Global ────────────────────────────────────────────────

pub fn setVolume(volume: f32) void {
    master_volume = std.math.clamp(volume, 0.0, 1.0);
}
