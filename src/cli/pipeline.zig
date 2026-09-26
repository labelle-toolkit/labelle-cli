//! Command-execution pipeline for the labelle CLI (#311). Extracted from
//! cli.zig `main` so the dispatcher stays small: this owns the
//! generate -> build -> run flow and the docker / wasm / ios / android
//! branches, plus the two execution helpers that go with it
//! (WasmRebuildCtx for `wasm serve --watch`; the export output-path
//! resolvers). Behavior is identical to when this lived in `main`.
const std = @import("std");
const builtin = @import("builtin");
const project_config = @import("project_config.zig");
const upgrade = @import("upgrade.zig");
const config = @import("config.zig");
const compatibility = @import("compatibility.zig");
const lockfile = @import("lockfile.zig");
const runner = @import("runner.zig");
const assembler = @import("assembler.zig");
const assembler_proc = @import("assembler_proc.zig");
const emsdk_toolchain = @import("emsdk_toolchain.zig");
const emsdk_activate = @import("emsdk_activate.zig");
const python_provision = @import("python_provision.zig");
const prebuild = @import("prebuild.zig");
const material_toolchain = @import("material_toolchain.zig");
const bake_mod = @import("bake.zig");
const docker = @import("docker.zig");
const serve = @import("serve.zig");
const export_mod = @import("export.zig");
const ios = @import("ios.zig");
const android = @import("android.zig");
const util = @import("util.zig");
const progress = @import("progress.zig");
const astc_cmd = @import("../astc/cmd.zig");
const sdl_provision = @import("sdl_provision.zig");
const bundle = @import("bundle.zig");
const linux_desktop = @import("linux_desktop.zig");
const args_mod = @import("args.zig");
const screenshot_format = @import("screenshot_format.zig");
const provider_contract = @import("provider_contract.zig");
const provider_dispatch = @import("provider_dispatch.zig");
const provider_github = @import("provider_github.zig");
const provider_hooks = @import("provider_hooks.zig");
const provider_targets = @import("provider_targets.zig");
const asm_cache = @import("asm_cache.zig");
const ParsedArgs = args_mod.ParsedArgs;
const appendRunForwardedArgs = args_mod.appendRunForwardedArgs;
const resolveAndroidBackend = args_mod.resolveAndroidBackend;

/// Rebuild context for `wasm serve --watch` (cli#208). Bundles the
/// generate+build inputs the initial pipeline computed so the serve
/// loop's watcher thread can re-run them on a source change. Passed to
/// `serve.serveAndOpen` as an opaque `*anyopaque` + a static `rebuild`
/// entry point matching `serve.RebuildFn`.
const WasmRebuildCtx = struct {
    allocator: std.mem.Allocator,
    asm_bin: assembler_proc.Assembler,
    project_dir: []const u8,
    platform_tag: []const u8,
    backend_tag: []const u8,
    output_dir: []const u8,
    target_dir: []const u8,
    zig_args: []const []const u8,
    zig_env: ?*const std.process.Environ.Map,
    /// The project's declared `.prebuild` steps (cli#355), borrowed from
    /// the parse arena. A watched rebuild must re-run them: they are what
    /// turn an edited `.tsx`/generator into the atlas or `.zig` table the
    /// regeneration below then reads, so skipping them would serve a
    /// "successful" rebuild made of STALE generated assets — the exact
    /// silent-staleness bug the hook exists to kill.
    prebuild_steps: []const prebuild.Step,
    /// Options for those steps. `fatal_on_step_failure = false` here: a
    /// failing step in watch mode must report and keep the server alive,
    /// like a failing `generate` or `zig build` already does — not exit
    /// the process out from under the serve loop.
    prebuild_opts: prebuild.Options,
    /// The prebuild runner. A field only so the stage-order test below can
    /// observe whether the steps ran without spawning them; production never
    /// overrides it.
    run_prebuild: *const fn (std.mem.Allocator, []const u8, []const prebuild.Step, prebuild.Options) prebuild.Error!void = prebuild.runAll,
    /// The shader-compiler override gate, run AFTER the prebuild steps and
    /// the `before generate` hooks and BEFORE generation on every rebuild — the same function the cold
    /// pipeline runs before its `assembler generate`. It is a field only so
    /// the stage test below can supply the override value without touching
    /// the process environment; production never overrides the default.
    shader_preflight: *const fn (std.mem.Allocator, []const u8) anyerror!void = material_toolchain.preflight,
    /// Provider lifecycle hooks (contract §6). A watched rebuild re-runs the
    /// SAME `generate` and `build` plans the cold pipeline ran, in the same
    /// before / core-or-replace / after order — hooks that generate inputs
    /// or post-process the WASM output would otherwise serve stale or
    /// incomplete artifacts after the first watched edit, and a `replace`
    /// hook's step would silently fall back to the core operation (Codex P2
    /// on #420). `hooks` is the cold pipeline's site; with no plugins every
    /// plan is empty and no phase runs.
    hooks: *provider_hooks.Site,
    generate_plan: provider_hooks.Plan = .{},
    build_plan: provider_hooks.Plan = .{},
    /// Rediscovers the providers and replans both phases at the start of
    /// EVERY rebuild, so a watched edit to `project.labelle`, to a provider
    /// manifest or to `provider_config` reaches the next rebuild. The
    /// startup plans above are only the initial state; with a replan
    /// installed they never run a rebuild themselves (they were captured
    /// once and reused for every rebuild, so removed hooks kept running and
    /// added ones were skipped until the server restarted — Codex P2 on
    /// #420). Production installs `WatchReplan`; `null` keeps the startup
    /// plans (the plumbing tests' shape). A failing replan stops the rebuild
    /// before any phase and leaves the previous plans installed.
    replan: ?Replan = null,
    /// The step output directories of the layout contract, as the cold
    /// pipeline computed them (`provider_hooks.stepOutputDir`).
    generate_out: []const u8 = "",
    build_out: []const u8 = "",
    /// The phase runner. A field only so the plumbing test below can record
    /// the phases without a host compiler; production never overrides it.
    run_hook_phase: *const fn (*provider_hooks.Site, []const provider_hooks.Planned, provider_contract.Step, provider_contract.Phase, []const u8) anyerror!u8 = provider_hooks.runPhase,

    /// Which stage a rebuild stopped at. Ordered as the stages run; the
    /// watch loop only needs the bool, but the test asserts the ORDER —
    /// that the shader preflight fires before generation is attempted.
    const Stage = error{
        ReplanFailed,
        PrebuildFailed,
        HookFailed,
        ShaderPreflightFailed,
        GenerateFailed,
        FingerprintFailed,
        ZigSpawnFailed,
        BuildFailed,
    };

    /// The per-rebuild replan seam: `run` receives `ctx` and the context it
    /// must update (`hooks.providers`, `hooks.cfg`, `generate_plan`,
    /// `build_plan`).
    pub const Replan = struct {
        ctx: *anyopaque,
        run: *const fn (*anyopaque, *WasmRebuildCtx) anyerror!void,
    };

    /// One hook phase of a watched rebuild. A failing hook (nonzero exit, or
    /// an error resolving the host/pin) stops the rebuild like a failing
    /// core step does: reported, server kept alive, browser not reloaded.
    fn hookPhase(self: *WasmRebuildCtx, list: []const provider_hooks.Planned, step: provider_contract.Step, phase: provider_contract.Phase, output_dir: []const u8) Stage!void {
        if (list.len == 0) return;
        const code = self.run_hook_phase(self.hooks, list, step, phase, output_dir) catch |err| {
            std.debug.print("labelle: rebuild {s} {s} hook failed ({s})\n", .{ @tagName(phase), @tagName(step), @errorName(err) });
            return error.HookFailed;
        };
        if (code != 0) return error.HookFailed;
    }

    /// Re-run prebuild → generate → fixFingerprints → `zig build`. Returns
    /// true only on a clean rebuild; on any failure it prints the error
    /// (keeping the server alive) and returns false so the browser is NOT
    /// reloaded onto a broken build.
    fn rebuild(ctx_ptr: *anyopaque) bool {
        const self: *WasmRebuildCtx = @ptrCast(@alignCast(ctx_ptr));
        self.rebuildStaged() catch return false;
        return true;
    }

    fn rebuildStaged(self: *WasmRebuildCtx) Stage!void {
        const a = self.allocator;

        // 0. Re-read the project, rediscover the providers, re-check that
        //    the served target still has a pinned owner and replan the hook
        //    phases for THIS rebuild (see `replan`) — FIRST, ahead of every
        //    side-effecting stage. A watched edit that removes or unpins the
        //    target owner used to be refused only after the prebuild
        //    commands below had already run once for the invalid
        //    configuration (Codex P2 on #421). A failing replan — a
        //    malformed manifest saved mid-session, say — is reported like a
        //    failing core step and stops here, before any stage.
        if (self.replan) |replan| {
            replan.run(replan.ctx, self) catch |err| {
                std.debug.print("labelle: rebuild stopped before prebuild: provider replan failed ({s})\n", .{@errorName(err)});
                return error.ReplanFailed;
            };
        }

        // 0a. Re-run the declared prebuild steps, ahead of generation just
        //     as the initial pipeline does. Steps that declare `.inputs` +
        //     `.outputs` are skipped while fresh, so the common watch
        //     iteration costs a few stats — and their declared `.outputs`
        //     are excluded from the watch signature (`ignore_files` at the
        //     `serveAndOpen` call below), so the run that DOES regenerate
        //     them no longer looks like a fresh edit on the next poll.
        //     A step that declares no `.outputs` runs on every rebuild by
        //     design and is not excluded from anything; if such a step
        //     also writes into the watched tree the watcher re-baselines
        //     after one follow-up rebuild (`serve.WatchBaseline`), but
        //     declaring `.outputs` avoids even that one.
        self.run_prebuild(a, self.project_dir, self.prebuild_steps, self.prebuild_opts) catch |err| {
            std.debug.print("labelle: rebuild prebuild step failed ({s})\n", .{@errorName(err)});
            return error.PrebuildFailed;
        };

        // 0b. The `before generate` hooks, then the shader-compiler override
        //     gate AFTER them (a prebuild step or a before-generate hook may
        //     be what creates `materials/`; Codex P2 on #420) and BEFORE the
        //     core generation. The cold pipeline gates at startup and again
        //     after its own before-generate hooks; a project that gains
        //     `materials/` while being watched would otherwise skip it and
        //     hit the opaque compiler failure this gate exists to replace.
        try self.hookPhase(self.generate_plan.before, .generate, .before, self.generate_out);
        self.shader_preflight(a, self.project_dir) catch |err| {
            std.debug.print("labelle: rebuild stopped before generate: shader compiler override rejected ({s})\n", .{@errorName(err)});
            return error.ShaderPreflightFailed;
        };

        // 1. Regenerate — scene/prefab/script *structure* (new files, added
        //    components) can change, not just @embedFile'd content. Wrapped
        //    in the `generate` hook phases exactly like the cold pipeline
        //    (its `before` phase ran with the gate above).
        if (self.generate_plan.replace) |replacement| {
            try self.hookPhase(&.{replacement}, .generate, .replace, self.generate_out);
        } else {
            assembler_proc.generate(self.asm_bin, a, self.project_dir, self.platform_tag, self.backend_tag) catch |err| {
                std.debug.print("labelle: rebuild generate failed ({s})\n", .{@errorName(err)});
                return error.GenerateFailed;
            };
            // 2. `generate` rewrites build.zig with a placeholder fingerprint;
            //    re-fix it before building.
            runner.fixFingerprints(a, self.project_dir, self.output_dir) catch |err| {
                std.debug.print("labelle: rebuild fingerprint fix failed ({s})\n", .{@errorName(err)});
                return error.FingerprintFailed;
            };
        }
        try self.hookPhase(self.generate_plan.after, .generate, .after, self.generate_out);
        // 3. Rebuild the WASM bundle (captured output so a compile error
        //    surfaces in the terminal without killing the serve loop),
        //    inside the `build` hook phases.
        try self.hookPhase(self.build_plan.before, .build, .before, self.build_out);
        if (self.build_plan.replace) |replacement| {
            try self.hookPhase(&.{replacement}, .build, .replace, self.build_out);
        } else {
            try self.coreBuild();
        }
        try self.hookPhase(self.build_plan.after, .build, .after, self.build_out);
    }

    fn coreBuild(self: *WasmRebuildCtx) Stage!void {
        const a = self.allocator;
        const res = runner.runZigWithEnv(a, self.target_dir, self.zig_args, self.zig_env) catch |err| {
            std.debug.print("labelle: rebuild could not spawn zig ({s})\n", .{@errorName(err)});
            return error.ZigSpawnFailed;
        };
        defer a.free(res.stdout);
        defer a.free(res.stderr);
        switch (res.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("labelle: rebuild failed:\n{s}\n", .{res.stderr});
                return error.BuildFailed;
            },
            else => {
                std.debug.print("labelle: rebuild terminated abnormally\n{s}\n", .{res.stderr});
                return error.BuildFailed;
            },
        }
    }

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
        const default_gate = std.meta.fieldInfo(WasmRebuildCtx, .shader_preflight).defaultValue() orelse return error.TestUnexpectedResult;
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
        var site = testSite(a, project);
        var ctx = WasmRebuildCtx{
            .allocator = a,
            .asm_bin = .{ .path = asm_path },
            .project_dir = project,
            .platform_tag = "wasm",
            .backend_tag = "bgfx",
            .output_dir = project,
            .target_dir = project,
            .zig_args = &.{},
            .zig_env = null,
            .prebuild_steps = &.{},
            .prebuild_opts = .{ .fatal_on_step_failure = false },
            .shader_preflight = Fixture.invalidOverride,
            .hooks = &site,
        };

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
            .hook = .{ .id = "gen", .step = .generate, .target = "wasm", .when = .before, .build_step = "tool", .executable = "bin/tool" },
            .qualified = "pkg/gen",
        }} };
        try std.testing.expectError(error.ShaderPreflightFailed, ctx.rebuildStaged());
        try std.testing.expect(Hook.ran);

        // materials/ stays: every later rebuild stops at the preflight too.
        ctx.generate_plan = .{};
        try std.testing.expectError(error.ShaderPreflightFailed, ctx.rebuildStaged());
        try std.testing.expect(!rebuild(@ptrCast(&ctx)));
    }

    /// A hook site with no providers, for the rebuild tests: the plans are
    /// what the tests supply; nothing here reaches a compiler or a lock.
    fn testSite(a: std.mem.Allocator, project: []const u8) provider_hooks.Site {
        return .{
            .a = a,
            .backing = a,
            .providers = &.{},
            .root = project,
            .cfg = .{ .name = "game" },
            .target = "wasm",
            .optimize = .ReleaseSafe,
            .progress = .off,
            .reporter = null,
        };
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
        const default_runner = std.meta.fieldInfo(WasmRebuildCtx, .run_hook_phase).defaultValue() orelse return error.TestUnexpectedResult;
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
                    .hook = .{ .id = id, .step = step, .target = "wasm", .when = when, .build_step = "tool", .executable = "bin/tool" },
                    .qualified = id,
                };
            }
        };

        // No assembler and no compiler exist at these paths, so the core
        // steps are observable as GenerateFailed / ZigSpawnFailed —
        // distinct from any hook outcome.
        const asm_path = try a.dupe(u8, "/nonexistent/labelle-assembler-probe");
        defer a.free(asm_path);
        var site = testSite(a, project);
        var ctx = WasmRebuildCtx{
            .allocator = a,
            .asm_bin = .{ .path = asm_path },
            .project_dir = project,
            .platform_tag = "wasm",
            .backend_tag = "bgfx",
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
        try std.testing.expect(rebuild(@ptrCast(&ctx)));

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
        try std.testing.expect(!rebuild(@ptrCast(&ctx)));

        // So does a hook the runner cannot even start (an unpinned remote
        // provider): the error is reported, not propagated out of the loop.
        ctx.generate_plan.after = &.{};
        ctx.build_plan.before = &.{Fixture.planned("unpinned", .build, .before)};
        Spy.reset();
        try std.testing.expectError(error.HookFailed, ctx.rebuildStaged());
        try std.testing.expectEqual(@as(usize, 3), Spy.count);
        try std.testing.expectEqualStrings("unpinned", Spy.calls[2].id);
    }

    // The replan seam: every rebuild replans before its first phase, the
    // plans the replan installs are the ones that run, and a failing replan
    // stops the rebuild ahead of every phase with the previous plans intact.
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
                    .hook = .{ .id = id, .step = step, .target = "wasm", .when = when, .build_step = "tool", .executable = "bin/tool" },
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
            fn replan(ptr: *anyopaque, ctx: *WasmRebuildCtx) anyerror!void {
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
            // The prebuild runner: counts runs, and records whether the
            // replan of this rebuild had already happened.
            var prebuilds: usize = 0;
            var replans_at_prebuild: usize = 0;
            fn runPrebuild(_: std.mem.Allocator, _: []const u8, _: []const prebuild.Step, _: prebuild.Options) prebuild.Error!void {
                prebuilds += 1;
                replans_at_prebuild = replans;
            }
        };
        var counter: usize = 0;
        const asm_path = try a.dupe(u8, "/nonexistent/labelle-assembler-probe");
        defer a.free(asm_path);
        var site = testSite(a, project);
        var ctx = WasmRebuildCtx{
            .allocator = a,
            .asm_bin = .{ .path = asm_path },
            .project_dir = project,
            .platform_tag = "wasm",
            .backend_tag = "bgfx",
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
            .replan = .{ .ctx = &counter, .run = Spy.replan },
        };
        // Production wiring: the default prebuild runner IS the cold one.
        const default_prebuild = std.meta.fieldInfo(WasmRebuildCtx, .run_prebuild).defaultValue() orelse return error.TestUnexpectedResult;
        try std.testing.expect(default_prebuild == prebuild.runAll);

        // Rebuild 1: replanned once; the FRESH plans ran, the startup plans
        // did not. The replan came first: the prebuild steps ran after it.
        Spy.reset();
        try ctx.rebuildStaged();
        try std.testing.expectEqual(@as(usize, 1), counter);
        try std.testing.expectEqual(@as(usize, 1), Spy.prebuilds);
        try std.testing.expectEqual(@as(usize, 1), Spy.replans_at_prebuild);
        try std.testing.expectEqual(@as(usize, 2), Spy.phase_count);
        try std.testing.expectEqualStrings("gen-fresh", Spy.phases[0]);
        try std.testing.expectEqualStrings("build-fresh", Spy.phases[1]);
        // Rebuild 2: replanned again — once per rebuild, not once per session.
        Spy.reset();
        try std.testing.expect(rebuild(@ptrCast(&ctx)));
        try std.testing.expectEqual(@as(usize, 2), counter);
        try std.testing.expectEqual(@as(usize, 2), Spy.phase_count);
        // A failing replan stops the rebuild before any phase, and the plans
        // installed by the last good replan stay in place.
        Spy.fail_next = true;
        Spy.reset();
        try std.testing.expectError(error.ReplanFailed, ctx.rebuildStaged());
        try std.testing.expectEqual(@as(usize, 3), counter);
        try std.testing.expectEqual(@as(usize, 0), Spy.phase_count);
        // ...and before the prebuild steps: an edit that drops or unpins the
        // served target's owner runs no side-effecting prebuild work for
        // the refused configuration (Codex P2 on #421).
        try std.testing.expectEqual(@as(usize, 0), Spy.prebuilds);
        try std.testing.expectEqualStrings("gen-fresh", ctx.generate_plan.replace.?.hook.id);
        try std.testing.expectEqualStrings("build-fresh", ctx.build_plan.replace.?.hook.id);
        Spy.fail_next = false;
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
};

