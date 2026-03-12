/// labelle-cli — reads project.labelle and generates/builds/runs the assembled game.
///
/// Usage:
///   labelle generate [dir]       — generate .labelle/ assembler files
///   labelle run [dir]            — generate + build + run
///   labelle build [dir]          — generate + build (no run)
///   labelle [dir]                — alias for `run`
///   labelle init <name> [dir]    — scaffold a new project
///   labelle install [pkg] [ver]  — fetch packages into cache
///   labelle upgrade [dir] [pkg] [ver] — bump versions in project.labelle
///   labelle update [ver]         — self-update the CLI
const std = @import("std");
const gen = @import("generator");

const Command = enum { generate, build, run, init, install, upgrade, update, help, version, targets };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip(); // skip program name

    // Parse command and project dir
    var command: Command = .run;
    var project_dir: []const u8 = ".";
    var extra_args: [8][]const u8 = undefined;
    var extra_count: usize = 0;

    if (args.next()) |first| {
        if (std.mem.eql(u8, first, "generate")) {
            command = .generate;
            project_dir = args.next() orelse ".";
        } else if (std.mem.eql(u8, first, "build")) {
            command = .build;
            project_dir = args.next() orelse ".";
        } else if (std.mem.eql(u8, first, "run")) {
            command = .run;
            project_dir = args.next() orelse ".";
        } else if (std.mem.eql(u8, first, "init")) {
            command = .init;
            // Collect remaining args for init
            while (args.next()) |arg| {
                if (extra_count >= extra_args.len) {
                    std.debug.print("labelle: too many arguments\n", .{});
                    return error.TooManyArguments;
                }
                extra_args[extra_count] = arg;
                extra_count += 1;
            }
        } else if (std.mem.eql(u8, first, "install")) {
            command = .install;
            while (args.next()) |arg| {
                if (extra_count >= extra_args.len) {
                    std.debug.print("labelle: too many arguments\n", .{});
                    return error.TooManyArguments;
                }
                extra_args[extra_count] = arg;
                extra_count += 1;
            }
        } else if (std.mem.eql(u8, first, "upgrade")) {
            command = .upgrade;
            // First non-package arg could be a directory
            if (args.next()) |next_arg| {
                // If it looks like a package name, treat as extra arg
                if (std.mem.eql(u8, next_arg, "core") or
                    std.mem.eql(u8, next_arg, "engine") or
                    std.mem.eql(u8, next_arg, "gfx") or
                    std.mem.eql(u8, next_arg, "cli") or
                    std.mem.eql(u8, next_arg, "labelle") or
                    std.mem.eql(u8, next_arg, "all"))
                {
                    extra_args[extra_count] = next_arg;
                    extra_count += 1;
                } else {
                    project_dir = next_arg;
                }
            }
            while (args.next()) |arg| {
                if (extra_count >= extra_args.len) {
                    std.debug.print("labelle: too many arguments\n", .{});
                    return error.TooManyArguments;
                }
                extra_args[extra_count] = arg;
                extra_count += 1;
            }
        } else if (std.mem.eql(u8, first, "update")) {
            command = .update;
            while (args.next()) |arg| {
                if (extra_count >= extra_args.len) {
                    std.debug.print("labelle: too many arguments\n", .{});
                    return error.TooManyArguments;
                }
                extra_args[extra_count] = arg;
                extra_count += 1;
            }
        } else if (std.mem.eql(u8, first, "help") or std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
            command = .help;
        } else if (std.mem.eql(u8, first, "version") or std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-v")) {
            command = .version;
        } else if (std.mem.eql(u8, first, "targets")) {
            command = .targets;
        } else {
            // No command — treat as project dir, default to run
            project_dir = first;
        }
    }

    // Standalone commands (no project.labelle needed)
    switch (command) {
        .help => return printHelp(),
        .version => return printVersion(),
        .targets => return printTargets(),
        .init => return cmdInit(allocator, extra_args[0..extra_count]),
        .install => return cmdInstall(allocator, extra_args[0..extra_count]),
        .update => return cmdUpdate(allocator, extra_args[0..extra_count]),
        else => {},
    }

    // Read and parse project.labelle
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = readProjectConfig(arena.allocator(), project_dir) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("\n  No project.labelle found in '{s}'.\n\n", .{project_dir});
            std.debug.print("  To create a new project:\n", .{});
            std.debug.print("    labelle init <name>\n\n", .{});
            std.debug.print("  To see all commands:\n", .{});
            std.debug.print("    labelle help\n\n", .{});
        }
        return;
    };

    // Upgrade modifies project.labelle in the project directory
    if (command == .upgrade) {
        return cmdUpgrade(allocator, project_dir, parsed, extra_args[0..extra_count]);
    }

    // Ensure package cache is populated
    try ensureCache(allocator, parsed);

    // Validate version compatibility
    validateCompatibility(parsed);

    // Generate into .labelle/
    const output_dir = try std.fs.path.join(allocator, &.{ project_dir, ".labelle" });
    defer allocator.free(output_dir);

    std.debug.print("labelle: generating '{s}'...\n", .{parsed.name});
    std.debug.print("  backend: {s}  platform: {s}  ecs: {s}  gui: {s}  window: {d}x{d}\n", .{
        @tagName(parsed.backend), @tagName(parsed.platform), @tagName(parsed.ecs), @tagName(parsed.gui), parsed.width, parsed.height,
    });

    try gen.generate(allocator, parsed, output_dir, project_dir);

    // Target subdir: .labelle/raylib_desktop/, etc.
    const target_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ @tagName(parsed.backend), @tagName(parsed.platform) });
    defer allocator.free(target_name);
    const target_dir = try std.fs.path.join(allocator, &.{ output_dir, target_name });
    defer allocator.free(target_dir);

    try fixFingerprint(allocator, target_dir);
    try writeLockFile(allocator, project_dir, parsed);
    std.debug.print("  generated .labelle/{s}/\n", .{target_name});

    if (command == .generate) return;

    // Build
    std.debug.print("labelle: building...\n", .{});
    const build_result = try runZig(allocator, target_dir, &.{ "zig", "build" });
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);

    switch (build_result.term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("labelle: build failed:\n{s}\n", .{build_result.stderr});
            return error.BuildFailed;
        },
        else => {
            std.debug.print("labelle: build process terminated abnormally\n{s}\n", .{build_result.stderr});
            return error.BuildFailed;
        },
    }
    std.debug.print("  build ok\n", .{});

    if (command == .build) return;

    // Run
    std.debug.print("labelle: running...\n\n", .{});
    const run_result = try runZigInherit(allocator, target_dir, &.{ "zig", "build", "run" });
    if (run_result != 0) {
        std.debug.print("\nlabelle: process exited with code {d}\n", .{run_result});
    }
}

