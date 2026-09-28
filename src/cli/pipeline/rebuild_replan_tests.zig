//! Tests of `Replanner` (`rebuild_replan.zig`) against real projects and
//! provider manifests, and of the two-stage (pre-check -> prebuild ->
//! replan) watched rebuild it drives. The rebuild-driven tests use a tool
//! that always succeeds (`testing.okTool`) for the assembler and the
//! compiler, so a whole rebuild commits (cli#469).
const std = @import("std");
const config = @import("../config.zig");
const lockfile = @import("../lockfile.zig");
const project_config = @import("../project_config.zig");
const prebuild = @import("../prebuild.zig");
const asm_cache = @import("../asm_cache.zig");
const provider_contract = @import("../provider_contract.zig");
const provider_dispatch = @import("../provider_dispatch.zig");
const provider_github = @import("../provider_github.zig");
const provider_hooks = @import("../provider_hooks.zig");
const RebuildCtx = @import("rebuild.zig").RebuildCtx;
const Replanner = @import("rebuild_replan.zig").Replanner;
const testing = @import("testing.zig");

/// `Replanner.run` then `commit`: a replan the tests drive directly,
/// without a whole rebuild around it.
fn runCommitted(replan: *Replanner, ctx: *RebuildCtx) !void {
    try Replanner.run(replan, ctx);
    Replanner.commit(replan);
}

// Against a real project: edits to the manifest between rebuilds change
// the installed plans; a broken manifest fails the replan and keeps the
// last good plans; nothing leaks across generations.
test "watch replan re-reads the project and provider manifests on every call" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "pkg");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    try tmp.dir.writeFile(io, .{
        .sub_path = "project/project.labelle",
        .data = ".{ .name = \"game\", .plugins = .{ .{ .name = \"pkg\", .repo = \"local:../pkg\", .version = \"1.0.0\" } } }",
    });
    // The package owns the served target, as the cold pipeline required
    // before the server started; `targets` lets a step drop that.
    const Manifest = struct {
        fn writeAt(dir: std.Io.Dir, sub_path: []const u8, targets: []const u8, hooks: []const u8) !void {
            var buf: [1024]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, ".{{ .name = \"pkg\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{{ {s} }}, .hooks = .{{ {s} }} }}", .{ targets, hooks });
            try dir.writeFile(config.globalIo(), .{ .sub_path = sub_path, .data = text });
        }
        fn write(dir: std.Io.Dir, hooks: []const u8) !void {
            try writeAt(dir, "pkg/plugin.labelle", "\"probe-target\"", hooks);
        }
    };
    const gen_hook = ".{ .id = \"gen\", .step = .generate, .target = \"probe-target\", .when = .before, .build_step = \"tool\", .executable = \"bin/tool\" }";
    const build_hook = ".{ .id = \"post\", .step = .build, .target = \"probe-target\", .when = .after, .build_step = \"tool\", .executable = \"bin/tool\" }";
    try Manifest.write(tmp.dir, gen_hook);

    const asm_path = try testing.okTool(a, tmp.dir);
    defer a.free(asm_path);
    var site = testing.testSite(a, project);
    var ctx = RebuildCtx{
        .allocator = a,
        .asm_bin = .{ .path = asm_path },
        .project_dir = project,
        .platform_tag = "probe-target",
        .backend_tag = "probe",
        .output_dir = project,
        .target_dir = project,
        .zig_args = &.{asm_path},
        .zig_env = null,
        .prebuild_steps = &.{},
        .prebuild_opts = .{ .fatal_on_step_failure = false },
        .hooks = &site,
    };
    defer ctx.deinit();
    var replan = Replanner{ .backing = a, .project_dir = project };
    const startup_cfg = site.cfg;
    defer replan.deinit(&site, &.{}, startup_cfg);

    // First replan: the manifest's generate hook is planned; the site
    // now knows the provider and the re-read config.
    try runCommitted(&replan, &ctx);
    try std.testing.expectEqual(@as(usize, 1), ctx.generate_plan.before.len);
    try std.testing.expectEqualStrings("pkg/gen", ctx.generate_plan.before[0].qualified);
    try std.testing.expect(ctx.build_plan.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), site.providers.len);
    try std.testing.expectEqual(@as(usize, 1), site.cfg.plugins.len);
    // The manifest changes between rebuilds: the next replan sees it.
    try Manifest.write(tmp.dir, build_hook);
    try runCommitted(&replan, &ctx);
    try std.testing.expect(ctx.generate_plan.isEmpty());
    try std.testing.expectEqualStrings("pkg/post", ctx.build_plan.after[0].qualified);
    // A broken manifest fails the replan; the last good plans stay
    // installed and remain readable (their generation was kept).
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/plugin.labelle", .data = "not a manifest" });
    try std.testing.expectError(error.InvalidManifest, Replanner.run(&replan, &ctx));
    try std.testing.expectEqualStrings("pkg/post", ctx.build_plan.after[0].qualified);
    try Manifest.write(tmp.dir, build_hook);
    try runCommitted(&replan, &ctx);
    const good = replan.current.?;

    // The served target loses its owner (Codex P1 on #421). Each case
    // fails the replan with the cold pipeline's error and keeps the
    // previous generation installed: its plans, its providers, its
    // config — never empty plans that would generate for an unowned
    // target.
    const Kept = struct {
        fn check(r: *const Replanner, c: *const RebuildCtx, s: *const provider_hooks.Site, expected: *const Replanner.Generation) !void {
            try std.testing.expectEqual(expected, r.current.?);
            try std.testing.expectEqualStrings("pkg/post", c.build_plan.after[0].qualified);
            try std.testing.expectEqual(@as(usize, 1), s.providers.len);
            try std.testing.expectEqual(@as(usize, 1), s.cfg.plugins.len);
        }
    };
    // (a) The package stops declaring the target.
    try Manifest.writeAt(tmp.dir, "pkg/plugin.labelle", "", "");
    try std.testing.expectError(error.NoProviderForTarget, Replanner.run(&replan, &ctx));
    try Kept.check(&replan, &ctx, &site, good);
    try Manifest.write(tmp.dir, build_hook);
    // (b) The project drops the plugin altogether.
    try tmp.dir.writeFile(io, .{ .sub_path = "project/project.labelle", .data = ".{ .name = \"game\" }" });
    try std.testing.expectError(error.NoProviderForTarget, Replanner.run(&replan, &ctx));
    try Kept.check(&replan, &ctx, &site, good);
    // (c) The owner becomes a remote package read from the ordinary
    //     cache with no integrity pin: present, but unverified.
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(home);
    asm_cache.setCacheRootOverride(home);
    defer asm_cache.clearCacheRootOverride();
    const cached = try std.fs.path.join(a, &.{ "packages", "plugins", "example", "pkg", "1.0.0" });
    defer a.free(cached);
    try tmp.dir.createDirPath(io, cached);
    const cached_manifest = try std.fs.path.join(a, &.{ cached, "plugin.labelle" });
    defer a.free(cached_manifest);
    try Manifest.writeAt(tmp.dir, cached_manifest, "\"probe-target\"", build_hook);
    try tmp.dir.writeFile(io, .{
        .sub_path = "project/project.labelle",
        .data = ".{ .name = \"game\", .plugins = .{ .{ .name = \"pkg\", .repo = \"example/pkg\", .version = \"1.0.0\" } } }",
    });
    try std.testing.expectError(error.UnverifiedTargetOwner, Replanner.run(&replan, &ctx));
    try Kept.check(&replan, &ctx, &site, good);
    try std.testing.expectEqualStrings("local:../pkg", site.cfg.plugins[0].repo);
}

