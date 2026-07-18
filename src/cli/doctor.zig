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
const emsdk_toolchain = @import("emsdk_toolchain.zig");
const emsdk_cache = @import("emsdk_cache.zig");
const python_provision = @import("python_provision.zig");

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

// ── `--json` capability report (labelle-studio ToolchainGate contract) ──
// Mirrors the zod schema in labelle-studio/src/services/doctor.ts:
//   { capabilities: [ { id, required, ok, items: [ { id, name, ok, fixable,
//     size_mb, action, detail, hint } ] } ] }
// `?[]const u8` serializes to JSON `null` when absent; `std.json.Stringify`
// emits `[]const u8` fields as strings and produces compact single-line
// output (which is what the studio's line-based extractor looks for).

const JsonItem = struct {
    id: []const u8,
    name: []const u8,
    ok: bool,
    fixable: bool,
    size_mb: u32,
    action: ?[]const u8,
    detail: ?[]const u8,
    hint: ?[]const u8,
};

const JsonCapability = struct {
    id: []const u8,
    required: bool,
    ok: bool,
    items: []const JsonItem,
};

const JsonReport = struct {
    capabilities: []const JsonCapability,
};

/// Serialize the wasm-toolchain capability (zig + python + emsdk/emcc) as the
/// studio's capability JSON on stdout. The python item is FIXABLE when
/// managed provisioning supports this platform: `action` carries the exact
/// command (`labelle install python`) the studio's install flow runs
/// (cli#291); zig/emsdk stay non-fixable status rows (the studio treats
/// `ok || !fixable` as satisfied).
fn emitJsonReport(zig_check: Check, python_check: Check, emsdk_check: Check) !void {
    var out_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(config.globalIo(), &out_buf);
    try writeJsonReport(&w.interface, zig_check, python_check, emsdk_check);
    try w.interface.flush();
}

/// Serialize the capability report to `w` (split out for testing). Emits a
/// single compact JSON line + trailing newline.
fn writeJsonReport(w: *std.Io.Writer, zig_check: Check, python_check: Check, emsdk_check: Check) !void {
    // The python item used to proxy the emsdk check (no independent probe
    // existed); it now carries a REAL interpreter check and, on platforms
    // with managed provisioning, is fixable via `labelle install python`
    // (cli#291). ~25 MB = the python-build-standalone install_only archive.
    const python_fixable = python_provision.managedProvisioningSupported();
    const items = [_]JsonItem{
        .{
            .id = "zig",
            .name = "Zig toolchain",
            .ok = zig_check.ok,
            .fixable = false,
            .size_mb = 0,
            .action = null,
            .detail = zig_check.detail,
            .hint = zig_check.hint,
        },
        .{
            .id = "python",
            .name = "Python (wasm: emsdk + emcc)",
            .ok = python_check.ok,
            .fixable = python_fixable,
            .size_mb = if (python_fixable) 25 else 0,
            .action = if (python_fixable) "labelle install python" else null,
            .detail = python_check.detail,
            .hint = python_check.hint,
        },
        .{
            .id = "emsdk",
            .name = "emsdk toolchain (wasm)",
            .ok = emsdk_check.ok,
            .fixable = false,
            .size_mb = 0,
            .action = null,
            .detail = emsdk_check.detail,
            .hint = emsdk_check.hint,
        },
    };
    const caps = [_]JsonCapability{
        .{
            .id = "wasm",
            .required = true,
            .ok = zig_check.ok and python_check.ok and emsdk_check.ok,
            .items = &items,
        },
    };
    const report = JsonReport{ .capabilities = &caps };
    try std.json.Stringify.value(report, .{}, w);
    try w.writeByte('\n');
}