// ── labelle help / version / targets ─────────────────────────────────

fn printHelp() void {
    std.debug.print(
        \\Labelle CLI v{s}
        \\
        \\Usage: labelle <command> [options]
        \\
        \\Commands:
        \\  init <name> [dir]    Create a new labelle project
        \\  generate [dir]       Generate .labelle/ assembler files
        \\  build [dir]          Generate + build the project
        \\  run [dir]            Generate + build + run (default)
        \\  targets              List available build targets
        \\  install [pkg] [ver]  Fetch packages into cache
        \\  upgrade [dir] [pkg] [ver]  Bump versions in project.labelle
        \\  update [ver]         Update the labelle CLI itself
        \\  help                 Show this help
        \\  version              Show CLI version
        \\
        \\Examples:
        \\  labelle init my-game
        \\  labelle generate
        \\  labelle run
        \\  labelle build ../my-game
        \\  labelle install 0.2.0
        \\  labelle upgrade core 0.2.0
        \\
    , .{gen.CLI_VERSION});
}

fn printVersion() void {
    std.debug.print("labelle v{s}\n", .{gen.CLI_VERSION});
}

fn printTargets() void {
    std.debug.print(
        \\Available backends:
        \\  raylib     Raylib (desktop, web)
        \\  sokol      Sokol (desktop, web)
        \\  sdl        SDL2 (desktop)
        \\  bgfx       BGFX (desktop)
        \\  wgpu       WebGPU (desktop, web)
        \\
        \\Available ECS adapters:
        \\  zig_ecs    zig-ecs
        \\  zflecs     zflecs (Flecs)
        \\  mr_ecs     mr-ecs
        \\
        \\Set backend/ecs in your project.labelle file.
        \\
    , .{});
}

// ── labelle init ─────────────────────────────────────────────────────

