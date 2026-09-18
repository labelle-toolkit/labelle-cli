//! Shader execution/caching lives in the generated Zig graph. The CLI only
//! preflights an explicit host-tool override; normal builds provision it there.
//!
//! The preflight fails CLOSED: once `LABELLE_SHADERC` is set for a project that
//! has `materials/`, generation stops unless the value is an absolute path to a
//! real file. Silently ignoring a bad override would hand the generated graph a
//! compiler that cannot run, surfacing much later as an unrelated `zig build`
//! failure — or, under `labelle run`, as a silently reused stale binary.
const std = @import("std");
const config = @import("config.zig");

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
}

/// Read `LABELLE_SHADERC` and gate on it. Called by BOTH the cold pipeline
/// (`pipeline.run`, before `assembler generate`) and every watched rebuild
/// (`WasmRebuildCtx.rebuild`), so a `materials/` directory that appears
/// only after `wasm serve --watch` started is gated exactly like a cold
/// build — the first rebuild that would consume the override is the one
/// that validates it.
pub fn preflight(a: std.mem.Allocator, project_dir: []const u8) !void {
    const path = config.globalEnviron().getAlloc(a, "LABELLE_SHADERC") catch |err| switch (err) {
        // No override configured: the generated graph builds the pinned
        // compiler itself. Any OTHER failure is real and must not be
        // mistaken for "unset".
        error.EnvironmentVariableMissing => return,
        else => return err,
    };
    defer a.free(path);
    try preflightWith(a, project_dir, path);
}

/// The gate itself, with the override value supplied by the caller: a
/// project WITHOUT `materials/` has nothing that will consume the override,
/// so it passes; a project WITH one must carry a valid override or stop
/// here, before generation. `null` (no override) always passes.
pub fn preflightWith(a: std.mem.Allocator, project_dir: []const u8, override: ?[]const u8) !void {
    const path = override orelse return;
    const materials = try std.fs.path.join(a, &.{ project_dir, "materials" });
    defer a.free(materials);
    var dir = std.Io.Dir.cwd().openDir(config.globalIo(), materials, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    dir.close(config.globalIo());
    try validateOverride(path);
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
    try preflightWith(a, project, "shaderc");
    // materials/ appears later (an edit, a prebuild hook): the SAME call
    // now rejects the same value. This is the property the watched
    // rebuild relies on when it re-invokes the preflight.
    try tmp.dir.createDirPath(io, "project/materials");
    try std.testing.expectError(error.ShadercOverrideMustBeAbsolute, preflightWith(a, project, "shaderc"));
    // No override configured: never gated, materials/ or not.
    try preflightWith(a, project, null);
}
