//! Lifecycle hook planning and execution (provider contract v1 §6).
//!
//! A hook is `<package>/<id>` attached to one `(step, target)` in one phase:
//! `before` hooks, then the core operation or its unique `replace`, then
//! `after` hooks. Within a phase the order comes from explicit `after_hooks`
//! edges; independent hooks run in qualified-ID order, so the plan is the
//! same whatever order the manifests were read in. Provider dependency
//! edges (contract §6) wait for a manifest dependency field; there is none
//! yet, so `after_hooks` are the only edges today.
//!
//! Nothing here knows a platform, store or package name: the CLI is agnostic
//! (`docs/rfc-package-commands.md`).
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("provider_contract.zig");
const manifest = @import("provider_manifest.zig");
const dispatch = @import("provider_dispatch.zig");
const project = @import("project_config.zig");
const progress = @import("progress.zig");

pub const Planned = struct { provider: *const dispatch.Provider, hook: manifest.Hook, qualified: []const u8 };

pub const Plan = struct {
    before: []const Planned = &.{},
    replace: ?Planned = null,
    after: []const Planned = &.{},

    pub fn isEmpty(self: Plan) bool {
        return self.before.len == 0 and self.replace == null and self.after.len == 0;
    }
};

fn phaseRank(phase: contract.Phase) u8 {
    return switch (phase) {
        .before => 0,
        .replace => 1,
        .after => 2,
    };
}

fn sameSlot(x: manifest.Hook, y: manifest.Hook) bool {
    return x.step == y.step and std.mem.eql(u8, x.target, y.target);
}

/// Every hook of every provider with its stable identity. Order follows the
/// input; the planner never relies on it.
fn collect(a: std.mem.Allocator, providers: []const dispatch.Provider) ![]Planned {
    var list: std.ArrayList(Planned) = .empty;
    for (providers) |*provider| {
        for (provider.meta.hooks) |hook| {
            try list.append(a, .{
                .provider = provider,
                .hook = hook,
                .qualified = try manifest.qualifiedId(a, provider.meta.name, hook.id),
            });
        }
    }
    return list.items;
}

fn find(entries: []const Planned, qualified: []const u8) ?Planned {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.qualified, qualified)) return entry;
    }
    return null;
}

/// The `<package>` half of a qualified `<package>/<id>` reference.
fn packageOf(qualified: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, qualified, '/') orelse return qualified;
    return qualified[0..slash];
}

/// Cross-provider rules of contract §6, checked once at discovery so that
/// `labelle help` and `providers resolve --accept` fail on a broken graph
/// too. Prints one diagnostic line per failure, then returns the error.
///
/// `unresolved` names packages the project declares that discovery could
/// not read this time — a remote package absent from every cache while the
/// cache state is `unknown` (metadata-only `help` and command dispatch run
/// before any installer). A reference into one of them is *unresolved*, not
/// missing: nothing can be said about it until the package is present, and
/// failing would hide every provider's commands from `help` and refuse
/// dispatch for a graph that is valid once the cache is warm (Codex P2 on
/// #420). A reference into a package that IS present, or into one the
/// project never declared, is still a genuine `MissingHookReference`.
pub fn validateAll(a: std.mem.Allocator, providers: []const dispatch.Provider, unresolved: []const []const u8) !void {
    const entries = try collect(a, providers);
    for (entries, 0..) |entry, i| {
        if (entry.hook.when != .replace) continue;
        for (entries[0..i]) |previous| {
            if (previous.hook.when == .replace and sameSlot(previous.hook, entry.hook)) {
                std.debug.print("labelle: hooks: two packages replace '{s}' for target '{s}': '{s}' and '{s}'\n", .{
                    @tagName(entry.hook.step), entry.hook.target, previous.qualified, entry.qualified,
                });
                return error.DuplicateReplaceHook;
            }
        }
    }
    for (entries) |entry| {
        for (entry.hook.after_hooks) |ref| {
            const referenced = find(entries, ref) orelse {
                var deferred = false;
                for (unresolved) |package| {
                    if (std.mem.eql(u8, package, packageOf(ref))) deferred = true;
                }
                if (deferred) continue; // Checked once the package can be read.
                std.debug.print("labelle: hooks: '{s}' references unknown hook '{s}'\n", .{ entry.qualified, ref });
                return error.MissingHookReference;
            };
            if (!sameSlot(referenced.hook, entry.hook)) {
                std.debug.print("labelle: hooks: '{s}' references '{s}' which attaches to '{s}' for target '{s}'\n", .{
                    entry.qualified, ref, @tagName(referenced.hook.step), referenced.hook.target,
                });
                return error.HookReferenceMismatch;
            }
            if (phaseRank(referenced.hook.when) > phaseRank(entry.hook.when)) {
                std.debug.print("labelle: hooks: '{s}' references '{s}' which runs in a later phase\n", .{ entry.qualified, ref });
                return error.HookPhaseOrder;
            }
        }
    }
    // Same-phase cycles: order every DISTINCT `(step, target, phase)` group
    // once, the way `plan` will. Ordering the group of every entry ran the
    // quadratic sort N times for N hooks in one phase — cubic work with
    // every temporary left on the discovery arena, enough for a manifest
    // within the 1 MiB limit to stall `help` and every build (Codex P2 on
    // #420). `visited` holds one representative per group already ordered.
    var visited: std.ArrayList(Planned) = .empty;
    entries_loop: for (entries) |entry| {
        for (visited.items) |seen| {
            if (sameSlot(seen.hook, entry.hook) and seen.hook.when == entry.hook.when) continue :entries_loop;
        }
        try visited.append(a, entry);
        const group = try select(a, entries, entry.hook.step, entry.hook.target, entry.hook.when);
        _ = try orderPhase(a, group);
    }
}

/// How many times `orderPhase` ran. A test seam only: the count is what
/// proves validation orders each group once rather than once per hook.
var order_phase_calls: usize = 0;

