//! `labelle doctor` — preflight the desktop build/run requirements and report
//! missing system dependencies with actionable fixes.
//!
//! The core target's checks come first. Inside a project, `labelle doctor`
//! then runs the doctor of every pinned provider whose manifest declares one
//! (the same run as `labelle <namespace> doctor`; see `provider_doctor.zig`),
//! and exits non-zero if the core or any provider fails. `--core-only` skips
//! the provider part. Almost everything a
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
const assembler_proc = @import("assembler_proc.zig");
const assembler_describe = @import("assembler_describe.zig");
const provider_targets = @import("provider_targets.zig");
const sdl_provision = @import("sdl_provision.zig");
const zig_toolchain = @import("zig_toolchain.zig");
const zig_cache = @import("zig_cache.zig");
const python_provision = @import("python_provision.zig");
const provider_doctor = @import("provider_doctor.zig");
const provider_dispatch = @import("provider_dispatch.zig");
const provider_doctor_json = @import("provider_doctor_json.zig");

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
//
// Inside a project the pinned providers' doctors contribute capabilities of
// their own (RFC cli#466 D7, `provider_doctor_json.zig`): the core runs them
// with `--json`, captures their stdout and prints ONE document. A provider
// capability replaces a core one with the same id. The core reports only
// what it owns: the managed Zig (`zig`) and the managed Python (`python`,
// optional: `.prebuild` steps and provider tools use it). A target's
// toolchain capability is its provider's to report.

const JsonItem = provider_doctor_json.Item;
const JsonCapability = provider_doctor_json.Capability;

/// Serialize the core's capabilities (`zig`, `python`), with the providers'
/// (when `providers` is set), as the studio's capability JSON on stdout. The
/// python item is FIXABLE when managed provisioning supports this platform:
/// `action` carries the exact command (`labelle install python`) the
/// studio's install flow runs (cli#291); zig stays a non-fixable status row
/// (the studio treats `ok || !fixable` as satisfied).
fn emitJsonReport(a: std.mem.Allocator, zig_check: Check, python_check: Check, providers: ?provider_doctor.Report) !void {
    var out_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(config.globalIo(), &out_buf);
    try writeJsonReport(&w.interface, a, zig_check, python_check, providers);
    try w.interface.flush();
}

/// Serialize the capability report to `w` (split out for testing). Emits a
/// single compact JSON line + trailing newline.
fn writeJsonReport(w: *std.Io.Writer, a: std.mem.Allocator, zig_check: Check, python_check: Check, providers: ?provider_doctor.Report) !void {
    // ~25 MB = the python-build-standalone install_only archive.
    const python_fixable = python_provision.managedProvisioningSupported();
    const zig_items = [_]JsonItem{.{
        .id = "zig",
        .name = "Zig toolchain",
        .ok = zig_check.ok,
        .fixable = false,
        .size_mb = 0,
        .action = null,
        .detail = zig_check.detail,
        .hint = zig_check.hint,
    }};
    const python_items = [_]JsonItem{.{
        .id = "python",
        .name = python_check_name,
        .ok = python_check.ok,
        .fixable = python_fixable,
        .size_mb = if (python_fixable) 25 else 0,
        .action = if (python_fixable) "labelle install python" else null,
        .detail = python_check.detail,
        .hint = python_check.hint,
    }};
    const caps = [_]JsonCapability{
        .{ .id = "zig", .required = true, .ok = zig_check.ok, .items = &zig_items },
        // Optional: only `.prebuild` steps and provider tools that spawn
        // Python need it, and a provider that does reports its own need.
        .{ .id = "python", .required = false, .ok = python_check.ok, .items = &python_items },
    };
    const merged = try provider_doctor_json.aggregate(a, &caps, providers);
    // The stderr summary is derived from the merged document, so the two
    // cannot disagree (RFC cli#466 D7).
    var err_buf: [1024]u8 = undefined;
    var err_w = std.Io.File.stderr().writerStreaming(config.globalIo(), &err_buf);
    try provider_doctor_json.printSummary(&err_w.interface, merged);
    try err_w.interface.flush();
    try provider_doctor_json.write(w, merged.capabilities);
}

