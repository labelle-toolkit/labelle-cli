// ─────────────────────────────────────────────────────────────────────
// Byte-level transforms A–F
// ─────────────────────────────────────────────────────────────────────
//
//   A — delete a top-level key (used for "assets")
//   B — rename a top-level key ("entities" → "children")
//   C — lift `"root": { ... }` wrapper to top level
//   D — rename `"components"` → `"overrides"` on prefab refs
//   E — lift `overrides` wrapper on prefab refs (RFC #596) — only when
//       every inner key is PascalCase (cli#338)
//   F — REMOVED (cli#338): inline `components` wrapper is canonical
//
// All functions operate on raw JSONC bytes and rely on the JSONC scanner
// primitives in `scanner.zig`. The RFC #596 meta/directive transforms
// (G–I) live in `transforms_meta.zig`.

const std = @import("std");
const scanner = @import("scanner.zig");

const findTopLevelKey = scanner.findTopLevelKey;
const findStringEnd = scanner.findStringEnd;
const skipValue = scanner.skipValue;
const skipContainer = scanner.skipContainer;
const skipWsAndComments = scanner.skipWsAndComments;

// ─────────────────────────────────────────────────────────────────────
// Shared line-tail probe
// ─────────────────────────────────────────────────────────────────────

/// True when everything from `from` to the next `\n` (or EOF) is
/// whitespace, optionally followed by a `//` line comment. Used by the
/// delete/drop splicers to decide whether "extend the cut to end of
/// line" is safe: on files that collapse closers onto the entry's last
/// line (`... }}` / `... }}}`), the remainder of the line carries LIVE
/// structure (the enclosing object's `}`), and eating it truncates the
/// file — the cli#337 `UnexpectedEndOfInput` project-abort.
fn lineTailIsBlankOrComment(src: []const u8, from: usize) bool {
    var i = from;
    while (i < src.len and src[i] != '\n') : (i += 1) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\r') continue;
        // A trailing `//` comment belongs to the deleted entry's line;
        // eating it along with the entry is fine.
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') return true;
        return false;
    }
    return true;
}

/// Extend `cut_end` through the end of the current line — but ONLY when
/// the line's tail is blank/comment (see `lineTailIsBlankOrComment`).
/// Otherwise the cut stops where the entry's bytes stop, leaving the
/// rest of the line (e.g. a collapsed closing brace) intact.
fn extendCutToEol(src: []const u8, cut_end: usize) usize {
    if (!lineTailIsBlankOrComment(src, cut_end)) return cut_end;
    var e = cut_end;
    while (e < src.len and src[e] != '\n') e += 1;
    if (e < src.len and src[e] == '\n') e += 1;
    return e;
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
pub fn deleteTopLevelKey(arena: std.mem.Allocator, src: []const u8, key: []const u8) ?[]u8 {
    const loc = findTopLevelKey(src, key) orelse return null;

    var cut_start: usize = loc.line_start;
    var cut_end: usize = loc.value_end;

    if (loc.comma_after) |c| {
        // Has trailing comma — eat from line start through end-of-line
        // after the comma (line-tail permitting; see `extendCutToEol`).
        cut_end = extendCutToEol(src, c + 1);
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
        cut_end = extendCutToEol(src, cut_end);
    }

    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena, src[0..cut_start]) catch return null;
    out.appendSlice(arena, src[cut_end..]) catch return null;
    return out.toOwnedSlice(arena) catch null;
}

// ─────────────────────────────────────────────────────────────────────
// Transform B — rename a top-level key (used for "entities" → "children")
// ─────────────────────────────────────────────────────────────────────