/// The production replan for `wasm serve --watch` (`WasmRebuildCtx.replan`):
/// re-reads `project.labelle`, brings the package cache and `labelle.lock`
/// in line with it when it changed, rediscovers the providers with the
/// package cache `.populated` and replans the `generate` and `build` phases
/// for the target being served. Each successful replan lives on its own
/// arena; the previous generation — its arena and any pinned provider
/// sources it extracted — is released only once the new one is installed,
/// so a failed replan leaves the context pointing at intact storage.
const WatchReplan = struct {
    backing: std.mem.Allocator,
    project_dir: []const u8,
    /// Storage of the plans currently installed on the context. `null`
    /// until the first replan: the startup plans live on the pipeline's
    /// hook arena, which outlives the server.
    current: ?*Generation = null,
    /// Populates the package cache for the project as it now reads — the
    /// cold pipeline's `assembler install`. `null` skips the install (the
    /// plumbing tests' shape).
    installer: ?Installer = null,
    /// Rewrites `labelle.lock` for the re-read project, as the cold pipeline
    /// does before generation. A field only so a test can observe it.
    write_lock: *const fn (std.mem.Allocator, []const u8, project_config.ProjectConfig) anyerror!void = lockfile.writeLockFile,
    /// SHA-256 of the `project.labelle` bytes the package cache and the lock
    /// were last brought in line with. `null` until `baseline` or the first
    /// replan. A replan that reads the same bytes skips the install and the
    /// lock write: the common watched edit (a script, an asset) costs
    /// nothing here.
    synced: ?[32]u8 = null,

    /// The package-cache install seam: `run(ctx, allocator, project_dir)`.
    const Installer = struct {
        ctx: *const anyopaque,
        run: *const fn (*const anyopaque, std.mem.Allocator, []const u8) anyerror!void,
    };

    /// Production installer: the pipeline's `AssemblerInstaller`.
    fn assemblerInstaller(installer: *const AssemblerInstaller) Installer {
        return .{ .ctx = installer, .run = struct {
            fn run(ctx: *const anyopaque, a: std.mem.Allocator, project_dir: []const u8) anyerror!void {
                const self: *const AssemblerInstaller = @ptrCast(@alignCast(ctx));
                return self.install(a, project_dir);
            }
        }.run };
    }

    fn digestProject(a: std.mem.Allocator, project_dir: []const u8) ![32]u8 {
        const path = try std.fs.path.join(a, &.{ project_dir, "project.labelle" });
        defer a.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, a, .limited(16 * 1024 * 1024));
        defer a.free(bytes);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        return digest;
    }

    /// Record the project the cold pipeline just installed and locked, so
    /// the first replan does not repeat that work for unchanged bytes.
    fn baseline(self: *WatchReplan) void {
        self.synced = digestProject(self.backing, self.project_dir) catch null;
    }

    const Generation = struct {
        arena: std.heap.ArenaAllocator,
        sources: provider_github.Sources,

        /// Heap-allocated so the arena's address is stable: every allocator
        /// handle carved from it (the sources' included) points at it.
        fn create(backing: std.mem.Allocator) !*Generation {
            const generation = try backing.create(Generation);
            generation.* = .{ .arena = std.heap.ArenaAllocator.init(backing), .sources = undefined };
            generation.sources = .{ .a = generation.arena.allocator() };
            return generation;
        }

        fn destroy(self: *Generation, backing: std.mem.Allocator) void {
            self.sources.deinit();
            self.arena.deinit();
            backing.destroy(self);
        }
    };

    fn run(ptr: *anyopaque, ctx: *WasmRebuildCtx) anyerror!void {
        const self: *WatchReplan = @ptrCast(@alignCast(ptr));
        const next = try Generation.create(self.backing);
        errdefer next.destroy(self.backing);
        const a = next.arena.allocator();
        const digest = try digestProject(a, self.project_dir);
        var cfg = try config.readProjectConfig(a, self.project_dir);
        // The served target's platform and backend are the pipeline's
        // resolved ones (`wasm serve` overrides what the file declares).
        cfg.platform = ctx.hooks.cfg.platform;
        cfg.backend = ctx.hooks.cfg.backend;
        // An edited `project.labelle` may declare a package the startup
        // install never fetched and the startup lock never pinned: install
        // first, as the cold pipeline does ahead of discovery, or an added
        // remote provider fails `.populated` discovery with
        // `ProviderPackageMissing` and an added local one's first hook
        // fails `MissingProviderPin` — on every rebuild until the server
        // restarts (Codex P2 on #420).
        const changed = if (self.synced) |synced| !std.mem.eql(u8, &synced, &digest) else true;
        if (changed) if (self.installer) |installer| try installer.run(installer.ctx, a, self.project_dir);
        const providers: []const provider_dispatch.Provider = if (cfg.plugins.len == 0)
            &.{}
        else
            try provider_dispatch.discover(a, ctx.hooks.root, cfg, &next.sources, .populated);
        // The served target must still have a pinned owner among the NEW
        // providers: an edit that drops the owning package, or unpins a
        // remote owner, fails this rebuild with the cold pipeline's
        // diagnostic and keeps the previous state — installing empty plans
        // would generate for a target nobody owns (Codex P1 on #421).
        switch (try confirmTarget(a, providers, ctx.hooks.target)) {
            .resolved => {},
            .refused => |kind| return switch (kind) {
                .no_provider => error.NoProviderForTarget,
                .unpinned_owner => error.UnverifiedTargetOwner,
            },
        }
        const generate_plan = try provider_hooks.plan(a, providers, .generate, ctx.hooks.target);
        const build_plan = try provider_hooks.plan(a, providers, .build, ctx.hooks.target);
        // The lock follows the re-read project once the target is confirmed
        // and the plans are good — the cold pipeline's order — and before
        // any hook runs, since each hook verifies its pin against it.
        if (changed) try self.write_lock(a, self.project_dir, cfg);
        self.synced = digest;
        // Install only now, so a failure above leaves the previous plans —
        // and their storage — untouched.
        ctx.hooks.providers = providers;
        ctx.hooks.cfg = cfg;
        ctx.generate_plan = generate_plan;
        ctx.build_plan = build_plan;
        if (self.current) |previous| previous.destroy(self.backing);
        self.current = next;
    }

    /// Release the current generation. Once a replan succeeded, `site`'s
    /// `providers` and `cfg` point into that generation, so they are put back
    /// on the caller's stable (startup) storage first: nothing on the site
    /// may dangle, whatever runs after this (Codex P2 on #420).
    fn deinit(self: *WatchReplan, site: *provider_hooks.Site, stable_providers: []const provider_dispatch.Provider, stable_cfg: project_config.ProjectConfig) void {
        if (self.current) |generation| {
            site.providers = stable_providers;
            site.cfg = stable_cfg;
            generation.destroy(self.backing);
        }
        self.current = null;
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
                try writeAt(dir, "pkg/plugin.labelle", "\"wasm\"", hooks);
            }
        };
        const gen_hook = ".{ .id = \"gen\", .step = .generate, .target = \"wasm\", .when = .before, .build_step = \"tool\", .executable = \"bin/tool\" }";
        const build_hook = ".{ .id = \"post\", .step = .build, .target = \"wasm\", .when = .after, .build_step = \"tool\", .executable = \"bin/tool\" }";
        try Manifest.write(tmp.dir, gen_hook);

        const asm_path = try a.dupe(u8, "/nonexistent/labelle-assembler-probe");
        defer a.free(asm_path);
        var site = WasmRebuildCtx.testSite(a, project);
        var ctx = WasmRebuildCtx{
            .allocator = a,
            .asm_bin = .{ .path = asm_path },
            .project_dir = project,
            .platform_tag = "wasm",
            .backend_tag = "bgfx",
            .output_dir = project,
            .target_dir = project,
            .zig_args = &.{},
            .zig_env = null,
            .prebuild_steps = &.{},
            .prebuild_opts = .{ .fatal_on_step_failure = false },
            .hooks = &site,
        };
        var replan = WatchReplan{ .backing = a, .project_dir = project };
        const startup_cfg = site.cfg;
        defer replan.deinit(&site, &.{}, startup_cfg);

        // First replan: the manifest's generate hook is planned; the site
        // now knows the provider and the re-read config.
        try WatchReplan.run(&replan, &ctx);
        try std.testing.expectEqual(@as(usize, 1), ctx.generate_plan.before.len);
        try std.testing.expectEqualStrings("pkg/gen", ctx.generate_plan.before[0].qualified);
        try std.testing.expect(ctx.build_plan.isEmpty());
        try std.testing.expectEqual(@as(usize, 1), site.providers.len);
        try std.testing.expectEqual(@as(usize, 1), site.cfg.plugins.len);
        // The manifest changes between rebuilds: the next replan sees it.
        try Manifest.write(tmp.dir, build_hook);
        try WatchReplan.run(&replan, &ctx);
        try std.testing.expect(ctx.generate_plan.isEmpty());
        try std.testing.expectEqualStrings("pkg/post", ctx.build_plan.after[0].qualified);
        // A broken manifest fails the replan; the last good plans stay
        // installed and remain readable (their generation was kept).
        try tmp.dir.writeFile(io, .{ .sub_path = "pkg/plugin.labelle", .data = "not a manifest" });
        try std.testing.expectError(error.InvalidManifest, WatchReplan.run(&replan, &ctx));
        try std.testing.expectEqualStrings("pkg/post", ctx.build_plan.after[0].qualified);
        try Manifest.write(tmp.dir, build_hook);
        try WatchReplan.run(&replan, &ctx);
        const good = replan.current.?;

        // The served target loses its owner (Codex P1 on #421). Each case
        // fails the replan with the cold pipeline's error and keeps the
        // previous generation installed: its plans, its providers, its
        // config — never empty plans that would generate for an unowned
        // target.
        const Kept = struct {
            fn check(r: *const WatchReplan, c: *const WasmRebuildCtx, s: *const provider_hooks.Site, expected: *const WatchReplan.Generation) !void {
                try std.testing.expectEqual(expected, r.current.?);
                try std.testing.expectEqualStrings("pkg/post", c.build_plan.after[0].qualified);
                try std.testing.expectEqual(@as(usize, 1), s.providers.len);
                try std.testing.expectEqual(@as(usize, 1), s.cfg.plugins.len);
            }
        };
        // (a) The package stops declaring the target.
        try Manifest.writeAt(tmp.dir, "pkg/plugin.labelle", "", "");
        try std.testing.expectError(error.NoProviderForTarget, WatchReplan.run(&replan, &ctx));
        try Kept.check(&replan, &ctx, &site, good);
        try Manifest.write(tmp.dir, build_hook);
        // (b) The project drops the plugin altogether.
        try tmp.dir.writeFile(io, .{ .sub_path = "project/project.labelle", .data = ".{ .name = \"game\" }" });
        try std.testing.expectError(error.NoProviderForTarget, WatchReplan.run(&replan, &ctx));
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
        try Manifest.writeAt(tmp.dir, cached_manifest, "\"wasm\"", build_hook);
        try tmp.dir.writeFile(io, .{
            .sub_path = "project/project.labelle",
            .data = ".{ .name = \"game\", .plugins = .{ .{ .name = \"pkg\", .repo = \"example/pkg\", .version = \"1.0.0\" } } }",
        });
        try std.testing.expectError(error.UnverifiedTargetOwner, WatchReplan.run(&replan, &ctx));
        try Kept.check(&replan, &ctx, &site, good);
        try std.testing.expectEqualStrings("local:../pkg", site.cfg.plugins[0].repo);
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
            .data = ".{ .name = \"pkg\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{ \"wasm\" } }",
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

        const asm_path = try a.dupe(u8, "/nonexistent/labelle-assembler-probe");
        defer a.free(asm_path);
        var site = WasmRebuildCtx.testSite(a, project);
        var ctx = WasmRebuildCtx{
            .allocator = a,
            .asm_bin = .{ .path = asm_path },
            .project_dir = project,
            .platform_tag = "wasm",
            .backend_tag = "bgfx",
            .output_dir = project,
            .target_dir = project,
            .zig_args = &.{},
            .zig_env = null,
            .prebuild_steps = &.{},
            .prebuild_opts = .{ .fatal_on_step_failure = false },
            .hooks = &site,
        };
        var replan = WatchReplan{
            .backing = a,
            .project_dir = project,
            .installer = .{ .ctx = &Spy.count, .run = Spy.install },
            .write_lock = Spy.lock,
        };
        const startup_cfg = site.cfg;
        defer replan.deinit(&site, &.{}, startup_cfg);
        // The cold pipeline installed and locked this project: the baseline.
        replan.baseline();
        try WatchReplan.run(&replan, &ctx);
        try std.testing.expectEqual(@as(usize, 0), Spy.count);

        // The project gains a remote package the startup install never saw.
        try tmp.dir.writeFile(io, .{ .sub_path = "project/project.labelle", .data = ".{ .name = \"game\", .plugins = .{ " ++ local ++ ", " ++ remote ++ " } }" });
        // A failing install fails the replan (previous state kept) and is
        // retried on the next rebuild, with no lock written in between.
        Spy.fail_install = true;
        try std.testing.expectError(error.InstallFailed, WatchReplan.run(&replan, &ctx));
        try std.testing.expectEqual(@as(usize, 1), site.cfg.plugins.len);
        Spy.fail_install = false;
        try WatchReplan.run(&replan, &ctx);
        // Installed first (discovery then found the package), locked for the
        // new project last.
        try std.testing.expectEqual(@as(usize, 3), Spy.count);
        try std.testing.expectEqualStrings("install", Spy.events[0]);
        try std.testing.expectEqualStrings("install", Spy.events[1]);
        try std.testing.expectEqualStrings("lock-2", Spy.events[2]);
        try std.testing.expectEqual(@as(usize, 2), site.cfg.plugins.len);
        // Unchanged again: nothing re-runs.
        try WatchReplan.run(&replan, &ctx);
        try std.testing.expectEqual(@as(usize, 3), Spy.count);

        // Without the install the same edit is the reported failure: the
        // cache never learns about the package.
        var bare = WatchReplan{ .backing = a, .project_dir = project, .write_lock = Spy.lock };
        defer bare.deinit(&site, &.{}, startup_cfg);
        try std.Io.Dir.cwd().deleteTree(io, Spy.cache_dir);
        try std.testing.expectError(error.ProviderPackageMissing, WatchReplan.run(&bare, &ctx));
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
            .data = ".{ .name = \"pkg\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{ \"wasm\" } }",
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
        const asm_path = try a.dupe(u8, "/nonexistent/labelle-assembler-probe");
        defer a.free(asm_path);
        var site = WasmRebuildCtx.testSite(a, project);
        site.providers = &stable_providers;
        site.cfg = stable_cfg;
        var ctx = WasmRebuildCtx{
            .allocator = a,
            .asm_bin = .{ .path = asm_path },
            .project_dir = project,
            .platform_tag = "wasm",
            .backend_tag = "bgfx",
            .output_dir = project,
            .target_dir = project,
            .zig_args = &.{},
            .zig_env = null,
            .prebuild_steps = &.{},
            .prebuild_opts = .{ .fatal_on_step_failure = false },
            .hooks = &site,
        };
        var replan = WatchReplan{ .backing = a, .project_dir = project, .write_lock = Lock.none };
        try WatchReplan.run(&replan, &ctx);
        // The site now reads the replan's generation, not the startup storage.
        try std.testing.expect(site.providers.ptr != &stable_providers);
        try std.testing.expectEqualStrings("game", site.cfg.name);
        replan.deinit(&site, &stable_providers, stable_cfg);
        try std.testing.expect(replan.current == null);
        try std.testing.expect(site.providers.ptr == &stable_providers);
        try std.testing.expectEqualStrings("startup", site.cfg.name);
        try std.testing.expectEqualStrings("/startup", site.providers[0].dir);
    }
};

