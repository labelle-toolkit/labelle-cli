const std = @import("std");
const parser = @import("parser");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: zon-parse-demo <file.zon>\n", .{});
        std.process.exit(1);
    }

    const path = args[1];
    std.debug.print("Parsing: {s}\n\n", .{path});

    const value = parser.Parser.parseFile(allocator, path) catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        std.process.exit(1);
    };

    var buf: [64 * 1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    parser.printValue(writer, value, 0) catch {
        std.debug.print("Output too large for buffer\n", .{});
        std.process.exit(1);
    };
    std.debug.print("{s}\n", .{fbs.getWritten()});
}
