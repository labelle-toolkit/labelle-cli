/// `labelle migrate unified [dir]` — auto-fix four legacy unified-format
/// patterns the audit detects, with **comment preservation**.
///
/// Companion to `labelle audit unification` (cli#232/#236/#237 — see
/// `audit.zig`). The audit flags four legacy spellings the unified
/// loader still accepts with a one-shot warn each; engine #592 / #594
/// will remove them in v2.0. This subcommand mechanically transforms
/// them in place so projects can move to the canonical flat form
/// without hand-edits across hundreds of files.
///
/// The four transforms (idempotent — running twice on the same file
/// produces no further changes):
///
///   1. **`legacy_entities`** — top-level `"entities"` key. Rename to
///      `"children"` (post-#594 flat form drops the `"root"` wrapper).
///
///   2. **`legacy_components_on_ref`** — `"components"` on a prefab
///      *reference* (an object with a `"prefab"` sibling). Rename the
///      key to `"overrides"`. Inline-mode entities (no `"prefab"` —
///      `"components"` is the canonical shape there) are left alone.
///
///   3. **`legacy_assets`** — top-level `"assets"` array. The engine
///      ignores it (RFC #563 derives assets from sprite refs); delete
///      the line entirely, fixing up trailing commas.
///
///   4. **`legacy_root_wrapper`** — top-level `"root":` object. Lift
///      its contents to the file's top level and reduce indentation on
///      every inner line by one level (four spaces).
///
/// **Comment-preserving strategy.** A naive re-serialize would round-
/// trip through `std.json.Value` and lose every JSONC comment plus
/// reorder unchanged keys. Instead this module operates on the **raw
/// bytes** of the file, locating the target keys with a small JSONC-
/// aware scanner (strings/escape sequences/comments are respected) and
/// splicing edits in place. The original whitespace, comment lines,
/// key ordering, and trailing punctuation are preserved everywhere the
/// migrator does *not* touch.
///
/// CLI shape:
///   labelle migrate unified [dir]
///   labelle migrate unified [dir] --dry-run
///
/// Exit codes:
///   0 — clean (everything migrated or already on the flat form)
///   1 — parse failure on at least one file, or write failure

const std = @import("std");
const config = @import("config.zig");

// ─────────────────────────────────────────────────────────────────────
// Entry point — dispatch + CLI flags
// ─────────────────────────────────────────────────────────────────────

const usage =
    \\  usage: labelle migrate unified [dir] [--dry-run]
    \\
    \\Auto-fix the four legacy unified-format patterns the
    \\`labelle audit unification` subcommand detects:
    \\
    \\  1. top-level "entities" → top-level "children"
    \\  2. "components" on a prefab reference → "overrides"
    \\  3. top-level "assets" (ignored by engine) → removed
    \\  4. top-level "root" wrapper → contents lifted to top level
    \\
    \\Comments and unchanged keys are preserved byte-for-byte (the
    \\migrator operates on raw bytes, not a re-serialized parse).
    \\
    \\Exits 0 on success (clean or migrated), 1 on parse / write error.
    \\
;

pub fn cmdMigrate(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    if (cmd_args.len == 0) {
        std.debug.print("labelle migrate: missing subcommand\n", .{});
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    }
    const sub = cmd_args[0];
    if (std.mem.eql(u8, sub, "help") or std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        std.debug.print("{s}", .{usage});
        return;
    }
    if (!std.mem.eql(u8, sub, "unified")) {
        std.debug.print("labelle migrate: unknown subcommand '{s}'\n", .{sub});
        std.debug.print("{s}", .{usage});
        std.process.exit(1);
    }
    return runUnifiedMigrate(allocator, cmd_args[1..]);
}

fn runUnifiedMigrate(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    var project_dir: []const u8 = ".";
    var dir_set = false;
    var dry_run = false;
    for (cmd_args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("labelle migrate unified: unknown flag '{s}'\n", .{arg});
            std.debug.print("{s}", .{usage});
            std.process.exit(1);
        }
        if (dir_set) {
            std.debug.print("labelle migrate unified: unexpected argument '{s}' (only one project dir accepted)\n", .{arg});
            std.debug.print("{s}", .{usage});
            std.process.exit(1);
        }
        project_dir = arg;
        dir_set = true;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const A = arena.allocator();

    var summary = Summary{};
    runMigrateOn(A, project_dir, dry_run, &summary) catch |err| {
        std.debug.print("labelle migrate unified: failed on project '{s}': {s}\n", .{ project_dir, @errorName(err) });
        std.process.exit(1);
    };

    summary.print(project_dir, dry_run);
    if (summary.parse_errors > 0 or summary.write_errors > 0) std.process.exit(1);
}

// ─────────────────────────────────────────────────────────────────────
// Migrator core
// ─────────────────────────────────────────────────────────────────────

