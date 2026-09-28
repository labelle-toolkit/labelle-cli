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

pub const SessionKey = struct {
    /// The replacement's package (`provider.meta.name`).
    package: []const u8,
    /// Its declared version (`.plugins` entry).
    version: []const u8,
    /// Its repository spec, which carries the pin.
    pin: []const u8,
    /// The replacement hook (`<package>/<id>`), with its tool.
    hook: []const u8,
    build_step: []const u8,
    executable: []const u8,
    /// The explicit `.watch = true` capability.
    watch: bool,
    backend: []const u8,
    target: []const u8,
    /// Whether the target comes from `project.labelle` (no `--platform`),
    /// so an edit to the file's `.platform` changes it.
    target_follows_file: bool,
    /// The generated target directory the output is built and published
    /// from (`.labelle/<backend>_<target>`).
    output: []const u8,
    optimize: provider_contract.Optimize,
    /// SHA-256 of the replacement's `provider_config` file, or null.
    settings: ?[32]u8,

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
        return .{
            .package = provider.meta.name,
            .version = provider.dep.version,
            .pin = provider.dep.repo,
            .hook = replacement.qualified,
            .build_step = replacement.hook.build_step,
            .executable = replacement.hook.executable,
            .watch = replacement.hook.watch,
            .backend = backend,
            .target = target,
            .target_follows_file = target_follows_file,
            .output = try outputOf(a, backend, target),
            .optimize = optimize,
            .settings = try settingsDigest(a, root, cfg, provider.meta.name),
        };
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
        if (!eql(self.hook, n.hook) or !eql(self.build_step, n.build_step) or !eql(self.executable, n.executable)) return "the run replacement";
        if (self.watch != n.watch) return "the watch capability";
        if (!eql(self.backend, n.backend)) return "the backend";
        if (!eql(self.target, n.target)) return "the target";
        if (!eql(self.output, n.output)) return "the output location";
        if (self.optimize != n.optimize) return "the effective optimize mode";
        if (!std.meta.eql(self.settings, n.settings)) return "the replacement's settings";
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
        .hook = "pkg/serve",
        .build_step = "tool",
        .executable = "bin/tool",
        .watch = true,
        .backend = "probe",
        .target = "probe-target",
        .target_follows_file = false,
        .output = ".labelle/probe_probe-target",
        .optimize = .ReleaseSafe,
        .settings = null,
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
        .{ .what = "the run replacement", .edit = struct {
            fn f(k: *SessionKey) void {
                k.executable = "bin/other";
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