/// The watcher's `ignore_files` set for `wasm serve --watch`: the absolute
/// paths of every declared prebuild `.outputs` entry, anchored at
/// `project_dir`. Caller owns the list and every slice in it.
///
/// Excluding them is what stops the rebuild callback from tripping its own
/// watcher (cli#355): `watchLoop` records the signature captured BEFORE the
/// callback runs, so a hook's regeneration of `assets/out.png` otherwise
/// looked like a fresh edit on the next poll and fired a second full
/// generate/compile/reload. Same reasoning as the `.labelle/` skip.
///
/// `hooks_enabled` is the `LABELLE_NO_PREBUILD` kill switch, and the reason
/// it is a parameter rather than an assumption. With hooks off, the rebuild
/// callback writes none of these files, so the self-trigger cannot happen —
/// while excluding them anyway broke a documented use of the switch:
/// regenerating those outputs OUT OF BAND (in CI, or by hand) never reached
/// the watch signature, so the browser kept serving the previous build until
/// some unrelated watched file happened to change (cli#361 review). With
/// hooks off, the outputs are ordinary externally managed inputs and belong
/// in the watch set, so the set comes back empty.
///
/// Best-effort: a path that can't be joined is simply not excluded — that
/// costs a redundant rebuild, never a missed one.
fn collectPrebuildIgnorePaths(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    steps: []const prebuild.Step,
    hooks_enabled: bool,
) std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    if (!hooks_enabled) return out;
    for (steps) |step| {
        for (step.outputs) |rel| {
            const p = serve.watchIgnorePath(allocator, project_dir, rel) catch continue;
            out.append(allocator, p) catch {
                allocator.free(p);
                continue;
            };
        }
    }
    return out;
}

/// Resolve the `wasm export --output` value to a path the packager can
/// use. Absolute paths pass through; a relative path is anchored to the
/// project dir so `labelle wasm export ../game --output release` writes
/// under the project, matching where the build output already lives.
/// Caller owns the returned slice.
///
/// SAFETY: the export dir is wiped (`deleteTree`) on every run, so a
/// destructive `--output` — `.`, `..`, the project/cwd root, or any
/// ancestor of them — would delete the user's source tree. Such targets
/// are refused with `error.DestructiveOutputPath` instead. (The
/// complementary "non-empty dir not created by a prior export" guard
/// lives in `export.packageExport`, which owns the deletion.)
fn resolveExportOutput(allocator: std.mem.Allocator, project_dir: []const u8, output: []const u8) ![]const u8 {
    // Normalized form of `output` alone (collapses `.`/`..`; keeps a
    // relative path relative). `resolve` does NOT anchor relatives at the
    // cwd in Zig 0.16, so this is pure path math — no filesystem access,
    // which also keeps it unit-testable.
    const norm = try std.fs.path.resolve(allocator, &.{output});
    defer allocator.free(norm);

    const destructive = if (std.fs.path.isAbsolute(norm))
        // Absolute output: refuse the filesystem root (no parent to scope
        // the wipe) or the project dir / an ancestor of it when the
        // project path is itself absolute. Other absolute dirs are still
        // guarded by the non-empty-without-marker check in packageExport.
        std.fs.path.dirname(norm) == null or
            (std.fs.path.isAbsolute(project_dir) and try absTargetHitsProject(allocator, norm, project_dir))
    else
        // Relative output: refuse the project root itself (`.`) or any
        // path that escapes above it (leading `..`) — wiping either would
        // delete the project / a parent tree.
        std.mem.eql(u8, norm, ".") or escapesUpward(norm);

    if (destructive) {
        std.debug.print(
            "labelle wasm export: refusing to use '{s}' as --output\n" ++
                "  the export directory is wiped on every run, and this path is the\n" ++
                "  project directory, an ancestor of it, or the filesystem root.\n" ++
                "  choose a dedicated subdirectory, e.g. --output ./release\n",
            .{output},
        );
        return error.DestructiveOutputPath;
    }

    if (std.fs.path.isAbsolute(output)) return allocator.dupe(u8, output);
    return std.fs.path.join(allocator, &.{ project_dir, output });
}

/// True when a relative, normalized `norm` names the project root
/// itself (`.` is handled by the caller) via an upward escape — i.e. its
/// first path component is `..`. Separator-agnostic: matches both `../`
/// and `..\` so a Windows-style output is caught even if `resolve`
/// emitted the other separator.
fn escapesUpward(norm: []const u8) bool {
    if (std.mem.eql(u8, norm, "..")) return true;
    return norm.len > 2 and std.mem.eql(u8, norm[0..2], "..") and std.fs.path.isSep(norm[2]);
}

/// Path-boundary equality, case-insensitive on Windows (whose
/// filesystems are case-insensitive, so `C:\Proj` and `c:\proj` name the
/// same dir — a destructive-ancestor check must treat them as equal).
fn pathEql(a: []const u8, b: []const u8) bool {
    return if (@import("builtin").os.tag == .windows)
        std.ascii.eqlIgnoreCase(a, b)
    else
        std.mem.eql(u8, a, b);
}

/// True when the absolute, normalized output `norm` is the (absolute)
/// project dir itself or an ancestor of it.
fn absTargetHitsProject(allocator: std.mem.Allocator, norm: []const u8, project_dir: []const u8) !bool {
    const proj_abs = try std.fs.path.resolve(allocator, &.{project_dir});
    defer allocator.free(proj_abs);
    if (pathEql(norm, proj_abs)) return true;
    // `norm` is an ancestor of `proj_abs` only if it extends it at a path
    // boundary — guards against "/foo" matching "/foobar". `isSep` accepts
    // either separator so a mixed-separator input still lands correctly.
    return proj_abs.len > norm.len and
        pathEql(proj_abs[0..norm.len], norm) and
        std.fs.path.isSep(proj_abs[norm.len]);
}

/// cli#320: in `--progress=json` mode a desktop `run` spawns the game
/// with inherited stdout, so the game's own log lines share the stream
/// with the NDJSON progress records — pure NDJSON on stdout is a
/// `build`-only guarantee. Say so once, on stderr, at the run-phase
/// seam (the two call sites below are mutually exclusive branches, so
/// the note prints exactly once per invocation). No-op when no reporter
/// is active — without one there is no NDJSON stream to interleave with.
fn noteRunSharesStdout(reporter: ?*progress.Reporter) void {
    const r = reporter orelse return;
    if (r.mode != .json) return;
    std.debug.print("labelle: note: during `run`, game output shares stdout with NDJSON progress records\n", .{});
}

/// Cold-path stage order (cli#387 gap 3): the shader-compiler override gate
/// runs BEFORE `assembler install`, not after it. The gate is pure local
/// stat-ing; the install is a network-bound package fetch that can take
/// minutes, so validating afterwards made a one-character typo in
/// `LABELLE_SHADERC` cost a full download before the diagnostic appeared.
///
/// `installer` is a value with an `install(allocator, project_dir)` method
/// rather than a plain fn pointer because the real one carries the resolved
/// assembler binary. The seam exists so a test can observe that a rejected
/// override means the install step NEVER RAN, instead of inferring it from
/// wall-clock timing.
fn gateThenInstall(
    a: std.mem.Allocator,
    project_dir: []const u8,
    gate: *const fn (std.mem.Allocator, []const u8) anyerror!void,
    installer: anytype,
) !void {
    try gate(a, project_dir);
    try installer.install(a, project_dir);
}

/// Production installer: `labelle-assembler install --project-root <dir>`,
/// which populates the package cache `generate` assumes.
const AssemblerInstaller = struct {
    bin: assembler_proc.Assembler,

    fn install(self: AssemblerInstaller, a: std.mem.Allocator, project_dir: []const u8) !void {
        return self.bin.run(a, "install", &.{ "--project-root", project_dir });
    }
};

/// The cold pipeline's `before generate` phase, then the shader-compiler
/// override gate AGAIN. `gateThenInstall` validated the override before the
/// install, but a before-generate hook may be what creates `materials/`:
/// with no consumer at that point the gate passed, and an unusable
/// `LABELLE_SHADERC` then failed generation or the build with the opaque
/// error the gate exists to replace (Codex P2 on #420). The re-check runs
/// only when hooks ran — otherwise nothing changed since the first one —
/// and before every core generation input reader. On success the progress
/// detail is back on the core step (`provider_hooks.runBefore`).
fn beforeGenerate(
    site: *provider_hooks.Site,
    before: []const provider_hooks.Planned,
    output_dir: []const u8,
    project_dir: []const u8,
    gate: *const fn (std.mem.Allocator, []const u8) anyerror!void,
) !u8 {
    const code = try provider_hooks.runBefore(site, before, .generate, output_dir, "assembler generate");
    if (code != 0) return code;
    if (before.len != 0) try gate(site.backing, project_dir);
    return 0;
}

test "pipeline: the shader override is re-gated after the before-generate hooks" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    try tmp.dir.writeFile(io, .{
        .sub_path = "project/labelle.lock",
        .data = ".{ .plugins = .{ .{ .name = \"pkg\", .repo = \"local:../pkg\", .version = \"1.0.0\" } } }",
    });
    const Fixture = struct {
        var provider: provider_dispatch.Provider = .{
            .dep = .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
            .dir = "/pkg",
            .meta = .{ .name = "pkg", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0" },
            .verified = true,
        };
        var materials: []const u8 = "";
        var hook_ran = false;
        var gate_ran = false;
        // The before-generate hook creates `materials/`, the shape the
        // startup gate could not see.
        fn hook(_: std.mem.Allocator, _: provider_dispatch.Host, _: []const u8, _: provider_dispatch.Provider, _: provider_contract.Tool, _: provider_dispatch.ToolRun) anyerror!u8 {
            hook_ran = true;
            try std.Io.Dir.cwd().createDirPath(config.globalIo(), materials);
            return 0;
        }
        // The same gate the cold path runs, with the env read replaced by a
        // known-bad value.
        fn badOverride(alloc: std.mem.Allocator, dir: []const u8) anyerror!void {
            gate_ran = true;
            return material_toolchain.preflightWith(alloc, dir, "shaderc", .native);
        }
    };
    Fixture.materials = try std.fs.path.join(a, &.{ project, "materials" });
    // The startup gate (before the install) passes: no `materials/` yet.
    try gateThenInstall(a, project, Fixture.badOverride, struct {
        fn install(_: @This(), _: std.mem.Allocator, _: []const u8) !void {}
    }{});
    const planned: provider_hooks.Planned = .{
        .provider = &Fixture.provider,
        .hook = .{ .id = "gen", .step = .generate, .target = "desktop", .when = .before, .build_step = "tool", .executable = "bin/tool" },
        .qualified = "pkg/gen",
    };
    var site: provider_hooks.Site = .{
        .a = a,
        .backing = std.testing.allocator,
        .providers = &.{Fixture.provider},
        .root = project,
        .cfg = .{ .name = "game" },
        .target = "desktop",
        .optimize = .Debug,
        .progress = .off,
        .reporter = null,
        .host = .{ .zig = "/z", .cache_root = project, .global_cache = project, .packages = project },
        .run_tool = Fixture.hook,
    };
    // No hooks: nothing could have changed, so the gate is not re-run.
    Fixture.gate_ran = false;
    try std.testing.expectEqual(@as(u8, 0), try beforeGenerate(&site, &.{}, project, project, Fixture.badOverride));
    try std.testing.expect(!Fixture.gate_ran);
    // The hook creates `materials/`; the re-check fires after it and stops
    // the command before any core generation.
    try std.testing.expectError(error.ShadercOverrideMustBeAbsolute, beforeGenerate(&site, &.{planned}, project, project, Fixture.badOverride));
    try std.testing.expect(Fixture.hook_ran and Fixture.gate_ran);
}

test "a rejected shader override stops the cold build before any package is installed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project/materials");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);

    const Spy = struct {
        var installed: bool = false;
        fn install(_: @This(), _: std.mem.Allocator, _: []const u8) !void {
            installed = true;
        }
        // The same gate the cold and watched paths share, with the env read
        // replaced by a known-bad value.
        fn badOverride(alloc: std.mem.Allocator, dir: []const u8) anyerror!void {
            return material_toolchain.preflightWith(alloc, dir, "shaderc", .native);
        }
        fn badDockerOverride(alloc: std.mem.Allocator, dir: []const u8) anyerror!void {
            return material_toolchain.preflightWith(alloc, dir, "shaderc", .docker);
        }
        fn goodOverride(alloc: std.mem.Allocator, dir: []const u8) anyerror!void {
            return material_toolchain.preflightWith(alloc, dir, "/bin/sh", .native);
        }
    };

    Spy.installed = false;
    try std.testing.expectError(error.ShadercOverrideMustBeAbsolute, gateThenInstall(a, project, Spy.badOverride, Spy{}));
    // The point of the move: the network-bound install never ran.
    try std.testing.expect(!Spy.installed);

    // `--docker` takes the same ordering, not a bypass.
    Spy.installed = false;
    try std.testing.expectError(error.ShadercOverrideMustBeAbsolute, gateThenInstall(a, project, Spy.badDockerOverride, Spy{}));
    try std.testing.expect(!Spy.installed);

    // A valid override still reaches the install, so the assertions above
    // are the gate firing rather than the install being unreachable.
    Spy.installed = false;
    try gateThenInstall(a, project, Spy.goodOverride, Spy{});
    try std.testing.expect(Spy.installed);
}

/// Run the project-scoped pipeline: read project.labelle, then
/// generate -> build -> run (or the docker / wasm / ios / android
/// variant selected by `parsed_args`). Dispatch of the standalone
/// subcommands stays in cli.zig `main`; this is invoked only for the
/// project commands (generate / build / run / wasm / ios / android).
/// Returns the process exit status the command earned: the game's own exit
/// status for `run` (0 for a genuine `--timeout` expiry), 0 for everything
/// that completed. `main` returns it as the CLI's exit code, so automation
/// can tell a crash from a clean run (cli#390).
///
/// A build that stops the launch is always NONZERO: the build (docker /
/// progress / captured) fails through `error.BuildFailed`, i.e. exit 1,
/// because that error path is what runs this function's errdefers. The
/// build's real code is in the `failed` progress record.
/// A subcommand that completed is exit 0; its error propagates unchanged.
/// Lets `run` return a status while the subcommands it delegates to keep
/// their `!void` signatures.
fn ok(result: anytype) !u8 {
    if (comptime @typeInfo(@TypeOf(result)) == .error_union) try result;
    return 0;
}

/// Why `confirmTarget` refused the requested target. The kind survives to
/// the `failed` progress record, so a `labelle status --json` consumer can
/// tell an absent owner (add a provider) from an unpinned one (pin the
/// declared package) the same way the human diagnostic does (Codex on #421).
const TargetRefusal = enum {
    no_provider,
    unpinned_owner,

    /// The `detail` of the `failed` progress record.
    fn detail(self: TargetRefusal) []const u8 {
        return switch (self) {
            .no_provider => "no provider for target",
            .unpinned_owner => "unpinned provider for target",
        };
    }
};

const TargetVerdict = union(enum) {
    resolved: provider_targets.Resolved,
    refused: TargetRefusal,
};

/// The ownership half of target resolution with the pipeline's diagnostic:
/// `provider_targets.resolve` against the discovered providers, or the
/// refusal kind after printing its diagnostic (the no-provider line's
/// registry hint is read from the cached registry document only). The
/// caller marks its feed with the kind and exits.
fn confirmTarget(a: std.mem.Allocator, providers: []const provider_dispatch.Provider, requested: []const u8) !TargetVerdict {
    const resolved = provider_targets.resolve(providers, requested) catch |err| switch (err) {
        error.NoProviderForTarget => {
            provider_targets.reportNoProvider(a, requested);
            return .{ .refused = .no_provider };
        },
        // The owner is a remote package read from the ordinary cache with
        // no integrity pin: a target-owning provider is held to the pinned
        // boundary even when no hook of its would ever call `requirePinned`.
        error.UnverifiedTargetOwner => {
            provider_targets.reportUnverifiedOwner(a, providers, requested);
            return .{ .refused = .unpinned_owner };
        },
        else => return err,
    };
    return .{ .resolved = resolved };
}

/// The pre-install ownership verdict (`run`, step 3).
const EarlyVerdict = enum {
    /// A pinned provider owns the target in the complete metadata view.
    confirmed,
    /// A declared remote package is unread, so the view is partial; the
    /// post-install discovery decides.
    deferred,
    /// Refused, with `confirmTarget`'s diagnostic already printed.
    refused,
};

