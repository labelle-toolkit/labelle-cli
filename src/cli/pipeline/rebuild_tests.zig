//! Tests of `RebuildCtx` (`rebuild.zig`): the stage order, the hook
//! phases, the replan seam, the transaction (cli#469), cancellation and
//! publication.
const std = @import("std");
const config = @import("../config.zig");
const prebuild = @import("../prebuild.zig");
const material_toolchain = @import("../material_toolchain.zig");
const supervise = @import("../supervise.zig");
const provider_contract = @import("../provider_contract.zig");
const provider_dispatch = @import("../provider_dispatch.zig");
const provider_hooks = @import("../provider_hooks.zig");
const provider_env = @import("../provider_env.zig");
const RebuildCtx = @import("rebuild.zig").RebuildCtx;
const testing = @import("testing.zig");

test "watched rebuild gates the shader override after the before-generate hooks and before generate" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);

    // Production wiring: the default IS the cold pipeline's preflight,
    // not a copy of it.
    const default_gate = std.meta.fieldInfo(RebuildCtx, .shader_preflight).defaultValue() orelse return error.TestUnexpectedResult;
    try std.testing.expect(default_gate == material_toolchain.preflight);

    const Fixture = struct {
        fn invalidOverride(alloc: std.mem.Allocator, dir: []const u8) anyerror!void {
            // The same gate `preflight` reaches, with the env read
            // replaced by a known-bad value.
            return material_toolchain.preflightWith(alloc, dir, "shaderc", .native);
        }
    };
    // No assembler exists at this path, so reaching generation is
    // observable as GenerateFailed — distinct from the gate firing.
    const asm_path = try a.dupe(u8, "/nonexistent/labelle-assembler-probe");
    defer a.free(asm_path);
    var site = testing.testSite(a, project);
    var ctx = RebuildCtx{
        .allocator = a,
        .asm_bin = .{ .path = asm_path },
        .project_dir = project,
        .platform_tag = "probe-target",
        .output_dir = project,
        .target_dir = project,
        .zig_args = &.{},
        .zig_env = null,
        .prebuild_steps = &.{},
        .prebuild_opts = .{ .fatal_on_step_failure = false },
        .shader_preflight = Fixture.invalidOverride,
        .hooks = &site,
    };
    defer ctx.deinit();

    // Started WITHOUT materials/: the invalid override is not consulted
    // and the rebuild proceeds to generation (which fails for its own
    // reason here). This is the cold-start shape that skipped the gate.
    try std.testing.expectError(error.GenerateFailed, ctx.rebuildStaged());

    // A `before generate` hook creates materials/: the gate runs AFTER
    // that phase, so this very rebuild stops at the preflight, before
    // generation is attempted (Codex P2 on #420).
    const Hook = struct {
        var materials: []const u8 = "";
        var ran = false;
        fn run(_: *provider_hooks.Site, _: []const provider_hooks.Planned, _: provider_contract.Step, phase: provider_contract.Phase, _: []const u8) anyerror!u8 {
            if (phase == .before) {
                ran = true;
                try std.Io.Dir.cwd().createDirPath(config.globalIo(), materials);
            }
            return 0;
        }
        var provider: provider_dispatch.Provider = .{
            .dep = .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
            .dir = "/pkg",
            .meta = .{ .name = "pkg", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0" },
            .verified = true,
        };
    };
    Hook.materials = try std.fs.path.join(a, &.{ project, "materials" });
    defer a.free(Hook.materials);
    ctx.run_hook_phase = Hook.run;
    ctx.generate_plan = .{ .before = &.{.{
        .provider = &Hook.provider,
        .hook = .{ .id = "gen", .step = .generate, .target = "probe-target", .when = .before, .build_step = "tool", .executable = "bin/tool" },
        .qualified = "pkg/gen",
    }} };
    try std.testing.expectError(error.ShaderPreflightFailed, ctx.rebuildStaged());
    try std.testing.expect(Hook.ran);

    // materials/ stays: every later rebuild stops at the preflight too.
    ctx.generate_plan = .{};
    try std.testing.expectError(error.ShaderPreflightFailed, ctx.rebuildStaged());
    try std.testing.expect(!RebuildCtx.rebuild(@ptrCast(&ctx)));
}