/// Shared fixture for the two-stage (pre-check → prebuild → replan)
/// tests below: a project declaring a local package `pkg` that owns
/// `probe-target`, a rebuild context wired to the production pre-check and
/// replan, and spies for the prebuild runner and the hook phases.
const TwoStage = struct {
    const gen_hook = ".{ .id = \"gen\", .step = .generate, .target = \"probe-target\", .when = .before, .build_step = \"tool\", .executable = \"bin/tool\" }";
    const local_project = ".{ .name = \"game\", .plugins = .{ .{ .name = \"pkg\", .repo = \"local:../pkg\", .version = \"1.0.0\" } } }";

    fn manifest(buf: []u8, targets: []const u8, hooks: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, ".{{ .name = \"pkg\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{{ {s} }}, .hooks = .{{ {s} }} }}", .{ targets, hooks });
    }

    const Spy = struct {
        var prebuilds: usize = 0;
        /// When set, the prebuild step writes this manifest text here —
        /// a generator whose output is the provider's metadata.
        var generate_path: []const u8 = "";
        var generate_text: []const u8 = "";
        var hooks: [4][]const u8 = undefined;
        var hook_count: usize = 0;
        fn reset() void {
            prebuilds = 0;
            hook_count = 0;
            generate_path = "";
        }
        fn runPrebuild(_: std.mem.Allocator, _: []const u8, _: []const prebuild.Step, _: prebuild.Options) prebuild.Error!void {
            prebuilds += 1;
            if (generate_path.len != 0) {
                std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = generate_path, .data = generate_text }) catch return error.PrebuildStepFailed;
            }
        }
        fn runHook(_: *provider_hooks.Site, list: []const provider_hooks.Planned, _: provider_contract.Step, _: provider_contract.Phase, _: []const u8) anyerror!u8 {
            for (list) |planned| {
                hooks[hook_count] = planned.qualified;
                hook_count += 1;
            }
            return 0;
        }
        fn lock(_: std.mem.Allocator, _: []const u8, _: project_config.ProjectConfig) anyerror!void {}
    };
};

// Stage one: a watched edit that leaves the served target clearly
// ownerless (or unpinned) is refused by the pre-check, before the
// prebuild steps run a single side effect for it (Codex P2 on #421).
test "watched rebuild refuses a target whose owner disappeared before the prebuild steps" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "pkg");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    var buf: [1024]u8 = undefined;
    const owning = try TwoStage.manifest(&buf, "\"probe-target\"", TwoStage.gen_hook);
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/plugin.labelle", .data = owning });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/project.labelle", .data = TwoStage.local_project });

    const asm_path = try testing.okTool(a, tmp.dir);
    defer a.free(asm_path);
    var site = testing.testSite(a, project);
    var replan = Replanner{ .backing = a, .project_dir = project, .write_lock = TwoStage.Spy.lock };
    const startup_cfg = site.cfg;
    defer replan.deinit(&site, &.{}, startup_cfg);
    var ctx = RebuildCtx{
        .allocator = a,
        .asm_bin = .{ .path = asm_path },
        .project_dir = project,
        .platform_tag = "probe-target",
        .backend_tag = "probe",
        .output_dir = project,
        .target_dir = project,
        .zig_args = &.{asm_path},
        .zig_env = null,
        .prebuild_steps = &.{},
        .prebuild_opts = .{ .fatal_on_step_failure = false },
        .hooks = &site,
        .run_prebuild = TwoStage.Spy.runPrebuild,
        .run_hook_phase = TwoStage.Spy.runHook,
        .replan = replan.seam(),
    };
    defer ctx.deinit();

    // Owned: the pre-check passes, the prebuild runs, the replan plans
    // the hook (generation then fails on the missing assembler).
    TwoStage.Spy.reset();
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(usize, 1), TwoStage.Spy.prebuilds);
    try std.testing.expectEqual(@as(usize, 1), TwoStage.Spy.hook_count);
    const good = replan.current.?;

    // (a) The project drops the package: no local package is left to
    // regenerate, so no prebuild can bring an owner back.
    try tmp.dir.writeFile(io, .{ .sub_path = "project/project.labelle", .data = ".{ .name = \"game\" }" });
    try std.testing.expectError(error.NoProviderForTarget, Replanner.precheck(&replan, &ctx));
    TwoStage.Spy.reset();
    try std.testing.expectError(error.TargetPrecheckFailed, ctx.rebuildStaged());
    try std.testing.expectEqual(@as(usize, 0), TwoStage.Spy.prebuilds);
    try std.testing.expectEqual(@as(usize, 0), TwoStage.Spy.hook_count);
    try std.testing.expectEqual(good, replan.current.?);
    // (b) The only package left is a cached remote one that does not
    // declare the target: no local candidate, no remote owner.
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(home);
    asm_cache.setCacheRootOverride(home);
    defer asm_cache.clearCacheRootOverride();
    const cached = try std.fs.path.join(a, &.{ "packages", "plugins", "example", "pkg", "1.0.0" });
    defer a.free(cached);
    try tmp.dir.createDirPath(io, cached);
    const cached_manifest = try std.fs.path.join(a, &.{ cached, "plugin.labelle" });
    defer a.free(cached_manifest);
    var unowned_buf: [1024]u8 = undefined;
    const unowned = try TwoStage.manifest(&unowned_buf, "", TwoStage.gen_hook);
    try tmp.dir.writeFile(io, .{ .sub_path = cached_manifest, .data = unowned });
    const remote_project = ".{ .name = \"game\", .plugins = .{ .{ .name = \"pkg\", .repo = \"example/pkg\", .version = \"1.0.0\" } } }";
    try tmp.dir.writeFile(io, .{ .sub_path = "project/project.labelle", .data = remote_project });
    try std.testing.expectError(error.NoProviderForTarget, Replanner.precheck(&replan, &ctx));
    TwoStage.Spy.reset();
    try std.testing.expectError(error.TargetPrecheckFailed, ctx.rebuildStaged());
    try std.testing.expectEqual(@as(usize, 0), TwoStage.Spy.prebuilds);
    try std.testing.expectEqual(good, replan.current.?);
    // (c) The owner becomes a remote package with no integrity pin.
    try tmp.dir.writeFile(io, .{ .sub_path = cached_manifest, .data = owning });
    try std.testing.expectError(error.UnverifiedTargetOwner, Replanner.precheck(&replan, &ctx));
    TwoStage.Spy.reset();
    try std.testing.expectError(error.TargetPrecheckFailed, ctx.rebuildStaged());
    try std.testing.expectEqual(@as(usize, 0), TwoStage.Spy.prebuilds);
    try std.testing.expectEqual(good, replan.current.?);

    // Not "clearly gone": a declared local package — with no manifest
    // yet, or with one that does not declare the target NOW — may be
    // (re)generated by a prebuild step. The pre-check defers; the
    // prebuild runs; the full replan after it is what refuses, when
    // nothing changed the manifest.
    try tmp.dir.writeFile(io, .{ .sub_path = "project/project.labelle", .data = TwoStage.local_project });
    try tmp.dir.deleteFile(io, "pkg/plugin.labelle");
    try Replanner.precheck(&replan, &ctx);
    TwoStage.Spy.reset();
    try std.testing.expectError(error.ReplanFailed, ctx.rebuildStaged());
    try std.testing.expectEqual(@as(usize, 1), TwoStage.Spy.prebuilds);
    try std.testing.expectEqual(@as(usize, 0), TwoStage.Spy.hook_count);
    try std.testing.expectEqual(good, replan.current.?);
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/plugin.labelle", .data = unowned });
    try Replanner.precheck(&replan, &ctx);
    TwoStage.Spy.reset();
    try std.testing.expectError(error.ReplanFailed, ctx.rebuildStaged());
    try std.testing.expectEqual(@as(usize, 1), TwoStage.Spy.prebuilds);
    try std.testing.expectEqual(@as(usize, 0), TwoStage.Spy.hook_count);
    try std.testing.expectEqual(good, replan.current.?);
}

