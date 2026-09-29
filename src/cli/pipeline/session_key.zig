//! What a running watch-session replacement depends on (RFC cli#466 §3.4
//! "session-change rules"). The replacement keeps the configuration it was
//! started with, so a rebuild whose replan changes any of these must not
//! publish: it ends with `restart labelle run --watch: <what> changed`.
//! Script, asset and build-only configuration changes rebuild normally.
const std = @import("std");
const config = @import("../config.zig");
const project_config = @import("../project_config.zig");
const provider_contract = @import("../provider_contract.zig");
const provider_dispatch = @import("../provider_dispatch.zig");
const provider_hooks = @import("../provider_hooks.zig");
const provider_github = @import("../provider_github.zig");
const provider_manifest = @import("../provider_manifest.zig");
const zig_toolchain = @import("../zig_toolchain.zig");
const tree = @import("../watch/tree.zig");

pub const SessionKey = struct {
    /// The replacement's package (`provider.meta.name`).
    package: []const u8,
    /// Its declared version (`.plugins` entry).
    version: []const u8,
    /// The verified pin: for a remote provider the commit and archive
    /// SHA-256 `labelle.providers.lock` accepted for it (a lock update to
    /// other bytes for the same package, repository and version changes
    /// it); for a local provider its repository spec (`pinOf`).
    pin: []const u8,
    /// SHA-256 of the sources of the LOCAL providers the replacement runs
    /// from — its own and its `before run` hooks' owners — which built its
    /// tools at startup; `null` when none is local (a remote one is pinned
    /// by `pin`). An edit to them is a change: the replacement keeps the
    /// binary it started with (cli#474). `localSourceDigest` says what is
    /// hashed.
    source: ?[32]u8 = null,
    /// The wire version negotiated from the provider's `command_contract`.
    wire: []const u8,
    /// The replacement hook (`<package>/<id>`), with its tool.
    hook: []const u8,
    build_step: []const u8,
    executable: []const u8,
    /// The explicit `.watch = true` capability.
    watch: bool,
    /// The `before run` hooks, which ran once before the replacement
    /// started and are never re-run by a rebuild: per hook, in plan order,
    /// its id, tool, and its owning provider's version, verified pin,
    /// negotiated wire and `provider_config` mapping.
    before_run: []const u8,
    /// The backend package's name as `labelle-assembler describe` resolved
    /// it (cli#471 D4): the CLI reads no `.backend` of its own.
    backend: []const u8,
    /// The explicit `.backend_package`'s name, "" when none. It names the
    /// generated target dir (`describe`'s `target_dir`, cli#471 D3), and the
    /// session builds and publishes the dir it started with, so a renamed
    /// package is a change. Its version is not: a bump regenerates into the
    /// same dir.
    backend_package: []const u8 = "",
    target: []const u8,
    /// Whether the target comes from `project.labelle` (no `--platform`),
    /// so an edit to the file's `.platform` changes it.
    target_follows_file: bool,
    /// The generated target directory the output is built and published
    /// from (`.labelle/<backend>_<target>`).
    output: []const u8,
    optimize: provider_contract.Optimize,
    /// The replacement's `provider_config` file (project-relative, as
    /// mapped), which it received as `config_file`, and the SHA-256 of its
    /// bytes; null when unmapped.
    settings_path: ?[]const u8,
    settings: ?[32]u8,
    /// The Zig version the project requires (`zig_version`, else derived
    /// from the engine): the compiler the session resolved at startup.
    zig: []const u8,
    /// The `assembler_version` pin: the session resolved its assembler at
    /// startup and every rebuild generates with it.
    assembler: []const u8,

    /// The key of a replanned configuration: its `run` plan's replacement,
    /// the backend and target it builds, and the effective optimize mode.
    /// `null` when the plan has no replacement at all.
    pub fn of(
        a: std.mem.Allocator,
        root: []const u8,
        cfg: project_config.ProjectConfig,
        run_plan: provider_hooks.Plan,
        backend: []const u8,
        target: []const u8,
        target_follows_file: bool,
        optimize: provider_contract.Optimize,
    ) !?SessionKey {
        const replacement = run_plan.replace orelse return null;
        const provider = replacement.provider.*;
        // Each `before run` hook with its OWNING provider's identity: a
        // hook of another package whose version, pin, wire or settings
        // mapping changed ran, at startup, as the old one.
        var before: std.ArrayList(u8) = .empty;
        for (run_plan.before) |planned| {
            const owner = planned.provider.*;
            const owner_wire: []const u8 = if (owner.meta.command_contract) |range| provider_manifest.negotiate(range) catch "none" else "none";
            const owner_settings: []const u8 = for (cfg.provider_config) |entry| {
                if (std.mem.eql(u8, entry.package, owner.meta.name)) break entry.file;
            } else "";
            try before.print(a, "{s}|{s}|{s}|{s}|{s}|{s}|{s};", .{
                planned.qualified, planned.hook.build_step,       planned.hook.executable,
                owner.dep.version, try pinOf(a, root, owner.dep), owner_wire,
                owner_settings,
            });
        }
        const settings_path: ?[]const u8 = for (cfg.provider_config) |entry| {
            if (std.mem.eql(u8, entry.package, provider.meta.name)) break entry.file;
        } else null;
        const wire: []const u8 = if (provider.meta.command_contract) |range| provider_manifest.negotiate(range) catch "none" else "none";
        const zig = try zig_toolchain.resolveRequiredVersion(a, root);
        var local_dirs: std.ArrayList([]const u8) = .empty;
        if (provider.dep.isLocal()) try local_dirs.append(a, provider.dir);
        for (run_plan.before) |planned| {
            const owner = planned.provider.*;
            if (!owner.dep.isLocal()) continue;
            for (local_dirs.items) |seen| {
                if (std.mem.eql(u8, seen, owner.dir)) break;
            } else try local_dirs.append(a, owner.dir);
        }
        return .{
            .package = provider.meta.name,
            .version = provider.dep.version,
            .pin = try pinOf(a, root, provider.dep),
            .source = if (local_dirs.items.len == 0) null else try localSourceDigest(a, local_dirs.items, root),
            .wire = wire,
            .hook = replacement.qualified,
            .build_step = replacement.hook.build_step,
            .executable = replacement.hook.executable,
            .watch = replacement.hook.watch,
            .before_run = before.items,
            .backend = backend,
            .backend_package = backendPackageName(cfg),
            .target = target,
            .target_follows_file = target_follows_file,
            .output = try outputOf(a, backend, target),
            .optimize = optimize,
            .settings_path = settings_path,
            .settings = try settingsDigest(a, root, cfg, provider.meta.name),
            .zig = zig.version,
            .assembler = cfg.assembler_version orelse "",
        };
    }

    /// The pin a key records for `dep`: `<repo>@<commit>#<sha256>` from the
    /// accepted `labelle.providers.lock` entry matching it, else the repo
    /// spec (a local provider, or a remote one no lock names yet).
    pub fn pinOf(a: std.mem.Allocator, root: []const u8, dep: project_config.PluginDep) ![]const u8 {
        const path = try std.fs.path.join(a, &.{ root, provider_github.lock_name });
        const bytes = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, a, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return dep.repo,
            else => return err,
        };
        const doc = try provider_github.parse(a, bytes, true);
        for (doc.providers) |pin| {
            if (pin.matches(dep)) return std.fmt.allocPrint(a, "{s}@{s}#{s}", .{ pin.repo, pin.commit, pin.sha256 });
        }
        return dep.repo;
    }

    /// `.labelle/<backend>_<target>`: the output location a key names.
    pub fn outputOf(a: std.mem.Allocator, backend: []const u8, target: []const u8) ![]const u8 {
        const name = try std.fmt.allocPrint(a, "{s}_{s}", .{ backend, target });
        return std.fs.path.join(a, &.{ ".labelle", name });
    }

    /// What a replanned configuration changed that the running replacement
    /// depends on, in the order the diagnostic reports; `null` when nothing.
    /// `next == null`: the replanned project has no replacement any more.
    pub fn changed(self: SessionKey, next: ?SessionKey) ?[]const u8 {
        const n = next orelse return "the run replacement";
        if (!eql(self.package, n.package)) return "the provider package";
        if (!eql(self.version, n.version)) return "the provider version";
        if (!eql(self.pin, n.pin)) return "the provider pin";
        if (!std.meta.eql(self.source, n.source)) return "the provider source";
        if (!eql(self.wire, n.wire)) return "the provider contract version";
        if (!eql(self.hook, n.hook) or !eql(self.build_step, n.build_step) or !eql(self.executable, n.executable)) return "the run replacement";
        if (self.watch != n.watch) return "the watch capability";
        if (!eql(self.before_run, n.before_run)) return "the before-run hooks";
        if (!eql(self.backend, n.backend)) return "the backend";
        if (!eql(self.backend_package, n.backend_package)) return "the backend package";
        if (!eql(self.target, n.target)) return "the target";
        if (!eql(self.output, n.output)) return "the output location";
        if (self.optimize != n.optimize) return "the effective optimize mode";
        if (!optEql(self.settings_path, n.settings_path) or !std.meta.eql(self.settings, n.settings)) return "the replacement's settings";
        if (!eql(self.zig, n.zig)) return "the Zig version";
        if (!eql(self.assembler, n.assembler)) return "the assembler version";
        return null;
    }

    /// The config-level half, drawn from `project.labelle` before any
    /// prebuild step runs: the backend (`backend`, the name `describe`
    /// resolves for the file as it now is), its package's name, and the
    /// target when the file picks it.
    pub fn configChanged(self: SessionKey, cfg: project_config.ProjectConfig, backend: []const u8) ?[]const u8 {
        if (!eql(self.backend, backend)) return "the backend";
        if (!eql(self.backend_package, backendPackageName(cfg))) return "the backend package";
        if (self.target_follows_file and !eql(self.target, cfg.declared_target)) return "the target";
        return null;
    }

    /// The `backend_package` a key records for `cfg`.
    pub fn backendPackageName(cfg: project_config.ProjectConfig) []const u8 {
        return if (cfg.backend_package) |bp| bp.name else "";
    }

    /// Print the restart diagnostic for `what`.
    pub fn report(what: []const u8) error{SessionChanged} {
        std.debug.print("labelle: restart labelle run --watch: {s} changed\n" ++
            "  the running replacement keeps the configuration it started with; this rebuild published nothing\n", .{what});
        return error.SessionChanged;
    }
};

