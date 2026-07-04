//! `labelle doctor` — preflight the desktop build/run requirements and report
//! missing system dependencies with actionable fixes.
//!
//! Desktop counterpart of `labelle android doctor`. Almost everything a
//! labelle game needs is fetched + compiled by Zig automatically (raylib,
//! sokol, cimgui, glfw, wgpu-native, the labelle packages). The one genuine
//! manual system dependency is **SDL2** — used by the raylib/sokol backends
//! for the desktop gamepad source, and by the `sdl` backend as the renderer
//! (which additionally needs the headers + SDL2_mixer). When it is missing the
//! build otherwise fails deep in a Zig linker dump ("unable to find dynamic
//! system library 'SDL2'"); this command surfaces it up front instead.
//!
//! `--fix` auto-provisions SDL2 into `~/.labelle/sdl2/` on Windows (see
//! `sdl_provision.zig`); `build`/`run` then auto-wire the cached install
//! into the child environment so it works without manual env setup.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const project_config = @import("project_config.zig");
const sdl_provision = @import("sdl_provision.zig");
const zig_toolchain = @import("zig_toolchain.zig");
const zig_cache = @import("zig_cache.zig");

const Check = struct {
    name: []const u8,
    ok: bool,
    /// Shown indented under an OK line (e.g. the resolved path or version).
    detail: ?[]const u8 = null,
    /// Shown under a FAIL/WARN line — the actionable fix.
    hint: ?[]const u8 = null,
    /// Required misses are FAIL (non-zero exit); optional misses are WARN.
    required: bool = true,
};

pub fn cmdDoctor(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var project_dir: []const u8 = ".";
    var do_fix = false;
    for (cmd_args) |arg| {
        if (std.mem.eql(u8, arg, "--fix")) {
            do_fix = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("labelle doctor: unknown option '{s}'\n  usage: labelle doctor [dir] [--fix]\n", .{arg});
            return error.InvalidArgument;
        } else {
            project_dir = arg;
        }
    }

    // Best-effort read of project.labelle to scope what's actually required.
    const cfg = readProjectConfig(arena, project_dir);
    const effective_backend = cfg.backend orelse .raylib;

    const needs_sdl_render = effective_backend == .sdl;
    const needs_sdl_gamepad = switch (effective_backend) {
        .raylib, .sokol, .sdl => !cfg.gamepad_off,
        else => false,
    };
    const needs_sdl = needs_sdl_render or needs_sdl_gamepad;

    var checks: std.ArrayList(Check) = .empty;

    try checks.append(arena, checkZig(arena));

    if (needs_sdl) {
        var lib = checkSdl2Lib(arena);
        if (!lib.ok and do_fix) {
            std.debug.print("\nlabelle doctor: provisioning SDL2...\n", .{});
            _ = sdl_provision.provisionSdl2(allocator);
            lib = checkSdl2Lib(arena); // re-detect — the cache scan now finds it
        }
        try checks.append(arena, lib);
        if (builtin.os.tag == .windows) try checks.append(arena, checkSdl2Dll(arena));
        if (needs_sdl_render) {
            try checks.append(arena, checkSdl2Headers(arena));
            try checks.append(arena, checkSdl2Mixer(arena));
        }
    } else if (do_fix) {
        std.debug.print("labelle doctor: nothing to fix — this backend needs no system libraries.\n", .{});
    }

    // ── Report ──────────────────────────────────────────────────────────
    const backend_label = if (cfg.backend) |b| @tagName(b) else "unknown (no project.labelle)";
    const gamepad_label = if (needs_sdl_gamepad) "on" else if (needs_sdl) "off" else "n/a";
    std.debug.print(
        \\
        \\labelle doctor
        \\==============
        \\  project: {s}
        \\  backend: {s}   gamepad: {s}
        \\
        \\
    , .{ project_dir, backend_label, gamepad_label });

    if (!needs_sdl) {
        std.debug.print("  This backend needs no manual system libraries — everything is fetched + built by Zig.\n", .{});
    }

    var failures: u32 = 0;
    var warnings: u32 = 0;
    for (checks.items) |c| {
        if (c.ok) {
            std.debug.print("  [  OK  ] {s}\n", .{c.name});
            if (c.detail) |d| std.debug.print("           {s}\n", .{d});
        } else if (c.required) {
            failures += 1;
            std.debug.print("  [ FAIL ] {s}\n", .{c.name});
            if (c.hint) |h| std.debug.print("           -> {s}\n", .{h});
        } else {
            warnings += 1;
            std.debug.print("  [ WARN ] {s}\n", .{c.name});
            if (c.hint) |h| std.debug.print("           -> {s}\n", .{h});
        }
    }

    std.debug.print("\n", .{});
    if (failures == 0) {
        std.debug.print("  All required desktop build dependencies are present.\n\n", .{});
    } else {
        std.debug.print("  {d} required dependency(ies) missing — see FAIL lines above.\n\n", .{failures});
        // Clean non-zero exit (scriptable) without a Zig error-return trace —
        // this is a user-facing diagnostic, not an internal failure.
        std.process.exit(1);
    }
}