// A served target switches to a local provider whose EXISTING
// manifest is a stale prebuild output: it does not declare the target
// until the generator reruns. The pre-check must let the prebuild run;
// the replan after it sees the regenerated manifest (cli#429).
test "watched rebuild lets a prebuild refresh an existing provider manifest" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "pkg");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    const pkg = try tmp.dir.realPathFileAlloc(io, "pkg", a);
    defer a.free(pkg);
    try tmp.dir.writeFile(io, .{ .sub_path = "project/project.labelle", .data = TwoStage.local_project });
    var stale_buf: [1024]u8 = undefined;
    const stale = try TwoStage.manifest(&stale_buf, "", TwoStage.gen_hook);
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/plugin.labelle", .data = stale });

    const asm_path = try testing.okTool(a, tmp.dir);
    defer a.free(asm_path);
    var site = testing.testSite(a, project);
    var replan = Replanner{ .backing = a, .project_dir = project, .write_lock = TwoStage.Spy.lock };
    const startup_cfg = site.cfg;
    defer replan.deinit(&site, &.{}, startup_cfg);
    var ctx = RebuildCtx{
        .allocator = a,
        .asm_bin = .{ .path = asm_path },
        .project_dir = project,
        .platform_tag = "probe-target",
        .backend_tag = "probe",
        .output_dir = project,
        .target_dir = project,
        .zig_args = &.{asm_path},
        .zig_env = null,
        .prebuild_steps = &.{},
        .prebuild_opts = .{ .fatal_on_step_failure = false },
        .hooks = &site,
        .run_prebuild = TwoStage.Spy.runPrebuild,
        .run_hook_phase = TwoStage.Spy.runHook,
        .replan = replan.seam(),
    };
    defer ctx.deinit();

    // The existing manifest does not declare the target, yet the
    // pre-check defers: a local package's metadata is not final
    // before its prebuild runs.
    try Replanner.precheck(&replan, &ctx);
    var buf: [1024]u8 = undefined;
    const regenerated = try TwoStage.manifest(&buf, "\"probe-target\"", TwoStage.gen_hook);
    const manifest_path = try std.fs.path.join(a, &.{ pkg, "plugin.labelle" });
    defer a.free(manifest_path);
    TwoStage.Spy.reset();
    TwoStage.Spy.generate_path = manifest_path;
    TwoStage.Spy.generate_text = regenerated;
    // The rebuild gets past the replan (generation then fails on the
    // missing assembler): the regenerated manifest owns the target and
    // its hook ran in this very rebuild.
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(usize, 1), TwoStage.Spy.prebuilds);
    try std.testing.expect(replan.current != null);
    try std.testing.expectEqual(@as(usize, 1), TwoStage.Spy.hook_count);
    try std.testing.expectEqualStrings("pkg/gen", TwoStage.Spy.hooks[0]);
}