/// Per-run counts surfaced to the user. The audit's "expected counts"
/// for a given project map 1:1 onto these:
///
///   audit.legacy_entities         ↔ summary.entities_renames
///   audit.legacy_components_on_ref ↔ summary.components_renames
///   audit.legacy_assets            ↔ summary.assets_deletes
///   audit.legacy_root_wrapper      ↔ summary.root_wrappers_lifted
pub const Summary = struct {
    files_scanned: usize = 0,
    files_modified: usize = 0,
    files_clean: usize = 0,
    entities_renames: usize = 0,
    components_renames: usize = 0,
    assets_deletes: usize = 0,
    root_wrappers_lifted: usize = 0,
    parse_errors: usize = 0,
    write_errors: usize = 0,

    fn print(self: *const Summary, project_dir: []const u8, dry_run: bool) void {
        const lifted = if (dry_run) "would be lifted" else "lifted";
        const removed = if (dry_run) "would be removed" else "removed";
        const renamed = if (dry_run) "would be renamed" else "renamed";
        const modified = if (dry_run) "would be modified" else "modified";
        std.debug.print("labelle migrate unified: {s}\n", .{project_dir});
        std.debug.print("  {d} root wrapper{s} {s}\n", .{
            self.root_wrappers_lifted,
            if (self.root_wrappers_lifted == 1) "" else "s",
            lifted,
        });
        std.debug.print("  {d} legacy 'assets' key{s} {s}\n", .{
            self.assets_deletes,
            if (self.assets_deletes == 1) "" else "s",
            removed,
        });
        std.debug.print("  {d} 'entities' → 'children' rename{s} {s}\n", .{
            self.entities_renames,
            if (self.entities_renames == 1) "" else "s",
            renamed,
        });
        std.debug.print("  {d} 'components' → 'overrides' rename{s} {s}\n", .{
            self.components_renames,
            if (self.components_renames == 1) "" else "s",
            renamed,
        });
        std.debug.print("  files {s}: {d}\n", .{ modified, self.files_modified });
        std.debug.print("  files clean:        {d}\n", .{self.files_clean});
        if (self.parse_errors > 0) std.debug.print("  parse errors:       {d}\n", .{self.parse_errors});
        if (self.write_errors > 0) std.debug.print("  write errors:       {d}\n", .{self.write_errors});
    }
};

fn runMigrateOn(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    dry_run: bool,
    summary: *Summary,
) !void {
    inline for (.{ "scenes", "prefabs" }) |subdir| {
        try walkAndMigrate(arena, project_dir, subdir, dry_run, summary);
    }
}

fn walkAndMigrate(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    subdir: []const u8,
    dry_run: bool,
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
    try walkSubdir(arena, &dir, full, &rel_buf, dry_run, summary);
}

fn walkSubdir(
    arena: std.mem.Allocator,
    dir: *std.Io.Dir,
    abs_dir: []const u8,
    rel_buf: *std.ArrayList(u8),
    dry_run: bool,
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
                try walkSubdir(arena, &sub, sub_abs, rel_buf, dry_run, summary);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".jsonc")) continue;
                try migrateFile(arena, dir, entry.name, rel_buf.items, dry_run, summary);
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

    var counts = FileCounts{};
    const out = try transformBytes(arena, raw, parsed.value, &counts);

    summary.entities_renames += counts.entities_renames;
    summary.components_renames += counts.components_renames;
    summary.assets_deletes += counts.assets_deletes;
    summary.root_wrappers_lifted += counts.root_wrappers_lifted;

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

const FileCounts = struct {
    entities_renames: usize = 0,
    components_renames: usize = 0,
    assets_deletes: usize = 0,
    root_wrappers_lifted: usize = 0,

    fn totalEdits(self: FileCounts) usize {
        return self.entities_renames + self.components_renames + self.assets_deletes + self.root_wrappers_lifted;
    }
};

// ─────────────────────────────────────────────────────────────────────
// Byte-oriented transform pipeline
// ─────────────────────────────────────────────────────────────────────

/// Apply all four transforms to `src` and return a new owned buffer.
///
/// Pass order:
///   1. root-wrapper lift — runs first so the post-lift top level can
///      be reached by the subsequent top-level transforms (a file with
///      `root: { entities: [...] }` needs the lift before the entities
///      rename can see the now-top-level `entities`).
///   2. assets-delete — top-level only.
///   3. entities → children rename — top-level only.
///   4. components → overrides — walks the whole tree.
///
/// Each pass re-parses the working buffer to refresh structural info,
/// then locates the target key in the raw JSONC bytes. The whole
/// pipeline runs once; idempotency follows from each pass being a no-
/// op on already-flat files. Tests verify the second run produces
/// byte-identical output.
fn transformBytes(
    arena: std.mem.Allocator,
    src: []const u8,
    parsed_value: std.json.Value,
    counts: *FileCounts,
) ![]u8 {
    _ = parsed_value;
    var current = try arena.dupe(u8, src);

    // Pass 1 — top-level "root" wrapper lift.
    {
        const stripped = try stripJsoncToJson(arena, current);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, stripped, .{});
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("root")) |rv| {
                if (rv == .object) {
                    if (liftTopLevelRoot(arena, current)) |out| {
                        current = out;
                        counts.root_wrappers_lifted += 1;
                    }
                }
            }
        }
    }

    // Pass 2 — top-level "assets" key delete.
    {
        const stripped = try stripJsoncToJson(arena, current);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, stripped, .{});
        defer parsed.deinit();
        if (parsed.value == .object and parsed.value.object.get("assets") != null) {
            if (deleteTopLevelKey(arena, current, "assets")) |out| {
                current = out;
                counts.assets_deletes += 1;
            }
        }
    }

    // Pass 3 — top-level "entities" → "children" rename.
    {
        const stripped = try stripJsoncToJson(arena, current);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, stripped, .{});
        defer parsed.deinit();
        if (parsed.value == .object and parsed.value.object.get("entities") != null) {
            if (renameTopLevelKey(arena, current, "entities", "children")) |out| {
                current = out;
                counts.entities_renames += 1;
            }
        }
    }

    // Pass 4 — every "components" key on a prefab-ref object → "overrides".
    // Loops until no further renames are made; each rename invalidates
    // byte offsets so we re-scan after each edit. Bounded by the number
    // of prefab refs in the file (worst case O(n²) walks; n is small).
    while (true) {
        const stripped = try stripJsoncToJson(arena, current);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena, stripped, .{});
        defer parsed.deinit();
        const edited = renameOneComponentsOnRef(arena, current, parsed.value) catch null;
        if (edited) |out| {
            current = out;
            counts.components_renames += 1;
            continue;
        }
        break;
    }

    return current;
}

