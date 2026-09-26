const std = @import("std");
pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const context = try init.minimal.environ.getAlloc(a, "LABELLE_CONTEXT");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, context, a, .limited(1024 * 1024));
    const ctx = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    const output = ctx.value.object.get("output_dir").?.string;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    _ = args.skip();
    var collected: std.ArrayList([]const u8) = .empty;
    while (args.next()) |arg| try collected.append(a, arg);
    const capture = try std.json.Stringify.valueAlloc(a, .{
        .context_path = context,
        .context = ctx.value,
        .args = collected.items,
        .revision = @import("revision.zig").value,
        .cwd = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", a),
    }, .{});
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = try std.fs.path.join(a, &.{ output, "capture.json" }),
        .data = capture,
    });
    if (collected.items.len > 0 and std.mem.eql(u8, collected.items[0], "fail")) return 7;
    if (collected.items.len > 0 and std.mem.eql(u8, collected.items[0], "crash")) @panic("provider fixture crash");
    return 0;
}
