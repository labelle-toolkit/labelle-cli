//! A watched rebuild as a transaction, end to end against real projects,
//! manifests and locks (RFC cli#466 §3.4): a failure anywhere after the
//! replan restores the whole previous state (cli#469); an edited
//! `.prebuild` list runs in the rebuild that sees it and swaps the watch
//! ignore set with it (cli#463); a change the running replacement depends
//! on ends the rebuild with the restart diagnostic and publishes nothing;
//! a rebuild publishes only once its `after build` hooks succeeded; and a
//! cancelled rebuild reaps its child. The assembler and the compiler are
//! scripts (`testing.exitTool`), so these tests are POSIX-only; the
//! cancellation test spawns the real child fixture.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const lockfile = @import("../lockfile.zig");
const project_config = @import("../project_config.zig");
const prebuild = @import("../prebuild.zig");
const runner = @import("../runner.zig");
const supervise = @import("../supervise.zig");
const provider_contract = @import("../provider_contract.zig");
const provider_dispatch = @import("../provider_dispatch.zig");
const provider_github = @import("../provider_github.zig");
const provider_hooks = @import("../provider_hooks.zig");
const RebuildCtx = @import("rebuild.zig").RebuildCtx;
const Replanner = @import("rebuild_replan.zig").Replanner;
const SessionKey = @import("session_key.zig").SessionKey;
const testing = @import("testing.zig");

pub const target = "probe-target";

/// A project with one local provider `pkg` owning the target, written in
/// the temporary directory, plus the cold pipeline's startup state.
pub const Fixture = struct {
    a: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    project: [:0]u8,
    ok: [:0]u8,
    fail: [:0]u8,
    /// Stable one-element argvs of the two tools.
    ok_argv: [1][]const u8 = undefined,
    fail_argv: [1][]const u8 = undefined,
    arena: std.heap.ArenaAllocator,
    sources: provider_github.Sources,
    cfg: project_config.ProjectConfig = undefined,
    providers: []const provider_dispatch.Provider = &.{},
    run_plan: provider_hooks.Plan = .{},
    generate_plan: provider_hooks.Plan = .{},
    build_plan: provider_hooks.Plan = .{},

    pub const Spec = struct {
        version: []const u8 = "1.0.0",
        /// Extra `.hooks` records of the manifest.
        hooks: []const u8 = "",
        /// `.target_defaults` records.
        defaults: []const u8 = "",
        /// Extra `project.labelle` fields.
        project_extra: []const u8 = "",
        contract: []const u8 = ">=1.0.0 <2.0.0",
    };

    pub fn init(fx: *Fixture, a: std.mem.Allocator) !void {
        const io = config.globalIo();
        fx.a = a;
        fx.tmp = std.testing.tmpDir(.{});
        try fx.tmp.dir.createDirPath(io, "project");
        try fx.tmp.dir.createDirPath(io, "pkg");
        fx.project = try fx.tmp.dir.realPathFileAlloc(io, "project", a);
        fx.ok = try testing.okTool(a, fx.tmp.dir);
        fx.fail = try testing.exitTool(a, fx.tmp.dir, "fail-tool", 1);
        fx.ok_argv = .{fx.ok};
        fx.fail_argv = .{fx.fail};
        fx.arena = std.heap.ArenaAllocator.init(a);
        fx.sources = .{ .a = fx.arena.allocator() };
    }

    pub fn deinit(fx: *Fixture) void {
        fx.sources.deinit();
        fx.arena.deinit();
        fx.a.free(fx.project);
        fx.a.free(fx.ok);
        fx.a.free(fx.fail);
        fx.tmp.cleanup();
    }

    pub fn write(fx: *Fixture, spec: Spec) !void {
        const io = config.globalIo();
        var buf: [4096]u8 = undefined;
        const manifest = try std.fmt.bufPrint(&buf, ".{{ .name = \"pkg\", .manifest_version = 2, .command_contract = \"{s}\", .targets = .{{ \"{s}\" }}, .target_defaults = .{{ {s} }}, .hooks = .{{ .{{ .id = \"serve\", .step = .run, .target = \"{s}\", .when = .replace, .build_step = \"tool\", .executable = \"bin/tool\", .watch = true }}, {s} }} }}", .{ spec.contract, target, spec.defaults, target, spec.hooks });
        try fx.tmp.dir.writeFile(io, .{ .sub_path = "pkg/plugin.labelle", .data = manifest });
        var pbuf: [2048]u8 = undefined;
        const proj = try std.fmt.bufPrint(&pbuf, ".{{ .name = \"game\", .plugins = .{{ .{{ .name = \"pkg\", .repo = \"local:../pkg\", .version = \"{s}\" }} }}{s} }}", .{ spec.version, spec.project_extra });
        try fx.tmp.dir.writeFile(io, .{ .sub_path = "project/project.labelle", .data = proj });
    }

    /// The cold pipeline: read, lock, discover, plan.
    pub fn startup(fx: *Fixture) !void {
        const sa = fx.arena.allocator();
        fx.cfg = try config.readProjectConfig(sa, fx.project);
        try lockfile.writeLockFile(sa, fx.project, fx.cfg);
        fx.providers = try provider_dispatch.discover(sa, fx.project, fx.cfg, &fx.sources, .populated);
        fx.run_plan = try provider_hooks.plan(sa, fx.providers, .run, target);
        fx.generate_plan = try provider_hooks.plan(sa, fx.providers, .generate, target);
        fx.build_plan = try provider_hooks.plan(sa, fx.providers, .build, target);
    }

    pub fn site(fx: *Fixture) provider_hooks.Site {
        var s = testing.testSite(fx.a, fx.project);
        s.target = target;
        s.providers = fx.providers;
        s.cfg = fx.cfg;
        s.host = .{ .zig = "/z", .cache_root = fx.project, .global_cache = fx.project, .packages = fx.project };
        return s;
    }

    pub fn lockBytes(fx: *Fixture) ![]u8 {
        return fx.tmp.dir.readFileAlloc(config.globalIo(), "project/labelle.lock", fx.a, .limited(1 << 20));
    }
};

