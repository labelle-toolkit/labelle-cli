const std = @import("std");
const builtin = @import("builtin");
const gen = @import("generator");

const ZIG_VERSION = "0.15.2";

const host_arch = switch (builtin.cpu.arch) {
    .aarch64 => "aarch64",
    .x86_64 => "x86_64",
    else => @compileError("unsupported architecture for docker builds"),
};

const host_target = host_arch ++ "-" ++ @tagName(builtin.os.tag);

const install_zig = "apt-get update -qq > /dev/null 2>&1 && " ++
    "apt-get install -y -qq python3-pip > /dev/null 2>&1 && " ++
    "pip3 install ziglang==" ++ ZIG_VERSION ++ " --break-system-packages > /dev/null 2>&1";

fn zigCacheDir(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "ZIG_GLOBAL_CACHE_DIR")) |dir| {
        return dir;
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".cache", "zig" });
    } else |_| {}

    return error.NoCacheDir;
}

/// Run `zig build` inside a Docker container with inherited stdio.
/// For desktop platforms, cross-compiles back to the host OS and shares the Zig cache.
/// For WASM, uses its own cache (host cache has macOS-native emscripten binaries).
/// Returns the exit code of the docker process.
pub fn runBuild(allocator: std.mem.Allocator, target_dir: []const u8, platform: gen.Platform) !u8 {
    const abs_target = try std.fs.realpathAlloc(allocator, target_dir);
    defer allocator.free(abs_target);

    const parent = std.fs.path.dirname(abs_target) orelse return error.InvalidPath;
    const subdir = std.fs.path.basename(abs_target);

    const labelle_vol = try std.fmt.allocPrint(allocator, "{s}:/labelle", .{parent});
    defer allocator.free(labelle_vol);

    const zig_build_cmd: []const u8 = if (platform == .wasm)
        "python3 -m ziglang build"
    else
        "python3 -m ziglang build -Dtarget=" ++ host_target;

    // The script first runs `zig build` to get the fingerprint error, patches build.zig.zon,
    // then runs the real build. This mirrors fixFingerprint but works inside the container.
    const script = try std.fmt.allocPrint(allocator,
        "{s} && cd /labelle/{s} && " ++
            "BUILD_OUT=$({s} 2>&1 || true) && " ++
            "FP=$(echo \"$BUILD_OUT\" | grep 'use this value:' | sed 's/.*use this value: //') && " ++
            "if [ -n \"$FP\" ]; then sed -i \"s/.fingerprint = .*,/.fingerprint = $FP,/\" build.zig.zon; fi && " ++
            "{s}",
        .{ install_zig, subdir, zig_build_cmd, zig_build_cmd },
    );
    defer allocator.free(script);

    // For non-WASM builds, share the host Zig cache for pre-fetched packages.
    // WASM builds need their own cache since emscripten binaries are platform-specific.
    if (platform != .wasm) {
        const cache_dir = zigCacheDir(allocator) catch "/dev/null";
        defer if (!std.mem.eql(u8, cache_dir, "/dev/null")) allocator.free(cache_dir);
        const cache_vol = try std.fmt.allocPrint(allocator, "{s}:/root/.cache/zig", .{cache_dir});
        defer allocator.free(cache_vol);

        return spawnAndWait(allocator, &.{ "docker", "run", "--rm", "-v", labelle_vol, "-v", cache_vol, "ubuntu:24.04", "bash", "-c", script });
    }

    return spawnAndWait(allocator, &.{ "docker", "run", "--rm", "-v", labelle_vol, "ubuntu:24.04", "bash", "-c", script });
}

fn spawnAndWait(allocator: std.mem.Allocator, argv: []const []const u8) !u8 {
    var child: std.process.Child = .init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    const term = try child.wait();
    return switch (term) {
        .Exited => |code| code,
        .Signal => |sig| {
            std.debug.print("labelle: docker killed by signal {d}\n", .{sig});
            return 1;
        },
        .Stopped => |sig| {
            std.debug.print("labelle: docker stopped by signal {d}\n", .{sig});
            return 1;
        },
        .Unknown => |val| {
            std.debug.print("labelle: docker unknown termination {d}\n", .{val});
            return 1;
        },
    };
}