// ─────────────────────────────────────────────────────────────────────
// JSONC-aware byte scanner
// ─────────────────────────────────────────────────────────────────────

/// Outcome of `findTopLevelKey`. `key_start` points at the opening `"`
/// of the key string; `key_end` is one past its closing `"`. `colon`
/// points at the `:` byte that follows. `value_start` is the index of
/// the first non-whitespace value byte. `entry_start` is the position
/// of the first byte of the "key entry" — including leading whitespace
/// from the previous newline. `entry_end` is the index just past the
/// value's last byte, **excluding** any trailing comma. `comma_after`
/// is the index of the `,` that separates this entry from the next
/// sibling (or `null` if this is the last entry of the object).
const KeyLoc = struct {
    /// Index of the opening `"` of the key.
    key_start: usize,
    /// One past the closing `"` of the key.
    key_end: usize,
    /// Index of the `:` between key and value.
    colon: usize,
    /// Index of the first byte of the value (whitespace-skipped).
    value_start: usize,
    /// One past the last byte of the value.
    value_end: usize,
    /// Index of the `,` that follows this entry (if any).
    comma_after: ?usize,
    /// Index of the start-of-line of the entry (the previous `\n`+1,
    /// or the `{`+1 if this is the first sibling).
    line_start: usize,
};

/// Locate `key` as a *top-level* key in the file's outer `{ ... }`.
/// Returns `null` if not present. Strings, line/block comments are
/// respected by the scanner so a `"key"` inside a JSON string won't
/// be misidentified.
fn findTopLevelKey(src: []const u8, key: []const u8) ?KeyLoc {
    // Skip whitespace/comments to find the opening `{`.
    var i: usize = skipWsAndComments(src, 0);
    if (i >= src.len or src[i] != '{') return null;
    i += 1;

    while (true) {
        i = skipWsAndComments(src, i);
        if (i >= src.len) return null;
        if (src[i] == '}') return null;
        if (src[i] != '"') return null; // malformed; bail
        const k_start = i;
        const k_end = findStringEnd(src, k_start);
        const this_key = src[k_start + 1 .. k_end - 1];

        // Find `:`
        var j = skipWsAndComments(src, k_end);
        if (j >= src.len or src[j] != ':') return null;
        const colon_pos = j;
        j += 1;
        j = skipWsAndComments(src, j);
        const value_start = j;
        const value_end = skipValue(src, value_start);
        var k = skipWsAndComments(src, value_end);
        var comma: ?usize = null;
        if (k < src.len and src[k] == ',') {
            comma = k;
            k += 1;
        }

        if (std.mem.eql(u8, this_key, key)) {
            // Find line_start: walk back to the previous '\n'+1.
            var ls: usize = k_start;
            while (ls > 0 and src[ls - 1] != '\n') ls -= 1;
            return KeyLoc{
                .key_start = k_start,
                .key_end = k_end,
                .colon = colon_pos,
                .value_start = value_start,
                .value_end = value_end,
                .comma_after = comma,
                .line_start = ls,
            };
        }

        i = k;
    }
}

/// Return the index of the character just past the closing `"` of the
/// string starting at `start` (which must point at `"`).
fn findStringEnd(src: []const u8, start: usize) usize {
    std.debug.assert(src[start] == '"');
    var i: usize = start + 1;
    while (i < src.len) {
        const c = src[i];
        if (c == '\\' and i + 1 < src.len) {
            i += 2;
            continue;
        }
        if (c == '"') return i + 1;
        i += 1;
    }
    return src.len;
}

/// Skip past one JSON value starting at `start`. Returns the index
/// just past its last byte. Handles objects/arrays via brace counting
/// (still honoring strings and comments inside), and scalars via a
/// terminator-set.
fn skipValue(src: []const u8, start: usize) usize {
    var i = start;
    if (i >= src.len) return i;
    switch (src[i]) {
        '"' => return findStringEnd(src, i),
        '{', '[' => return skipContainer(src, i),
        else => {
            // Scalar — number / true / false / null. Read until we
            // hit a structural terminator at the current bracket depth.
            while (i < src.len) : (i += 1) {
                const c = src[i];
                if (c == ',' or c == '}' or c == ']' or c == '\n' or c == ' ' or c == '\t' or c == '\r') return i;
                if (c == '/' and i + 1 < src.len and (src[i + 1] == '/' or src[i + 1] == '*')) return i;
            }
            return i;
        },
    }
}

/// Skip a `{ ... }` or `[ ... ]` container starting at `start` (which
/// must point at `{` or `[`). Returns the index just past the matching
/// closing brace. Respects strings and JSONC comments inside.
fn skipContainer(src: []const u8, start: usize) usize {
    var depth: usize = 0;
    var i = start;
    while (i < src.len) {
        const c = src[i];
        if (c == '"') {
            i = findStringEnd(src, i);
            continue;
        }
        if (c == '/' and i + 1 < src.len) {
            if (src[i + 1] == '/') {
                while (i < src.len and src[i] != '\n') i += 1;
                continue;
            }
            if (src[i + 1] == '*') {
                i += 2;
                while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
                i = @min(src.len, i + 2);
                continue;
            }
        }
        if (c == '{' or c == '[') depth += 1;
        if (c == '}' or c == ']') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
        i += 1;
    }
    return i;
}