/// Records hook invocations in order; `fail_id` exits 7.
pub const Hooks = struct {
    // Copied: the ids live on a generation a rollback releases.
    var bufs: [16][32]u8 = undefined;
    var log: [16][]const u8 = undefined;
    var count: usize = 0;
    var fail_id: []const u8 = "";
    pub fn reset() void {
        count = 0;
        fail_id = "";
    }
    pub fn run(_: *provider_hooks.Site, list: []const provider_hooks.Planned, _: provider_contract.Step, _: provider_contract.Phase, _: []const u8) anyerror!u8 {
        for (list) |planned| {
            const id = planned.hook.id;
            @memcpy(bufs[count][0..id.len], id);
            log[count] = bufs[count][0..id.len];
            count += 1;
            if (std.mem.eql(u8, planned.hook.id, fail_id)) return 7;
        }
        return 0;
    }
    fn saw(id: []const u8) bool {
        for (log[0..count]) |entry| if (std.mem.eql(u8, entry, id)) return true;
        return false;
    }
};

/// Records publications, and which hooks had run by then. Runs the gate
/// as `watch.Publisher` does: before the switch, then the commit point.
pub const Publish = struct {
    pub var count: usize = 0;
    var hooks_at_publish: usize = 0;
    pub var fail = false;
    pub fn reset() void {
        count = 0;
        fail = false;
    }
    pub fn run(_: *anyopaque, gate: @import("../watch.zig").PublishGate) anyerror!void {
        if (fail) return error.DiskFull;
        try gate.before_switch(gate.ctx);
        try gate.before_advance(gate.ctx);
        count += 1;
        hooks_at_publish = Hooks.count;
    }
};

/// Records the prebuild steps each rebuild ran.
pub const Steps = struct {
    // Copied: the steps live on a generation a rollback releases.
    var buf: [32]u8 = undefined;
    var last: []const u8 = "";
    pub var runs: usize = 0;
    pub fn run(_: std.mem.Allocator, _: []const u8, steps: []const prebuild.Step, _: prebuild.Options) prebuild.Error!void {
        runs += 1;
        const name = if (steps.len == 0) "" else steps[0].run[0];
        @memcpy(buf[0..name.len], name);
        last = buf[0..name.len];
    }
};

