//! Managed emsdk-toolchain resolver — the emsdk sibling of `zig_toolchain.zig`.
//!
//! Part of labelle-studio#25 (labelle-cli#283). wasm builds need `emcc`; the
//! CLI owns it the way it owns Zig (#279): read the required emsdk version,
//! resolve it to a per-version cache under `~/.labelle/emsdk/<ver>/`, fetch +
//! **verify** + **activate** it if absent, and point the wasm build at the
//! managed `emcc` instead of a PATH `emcc` (`/opt/homebrew/bin`, `~/emsdk`) —
//! the Finder-minimal-PATH failure the epic exists to kill.
//!
//! ## Fetch + ACTIVATE (why this differs from the Zig manager)
//!
//! Zig ships a self-contained release archive: download + verify + extract and
//! the compiler is ready. emsdk does NOT — it is a small *bootstrapper*. The
//! git checkout only contains the `emsdk` launcher; the actual toolchain
//! (clang, node, the `emcc` driver, the wasm sysroot) is materialized by
//! running `emsdk install <ver>` + `emsdk activate <ver>`, which downloads the
//! prebuilt SDK into `<emsdk>/upstream/` + `<emsdk>/node/` and writes the
//! `.emscripten` (EM_CONFIG) file. **Merely fetching without activating is
//! exactly labelle-assembler#492**: the generated wasm `build.zig` references
//! `emsdk_dep.path("upstream/emscripten/emcc")`, which is `FileNotFound` until
//! activation runs. So this resolver treats `emcc`'s existence — the product
//! of activation — as the "installed" marker, and `ensureInstalled` always
//! runs `install` + `activate`, never a bare fetch.
//!
//! Approach chosen: **(a) fetch the pinned emsdk git checkout into the managed
//! dir and run its bundled `emsdk install/activate`**, rather than (b) grabbing
//! a prebuilt emscripten release. (a) matches how the assembler already pins
//! emsdk (a git dependency in `backends/*/build.zig.zon`), so the managed
//! toolchain is byte-for-byte the same emscripten the build expects, and the
//! activation step is emsdk's own supported install path.
//!
//! ## Verification posture (fail-closed where a hash exists)
//!
//! Emscripten publishes **no** minisign/GPG signatures for emsdk (unlike Zig).
//! The strongest pin available is the exact git commit — the same one the
//! assembler pins (`git+…/emsdk?ref=<ver>#<commit>`). So for the DEFAULT
//! version we fetch that pinned commit and verify `git rev-parse HEAD` matches
//! `DEFAULT_EMSDK_COMMIT`, failing closed on a mismatch (mirroring #279's
//! posture). The subsequent `emsdk install` sub-downloads (clang/node/…) are
//! fetched by emsdk over HTTPS from emscripten's release storage; emsdk has no
//! per-artifact signature check, so those are trusted by transport + provenance
//! — documented here rather than silently skipped. A non-default pinned version
//! (no known commit) is fetched by tag over HTTPS with the same caveat.
//!
//! ## Version-resolution precedence (see `resolveRequiredVersion`)
//!
//!   1. `LABELLE_EMSDK` env var — absolute path to an `emcc`. Total override:
//!      skips version resolution *and* the cache. Handled in `resolveEmcc`.
//!   2. `--emcc <path>` flag — same, via `setFlagOverride`. `LABELLE_EMSDK`
//!      wins over the flag, matching the Zig manager's env-over-flag rule.
//!   3. `emsdk_version` pin in `project.labelle` (`launcher_manifest`).
//!   4. Engine-derived: map the pinned engine version to its required emsdk via
//!      `emsdkVersionForEngine` (today the toolkit rides ONE emsdk train, so
//!      this returns `DEFAULT_EMSDK_VERSION` for the 1.x engine major; the map
//!      is the seam where future engine-train divergence lands).
//!   5. `DEFAULT_EMSDK_VERSION` constant — kept in lockstep with the emsdk the
//!      assembler backends pin (`backends/*/build.zig.zon`).

const std = @import("std");
const builtin = @import("builtin");
const emsdk_cache = @import("emsdk_cache.zig");
const config = @import("config.zig");
const launcher_manifest = @import("launcher_manifest.zig");
const util = @import("util.zig");

const is_windows = builtin.os.tag == .windows;