// Stage two: a prebuild step that generates the provider's manifest is
// seen by THIS rebuild's replan — the plans that run are the generated
// ones, not the stale or missing metadata from before the prebuild
// (Codex P2 on #427).
test "watched rebuild replans after a prebuild step generates provider metadata" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "pkg");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    const pkg = try tmp.dir.realPathFileAlloc(io, "pkg", a);
    defer a.free(pkg);
    try tmp.dir.writeFile(io, .{ .sub_path = "project/project.labelle", .data = TwoStage.local_project });

    const asm_path = try testing.okTool(a, tmp.dir);
    defer a.free(asm_path);
    var site = testing.testSite(a, project);
    var replan = Replanner{ .backing = a, .project_dir = project, .write_lock = TwoStage.Spy.lock };
    const startup_cfg = site.cfg;
    defer replan.deinit(&site, &.{}, startup_cfg);
    var ctx = RebuildCtx{
        .allocator = a,
        .asm_bin = .{ .path = asm_path },
        .project_dir = project,
        .platform_tag = "probe-target",
        .backend_tag = "probe",
        .output_dir = project,
        .target_dir = project,
        .zig_args = &.{asm_path},
        .zig_env = null,
        .prebuild_steps = &.{},
        .prebuild_opts = .{ .fatal_on_step_failure = false },
        .hooks = &site,
        .run_prebuild = TwoStage.Spy.runPrebuild,
        .run_hook_phase = TwoStage.Spy.runHook,
        .replan = replan.seam(),
    };
    defer ctx.deinit();

    // The manifest does not exist when the rebuild starts; the prebuild
    // step generates it, owning the target and declaring a hook.
    var buf: [1024]u8 = undefined;
    const generated = try TwoStage.manifest(&buf, "\"probe-target\"", TwoStage.gen_hook);
    const manifest_path = try std.fs.path.join(a, &.{ pkg, "plugin.labelle" });
    defer a.free(manifest_path);
    TwoStage.Spy.reset();
    TwoStage.Spy.generate_path = manifest_path;
    TwoStage.Spy.generate_text = generated;
    try ctx.rebuildStaged();
    try std.testing.expectEqual(@as(usize, 1), TwoStage.Spy.prebuilds);
    // The replan saw the generated manifest: its hook is planned and ran
    // in this very rebuild.
    try std.testing.expectEqual(@as(usize, 1), ctx.generate_plan.before.len);
    try std.testing.expectEqualStrings("pkg/gen", ctx.generate_plan.before[0].qualified);
    try std.testing.expectEqual(@as(usize, 1), TwoStage.Spy.hook_count);
    try std.testing.expectEqualStrings("pkg/gen", TwoStage.Spy.hooks[0]);

    // The mechanism: the same rebuild with a prebuild that generates
    // nothing is refused by the replan — so the plan above came from
    // the manifest the prebuild wrote, read after it ran.
    try tmp.dir.deleteFile(io, "pkg/plugin.labelle");
    TwoStage.Spy.reset();
    try std.testing.expectError(error.ReplanFailed, ctx.rebuildStaged());
    try std.testing.expectEqual(@as(usize, 1), TwoStage.Spy.prebuilds);
    try std.testing.expectEqual(@as(usize, 0), TwoStage.Spy.hook_count);
}

// A pinned remote provider is unpacked once per changed pin, not twice
// per save: the pre-check reads its manifest from the extraction an
// earlier generation verified, and a replan reuses the extraction of an
// unchanged pin (cli#429).
test "watch replan extracts a pinned provider once per changed pin" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "home/provider-archives");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    const home = try tmp.dir.realPathFileAlloc(io, "home", a);
    defer a.free(home);
    asm_cache.setCacheRootOverride(home);
    defer asm_cache.clearCacheRootOverride();
    try tmp.dir.writeFile(io, .{
        .sub_path = "project/project.labelle",
        .data = ".{ .name = \"game\", .plugins = .{ .{ .name = \"pkg\", .repo = \"example/pkg\", .version = \"1.0.0\" } } }",
    });
    const Pins = struct {
        /// Publish an archive of the owning manifest (bytes varied by
        /// `variant`) and pin it in the project's provider lock.
        fn publish(dir: std.Io.Dir, variant: []const u8, commit: u8) !void {
            const ta = std.testing.allocator;
            const data = try provider_github.testProviderArchive(ta, ".{ .name = \"pkg\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{ \"probe-target\" } }", variant);
            defer ta.free(data);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
            const hex = std.fmt.bytesToHex(digest, .lower);
            var name_buf: [128]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "home/provider-archives/{s}.tar.gz", .{&hex});
            try dir.writeFile(config.globalIo(), .{ .sub_path = name, .data = data });
            var commit_hex: [40]u8 = undefined;
            @memset(&commit_hex, commit);
            var lock_buf: [512]u8 = undefined;
            const lock = try std.fmt.bufPrint(&lock_buf, "{{\"schema_version\":1,\"providers\":[{{\"package\":\"pkg\",\"repo\":\"example/pkg\",\"version\":\"1.0.0\",\"commit\":\"{s}\",\"sha256\":\"{s}\"}}]}}", .{ &commit_hex, &hex });
            try dir.writeFile(config.globalIo(), .{ .sub_path = "project/" ++ provider_github.lock_name, .data = lock });
        }
    };
    try Pins.publish(tmp.dir, "// v1\n", '1');

    // The cold pipeline's own extraction, lent to the session; its
    // storage outlives the replan, as `run`'s does.
    var startup_arena = std.heap.ArenaAllocator.init(a);
    defer startup_arena.deinit();
    const sa = startup_arena.allocator();
    var startup_sources: provider_github.Sources = .{ .a = sa };
    defer startup_sources.deinit();
    const startup_cfg_read = try config.readProjectConfig(sa, project);
    const startup_providers = try provider_dispatch.discover(sa, project, startup_cfg_read, &startup_sources, .populated);
    try std.testing.expectEqual(@as(usize, 1), startup_providers.len);

    const asm_path = try testing.okTool(a, tmp.dir);
    defer a.free(asm_path);
    var site = testing.testSite(a, project);
    var ctx = RebuildCtx{
        .allocator = a,
        .asm_bin = .{ .path = asm_path },
        .project_dir = project,
        .platform_tag = "probe-target",
        .backend_tag = "probe",
        .output_dir = project,
        .target_dir = project,
        .zig_args = &.{asm_path},
        .zig_env = null,
        .prebuild_steps = &.{},
        .prebuild_opts = .{ .fatal_on_step_failure = false },
        .hooks = &site,
    };
    defer ctx.deinit();
    var replan = Replanner{ .backing = a, .project_dir = project, .write_lock = TwoStage.Spy.lock };
    const startup_cfg = site.cfg;
    defer replan.deinit(&site, &.{}, startup_cfg);
    replan.seed(&startup_sources);

    // Two consecutive rebuilds with the pin unchanged: the pre-check
    // reads the lent extraction, the replan reuses it — nothing is
    // unpacked, and the providers point at the cold pipeline's copy.
    const before = provider_github.extraction_count;
    for (0..2) |_| {
        try Replanner.precheck(&replan, &ctx);
        try runCommitted(&replan, &ctx);
        try std.testing.expectEqualStrings(startup_providers[0].dir, site.providers[0].dir);
    }
    try std.testing.expectEqual(before, provider_github.extraction_count);

    // The pin changes: the pre-check still unpacks nothing (the new pin
    // is unread, so it defers), the replan unpacks it exactly once...
    try Pins.publish(tmp.dir, "// v2\n", '2');
    try Replanner.precheck(&replan, &ctx);
    try std.testing.expectEqual(before, provider_github.extraction_count);
    try runCommitted(&replan, &ctx);
    try std.testing.expectEqual(before + 1, provider_github.extraction_count);
    const v2_dir = try a.dupe(u8, site.providers[0].dir);
    defer a.free(v2_dir);
    try std.testing.expect(!std.mem.eql(u8, startup_providers[0].dir, v2_dir));
    // ...and the two rebuilds after it reuse that extraction.
    for (0..2) |_| {
        try Replanner.precheck(&replan, &ctx);
        try runCommitted(&replan, &ctx);
        try std.testing.expectEqualStrings(v2_dir, site.providers[0].dir);
    }
    try std.testing.expectEqual(before + 1, provider_github.extraction_count);

    // Back to v1: its lent extraction is still there, so nothing is
    // unpacked; v2's, owned by the session and read by no installed
    // generation any more, is removed.
    try Pins.publish(tmp.dir, "// v1\n", '1');
    try Replanner.precheck(&replan, &ctx);
    try runCommitted(&replan, &ctx);
    try std.testing.expectEqual(before + 1, provider_github.extraction_count);
    try std.testing.expectEqualStrings(startup_providers[0].dir, site.providers[0].dir);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, v2_dir, .{}));
}