/// The metadata-only (`.unknown`) discovery and ownership check that runs
/// before the install. Everything it reads — the manifests, and the pinned
/// archives `Sources.fromPin` extracts (up to 128 MiB compressed, 512 MiB of
/// tar) — lives on a scratch arena carved from `backing` and freed before
/// this returns: only the verdict leaves. On the pipeline's long-lived arena
/// that storage was never reclaimed, so the authoritative discovery after
/// the install held every pinned provider twice, and a `wasm serve
/// --no-build` server kept both for its lifetime (Codex P2 on #421).
/// `error.ProviderDiscoveryFailed` after printing the reason.
fn earlyTargetCheck(backing: std.mem.Allocator, project_root: []const u8, cfg: project_config.ProjectConfig, requested: []const u8) !EarlyVerdict {
    var scratch = std.heap.ArenaAllocator.init(backing);
    defer scratch.deinit();
    const a = scratch.allocator();
    var sources: provider_github.Sources = .{ .a = a };
    defer sources.deinit();
    const early = provider_dispatch.discoverAll(a, project_root, cfg, &sources, .unknown) catch |err| {
        std.debug.print("labelle: provider discovery failed: {s}\n", .{@errorName(err)});
        return error.ProviderDiscoveryFailed;
    };
    if (early.unresolved.len != 0) return .deferred;
    return switch (try confirmTarget(a, early.providers, requested)) {
        .resolved => .confirmed,
        .refused => .refused,
    };
}

// The mechanism, not just the verdict: the check allocates from `backing`
// (so the discovery really ran on it) and returns every byte before it
// returns — nothing it read survives on a longer-lived allocator.
test "pipeline: the early target check frees its discovery before returning" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "pkg");
    const project = try tmp.dir.realPathFileAlloc(io, "project", std.testing.allocator);
    defer std.testing.allocator.free(project);
    try tmp.dir.writeFile(io, .{
        .sub_path = "pkg/plugin.labelle",
        .data = ".{ .name = \"pkg\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{ \"probe-target\" } }",
    });
    const cfg: project_config.ProjectConfig = .{ .name = "game", .plugins = &.{
        .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
    } };
    const cases = [_]struct { target: []const u8, verdict: EarlyVerdict }{
        .{ .target = "probe-target", .verdict = .confirmed },
        .{ .target = "other-target", .verdict = .refused },
    };
    for (cases) |case| {
        var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const verdict = try earlyTargetCheck(counting.allocator(), project, cfg, case.target);
        try std.testing.expectEqual(case.verdict, verdict);
        try std.testing.expect(counting.allocations > 0);
        try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
        try std.testing.expectEqual(counting.allocations, counting.deallocations);
    }
}

test "pipeline: each target refusal kind writes its own progress detail" {
    // The two kinds call for different fixes, so their records must differ
    // and the unpinned one must name the condition.
    try std.testing.expectEqualStrings("no provider for target", TargetRefusal.no_provider.detail());
    try std.testing.expectEqualStrings("unpinned provider for target", TargetRefusal.unpinned_owner.detail());
    try std.testing.expect(std.mem.indexOf(u8, TargetRefusal.unpinned_owner.detail(), "unpinned") != null);
    try std.testing.expect(std.mem.indexOf(u8, TargetRefusal.no_provider.detail(), "unpinned") == null);
}

