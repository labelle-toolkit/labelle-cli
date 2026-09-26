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

/// Cross-provider rules of contract §6, checked once at discovery so that
/// `labelle help` and `providers resolve --accept` fail on a broken graph
/// too. Prints one diagnostic line per failure, then returns the error.
pub fn validateAll(a: std.mem.Allocator, providers: []const dispatch.Provider) !void {
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
    // Same-phase cycles: order every phase group the way `plan` will.
    for (entries) |entry| {
        const group = try select(a, entries, entry.hook.step, entry.hook.target, entry.hook.when);
        _ = try orderPhase(a, group);
    }
}

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
    a: std.mem.Allocator,
    providers: []const dispatch.Provider,
    /// Canonical project root.
    root: []const u8,
    cfg: project.ProjectConfig,
    target: []const u8,
    optimize: contract.Optimize,
    progress: contract.Progress,
    reporter: ?*progress.Reporter,
    host: ?dispatch.Host = null,
};

/// Run one phase of a plan in order, stopping at the first failure. Returns
/// 0 or the failing hook's exit code, after marking the progress feed
/// failed; the caller exits with that code.
pub fn runPhase(site: *Site, list: []const Planned, step: contract.Step, phase: contract.Phase, output_dir: []const u8) !u8 {
    if (list.len == 0) return 0;
    const a = site.a;
    if (site.host == null) site.host = try dispatch.resolveHost(a, site.root);
    const output = try dispatch.canonicalDir(a, output_dir);
    for (list) |planned| {
        const provider = planned.provider.*;
        const lock = try dispatch.requirePinned(a, site.root, provider);
        const settings = try dispatch.resolveSettings(a, site.root, site.cfg, site.providers, provider.meta.name);
        if (site.reporter) |r| r.beginPhaseOrStep(progressPhase(step), try std.fmt.allocPrint(a, "hook {s}", .{planned.qualified}));
        std.debug.print("labelle: running {s} hook '{s}' for {s} ({s})\n", .{ @tagName(phase), planned.qualified, @tagName(step), site.target });
        const code = try dispatch.runTool(a, site.host.?, site.root, provider, .{ .build_step = planned.hook.build_step, .executable = planned.hook.executable }, .{
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

/// The end of a `run` step: `after` hooks run only when the game exited 0
/// (contract §6), and the feed is `done` only once they have. A failing
/// hook's exit code replaces the game's.
pub fn finishRun(site: *Site, after: []const Planned, output_dir: []const u8, code: u8) !u8 {
    if (code == 0) {
        const hook_code = try runPhase(site, after, .run, .after, output_dir);
        if (hook_code != 0) return hook_code;
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
        try validateAll(a, &providers);
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
        try validateAll(a, &providers);
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
    try validateAll(a, &across);
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
    try std.testing.expectError(error.DuplicateReplaceHook, validateAll(a, &.{owner}));
    const other = Fixture.provider("other", &.{}, &.{Fixture.hook("late", .bundle, "probe-target", .after, &.{})});
    const missing = Fixture.provider("pkg", &.{}, &.{Fixture.hook("h", .bundle, "probe-target", .after, &.{"other/absent"})});
    try std.testing.expectError(error.MissingHookReference, validateAll(a, &.{ other, missing }));
    const mismatch = Fixture.provider("pkg", &.{}, &.{Fixture.hook("h", .build, "probe-target", .after, &.{"other/late"})});
    try std.testing.expectError(error.HookReferenceMismatch, validateAll(a, &.{ other, mismatch }));
    const early = Fixture.provider("pkg", &.{}, &.{Fixture.hook("h", .bundle, "probe-target", .before, &.{"other/late"})});
    try std.testing.expectError(error.HookPhaseOrder, validateAll(a, &.{ other, early }));
    const replace_to_after = Fixture.provider("pkg", &.{"probe-target"}, &.{Fixture.hook("h", .bundle, "probe-target", .replace, &.{"other/late"})});
    try std.testing.expectError(error.HookPhaseOrder, validateAll(a, &.{ other, replace_to_after }));
    const loop_a = Fixture.provider("pkg-a", &.{}, &.{Fixture.hook("h", .bundle, "probe-target", .after, &.{"pkg-b/h"})});
    const loop_b = Fixture.provider("pkg-b", &.{}, &.{Fixture.hook("h", .bundle, "probe-target", .after, &.{"pkg-a/h"})});
    try std.testing.expectError(error.HookCycle, validateAll(a, &.{ loop_a, loop_b }));
    try std.testing.expectError(error.HookCycle, validateAll(a, &.{ loop_b, loop_a }));
    // A well-formed pair passes, so the errors above are the rules firing.
    const good = Fixture.provider("pkg", &.{}, &.{Fixture.hook("h", .bundle, "probe-target", .after, &.{"other/late"})});
    try validateAll(a, &.{ other, good });
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