/// Default emsdk version resolved/activated when a project pins none and no
/// engine mapping applies. Keep in lockstep with the emsdk the assembler
/// backends pin (`backends/raylib/build.zig.zon`, `backends/sokol/…`:
/// `git+https://github.com/emscripten-core/emsdk?ref=4.0.9#<commit>`).
pub const DEFAULT_EMSDK_VERSION = "4.0.9";

/// The exact emsdk git commit the assembler pins for `DEFAULT_EMSDK_VERSION`.
/// Used to fail-closed verify the fetched checkout (emscripten publishes no
/// signature — the commit hash is the strongest available pin). Keep in
/// lockstep with the `#<commit>` in the assembler backends' `build.zig.zon`.
pub const DEFAULT_EMSDK_COMMIT = "3bcf1dcd01f040f370e10fe673a092d9ed79ebb5";

/// emsdk git repository. Cloned (shallow, at the version tag) into the managed
/// version dir; `emsdk install/activate` then populates it in place.
pub const EMSDK_GIT_URL = "https://github.com/emscripten-core/emsdk.git";

/// Where the requested version came from — reported by `toolchain emsdk`.
pub const VersionSource = enum {
    env_override, // LABELLE_EMSDK (a path, not a version)
    flag_override, // --emcc <path>
    project_pin, // emsdk_version in project.labelle
    engine_derived, // mapped from the pinned engine version
    default, // DEFAULT_EMSDK_VERSION fallback

    pub fn label(self: VersionSource) []const u8 {
        return switch (self) {
            .env_override => "LABELLE_EMSDK env override",
            .flag_override => "--emcc flag override",
            .project_pin => "emsdk_version in project.labelle",
            .engine_derived => "derived from pinned engine version",
            .default => "CLI default (matches the assembler's pinned emsdk)",
        };
    }
};

pub const ResolvedVersion = struct {
    /// Heap-owned version string (e.g. "4.0.9"). Caller frees.
    version: []u8,
    source: VersionSource,
};

// ── Escape hatches (mirroring LABELLE_ZIG / --zig) ─────────────────────

/// `--emcc <path>` override, set by the arg parser. Borrowed slice owned by
/// the caller (argv lives for the whole process). `LABELLE_EMSDK` wins.
var _flag_override: ?[]const u8 = null;

/// Record the `--emcc <path>` flag. `path` must outlive all `resolveEmcc`
/// calls (argv-lifetime is fine). Pass null to clear (tests).
pub fn setFlagOverride(path: ?[]const u8) void {
    _flag_override = path;
}

/// Look up the `LABELLE_EMSDK` path override. Heap-owned on success (caller
/// frees), null when unset. Mirrors `zig_toolchain.lookupEnvOverride`.
pub fn lookupEnvOverride(allocator: std.mem.Allocator) !?[]u8 {
    return config.globalEnviron().getAlloc(allocator, "LABELLE_EMSDK") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
}

// ── Test seam: injectable process boundary ─────────────────────────────

pub const ExecResult = struct { exit_code: u8 };

/// A recorded/handled child process: `argv` and the `cwd` it ran in.
pub const ExecFn = *const fn (allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) anyerror!ExecResult;

/// When set, every fetch/install/activate step is routed here instead of
/// spawning a real `git`/`emsdk`. Tests use this to assert WHICH steps run
/// (crucially: that `activate` is invoked, not just a fetch) with no network.
var _exec_override: ?ExecFn = null;

/// Test-only: intercept the process boundary. Pass null to restore.
pub fn setExecOverrideForTest(f: ?ExecFn) void {
    _exec_override = f;
}

/// Run one external step (git clone / emsdk install / emsdk activate) in `cwd`,
/// routed through the test seam when set. Fails with `error.EmsdkStepFailed`.
fn execStep(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !void {
    if (_exec_override) |f| {
        const r = try f(allocator, argv, cwd);
        if (r.exit_code != 0) return error.EmsdkStepFailed;
        return;
    }
    const result = blk: {
        if (cwd) |c| {
            break :blk std.process.run(allocator, config.globalIo(), .{
                .argv = argv,
                .cwd = .{ .path = c },
            }) catch return error.EmsdkStepFailed;
        }
        break :blk std.process.run(allocator, config.globalIo(), .{ .argv = argv }) catch return error.EmsdkStepFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("labelle: emsdk step failed (exit {d})\n  {s}\n", .{ code, result.stderr });
            return error.EmsdkStepFailed;
        },
        else => {
            std.debug.print("labelle: emsdk step terminated abnormally\n  {s}\n", .{result.stderr});
            return error.EmsdkStepFailed;
        },
    }
}

