//! `labelle doctor` — preflight the desktop build/run requirements and report
//! missing system dependencies with actionable fixes.
//!
//! The core target's checks come first. Inside a project, `labelle doctor`
//! then runs the doctor of every pinned provider whose manifest declares one
//! (the same run as `labelle <namespace> doctor`; see `provider_doctor.zig`),
//! and exits non-zero if the core or any provider fails. `--core-only` skips
//! the provider part. The core checks only what it owns: the managed Zig and
//! Python. Everything else a labelle game needs is fetched + compiled by Zig,
//! or is a provider's to check and provision.
//!
//! SDL2 is one such system library: the `sdl` renderer and the gamepad
//! source of other desktop backends link it. Its provisioning, runtime DLL
//! staging and doctor rows left the core for the opt-in `sdl2` provider
//! (labelle-sdl; RFC cli#471 S4, D2). When the project's build links SDL2
//! and `.plugins` does not list that provider, doctor prints a one-line
//! hint instead (`sdl2Hint`).
//!
//! `--fix` has nothing to fix in the core any more; a provider's doctor
//! fixes its own (`labelle <namespace> doctor --fix`). Forwarding `--fix` to
//! the provider doctors (RFC cli#471 D10) is not implemented yet.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const assembler_proc = @import("assembler_proc.zig");
const assembler_describe = @import("assembler_describe.zig");
const provider_targets = @import("provider_targets.zig");
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
    // checks and the provider doctors, and stop — no human report. The python
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
    // (`describe`, cli#471 D4: the CLI reads no `.backend` of its own). Only
    // inside a project: outside one, or when `describe` cannot answer, it is
    // unknown. It scopes nothing but the report header and the SDL2 hint.
    const backend: ?[]const u8 = if (cfg.found) describeBackend(arena, scope.dir) else null;

    if (do_fix) {
        std.debug.print("labelle doctor: the core has nothing to fix; a provider's doctor fixes its own (`labelle <namespace> doctor --fix`).\n", .{});
    }

    var checks: std.ArrayList(Check) = .empty;

    try checks.append(arena, zig_check);
    try checks.append(arena, python_check);

    // ── Report ──────────────────────────────────────────────────────────
    const backend_label = if (backend) |name|
        name
    else if (cfg.found)
        "unknown (`labelle-assembler describe` gave no answer)"
    else
        "unknown (no project.labelle)";
    const gamepad_label = if (!cfg.found) "n/a" else if (cfg.gamepad_off) "off" else "on";
    std.debug.print(
        \\
        \\labelle doctor
        \\==============
        \\  project: {s}
        \\  backend: {s}   gamepad: {s}
        \\
        \\
    , .{ scope.dir, backend_label, gamepad_label });

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
        std.debug.print("  All required core dependencies are present.\n", .{});
    } else {
        std.debug.print("  {d} required dependency(ies) missing — see FAIL lines above.\n", .{failures});
    }
    if (sdl2Hint(cfg, backend)) |hint| std.debug.print("  {s}\n", .{hint});

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
    /// `.plugins` lists the `sdl2` provider (labelle-sdl).
    sdl2_provider: bool = false,
};

/// The one line doctor prints about SDL2 now that the core no longer
/// provisions it (cli#471 S4), or null. Shown when the project's desktop
/// build links SDL2 and `.plugins` lacks the `sdl2` provider that took the
/// provisioning over. "Links SDL2" is the rule the core used to provision
/// by: the `sdl` renderer always; raylib, sokol and bgfx for their gamepad
/// source unless `.gamepad = .none`. An unknown backend (`describe` gave no
/// answer) is judged by the gamepad alone, as the assembler's default
/// backend links SDL2 for it. Outside a project there is nothing to judge.
/// Advice, never a failure: SDL2 may be installed by other means.
fn sdl2Hint(cfg: Cfg, backend: ?[]const u8) ?[]const u8 {
    if (!cfg.found or cfg.sdl2_provider or !linksSdl2(backend, cfg.gamepad_off)) return null;
    return "SDL2: this build links SDL2, which the CLI no longer provisions: add the `sdl2` provider (labelle-sdl) to .plugins, set LABELLE_SDL2_LIB, or use `.gamepad = .none`.";
}

fn linksSdl2(backend: ?[]const u8, gamepad_off: bool) bool {
    const name = backend orelse return !gamepad_off;
    if (std.mem.eql(u8, name, "sdl")) return true;
    for ([_][]const u8{ "raylib", "sokol", "bgfx" }) |pad| {
        if (std.mem.eql(u8, name, pad)) return !gamepad_off;
    }
    return false;
}

test "doctor: the SDL2 hint follows the old rule and goes quiet with the provider (cli#471 S4)" {
    const plain: Cfg = .{ .found = true };
    // The renderer always, even with the gamepad opted out.
    try std.testing.expect(sdl2Hint(plain, "sdl") != null);
    try std.testing.expect(sdl2Hint(.{ .found = true, .gamepad_off = true }, "sdl") != null);
    // The gamepad backends unless opted out; any other backend never.
    for ([_][]const u8{ "raylib", "sokol", "bgfx" }) |name| {
        try std.testing.expect(sdl2Hint(plain, name) != null);
        try std.testing.expect(sdl2Hint(.{ .found = true, .gamepad_off = true }, name) == null);
    }
    for ([_][]const u8{ "null", "wgpu", "acme" }) |name| try std.testing.expect(sdl2Hint(plain, name) == null);
    // Unknown backend: the gamepad decides.
    try std.testing.expect(sdl2Hint(plain, null) != null);
    try std.testing.expect(sdl2Hint(.{ .found = true, .gamepad_off = true }, null) == null);
    // The provider listed, or no project: no hint.
    try std.testing.expect(sdl2Hint(.{ .found = true, .sdl2_provider = true }, "sdl") == null);
    try std.testing.expect(sdl2Hint(.{}, "sdl") == null);
}

/// The backend package's name for the core target, from `labelle-assembler
/// describe`; null when the assembler cannot be resolved or cannot answer
/// (doctor is best-effort: it reports "unknown" and keeps checking).
fn describeBackend(arena: std.mem.Allocator, project_dir: []const u8) ?[]const u8 {
    const bin = assembler_proc.resolve(arena, project_dir, "describe") catch return null;
    const d = assembler_describe.Describer.init(bin, project_dir).query(arena, provider_targets.core_target) orelse return null;
    return d.backend.name;
}

/// The gamepad opt-out and whether the `sdl2` provider is listed, from
/// `project.labelle`. Parsed when it parses; otherwise read out of the text
/// (doctor is best-effort and still reports on a config the build would
/// reject).
fn readProjectConfig(arena: std.mem.Allocator, project_dir: []const u8) Cfg {
    const io = config.globalIo();
    const path = std.fs.path.join(arena, &.{ project_dir, "project.labelle" }) catch return .{};
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return .{};

    if (config.readProjectConfigQuiet(arena, project_dir)) |parsed| {
        return .{ .found = true, .gamepad_off = parsed.gamepad == .none, .sdl2_provider = parsed.hasPlugin("sdl2") };
    } else |_| {}
    return .{
        .found = true,
        .gamepad_off = std.mem.indexOf(u8, content, ".gamepad = .none") != null or
            std.mem.indexOf(u8, content, ".gamepad=.none") != null,
        .sdl2_provider = std.mem.indexOf(u8, content, "\"sdl2\"") != null,
    };
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