pub fn cmdDoctor(allocator: std.mem.Allocator, cmd_args: []const []const u8) !void {
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var project_dir: []const u8 = ".";
    var do_fix = false;
    var as_json = false;
    var core_only = false;
    var i: usize = 0;
    while (i < cmd_args.len) : (i += 1) {
        const arg = cmd_args[i];
        if (try zigFlag(cmd_args, &i)) |path| {
            // `--zig <path>` / `--zig=<path>`, as `labelle build` takes it:
            // the compiler the core check reports and the provider doctors'
            // tools build with. `LABELLE_ZIG` still wins. The slice borrows
            // argv, which lives for the whole process.
            zig_toolchain.setFlagOverride(path);
        } else if (std.mem.eql(u8, arg, "--fix")) {
            do_fix = true;
        } else if (std.mem.eql(u8, arg, "--core-only")) {
            // Skip the pinned providers' doctors (see provider_doctor.zig).
            core_only = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            // Machine-readable capability report for labelle-studio's
            // ToolchainGate (`doctor_check` in src-tauri/src/lib.rs). Emits a
            // single-line `{"capabilities":[…]}` and nothing else.
            as_json = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("labelle doctor: unknown option '{s}'\n  usage: labelle doctor [dir] [--fix] [--json] [--core-only] [--zig <path>]\n", .{arg});
            return error.InvalidArgument;
        } else {
            project_dir = arg;
        }
    }

    // One project root for both halves: the core checks (config, backend,
    // the Zig version) and the provider doctors read the same project.
    const scope = resolveScope(arena, project_dir);

    // Best-effort read of project.labelle to scope what's actually required.
    const cfg = readProjectConfig(arena, scope.dir);

    const zig_check = checkZig(arena, scope.dir);
    const python_check = checkPython(arena);

    // `--json`: emit the studio's capability report from the toolchain
    // checks and the provider doctors, and stop — no human report, no SDL
    // provisioning. The python
    // item is fixable via `labelle install python` (cli#291); zig stays a
    // non-fixable status row (the gate treats non-fixable as satisfied, so
    // it renders their status without offering an install button).
    //
    // Inside a project, and unless `--core-only`, every provider doctor runs
    // with `--json` and its captured capability joins the document (RFC
    // cli#466 D7). Their human report lines go to stderr; stdout carries the
    // one document and nothing else. The exit status stays 0: the verdict
    // is in the document.
    if (as_json) {
        const providers: ?provider_doctor.Report = if (core_only) null else if (scope.root) |root|
            try provider_doctor.runForRoot(arena, root, true)
        else
            null;
        try emitJsonReport(arena, zig_check, python_check, providers);
        return;
    }

    // Which backend the project builds with, as the assembler resolves it
    // (`describe`, cli#471 D4: the CLI reads no `.backend` of its own), and
    // so which parts of SDL2 it pulls in (`sdl_provision.Needs`, the one
    // place the backend names are spelled). Only inside a project: outside
    // one, or when `describe` cannot answer, the assembler's default backend
    // is assumed, which links SDL2 for the desktop gamepad source.
    const backend: ?[]const u8 = if (cfg.found) describeBackend(arena, scope.dir) else null;
    const needs: sdl_provision.Needs = if (backend) |name|
        .of(name, cfg.gamepad_off)
    else
        .{ .gamepad = !cfg.gamepad_off };
    const needs_sdl_render = needs.render;
    const needs_sdl_gamepad = needs.gamepad;
    const needs_sdl = needs.any();

    var checks: std.ArrayList(Check) = .empty;

    try checks.append(arena, zig_check);
    try checks.append(arena, python_check);

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
    const backend_label = if (backend) |name|
        name
    else if (cfg.found)
        "unknown (`labelle-assembler describe` gave no answer)"
    else
        "unknown (no project.labelle)";
    const gamepad_label = if (needs_sdl_gamepad) "on" else if (needs_sdl) "off" else "n/a";
    std.debug.print(
        \\
        \\labelle doctor
        \\==============
        \\  project: {s}
        \\  backend: {s}   gamepad: {s}
        \\
        \\
    , .{ scope.dir, backend_label, gamepad_label });

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
        std.debug.print("  All required desktop build dependencies are present.\n", .{});
    } else {
        std.debug.print("  {d} required dependency(ies) missing — see FAIL lines above.\n", .{failures});
    }

    // The pinned providers' doctors, after the core checks and whatever they
    // found: a core failure does not hide a provider's report, and one
    // provider failing does not stop the next.
    const providers: ?provider_doctor.Report = if (core_only) null else if (scope.root) |root|
        try provider_doctor.runForRoot(arena, root, false)
    else blk: {
        provider_doctor.printOutsideProject(project_dir);
        break :blk null;
    };
    std.debug.print("\n", .{});
    const code = provider_doctor.exitCode(failures == 0, providers);
    // Clean non-zero exit (scriptable) without a Zig error-return trace —
    // this is a user-facing diagnostic, not an internal failure.
    if (code != 0) std.process.exit(code);
}

