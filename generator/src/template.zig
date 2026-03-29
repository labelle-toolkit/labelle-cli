/// Mustache-style template engine for labelle code generation.
///
/// Supports:
///   {{variable}}    — named variable substitution from a struct with []const u8 fields
///   .section_name   — section delimiters for multi-section template files
///
/// Data context is a Zig struct where each field is []const u8.
const std = @import("std");

/// Render a template, replacing each {{variable}} with the matching field from `data`.
/// Unknown variables are written as-is (for debugging).
pub fn render(template: []const u8, data: anytype, writer: anytype) !void {
    var pos: usize = 0;
    while (pos < template.len) {
        if (pos + 4 <= template.len and template[pos] == '{' and template[pos + 1] == '{') {
            if (std.mem.indexOfPos(u8, template, pos + 2, "}}")) |end| {
                const name = std.mem.trim(u8, template[pos + 2 .. end], " ");
                if (getField(data, name)) |value| {
                    try writer.writeAll(value);
                } else {
                    // Unknown variable — write placeholder as-is
                    try writer.writeAll(template[pos .. end + 2]);
                }
                pos = end + 2;
                continue;
            }
        }
        try writer.writeByte(template[pos]);
        pos += 1;
    }
}

/// Render a named section from a multi-section template file, with {{variable}} substitution.
pub fn renderSection(template: []const u8, section: []const u8, data: anytype, writer: anytype) !void {
    const content = getSection(template, section) orelse {
        std.log.err("template section not found: .{s}", .{section});
        return error.SectionNotFound;
    };
    try render(content, data, writer);
}

/// Like renderSection, but silently skips if the section doesn't exist.
pub fn renderSectionOptional(template: []const u8, section: []const u8, data: anytype, writer: anytype) !void {
    const content = getSection(template, section) orelse return;
    try render(content, data, writer);
}

/// Write a section verbatim (no variable substitution).
pub fn writeSection(template: []const u8, section: []const u8, writer: anytype) !void {
    const content = getSection(template, section) orelse {
        std.log.err("template section not found: .{s}", .{section});
        return error.SectionNotFound;
    };
    try writer.writeAll(content);
}

/// Extract raw section content (without any rendering).
pub fn getSection(template: []const u8, section: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < template.len) {
        // Must be at start of template or after a newline
        if (pos > 0 and template[pos - 1] != '\n') {
            if (std.mem.indexOfScalarPos(u8, template, pos, '\n')) |nl| {
                pos = nl + 1;
            } else break;
            continue;
        }

        if (template[pos] != '.') {
            if (std.mem.indexOfScalarPos(u8, template, pos, '\n')) |nl| {
                pos = nl + 1;
            } else break;
            continue;
        }

        const name_start = pos + 1;
        const line_end = std.mem.indexOfScalarPos(u8, template, name_start, '\n') orelse template.len;
        const name = std.mem.trimRight(u8, template[name_start..line_end], " \t\r");

        if (std.mem.eql(u8, name, section)) {
            const content_start = if (line_end < template.len) line_end + 1 else template.len;
            const content_end = findNextSection(template, content_start);
            return template[content_start..content_end];
        }

        if (line_end < template.len) {
            pos = line_end + 1;
        } else break;
    }
    return null;
}

