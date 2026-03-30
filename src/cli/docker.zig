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

// Shell snippet that locates or fetches xcode-frameworks, then patches build.zig
// to add framework/include/lib search paths for macOS cross-compilation.
const setup_xcode_frameworks =
    // Find xcode-frameworks in the Zig cache by looking for AppKit.framework
    "XCODE_PKG=$(find /root/.cache/zig/p/ -maxdepth 2 -name 'AppKit.framework' -path '*/Frameworks/*' 2>/dev/null | head -1 | sed 's|/Frameworks/AppKit.framework||') && " ++
    // If not cached, clone from Corendos/xcode-frameworks (open-source macOS framework stubs)
    "if [ -z \"$XCODE_PKG\" ]; then " ++
    "apt-get install -y -qq git > /dev/null 2>&1 && " ++
    "git clone --depth 1 -b main https://github.com/Corendos/xcode-frameworks.git /tmp/xcode-fw > /dev/null 2>&1 && " ++
    "XCODE_PKG=/tmp/xcode-fw; fi && " ++
    // Patch build.zig to inject framework search paths before exe.linkLibrary(raylib_artifact)
    "if [ -n \"$XCODE_PKG\" ] && grep -q 'linkLibrary(raylib_artifact)' build.zig; then " ++
    "sed -i \"s|exe.linkLibrary(raylib_artifact);|" ++
    "exe.addFrameworkPath(.{ .cwd_relative = \\\"$XCODE_PKG/Frameworks\\\" });\\n" ++
    "    exe.addSystemIncludePath(.{ .cwd_relative = \\\"$XCODE_PKG/include\\\" });\\n" ++
    "    exe.addLibraryPath(.{ .cwd_relative = \\\"$XCODE_PKG/lib\\\" });\\n" ++
    "    exe.linkLibrary(raylib_artifact);|\" build.zig; fi";

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
/// For desktop platforms, cross-compiles back to the host OS, shares the Zig cache,
/// and injects macOS framework paths from xcode-frameworks for linking.
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

    // For macOS desktop builds, set up xcode-frameworks before building.
    const macos_setup: []const u8 = if (platform == .desktop)
        setup_xcode_frameworks ++ " && "
    else
        "";

    // The script:
    // 1. Installs Zig via pip
    // 2. Fixes the build.zig.zon fingerprint (mirrors fixFingerprint on the host)
    // 3. For macOS desktop: locates/fetches xcode-frameworks and patches build.zig
    // 4. Runs zig build
    const script = try std.fmt.allocPrint(allocator,
        "{s} && cd /labelle/{s} && " ++
            "BUILD_OUT=$({s} 2>&1 || true) && " ++
            "FP=$(echo \"$BUILD_OUT\" | grep 'use this value:' | sed 's/.*use this value: //') && " ++
            "if [ -n \"$FP\" ]; then sed -i \"s/.fingerprint = .*,/.fingerprint = $FP,/\" build.zig.zon; fi && " ++
            "{s}" ++
            "{s}",
        .{ install_zig, subdir, zig_build_cmd, macos_setup, zig_build_cmd },
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