// ── Project config (textual, dependency-free) ───────────────────────────

const Cfg = struct {
    backend: ?project_config.Backend = null,
    gamepad_off: bool = false,
};

/// Read backend + gamepad opt-out straight out of `project.labelle` text. A
/// full ZON parse isn't worth a dependency here; the two fields we need are
/// simple `.field = .value` forms.
fn readProjectConfig(arena: std.mem.Allocator, project_dir: []const u8) Cfg {
    const io = config.globalIo();
    const path = std.fs.path.join(arena, &.{ project_dir, "project.labelle" }) catch return .{};
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return .{};

    var cfg: Cfg = .{};
    if (std.mem.indexOf(u8, content, ".backend = .")) |idx| {
        const start = idx + ".backend = .".len;
        var end = start;
        while (end < content.len and (std.ascii.isAlphanumeric(content[end]) or content[end] == '_')) end += 1;
        cfg.backend = std.meta.stringToEnum(project_config.Backend, content[start..end]);
    }
    cfg.gamepad_off = std.mem.indexOf(u8, content, ".gamepad = .none") != null or
        std.mem.indexOf(u8, content, ".gamepad=.none") != null;
    return cfg;
}

// ── Individual checks ───────────────────────────────────────────────────

fn checkZig(arena: std.mem.Allocator) Check {
    // Post-cli#279 the CLI owns Zig: it resolves + downloads + verifies a
    // managed toolchain on demand, so "zig on PATH" is no longer required.
    // Report the managed toolchain the next build would use, without
    // triggering a download.
    if (zig_toolchain.lookupEnvOverride(arena) catch null) |path| {
        return .{ .name = "Zig toolchain", .ok = true, .detail = std.fmt.allocPrint(arena, "LABELLE_ZIG override: {s}", .{path}) catch "LABELLE_ZIG override" };
    }
    const resolved = zig_toolchain.resolveRequiredVersion(arena, ".") catch {
        return .{ .name = "Zig toolchain", .ok = false, .hint = "could not resolve the required Zig version" };
    };
    const bin = zig_cache.binaryPath(arena, resolved.version) catch {
        return .{ .name = "Zig toolchain", .ok = false, .hint = "could not compute the managed Zig path" };
    };
    const installed = blk: {
        std.Io.Dir.cwd().access(config.globalIo(), bin, .{}) catch break :blk false;
        break :blk true;
    };
    if (installed) {
        return .{ .name = "Zig toolchain", .ok = true, .detail = std.fmt.allocPrint(arena, "managed zig {s} ({s})", .{ resolved.version, resolved.source.label() }) catch "managed zig" };
    }
    return .{
        .name = "Zig toolchain",
        .ok = true,
        .detail = std.fmt.allocPrint(arena, "managed zig {s} — will download + verify on first build", .{resolved.version}) catch "managed zig (not yet installed)",
    };
}

