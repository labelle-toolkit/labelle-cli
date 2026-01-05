// Engine Version Resolver
//
// Handles resolving labelle-engine versions from:
// - "latest" -> fetches latest release from GitHub
// - "0.33.0" -> specific version
// - Local path (for development)

const std = @import("std");

const github_api_url = "https://api.github.com/repos/labelle-toolkit/labelle-engine/releases/latest";
const github_releases_url = "https://api.github.com/repos/labelle-toolkit/labelle-engine/releases";

pub const ResolvedVersion = struct {
    version: []const u8,
    allocated: bool,
};

/// Resolve a version string to a concrete version.
/// "latest" fetches from GitHub API.
/// Specific versions are returned as-is.
pub fn resolveVersion(allocator: std.mem.Allocator, version: []const u8) !ResolvedVersion {
    if (std.mem.eql(u8, version, "latest")) {
        const latest = try getLatestVersion(allocator);
        return .{ .version = latest, .allocated = true };
    }
    return .{ .version = version, .allocated = false };
}

/// Fetch the latest release version from GitHub.
pub fn getLatestVersion(allocator: std.mem.Allocator) ![]const u8 {
    // Use curl to fetch from GitHub API
    var child = std.process.Child.init(&.{
        "curl",
        "-s",
        "-H",
        "Accept: application/vnd.github.v3+json",
        github_api_url,
    }, allocator);

    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    const stdout = child.stdout orelse return error.NoStdout;
    const output = try stdout.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(output);

    _ = try child.wait();

    // Parse JSON to extract tag_name
    // Simple parsing - look for "tag_name": "vX.Y.Z"
    // JSON format: "tag_name": "v0.33.0"
    const marker = "\"tag_name\":";
    const tag_start = std.mem.indexOf(u8, output, marker) orelse return error.InvalidResponse;

    // Find the opening quote of the value (skip whitespace)
    const after_colon = tag_start + marker.len;
    const quote_start = std.mem.indexOfPos(u8, output, after_colon, "\"") orelse return error.InvalidResponse;

    // Find the closing quote
    const quote_end = std.mem.indexOfPos(u8, output, quote_start + 1, "\"") orelse return error.InvalidResponse;

    var version = output[quote_start + 1 .. quote_end];
    // Strip 'v' prefix if present
    if (version.len > 0 and version[0] == 'v') {
        version = version[1..];
    }

    return try allocator.dupe(u8, version);
}

/// Get cache directory for engine versions
fn getCacheDir(allocator: std.mem.Allocator) ![]const u8 {
    // Use ~/.cache/labelle-cli/engines/
    const home = std.posix.getenv("HOME") orelse "/tmp";
    return try std.fmt.allocPrint(allocator, "{s}/.cache/labelle-cli/engines", .{home});
}

/// Get the bootstrap directory path
fn getBootstrapDir(allocator: std.mem.Allocator) ![]const u8 {
    return try allocator.dupe(u8, ".labelle-bootstrap");
}