fn findNextSection(template: []const u8, start: usize) usize {
    var pos = start;
    while (pos < template.len) {
        if (template[pos] == '.') {
            if (pos + 1 < template.len and isIdentChar(template[pos + 1])) {
                return pos;
            }
        }
        if (std.mem.indexOfScalarPos(u8, template, pos, '\n')) |nl| {
            pos = nl + 1;
        } else break;
    }
    return template.len;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// ── Dynamic template engine ───────────────────────────────────────────
// Supports runtime string maps, {{#if}}/{{#else}}/{{/if}},
// {{#each list}}/{{/each}}, and nested blocks.

pub const ListItem = struct {
    fields: std.StringHashMap([]const u8),
};

pub const TemplateData = struct {
    scalars: std.StringHashMap([]const u8),
    lists: std.StringHashMap([]const ListItem),
};

/// Render a template using runtime TemplateData (string maps + list maps).
pub fn renderDynamic(template: []const u8, data: TemplateData, writer: anytype) !void {
    try renderDynamicInner(template, data, null, writer);
}

fn renderDynamicInner(
    template: []const u8,
    data: TemplateData,
    item: ?*const ListItem,
    writer: anytype,
) !void {
    var pos: usize = 0;
    while (pos < template.len) {
        // Look for {{
        if (pos + 2 <= template.len and template[pos] == '{' and template[pos + 1] == '{') {
            if (std.mem.indexOfPos(u8, template, pos + 2, "}}")) |close| {
                const tag = std.mem.trim(u8, template[pos + 2 .. close], " ");

                // {{#if name}}
                if (std.mem.startsWith(u8, tag, "#if ")) {
                    const name = std.mem.trim(u8, tag[4..], " ");
                    const after_tag = close + 2;
                    const block_end = findBlockEnd(template, after_tag, "if") orelse return error.UnmatchedBlock;
                    const body = template[after_tag..block_end.body_end];

                    const truthy = isTruthy(name, data, item);

                    // Split on {{#else}} if present
                    if (findElse(template, after_tag, block_end.body_end)) |else_pos| {
                        if (truthy) {
                            try renderDynamicInner(template[after_tag..else_pos], data, item, writer);
                        } else {
                            const else_tag_end = else_pos + findTagLen(template, else_pos);
                            try renderDynamicInner(template[else_tag_end..block_end.body_end], data, item, writer);
                        }
                    } else {
                        if (truthy) {
                            try renderDynamicInner(body, data, item, writer);
                        }
                    }
                    pos = block_end.block_end;
                    continue;
                }

                // {{#each list_name}}
                if (std.mem.startsWith(u8, tag, "#each ")) {
                    const name = std.mem.trim(u8, tag[6..], " ");
                    const after_tag = close + 2;
                    const block_end = findBlockEnd(template, after_tag, "each") orelse return error.UnmatchedBlock;
                    const body = template[after_tag..block_end.body_end];

                    if (data.lists.get(name)) |items| {
                        for (items) |*list_item| {
                            try renderDynamicInner(body, data, list_item, writer);
                        }
                    }
                    pos = block_end.block_end;
                    continue;
                }

                // {{/if}} or {{/each}} — shouldn't hit here in well-formed templates
                if (std.mem.startsWith(u8, tag, "/")) {
                    pos = close + 2;
                    continue;
                }

                // {{#else}} — shouldn't hit here either
                if (std.mem.eql(u8, tag, "#else")) {
                    pos = close + 2;
                    continue;
                }

                // Plain variable interpolation
                const value = lookupVar(tag, data, item);
                try writer.writeAll(value);
                pos = close + 2;
                continue;
            }
        }
        try writer.writeByte(template[pos]);
        pos += 1;
    }
}

fn isTruthy(name: []const u8, data: TemplateData, item: ?*const ListItem) bool {
    // Check item fields first, then scalars
    if (item) |it| {
        if (it.fields.get(name)) |v| return v.len > 0;
    }
    if (data.scalars.get(name)) |v| return v.len > 0;
    return false;
}

fn lookupVar(name: []const u8, data: TemplateData, item: ?*const ListItem) []const u8 {
    // Item fields first (inner scope), then parent scalars
    if (item) |it| {
        if (it.fields.get(name)) |v| return v;
    }
    return data.scalars.get(name) orelse "";
}

const BlockEnd = struct {
    body_end: usize, // where the closing tag starts
    block_end: usize, // after the closing tag (past }})
};

/// Find the matching {{/kind}} for a block starting at `start`, handling nesting.
fn findBlockEnd(template: []const u8, start: usize, kind: []const u8) ?BlockEnd {
    var depth: usize = 1;
    var pos = start;
    while (pos < template.len) {
        if (pos + 2 <= template.len and template[pos] == '{' and template[pos + 1] == '{') {
            if (std.mem.indexOfPos(u8, template, pos + 2, "}}")) |close| {
                const tag = std.mem.trim(u8, template[pos + 2 .. close], " ");

                // Opening tag of same kind
                if (tag.len > 1 and tag[0] == '#') {
                    const rest = std.mem.trim(u8, tag[1..], " ");
                    if (std.mem.startsWith(u8, rest, kind)) {
                        const after = std.mem.trim(u8, rest[kind.len..], " ");
                        // "#if foo" or "#each bar" — the char after kind is space or end
                        if (after.len > 0 or rest.len == kind.len) {
                            // Only count if it's genuinely the same block type
                            if (rest.len == kind.len or (rest.len > kind.len and rest[kind.len] == ' ')) {
                                depth += 1;
                            }
                        }
                    }
                }

                // Closing tag
                if (tag.len > 1 and tag[0] == '/') {
                    const close_kind = std.mem.trim(u8, tag[1..], " ");
                    if (std.mem.eql(u8, close_kind, kind)) {
                        depth -= 1;
                        if (depth == 0) {
                            return BlockEnd{
                                .body_end = pos,
                                .block_end = close + 2,
                            };
                        }
                    }
                }

                pos = close + 2;
                continue;
            }
        }
        pos += 1;
    }
    return null;
}

/// Find {{#else}} at the current nesting level between start and end.
fn findElse(template: []const u8, start: usize, end: usize) ?usize {
    var depth: usize = 0;
    var pos = start;
    while (pos < end) {
        if (pos + 2 <= end and template[pos] == '{' and template[pos + 1] == '{') {
            if (std.mem.indexOfPos(u8, template, pos + 2, "}}")) |close| {
                if (close + 2 > end) {
                    pos += 1;
                    continue;
                }
                const tag = std.mem.trim(u8, template[pos + 2 .. close], " ");

                // Track nesting of if blocks
                if (std.mem.startsWith(u8, tag, "#if ")) {
                    depth += 1;
                } else if (std.mem.eql(u8, tag, "/if")) {
                    if (depth > 0) depth -= 1;
                } else if (std.mem.eql(u8, tag, "#else") and depth == 0) {
                    return pos;
                }

                pos = close + 2;
                continue;
            }
        }
        pos += 1;
    }
    return null;
}

/// Return the length of a {{...}} tag starting at `pos`.
fn findTagLen(template: []const u8, pos: usize) usize {
    if (std.mem.indexOfPos(u8, template, pos + 2, "}}")) |close| {
        return close + 2 - pos;
    }
    return 0;
}

/// Look up a field by name at runtime from a comptime-known struct type.
fn getField(data: anytype, name: []const u8) ?[]const u8 {
    const T = @TypeOf(data);
    const info = @typeInfo(T);
    if (info != .@"struct") return null;
    const fields = info.@"struct".fields;
    inline for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            return @field(data, field.name);
        }
    }
    return null;
}