pub fn renameTopLevelKey(
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
pub fn liftTopLevelRoot(arena: std.mem.Allocator, src: []const u8) ?[]u8 {
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
pub fn dedentBy(
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
pub fn renameOneComponentsOnRef(
    arena: std.mem.Allocator,
    src: []const u8,
    parsed_value: std.json.Value,
) !?[]u8 {
    // Walk parsed JSON to determine WHETHER a target exists (cheap,
    // exact). Then walk the raw bytes to locate it.
    if (!treeHasComponentsOnRef(parsed_value)) return null;
    return findAndRenameComponentsOnRef(arena, src);
}

pub fn treeHasComponentsOnRef(value: std.json.Value) bool {
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
pub fn findAndRenameComponentsOnRef(arena: std.mem.Allocator, src: []const u8) ?[]u8 {
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
pub fn objectHasPrefabStringAndComponents(src: []const u8, start_brace: usize, end_one_past: usize) ?usize {
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
// Transform E (RFC #596) — lift `overrides` wrapper on prefab refs
// ─────────────────────────────────────────────────────────────────────

/// `{prefab: "x", overrides: {Position: {...}, Image: {...}}}` →
/// `{prefab: "x", Position: {...}, Image: {...}}`.
///
/// Top-down driver: locate the first object that has both `prefab` and
/// `overrides`; rewrite its bytes by splicing out the wrapping key/value
/// and de-indenting the contents one level. Loops until no candidates
/// remain (each rewrite invalidates byte offsets).
pub fn liftOneOverridesBlock(
    arena: std.mem.Allocator,
    src: []const u8,
    parsed_value: std.json.Value,
) !?[]u8 {
    if (!treeHasWrapperOnRef(parsed_value, "overrides")) return null;
    return findAndLiftWrapper(arena, src, .{ .wrapper = "overrides", .require_sibling_prefab = true });
}

// ─────────────────────────────────────────────────────────────────────
// Transform F — REMOVED (cli#338)
// ─────────────────────────────────────────────────────────────────────
//
// The inline `components:` wrapper (`{components: {...}}` on an entity
// WITHOUT a `prefab` sibling) is a canonical engine 2.x shape, not
// legacy. The engine's case-convention rule only recognizes PascalCase
// flat keys as components; pack-namespaced (lowercase) keys such as
// `rooms__Room` are ONLY recognized inside the wrapper. Lifting them
// flat made the engine silently drop the components at load time.
// Engine v2.0 removed `components` on prefab REFERENCES only (see
// transform B / `renameOneComponentsOnRef`).

pub fn treeHasWrapperOnRef(value: std.json.Value, wrapper: []const u8) bool {
    switch (value) {
        .object => |obj| {
            const has_prefab = blk: {
                const v = obj.get("prefab") orelse break :blk false;
                break :blk v == .string;
            };
            if (has_prefab) {
                if (obj.get(wrapper)) |wv| {
                    if (wv == .object) return true;
                }
            }
            var it = obj.iterator();
            while (it.next()) |kv| {
                if (treeHasWrapperOnRef(kv.value_ptr.*, wrapper)) return true;
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (treeHasWrapperOnRef(item, wrapper)) return true;
            }
        },
        else => {},
    }
    return false;
}

pub const WrapperSpec = struct {
    wrapper: []const u8,
    require_sibling_prefab: bool,
};

/// True when every direct key of the object literal at [v_start, v_end)
/// is PascalCase (first byte A–Z). The engine's case-convention rule
/// (RFC #596 / engine `isPascalCase`) treats ONLY uppercase-first flat
/// keys as components — a lowercase key (pack-namespaced names like
/// `rooms__Room`, `industry__Storage`) lifted out of its wrapper is
/// reclassified as *structural* and **silently dropped** at load time
/// (cli#338). Lifting is therefore only semantics-preserving when the
/// wrapper's contents are all PascalCase; otherwise the wrapper is the
/// REQUIRED shape and must be left alone.
pub fn innerKeysAllPascal(src: []const u8, v_start: usize, v_end_one_past: usize) bool {
    var i = v_start + 1; // past the `{`
    const end = v_end_one_past - 1; // the closing `}`
    while (i < end) {
        i = skipWsAndComments(src, i);
        if (i >= end) break;
        if (src[i] == '}') break;
        if (src[i] != '"') return false; // malformed — refuse the lift
        const k_start = i;
        const k_end = findStringEnd(src, k_start);
        const key = src[k_start + 1 .. k_end - 1];
        if (key.len == 0 or key[0] < 'A' or key[0] > 'Z') return false;
        var j = skipWsAndComments(src, k_end);
        if (j >= end or src[j] != ':') return false;
        j += 1;
        j = skipWsAndComments(src, j);
        const val_end = skipValue(src, j);
        var k = skipWsAndComments(src, val_end);
        if (k < end and src[k] == ',') k += 1;
        i = k;
    }
    return true;
}

/// Byte-level walker shared by transforms 5 (overrides) and 6 (inline
/// components). Locate the first object literal `{ ... }` whose direct
/// children match `spec`, then lift `wrapper:`'s inner object's contents
/// to be siblings of the wrapper key.
pub fn findAndLiftWrapper(arena: std.mem.Allocator, src: []const u8, spec: WrapperSpec) ?[]u8 {
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
            if (objectHasWrapper(src, i, obj_end, spec)) |key_loc| {
                if (liftWrapperAt(arena, src, i, obj_end, key_loc)) |out| return out;
            }
            i += 1;
            continue;
        }
        i += 1;
    }
    return null;
}

/// Look at the siblings inside the object delimited by `[start_brace,
/// end_one_past)`. If a wrapper-key matching `spec` exists (and the
/// optional `prefab` sibling rule is satisfied) — and its value is an
/// object — return the byte index of the wrapper key's opening `"`. The
/// scan ignores keys inside nested containers so we don't pick up
/// inherited keys like a `components` deep inside a storages array.
pub fn objectHasWrapper(src: []const u8, start_brace: usize, end_one_past: usize, spec: WrapperSpec) ?usize {
    var i = start_brace + 1;
    var prefab_is_string = false;
    var wrapper_pos: ?usize = null;

    while (i < end_one_past) {
        i = skipWsAndComments(src, i);
        if (i >= end_one_past) break;
        if (src[i] == '}') break;
        if (src[i] != '"') return null;
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
        } else if (std.mem.eql(u8, key, spec.wrapper)) {
            // Wrapper must be object-valued and non-empty for a lift to
            // produce siblings. An empty object `{}` still triggers a
            // lift — the splice removes the wrapper line entirely.
            // Lift ONLY when every inner key is PascalCase: lowercase
            // (pack-namespaced) keys are only recognized inside the
            // wrapper, so lifting them silently drops the components at
            // engine load (cli#338). Non-liftable wrappers are simply
            // left in place — they're a valid engine 2.x shape.
            if (v_start < src.len and src[v_start] == '{' and
                innerKeysAllPascal(src, v_start, v_end))
            {
                wrapper_pos = k_start;
            }
        }

        var k = skipWsAndComments(src, v_end);
        if (k < end_one_past and src[k] == ',') k += 1;
        i = k;
    }

    if (wrapper_pos == null) return null;
    if (spec.require_sibling_prefab and !prefab_is_string) return null;
    if (!spec.require_sibling_prefab and prefab_is_string) return null;
    return wrapper_pos;
}

/// Splice the wrapper entry out of an object, lifting its inner-object
/// contents to be siblings. Strategy mirrors `liftTopLevelRoot`: locate
/// the wrapper-key line, dedent each line of the wrapper's value, splice
/// in the dedented body, and rebuild the trailing-comma chain so the
/// surrounding object remains valid JSON.
pub fn liftWrapperAt(
    arena: std.mem.Allocator,
    src: []const u8,
    start_brace: usize,
    end_one_past: usize,
    wrapper_key_start: usize,
) ?[]u8 {
    _ = end_one_past;
    // Locate full wrapper KeyLoc by re-scanning from the wrapper key.
    const k_start = wrapper_key_start;
    const k_end = findStringEnd(src, k_start);
    var j = skipWsAndComments(src, k_end);
    if (j >= src.len or src[j] != ':') return null;
    const colon = j;
    j += 1;
    j = skipWsAndComments(src, j);
    const v_start = j;
    if (v_start >= src.len or src[v_start] != '{') return null;
    const v_end = skipValue(src, v_start);
    // value_end points one past the matching `}`.
    const inner_open = v_start;
    const inner_close = v_end - 1;
    if (inner_close <= inner_open or src[inner_close] != '}') return null;

    // Locate trailing comma + line_start (same as findTopLevelKey's
    // KeyLoc structure).
    var k = skipWsAndComments(src, v_end);
    var comma_after: ?usize = null;
    if (k < src.len and src[k] == ',') {
        comma_after = k;
        k += 1;
    }
    // line_start: walk back from k_start to the previous '\n'+1, or to
    // just past the opening `{` of the containing object if there's no
    // newline in between (single-line entries like
    // `{ "prefab": "x", "overrides": { ... } }`).
    var line_start: usize = k_start;
    while (line_start > 0 and src[line_start - 1] != '\n' and line_start - 1 > start_brace) line_start -= 1;
    const has_leading_newline = line_start > 0 and src[line_start - 1] == '\n';

    _ = colon;

    // Compute dedent width: the difference between the inner body's
    // indent (its first non-empty line's leading-space count) and the
    // wrapper key's column. Both inner indent and wrapper column are
    // absolute (number of leading spaces). The dedent equals the
    // single-step increment between them (typically 4 — one level).
    // For single-line wrappers the inner body has no indent to strip.
    const wrapper_column: usize = blk: {
        if (!has_leading_newline) break :blk 0;
        var w: usize = 0;
        var p = line_start;
        while (p < k_start and src[p] == ' ') : (p += 1) w += 1;
        break :blk w;
    };
    const inner_first_indent: usize = blk: {
        if (!has_leading_newline) break :blk 0;
        // Scan inner_body for the first non-blank line's leading-space
        // run. `inner_body` defined later — re-locate the open brace.
        const inner_open_local = v_start;
        const inner_close_local = v_end - 1;
        const body_local = src[inner_open_local + 1 .. inner_close_local];
        var i: usize = 0;
        // Skip blank lines (whitespace-only + `\n`).
        while (i < body_local.len) {
            const line_start_local = i;
            while (i < body_local.len and body_local[i] != '\n') i += 1;
            const line = body_local[line_start_local..i];
            var s: usize = 0;
            while (s < line.len and (line[s] == ' ' or line[s] == '\t')) s += 1;
            if (s < line.len) break :blk s;
            if (i < body_local.len) i += 1;
        }
        break :blk wrapper_column;
    };
    const outer_indent: usize = if (inner_first_indent > wrapper_column)
        inner_first_indent - wrapper_column
    else
        0;

    const inner_body = src[inner_open + 1 .. inner_close];

    // Detect inline (single-line) wrapper: the inner body has no
    // newlines AND the wrapper's `}` is on the same line as the `{`.
    const inline_wrapper = std.mem.indexOfScalar(u8, inner_body, '\n') == null;

    var rebuilt: std.ArrayList(u8) = .empty;
    if (inline_wrapper) {
        // Trim outer whitespace from the body so we get `Position: {x:
        // 1}` rather than `   Position: {x: 1}   `.
        var body = inner_body;
        var lo: usize = 0;
        while (lo < body.len and (body[lo] == ' ' or body[lo] == '\t')) lo += 1;
        var hi: usize = body.len;
        while (hi > lo and (body[hi - 1] == ' ' or body[hi - 1] == '\t')) hi -= 1;
        body = body[lo..hi];
        if (body.len == 0) {
            // Empty `overrides: {}` — drop the wrapper entry entirely.
            return spliceDropEntry(arena, src, line_start, k_start, v_end, comma_after, has_leading_newline);
        }
        rebuilt.appendSlice(arena, body) catch return null;
    } else {
        // Multi-line wrapper. Dedent inner body by `outer_indent` and
        // splice in place of the wrapper entry.
        var body = inner_body;
        if (body.len > 0 and body[0] == '\n') body = body[1..];
        // Trim trailing whitespace + newline before the close brace.
        if (body.len > 0 and body[body.len - 1] != '\n') {
            var t: usize = body.len;
            while (t > 0 and (body[t - 1] == ' ' or body[t - 1] == '\t')) t -= 1;
            body = body[0..t];
        }
        if (body.len > 0 and body[body.len - 1] == '\n') body = body[0 .. body.len - 1];
        if (body.len == 0) {
            return spliceDropEntry(arena, src, line_start, k_start, v_end, comma_after, has_leading_newline);
        }
        dedentBy(arena, &rebuilt, body, outer_indent) catch return null;
    }

    // Splice from wrapper-line start (or just past the key in inline-
    // case) through `v_end` (which is one past wrapper's `}`).
    var splice_start: usize = line_start;
    var splice_end: usize = v_end;
    if (!has_leading_newline) {
        // Inline: keep the line intact, replace just `"wrapper": { ... }`
        splice_start = k_start;
    }
    if (comma_after) |c| {
        splice_end = c + 1;
        rebuilt.append(arena, ',') catch return null;
    }

    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena, src[0..splice_start]) catch return null;
    out.appendSlice(arena, rebuilt.items) catch return null;
    out.appendSlice(arena, src[splice_end..]) catch return null;
    return out.toOwnedSlice(arena) catch null;
}

/// Drop an entire wrapper entry (for the `overrides: {}` / `components:
/// {}` empty-block case). Handles the trailing-comma fixup so the
/// preceding sibling stays well-formed. `key_start` is the index of the
/// opening `"` of the wrapper key — used for the inline (no leading
/// newline) case where the cut start must be the key, not the line
/// start of the surrounding entity object.
pub fn spliceDropEntry(
    arena: std.mem.Allocator,
    src: []const u8,
    line_start: usize,
    key_start: usize,
    v_end: usize,
    comma_after: ?usize,
    has_leading_newline: bool,
) ?[]u8 {
    var cut_start: usize = if (has_leading_newline) line_start else key_start;
    var cut_end: usize = v_end;
    if (comma_after) |c| {
        // There's a trailing comma after the wrapper. Eat it (and the
        // rest of the line if we're in line-based mode — but only when
        // the tail is blank/comment; collapsed closers must survive).
        cut_end = c + 1;
        if (has_leading_newline) {
            cut_end = extendCutToEol(src, cut_end);
        }
    } else {
        // No trailing comma — wrapper is the LAST entry. Rewind past
        // the preceding `,` to drop the now-redundant separator on the
        // previous sibling.
        var p: isize = @intCast(cut_start);
        p -= 1;
        while (p >= 0) : (p -= 1) {
            const c = src[@intCast(p)];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') continue;
            if (c == ',') {
                cut_start = @intCast(p);
                break;
            }
            break;
        }
        if (has_leading_newline) {
            cut_end = extendCutToEol(src, cut_end);
        }
    }

    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena, src[0..cut_start]) catch return null;
    out.appendSlice(arena, src[cut_end..]) catch return null;
    return out.toOwnedSlice(arena) catch null;
}
