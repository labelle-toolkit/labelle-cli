// WASM build and serve commands for labelle-cli
//
// Provides commands for building labelle-engine projects to WebAssembly
// using the Sokol backend with Emscripten.
//
// Commands:
//   wasm build     - Build project for WebAssembly
//   wasm serve     - Build and serve locally with hot reload
//   wasm export    - Create optimized production build

const std = @import("std");
const project_config = @import("../project_config.zig");
const engine_resolver = @import("../engine_resolver.zig");

const Allocator = std.mem.Allocator;

/// WASM subcommand
const WasmCommand = enum {
    build,
    serve,
    @"export",
    help,
};

/// WASM build options
const WasmOptions = struct {
    command: WasmCommand = .help,
    debug: bool = false,
    output_dir: []const u8 = "dist",
    port: u16 = 8080,
    no_build: bool = false,
    watch: bool = false,
    no_open: bool = false,
    platform: ?[]const u8 = null,
    zip: bool = false,
    show_help: bool = false,
};

/// Handle wasm subcommands
pub fn handleWasm(allocator: Allocator, args: []const []const u8) !void {
    const options = parseWasmArgs(args);

    if (options.show_help or options.command == .help) {
        printWasmHelp();
        return;
    }

    switch (options.command) {
        .build => try handleWasmBuild(allocator, options),
        .serve => try handleWasmServe(allocator, options),
        .@"export" => try handleWasmExport(allocator, options),
        .help => printWasmHelp(),
    }
}

fn parseWasmArgs(args: []const []const u8) WasmOptions {
    var options = WasmOptions{};

    if (args.len == 0) {
        return options;
    }

    // Parse subcommand
    const cmd_str = args[0];
    if (std.mem.eql(u8, cmd_str, "build")) {
        options.command = .build;
    } else if (std.mem.eql(u8, cmd_str, "serve")) {
        options.command = .serve;
    } else if (std.mem.eql(u8, cmd_str, "export")) {
        options.command = .@"export";
    } else if (std.mem.eql(u8, cmd_str, "help") or
        std.mem.eql(u8, cmd_str, "--help") or
        std.mem.eql(u8, cmd_str, "-h"))
    {
        options.command = .help;
        return options;
    }

    // Parse remaining options
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-d")) {
            options.debug = true;
        } else if (std.mem.eql(u8, arg, "--no-build")) {
            options.no_build = true;
        } else if (std.mem.eql(u8, arg, "--watch") or std.mem.eql(u8, arg, "-w")) {
            options.watch = true;
        } else if (std.mem.eql(u8, arg, "--no-open")) {
            options.no_open = true;
        } else if (std.mem.eql(u8, arg, "--zip")) {
            options.zip = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.show_help = true;
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            options.output_dir = arg["--output=".len..];
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            const port_str = arg["--port=".len..];
            options.port = std.fmt.parseInt(u16, port_str, 10) catch 8080;
        } else if (std.mem.startsWith(u8, arg, "--platform=")) {
            options.platform = arg["--platform=".len..];
        }
    }

    return options;
}