/// Skip whitespace and JSONC comments starting at `i`. Returns the
/// index of the first significant byte (or `src.len`).
fn skipWsAndComments(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len) {
            if (src[i + 1] == '/') {
                while (i < src.len and src[i] != '\n') i += 1;
                continue;
            }
            if (src[i + 1] == '*') {
                i += 2;
                while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
                i = @min(src.len, i + 2);
                continue;
            }
        }
        break;
    }
    return i;
}

// ─────────────────────────────────────────────────────────────────────
// Transform A — delete a top-level key (used for "assets")
// ─────────────────────────────────────────────────────────────────────

/// Delete the entire line(s) of a top-level key entry, including its
/// value and the surrounding comma. Returns a new owned buffer, or
/// `null` if the key was not found.
///
/// Trailing-comma policy: if the deleted entry was followed by a `,`
/// we drop the comma along with the entry. If it was the LAST entry
/// (no trailing comma), we drop the preceding comma instead — failing
/// to do that would leave the previous sibling with a now-illegal
/// trailing comma. The hunt-back walks past whitespace + `/* */` block
/// comments + `//` line comments to find a `,` and rewinds to just
/// before it.
fn deleteTopLevelKey(arena: std.mem.Allocator, src: []const u8, key: []const u8) ?[]u8 {
    const loc = findTopLevelKey(src, key) orelse return null;

    var cut_start: usize = loc.line_start;
    var cut_end: usize = loc.value_end;

    if (loc.comma_after) |c| {
        // Has trailing comma — eat from line start through end-of-line
        // after the comma.
        cut_end = c + 1;
        // Extend to end-of-line so we delete the entire visual line.
        while (cut_end < src.len and src[cut_end] != '\n') cut_end += 1;
        if (cut_end < src.len and src[cut_end] == '\n') cut_end += 1;
    } else {
        // Last entry — rewind cut_start to *before* the preceding `,`
        // so the previous sibling no longer has a trailing comma.
        var p: isize = @intCast(loc.line_start);
        p -= 1;
        while (p >= 0) : (p -= 1) {
            const c = src[@intCast(p)];
            if (c == ' ' or c == '\t' or c == '\r') continue;
            if (c == '\n') {
                // We just stepped into the end of the preceding line.
                // If that line is a pure `//` line-comment (only
                // whitespace before the `//`), skip the entire line so
                // the comment text isn't interpreted as code. The next
                // outer `p -= 1` will land us on the `\n` of the line
                // before that.
                const newline_idx: usize = @intCast(p);
                // Find the start of this line (the one whose `\n` we
                // are sitting on).
                var ls: usize = newline_idx;
                while (ls > 0 and src[ls - 1] != '\n') ls -= 1;
                // Scan from `ls` looking for `//` after only whitespace.
                var s: usize = ls;
                while (s < newline_idx and (src[s] == ' ' or src[s] == '\t')) s += 1;
                if (s + 1 < newline_idx and src[s] == '/' and src[s + 1] == '/') {
                    // Jump to just before the line start; outer step
                    // moves us one further (onto the prior `\n`).
                    p = @as(isize, @intCast(ls));
                    // After `continue` the for-loop runs `p -= 1`, so
                    // we want p such that p-1 lands on the byte just
                    // before `ls`. That means p = ls.
                }
                continue;
            }
            if (c == '/' and p > 0 and src[@intCast(p - 1)] == '*') {
                // Walk back through a block comment. On entry `p` is at
                // the `/` of `*/`. After this block the next outer
                // iteration's `p -= 1` must land us on the byte BEFORE
                // the `/` of `/*` — i.e. we want `p` (post-decrement) to
                // be `(index of /*-slash) - 1`. The inner loop ends with
                // `p` at the `*` of `/*`, so step one further back to
                // the `/` and let the outer step take us past it.
                p -= 2;
                while (p >= 1 and !(src[@intCast(p - 1)] == '/' and src[@intCast(p)] == '*')) p -= 1;
                if (p >= 1) p -= 1;
                continue;
            }
            if (c == ',') {
                cut_start = @intCast(p);
                break;
            }
            break; // no preceding comma — this is the only key
        }
        // Extend cut_end to end-of-line.
        while (cut_end < src.len and src[cut_end] != '\n') cut_end += 1;
        if (cut_end < src.len and src[cut_end] == '\n') cut_end += 1;
    }

    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena, src[0..cut_start]) catch return null;
    out.appendSlice(arena, src[cut_end..]) catch return null;
    return out.toOwnedSlice(arena) catch null;
}

// ─────────────────────────────────────────────────────────────────────
// Transform B — rename a top-level key (used for "entities" → "children")
// ─────────────────────────────────────────────────────────────────────

fn renameTopLevelKey(
    arena: std.mem.Allocator,
    src: []const u8,
    old: []const u8,
    new: []const u8,
) ?[]u8 {
    const loc = findTopLevelKey(src, old) orelse return null;
    // The "key" bytes between the quotes:
    //   key_start = position of opening `"`
    //   key_end   = one past closing `"`
    // The unquoted key occupies key_start+1 .. key_end-1.
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena, src[0 .. loc.key_start + 1]) catch return null;
    out.appendSlice(arena, new) catch return null;
    out.appendSlice(arena, src[loc.key_end - 1 ..]) catch return null;
    return out.toOwnedSlice(arena) catch null;
}

// ─────────────────────────────────────────────────────────────────────
// Transform C — lift `"root": { ... }` wrapper to top level
// ─────────────────────────────────────────────────────────────────────