// An edit to `project.labelle` brings the package cache and the lock in
// line before discovery: a newly declared remote package is installed
// (else `.populated` discovery fails `ProviderPackageMissing` on every
// rebuild), the lock is rewritten after the plans are good, and an
// unchanged project costs neither.
test "watch replan installs and relocks when project.labelle changes" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "pkg");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(home);
    asm_cache.setCacheRootOverride(home);
    defer asm_cache.clearCacheRootOverride();
    try tmp.dir.writeFile(io, .{
        .sub_path = "pkg/plugin.labelle",
        .data = ".{ .name = \"pkg\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{ \"probe-target\" } }",
    });
    const local = ".{ .name = \"pkg\", .repo = \"local:../pkg\", .version = \"1.0.0\" }";
    const remote = ".{ .name = \"extra\", .repo = \"example/extra\", .version = \"1.0.0\" }";
    try tmp.dir.writeFile(io, .{ .sub_path = "project/project.labelle", .data = ".{ .name = \"game\", .plugins = .{ " ++ local ++ " } }" });

    const Spy = struct {
        var events: [8][]const u8 = undefined;
        var count: usize = 0;
        var cache_dir: []const u8 = "";
        var fail_install = false;
        fn install(_: *const anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!void {
            events[count] = "install";
            count += 1;
            if (fail_install) return error.InstallFailed;
            // What `assembler install` does for a declared remote package.
            try std.Io.Dir.cwd().createDirPath(config.globalIo(), cache_dir);
        }
        fn lock(_: std.mem.Allocator, _: []const u8, cfg: project_config.ProjectConfig) anyerror!void {
            events[count] = if (cfg.plugins.len == 2) "lock-2" else "lock-1";
            count += 1;
        }
    };
    Spy.count = 0;
    Spy.cache_dir = try std.fs.path.join(a, &.{ home, "packages", "plugins", "example", "extra", "1.0.0" });
    defer a.free(Spy.cache_dir);

    const asm_path = try testing.okTool(a, tmp.dir);
    defer a.free(asm_path);
    var site = testing.testSite(a, project);
    var ctx = RebuildCtx{
        .allocator = a,
        .asm_bin = .{ .path = asm_path },
        .project_dir = project,
        .platform_tag = "probe-target",
        .backend_tag = "probe",
        .output_dir = project,
        .target_dir = project,
        .zig_args = &.{asm_path},
        .zig_env = null,
        .prebuild_steps = &.{},
        .prebuild_opts = .{ .fatal_on_step_failure = false },
        .hooks = &site,
    };
    defer ctx.deinit();
    var replan = Replanner{
        .backing = a,
        .project_dir = project,
        .installer = .{ .ctx = &Spy.count, .run = Spy.install },
        .write_lock = Spy.lock,
    };
    const startup_cfg = site.cfg;
    defer replan.deinit(&site, &.{}, startup_cfg);
    // The cold pipeline installed and locked this project: the baseline.
    replan.baseline();
    try runCommitted(&replan, &ctx);
    try std.testing.expectEqual(@as(usize, 0), Spy.count);

    // The project gains a remote package the startup install never saw.
    try tmp.dir.writeFile(io, .{ .sub_path = "project/project.labelle", .data = ".{ .name = \"game\", .plugins = .{ " ++ local ++ ", " ++ remote ++ " } }" });
    // A failing install fails the replan (previous state kept) and is
    // retried on the next rebuild, with no lock written in between.
    Spy.fail_install = true;
    try std.testing.expectError(error.InstallFailed, Replanner.run(&replan, &ctx));
    try std.testing.expectEqual(@as(usize, 1), site.cfg.plugins.len);
    Spy.fail_install = false;
    try runCommitted(&replan, &ctx);
    // Installed first (discovery then found the package), locked for the
    // new project last.
    try std.testing.expectEqual(@as(usize, 3), Spy.count);
    try std.testing.expectEqualStrings("install", Spy.events[0]);
    try std.testing.expectEqualStrings("install", Spy.events[1]);
    try std.testing.expectEqualStrings("lock-2", Spy.events[2]);
    try std.testing.expectEqual(@as(usize, 2), site.cfg.plugins.len);
    // Unchanged again: nothing re-runs.
    try runCommitted(&replan, &ctx);
    try std.testing.expectEqual(@as(usize, 3), Spy.count);

    // Without the install the same edit is the reported failure: the
    // cache never learns about the package.
    var bare = Replanner{ .backing = a, .project_dir = project, .write_lock = Spy.lock };
    defer bare.deinit(&site, &.{}, startup_cfg);
    try std.Io.Dir.cwd().deleteTree(io, Spy.cache_dir);
    try std.testing.expectError(error.ProviderPackageMissing, Replanner.run(&bare, &ctx));
}

