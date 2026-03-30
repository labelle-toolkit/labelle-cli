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

// Fix #4: Let stderr through so install failures are visible to the user.
const install_zig = "apt-get update -qq > /dev/null && " ++
    "apt-get install -y -qq python3-pip > /dev/null && " ++
    "pip3 install ziglang==" ++ ZIG_VERSION ++ " --break-system-packages > /dev/null";

// Shell snippet that locates or fetches xcode-frameworks, then patches build.zig
// to add framework/include/lib search paths for macOS cross-compilation.
// Fix #5: Match any linkLibrary call, not just raylib_artifact.
const setup_xcode_frameworks =
    "XCODE_PKG=$(find /root/.cache/zig/p/ -maxdepth 2 -name 'AppKit.framework' -path '*/Frameworks/*' 2>/dev/null | head -1 | sed 's|/Frameworks/AppKit.framework||') && " ++
    "if [ -z \"$XCODE_PKG\" ]; then " ++
    "apt-get install -y -qq git > /dev/null && " ++
    "git clone --depth 1 -b main https://github.com/Corendos/xcode-frameworks.git /tmp/xcode-fw > /dev/null 2>&1 && " ++
    "XCODE_PKG=/tmp/xcode-fw; fi && " ++
    "if [ -n \"$XCODE_PKG\" ] && grep -q 'exe.linkLibrary' build.zig; then " ++
    "sed -i \"1s|^|// xcode-frameworks injected by labelle --docker\\n|\" build.zig && " ++
    "sed -i \"/exe.linkLibrary/i\\\\    exe.addFrameworkPath(.{ .cwd_relative = \\\"$XCODE_PKG/Frameworks\\\" });\" build.zig && " ++
    "sed -i \"/exe.linkLibrary/i\\\\    exe.addSystemIncludePath(.{ .cwd_relative = \\\"$XCODE_PKG/include\\\" });\" build.zig && " ++
    "sed -i \"/exe.linkLibrary/i\\\\    exe.addLibraryPath(.{ .cwd_relative = \\\"$XCODE_PKG/lib\\\" });\" build.zig; fi";

// Fix #6: Use head -1 to handle multiple fingerprint mismatches, and | as sed delimiter.
const fix_fingerprint_script =
    "BUILD_OUT=$({s} 2>&1 || true) && " ++
    "FP=$(echo \"$BUILD_OUT\" | grep 'use this value:' | head -1 | sed 's/.*use this value: //') && " ++
    "if [ -n \"$FP\" ]; then sed -i \"s|.fingerprint = .*,|.fingerprint = $FP,|\" build.zig.zon; fi";

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
/// For macOS targets, shares the Zig cache and injects xcode-frameworks paths.
/// For WASM, uses its own cache (host cache has macOS-native emscripten binaries).
/// Returns the exit code of the docker process.
pub fn runBuild(allocator: std.mem.Allocator, target_dir: []const u8, platform: gen.Platform, target_override: ?[]const u8) !u8 {
    const abs_target = try std.fs.realpathAlloc(allocator, target_dir);
    defer allocator.free(abs_target);

    const parent = std.fs.path.dirname(abs_target) orelse return error.InvalidPath;
    const subdir = std.fs.path.basename(abs_target);

    const labelle_vol = try std.fmt.allocPrint(allocator, "{s}:/labelle", .{parent});
    defer allocator.free(labelle_vol);

    // Determine the build command:
    // - WASM: no -Dtarget (build.zig handles it)
    // - --target=<triple>: use the explicit override
    // - Default: cross-compile back to the host OS
    const zig_build_cmd_alloc = if (target_override) |t|
        try std.fmt.allocPrint(allocator, "python3 -m ziglang build -Dtarget={s}", .{t})
    else
        null;
    defer if (zig_build_cmd_alloc) |cmd| allocator.free(cmd);

    const effective_cmd: []const u8 = zig_build_cmd_alloc orelse if (platform == .wasm)
        "python3 -m ziglang build"
    else
        "python3 -m ziglang build -Dtarget=" ++ host_target;

    // Fix #1: Only set up xcode-frameworks when actually targeting macOS,
    // not for all desktop builds (e.g. Linux user building for Linux).
    const is_macos_target = if (target_override) |t|
        std.mem.indexOf(u8, t, "macos") != null
    else
        // No explicit target — default is host_target, so check host OS
        builtin.os.tag == .macos and platform == .desktop;

    const macos_setup: []const u8 = if (is_macos_target)
        setup_xcode_frameworks ++ " && "
    else
        "";

    const script = try std.fmt.allocPrint(allocator,
        "{s} && cd /labelle/{s} && " ++
            fix_fingerprint_script ++ " && " ++
            "{s}" ++
            "{s}",
        .{ install_zig, subdir, effective_cmd, macos_setup, effective_cmd },
    );
    defer allocator.free(script);

    // For non-WASM builds, share the host Zig cache for pre-fetched packages.
    // WASM builds need their own cache since emscripten binaries are platform-specific.
    // Fix #2: Skip cache mount if cache dir can't be resolved, instead of mounting /dev/null.
    if (platform != .wasm) {
        if (zigCacheDir(allocator)) |cache_dir| {
            defer allocator.free(cache_dir);
            const cache_vol = try std.fmt.allocPrint(allocator, "{s}:/root/.cache/zig", .{cache_dir});
            defer allocator.free(cache_vol);

            return spawnAndWait(allocator, &.{ "docker", "run", "--rm", "-v", labelle_vol, "-v", cache_vol, "ubuntu:24.04", "bash", "-c", script });
        } else |_| {}
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