/// Lift the contents of a top-level `"root": { ... }` object up to
/// the file's top level and de-indent each inner line by four spaces.
///
/// The shape we expect:
/// ```jsonc
/// {
///   "name": "main",
///   "root": {
///     "children": [ ... ]
///   }
/// }
/// ```
/// becomes:
/// ```jsonc
/// {
///   "name": "main",
///   "children": [ ... ]
/// }
/// ```
///
/// Implementation strategy:
///   1. Find the `"root"` key entry via `findTopLevelKey`.
///   2. The value bytes (between the inner `{` and matching `}`) are
///      the new top-level entries.
///   3. Splice: replace `"root": { …inner… }` with `…inner_dedented…`.
///   4. If `"root"` had a trailing comma after `}`, drop it iff the
///      lifted entries already end on `}` of the outer object.
fn liftTopLevelRoot(arena: std.mem.Allocator, src: []const u8) ?[]u8 {
    const loc = findTopLevelKey(src, "root") orelse return null;

    // The value must be an object — caller already checked via the
    // parsed JSON, but defend here in case of weirdness.
    if (loc.value_start >= src.len or src[loc.value_start] != '{') return null;
    // value_end points to one past the matching `}` of the value.
    const inner_open = loc.value_start; // byte at `{`
    const inner_close = loc.value_end - 1; // byte at `}`
    if (inner_close <= inner_open or src[inner_close] != '}') return null;

    // The amount we dedent each inner line by is the indent of the
    // `"root":` line itself — that puts every inner line at the same
    // column as `"root"` was, i.e. at sibling level with `"name"` etc.
    const outer_indent = loc.key_start - loc.line_start;

    // Inner body lives between the bytes just after `{` and just
    // before `}`.
    const inner_body = src[inner_open + 1 .. inner_close];

    // Trim a leading `\n` from inner_body so the lifted content starts
    // on its own line (the `\n` after `{` is no longer needed since
    // we're removing the `{`).
    var body = inner_body;
    if (body.len > 0 and body[0] == '\n') body = body[1..];

    // The closing `}` of the inner object was preceded by an indent
    // line like "    " (the outer-indent run). Strip that trailing
    // whitespace-only run so we don't emit a blank-ish line where the
    // close brace used to sit.
    if (body.len > 0 and body[body.len - 1] != '\n') {
        var t: usize = body.len;
        while (t > 0 and (body[t - 1] == ' ' or body[t - 1] == '\t')) t -= 1;
        body = body[0..t];
    }
    // After the trim above, `body` typically ends in `\n` (the newline
    // that separated the last inner entry from the close brace's
    // indent). Drop that final newline too — the splice_end below
    // starts at the close brace's `}` which is followed by its own
    // newline; keeping both would inject a blank line where the close
    // brace used to sit.
    if (body.len > 0 and body[body.len - 1] == '\n') body = body[0 .. body.len - 1];

    var dedented: std.ArrayList(u8) = .empty;
    dedentBy(arena, &dedented, body, outer_indent) catch return null;

    // Splice from the `"root":` line's indent run (line_start) through
    // the `}` of root's value (and the trailing comma if any). When the
    // `"root"` entry HAD a trailing comma (i.e. it is NOT the last key
    // of the outer object), we must re-emit that comma after the lifted
    // body — otherwise the last lifted entry runs into the next sibling
    // with no separator, producing invalid JSON. We append the comma to
    // the dedented body so it lands on the same line as the last inner
    // entry: `"children": []` becomes `"children": [],`.
    const splice_start: usize = loc.line_start;
    var splice_end: usize = loc.value_end;
    if (loc.comma_after) |c| {
        splice_end = c + 1;
        dedented.append(arena, ',') catch return null;
    }

    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena, src[0..splice_start]) catch return null;
    out.appendSlice(arena, dedented.items) catch return null;
    out.appendSlice(arena, src[splice_end..]) catch return null;
    return out.toOwnedSlice(arena) catch null;
}

