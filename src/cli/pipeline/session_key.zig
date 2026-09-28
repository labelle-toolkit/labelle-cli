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
    backend: []const u8,
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
        return .{
            .package = provider.meta.name,
            .version = provider.dep.version,
            .pin = try pinOf(a, root, provider.dep),
            .wire = wire,
            .hook = replacement.qualified,
            .build_step = replacement.hook.build_step,
            .executable = replacement.hook.executable,
            .watch = replacement.hook.watch,
            .before_run = before.items,
            .backend = backend,
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
        if (!eql(self.wire, n.wire)) return "the provider contract version";
        if (!eql(self.hook, n.hook) or !eql(self.build_step, n.build_step) or !eql(self.executable, n.executable)) return "the run replacement";
        if (self.watch != n.watch) return "the watch capability";
        if (!eql(self.before_run, n.before_run)) return "the before-run hooks";
        if (!eql(self.backend, n.backend)) return "the backend";
        if (!eql(self.target, n.target)) return "the target";
        if (!eql(self.output, n.output)) return "the output location";
        if (self.optimize != n.optimize) return "the effective optimize mode";
        if (!optEql(self.settings_path, n.settings_path) or !std.meta.eql(self.settings, n.settings)) return "the replacement's settings";
        if (!eql(self.zig, n.zig)) return "the Zig version";
        if (!eql(self.assembler, n.assembler)) return "the assembler version";
        return null;
    }

    /// The config-level half, drawn from `project.labelle` alone before any
    /// prebuild step runs: the backend, and the target when the file picks
    /// it.
    pub fn configChanged(self: SessionKey, cfg: project_config.ProjectConfig) ?[]const u8 {
        if (!eql(self.backend, @tagName(cfg.backend))) return "the backend";
        if (self.target_follows_file and !eql(self.target, @tagName(cfg.platform))) return "the target";
        return null;
    }

    /// Print the restart diagnostic for `what`.
    pub fn report(what: []const u8) error{SessionChanged} {
        std.debug.print("labelle: restart labelle run --watch: {s} changed\n" ++
            "  the running replacement keeps the configuration it started with; this rebuild published nothing\n", .{what});
        return error.SessionChanged;
    }
};

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
    key.backend = @tagName(cfg.backend);
    key.target = "probe-target";
    try std.testing.expect(key.configChanged(cfg) == null);
    key.target_follows_file = true;
    try std.testing.expectEqualStrings("the target", key.configChanged(cfg).?);
    key.backend = "other";
    try std.testing.expectEqualStrings("the backend", key.configChanged(cfg).?);
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