// ── `--zig` ─────────────────────────────────────────────────────────────

/// `--zig <path>` or `--zig=<path>` at `args[i.*]`: the path (advancing `i`
/// past a separate value), or null when the argument is something else.
/// A missing or empty path is `error.InvalidArgument`.
fn zigFlag(args: []const []const u8, i: *usize) !?[]const u8 {
    const arg = args[i.*];
    const path = if (std.mem.startsWith(u8, arg, "--zig="))
        arg["--zig=".len..]
    else if (std.mem.eql(u8, arg, "--zig")) blk: {
        if (i.* + 1 >= args.len) break :blk "";
        i.* += 1;
        break :blk args[i.*];
    } else return null;
    if (path.len == 0) {
        std.debug.print("labelle doctor: --zig requires a path (e.g. --zig /opt/zig/zig)\n", .{});
        return error.InvalidArgument;
    }
    return path;
}

// ── Project scope ───────────────────────────────────────────────────────

const Scope = struct {
    /// The directory every check reads: the project root, or the given
    /// directory outside a project.
    dir: []const u8,
    /// The canonical project root, null outside a project.
    root: ?[]const u8,
};

/// The nearest project at or above `start`, found the way the provider
/// commands find it (`provider_dispatch.projectRootFrom`), so `labelle
/// doctor` run from a project's subdirectory checks that project in full.
/// Outside a project (or when `start` cannot be resolved) the core checks
/// read `start` as before and there is no provider part.
fn resolveScope(arena: std.mem.Allocator, start: []const u8) Scope {
    const root = provider_dispatch.projectRootFrom(arena, start) catch null;
    return .{ .dir = root orelse start, .root = root };
}

// ── Project config (textual, dependency-free) ───────────────────────────

const Cfg = struct {
    /// A `project.labelle` was read.
    found: bool = false,
    gamepad_off: bool = false,
};

/// The backend package's name for the core target, from `labelle-assembler
/// describe`; null when the assembler cannot be resolved or cannot answer
/// (doctor is best-effort: it reports "unknown" and keeps checking).
fn describeBackend(arena: std.mem.Allocator, project_dir: []const u8) ?[]const u8 {
    const bin = assembler_proc.resolve(arena, project_dir, "describe") catch return null;
    const d = assembler_describe.Describer.init(bin, project_dir).query(arena, provider_targets.core_target) orelse return null;
    return d.backend.name;
}