pub fn run(allocator: std.mem.Allocator, parsed_args: ParsedArgs) !u8 {
    const command = parsed_args.command;
    const project_dir = parsed_args.project_dir;
    const timeout_ns = parsed_args.timeout_ns;

    // Read and parse project.labelle
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // Stale-CLI gate (#353), BEFORE the project parse: refuse to build a
    // project whose lock was written by a NEWER CLI —
    // `ignore_unknown_fields` means this binary would silently skip
    // config it doesn't know (the incident: per-atlas `.astc_block`
    // ignored → every atlas encoded at the old global block size,
    // visibly mangled art, zero errors). Running first also means a
    // newer project whose MIRRORED fields changed shape gets this
    // actionable message instead of a bare parse error. `upgrade` is
    // exempt: it is the way out of this error.
    if (command != .upgrade_cmd) {
        lockfile.enforceCliNotStale(allocator, project_dir, parsed_args.allow_older_cli) catch std.process.exit(1);
    }

    var parsed = config.readProjectConfig(arena.allocator(), project_dir) catch |err| {
        if (err == error.FileNotFound) {
            config.printNoProjectError(project_dir);
        }
        return 1;
    };

    // Normalize the deprecated `.initial_scene` alias (RFC #560 / #565)
    // into `.initial_prefab`. The `--scene=` flag does NOT rewrite
    // `.initial_prefab` anymore — it sets `LABELLE_SCENE=<name>` in the
    // spawned game's env (cli#229) and the project's loading-scene
    // controller reads it via `engine.requestedScene()` and transitions
    // once `assets.allReady`. The legacy initial-prefab-rewrite path was
    // removed because it bypassed the loading gate and made the game
    // stick on the target scene's async-load forever for projects with
    // a loading-scene gate.
    parsed.normalizeInitialPrefab();

    // The requested target (RFC #406 phase 3b, docs/provider-targets.md):
    // `--platform=<t>` — the legacy platform subcommands set the same
    // override — else the project's declared platform. It is resolved below
    // against the core target and the pinned providers' declarations;
    // `parsed.platform` is derived from the RESULT only where the pinned
    // assembler and the legacy sites still need the schema enum.
    const requested_target: []const u8 = parsed_args.platform_override orelse @tagName(parsed.platform);

    // Upgrade modifies project.labelle in the project directory
    if (command == .upgrade_cmd) {
        return ok(upgrade.cmdUpgrade(allocator, project_dir, parsed, parsed_args.extra_args[0..parsed_args.extra_count]));
    }

    // ── Target resolution, the NAME half (RFC #406 phase 3b) ──────────
    // (docs/provider-targets.md "Resolution")
    // The target is the core `desktop` or one a pinned provider declares;
    // nothing else, including the project's own `.platform` and the legacy
    // `wasm`/`ios`/`android` subcommands (no shim, RFC #406 "Migration").
    // Ownership needs the providers, and provider discovery runs only
    // after the assembler's `install` populated the package cache (below,
    // next to `gateThenInstall`; Codex P1 on #420) — while the target
    // directory, the progress feed and the schema platform every
    // pre-install step keys off need the name now. So the name is settled
    // here from the string alone: `desktop` is core; any other name is
    // PROVISIONALLY a provider target, confirmed against the discovered
    // providers right after the install and refused there when nobody
    // owns it. Two verdicts need no provider and land immediately:
    const hook_arena = arena.allocator();
    const project_root = try std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), project_dir, hook_arena);
    const provisional = try provider_targets.provisional(requested_target);
    // (1) A project that declares no packages can have no provider, so a
    //     provider target fails before anything is read, written or built.
    //     The registry hint in the failure line is read from the cached
    //     registry document only.
    if (!provisional.is_core and parsed.plugins.len == 0) {
        provider_targets.reportNoProvider(hook_arena, requested_target);
        return 1;
    }
    // (2) `labelle bundle` of the core target: the desktop packager is
    //     macOS-only and no hook can replace it (nobody may own `desktop`,
    //     so no `replace` hook on `bundle` can plan for it), so refuse it
    //     off macOS before any install or build, as the old `cli.zig` gate
    //     did. A provider target is packaged by its provider — checked
    //     with the plans, after discovery.
    if (command == .bundle_cmd and provisional.is_core and !bundle.hostSupported()) {
        bundle.printUnsupported();
        return 1;
    }
    // (3) A provider target whose ownership is decidable NOW is decided
    //     now, so an identifier-shaped typo (`--platform=waasm`) never runs
    //     `.prebuild`, the assembler resolution, the ASTC prepass or the
    //     install first (Codex on #421). This is the same metadata-only read
    //     `labelle targets` does (`.unknown`: cached manifests, no
    //     installer): when it can read EVERY declared package, the verdict
    //     — no owner, or an unpinned remote owner — is the one the
    //     post-install check would reach, so it lands here with the same
    //     diagnostics. A declared remote package it cannot read yet (cold
    //     cache, no pin) leaves the view partial, and the verdict waits for
    //     the post-install discovery, which stays the authoritative check.
    //     A manifest that fails discovery fails it closed here: the install
    //     cannot mend a manifest it can already read. Never for the core
    //     target, which needs no provider.
    //     The pass runs on a scratch arena of its own (`earlyTargetCheck`),
    //     so the pinned archives it reads are not held again beside the
    //     authoritative discovery's copies (Codex P2 on #421).
    if (!provisional.is_core) {
        switch (earlyTargetCheck(allocator, project_root, parsed, requested_target) catch return 1) {
            .confirmed, .deferred => {},
            .refused => return 1,
        }
    }
    // The legacy sites below (`parsed.platform == .X`; the guard's migration
    // allowlist) keep working for the schema-named provider targets. A
    // target outside the enum reaches only steps its provider does not
    // replace, which treat it as the generic host baseline. `parsed.platform`
    // is derived from the NAME only where the pinned assembler and the
    // legacy sites still need the schema enum.
    parsed.platform = provisional.legacy orelse .desktop;

    // `labelle ios` always implies the sokol backend (its target came
    // through the resolver like everything else).
    if (command == .ios_cmd) {
        parsed.backend = .sokol;
    }

    // Resolve the backend for ANY android-targeting invocation —
    // `labelle android`, `labelle run --platform=android`, or
    // `labelle build --platform=android` all land here. The backend is
    // taken from the project's declared backend, honoring an
    // Android-capable choice (`sokol` or `bgfx`) and falling back to
    // sokol otherwise (#252). Keying off the resolved platform (rather
    // than the subcommand) means a `.backend = .raylib` project run with
    // `--platform=android` gets the same helpful fallback as `labelle
    // android` instead of failing later on a missing `raylib_android`
    // target dir.
    if (parsed.platform == .android) {
        const android_backend = resolveAndroidBackend(parsed.backend);
        if (android_backend != parsed.backend) {
            std.debug.print(
                "labelle: backend '{s}' can't target Android; defaulting to sokol.\n",
                .{@tagName(parsed.backend)},
            );
        }
        parsed.backend = android_backend;
    }

    // `labelle wasm serve|export --no-build` — skip the generate+build
    // pipeline and serve/package the existing build output. The web dir
    // lives under the wasm target subdir (`.labelle/<backend>_wasm/`).
    //
    // Only generate and build are skipped: serving or exporting the existing
    // artifact IS the `run` step, so the `run` hook plan (contract §6) runs
    // here exactly as on the building path — `--no-build` used to return
    // before discovery and silently dropped every declared run hook (Codex
    // P2 on #420). No installer runs on this path, so discovery is the
    // metadata-only kind (`.unknown`, as `labelle help`): a declared remote
    // package absent from every cache is not listed rather than reported as
    // a broken install that never happened.
    if (command == .wasm_cmd and parsed_args.serve_no_build) {
        // Nothing is installed on this path, so the provisional target is
        // confirmed against the providers discoverable as-is (`.unknown`,
        // like `labelle targets`): a package absent from the cache cannot
        // own a target here. Same diagnostics as the pipeline's own check.
        var no_build_sources: provider_github.Sources = .{ .a = hook_arena };
        defer no_build_sources.deinit();
        const known = provider_dispatch.discover(hook_arena, project_root, parsed, &no_build_sources, .unknown) catch |err| {
            std.debug.print("labelle: provider discovery failed: {s}\n", .{@errorName(err)});
            return 1;
        };
        const served = switch (try confirmTarget(hook_arena, known, requested_target)) {
            .resolved => |resolved| resolved,
            .refused => return 1,
        };
        const wasm_target = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ @tagName(parsed.backend), served.name });
        defer allocator.free(wasm_target);
        const wasm_target_dir = try std.fs.path.join(allocator, &.{ project_dir, ".labelle", wasm_target });
        defer allocator.free(wasm_target_dir);
        const web_dir = try std.fs.path.join(allocator, &.{ wasm_target_dir, "zig-out", "web" });
        defer allocator.free(web_dir);
        if (std.Io.Dir.cwd().access(config.globalIo(), web_dir, .{})) |_| {} else |_| {
            const verb = if (parsed_args.wasm_export) "export" else "serve";
            std.debug.print(
                "labelle wasm {s}: no existing WASM build at '{s}'\n" ++
                    "  run `labelle wasm {s}` (without --no-build) first.\n",
                .{ verb, web_dir, verb },
            );
            return error.BuildFailed;
        }
        const project_web_dir = try std.fs.path.join(allocator, &.{ project_dir, "web" });
        defer allocator.free(project_web_dir);

        // The run hooks are planned from the same discovery (`known`) the
        // served target was just confirmed against, for the served name.
        const no_build_plan = try provider_hooks.plan(hook_arena, known, .run, served.name);
        // The same wire `optimize` the building path reports for this
        // platform; there is no progress feed on this path.
        const no_build_optimize = std.meta.stringToEnum(provider_contract.Optimize, parsed_args.optimize_override orelse "ReleaseSafe") orelse {
            std.debug.print("labelle: unknown optimize mode '{s}'\n", .{parsed_args.optimize_override.?});
            return 1;
        };
        var no_build_site: provider_hooks.Site = .{
            .a = hook_arena,
            .backing = allocator,
            .providers = known,
            .root = project_root,
            .cfg = parsed,
            .target = served.name,
            .optimize = no_build_optimize,
            .progress = switch (parsed_args.progress_mode) {
                .human => .human,
                .json => .json,
                .off => .off,
            },
            .reporter = null,
        };
        const no_build_out = try provider_hooks.stepOutputDir(hook_arena, wasm_target_dir, .run, served.name, null);
        {
            const code = try provider_hooks.runPhase(&no_build_site, no_build_plan.before, .run, .before, no_build_out);
            if (code != 0) return code;
        }
        if (no_build_plan.replace) |replacement| {
            const code = try provider_hooks.runPhase(&no_build_site, &.{replacement}, .run, .replace, no_build_out);
            if (code != 0) return code;
            return provider_hooks.finishRun(&no_build_site, no_build_plan.after, no_build_out, .exited_clean);
        }
        if (parsed_args.wasm_export) {
            const out_abs = try resolveExportOutput(allocator, project_dir, parsed_args.export_output);
            defer allocator.free(out_abs);
            try export_mod.packageExport(allocator, web_dir, project_web_dir, .{
                .output_dir = out_abs,
                .zip = parsed_args.export_zip,
                .platform = parsed_args.export_pkg_platform,
            });
            return provider_hooks.finishRun(&no_build_site, no_build_plan.after, no_build_out, .exited_clean);
        }
        // No watch in the `--no-build` path (the parser already rejects the
        // `--watch --no-build` combination, so `serve_watch` is false here).
        // The server returns on Ctrl+C / SIGTERM, the serve's clean end, and
        // the after hooks run then — as on the building path.
        try serve.serveAndOpen(allocator, web_dir, project_web_dir, parsed_args.serve_port, !parsed_args.serve_no_open, null);
        return provider_hooks.finishServe(&no_build_site, no_build_plan.after, no_build_out);
    }

    // (Provider discovery, the ownership check of the provisional target
    // and the hook plans are computed further down, right after the package
    // cache is populated — see the `gateThenInstall` call.)

    // ── Build-progress feed (cli#284) ──────────────────────────────────
    // Target subdir: .labelle/raylib_desktop/, etc. Computed up front so
    // the live status file `.labelle/<target>/.build-progress.json` has a
    // home from the first `resolve` record onward (the dir is created by
    // the reporter; the assembler generates into it later). Named after
    // the PROVISIONAL target: the name depends on the string alone, and a
    // target refused after the install leaves only a `failed` record here.
    const target_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ @tagName(parsed.backend), provisional.name });
    defer allocator.free(target_name);
    const target_dir = try std.fs.path.join(allocator, &.{ project_dir, ".labelle", target_name });
    defer allocator.free(target_dir);

    // One event source, three access modes: NDJSON on stdout
    // (`--progress=json`), the atomically-rewritten status file (all
    // modes; read by `labelle status` + studio), and a live indicator on
    // stderr (default human mode — a TTY-only spinner while `zig build`
    // runs, "still working" heartbeat lines while the assembler child
    // owns stderr during resolve/generate, cli#321). Enabled for the
    // commands that run the shared build pipeline; `labelle generate` and
    // the ios/android subcommands (which own their own build flows) stay
    // report-free. A
    // reporter that fails to initialize downgrades to the pre-#284
    // behavior instead of blocking the build.
    var reporter_storage: progress.Reporter = undefined;
    const reporter: ?*progress.Reporter = blk: {
        if (command != .build and command != .run and command != .wasm_cmd and command != .bundle_cmd) break :blk null;
        reporter_storage = progress.Reporter.init(allocator, config.globalIo(), parsed_args.progress_mode, target_dir) catch break :blk null;
        break :blk &reporter_storage;
    };
    defer if (reporter) |r| r.deinit();
    // Any error path from here on marks the status file `failed`, so an
    // out-of-band reader never sees a live phase for a dead build. The
    // catch-all detail is composed from the live phase ("generate
    // failed", …) so the terminal record still names the stage that was
    // active — the record's own `phase` field flips to "failed" (cli#318).
    // (Pipeline code that terminates via process-exit instead of an error
    // return goes through `progress.fatalExit`, which does the same.)
    errdefer if (reporter) |r| r.failActiveStage(1);
    if (reporter) |r| {
        // Registers the fatalExit hook + starts the keepalive ticker that
        // refreshes elapsed/updated timestamps while child processes own
        // the foreground (assembler, zig, game).
        r.activate();
        r.beginPhase(.resolve, "resolving toolchain + packages");
    }

    // Validate version compatibility
    compatibility.validateCompatibility(parsed);

    // Pre-build hooks (#355). Runs on `generate` / `build` / `run` (and
    // the ios/android/wasm flows, which all generate) — the first thing
    // that touches the project after its config is validated, and ahead
    // of EVERY generation input reader: the ASTC pre-pass, the `--bake`
    // pre-pass, the assembler's cache populate and `generate`. That
    // ordering is the point: a step may emit an atlas declared in
    // `.resources` or a script the game compiles against, and all of
    // those are read downstream.
    //
    // No-op — no print, no stat, no spawn — for a project with no
    // `.prebuild`, so the default path is byte-identical to before.
    //
    // In `--progress=json` mode the child's stdout is routed to the CLI's
    // stderr so the NDJSON stdout feed stays pure (cli#320); see
    // `prebuild.zig`'s module doc for that and for the trust posture.
    // A non-zero step exits the CLI with the child's exact code from
    // inside `runAll` (via `progress.fatalExit`, which marks the status
    // file `failed` first), mirroring the assembler delegation.
    //
    // A hook is very often a Python program — `.run = .{ "python3",
    // "tools/gen_tiles.py", ... }` is this feature's documented example. On a
    // machine whose only interpreter is the CLI-managed one (`labelle install
    // python`), that interpreter reaches PATH solely through
    // `python_provision.autoWireEnv`, which used to run far below inside the
    // wasm-only block — i.e. AFTER the hooks had already failed to spawn
    // (cli#361 review). Wire it HERE, ahead of the first spawn, so the
    // documented generator works on every platform and not just after a wasm
    // build has got that far.
    //
    // Gated on hooks that will actually run, so the no-`.prebuild` path stays
    // byte-identical (no cache stat, no "using provisioned Python" line) and
    // `LABELLE_NO_PREBUILD=1` stays fully inert. Idempotent and cheap: the
    // wasm block below still calls it for projects with no hooks, and a
    // second call returns early once the dir is on PATH.
    //
    // Nothing else a hook could reasonably need is wired later. The managed
    // Zig toolchain is spawned by absolute path and never joins PATH at all;
    // emsdk activation exists for the emcc link step and pulling it above the
    // hooks would force a toolchain fetch on every build; and
    // `sdl_provision.autoWireEnv` (just below) sets a Windows link/runtime
    // variable consumed by `zig build`, not a tool a generator spawns.
    if (parsed.prebuild.len > 0 and !prebuild.skipRequested(allocator)) {
        python_provision.autoWireEnv(allocator);
    }

    try prebuild.runAll(allocator, project_dir, parsed.prebuild, .{
        .route_stdout_to_stderr = parsed_args.progress_mode == .json,
    });

    // Auto-wire a cache-provisioned SDL2 (`labelle doctor --fix`) into the
    // build/run environment so desktop games that need it (raylib/sokol
    // gamepad, sdl backend) link + run without the user setting
    // LABELLE_SDL2_LIB by hand. No-op when SDL2 isn't in the cache or the
    // user already set the var. Scoped like `labelle doctor`: the sdl
    // backend always needs SDL2; raylib/sokol only for the gamepad
    // source, so `.gamepad = .none` projects get nothing injected.
    // Backends that pull in SDL2: the `sdl` renderer always, and
    // raylib/sokol/bgfx for the shared desktop gamepad source unless gamepad
    // is opted out. Mirrors the assembler's `deps_linker.stagesSdlGamepad`
    // (raylib/sokol/bgfx with `gamepad == .auto`) — bgfx was previously
    // missing here, so its default gamepad-enabled desktop builds never got
    // SDL2 auto-wired or the runtime DLL staged (cli#285 / cli#286).
    const wants_sdl2 = parsed.backend == .sdl or
        ((parsed.backend == .raylib or parsed.backend == .sokol or parsed.backend == .bgfx) and parsed.gamepad != .none);
    if (parsed.platform == .desktop and wants_sdl2) {
        sdl_provision.autoWireEnv(allocator);
    }

    // Issue #217: the CLI is a thin driver over the standalone
    // labelle-assembler binary. Resolve it once here (LABELLE_ASSEMBLER
    // env var > assembler_version in project.labelle > auto-downloaded
    // default) and reuse the located binary for both the cache-populate
    // step and code generation below.
    const asm_bin = try assembler_proc.resolve(allocator, project_dir, "generate");
    defer asm_bin.deinit(allocator);
    std.debug.print("  using assembler: {s}\n", .{asm_bin.path});

    // (The ASTC conversion pre-pass used to run here, before the install.
    // It is a generation-input reader — it consumes the declared PNGs — so
    // it now runs inside the core `generate` step below, AFTER the `before
    // generate` provider hooks; see the note there.)

    // Ensure the package cache is populated. The assembler's `generate`
    // subcommand assumes a populated cache (it does not fetch packages
    // itself), so delegate `install --project-root` to the binary first.
    // This replaces the CLI's former in-process `cache.ensureCache`,
    // which depended on the assembler's `generator` module.
    //
    // The shader-compiler override gate runs immediately BEFORE this install
    // (cli#387 gap 3): a typo'd `LABELLE_SHADERC` used to be reported only
    // after the slow, network-bound fetch had finished. `--docker` selects the
    // docker-aware variant, which validates identically and then says that the
    // host path is not forwarded into the container.
    try gateThenInstall(
        allocator,
        project_dir,
        if (parsed_args.docker) material_toolchain.preflightDocker else material_toolchain.preflight,
        AssemblerInstaller{ .bin = asm_bin },
    );

    // ── Provider discovery, target ownership and hook plans ────────────
    // (contract §6; docs/provider-hooks.md, docs/provider-targets.md)
    // Discovery reads every declared provider manifest and validates the
    // whole hook graph ONCE, so a malformed provider fails a plain `labelle
    // build` closed before generation or any compiler runs. It sits HERE,
    // after `install` populated the package cache and not before it (Codex
    // P1 on #420): a declared remote package that is neither pinned nor yet
    // in the ordinary cache has no manifest to read, and discovering ahead of
    // the installer read every such package as runtime-only — a cold cache
    // silently built without the package's hooks while a warm one ran them
    // (or refused as unpinned). With the cache populated, `.populated` makes
    // an absent package an error instead. Skipped for a project with no
    // plugins; for pinned remote providers it is the same verified extraction
    // every provider command performs (the integrity model of cli#414 — the
    // cost is accepted). The plans are pure and computed here for all four
    // steps; a project without hooks gets four empty plans and never resolves
    // the host compiler.
    var provider_sources: provider_github.Sources = .{ .a = hook_arena };
    defer provider_sources.deinit();
    const providers: []const provider_dispatch.Provider = if (parsed.plugins.len == 0)
        &.{}
    else
        provider_dispatch.discover(hook_arena, project_root, parsed, &provider_sources, .populated) catch |err| {
            std.debug.print("labelle: provider discovery failed: {s}\n", .{@errorName(err)});
            if (reporter) |r| r.finishFailed(1, "provider discovery failed");
            return 1;
        };
    // The ownership half of target resolution: the provisional target from
    // above is confirmed against the discovered providers — the first point
    // at which a declared package's manifest is guaranteed readable — and
    // refused when none declares it. This is the only place a provider
    // target becomes a resolved one; nothing has been generated, locked or
    // compiled yet, and the `failed` progress record names the reason —
    // which of the two refusals it was, since each calls for a different fix.
    const target = switch (try confirmTarget(hook_arena, providers, requested_target)) {
        .resolved => |resolved| resolved,
        .refused => |why| {
            if (reporter) |r| r.finishFailed(1, why.detail());
            return 1;
        },
    };
    const hook_plans = .{
        .generate = try provider_hooks.plan(hook_arena, providers, .generate, target.name),
        .build = try provider_hooks.plan(hook_arena, providers, .build, target.name),
        .bundle = try provider_hooks.plan(hook_arena, providers, .bundle, target.name),
        .run = try provider_hooks.plan(hook_arena, providers, .run, target.name),
    };
    // The labelle-assembler#378 boundary: the assembler generates only for
    // the schema platforms, so a provider target outside that enum can be
    // generated for only by its provider's `replace` hook on `generate`.
    // Without one, stop HERE — before the lock, the assembler's `generate`
    // and any compiler — rather than hand the assembler a name it cannot
    // take.
    if (target.legacy == null and hook_plans.generate.replace == null) {
        std.debug.print("labelle: target '{s}' is declared by '{s}' but the pinned assembler cannot generate for it yet (labelle-assembler#378)\n", .{ target.name, target.providerName() });
        if (reporter) |r| r.finishFailed(1, "the pinned assembler cannot generate for this target");
        return 1;
    }
    // `labelle bundle` of a provider target is packaged by its provider, so
    // it needs a `replace` hook on `bundle` — and needs no particular host.
    // (The core target's macOS-only gate ran before the install, above.)
    if (command == .bundle_cmd) {
        if (target.provider) |provider| {
            if (hook_plans.bundle.replace == null) {
                std.debug.print("labelle: target '{s}' has no bundle replacement; package '{s}' must declare a `.when = .replace` hook on `bundle`\n", .{ target.name, provider.meta.name });
                return error.NoBundleReplacement;
            }
        }
    }

    // Plugin→core compatibility, the POST-RESOLVE half (#332).
    //
    // Deliberately here and not beside `validateCompatibility` above: that one
    // runs on `ProjectConfig` alone, before any package exists on disk, so a
    // remote plugin's `plugin.labelle` is simply not readable yet and every
    // declaration would read as absent. `install` above is what populates the
    // cache, so this is the first point where a declared `.core_compat` can be
    // honored at all. Warn-only and non-fatal, like every other check in
    // `compatibility.zig`.
    compatibility.validatePluginCoreCompat(allocator, parsed, project_dir);

    // `labelle.lock` is written HERE, before generation, rather than after
    // it: a `before generate` provider hook already needs the lock (contract
    // §2 — `lock_file` is non-null inside a project, and the hook's own pin
    // is verified against it). `install` above populated the cache the lock
    // writer reads, so every resolved version is already known. A generate
    // that then fails leaves a fresh lock reflecting the declared pins —
    // harmless, and `enforceCliNotStale` only reads it on the next run.
    try lockfile.writeLockFile(allocator, project_dir, parsed);

    // Generate into .labelle/
    const output_dir = try std.fs.path.join(allocator, &.{ project_dir, ".labelle" });
    defer allocator.free(output_dir);

    // GUI resolution (reading the plugin's gui.labelle manifest) is owned
    // by the assembler's `generate` subcommand — the CLI no longer
    // resolves it. The status line reports whether a GUI is *configured*
    // in project.labelle; the assembler logs the resolved plugin name.
    const gui_label: []const u8 = if (parsed.gui != null) "configured" else "none";
    if (reporter) |r| r.beginPhase(.generate, "assembler generate");
    std.debug.print("labelle: generating '{s}'...\n", .{parsed.name});
    std.debug.print("  backend: {s}  target: {s}  ecs: {s}  gui: {s}  window: {d}x{d}\n", .{
        @tagName(parsed.backend), target.name, @tagName(parsed.ecs), gui_label, parsed.width, parsed.height,
    });

    // Scenes and prefabs are always embedded via @embedFile
    const effective_optimize = parsed_args.optimize_override orelse
        if (parsed.platform == .wasm) @as(?[]const u8, "ReleaseSafe") else null;

    // Everything a provider hook run needs. The host compiler is resolved by
    // the first hook that runs (never for an empty plan), and hooks report
    // under the phase of the core step they wrap; the wire `optimize` and
    // `progress` mirror this invocation's, so a hook builds what the core
    // step builds and speaks the mode the user asked for.
    const hook_optimize = std.meta.stringToEnum(provider_contract.Optimize, effective_optimize orelse "Debug") orelse {
        std.debug.print("labelle: unknown optimize mode '{s}'\n", .{effective_optimize.?});
        return 1;
    };
    var hook_site: provider_hooks.Site = .{
        .a = hook_arena,
        .backing = allocator,
        .providers = providers,
        .root = project_root,
        .cfg = parsed,
        .target = target.name,
        .optimize = hook_optimize,
        .progress = switch (parsed_args.progress_mode) {
            .human => .human,
            .json => .json,
            .off => .off,
        },
        .reporter = reporter,
        // Reaches the `bundle` hooks only; a provider target's bundle
        // replacement would otherwise drop it silently (Codex P2 on #421).
        .build_number = if (command == .bundle_cmd) parsed_args.bundle_build_number else null,
    };

    // Issue #217 phase 2: delegate code generation to the standalone
    // labelle-assembler binary via the shared subprocess harness, instead
    // of calling an in-process generator. The binary was located above
    // (`asm_bin`) and already used for the `install` cache-populate step.
    //
    // `build` / `run` are not assembler subcommands: the subsequent
    // `zig build` invocation and binary launch stay CLI-side (see below).
    // The CLI owns docker orchestration, the WASM serve loop, the
    // iOS/Android deploy paths and `--timeout` — generation is the only
    // step the assembler binary delegates.
    // `parsed_args.scene_override` is intentionally NOT forwarded to the
    // assembler. PR #243 removed the CLI's `cfg.initial_prefab` rewrite for
    // exactly this reason; the assembler's own `--scene` handling does the
    // same rewrite, which bypasses any loading-scene gate the project
    // declares. The override is delivered at runtime via the
    // `LABELLE_SCENE` env var injected at the spawn site (~line 990).
    //
    // (The shader-compiler override gate used to run here. It now runs in
    // `gateThenInstall`, ahead of the network-bound package install — see
    // cli#387 gap 3.)
    //
    // Provider hooks on `generate` (contract §6): `before` hooks, then the
    // core generation — or its unique `replace` hook — then `after` hooks.
    // `output_dir` is the generated tree itself. A failing hook ends the
    // command with the hook's own exit code; nothing past it runs.
    //
    // The `before` phase runs ahead of EVERY generation-input reader: the
    // ASTC conversion pre-pass and the `--bake` pre-pass both consume the
    // declared PNGs, so a hook that produces one of them used to run too
    // late for them — `generate --bake` failed on the not-yet-written PNG
    // and a hook-generated PNG never got its `.astc` sibling (Codex P2 on
    // #420). Both pre-passes are part of the core generation they feed, so
    // a `replace generate` hook stands in for them too: the replacement
    // owns whatever preprocessing its generation needs.
    //
    // The shader-compiler override is gated again right after the `before`
    // phase (`beforeGenerate`): a hook may be what creates `materials/`.
    const generate_out = try provider_hooks.stepOutputDir(hook_arena, target_dir, .generate, target.name, null);
    {
        const gate: *const fn (std.mem.Allocator, []const u8) anyerror!void = if (parsed_args.docker) material_toolchain.preflightDocker else material_toolchain.preflight;
        const code = try beforeGenerate(&hook_site, hook_plans.generate.before, generate_out, project_dir, gate);
        if (code != 0) return code;
    }
    core_generate: {
        if (hook_plans.generate.replace) |replacement| {
            const code = try provider_hooks.runPhase(&hook_site, &.{replacement}, .generate, .replace, generate_out);
            if (code != 0) return code;
            break :core_generate;
        }

        // ASTC build-time conversion (#340): when this platform ships ASTC atlases
        // (`asset_compression`), run `labelle astc` first so the `<name>.astc`
        // siblings exist for the assembler's catalog `.png → .astc` swap. Runs
        // before the assembler's `generate` (it only needs project.labelle + the
        // PNGs + astcenc). Non-fatal — on any failure the assembler finds no
        // sibling and falls back to the source PNG, so the build still succeeds.
        //
        // EXCEPT a misconfiguration. `ConflictingAstcBlocks` means two atlases
        // compile to one `.astc` with disagreeing block pins; falling back would
        // hand BOTH of them whatever `.astc` is on disk — including a STALE one
        // from an earlier build, which is worse than no atlas because it looks
        // like it worked. So a config error stops the build, while a conversion
        // failure still degrades to PNG.
        //
        // Only for a target the capability tables know (`target.legacy`:
        // `desktop` or a schema-named provider target). A provider target
        // outside the enum has `parsed.platform` derived as `.desktop` for the
        // legacy sites, but it is NOT the desktop target: running the desktop
        // prepass for it would encode ASTC siblings by desktop capabilities
        // (Codex on #421). Its provider owns its asset pipeline; `cmdAstc`
        // itself refuses such a name.
        if (target.legacy != null and parsed.asset_compression.formatFor(parsed.platform) == .astc) {
            // Pass the RESOLVED target: `--platform=wasm`, `labelle ios` (forces
            // sokol) and the Android backend fallback all differ from what
            // project.labelle declares, and the loadable blocks depend on both.
            astc_cmd.cmdAstc(allocator, &.{
                project_dir,
                "--platform",
                @tagName(parsed.platform),
                "--backend",
                @tagName(parsed.backend),
            }) catch |err| switch (err) {
                error.ConflictingAstcBlocks => progress.fatalExit(
                    1,
                    "conflicting .astc_block pins compile to one .astc — see the error above",
                ),
                // A stale `.astc` (wrong block for this target) that could not be
                // deleted would be swapped in by the assembler — the PNG fallback
                // below would be a lie. Stop instead (labelle-bgfx#134).
                error.StaleAstcSiblingUndeletable => progress.fatalExit(
                    1,
                    "a stale .astc sibling could not be deleted — see the error above",
                ),
                else => std.debug.print(
                    "labelle: ASTC conversion failed ({s}); falling back to PNG atlases\n",
                    .{@errorName(err)},
                ),
            };
        }

        // Opt-in PNG → LRGBA pre-bake. Runs before the assembler so its
        // @embedFile path picks up the fresh `.rgba` files. Skipped unless
        // `--bake` is passed: raw RGBA expands heavily-transparent atlases
        // by 100×+ (a 200 KB PNG can become 64 MB), so default-off keeps
        // APK size sane. Use for projects whose atlases are nearly opaque
        // and PNG decode dominates cold start.
        if (parsed_args.bake) {
            bake_mod.run(allocator, project_dir, parsed.resources) catch |err| {
                std.debug.print("labelle: bake failed: {s}\n", .{@errorName(err)});
                return err;
            };
        }

        // The assembler receives the resolved target NAME; the #378 gate above
        // guarantees it is one the pinned assembler can take.
        try assembler_proc.generate(
            asm_bin,
            allocator,
            project_dir,
            target.name,
            @tagName(parsed.backend),
        );

        // (`target_name`/`target_dir` — .labelle/raylib_desktop/, etc. — are
        // computed up front, before the progress reporter init; see cli#284.)

        // fixFingerprints runs `zig build` locally per emitted target dir to
        // discover the correct hash. With assembler >=0.14.0 there are two
        // (`<backend>_<platform>/` and `tests/`); patching only the exe dir
        // would leave `tests/` with a placeholder fingerprint and break
        // `labelle test`.
        //
        // For docker builds we skip the exe target — the host Zig toolchain
        // may not have the native libs the chosen backend needs (that's why
        // we're routing through docker in the first place). The tests target
        // is the exception: it uses the null backend (no native libs), so
        // host Zig can build it even when --docker is set, and skipping
        // would leave `labelle test` broken on the host after `labelle build
        // --docker`. Patch `tests/` directly when present.
        if (!parsed_args.docker) {
            try runner.fixFingerprints(allocator, project_dir, output_dir);
        } else {
            const tests_dir = try std.fs.path.join(allocator, &.{ output_dir, "tests" });
            defer allocator.free(tests_dir);
            const tests_build_zig = try std.fs.path.join(allocator, &.{ tests_dir, "build.zig" });
            defer allocator.free(tests_build_zig);
            if (std.Io.Dir.cwd().access(config.globalIo(), tests_build_zig, .{})) |_| {
                try runner.fixFingerprint(allocator, project_dir, tests_dir);
            } else |_| {}
        }
        // (`labelle.lock` was written before generation — see the provider
        // hook note beside `validatePluginCoreCompat`.)
        std.debug.print("  generated .labelle/{s}/\n", .{target_name});

        // For a wasm build: activate the emsdk checkout Zig just fetched into the
        // project-local `zig-pkg/` (during the fingerprint pass above) so the emcc
        // link step finds `upstream/emscripten/emcc`. Without this a fresh
        // `labelle build --platform wasm` — or `generate --platform wasm` followed
        // by a manual `zig build` — dies at the emcc step because the fetched emsdk
        // package is NOT activated: the remaining half of labelle-assembler#492 (the
        // docker path already does this in-container). Run it BEFORE the `generate`
        // early-return so the generate-then-build path is covered too. Best-effort +
        // idempotent; on failure the build still surfaces the clear #492 guidance.
        // The PINNED version keeps activation deterministic.
        if (!parsed_args.docker and parsed.platform == .wasm) {
            // Python preflight (cli#291): emsdk activation and emcc itself (an
            // `env python3` script) both need a working interpreter. Fail fast
            // with the exact fix instead of dying deep inside emsdk activation
            // with an unrelated-looking error. `autoWireEnv` first: it puts a
            // previously-provisioned managed Python on this process's PATH (and
            // wires the TLS bundle on Windows), which is what makes the
            // availability probe — and the activation below — see it.
            python_provision.autoWireEnv(allocator);
            if (!python_provision.isAvailable(allocator)) {
                std.debug.print("labelle: wasm builds need Python 3 (emsdk activation + emcc) and none was found.\n" ++
                    "  fix: labelle install python   (managed, ~25 MB into ~/.labelle/python)\n" ++
                    "  or install Python 3 yourself and ensure `python3` is on PATH.\n", .{});
                return error.BuildFailed;
            }
            const resolved_emsdk = try emsdk_toolchain.resolveRequiredVersion(allocator, project_dir);
            defer allocator.free(resolved_emsdk.version);
            emsdk_activate.activateFetchedEmsdk(allocator, target_dir, resolved_emsdk.version);
        }
    }
    {
        const code = try provider_hooks.runPhase(&hook_site, hook_plans.generate.after, .generate, .after, generate_out);
        if (code != 0) return code;
    }

    if (command == .generate) return 0;

    // `labelle ios` subcommand — handles its own build/xcode/run
    if (command == .ios_cmd) {
        return ok(ios.handleIos(allocator, parsed_args.extra_args[0..parsed_args.extra_count], parsed, target_dir));
    }

    // `labelle android` subcommand — handles its own build/run
    if (command == .android_cmd) {
        return ok(android.handleAndroid(allocator, parsed_args.extra_args[0..parsed_args.extra_count], parsed, project_dir, target_dir));
    }

    // Warn if --target is used without --docker (it has no effect otherwise)
    if (parsed_args.docker_target != null and !parsed_args.docker) {
        std.debug.print("labelle: warning: --target has no effect without --docker\n", .{});
    }

    // Build — default to ReleaseSafe for WASM (Debug exceeds browser local variable limits)
    const optimize_flag: ?[]const u8 = if (effective_optimize) |opt|
        try std.fmt.allocPrint(allocator, "-Doptimize={s}", .{opt})
    else
        null;
    defer if (optimize_flag) |f| allocator.free(f);

    // Resolve the managed Zig toolchain (labelle-cli#279): every `zig` spawn
    // uses this binary, never PATH. Downloads + verifies on a cache miss.
    // Skipped for docker builds — the toolchain lives inside the container.
    const managed_zig: ?[]u8 = if (parsed_args.docker) null else try runner.resolveZigExe(allocator, project_dir);
    defer if (managed_zig) |z| allocator.free(z);

    // Build a base env for child `zig` that pins ZIG_*_CACHE_DIR into the
    // labelle cache tree (user-writable, never next to a read-only install).
    // For a wasm build, ALSO layer the managed emsdk's EMSDK/EM_CONFIG/PATH
    // wiring on top when one is already provisioned (labelle-cli#283) — an
    // escape hatch for builds/backends that resolve `emcc` via PATH/env rather
    // than the fetched package activated just above.
    var zig_env_storage: ?std.process.Environ.Map = if (parsed_args.docker)
        null
    else if (parsed.platform == .wasm)
        try runner.buildWasmEnv(allocator, project_dir)
    else
        try runner.buildZigEnv(allocator, &.{});
    defer if (zig_env_storage) |*m| m.deinit();
    const zig_env_ptr: ?*const std.process.Environ.Map = if (zig_env_storage) |*m| m else null;

    var zig_args: std.ArrayList([]const u8) = .empty;
    defer zig_args.deinit(allocator);
    try zig_args.append(allocator, managed_zig orelse "zig");
    try zig_args.append(allocator, "build");
    if (optimize_flag) |flag| try zig_args.append(allocator, flag);

    // Provider hooks on `build` (contract §6) wrap the whole core build —
    // docker or host `zig build` plus the runtime DLL staging — with
    // `output_dir` = the target's `zig-out/`. A `replace` hook stands in for
    // all of it. Hooks report under the `compile` phase.
    const build_out = try provider_hooks.stepOutputDir(hook_arena, target_dir, .build, target.name, null);
    {
        const code = try provider_hooks.runPhase(&hook_site, hook_plans.build.before, .build, .before, build_out);
        if (code != 0) return code;
    }
    core_build: {
        if (hook_plans.build.replace) |replacement| {
            const code = try provider_hooks.runPhase(&hook_site, &.{replacement}, .build, .replace, build_out);
            if (code != 0) return code;
            break :core_build;
        }
        if (parsed_args.docker) {
            // Docker builds get phase-level progress only: the toolchain (and
            // its progress pipe) lives inside the container.
            if (reporter) |r| r.beginPhaseOrStep(.compile, "docker build");
            std.debug.print("labelle: building via docker...\n", .{});
            const docker_exit = try docker.runBuild(allocator, target_dir, parsed.platform, parsed_args.docker_target, effective_optimize);
            if (reporter) |r| r.clearSpinner();
            if (docker_exit != 0) {
                if (reporter) |r| r.finishFailed(docker_exit, "docker build failed");
                std.debug.print("labelle: docker build failed (exit code {d})\n", .{docker_exit});
                return error.BuildFailed;
            }
        } else if (reporter) |r| {
            // cli#284: spawn `zig build` with Zig's std.Progress IPC pipe
            // attached — live node names + keepalives flow into the feed
            // during the compile (see runner.zig for what Zig 0.16 actually
            // relays), and stdio is inherited so compile errors stream to the
            // terminal unaltered (nothing is captured or eaten).
            std.debug.print("labelle: building...\n", .{});
            r.beginPhaseOrStep(.compile, "zig build");
            const build_code = try runner.runZigInheritProgress(allocator, target_dir, zig_args.items, zig_env_ptr, r);
            // Wipe the spinner line before anything else prints on it.
            r.clearSpinner();
            if (build_code != 0) {
                r.finishFailed(build_code, "zig build failed");
                std.debug.print("labelle: build failed (exit {d})\n", .{build_code});
                return error.BuildFailed;
            }
        } else {
            std.debug.print("labelle: building...\n", .{});
            const build_result = try runner.runZigWithEnv(allocator, target_dir, zig_args.items, zig_env_ptr);
            defer allocator.free(build_result.stdout);
            defer allocator.free(build_result.stderr);

            switch (build_result.term) {
                .exited => |code| if (code != 0) {
                    std.debug.print("labelle: build failed:\n{s}\n", .{build_result.stderr});
                    return error.BuildFailed;
                },
                else => {
                    std.debug.print("labelle: build process terminated abnormally\n{s}\n", .{build_result.stderr});
                    return error.BuildFailed;
                },
            }
        }
        std.debug.print("  build ok\n", .{});

        // Stage the runtime SDL2.dll next to the freshly-built desktop exe. A
        // gamepad/SDL2 build's exe fails process creation with a bare
        // `FileNotFound` when SDL2.dll isn't in its own directory (cli#285): the
        // Windows loader resolves implicitly-linked DLLs from the exe dir first,
        // and neither the PATH prepend from autoWireEnv nor a user-set
        // LABELLE_SDL2_LIB puts the DLL there. Docker builds are skipped — their
        // exe is built for the container's OS, so a host SDL2.dll is irrelevant.
        if (!parsed_args.docker and parsed.platform == .desktop and wants_sdl2) {
            const bin_dir = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "bin" });
            defer allocator.free(bin_dir);
            sdl_provision.stageSdl2DllBesideExe(allocator, bin_dir);
        }

        // `labelle build` finalization — everything that turns the compiled
        // tree into the command's final artifact. It sits INSIDE the core
        // build so the `after build` hooks below see the finished artifact
        // (a signing, inspecting or publishing hook used to run before the
        // APK existed, and reported success even when packaging then
        // failed — Codex P2 on #420), and so that a `replace build` hook
        // owns it: the replacement produces the artifact its target needs,
        // packaging included.
        if (command == .build) {
            // Linux `.desktop` entry + icon (cli#359): after a desktop build,
            // write `zig-out/<exe>.desktop` + `zig-out/<exe>.png` beside `bin/`
            // — automatically on a Linux host, or anywhere with
            // `--linux-desktop`. Skipped under `--docker`: that exe was built
            // for the container's target and the entry's absolute paths would
            // describe this host, not the one that will run it. `run` is
            // deliberately left alone — the entry is a packaging artifact.
            // Core desktop only: a provider target is packaged by its provider.
            if (!parsed_args.docker and target.provider == null and linux_desktop.shouldEmit(parsed_args.linux_desktop)) {
                const entry_path = try linux_desktop.createFromBuild(allocator, project_dir, target_dir, parsed);
                allocator.free(entry_path);
            }
            // `labelle build --platform=android` builds the shared library
            // above (the generic `zig build` produces `zig-out/lib/libgame.so`)
            // but, unlike `labelle android build`, used to stop there and leave
            // a bare `.so`. Package it into a signed APK so the artifact is
            // installable — backend-agnostic, so it covers sokol and bgfx alike.
            if (parsed.platform == .android) {
                const apk_path = try android.packageApk(allocator, project_dir, target_dir, parsed, false, .{}, .{
                    .strip_native = android.stripForOptimize(effective_optimize),
                });
                defer allocator.free(apk_path);
                std.debug.print("labelle: APK ready: {s}\n", .{apk_path});
            }
        }
    }
    {
        const code = try provider_hooks.runPhase(&hook_site, hook_plans.build.after, .build, .after, build_out);
        if (code != 0) return code;
    }

    // `labelle bundle` (cli#359): the exe is built; wrap it. Packaging
    // runs AFTER the compile, so keep the progress feed open across it
    // (a `run` phase, as `wasm export` does) and only mark `done` once
    // the `.app` is on disk — a `--progress=json` consumer must not see
    // `done` before the artifact exists.
    if (command == .bundle_cmd) {
        if (reporter) |r| {
            r.beginPhaseOrStep(.run, "packaging bundle");
            r.clearSpinner();
        }
        // Provider hooks on `bundle` (contract §6). `output_dir` is the step
        // output directory — `zig-out/bundle/<target>/`, or the resolved
        // `--output` — which is also where the core packager puts the
        // `.app` (`bundle.resolveOutputDir` shares the default), so hooks
        // and the packager always agree on the artifact's directory.
        const bundle_override: ?[]const u8 = if (parsed_args.bundle_output) |o|
            try bundle.resolveOutputDir(hook_arena, project_dir, target_dir, o)
        else
            null;
        const bundle_out = try provider_hooks.stepOutputDir(hook_arena, target_dir, .bundle, target.name, bundle_override);
        {
            // The feed returns to "packaging bundle" once the hooks are done.
            const code = try provider_hooks.runBefore(&hook_site, hook_plans.bundle.before, .bundle, bundle_out, "packaging bundle");
            if (code != 0) return code;
        }
        core_bundle: {
            if (hook_plans.bundle.replace) |replacement| {
                const code = try provider_hooks.runPhase(&hook_site, &.{replacement}, .bundle, .replace, bundle_out);
                if (code != 0) return code;
                break :core_bundle;
            }
            const app_path = try bundle.createFromBuild(allocator, project_dir, target_dir, parsed, .{
                .output = parsed_args.bundle_output,
                .build_number = parsed_args.bundle_build_number,
            });
            defer allocator.free(app_path);
            // `createFromBuild` already printed the plain path. The paste-able
            // hint is single-quoted so a `"`, `$VAR` or backtick in a project
            // title stays literal instead of expanding in the user's shell.
            const quoted = try bundle.shellSingleQuote(allocator, app_path);
            defer allocator.free(quoted);
            std.debug.print("  open {s}\n", .{quoted});
        }
        {
            const code = try provider_hooks.runPhase(&hook_site, hook_plans.bundle.after, .bundle, .after, bundle_out);
            if (code != 0) return code;
        }
        if (reporter) |r| r.finishDone(0);
        return 0;
    }

    if (command == .build) {
        // (The build's finalization — the Linux `.desktop` entry and the
        // APK packaging — ran inside the core build above, ahead of the
        // `after build` hooks.)
        if (reporter) |r| r.finishDone(0);
        return 0;
    }

    // Run
    //
    // Provider hooks on `run` (contract §6): `before` runs once here, ahead
    // of every branch below; a `replace` hook stands in for all of them;
    // `after` runs at each branch's success exit through
    // `provider_hooks.finishRun`, which also owns the terminal `done` record
    // so a `--progress=json` consumer never sees `done` before the hooks
    // finished. After hooks never run unless the game itself exited 0 —
    // not after a nonzero exit, not after the `--timeout` watchdog's kill
    // (exit 0 for the CLI, cli#390) and not after a detached simulator or
    // device launch (`provider_hooks.RunOutcome`). The interactive `wasm
    // serve` loop is the one exception in timing: its `done` record lands
    // before the loop and the after hooks run only once the server returns.
    //
    // A cross-compiled `--docker --target=<t>` binary cannot run on this
    // host, so the core launch is skipped — and with it the whole `run`
    // step: decided HERE, before the `before run` hooks, so no run hook
    // prepares (or fails) a launch that never happens (Codex P2 on #420).
    if (crossTargetLaunchSkipped(parsed_args.docker, parsed_args.docker_target, parsed.platform, hook_plans.run.replace != null)) |t| {
        std.debug.print("labelle: cannot run cross-compiled binary (target: {s})\n", .{t});
        std.debug.print("  binary is at: {s}/zig-out/bin/\n", .{target_dir});
        if (reporter) |r| r.finishDone(0); // build succeeded; run skipped
        return 0;
    }
    const run_out = try provider_hooks.stepOutputDir(hook_arena, target_dir, .run, target.name, null);
    {
        const code = try provider_hooks.runPhase(&hook_site, hook_plans.run.before, .run, .before, run_out);
        if (code != 0) return code;
    }
    if (hook_plans.run.replace) |replacement| {
        const code = try provider_hooks.runPhase(&hook_site, &.{replacement}, .run, .replace, run_out);
        if (code != 0) return code;
        return provider_hooks.finishRun(&hook_site, hook_plans.run.after, run_out, .exited_clean);
    }
    if (parsed.platform == .wasm) {
        const web_dir = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "web" });
        defer allocator.free(web_dir);
        const project_web_dir = try std.fs.path.join(allocator, &.{ project_dir, "web" });
        defer allocator.free(project_web_dir);
        if (parsed_args.wasm_export) {
            // `wasm export`: package the fresh build into a deployment dir
            // instead of serving it. Packaging runs AFTER the build, so
            // keep the progress feed open across it (a run phase) and only
            // mark `done` once the artifacts are on disk — otherwise a
            // `--progress=json` consumer sees `done` before the export.
            if (reporter) |r| {
                r.beginPhaseOrStep(.run, "packaging wasm export");
                r.clearSpinner();
            }
            const out_abs = try resolveExportOutput(allocator, project_dir, parsed_args.export_output);
            defer allocator.free(out_abs);
            try export_mod.packageExport(allocator, web_dir, project_web_dir, .{
                .output_dir = out_abs,
                .zip = parsed_args.export_zip,
                .platform = parsed_args.export_pkg_platform,
            });
            return provider_hooks.finishRun(&hook_site, hook_plans.run.after, run_out, .exited_clean);
        } else {
            // WASM serve: the loop is interactive (runs until Ctrl+C), so
            // the terminal `done` record lands before the serve loop. The
            // loop returns on Ctrl+C / SIGTERM (`serve.serveAndOpen`
            // installs the handler), which is how the `after run` hooks
            // below become reachable at all (Codex P2 on #420); a failing
            // one revises that provisional `done` (`finishServe`).
            if (reporter) |r| r.finishDone(0);
            // The watched session's replan storage lives at THIS scope, not
            // inside the `--watch` branch: once a rebuild has replanned,
            // `hook_site.cfg`/`providers` point into its current generation,
            // and the `after run` hooks below resolve settings through them.
            // Destroyed at the watch branch's end, that storage was freed
            // before the shutdown hooks read it (Codex P2 on #420). The
            // defer runs after the `return` expression below is evaluated,
            // i.e. after the hooks, and restores the startup storage on the
            // site as it releases the generation.
            const watch_installer = AssemblerInstaller{ .bin = asm_bin };
            var watch_replan = WatchReplan{
                .backing = allocator,
                .project_dir = project_dir,
                .installer = WatchReplan.assemblerInstaller(&watch_installer),
            };
            defer watch_replan.deinit(&hook_site, providers, parsed);
            if (parsed_args.serve_watch) {
                // `--watch` (cli#208): hand the serve loop a rebuild callback
                // that re-runs the same generate→fingerprint→zig-build steps
                // this pipeline just did. The context borrows locals that stay
                // alive because `serveAndOpen` blocks until Ctrl+C.
                //
                // The hook plans are NOT borrowed for the session: every
                // rebuild re-reads the project and replans through
                // `watch_replan`, so an edited manifest or `provider_config`
                // reaches the next rebuild; the plans computed above are only
                // the initial state. The project the cold pipeline just
                // installed and locked is the replan's baseline: an edit to
                // `project.labelle` re-runs the install and rewrites the lock.
                watch_replan.baseline();
                var rebuild_ctx = WasmRebuildCtx{
                    .allocator = allocator,
                    .asm_bin = asm_bin,
                    .project_dir = project_dir,
                    .platform_tag = target.name,
                    .backend_tag = @tagName(parsed.backend),
                    .output_dir = output_dir,
                    .target_dir = target_dir,
                    .zig_args = zig_args.items,
                    .zig_env = zig_env_ptr,
                    .prebuild_steps = parsed.prebuild,
                    .prebuild_opts = .{
                        .route_stdout_to_stderr = parsed_args.progress_mode == .json,
                        // Keep the serve loop alive on a failing step.
                        .fatal_on_step_failure = false,
                    },
                    // The same hook site, plans and output directories the
                    // cold pipeline just used; the feed is already terminal
                    // here, so the hooks' sub-step records are no-ops.
                    .hooks = &hook_site,
                    .generate_plan = hook_plans.generate,
                    .build_plan = hook_plans.build,
                    .generate_out = generate_out,
                    .build_out = build_out,
                    .replan = .{ .ctx = &watch_replan, .run = WatchReplan.run },
                };
                // The hooks' declared `.outputs` are excluded from the watch
                // signature so the rebuild callback can't trip its own
                // watcher — but ONLY while the hooks actually run, so the
                // kill switch doesn't hide out-of-band regeneration from the
                // watcher. See `collectPrebuildIgnorePaths`.
                var ignore_files = collectPrebuildIgnorePaths(
                    allocator,
                    project_dir,
                    parsed.prebuild,
                    !prebuild.skipRequested(allocator),
                );
                defer {
                    for (ignore_files.items) |f| allocator.free(f);
                    ignore_files.deinit(allocator);
                }

                try serve.serveAndOpen(allocator, web_dir, project_web_dir, parsed_args.serve_port, !parsed_args.serve_no_open, .{
                    .watch_dir = project_dir,
                    .rebuild_fn = WasmRebuildCtx.rebuild,
                    .rebuild_ctx = &rebuild_ctx,
                    .ignore_files = ignore_files.items,
                });
            } else {
                try serve.serveAndOpen(allocator, web_dir, project_web_dir, parsed_args.serve_port, !parsed_args.serve_no_open, null);
            }
            // The server returned (Ctrl+C / SIGTERM): the serve's clean end.
            // The feed already says `done`; only the hooks run here, and a
            // failing one revises that record to `failed`.
            return provider_hooks.finishServe(&hook_site, hook_plans.run.after, run_out);
        }
    } else if (parsed.platform == .ios) {
        // iOS: deploy to simulator
        if (reporter) |r| r.beginPhaseOrStep(.run, "deploying to iOS Simulator");
        std.debug.print("labelle: deploying to iOS Simulator...\n", .{});
        try ios.deployToSimulator(allocator, target_dir, parsed);
        // `simctl launch` returns while the app runs on: its exit is never
        // seen here, so this is not the clean exit after hooks wait for.
        return provider_hooks.finishRun(&hook_site, hook_plans.run.after, run_out, .launched_detached);
    } else if (parsed.platform == .android) {
        // Android: deploy to device/emulator
        if (reporter) |r| r.beginPhaseOrStep(.run, "deploying to Android");
        std.debug.print("labelle: deploying to Android...\n", .{});
        // An app the system starts has no environment we control, so the
        // env-based run options travel as `am start --es` intent extras
        // under the same `LABELLE_*` names (cli#397); the Android runtime
        // turns them back into env vars (labelle-bgfx#139,
        // labelle-sokol#25). A runtime without that support ignores them.
        var launch_extras: std.ArrayList(runner.EnvKV) = .empty;
        defer launch_extras.deinit(allocator);
        var sec_buf: [32]u8 = undefined;
        try runner.appendRunOptionEnv(allocator, &launch_extras, runOptionEnv(&parsed_args), &sec_buf);
        try android.deployToDevice(allocator, project_dir, target_dir, parsed, false, .{}, .{
            .strip_native = android.stripForOptimize(effective_optimize),
        }, launch_extras.items);
        // `am start` likewise returns with the app still running.
        return provider_hooks.finishRun(&hook_site, hook_plans.run.after, run_out, .launched_detached);
    } else {
        if (timeout_ns) |t| {
            const secs = t / std.time.ns_per_s;
            const mins = secs / 60;
            const rem = secs % 60;
            if (mins > 0 and rem > 0) {
                std.debug.print("labelle: running (timeout: {d}m{d}s)...\n\n", .{ mins, rem });
            } else if (mins > 0) {
                std.debug.print("labelle: running (timeout: {d}m)...\n\n", .{mins});
            } else {
                std.debug.print("labelle: running (timeout: {d}s)...\n\n", .{secs});
            }
        } else {
            std.debug.print("labelle: running...\n\n", .{});
        }
        // Build a combined env map for the child when --scene (cli#229)
        // and/or --screenshot (cli#227) are set. Both flags need to be
        // surfaced as env vars to the spawned game:
        //  - LABELLE_SCENE          (cli#229 runtime scene-override)
        //  - LABELLE_SCREENSHOT_PATH
        //  - LABELLE_SCREENSHOT_AFTER_SEC
        // Loading-controller scripts read LABELLE_SCENE *after*
        // assets.allReady succeeds and call setScene(requested), so
        // asset streaming for large scenes no longer races boot. This
        // is now the ONLY mechanism for `--scene=` — the legacy
        // `.initial_prefab` rewrite was removed (see above).
        // Default the child env to the ZIG_*_CACHE_DIR map (cli#279) so the
        // rebuilt-and-run step still lands the compiler cache in user space.
        var env_map_storage: ?std.process.Environ.Map = null;
        defer if (env_map_storage) |*m| m.deinit();
        var env_map_ptr: ?*const std.process.Environ.Map = zig_env_ptr;
        const has_scene_env = parsed_args.scene_override != null;
        const has_screenshot_env = parsed_args.screenshot_path != null;
        // --headless (and the flags that imply it) surface as
        // LABELLE_HEADLESS=1 plus the optional uncapped/ticks knobs that
        // the sokol desktop backend reads. `parsed_args.headless` is
        // already set true by `--uncapped`/`--ticks`, so this one check
        // covers all three.
        const has_headless_env = parsed_args.headless;
        // --profile surfaces as LABELLE_PROFILE=1, enabling the engine's
        // built-in frame profiler. Independent of --headless.
        const has_profile_env = parsed_args.profile;
        // Fingerprint every path the capture could land at BEFORE the game
        // runs, so the post-run report can tell a file this run wrote from one
        // an earlier run left behind. The game's cwd — what a relative path
        // resolves against — is the project dir under --docker and the target
        // dir otherwise.
        const screenshot_probe: ?ScreenshotProbe = if (parsed_args.screenshot_path) |path|
            ScreenshotProbe.init(allocator, path, if (parsed_args.docker) project_dir else target_dir)
        else
            null;
        defer if (screenshot_probe) |p| p.deinit(allocator);
        if (has_scene_env or has_screenshot_env or has_headless_env or has_profile_env) {
            var extras: std.ArrayList(runner.EnvKV) = .empty;
            defer extras.deinit(allocator);
            // --scene / --profile / --screenshot(+--after): the list shared
            // with the Android launch (cli#397).
            var sec_buf: [32]u8 = undefined;
            try runner.appendRunOptionEnv(allocator, &extras, runOptionEnv(&parsed_args), &sec_buf);
            var ticks_buf: [32]u8 = undefined;
            if (parsed_args.headless) {
                try extras.append(allocator, .{ .key = "LABELLE_HEADLESS", .value = "1" });
                if (parsed_args.headless_uncapped) {
                    try extras.append(allocator, .{ .key = "LABELLE_HEADLESS_UNCAPPED", .value = "1" });
                }
                if (parsed_args.headless_ticks) |n| {
                    const ticks_str = try std.fmt.bufPrint(&ticks_buf, "{d}", .{n});
                    try extras.append(allocator, .{ .key = "LABELLE_HEADLESS_TICKS", .value = ticks_str });
                }
            }
            if (parsed_args.screenshot_path) |path| {
                // Deliberately "requested", not "will be written to": the
                // backend picks the real filename and may not honor this path
                // (labelle-bgfx#57 appends its own `.tga`). The authoritative
                // line is `ScreenshotProbe.report` after the run.
                std.debug.print("labelle: screenshot requested: '{s}'\n", .{path});
            }
            // For a non-docker run, fold the ZIG_*_CACHE_DIR vars in too so
            // both the build and run children share the managed cache. For a
            // docker run there is no managed toolchain, so just add extras.
            env_map_storage = if (parsed_args.docker)
                try runner.buildEnvironWithExtra(allocator, extras.items)
            else
                try runner.buildZigEnv(allocator, extras.items);
            env_map_ptr = &env_map_storage.?;
        }

        // When --docker was used, run the built binary directly instead of
        // calling `zig build run` (local Zig may be broken).
        if (parsed_args.docker) {
            // (A cross-compiled binary never reaches here: the launch is
            // skipped before the run hooks — `crossTargetLaunchSkipped`.)
            // The assembler names the desktop binary after the project
            // (sanitized) so concurrent games are distinguishable to
            // `pgrep` (labelle-assembler#362). Derive the same name here so
            // the docker run path execs the binary by its real on-disk name.
            const exe_name = try util.sanitizeExeName(allocator, parsed.name);
            defer allocator.free(exe_name);
            const bin_path = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "bin", exe_name });
            defer allocator.free(bin_path);
            var run_args: std.ArrayList([]const u8) = .empty;
            defer run_args.deinit(allocator);
            try run_args.append(allocator, bin_path);
            try appendRunForwardedArgs(&run_args, allocator, &parsed_args);
            if (reporter) |r| r.beginPhaseOrStep(.run, exe_name);
            noteRunSharesStdout(reporter);
            const run_outcome = runOutcome(try runner.runInheritTerm(allocator, project_dir, run_args.items, timeout_ns, env_map_ptr));
            if (run_outcome == .exited_error) {
                std.debug.print("\nlabelle: process exited with code {d}\n", .{run_outcome.status()});
            }
            if (screenshot_probe) |p| p.report(allocator);
            // The game ran: the pipeline is `done` even on a nonzero game
            // exit — the code is carried in the terminal record, and it is
            // also the CLI's exit status (cli#390). After hooks run first,
            // and only when the game itself exited clean — never after the
            // watchdog's kill, which is also exit 0.
            return provider_hooks.finishRun(&hook_site, hook_plans.run.after, run_out, run_outcome);
        } else {
            // Run the game BINARY DIRECTLY rather than via `zig build run`.
            // `zig build run` launches the game in its own child process
            // group, which ESCAPES the --timeout kill: the watchdog signals
            // labelle's direct child (the `zig build` process), the game
            // survives in its separate group, gets reparented to init, and
            // orphans. Run as labelle's own child and the game stays in the
            // process group the watchdog signals, so SIGTERM→SIGKILL
            // actually reaches it. Mirrors the --docker path.
            //
            // Keep the game's cwd at `target_dir` (a target_dir-relative
            // argv[0]) so saves land exactly where `zig build run` put them.
            //
            // There is deliberately NO second `zig build` here. The core
            // build above (`core_build`, or its `replace` hook) is the one
            // and only build of this command; the warm re-build that used
            // to sit here was a leftover of translating `zig build run`
            // into build-then-exec (cli#265) — a warm-cache no-op that
            // nonetheless re-ran the install steps, so a `zig-out/` file an
            // `after build` hook had signed, stripped or patched was copied
            // back to its unhooked original right before launch, and a
            // `replace` hook's build was quietly followed by the core one
            // (Codex P2 on #420). `run` begins when the game binary is
            // about to spawn.
            // Exe name: the assembler names the desktop exe after the
            // sanitized project (labelle-assembler#362); older generated
            // build.zig still emit `game`. Prefer the project name; fall back
            // to `game` when that binary isn't on disk, so this works both
            // before and after the rename ships. Run it by a target_dir-
            // relative path so the game's cwd stays `target_dir` (saves land
            // where `zig build run` put them). Mirrors the --docker path.
            // Probe with the platform executable suffix: on Windows the
            // assembler emits `<name>.exe`, so a suffix-less probe never
            // matches and would wrongly fall back to the legacy `game` name,
            // then fail to launch with FileNotFound (cli#309).
            const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
            const sanitized = try util.sanitizeExeName(allocator, parsed.name);
            defer allocator.free(sanitized);
            const sanitized_exe = try std.fmt.allocPrint(allocator, "{s}{s}", .{ sanitized, exe_suffix });
            defer allocator.free(sanitized_exe);
            const sanitized_full = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "bin", sanitized_exe });
            defer allocator.free(sanitized_full);
            const exe_basename: []const u8 = if (util.fileExists(sanitized_full)) sanitized_exe else "game" ++ exe_suffix;
            const rel_bin = try std.fs.path.join(allocator, &.{ "zig-out", "bin", exe_basename });
            defer allocator.free(rel_bin);
            var run_args: std.ArrayList([]const u8) = .empty;
            defer run_args.deinit(allocator);
            try run_args.append(allocator, rel_bin);
            try appendRunForwardedArgs(&run_args, allocator, &parsed_args);
            if (reporter) |r| r.beginPhaseOrStep(.run, exe_basename);
            noteRunSharesStdout(reporter);
            const run_outcome = runOutcome(try runner.runInheritTerm(allocator, target_dir, run_args.items, timeout_ns, env_map_ptr));
            if (run_outcome == .exited_error) {
                std.debug.print("\nlabelle: process exited with code {d}\n", .{run_outcome.status()});
            }
            if (screenshot_probe) |p| p.report(allocator);
            // The game ran: the pipeline is `done` even on a nonzero game
            // exit — the code is carried in the terminal record, and it is
            // also the CLI's exit status (cli#390). After hooks run first,
            // and only when the game itself exited clean — never after the
            // watchdog's kill, which is also exit 0.
            return provider_hooks.finishRun(&hook_site, hook_plans.run.after, run_out, run_outcome);
        }
    }
}

