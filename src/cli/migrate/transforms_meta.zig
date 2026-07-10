// ─────────────────────────────────────────────────────────────────────
// RFC #596 meta / directive transforms G–I
// ─────────────────────────────────────────────────────────────────────
//
//   G — top-level `name:` → `meta.name` or drop
//   H — file-level directives → meta block
//   I — collapse file-level wrapping object to array
//
// These splice raw JSONC bytes using the scanner primitives and reuse
// `deleteTopLevelKey`/`dedentBy` from `transforms.zig`.

const std = @import("std");
const scanner = @import("scanner.zig");
const transforms = @import("transforms.zig");

const findTopLevelKey = scanner.findTopLevelKey;
const findStringEnd = scanner.findStringEnd;
const skipValue = scanner.skipValue;
const skipContainer = scanner.skipContainer;
const skipWsAndComments = scanner.skipWsAndComments;
const deleteTopLevelKey = transforms.deleteTopLevelKey;

// ─────────────────────────────────────────────────────────────────────
// Transform G (RFC #596) — top-level `name:` → `meta.name` or drop
// ─────────────────────────────────────────────────────────────────────

/// Move a top-level `name: "<X>"` field into `meta.name`. Two shapes:
///   1. `meta:` already exists — for now we just rename the `name:` key
///      to `meta.name`-style by emitting a `meta: { name: "<X>" }`
///      wrapper alongside the existing meta block (we don't merge, just
///      ensure both are valid keys — but JSON doesn't allow duplicate
///      keys, so the proper fix is to actually merge). The `has_meta`
///      branch falls back to leaving the existing meta alone and only
///      drops the bare `name:` — this is a conservative choice; the
///      audit will re-flag the divergent name on the next pass and a
///      human can hand-merge.
///   2. No `meta:` — rename the `name:` key in place to `meta`, and
///      wrap its string value `"<X>"` as `{ "name": "<X>" }`. Cheap and
///      preserves the original line structure.
pub fn moveNameToMeta(arena: std.mem.Allocator, src: []const u8, has_meta: bool) ?[]u8 {
    if (has_meta) {
        // Conservative: leave the existing `meta:` block alone (merging
        // is structurally risky to do byte-level). Just drop the bare
        // `name:` so the audit only re-fires for divergent-name files
        // that actually NEED human attention. This case is also rare
        // enough across FP / bouncing-ball that the simpler behaviour
        // is preferable to a half-correct merge. If/when we see a real
        // case in the smoke run we'll extend this.
        return deleteTopLevelKey(arena, src, "name");
    }
    // Find the `"name"` key; rewrite as `"meta": { "name": "<X>" }`.
    const loc = findTopLevelKey(src, "name") orelse return null;
    if (loc.value_start >= src.len or src[loc.value_start] != '"') return null;
    const v_end = loc.value_end; // one past the value's closing `"`
    // Re-emit:
    //   <before key_start> "meta": { "name": <orig value string> } <after v_end>
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena, src[0..loc.key_start]) catch return null;
    out.appendSlice(arena, "\"meta\": { \"name\": ") catch return null;
    out.appendSlice(arena, src[loc.value_start..v_end]) catch return null;
    out.appendSlice(arena, " }") catch return null;
    out.appendSlice(arena, src[v_end..]) catch return null;
    return out.toOwnedSlice(arena) catch null;
}

// ─────────────────────────────────────────────────────────────────────
// Transform H (RFC #596 update) — file-level directives → meta block
// ─────────────────────────────────────────────────────────────────────

/// Return true if `key` looks like an "entity-shape" key — either a
/// component override (PascalCase: first ASCII letter is uppercase) or
/// a structural key the per-entity layer owns (`prefab`). The file-as-
/// array collapse and the directives-to-meta transform both refuse to
/// touch files whose top level contains any such key — that's the
/// "single root entity at file top-level" case, which doesn't map to
/// the bundle shape (yet).
pub fn isEntityShapeKey(key: []const u8) bool {
    if (key.len == 0) return false;
    if (std.mem.eql(u8, key, "prefab")) return true;
    const c = key[0];
    return c >= 'A' and c <= 'Z';
}

/// Engine-known file-header directive names per RFC #596 (updated). The
/// migrator treats these as the canonical "must move into meta" set;
/// any other lowercase non-structural top-level key (custom author
/// keys) ALSO flows into meta — they have no other home post-bundle.
pub fn isStructuralFileKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "name") or
        std.mem.eql(u8, key, "meta") or
        std.mem.eql(u8, key, "children");
}