/// Scaffold a new project directory with project.labelle and starter files.
/// Usage: labelle init <name> [--backend=X] [--ecs=X] [--gui=X] [dir]
fn cmdInit(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    // Parse flags and positional args
    var name: ?[]const u8 = null;
    var dir_override: ?[]const u8 = null;
    var backend: []const u8 = "raylib";
    var ecs: []const u8 = "zig_ecs";
    var gui: []const u8 = "none";

    for (cmd_args) |arg| {
        if (std.mem.startsWith(u8, arg, "--backend=")) {
            backend = arg["--backend=".len..];
        } else if (std.mem.startsWith(u8, arg, "--ecs=")) {
            ecs = arg["--ecs=".len..];
        } else if (std.mem.startsWith(u8, arg, "--gui=")) {
            gui = arg["--gui=".len..];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("labelle init: unknown flag '{s}'\n", .{arg});
            return error.UnknownFlag;
        } else if (name == null) {
            name = arg;
        } else {
            dir_override = arg;
        }
    }

    const project_name = name orelse {
        std.debug.print("labelle init: missing project name\n", .{});
        std.debug.print("usage: labelle init <name> [--backend=raylib] [--ecs=zig_ecs] [dir]\n", .{});
        return error.MissingArgument;
    };

    const dir = dir_override orelse project_name;
    const cwd = std.fs.cwd();

    // Create project directory
    cwd.makePath(dir) catch |err| {
        std.debug.print("labelle init: could not create '{s}': {any}\n", .{ dir, err });
        return error.InitFailed;
    };

    // Write project.labelle
    {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);

        try w.print(
            \\.{{
            \\    .name = "{s}",
            \\    .title = "{s}",
            \\    .width = 800,
            \\    .height = 600,
            \\    .target_fps = 60,
            \\    .backend = .{s},
            \\    .ecs = .{s},
            \\    .gui = .{s},
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
            \\}}
            \\
        , .{ project_name, project_name, backend, ecs, gui, gen.CLI_VERSION, gen.CLI_VERSION, gen.CLI_VERSION, gen.CLI_VERSION });

        const path = try std.fs.path.join(allocator, &.{ dir, "project.labelle" });
        defer allocator.free(path);
        const file = try cwd.createFile(path, .{ .exclusive = true });
        defer file.close();
        try file.writeAll(buf.items);
    }

    // Create starter directories
    const dirs = [_][]const u8{ "scripts", "scenes", "prefabs", "assets", "components", "hooks" };
    for (dirs) |subdir| {
        const path = try std.fs.path.join(allocator, &.{ dir, subdir });
        defer allocator.free(path);
        cwd.makePath(path) catch {};
    }

    // Write a starter scene
    {
        const path = try std.fs.path.join(allocator, &.{ dir, "scenes", "main.zon" });
        defer allocator.free(path);
        if (cwd.createFile(path, .{ .exclusive = true })) |file| {
            defer file.close();
            file.writeAll(
                \\.{
                \\    .name = "main",
                \\    .entities = .{},
                \\}
                \\
            ) catch {};
        } else |err| {
            if (err != error.PathAlreadyExists) return err;
        }
    }

    // Write .gitignore
    {
        const path = try std.fs.path.join(allocator, &.{ dir, ".gitignore" });
        defer allocator.free(path);
        if (cwd.createFile(path, .{ .exclusive = true })) |file| {
            defer file.close();
            file.writeAll(".labelle/\n") catch {};
        } else |err| {
            if (err != error.PathAlreadyExists) return err;
        }
    }

    std.debug.print("labelle: created project '{s}' in {s}/\n", .{ project_name, dir });
    std.debug.print("  next: cd {s} && labelle run\n", .{dir});
}

// ── labelle install ──────────────────────────────────────────────────

/// Fetch and cache packages without modifying any project.
/// Usage: labelle install [pkg version | version]
fn cmdInstall(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    if (cmd_args.len == 0) {
        // Install all packages for the current project
        const parsed = readProjectConfig(allocator, ".") catch {
            std.debug.print("labelle install: no project.labelle found. Usage:\n", .{});
            std.debug.print("  labelle install              — install deps for current project\n", .{});
            std.debug.print("  labelle install <version>    — cache all packages at a version\n", .{});
            std.debug.print("  labelle install core <ver>   — cache a specific package\n", .{});
            return error.MissingArgument;
        };
        try ensureCache(allocator, parsed);
        std.debug.print("labelle: all packages cached\n", .{});
        return;
    }

    if (cmd_args.len == 1) {
        // labelle install 0.3.0 — cache all framework packages at this version
        const version = cmd_args[0];
        std.debug.print("labelle: caching all packages at version {s}...\n", .{version});

        const packages = [_][]const u8{ "core", "engine", "gfx" };
        for (packages) |pkg| {
            if (!try gen.isFrameworkCached(allocator, pkg, version)) {
                std.debug.print("  fetching {s} {s}...\n", .{ pkg, version });
                try fetchFrameworkWithFallback(allocator, pkg, version);
            } else {
                std.debug.print("  {s} {s} already cached\n", .{ pkg, version });
            }
        }

        if (!try gen.isCliCached(allocator, version)) {
            std.debug.print("  fetching cli {s}...\n", .{version});
            try fetchCliWithFallback(allocator, version);
        } else {
            std.debug.print("  cli {s} already cached\n", .{version});
        }

        std.debug.print("labelle: done\n", .{});
        return;
    }

    // labelle install core 0.2.0
    const pkg_name = cmd_args[0];
    const version = cmd_args[1];

    if (std.mem.eql(u8, pkg_name, "core") or std.mem.eql(u8, pkg_name, "engine") or std.mem.eql(u8, pkg_name, "gfx")) {
        std.debug.print("labelle: fetching {s} {s}...\n", .{ pkg_name, version });
        try fetchFrameworkWithFallback(allocator, pkg_name, version);
    } else if (std.mem.eql(u8, pkg_name, "cli")) {
        std.debug.print("labelle: fetching cli {s}...\n", .{version});
        try fetchCliWithFallback(allocator, version);
    } else {
        std.debug.print("labelle install: unknown package '{s}'\n", .{pkg_name});
        std.debug.print("  known packages: core, engine, gfx, cli\n", .{});
        return error.UnknownPackage;
    }

    std.debug.print("labelle: done\n", .{});
}

// ── labelle upgrade ──────────────────────────────────────────────────

