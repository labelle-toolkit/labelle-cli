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