pub fn rebuildCtx(fx: *Fixture, site: *provider_hooks.Site, replan: *Replanner, dummy: *u8) RebuildCtx {
    return .{
        .allocator = fx.a,
        .asm_bin = .{ .path = fx.ok },
        .project_dir = fx.project,
        .platform_tag = target,
        .backend_tag = "probe",
        .output_dir = fx.project,
        .target_dir = fx.project,
        .zig_args = &fx.ok_argv,
        .zig_env = null,
        .prebuild_steps = fx.cfg.prebuild,
        .prebuild_opts = .{ .fatal_on_step_failure = false },
        .hooks = site,
        .generate_plan = fx.generate_plan,
        .build_plan = fx.build_plan,
        .replan = replan.seam(),
        .publish = .{ .ctx = dummy, .run = Publish.run },
        .run_hook_phase = Hooks.run,
        .run_prebuild = Steps.run,
    };
}

test "rebuild transaction: a failure after the replan restores every replanned piece of state (cli#469)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit();
    try fx.write(.{ .hooks = ".{ .id = \"done-v1\", .step = .run, .target = \"probe-target\", .when = .after, .build_step = \"tool\", .executable = \"bin/tool\" }" });
    try fx.startup();
    var site = fx.site();
    defer site.env.deinit();
    var replan = Replanner{ .backing = a, .project_dir = fx.project };
    defer replan.deinit(&site, fx.providers, fx.cfg);
    replan.baseline();
    var dummy: u8 = 0;
    var ctx = rebuildCtx(&fx, &site, &replan, &dummy);
    defer ctx.deinit();
    const lock_v1 = try fx.lockBytes();
    defer a.free(lock_v1);

    // The edit: a new version, new generate and after-build hooks, a new
    // after-run hook, a target default — and then the compile fails.
    try fx.write(.{
        .version = "2.0.0",
        .hooks = ".{ .id = \"gen-v2\", .step = .generate, .target = \"probe-target\", .when = .before, .build_step = \"tool\", .executable = \"bin/tool\" }, .{ .id = \"post-v2\", .step = .build, .target = \"probe-target\", .when = .after, .build_step = \"tool\", .executable = \"bin/tool\" }, .{ .id = \"done-v2\", .step = .run, .target = \"probe-target\", .when = .after, .build_step = \"tool\", .executable = \"bin/tool\" }",
        .defaults = ".{ .target = \"probe-target\", .optimize = .ReleaseFast }",
    });
    ctx.zig_args = &fx.fail_argv;
    Hooks.reset();
    Publish.reset();
    try std.testing.expectError(error.BuildFailed, ctx.rebuildStaged());
    // The replan ran (its generate hook did), and nothing of it survived:
    try std.testing.expect(Hooks.saw("gen-v2"));
    try std.testing.expectEqual(@as(usize, 0), Publish.count);
    try std.testing.expect(site.providers.ptr == fx.providers.ptr);
    try std.testing.expectEqualStrings("1.0.0", site.cfg.plugins[0].version);
    try std.testing.expectEqual(provider_contract.Optimize.ReleaseSafe, site.optimize);
    try std.testing.expect(ctx.generate_plan.isEmpty());
    try std.testing.expect(ctx.build_plan.isEmpty());
    try std.testing.expectEqualStrings(fx.fail, ctx.zig_args[0]);
    try std.testing.expectEqual(@as(usize, 1), ctx.zig_args.len);
    try std.testing.expect(site.env.isEmpty());
    try std.testing.expect(replan.current == null and replan.staged == null);
    // The lock on disk is the committed one, byte for byte...
    const lock_after = try fx.lockBytes();
    defer a.free(lock_after);
    try std.testing.expectEqualSlices(u8, lock_v1, lock_after);
    // ...and the shutdown runs the committed (startup) after-run hooks.
    const shutdown = replan.shutdownRunAfter(fx.run_plan.after);
    try std.testing.expectEqual(fx.run_plan.after.ptr, shutdown.ptr);
    try std.testing.expectEqualStrings("pkg/done-v1", shutdown[0].qualified);

    // The fix: the same edit now commits, the lock follows, and the
    // shutdown's hooks are the new generation's.
    ctx.zig_args = &fx.ok_argv;
    Hooks.reset();
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(usize, 1), Publish.count);
    try std.testing.expectEqualStrings("2.0.0", site.cfg.plugins[0].version);
    try std.testing.expectEqual(provider_contract.Optimize.ReleaseFast, site.optimize);
    try std.testing.expectEqualStrings("-Doptimize=ReleaseFast", ctx.zig_args[ctx.zig_args.len - 1]);
    try std.testing.expect(replan.current != null and replan.staged == null);
    const lock_v2 = try fx.lockBytes();
    defer a.free(lock_v2);
    try std.testing.expect(!std.mem.eql(u8, lock_v1, lock_v2));
    try std.testing.expectEqualStrings("pkg/done-v2", replan.shutdownRunAfter(fx.run_plan.after)[0].qualified);
}

