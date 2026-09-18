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

/// How a Windows path's extension relates to spawning it as a PROCESS.
pub const WindowsExecKind = enum {
    /// `CreateProcess` can launch this file directly.
    directly_executable,
    /// A script that only runs THROUGH `cmd.exe /c` — it can never be the
    /// executable path of a process spawn.
    interpreter_required,
    /// Not a runnable form at all.
    not_executable,
};

/// Windows has no execute bit, so executability is an extension question.
/// The repo's own convention is `exe_suffix = ".exe"` (see `zig_cache.zig`,
/// `assembler.zig`, `pipeline.zig`); `.com` is the other form `CreateProcess`
/// launches directly.
const windows_exec_exts = [_][]const u8{ ".exe", ".com" };

/// `.bat`/`.cmd` are NOT in the list above, deliberately (#389 review).
///
/// DECISION: REJECT them, with a diagnostic that says what to pass instead.
///
/// Windows cannot spawn a batch file as a process image: `CreateProcess`
/// requires a PE binary, so a `.bat`/`.cmd` only runs as an ARGUMENT to
/// `cmd.exe /c`. `LABELLE_SHADERC` is consumed by the generated Zig build
/// graph, which puts the value in the `argv[0]` slot of a plain
/// `std.process.Child` spawn — there is no seam there for an interpreter,
/// and inventing one in the CLI would not reach the graph that actually
/// runs the compiler. Accepting a batch wrapper here therefore passes
/// preflight and dies at spawn with `error.InvalidExe` — precisely the
/// late, opaque failure this gate exists to replace, which is why the
/// earlier allowlist was worse than useless.
///
/// Supporting them properly means teaching the generated graph to spawn
/// `cmd.exe /c <wrapper>`; that is an assembler-side change, not a CLI one,
/// and is not worth it for a wrapper the user can replace with the real
/// `shaderc.exe` it invokes.
const windows_interpreted_exts = [_][]const u8{ ".bat", ".cmd" };

fn hasExtension(path: []const u8, exts: []const []const u8) bool {
    for (exts) |ext| {
        if (path.len < ext.len) continue;
        if (std.ascii.eqlIgnoreCase(path[path.len - ext.len ..], ext)) return true;
    }
    return false;
}

/// Pure classification, so the Windows policy is testable on every host.
pub fn classifyWindowsPath(path: []const u8) WindowsExecKind {
    if (hasExtension(path, &windows_exec_exts)) return .directly_executable;
    if (hasExtension(path, &windows_interpreted_exts)) return .interpreter_required;
    return .not_executable;
}