// The serve loop is interactive (it blocks until Ctrl+C), so the hook
// phases of a WATCHED rebuild are proven here, on the context itself,
// rather than by the subprocess e2e: the phases run in contract order
// around the core steps, a `replace` plan stands in for the core step,
// and a failing hook stops the rebuild before the next stage.
test "watched rebuild runs the generate and build hook phases in order" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);

    // Production wiring: the default runner IS the cold pipeline's.
    const default_runner = std.meta.fieldInfo(RebuildCtx, .run_hook_phase).defaultValue() orelse return error.TestUnexpectedResult;
    try std.testing.expect(default_runner == provider_hooks.runPhase);

    const Spy = struct {
        const Call = struct { step: provider_contract.Step, phase: provider_contract.Phase, id: []const u8, out: []const u8 };
        var calls: [8]Call = undefined;
        var count: usize = 0;
        fn reset() void {
            count = 0;
        }
        fn run(_: *provider_hooks.Site, list: []const provider_hooks.Planned, step: provider_contract.Step, phase: provider_contract.Phase, out: []const u8) anyerror!u8 {
            for (list) |planned| {
                calls[count] = .{ .step = step, .phase = phase, .id = planned.hook.id, .out = out };
                count += 1;
                if (std.mem.eql(u8, planned.hook.id, "fail")) return 7;
                if (std.mem.eql(u8, planned.hook.id, "unpinned")) return error.RemoteProviderIntegrityRequired;
            }
            return 0;
        }
        fn expectCalls(expected: []const Call) !void {
            try std.testing.expectEqual(expected.len, count);
            for (expected, calls[0..count]) |want, got| {
                try std.testing.expectEqual(want.step, got.step);
                try std.testing.expectEqual(want.phase, got.phase);
                try std.testing.expectEqualStrings(want.id, got.id);
                try std.testing.expectEqualStrings(want.out, got.out);
            }
        }
    };
    const Fixture = struct {
        var provider: provider_dispatch.Provider = .{
            .dep = .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
            .dir = "/pkg",
            .meta = .{ .name = "pkg", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0" },
            .verified = true,
        };
        fn planned(id: []const u8, step: provider_contract.Step, when: provider_contract.Phase) provider_hooks.Planned {
            return .{
                .provider = &provider,
                .hook = .{ .id = id, .step = step, .target = "probe-target", .when = when, .build_step = "tool", .executable = "bin/tool" },
                .qualified = id,
            };
        }
    };

    // No assembler and no compiler exist at these paths, so the core
    // steps are observable as GenerateFailed / ZigSpawnFailed —
    // distinct from any hook outcome.
    const asm_path = try a.dupe(u8, "/nonexistent/labelle-assembler-probe");
    defer a.free(asm_path);
    var site = testing.testSite(a, project);
    var ctx = RebuildCtx{
        .allocator = a,
        .asm_bin = .{ .path = asm_path },
        .project_dir = project,
        .platform_tag = "probe-target",
        .output_dir = project,
        .target_dir = project,
        .zig_args = &.{ "/nonexistent/zig-probe", "build" },
        .zig_env = null,
        .prebuild_steps = &.{},
        .prebuild_opts = .{ .fatal_on_step_failure = false },
        .hooks = &site,
        .generate_out = "/gen-out",
        .build_out = "/build-out",
        .run_hook_phase = Spy.run,
    };
    defer ctx.deinit();

    // Empty plans: no phase runs, the core generate is reached.
    Spy.reset();
    try std.testing.expectError(error.GenerateFailed, ctx.rebuildStaged());
    try Spy.expectCalls(&.{});

    // Before-generate hooks run ahead of the core generate, which then
    // fails; nothing after it runs.
    ctx.generate_plan = .{
        .before = &.{Fixture.planned("gen-pre", .generate, .before)},
        .after = &.{Fixture.planned("gen-post", .generate, .after)},
    };
    ctx.build_plan = .{
        .before = &.{Fixture.planned("build-pre", .build, .before)},
        .after = &.{Fixture.planned("build-post", .build, .after)},
    };
    Spy.reset();
    try std.testing.expectError(error.GenerateFailed, ctx.rebuildStaged());
    try Spy.expectCalls(&.{.{ .step = .generate, .phase = .before, .id = "gen-pre", .out = "/gen-out" }});

    // A `replace` on generate stands in for the core generate (and its
    // fingerprint pass), so the rebuild reaches the build phases; the
    // core build then fails to spawn, so `after build` never runs.
    ctx.generate_plan.replace = Fixture.planned("gen-swap", .generate, .replace);
    Spy.reset();
    try std.testing.expectError(error.ZigSpawnFailed, ctx.rebuildStaged());
    try Spy.expectCalls(&.{
        .{ .step = .generate, .phase = .before, .id = "gen-pre", .out = "/gen-out" },
        .{ .step = .generate, .phase = .replace, .id = "gen-swap", .out = "/gen-out" },
        .{ .step = .generate, .phase = .after, .id = "gen-post", .out = "/gen-out" },
        .{ .step = .build, .phase = .before, .id = "build-pre", .out = "/build-out" },
    });

    // A `replace` on build too: the whole rebuild is hooks, in order.
    ctx.build_plan.replace = Fixture.planned("build-swap", .build, .replace);
    Spy.reset();
    try ctx.rebuildStaged();
    try Spy.expectCalls(&.{
        .{ .step = .generate, .phase = .before, .id = "gen-pre", .out = "/gen-out" },
        .{ .step = .generate, .phase = .replace, .id = "gen-swap", .out = "/gen-out" },
        .{ .step = .generate, .phase = .after, .id = "gen-post", .out = "/gen-out" },
        .{ .step = .build, .phase = .before, .id = "build-pre", .out = "/build-out" },
        .{ .step = .build, .phase = .replace, .id = "build-swap", .out = "/build-out" },
        .{ .step = .build, .phase = .after, .id = "build-post", .out = "/build-out" },
    });
    Spy.reset();
    try std.testing.expect(RebuildCtx.rebuild(@ptrCast(&ctx)));

    // A failing hook (nonzero exit) stops the rebuild at that phase.
    ctx.generate_plan.after = &.{ Fixture.planned("fail", .generate, .after), Fixture.planned("gen-post", .generate, .after) };
    Spy.reset();
    try std.testing.expectError(error.HookFailed, ctx.rebuildStaged());
    try Spy.expectCalls(&.{
        .{ .step = .generate, .phase = .before, .id = "gen-pre", .out = "/gen-out" },
        .{ .step = .generate, .phase = .replace, .id = "gen-swap", .out = "/gen-out" },
        .{ .step = .generate, .phase = .after, .id = "fail", .out = "/gen-out" },
    });
    Spy.reset();
    try std.testing.expect(!RebuildCtx.rebuild(@ptrCast(&ctx)));

    // So does a hook the runner cannot even start (an unpinned remote
    // provider): the error is reported, not propagated out of the loop.
    ctx.generate_plan.after = &.{};
    ctx.build_plan.before = &.{Fixture.planned("unpinned", .build, .before)};
    Spy.reset();
    try std.testing.expectError(error.HookFailed, ctx.rebuildStaged());
    try std.testing.expectEqual(@as(usize, 3), Spy.count);
    try std.testing.expectEqualStrings("unpinned", Spy.calls[2].id);
}