/// Read the gamepad opt-out straight out of `project.labelle` text. A full
/// ZON parse isn't worth a dependency here; the field is a simple
/// `.field = .value` form.
fn readProjectConfig(arena: std.mem.Allocator, project_dir: []const u8) Cfg {
    const io = config.globalIo();
    const path = std.fs.path.join(arena, &.{ project_dir, "project.labelle" }) catch return .{};
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return .{};

    var cfg: Cfg = .{ .found = true };
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
    const resolved = zig_toolchain.resolveRequiredVersion(arena, project_dir) catch {
        return .{ .name = "Zig toolchain", .ok = false, .hint = "could not resolve the required Zig version" };
    };
    // An override is used as-is by every build, so it is checked, not
    // assumed: the same `verifyBinary` the provider host resolution uses.
    if (zig_toolchain.lookupEnvOverride(arena) catch null) |path| return checkOverride(arena, "LABELLE_ZIG", path, resolved.version);
    if (zig_toolchain.flagOverride()) |path| return checkOverride(arena, "--zig", path, resolved.version);
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

/// The core check of a Zig override (`LABELLE_ZIG` or `--zig`) against the
/// project's required version.
fn checkOverride(arena: std.mem.Allocator, source: []const u8, path: []const u8, required: []const u8) Check {
    const name = "Zig toolchain";
    const verified = zig_toolchain.verifyBinary(arena, path, required) catch
        return .{ .name = name, .ok = false, .hint = "could not check the Zig override (out of memory)" };
    const fmt = std.fmt.allocPrint;
    return switch (verified) {
        .ok => .{ .name = name, .ok = true, .detail = fmt(arena, "{s} override: {s} (zig {s}, verified)", .{ source, path, required }) catch "override verified" },
        .missing => .{ .name = name, .ok = false, .hint = fmt(arena, "{s} override '{s}' does not exist", .{ source, path }) catch "override does not exist" },
        .not_executable => .{ .name = name, .ok = false, .hint = fmt(arena, "{s} override '{s}' is not an executable file", .{ source, path }) catch "override is not executable" },
        .failed => .{ .name = name, .ok = false, .hint = fmt(arena, "{s} override '{s}' did not run `zig version`", .{ source, path }) catch "override did not run" },
        .version => |reported| .{ .name = name, .ok = false, .hint = fmt(arena, "{s} override '{s}' is Zig {s}; this project requires {s}", .{ source, path, reported, required }) catch "override has the wrong version" },
    };
}

/// The name of the Python check, in the human report and the JSON item.
const python_check_name = "Python (.prebuild steps, provider tools)";

/// Python: the managed interpreter under `~/.labelle/python`, or a system
/// `python3` (`python`/`python3` on Windows) on PATH. Optional (a WARN,
/// never a FAIL): the core itself runs no Python; `.prebuild` steps and
/// provider commands and hooks that spawn it do, and get the managed one on
/// PATH (RFC cli#466 D2).
fn checkPython(arena: std.mem.Allocator) Check {
    // `managedPythonOk` RUNS the interpreter (--version), so a half-extracted
    // install reports not-ok instead of faking readiness (PR #291 review).
    if (python_provision.managedPythonOk(arena)) {
        const exe = python_provision.findPythonExe(arena) orelse unreachable;
        return .{ .name = python_check_name, .ok = true, .required = false, .detail = std.fmt.allocPrint(arena, "managed: {s}", .{exe}) catch "managed" };
    }
    if (python_provision.systemPythonOk(arena)) {
        return .{ .name = python_check_name, .ok = true, .required = false, .detail = "system python3 on PATH" };
    }
    return .{
        .name = python_check_name,
        .ok = false,
        .required = false,
        .hint = if (python_provision.managedProvisioningSupported())
            "run `labelle install python` (managed, ~25 MB) or install Python 3 yourself"
        else
            "install Python 3 and ensure `python3` is on PATH",
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

test "doctor: a Zig override is verified, not assumed: missing, wrong version, right version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.writeFile(io, .{ .sub_path = "project.labelle", .data = ".{ .name = \"x\", .zig_version = \"0.16.0\" }" });

    // Missing, through the real `checkZig` with a `--zig` flag: the override
    // branch ran (the hint names it) and the check fails.
    // (A LABELLE_ZIG in the test environment would win over the flag.)
    const env_override = (zig_toolchain.lookupEnvOverride(a) catch null) != null;
    const missing = try std.fs.path.join(a, &.{ dir, "no-such-zig" });
    zig_toolchain.setFlagOverride(missing);
    defer zig_toolchain.setFlagOverride(null);
    if (!env_override) {
        const flagged = checkZig(a, dir);
        try std.testing.expect(!flagged.ok);
        try std.testing.expect(std.mem.indexOf(u8, flagged.hint.?, "--zig override") != null);
        try std.testing.expect(std.mem.indexOf(u8, flagged.hint.?, "does not exist") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, checkOverride(a, "--zig", missing, "0.16.0").hint.?, "does not exist") != null);

    // A directory is not an executable.
    try std.testing.expect(!checkOverride(a, "--zig", dir, "0.16.0").ok);

    // Scripts that answer `zig version`: POSIX shells only.
    if (builtin.os.tag == .windows) return;
    const Fake = struct {
        fn write(d: std.Io.Dir, name: []const u8, version: []const u8) !void {
            var buf: [128]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "#!/bin/sh\necho {s}\n", .{version});
            try d.writeFile(config.globalIo(), .{ .sub_path = name, .data = text, .flags = .{ .permissions = .executable_file } });
        }
    };
    try Fake.write(tmp.dir, "zig-old", "0.15.1");
    try Fake.write(tmp.dir, "zig-right", "0.16.0");
    const old = checkOverride(a, "LABELLE_ZIG", try std.fs.path.join(a, &.{ dir, "zig-old" }), "0.16.0");
    try std.testing.expect(!old.ok);
    // The version was actually read: the hint quotes what the binary said.
    try std.testing.expect(std.mem.indexOf(u8, old.hint.?, "is Zig 0.15.1; this project requires 0.16.0") != null);
    const right = checkOverride(a, "LABELLE_ZIG", try std.fs.path.join(a, &.{ dir, "zig-right" }), "0.16.0");
    try std.testing.expect(right.ok);
    try std.testing.expect(std.mem.indexOf(u8, right.detail.?, "zig 0.16.0, verified") != null);
    // And through `checkZig` with the flag: the same verdict.
    if (env_override) return;
    zig_toolchain.setFlagOverride(try std.fs.path.join(a, &.{ dir, "zig-old" }));
    try std.testing.expect(!checkZig(a, dir).ok);
    zig_toolchain.setFlagOverride(try std.fs.path.join(a, &.{ dir, "zig-right" }));
    try std.testing.expect(checkZig(a, dir).ok);
}

