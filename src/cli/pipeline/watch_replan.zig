//! The production replan for `wasm serve --watch`
//! (`WasmRebuildCtx.replan`): `WatchReplan` and its generations. Its
//! tests live in `watch_replan_tests.zig`.
const std = @import("std");
const config = @import("../config.zig");
const lockfile = @import("../lockfile.zig");
const project_config = @import("../project_config.zig");
const provider_dispatch = @import("../provider_dispatch.zig");
const provider_github = @import("../provider_github.zig");
const provider_hooks = @import("../provider_hooks.zig");
const provider_targets = @import("../provider_targets.zig");
const WasmRebuildCtx = @import("watch.zig").WasmRebuildCtx;
const refuseLegacyWasmReplacement = @import("args_resolve.zig").refuseLegacyWasmReplacement;
const refuseKnownLegacyWasmReplacement = @import("args_resolve.zig").refuseKnownLegacyWasmReplacement;
const confirmTarget = @import("args_resolve.zig").confirmTarget;
const AssemblerInstaller = @import("install.zig").AssemblerInstaller;

/// The production replan for `wasm serve --watch` (`WasmRebuildCtx.replan`):
/// re-reads `project.labelle`, brings the package cache and `labelle.lock`
/// in line with it when it changed, rediscovers the providers with the
/// package cache `.populated` and replans the `generate` and `build` phases
/// for the target being served. Each successful replan lives on its own
/// arena; the previous generation — its arena and any pinned provider
/// sources it extracted — is released only once the new one is installed,
/// so a failed replan leaves the context pointing at intact storage.
pub const WatchReplan = struct {
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
    /// Pinned provider extractions shared across this session's
    /// generations, keyed by the verified archive hash: a replan reuses the
    /// directory an unchanged pin was unpacked into and the pre-check reads
    /// manifests from it without touching an archive (cli#429). Created on
    /// first use; `null` until then.
    extractions: ?provider_github.Extractions = null,

    /// The package-cache install seam: `run(ctx, allocator, project_dir)`.
    pub const Installer = struct {
        ctx: *const anyopaque,
        run: *const fn (*const anyopaque, std.mem.Allocator, []const u8) anyerror!void,
    };

    /// Production installer: the pipeline's `AssemblerInstaller`.
    pub fn assemblerInstaller(installer: *const AssemblerInstaller) Installer {
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
    pub fn baseline(self: *WatchReplan) void {
        self.synced = digestProject(self.backing, self.project_dir) catch null;
    }

    /// Lend the cold pipeline's pinned extractions (`startup`, which
    /// outlives this replan) to the session, so the first rebuild does not
    /// unpack an unchanged pin again. Best effort: a failure only costs
    /// that extraction.
    pub fn seed(self: *WatchReplan, startup: *const provider_github.Sources) void {
        self.extractionCache().seed(startup) catch {};
    }

    fn extractionCache(self: *WatchReplan) *provider_github.Extractions {
        if (self.extractions == null) self.extractions = .{ .a = self.backing };
        return &self.extractions.?;
    }

    /// Drop the owned extractions no installed generation reads: the
    /// current one's are kept, everything else a failed replan unpacked, or
    /// that only a released generation read, is removed.
    fn pruneExtractions(self: *WatchReplan) void {
        const cache = if (self.extractions) |*c| c else return;
        const keep: []const []const provider_github.Sources.Extracted = if (self.current) |generation| &.{generation.sources.used.items} else &.{};
        cache.retain(keep);
    }

    pub const Generation = struct {
        arena: std.heap.ArenaAllocator,
        sources: provider_github.Sources,
        /// This generation's `after run` hooks, planned against the same
        /// providers and config it installs on the site. The serve's
        /// shutdown runs these (`shutdownRunAfter`), not the startup plan:
        /// once a replan changed a provider's version the startup plan's
        /// pins no longer match the rewritten lock (`StaleProviderPin`),
        /// and added or removed after-run hooks would be ignored (Codex P2
        /// on #427).
        run_after: []const provider_hooks.Planned = &.{},

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

    pub fn run(ptr: *anyopaque, ctx: *WasmRebuildCtx) anyerror!void {
        const self: *WatchReplan = @ptrCast(@alignCast(ptr));
        const next = try Generation.create(self.backing);
        // Unchanged pins reuse the extraction an earlier generation made;
        // only a changed pin is unpacked (cli#429).
        next.sources.shared = self.extractionCache();
        errdefer self.pruneExtractions();
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
        switch (try confirmTarget(a, ctx.hooks.root, providers, ctx.hooks.target)) {
            .resolved => {},
            .refused => |kind| return switch (kind) {
                .no_provider => error.NoProviderForTarget,
                .unpinned_owner => error.UnverifiedTargetOwner,
            },
        }
        const generate_plan = try provider_hooks.plan(a, providers, .generate, ctx.hooks.target);
        const build_plan = try provider_hooks.plan(a, providers, .build, ctx.hooks.target);
        const run_plan = try provider_hooks.plan(a, providers, .run, ctx.hooks.target);
        if (refuseLegacyWasmReplacement(run_plan)) return error.LegacyWasmReplacement;
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
        next.run_after = run_plan.after;
        if (self.current) |previous| previous.destroy(self.backing);
        self.current = next;
        self.pruneExtractions();
    }

    /// The `after run` hooks the serve's shutdown runs: the current
    /// generation's — planned against the providers and config installed on
    /// the site, and pinned by the lock the replan last wrote — or `startup`
    /// when no rebuild has replanned yet. Read before `deinit`, which puts
    /// the site back on the startup storage.
    pub fn shutdownRunAfter(self: *const WatchReplan, startup: []const provider_hooks.Planned) []const provider_hooks.Planned {
        return if (self.current) |generation| generation.run_after else startup;
    }

    /// The ownership pre-check (`WasmRebuildCtx.Replan.precheck`): before
    /// the prebuild steps, re-read `project.labelle` and read the manifests
    /// the declared packages have NOW — the same metadata-only (`.unknown`)
    /// discovery the cold pipeline's pre-install verdict uses
    /// (`earlyTargetCheck`), on a scratch arena freed before returning: no
    /// install, no lock write, no plan, nothing installed on `ctx`.
    ///
    /// Known run replacements are refused before prebuild because a legacy
    /// watch session cannot switch server implementations while running.
    /// Ownership refusals are limited to what no prebuild step can mend:
    /// - an owner that is a remote package without an integrity pin
    ///   (`UnverifiedTargetOwner`) — a pin lives in `project.labelle`;
    /// - no owner at all (`NoProviderForTarget`) while the project declares
    ///   no LOCAL package and every declared remote one was read — the
    ///   project dropped the owner and nothing a prebuild writes can bring
    ///   one back.
    ///
    /// Everything else passes to the full replan after the prebuild, which
    /// stays authoritative and runs before any hook or generate: any
    /// declared local package — with no `plugin.labelle` yet, or one that
    /// does not declare the target NOW, since a prebuild step may be what
    /// (re)generates it (Codex P2 on #427, cli#429) — and a declared remote
    /// package not read yet (not in the cache: the replan's install fetches
    /// it; pinned but not extracted by any earlier generation: the replan
    /// extracts it). An error reading the project or a present manifest
    /// fails closed, as the cold pre-install check does.
    ///
    /// Metadata only: a pinned remote is read from the directory an earlier
    /// generation (or the cold pipeline) extracted from the same verified
    /// archive — no archive is read, decompressed or unpacked here
    /// (cli#429).
    pub fn precheck(ptr: *anyopaque, ctx: *WasmRebuildCtx) anyerror!void {
        const self: *WatchReplan = @ptrCast(@alignCast(ptr));
        var scratch = std.heap.ArenaAllocator.init(self.backing);
        defer scratch.deinit();
        const a = scratch.allocator();
        var cfg = try config.readProjectConfig(a, self.project_dir);
        cfg.platform = ctx.hooks.cfg.platform;
        cfg.backend = ctx.hooks.cfg.backend;
        // Lookup only: a pinned remote is read from the extraction an
        // earlier generation (or the cold pipeline) verified and unpacked,
        // never from its archive — a pin with none yet is unread, and the
        // replan decides (cli#429).
        var sources: provider_github.Sources = .{ .a = a, .shared = self.extractionCache(), .extract = false };
        defer sources.deinit();
        const view = try provider_dispatch.discoverAll(a, ctx.hooks.root, cfg, &sources, .unknown);
        if (try refuseKnownLegacyWasmReplacement(a, view.providers, ctx.hooks.target)) return error.LegacyWasmReplacement;
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

    /// Release the current generation. Once a replan succeeded, `site`'s
    /// `providers` and `cfg` point into that generation, so they are put back
    /// on the caller's stable (startup) storage first: nothing on the site
    /// may dangle, whatever runs after this (Codex P2 on #420).
    pub fn deinit(self: *WatchReplan, site: *provider_hooks.Site, stable_providers: []const provider_dispatch.Provider, stable_cfg: project_config.ProjectConfig) void {
        if (self.current) |generation| {
            site.providers = stable_providers;
            site.cfg = stable_cfg;
            generation.destroy(self.backing);
        }
        self.current = null;
        if (self.extractions) |*cache| cache.deinit();
        self.extractions = null;
    }
};