fn checkSdl2Lib(arena: std.mem.Allocator) Check {
    const name = "SDL2 library (gamepad + sdl backend)";
    switch (builtin.os.tag) {
        .windows => {
            if (envOwned(arena, "LABELLE_SDL2_LIB")) |dir| {
                const probe = std.fs.path.join(arena, &.{ dir, "libSDL2.dll.a" }) catch dir;
                if (fileExists(probe)) return ok(name, dir);
            }
            if (findCachedSdl2Lib(arena)) |dir| return ok(name, dir);
            return .{ .name = name, .ok = false, .hint = "SDL2 (MinGW dev libs) not found. Download SDL2-devel-<ver>-mingw, then set LABELLE_SDL2_LIB to its x86_64-w64-mingw32\\lib dir (and put SDL2.dll on PATH). Or set `.gamepad = .none` in project.labelle if you don't need gamepad input. (`labelle doctor --fix` will automate this soon.)" };
        },
        .linux => {
            if (runOk(arena, &.{ "pkg-config", "--exists", "sdl2" })) return ok(name, "pkg-config: sdl2");
            for ([_][]const u8{ "/usr/lib/x86_64-linux-gnu/libSDL2.so", "/usr/lib/libSDL2.so", "/usr/lib64/libSDL2.so", "/usr/local/lib/libSDL2.so" }) |p| {
                if (fileExists(p)) return ok(name, p);
            }
            return .{ .name = name, .ok = false, .hint = "SDL2 not found. Install it: `sudo apt install libsdl2-dev` (Debian/Ubuntu) or `sudo dnf install SDL2-devel` (Fedora). Or set `.gamepad = .none`." };
        },
        .macos => {
            for ([_][]const u8{ "/opt/homebrew/lib/libSDL2.dylib", "/usr/local/lib/libSDL2.dylib" }) |p| {
                if (fileExists(p)) return ok(name, p);
            }
            return .{ .name = name, .ok = false, .hint = "SDL2 not found. Install it: `brew install sdl2`. Or set `.gamepad = .none`." };
        },
        else => return .{ .name = name, .ok = false, .hint = "Unsupported desktop OS for SDL2 detection." },
    }
}

fn checkSdl2Dll(arena: std.mem.Allocator) Check {
    const name = "SDL2.dll for runtime";
    if (onPath(arena, "SDL2.dll")) |p| return ok(name, p);
    // The provisioner places SDL2.dll in the cache lib dir; accept that so a
    // freshly `--fix`ed setup reports green. (Auto-wiring PATH for `run` is a
    // later phase; until then add this dir to PATH for standalone runs.)
    if (findCachedSdl2Lib(arena)) |libdir| {
        const dll = std.fs.path.join(arena, &.{ libdir, "SDL2.dll" }) catch libdir;
        if (fileExists(dll)) {
            return .{ .name = name, .ok = true, .detail = std.fmt.allocPrint(arena, "{s} (labelle SDL2 cache — add this dir to PATH for runtime)", .{libdir}) catch dll };
        }
    }
    return .{ .name = name, .ok = false, .required = false, .hint = "SDL2.dll is needed at runtime. Add the SDL2 `bin` dir to PATH, or run `labelle doctor --fix`." };
}