/// The `--target` of a `run --docker` whose launch is skipped: a
/// cross-compiled binary cannot run on this host. Only the host launch
/// branch launches a binary here — `wasm`, `ios` and `android` deploy their
/// own way — and a `replace run` hook stands in for the launch entirely, so
/// neither is skipped. `null` when the launch happens.
fn crossTargetLaunchSkipped(in_docker: bool, docker_target: ?[]const u8, platform: project_config.Platform, replaced: bool) ?[]const u8 {
    if (!in_docker or replaced) return null;
    switch (platform) {
        .wasm, .ios, .android => return null,
        else => return docker_target,
    }
}

test "pipeline: a cross-target docker run is skipped before the run hooks" {
    // The skipped shape: docker, a cross target, the host launch branch.
    try std.testing.expectEqualStrings("aarch64-linux", crossTargetLaunchSkipped(true, "aarch64-linux", .desktop, false).?);
    // Each condition alone is not enough.
    try std.testing.expect(crossTargetLaunchSkipped(false, "aarch64-linux", .desktop, false) == null);
    try std.testing.expect(crossTargetLaunchSkipped(true, null, .desktop, false) == null);
    // A replacement launches its own way; the deploy targets never reach
    // the host launch branch.
    try std.testing.expect(crossTargetLaunchSkipped(true, "aarch64-linux", .desktop, true) == null);
    for ([_]project_config.Platform{ .wasm, .ios, .android }) |platform| {
        try std.testing.expect(crossTargetLaunchSkipped(true, "aarch64-linux", platform, false) == null);
    }
}

