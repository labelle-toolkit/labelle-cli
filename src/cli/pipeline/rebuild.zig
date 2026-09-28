//! Watched rebuilds (cli#208, RFC cli#466 §3.4): `RebuildCtx`, the context
//! a watch loop's thread re-runs replan -> prebuild -> generate -> build
//! through, and `collectPrebuildIgnorePaths`, the watcher's ignore set.
//! The per-rebuild provider replan lives in `rebuild_replan.zig`.
//!
//! A rebuild is a transaction (cli#469): everything a replan changes — the
//! providers, the config, the prebuild steps, the plans, the optimize mode,
//! the `zig build` argv, the environment, the lock — is staged while the
//! rebuild runs and committed only once it has fully succeeded (and been
//! published, when the session publishes). Any failure, a cancellation
//! included, restores the whole previous state.
const std = @import("std");
const config = @import("../config.zig");
const runner = @import("../runner.zig");
const assembler_proc = @import("../assembler_proc.zig");
const prebuild = @import("../prebuild.zig");
const material_toolchain = @import("../material_toolchain.zig");
const watch = @import("../watch.zig");
const supervise = @import("../supervise.zig");
const project_config = @import("../project_config.zig");
const provider_contract = @import("../provider_contract.zig");
const provider_dispatch = @import("../provider_dispatch.zig");
const provider_hooks = @import("../provider_hooks.zig");
const provider_env = @import("../provider_env.zig");
const testing = @import("testing.zig");
const generate = @import("generate.zig");
const install = @import("install.zig");
const plugins = @import("../plugins.zig");

