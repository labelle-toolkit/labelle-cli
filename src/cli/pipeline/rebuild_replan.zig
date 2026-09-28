//! The production replan of a watched rebuild (`RebuildCtx.replan`):
//! `Replanner` and its generations. Its tests live in
//! `rebuild_replan_tests.zig`.
const std = @import("std");
const config = @import("../config.zig");
const lockfile = @import("../lockfile.zig");
const project_config = @import("../project_config.zig");
const provider_dispatch = @import("../provider_dispatch.zig");
const provider_github = @import("../provider_github.zig");
const provider_hooks = @import("../provider_hooks.zig");
const provider_targets = @import("../provider_targets.zig");
const RebuildCtx = @import("rebuild.zig").RebuildCtx;
const SessionKey = @import("session_key.zig").SessionKey;
const confirmTarget = @import("args_resolve.zig").confirmTarget;
const AssemblerInstaller = @import("install.zig").AssemblerInstaller;
const provider_contract = @import("../provider_contract.zig");
const optimize_mod = @import("optimize.zig");

/// The production replan (`RebuildCtx.replan`): re-reads `project.labelle`,
/// brings the package cache and `labelle.lock` in line with it when it
/// changed, rediscovers the providers with the package cache `.populated`
/// and replans the `generate` and `build` phases for the target being
/// built.
///
/// Transactional (cli#469): each rebuild stages a new generation — its own
/// arena, providers, config, plans and `after run` hooks — and installs it
/// on the rebuild context. The committed generation stays alive until the
/// rebuild ends: `commit` releases it once the whole rebuild succeeded,
/// `rollback` releases the staged one instead and restores the lock and
/// the synced digest, so a rebuild that fails anywhere leaves the session
/// exactly as it was.
pub const Replanner = struct {
    backing: std.mem.Allocator,
    project_dir: []const u8,
    /// The committed generation: storage of the plans the session runs.
    /// `null` until the first committed replan: the startup plans live on
    /// the pipeline's hook arena, which outlives the session.
    current: ?*Generation = null,
    /// The generation this rebuild is building on; installed on the context
    /// once `run` succeeds (`installed`), committed or rolled back when the
    /// rebuild ends.
    staged: ?*Generation = null,
    installed: bool = false,
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
    /// What `rollback` puts back: the digest before this rebuild, and the
    /// lock's bytes before this rebuild rewrote it (`lock_written`; `null`
    /// bytes: there was no lock).
    synced_before: ?[32]u8 = null,
    lock_written: bool = false,
    lock_before: ?[]u8 = null,
    /// Pinned provider extractions shared across this session's
    /// generations, keyed by the verified archive hash (cli#429).
    extractions: ?provider_github.Extractions = null,
    /// A session mode that cannot switch the replacement serving it while
    /// running (the legacy serve command): refuses a `run` replacement in
    /// the replanned project. Supplied by that command.
    forbid_run_replacement: ?Forbid = null,
    /// `labelle run --watch`: what the running replacement depends on. A
    /// replan that changes any of it fails with `error.SessionChanged`
    /// after printing the restart diagnostic (`session_key.zig`).
    session: ?*const SessionKey = null,

    /// The package-cache install seam: `run(ctx, allocator, project_dir)`.
    pub const Installer = struct {
        ctx: *const anyopaque,
        run: *const fn (*const anyopaque, std.mem.Allocator, []const u8) anyerror!void,
    };

    /// The refusal of a run replacement: `plan` for a planned one, `known`
    /// for one a metadata-only read already shows. Each prints its own
    /// diagnostic and returns true to refuse.
    pub const Forbid = struct {
        plan: *const fn (provider_hooks.Plan) bool,
        known: *const fn (std.mem.Allocator, []const provider_dispatch.Provider, []const u8) anyerror!bool,
    };

    /// Production installer: the pipeline's `AssemblerInstaller`, whose
    /// failure fails the rebuild instead of ending the session.
    pub fn assemblerInstaller(installer: *const AssemblerInstaller) Installer {
        return .{ .ctx = installer, .run = struct {
            fn run(ctx: *const anyopaque, a: std.mem.Allocator, project_dir: []const u8) anyerror!void {
                const self: *const AssemblerInstaller = @ptrCast(@alignCast(ctx));
                var fallible = self.*;
                fallible.bin.fatal_on_failure = false;
                return fallible.install(a, project_dir);
            }
        }.run };
    }

    /// The `RebuildCtx.Replan` seam over this replanner.
    pub fn seam(self: *Replanner) RebuildCtx.Replan {
        return .{ .ctx = self, .precheck = precheck, .run = run, .commit = commit, .rollback = rollback };
    }

    fn digestBytes(bytes: []const u8) [32]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        return digest;
    }

    fn digestProject(a: std.mem.Allocator, project_dir: []const u8) ![32]u8 {
        const path = try std.fs.path.join(a, &.{ project_dir, "project.labelle" });
        defer a.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, a, .limited(16 * 1024 * 1024));
        defer a.free(bytes);
        return digestBytes(bytes);
    }

    /// Record the project the cold pipeline just installed and locked, so
    /// the first replan does not repeat that work for unchanged bytes.
    pub fn baseline(self: *Replanner) void {
        self.synced = digestProject(self.backing, self.project_dir) catch null;
    }

    /// Lend the cold pipeline's pinned extractions (`startup`, which
    /// outlives this replan) to the session, so the first rebuild does not
    /// unpack an unchanged pin again. Best effort.
    pub fn seed(self: *Replanner, startup: *const provider_github.Sources) void {
        self.extractionCache().seed(startup) catch {};
    }

    fn extractionCache(self: *Replanner) *provider_github.Extractions {
        if (self.extractions == null) self.extractions = .{ .a = self.backing };
        return &self.extractions.?;
    }

    /// Drop the owned extractions no live generation reads.
    fn pruneExtractions(self: *Replanner) void {
        const cache = if (self.extractions) |*c| c else return;
        var keep: [2][]const provider_github.Sources.Extracted = undefined;
        var n: usize = 0;
        if (self.current) |g| {
            keep[n] = g.sources.used.items;
            n += 1;
        }
        if (self.staged) |g| {
            keep[n] = g.sources.used.items;
            n += 1;
        }
        cache.retain(keep[0..n]);
    }

    pub const Generation = struct {
        arena: std.heap.ArenaAllocator,
        sources: provider_github.Sources,
        /// This generation's `after run` hooks, planned against the same
        /// providers and config it installs. The session's shutdown runs
        /// the COMMITTED generation's (`shutdownRunAfter`), not the startup
        /// plan (Codex P2 on #427), and never a rolled-back one (cli#469).
        run_after: []const provider_hooks.Planned = &.{},
        /// The project read for this generation (by the pre-check), with
        /// its digest; `null` until read.
        cfg: ?project_config.ProjectConfig = null,
        digest: [32]u8 = undefined,

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

        /// Read `project.labelle` onto this generation's arena.
        fn read(self: *Generation, project_dir: []const u8) !project_config.ProjectConfig {
            if (self.cfg) |cfg| return cfg;
            const a = self.arena.allocator();
            self.digest = try digestProject(a, project_dir);
            self.cfg = try config.readProjectConfig(a, project_dir);
            return self.cfg.?;
        }
    };

    /// A generation for this rebuild: the staged one when the pre-check
    /// created it, else a fresh one. A generation `run` installed but
    /// nobody committed (a caller driving `run` directly) is committed
    /// first.
    fn stage(self: *Replanner) !*Generation {
        if (self.installed) commit(self);
        if (self.staged) |g| return g;
        const g = try Generation.create(self.backing);
        g.sources.shared = self.extractionCache();
        self.staged = g;
        return g;
    }

    fn dropStaged(self: *Replanner) void {
        if (self.staged) |g| g.destroy(self.backing);
        self.staged = null;
        self.installed = false;
    }

    /// End the transaction successfully: the staged generation becomes the
    /// committed one and the previous committed one is released.
    pub fn commit(ptr: *anyopaque) void {
        const self: *Replanner = @ptrCast(@alignCast(ptr));
        if (self.installed) {
            if (self.current) |previous| previous.destroy(self.backing);
            self.current = self.staged;
            self.staged = null;
            self.installed = false;
        } else self.dropStaged();
        self.forgetLock();
        self.pruneExtractions();
    }

    /// End the transaction on a failure: the staged generation is released,
    /// the lock and the synced digest go back to what they were.
    pub fn rollback(ptr: *anyopaque) void {
        const self: *Replanner = @ptrCast(@alignCast(ptr));
        const was_installed = self.installed;
        self.dropStaged();
        if (was_installed) self.synced = self.synced_before;
        if (self.lock_written) self.restoreLock();
        self.forgetLock();
        self.pruneExtractions();
    }

    fn lockPath(self: *const Replanner, a: std.mem.Allocator) ![]const u8 {
        return std.fs.path.join(a, &.{ self.project_dir, "labelle.lock" });
    }

    fn backupLock(self: *Replanner) !void {
        const path = try self.lockPath(self.backing);
        defer self.backing.free(path);
        self.lock_before = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, self.backing, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        self.lock_written = true;
    }

    fn restoreLock(self: *Replanner) void {
        const io = config.globalIo();
        const path = self.lockPath(self.backing) catch return;
        defer self.backing.free(path);
        if (self.lock_before) |bytes| {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes }) catch |err| {
                std.debug.print("labelle: could not restore labelle.lock after a failed rebuild ({s})\n", .{@errorName(err)});
            };
        } else std.Io.Dir.cwd().deleteFile(io, path) catch {};
    }

    fn forgetLock(self: *Replanner) void {
        if (self.lock_before) |bytes| self.backing.free(bytes);
        self.lock_before = null;
        self.lock_written = false;
    }

    pub fn run(ptr: *anyopaque, ctx: *RebuildCtx) anyerror!void {
        const self: *Replanner = @ptrCast(@alignCast(ptr));
        const next = try self.stage();
        errdefer if (!self.installed) {
            self.dropStaged();
            self.pruneExtractions();
        };
        const a = next.arena.allocator();
        var cfg = try next.read(self.project_dir);
        const digest = next.digest;
        const file_backend = @tagName(cfg.backend);
        // The target's platform and backend are the pipeline's resolved
        // ones (a command may override what the file declares); a session
        // compares the file's own values against its key.
        cfg.platform = ctx.hooks.cfg.platform;
        cfg.backend = ctx.hooks.cfg.backend;
        // An edited `project.labelle` may declare a package the startup
        // install never fetched and the startup lock never pinned: install
        // first, as the cold pipeline does ahead of discovery (Codex P2 on
        // #420).
        const changed = if (self.synced) |synced| !std.mem.eql(u8, &synced, &digest) else true;
        if (changed) if (self.installer) |installer| try installer.run(installer.ctx, a, self.project_dir);
        const providers: []const provider_dispatch.Provider = if (cfg.plugins.len == 0)
            &.{}
        else
            try provider_dispatch.discover(a, ctx.hooks.root, cfg, &next.sources, .populated);
        // The target must still have a pinned owner among the NEW
        // providers (Codex P1 on #421).
        switch (try confirmTarget(a, ctx.hooks.root, providers, ctx.hooks.target)) {
            .resolved => {},
            .refused => |kind| return switch (kind) {
                .no_provider => error.NoProviderForTarget,
                .unpinned_owner => error.UnverifiedTargetOwner,
            },
        }
        // The effective optimize mode, recomputed against the NEW providers.
        const optimize = optimize_mod.effective(ctx.optimize_flag, optimize_mod.ownerDefault(providers, ctx.hooks.target), ctx.fallback_optimize);
        const wire_optimize = std.meta.stringToEnum(provider_contract.Optimize, optimize.mode orelse "Debug") orelse return error.InvalidOptimizeMode;
        const zig_args = try withOptimize(a, ctx.zig_args, optimize.mode);
        const generate_plan = try provider_hooks.plan(a, providers, .generate, ctx.hooks.target);
        const build_plan = try provider_hooks.plan(a, providers, .build, ctx.hooks.target);
        const run_plan = try provider_hooks.plan(a, providers, .run, ctx.hooks.target);
        if (self.forbid_run_replacement) |forbid| if (forbid.plan(run_plan)) return error.RunReplacementForbidden;
        if (self.session) |key| {
            const replanned = try SessionKey.of(a, ctx.hooks.root, cfg, run_plan, file_backend, ctx.hooks.target, key.target_follows_file, wire_optimize);
            if (key.changed(replanned)) |what| return SessionKey.report(what);
        }
        // The lock follows the re-read project once the target is confirmed
        // and the plans are good — the cold pipeline's order — and before
        // any hook runs. Its previous bytes are kept for a rollback.
        self.synced_before = self.synced;
        if (changed) {
            try self.backupLock();
            try self.write_lock(a, self.project_dir, cfg);
        }
        self.synced = digest;
        // Install on the rebuild context; the rebuild restores the previous
        // values and `rollback` releases this generation if it then fails.
        ctx.hooks.providers = providers;
        ctx.hooks.cfg = cfg;
        ctx.prebuild_steps = cfg.prebuild;
        ctx.generate_plan = generate_plan;
        ctx.build_plan = build_plan;
        if (ctx.hooks.optimize != wire_optimize)
            std.debug.print("labelle: rebuild optimize mode is now {s} (was {s})\n", .{ @tagName(wire_optimize), @tagName(ctx.hooks.optimize) });
        ctx.hooks.optimize = wire_optimize;
        ctx.zig_args = zig_args;
        next.run_after = run_plan.after;
        self.installed = true;
        self.pruneExtractions();
    }

    /// `args` (a `zig build` argv) with its `-Doptimize=` flag replaced by
    /// `mode`'s, or dropped when there is none. Allocated with `a`.
    pub fn withOptimize(a: std.mem.Allocator, args: []const []const u8, mode: ?[]const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (args) |arg| {
            if (!std.mem.startsWith(u8, arg, "-Doptimize=")) try out.append(a, arg);
        }
        if (mode) |m| try out.append(a, try std.fmt.allocPrint(a, "-Doptimize={s}", .{m}));
        return out.items;
    }

    /// The `after run` hooks the session's shutdown runs: the COMMITTED
    /// generation's — planned against the providers and config committed
    /// with it, and pinned by the lock it wrote — or `startup` when no
    /// rebuild has committed yet. Read before `deinit`.
    pub fn shutdownRunAfter(self: *const Replanner, startup: []const provider_hooks.Planned) []const provider_hooks.Planned {
        return if (self.current) |generation| generation.run_after else startup;
    }

    /// The config replan and the ownership pre-check
    /// (`RebuildCtx.Replan.precheck`), before the prebuild steps:
    ///
    /// - re-read `project.labelle` for this rebuild (onto the staged
    ///   generation, which `run` reuses) and stage the `.prebuild` steps it
    ///   declares on the context, so an edited or added step runs in THIS
    ///   rebuild and a removed one does not (cli#463);
    /// - in a watch session, refuse a backend or target change before any
    ///   step runs (`SessionKey.configChanged`);
    /// - read the manifests the declared packages have NOW, metadata-only
    ///   (`.unknown`) on a scratch arena — no install, no lock write, no
    ///   plan — and refuse a known run replacement where the session
    ///   forbids one, or a target whose owner is clearly gone.
    ///
    /// Ownership refusals are limited to what no prebuild step can mend:
    /// an owner that is a remote package without an integrity pin
    /// (`UnverifiedTargetOwner`), or no owner at all while the project
    /// declares no LOCAL package and every declared remote one was read
    /// (`NoProviderForTarget`). Everything else passes to `run`, which stays
    /// authoritative (Codex P2 on #427, cli#429).
    pub fn precheck(ptr: *anyopaque, ctx: *RebuildCtx) anyerror!void {
        const self: *Replanner = @ptrCast(@alignCast(ptr));
        // A generation a previous pre-check read but no rebuild used is
        // stale: read afresh.
        if (!self.installed) self.dropStaged();
        const next = try self.stage();
        var cfg = next.read(self.project_dir) catch |err| {
            self.dropStaged();
            return err;
        };
        if (self.session) |key| if (key.configChanged(cfg)) |what| return SessionKey.report(what);
        ctx.prebuild_steps = cfg.prebuild;

        var scratch = std.heap.ArenaAllocator.init(self.backing);
        defer scratch.deinit();
        const a = scratch.allocator();
        cfg.platform = ctx.hooks.cfg.platform;
        cfg.backend = ctx.hooks.cfg.backend;
        // Lookup only: a pinned remote is read from the extraction an
        // earlier generation (or the cold pipeline) verified and unpacked,
        // never from its archive (cli#429).
        var sources: provider_github.Sources = .{ .a = a, .shared = self.extractionCache(), .extract = false };
        defer sources.deinit();
        const view = try provider_dispatch.discoverAll(a, ctx.hooks.root, cfg, &sources, .unknown);
        if (self.forbid_run_replacement) |forbid| if (try forbid.known(a, view.providers, ctx.hooks.target)) return error.RunReplacementForbidden;
        if (view.unresolved.len != 0) return;
        if (provider_targets.resolve(view.providers, ctx.hooks.target)) |_| {
            return;
        } else |err| switch (err) {
            error.NoProviderForTarget => if (declaresLocalPackage(cfg)) return,
            error.UnverifiedTargetOwner => {},
            else => return err,
        }
        // Refused: `confirmTarget` prints the cold pipeline's diagnostic.
        return switch (try confirmTarget(a, ctx.hooks.root, view.providers, ctx.hooks.target)) {
            .resolved => {},
            .refused => |kind| switch (kind) {
                .no_provider => error.NoProviderForTarget,
                .unpinned_owner => error.UnverifiedTargetOwner,
            },
        };
    }

    /// True when the project declares any local package: its manifest may
    /// be (re)generated by a prebuild step, so no ownership verdict drawn
    /// from what it declares NOW is final.
    fn declaresLocalPackage(cfg: project_config.ProjectConfig) bool {
        for (cfg.plugins) |dep| if (dep.isLocal()) return true;
        return false;
    }

    /// Release every generation. Once a replan was committed, `site`'s
    /// `providers` and `cfg` point into it, so they are put back on the
    /// caller's stable (startup) storage first: nothing on the site may
    /// dangle, whatever runs after this (Codex P2 on #420).
    pub fn deinit(self: *Replanner, site: *provider_hooks.Site, stable_providers: []const provider_dispatch.Provider, stable_cfg: project_config.ProjectConfig) void {
        if (self.current != null or self.installed) {
            site.providers = stable_providers;
            site.cfg = stable_cfg;
        }
        self.dropStaged();
        if (self.current) |generation| generation.destroy(self.backing);
        self.current = null;
        self.forgetLock();
        if (self.extractions) |*cache| cache.deinit();
        self.extractions = null;
    }
};