pub fn cmdDoctor(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var project_dir: []const u8 = ".";
    var do_fix = false;
    var as_json = false;
    for (cmd_args) |arg| {
        if (std.mem.eql(u8, arg, "--fix")) {
            do_fix = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            // Machine-readable capability report for labelle-studio's
            // ToolchainGate (`doctor_check` in src-tauri/src/lib.rs). Emits a
            // single-line `{"capabilities":[…]}` and nothing else.
            as_json = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("labelle doctor: unknown option '{s}'\n  usage: labelle doctor [dir] [--fix] [--json]\n", .{arg});
            return error.InvalidArgument;
        } else {
            project_dir = arg;
        }
    }

    // Best-effort read of project.labelle to scope what's actually required.
    const cfg = readProjectConfig(arena, project_dir);
    const effective_backend = cfg.backend orelse .raylib;

    const needs_sdl_render = effective_backend == .sdl;
    // Which backends pull in SDL2 for the shared desktop gamepad source. This
    // MUST match what the assembler actually wires, or doctor gives an
    // all-clear and `labelle build` then fails at link with "unable to find
    // dynamic system library 'SDL2'" (cli#286). The assembler's source of
    // truth is `labelle-assembler/src/deps_linker.zig:stagesSdlGamepad`, which
    // stages `backends/sdl_gamepad` (→ `-lSDL2`) for `.raylib, .sokol, .bgfx`
    // whenever `gamepad == .auto`. bgfx was missing here, so its default
    // (gamepad-enabled) desktop builds linked SDL2 while doctor reported
    // `gamepad: n/a` and `--fix` refused to provision it. `.sdl` is kept in
    // this set too: the sdl render backend links SDL2 unconditionally (as the
    // renderer, see needs_sdl_render), so surfacing the requirement there is
    // correct regardless of gamepad.
    const needs_sdl_gamepad = switch (effective_backend) {
        .raylib, .sokol, .bgfx, .sdl => !cfg.gamepad_off,
        else => false,
    };
    const needs_sdl = needs_sdl_render or needs_sdl_gamepad;

    const zig_check = checkZig(arena, project_dir);
    const python_check = checkPython(arena);
    const emsdk_check = checkEmsdk(arena, project_dir);

    // `--json`: emit the studio's capability report from the toolchain
    // checks and stop — no human report, no SDL provisioning. The wasm
    // capability is what labelle-studio's ToolchainGate consumes. The python
    // item is fixable via `labelle install python` (cli#291); zig/emsdk stay
    // non-fixable status rows (the gate treats non-fixable as satisfied, so
    // it renders their status without offering an install button).
    if (as_json) {
        try emitJsonReport(zig_check, python_check, emsdk_check);
        return;
    }

    var checks: std.ArrayList(Check) = .empty;

    try checks.append(arena, zig_check);
    try checks.append(arena, python_check);
    try checks.append(arena, emsdk_check);

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

fn checkZig(arena: std.mem.Allocator, project_dir: []const u8) Check {
    // Post-cli#279 the CLI owns Zig: it resolves + downloads + verifies a
    // managed toolchain on demand, so "zig on PATH" is no longer required.
    // Report the managed toolchain the next build would use, without
    // triggering a download. Scoped to `project_dir` so `labelle doctor <dir>`
    // reports the target project's Zig, not the CWD's (cli#279 review).
    if (zig_toolchain.lookupEnvOverride(arena) catch null) |path| {
        return .{ .name = "Zig toolchain", .ok = true, .detail = std.fmt.allocPrint(arena, "LABELLE_ZIG override: {s}", .{path}) catch "LABELLE_ZIG override" };
    }
    const resolved = zig_toolchain.resolveRequiredVersion(arena, project_dir) catch {
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

/// Python for the wasm toolchain: the managed interpreter under
/// `~/.labelle/python`, or the system one the emsdk launcher actually
/// resolves (`python3` on non-Windows; `python`/`python3` on Windows —
/// python_provision.systemPythonOk mirrors activation exactly). Reported
/// independently of the emsdk check since cli#291 (it used to proxy emsdk).
fn checkPython(arena: std.mem.Allocator) Check {
    // `managedPythonOk` RUNS the interpreter (--version), so a half-extracted
    // install reports not-ok instead of faking readiness (PR #291 review).
    if (python_provision.managedPythonOk(arena)) {
        const exe = python_provision.findPythonExe(arena) orelse unreachable;
        return .{ .name = "Python (wasm)", .ok = true, .detail = std.fmt.allocPrint(arena, "managed: {s}", .{exe}) catch "managed" };
    }
    if (python_provision.systemPythonOk(arena)) {
        return .{ .name = "Python (wasm)", .ok = true, .detail = "system python3 on PATH" };
    }
    return .{
        .name = "Python (wasm)",
        .ok = false,
        .hint = if (python_provision.managedProvisioningSupported())
            "run `labelle install python` (managed, ~25 MB) or install Python 3 yourself"
        else
            "install Python 3 and ensure `python3` is on PATH",
    };
}

fn checkEmsdk(arena: std.mem.Allocator, project_dir: []const u8) Check {
    // Post-cli#283 the CLI owns emsdk/emcc for wasm builds: it resolves +
    // fetches + verifies + ACTIVATES a managed emsdk on demand, so "emcc on
    // PATH" is no longer required. Report the managed toolchain the next wasm
    // build would use, without triggering a fetch/activate.
    if (emsdk_toolchain.lookupEnvOverride(arena) catch null) |path| {
        return .{ .name = "emsdk toolchain (wasm)", .ok = true, .detail = std.fmt.allocPrint(arena, "LABELLE_EMSDK override: {s}", .{path}) catch "LABELLE_EMSDK override" };
    }
    const resolved = emsdk_toolchain.resolveRequiredVersion(arena, project_dir) catch {
        return .{ .name = "emsdk toolchain (wasm)", .ok = false, .hint = "could not resolve the required emsdk version" };
    };
    const emcc = emsdk_cache.emccPath(arena, resolved.version) catch {
        return .{ .name = "emsdk toolchain (wasm)", .ok = false, .hint = "could not compute the managed emcc path" };
    };
    const activated = blk: {
        std.Io.Dir.cwd().access(config.globalIo(), emcc, .{}) catch break :blk false;
        break :blk true;
    };
    if (activated) {
        return .{ .name = "emsdk toolchain (wasm)", .ok = true, .detail = std.fmt.allocPrint(arena, "managed emsdk {s} ({s})", .{ resolved.version, resolved.source.label() }) catch "managed emsdk" };
    }
    return .{
        .name = "emsdk toolchain (wasm)",
        .ok = true,
        .detail = std.fmt.allocPrint(arena, "managed emsdk {s} — will fetch + activate on first wasm build", .{resolved.version}) catch "managed emsdk (not yet activated)",
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

// ── Tests ───────────────────────────────────────────────────────────────

/// The `--json` capability report is a cross-repo contract with
/// labelle-studio's ToolchainGate (src/services/doctor.ts zod schema). Pin
/// its shape so a drift breaks CI here, not the studio at runtime.
pub const JsonReportSpec = struct {
    test "doctor --json emits a wasm capability with zig+python+emsdk items" {
        const testing = std.testing;
        var buf: [3072]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        // zig ok, python NOT ok, emsdk ok → capability ok must be the AND (false).
        const zig_check = Check{ .name = "Zig toolchain", .ok = true, .detail = "managed zig 0.16.0" };
        const python_check = Check{ .name = "Python (wasm)", .ok = false, .hint = "run `labelle install python`" };
        const emsdk_check = Check{ .name = "emsdk", .ok = true, .detail = "activated" };
        try writeJsonReport(&w, zig_check, python_check, emsdk_check);
        const line = w.buffered();

        // Exactly one line (the studio extractor is line-based).
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));

        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        const caps = parsed.value.object.get("capabilities").?.array;
        try testing.expectEqual(@as(usize, 1), caps.items.len);

        const wasm = caps.items[0].object;
        try testing.expectEqualStrings("wasm", wasm.get("id").?.string);
        try testing.expectEqual(true, wasm.get("required").?.bool);
        try testing.expectEqual(false, wasm.get("ok").?.bool); // AND of item states

        const items = wasm.get("items").?.array;
        try testing.expectEqual(@as(usize, 3), items.items.len);

        const zig_item = items.items[0].object;
        try testing.expectEqualStrings("zig", zig_item.get("id").?.string);
        try testing.expectEqual(true, zig_item.get("ok").?.bool);
        try testing.expectEqual(false, zig_item.get("fixable").?.bool);
        try testing.expectEqualStrings("managed zig 0.16.0", zig_item.get("detail").?.string);
        try testing.expectEqual(std.json.Value.null, std.meta.activeTag(zig_item.get("hint").?));

        // The python item carries its OWN check now (it used to proxy emsdk)
        // and is fixable on managed-provisioning platforms with the exact
        // install command as its action (cli#291).
        const py_item = items.items[1].object;
        try testing.expectEqualStrings("python", py_item.get("id").?.string);
        try testing.expectEqual(false, py_item.get("ok").?.bool);
        const py_fixable = python_provision.managedProvisioningSupported();
        try testing.expectEqual(py_fixable, py_item.get("fixable").?.bool);
        if (py_fixable) {
            try testing.expectEqualStrings("labelle install python", py_item.get("action").?.string);
            try testing.expectEqual(@as(i64, 25), py_item.get("size_mb").?.integer);
        }
        try testing.expectEqualStrings("run `labelle install python`", py_item.get("hint").?.string);

        const emsdk_item = items.items[2].object;
        try testing.expectEqualStrings("emsdk", emsdk_item.get("id").?.string);
        try testing.expectEqual(true, emsdk_item.get("ok").?.bool);
        try testing.expectEqual(false, emsdk_item.get("fixable").?.bool);
    }
};