/// Append `body` to `out`, removing up to `unit` leading spaces from
/// every line. Preserves blank lines as-is so authors don't lose
/// vertical structure.
fn dedentBy(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    body: []const u8,
    unit: usize,
) !void {
    var i: usize = 0;
    while (i < body.len) {
        // Strip up to `unit` leading spaces.
        var stripped: usize = 0;
        while (stripped < unit and i < body.len and body[i] == ' ') {
            stripped += 1;
            i += 1;
        }
        // Copy the rest of the line up to and including `\n`.
        while (i < body.len) {
            try out.append(arena, body[i]);
            if (body[i] == '\n') {
                i += 1;
                break;
            }
            i += 1;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Transform D — rename `"components"` → `"overrides"` on prefab refs
// ─────────────────────────────────────────────────────────────────────

/// Walk the parsed tree; find the first object that has *both* a
/// `"prefab"` (string) sibling and a `"components"` sibling. Locate
/// that `"components"` key in the raw bytes and rename it in place.
/// Returns the edited buffer, or `null` if no such object exists.
/// Callers loop on this so each renaming step works against a freshly
/// re-parsed tree (byte offsets shift after each edit).
fn renameOneComponentsOnRef(
    arena: std.mem.Allocator,
    src: []const u8,
    parsed_value: std.json.Value,
) !?[]u8 {
    // Walk parsed JSON to determine WHETHER a target exists (cheap,
    // exact). Then walk the raw bytes to locate it.
    if (!treeHasComponentsOnRef(parsed_value)) return null;
    return findAndRenameComponentsOnRef(arena, src);
}

fn treeHasComponentsOnRef(value: std.json.Value) bool {
    switch (value) {
        .object => |obj| {
            const has_prefab = blk: {
                const v = obj.get("prefab") orelse break :blk false;
                break :blk v == .string;
            };
            const has_components = obj.get("components") != null;
            if (has_prefab and has_components) return true;
            var it = obj.iterator();
            while (it.next()) |kv| {
                if (treeHasComponentsOnRef(kv.value_ptr.*)) return true;
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (treeHasComponentsOnRef(item)) return true;
            }
        },
        else => {},
    }
    return false;
}

/// Byte-level walker: locate the first object literal `{ ... }` that
/// contains both a `"prefab"` (string-valued) and a `"components"`
/// sibling key, and return the buffer with that `"components"` key
/// renamed to `"overrides"`.
fn findAndRenameComponentsOnRef(arena: std.mem.Allocator, src: []const u8) ?[]u8 {
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == '"') {
            i = findStringEnd(src, i);
            continue;
        }
        if (src[i] == '/' and i + 1 < src.len) {
            if (src[i + 1] == '/') {
                while (i < src.len and src[i] != '\n') i += 1;
                continue;
            }
            if (src[i + 1] == '*') {
                i += 2;
                while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
                i = @min(src.len, i + 2);
                continue;
            }
        }
        if (src[i] == '{') {
            const obj_end = skipContainer(src, i);
            if (objectHasPrefabStringAndComponents(src, i, obj_end)) |components_key_loc| {
                var out: std.ArrayList(u8) = .empty;
                out.appendSlice(arena, src[0 .. components_key_loc + 1]) catch return null;
                out.appendSlice(arena, "overrides") catch return null;
                out.appendSlice(arena, src[components_key_loc + 1 + "components".len ..]) catch return null;
                return out.toOwnedSlice(arena) catch null;
            }
            i += 1;
            continue;
        }
        i += 1;
    }
    return null;
}

/// Scan one object literal (delimited by `[start_brace, end_one_past)`)
/// for sibling keys `"prefab"` (string-valued) and `"components"`. If
/// both are present, return the byte index of the opening `"` of the
/// `"components"` key. Skips into nested `{...}` and `[...]` so they
/// don't contaminate the sibling check.
fn objectHasPrefabStringAndComponents(src: []const u8, start_brace: usize, end_one_past: usize) ?usize {
    var i = start_brace + 1; // past `{`
    var prefab_is_string = false;
    var components_pos: ?usize = null;

    while (i < end_one_past) {
        i = skipWsAndComments(src, i);
        if (i >= end_one_past) break;
        if (src[i] == '}') break;
        if (src[i] != '"') {
            // Malformed for our purposes; bail.
            return null;
        }
        const k_start = i;
        const k_end = findStringEnd(src, k_start);
        const key = src[k_start + 1 .. k_end - 1];
        var j = skipWsAndComments(src, k_end);
        if (j >= end_one_past or src[j] != ':') return null;
        j += 1;
        j = skipWsAndComments(src, j);
        const v_start = j;
        const v_end = skipValue(src, v_start);

        if (std.mem.eql(u8, key, "prefab")) {
            if (v_start < src.len and src[v_start] == '"') prefab_is_string = true;
        } else if (std.mem.eql(u8, key, "components")) {
            components_pos = k_start;
        }

        // Skip past the value and optional trailing comma.
        var k = skipWsAndComments(src, v_end);
        if (k < end_one_past and src[k] == ',') k += 1;
        i = k;
    }

    if (prefab_is_string and components_pos != null) return components_pos;
    return null;
}

// ─────────────────────────────────────────────────────────────────────
// JSONC → JSON pre-stripper (copied from audit.zig — keeps this module
// self-contained, and the two stay in sync via the shared tests).
// ─────────────────────────────────────────────────────────────────────

fn stripJsoncToJson(arena: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);
    try out.ensureTotalCapacity(arena, src.len);

    var i: usize = 0;
    var in_string = false;
    while (i < src.len) {
        const c = src[i];
        if (in_string) {
            try out.append(arena, c);
            if (c == '\\' and i + 1 < src.len) {
                try out.append(arena, src[i + 1]);
                i += 2;
                continue;
            }
            if (c == '"') in_string = false;
            i += 1;
            continue;
        }
        if (c == '"') {
            in_string = true;
            try out.append(arena, c);
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len) {
            if (src[i + 1] == '/') {
                i += 2;
                while (i < src.len and src[i] != '\n') i += 1;
                continue;
            }
            if (src[i + 1] == '*') {
                i += 2;
                while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
                i = @min(src.len, i + 2);
                continue;
            }
        }
        if (c == ',') {
            var j = i + 1;
            while (j < src.len) : (j += 1) {
                const cc = src[j];
                if (cc == ' ' or cc == '\t' or cc == '\n' or cc == '\r') continue;
                if (cc == '/' and j + 1 < src.len and (src[j + 1] == '/' or src[j + 1] == '*')) {
                    if (src[j + 1] == '/') {
                        while (j < src.len and src[j] != '\n') j += 1;
                    } else {
                        j += 2;
                        while (j + 1 < src.len and !(src[j] == '*' and src[j + 1] == '/')) j += 1;
                        j += 1;
                    }
                    continue;
                }
                break;
            }
            if (j < src.len and (src[j] == ']' or src[j] == '}')) {
                i += 1;
                continue;
            }
        }
        try out.append(arena, c);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

// ─────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────

const expect = @import("zspec").expect;

test {
    @import("zspec").runAll(@This());
}

/// Run all four transforms on `src` and return the result, allocated
/// in `arena`. Helper for tests that don't care about per-pass counts.
fn applyAll(arena: std.mem.Allocator, src: []const u8) ![]u8 {
    const stripped = try stripJsoncToJson(arena, src);
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, stripped, .{});
    defer parsed.deinit();
    var counts = FileCounts{};
    return try transformBytes(arena, src, parsed.value, &counts);
}

/// Convenience for tests — runs `applyAll` against an arena so call
/// sites don't have to track every intermediate allocation produced
/// by the byte-level edit pipeline. Returns the final transformed
/// buffer (which lives inside the arena, so the caller just needs to
/// keep the arena alive for the duration of the assertions).
fn applyAllArena(arena: *std.heap.ArenaAllocator, src: []const u8) ![]const u8 {
    return try applyAll(arena.allocator(), src);
}

pub const TransformRootWrapperSpec = struct {
    pub const lifts_simple_wrapper = struct {
        test "lifts `\"root\": { \"children\": [] }` and de-indents" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"root\": {\n" ++
                "        \"children\": []\n" ++
                "    }\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            const expected =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"children\": []\n" ++
                "}\n";
            try std.testing.expectEqualStrings(expected, out);
        }
    };

    pub const preserves_comments = struct {
        test "comments on lifted children survive" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    // top-level note stays put\n" ++
                "    \"root\": {\n" ++
                "        // inner note moves up one indent\n" ++
                "        \"children\": [\n" ++
                "            { \"prefab\": \"x\" } // inline note\n" ++
                "        ]\n" ++
                "    }\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            // The three comments must all still appear, verbatim.
            try std.testing.expect(std.mem.indexOf(u8, out, "// top-level note stays put") != null);
            try std.testing.expect(std.mem.indexOf(u8, out, "// inner note moves up one indent") != null);
            try std.testing.expect(std.mem.indexOf(u8, out, "// inline note") != null);
            // And the `"root"` wrapper is gone.
            try std.testing.expect(std.mem.indexOf(u8, out, "\"root\"") == null);
        }
    };

    pub const root_in_middle_of_metadata = struct {
        // Regression for cursor[bot] finding: when `"root"` is not the
        // LAST top-level key (i.e. has a trailing comma) the lift used to
        // consume the comma but never re-emit it, producing invalid JSON
        // like `..."children": []"metadata": "x"...`.
        test "root in middle of metadata keys produces valid JSON" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"root\": {\n" ++
                "        \"children\": []\n" ++
                "    },\n" ++
                "    \"metadata\": \"x\"\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            // Must round-trip through the JSON parser.
            const stripped = try stripJsoncToJson(arena.allocator(), out);
            var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
            defer parsed.deinit();
            const obj = parsed.value.object;
            try std.testing.expect(obj.get("root") == null);
            try std.testing.expect(obj.get("children") != null);
            try std.testing.expectEqualStrings("main", obj.get("name").?.string);
            try std.testing.expectEqualStrings("x", obj.get("metadata").?.string);
        }

        test "root in middle with trailing comma on its own line" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"root\": {\n" ++
                "        \"children\": []\n" ++
                "    }\n" ++
                "    ,\n" ++
                "    \"metadata\": \"x\"\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            const stripped = try stripJsoncToJson(arena.allocator(), out);
            var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
            defer parsed.deinit();
            const obj = parsed.value.object;
            try std.testing.expect(obj.get("root") == null);
            try std.testing.expect(obj.get("children") != null);
            try std.testing.expectEqualStrings("x", obj.get("metadata").?.string);
        }

        // Adversarial: root not last, a `//` line comment between two
        // outer-level keys, and a `/* */` block comment elsewhere. The
        // whole file must round-trip through the JSON parser after the
        // lift.
        test "root in middle with mixed line + block comments around" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    // line note between name and root\n" ++
                "    \"root\": {\n" ++
                "        /* inside-root block note */\n" ++
                "        \"children\": []\n" ++
                "    },\n" ++
                "    \"metadata\": \"x\"\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            const stripped = try stripJsoncToJson(arena.allocator(), out);
            var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
            defer parsed.deinit();
            const obj = parsed.value.object;
            try std.testing.expect(obj.get("root") == null);
            try std.testing.expect(obj.get("children") != null);
            try std.testing.expectEqualStrings("main", obj.get("name").?.string);
            try std.testing.expectEqualStrings("x", obj.get("metadata").?.string);
        }

        test "root in middle with line comment between `}` and next key" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"root\": {\n" ++
                "        \"children\": []\n" ++
                "    }, // close root\n" ++
                "    \"metadata\": \"x\"\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            const stripped = try stripJsoncToJson(arena.allocator(), out);
            var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
            defer parsed.deinit();
            const obj = parsed.value.object;
            try std.testing.expect(obj.get("root") == null);
            try std.testing.expect(obj.get("children") != null);
            try std.testing.expectEqualStrings("x", obj.get("metadata").?.string);
        }
    };
};