fn handleWasmBuild(allocator: Allocator, options: WasmOptions) !void {
    // Read project config
    const config = project_config.readProjectConfig(allocator, ".") catch |err| {
        std.debug.print("Error reading project.labelle: {}\n", .{err});
        std.debug.print("Run 'labelle init <name>' to create a new project\n", .{});
        return;
    };
    defer config.deinit(allocator);

    const project_name = config.name orelse "game";

    std.debug.print("Building {s} for WebAssembly...\n", .{project_name});
    std.debug.print("  Backend: Sokol (WebGL2)\n", .{});
    std.debug.print("  Configuration: {s}\n", .{if (options.debug) "Debug" else "Release"});
    std.debug.print("\n", .{});

    // Step 1: Generate WASM build files
    try generateWasmBuildFiles(allocator, config, options);

    // Step 2: Run zig build for WASM target
    std.debug.print("Running: zig build -Dtarget=wasm32-emscripten\n", .{});

    var build_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer build_args.deinit(allocator);

    try build_args.appendSlice(allocator, &.{ "zig", "build" });
    try build_args.append(allocator, "-Dtarget=wasm32-emscripten");

    if (!options.debug) {
        try build_args.append(allocator, "-Doptimize=ReleaseSmall");
    }

    // Run build and capture output for fingerprint fix
    const run_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = build_args.items,
        .cwd = "wasm",
    }) catch |err| {
        std.debug.print("Failed to run zig build: {}\n", .{err});
        return;
    };
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    if (run_result.term.Exited != 0) {
        // Check if it's a fingerprint error and try to fix it
        const prefix = "use this value: 0x";
        if (std.mem.indexOf(u8, run_result.stderr, prefix)) |start| {
            const fp_start = start + prefix.len;
            if (fp_start + 16 <= run_result.stderr.len) {
                const suggested_fp = run_result.stderr[fp_start .. fp_start + 16];

                std.debug.print("Fixing fingerprint and retrying...\n", .{});

                // Update build.zig.zon with correct fingerprint
                try fixFingerprint(allocator, "wasm/build.zig.zon", suggested_fp);

                // Retry the build
                var retry_child = std.process.Child.init(build_args.items, allocator);
                retry_child.cwd = "wasm";

                const retry_term = try retry_child.spawnAndWait();
                if (retry_term.Exited != 0) {
                    std.debug.print("\nBuild failed!\n", .{});
                    return;
                }
            }
        } else {
            // Print the error output if not a fingerprint error
            std.debug.print("{s}", .{run_result.stderr});
            std.debug.print("\nBuild failed!\n", .{});
            return;
        }
    }

    // Step 3: Generate HTML shell and copy to output
    try generateHtmlShell(allocator, config, options);

    // Get output size info
    const wasm_path = try std.fmt.allocPrint(allocator, "{s}/{s}.wasm", .{ options.output_dir, project_name });
    defer allocator.free(wasm_path);

    var wasm_size: u64 = 0;
    if (std.fs.cwd().openFile(wasm_path, .{})) |file| {
        defer file.close();
        const stat = try file.stat();
        wasm_size = stat.size;
    } else |_| {}

    std.debug.print("\nBuild successful!\n", .{});
    std.debug.print("  Output: ./{s}/\n", .{options.output_dir});
    if (wasm_size > 0) {
        std.debug.print("  Size: {d} KB (WASM)\n", .{wasm_size / 1024});
    }
}

fn handleWasmServe(allocator: Allocator, options: WasmOptions) !void {
    // Build first if needed
    if (!options.no_build) {
        try handleWasmBuild(allocator, options);
        std.debug.print("\n", .{});
    }

    std.debug.print("Starting server...\n", .{});
    std.debug.print("  Local:   http://localhost:{d}\n", .{options.port});
    std.debug.print("\nPress Ctrl+C to stop\n\n", .{});

    // Use Python's http.server as it's widely available
    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{options.port});
    defer allocator.free(port_str);

    var child = std.process.Child.init(&.{
        "python3",
        "-m",
        "http.server",
        port_str,
        "--directory",
        options.output_dir,
    }, allocator);

    // Open browser if not disabled
    if (!options.no_open) {
        const url = try std.fmt.allocPrint(allocator, "http://localhost:{d}", .{options.port});
        defer allocator.free(url);

        var open_child = std.process.Child.init(&.{ "open", url }, allocator);
        _ = open_child.spawnAndWait() catch {};
    }

    _ = try child.spawnAndWait();
}