/// Extensions a backend may append to the requested screenshot path instead of
/// honoring it verbatim. bgfx writes TGA and appends `.tga` to whatever it is
/// given, so `--screenshot=shot.png` lands at `shot.png.tga` (labelle-bgfx#57).
///
/// The append itself lives in the backend, out of this repo's reach — so once
/// the run is over `ScreenshotProbe.report` finishes the job here instead,
/// re-encoding the capture into the requested format and dropping the
/// doubly-named intermediate (cli#356, `screenshot_format.zig`). Every entry
/// must stay decodable by the vendored stb build (`stb_image_impl.c`).
const screenshot_suffixes = [_][]const u8{ ".tga", ".png", ".bmp" };

/// Pre-run fingerprint of one candidate path. Existence alone is not enough to
/// claim "this run wrote it" — a file left by an EARLIER run would be reported
/// as a fresh capture even when the current one failed, and a stale file at the
/// exact requested path would mask a newly written suffixed one. So compare
/// size+mtime across the run and treat only a created-or-changed file as ours.
const FileStamp = struct {
    existed: bool = false,
    size: u64 = 0,
    mtime_ns: i128 = 0,

    fn take(path: []const u8) FileStamp {
        const st = std.Io.Dir.cwd().statFile(config.globalIo(), path, .{}) catch return .{};
        return .{ .existed = true, .size = st.size, .mtime_ns = st.mtime.nanoseconds };
    }

    /// True when `after` represents a file this run created or rewrote.
    fn changed(before: FileStamp, after: FileStamp) bool {
        if (!after.existed) return false;
        if (!before.existed) return true;
        return before.size != after.size or before.mtime_ns != after.mtime_ns;
    }
};