test "doctor: --zig is consumed with its value, in both spellings, and never read as the project dir" {
    const args = [_][]const u8{ "some/dir", "--zig", "/opt/zig/zig", "--zig=/other/zig", "--fix" };
    var i: usize = 0;
    try std.testing.expectEqual(@as(?[]const u8, null), try zigFlag(&args, &i));
    i = 1;
    try std.testing.expectEqualStrings("/opt/zig/zig", (try zigFlag(&args, &i)).?);
    // The separate value was consumed: the loop resumes after it.
    try std.testing.expectEqual(@as(usize, 2), i);
    i = 3;
    try std.testing.expectEqualStrings("/other/zig", (try zigFlag(&args, &i)).?);
    try std.testing.expectEqual(@as(usize, 3), i);
    i = 4;
    try std.testing.expectEqual(@as(?[]const u8, null), try zigFlag(&args, &i));
    for ([_][]const []const u8{ &.{"--zig"}, &.{"--zig="} }) |bad| {
        i = 0;
        try std.testing.expectError(error.InvalidArgument, zigFlag(bad, &i));
    }
}

test "doctor: run from a project subdirectory, both halves use the project root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "game/src/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "game/project.labelle", .data = ".{ .name = \"x\", .gamepad = .none, .zig_version = \"0.16.0\" }" });
    const root = try tmp.dir.realPathFileAlloc(io, "game", a);
    const nested = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "game", "src", "deep" });
    const scope = resolveScope(a, nested);
    // The walked-up root, not the subdirectory, for the core checks too ...
    try std.testing.expectEqualStrings(root, scope.dir);
    try std.testing.expectEqualStrings(root, scope.root.?);
    // ... so they see the project's own settings.
    const cfg = readProjectConfig(a, scope.dir);
    try std.testing.expect(cfg.found);
    try std.testing.expect(cfg.gamepad_off);
    // The Zig version comes from the project's own pin, not the default.
    const zig = try zig_toolchain.resolveRequiredVersion(a, scope.dir);
    try std.testing.expectEqual(.project_pin, zig.source);
    try std.testing.expectEqual(.default, (try zig_toolchain.resolveRequiredVersion(a, nested)).source);
    // The subdirectory alone has no project.labelle: reading it would have
    // fallen back to the defaults.
    try std.testing.expect(!readProjectConfig(a, nested).found);
    // Outside a project: the given directory, no provider part.
    try tmp.dir.createDirPath(io, "loose");
    const loose = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "loose" });
    const outside = resolveScope(a, loose);
    if (outside.root == null) try std.testing.expectEqualStrings(loose, outside.dir);
}