fn handleWasmExport(allocator: Allocator, options: WasmOptions) !void {
    // Build with release optimizations
    var build_options = options;
    build_options.debug = false;
    build_options.output_dir = if (options.platform != null)
        "release"
    else
        options.output_dir;

    try handleWasmBuild(allocator, build_options);

    // Create zip if requested
    if (options.zip) {
        const config = project_config.readProjectConfig(allocator, ".") catch return;
        defer config.deinit(allocator);

        const project_name = config.name orelse "game";
        const zip_name = try std.fmt.allocPrint(allocator, "{s}-wasm.zip", .{project_name});
        defer allocator.free(zip_name);

        std.debug.print("\nCreating {s}...\n", .{zip_name});

        var zip_child = std.process.Child.init(&.{
            "zip",
            "-r",
            zip_name,
            build_options.output_dir,
        }, allocator);
        _ = zip_child.spawnAndWait() catch {
            std.debug.print("Warning: Could not create zip (zip command not found)\n", .{});
        };
    }

    std.debug.print("\nExport complete! Ready to deploy.\n", .{});
}

fn generateWasmBuildFiles(allocator: Allocator, config: project_config.ProjectConfig, options: WasmOptions) !void {
    _ = options;

    // Create wasm directory
    std.fs.cwd().makeDir("wasm") catch {};

    const engine_version = config.engine_version orelse "latest";
    const project_name = config.name orelse "game";
    const physics_enabled = config.physics_enabled;

    // Resolve engine version for hash
    const resolved = engine_resolver.resolveVersion(allocator, engine_version, false) catch |err| {
        std.debug.print("Error resolving engine version: {}\n", .{err});
        return err;
    };
    defer if (resolved.allocated) allocator.free(resolved.version);

    // Fetch engine hash - construct full URL
    const engine_url = try std.fmt.allocPrint(allocator, "git+https://github.com/labelle-toolkit/labelle-engine#v{s}", .{resolved.version});
    defer allocator.free(engine_url);

    const engine_hash = try engine_resolver.fetchPackageHash(allocator, engine_url);
    defer allocator.free(engine_hash);

    // Generate build.zig.zon
    const build_zon = try generateWasmBuildZon(allocator, project_name, resolved.version, engine_hash, physics_enabled);
    defer allocator.free(build_zon);

    var zon_file = try std.fs.cwd().createFile("wasm/build.zig.zon", .{});
    defer zon_file.close();
    try zon_file.writeAll(build_zon);

    // Generate build.zig
    const build_zig = try generateWasmBuildZig(allocator, project_name, physics_enabled);
    defer allocator.free(build_zig);

    var zig_file = try std.fs.cwd().createFile("wasm/build.zig", .{});
    defer zig_file.close();
    try zig_file.writeAll(build_zig);

    std.debug.print("Generated WASM build files in wasm/\n", .{});
}

fn generateWasmBuildZon(
    allocator: Allocator,
    project_name: []const u8,
    engine_version: []const u8,
    engine_hash: []const u8,
    physics_enabled: bool,
) ![]const u8 {
    _ = physics_enabled;

    // Convert hyphens to underscores for valid Zig identifier
    const safe_name = try allocator.dupe(u8, project_name);
    defer allocator.free(safe_name);
    for (safe_name) |*c| {
        if (c.* == '-') c.* = '_';
    }

    // Generate a simple fingerprint based on project name
    var fingerprint: u64 = 0;
    for (safe_name) |c| {
        fingerprint = fingerprint *% 31 +% c;
    }

    return try std.fmt.allocPrint(allocator,
        \\.{{
        \\    .fingerprint = 0x{x},
        \\    .name = .{s}_wasm,
        \\    .version = "0.1.0",
        \\    .dependencies = .{{
        \\        .@"labelle-engine" = .{{
        \\            .url = "git+https://github.com/labelle-toolkit/labelle-engine#v{s}",
        \\            .hash = "{s}",
        \\        }},
        \\    }},
        \\    .paths = .{{ "build.zig", "build.zig.zon" }},
        \\}}
        \\
    , .{ fingerprint, safe_name, engine_version, engine_hash });
}