// The serve's shutdown runs the CURRENT generation's `after run` hooks:
// a rebuild that bumped the provider's version (and rewrote the lock)
// and swapped its after-run hook set leaves the startup plan stale —
// its pin fails `StaleProviderPin` and its hook set is the old one —
// while `shutdownRunAfter` hands the finish the replanned set, which
// runs against the new lock (Codex P2 on #427).
test "watched serve shutdown runs the replanned after-run hooks" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "pkg");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    const Files = struct {
        fn write(dir: std.Io.Dir, version: []const u8, hook_id: []const u8) !void {
            var buf: [1024]u8 = undefined;
            const manifest = try std.fmt.bufPrint(&buf, ".{{ .name = \"pkg\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{{ \"probe-target\" }}, .hooks = .{{ .{{ .id = \"{s}\", .step = .run, .target = \"probe-target\", .when = .after, .build_step = \"tool\", .executable = \"bin/tool\" }} }} }}", .{hook_id});
            try dir.writeFile(config.globalIo(), .{ .sub_path = "pkg/plugin.labelle", .data = manifest });
            var pbuf: [512]u8 = undefined;
            const proj = try std.fmt.bufPrint(&pbuf, ".{{ .name = \"game\", .plugins = .{{ .{{ .name = \"pkg\", .repo = \"local:../pkg\", .version = \"{s}\" }} }} }}", .{version});
            try dir.writeFile(config.globalIo(), .{ .sub_path = "project/project.labelle", .data = proj });
        }
    };
    const Spy = struct {
        var ran: [4][]const u8 = undefined;
        var count: usize = 0;
        fn tool(_: std.mem.Allocator, _: provider_dispatch.Host, _: []const u8, _: provider_dispatch.Provider, _: provider_contract.Tool, tool_run: provider_dispatch.ToolRun) anyerror!u8 {
            // Static ids from the fixture's two manifests.
            ran[count] = if (std.mem.eql(u8, tool_run.invocation.id, "publish-v2")) "publish-v2" else "other";
            count += 1;
            return 0;
        }
    };
    Spy.count = 0;

    // Startup: v1 with an after-run hook, installed and locked by the
    // cold pipeline; the startup plan is taken from that state.
    try Files.write(tmp.dir, "1.0.0", "publish-v1");
    var startup_arena = std.heap.ArenaAllocator.init(a);
    defer startup_arena.deinit();
    const sa = startup_arena.allocator();
    const startup_cfg = try config.readProjectConfig(sa, project);
    try lockfile.writeLockFile(sa, project, startup_cfg);
    var startup_sources: provider_github.Sources = .{ .a = sa };
    defer startup_sources.deinit();
    const startup_providers = try provider_dispatch.discover(sa, project, startup_cfg, &startup_sources, .populated);
    const startup_run = try provider_hooks.plan(sa, startup_providers, .run, "probe-target");
    try std.testing.expectEqualStrings("pkg/publish-v1", startup_run.after[0].qualified);

    const asm_path = try testing.okTool(a, tmp.dir);
    defer a.free(asm_path);
    var site = testing.testSite(a, project);
    site.providers = startup_providers;
    site.cfg = startup_cfg;
    site.host = .{ .zig = "/z", .cache_root = project, .global_cache = project, .packages = project };
    site.run_tool = Spy.tool;
    var ctx = RebuildCtx{
        .allocator = a,
        .asm_bin = .{ .path = asm_path },
        .project_dir = project,
        .platform_tag = "probe-target",
        .backend_tag = "probe",
        .output_dir = project,
        .target_dir = project,
        .zig_args = &.{asm_path},
        .zig_env = null,
        .prebuild_steps = &.{},
        .prebuild_opts = .{ .fatal_on_step_failure = false },
        .hooks = &site,
    };
    defer ctx.deinit();
    // The lock written in place (not staged), inside the rebuild's lock
    // transaction, which already holds the project lock (cli#481).
    const InPlace = struct {
        fn lock(la: std.mem.Allocator, dir: []const u8, cfg: project_config.ProjectConfig) anyerror!void {
            const path = try std.fs.path.join(la, &.{ dir, "labelle.lock" });
            defer la.free(path);
            try lockfile.writeLockFileTo(la, dir, cfg, path);
        }
    };
    var replan = Replanner{ .backing = a, .project_dir = project, .write_lock = InPlace.lock };
    defer replan.deinit(&site, startup_providers, startup_cfg);
    replan.baseline();
    // No rebuild has replanned yet: the startup plan is the shutdown's.
    try std.testing.expectEqual(startup_run.after.ptr, replan.shutdownRunAfter(startup_run.after).ptr);

    // A watched edit bumps the provider to v2 and swaps its after-run
    // hook; the rebuild's replan installs it and relocks.
    try Files.write(tmp.dir, "2.0.0", "publish-v2");
    try runCommitted(&replan, &ctx);

    // The startup plan is stale against the rewritten lock...
    try std.testing.expectError(error.StaleProviderPin, provider_hooks.finishServe(&site, startup_run.after, project));
    try std.testing.expectEqual(@as(usize, 0), Spy.count);
    // ...the shutdown's plan is the replanned one, and it runs.
    const after = replan.shutdownRunAfter(startup_run.after);
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqualStrings("pkg/publish-v2", after[0].qualified);
    try std.testing.expectEqual(@as(u8, 0), try provider_hooks.finishServe(&site, after, project));
    try std.testing.expectEqual(@as(usize, 1), Spy.count);
    try std.testing.expectEqualStrings("publish-v2", Spy.ran[0]);

    // A later edit that removes every after-run hook: shutdown runs none.
    try tmp.dir.writeFile(io, .{
        .sub_path = "pkg/plugin.labelle",
        .data = ".{ .name = \"pkg\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{ \"probe-target\" } }",
    });
    try runCommitted(&replan, &ctx);
    try std.testing.expectEqual(@as(usize, 0), replan.shutdownRunAfter(startup_run.after).len);
}