/// Find one top-level key that should be moved into `meta:` and return
/// the rewritten buffer. Returns `null` when no eligible key remains
/// (fixed point reached). Only fires when:
///   - file's top-level is an object,
///   - it contains no entity-shape keys (no PascalCase, no `prefab`),
///   - at least one lowercase non-structural key (not `name`, not
///     `meta`, not `children`) is present.
/// The presence of `children:` is NOT required — the rare "directives
/// only, no children" file also routes through this transform so that
/// pass 9 can emit a header-only bundle.
pub fn moveOneDirectiveToMeta(
    arena: std.mem.Allocator,
    src: []const u8,
    parsed_value: std.json.Value,
) !?[]u8 {
    if (parsed_value != .object) return null;
    const obj = parsed_value.object;
    // Reject if any entity-shape key is present.
    var it = obj.iterator();
    while (it.next()) |kv| {
        if (isEntityShapeKey(kv.key_ptr.*)) return null;
    }
    // Find the first eligible key to move (skip structural keys).
    it = obj.iterator();
    const target_key: []const u8 = while (it.next()) |kv| {
        const k = kv.key_ptr.*;
        if (isStructuralFileKey(k)) continue;
        break k;
    } else return null;

    // Locate the key in the raw bytes and capture its value bytes.
    const loc = findTopLevelKey(src, target_key) orelse return null;
    const value_bytes = src[loc.value_start..loc.value_end];

    // Drop the directive from the file (handles trailing/leading
    // comma fixup correctly — already proven by `deleteTopLevelKey`).
    const without_directive = deleteTopLevelKey(arena, src, target_key) orelse return null;

    // Now insert the directive into a `meta:` block. If `meta:` is
    // absent we create one; if present we merge.
    const has_meta = obj.get("meta") != null;
    if (has_meta) {
        return try mergeIntoExistingMeta(arena, without_directive, target_key, value_bytes);
    }
    return try insertNewMeta(arena, without_directive, target_key, value_bytes);
}

/// Insert a new top-level `"meta": { "<key>": <value> }` entry into
/// `src`. The new entry is placed at the very top of the outer object
/// (right after `{` + the first newline) so the file's structural
/// layout starts with the bundle-header-to-be.
pub fn insertNewMeta(
    arena: std.mem.Allocator,
    src: []const u8,
    key: []const u8,
    value_bytes: []const u8,
) !?[]u8 {
    // Find the file's outer `{`.
    const file_start = skipWsAndComments(src, 0);
    if (file_start >= src.len or src[file_start] != '{') return null;
    // Probe the object's first key (if any) to determine the indent
    // we should match. Default to four spaces if the object is empty.
    var indent_buf: [16]u8 = [_]u8{' '} ** 16;
    var indent_len: usize = 4;
    {
        var i: usize = file_start + 1;
        // Skip whitespace and comments to find first key.
        i = skipWsAndComments(src, i);
        if (i < src.len and src[i] == '"') {
            // Walk back to the line start to measure the indent.
            var ls: usize = i;
            while (ls > 0 and src[ls - 1] != '\n') ls -= 1;
            const measured = i - ls;
            if (measured > 0 and measured <= indent_buf.len) {
                indent_len = measured;
                // Copy real indent bytes (may be tabs).
                var k: usize = 0;
                while (k < measured) : (k += 1) indent_buf[k] = src[ls + k];
            }
        }
    }
    const indent = indent_buf[0..indent_len];

    // Compose: <pre `{`><...> + `\n<indent>"meta": { "<key>": <value> },`
    //        + <existing inside-`{` content>.
    var out: std.ArrayList(u8) = .empty;
    // Bytes through and including `{`.
    out.appendSlice(arena, src[0 .. file_start + 1]) catch return null;
    // If the existing first byte after `{` is `\n`, eat it (we'll add
    // our own newline below). Otherwise leave whatever is there alone.
    var rest_start: usize = file_start + 1;
    if (rest_start < src.len and src[rest_start] == '\n') {
        rest_start += 1;
    }
    // Emit the inserted meta entry on its own line, with a trailing
    // comma so it slots in front of whatever existed.
    out.append(arena, '\n') catch return null;
    out.appendSlice(arena, indent) catch return null;
    out.appendSlice(arena, "\"meta\": { \"") catch return null;
    out.appendSlice(arena, key) catch return null;
    out.appendSlice(arena, "\": ") catch return null;
    out.appendSlice(arena, value_bytes) catch return null;
    out.appendSlice(arena, " }") catch return null;
    // Determine whether the original object had any remaining content
    // after the `{` — if so, append a comma + the rest. If the object
    // is empty (just `{}` post-deletion), no comma needed.
    var probe: usize = rest_start;
    probe = skipWsAndComments(src, probe);
    const has_more = probe < src.len and src[probe] != '}';
    if (has_more) {
        out.append(arena, ',') catch return null;
    }
    out.append(arena, '\n') catch return null;
    out.appendSlice(arena, src[rest_start..]) catch return null;
    return out.toOwnedSlice(arena) catch null;
}