pub const DeleteTopLevelKeyBlockCommentSpec = struct {
    // Regression for cursor[bot] finding: the backward walk that looks
    // for the preceding comma when the target key is the LAST entry used
    // to land one byte too late after skipping a `/* ... */` block. The
    // outer `p -= 1` from the for-loop then put `p` on the `/` of `/*`,
    // which broke the walk early and left the preceding sibling with a
    // dangling `,` — producing invalid JSON.
    test "deletes last key preceded by a block comment" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    /* trailing note */\n" ++
            "    \"assets\": [\"a\"]\n" ++
            "}\n";
        const out = try applyAllArena(&arena, src);
        // Pre-fix the backward walk lost the preceding `,` because it
        // landed on the `/` of `/*` and broke. The trailing comma after
        // `"main"` MUST be removed — otherwise the raw .jsonc parses as
        // {"name":"main",} which is illegal JSON (the JSONC-stripper
        // happens to forgive trailing commas, but a strict reader does
        // not).
        try std.testing.expect(std.mem.indexOf(u8, out, "\"assets\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"main\",") == null);
        // And it must round-trip through the JSON parser too.
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("main", parsed.value.object.get("name").?.string);
    }

    // Regression for cursor[bot] finding: the backward walk that looks
    // for the preceding comma when the target key is the LAST entry
    // claims (per its doc) to skip "whitespace + comments", but only
    // handled `/* ... */` block comments — never `//` line comments. A
    // `//` comment sitting on its own line between the preceding comma
    // and the deleted key made the walk hit the comment text and break
    // before finding the comma — leaving a dangling trailing comma on
    // the preceding sibling and producing invalid strict JSON.
    test "deletes last key preceded by a `//` line comment" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    // trailing note\n" ++
            "    \"assets\": [\"a\"]\n" ++
            "}\n";
        const out = try applyAllArena(&arena, src);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"assets\"") == null);
        // Trailing comma on `"main"` must be gone.
        try std.testing.expect(std.mem.indexOf(u8, out, "\"main\",") == null);
        // Round-trip through the JSON parser to be safe.
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("main", parsed.value.object.get("name").?.string);
    }

    // Adversarial: both kinds of comments interleaved before the
    // deleted last-key.
    test "deletes last key preceded by mixed `//` and `/* */` comments" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    // line note\n" ++
            "    /* block note */\n" ++
            "    \"assets\": [\"a\"]\n" ++
            "}\n";
        const out = try applyAllArena(&arena, src);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"assets\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"main\",") == null);
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("main", parsed.value.object.get("name").?.string);
    }
};

