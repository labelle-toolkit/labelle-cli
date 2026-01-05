// Project Configuration Reader
//
// Reads project.labelle files to extract configuration,
// particularly the engine_version field.

const std = @import("std");

pub const ProjectConfig = struct {
    name: ?[]const u8 = null,
    engine_version: ?[]const u8 = null,
    initial_scene: ?[]const u8 = null,
    output_dir: ?[]const u8 = null,
    raw_content: []const u8,

    pub fn deinit(self: *const ProjectConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.raw_content);
    }
};

/// Read and parse project.labelle from the given directory.
pub fn readProjectConfig(allocator: std.mem.Allocator, project_path: []const u8) !ProjectConfig {
    const file_path = try std.fmt.allocPrint(allocator, "{s}/project.labelle", .{project_path});
    defer allocator.free(file_path);

    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return error.ProjectNotFound;
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);

    var config = ProjectConfig{ .raw_content = content };

    // Simple parsing - look for key fields
    config.name = extractStringField(content, ".name");
    config.engine_version = extractStringField(content, ".engine_version");
    config.initial_scene = extractStringField(content, ".initial_scene");
    config.output_dir = extractStringField(content, ".output_dir");

    return config;
}

/// Extract a string field value from ZON content.
/// Looks for patterns like: .field_name = "value"
fn extractStringField(content: []const u8, field: []const u8) ?[]const u8 {
    // Look for the field
    const field_pos = std.mem.indexOf(u8, content, field) orelse return null;

    // Find the equals sign
    const eq_pos = std.mem.indexOfPos(u8, content, field_pos, "=") orelse return null;

    // Find the opening quote
    const quote_start = std.mem.indexOfPos(u8, content, eq_pos, "\"") orelse return null;

    // Find the closing quote
    const quote_end = std.mem.indexOfPos(u8, content, quote_start + 1, "\"") orelse return null;

    return content[quote_start + 1 .. quote_end];
}

/// Update the engine_version field in project.labelle
pub fn updateEngineVersion(allocator: std.mem.Allocator, project_path: []const u8, new_version: []const u8) !void {
    const file_path = try std.fmt.allocPrint(allocator, "{s}/project.labelle", .{project_path});
    defer allocator.free(file_path);

    // Read current content
    const file = try std.fs.cwd().openFile(file_path, .{});
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    file.close();
    defer allocator.free(content);

    // Find and replace engine_version value
    const field = ".engine_version";
    const field_pos = std.mem.indexOf(u8, content, field) orelse return error.FieldNotFound;
    const eq_pos = std.mem.indexOfPos(u8, content, field_pos, "=") orelse return error.FieldNotFound;
    const quote_start = std.mem.indexOfPos(u8, content, eq_pos, "\"") orelse return error.FieldNotFound;
    const quote_end = std.mem.indexOfPos(u8, content, quote_start + 1, "\"") orelse return error.FieldNotFound;

    // Build new content: before + new version + after
    const new_content = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        content[0 .. quote_start + 1],
        new_version,
        content[quote_end..],
    });
    defer allocator.free(new_content);

    // Write back
    const write_file = try std.fs.cwd().createFile(file_path, .{});
    defer write_file.close();
    try write_file.writeAll(new_content);
}

test "extractStringField" {
    const content =
        \\.{
        \\    .name = "my-game",
        \\    .engine_version = "0.33.0",
        \\}
    ;

    const name = extractStringField(content, ".name");
    try std.testing.expectEqualStrings("my-game", name.?);

    const version = extractStringField(content, ".engine_version");
    try std.testing.expectEqualStrings("0.33.0", version.?);

    const missing = extractStringField(content, ".missing_field");
    try std.testing.expect(missing == null);
}