/// Merge `<key>: <value>` into an existing top-level `meta: { ... }`
/// block. The new entry is appended right before the closing `}` of
/// the meta object, with a leading `,` if the meta object isn't empty.
pub fn mergeIntoExistingMeta(
    arena: std.mem.Allocator,
    src: []const u8,
    key: []const u8,
    value_bytes: []const u8,
) !?[]u8 {
    const loc = findTopLevelKey(src, "meta") orelse return null;
    if (loc.value_start >= src.len or src[loc.value_start] != '{') return null;
    const meta_open = loc.value_start; // `{`
    const meta_close = loc.value_end - 1; // `}`
    if (meta_close <= meta_open or src[meta_close] != '}') return null;

    // Probe to see whether the meta object is empty.
    var probe: usize = meta_open + 1;
    probe = skipWsAndComments(src, probe);
    const empty = probe >= meta_close;

    var out: std.ArrayList(u8) = .empty;
    // Everything up to and including the meta-close-brace's prior byte.
    // We splice in just before the `}`.
    var splice_at: usize = meta_close;
    // Trim any trailing whitespace right before `}` so our injection
    // does not produce e.g. `..., \n }` with awkward spacing. Keep one
    // space for readability.
    while (splice_at > meta_open + 1) {
        const c = src[splice_at - 1];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            splice_at -= 1;
            continue;
        }
        break;
    }
    // JSONC allows a trailing comma before `}`. If the last structural
    // byte is already a `,`, we must NOT prepend another `,` — that
    // would yield `..., , "newkey": ...` (invalid JSON). Detect it and
    // suppress the prepended separator.
    const has_trailing_comma = !empty and splice_at > meta_open + 1 and
        src[splice_at - 1] == ',';
    out.appendSlice(arena, src[0..splice_at]) catch return null;
    if (!empty and !has_trailing_comma) {
        out.appendSlice(arena, ", ") catch return null;
    } else {
        out.append(arena, ' ') catch return null;
    }
    out.append(arena, '"') catch return null;
    out.appendSlice(arena, key) catch return null;
    out.appendSlice(arena, "\": ") catch return null;
    out.appendSlice(arena, value_bytes) catch return null;
    out.append(arena, ' ') catch return null;
    out.appendSlice(arena, src[splice_at..]) catch return null;
    return out.toOwnedSlice(arena) catch null;
}

// ─────────────────────────────────────────────────────────────────────
// Transform I (RFC #596) — collapse file-level wrapping object to array
// ─────────────────────────────────────────────────────────────────────

/// File top-level is `{...}` whose only entity-bearing key is
/// `children:` (no `prefab`, no PascalCase components). A sibling
/// `meta:` block is now ACCEPTED — `collapseFileToArray` emits it as
/// the bundle's first element. Likewise the rare "meta only, no
/// children" file is accepted and collapses to `[ {meta: {...}} ]`.
///
/// Any other top-level key (lowercase non-structural, e.g. an
/// `initial_state` directive that the upstream `moveOneDirectiveToMeta`
/// pass missed) blocks the collapse — the audit will re-fire and a
/// human can decide.
pub fn shouldCollapseFileToArray(value: std.json.Value) bool {
    if (value != .object) return false;
    const obj = value.object;
    const has_children = obj.get("children") != null;
    const has_meta = obj.get("meta") != null;
    // Need at least one of `children:` or `meta:` to have anything to
    // emit. The empty `{}` case is rejected — that's a malformed file,
    // not a bundle.
    if (!has_children and !has_meta) return false;
    // Reject anything that adds semantic content we can't carry through.
    // The two accepted structural keys at this stage are `children:` and
    // `meta:`. PascalCase, `prefab:`, and any other lowercase key block
    // the collapse.
    var it = obj.iterator();
    while (it.next()) |kv| {
        const k = kv.key_ptr.*;
        if (std.mem.eql(u8, k, "children")) continue;
        if (std.mem.eql(u8, k, "meta")) continue;
        return false;
    }
    return true;
}