/// Bump version fields in project.labelle.
/// Usage: labelle upgrade [dir] [pkg] [version]
fn cmdUpgrade(allocator: std.mem.Allocator, project_dir: []const u8, cfg: gen.ProjectConfig, cmd_args: []const []const u8) !void {
    const labelle_path = try std.fs.path.join(allocator, &.{ project_dir, "project.labelle" });
    defer allocator.free(labelle_path);

    var content = try std.fs.cwd().readFileAlloc(allocator, labelle_path, 1024 * 1024);

    const target_version = gen.CLI_VERSION;

    if (cmd_args.len == 0) {
        // Upgrade all framework versions to CLI's latest compatible set
        std.debug.print("labelle: upgrading all framework versions to {s}...\n", .{target_version});
        content = try replaceAndFree(allocator, content, "core_version", cfg.core_version, target_version);
        content = try replaceAndFree(allocator, content, "engine_version", cfg.engine_version, target_version);
        content = try replaceAndFree(allocator, content, "gfx_version", cfg.gfx_version, target_version);
        content = try replaceAndFree(allocator, content, "labelle_version", cfg.labelle_version, target_version);
    } else {
        const pkg = cmd_args[0];
        const version = if (cmd_args.len > 1) cmd_args[1] else target_version;

        if (std.mem.eql(u8, pkg, "core")) {
            content = try replaceAndFree(allocator, content, "core_version", cfg.core_version, version);
        } else if (std.mem.eql(u8, pkg, "engine")) {
            content = try replaceAndFree(allocator, content, "engine_version", cfg.engine_version, version);
        } else if (std.mem.eql(u8, pkg, "gfx")) {
            content = try replaceAndFree(allocator, content, "gfx_version", cfg.gfx_version, version);
        } else if (std.mem.eql(u8, pkg, "labelle") or std.mem.eql(u8, pkg, "cli")) {
            content = try replaceAndFree(allocator, content, "labelle_version", cfg.labelle_version, version);
        } else if (std.mem.eql(u8, pkg, "all")) {
            content = try replaceAndFree(allocator, content, "core_version", cfg.core_version, version);
            content = try replaceAndFree(allocator, content, "engine_version", cfg.engine_version, version);
            content = try replaceAndFree(allocator, content, "gfx_version", cfg.gfx_version, version);
            content = try replaceAndFree(allocator, content, "labelle_version", cfg.labelle_version, version);
        } else {
            std.debug.print("labelle upgrade: unknown package '{s}'\n", .{pkg});
            std.debug.print("  packages: core, engine, gfx, cli, all\n", .{});
            allocator.free(content);
            return error.UnknownPackage;
        }

        std.debug.print("labelle: upgrading {s} to {s}...\n", .{ pkg, version });
    }

    // Write back
    const file = try std.fs.cwd().createFile(labelle_path, .{});
    defer file.close();
    try file.writeAll(content);
    allocator.free(content);

    std.debug.print("labelle: project.labelle updated\n", .{});
    std.debug.print("  run 'labelle generate' to regenerate build files\n", .{});
}

/// Replace a version field and free the old content.
fn replaceAndFree(allocator: std.mem.Allocator, old_content: []u8, field_name: []const u8, old_value: []const u8, new_value: []const u8) ![]u8 {
    errdefer allocator.free(old_content);
    const result = try replaceVersionField(allocator, old_content, field_name, old_value, new_value);
    allocator.free(old_content);
    return result;
}

/// Replace a version field value in project.labelle content.
/// Finds `.field_name = "old_value"` and replaces old_value with new_value.
fn replaceVersionField(allocator: std.mem.Allocator, content: []const u8, field_name: []const u8, old_value: []const u8, new_value: []const u8) ![]u8 {
    // Build the search string: .field_name = "old_value"
    const search = try std.fmt.allocPrint(allocator, ".{s} = \"{s}\"", .{ field_name, old_value });
    defer allocator.free(search);
    const replace = try std.fmt.allocPrint(allocator, ".{s} = \"{s}\"", .{ field_name, new_value });
    defer allocator.free(replace);

    if (std.mem.indexOf(u8, content, search)) |idx| {
        var result = std.ArrayList(u8){};
        try result.appendSlice(allocator, content[0..idx]);
        try result.appendSlice(allocator, replace);
        try result.appendSlice(allocator, content[idx + search.len ..]);
        return result.toOwnedSlice(allocator);
    }

    // Field not found — return a copy
    return try allocator.dupe(u8, content);
}

// ── labelle update ───────────────────────────────────────────────────