// The replan seam: every rebuild pre-checks the target before the
// prebuild steps and replans after them, before its first hook phase;
// the plans the replan installs are the ones that run, and a failing
// replan stops the rebuild ahead of every hook with the previous plans
// intact.
test "watched rebuild replans the hook phases on every rebuild" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);

    const Fixture = struct {
        var provider: provider_dispatch.Provider = .{
            .dep = .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
            .dir = "/pkg",
            .meta = .{ .name = "pkg", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0" },
            .verified = true,
        };
        fn planned(id: []const u8, step: provider_contract.Step, when: provider_contract.Phase) provider_hooks.Planned {
            return .{
                .provider = &provider,
                .hook = .{ .id = id, .step = step, .target = "probe-target", .when = when, .build_step = "tool", .executable = "bin/tool" },
                .qualified = id,
            };
        }
    };
    const Spy = struct {
        var phases: [8][]const u8 = undefined;
        var phase_count: usize = 0;
        var replans: usize = 0;
        var fail_next = false;
        fn run(_: *provider_hooks.Site, list: []const provider_hooks.Planned, _: provider_contract.Step, _: provider_contract.Phase, _: []const u8) anyerror!u8 {
            for (list) |planned| {
                phases[phase_count] = planned.hook.id;
                phase_count += 1;
            }
            return 0;
        }
        fn replan(ptr: *anyopaque, ctx: *RebuildCtx) anyerror!void {
            const counter: *usize = @ptrCast(@alignCast(ptr));
            counter.* += 1;
            replans += 1;
            if (fail_next) return error.ProviderManifestBroken;
            // What production does: a fresh plan replaces the installed one.
            ctx.generate_plan = .{ .replace = Fixture.planned("gen-fresh", .generate, .replace) };
            ctx.build_plan = .{ .replace = Fixture.planned("build-fresh", .build, .replace) };
        }
        fn reset() void {
            phase_count = 0;
            prebuilds = 0;
        }
        // The ownership pre-check: counts runs; `refuse_next` stands in
        // for a target whose owner is clearly gone.
        var prechecks: usize = 0;
        var refuse_next = false;
        fn precheck(_: *anyopaque, _: *RebuildCtx) anyerror!void {
            prechecks += 1;
            if (refuse_next) return error.NoProviderForTarget;
        }
        // The prebuild runner: counts runs, and records how far this
        // rebuild's pre-check and replan had got when it ran.
        var prebuilds: usize = 0;
        var replans_at_prebuild: usize = 0;
        var prechecks_at_prebuild: usize = 0;
        fn runPrebuild(_: std.mem.Allocator, _: []const u8, _: []const prebuild.Step, _: prebuild.Options) prebuild.Error!void {
            prebuilds += 1;
            replans_at_prebuild = replans;
            prechecks_at_prebuild = prechecks;
        }
    };
    var counter: usize = 0;
    const asm_path = try a.dupe(u8, "/nonexistent/labelle-assembler-probe");
    defer a.free(asm_path);
    var site = testing.testSite(a, project);
    var ctx = RebuildCtx{
        .allocator = a,
        .asm_bin = .{ .path = asm_path },
        .project_dir = project,
        .platform_tag = "probe-target",
        .output_dir = project,
        .target_dir = project,
        .zig_args = &.{ "/nonexistent/zig-probe", "build" },
        .zig_env = null,
        .prebuild_steps = &.{},
        .prebuild_opts = .{ .fatal_on_step_failure = false },
        .hooks = &site,
        // The startup plans: a `replace` on both steps, so if they ran
        // the rebuild would succeed on "gen-stale"/"build-stale".
        .generate_plan = .{ .replace = Fixture.planned("gen-stale", .generate, .replace) },
        .build_plan = .{ .replace = Fixture.planned("build-stale", .build, .replace) },
        .run_hook_phase = Spy.run,
        .run_prebuild = Spy.runPrebuild,
        .replan = .{ .ctx = &counter, .precheck = Spy.precheck, .run = Spy.replan },
    };
    defer ctx.deinit();
    // Production wiring: the default prebuild runner IS the cold one.
    const default_prebuild = std.meta.fieldInfo(RebuildCtx, .run_prebuild).defaultValue() orelse return error.TestUnexpectedResult;
    try std.testing.expect(default_prebuild == prebuild.runAll);

    // Rebuild 1: replanned once; the FRESH plans ran, the startup plans
    // did not. The pre-check came first, the prebuild steps next, the
    // replan after them (so it sees what they generate).
    Spy.reset();
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(usize, 1), counter);
    try std.testing.expectEqual(@as(usize, 1), Spy.prebuilds);
    try std.testing.expectEqual(@as(usize, 1), Spy.prechecks_at_prebuild);
    try std.testing.expectEqual(@as(usize, 0), Spy.replans_at_prebuild);
    try std.testing.expectEqual(@as(usize, 2), Spy.phase_count);
    try std.testing.expectEqualStrings("gen-fresh", Spy.phases[0]);
    try std.testing.expectEqualStrings("build-fresh", Spy.phases[1]);
    // Rebuild 2: replanned again — once per rebuild, not once per session.
    Spy.reset();
    try std.testing.expect(RebuildCtx.rebuild(@ptrCast(&ctx)));
    try std.testing.expectEqual(@as(usize, 2), counter);
    try std.testing.expectEqual(@as(usize, 2), Spy.phase_count);
    // A failing replan stops the rebuild before any hook phase, and the
    // plans installed by the last good replan stay in place.
    Spy.fail_next = true;
    Spy.reset();
    try std.testing.expectError(error.ReplanFailed, ctx.rebuildStaged());
    try std.testing.expectEqual(@as(usize, 3), counter);
    try std.testing.expectEqual(@as(usize, 0), Spy.phase_count);
    // (It ran after the prebuild steps, by design: they may generate
    // the metadata the replan reads.)
    try std.testing.expectEqual(@as(usize, 1), Spy.prebuilds);
    try std.testing.expectEqualStrings("gen-fresh", ctx.generate_plan.replace.?.hook.id);
    try std.testing.expectEqualStrings("build-fresh", ctx.build_plan.replace.?.hook.id);
    Spy.fail_next = false;
    // A refusing pre-check stops the rebuild before the prebuild steps:
    // an edit that drops or unpins the served target's owner runs no
    // side-effecting prebuild work for the refused configuration (Codex
    // P2 on #421) — and no replan either.
    Spy.refuse_next = true;
    Spy.reset();
    try std.testing.expectError(error.TargetPrecheckFailed, ctx.rebuildStaged());
    try std.testing.expectEqual(@as(usize, 0), Spy.prebuilds);
    try std.testing.expectEqual(@as(usize, 3), counter);
    try std.testing.expectEqual(@as(usize, 0), Spy.phase_count);
    Spy.refuse_next = false;
    // Without a replan the startup plans are what run (the earlier tests'
    // shape), so the fresh plans above came from the seam.
    ctx.replan = null;
    ctx.generate_plan = .{ .replace = Fixture.planned("gen-stale", .generate, .replace) };
    ctx.build_plan = .{ .replace = Fixture.planned("build-stale", .build, .replace) };
    Spy.reset();
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(usize, 3), counter);
    try std.testing.expectEqualStrings("gen-stale", Spy.phases[0]);
    try std.testing.expectEqualStrings("build-stale", Spy.phases[1]);
}

