const std = @import("std");
const builtin = @import("builtin");
const project_config = @import("project_config.zig");
const config = @import("config.zig");
const emsdk_toolchain = @import("emsdk_toolchain.zig");

const ZIG_VERSION = "0.16.0";

/// emsdk version the in-container wasm build activates. Kept in lockstep with
/// the host manager's default (labelle-cli#283) and the assembler's pin.
const EMSDK_VERSION = emsdk_toolchain.DEFAULT_EMSDK_VERSION;

// In-container emsdk activation for the wasm build (labelle-cli#283 / fixes
// labelle-assembler#492). The generated wasm `build.zig` links via the emsdk
// zig-dependency package's `emcc`, but that package is fetched-but-NOT-activated
// — `upstream/emscripten/emcc` is FileNotFound until `emsdk install/activate`
// runs. The first `zig build` (the fingerprint pass below) fetches + unpacks the
// emsdk package into the project-local `zig-pkg/<hash>/` dir (NOT the global Zig
// cache); this snippet then locates it, makes it writable (Zig marks package
// dirs read-only), and runs the emsdk install + **activate** flow in place so
// the second `zig build` finds `emcc`. `zig-pkg` is searched relative to the
// build dir (we run after `cd /labelle/<subdir>`), with the global Zig package
// cache as a fallback for non-vendored layouts. Exports EMSDK/EM_CONFIG so emcc
// resolves its toolchain config.
const activate_emsdk =
    "EMSDK_PKG=$(find zig-pkg /root/.cache/zig/p -maxdepth 2 -type f -name emsdk.py 2>/dev/null | head -1 | xargs -r dirname) && " ++
    "if [ -n \"$EMSDK_PKG\" ]; then " ++
    "chmod -R u+w \"$EMSDK_PKG\" 2>/dev/null || true; " ++
    "(cd \"$EMSDK_PKG\" && chmod +x ./emsdk 2>/dev/null; ./emsdk install " ++ EMSDK_VERSION ++ " && ./emsdk activate " ++ EMSDK_VERSION ++ ") && " ++
    "export EMSDK=\"$(cd \"$EMSDK_PKG\" && pwd)\" && export EM_CONFIG=\"$EMSDK/.emscripten\"; " ++
    "else echo 'labelle: could not locate the fetched emsdk package to activate' >&2; fi && ";

const host_arch = switch (builtin.cpu.arch) {
    .aarch64 => "aarch64",
    .x86_64 => "x86_64",
    else => @compileError("unsupported architecture for docker builds"),
};

const host_target = host_arch ++ "-" ++ @tagName(builtin.os.tag);

// Download Zig from ziglang.org directly, then cherry-pick PR #31850's
// one-line STOPSIG fix into the stdlib. Background: 0.16.0 ships with
// two WASM/emscripten compile bugs —
//   1. `std/os/emscripten.zig:STOPSIG` returns `u32` while the body
//      `@enumFromInt`s into `SIG` (Zig issue #31849, fixed in master by
//      PR #31850). The sed below applies the same one-line change.
//   2. translate-c rejects recent emsdk headers' multi-arg
//      `__attribute__((deprecated("msg1","msg2")))` form (translate-c
//      issue #306). Avoided by hand-rolled extern shims in the
//      assembler's WASM template — no stdlib change needed.
const install_zig = "apt-get update -qq > /dev/null && " ++
    "apt-get install -y -qq curl xz-utils ca-certificates python3 > /dev/null && " ++
    "curl -fsSL https://ziglang.org/download/" ++ ZIG_VERSION ++ "/zig-x86_64-linux-" ++ ZIG_VERSION ++ ".tar.xz | tar -xJ -C /opt > /dev/null && " ++
    "ln -sf /opt/zig-x86_64-linux-" ++ ZIG_VERSION ++ "/zig /usr/local/bin/zig && " ++
    "sed -i 's/pub fn STOPSIG(s: u32) u32 {/pub fn STOPSIG(s: u32) SIG {/' /opt/zig-x86_64-linux-" ++ ZIG_VERSION ++ "/lib/std/os/emscripten.zig";