/// Self-update the CLI binary by downloading from the release server.
/// Usage: labelle update [version]
fn cmdUpdate(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    const r2_base_url = "https://releases.labelle.games/cli";

    std.debug.print("labelle: checking for updates...\n", .{});
    std.debug.print("  current version: {s}\n\n", .{gen.CLI_VERSION});

    // Determine target version
    var target_version: []const u8 = undefined;
    var target_version_owned: ?[]u8 = null;
    defer if (target_version_owned) |v| allocator.free(v);

    if (cmd_args.len > 0) {
        // Explicit version requested
        target_version = cmd_args[0];
    } else {
        // Fetch latest version from R2
        const latest_url = r2_base_url ++ "/latest.txt";
        const result = runCmd(allocator, &.{ "curl", "-s", "-f", latest_url }) catch {
            std.debug.print("labelle: could not check for updates (is curl installed?)\n", .{});
            printManualUpdateInstructions("latest");
            return;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| if (code != 0) {
                std.debug.print("labelle: could not fetch latest version from release server\n", .{});
                printManualUpdateInstructions("latest");
                return;
            },
            else => {
                std.debug.print("labelle: curl terminated abnormally\n", .{});
                return;
            },
        }

        var latest = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
        if (std.mem.startsWith(u8, latest, "v")) latest = latest[1..];

        target_version_owned = try allocator.dupe(u8, latest);
        target_version = target_version_owned.?;
    }

    // Compare versions
    const current = parseVersion(gen.CLI_VERSION);
    const target = parseVersion(target_version);

    if (current >= target) {
        if (current > target) {
            std.debug.print("  you are running a newer version ({s}) than {s}\n", .{ gen.CLI_VERSION, target_version });
        } else {
            std.debug.print("  already on the latest version ({s})\n", .{gen.CLI_VERSION});
        }
        return;
    }

    std.debug.print("  new version available: {s}\n\n", .{target_version});

    // Determine platform
    const builtin = @import("builtin");
    const os_name: []const u8 = switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "windows",
        else => {
            std.debug.print("labelle: unsupported platform for binary download\n", .{});
            printManualUpdateInstructions(target_version);
            return;
        },
    };
    const arch_name: []const u8 = switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x86_64",
        else => {
            std.debug.print("labelle: unsupported architecture for binary download\n", .{});
            printManualUpdateInstructions(target_version);
            return;
        },
    };

    // Download
    const download_url = try std.fmt.allocPrint(allocator, "{s}/v{s}/labelle-{s}-{s}", .{
        r2_base_url, target_version, os_name, arch_name,
    });
    defer allocator.free(download_url);

    const tmp_path = try getTempFilePath(allocator, "labelle-update");
    defer allocator.free(tmp_path);
    std.debug.print("  downloading {s}...\n", .{download_url});

    const dl_result = runCmd(allocator, &.{ "curl", "-s", "-f", "-o", tmp_path, download_url }) catch {
        std.debug.print("labelle: download failed (is curl installed?)\n", .{});
        printManualUpdateInstructions(target_version);
        return;
    };
    defer allocator.free(dl_result.stdout);
    defer allocator.free(dl_result.stderr);

    switch (dl_result.term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("labelle: download failed (HTTP error)\n", .{});
            printManualUpdateInstructions(target_version);
            return;
        },
        else => {
            std.debug.print("labelle: download process terminated abnormally\n", .{});
            return;
        },
    }

    // Make executable (Unix only; builtin already imported above for platform detection)
    if (builtin.os.tag != .windows) {
        _ = runCmd(allocator, &.{ "chmod", "+x", tmp_path }) catch {};
    }

    std.debug.print("\n  downloaded v{s} to {s}\n\n", .{ target_version, tmp_path });
    std.debug.print("  to complete the update, run:\n", .{});

    // Try to find where the current binary is
    const exe_path = std.fs.selfExePathAlloc(allocator) catch null;
    defer if (exe_path) |p| allocator.free(p);

    if (builtin.os.tag == .windows) {
        if (exe_path) |path| {
            std.debug.print("    move {s} {s}\n", .{ tmp_path, path });
        } else {
            std.debug.print("    move {s} labelle.exe\n", .{tmp_path});
        }
    } else {
        if (exe_path) |path| {
            std.debug.print("    sudo mv {s} {s}\n", .{ tmp_path, path });
        } else {
            std.debug.print("    sudo mv {s} /usr/local/bin/labelle\n", .{tmp_path});
        }
    }
}

/// Get a platform-aware temporary file path.
fn getTempFilePath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const builtin = @import("builtin");
    const tmp_base: []const u8 = if (builtin.os.tag == .windows)
        std.process.getEnvVarOwned(allocator, "TEMP") catch
            std.process.getEnvVarOwned(allocator, "TMP") catch
            try allocator.dupe(u8, "C:\\Windows\\Temp")
    else
        try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmp_base);

    return try std.fs.path.join(allocator, &.{ tmp_base, name });
}

fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.Child.RunResult {
    return std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
}

/// Parse semantic version string into a comparable number.
/// "1.2.3" -> 1*1000000 + 2*1000 + 3 = 1002003
/// Supports components up to 999 each.
fn parseVersion(version: []const u8) u32 {
    var parts: [3]u32 = .{ 0, 0, 0 };
    var part_idx: u8 = 0;

    for (version) |c| {
        if (c == '.') {
            part_idx += 1;
            if (part_idx >= 3) break;
        } else if (c >= '0' and c <= '9') {
            parts[part_idx] = parts[part_idx] * 10 + (c - '0');
        }
    }

    return parts[0] * 1_000_000 + parts[1] * 1_000 + parts[2];
}