/// Fetch the package hash for a given URL using zig fetch
fn fetchPackageHash(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var child = std.process.Child.init(&.{ "zig", "fetch", url }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = child.stdout orelse return error.NoStdout;
    const output = try stdout.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(output);

    const result = try child.wait();
    if (result.Exited != 0) {
        return error.FetchFailed;
    }

    // stdout contains the hash (trimmed)
    const hash = std.mem.trim(u8, output, &std.ascii.whitespace);
    if (hash.len == 0) {
        return error.EmptyHash;
    }

    return try allocator.dupe(u8, hash);
}

/// Create a bootstrap build.zig.zon for the given engine version
fn createBootstrapBuildZon(allocator: std.mem.Allocator, dir: std.fs.Dir, version: []const u8, hash: []const u8) !void {
    const content = try std.fmt.allocPrint(allocator,
        \\.{{
        \\    .fingerprint = 0x3dda308fa396ad7d,
        \\    .name = .labelle_bootstrap,
        \\    .version = "0.0.0",
        \\    .minimum_zig_version = "0.15.2",
        \\    .dependencies = .{{
        \\        .@"labelle-engine" = .{{
        \\            .url = "git+https://github.com/labelle-toolkit/labelle-engine?ref=v{s}",
        \\            .hash = "{s}",
        \\        }},
        \\    }},
        \\    .paths = .{{ "build.zig", "build.zig.zon" }},
        \\}}
        \\
    , .{ version, hash });
    defer allocator.free(content);

    var file = try dir.createFile("build.zig.zon", .{});
    defer file.close();
    try file.writeAll(content);
}

/// Create a bootstrap build.zig that runs the engine's generator
fn createBootstrapBuildZig(dir: std.fs.Dir, project_path: []const u8) !void {
    _ = project_path;
    const content =
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
        \\    const engine_dep = b.dependency("labelle-engine", .{
        \\        .target = target,
        \\        .optimize = optimize,
        \\    });
        \\
        \\    // Get the generator executable from the engine
        \\    const generator = engine_dep.artifact("labelle-generate");
        \\
        \\    // Run step that executes the generator
        \\    const run_generator = b.addRunArtifact(generator);
        \\    run_generator.setCwd(b.path(".."));  // Run in project directory
        \\
        \\    // Pass through any arguments
        \\    if (b.args) |args| {
        \\        run_generator.addArgs(args);
        \\    }
        \\
        \\    const run_step = b.step("run", "Run the generator");
        \\    run_step.dependOn(&run_generator.step);
        \\}
        \\
    ;

    var file = try dir.createFile("build.zig", .{});
    defer file.close();
    try file.writeAll(content);
}

/// Run the engine's generator with the given arguments.
pub fn runEngineGenerator(allocator: std.mem.Allocator, version: []const u8, project_path: []const u8) !void {
    const bootstrap_dir_path = try getBootstrapDir(allocator);
    defer allocator.free(bootstrap_dir_path);

    // Create bootstrap directory
    std.fs.cwd().makeDir(bootstrap_dir_path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var bootstrap_dir = try std.fs.cwd().openDir(bootstrap_dir_path, .{});
    defer bootstrap_dir.close();

    // First, fetch the engine to get its hash
    const engine_url = try std.fmt.allocPrint(
        allocator,
        "git+https://github.com/labelle-toolkit/labelle-engine?ref=v{s}",
        .{version},
    );
    defer allocator.free(engine_url);

    std.debug.print("Fetching labelle-engine {s}...\n", .{version});

    const hash = fetchPackageHash(allocator, engine_url) catch |err| {
        std.debug.print("Error fetching engine: {}\n", .{err});
        return error.FetchFailed;
    };
    defer allocator.free(hash);

    // Create bootstrap build files
    try createBootstrapBuildZon(allocator, bootstrap_dir, version, hash);
    try createBootstrapBuildZig(bootstrap_dir, project_path);

    std.debug.print("Running generator...\n", .{});

    // Run the generator from the bootstrap directory
    var child = std.process.Child.init(&.{
        "zig",
        "build",
        "run",
    }, allocator);
    child.cwd = bootstrap_dir_path;

    const result = try child.spawnAndWait();
    if (result.Exited != 0) {
        std.debug.print("Generator failed with exit code {}\n", .{result.Exited});
        return error.GeneratorFailed;
    }

    std.debug.print("Generation complete!\n", .{});
}

/// Check if a version exists in the cache
fn isVersionCached(allocator: std.mem.Allocator, version: []const u8) !bool {
    const cache_dir = try getCacheDir(allocator);
    defer allocator.free(cache_dir);

    const version_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_dir, version });
    defer allocator.free(version_dir);

    std.fs.accessAbsolute(version_dir, .{}) catch return false;
    return true;
}

test "resolveVersion returns version as-is for non-latest" {
    const resolved = try resolveVersion(std.testing.allocator, "0.33.0");
    try std.testing.expectEqualStrings("0.33.0", resolved.version);
    try std.testing.expect(!resolved.allocated);
}
