//! `labelle run --watch` (RFC cli#466 §3.4, §4): a long-lived run
//! replacement serves the last successfully built output while core
//! watches the project, rebuilds and publishes.
//!
//! Core's part is generic: file watching, rebuild orchestration with the
//! full hook phases, publication of the last successful output
//! (`watch.Publisher`) and the generation notification. Serving and
//! reloading belong to the provider. The session:
//!
//! 1. refuses, before any build, a target without a run replacement that
//!    declares `.watch = true` and speaks wire `1.3.0`+ (`refusal`);
//! 2. after the cold build (its `after build` hooks included) publishes
//!    generation 0, then starts the replacement with `run.watch` naming
//!    the generation file and the published output directory;
//! 3. runs every rebuild on a watcher thread, on its OWN copy of the hook
//!    site, as a transaction (`RebuildCtx`): a rebuild publishes only once
//!    it fully succeeded, and one whose replan changes what the running
//!    replacement depends on (`SessionKey`) ends with a restart diagnostic;
//! 4. when the replacement exits, stops the watcher, cancels and reaps any
//!    in-flight rebuild child, joins the thread, and only then finishes the
//!    run: `after run` (the COMMITTED generation's hooks) only on a clean
//!    status-0 exit, cleanup always.
//!
//! Every child of the session — the replacement, the rebuilds' tools and
//! compilers, the `after run` hooks — runs supervised (`supervise.zig`),
//! and Ctrl+C / SIGTERM is forwarded to it (`watch/cancel.zig`), so no
//! child outlives the command.
const std = @import("std");
const config = @import("../config.zig");
const prebuild = @import("../prebuild.zig");
const supervise = @import("../supervise.zig");
const watch = @import("../watch.zig");
const provider_contract = @import("../provider_contract.zig");
const provider_manifest = @import("../provider_manifest.zig");
const provider_hooks = @import("../provider_hooks.zig");
const RebuildCtx = @import("rebuild.zig").RebuildCtx;
const Replanner = @import("rebuild_replan.zig").Replanner;
const SessionKey = @import("session_key.zig").SessionKey;
const AssemblerInstaller = @import("install.zig").AssemblerInstaller;
const Context = @import("context.zig").Context;

/// Why `labelle run --watch` cannot watch a target.
pub const Refusal = enum {
    no_replacement,
    no_capability,
    old_wire,

    pub fn detail(self: Refusal) []const u8 {
        return switch (self) {
            .no_replacement => "no watch-capable run replacement",
            .no_capability => "the run replacement does not declare .watch",
            .old_wire => "the run replacement's provider contract predates run.watch",
        };
    }
};

/// The pure verdict: `null` when `plan`'s replacement can run a watch
/// session.
pub fn verdict(plan: provider_hooks.Plan) ?Refusal {
    const replacement = plan.replace orelse return .no_replacement;
    if (!replacement.hook.watch) return .no_capability;
    const range = replacement.provider.meta.command_contract orelse return .old_wire;
    const wire = provider_manifest.negotiate(range) catch return .old_wire;
    if (!provider_contract.carriesWatchContext(wire)) return .old_wire;
    return null;
}

/// `verdict`, printing the refusal's diagnostic: it names the package and
/// what is missing.
pub fn refusal(target: []const u8, plan: provider_hooks.Plan) ?Refusal {
    const why = verdict(plan) orelse return null;
    switch (why) {
        .no_replacement => std.debug.print(
            "labelle: run --watch: target '{s}' has no run replacement to watch through\n" ++
                "  watch mode needs a provider whose `replace run` hook declares `.watch = true`; core targets are not watched\n",
            .{target},
        ),
        .no_capability => std.debug.print(
            "labelle: run --watch: package '{s}' does not declare `.watch = true` on its run replacement '{s}' for target '{s}'\n",
            .{ plan.replace.?.provider.meta.name, plan.replace.?.qualified, target },
        ),
        .old_wire => {
            const provider = plan.replace.?.provider.meta;
            const wire = if (provider.command_contract) |range| provider_manifest.negotiate(range) catch "none" else "none";
            std.debug.print(
                "labelle: run --watch: package '{s}' speaks provider contract {s}; its run replacement '{s}' needs >= {s} to receive run.watch\n",
                .{ provider.name, wire, plan.replace.?.qualified, provider_contract.watch_context_since },
            );
        },
    }
    return why;
}