fn select(a: std.mem.Allocator, entries: []const Planned, step: contract.Step, target: []const u8, phase: contract.Phase) ![]Planned {
    var list: std.ArrayList(Planned) = .empty;
    for (entries) |entry| {
        if (entry.hook.step == step and entry.hook.when == phase and std.mem.eql(u8, entry.hook.target, target))
            try list.append(a, entry);
    }
    return list.items;
}

/// Kahn's algorithm, always taking the lexicographically smallest ready
/// qualified ID, so the result is a function of the graph alone. Edges are
/// the `after_hooks` references that land inside `group`; references to an
/// earlier phase are satisfied by the phase order and create no edge.
fn orderPhase(a: std.mem.Allocator, group: []const Planned) ![]Planned {
    if (builtin.is_test) order_phase_calls += 1;
    const n = group.len;
    const done = try a.alloc(bool, n);
    @memset(done, false);
    const pending = try a.alloc(usize, n);
    for (group, 0..) |entry, i| {
        pending[i] = 0;
        for (entry.hook.after_hooks) |ref| {
            if (find(group, ref) != null) pending[i] += 1;
        }
    }
    var out: std.ArrayList(Planned) = .empty;
    while (out.items.len < n) {
        var best: ?usize = null;
        for (group, 0..) |entry, i| {
            if (done[i] or pending[i] != 0) continue;
            if (best == null or std.mem.lessThan(u8, entry.qualified, group[best.?].qualified)) best = i;
        }
        const next = best orelse {
            std.debug.print("labelle: hooks: cycle among", .{});
            var first = true;
            for (group, 0..) |entry, i| {
                if (done[i]) continue;
                std.debug.print("{s} '{s}'", .{ if (first) "" else ",", entry.qualified });
                first = false;
            }
            std.debug.print("\n", .{});
            return error.HookCycle;
        };
        done[next] = true;
        try out.append(a, group[next]);
        for (group, 0..) |entry, j| {
            if (done[j]) continue;
            for (entry.hook.after_hooks) |ref| {
                if (std.mem.eql(u8, ref, group[next].qualified)) pending[j] -= 1;
            }
        }
    }
    return out.items;
}

/// Pure and deterministic; independent of manifest read order. Assumes
/// `validateAll` passed for `providers`.
pub fn plan(a: std.mem.Allocator, providers: []const dispatch.Provider, step: contract.Step, target: []const u8) !Plan {
    const entries = try collect(a, providers);
    const replacements = try select(a, entries, step, target, .replace);
    if (replacements.len > 1) return error.DuplicateReplaceHook;
    return .{
        .before = try orderPhase(a, try select(a, entries, step, target, .before)),
        .replace = if (replacements.len == 1) replacements[0] else null,
        .after = try orderPhase(a, try select(a, entries, step, target, .after)),
    };
}

/// The step output-directory contract every hook and the core packager
/// agree on. `bundle_override` is the already-resolved `--output` directory,
/// when one was given. Caller creates it and canonicalises before use.
pub fn stepOutputDir(a: std.mem.Allocator, target_dir: []const u8, step: contract.Step, target: []const u8, bundle_override: ?[]const u8) ![]const u8 {
    return switch (step) {
        .generate => a.dupe(u8, target_dir),
        .build, .run => std.fs.path.join(a, &.{ target_dir, "zig-out" }),
        .bundle => if (bundle_override) |dir| a.dupe(u8, dir) else std.fs.path.join(a, &.{ target_dir, "zig-out", "bundle", target }),
    };
}

/// The progress phase a step's hooks report under.
fn progressPhase(step: contract.Step) progress.Phase {
    return switch (step) {
        .generate => .generate,
        .build => .compile,
        .bundle, .run => .run,
    };
}

/// Everything a hook run needs from the pipeline. `host` is resolved on the
/// first hook only, so a project whose plan is empty never touches the
/// compiler check.
pub const Site = struct {
    /// Long-lived storage: the pipeline's hook arena, which holds the
    /// providers, the plans and (once resolved) the host. Nothing a single
    /// phase allocates lands here.
    a: std.mem.Allocator,
    /// The allocator every phase's scratch arena is carved from and returned
    /// to when the phase ends. A watched serve session (`--watch`) runs the
    /// `generate` and `build` phases on every saved edit through one
    /// long-lived site; allocating each hook's lock, settings, workspace
    /// paths, environment and serialised context on the site arena grew
    /// memory on every rebuild (Codex P2 on #420).
    backing: std.mem.Allocator,
    providers: []const dispatch.Provider,
    /// Canonical project root.
    root: []const u8,
    cfg: project.ProjectConfig,
    target: []const u8,
    optimize: contract.Optimize,
    progress: contract.Progress,
    reporter: ?*progress.Reporter,
    /// `labelle bundle --build-number`: handed to the `bundle` hooks only
    /// (contract §2 `build_number`), since a provider replacement packages
    /// the target instead of the core packager that would stamp it.
    build_number: ?[]const u8 = null,
    host: ?dispatch.Host = null,
    /// The tool launcher. A field only so the scratch-arena test below can
    /// observe which allocator a hook invocation receives without a host
    /// compiler; production never overrides it.
    run_tool: *const fn (std.mem.Allocator, dispatch.Host, []const u8, dispatch.Provider, contract.Tool, dispatch.ToolRun) anyerror!u8 = dispatch.runTool,
    /// The host-compiler resolver. A field only so the pin-order test below
    /// can observe that an unpinned provider never reaches it; production
    /// never overrides it.
    resolve_host: *const fn (std.mem.Allocator, []const u8) anyerror!dispatch.Host = dispatch.resolveHost,
};