test "rebuild transaction: publication happens only after the after-build hooks, never after a failure" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit();
    try fx.write(.{ .hooks = ".{ .id = \"stage\", .step = .build, .target = \"probe-target\", .when = .after, .build_step = \"tool\", .executable = \"bin/tool\" }" });
    try fx.startup();
    var site = fx.site();
    defer site.env.deinit();
    var replan = Replanner{ .backing = a, .project_dir = fx.project };
    defer replan.deinit(&site, fx.providers, fx.cfg);
    replan.baseline();
    var dummy: u8 = 0;
    var ctx = rebuildCtx(&fx, &site, &replan, &dummy);
    defer ctx.deinit();

    // Success: published once, after the `after build` hook ran.
    Hooks.reset();
    Publish.reset();
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(usize, 1), Publish.count);
    try std.testing.expect(Hooks.saw("stage"));
    try std.testing.expectEqual(Hooks.count, Publish.hooks_at_publish);
    // A failing compile, a failing after-build hook, a failing publication:
    // nothing is published, and the next good rebuild publishes again.
    ctx.zig_args = &fx.fail_argv;
    try std.testing.expectError(error.BuildFailed, ctx.rebuildStaged());
    ctx.zig_args = &fx.ok_argv;
    Hooks.fail_id = "stage";
    try std.testing.expectError(error.HookFailed, ctx.rebuildStaged());
    Hooks.fail_id = "";
    Publish.fail = true;
    try std.testing.expectError(error.PublishFailed, ctx.rebuildStaged());
    Publish.fail = false;
    try std.testing.expectEqual(@as(usize, 1), Publish.count);
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(usize, 2), Publish.count);
}

test "rebuild transaction: an edited prebuild step runs in the rebuild that sees it, and swaps the ignore set (cli#463)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit();
    try fx.write(.{ .project_extra = ", .prebuild = .{ .{ .run = .{ \"gen-a\" }, .outputs = .{ \"a.out\" } } }" });
    try fx.startup();
    var site = fx.site();
    defer site.env.deinit();
    var replan = Replanner{ .backing = a, .project_dir = fx.project };
    defer replan.deinit(&site, fx.providers, fx.cfg);
    replan.baseline();
    var dummy: u8 = 0;
    var ctx = rebuildCtx(&fx, &site, &replan, &dummy);
    defer ctx.deinit();
    ctx.initIgnore();
    try std.testing.expectEqual(@as(u64, 0), ctx.ignore.epoch);
    try std.testing.expect(std.mem.endsWith(u8, ctx.ignore.files[0], "a.out"));

    // The step changes; this very rebuild runs the NEW step, and the
    // ignore set follows the commit.
    try fx.write(.{ .project_extra = ", .prebuild = .{ .{ .run = .{ \"gen-b\" }, .outputs = .{ \"b.out\" } } }" });
    Steps.runs = 0;
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(usize, 1), Steps.runs);
    try std.testing.expectEqualStrings("gen-b", Steps.last);
    try std.testing.expectEqual(@as(u64, 1), ctx.ignore.epoch);
    // The step's declared output, and the CLI's own `labelle.lock`.
    try std.testing.expectEqual(@as(usize, 2), ctx.ignore.files.len);
    try std.testing.expect(std.mem.endsWith(u8, ctx.ignore.files[0], "b.out"));
    try std.testing.expect(std.mem.endsWith(u8, ctx.ignore.files[1], "labelle.lock"));
    // An unchanged rebuild keeps the set (and its epoch).
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(u64, 1), ctx.ignore.epoch);

    // A step edit whose rebuild fails: the new step ran, but the committed
    // steps and the ignore set stay the previous ones.
    try fx.write(.{ .project_extra = ", .prebuild = .{ .{ .run = .{ \"gen-c\" }, .outputs = .{ \"c.out\" } } }" });
    ctx.zig_args = &fx.fail_argv;
    try std.testing.expectError(error.BuildFailed, ctx.rebuildStaged());
    try std.testing.expectEqualStrings("gen-c", Steps.last);
    try std.testing.expectEqualStrings("gen-b", ctx.prebuild_steps[0].run[0]);
    try std.testing.expectEqual(@as(u64, 1), ctx.ignore.epoch);
    try std.testing.expect(std.mem.endsWith(u8, ctx.ignore.files[0], "b.out"));
}