/// The `--json` capability report is a cross-repo contract with
/// labelle-studio's ToolchainGate (src/services/doctor.ts zod schema). Pin
/// its shape so a drift breaks CI here, not the studio at runtime.
pub const JsonReportSpec = struct {
    test "doctor --json emits the core's zig and python capabilities, python optional" {
        const testing = std.testing;
        var buf: [3072]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        const zig_check = Check{ .name = "Zig toolchain", .ok = true, .detail = "managed zig 0.16.0" };
        const python_check = Check{ .name = python_check_name, .ok = false, .required = false, .hint = "run `labelle install python`" };
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try writeJsonReport(&w, arena.allocator(), zig_check, python_check, null);
        const line = w.buffered();

        // Exactly one line (the studio extractor is line-based).
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));

        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        const caps = parsed.value.object.get("capabilities").?.array;
        // The core names no target's capability: that is its provider's.
        try testing.expectEqual(@as(usize, 2), caps.items.len);

        const zig = caps.items[0].object;
        try testing.expectEqualStrings("zig", zig.get("id").?.string);
        try testing.expectEqual(true, zig.get("required").?.bool);
        try testing.expectEqual(true, zig.get("ok").?.bool);
        const zig_item = zig.get("items").?.array.items[0].object;
        try testing.expectEqualStrings("zig", zig_item.get("id").?.string);
        try testing.expectEqual(false, zig_item.get("fixable").?.bool);
        try testing.expectEqualStrings("managed zig 0.16.0", zig_item.get("detail").?.string);
        try testing.expectEqual(std.json.Value.null, std.meta.activeTag(zig_item.get("hint").?));

        // Python is optional: a missing one fails its own capability, which
        // is not required, and is fixable on managed-provisioning platforms
        // with the exact install command as its action (cli#291).
        const python = caps.items[1].object;
        try testing.expectEqualStrings("python", python.get("id").?.string);
        try testing.expectEqual(false, python.get("required").?.bool);
        try testing.expectEqual(false, python.get("ok").?.bool);
        const py_item = python.get("items").?.array.items[0].object;
        try testing.expectEqualStrings("python", py_item.get("id").?.string);
        try testing.expectEqual(false, py_item.get("ok").?.bool);
        const py_fixable = python_provision.managedProvisioningSupported();
        try testing.expectEqual(py_fixable, py_item.get("fixable").?.bool);
        if (py_fixable) {
            try testing.expectEqualStrings("labelle install python", py_item.get("action").?.string);
            try testing.expectEqual(@as(i64, 25), py_item.get("size_mb").?.integer);
        }
        try testing.expectEqualStrings("run `labelle install python`", py_item.get("hint").?.string);
    }

    test "doctor: a missing Python is a warning, never a failure" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expect(!checkPython(arena.allocator()).required);
    }
};