/// Run one phase of a plan in order, stopping at the first failure. Returns
/// 0 or the failing hook's exit code, after marking the progress feed
/// failed; the caller exits with that code.
///
/// Everything the phase allocates lives in a scratch arena freed on return;
/// only the resolved host outlives it, on the site's long-lived arena.
pub fn runPhase(site: *Site, list: []const Planned, step: contract.Step, phase: contract.Phase, output_dir: []const u8) !u8 {
    if (list.len == 0) return 0;
    var scratch = std.heap.ArenaAllocator.init(site.backing);
    defer scratch.deinit();
    const a = scratch.allocator();
    // Every hook's pin is checked BEFORE the host compiler is resolved, as
    // the command path does (`dispatch.dispatch`): resolving first
    // ran `zig version` and created cache directories, and on a machine
    // without the pinned compiler an unpinned remote hook was reported as
    // `ProviderCompilerMissing` — "install Zig" — instead of the integrity
    // failure that is the actual problem (Codex P2 on #420).
    const locks = try a.alloc([]const u8, list.len);
    for (list, locks) |planned, *lock| lock.* = try dispatch.requirePinned(a, site.root, planned.provider.*);
    if (site.host == null) site.host = try site.resolve_host(site.a, site.root);
    const output = try dispatch.canonicalDir(a, output_dir);
    for (list, locks) |planned, lock| {
        const provider = planned.provider.*;
        const settings = try dispatch.resolveSettings(a, site.root, site.cfg, site.providers, provider.meta.name);
        if (site.reporter) |r| r.beginPhaseOrStep(progressPhase(step), try std.fmt.allocPrint(a, "hook {s}", .{planned.qualified}));
        std.debug.print("labelle: running {s} hook '{s}' for {s} ({s})\n", .{ @tagName(phase), planned.qualified, @tagName(step), site.target });
        const code = try site.run_tool(a, site.host.?, site.root, provider, .{ .build_step = planned.hook.build_step, .executable = planned.hook.executable }, .{
            .invocation = .{ .kind = .hook, .id = planned.hook.id, .step = step, .phase = phase },
            .needs_project = true,
            .target = site.target,
            .lock_file = lock,
            .output_dir = output,
            .optimize = site.optimize,
            .progress = site.progress,
            .settings = settings,
            .trailing = &.{},
            .cwd = site.root,
            .build_number = if (step == .bundle) site.build_number else null,
        });
        if (site.reporter) |r| r.clearSpinner();
        if (code != 0) {
            std.debug.print("labelle: hook '{s}' failed (exit {d})\n", .{ planned.qualified, code });
            if (site.reporter) |r| r.finishFailed(code, "hook failed");
            return code;
        }
    }
    return 0;
}

/// A `before` phase whose core step reports under the same progress phase
/// with its own detail (`assembler generate`, `packaging bundle`). Each hook
/// renames the live sub-step to `hook <package>/<id>`; once the phase
/// succeeds the core step's `core_detail` is re-entered, so status and JSON
/// consumers do not keep seeing the last hook "running" throughout the
/// potentially long core operation (Codex P2 on #420). With no hooks nothing
/// is emitted: the detail never changed.
pub fn runBefore(site: *Site, list: []const Planned, step: contract.Step, output_dir: []const u8, core_detail: []const u8) !u8 {
    const code = try runPhase(site, list, step, .before, output_dir);
    if (code == 0 and list.len != 0) {
        if (site.reporter) |r| r.beginPhaseOrStep(progressPhase(step), core_detail);
    }
    return code;
}

/// The end of an interactive serve session: the server returned (Ctrl+C /
/// SIGTERM, the serve's clean end), and the `after run` hooks run now. The
/// feed's `done` record landed BEFORE the loop, so a failing hook — a
/// nonzero exit, or an error before it could run — revises that `done` to
/// `failed` with the code the CLI exits with (`reviseDoneAsFailed`); plain
/// `finishFailed` is absorbed by the terminal state and left the status file
/// and the NDJSON stream reporting success (Codex P2 on #420).
pub fn finishServe(site: *Site, after: []const Planned, output_dir: []const u8) !u8 {
    const code = runPhase(site, after, .run, .after, output_dir) catch |err| {
        if (site.reporter) |r| r.reviseDoneAsFailed(1, "hook failed");
        return err;
    };
    if (code != 0) {
        if (site.reporter) |r| r.reviseDoneAsFailed(code, "hook failed");
    }
    return code;
}

/// How the core `run` step ended. A status of 0 alone does not mean the
/// game ran to a clean end: the `--timeout` watchdog reports 0 after
/// killing the game (cli#390), and a simulator or device launch returns
/// while the app is still running. Only `exited_clean` is the success of
/// contract §6 that lets a publishing or cleanup `after run` hook run
/// (Codex P2 on #420); the CLI's exit status is `status()` either way.
pub const RunOutcome = union(enum) {
    /// The game process itself exited with status 0.
    exited_clean,
    /// The game process exited with this nonzero status (or was killed by a
    /// signal, 128 + signal).
    exited_error: u8,
    /// The watchdog killed the game at the `--timeout` deadline.
    timed_out,
    /// The launch returned while the app runs elsewhere (`simctl launch`,
    /// `adb shell am start`): its exit is never observed.
    launched_detached,

    pub fn fromExit(code: u8) RunOutcome {
        return if (code == 0) .exited_clean else .{ .exited_error = code };
    }

    /// The CLI's exit status for this outcome.
    pub fn status(self: RunOutcome) u8 {
        return switch (self) {
            .exited_error => |code| code,
            .exited_clean, .timed_out, .launched_detached => 0,
        };
    }

    fn skipReason(self: RunOutcome) []const u8 {
        return switch (self) {
            .exited_clean => unreachable,
            .exited_error => "the game exited with an error",
            .timed_out => "the game was stopped by --timeout",
            .launched_detached => "the app was launched detached and is still running",
        };
    }
};