// Shell snippet that locates or fetches xcode-frameworks, then patches build.zig
// to add framework/include/lib search paths for macOS cross-compilation.
const setup_xcode_frameworks =
    "XCODE_PKG=$(find /root/.cache/zig/p/ -maxdepth 2 -name 'AppKit.framework' -path '*/Frameworks/*' 2>/dev/null | head -1 | sed 's|/Frameworks/AppKit.framework||') && " ++
    "if [ -z \"$XCODE_PKG\" ]; then " ++
    "apt-get install -y -qq git > /dev/null && " ++
    "git clone --depth 1 https://github.com/Corendos/xcode-frameworks.git /tmp/xcode-fw > /dev/null 2>&1 && " ++
    "cd /tmp/xcode-fw && git fetch --depth 1 origin 9a45f3ac977fd25dff77e58c6de1870b6808c4a7 > /dev/null 2>&1 && git checkout FETCH_HEAD > /dev/null 2>&1 && cd - > /dev/null && " ++
    "XCODE_PKG=/tmp/xcode-fw; fi && " ++
    "if [ -n \"$XCODE_PKG\" ] && grep -q 'exe.root_module.linkLibrary' build.zig; then " ++
    "sed -i \"1s|^|// xcode-frameworks injected by labelle --docker\\n|\" build.zig && " ++
    "sed -i \"/exe.root_module.linkLibrary/i\\\\    exe.root_module.addFrameworkPath(.{ .cwd_relative = \\\"$XCODE_PKG/Frameworks\\\" });\" build.zig && " ++
    "sed -i \"/exe.root_module.linkLibrary/i\\\\    exe.root_module.addSystemIncludePath(.{ .cwd_relative = \\\"$XCODE_PKG/include\\\" });\" build.zig && " ++
    "sed -i \"/exe.root_module.linkLibrary/i\\\\    exe.root_module.addLibraryPath(.{ .cwd_relative = \\\"$XCODE_PKG/lib\\\" });\" build.zig; fi";

/// Recursively copy a directory tree. `src` and `dst` are absolute paths.
///
/// Nested symlinks (links *inside* the copied tree) are reproduced as
/// symlinks rather than dereferenced. This is deliberate: the assembler
/// only ever links the game's top-level `@embedFile`-able dirs (see
/// `materializeSymlinks`), and `@embedFile` does not need links *within*
/// those dirs followed. Crucially, copying nested symlinks as-is means a
/// circular symlink (e.g. an `assets/` entry pointing at an ancestor dir)
/// can never make `copyTree` recurse forever — recursion only descends
/// into real directories, which form a finite tree.
fn copyTree(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(io, dst);

    var src_dir = try cwd.openDir(io, src, .{ .iterate = true });
    defer src_dir.close(io);

    var iter = src_dir.iterate();
    while (try iter.next(io)) |entry| {
        const src_sub = try std.fs.path.join(allocator, &.{ src, entry.name });
        defer allocator.free(src_sub);
        const dst_sub = try std.fs.path.join(allocator, &.{ dst, entry.name });
        defer allocator.free(dst_sub);

        switch (entry.kind) {
            .directory => try copyTree(allocator, src_sub, dst_sub),
            .file => try cwd.copyFile(src_sub, cwd, dst_sub, io, .{}),
            // Reproduce nested symlinks as symlinks — do NOT dereference
            // them. This avoids unbounded recursion on circular links and
            // is sufficient for `@embedFile`, which only needs the
            // top-level dir links resolved (handled by materializeSymlinks).
            .sym_link => {
                var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const target_len = cwd.readLink(io, src_sub, &link_buf) catch |err| {
                    std.debug.print("labelle: warning: skipping unreadable symlink '{s}' for docker build: {any}\n", .{ src_sub, err });
                    continue;
                };
                cwd.symLink(io, link_buf[0..target_len], dst_sub, .{}) catch |err| {
                    std.debug.print("labelle: warning: could not recreate symlink '{s}' for docker build: {any}\n", .{ dst_sub, err });
                };
            },
            else => {},
        }
    }
}