// Once a rebuild replanned, the site points into the replan's storage;
// releasing it puts the site back on the stable startup storage, so a
// shutdown hook after it can never read freed memory.
test "watch replan release restores the site's stable storage" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "pkg");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    try tmp.dir.writeFile(io, .{
        .sub_path = "pkg/plugin.labelle",
        .data = ".{ .name = \"pkg\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{ \"probe-target\" } }",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "project/project.labelle",
        .data = ".{ .name = \"game\", .plugins = .{ .{ .name = \"pkg\", .repo = \"local:../pkg\", .version = \"1.0.0\" } } }",
    });
    const Lock = struct {
        fn none(_: std.mem.Allocator, _: []const u8, _: project_config.ProjectConfig) anyerror!void {}
    };
    const stable_providers = [_]provider_dispatch.Provider{.{
        .dep = .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
        .dir = "/startup",
        .meta = .{ .name = "pkg", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0" },
        .verified = true,
    }};
    const stable_cfg: project_config.ProjectConfig = .{ .name = "startup" };
    const asm_path = try testing.okTool(a, tmp.dir);
    defer a.free(asm_path);
    var site = testing.testSite(a, project);
    site.providers = &stable_providers;
    site.cfg = stable_cfg;
    var ctx = RebuildCtx{
        .allocator = a,
        .asm_bin = .{ .path = asm_path },
        .project_dir = project,
        .platform_tag = "probe-target",
        .backend_tag = "probe",
        .output_dir = project,
        .target_dir = project,
        .zig_args = &.{asm_path},
        .zig_env = null,
        .prebuild_steps = &.{},
        .prebuild_opts = .{ .fatal_on_step_failure = false },
        .hooks = &site,
    };
    defer ctx.deinit();
    var replan = Replanner{ .backing = a, .project_dir = project, .write_lock = Lock.none };
    try runCommitted(&replan, &ctx);
    // The site now reads the replan's generation, not the startup storage.
    try std.testing.expect(site.providers.ptr != &stable_providers);
    try std.testing.expectEqualStrings("game", site.cfg.name);
    replan.deinit(&site, &stable_providers, stable_cfg);
    try std.testing.expect(replan.current == null);
    try std.testing.expect(site.providers.ptr == &stable_providers);
    try std.testing.expectEqualStrings("startup", site.cfg.name);
    try std.testing.expectEqualStrings("/startup", site.providers[0].dir);
}

// A replan installs the re-read `.prebuild` steps on the rebuild context,
// not only the hook config: the next rebuild runs the NEW steps, and a
// removed step stops running (Codex P2 on #460).
test "watch replan installs the re-read prebuild steps" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "pkg");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    try tmp.dir.writeFile(io, .{
        .sub_path = "pkg/plugin.labelle",
        .data = ".{ .name = \"pkg\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{ \"probe-target\" } }",
    });
    const head = ".{ .name = \"game\", .plugins = .{ .{ .name = \"pkg\", .repo = \"local:../pkg\", .version = \"1.0.0\" } }";
    try tmp.dir.writeFile(io, .{ .sub_path = "project/project.labelle", .data = head ++ ", .prebuild = .{ .{ .run = .{ \"gen-old\" } } } }" });
    const Lock = struct {
        fn none(_: std.mem.Allocator, _: []const u8, _: project_config.ProjectConfig) anyerror!void {}
    };
    const asm_path = try testing.okTool(a, tmp.dir);
    defer a.free(asm_path);
    var site = testing.testSite(a, project);
    const startup_steps = [_]prebuild.Step{.{ .run = &.{"gen-startup"} }};
    var ctx = RebuildCtx{
        .allocator = a,
        .asm_bin = .{ .path = asm_path },
        .project_dir = project,
        .platform_tag = "probe-target",
        .backend_tag = "probe",
        .output_dir = project,
        .target_dir = project,
        .zig_args = &.{asm_path},
        .zig_env = null,
        .prebuild_steps = &startup_steps,
        .prebuild_opts = .{ .fatal_on_step_failure = false },
        .hooks = &site,
    };
    defer ctx.deinit();
    var replan = Replanner{ .backing = a, .project_dir = project, .write_lock = Lock.none };
    const startup_cfg = site.cfg;
    defer replan.deinit(&site, &.{}, startup_cfg);

    try runCommitted(&replan, &ctx);
    try std.testing.expectEqual(@as(usize, 1), ctx.prebuild_steps.len);
    try std.testing.expectEqualStrings("gen-old", ctx.prebuild_steps[0].run[0]);

    // Changed: the next generation's steps replace the previous one's.
    try tmp.dir.writeFile(io, .{ .sub_path = "project/project.labelle", .data = head ++ ", .prebuild = .{ .{ .run = .{ \"gen-new\", \"--flag\" } }, .{ .run = .{ \"gen-extra\" } } } }" });
    try runCommitted(&replan, &ctx);
    try std.testing.expectEqual(@as(usize, 2), ctx.prebuild_steps.len);
    try std.testing.expectEqualStrings("gen-new", ctx.prebuild_steps[0].run[0]);
    try std.testing.expectEqualStrings("--flag", ctx.prebuild_steps[0].run[1]);
    try std.testing.expectEqualStrings("gen-extra", ctx.prebuild_steps[1].run[0]);

    // A failed replan keeps the installed steps (and their storage).
    try tmp.dir.writeFile(io, .{ .sub_path = "project/project.labelle", .data = "not zon" });
    if (Replanner.run(&replan, &ctx)) |_| return error.TestUnexpectedResult else |_| {}
    try std.testing.expectEqualStrings("gen-new", ctx.prebuild_steps[0].run[0]);

    // Removed: no step runs any more.
    try tmp.dir.writeFile(io, .{ .sub_path = "project/project.labelle", .data = head ++ " }" });
    try runCommitted(&replan, &ctx);
    try std.testing.expectEqual(@as(usize, 0), ctx.prebuild_steps.len);
}