/// The end of a `run` step: `after` hooks run only when the game itself
/// exited 0 (contract §6), and the feed is `done` only once they have. A
/// failing hook's exit code replaces the game's. Every other outcome skips
/// the hooks with one `labelle: after-run hooks skipped: <reason>` line
/// (only when there are hooks to skip) and keeps the outcome's status.
pub fn finishRun(site: *Site, after: []const Planned, output_dir: []const u8, outcome: RunOutcome) !u8 {
    const code = outcome.status();
    switch (outcome) {
        .exited_clean => {
            const hook_code = try runPhase(site, after, .run, .after, output_dir);
            if (hook_code != 0) return hook_code;
        },
        else => if (after.len != 0) std.debug.print("labelle: after-run hooks skipped: {s}\n", .{outcome.skipReason()}),
    }
    if (site.reporter) |r| r.finishDone(code);
    return code;
}

// ── Tests ────────────────────────────────────────────────────────────────

const Fixture = struct {
    fn hook(id: []const u8, step: contract.Step, target: []const u8, when: contract.Phase, after: []const []const u8) manifest.Hook {
        return .{ .id = id, .step = step, .target = target, .when = when, .build_step = "tool", .executable = "bin/tool", .after_hooks = after };
    }
    fn provider(name: []const u8, targets: []const []const u8, hooks: []const manifest.Hook) dispatch.Provider {
        return .{
            .dep = .{ .name = name, .repo = "local:../x", .version = "1.0.0" },
            .dir = "/x",
            .meta = .{ .name = name, .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0", .hooks = hooks, .targets = targets },
            .verified = true,
        };
    }
    fn ids(a: std.mem.Allocator, list: []const Planned) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (list, 0..) |entry, i| {
            if (i != 0) try out.appendSlice(a, " ");
            try out.appendSlice(a, entry.qualified);
        }
        return out.items;
    }
};

test "provider hooks: before, replace, after; ties by qualified id; independent of provider order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zeta = Fixture.provider("zeta", &.{"probe-target"}, &.{
        Fixture.hook("stamp", .bundle, "probe-target", .after, &.{}),
        Fixture.hook("pack", .bundle, "probe-target", .replace, &.{}),
        Fixture.hook("prep", .bundle, "probe-target", .before, &.{}),
    });
    const alpha = Fixture.provider("alpha", &.{}, &.{
        Fixture.hook("sign", .bundle, "probe-target", .after, &.{}),
        Fixture.hook("check", .bundle, "probe-target", .before, &.{}),
        Fixture.hook("other", .build, "probe-target", .before, &.{}),
        Fixture.hook("elsewhere", .bundle, "desktop", .before, &.{}),
    });
    const mid = Fixture.provider("mid", &.{}, &.{Fixture.hook("audit", .bundle, "probe-target", .after, &.{})});
    const orders = [_][3]dispatch.Provider{ .{ zeta, alpha, mid }, .{ mid, zeta, alpha }, .{ alpha, mid, zeta } };
    for (orders) |providers| {
        try validateAll(a, &providers, &.{});
        const p = try plan(a, &providers, .bundle, "probe-target");
        try std.testing.expectEqualStrings("alpha/check zeta/prep", try Fixture.ids(a, p.before));
        try std.testing.expectEqualStrings("zeta/pack", p.replace.?.qualified);
        try std.testing.expectEqualStrings("alpha/sign mid/audit zeta/stamp", try Fixture.ids(a, p.after));
        try std.testing.expect(!p.isEmpty());
        // Other steps and targets are excluded; a package owning nothing
        // still attaches before/after hooks to `desktop`.
        const build = try plan(a, &providers, .build, "probe-target");
        try std.testing.expectEqualStrings("alpha/other", try Fixture.ids(a, build.before));
        try std.testing.expect(build.replace == null and build.after.len == 0);
        const desktop = try plan(a, &providers, .bundle, "desktop");
        try std.testing.expectEqualStrings("alpha/elsewhere", try Fixture.ids(a, desktop.before));
        try std.testing.expect((try plan(a, &providers, .run, "desktop")).isEmpty());
    }
}

test "provider hooks: after_hooks edges override the qualified-id tie" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zeta = Fixture.provider("zeta", &.{}, &.{Fixture.hook("x", .build, "desktop", .after, &.{})});
    const alpha = Fixture.provider("alpha", &.{}, &.{Fixture.hook("y", .build, "desktop", .after, &.{"zeta/x"})});
    for ([_][2]dispatch.Provider{ .{ zeta, alpha }, .{ alpha, zeta } }) |providers| {
        try validateAll(a, &providers, &.{});
        const p = try plan(a, &providers, .build, "desktop");
        try std.testing.expectEqualStrings("zeta/x alpha/y", try Fixture.ids(a, p.after));
    }
    // Without the edge the tie decides, proving the edge did the reordering.
    const plain = Fixture.provider("alpha", &.{}, &.{Fixture.hook("y", .build, "desktop", .after, &.{})});
    const untied = [_]dispatch.Provider{ zeta, plain };
    try std.testing.expectEqualStrings("alpha/y zeta/x", try Fixture.ids(a, (try plan(a, &untied, .build, "desktop")).after));
    // A reference to an earlier phase is accepted and creates no edge.
    const early = Fixture.provider("alpha", &.{}, &.{
        Fixture.hook("y", .build, "desktop", .after, &.{"alpha/first"}),
        Fixture.hook("first", .build, "desktop", .before, &.{}),
    });
    const across = [_]dispatch.Provider{ zeta, early };
    try validateAll(a, &across, &.{});
    try std.testing.expectEqualStrings("alpha/y zeta/x", try Fixture.ids(a, (try plan(a, &across, .build, "desktop")).after));
}

