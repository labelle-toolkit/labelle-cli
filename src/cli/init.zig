const std = @import("std");
const gen = @import("generator");
const assembler = @import("assembler.zig");
const config = @import("config.zig");

/// Scaffold a new project directory with project.labelle and starter files.
pub fn cmdInit(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    var name: ?[]const u8 = null;
    var dir_override: ?[]const u8 = null;
    var backend: []const u8 = "raylib";
    var ecs: []const u8 = "zig_ecs";
    var gui: ?[]const u8 = null;
    var core_version: []const u8 = gen.CORE_VERSION;
    var engine_version: []const u8 = gen.ENGINE_VERSION;
    var gfx_version: []const u8 = gen.GFX_VERSION;
    var labelle_version: []const u8 = gen.CLI_VERSION;
    var assembler_version: []const u8 = assembler.DEFAULT_ASSEMBLER_VERSION;

    for (cmd_args) |arg| {
        if (std.mem.startsWith(u8, arg, "--backend=")) {
            backend = arg["--backend=".len..];
        } else if (std.mem.startsWith(u8, arg, "--ecs=")) {
            ecs = arg["--ecs=".len..];
        } else if (std.mem.startsWith(u8, arg, "--gui=")) {
            gui = arg["--gui=".len..];
        } else if (std.mem.startsWith(u8, arg, "--core-version=")) {
            core_version = arg["--core-version=".len..];
        } else if (std.mem.startsWith(u8, arg, "--engine-version=")) {
            engine_version = arg["--engine-version=".len..];
        } else if (std.mem.startsWith(u8, arg, "--gfx-version=")) {
            gfx_version = arg["--gfx-version=".len..];
        } else if (std.mem.startsWith(u8, arg, "--labelle-version=")) {
            labelle_version = arg["--labelle-version=".len..];
        } else if (std.mem.startsWith(u8, arg, "--assembler-version=")) {
            assembler_version = arg["--assembler-version=".len..];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("labelle init: unknown flag '{s}'\n", .{arg});
            return error.UnknownFlag;
        } else if (name == null) {
            name = arg;
        } else if (dir_override == null) {
            dir_override = arg;
        } else {
            std.debug.print("labelle init: unexpected argument '{s}'\n", .{arg});
            std.debug.print("usage: labelle init <name> [--backend=X] [--ecs=X] [--gui=X] [--*-version=X] [dir]\n", .{});
            return error.TooManyArguments;
        }
    }

    const project_name = name orelse {
        std.debug.print("labelle init: missing project name\n", .{});
        std.debug.print("usage: labelle init <name> [--backend=X] [--ecs=X] [--gui=X] [--*-version=X] [dir]\n", .{});
        return error.MissingArgument;
    };

    const dir = dir_override orelse project_name;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    cwd.createDirPath(io, dir) catch |err| {
        std.debug.print("labelle init: could not create '{s}': {any}\n", .{ dir, err });
        return error.InitFailed;
    };

    // Write project.labelle
    {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        const w = &aw.writer;

        try w.print(
            \\.{{
            \\    .name = "{s}",
            \\    .title = "{s}",
            \\    .width = 800,
            \\    .height = 600,
            \\    .target_fps = 60,
            \\    .backend = .{s},
            \\    .ecs = .{s},
            \\
        , .{ project_name, project_name, backend, ecs });

        // GUI plugin reference (null = no GUI, or a plugin ref)
        if (gui) |gui_path| {
            try w.print(
                \\    .gui = .{{ .path = "{s}" }},
                \\
            , .{gui_path});
        }

        try w.print(
            \\    .plugins = .{{}},
            \\    .layers = .{{
            \\        .{{ .name = "background", .order = 0, .space = .screen }},
            \\        .{{ .name = "world", .order = 1, .space = .world }},
            \\        .{{ .name = "ui", .order = 2, .space = .screen }},
            \\    }},
            \\    .core_version = "{s}",
            \\    .engine_version = "{s}",
            \\    .gfx_version = "{s}",
            \\    .labelle_version = "{s}",
            \\    .assembler_version = "{s}",
            \\}}
            \\
        , .{ core_version, engine_version, gfx_version, labelle_version, assembler_version });

        const path = try std.fs.path.join(allocator, &.{ dir, "project.labelle" });
        defer allocator.free(path);
        try cwd.writeFile(io, .{
            .sub_path = path,
            .data = aw.written(),
            .flags = .{ .exclusive = true },
        });
    }

    // Create starter directories
    const dirs = [_][]const u8{ "scripts", "scenes", "prefabs", "assets", "components", "hooks" };
    for (dirs) |subdir| {
        const path = try std.fs.path.join(allocator, &.{ dir, subdir });
        defer allocator.free(path);
        cwd.createDirPath(io, path) catch {};
    }

    // Write a starter scene
    {
        const path = try std.fs.path.join(allocator, &.{ dir, "scenes", "main.zon" });
        defer allocator.free(path);
        cwd.writeFile(io, .{
            .sub_path = path,
            .data =
                \\.{
                \\    .name = "main",
                \\    .entities = .{},
                \\}
                \\
            ,
            .flags = .{ .exclusive = true },
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // Write .gitignore
    {
        const path = try std.fs.path.join(allocator, &.{ dir, ".gitignore" });
        defer allocator.free(path);
        cwd.writeFile(io, .{
            .sub_path = path,
            .data = ".labelle/\n",
            .flags = .{ .exclusive = true },
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    std.debug.print("labelle: created project '{s}' in {s}/\n", .{ project_name, dir });
    std.debug.print("  next: cd {s} && labelle run\n", .{dir});
}
