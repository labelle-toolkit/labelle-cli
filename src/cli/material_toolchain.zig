//! Shader execution/caching lives in the generated Zig graph. The CLI only
//! preflights an explicit host-tool override; normal builds provision it there.
//!
//! The preflight fails CLOSED: once `LABELLE_SHADERC` is set for a project that
//! has `materials/`, generation stops unless the value is an absolute path to a
//! real, EXECUTABLE file. Silently ignoring a bad override would hand the generated graph a
//! compiler that cannot run, surfacing much later as an unrelated `zig build`
//! failure — or, under `labelle run`, as a silently reused stale binary.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");

/// Where the build that will consume the override actually runs.
///
/// `--docker` is NOT a second place to look for the compiler: the override is
/// validated on the HOST (so a typo still fails here, naming the value,
/// instead of deep inside the container) and then deliberately NOT forwarded
/// into the container. A host `shaderc` is a host-OS/arch binary; bind-mounting
/// it into the linux build image would swap an honest preflight failure for an
/// `Exec format error` thousands of lines into `zig build`. The containerised
/// build therefore compiles shaders with its own in-container pinned compiler,
/// and `preflightWith` says so out loud rather than letting the user believe
/// the override took effect.
pub const BuildHost = enum { native, docker };

/// Windows has no execute bit, so executability is an extension question.
/// The repo's own convention is `exe_suffix = ".exe"` (see `zig_cache.zig`,
/// `assembler.zig`, `pipeline.zig`); `.bat`/`.cmd` are accepted alongside it
/// as the other directly-spawnable forms.
const windows_exec_exts = [_][]const u8{ ".exe", ".bat", ".cmd" };

fn hasWindowsExecExtension(path: []const u8) bool {
    for (windows_exec_exts) |ext| {
        if (path.len < ext.len) continue;
        if (std.ascii.eqlIgnoreCase(path[path.len - ext.len ..], ext)) return true;
    }
    return false;
}

pub fn validateOverridePath(path: []const u8) !void {
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return error.ShadercOverrideMustBeAbsolute;
}

/// Full override check, diagnostics included. Every rejection names the
/// offending value so the message is actionable without re-reading the env.
pub fn validateOverride(path: []const u8) !void {
    validateOverridePath(path) catch |err| {
        std.debug.print("labelle: LABELLE_SHADERC '{s}' is not an absolute path; it must name the host shaderc executable, or be unset to build the pinned compiler automatically\n", .{path});
        return err;
    };
    const stat = std.Io.Dir.cwd().statFile(config.globalIo(), path, .{}) catch |err| {
        std.debug.print("labelle: LABELLE_SHADERC '{s}' is unavailable ({s}); unset it to build the pinned compiler automatically\n", .{ path, @errorName(err) });
        return error.ShadercOverrideUnavailable;
    };
    if (stat.kind != .file) {
        std.debug.print("labelle: LABELLE_SHADERC '{s}' is a {s}, not an executable file; unset it to build the pinned compiler automatically\n", .{ path, @tagName(stat.kind) });
        return error.ShadercOverrideNotAFile;
    }
    // A regular file is not yet a runnable one. Without this the preflight
    // waves through a `-rw-r--r--` path and the build dies at exec time with
    // exactly the opaque failure the gate exists to replace.
    if (builtin.os.tag == .windows) {
        if (!hasWindowsExecExtension(path)) {
            std.debug.print("labelle: LABELLE_SHADERC '{s}' is not executable: it has no executable extension (.exe, .bat or .cmd); point it at the shaderc executable, or unset it to build the pinned compiler automatically\n", .{path});
            return error.ShadercOverrideNotExecutable;
        }
    } else {
        const mode = stat.permissions.toMode();
        if (mode & 0o111 == 0) {
            std.debug.print("labelle: LABELLE_SHADERC '{s}' is not executable: mode {o} has no execute permission for any user; `chmod +x {s}`, or unset it to build the pinned compiler automatically\n", .{ path, mode & 0o7777, path });
            return error.ShadercOverrideNotExecutable;
        }
    }
}

/// Read `LABELLE_SHADERC` and gate on it. Called by BOTH the cold pipeline
/// (`pipeline.run`, before `assembler generate`) and every watched rebuild
/// (`WasmRebuildCtx.rebuild`), so a `materials/` directory that appears
/// only after `wasm serve --watch` started is gated exactly like a cold
/// build — the first rebuild that would consume the override is the one
/// that validates it.
pub fn preflight(a: std.mem.Allocator, project_dir: []const u8) !void {
    return preflightHost(a, project_dir, .native);
}

/// The `--docker` cold path. Same gate, same diagnostics, plus the notice
/// that the validated host path is not forwarded into the container.
pub fn preflightDocker(a: std.mem.Allocator, project_dir: []const u8) !void {
    return preflightHost(a, project_dir, .docker);
}

fn preflightHost(a: std.mem.Allocator, project_dir: []const u8, host: BuildHost) !void {
    const shaderc = config.globalEnviron().getAlloc(a, "LABELLE_SHADERC") catch |err| switch (err) {
        // No override configured: the generated graph builds the pinned
        // compiler itself. Any OTHER failure is real and must not be
        // mistaken for "unset".
        error.EnvironmentVariableMissing => return,
        else => return err,
    };
    defer a.free(shaderc);
    try preflightWith(a, project_dir, shaderc, host);
}