test "provider hooks: cross-provider graph errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const owner = Fixture.provider("owner", &.{"probe-target"}, &.{
        Fixture.hook("one", .bundle, "probe-target", .replace, &.{}),
        Fixture.hook("two", .bundle, "probe-target", .replace, &.{}),
    });
    try std.testing.expectError(error.DuplicateReplaceHook, validateAll(a, &.{owner}, &.{}));
    const other = Fixture.provider("other", &.{}, &.{Fixture.hook("late", .bundle, "probe-target", .after, &.{})});
    const missing = Fixture.provider("pkg", &.{}, &.{Fixture.hook("h", .bundle, "probe-target", .after, &.{"other/absent"})});
    try std.testing.expectError(error.MissingHookReference, validateAll(a, &.{ other, missing }, &.{}));
    const mismatch = Fixture.provider("pkg", &.{}, &.{Fixture.hook("h", .build, "probe-target", .after, &.{"other/late"})});
    try std.testing.expectError(error.HookReferenceMismatch, validateAll(a, &.{ other, mismatch }, &.{}));
    const early = Fixture.provider("pkg", &.{}, &.{Fixture.hook("h", .bundle, "probe-target", .before, &.{"other/late"})});
    try std.testing.expectError(error.HookPhaseOrder, validateAll(a, &.{ other, early }, &.{}));
    const replace_to_after = Fixture.provider("pkg", &.{"probe-target"}, &.{Fixture.hook("h", .bundle, "probe-target", .replace, &.{"other/late"})});
    try std.testing.expectError(error.HookPhaseOrder, validateAll(a, &.{ other, replace_to_after }, &.{}));
    const loop_a = Fixture.provider("pkg-a", &.{}, &.{Fixture.hook("h", .bundle, "probe-target", .after, &.{"pkg-b/h"})});
    const loop_b = Fixture.provider("pkg-b", &.{}, &.{Fixture.hook("h", .bundle, "probe-target", .after, &.{"pkg-a/h"})});
    try std.testing.expectError(error.HookCycle, validateAll(a, &.{ loop_a, loop_b }, &.{}));
    try std.testing.expectError(error.HookCycle, validateAll(a, &.{ loop_b, loop_a }, &.{}));
    // A well-formed pair passes, so the errors above are the rules firing.
    const good = Fixture.provider("pkg", &.{}, &.{Fixture.hook("h", .bundle, "probe-target", .after, &.{"other/late"})});
    try validateAll(a, &.{ other, good }, &.{});
}

test "provider hooks: validation orders each (step, target, phase) group once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Six hooks in ONE group (`after build desktop`) across two providers,
    // plus one hook in a second group, so the count distinguishes "once per
    // group" (2) from "once per hook" (7).
    const many = Fixture.provider("many", &.{}, &.{
        Fixture.hook("h1", .build, "desktop", .after, &.{}),
        Fixture.hook("h2", .build, "desktop", .after, &.{"many/h1"}),
        Fixture.hook("h3", .build, "desktop", .after, &.{"many/h2"}),
        Fixture.hook("h4", .build, "desktop", .after, &.{}),
    });
    const more = Fixture.provider("more", &.{}, &.{
        Fixture.hook("h5", .build, "desktop", .after, &.{"many/h4"}),
        Fixture.hook("h6", .build, "desktop", .after, &.{}),
        Fixture.hook("solo", .generate, "desktop", .before, &.{}),
    });
    const providers = [_]dispatch.Provider{ many, more };
    order_phase_calls = 0;
    try validateAll(a, &providers, &.{});
    try std.testing.expectEqual(@as(usize, 2), order_phase_calls);
    // The result is unchanged: the plan is the same topological order the
    // per-hook validation produced.
    const p = try plan(a, &providers, .build, "desktop");
    try std.testing.expectEqualStrings("many/h1 many/h2 many/h3 many/h4 more/h5 more/h6", try Fixture.ids(a, p.after));
    try std.testing.expectEqualStrings("more/solo", try Fixture.ids(a, (try plan(a, &providers, .generate, "desktop")).before));
    // The one ordering still sees the whole group: a cycle among later
    // members of it is caught, so the dedup did not skip validation.
    const looped = Fixture.provider("more", &.{}, &.{
        Fixture.hook("h5", .build, "desktop", .after, &.{"more/h6"}),
        Fixture.hook("h6", .build, "desktop", .after, &.{"more/h5"}),
    });
    order_phase_calls = 0;
    try std.testing.expectError(error.HookCycle, validateAll(a, &.{ many, looped }, &.{}));
    try std.testing.expectEqual(@as(usize, 1), order_phase_calls);
}

test "provider hooks: an unpinned provider is refused before the host compiler is resolved" {
    const io = @import("config.zig").globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "project");
    const root = try tmp.dir.realPathFileAlloc(io, "project", a);
    // The lock names the remote provider exactly, so the pin check reaches
    // the integrity rule rather than failing on the lock itself.
    try tmp.dir.writeFile(io, .{
        .sub_path = "project/labelle.lock",
        .data = ".{ .plugins = .{ .{ .name = \"pkg\", .repo = \"example/pkg\", .version = \"1.0.0\" } } }",
    });
    const Spy = struct {
        var host_calls: usize = 0;
        var tool_calls: usize = 0;
        fn resolve(_: std.mem.Allocator, r: []const u8) anyerror!dispatch.Host {
            host_calls += 1;
            return .{ .zig = "/z", .cache_root = r, .global_cache = r, .packages = r };
        }
        fn run(_: std.mem.Allocator, _: dispatch.Host, _: []const u8, _: dispatch.Provider, _: contract.Tool, _: dispatch.ToolRun) anyerror!u8 {
            tool_calls += 1;
            return 0;
        }
    };
    // Production wiring: the default resolver IS the real one.
    try std.testing.expect((std.meta.fieldInfo(Site, .resolve_host).defaultValue() orelse return error.TestUnexpectedResult) == dispatch.resolveHost);
    var unpinned = Fixture.provider("pkg", &.{}, &.{Fixture.hook("h", .build, "desktop", .after, &.{})});
    unpinned.dep.repo = "example/pkg";
    unpinned.verified = false;
    const planned: Planned = .{ .provider = &unpinned, .hook = unpinned.meta.hooks[0], .qualified = "pkg/h" };
    var site: Site = .{
        .a = a,
        .backing = std.testing.allocator,
        .providers = &.{unpinned},
        .root = root,
        .cfg = .{ .name = "game" },
        .target = "desktop",
        .optimize = .Debug,
        .progress = .off,
        .reporter = null,
        .run_tool = Spy.run,
        .resolve_host = Spy.resolve,
    };
    const out = try std.fs.path.join(a, &.{ root, "zig-out" });
    try std.testing.expectError(error.RemoteProviderIntegrityRequired, runPhase(&site, &.{planned}, .build, .after, out));
    try std.testing.expectEqual(@as(usize, 0), Spy.host_calls);
    try std.testing.expectEqual(@as(usize, 0), Spy.tool_calls);
    try std.testing.expect(site.host == null);
    // The same provider, pinned: the resolver is reached exactly once and
    // the hook runs — so the zero above is the pin check firing first, not
    // the resolver being unreachable.
    var pinned = unpinned;
    pinned.verified = true;
    const planned_ok: Planned = .{ .provider = &pinned, .hook = pinned.meta.hooks[0], .qualified = "pkg/h" };
    site.providers = &.{pinned};
    try std.testing.expectEqual(@as(u8, 0), try runPhase(&site, &.{planned_ok}, .build, .after, out));
    try std.testing.expectEqual(@as(usize, 1), Spy.host_calls);
    try std.testing.expectEqual(@as(usize, 1), Spy.tool_calls);
}