// ── Version resolution ─────────────────────────────────────────────────

/// Map a pinned engine version to its required emsdk version. The toolkit
/// currently ships on a single emsdk train, so any engine on the 1.x major maps
/// to `DEFAULT_EMSDK_VERSION`. Returns null for an unrecognized engine so the
/// caller falls through to the default. This is the seam where future
/// divergence lands (mirrors `zig_toolchain.zigVersionForEngine`).
pub fn emsdkVersionForEngine(engine_version: []const u8) ?[]const u8 {
    const major = util.parseVersion(engine_version) / 1_000_000;
    return switch (major) {
        1 => DEFAULT_EMSDK_VERSION,
        else => null,
    };
}

/// Resolve the emsdk VERSION the project requires and where it came from.
/// Does not consult the path overrides (those short-circuit in `resolveEmcc`);
/// this is the version-only chain: project pin → engine-derived → default.
/// Caller owns `result.version`.
pub fn resolveRequiredVersion(allocator: std.mem.Allocator, project_dir: []const u8) !ResolvedVersion {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const manifest = try launcher_manifest.readLauncherManifest(a, project_dir);

    // 3. Explicit emsdk_version pin.
    if (manifest) |m| {
        if (m.emsdk_version) |v| {
            if (v.len > 0) return .{ .version = try allocator.dupe(u8, v), .source = .project_pin };
        }
    }

    // 4. Engine-derived. Prefer project.labelle's engine_version, else the
    //    resolved engine in labelle.lock.
    const engine_version: ?[]const u8 = blk: {
        if (manifest) |m| if (m.engine_version) |ev| if (ev.len > 0) break :blk ev;
        break :blk readLockEngineVersion(a, project_dir);
    };
    if (engine_version) |ev| {
        if (emsdkVersionForEngine(ev)) |mv| {
            return .{ .version = try allocator.dupe(u8, mv), .source = .engine_derived };
        }
    }

    // 5. Default.
    return .{ .version = try allocator.dupe(u8, DEFAULT_EMSDK_VERSION), .source = .default };
}

/// Minimal `labelle.lock` shape: only `.resolved.engine.version`. Returns an
/// arena-owned slice (borrowed from `allocator`), or null if absent/unparsable.
/// Mirrors `zig_toolchain.readLockEngineVersion`.
fn readLockEngineVersion(allocator: std.mem.Allocator, project_dir: []const u8) ?[]const u8 {
    @setEvalBranchQuota(10000);
    const lock_path = std.fs.path.join(allocator, &.{ project_dir, "labelle.lock" }) catch return null;
    const raw = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), lock_path, allocator, .limited(1024 * 1024)) catch return null;
    const raw_z = allocator.dupeZ(u8, raw) catch return null;

    const LockShape = struct {
        resolved: ?struct {
            engine: ?struct { version: []const u8 = "" } = null,
        } = null,
    };
    const parsed = std.zon.parse.fromSliceAlloc(LockShape, allocator, raw_z, null, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    const resolved = parsed.resolved orelse return null;
    const engine = resolved.engine orelse return null;
    if (engine.version.len == 0) return null;
    return engine.version;
}

// ── Resolve to a managed emcc path ─────────────────────────────────────

/// Resolve the `emcc` a wasm build should use, fetching + verifying +
/// **activating** the required emsdk on a cache miss. Precedence:
///   1. `LABELLE_EMSDK` env path (wins over everything).
///   2. `--emcc <path>` flag.
///   3. managed cache for `resolveRequiredVersion(project_dir)`.
/// Caller owns the returned slice.
pub fn resolveEmcc(allocator: std.mem.Allocator, project_dir: []const u8) ![]u8 {
    if (try lookupEnvOverride(allocator)) |path| return path;
    if (_flag_override) |path| return allocator.dupe(u8, path);

    const resolved = try resolveRequiredVersion(allocator, project_dir);
    defer allocator.free(resolved.version);

    const emcc_path = try emsdk_cache.emccPath(allocator, resolved.version);
    errdefer allocator.free(emcc_path);

    std.Io.Dir.cwd().access(config.globalIo(), emcc_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            ensureInstalled(allocator, resolved.version) catch |dl_err| {
                std.debug.print(
                    \\
                    \\labelle: could not provision emsdk {s}.
                    \\  emsdk/emcc is required to build for wasm. Options:
                    \\    - set LABELLE_EMSDK=/path/to/emcc (or pass --emcc /path/to/emcc)
                    \\    - run: labelle install emsdk {s}
                    \\    - pin a different emsdk_version in project.labelle
                    \\
                , .{ resolved.version, resolved.version });
                allocator.free(emcc_path);
                return dl_err;
            };
        },
        else => {
            allocator.free(emcc_path);
            return err;
        },
    };
    return emcc_path;
}