test "rebuild transaction: a change the running replacement depends on publishes nothing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit();
    try fx.write(.{});
    try fx.startup();
    var site = fx.site();
    defer site.env.deinit();
    // The startup mode with no `--optimize` and no owner default.
    site.optimize = .Debug;
    const key = (try SessionKey.of(fx.arena.allocator(), fx.project, fx.cfg, fx.run_plan, @tagName(fx.cfg.backend), target, false, site.optimize)).?;
    var replan = Replanner{ .backing = a, .project_dir = fx.project, .session = &key };
    defer replan.deinit(&site, fx.providers, fx.cfg);
    replan.baseline();
    var dummy: u8 = 0;
    var ctx = rebuildCtx(&fx, &site, &replan, &dummy);
    defer ctx.deinit();
    const lock_v1 = try fx.lockBytes();
    defer a.free(lock_v1);

    // A script or asset edit (nothing here changes): rebuilds and publishes.
    Publish.reset();
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(usize, 1), Publish.count);

    const Case = struct { spec: Fixture.Spec, prebuild_runs: usize };
    const cases = [_]Case{
        // The provider version (after the prebuild: provider metadata).
        .{ .spec = .{ .version = "2.0.0" }, .prebuild_runs = 1 },
        // The effective optimize mode, through the owner's default.
        .{ .spec = .{ .defaults = ".{ .target = \"probe-target\", .optimize = .ReleaseFast }" }, .prebuild_runs = 1 },
        // The backend: refused before any prebuild step runs.
        .{ .spec = .{ .project_extra = ", .backend = .null" }, .prebuild_runs = 0 },
        // The replacement losing its watch capability.
        .{ .spec = .{ .hooks = "" }, .prebuild_runs = 1 },
        // The provider's negotiated wire falling below run.watch.
        .{ .spec = .{ .contract = ">=1.0.0 <1.3.0" }, .prebuild_runs = 1 },
        // A `before run` hook added: it ran once, before the replacement.
        .{ .spec = .{ .hooks = ".{ .id = \"prepare\", .step = .run, .target = \"probe-target\", .when = .before, .build_step = \"tool\", .executable = \"bin/tool\" }" }, .prebuild_runs = 1 },
        // The Zig version the project requires.
        .{ .spec = .{ .project_extra = ", .zig_version = \"0.99.0\"" }, .prebuild_runs = 1 },
        // The assembler the session resolved at startup.
        .{ .spec = .{ .project_extra = ", .assembler_version = \"0.99.0\"" }, .prebuild_runs = 1 },
    };
    for (cases, 0..) |case, i| {
        try fx.write(case.spec);
        if (i == 3) {
            // Rewrite the manifest's replacement without `.watch`.
            var buf: [1024]u8 = undefined;
            const manifest = try std.fmt.bufPrint(&buf, ".{{ .name = \"pkg\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{{ \"{s}\" }}, .hooks = .{{ .{{ .id = \"serve\", .step = .run, .target = \"{s}\", .when = .replace, .build_step = \"tool\", .executable = \"bin/tool\" }} }} }}", .{ target, target });
            try fx.tmp.dir.writeFile(config.globalIo(), .{ .sub_path = "pkg/plugin.labelle", .data = manifest });
        }
        Steps.runs = 0;
        try std.testing.expectError(error.SessionChanged, ctx.rebuildStaged());
        try std.testing.expectEqual(case.prebuild_runs, Steps.runs);
        try std.testing.expectEqual(@as(usize, 1), Publish.count);
        const lock_now = try fx.lockBytes();
        defer a.free(lock_now);
        try std.testing.expectEqualSlices(u8, lock_v1, lock_now);
        try std.testing.expectEqualStrings("1.0.0", site.cfg.plugins[0].version);
    }
    // Reverting the edit rebuilds and publishes again.
    try fx.write(.{});
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(usize, 2), Publish.count);
}

/// A hook phase that runs the real child fixture, the way `runTool` runs a
/// provider tool: through `runner`, which supervises it on this thread.
const SlowHook = struct {
    var id: []const u8 = "";
    fn run(_: *provider_hooks.Site, list: []const provider_hooks.Planned, _: provider_contract.Step, _: provider_contract.Phase, _: []const u8) anyerror!u8 {
        for (list) |planned| {
            if (!std.mem.eql(u8, planned.hook.id, id)) continue;
            const exe = @import("test_fixtures").child_exe;
            return runner.runZigInheritWithEnv(std.testing.allocator, ".", &.{ exe, "sleep:60000" }, null, null);
        }
        return 0;
    }
};