test "provider hooks: step output directories follow the layout contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const target_dir = try std.fs.path.join(a, &.{ "proj", ".labelle", "probe_desktop" });
    try std.testing.expectEqualStrings(target_dir, try stepOutputDir(a, target_dir, .generate, "desktop", null));
    const zig_out = try std.fs.path.join(a, &.{ target_dir, "zig-out" });
    try std.testing.expectEqualStrings(zig_out, try stepOutputDir(a, target_dir, .build, "desktop", null));
    try std.testing.expectEqualStrings(zig_out, try stepOutputDir(a, target_dir, .run, "desktop", null));
    const bundle_dir = try std.fs.path.join(a, &.{ target_dir, "zig-out", "bundle", "probe-target" });
    try std.testing.expectEqualStrings(bundle_dir, try stepOutputDir(a, target_dir, .bundle, "probe-target", null));
    try std.testing.expectEqualStrings("/elsewhere/dist", try stepOutputDir(a, target_dir, .bundle, "probe-target", "/elsewhere/dist"));
    // The override is bundle-only: other steps never move.
    try std.testing.expectEqualStrings(zig_out, try stepOutputDir(a, target_dir, .build, "desktop", "/elsewhere/dist"));
    // The desktop default is the same directory the core packager uses.
    const bundle = @import("bundle.zig");
    const core = try bundle.resolveOutputDir(a, "proj", target_dir, null);
    try std.testing.expectEqualStrings(core, try stepOutputDir(a, target_dir, .bundle, "desktop", null));
}

test "provider hooks: a reference into a declared-but-unread package is unresolved, not missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const local = Fixture.provider("local", &.{}, &.{Fixture.hook("h", .build, "desktop", .after, &.{"remote/late"})});
    // `remote` is declared but could not be read (cold cache, `.unknown`):
    // the reference is deferred and the graph passes with the one provider.
    try validateAll(a, &.{local}, &.{"remote"});
    // The same graph with nothing unresolved is the genuine error, so the
    // pass above is the deferral firing rather than the check being absent.
    try std.testing.expectError(error.MissingHookReference, validateAll(a, &.{local}, &.{}));
    // A typo into a package the project never declared is still caught,
    // even while some other package is unresolved.
    const typo = Fixture.provider("local", &.{}, &.{Fixture.hook("h", .build, "desktop", .after, &.{"remot/late"})});
    try std.testing.expectError(error.MissingHookReference, validateAll(a, &.{typo}, &.{"remote"}));
    // Once `remote` is read, its hooks are checked for real: a present
    // package without the named hook is missing, and with it every rule
    // applies (here the slot mismatch).
    const remote_without = Fixture.provider("remote", &.{}, &.{Fixture.hook("other", .build, "desktop", .after, &.{})});
    try std.testing.expectError(error.MissingHookReference, validateAll(a, &.{ local, remote_without }, &.{}));
    const remote_elsewhere = Fixture.provider("remote", &.{}, &.{Fixture.hook("late", .bundle, "desktop", .after, &.{})});
    try std.testing.expectError(error.HookReferenceMismatch, validateAll(a, &.{ local, remote_elsewhere }, &.{}));
    const remote_ok = Fixture.provider("remote", &.{}, &.{Fixture.hook("late", .build, "desktop", .after, &.{})});
    try validateAll(a, &.{ local, remote_ok }, &.{});
    // The deferred reference creates no edge, so the plan still orders the
    // hooks that are present.
    const p = try plan(a, &.{local}, .build, "desktop");
    try std.testing.expectEqualStrings("local/h", try Fixture.ids(a, p.after));
}

/// Counts what is live in a backing allocator, so a test can assert that a
/// phase returned everything it allocated — the mechanism, not a value.
const CountingAllocator = struct {
    inner: std.mem.Allocator,
    live: usize = 0,
    allocations: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.inner.rawAlloc(len, alignment, ret_addr);
        if (result != null) {
            self.live += len;
            self.allocations += 1;
        }
        return result;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.inner.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.live = self.live - memory.len + new_len;
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.inner.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null) self.live = self.live - memory.len + new_len;
        return result;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, alignment, ret_addr);
        self.live -= memory.len;
    }
};