fn checkSdl2Headers(arena: std.mem.Allocator) Check {
    const name = "SDL2 headers (sdl backend)";
    switch (builtin.os.tag) {
        .windows => {
            if (envOwned(arena, "LABELLE_SDL2_LIB")) |dir| {
                const inc = std.fs.path.join(arena, &.{ dir, "..", "include", "SDL2", "SDL.h" }) catch dir;
                if (fileExists(inc)) return ok(name, inc);
            }
            // The --fix-provisioned MinGW package ships headers beside the
            // lib — accept the cache here the same way checkSdl2Lib does,
            // so a fixed setup passes the headers check too.
            if (findCachedSdl2Lib(arena)) |libdir| {
                const inc = std.fs.path.join(arena, &.{ libdir, "..", "include", "SDL2", "SDL.h" }) catch libdir;
                if (fileExists(inc)) return ok(name, inc);
            }
            return fail(name, "SDL2 headers not found. The `sdl` render backend needs the SDL2 dev headers (SDL2/SDL.h) from the MinGW dev package.");
        },
        .linux => {
            if (runOk(arena, &.{ "pkg-config", "--cflags", "sdl2" })) return ok(name, "pkg-config: sdl2 cflags");
            if (fileExists("/usr/include/SDL2/SDL.h")) return ok(name, "/usr/include/SDL2/SDL.h");
            return fail(name, "SDL2 headers not found. `sudo apt install libsdl2-dev` / `sudo dnf install SDL2-devel`.");
        },
        .macos => {
            for ([_][]const u8{ "/opt/homebrew/include/SDL2/SDL.h", "/usr/local/include/SDL2/SDL.h" }) |p| {
                if (fileExists(p)) return ok(name, p);
            }
            return fail(name, "SDL2 headers not found. `brew install sdl2`.");
        },
        else => return fail(name, "Unsupported OS."),
    }
}

fn checkSdl2Mixer(arena: std.mem.Allocator) Check {
    const name = "SDL2_mixer (sdl backend audio)";
    switch (builtin.os.tag) {
        .windows => {
            if (envOwned(arena, "LABELLE_SDL2_LIB")) |dir| {
                const probe = std.fs.path.join(arena, &.{ dir, "libSDL2_mixer.dll.a" }) catch dir;
                if (fileExists(probe)) return ok(name, probe);
            }
            return fail(name, "SDL2_mixer not found. The `sdl` backend's audio needs SDL2_mixer-devel (MinGW). Download SDL2_mixer-devel-<ver>-mingw alongside SDL2.");
        },
        .linux => {
            if (runOk(arena, &.{ "pkg-config", "--exists", "SDL2_mixer" })) return ok(name, "pkg-config: SDL2_mixer");
            return fail(name, "SDL2_mixer not found. `sudo apt install libsdl2-mixer-dev` / `sudo dnf install SDL2_mixer-devel`.");
        },
        .macos => {
            for ([_][]const u8{ "/opt/homebrew/lib/libSDL2_mixer.dylib", "/usr/local/lib/libSDL2_mixer.dylib" }) |p| {
                if (fileExists(p)) return ok(name, p);
            }
            return fail(name, "SDL2_mixer not found. `brew install sdl2_mixer`.");
        },
        else => return fail(name, "Unsupported OS."),
    }
}

// ── Helpers ─────────────────────────────────────────────────────────────

fn ok(name: []const u8, detail: []const u8) Check {
    return .{ .name = name, .ok = true, .detail = detail };
}

fn fail(name: []const u8, hint: []const u8) Check {
    return .{ .name = name, .ok = false, .hint = hint };
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(config.globalIo(), path, .{}) catch return false;
    return true;
}

fn envOwned(arena: std.mem.Allocator, key: []const u8) ?[]u8 {
    if (config.globalEnviron().getAlloc(arena, key)) |v| return v else |_| return null;
}

/// Run a command and report whether it exited 0. Used for `pkg-config` probes.
fn runOk(arena: std.mem.Allocator, argv: []const []const u8) bool {
    const res = std.process.run(arena, config.globalIo(), .{ .argv = argv }) catch return false;
    return switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

/// First PATH entry containing `filename`, or null.
fn onPath(arena: std.mem.Allocator, filename: []const u8) ?[]const u8 {
    const path = envOwned(arena, "PATH") orelse return null;
    var it = std.mem.tokenizeScalar(u8, path, std.fs.path.delimiter);
    while (it.next()) |dir| {
        const full = std.fs.path.join(arena, &.{ dir, filename }) catch continue;
        if (fileExists(full)) return full;
    }
    return null;
}

/// Cached SDL2 lib dir, any version. Delegates to the provisioner's scan
/// so detection here and the build/run env wiring share one acceptance
/// rule — doctor must never report a cache green that autoWireEnv then
/// ignores.
fn findCachedSdl2Lib(arena: std.mem.Allocator) ?[]const u8 {
    return sdl_provision.findCachedLibDir(arena);
}