fn printManualUpdateInstructions(version: []const u8) void {
    std.debug.print("\n  to update manually, download from:\n", .{});
    std.debug.print("    https://releases.labelle.games/cli/v{s}/\n\n", .{version});
    std.debug.print("  or build from source:\n", .{});
    std.debug.print("    git clone https://github.com/labelle-toolkit/labelle-cli.git\n", .{});
    std.debug.print("    zig build -Doptimize=ReleaseSafe\n", .{});
}

fn readProjectConfig(allocator: std.mem.Allocator, project_dir: []const u8) !gen.ProjectConfig {
    const labelle_path = try std.fs.path.join(allocator, &.{ project_dir, "project.labelle" });

    const source_raw = std.fs.cwd().readFileAlloc(allocator, labelle_path, 1024 * 1024) catch |err| {
        std.debug.print("labelle: could not read '{s}': {any}\n", .{ labelle_path, err });
        return error.FileNotFound;
    };

    const source = try allocator.dupeZ(u8, source_raw);

    return std.zon.parse.fromSlice(gen.ProjectConfig, allocator, source, null, .{}) catch |err| {
        std.debug.print("labelle: could not parse '{s}': {any}\n", .{ labelle_path, err });
        return error.ParseError;
    };
}

/// Run a command with inherited stdio (output goes straight to terminal).
fn runZigInherit(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !u8 {
    var child: std.process.Child = .init(argv, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    return switch (term) {
        .Exited => |code| code,
        .Signal => |sig| {
            std.debug.print("labelle: killed by signal {d}\n", .{sig});
            return 1;
        },
        .Stopped => |sig| {
            std.debug.print("labelle: stopped by signal {d}\n", .{sig});
            return 1;
        },
        .Unknown => |val| {
            std.debug.print("labelle: unknown termination {d}\n", .{val});
            return 1;
        },
    };
}

fn runZig(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !std.process.Child.RunResult {
    return std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
    });
}

/// Validate that declared dependency versions are compatible with each other.
/// Checks major.minor compatibility between framework packages.
/// Skipped for any package using a `local:` override.
fn validateCompatibility(cfg: gen.ProjectConfig) void {
    const is_local = gen.isLocalVersion;
    var warnings: u8 = 0;

    // Extract major.minor for each non-local framework version
    const core_mm = if (!is_local(cfg.core_version)) parseMajorMinor(cfg.core_version) else null;
    const engine_mm = if (!is_local(cfg.engine_version)) parseMajorMinor(cfg.engine_version) else null;
    const gfx_mm = if (!is_local(cfg.gfx_version)) parseMajorMinor(cfg.gfx_version) else null;
    const cli_mm = if (!is_local(cfg.labelle_version)) parseMajorMinor(cfg.labelle_version) else null;

    // engine depends on core — major.minor must match
    if (core_mm != null and engine_mm != null and core_mm.? != engine_mm.?) {
        std.debug.print("labelle: warning: engine {s} may be incompatible with core {s}\n", .{ cfg.engine_version, cfg.core_version });
        std.debug.print("  engine depends on core — their major.minor versions should match\n", .{});
        std.debug.print("  hint: run `labelle upgrade all`\n\n", .{});
        warnings += 1;
    }

    // gfx depends on core — major.minor must match
    if (core_mm != null and gfx_mm != null and core_mm.? != gfx_mm.?) {
        std.debug.print("labelle: warning: gfx {s} may be incompatible with core {s}\n", .{ cfg.gfx_version, cfg.core_version });
        std.debug.print("  gfx depends on core — their major.minor versions should match\n", .{});
        std.debug.print("  hint: run `labelle upgrade gfx` or `labelle upgrade all`\n\n", .{});
        warnings += 1;
    }

    // backends (from CLI) depend on core — major.minor must match
    if (core_mm != null and cli_mm != null and core_mm.? != cli_mm.?) {
        std.debug.print("labelle: warning: cli {s} backends may be incompatible with core {s}\n", .{ cfg.labelle_version, cfg.core_version });
        std.debug.print("  backend adapters implement core interfaces — their major.minor versions should match\n", .{});
        std.debug.print("  hint: run `labelle upgrade cli` or `labelle upgrade all`\n\n", .{});
        warnings += 1;
    }

    // plugins depend on core — check each non-local plugin
    for (cfg.plugins) |plugin| {
        if (plugin.isLocal()) continue;
        const plugin_mm = parseMajorMinor(plugin.version);
        if (core_mm != null and plugin_mm != core_mm.?) {
            std.debug.print("labelle: warning: plugin {s} {s} may be incompatible with core {s}\n", .{ plugin.name, plugin.version, cfg.core_version });
            std.debug.print("  plugins depend on core — their major.minor versions should match\n", .{});
            std.debug.print("  hint: update the plugin version in project.labelle\n\n", .{});
            warnings += 1;
        }
    }

    if (warnings > 0) {
        std.debug.print("labelle: {d} compatibility warning(s) — proceeding anyway\n\n", .{warnings});
    }
}

/// Parse a semver string into a major.minor comparable value.
/// "0.3.2" -> 0*100 + 3 = 3  (patch is ignored for compatibility)
fn parseMajorMinor(version: []const u8) u32 {
    var parts: [3]u32 = .{ 0, 0, 0 };
    var part_idx: u8 = 0;

    for (version) |c| {
        if (c == '.') {
            part_idx += 1;
            if (part_idx >= 3) break;
        } else if (c >= '0' and c <= '9') {
            parts[part_idx] = parts[part_idx] * 10 + (c - '0');
        }
    }

    return parts[0] * 100 + parts[1];
}

/// Write labelle.lock into the project root.
/// Records resolved versions for reproducibility and diagnostics.
fn writeLockFile(allocator: std.mem.Allocator, project_dir: []const u8, cfg: gen.ProjectConfig) !void {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll(
        \\// labelle.lock — resolved dependency versions
        \\// Generated by labelle-cli. Commit this file to git.
        \\.{
        \\
    );

    try w.print("    .cli_version = \"{s}\",\n", .{gen.CLI_VERSION});
    try w.print("    .resolved = .{{\n", .{});
    try w.print("        .core = .{{ .version = \"{s}\" }},\n", .{cfg.core_version});
    try w.print("        .engine = .{{ .version = \"{s}\" }},\n", .{cfg.engine_version});
    try w.print("        .gfx = .{{ .version = \"{s}\" }},\n", .{cfg.gfx_version});
    try w.print("        .labelle = .{{ .version = \"{s}\" }},\n", .{cfg.labelle_version});
    try w.print("        .backend = .{{ .name = \"{s}\", .platform = \"{s}\" }},\n", .{ @tagName(cfg.backend), @tagName(cfg.platform) });

    if (cfg.ecs != .mock) {
        try w.print("        .ecs = .{{ .name = \"{s}\" }},\n", .{@tagName(cfg.ecs)});
    }
    if (cfg.gui != .none) {
        try w.print("        .gui = .{{ .name = \"{s}\" }},\n", .{@tagName(cfg.gui)});
    }

    try w.writeAll("    },\n");

    // Plugins
    if (cfg.plugins.len > 0) {
        try w.writeAll("    .plugins = .{\n");
        for (cfg.plugins) |plugin| {
            try w.print("        .{{ .name = \"{s}\", .repo = \"{s}\", .version = \"{s}\" }},\n", .{
                plugin.name, plugin.repo, plugin.version,
            });
        }
        try w.writeAll("    },\n");
    }

    try w.writeAll("}\n");

    // Write to project_dir/labelle.lock
    const lock_path = try std.fs.path.join(allocator, &.{ project_dir, "labelle.lock" });
    defer allocator.free(lock_path);

    const file = try std.fs.cwd().createFile(lock_path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

/// Ensure all dependencies declared in the project config are present in the local cache.
/// Tries monorepo first (for development), falls back to remote fetching.
fn ensureCache(allocator: std.mem.Allocator, cfg: gen.ProjectConfig) !void {
    const missing = try gen.validateCache(allocator, cfg);
    defer {
        for (missing) |m| allocator.free(m);
        allocator.free(missing);
    }

    if (missing.len == 0) return;

    std.debug.print("labelle: populating package cache...\n", .{});

    // Framework packages: core, engine, gfx
    const framework = [_]struct { name: []const u8, version: []const u8, dir: []const u8 }{
        .{ .name = "core", .version = cfg.core_version, .dir = "labelle-core" },
        .{ .name = "engine", .version = cfg.engine_version, .dir = "engine" },
        .{ .name = "gfx", .version = cfg.gfx_version, .dir = "labelle-gfx" },
    };

    for (framework) |pkg| {
        if (!try gen.isFrameworkCached(allocator, pkg.name, pkg.version)) {
            try fetchFrameworkWithFallback(allocator, pkg.name, pkg.version);
        }
    }

    // CLI-bundled packages (backends, ecs, gui)
    if (!try gen.isCliCached(allocator, cfg.labelle_version)) {
        try fetchCliWithFallback(allocator, cfg.labelle_version);
    }

    // Plugins
    for (cfg.plugins) |plugin| {
        if (!try gen.isPluginCached(allocator, plugin)) {
            try fetchPluginWithFallback(allocator, plugin);
        }
    }

    std.debug.print("  cache populated\n", .{});
}

/// Fetch a framework package: try monorepo first, then remote git clone.
fn fetchFrameworkWithFallback(allocator: std.mem.Allocator, name: []const u8, version: []const u8) !void {
    // Try monorepo first
    if (findRepoRoot(allocator)) |repo_root| {
        defer allocator.free(repo_root);
        const dir_name: []const u8 = if (std.mem.eql(u8, name, "core"))
            "labelle-core"
        else if (std.mem.eql(u8, name, "engine"))
            "engine"
        else if (std.mem.eql(u8, name, "gfx"))
            "labelle-gfx"
        else
            name;
        const src = try std.fs.path.join(allocator, &.{ repo_root, dir_name });
        defer allocator.free(src);

        if (dirExists(src)) {
            std.debug.print("  caching {s} {s} (local)\n", .{ name, version });
            try gen.populateFrameworkPackage(allocator, name, version, src);
            return;
        }
    }

    // Fall back to remote fetch
    std.debug.print("  fetching {s} {s} (remote)...\n", .{ name, version });
    try gen.fetchFrameworkPackage(allocator, name, version);
}

/// Fetch CLI-bundled packages: try monorepo first, then remote.
fn fetchCliWithFallback(allocator: std.mem.Allocator, version: []const u8) !void {
    // Try monorepo first
    if (findRepoRoot(allocator)) |repo_root| {
        defer allocator.free(repo_root);
        const companion = try std.fs.path.join(allocator, &.{ repo_root, "labelle-cli" });
        defer allocator.free(companion);

        if (dirExists(companion)) {
            std.debug.print("  caching cli {s} (local)\n", .{version});
            try gen.populateCliCache(allocator, version, companion);
            return;
        }
    }

    // Fall back to remote fetch
    std.debug.print("  fetching cli {s} (remote)...\n", .{version});
    try gen.fetchCliPackages(allocator, version);
}

/// Fetch a plugin: try monorepo first, then remote git clone.
fn fetchPluginWithFallback(allocator: std.mem.Allocator, plugin: gen.PluginDep) !void {
    // Try monorepo first
    if (findRepoRoot(allocator)) |repo_root| {
        defer allocator.free(repo_root);
        const plugin_dir = try std.fmt.allocPrint(allocator, "labelle-{s}", .{plugin.name});
        defer allocator.free(plugin_dir);
        const src = try std.fs.path.join(allocator, &.{ repo_root, plugin_dir });
        defer allocator.free(src);

        if (dirExists(src)) {
            std.debug.print("  caching plugin {s} {s} (local)\n", .{ plugin.name, plugin.version });
            try gen.populatePlugin(allocator, plugin, src);
            return;
        }
    }

    // Fall back to remote fetch
    std.debug.print("  fetching plugin {s} {s} (remote)...\n", .{ plugin.name, plugin.version });
    try gen.fetchPlugin(allocator, plugin);
}

fn dirExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Try to find the monorepo root by walking up from the CLI executable path.
/// Returns null if we can't determine it (e.g. installed globally, not in monorepo).
fn findRepoRoot(allocator: std.mem.Allocator) ?[]const u8 {
    // Get the CLI executable's directory
    const exe_path = std.fs.selfExePathAlloc(allocator) catch return null;
    defer allocator.free(exe_path);

    // Walk up from exe dir looking for a directory that contains labelle-core/
    // (as a marker that we're in the monorepo)
    var dir = std.fs.path.dirname(exe_path) orelse return null;
    var depth: u8 = 0;
    while (depth < 6) : (depth += 1) {
        // Check if this directory contains labelle-core/
        const marker = std.fs.path.join(allocator, &.{ dir, "labelle-core" }) catch return null;
        defer allocator.free(marker);

        std.fs.cwd().access(marker, .{}) catch {
            dir = std.fs.path.dirname(dir) orelse return null;
            continue;
        };

        return allocator.dupe(u8, dir) catch return null;
    }

    return null;
}

/// Run `zig build` in output_dir, parse the fingerprint error, and patch build.zig.zon.
fn fixFingerprint(allocator: std.mem.Allocator, output_dir: []const u8) !void {
    const zon_path = try std.fs.path.join(allocator, &.{ output_dir, "build.zig.zon" });
    defer allocator.free(zon_path);

    const result = try runZig(allocator, output_dir, &.{ "zig", "build" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const marker = "use this value: ";
    if (std.mem.indexOf(u8, result.stderr, marker)) |idx| {
        const start = idx + marker.len;
        var end = start;
        while (end < result.stderr.len and result.stderr[end] != '\n' and result.stderr[end] != ';') {
            end += 1;
        }
        const suggested = result.stderr[start..end];

        const zon_content = try std.fs.cwd().readFileAlloc(allocator, zon_path, 1024 * 1024);
        defer allocator.free(zon_content);

        const fp_marker = ".fingerprint = ";
        if (std.mem.indexOf(u8, zon_content, fp_marker)) |fp_idx| {
            const val_start = fp_idx + fp_marker.len;
            var val_end = val_start;
            while (val_end < zon_content.len and zon_content[val_end] != ',') {
                val_end += 1;
            }

            var new_content: std.ArrayList(u8) = .{};
            defer new_content.deinit(allocator);
            try new_content.appendSlice(allocator, zon_content[0..val_start]);
            try new_content.appendSlice(allocator, suggested);
            try new_content.appendSlice(allocator, zon_content[val_end..]);

            const file = try std.fs.cwd().createFile(zon_path, .{});
            defer file.close();
            try file.writeAll(new_content.items);
        }
    }
}