/// The gate itself, with the override value supplied by the caller: a
/// project WITHOUT `materials/` has nothing that will consume the override,
/// so it passes; a project WITH one must carry a valid override or stop
/// here, before generation. `null` (no override) always passes.
pub fn preflightWith(a: std.mem.Allocator, project_dir: []const u8, override: ?[]const u8, host: BuildHost) !void {
    const shaderc = override orelse return;
    const materials = try std.fs.path.join(a, &.{ project_dir, "materials" });
    defer a.free(materials);
    var dir = std.Io.Dir.cwd().openDir(config.globalIo(), materials, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    dir.close(config.globalIo());
    try validateOverride(shaderc);
    // Validation first, notice second: a `--docker` build with a bad value
    // still fails HERE, naming the value, rather than inside the container.
    if (host == .docker) {
        std.debug.print("labelle: note: LABELLE_SHADERC '{s}' is a HOST path and is NOT forwarded into the --docker build; the container compiles shaders with its own pinned compiler. A host executable cannot run inside the linux build image, so mapping it in would fail at exec time. Drop --docker for the override to take effect.\n", .{shaderc});
    }
}

test "shader tool override cannot depend on changed generated working directory" {
    try std.testing.expectError(error.ShadercOverrideMustBeAbsolute, validateOverridePath("shaderc"));
    try std.testing.expectError(error.ShadercOverrideMustBeAbsolute, validateOverridePath(""));
    try std.testing.expectError(error.ShadercOverrideMustBeAbsolute, validateOverridePath("./tools/shaderc"));
    try std.testing.expectError(error.ShadercOverrideMustBeAbsolute, validateOverridePath("../shaderc"));
    try validateOverridePath(if (@import("builtin").os.tag == .windows) "C:/tools/shaderc.exe" else "/tools/shaderc");
}

test "shader tool override rejects a relative, missing or non-file value" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    try std.testing.expectError(error.ShadercOverrideMustBeAbsolute, validateOverride("shaderc"));
    // An absolute path that does not exist must NOT pass as "probably fine".
    try std.testing.expectError(error.ShadercOverrideUnavailable, validateOverride("/nonexistent/labelle-shaderc-probe"));
    // A directory satisfies `access()` but can never be executed, so the
    // check has to look at the kind, not merely at reachability.
    try std.testing.expectError(error.ShadercOverrideNotAFile, validateOverride("/tmp"));
    // …and a real absolute file is accepted, so the rejections above are
    // the check firing rather than the check always failing.
    try validateOverride("/bin/sh");
}

test "shader tool override rejects a regular file without the executable bit" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A perfectly ordinary `-rw-r--r--` file: a real file, absolute path,
    // stat-able — everything the pre-#387 gate checked — that can never be
    // exec'd. It must be rejected HERE, not at exec time.
    (try tmp.dir.createFile(io, "shaderc", .{ .permissions = .fromMode(0o644) })).close(io);
    const not_exec = try tmp.dir.realPathFileAlloc(io, "shaderc", a);
    defer a.free(not_exec);
    try std.testing.expectError(error.ShadercOverrideNotExecutable, validateOverride(not_exec));
    // Same file, +x: accepted. The rejection above is the mode check firing,
    // not the path being unusable for some other reason.
    try std.Io.Dir.cwd().setFilePermissions(io, not_exec, .fromMode(0o755), .{});
    try validateOverride(not_exec);
}

test "shader tool override gate is keyed on materials/ existing at call time, not at startup" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    // Cold start without materials/: an invalid override is NOT consulted.
    try preflightWith(a, project, "shaderc", .native);
    // materials/ appears later (an edit, a prebuild hook): the SAME call
    // now rejects the same value. This is the property the watched
    // rebuild relies on when it re-invokes the preflight.
    try tmp.dir.createDirPath(io, "project/materials");
    try std.testing.expectError(error.ShadercOverrideMustBeAbsolute, preflightWith(a, project, "shaderc", .native));
    // No override configured: never gated, materials/ or not.
    try preflightWith(a, project, null, .native);
}

test "shader tool override gate applies to --docker builds, and to non-executable values, through the same preflightWith" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project/materials");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);

    // Gap 1: a `--docker` build with an invalid override stops at the
    // preflight, naming the value — it does not sail through to the
    // container, where the override is not forwarded at all.
    try std.testing.expectError(error.ShadercOverrideMustBeAbsolute, preflightWith(a, project, "shaderc", .docker));
    try std.testing.expectError(error.ShadercOverrideUnavailable, preflightWith(a, project, "/nonexistent/labelle-shaderc-probe", .docker));

    // Gap 2: a non-executable regular file is rejected on BOTH hosts — the
    // check lives in the shared gate, so the cold, watched and docker paths
    // cannot drift apart.
    (try tmp.dir.createFile(io, "shaderc", .{ .permissions = .fromMode(0o644) })).close(io);
    const shaderc = try tmp.dir.realPathFileAlloc(io, "shaderc", a);
    defer a.free(shaderc);
    try std.testing.expectError(error.ShadercOverrideNotExecutable, preflightWith(a, project, shaderc, .native));
    try std.testing.expectError(error.ShadercOverrideNotExecutable, preflightWith(a, project, shaderc, .docker));

    // Positive case: a genuinely executable compiler passes on both hosts,
    // so none of the rejections above is vacuous.
    try std.Io.Dir.cwd().setFilePermissions(io, shaderc, .fromMode(0o755), .{});
    try preflightWith(a, project, shaderc, .native);
    try preflightWith(a, project, shaderc, .docker);
}