test "provider hooks: each phase runs on a scratch arena that is freed on return" {
    const io = @import("config.zig").globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var long_lived = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer long_lived.deinit();
    const a = long_lived.allocator();
    try tmp.dir.createDirPath(io, "project");
    const root = try tmp.dir.realPathFileAlloc(io, "project", a);
    // The lock a hook run requires, naming the fixture provider exactly.
    try tmp.dir.writeFile(io, .{
        .sub_path = "project/labelle.lock",
        .data = ".{ .plugins = .{ .{ .name = \"pkg\", .repo = \"local:../x\", .version = \"1.0.0\" } } }",
    });
    const Spy = struct {
        var calls: usize = 0;
        var scratch_ptr: ?*anyopaque = null;
        fn run(scratch: std.mem.Allocator, _: dispatch.Host, _: []const u8, _: dispatch.Provider, _: contract.Tool, _: dispatch.ToolRun) anyerror!u8 {
            // What a real invocation does with its allocator: workspace
            // paths, an environment, a serialised context.
            _ = try scratch.alloc(u8, 64 * 1024);
            scratch_ptr = scratch.ptr;
            calls += 1;
            return 0;
        }
    };
    var counting: CountingAllocator = .{ .inner = std.testing.allocator };
    const provider = Fixture.provider("pkg", &.{}, &.{Fixture.hook("h", .build, "desktop", .after, &.{})});
    const planned: Planned = .{ .provider = &provider, .hook = provider.meta.hooks[0], .qualified = "pkg/h" };
    var site: Site = .{
        .a = a,
        .backing = counting.allocator(),
        .providers = &.{provider},
        .root = root,
        .cfg = .{ .name = "game" },
        .target = "desktop",
        .optimize = .Debug,
        .progress = .off,
        .reporter = null,
        // Pre-resolved, so no compiler is consulted.
        .host = .{ .zig = "/z", .cache_root = root, .global_cache = root, .packages = root },
        .run_tool = Spy.run,
    };
    const out = try std.fs.path.join(a, &.{ root, "zig-out" });
    // Production wiring: the default launcher IS the real one.
    try std.testing.expect((std.meta.fieldInfo(Site, .run_tool).defaultValue() orelse return error.TestUnexpectedResult) == dispatch.runTool);

    try std.testing.expectEqual(@as(u8, 0), try runPhase(&site, &.{planned}, .build, .after, out));
    try std.testing.expectEqual(@as(usize, 1), Spy.calls);
    // The invocation allocated through the scratch, which is carved from
    // the backing allocator and is NOT the long-lived arena...
    const first_pass = counting.allocations;
    try std.testing.expect(first_pass > 0);
    try std.testing.expect(Spy.scratch_ptr.? != a.ptr);
    // ...and everything came back when the phase returned.
    try std.testing.expectEqual(@as(usize, 0), counting.live);
    // A second phase on the same site (a watched rebuild) allocates afresh
    // and again leaves nothing live: the scratch is reset per phase, not
    // accumulated across them.
    try std.testing.expectEqual(@as(u8, 0), try runPhase(&site, &.{planned}, .build, .after, out));
    try std.testing.expectEqual(@as(usize, 2), Spy.calls);
    try std.testing.expect(counting.allocations > first_pass);
    try std.testing.expectEqual(@as(usize, 0), counting.live);
}

test "provider hooks: after-run hooks run only when the game itself exited clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const provider = Fixture.provider("pkg", &.{}, &.{Fixture.hook("h", .run, "desktop", .after, &.{})});
    const planned: Planned = .{ .provider = &provider, .hook = provider.meta.hooks[0], .qualified = "pkg/h" };
    // No lock exists under this root: reaching the hook machinery at all is
    // observable as `MissingProjectLock`, distinct from a skip.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(@import("config.zig").globalIo(), ".", a);
    var site: Site = .{
        .a = a,
        .backing = std.testing.allocator,
        .providers = &.{provider},
        .root = root,
        .cfg = .{ .name = "game" },
        .target = "desktop",
        .optimize = .Debug,
        .progress = .off,
        .reporter = null,
        .host = .{ .zig = "/z", .cache_root = root, .global_cache = root, .packages = root },
    };
    const out = try std.fs.path.join(a, &.{ root, "zig-out" });
    try std.testing.expectEqual(RunOutcome.exited_clean, RunOutcome.fromExit(0));
    try std.testing.expectEqual(RunOutcome{ .exited_error = 7 }, RunOutcome.fromExit(7));
    // A clean exit reaches the hook (and fails on the missing lock).
    try std.testing.expectError(error.MissingProjectLock, finishRun(&site, &.{planned}, out, .exited_clean));
    // Every other outcome skips it and keeps the outcome's status: the
    // watchdog and a detached launch are exit 0 without being clean.
    try std.testing.expectEqual(@as(u8, 0), try finishRun(&site, &.{planned}, out, .timed_out));
    try std.testing.expectEqual(@as(u8, 0), try finishRun(&site, &.{planned}, out, .launched_detached));
    try std.testing.expectEqual(@as(u8, 7), try finishRun(&site, &.{planned}, out, .{ .exited_error = 7 }));
    // With no after hooks a clean exit is simply done.
    try std.testing.expectEqual(@as(u8, 0), try finishRun(&site, &.{}, out, .exited_clean));
}

/// A reporter over a fresh status directory, for the progress tests below.
const TestFeed = struct {
    tmp: std.testing.TmpDir,
    dir: []const u8,
    reporter: progress.Reporter,

    fn init(self: *TestFeed, a: std.mem.Allocator) !void {
        const io = @import("config.zig").globalIo();
        self.tmp = std.testing.tmpDir(.{});
        try self.tmp.dir.createDirPath(io, "project");
        self.dir = try self.tmp.dir.realPathFileAlloc(io, "project", a);
        const target_dir = try std.fs.path.join(a, &.{ self.dir, ".labelle", "probe_desktop" });
        self.reporter = try progress.Reporter.init(a, io, .off, target_dir);
        try self.tmp.dir.writeFile(io, .{
            .sub_path = "project/labelle.lock",
            .data = ".{ .plugins = .{ .{ .name = \"pkg\", .repo = \"local:../x\", .version = \"1.0.0\" } } }",
        });
    }

    fn deinit(self: *TestFeed) void {
        self.reporter.deinit();
        self.tmp.cleanup();
    }

    fn detail(self: *const TestFeed) []const u8 {
        return self.reporter.detail_buf[0..self.reporter.detail_len];
    }

    fn site(self: *TestFeed, a: std.mem.Allocator, provider: *const dispatch.Provider, run_tool: @FieldType(Site, "run_tool")) Site {
        return .{
            .a = a,
            .backing = std.testing.allocator,
            .providers = provider[0..1],
            .root = self.dir,
            .cfg = .{ .name = "game" },
            .target = "desktop",
            .optimize = .Debug,
            .progress = .off,
            .reporter = &self.reporter,
            .host = .{ .zig = "/z", .cache_root = self.dir, .global_cache = self.dir, .packages = self.dir },
            .run_tool = run_tool,
        };
    }
};