/// Can the INVOKING user execute `path`? `null` when the host cannot say.
///
/// `mode & 0o111 != 0` only proves that SOME class carries an execute bit,
/// not that this process may exec the file (#389 review): a user-owned file
/// with mode `001` grants execute to *other* only, so the owner — the very
/// user running `labelle` — cannot run it, yet the bitwise test passed and
/// the build died at exec time with `EACCES`.
///
/// `faccessat(..., X_OK, AT_EACCESS)` answers the exact question, against the
/// EFFECTIVE uid/gid and the process's full supplementary-group set, which a
/// hand-rolled owner/group/other comparison cannot reproduce (it would need
/// `getgroups`, and would still be a re-implementation of the kernel's
/// check). `null` is returned for an errno that is not a permission verdict,
/// so the caller can fall back rather than reject a usable compiler.
fn executableByCaller(path: []const u8) ?bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const rc = std.c.faccessat(std.c.AT.FDCWD, @ptrCast(&buf), std.c.X_OK, std.c.AT.EACCESS);
    if (rc == 0) return true;
    return switch (std.c.errno(rc)) {
        // A permission verdict: the caller genuinely may not exec it.
        .ACCES, .PERM, .NOENT, .NOTDIR, .LOOP, .NAMETOOLONG, .TXTBSY => false,
        // Anything else (an `AT_EACCESS`-less kernel, EINVAL, EIO…) is not an
        // answer — let the caller fall back to the mode bits.
        else => null,
    };
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
        switch (classifyWindowsPath(path)) {
            .directly_executable => {},
            .interpreter_required => {
                std.debug.print("labelle: LABELLE_SHADERC '{s}' is a batch script, not an executable: Windows cannot spawn a .bat/.cmd as a process image (it only runs via `cmd.exe /c`), and the generated build graph spawns this path directly — it would fail at exec time. Point LABELLE_SHADERC at the shaderc.exe the wrapper invokes, or unset it to build the pinned compiler automatically\n", .{path});
                return error.ShadercOverrideNotExecutable;
            },
            .not_executable => {
                std.debug.print("labelle: LABELLE_SHADERC '{s}' is not executable: it has no executable extension (.exe or .com); point it at the shaderc executable, or unset it to build the pinned compiler automatically\n", .{path});
                return error.ShadercOverrideNotExecutable;
            },
        }
    } else {
        const mode = stat.permissions.toMode();
        // Ask the kernel whether THIS process may exec the file; fall back to
        // the mode bits only when it declines to say.
        const runnable = executableByCaller(path) orelse (mode & 0o111 != 0);
        if (!runnable) {
            std.debug.print("labelle: LABELLE_SHADERC '{s}' is not executable by the user running labelle: mode {o}; `chmod +x {s}`, or unset it to build the pinned compiler automatically\n", .{ path, mode & 0o7777, path });
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

test "a Windows batch wrapper is rejected, not accepted as directly spawnable — #389 review" {
    // Pure classification, so the Windows policy is asserted on every host
    // (the repo's CI runs the suite on macOS/Linux too).
    //
    // The MECHANISM, not just the verdict: `.bat`/`.cmd` must land in their
    // own class, distinct from "no executable extension at all", because the
    // two get different diagnostics — the batch one tells the user to point
    // at the `shaderc.exe` the wrapper invokes.
    try std.testing.expectEqual(WindowsExecKind.interpreter_required, classifyWindowsPath("C:/tools/shaderc.bat"));
    try std.testing.expectEqual(WindowsExecKind.interpreter_required, classifyWindowsPath("C:/tools/shaderc.CMD"));
    try std.testing.expectEqual(WindowsExecKind.directly_executable, classifyWindowsPath("C:/tools/shaderc.exe"));
    try std.testing.expectEqual(WindowsExecKind.directly_executable, classifyWindowsPath("C:/tools/SHADERC.EXE"));
    try std.testing.expectEqual(WindowsExecKind.directly_executable, classifyWindowsPath("C:/tools/shaderc.com"));
    try std.testing.expectEqual(WindowsExecKind.not_executable, classifyWindowsPath("C:/tools/shaderc"));
    try std.testing.expectEqual(WindowsExecKind.not_executable, classifyWindowsPath("C:/tools/shaderc.txt"));
    // A name that merely CONTAINS the extension is not a match.
    try std.testing.expectEqual(WindowsExecKind.not_executable, classifyWindowsPath("C:/tools/shaderc.bat.bak"));

    // And the classes really are distinct — a batch file is not quietly
    // filed under "directly executable", which is how it passed before.
    try std.testing.expect(classifyWindowsPath("C:/tools/shaderc.bat") != WindowsExecKind.directly_executable);
}

test "an execute bit for OTHER does not make the file executable by its owner — #389 review" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    // root's `X_OK` succeeds whenever ANY class has an execute bit, so the
    // distinction this test is about does not exist for root.
    if (std.c.geteuid() == 0) return error.SkipZigTest;

    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `---------x`: an execute bit is set, so `mode & 0o111 != 0` is TRUE and
    // the old gate waved this through — but the bit belongs to *other*, and
    // the file is owned by the user running the test, whose class (owner) has
    // no execute permission. Exec fails with EACCES.
    // Created readable so `realpath` can resolve it, then narrowed: the
    // point of the test is the MODE at validation time.
    (try tmp.dir.createFile(io, "shaderc", .{ .permissions = .fromMode(0o644) })).close(io);
    const path = try tmp.dir.realPathFileAlloc(io, "shaderc", a);
    defer a.free(path);
    try std.Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o001), .{});

    // Pin the mechanism: the OLD predicate accepts this file. Without this
    // the test could pass for a trivial reason (e.g. the file not existing).
    const mode = (try std.Io.Dir.cwd().statFile(io, path, .{})).permissions.toMode();
    try std.testing.expect(mode & 0o111 != 0);
    // ...and the new predicate is the one that rejects it.
    try std.testing.expectEqual(@as(?bool, false), executableByCaller(path));
    try std.testing.expectError(error.ShadercOverrideNotExecutable, validateOverride(path));

    // `--x------`: owner-only execute. The bitwise test and the effective
    // check agree here, so the rejection above is about the CLASS, not about
    // rejecting every unusual mode.
    try std.Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o100), .{});
    try std.testing.expectEqual(@as(?bool, true), executableByCaller(path));
    try validateOverride(path);

    // …and the ordinary 0755 case is unchanged.
    try std.Io.Dir.cwd().setFilePermissions(io, path, .fromMode(0o755), .{});
    try validateOverride(path);
}

test "the effective-permission check runs inside the shared preflightWith, so cold/--watch/--docker stay in lockstep" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project/materials");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);

    (try tmp.dir.createFile(io, "shaderc", .{ .permissions = .fromMode(0o644) })).close(io);
    const shaderc = try tmp.dir.realPathFileAlloc(io, "shaderc", a);
    defer a.free(shaderc);
    try std.Io.Dir.cwd().setFilePermissions(io, shaderc, .fromMode(0o001), .{});

    // Both hosts reject it — the check lives in `preflightWith`, which the
    // cold pipeline, the `--watch` rebuild and `--docker` all route through.
    try std.testing.expectError(error.ShadercOverrideNotExecutable, preflightWith(a, project, shaderc, .native));
    try std.testing.expectError(error.ShadercOverrideNotExecutable, preflightWith(a, project, shaderc, .docker));

    // Positive control on both, so neither rejection is vacuous.
    try std.Io.Dir.cwd().setFilePermissions(io, shaderc, .fromMode(0o755), .{});
    try preflightWith(a, project, shaderc, .native);
    try preflightWith(a, project, shaderc, .docker);
}