test "run --watch: only a replacement with .watch on wire 1.3.0+ can be watched" {
    var provider: @import("../provider_dispatch.zig").Provider = .{
        .dep = .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
        .dir = "/pkg",
        .meta = .{ .name = "pkg", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0" },
        .verified = true,
    };
    const hook: provider_manifest.Hook = .{ .id = "serve", .step = .run, .target = "probe-target", .when = .replace, .build_step = "tool", .executable = "bin/tool", .watch = true };
    // No replacement (a core target, or a provider without one).
    try std.testing.expectEqual(Refusal.no_replacement, verdict(.{}).?);
    // The capability is explicit: the wire alone is not enough.
    var plain = hook;
    plain.watch = false;
    try std.testing.expectEqual(Refusal.no_capability, verdict(.{ .replace = .{ .provider = &provider, .hook = plain, .qualified = "pkg/serve" } }).?);
    const planned: provider_hooks.Plan = .{ .replace = .{ .provider = &provider, .hook = hook, .qualified = "pkg/serve" } };
    try std.testing.expect(verdict(planned) == null);
    // A provider capped below 1.3.0 cannot receive run.watch.
    provider.meta.command_contract = ">=1.0.0 <1.3.0";
    try std.testing.expectEqual(Refusal.old_wire, verdict(planned).?);
    provider.meta.command_contract = ">=1.3.0 <1.4.0";
    try std.testing.expect(verdict(planned) == null);
}

/// How long a cancelled rebuild child gets to stop before it is killed.
const cancel_grace_ms = 5_000;

/// The session. `replacement` is the plan's (already refused otherwise);
/// the `before run` hooks have run.
pub fn run(
    cx: *const Context,
    replacement: provider_hooks.Planned,
    run_out: []const u8,
    generate_out: []const u8,
    build_out: []const u8,
    zig_args: []const []const u8,
    zig_env: ?*const std.process.Environ.Map,
) !u8 {
    const allocator = cx.allocator;
    const io = config.globalIo();
    const site = cx.hook_site;

    // Publication: the staged build output is the target's `zig-out`
    // (the `build` step's output directory); sessions live beside the
    // generated targets, under a dot directory no watch walk enters.
    const source = try std.fs.path.join(cx.hook_arena, &.{ site.target_dir, "zig-out" });
    const root = try std.fs.path.join(cx.hook_arena, &.{ site.root, ".labelle", ".watch", cx.target_name });
    var publisher = watch.Publisher.init(allocator, root, source) catch |err| {
        std.debug.print("labelle: run --watch: could not prepare '{s}' ({s})\n", .{ root, @errorName(err) });
        return 1;
    };
    defer publisher.deinit(true);
    publisher.publish(null) catch |err| {
        std.debug.print("labelle: run --watch: could not publish the initial build ({s})\n", .{@errorName(err)});
        return 1;
    };

    const key = (try SessionKey.of(
        cx.hook_arena,
        site.root,
        site.cfg,
        cx.hook_plans.run,
        cx.backend_name,
        cx.target.name,
        cx.parsed_args.platform_override == null,
        site.optimize,
    )) orelse unreachable; // `refusal` ran before the build

    // Every child from here on is supervised; Ctrl+C / SIGTERM reaches it.
    watch.installCancelHandler();
    var session_group: supervise.Group = .{};
    session_group.attach();
    defer session_group.detach();
    var rebuild_group: supervise.Group = .{};
    rebuild_group.attach();
    defer rebuild_group.detach();

    // The rebuilds' own site: a copy, so the replacement keeps the session
    // configuration it started with (§3.4) and no field the main thread
    // reads is written by the watcher thread.
    var rebuild_site = site.*;
    rebuild_site.reporter = null;
    // The pipeline's hook arena is not thread-safe: the watcher thread's
    // long-lived allocations (a host compiler resolved by its first hook)
    // go to an arena of its own, released after the shutdown hooks ran.
    var rebuild_arena = std.heap.ArenaAllocator.init(allocator);
    defer rebuild_arena.deinit();
    rebuild_site.a = rebuild_arena.allocator();
    // Its environment is a deep copy: a rebuild frees the environment it
    // replaces, and the startup one stays the session's (the replacement
    // may still be starting with it) until the watcher is joined.
    rebuild_site.env = try site.env.clone(allocator);
    var rebuild_env_owned = true;
    defer if (rebuild_env_owned) rebuild_site.env.deinit();
    const installer = AssemblerInstaller{ .bin = cx.asm_bin };
    var replanner = Replanner{
        .backing = allocator,
        .project_dir = cx.project_dir,
        .installer = Replanner.assemblerInstaller(&installer),
        .session = &key,
        .describer = .init(cx.asm_bin, cx.project_dir),
    };
    replanner.baseline();
    replanner.seed(cx.provider_sources);
    var ctx = RebuildCtx{
        .allocator = allocator,
        .asm_bin = cx.asm_bin,
        .project_dir = cx.project_dir,
        .platform_tag = cx.target.name,
        .output_dir = cx.output_dir,
        .target_dir = cx.target_dir,
        .zig_args = zig_args,
        .zig_env = zig_env,
        .optimize_flag = cx.parsed_args.optimize_override,
        .prebuild_steps = cx.parsed.prebuild,
        .prebuild_opts = .{
            .route_stdout_to_stderr = cx.parsed_args.progress_mode == .json,
            .fatal_on_step_failure = false,
        },
        .hooks = &rebuild_site,
        .generate_plan = cx.hook_plans.generate,
        .build_plan = cx.hook_plans.build,
        .generate_out = generate_out,
        .build_out = build_out,
        .replan = replanner.seam(),
        .publish = .{ .ctx = &publisher, .run = publishNext },
        .group = &rebuild_group,
        .hooks_enabled = !prebuild.skipRequested(allocator),
        // The startup environment the replacement is launched with; the
        // main thread does not touch it until the watcher is joined.
        .launch_env = &site.env,
        // The cold pipeline's generation pre-passes, failing the rebuild
        // (not the session) on a misconfiguration.
        .prepass = .{ .legacy_target = cx.target.legacy != null, .bake = cx.parsed_args.bake, .fatal = false },
    };
    ctx.initIgnore();
    defer ctx.deinit();

    var state: watch.WatchState = .{};
    const watcher = std.Thread.spawn(.{}, watch.watchLoop, .{ io, watch.WatchConfig{
        .watch_dir = cx.project_dir,
        .rebuild_fn = RebuildCtx.rebuild,
        .rebuild_ctx = &ctx,
        .ignore = &ctx.ignore,
        .baseline = cx.watch_baseline,
    }, &state }) catch |err| {
        std.debug.print("labelle: run --watch: could not start the file watcher ({s})\n", .{@errorName(err)});
        replanner.deinit(site, cx.providers, cx.parsed);
        return 1;
    };
    std.debug.print("labelle: watching {s} (published generation 0 at {s})\n", .{ cx.project_dir, publisher.output_dir });

    // The replacement, on the session's own site copy carrying `run.watch`.
    var session_site = site.*;
    var options = site.run_options orelse provider_contract.RunContext{ .env = &.{}, .args = &.{}, .timeout_ms = null };
    options.watch = .{ .generation_file = publisher.generation_file, .output_dir = publisher.output_dir };
    session_site.run_options = options;
    supervise.current = &session_group;
    defer supervise.current = null;
    const replaced = provider_hooks.runReplacement(&session_site, replacement, run_out);
    // A stop latched for the replacement ends with it: the `after run`
    // hooks of a clean exit are not signalled on spawn.
    session_group.clearPending();

    // The replacement ended (or never started): stop watching, cancel and
    // reap the in-flight rebuild, join — before anything else runs.
    state.stop.store(true, .release);
    rebuild_group.cancelAndReap(io, cancel_grace_ms);
    watcher.join();
    // The committed rebuild state becomes the command's: the `after run`
    // hooks resolve settings and pins through it, with its environment.
    site.providers = rebuild_site.providers;
    site.cfg = rebuild_site.cfg;
    site.optimize = rebuild_site.optimize;
    site.env.deinit();
    site.env = rebuild_site.env;
    rebuild_env_owned = false;
    if (site.host == null) site.host = session_site.host orelse rebuild_site.host;
    defer replanner.deinit(site, cx.providers, cx.parsed);

    const outcome = replaced catch |err| return err;
    const after = replanner.shutdownRunAfter(cx.hook_plans.run.after);
    if (outcome == .exited_error) {
        const code = outcome.exited_error;
        if (after.len != 0) std.debug.print("labelle: after-run hooks skipped: the run replacement exited with status {d}\n", .{code});
        // A non-zero or signal exit is the run's terminal outcome: the
        // status file leaves the live `run` phase (`failed`, the code the
        // CLI exits with), whatever path ended the replacement.
        if (site.reporter) |r| r.failIfActive(code, "the run replacement exited with an error");
        return code;
    }
    // A reported `timeout` (`run.outcome_file`, wire 1.5.0+) skips them too.
    return provider_hooks.finishRun(site, after, run_out, outcome);
}

fn publishNext(ptr: *anyopaque, gate: watch.PublishGate) anyerror!void {
    const publisher: *watch.Publisher = @ptrCast(@alignCast(ptr));
    try publisher.publish(gate);
    std.debug.print("labelle: published generation {d}\n", .{publisher.generation.?});
}