test "provider hooks: a before phase hands the progress detail back to the core step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var feed: TestFeed = undefined;
    try feed.init(a);
    defer feed.deinit();
    const Spy = struct {
        var seen: [progress.max_detail_len]u8 = undefined;
        var seen_len: usize = 0;
        var reporter: ?*progress.Reporter = null;
        fn run(_: std.mem.Allocator, _: dispatch.Host, _: []const u8, _: dispatch.Provider, _: contract.Tool, _: dispatch.ToolRun) anyerror!u8 {
            const r = reporter.?;
            seen_len = r.detail_len;
            @memcpy(seen[0..seen_len], r.detail_buf[0..seen_len]);
            return 0;
        }
    };
    Spy.reporter = &feed.reporter;
    const provider = Fixture.provider("pkg", &.{}, &.{Fixture.hook("h", .generate, "desktop", .before, &.{})});
    const planned: Planned = .{ .provider = &provider, .hook = provider.meta.hooks[0], .qualified = "pkg/h" };
    var site = feed.site(a, &provider, Spy.run);
    feed.reporter.beginPhase(.generate, "assembler generate");
    try std.testing.expectEqual(@as(u8, 0), try runBefore(&site, &.{planned}, .generate, feed.dir, "assembler generate"));
    // While the hook ran, the feed named it...
    try std.testing.expectEqualStrings("hook pkg/h", Spy.seen[0..Spy.seen_len]);
    // ...and once the phase is over the core step is what is reported.
    try std.testing.expectEqualStrings("assembler generate", feed.detail());
    try std.testing.expectEqual(progress.Phase.generate, feed.reporter.machine.current.?);
    // The plain phase runner leaves the hook's detail behind: the
    // restoration above is `runBefore`'s doing.
    try std.testing.expectEqual(@as(u8, 0), try runPhase(&site, &.{planned}, .generate, .before, feed.dir));
    try std.testing.expectEqualStrings("hook pkg/h", feed.detail());
    // A bundle's before hooks report under `run` and hand it back likewise.
    feed.reporter.beginPhaseOrStep(.run, "packaging bundle");
    try std.testing.expectEqual(@as(u8, 0), try runBefore(&site, &.{planned}, .bundle, feed.dir, "packaging bundle"));
    try std.testing.expectEqualStrings("packaging bundle", feed.detail());
    feed.reporter.finishDone(0);
}

test "provider hooks: a failing after hook at the serve's end revises the provisional done" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var feed: TestFeed = undefined;
    try feed.init(a);
    defer feed.deinit();
    const Spy = struct {
        var code: u8 = 0;
        fn run(_: std.mem.Allocator, _: dispatch.Host, _: []const u8, _: dispatch.Provider, _: contract.Tool, _: dispatch.ToolRun) anyerror!u8 {
            return code;
        }
    };
    const provider = Fixture.provider("pkg", &.{}, &.{Fixture.hook("h", .run, "probe-target", .after, &.{})});
    const planned: Planned = .{ .provider = &provider, .hook = provider.meta.hooks[0], .qualified = "pkg/h" };
    var site = feed.site(a, &provider, Spy.run);
    // The serve reported `done` before its loop; a passing hook keeps it.
    feed.reporter.beginPhase(.run, "serving");
    feed.reporter.finishDone(0);
    Spy.code = 0;
    try std.testing.expectEqual(@as(u8, 0), try finishServe(&site, &.{planned}, feed.dir));
    try std.testing.expectEqual(progress.Phase.done, feed.reporter.machine.current.?);
    // A failing hook: the CLI exits with its code, and the feed says so.
    Spy.code = 5;
    try std.testing.expectEqual(@as(u8, 5), try finishServe(&site, &.{planned}, feed.dir));
    try std.testing.expectEqual(progress.Phase.failed, feed.reporter.machine.current.?);
    try std.testing.expectEqual(@as(u8, 5), feed.reporter.exit_code.?);
}

test "provider hooks: a serve hook that cannot start also revises the provisional done" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var feed: TestFeed = undefined;
    try feed.init(a);
    defer feed.deinit();
    const Never = struct {
        fn run(_: std.mem.Allocator, _: dispatch.Host, _: []const u8, _: dispatch.Provider, _: contract.Tool, _: dispatch.ToolRun) anyerror!u8 {
            return error.TestUnexpectedResult;
        }
    };
    // A provider the lock does not name: refused before any tool runs.
    var provider = Fixture.provider("pkg", &.{}, &.{Fixture.hook("h", .run, "probe-target", .after, &.{})});
    provider.dep.version = "2.0.0";
    const planned: Planned = .{ .provider = &provider, .hook = provider.meta.hooks[0], .qualified = "pkg/h" };
    var site = feed.site(a, &provider, Never.run);
    feed.reporter.beginPhase(.run, "serving");
    feed.reporter.finishDone(0);
    try std.testing.expectError(error.StaleProviderPin, finishServe(&site, &.{planned}, feed.dir));
    try std.testing.expectEqual(progress.Phase.failed, feed.reporter.machine.current.?);
    try std.testing.expectEqual(@as(u8, 1), feed.reporter.exit_code.?);
}
