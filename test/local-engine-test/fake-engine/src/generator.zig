const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get project directory from current working directory
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fs.cwd().realpath(".", &cwd_buf);

    std.debug.print("Fake generator running in: {s}\n", .{cwd});
    std.debug.print("This is a test generator that creates minimal project files.\n", .{});

    // Check for --engine-path argument to determine if using local path
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var use_local_path = false;
    var local_engine_path: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--engine-path=")) {
            use_local_path = true;
            local_engine_path = arg["--engine-path=".len..];
            std.debug.print("Using local engine path: {s}\n", .{local_engine_path.?});
        }
    }

    // Create .labelle directory
    std.fs.cwd().makeDir(".labelle") catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Create build.zig.zon with either local path or placeholder
    const build_zon_content = if (use_local_path)
        try std.fmt.allocPrint(allocator,
            \\.{{
            \\    .name = .test_project,
            \\    .version = "0.0.1",
            \\    .minimum_zig_version = "0.15.0",
            \\    .dependencies = .{{
            \\        .@"labelle-engine" = .{{
            \\            .path = "{s}",
            \\        }},
            \\    }},
            \\    .paths = .{{ "build.zig", "build.zig.zon" }},
            \\}}
            \\
        , .{local_engine_path.?})
    else
        try allocator.dupe(u8,
            \\.{
            \\    .name = .test_project,
            \\    .version = "0.0.1",
            \\    .minimum_zig_version = "0.15.0",
            \\    .dependencies = .{
            \\        .@"labelle-engine" = .{
            \\            // NOTE: This would normally have a URL and hash
            \\            // but we're using a local path for testing
            \\            .path = "../fake-engine",
            \\        },
            \\    },
            \\    .paths = .{ "build.zig", "build.zig.zon" },
            \\}
            \\
        );
    defer allocator.free(build_zon_content);

    var zon_file = try std.fs.cwd().createFile(".labelle/build.zig.zon", .{});
    defer zon_file.close();
    try zon_file.writeAll(build_zon_content);

    // Create build.zig
    const build_zig_content =
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
        \\    const exe = b.addExecutable(.{
        \\        .name = "test_project",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("../main.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }),
        \\    });
        \\
        \\    b.installArtifact(exe);
        \\
        \\    const run_cmd = b.addRunArtifact(exe);
        \\    run_cmd.step.dependOn(b.getInstallStep());
        \\
        \\    const run_step = b.step("run", "Run the application");
        \\    run_step.dependOn(&run_cmd.step);
        \\}
        \\
    ;

    var build_file = try std.fs.cwd().createFile(".labelle/build.zig", .{});
    defer build_file.close();
    try build_file.writeAll(build_zig_content);

    // Create main.zig if it doesn't exist
    _ = std.fs.cwd().statFile("main.zig") catch {
        var main_file = try std.fs.cwd().createFile("main.zig", .{});
        defer main_file.close();
        try main_file.writeAll(
            \\const std = @import("std");
            \\
            \\pub fn main() void {
            \\    std.debug.print("Hello from test project!\n", .{});
            \\}
            \\
        );
        std.debug.print("Created main.zig\n", .{});
    };

    std.debug.print("Generated:\n", .{});
    std.debug.print("  - .labelle/build.zig.zon\n", .{});
    std.debug.print("  - .labelle/build.zig\n", .{});
    std.debug.print("Generation complete!\n", .{});
}