test "watched rebuild keeps the last good hook environment unless the whole rebuild succeeds" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    const Spy = struct {
        /// The hook that fails this rebuild, if any.
        var fail_id: []const u8 = "";
        var precheck_fails = false;
        // A contributing hook adds NEW=<value> to the rebuild's environment,
        // the way `runPhase` absorbs an env_file.
        var value: []const u8 = "";
        fn run(site: *provider_hooks.Site, list: []const provider_hooks.Planned, _: provider_contract.Step, _: provider_contract.Phase, _: []const u8) anyerror!u8 {
            for (list) |entry| {
                if (std.mem.eql(u8, entry.hook.id, fail_id)) return 7;
                if (std.mem.eql(u8, entry.hook.id, "tc")) {
                    var diag: provider_env.Diagnostic = .{};
                    try site.env.add(site.backing, site.backing, entry.qualified, .{ .set = &.{.{ .name = "NEW", .value = value }} }, &diag);
                }
            }
            return 0;
        }
        fn precheck(_: *anyopaque, _: *RebuildCtx) anyerror!void {
            if (precheck_fails) return error.NoProviderForTarget;
        }
        fn replan(_: *anyopaque, _: *RebuildCtx) anyerror!void {}
        var provider: provider_dispatch.Provider = .{
            .dep = .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
            .dir = "/pkg",
            .meta = .{ .name = "pkg", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0" },
            .verified = true,
        };
        fn planned(id: []const u8, step: provider_contract.Step, when: provider_contract.Phase) provider_hooks.Planned {
            return .{
                .provider = &provider,
                .hook = .{ .id = id, .step = step, .target = "probe-target", .when = when, .build_step = "tool", .executable = "bin/tool" },
                .qualified = id,
            };
        }
        fn value_of(site: *const provider_hooks.Site, name: []const u8) ?[]const u8 {
            for (site.env.vars.items) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
            return null;
        }
    };
    var site = testing.testSite(a, project);
    defer site.env.deinit();
    var dummy: u8 = 0;
    // Every step is a hook, so a whole rebuild can succeed without an
    // assembler or a compiler: `tc` contributes before generate, the
    // replacements stand in for the core steps.
    var ctx = RebuildCtx{
        .allocator = a,
        .asm_bin = .{ .path = "" },
        .project_dir = project,
        .platform_tag = "probe-target",
        .output_dir = project,
        .target_dir = project,
        .zig_args = &.{},
        .zig_env = null,
        .prebuild_steps = &.{},
        .prebuild_opts = .{ .fatal_on_step_failure = false },
        .hooks = &site,
        .run_hook_phase = Spy.run,
        .replan = .{ .ctx = &dummy, .precheck = Spy.precheck, .run = Spy.replan },
        .generate_plan = .{ .before = &.{Spy.planned("tc", .generate, .before)}, .replace = Spy.planned("gen", .generate, .replace) },
        .build_plan = .{ .replace = Spy.planned("build", .build, .replace) },
    };
    defer ctx.deinit();
    // A first successful rebuild installs its environment.
    Spy.value = "first";
    try ctx.rebuildStaged();
    try std.testing.expectEqualStrings("first", Spy.value_of(&site, "NEW").?);
    // Failing before any hook (the ownership pre-check): the last good
    // environment stays.
    Spy.precheck_fails = true;
    Spy.value = "second";
    try std.testing.expectError(error.TargetPrecheckFailed, ctx.rebuildStaged());
    try std.testing.expectEqualStrings("first", Spy.value_of(&site, "NEW").?);
    Spy.precheck_fails = false;
    // Failing AFTER the contributing hook ran (the build replacement): its
    // contribution is discarded and the last good one stays.
    Spy.fail_id = "build";
    try std.testing.expectError(error.HookFailed, ctx.rebuildStaged());
    try std.testing.expectEqualStrings("first", Spy.value_of(&site, "NEW").?);
    try std.testing.expectEqual(@as(usize, 1), site.env.vars.items.len);
    // A rebuild that succeeds replaces it...
    Spy.fail_id = "";
    try ctx.rebuildStaged();
    try std.testing.expectEqualStrings("second", Spy.value_of(&site, "NEW").?);
    // ...and one whose plan no longer has the contributing hook leaves
    // nothing behind.
    ctx.generate_plan.before = &.{};
    try ctx.rebuildStaged();
    try std.testing.expect(site.env.isEmpty());
}

