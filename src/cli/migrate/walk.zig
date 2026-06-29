// ─────────────────────────────────────────────────────────────────────
// File traversal — directory walk, xref pre-scan, per-file migration
// ─────────────────────────────────────────────────────────────────────
//
// `collectPrefabRefs` (+ `walkSubdirRefs`/`scanPrefabRefs`/
// `collectPrefabRefsFromValue`) run the first pass that records every
// `{prefab: "X"}` reference. `walkAndMigrate` (+ `walkSubdir`/
// `migrateFile`) run the second pass that applies the byte transforms.

const std = @import("std");
const config = @import("../config.zig");
const scanner = @import("scanner.zig");
const pipeline = @import("pipeline.zig");

const Summary = pipeline.Summary;
const FileCounts = pipeline.FileCounts;
const TransformCtx = pipeline.TransformCtx;
const stripJsoncToJson = scanner.stripJsoncToJson;
const transformBytes = pipeline.transformBytes;
const basenameNoExt = pipeline.basenameNoExt;

/// Walk a subdir and accumulate every `{prefab: "<name>"}` string-
/// referenced name into `xrefs`. Used by transform 8 to detect the case
/// where a file declares `name: "<X>"` that differs from its basename
/// AND other files reference it as `{prefab: "<X>"}` — those references
/// must be updated by hand (or the file renamed). The migrator can't
/// auto-resolve the ambiguity, so it just emits a warning per file.
/// Walks `<project_dir>/<subdir>` and collects every `{prefab: "X"}` xref
/// into `xrefs` (which lives in the main `arena`). Uses a per-file temp
/// arena that is reset after each file so the raw bytes + JSONC-stripped
/// buffer + parsed JSON tree for one file don't accumulate in the main
/// arena across N files — on a 1000-file project that would otherwise be
/// N file buffers + N parsed trees held simultaneously until the migrator
/// finishes. The only thing that survives the per-file reset is the xref
/// name string, which `collectPrefabRefsFromValue` dupes into `arena`
/// before returning. Future contributors: if you add anything that
/// outlives one file iteration, dupe it into `arena` here too.
pub fn collectPrefabRefs(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    subdir: []const u8,
    xrefs: *std.StringHashMap(void),
) !void {
    const io = config.globalIo();
    const full = try std.fs.path.join(arena, &.{ project_dir, subdir });
    var dir = std.Io.Dir.cwd().openDir(io, full, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var temp_arena = std.heap.ArenaAllocator.init(arena);
    defer temp_arena.deinit();
    try walkSubdirRefs(arena, &temp_arena, &dir, xrefs);
}

fn walkSubdirRefs(
    arena: std.mem.Allocator,
    temp_arena: *std.heap.ArenaAllocator,
    dir: *std.Io.Dir,
    xrefs: *std.StringHashMap(void),
) !void {
    const io = config.globalIo();
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer sub.close(io);
                try walkSubdirRefs(arena, temp_arena, &sub, xrefs);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".jsonc")) continue;
                const temp = temp_arena.allocator();
                const raw = dir.readFileAlloc(io, entry.name, temp, .limited(1024 * 1024)) catch {
                    _ = temp_arena.reset(.retain_capacity);
                    continue;
                };
                scanPrefabRefs(arena, temp, raw, xrefs) catch {};
                _ = temp_arena.reset(.retain_capacity);
            },
            else => {},
        }
    }
}

/// Pull every `{prefab: "<name>"}` reference out of one file's raw
/// JSONC bytes and insert the `<name>` strings into `xrefs`. Uses the
/// shared JSONC pre-stripper + `std.json` so comments don't confuse the
/// scan; we don't care about structural context (a `prefab:` key inside
/// a deeply-nested object is still a valid reference).
///
/// `temp` is reset by the caller after each file — raw bytes, the
/// stripped JSON buffer, and the parsed tree all live in `temp`. Only
/// xref name strings get duped into `arena` (the long-lived one that
/// owns `xrefs`).
pub fn scanPrefabRefs(
    arena: std.mem.Allocator,
    temp: std.mem.Allocator,
    raw: []const u8,
    xrefs: *std.StringHashMap(void),
) !void {
    const stripped = try stripJsoncToJson(temp, raw);
    var parsed = std.json.parseFromSlice(std.json.Value, temp, stripped, .{}) catch return;
    defer parsed.deinit();
    try collectPrefabRefsFromValue(arena, parsed.value, xrefs);
}

pub fn collectPrefabRefsFromValue(
    arena: std.mem.Allocator,
    value: std.json.Value,
    xrefs: *std.StringHashMap(void),
) !void {
    switch (value) {
        .object => |obj| {
            if (obj.get("prefab")) |pv| {
                if (pv == .string) {
                    // Dedup before duping: the value lives in the
                    // per-file temp arena and will vanish on reset, so
                    // the key MUST be duped into `arena` — but only on
                    // first sight, otherwise we leak a copy per
                    // reference across the project.
                    if (!xrefs.contains(pv.string)) {
                        const name_copy = try arena.dupe(u8, pv.string);
                        try xrefs.put(name_copy, {});
                    }
                }
            }
            var it = obj.iterator();
            while (it.next()) |kv| {
                try collectPrefabRefsFromValue(arena, kv.value_ptr.*, xrefs);
            }
        },
        .array => |arr| {
            for (arr.items) |item| try collectPrefabRefsFromValue(arena, item, xrefs);
        },
        else => {},
    }
}