/// SHA-256 over the files of the local provider trees `dirs`, in order:
/// per file, its path relative to its tree, its size and its bytes, files
/// sorted by that path. Walked with the watcher's skip rules (dot
/// directories, build output, nested checkouts), so what is hashed is what
/// the watch session watches; each tree's `plugin.labelle` is left out —
/// what the manifest declares is compared field by field above, and a
/// manifest edit the replacement does not depend on (a new `build` hook)
/// must stay an ordinary rebuild. Symbolic links are not followed. The
/// project directory `project` is never entered: a provider that contains
/// the project (`local:../..`) is hashed without it, or every script edit
/// would read as a provider change. A file or directory that disappears
/// during the walk (an editor saving through a temporary file it renames
/// away) is absent, not an error: the digest is best effort like the
/// watcher's walk, and the next edit is seen anyway.
pub fn localSourceDigest(a: std.mem.Allocator, dirs: []const []const u8, project: []const u8) ![32]u8 {
    var chunk: [64 * 1024]u8 = undefined;
    return localSourceDigestWith(a, dirs, project, null, &chunk);
}

/// Test seam: runs between collecting a tree's files and reading them.
const Between = *const fn ([]const u8, []const []const u8) void;

/// Files are streamed through `chunk`, so any size hashes in constant
/// memory; a test passes a tiny one.
fn localSourceDigestWith(a: std.mem.Allocator, dirs: []const []const u8, project: []const u8, between: ?Between, chunk: []u8) ![32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (dirs) |dir| {
        var files: std.ArrayList([]const u8) = .empty;
        defer {
            for (files.items) |f| a.free(f);
            files.deinit(a);
        }
        try collectSources(a, dir, "", project, &files);
        std.mem.sort([]const u8, files.items, {}, struct {
            fn lessThan(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lessThan);
        if (between) |hook| hook(dir, files.items);
        hash.update(dir);
        hash.update(&.{0});
        for (files.items) |rel| {
            const path = try std.fs.path.join(a, &.{ dir, rel });
            defer a.free(path);
            const io = config.globalIo();
            const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer file.close(io);
            hash.update(rel);
            hash.update(&.{0});
            // The bytes, then their length: framed, whatever the size.
            var total: u64 = 0;
            while (true) {
                const n = try file.readPositionalAll(io, chunk, total);
                hash.update(chunk[0..n]);
                total += n;
                if (n < chunk.len) break;
            }
            var size: [8]u8 = undefined;
            std.mem.writeInt(u64, &size, total, .little);
            hash.update(&size);
        }
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn collectSources(a: std.mem.Allocator, top: []const u8, rel: []const u8, project: []const u8, out: *std.ArrayList([]const u8)) !void {
    const io = config.globalIo();
    const abs = if (rel.len == 0) try a.dupe(u8, top) else try std.fs.path.join(a, &.{ top, rel });
    defer a.free(abs);
    // Below the tree's top, a directory is never entered through a link
    // (one swapped in mid-walk included).
    var dir = std.Io.Dir.cwd().openDir(io, abs, .{ .iterate = true, .follow_symlinks = rel.len == 0 }) catch |err| switch (err) {
        // A subdirectory renamed away (or replaced) mid-walk; the tree
        // itself must exist.
        error.FileNotFound, error.SymLinkLoop, error.NotDir => if (rel.len != 0) return else return err,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const sub = if (rel.len == 0) try a.dupe(u8, entry.name) else try std.fs.path.join(a, &.{ rel, entry.name });
        var owned = true;
        defer if (owned) a.free(sub);
        const kind = tree.entryKind(io, dir, entry) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        switch (kind) {
            .directory => {
                if (tree.skipWatchDir(entry.name)) continue;
                const sub_abs = try std.fs.path.join(a, &.{ top, sub });
                defer a.free(sub_abs);
                if (std.mem.eql(u8, sub_abs, project)) continue;
                if (tree.isNestedCheckout(io, a, sub_abs)) continue;
                try collectSources(a, top, sub, project, out);
            },
            .file => {
                if (rel.len == 0 and std.mem.eql(u8, entry.name, "plugin.labelle")) continue;
                // One spelling on every host, so the order is the same.
                std.mem.replaceScalar(u8, sub, '\\', '/');
                try out.append(a, sub);
                owned = false;
            },
            else => {},
        }
    }
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn optEql(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    return eql(x.?, y.?);
}

fn settingsDigest(a: std.mem.Allocator, root: []const u8, cfg: project_config.ProjectConfig, package: []const u8) !?[32]u8 {
    for (cfg.provider_config) |entry| {
        if (!std.mem.eql(u8, entry.package, package)) continue;
        const path = try std.fs.path.join(a, &.{ root, entry.file });
        defer a.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, a, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            // A missing file is its own state: creating it is a change.
            error.FileNotFound => return [_]u8{0} ** 32,
            else => return err,
        };
        defer a.free(bytes);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        return digest;
    }
    return null;
}

test "session key: every field the replacement depends on is reported, the first first" {
    const base: SessionKey = .{
        .package = "pkg",
        .version = "1.0.0",
        .pin = "local:../pkg",
        .wire = "1.3.0",
        .hook = "pkg/serve",
        .build_step = "tool",
        .executable = "bin/tool",
        .watch = true,
        .before_run = "",
        .backend = "probe",
        .target = "probe-target",
        .target_follows_file = false,
        .output = ".labelle/probe_probe-target",
        .optimize = .ReleaseSafe,
        .settings_path = null,
        .settings = null,
        .zig = "0.16.0",
        .assembler = "",
    };
    try std.testing.expect(base.changed(base) == null);
    try std.testing.expectEqualStrings("the run replacement", base.changed(null).?);
    const Case = struct { what: []const u8, edit: *const fn (*SessionKey) void };
    const cases = [_]Case{
        .{ .what = "the provider package", .edit = struct {
            fn f(k: *SessionKey) void {
                k.package = "other";
            }
        }.f },
        .{ .what = "the provider version", .edit = struct {
            fn f(k: *SessionKey) void {
                k.version = "1.1.0";
            }
        }.f },
        .{ .what = "the provider pin", .edit = struct {
            fn f(k: *SessionKey) void {
                k.pin = "github:o/r#sha256-x";
            }
        }.f },
        .{ .what = "the provider source", .edit = struct {
            fn f(k: *SessionKey) void {
                k.source = [_]u8{2} ** 32;
            }
        }.f },
        .{ .what = "the provider contract version", .edit = struct {
            fn f(k: *SessionKey) void {
                k.wire = "1.2.0";
            }
        }.f },
        .{ .what = "the run replacement", .edit = struct {
            fn f(k: *SessionKey) void {
                k.executable = "bin/other";
            }
        }.f },
        .{ .what = "the before-run hooks", .edit = struct {
            fn f(k: *SessionKey) void {
                k.before_run = "pkg/prepare|tool|bin/tool;";
            }
        }.f },
        .{ .what = "the watch capability", .edit = struct {
            fn f(k: *SessionKey) void {
                k.watch = false;
            }
        }.f },
        .{ .what = "the backend", .edit = struct {
            fn f(k: *SessionKey) void {
                k.backend = "other";
            }
        }.f },
        .{ .what = "the backend package", .edit = struct {
            fn f(k: *SessionKey) void {
                k.backend_package = "acme";
            }
        }.f },
        .{ .what = "the target", .edit = struct {
            fn f(k: *SessionKey) void {
                k.target = "other";
            }
        }.f },
        .{ .what = "the output location", .edit = struct {
            fn f(k: *SessionKey) void {
                k.output = ".labelle/elsewhere";
            }
        }.f },
        .{ .what = "the effective optimize mode", .edit = struct {
            fn f(k: *SessionKey) void {
                k.optimize = .Debug;
            }
        }.f },
        .{ .what = "the replacement's settings", .edit = struct {
            fn f(k: *SessionKey) void {
                k.settings = [_]u8{1} ** 32;
            }
        }.f },
        .{
            .what = "the replacement's settings",
            .edit = struct {
                fn f(k: *SessionKey) void {
                    // Remapped to another file with the same bytes.
                    k.settings_path = "providers/other.json";
                }
            }.f,
        },
        .{ .what = "the assembler version", .edit = struct {
            fn f(k: *SessionKey) void {
                k.assembler = "0.99.0";
            }
        }.f },
        .{ .what = "the Zig version", .edit = struct {
            fn f(k: *SessionKey) void {
                k.zig = "0.17.0";
            }
        }.f },
    };
    for (cases) |case| {
        var next = base;
        case.edit(&next);
        try std.testing.expectEqualStrings(case.what, base.changed(next).?);
    }
    // The config-level half: the backend always, the target only when the
    // file picks it.
    const cfg: project_config.ProjectConfig = .{ .name = "game" };
    var key = base;
    key.backend = "probe";
    key.target = "probe-target";
    try std.testing.expect(key.configChanged(cfg, "probe") == null);
    key.target_follows_file = true;
    try std.testing.expectEqualStrings("the target", key.configChanged(cfg, "probe").?);
    try std.testing.expectEqualStrings("the backend", key.configChanged(cfg, "other").?);
}

test "session key: renaming .backend_package asks for a restart (cli#471 D3)" {
    // The generated dir follows the package name (`describe`), so the edit
    // Codex found on #504 — same enum tag, a differently named package —
    // would otherwise generate into a new dir while the session keeps
    // building and publishing the old one.
    const started: project_config.ProjectConfig = .{ .name = "game", .backend_package = .{ .name = "acme", .repo = "github.com/acme/labelle-acme", .version = "1.0.0" } };
    var key = std.mem.zeroInit(SessionKey, .{ .backend = "probe", .backend_package = SessionKey.backendPackageName(started) });
    try std.testing.expect(key.configChanged(started, "probe") == null);
    // A version bump regenerates into the same dir: an ordinary rebuild.
    var bumped = started;
    bumped.backend_package.?.version = "1.1.0";
    try std.testing.expect(key.configChanged(bumped, "probe") == null);
    // Renamed, or dropped back to the enum's own package: a restart.
    var renamed = started;
    renamed.backend_package.?.name = "other";
    try std.testing.expectEqualStrings("the backend package", key.configChanged(renamed, "probe").?);
    var dropped = started;
    dropped.backend_package = null;
    try std.testing.expectEqualStrings("the backend package", key.configChanged(dropped, "probe").?);
    // The full key reports it too.
    var next = key;
    next.backend_package = "other";
    try std.testing.expectEqualStrings("the backend package", key.changed(next).?);
    key.backend_package = "";
    try std.testing.expect(key.configChanged(.{ .name = "game" }, "probe") == null);
}

test "session key: a remote provider's pin is the accepted lock entry, so a re-pin is a change" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", aa);
    const remote: project_config.PluginDep = .{ .name = "pkg", .repo = "github.com/example/pkg", .version = "1.0.0" };
    const local: project_config.PluginDep = .{ .name = "local", .repo = "local:../local", .version = "1.0.0" };
    // No lock: the declaration.
    try std.testing.expectEqualStrings("github.com/example/pkg", try SessionKey.pinOf(aa, root, remote));
    const Lock = struct {
        fn write(dir: std.Io.Dir, sha_digit: u8) !void {
            var sha: [64]u8 = undefined;
            @memset(&sha, sha_digit);
            var buf: [512]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, "{{\"schema_version\":1,\"providers\":[{{\"package\":\"pkg\",\"repo\":\"example/pkg\",\"version\":\"1.0.0\",\"commit\":\"1111111111111111111111111111111111111111\",\"sha256\":\"{s}\"}}]}}", .{&sha});
            try dir.writeFile(config.globalIo(), .{ .sub_path = provider_github.lock_name, .data = text });
        }
    };
    try Lock.write(tmp.dir, '2');
    const first = try SessionKey.pinOf(aa, root, remote);
    try std.testing.expect(std.mem.indexOf(u8, first, "1111111111111111111111111111111111111111#2222") != null);
    // The lock accepts other bytes for the same package, repo and version.
    try Lock.write(tmp.dir, '3');
    const second = try SessionKey.pinOf(aa, root, remote);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    // A local provider is not in the lock: its declaration.
    try std.testing.expectEqualStrings("local:../local", try SessionKey.pinOf(aa, root, local));
}

test "session key: a local provider's source digest covers its files, not its manifest or build output (cli#474)" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pkg/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/plugin.labelle", .data = ".{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/src/tool.zig", .data = "v1" });
    const dir = try tmp.dir.realPathFileAlloc(io, "pkg", a);
    defer a.free(dir);
    const dirs = [_][]const u8{dir};
    const first = try localSourceDigest(a, &dirs, "");
    // Build output, caches and the manifest are not the source.
    try tmp.dir.createDirPath(io, "pkg/zig-out/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/zig-out/bin/tool", .data = "binary" });
    try tmp.dir.createDirPath(io, "pkg/.zig-cache");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/.zig-cache/obj", .data = "obj" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/plugin.labelle", .data = ".{ .name = \"pkg\" }" });
    try std.testing.expectEqualSlices(u8, &first, &(try localSourceDigest(a, &dirs, "")));
    // A same-size edit to a source file is a change (content, not mtime).
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/src/tool.zig", .data = "v2" });
    const edited = try localSourceDigest(a, &dirs, "");
    try std.testing.expect(!std.mem.eql(u8, &first, &edited));
    // So is a new file; reverting everything restores the digest.
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/src/tool.zig", .data = "v1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/src/extra.zig", .data = "" });
    try std.testing.expect(!std.mem.eql(u8, &first, &(try localSourceDigest(a, &dirs, ""))));
    try tmp.dir.deleteFile(io, "pkg/src/extra.zig");
    try std.testing.expectEqualSlices(u8, &first, &(try localSourceDigest(a, &dirs, "")));
}