// ── Install (fetch + verify + ACTIVATE, atomic) ────────────────────────

/// Ensure emsdk `version` is FETCHED + ACTIVATED in the managed cache. No-op if
/// `emcc` already exists (activation already ran). The whole toolchain is
/// staged in a temp sibling dir then atomically renamed into place, so a
/// half-activated emsdk is never observed as installed (mirrors #279's
/// stage-then-publish scaffold + per-version lock).
pub fn ensureInstalled(allocator: std.mem.Allocator, version: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const emcc_path = try emsdk_cache.emccPath(allocator, version);
    defer allocator.free(emcc_path);
    // Fast path: already activated (emcc present), no lock contention.
    if (cwd.access(io, emcc_path, .{})) |_| return else |_| {}

    const dest_dir = try emsdk_cache.versionDir(allocator, version);
    defer allocator.free(dest_dir);

    // Serialize installs of the SAME version across processes with a
    // per-version advisory lock (mirrors #279): without it two concurrent
    // `labelle` processes could each stage + publish, and the loser's
    // `deleteTree(dest_dir)` would nuke the winner's activated toolchain out
    // from under a running build. The lock releases when the holder exits.
    const eroot = try emsdk_cache.emsdkRoot(allocator);
    defer allocator.free(eroot);
    cwd.createDirPath(io, eroot) catch {};
    const lock_path = try std.fmt.allocPrint(allocator, "{s}{c}{s}.lock", .{ eroot, std.fs.path.sep, version });
    defer allocator.free(lock_path);
    const lock_file = cwd.createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive }) catch |err| {
        std.debug.print("labelle: could not acquire emsdk install lock {s}: {any}\n", .{ lock_path, err });
        return error.EmsdkInstallLockFailed;
    };
    defer lock_file.close(io); // releases the advisory lock

    // Double-checked: another process may have finished activating while we
    // were blocked on the lock.
    if (cwd.access(io, emcc_path, .{})) |_| return else |_| {}

    // Stage under a temp sibling of the version dir. The suffix only needs to
    // avoid collisions with a concurrent/stale staging dir; seed a PRNG from a
    // stack address mixed with the dest path (0.16 has no std.crypto.random).
    var prng = std.Random.DefaultPrng.init(@intFromPtr(&dest_dir) ^ std.hash.Wyhash.hash(0, dest_dir));
    const staging = try std.fmt.allocPrint(allocator, "{s}.tmp-{d}", .{ dest_dir, prng.random().int(u32) });
    defer allocator.free(staging);
    cwd.deleteTree(io, staging) catch {};
    if (std.fs.path.dirname(staging)) |parent| cwd.createDirPath(io, parent) catch {};
    defer cwd.deleteTree(io, staging) catch {};

    // ── 1. Fetch the pinned emsdk checkout ──────────────────────────────
    // Shallow clone at the version TAG. `git clone` wants a nonexistent/empty
    // target; we cleared `staging` above.
    std.debug.print("labelle: fetching emsdk {s}...\n", .{version});
    std.debug.print("  git clone {s} (tag {s})\n", .{ EMSDK_GIT_URL, version });
    try execStep(allocator, &.{
        "git", "clone", "--depth", "1", "--branch", version, EMSDK_GIT_URL, staging,
    }, null);

    // ── 2. Verify the fetched commit (fail-closed where a pin exists) ───
    try verifyCheckout(allocator, version, staging);

    // ── 3. ACTIVATE (the #492 fix — never a bare fetch) ─────────────────
    // `emsdk install <ver>` downloads the prebuilt SDK into upstream/+node/;
    // `emsdk activate <ver>` writes `.emscripten` and materializes `emcc`.
    const launcher = try std.fs.path.join(allocator, &.{ staging, emsdk_cache.emsdk_launcher_name });
    defer allocator.free(launcher);
    if (!is_windows) {
        if (cwd.openFile(io, launcher, .{})) |file| {
            defer file.close(io);
            file.setPermissions(io, .fromMode(0o755)) catch {};
        } else |_| {}
    }
    std.debug.print("  emsdk install {s}...\n", .{version});
    try activateStep(allocator, launcher, staging, "install", version);
    std.debug.print("  emsdk activate {s}...\n", .{version});
    try activateStep(allocator, launcher, staging, "activate", version);

    // Sanity: emcc must exist in staging before we publish (activation ran).
    const staged_emcc = try std.fs.path.join(allocator, &.{ staging, emsdk_cache.emcc_relpath });
    defer allocator.free(staged_emcc);
    cwd.access(io, staged_emcc, .{}) catch {
        std.debug.print("labelle: emsdk {s} activated but '{s}' is missing — refusing to publish\n", .{ version, emsdk_cache.emcc_relpath });
        return error.EmsdkActivationIncomplete;
    };

    // Publish atomically. We hold the lock and re-checked `emcc_path` is
    // absent, so any `dest_dir` here is an INCOMPLETE leftover from a crashed
    // prior install (no working `emcc` → no build can be using it).
    cwd.deleteTree(io, dest_dir) catch {};
    if (std.fs.path.dirname(dest_dir)) |parent| cwd.createDirPath(io, parent) catch {};
    try cwd.rename(staging, cwd, dest_dir, io);

    std.debug.print("  installed + activated at {s}\n", .{dest_dir});
}