fn rebuildOnThread(ctx: *RebuildCtx, ok: *bool) void {
    ok.* = RebuildCtx.rebuild(ctx);
}

test "rebuild transaction: cancelling reaps the in-flight child — provisioning, compile, after-build — and publishes nothing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    const exe = @import("test_fixtures").child_exe;
    const Where = enum { provisioning, compile, after_build };
    for ([_]Where{ .provisioning, .compile, .after_build }) |where| {
        var fx: Fixture = undefined;
        try fx.init(a);
        defer fx.deinit();
        try fx.write(.{ .hooks = ".{ .id = \"toolchain\", .step = .generate, .target = \"probe-target\", .when = .before, .build_step = \"tool\", .executable = \"bin/tool\" }, .{ .id = \"stage\", .step = .build, .target = \"probe-target\", .when = .after, .build_step = \"tool\", .executable = \"bin/tool\" }" });
        try fx.startup();
        var site = fx.site();
        defer site.env.deinit();
        var replan = Replanner{ .backing = a, .project_dir = fx.project };
        defer replan.deinit(&site, fx.providers, fx.cfg);
        replan.baseline();
        var dummy: u8 = 0;
        var ctx = rebuildCtx(&fx, &site, &replan, &dummy);
        defer ctx.deinit();
        var group: supervise.Group = .{};
        ctx.group = &group;
        ctx.run_hook_phase = SlowHook.run;
        SlowHook.id = switch (where) {
            .provisioning => "toolchain",
            .after_build => "stage",
            .compile => "",
        };
        const compile_argv = [_][]const u8{ exe, "sleep:60000" };
        if (where == .compile) ctx.zig_args = &compile_argv;
        Publish.reset();

        var ok = true;
        const t = try std.Thread.spawn(.{}, rebuildOnThread, .{ &ctx, &ok });
        // Wait for the event: the slow child is registered in the group.
        const deadline = supervise.monotonicMs() + 30_000;
        while (group.live() == 0 and supervise.monotonicMs() < deadline) std.Thread.yield() catch {};
        try std.testing.expectEqual(@as(usize, 1), group.live());
        group.cancelAndReap(io, 5_000);
        t.join();
        try std.testing.expect(!ok);
        try std.testing.expectEqual(@as(usize, 0), group.live());
        try std.testing.expectEqual(@as(usize, 0), Publish.count);
        try std.testing.expect(replan.current == null and replan.staged == null);
    }
}