/// Rebuild context for a watch session. Bundles the generate+build inputs
/// the initial pipeline computed so the watcher thread can re-run them on
/// a source change. Handed to the watch loop as an opaque `*anyopaque` + a
/// static `rebuild` entry point matching `watch.RebuildFn`.
pub const RebuildCtx = struct {
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
    /// The project's declared `.prebuild` steps (cli#355). A watched rebuild
    /// must re-run them: they are what turn an edited `.tsx`/generator into
    /// the atlas or `.zig` table the regeneration below then reads, so
    /// skipping them would build a "successful" rebuild made of STALE
    /// generated assets. The replan's pre-check swaps in the steps an edited
    /// `project.labelle` declares BEFORE they run (cli#463).
    prebuild_steps: []const prebuild.Step,
    /// Options for those steps. `fatal_on_step_failure = false` here: a
    /// failing step in watch mode must report and keep the session alive,
    /// like a failing `generate` or `zig build` already does.
    prebuild_opts: prebuild.Options,
    /// The prebuild runner. A field only so the stage-order test below can
    /// observe whether the steps ran without spawning them; production never
    /// overrides it.
    run_prebuild: *const fn (std.mem.Allocator, []const u8, []const prebuild.Step, prebuild.Options) prebuild.Error!void = prebuild.runAll,
    /// The shader-compiler override gate, run AFTER the prebuild steps and
    /// the `before generate` hooks and BEFORE generation on every rebuild —
    /// the same function the cold pipeline runs before its `assembler
    /// generate`. A field only so the stage test below can supply the
    /// override value without touching the process environment.
    shader_preflight: *const fn (std.mem.Allocator, []const u8) anyerror!void = material_toolchain.preflight,
    /// The core generation's pre-passes (ASTC conversion, `--bake`), run
    /// before the assembler on every core-generated rebuild exactly as the
    /// cold pipeline runs them (`generate.corePrepasses`), against the
    /// rebuild's project config; `null` skips them (the plumbing tests).
    prepass: ?generate.Prepass = null,
    run_prepasses: *const fn (std.mem.Allocator, []const u8, project_config.ProjectConfig, generate.Prepass) anyerror!void = generate.corePrepasses,
    /// The managed-Python PATH wiring of the prebuild steps, the cold
    /// pipeline's (`install.wirePrebuildPython`): a step added mid-session
    /// gets it before it first runs. A field only so a test can observe it.
    wire_prebuild_env: *const fn (std.mem.Allocator, []const prebuild.Step) void = install.wirePrebuildPython,
    /// Provider lifecycle hooks (contract §6). A watched rebuild re-runs the
    /// `generate` and `build` plans in the same before / core-or-replace /
    /// after order as the cold pipeline. `hooks` is the rebuild's own site:
    /// the watch session hands it a copy of the cold pipeline's, so the
    /// running replacement's session configuration is never touched by a
    /// rebuild; the legacy serve passes the pipeline's site itself.
    hooks: *provider_hooks.Site,
    generate_plan: provider_hooks.Plan = .{},
    build_plan: provider_hooks.Plan = .{},
    /// Re-reads the project and replans on EVERY rebuild (see `Replan`), so
    /// a watched edit to `project.labelle`, to a provider manifest or to
    /// `provider_config` reaches the next rebuild. `null` keeps the startup
    /// plans (the plumbing tests' shape).
    replan: ?Replan = null,
    /// Runs once every stage of a rebuild succeeded, before the commit: the
    /// watch session's publication (`watch.Publisher`). A failure fails the
    /// rebuild — nothing is committed.
    publish: ?Publish = null,
    /// The step output directories of the layout contract, as the cold
    /// pipeline computed them (`provider_hooks.stepOutputDir`).
    generate_out: []const u8 = "",
    build_out: []const u8 = "",
    /// The phase runner. A field only so the plumbing test below can record
    /// the phases without a host compiler; production never overrides it.
    run_hook_phase: *const fn (*provider_hooks.Site, []const provider_hooks.Planned, provider_contract.Step, provider_contract.Phase, []const u8) anyerror!u8 = provider_hooks.runPhase,
    /// The supervised group the rebuild's children run in (`supervise.zig`);
    /// once cancelled, a rebuild stops at its next stage boundary. `null`
    /// runs unsupervised (the legacy serve, the plumbing tests).
    group: ?*supervise.Group = null,
    /// The declared outputs of the committed prebuild steps, excluded from
    /// the watch signature (`collectPrebuildIgnorePaths`); swapped at the
    /// commit that swaps the steps (cli#463). `hooks_enabled` is the
    /// `LABELLE_NO_PREBUILD` kill switch.
    ignore: watch.IgnoreSet = .{},
    hooks_enabled: bool = true,
    /// The environment the running replacement was launched with (a watch
    /// session): a rebuild whose hooks contribute a different one ends with
    /// the restart diagnostic and publishes nothing — the replacement
    /// cannot pick up a new toolchain environment. `null`: no such check.
    launch_env: ?*const provider_env.Accumulator = null,

    /// Which stage a rebuild stopped at. Ordered as the stages run; the
    /// watch loop only needs the bool, but the tests assert the ORDER.
    pub const Stage = error{
        Canceled,
        TargetPrecheckFailed,
        SessionChanged,
        PrebuildFailed,
        ReplanFailed,
        HookFailed,
        ShaderPreflightFailed,
        GenerateFailed,
        FingerprintFailed,
        ZigSpawnFailed,
        BuildFailed,
        PublishFailed,
        LockCommitFailed,
    };

    /// The per-rebuild replan seam, around the prebuild steps:
    ///
    /// - `precheck` runs FIRST, ahead of every side-effecting stage: it
    ///   re-reads `project.labelle` for this rebuild, stages the prebuild
    ///   steps it declares (so an edited step runs in THIS rebuild,
    ///   cli#463), and draws the cheap, metadata-only ownership verdict of
    ///   the served target. A verdict it cannot draw yet is left to `run`.
    /// - `run` runs AFTER the prebuild steps and before the first hook phase:
    ///   the full rediscovery + replan + ownership validation, so provider
    ///   metadata a prebuild step generates reaches THIS rebuild's plans
    ///   (Codex P2 on #427). It stages what it replans on the context.
    /// - `commit_lock` moves the rebuild's staged `labelle.lock` over the
    ///   project's at the rebuild's commit point (the last step that may
    ///   still fail): before the publication advances its generation, so a
    ///   consumer never sees new output with the old lock, and while a
    ///   failure still rolls the rebuild back (cli#474).
    /// - `commit` / `rollback` end the transaction (cli#469): `commit` once
    ///   the whole rebuild succeeded, `rollback` on any failure, restoring
    ///   whatever the replan changed outside the context (its generation,
    ///   the lock on disk — a lock `commit_lock` already moved included).
    ///
    /// Either may fail with `error.SessionChanged` when the edit affects the
    /// running replacement; it has printed the restart diagnostic.
    pub const Replan = struct {
        ctx: *anyopaque,
        precheck: ?*const fn (*anyopaque, *RebuildCtx) anyerror!void = null,
        run: *const fn (*anyopaque, *RebuildCtx) anyerror!void,
        commit_lock: ?*const fn (*anyopaque) anyerror!void = null,
        commit: ?*const fn (*anyopaque) void = null,
        rollback: ?*const fn (*anyopaque) void = null,
    };

    /// The publication (`watch.Publisher.publish`). It runs the gate's
    /// checks at their points (`watch.PublishGate`): the rebuild's cancel
    /// check before the output switch, and its commit point — the last
    /// cancel check and the lock commit — before the generation advances.
    pub const Publish = struct {
        ctx: *anyopaque,
        run: *const fn (*anyopaque, watch.PublishGate) anyerror!void,
    };

    /// Everything a rebuild may change on the context, as it was before.
    const Saved = struct {
        providers: []const provider_dispatch.Provider,
        cfg: project_config.ProjectConfig,
        optimize: provider_contract.Optimize,
        env: provider_env.Accumulator,
        prebuild_steps: []const prebuild.Step,
        generate_plan: provider_hooks.Plan,
        build_plan: provider_hooks.Plan,
        zig_args: []const []const u8,
        lock_path: ?[]const u8,
    };

    fn save(self: *const RebuildCtx) Saved {
        return .{
            .providers = self.hooks.providers,
            .cfg = self.hooks.cfg,
            .optimize = self.hooks.optimize,
            .env = self.hooks.env,
            .prebuild_steps = self.prebuild_steps,
            .generate_plan = self.generate_plan,
            .build_plan = self.build_plan,
            .zig_args = self.zig_args,
            .lock_path = self.hooks.lock_path,
        };
    }

    fn restore(self: *RebuildCtx, saved: Saved) void {
        self.hooks.providers = saved.providers;
        self.hooks.cfg = saved.cfg;
        self.hooks.optimize = saved.optimize;
        self.hooks.env = saved.env;
        self.prebuild_steps = saved.prebuild_steps;
        self.generate_plan = saved.generate_plan;
        self.build_plan = saved.build_plan;
        self.zig_args = saved.zig_args;
        self.hooks.lock_path = saved.lock_path;
    }

    fn canceled(self: *const RebuildCtx) bool {
        const group = self.group orelse return false;
        return group.isCancelled();
    }

    fn checkCanceled(self: *const RebuildCtx) Stage!void {
        if (self.canceled()) return error.Canceled;
    }

    /// The rebuild's commit point: nothing after it may fail. A cancel
    /// that arrived during the stages (a publication copy included) is
    /// honoured here, and the staged lock is committed — a failure to
    /// move it fails the rebuild, which rolls back (cli#474).
    fn commitPoint(self: *RebuildCtx) Stage!void {
        try self.checkCanceled();
        const replan = self.replan orelse return;
        const commit_lock = replan.commit_lock orelse return;
        commit_lock(replan.ctx) catch |err| {
            std.debug.print("labelle: rebuild could not commit labelle.lock ({s}); nothing is published\n", .{@errorName(err)});
            return error.LockCommitFailed;
        };
    }

    fn gateBeforeSwitch(ptr: *anyopaque) anyerror!void {
        const self: *RebuildCtx = @ptrCast(@alignCast(ptr));
        try self.checkCanceled();
    }

    fn gateBeforeAdvance(ptr: *anyopaque) anyerror!void {
        const self: *RebuildCtx = @ptrCast(@alignCast(ptr));
        try self.commitPoint();
    }

    /// One hook phase of a watched rebuild. A failing hook (nonzero exit, or
    /// an error resolving the host/pin) stops the rebuild like a failing
    /// core step does: reported, session kept alive, nothing published.
    fn hookPhase(self: *RebuildCtx, list: []const provider_hooks.Planned, step: provider_contract.Step, phase: provider_contract.Phase, output_dir: []const u8) Stage!void {
        if (list.len == 0) return;
        try self.checkCanceled();
        const code = self.run_hook_phase(self.hooks, list, step, phase, output_dir) catch |err| {
            if (self.canceled()) return error.Canceled;
            std.debug.print("labelle: rebuild {s} {s} hook failed ({s})\n", .{ @tagName(phase), @tagName(step), @errorName(err) });
            return error.HookFailed;
        };
        if (code != 0) return if (self.canceled()) error.Canceled else error.HookFailed;
    }

    /// The watch loop's entry point. Returns true only on a clean,
    /// committed rebuild; on any failure it prints the error (keeping the
    /// session alive) and returns false, so nothing consumes a broken build.
    pub fn rebuild(ctx_ptr: *anyopaque) bool {
        const self: *RebuildCtx = @ptrCast(@alignCast(ctx_ptr));
        // The rebuild's children run in the session's supervised group.
        const previous = supervise.current;
        supervise.current = self.group;
        defer supervise.current = previous;
        self.rebuildStaged() catch |err| {
            if (err == error.Canceled) std.debug.print("labelle: rebuild cancelled\n", .{});
            return false;
        };
        return true;
    }

    /// One watched rebuild, as a transaction (cli#469). Its environment is
    /// built fresh from the inherited one plus the contributions of the
    /// hooks that run in THIS rebuild (contract §2), so a hook a replan
    /// removed leaves nothing behind. Everything the rebuild changes —
    /// environment, replanned providers, config, prebuild steps, plans,
    /// optimize mode, argv — replaces the committed state only if the whole
    /// rebuild (its publication included) succeeds; a failure at any stage
    /// puts the whole previous state back, and the replan rolls back its
    /// generation and the lock. The ignore set follows the committed
    /// prebuild steps (cli#463).
    pub fn rebuildStaged(self: *RebuildCtx) Stage!void {
        const saved = self.save();
        self.hooks.env = .{ .windows = saved.env.windows };
        self.rebuildStages() catch |err| {
            self.hooks.env.deinit();
            self.restore(saved);
            if (self.replan) |replan| if (replan.rollback) |rollback| rollback(replan.ctx);
            return err;
        };
        var old_env = saved.env;
        old_env.deinit();
        if (self.replan) |replan| if (replan.commit) |commit| commit(replan.ctx);
        // The commit point moved any staged lock over `labelle.lock`.
        self.hooks.lock_path = saved.lock_path;
        self.refreshIgnore();
    }

    fn rebuildStages(self: *RebuildCtx) Stage!void {
        const a = self.allocator;
        try self.checkCanceled();

        // 0. The config replan and the served target's ownership pre-check
        //    (`Replan.precheck`), FIRST, ahead of every side-effecting stage:
        //    an edit that removes or unpins the target owner is refused before
        //    any prebuild command runs for it (Codex P2 on #421), and an
        //    edited `.prebuild` list is staged here so the steps below are the
        //    ones the project declares NOW (cli#463).
        if (self.replan) |replan| if (replan.precheck) |precheck| {
            precheck(replan.ctx, self) catch |err| {
                if (err == error.SessionChanged) return error.SessionChanged;
                if (self.canceled()) return error.Canceled;
                std.debug.print("labelle: rebuild stopped before prebuild: served target check failed ({s})\n", .{@errorName(err)});
                return error.TargetPrecheckFailed;
            };
        };

        // 0a. Re-run the declared prebuild steps, ahead of generation just
        //     as the initial pipeline does. Steps that declare `.inputs` +
        //     `.outputs` are skipped while fresh; their declared `.outputs`
        //     are excluded from the watch signature (`ignore`), so the run
        //     that DOES regenerate them does not look like a fresh edit.
        try self.checkCanceled();
        if (self.hooks_enabled) self.wire_prebuild_env(a, self.prebuild_steps);
        self.run_prebuild(a, self.project_dir, self.prebuild_steps, self.prebuild_opts) catch |err| {
            if (self.canceled()) return error.Canceled;
            std.debug.print("labelle: rebuild prebuild step failed ({s})\n", .{@errorName(err)});
            return error.PrebuildFailed;
        };

        // 0a'. Rediscover the providers, re-check that the served target
        //      still has a pinned owner and replan the hook phases for THIS
        //      rebuild — AFTER the prebuild steps, which may generate the
        //      provider metadata the discovery reads; before every hook phase.
        try self.checkCanceled();
        if (self.replan) |replan| {
            replan.run(replan.ctx, self) catch |err| {
                if (err == error.SessionChanged) return error.SessionChanged;
                if (self.canceled()) return error.Canceled;
                std.debug.print("labelle: rebuild stopped before generate: provider replan failed ({s})\n", .{@errorName(err)});
                return error.ReplanFailed;
            };
        }

        // 0b. The `before generate` hooks, then the shader-compiler override
        //     gate AFTER them (a prebuild step or a before-generate hook may
        //     be what creates `materials/`; Codex P2 on #420) and BEFORE the
        //     core generation.
        try self.hookPhase(self.generate_plan.before, .generate, .before, self.generate_out);
        self.shader_preflight(a, self.project_dir) catch |err| {
            std.debug.print("labelle: rebuild stopped before generate: shader compiler override rejected ({s})\n", .{@errorName(err)});
            return error.ShaderPreflightFailed;
        };

        // 1. Regenerate — scene/prefab/script *structure* can change, not
        //    just @embedFile'd content — inside the `generate` hook phases.
        if (self.generate_plan.replace) |replacement| {
            try self.hookPhase(&.{replacement}, .generate, .replace, self.generate_out);
        } else {
            try self.checkCanceled();
            if (self.prepass) |opts| self.run_prepasses(a, self.project_dir, self.hooks.cfg, opts) catch |err| {
                if (self.canceled()) return error.Canceled;
                std.debug.print("labelle: rebuild generation pre-pass failed ({s})\n", .{@errorName(err)});
                return error.GenerateFailed;
            };
            var asm_bin = self.asm_bin;
            // A failed regeneration fails this rebuild, never the session.
            asm_bin.fatal_on_failure = false;
            assembler_proc.generate(asm_bin, a, self.project_dir, self.platform_tag, self.backend_tag) catch |err| {
                if (self.canceled()) return error.Canceled;
                std.debug.print("labelle: rebuild generate failed ({s})\n", .{@errorName(err)});
                return error.GenerateFailed;
            };
            // 2. `generate` rewrites build.zig with a placeholder fingerprint;
            //    re-fix it before building.
            try self.checkCanceled();
            runner.fixFingerprints(a, self.project_dir, self.output_dir, &self.hooks.env) catch |err| {
                if (self.canceled()) return error.Canceled;
                std.debug.print("labelle: rebuild fingerprint fix failed ({s})\n", .{@errorName(err)});
                return error.FingerprintFailed;
            };
        }
        try self.hookPhase(self.generate_plan.after, .generate, .after, self.generate_out);
        // 3. Rebuild the target (captured output so a compile error surfaces
        //    in the terminal without killing the session), inside the
        //    `build` hook phases.
        try self.hookPhase(self.build_plan.before, .build, .before, self.build_out);
        if (self.build_plan.replace) |replacement| {
            try self.hookPhase(&.{replacement}, .build, .replace, self.build_out);
        } else {
            try self.coreBuild();
        }
        try self.hookPhase(self.build_plan.after, .build, .after, self.build_out);

        // 4. Every build stage and every `after build` hook succeeded: only
        //    now may the output be published (RFC cli#466 §3.4) — unless
        //    the hooks contributed an environment the running replacement
        //    was not launched with.
        try self.checkCanceled();
        if (self.launch_env) |launched| if (!self.hooks.env.sameAs(launched)) {
            return @import("session_key.zig").SessionKey.report("the provider environment");
        };
        const p = self.publish orelse return self.commitPoint();
        p.run(p.ctx, .{ .ctx = self, .before_switch = gateBeforeSwitch, .before_advance = gateBeforeAdvance }) catch |err| switch (err) {
            // The gate's own verdicts, reported where they were drawn.
            error.Canceled => return error.Canceled,
            error.LockCommitFailed => return error.LockCommitFailed,
            else => {
                std.debug.print("labelle: rebuild could not publish its output ({s}); the last good output stays published\n", .{@errorName(err)});
                return error.PublishFailed;
            },
        };
    }

    fn coreBuild(self: *RebuildCtx) Stage!void {
        const a = self.allocator;
        try self.checkCanceled();
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
            if (self.canceled()) return error.Canceled;
            std.debug.print("labelle: rebuild could not spawn zig ({s})\n", .{@errorName(err)});
            return error.ZigSpawnFailed;
        };
        defer a.free(res.stdout);
        defer a.free(res.stderr);
        if (self.canceled()) return error.Canceled;
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

    /// Recompute the ignore set from the committed prebuild steps, and the
    /// extra watched roots from the committed local providers (cli#474),
    /// swapping them (and moving `epoch`) only when either changed.
    pub fn refreshIgnore(self: *RebuildCtx) void {
        const a = self.allocator;
        var next = watchIgnorePaths(a, self.project_dir, self.prebuild_steps, self.hooks_enabled);
        var roots = localProviderRoots(a, self.project_dir, self.hooks.cfg.plugins);
        if (sameFiles(self.ignore.files, next.items) and sameFiles(self.ignore.roots, roots.items)) {
            freePaths(a, &next);
            freePaths(a, &roots);
            return;
        }
        const owned = next.toOwnedSlice(a) catch {
            freePaths(a, &next);
            freePaths(a, &roots);
            return;
        };
        const owned_roots = roots.toOwnedSlice(a) catch {
            for (owned) |f| a.free(f);
            a.free(owned);
            freePaths(a, &roots);
            return;
        };
        self.freeIgnore();
        self.ignore = .{ .files = owned, .roots = owned_roots, .epoch = self.ignore.epoch + 1 };
    }

    /// Seed the ignore set from the startup steps (epoch unchanged).
    pub fn initIgnore(self: *RebuildCtx) void {
        const epoch = self.ignore.epoch;
        self.refreshIgnore();
        self.ignore.epoch = epoch;
    }

    fn freeIgnore(self: *RebuildCtx) void {
        for (self.ignore.files) |f| self.allocator.free(f);
        if (self.ignore.files.len != 0) self.allocator.free(self.ignore.files);
        self.ignore.files = &.{};
        for (self.ignore.roots) |r| self.allocator.free(r);
        if (self.ignore.roots.len != 0) self.allocator.free(self.ignore.roots);
        self.ignore.roots = &.{};
    }

    pub fn deinit(self: *RebuildCtx) void {
        self.freeIgnore();
    }

    fn sameFiles(x: []const []const u8, y: []const []const u8) bool {
        if (x.len != y.len) return false;
        for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
        return true;
    }

    fn freePaths(a: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
        for (list.items) |f| a.free(f);
        list.deinit(a);
    }
};