pub const TransformEntitiesRenameSpec = struct {
    test "top-level `entities` becomes `children`" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    \"entities\": [\n" ++
            "        { \"prefab\": \"x\" }\n" ++
            "    ]\n" ++
            "}\n";
        const out = try applyAllArena(&arena, src);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"children\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"entities\"") == null);
    }
};

pub const TransformComponentsOnRefSpec = struct {
    pub const renames_when_prefab_sibling = struct {
        test "`components` next to `prefab` becomes `overrides`" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"children\": [\n" ++
                "        { \"prefab\": \"x\", \"components\": { \"Position\": { \"x\": 1 } } }\n" ++
                "    ]\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\"") != null);
            // No more `"components"` key (the value's nested keys
            // happen not to use the word, so a substring search is OK).
            try std.testing.expect(std.mem.indexOf(u8, out, "\"components\"") == null);
        }
    };

    pub const leaves_inline_components_alone = struct {
        test "inline `components` without `prefab` is the canonical shape and stays" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"children\": [\n" ++
                "        { \"components\": { \"Position\": { \"x\": 1 } } }\n" ++
                "    ]\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            try std.testing.expect(std.mem.indexOf(u8, out, "\"components\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, out, "\"overrides\"") == null);
        }
    };
};

pub const TransformAssetsDeleteSpec = struct {
    pub const deletes_with_trailing_comma = struct {
        test "drops `\"assets\": [...]` line entirely" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"assets\": [\"a\", \"b\"],\n" ++
                "    \"children\": []\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            try std.testing.expect(std.mem.indexOf(u8, out, "\"assets\"") == null);
            try std.testing.expect(std.mem.indexOf(u8, out, "\"children\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, out, "\"name\"") != null);
        }
    };

    pub const deletes_when_last_key = struct {
        test "drops preceding comma when `assets` is the last entry" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const src =
                "{\n" ++
                "    \"name\": \"main\",\n" ++
                "    \"assets\": [\"a\"]\n" ++
                "}\n";
            const out = try applyAllArena(&arena, src);
            // Must still parse as valid JSON (no dangling comma).
            const stripped = try stripJsoncToJson(arena.allocator(), out);
            var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
            defer parsed.deinit();
            try std.testing.expect(parsed.value.object.get("assets") == null);
            try std.testing.expectEqualStrings("main", parsed.value.object.get("name").?.string);
        }
    };
};

pub const IdempotencySpec = struct {
    test "running the migrator twice produces the same bytes" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    \"assets\": [\"a\"],\n" ++
            "    \"root\": {\n" ++
            "        \"children\": [\n" ++
            "            { \"prefab\": \"x\", \"components\": { \"Position\": { \"x\": 1 } } }\n" ++
            "        ]\n" ++
            "    }\n" ++
            "}\n";
        const once = try applyAllArena(&arena, src);
        const twice = try applyAllArena(&arena, once);
        try std.testing.expectEqualStrings(once, twice);
    }
};

pub const MixedFileSpec = struct {
    test "all four transforms in one file" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const src =
            "{\n" ++
            "    \"name\": \"main\",\n" ++
            "    \"assets\": [\"a\"],\n" ++
            "    \"root\": {\n" ++
            "        \"entities\": [\n" ++
            "            { \"prefab\": \"x\", \"components\": { \"Position\": { \"x\": 1 } } }\n" ++
            "        ]\n" ++
            "    }\n" ++
            "}\n";
        const out = try applyAllArena(&arena, src);

        // Must parse + have the expected post-migration shape.
        const stripped = try stripJsoncToJson(arena.allocator(), out);
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try std.testing.expect(obj.get("assets") == null);
        try std.testing.expect(obj.get("root") == null);
        try std.testing.expect(obj.get("entities") == null);
        try std.testing.expect(obj.get("children") != null);
        const child0 = obj.get("children").?.array.items[0].object;
        try std.testing.expect(child0.get("components") == null);
        try std.testing.expect(child0.get("overrides") != null);
    }
};