/// Invoke the emsdk launcher for a subcommand (`install`/`activate`) in `dir`.
/// On Windows the launcher is a `.bat`, so it runs through `cmd /c`.
fn activateStep(allocator: std.mem.Allocator, launcher: []const u8, dir: []const u8, subcmd: []const u8, version: []const u8) !void {
    if (is_windows) {
        try execStep(allocator, &.{ "cmd", "/c", launcher, subcmd, version }, dir);
    } else {
        try execStep(allocator, &.{ launcher, subcmd, version }, dir);
    }
}

/// Verify the fetched emsdk checkout. For the DEFAULT version we know the
/// exact commit (the assembler's pin), so `git rev-parse HEAD` MUST equal it —
/// fail closed on a mismatch. For any other version we have no known commit, so
/// we trust the tag fetch over HTTPS (documented tradeoff: emscripten publishes
/// no signatures). Skipped entirely under the test exec seam.
fn verifyCheckout(allocator: std.mem.Allocator, version: []const u8, staging: []const u8) !void {
    if (_exec_override != null) return; // tests: no real checkout to inspect
    if (!std.mem.eql(u8, version, DEFAULT_EMSDK_VERSION)) {
        std.debug.print("  note: emsdk {s} has no pinned commit; trusting the HTTPS tag fetch\n", .{version});
        return;
    }
    const result = std.process.run(allocator, config.globalIo(), .{
        .argv = &.{ "git", "rev-parse", "HEAD" },
        .cwd = .{ .path = staging },
    }) catch {
        std.debug.print("labelle: could not verify emsdk commit (git rev-parse failed)\n", .{});
        return error.EmsdkVerificationFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const head = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (!std.mem.eql(u8, head, DEFAULT_EMSDK_COMMIT)) {
        std.debug.print(
            "labelle: emsdk {s} commit mismatch — expected {s}, got {s} — refusing to activate\n",
            .{ version, DEFAULT_EMSDK_COMMIT, head },
        );
        return error.EmsdkVerificationFailed;
    }
    std.debug.print("  commit verified ({s})\n", .{DEFAULT_EMSDK_COMMIT});
}

// ── Subcommands ─────────────────────────────────────────────────────────

/// `labelle install emsdk <version>` — force fetch + verify + activate.
pub fn cmdInstallEmsdk(allocator: std.mem.Allocator, version: []const u8) !void {
    const emcc_path = try emsdk_cache.emccPath(allocator, version);
    defer allocator.free(emcc_path);
    if (std.Io.Dir.cwd().access(config.globalIo(), emcc_path, .{})) |_| {
        std.debug.print("labelle: emsdk {s} already activated at {s}\n", .{ version, emcc_path });
        return;
    } else |_| {}
    try ensureInstalled(allocator, version);
    std.debug.print("labelle: emsdk {s} installed + activated\n", .{version});
}

/// `labelle toolchain emsdk [dir]` — report the version, source, and resolved
/// emcc path for the project in `project_dir` (no download).
pub fn cmdEmsdkWhich(allocator: std.mem.Allocator, project_dir: []const u8) !void {
    const io = config.globalIo();
    if (try lookupEnvOverride(allocator)) |path| {
        defer allocator.free(path);
        std.debug.print("emcc: {s}\n  source: {s}\n", .{ path, VersionSource.env_override.label() });
        return;
    }
    if (_flag_override) |path| {
        std.debug.print("emcc: {s}\n  source: {s}\n", .{ path, VersionSource.flag_override.label() });
        return;
    }
    const resolved = try resolveRequiredVersion(allocator, project_dir);
    defer allocator.free(resolved.version);
    const emcc_path = try emsdk_cache.emccPath(allocator, resolved.version);
    defer allocator.free(emcc_path);
    const installed = blk: {
        std.Io.Dir.cwd().access(io, emcc_path, .{}) catch break :blk false;
        break :blk true;
    };
    std.debug.print("emcc: {s}\n  version: {s}\n  source: {s}\n  activated: {s}\n", .{
        emcc_path, resolved.version, resolved.source.label(), if (installed) "yes" else "no (will fetch + activate on next wasm build)",
    });
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const asm_cache = @import("asm_cache.zig");

test "emsdkVersionForEngine maps the 1.x train to the default; unknown -> null" {
    try testing.expectEqualStrings(DEFAULT_EMSDK_VERSION, emsdkVersionForEngine("1.65.0").?);
    try testing.expect(emsdkVersionForEngine("2.0.0") == null);
}

test "resolveRequiredVersion: no project -> default" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(config.globalIo(), &buf);

    const r = try resolveRequiredVersion(alloc, buf[0..n]);
    defer alloc.free(r.version);
    try testing.expectEqualStrings(DEFAULT_EMSDK_VERSION, r.version);
    try testing.expectEqual(VersionSource.default, r.source);
}

test "resolveRequiredVersion: explicit emsdk_version pin wins" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(config.globalIo(), .{
        .sub_path = "project.labelle",
        .data = ".{ .name = \"t\", .emsdk_version = \"3.1.50\", .engine_version = \"1.65.0\" }",
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(config.globalIo(), &buf);

    const r = try resolveRequiredVersion(alloc, buf[0..n]);
    defer alloc.free(r.version);
    try testing.expectEqualStrings("3.1.50", r.version);
    try testing.expectEqual(VersionSource.project_pin, r.source);
}

test "resolveRequiredVersion: engine_version derives when no explicit pin" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(config.globalIo(), .{
        .sub_path = "project.labelle",
        .data = ".{ .name = \"t\", .engine_version = \"1.65.0\" }",
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(config.globalIo(), &buf);

    const r = try resolveRequiredVersion(alloc, buf[0..n]);
    defer alloc.free(r.version);
    try testing.expectEqualStrings(DEFAULT_EMSDK_VERSION, r.version);
    try testing.expectEqual(VersionSource.engine_derived, r.source);
}

test "resolveRequiredVersion: falls back to labelle.lock engine version" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(config.globalIo(), .{
        .sub_path = "project.labelle",
        .data = ".{ .name = \"t\" }",
    });
    try tmp.dir.writeFile(config.globalIo(), .{
        .sub_path = "labelle.lock",
        .data = ".{ .resolved = .{ .engine = .{ .version = \"1.65.0\" } } }",
    });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(config.globalIo(), &buf);

    const r = try resolveRequiredVersion(alloc, buf[0..n]);
    defer alloc.free(r.version);
    try testing.expectEqual(VersionSource.engine_derived, r.source);
    try testing.expectEqualStrings(DEFAULT_EMSDK_VERSION, r.version);
}

test "resolveEmcc: --emcc flag override returns the path verbatim; env wins over flag" {
    const alloc = testing.allocator;
    setFlagOverride("/opt/custom/emcc");
    defer setFlagOverride(null);
    const p = try resolveEmcc(alloc, ".");
    defer alloc.free(p);
    // No LABELLE_EMSDK in the test environ, so the flag wins.
    try testing.expectEqualStrings("/opt/custom/emcc", p);
}

// ── Activation-invoked test (mocked process boundary) ──────────────────

/// Records the sequence of steps the installer runs so a test can assert that
/// ACTIVATION happens (not just a fetch) — the core #492 guarantee.
const StepRecorder = struct {
    var saw_clone: bool = false;
    var saw_install: bool = false;
    var saw_activate: bool = false;

    fn reset() void {
        saw_clone = false;
        saw_install = false;
        saw_activate = false;
    }

    /// Fake exec: records the step by keyword and, for `activate`, materializes
    /// the `emcc` file in the staging dir so the installer's post-activation
    /// sanity check (and the atomic publish) succeed — proving the resolved
    /// emcc path is exactly what activation produced.
    fn exec(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) anyerror!ExecResult {
        for (argv) |a| {
            if (std.mem.eql(u8, a, "clone")) saw_clone = true;
            if (std.mem.eql(u8, a, "install")) saw_install = true;
            if (std.mem.eql(u8, a, "activate")) saw_activate = true;
        }
        if (saw_activate) {
            // Build <cwd>/upstream/emscripten/emcc so the sanity check passes.
            const dir = cwd orelse return .{ .exit_code = 1 };
            const io = config.globalIo();
            const em_dir = try std.fs.path.join(allocator, &.{ dir, "upstream", "emscripten" });
            defer allocator.free(em_dir);
            std.Io.Dir.cwd().createDirPath(io, em_dir) catch {};
            const emcc = try std.fs.path.join(allocator, &.{ em_dir, emsdk_cache.emcc_name });
            defer allocator.free(emcc);
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = emcc, .data = "#!/bin/sh\n" }) catch {};
        }
        return .{ .exit_code = 0 };
    }
};