test "rebuild transaction: an edited project's lock is staged privately and committed only with the rebuild" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit();
    try fx.write(.{});
    try fx.startup();
    var site = fx.site();
    defer site.env.deinit();
    var replan = Replanner{ .backing = a, .project_dir = fx.project };
    defer replan.deinit(&site, fx.providers, fx.cfg);
    replan.baseline();
    var dummy: u8 = 0;
    var ctx = rebuildCtx(&fx, &site, &replan, &dummy);
    defer ctx.deinit();
    const lock_v1 = try fx.lockBytes();
    defer a.free(lock_v1);
    // What a hook of the rebuild sees: the project's `labelle.lock` (the
    // path the running replacement holds) and the lock it verifies against.
    const Seen = struct {
        var project_lock_has_new = false;
        var staged_has_new = false;
        var project: []const u8 = "";
        fn run(s: *provider_hooks.Site, list: []const provider_hooks.Planned, _: provider_contract.Step, _: provider_contract.Phase, _: []const u8) anyerror!u8 {
            for (list) |planned| if (std.mem.eql(u8, planned.hook.id, "stage-probe")) {
                const io = config.globalIo();
                const lock = try std.fs.path.join(std.testing.allocator, &.{ project, "labelle.lock" });
                defer std.testing.allocator.free(lock);
                const committed = try std.Io.Dir.cwd().readFileAlloc(io, lock, std.testing.allocator, .limited(1 << 20));
                defer std.testing.allocator.free(committed);
                project_lock_has_new = std.mem.indexOf(u8, committed, "\"7.7.7\"") != null;
                const staged = try std.Io.Dir.cwd().readFileAlloc(io, s.lock_path.?, std.testing.allocator, .limited(1 << 20));
                defer std.testing.allocator.free(staged);
                staged_has_new = std.mem.indexOf(u8, staged, "\"7.7.7\"") != null;
            };
            return 0;
        }
    };
    Seen.project = fx.project;
    ctx.run_hook_phase = Seen.run;
    const hook = ".{ .id = \"stage-probe\", .step = .build, .target = \"probe-target\", .when = .after, .build_step = \"tool\", .executable = \"bin/tool\" }";
    try fx.write(.{ .version = "7.7.7", .hooks = hook });
    // A failing compile: during the rebuild the hook saw the new lock only
    // at its private path; afterwards the staged lock is gone and the
    // project's lock never changed.
    ctx.zig_args = &fx.fail_argv;
    try std.testing.expectError(error.BuildFailed, ctx.rebuildStaged());
    const staged_path = try Replanner.stagedLockPath(a, fx.project);
    defer a.free(staged_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(config.globalIo(), staged_path, .{}));
    try std.testing.expect(site.lock_path == null);
    {
        const now = try fx.lockBytes();
        defer a.free(now);
        try std.testing.expectEqualSlices(u8, lock_v1, now);
    }
    // The same edit succeeding: the hook again saw only the staged lock
    // carry the new version; the commit moves it over `labelle.lock`.
    ctx.zig_args = &fx.ok_argv;
    Seen.project_lock_has_new = true;
    Seen.staged_has_new = false;
    try ctx.rebuildStaged();
    try std.testing.expect(!Seen.project_lock_has_new);
    try std.testing.expect(Seen.staged_has_new);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(config.globalIo(), staged_path, .{}));
    try std.testing.expect(site.lock_path == null);
    const committed = try fx.lockBytes();
    defer a.free(committed);
    try std.testing.expect(std.mem.indexOf(u8, committed, "\"7.7.7\"") != null);
}

test "rebuild transaction: a rebuild runs the cold pipeline's pre-passes and prebuild Python wiring on the re-read project" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    // Production wiring: the defaults ARE the cold pipeline's functions.
    const default_prepass = std.meta.fieldInfo(RebuildCtx, .run_prepasses).defaultValue() orelse return error.TestUnexpectedResult;
    try std.testing.expect(default_prepass == @import("generate.zig").corePrepasses);
    const default_wire = std.meta.fieldInfo(RebuildCtx, .wire_prebuild_env).defaultValue() orelse return error.TestUnexpectedResult;
    try std.testing.expect(default_wire == @import("install.zig").wirePrebuildPython);

    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit();
    try fx.write(.{});
    try fx.startup();
    var site = fx.site();
    defer site.env.deinit();
    var replan = Replanner{ .backing = a, .project_dir = fx.project };
    defer replan.deinit(&site, fx.providers, fx.cfg);
    replan.baseline();
    var dummy: u8 = 0;
    var ctx = rebuildCtx(&fx, &site, &replan, &dummy);
    defer ctx.deinit();
    // The assembler appends to a shared log, so the order is observable.
    const log = try std.fs.path.join(a, &.{ fx.project, "..", "order.log" });
    defer a.free(log);
    {
        var buf: [512]u8 = undefined;
        const script = try std.fmt.bufPrint(&buf, "#!/bin/sh\necho assembler >> '{s}'\n", .{log});
        try fx.tmp.dir.writeFile(io, .{ .sub_path = "asm-log", .data = script, .flags = .{ .permissions = .executable_file } });
    }
    const asm_path = try fx.tmp.dir.realPathFileAlloc(io, "asm-log", a);
    defer a.free(asm_path);
    ctx.asm_bin = .{ .path = asm_path };
    const Spy = struct {
        var log_path: []const u8 = "";
        var saw_version: [16]u8 = undefined;
        var saw_len: usize = 0;
        var bake = false;
        var wired_steps: usize = 0;
        var wired_before_prebuild = false;
        var prebuilds: usize = 0;
        fn append(line: []const u8) void {
            const prev = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), log_path, std.testing.allocator, .limited(4096)) catch std.testing.allocator.dupe(u8, "") catch unreachable;
            defer std.testing.allocator.free(prev);
            const next = std.mem.concat(std.testing.allocator, u8, &.{ prev, line, "\n" }) catch unreachable;
            defer std.testing.allocator.free(next);
            std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = log_path, .data = next }) catch unreachable;
        }
        fn prepass(_: std.mem.Allocator, _: []const u8, cfg: project_config.ProjectConfig, opts: @import("generate.zig").Prepass) anyerror!void {
            append("prepass");
            const v = cfg.plugins[0].version;
            @memcpy(saw_version[0..v.len], v);
            saw_len = v.len;
            bake = opts.bake;
        }
        fn wire(_: std.mem.Allocator, steps: []const prebuild.Step) void {
            wired_steps = steps.len;
            wired_before_prebuild = prebuilds == 0;
        }
        fn runPrebuild(_: std.mem.Allocator, _: []const u8, _: []const prebuild.Step, _: prebuild.Options) prebuild.Error!void {
            prebuilds += 1;
        }
    };
    Spy.log_path = log;
    ctx.prepass = .{ .legacy_target = true, .bake = true, .fatal = false };
    ctx.run_prepasses = Spy.prepass;
    ctx.wire_prebuild_env = Spy.wire;
    ctx.run_prebuild = Spy.runPrebuild;
    // The edit bumps the version and ADDS a prebuild step mid-session.
    try fx.write(.{ .version = "3.1.4", .project_extra = ", .prebuild = .{ .{ .run = .{ \"python3\", \"gen.py\" } } }" });
    try ctx.rebuildStaged();
    // The pre-passes ran before the assembler, on the re-read project.
    const order = try std.Io.Dir.cwd().readFileAlloc(io, log, a, .limited(4096));
    defer a.free(order);
    try std.testing.expectEqualStrings("prepass\nassembler\n", order);
    try std.testing.expectEqualStrings("3.1.4", Spy.saw_version[0..Spy.saw_len]);
    try std.testing.expect(Spy.bake);
    // The new step got the Python wiring before it first ran.
    try std.testing.expectEqual(@as(usize, 1), Spy.wired_steps);
    try std.testing.expect(Spy.wired_before_prebuild);
    try std.testing.expectEqual(@as(usize, 1), Spy.prebuilds);
}