fn generateWasmBuildZig(allocator: Allocator, project_name: []const u8, physics_enabled: bool) ![]const u8 {
    const physics_flag = if (physics_enabled) "true" else "false";

    // Convert hyphens to underscores for valid Zig identifier
    const safe_name = try allocator.dupe(u8, project_name);
    defer allocator.free(safe_name);
    for (safe_name) |*c| {
        if (c.* == '-') c.* = '_';
    }

    return try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {{
        \\    // WASM target using Emscripten
        \\    const target = b.standardTargetOptions(.{{
        \\        .default_target = .{{
        \\            .cpu_arch = .wasm32,
        \\            .os_tag = .emscripten,
        \\        }},
        \\    }});
        \\
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\
        \\    // Get labelle-engine dependency
        \\    const labelle_dep = b.dependency("labelle-engine", .{{
        \\        .target = target,
        \\        .optimize = optimize,
        \\        .backend = .sokol,
        \\        .physics = {s},
        \\    }});
        \\
        \\    // Build the game for WASM
        \\    const exe = b.addExecutable(.{{
        \\        .name = "{s}",
        \\        .root_module = b.createModule(.{{
        \\            .root_source_file = b.path("../main.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\            .imports = &.{{
        \\                .{{ .name = "labelle-engine", .module = labelle_dep.module("labelle-engine") }},
        \\            }},
        \\        }}),
        \\    }});
        \\
        \\    // Link with libc for Emscripten
        \\    exe.linkLibC();
        \\
        \\    b.installArtifact(exe);
        \\}}
        \\
    , .{ physics_flag, safe_name });
}

fn generateHtmlShell(allocator: Allocator, config: project_config.ProjectConfig, options: WasmOptions) !void {
    const project_name = config.name orelse "game";

    // Create output directory
    std.fs.cwd().makeDir(options.output_dir) catch {};

    // Copy WASM file
    const wasm_src = try std.fmt.allocPrint(allocator, "wasm/zig-out/bin/{s}.wasm", .{project_name});
    defer allocator.free(wasm_src);

    const wasm_dst = try std.fmt.allocPrint(allocator, "{s}/{s}.wasm", .{ options.output_dir, project_name });
    defer allocator.free(wasm_dst);

    std.fs.cwd().copyFile(wasm_src, std.fs.cwd(), wasm_dst, .{}) catch |err| {
        std.debug.print("Warning: Could not copy WASM file: {}\n", .{err});
    };

    // Generate HTML shell
    const html = try generateHtmlContent(allocator, project_name, config);
    defer allocator.free(html);

    const html_path = try std.fmt.allocPrint(allocator, "{s}/index.html", .{options.output_dir});
    defer allocator.free(html_path);

    var html_file = try std.fs.cwd().createFile(html_path, .{});
    defer html_file.close();
    try html_file.writeAll(html);
}

