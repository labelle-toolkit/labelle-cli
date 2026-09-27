//! `wasm serve --watch` rebuilds (cli#208): `WasmRebuildCtx`, the context
//! the serve loop's watcher thread re-runs prebuild -> generate -> build
//! through, and `collectPrebuildIgnorePaths`, the watcher's `ignore_files`
//! set. The per-rebuild provider replan lives in `watch_replan.zig`.
const std = @import("std");
const config = @import("../config.zig");
const runner = @import("../runner.zig");
const assembler_proc = @import("../assembler_proc.zig");
const prebuild = @import("../prebuild.zig");
const material_toolchain = @import("../material_toolchain.zig");
const serve = @import("../serve.zig");
const provider_contract = @import("../provider_contract.zig");
const provider_dispatch = @import("../provider_dispatch.zig");
const provider_hooks = @import("../provider_hooks.zig");
const provider_env = @import("../provider_env.zig");
const testing = @import("testing.zig");

/// Rebuild context for `wasm serve --watch` (cli#208). Bundles the
/// generate+build inputs the initial pipeline computed so the serve
/// loop's watcher thread can re-run them on a source change. Passed to
/// `serve.serveAndOpen` as an opaque `*anyopaque` + a static `rebuild`
/// entry point matching `serve.RebuildFn`.
pub const WasmRebuildCtx = struct {
    allocator: std.mem.Allocator,
    asm_bin: assembler_proc.Assembler,
    project_dir: []const u8,
    platform_tag: []const u8,
    backend_tag: []const u8,
    output_dir: []const u8,
    target_dir: []const u8,
    zig_args: []const []const u8,
    /// The base environment of the compile, without any hook contribution:
    /// each rebuild composes its own contributions onto it (`coreBuild`).
    zig_env: ?*const std.process.Environ.Map,
    /// The inputs of the effective optimize mode (`optimize.zig`), which the
    /// replan recomputes from the providers it rediscovers: the explicit
    /// `--optimize`, and the core's fallback for the served target. A
    /// provider edit that adds, changes or removes the owner's
    /// `.target_defaults` reaches the next rebuild's `-Doptimize` and wire
    /// `optimize`; an explicit flag always wins.
    optimize_flag: ?[]const u8 = null,
    fallback_optimize: ?[]const u8 = null,
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
    /// Rediscovers the providers and replans both phases on EVERY rebuild
    /// (ownership pre-check first, full replan after the prebuild steps —
    /// see `Replan`), so a watched edit to `project.labelle`, to a provider
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
        TargetPrecheckFailed,
        PrebuildFailed,
        ReplanFailed,
        HookFailed,
        ShaderPreflightFailed,
        GenerateFailed,
        FingerprintFailed,
        ZigSpawnFailed,
        BuildFailed,
    };

    /// The per-rebuild replan seam, in two stages around the prebuild steps:
    ///
    /// - `precheck` runs FIRST, ahead of every side-effecting stage: a cheap,
    ///   side-effect-free ownership check of the served target against the
    ///   manifests the declared packages have NOW (no install, no lock, no
    ///   plan). It refuses only a target whose owner is clearly gone or
    ///   unpinned, so an edit that drops or unpins the owner runs no prebuild
    ///   work for the refused configuration (Codex P2 on #421). A verdict it
    ///   cannot draw yet (a declared package it cannot read, a local
    ///   manifest a prebuild step may generate) is left to `run`.
    /// - `run` runs AFTER the prebuild steps and before the first hook phase:
    ///   the full rediscovery + replan + ownership validation, so provider
    ///   metadata a prebuild step generates — a local provider's
    ///   `plugin.labelle`, say — reaches THIS rebuild's plans (Codex P2 on
    ///   #427). It receives `ctx` and the context it must update
    ///   (`hooks.providers`, `hooks.cfg`, `generate_plan`, `build_plan`).
    pub const Replan = struct {
        ctx: *anyopaque,
        precheck: ?*const fn (*anyopaque, *WasmRebuildCtx) anyerror!void = null,
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
    pub fn rebuild(ctx_ptr: *anyopaque) bool {
        const self: *WasmRebuildCtx = @ptrCast(@alignCast(ctx_ptr));
        self.rebuildStaged() catch return false;
        return true;
    }

    /// One watched rebuild. Its environment is built fresh from the
    /// inherited one plus the contributions of the hooks that run in THIS
    /// rebuild (contract §2), so a hook a replan removed leaves nothing
    /// behind. It replaces the last successful build's environment only if
    /// the whole rebuild succeeds: one that fails at any stage (the
    /// pre-check, a prebuild step, the replan, a hook, the compile) puts the
    /// previous one back, so the served build and the `after run` hooks at
    /// the session's end keep the environment that build was made with.
    pub fn rebuildStaged(self: *WasmRebuildCtx) Stage!void {
        var previous = self.hooks.env;
        self.hooks.env = .{ .windows = previous.windows };
        self.rebuildStages() catch |err| {
            self.hooks.env.deinit();
            self.hooks.env = previous;
            return err;
        };
        previous.deinit();
    }

    fn rebuildStages(self: *WasmRebuildCtx) Stage!void {
        const a = self.allocator;

        // 0. The served target's ownership pre-check (`Replan.precheck`),
        //    FIRST, ahead of every side-effecting stage: a watched edit that
        //    removes or unpins the target owner used to be refused only
        //    after the prebuild commands below had already run once for the
        //    invalid configuration (Codex P2 on #421). Metadata only; the
        //    authoritative check is the full replan after the prebuild.
        if (self.replan) |replan| if (replan.precheck) |precheck| {
            precheck(replan.ctx, self) catch |err| {
                std.debug.print("labelle: rebuild stopped before prebuild: served target check failed ({s})\n", .{@errorName(err)});
                return error.TargetPrecheckFailed;
            };
        };

        // 0a. Re-run the declared prebuild steps, ahead of generation just
        //     as the initial pipeline does. Steps that declare `.inputs` +
        //     `.outputs` are skipped while fresh, so the common watch
        //     iteration costs a few stats — and their declared `.outputs`
        //     are excluded from the watch signature (`ignore_files` at the
        //     `serveAndOpen` call below), so the run that DOES regenerate
        //     them no longer looks like a fresh edit on the next poll.
        //     A step that declares no `.outputs` runs on every rebuild by
        //     design and is not excluded from anything; if such a step
        //     also writes into the watched tree the watcher settles after
        //     one follow-up rebuild — a few, capped, when it writes a
        //     different path each run (`serve.WatchBaseline`) — but
        //     declaring `.outputs` avoids even those.
        self.run_prebuild(a, self.project_dir, self.prebuild_steps, self.prebuild_opts) catch |err| {
            std.debug.print("labelle: rebuild prebuild step failed ({s})\n", .{@errorName(err)});
            return error.PrebuildFailed;
        };

        // 0a'. Re-read the project, rediscover the providers, re-check that
        //      the served target still has a pinned owner and replan the
        //      hook phases for THIS rebuild (see `replan`) — AFTER the
        //      prebuild steps, which may generate the provider metadata the
        //      discovery reads (a local provider's `plugin.labelle`), and
        //      whose declared outputs never schedule a corrective rebuild of
        //      their own; before every hook phase. A failing replan — a
        //      malformed manifest saved mid-session, say — is reported like
        //      a failing core step and stops here, before any hook.
        if (self.replan) |replan| {
            replan.run(replan.ctx, self) catch |err| {
                std.debug.print("labelle: rebuild stopped before generate: provider replan failed ({s})\n", .{@errorName(err)});
                return error.ReplanFailed;
            };
        }

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
            runner.fixFingerprints(a, self.project_dir, self.output_dir, &self.hooks.env) catch |err| {
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
        var composed: ?std.process.Environ.Map = if (self.zig_env) |base|
            (if (self.hooks.env.isEmpty()) null else self.hooks.env.compose(a, base) catch |err| {
                std.debug.print("labelle: rebuild could not compose the hook environment ({s})\n", .{@errorName(err)});
                return error.ZigSpawnFailed;
            })
        else
            null;
        defer if (composed) |*m| m.deinit();
        const env: ?*const std.process.Environ.Map = if (composed) |*m| m else self.zig_env;
        const res = runner.runZigWithEnv(a, self.target_dir, self.zig_args, env) catch |err| {
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
        var site = testing.testSite(a, project);
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
        var site = testing.testSite(a, project);
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
            // The ownership pre-check: counts runs; `refuse_next` stands in
            // for a target whose owner is clearly gone.
            var prechecks: usize = 0;
            var refuse_next = false;
            fn precheck(_: *anyopaque, _: *WasmRebuildCtx) anyerror!void {
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
            .replan = .{ .ctx = &counter, .precheck = Spy.precheck, .run = Spy.replan },
        };
        // Production wiring: the default prebuild runner IS the cold one.
        const default_prebuild = std.meta.fieldInfo(WasmRebuildCtx, .run_prebuild).defaultValue() orelse return error.TestUnexpectedResult;
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
        try std.testing.expect(rebuild(@ptrCast(&ctx)));
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
pub fn collectPrebuildIgnorePaths(
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
        fn precheck(_: *anyopaque, _: *WasmRebuildCtx) anyerror!void {
            if (precheck_fails) return error.NoProviderForTarget;
        }
        fn replan(_: *anyopaque, _: *WasmRebuildCtx) anyerror!void {}
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
    var ctx = WasmRebuildCtx{
        .allocator = a,
        .asm_bin = .{ .path = "" },
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
        .run_hook_phase = Spy.run,
        .replan = .{ .ctx = &dummy, .precheck = Spy.precheck, .run = Spy.replan },
        .generate_plan = .{ .before = &.{Spy.planned("tc", .generate, .before)}, .replace = Spy.planned("gen", .generate, .replace) },
        .build_plan = .{ .replace = Spy.planned("build", .build, .replace) },
    };
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