test "rebuild transaction: a before-run hook's OWNING provider changing is a session change" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit();
    // A second local package, `aux`, attaches a `before run` hook to the
    // target it does not own.
    try fx.tmp.dir.createDirPath(io, "aux");
    try fx.tmp.dir.writeFile(io, .{ .sub_path = "aux/plugin.labelle", .data = ".{ .name = \"aux\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .hooks = .{ .{ .id = \"prepare\", .step = .run, .target = \"probe-target\", .when = .before, .build_step = \"tool\", .executable = \"bin/tool\" } } }" });
    const Project = struct {
        fn write(dir: std.Io.Dir, aux_version: []const u8) !void {
            var buf: [1024]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, ".{{ .name = \"game\", .plugins = .{{ .{{ .name = \"pkg\", .repo = \"local:../pkg\", .version = \"1.0.0\" }}, .{{ .name = \"aux\", .repo = \"local:../aux\", .version = \"{s}\" }} }} }}", .{aux_version});
            try dir.writeFile(config.globalIo(), .{ .sub_path = "project/project.labelle", .data = text });
        }
    };
    try fx.write(.{});
    try Project.write(fx.tmp.dir, "1.0.0");
    try fx.startup();
    try std.testing.expectEqualStrings("aux/prepare", fx.run_plan.before[0].qualified);
    var site = fx.site();
    defer site.env.deinit();
    // The startup mode with no `--optimize` and no owner default.
    site.optimize = .Debug;
    const key = (try SessionKey.of(fx.arena.allocator(), fx.project, fx.cfg, fx.run_plan, @tagName(fx.cfg.backend), target, false, site.optimize)).?;
    var replan = Replanner{ .backing = a, .project_dir = fx.project, .session = &key };
    defer replan.deinit(&site, fx.providers, fx.cfg);
    replan.baseline();
    var dummy: u8 = 0;
    var ctx = rebuildCtx(&fx, &site, &replan, &dummy);
    defer ctx.deinit();
    Publish.reset();
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(usize, 1), Publish.count);
    // Only `aux`'s version changes: the hook id and tool are the same, the
    // replacement's own provider is untouched.
    try Project.write(fx.tmp.dir, "2.0.0");
    try std.testing.expectError(error.SessionChanged, ctx.rebuildStaged());
    try std.testing.expectEqual(@as(usize, 1), Publish.count);
}