fn generateHtmlContent(allocator: Allocator, project_name: []const u8, config: project_config.ProjectConfig) ![]const u8 {
    const width = config.window_width orelse 800;
    const height = config.window_height orelse 600;
    const title = config.window_title orelse project_name;

    return try std.fmt.allocPrint(allocator,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\    <meta charset="UTF-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\    <title>{s}</title>
        \\    <style>
        \\        * {{
        \\            margin: 0;
        \\            padding: 0;
        \\            box-sizing: border-box;
        \\        }}
        \\        body {{
        \\            background: #1a1a2e;
        \\            display: flex;
        \\            justify-content: center;
        \\            align-items: center;
        \\            min-height: 100vh;
        \\            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
        \\        }}
        \\        #container {{
        \\            text-align: center;
        \\        }}
        \\        canvas {{
        \\            border: 2px solid #4a4a6a;
        \\            border-radius: 8px;
        \\            box-shadow: 0 4px 20px rgba(0, 0, 0, 0.5);
        \\        }}
        \\        #loading {{
        \\            color: #e0e0e0;
        \\            font-size: 18px;
        \\            margin-bottom: 20px;
        \\        }}
        \\        #progress {{
        \\            width: 300px;
        \\            height: 6px;
        \\            background: #2a2a4a;
        \\            border-radius: 3px;
        \\            margin: 10px auto;
        \\            overflow: hidden;
        \\        }}
        \\        #progress-bar {{
        \\            height: 100%;
        \\            background: linear-gradient(90deg, #667eea, #764ba2);
        \\            width: 0%;
        \\            transition: width 0.3s ease;
        \\        }}
        \\        .hidden {{
        \\            display: none !important;
        \\        }}
        \\    </style>
        \\</head>
        \\<body>
        \\    <div id="container">
        \\        <div id="loading">
        \\            <p>Loading {s}...</p>
        \\            <div id="progress">
        \\                <div id="progress-bar"></div>
        \\            </div>
        \\        </div>
        \\        <canvas id="canvas" width="{d}" height="{d}"></canvas>
        \\    </div>
        \\
        \\    <script>
        \\        var Module = {{
        \\            canvas: document.getElementById('canvas'),
        \\            onRuntimeInitialized: function() {{
        \\                document.getElementById('loading').classList.add('hidden');
        \\            }},
        \\            setStatus: function(text) {{
        \\                if (text) {{
        \\                    var match = text.match(/([^(]+)\((\d+(\.\d+)?)\/(\d+)\)/);
        \\                    if (match) {{
        \\                        var progress = (parseInt(match[2]) / parseInt(match[4])) * 100;
        \\                        document.getElementById('progress-bar').style.width = progress + '%';
        \\                    }}
        \\                }}
        \\            }},
        \\            totalDependencies: 0,
        \\            monitorRunDependencies: function(left) {{
        \\                this.totalDependencies = Math.max(this.totalDependencies, left);
        \\                var progress = ((this.totalDependencies - left) / this.totalDependencies) * 100;
        \\                document.getElementById('progress-bar').style.width = progress + '%';
        \\            }}
        \\        }};
        \\    </script>
        \\    <script async src="{s}.js"></script>
        \\</body>
        \\</html>
        \\
    , .{ title, project_name, width, height, project_name });
}

fn fixFingerprint(allocator: Allocator, path: []const u8, new_fp: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    file.close();
    defer allocator.free(content);

    // Find and replace fingerprint
    const fp_prefix = ".fingerprint = 0x";
    if (std.mem.indexOf(u8, content, fp_prefix)) |start| {
        const fp_start = start + fp_prefix.len;
        if (fp_start + 16 <= content.len) {
            // Create new content with updated fingerprint
            var new_content: std.ArrayListUnmanaged(u8) = .empty;
            defer new_content.deinit(allocator);

            try new_content.appendSlice(allocator, content[0..fp_start]);
            try new_content.appendSlice(allocator, new_fp);
            try new_content.appendSlice(allocator, content[fp_start + 16 ..]);

            // Write back
            const write_file = try std.fs.cwd().createFile(path, .{});
            defer write_file.close();
            try write_file.writeAll(new_content.items);
        }
    }
}

fn printWasmHelp() void {
    std.debug.print(
        \\WebAssembly build commands
        \\
        \\Usage: labelle wasm <command> [options]
        \\
        \\Commands:
        \\  build       Build project for WebAssembly
        \\  serve       Build and serve locally
        \\  export      Create optimized production build
        \\
        \\Build Options:
        \\  --debug, -d         Build with debug info (default: release)
        \\  --output=DIR        Output directory (default: dist)
        \\
        \\Serve Options:
        \\  --port=PORT         Server port (default: 8080)
        \\  --no-build          Serve without rebuilding
        \\  --no-open           Don't open browser
        \\  --watch, -w         Watch for changes and rebuild
        \\
        \\Export Options:
        \\  --zip               Create zip archive
        \\  --platform=NAME     Platform-specific build (itch, github-pages)
        \\
        \\Examples:
        \\  labelle wasm build
        \\  labelle wasm serve --port 3000
        \\  labelle wasm export --zip
        \\
    , .{});
}