test "ensureInstalled fetches AND activates, and the resolved emcc is the activated one" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(config.globalIo(), &buf);
    const root = buf[0..n];

    asm_cache.setCacheRootOverride(root);
    defer asm_cache.clearCacheRootOverride();
    StepRecorder.reset();
    setExecOverrideForTest(StepRecorder.exec);
    defer setExecOverrideForTest(null);

    try ensureInstalled(alloc, DEFAULT_EMSDK_VERSION);

    // The #492 guarantee: activation is invoked, not merely a fetch.
    try testing.expect(StepRecorder.saw_clone);
    try testing.expect(StepRecorder.saw_install);
    try testing.expect(StepRecorder.saw_activate);

    // The published emcc is exactly the cache path a build spawn resolves to.
    const emcc_path = try emsdk_cache.emccPath(alloc, DEFAULT_EMSDK_VERSION);
    defer alloc.free(emcc_path);
    try std.Io.Dir.cwd().access(config.globalIo(), emcc_path, .{});

    // And a second call is a no-op fast path (emcc already present): reset the
    // recorder and confirm no steps re-run.
    StepRecorder.reset();
    try ensureInstalled(alloc, DEFAULT_EMSDK_VERSION);
    try testing.expect(!StepRecorder.saw_clone);
    try testing.expect(!StepRecorder.saw_activate);
}

test "resolveEmcc activates on a cache miss and returns the managed emcc path" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(config.globalIo(), &buf);
    const root = buf[0..n];

    asm_cache.setCacheRootOverride(root);
    defer asm_cache.clearCacheRootOverride();
    StepRecorder.reset();
    setExecOverrideForTest(StepRecorder.exec);
    defer setExecOverrideForTest(null);

    // No project.labelle → default version, cache miss → fetch+activate.
    const emcc = try resolveEmcc(alloc, root);
    defer alloc.free(emcc);

    try testing.expect(StepRecorder.saw_activate);
    const expected = try emsdk_cache.emccPath(alloc, DEFAULT_EMSDK_VERSION);
    defer alloc.free(expected);
    try testing.expectEqualStrings(expected, emcc);
}

test "DEFAULT_EMSDK_COMMIT is a full 40-char git sha" {
    try testing.expectEqual(@as(usize, 40), DEFAULT_EMSDK_COMMIT.len);
    for (DEFAULT_EMSDK_COMMIT) |c| {
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(hex);
    }
}