/// Rewrite `{...children: [...]...}` to `[...]`. Pre-{ content stays as
/// header (typically: nothing, or a leading `//` file note). Between-`{`-
/// and-`"children":` content is preserved if it's comment-only — we walk
/// each line and keep any line whose only non-whitespace is a `//` or
/// `/* */` comment, dropping the lines that hold the just-dropped/just-
/// moved siblings (e.g. the empty trailing comma after `name:` got
/// removed by pass 7).
///
/// When a sibling `meta:` block exists, the bundle gains a header
/// element: `[ {meta: {...}}, ...children-items ]`. When ONLY `meta:`
/// is present (no `children:`), the result is `[ {meta: {...}} ]` —
/// the rare directives-only file edge case.
pub fn collapseFileToArray(arena: std.mem.Allocator, src: []const u8, parsed_value: std.json.Value) ?[]u8 {
    // Find the file's outer `{` and matching `}`.
    const file_start = skipWsAndComments(src, 0);
    if (file_start >= src.len or src[file_start] != '{') return null;
    const file_end = skipContainer(src, file_start);
    if (file_end > src.len or src[file_end - 1] != '}') return null;

    // Capture the meta value bytes if a `meta:` block is present —
    // it becomes the bundle's first element.
    var meta_value_bytes: ?[]const u8 = null;
    if (parsed_value == .object and parsed_value.object.get("meta") != null) {
        if (findTopLevelKey(src, "meta")) |mloc| {
            meta_value_bytes = src[mloc.value_start..mloc.value_end];
        }
    }

    // Special case: file has `meta:` but NO `children:`. Emit a
    // header-only bundle.
    if (parsed_value == .object and parsed_value.object.get("children") == null) {
        const meta_bytes = meta_value_bytes orelse return null;
        const pre_header = src[0..file_start];
        const footer = if (file_end < src.len) src[file_end..] else "";
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(arena, pre_header) catch return null;
        out.appendSlice(arena, "[\n    { \"meta\": ") catch return null;
        out.appendSlice(arena, meta_bytes) catch return null;
        out.appendSlice(arena, " }\n]") catch return null;
        // Preserve trailing newline if present in footer.
        out.appendSlice(arena, footer) catch return null;
        return out.toOwnedSlice(arena) catch null;
    }

    // Find the `children` key.
    const loc = findTopLevelKey(src, "children") orelse return null;
    if (loc.value_start >= src.len or src[loc.value_start] != '[') return null;
    // The array literal occupies [value_start, value_end).
    const arr_start = loc.value_start;
    const arr_end = loc.value_end;

    // Outer indent = the column of the `"children":` key (its line's
    // leading-space run). Computed ONCE here and reused by both the
    // comment-harvest dedent and the array-body dedent below — the
    // wrapping `{` added exactly this many spaces to every inner line,
    // and post-collapse the `[` lands at column 0.
    const outer_indent = blk: {
        var w: usize = 0;
        var q0 = loc.line_start;
        while (q0 < loc.key_start and src[q0] == ' ') : (q0 += 1) w += 1;
        break :blk w;
    };

    // Leading content (BEFORE the outer `{`) — kept verbatim.
    const pre_header = src[0..file_start];

    // Footer: bytes after the outer `}` (typically a trailing newline).
    const footer = if (file_end < src.len) src[file_end..] else "";

    // Between-brace comment harvest: walk every line of src between
    // `file_start+1` and `loc.line_start` (i.e. between `{` and the
    // start-of-line of the `children:` key). If a line is whitespace-
    // only OR starts with a comment marker after only whitespace, we
    // keep it (de-indented by the outer indent). Lines containing
    // actual JSON (the now-removed/already-processed siblings, if any
    // somehow survived) get dropped — though `shouldCollapseFileToArray`
    // already gated this so there shouldn't be any.
    var harvested: std.ArrayList(u8) = .empty;
    // Skip the `{\n` byte first.
    var p: usize = file_start + 1;
    while (p < loc.line_start) {
        // Determine the start of this line.
        const line_begin = p;
        // Find the end of this line (one past `\n`, or src.len).
        var line_end: usize = p;
        while (line_end < loc.line_start and src[line_end] != '\n') line_end += 1;
        if (line_end < loc.line_start) line_end += 1; // include `\n`
        const line = src[line_begin..line_end];
        // Skip leading whitespace.
        var s: usize = 0;
        while (s < line.len and (line[s] == ' ' or line[s] == '\t')) s += 1;
        if (s == line.len) {
            // Whitespace-only line; skip.
        } else if (s + 1 < line.len and line[s] == '/' and (line[s + 1] == '/' or line[s + 1] == '*')) {
            // Comment line — keep, dedented by the outer indent
            // (matches the `[` of the array, which lives at column 0
            // post-collapse).
            var stripped: usize = 0;
            while (stripped < outer_indent and stripped < s) : (stripped += 1) {}
            harvested.appendSlice(arena, line[stripped..]) catch return null;
        } else {
            // Non-comment, non-whitespace line — predicate-gated, so
            // this shouldn't normally happen. Drop conservatively.
        }
        p = line_end;
    }
    const header = pre_header;

    // Body: dedent the array by one indent level if the inner body uses
    // a non-zero indent (the wrapping `{` added `outer_indent` spaces to
    // every line). Reuse the cached `outer_indent` computed above.
    const dedent = outer_indent;

    // Build dedented array.
    var body = src[arr_start..arr_end];
    var dedented: std.ArrayList(u8) = .empty;
    if (dedent == 0) {
        dedented.appendSlice(arena, body) catch return null;
    } else {
        // The first line (`[` and same-line tail) shouldn't be dedented
        // — it has no leading spaces. Subsequent lines (after each
        // `\n`) get their leading-space run trimmed by `dedent`.
        // Append the first line up to and including the first `\n`.
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            dedented.append(arena, body[i]) catch return null;
            if (body[i] == '\n') {
                i += 1;
                break;
            }
        }
        // Remaining lines.
        while (i < body.len) {
            var stripped: usize = 0;
            while (stripped < dedent and i < body.len and body[i] == ' ') {
                stripped += 1;
                i += 1;
            }
            while (i < body.len) {
                dedented.append(arena, body[i]) catch return null;
                if (body[i] == '\n') {
                    i += 1;
                    break;
                }
                i += 1;
            }
        }
        _ = &body;
    }

    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena, header) catch return null;
    out.appendSlice(arena, harvested.items) catch return null;
    // If a `meta:` block was present at the file level, splice a
    // `{ "meta": <value> },` header element into the bundle right after
    // the opening `[`. `dedented.items` starts with `[` and (typically)
    // a newline; we inject our header on its own indented line.
    if (meta_value_bytes) |mvb| {
        if (dedented.items.len > 0 and dedented.items[0] == '[') {
            out.append(arena, '[') catch return null;
            // Find where the first array entry would have started — if
            // the next byte is `\n`, emit our header on its own line; if
            // the array is `[]` (or `[ ]` with whitespace and `]`),
            // produce a header-only bundle.
            var tail_start: usize = 1;
            // Probe whether the rest of `dedented.items` is empty array.
            var p2: usize = 1;
            while (p2 < dedented.items.len and (dedented.items[p2] == ' ' or dedented.items[p2] == '\t' or dedented.items[p2] == '\n' or dedented.items[p2] == '\r')) p2 += 1;
            const is_empty_array = p2 < dedented.items.len and dedented.items[p2] == ']';
            if (is_empty_array) {
                // `[ ]` — replace with header-only bundle.
                out.appendSlice(arena, "\n    { \"meta\": ") catch return null;
                out.appendSlice(arena, mvb) catch return null;
                out.appendSlice(arena, " }\n]") catch return null;
                tail_start = dedented.items.len; // skip the rest
            } else {
                out.appendSlice(arena, "\n    { \"meta\": ") catch return null;
                out.appendSlice(arena, mvb) catch return null;
                out.appendSlice(arena, " },") catch return null;
                // Leave the existing `\n` (and indented next entry) in
                // place so the first child entry lands on its own line.
                // `tail_start` defaults to 1 (skip just the `[`).
            }
            out.appendSlice(arena, dedented.items[tail_start..]) catch return null;
        } else {
            // Defensive: shouldn't happen (an array body must start
            // with `[`).
            out.appendSlice(arena, dedented.items) catch return null;
        }
    } else {
        out.appendSlice(arena, dedented.items) catch return null;
    }
    out.appendSlice(arena, footer) catch return null;
    return out.toOwnedSlice(arena) catch null;
}