pub fn walkAndMigrate(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    subdir: []const u8,
    dry_run: bool,
    xrefs: *const std.StringHashMap(void),
    summary: *Summary,
) !void {
    const io = config.globalIo();
    const full = try std.fs.path.join(arena, &.{ project_dir, subdir });
    var dir = std.Io.Dir.cwd().openDir(io, full, .{ .iterate = true }) catch |err| switch (err) {
        // A missing scenes/ or prefabs/ is fine — tiny fixtures often
        // have only one of the two. The migrator just contributes zero
        // findings for that subdir; no error.
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var rel_buf: std.ArrayList(u8) = .empty;
    try rel_buf.appendSlice(arena, subdir);
    try walkSubdir(arena, &dir, full, &rel_buf, dry_run, xrefs, summary);
}

fn walkSubdir(
    arena: std.mem.Allocator,
    dir: *std.Io.Dir,
    abs_dir: []const u8,
    rel_buf: *std.ArrayList(u8),
    dry_run: bool,
    xrefs: *const std.StringHashMap(void),
    summary: *Summary,
) !void {
    const io = config.globalIo();
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const saved_rel = rel_buf.items.len;
        defer rel_buf.shrinkRetainingCapacity(saved_rel);
        try rel_buf.append(arena, std.fs.path.sep);
        try rel_buf.appendSlice(arena, entry.name);

        switch (entry.kind) {
            .directory => {
                var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer sub.close(io);
                const sub_abs = try std.fs.path.join(arena, &.{ abs_dir, entry.name });
                try walkSubdir(arena, &sub, sub_abs, rel_buf, dry_run, xrefs, summary);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".jsonc")) continue;
                try migrateFile(arena, dir, entry.name, rel_buf.items, dry_run, xrefs, summary);
            },
            else => {},
        }
    }
}

fn migrateFile(
    arena: std.mem.Allocator,
    dir: *std.Io.Dir,
    entry_name: []const u8,
    rel_path: []const u8,
    dry_run: bool,
    xrefs: *const std.StringHashMap(void),
    summary: *Summary,
) !void {
    const io = config.globalIo();
    summary.files_scanned += 1;

    const raw = dir.readFileAlloc(io, entry_name, arena, .limited(1024 * 1024)) catch |err| {
        std.debug.print("labelle migrate unified: could not read '{s}': {s}\n", .{ rel_path, @errorName(err) });
        summary.parse_errors += 1;
        return;
    };

    // Parse the JSONC-stripped form once up-front so transforms can
    // consult a structural view (top-level keys, prefab-ref objects)
    // without re-implementing JSONC tokenization.
    const stripped = stripJsoncToJson(arena, raw) catch {
        std.debug.print("labelle migrate unified: could not pre-strip '{s}'\n", .{rel_path});
        summary.parse_errors += 1;
        return;
    };
    var parsed = std.json.parseFromSlice(std.json.Value, arena, stripped, .{}) catch |err| {
        std.debug.print("labelle migrate unified: could not parse '{s}': {s}\n", .{ rel_path, @errorName(err) });
        summary.parse_errors += 1;
        return;
    };
    defer parsed.deinit();

    const basename = basenameNoExt(entry_name);
    var counts = FileCounts{};
    const ctx = TransformCtx{
        .basename = basename,
        .xrefs = xrefs,
        .rel_path = rel_path,
    };
    const out = try transformBytes(arena, raw, parsed.value, ctx, &counts);

    summary.entities_renames += counts.entities_renames;
    summary.components_renames += counts.components_renames;
    summary.assets_deletes += counts.assets_deletes;
    summary.root_wrappers_lifted += counts.root_wrappers_lifted;
    summary.overrides_lifts += counts.overrides_lifts;
    summary.components_lifts += counts.components_lifts;
    summary.file_as_array_collapses += counts.file_as_array_collapses;
    summary.name_field_drops += counts.name_field_drops;
    summary.name_field_meta_moves += counts.name_field_meta_moves;
    summary.name_field_xref_warnings += counts.name_field_xref_warnings;
    summary.directives_to_meta_moves += counts.directives_to_meta_moves;

    if (counts.totalEdits() == 0) {
        summary.files_clean += 1;
        return;
    }

    summary.files_modified += 1;
    if (dry_run) return;

    dir.writeFile(io, .{ .sub_path = entry_name, .data = out }) catch |err| {
        std.debug.print("labelle migrate unified: could not write '{s}': {s}\n", .{ rel_path, @errorName(err) });
        summary.write_errors += 1;
    };
}
