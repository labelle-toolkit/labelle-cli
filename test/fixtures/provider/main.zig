const std = @import("std");
pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const context = try init.minimal.environ.getAlloc(a, "LABELLE_CONTEXT");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, context, a, .limited(1024 * 1024));
    const ctx = try std.json.parseFromSlice(std.json.Value, a, bytes, .{});
    const output = ctx.value.object.get("output_dir").?.string;
    const setting_file = ctx.value.object.get("config_file").?;
    const setting: ?[]const u8 = if (setting_file == .null) null else blk: {
        const raw = try std.Io.Dir.cwd().readFileAlloc(init.io, setting_file.string, a, .limited(1024 * 1024));
        const settings = try std.json.parseFromSlice(struct { label: []const u8 }, a, raw, .{});
        break :blk settings.value.label;
    };
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    _ = args.skip();
    var collected: std.ArrayList([]const u8) = .empty;
    while (args.next()) |arg| try collected.append(a, arg);
    const capture = try std.json.Stringify.valueAlloc(a, .{
        .context_path = context,
        .context = ctx.value,
        .args = collected.items,
        .setting = setting,
        .revision = @import("revision.zig").value,
        .cwd = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", a),
    }, .{});
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = try std.fs.path.join(a, &.{ output, "capture.json" }),
        .data = capture,
    });
    // Hooks share one output directory per step, so appending one line per
    // invocation to `hooks.log` makes their order observable. The timestamp
    // is monotonic within a host; `lock_file_exists` is checked at the moment
    // the hook runs (the lock must already exist for a `before generate` hook).
    const invocation = ctx.value.object.get("invocation").?;
    const lock_file = ctx.value.object.get("lock_file").?;
    const lock_exists = lock_file == .string and blk: {
        std.Io.Dir.cwd().access(init.io, lock_file.string, .{}) catch break :blk false;
        break :blk true;
    };
    const line = try std.json.Stringify.valueAlloc(a, .{
        .invocation = invocation,
        .target = ctx.value.object.get("target").?,
        .output_dir = output,
        .lock_file = lock_file,
        .lock_file_exists = lock_exists,
        .optimize = ctx.value.object.get("optimize").?,
        .progress = ctx.value.object.get("progress").?,
        .package_dir = ctx.value.object.get("package_dir").?,
        .nanoseconds = std.Io.Timestamp.now(init.io, .awake).nanoseconds,
    }, .{});
    const log_path = try std.fs.path.join(a, &.{ output, "hooks.log" });
    const previous = std.Io.Dir.cwd().readFileAlloc(init.io, log_path, a, .limited(1024 * 1024)) catch "";
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = log_path,
        .data = try std.mem.concat(a, u8, &.{ previous, line, "\n" }),
    });
    // Hooks receive no argv, so a failing hook is selected by environment:
    // `PROVIDER_PROBE_FAIL=<hook id>` makes that hook exit 7.
    if (init.minimal.environ.getAlloc(a, "PROVIDER_PROBE_FAIL")) |fail_id| {
        if (invocation == .object and invocation.object.get("id").?.string.len > 0 and
            std.mem.eql(u8, invocation.object.get("id").?.string, fail_id)) return 7;
    } else |_| {}
    if (collected.items.len > 0 and std.mem.eql(u8, collected.items[0], "fail")) return 7;
    if (collected.items.len > 0 and std.mem.eql(u8, collected.items[0], "crash")) @panic("provider fixture crash");
    return 0;
}