/// The `labelle run` options that reach the game as `LABELLE_*` variables on
/// every platform (env block on desktop, intent extras on Android — cli#397).
/// The `run` outcome a launched game's termination stands for.
fn runOutcome(term: runner.Termination) provider_hooks.RunOutcome {
    return switch (term) {
        .exited => |code| provider_hooks.RunOutcome.fromExit(code),
        .timed_out => .timed_out,
    };
}

fn runOptionEnv(parsed_args: *const ParsedArgs) runner.RunOptionEnv {
    return .{
        .scene = parsed_args.scene_override,
        .profile = parsed_args.profile,
        .screenshot_path = parsed_args.screenshot_path,
        .screenshot_after_ns = parsed_args.screenshot_after_ns,
    };
}

/// Where a screenshot might land, fingerprinted before the game runs.
///
/// The CLI only forwards `LABELLE_SCREENSHOT_PATH`; the backend owns the real
/// filename and the CLI never verified the result, so a capture written to a
/// different path read as "no screenshot was produced" — the misreading this
/// exists to prevent.
///
/// `run_cwd` is the directory the game runs in, which is NOT the user's cwd:
/// normally `.labelle/<target>/` (so saves land where `zig build run` put
/// them), but `project_dir` under `--docker`. A relative `--screenshot=shot.png`
/// is resolved by the game against that cwd, so that is where to look and what
/// to print — an unqualified relative path would send the user to the wrong
/// directory.
const ScreenshotProbe = struct {
    /// Path as the user typed it.
    requested: []const u8,
    /// `requested` resolved against the game's cwd (owned).
    resolved: []const u8,
    /// Index 0 is `resolved`; the rest follow `screenshot_suffixes`.
    before: [1 + screenshot_suffixes.len]FileStamp = @splat(.{}),

    fn init(allocator: std.mem.Allocator, requested: []const u8, run_cwd: []const u8) ?ScreenshotProbe {
        const resolved: []const u8 = if (std.fs.path.isAbsolute(requested))
            allocator.dupe(u8, requested) catch return null
        else
            std.fs.path.join(allocator, &.{ run_cwd, requested }) catch return null;

        var probe: ScreenshotProbe = .{ .requested = requested, .resolved = resolved };
        for (0..probe.before.len) |i| {
            const path = probe.candidatePath(allocator, i) orelse continue;
            defer allocator.free(path);
            probe.before[i] = FileStamp.take(path);
        }
        return probe;
    }

    fn deinit(self: ScreenshotProbe, allocator: std.mem.Allocator) void {
        allocator.free(self.resolved);
    }

    /// Candidate `i`: 0 is the resolved path itself, then one per suffix.
    fn candidatePath(self: ScreenshotProbe, allocator: std.mem.Allocator, i: usize) ?[]u8 {
        if (i == 0) return allocator.dupe(u8, self.resolved) catch null;
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ self.resolved, screenshot_suffixes[i - 1] }) catch null;
    }

    /// Report where the screenshot ACTUALLY landed, after the game has exited.
    fn report(self: ScreenshotProbe, allocator: std.mem.Allocator) void {
        var stale_exact = false;
        for (0..self.before.len) |i| {
            const path = self.candidatePath(allocator, i) orelse continue;
            defer allocator.free(path);
            const after = FileStamp.take(path);
            if (!FileStamp.changed(self.before[i], after)) {
                // Pre-existing and untouched. Worth calling out only for the
                // exact path, where its presence is actively misleading.
                if (i == 0 and after.existed) stale_exact = true;
                continue;
            }
            self.reconcile(allocator, path);
            return;
        }

        std.debug.print("labelle: warning: no screenshot was written (looked for '{s}'", .{self.resolved});
        for (screenshot_suffixes) |suffix| std.debug.print(", '{s}{s}'", .{ self.resolved, suffix });
        std.debug.print(")\n", .{});
        if (stale_exact) {
            std.debug.print("  note: '{s}' exists but is unchanged — it is left over from an earlier run, not this one\n", .{self.resolved});
        }
        std.debug.print("  hint: capture needs a native surface on some backends — a headless bgfx device has no backbuffer to read back\n\n", .{});
    }

    /// The capture landed at `written`. Put it on the requested path when
    /// the CLI can (cli#356) — a same-format move, or a decode/re-encode
    /// through the vendored stb — then print where the file REALLY is.
    ///
    /// Every branch prints exactly one `screenshot written to` line naming
    /// the path that now holds the capture, so the line stays the
    /// authoritative one a script can parse.
    fn reconcile(self: ScreenshotProbe, allocator: std.mem.Allocator, written: []const u8) void {
        const plan = screenshot_format.plan(self.resolved, written);
        switch (plan) {
            .honored => std.debug.print("labelle: screenshot written to '{s}'\n", .{written}),
            .keep => {
                std.debug.print("labelle: screenshot written to '{s}'\n", .{written});
                if (screenshot_format.formatFromPath(self.resolved) == null) {
                    std.debug.print("  note: the backend appended its own extension — '{s}' names no image format, so the capture was left as written\n", .{self.resolved});
                } else {
                    std.debug.print("  note: the backend wrote a format this CLI cannot decode — the requested path '{s}' was not written\n", .{self.resolved});
                }
            },
            .move, .transcode => {
                screenshot_format.apply(allocator, plan, self.resolved, written) catch |err| {
                    // The capture still exists where the backend put it, so
                    // report THAT path — the old pre-#356 behaviour, which is
                    // the honest fallback when the conversion cannot happen.
                    std.debug.print("labelle: screenshot written to '{s}'\n", .{written});
                    std.debug.print("  note: the backend did not honor '{s}' and the CLI could not rewrite it ({s})\n", .{ self.resolved, @errorName(err) });
                    return;
                };
                std.debug.print("labelle: screenshot written to '{s}'\n", .{self.resolved});
                switch (plan) {
                    .move => std.debug.print("  note: the backend wrote '{s}'; moved onto the requested path\n", .{written}),
                    .transcode => |t| std.debug.print("  note: the backend wrote {s} to '{s}'; re-encoded as {s} at the requested path\n", .{ t.from.label(), written, t.to.label() }),
                    else => unreachable,
                }
            },
        }
    }
};

/// The post-run screenshot report end to end (cli#356): a backend that
/// appended its own extension is reconciled onto the requested path.
///
/// Drives the REAL `ScreenshotProbe` — pre-run fingerprint, suffix scan,
/// change detection, reconcile — rather than `screenshot_format` alone, so
/// the wiring between them is covered too. `report` prints to stderr, so
/// the `labelle: screenshot written to ...` lines in the test log are the
/// actual user-facing output.
pub const ScreenshotProbeSpec = struct {
    /// `ScreenshotProbe` resolves relative paths against the game's cwd and
    /// then works from the process cwd, and `std.testing.tmpDir` creates its
    /// directory under a cwd-relative `.zig-cache/tmp/`, so a cwd-relative
    /// `run_cwd` addresses exactly the files the tmp dir holds.
    fn runCwd(allocator: std.mem.Allocator, tmp: std.testing.TmpDir) ![]u8 {
        return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    }

    test "a .png request the backend answered with .png.tga lands as a PNG" {
        const a = std.testing.allocator;
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const run_cwd = try runCwd(a, tmp);
        defer a.free(run_cwd);

        // Fingerprint BEFORE the "run", exactly as the pipeline does.
        const probe = ScreenshotProbe.init(a, "shot.png", run_cwd).?;
        defer probe.deinit(a);

        // The "backend" writes TGA under the doubly-wrong name.
        try screenshot_format.writeTestFixture(a, tmp.dir, "shot.png.tga", .tga);

        probe.report(a);

        const out = try tmp.dir.readFileAlloc(io, "shot.png", a, .unlimited);
        defer a.free(out);
        try std.testing.expect(std.mem.startsWith(u8, out, "\x89PNG\r\n\x1a\n"));
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "shot.png.tga", .{}));
    }

    test "a capture left over from an earlier run is not reconciled" {
        const a = std.testing.allocator;
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const run_cwd = try runCwd(a, tmp);
        defer a.free(run_cwd);

        // Stale file exists BEFORE the probe fingerprints it, and the "run"
        // writes nothing. Touching it would turn a failed capture into a
        // report of a screenshot this run never took.
        try screenshot_format.writeTestFixture(a, tmp.dir, "shot.png.tga", .tga);
        const probe = ScreenshotProbe.init(a, "shot.png", run_cwd).?;
        defer probe.deinit(a);

        probe.report(a);

        _ = try tmp.dir.statFile(io, "shot.png.tga", .{});
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "shot.png", .{}));
    }

    test "an extension-less request is left where the backend put it" {
        const a = std.testing.allocator;
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const run_cwd = try runCwd(a, tmp);
        defer a.free(run_cwd);

        const probe = ScreenshotProbe.init(a, "shot", run_cwd).?;
        defer probe.deinit(a);

        try screenshot_format.writeTestFixture(a, tmp.dir, "shot.tga", .tga);

        probe.report(a);

        // Nothing was asked for, so `shot.tga` is the better name of the two.
        _ = try tmp.dir.statFile(io, "shot.tga", .{});
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "shot", .{}));
    }
};

pub const CollectPrebuildIgnorePathsSpec = struct {
    const steps: []const prebuild.Step = &.{
        .{ .run = &.{ "python3", "tools/gen.py" }, .outputs = &.{ "assets/out.png", "src/table.zig" } },
        .{ .run = &.{"./tools/nothing.sh"} }, // declares no outputs
    };

    fn free(a: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
        for (list.items) |f| a.free(f);
        list.deinit(a);
    }

    pub const hooks_enabled = struct {
        test "every declared output is excluded from the watch signature" {
            const a = std.testing.allocator;
            var got = collectPrebuildIgnorePaths(a, "/proj", steps, true);
            defer free(a, &got);

            try std.testing.expectEqual(@as(usize, 2), got.items.len);
            // Build the expectation with the SAME resolver the collector
            // uses. Re-implementing the join here (even via `std.fs.path.join`)
            // is not host-portable: `join` inserts the native separator
            // between its arguments but leaves the '/' inside a relative
            // path alone, so on Windows it yields `/proj\assets/out.png`
            // while `watchIgnorePath` normalises to `/proj\assets\out.png`.
            // This spec's subject is WHICH outputs are excluded, not how a
            // path is spelled — that belongs to `watchIgnorePath`'s own tests.
            const png = try serve.watchIgnorePath(a, "/proj", "assets/out.png");
            defer a.free(png);
            try std.testing.expectEqualStrings(png, got.items[0]);
        }

        test "a step that declares no outputs contributes nothing" {
            const a = std.testing.allocator;
            var got = collectPrebuildIgnorePaths(a, "/proj", steps[1..], true);
            defer free(a, &got);
            try std.testing.expectEqual(@as(usize, 0), got.items.len);
        }
    };

    // cli#361 review: with `LABELLE_NO_PREBUILD=1` the rebuild callback never
    // writes these files, so excluding them only hid an out-of-band
    // regeneration — a documented use of the kill switch — from the watcher,
    // leaving the browser on a stale build.
    pub const hooks_disabled = struct {
        test "the kill switch leaves declared outputs in the watch set" {
            const a = std.testing.allocator;
            var got = collectPrebuildIgnorePaths(a, "/proj", steps, false);
            defer free(a, &got);
            try std.testing.expectEqual(@as(usize, 0), got.items.len);
        }
    };
};

pub const ResolveExportOutputSpec = struct {
    // The export dir is wiped on every run, so a destructive `--output`
    // must be refused before it can delete the user's source tree.
    pub const rejects_destructive = struct {
        test "--output . (the project dir) is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "."),
            );
        }

        test "--output .. (an ancestor) is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", ".."),
            );
        }

        test "--output ../.. (a higher ancestor) is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "../.."),
            );
        }

        test "--output / (filesystem root) is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "/"),
            );
        }

        test "an absolute --output equal to the project dir is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "/proj/root"),
            );
        }

        test "an absolute --output that is an ancestor of the project is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "/proj"),
            );
        }

        test "foo/../.. collapsing to an escape is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "foo/../.."),
            );
        }
    };

    pub const accepts_dedicated = struct {
        test "a dedicated subdir under the project is accepted" {
            const a = std.testing.allocator;
            const out = try resolveExportOutput(a, "/proj/root", "release");
            defer a.free(out);
            // Compare against `join` rather than a hardcoded "/" so the
            // assertion holds on Windows (where join uses '\\').
            const want = try std.fs.path.join(a, &.{ "/proj/root", "release" });
            defer a.free(want);
            try std.testing.expectEqualStrings(want, out);
        }

        test "a nested dedicated subdir is accepted" {
            const a = std.testing.allocator;
            const out = try resolveExportOutput(a, "/proj/root", "dist/web");
            defer a.free(out);
            const want = try std.fs.path.join(a, &.{ "/proj/root", "dist/web" });
            defer a.free(want);
            try std.testing.expectEqualStrings(want, out);
        }

        test "an unrelated absolute --output is accepted verbatim" {
            // "/tmp/..." is absolute on POSIX and "rooted" (absolute) on
            // Windows, so it returns verbatim on both.
            const out = try resolveExportOutput(std.testing.allocator, "/proj/root", "/tmp/exports/game");
            defer std.testing.allocator.free(out);
            try std.testing.expectEqualStrings("/tmp/exports/game", out);
        }
    };

    // Windows treats both '/' and '\\' as separators and its filesystem is
    // case-insensitive. These run only on Windows CI (skipped elsewhere)
    // so the directory-wiping guard is actually exercised for those shapes
    // — a hardcoded '/' comparison here would wrongly allow a destructive
    // backslash/drive-letter `--output`.
    pub const windows_separators = struct {
        test "upward escapes via '\\' or mixed separators are rejected" {
            if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
            const a = std.testing.allocator;
            for ([_][]const u8{ "..\\secret", "../secret", "foo\\..\\..", "foo/..\\.." }) |esc| {
                try std.testing.expectError(
                    error.DestructiveOutputPath,
                    resolveExportOutput(a, "C:\\proj\\root", esc),
                );
            }
        }

        test "a case-differing absolute ancestor is rejected" {
            if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
            const a = std.testing.allocator;
            // Same directory on Windows (case-insensitive) — must be
            // treated as a destructive ancestor, not wrongly accepted.
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(a, "C:\\Proj\\Root", "c:\\proj"),
            );
        }

        test "a dedicated backslash subdir is accepted" {
            if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
            const a = std.testing.allocator;
            const out = try resolveExportOutput(a, "C:\\proj\\root", "release");
            defer a.free(out);
            const want = try std.fs.path.join(a, &.{ "C:\\proj\\root", "release" });
            defer a.free(want);
            try std.testing.expectEqualStrings(want, out);
        }
    };
};