// A watch session hands the rebuilds a DEEP copy of the startup environment
// (`watch_session.run`): a committed rebuild frees the environment it
// replaces, and the replacement's own site — which may still be starting
// with the startup environment — must never see that storage freed or
// changed.
test "a rebuild's environment changes never reach the session's copy" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    const Spy = struct {
        fn run(site: *provider_hooks.Site, list: []const provider_hooks.Planned, _: provider_contract.Step, _: provider_contract.Phase, _: []const u8) anyerror!u8 {
            for (list) |entry| if (std.mem.eql(u8, entry.hook.id, "tc")) {
                var diag: provider_env.Diagnostic = .{};
                try site.env.add(site.backing, site.backing, entry.qualified, .{ .set = &.{.{ .name = "PROBE_TOOLCHAIN", .value = "rebuilt" }} }, &diag);
            };
            return 0;
        }
        var provider: provider_dispatch.Provider = .{
            .dep = .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
            .dir = "/pkg",
            .meta = .{ .name = "pkg", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0" },
            .verified = true,
        };
        fn planned(id: []const u8, step: provider_contract.Step, when: provider_contract.Phase) provider_hooks.Planned {
            return .{ .provider = &provider, .hook = .{ .id = id, .step = step, .target = "probe-target", .when = when, .build_step = "tool", .executable = "bin/tool" }, .qualified = id };
        }
    };
    // The session's site, with the environment the startup hooks contributed.
    var session = testing.testSite(a, project);
    defer session.env.deinit();
    var diag: provider_env.Diagnostic = .{};
    try session.env.add(a, a, "pkg/tc", .{ .set = &.{.{ .name = "PROBE_TOOLCHAIN", .value = "startup" }} }, &diag);
    const startup_value = session.env.vars.items[0].value;
    // The rebuilds' copy.
    var rebuilds = session;
    rebuilds.env = try session.env.clone(a);
    defer rebuilds.env.deinit();
    var ctx = RebuildCtx{
        .allocator = a,
        .asm_bin = .{ .path = "" },
        .project_dir = project,
        .platform_tag = "probe-target",
        .output_dir = project,
        .target_dir = project,
        .zig_args = &.{},
        .zig_env = null,
        .prebuild_steps = &.{},
        .prebuild_opts = .{ .fatal_on_step_failure = false },
        .hooks = &rebuilds,
        .run_hook_phase = Spy.run,
        .generate_plan = .{ .before = &.{Spy.planned("tc", .generate, .before)}, .replace = Spy.planned("gen", .generate, .replace) },
        .build_plan = .{ .replace = Spy.planned("build", .build, .replace) },
    };
    defer ctx.deinit();
    // Two committed rebuilds: each frees the environment it replaces.
    try ctx.rebuildStaged();
    try ctx.rebuildStaged();
    try std.testing.expectEqualStrings("rebuilt", rebuilds.env.vars.items[0].value);
    // The session's copy is untouched: same storage, same value.
    try std.testing.expectEqual(@as(usize, 1), session.env.vars.items.len);
    try std.testing.expectEqual(startup_value.ptr, session.env.vars.items[0].value.ptr);
    try std.testing.expectEqualStrings("startup", session.env.vars.items[0].value);
}