test "session key: a source file renamed away during the digest walk is absent, not an error (cli#474)" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pkg/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/src/keep.zig", .data = "keep" });
    const dir = try tmp.dir.realPathFileAlloc(io, "pkg", a);
    defer a.free(dir);
    const dirs = [_][]const u8{dir};
    const without = try localSourceDigest(a, &dirs, "");
    // An editor's temporary file: listed by the walk, gone when read.
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/src/keep.zig~", .data = "tmp" });
    const Vanish = struct {
        var seen = false;
        fn between(top: []const u8, files: []const []const u8) void {
            for (files) |rel| if (std.mem.eql(u8, rel, "src/keep.zig~")) {
                const path = std.fs.path.join(std.testing.allocator, &.{ top, rel }) catch return;
                defer std.testing.allocator.free(path);
                std.Io.Dir.cwd().deleteFile(config.globalIo(), path) catch return;
                seen = true;
            };
        }
    };
    var chunk: [4096]u8 = undefined;
    const got = try localSourceDigestWith(a, &dirs, "", Vanish.between, &chunk);
    // The seam really removed a listed file, and the digest is the tree's
    // without it.
    try std.testing.expect(Vanish.seen);
    try std.testing.expectEqualSlices(u8, &without, &got);
}

test "session key: a provider containing the project is hashed without the project (cli#474)" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "mono/game");
    try tmp.dir.writeFile(io, .{ .sub_path = "mono/tool.zig", .data = "tool" });
    try tmp.dir.writeFile(io, .{ .sub_path = "mono/game/main.zig", .data = "v1" });
    const mono = try tmp.dir.realPathFileAlloc(io, "mono", a);
    defer a.free(mono);
    const project = try tmp.dir.realPathFileAlloc(io, "mono/game", a);
    defer a.free(project);
    const dirs = [_][]const u8{mono};
    const first = try localSourceDigest(a, &dirs, project);
    // A project edit is not a provider-source change...
    try tmp.dir.writeFile(io, .{ .sub_path = "mono/game/main.zig", .data = "v2" });
    try std.testing.expectEqualSlices(u8, &first, &(try localSourceDigest(a, &dirs, project)));
    // ...an edit to the provider around it is.
    try tmp.dir.writeFile(io, .{ .sub_path = "mono/tool.zig", .data = "tool2" });
    try std.testing.expect(!std.mem.eql(u8, &first, &(try localSourceDigest(a, &dirs, project))));
}

test "session key: provider files are hashed in chunks, whatever their size (cli#476)" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pkg");
    // A file many chunks long, and one exactly a chunk long.
    const big = try a.alloc(u8, 10_000);
    defer a.free(big);
    for (big, 0..) |*b, i| b.* = @intCast(i % 251);
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/big.bin", .data = big });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/even.bin", .data = big[0..64] });
    const dir = try tmp.dir.realPathFileAlloc(io, "pkg", a);
    defer a.free(dir);
    const dirs = [_][]const u8{dir};
    var tiny: [64]u8 = undefined;
    var huge: [32 * 1024]u8 = undefined;
    const streamed = try localSourceDigestWith(a, &dirs, "", null, &tiny);
    const whole = try localSourceDigestWith(a, &dirs, "", null, &huge);
    try std.testing.expectEqualSlices(u8, &whole, &streamed);
    // A change past the first chunks is still seen.
    big[9_999] +%= 1;
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/big.bin", .data = big });
    try std.testing.expect(!std.mem.eql(u8, &streamed, &(try localSourceDigestWith(a, &dirs, "", null, &tiny))));
}