/// Everything a rebuild itself writes into the watched tree: the prebuild
/// steps' declared outputs (`collectPrebuildIgnorePaths`) and the project's
/// `labelle.lock`, which the CLI writes (a replan's commit) and nobody edits
/// as an input — the build reads `project.labelle`. The watch session's
/// pre-build baseline uses the same set as the watcher. Caller owns it.
pub fn watchIgnorePaths(allocator: std.mem.Allocator, project_dir: []const u8, steps: []const prebuild.Step, hooks_enabled: bool) std.ArrayList([]const u8) {
    var out = collectPrebuildIgnorePaths(allocator, project_dir, steps, hooks_enabled);
    const lock = watch.watchIgnorePath(allocator, project_dir, "labelle.lock") catch return out;
    out.append(allocator, lock) catch allocator.free(lock);
    return out;
}

/// The source trees of the project's LOCAL providers (a `local:` or `@`
/// package with a `plugin.labelle`) that the project's own walk does not
/// cover, as canonical paths: the watch session watches them too, so an
/// edit to a provider's hooks or tools rebuilds (cli#474).
///
/// Collapsed so each file is walked exactly once — the watch signature
/// XOR-folds every file, and a file folded twice cancels out, hiding its
/// edits: a provider the project's walk reaches (inside the project, not
/// under a skipped directory or a nested checkout) is dropped, and so is a
/// provider another kept root's walk reaches. A provider that CONTAINS the
/// project (`local:../..`) is kept; its walk skips the project
/// (`computeSignatureRoots`). Best effort: a package that cannot be
/// resolved is not watched. Caller owns the list.
pub fn localProviderRoots(allocator: std.mem.Allocator, project_dir: []const u8, deps: []const project_config.PluginDep) std.ArrayList([]const u8) {
    const io = config.globalIo();
    var out: std.ArrayList([]const u8) = .empty;
    const project_real = std.Io.Dir.cwd().realPathFileAlloc(io, project_dir, allocator) catch return out;
    defer allocator.free(project_real);
    var candidates: std.ArrayList([]const u8) = .empty;
    defer candidates.deinit(allocator);
    defer for (candidates.items) |c| allocator.free(c);
    for (deps) |dep| {
        if (!dep.isLocal()) continue;
        const declared = plugins.resolvePluginDir(allocator, project_dir, dep) catch continue;
        defer allocator.free(declared);
        const dir_z = std.Io.Dir.cwd().realPathFileAlloc(io, declared, allocator) catch continue;
        defer allocator.free(dir_z);
        const manifest = std.fs.path.join(allocator, &.{ dir_z, "plugin.labelle" }) catch continue;
        defer allocator.free(manifest);
        std.Io.Dir.cwd().access(io, manifest, .{}) catch continue;
        const dir = allocator.dupe(u8, dir_z) catch continue;
        candidates.append(allocator, dir) catch allocator.free(dir);
    }
    // Outermost first, so a nested provider meets the root that covers it.
    std.mem.sort([]const u8, candidates.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return x.len < y.len;
        }
    }.lessThan);
    for (candidates.items) |dir| {
        const covered = blk: {
            if (watch.publish.within(project_real, dir) and watch.tree.reaches(io, allocator, project_real, dir)) break :blk true;
            for (out.items) |kept| {
                if (watch.publish.within(kept, dir) and watch.tree.reaches(io, allocator, kept, dir)) break :blk true;
            }
            break :blk false;
        };
        if (covered) continue;
        const owned = allocator.dupe(u8, dir) catch continue;
        out.append(allocator, owned) catch allocator.free(owned);
    }
    return out;
}

/// The watcher's ignore set for a watch session: the absolute
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
/// the watch signature, so the session kept the previous build until
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
            const p = watch.watchIgnorePath(allocator, project_dir, rel) catch continue;
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
            const png = try watch.watchIgnorePath(a, "/proj", "assets/out.png");
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
    // leaving the session on a stale build.
    pub const hooks_disabled = struct {
        test "the kill switch leaves declared outputs in the watch set" {
            const a = std.testing.allocator;
            var got = collectPrebuildIgnorePaths(a, "/proj", steps, false);
            defer free(a, &got);
            try std.testing.expectEqual(@as(usize, 0), got.items.len);
        }
    };
};

test {
    _ = @import("rebuild_tests.zig");
}
