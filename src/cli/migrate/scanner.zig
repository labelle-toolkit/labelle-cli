// ─────────────────────────────────────────────────────────────────────
// JSONC-aware byte scanner + JSONC → JSON pre-stripper
// ─────────────────────────────────────────────────────────────────────
//
// Shared low-level primitives used by the byte-transform pipeline:
//   - `KeyLoc` + `findTopLevelKey` locate a top-level key in raw JSONC
//     bytes (respecting strings/comments).
//   - `findStringEnd` / `skipValue` / `skipContainer` / `skipWsAndComments`
//     are the scanner helpers the transforms reuse.
//   - `stripJsoncToJson` produces a comment-free JSON buffer for `std.json`.

const std = @import("std");

/// Outcome of `findTopLevelKey`. `key_start` points at the opening `"`
/// of the key string; `key_end` is one past its closing `"`. `colon`
/// points at the `:` byte that follows. `value_start` is the index of
/// the first non-whitespace value byte. `entry_start` is the position
/// of the first byte of the "key entry" — including leading whitespace
/// from the previous newline. `entry_end` is the index just past the
/// value's last byte, **excluding** any trailing comma. `comma_after`
/// is the index of the `,` that separates this entry from the next
/// sibling (or `null` if this is the last entry of the object).
pub const KeyLoc = struct {
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
pub fn findTopLevelKey(src: []const u8, key: []const u8) ?KeyLoc {
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
pub fn findStringEnd(src: []const u8, start: usize) usize {
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
pub fn skipValue(src: []const u8, start: usize) usize {
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
pub fn skipContainer(src: []const u8, start: usize) usize {
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
pub fn skipWsAndComments(src: []const u8, start: usize) usize {
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
// JSONC → JSON pre-stripper (copied from audit.zig — keeps this module
// self-contained, and the two stay in sync via the shared tests).
// ─────────────────────────────────────────────────────────────────────

pub fn stripJsoncToJson(arena: std.mem.Allocator, src: []const u8) ![]u8 {
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
