const std = @import("std");
const builtin = @import("builtin");
const gen = @import("generator");
const config = @import("config.zig");

const ZIG_VERSION = "0.15.2";

const host_arch = switch (builtin.cpu.arch) {
    .aarch64 => "aarch64",
    .x86_64 => "x86_64",
    else => @compileError("unsupported architecture for docker builds"),
};

const host_target = host_arch ++ "-" ++ @tagName(builtin.os.tag);

const install_zig = "apt-get update -qq > /dev/null && " ++
    "apt-get install -y -qq python3-pip > /dev/null && " ++
    "pip3 install ziglang==" ++ ZIG_VERSION ++ " --break-system-packages > /dev/null";

// Shell snippet that locates or fetches xcode-frameworks, then patches build.zig
// to add framework/include/lib search paths for macOS cross-compilation.
const setup_xcode_frameworks =
    "XCODE_PKG=$(find /root/.cache/zig/p/ -maxdepth 2 -name 'AppKit.framework' -path '*/Frameworks/*' 2>/dev/null | head -1 | sed 's|/Frameworks/AppKit.framework||') && " ++
    "if [ -z \"$XCODE_PKG\" ]; then " ++
    "apt-get install -y -qq git > /dev/null && " ++
    "git clone --depth 1 https://github.com/Corendos/xcode-frameworks.git /tmp/xcode-fw > /dev/null 2>&1 && " ++
    "cd /tmp/xcode-fw && git fetch --depth 1 origin 9a45f3ac977fd25dff77e58c6de1870b6808c4a7 > /dev/null 2>&1 && git checkout FETCH_HEAD > /dev/null 2>&1 && cd - > /dev/null && " ++
    "XCODE_PKG=/tmp/xcode-fw; fi && " ++
    "if [ -n \"$XCODE_PKG\" ] && grep -q 'exe.linkLibrary' build.zig; then " ++
    "sed -i \"1s|^|// xcode-frameworks injected by labelle --docker\\n|\" build.zig && " ++
    "sed -i \"/exe.linkLibrary/i\\\\    exe.addFrameworkPath(.{ .cwd_relative = \\\"$XCODE_PKG/Frameworks\\\" });\" build.zig && " ++
    "sed -i \"/exe.linkLibrary/i\\\\    exe.addSystemIncludePath(.{ .cwd_relative = \\\"$XCODE_PKG/include\\\" });\" build.zig && " ++
    "sed -i \"/exe.linkLibrary/i\\\\    exe.addLibraryPath(.{ .cwd_relative = \\\"$XCODE_PKG/lib\\\" });\" build.zig; fi";

fn zigCacheDir(allocator: std.mem.Allocator) ![]const u8 {
    const env = config.globalEnviron();
    if (env.getAlloc(allocator, "ZIG_GLOBAL_CACHE_DIR")) |dir| {
        return dir;
    } else |_| {}

    if (env.getAlloc(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".cache", "zig" });
    } else |_| {}

    return error.NoCacheDir;
}

/// Sanitize a user-supplied target triple to prevent shell injection.
/// Only allows [A-Za-z0-9_.-]; replaces any other byte with '_'.
fn sanitizeTarget(allocator: std.mem.Allocator, target: []const u8) ![]u8 {
    var sanitized = try allocator.alloc(u8, target.len);
    for (target, 0..) |c, i| {
        sanitized[i] = switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '.', '_', '-' => c,
            else => '_',
        };
    }
    return sanitized;
}

/// Run `zig build` inside a Docker container with inherited stdio.
/// For macOS targets, shares the Zig cache and injects xcode-frameworks paths.
/// For WASM, uses its own cache (host cache has macOS-native emscripten binaries).
/// Returns the exit code of the docker process.
pub fn runBuild(allocator: std.mem.Allocator, target_dir: []const u8, platform: gen.Platform, target_override: ?[]const u8, optimize: ?[]const u8) !u8 {
    const abs_target = try std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), target_dir, allocator);
    defer allocator.free(abs_target);

    const parent = std.fs.path.dirname(abs_target) orelse return error.InvalidPath;
    const subdir = std.fs.path.basename(abs_target);

    const labelle_vol = try std.fmt.allocPrint(allocator, "{s}:/labelle", .{parent});
    defer allocator.free(labelle_vol);

    // Build the zig command with optional -Dtarget and -Doptimize flags.
    // Sanitize target_override to prevent shell injection.
    // Ignore --target for WASM builds (build.zig handles the wasm32-emscripten target).
    const sanitized_target = if (platform != .wasm and target_override != null)
        try sanitizeTarget(allocator, target_override.?)
    else
        null;
    defer if (sanitized_target) |s| allocator.free(s);

    const effective_target: []const u8 = if (platform == .wasm)
        ""
    else
        sanitized_target orelse host_target;

    const optimize_part = if (optimize) |opt|
        try std.fmt.allocPrint(allocator, " -Doptimize={s}", .{opt})
    else
        null;
    defer if (optimize_part) |o| allocator.free(o);

    const effective_cmd = if (effective_target.len == 0)
        try std.fmt.allocPrint(allocator, "python3 -m ziglang build{s}", .{optimize_part orelse ""})
    else
        try std.fmt.allocPrint(allocator, "python3 -m ziglang build -Dtarget={s}{s}", .{ effective_target, optimize_part orelse "" });
    defer allocator.free(effective_cmd);

    // Only set up xcode-frameworks when the effective target is macOS.
    const is_macos_target = if (sanitized_target) |t|
        std.mem.indexOf(u8, t, "macos") != null
    else if (platform == .wasm)
        false
    else
        std.mem.indexOf(u8, host_target, "macos") != null;

    const macos_setup: []const u8 = if (is_macos_target)
        setup_xcode_frameworks ++ " && "
    else
        "";

    // Fix fingerprint: run build once to get the error, patch if needed, then build for real.
    // Only re-runs the build if a fingerprint was actually found and patched.
    const script = try std.fmt.allocPrint(allocator,
        "{s} && cd /labelle/{s} && " ++
            "BUILD_OUT=$({s} 2>&1 || true) && " ++
            "FP=$(echo \"$BUILD_OUT\" | grep 'use this value:' | head -1 | sed 's/.*use this value: //') && " ++
            "if [ -n \"$FP\" ]; then sed -i \"s|.fingerprint = .*,|.fingerprint = $FP,|\" build.zig.zon; fi && " ++
            "{s}" ++
            "{s}",
        .{ install_zig, subdir, effective_cmd, macos_setup, effective_cmd },
    );
    defer allocator.free(script);

    // For non-WASM builds, share the host Zig cache for pre-fetched packages.
    // WASM builds need their own cache since emscripten binaries are platform-specific.
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
    _ = allocator;
    const io = config.globalIo();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| {
            std.debug.print("labelle: docker killed by signal {d}\n", .{@intFromEnum(sig)});
            return 1;
        },
        .stopped => |sig| {
            std.debug.print("labelle: docker stopped by signal {d}\n", .{@intFromEnum(sig)});
            return 1;
        },
        .unknown => |val| {
            std.debug.print("labelle: docker unknown termination {d}\n", .{val});
            return 1;
        },
    };
}