/// Replace every immediate-child symlink of `target_dir` with a real
/// recursive copy of its resolved content.
///
/// The assembler links the game's `@embedFile`-able directories
/// (`scenes/`, `prefabs/`, `assets/`, `components/`, …) into the target
/// dir as relative symlinks pointing at `../../<folder>` in the project
/// root. The native build resolves those links fine. The Docker build
/// only volume-mounts `.labelle/` (the target dir's parent), so a link
/// like `.labelle/<target>/scenes -> ../../scenes` dangles inside the
/// container — `@embedFile("scenes/main.jsonc")` then fails with
/// FileNotFound at compile time.
///
/// Materializing the links into real directories on the host, before
/// the mount, makes the embedded sources resolve in-container. This is
/// Docker-path-only; the native build path is left untouched. Folder
/// set isn't hard-coded — whatever the assembler linked gets copied —
/// so it can't drift from the assembler's behavior.
///
/// No staleness on iterative builds: this only acts on entries that are
/// *currently symlinks*, but every `labelle build --docker` invocation
/// runs the assembler's `generate` step first (cli.zig calls
/// `assembler_proc.generate` unconditionally before `docker.runBuild`).
/// The assembler's `linkDir` is idempotent and explicitly recreates each
/// game-dir symlink even when the path is already a real directory left
/// over from a prior `materializeSymlinks` run — it detects the
/// `error.NotLink` case, `deleteTree`s the stale copy, and writes a fresh
/// symlink (see labelle-assembler/src/scanner.zig:linkDir). So the
/// materialized copies are transient: they exist only between one
/// `generate` and that build's `docker run`, and are blown away by the
/// next `generate`. A second `--docker` build therefore always sees fresh
/// symlinks here, never a stale real dir.
fn materializeSymlinks(allocator: std.mem.Allocator, target_dir: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    var dir = cwd.openDir(io, target_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    // Collect symlink names first; mutating the tree mid-iteration is
    // unsafe.
    var links: std.ArrayList([]const u8) = .empty;
    defer {
        for (links.items) |n| allocator.free(n);
        links.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .sym_link) continue;
        try links.append(allocator, try allocator.dupe(u8, entry.name));
    }

    for (links.items) |name| {
        const link_path = try std.fs.path.join(allocator, &.{ target_dir, name });
        defer allocator.free(link_path);

        // Resolve the link to its real on-host location while the link
        // still exists.
        const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, link_path, allocator) catch |err| {
            std.debug.print("labelle: warning: could not resolve '{s}' for docker build: {any}\n", .{ link_path, err });
            continue;
        };
        defer allocator.free(resolved);

        const stat = try cwd.statFile(io, link_path, .{});

        // Replace the link with a real copy of its target.
        try cwd.deleteTree(io, link_path);
        if (stat.kind == .directory) {
            try copyTree(allocator, resolved, link_path);
        } else {
            try cwd.copyFile(resolved, cwd, link_path, io, .{});
        }
    }
}

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
pub fn runBuild(allocator: std.mem.Allocator, target_dir: []const u8, platform: project_config.Platform, target_override: ?[]const u8, optimize: ?[]const u8) !u8 {
    const abs_target = try std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), target_dir, allocator);
    defer allocator.free(abs_target);

    // The assembler links the game's @embedFile-able dirs (scenes/,
    // prefabs/, assets/, …) into the target dir as relative symlinks
    // pointing outside .labelle/. The docker volume only mounts
    // .labelle/, so those links dangle in-container and @embedFile
    // fails at compile time. Dereference them into real copies on the
    // host before the mount. Native builds never call this.
    try materializeSymlinks(allocator, abs_target);

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
        try std.fmt.allocPrint(allocator, "zig build{s}", .{optimize_part orelse ""})
    else
        try std.fmt.allocPrint(allocator, "zig build -Dtarget={s}{s}", .{ effective_target, optimize_part orelse "" });
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

    // WASM: after the fingerprint pass has fetched the emsdk package, activate
    // it in place so `emcc` exists for the real build (fixes #492). No-op for
    // every other platform.
    const emsdk_setup: []const u8 = if (platform == .wasm)
        activate_emsdk
    else
        "";

    // Fix fingerprint: run build once to get the error, patch if needed, then build for real.
    // Only re-runs the build if a fingerprint was actually found and patched.
    // For wasm, the fingerprint pass also warms the Zig package cache so the
    // emsdk activation snippet can find + activate the fetched emsdk package.
    const script = try std.fmt.allocPrint(allocator,
        "{s} && cd /labelle/{s} && " ++
            "BUILD_OUT=$({s} 2>&1 || true) && " ++
            "FP=$(echo \"$BUILD_OUT\" | grep 'use this value:' | head -1 | sed 's/.*use this value: //') && " ++
            "if [ -n \"$FP\" ]; then sed -i \"s|.fingerprint = .*,|.fingerprint = $FP,|\" build.zig.zon; fi && " ++
            "{s}" ++
            "{s}" ++
            "{s}",
        .{ install_zig, subdir, effective_cmd, emsdk_setup, macos_setup, effective_cmd },
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