// The running replacement keeps the environment it was launched with: a
// rebuild whose hooks contribute a different one must not publish output
// built for another toolchain environment.
test "a rebuild that contributes a different environment than the launch one publishes nothing" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    const Spy = struct {
        var value: []const u8 = "";
        var published: usize = 0;
        fn run(site: *provider_hooks.Site, list: []const provider_hooks.Planned, _: provider_contract.Step, _: provider_contract.Phase, _: []const u8) anyerror!u8 {
            for (list) |entry| if (std.mem.eql(u8, entry.hook.id, "tc")) {
                var diag: provider_env.Diagnostic = .{};
                try site.env.add(site.backing, site.backing, entry.qualified, .{ .set = &.{.{ .name = "SDK_ROOT", .value = value }} }, &diag);
            };
            return 0;
        }
        fn publish(_: *anyopaque, gate: @import("../watch.zig").PublishGate) anyerror!void {
            try gate.before_switch(gate.ctx);
            try gate.before_advance(gate.ctx);
            published += 1;
        }
        var provider: provider_dispatch.Provider = .{
            .dep = .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
            .dir = "/pkg",
            .meta = .{ .name = "pkg", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0" },
            .verified = true,
        };
        fn planned(id: []const u8, step: provider_contract.Step, when: provider_contract.Phase) provider_hooks.Planned {
            return .{ .provider = &provider, .hook = .{ .id = id, .step = step, .target = "probe-target", .when = when, .build_step = "tool", .executable = "bin/tool" }, .qualified = id };
        }
    };
    // What the replacement was launched with.
    var launched: provider_env.Accumulator = .{};
    defer launched.deinit();
    var diag: provider_env.Diagnostic = .{};
    try launched.add(a, a, "tc", .{ .set = &.{.{ .name = "SDK_ROOT", .value = "/one" }} }, &diag);
    var site = testing.testSite(a, project);
    site.env = try launched.clone(a);
    defer site.env.deinit();
    var dummy: u8 = 0;
    var ctx = RebuildCtx{
        .allocator = a,
        .asm_bin = .{ .path = "" },
        .project_dir = project,
        .platform_tag = "probe-target",
        .output_dir = project,
        .target_dir = project,
        .zig_args = &.{},
        .zig_env = null,
        .prebuild_steps = &.{},
        .prebuild_opts = .{ .fatal_on_step_failure = false },
        .hooks = &site,
        .run_hook_phase = Spy.run,
        .publish = .{ .ctx = &dummy, .run = Spy.publish },
        .launch_env = &launched,
        .generate_plan = .{ .before = &.{Spy.planned("tc", .generate, .before)}, .replace = Spy.planned("gen", .generate, .replace) },
        .build_plan = .{ .replace = Spy.planned("build", .build, .replace) },
    };
    defer ctx.deinit();
    // The same environment: published.
    Spy.value = "/one";
    Spy.published = 0;
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(usize, 1), Spy.published);
    // A different one: the restart diagnostic, nothing published, and the
    // committed environment stays the launch one.
    Spy.value = "/two";
    try std.testing.expectError(error.SessionChanged, ctx.rebuildStaged());
    try std.testing.expectEqual(@as(usize, 1), Spy.published);
    try std.testing.expectEqualStrings("/one", site.env.vars.items[0].value);
    // The check is the mechanism: without a launch environment it publishes.
    ctx.launch_env = null;
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(usize, 2), Spy.published);
}