// Contract §1 `.target_defaults`: every replan recomputes the effective
// optimize mode from the providers it rediscovers, so an edited default
// reaches the next rebuild's `-Doptimize` and wire `optimize`, and an
// explicit `--optimize` still wins.
test "watch replan recomputes the effective optimize mode from the owner's defaults" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "pkg");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    try tmp.dir.writeFile(io, .{
        .sub_path = "project/project.labelle",
        .data = ".{ .name = \"game\", .plugins = .{ .{ .name = \"pkg\", .repo = \"local:../pkg\", .version = \"1.0.0\" } } }",
    });
    const Manifest = struct {
        fn write(dir: std.Io.Dir, defaults: []const u8) !void {
            var buf: [512]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, ".{{ .name = \"pkg\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{{ \"probe-target\" }}, .target_defaults = .{{ {s} }} }}", .{defaults});
            try dir.writeFile(config.globalIo(), .{ .sub_path = "pkg/plugin.labelle", .data = text });
        }
        fn flags(args: []const []const u8) usize {
            var n: usize = 0;
            for (args) |arg| n += @intFromBool(std.mem.startsWith(u8, arg, "-Doptimize="));
            return n;
        }
    };
    const asm_path = try testing.okTool(a, tmp.dir);
    defer a.free(asm_path);
    var site = testing.testSite(a, project);
    var ctx = RebuildCtx{
        .allocator = a,
        .asm_bin = .{ .path = asm_path },
        .project_dir = project,
        .platform_tag = "probe-target",
        .backend_tag = "probe",
        .output_dir = project,
        .target_dir = project,
        // The startup plan, before any replan.
        .zig_args = &.{ "zig", "build", "-Doptimize=ReleaseSafe" },
        .zig_env = null,
        .prebuild_steps = &.{},
        .prebuild_opts = .{ .fatal_on_step_failure = false },
        .hooks = &site,
    };
    defer ctx.deinit();
    var replan = Replanner{ .backing = a, .project_dir = project };
    const startup_cfg = site.cfg;
    defer replan.deinit(&site, &.{}, startup_cfg);

    // The owner declares a default: it replaces the startup mode.
    try Manifest.write(tmp.dir, ".{ .target = \"probe-target\", .optimize = .ReleaseSmall }");
    try runCommitted(&replan, &ctx);
    try std.testing.expectEqual(provider_contract.Optimize.ReleaseSmall, site.optimize);
    try std.testing.expectEqualStrings("-Doptimize=ReleaseSmall", ctx.zig_args[ctx.zig_args.len - 1]);
    try std.testing.expectEqual(@as(usize, 1), Manifest.flags(ctx.zig_args));
    try std.testing.expectEqualStrings("build", ctx.zig_args[1]);
    // The default is edited away: no mode, so the flag is dropped and the
    // wire mode is Debug.
    try Manifest.write(tmp.dir, "");
    try runCommitted(&replan, &ctx);
    try std.testing.expectEqual(provider_contract.Optimize.Debug, site.optimize);
    try std.testing.expectEqualStrings("build", ctx.zig_args[ctx.zig_args.len - 1]);
    try std.testing.expectEqual(@as(usize, 0), Manifest.flags(ctx.zig_args));
    // An explicit flag wins over a declared default.
    ctx.optimize_flag = "Debug";
    try Manifest.write(tmp.dir, ".{ .target = \"probe-target\", .optimize = .ReleaseFast }");
    try runCommitted(&replan, &ctx);
    try std.testing.expectEqual(provider_contract.Optimize.Debug, site.optimize);
    try std.testing.expectEqualStrings("-Doptimize=Debug", ctx.zig_args[ctx.zig_args.len - 1]);
    try std.testing.expectEqual(@as(usize, 1), Manifest.flags(ctx.zig_args));
}

test "watch replan: withOptimize replaces or drops the flag, keeping every other argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const replaced = try Replanner.withOptimize(a, &.{ "zig", "build", "-Doptimize=Debug", "-Dother=1" }, "ReleaseFast");
    try std.testing.expectEqual(@as(usize, 4), replaced.len);
    try std.testing.expectEqualStrings("-Dother=1", replaced[2]);
    try std.testing.expectEqualStrings("-Doptimize=ReleaseFast", replaced[3]);
    const dropped = try Replanner.withOptimize(a, &.{ "zig", "build", "-Doptimize=Debug" }, null);
    try std.testing.expectEqual(@as(usize, 2), dropped.len);
}

// cli#471 D3 (CodeRabbit on #504): a watched rebuild applies the cold
// pipeline's support gate. A backend bump that makes `describe` refuse the
// pair fails THAT rebuild (the session lives on); no answer, a supported
// pair, a replaced generation or a target outside the schema pass.
test "watch replan: describe's unsupported verdict fails the rebuild before generation" {
    const Fake = struct {
        var calls: usize = 0;
        var reply: ?[]const u8 = null;
        fn spawn(_: std.mem.Allocator, _: []const []const u8) ?[]const u8 {
            calls += 1;
            return reply;
        }
        fn doc(comptime supported: []const u8, comptime reason: []const u8) []const u8 {
            return "{\"schema\":\"labelle.describe/v1\",\"target\":\"desktop\",\"target_dir\":\".labelle/acme_desktop\"," ++
                "\"backend\":{\"name\":\"acme\",\"id\":null,\"repo\":null,\"version\":\"2.0.0\",\"local_path\":null}," ++
                "\"asset_format\":\"png\",\"supported\":" ++ supported ++ reason ++ ",\"capabilities_source\":\"manifest\"}";
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const describer: @import("../assembler_describe.zig").Describer = .{ .bin_path = "/asm", .protocol = 7, .project_dir = "/proj", .spawn = Fake.spawn };
    const core: @import("../provider_targets.zig").Resolved = .{ .name = "desktop", .provider = null, .legacy = .desktop };

    Fake.reply = Fake.doc("false", ",\"reason\":\"provider 'acme.gfx' does not support capability 'probe'\"");
    try std.testing.expectError(error.BackendUnsupportedTarget, Replanner.generateGate(describer, a, "desktop", core, false));

    Fake.reply = Fake.doc("true", "");
    try Replanner.generateGate(describer, a, "desktop", core, false);
    // No answer (describe failed): the enum behaviour, i.e. proceed.
    Fake.reply = null;
    try Replanner.generateGate(describer, a, "desktop", core, false);
    try Replanner.generateGate(.off, a, "desktop", core, false);

    // Never asked when the core generation does not run for the target.
    Fake.reply = Fake.doc("false", ",\"reason\":\"x\"");
    Fake.calls = 0;
    try Replanner.generateGate(describer, a, "desktop", core, true);
    const foreign: @import("../provider_targets.zig").Resolved = .{ .name = "probe-target", .provider = null, .legacy = null };
    try Replanner.generateGate(describer, a, "probe-target", foreign, false);
    try std.testing.expectEqual(@as(usize, 0), Fake.calls);
}
