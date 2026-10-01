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
const provider_env = @import("provider_env.zig");
const config = @import("config.zig");
const run_outcome = @import("provider_run_outcome.zig");

/// Run a `run` replacement and say how it ended, its `run.outcome_file`
/// report included (`provider_run_outcome.zig`, wire `1.5.0`+).
pub const runReplacement = run_outcome.runReplacement;

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

/// The first hook among `lists` that can contribute an environment
/// (contract §2 `env_file`): one in a `contract.envFileSlot` whose provider
/// negotiates wire `1.3.0` or newer (an older wire has no `env_file`, so its
/// hook cannot). A build path that cannot carry contributions refuses when
/// this finds one, rather than silently bypassing the provider.
pub fn firstContributor(lists: []const []const Planned, step_of: []const contract.Step) ?Planned {
    for (lists, step_of) |list, step| {
        for (list) |planned| {
            const invocation: contract.Invocation = .{ .kind = .hook, .id = planned.hook.id, .step = step, .phase = planned.hook.when };
            if (!contract.envFileSlot(invocation)) continue;
            const wire = manifest.negotiate(planned.provider.meta.command_contract orelse continue) catch continue;
            if (contract.carriesToolchainContext(wire)) return planned;
        }
    }
    return null;
}

/// `firstContributor` over the three contributing slots of one target's
/// plans: `before`/`after generate` and `before build`.
pub fn planContributor(generate: Plan, build: Plan) ?Planned {
    return firstContributor(&.{ generate.before, generate.after, build.before }, &.{ .generate, .generate, .build });
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
    /// The generated target directory (`.labelle/<backend>_<target>/`),
    /// handed to every hook as contract §2 `target_dir` (wire `1.2.0`+):
    /// a hook's `output_dir` may sit elsewhere (`bundle --output`), and a
    /// packaging hook still needs the generated tree. Canonicalised (and
    /// created) per phase, like the output directory.
    target_dir: []const u8,
    /// `labelle run`'s options, handed to the `run`-step hooks only as
    /// contract §2 `run` (wire `1.2.0`+). The pipeline sets it for the
    /// `run` command; any other command's `run` hooks (a legacy serve
    /// subcommand) receive the empty set. The CLI passes the platform-neutral
    /// `LABELLE_*` pairs and maps nothing: how they reach the game on a
    /// provider's target is the provider's decision.
    run_options: ?contract.RunContext = null,
    /// The last lifecycle step of the command these hooks run under, handed
    /// to every hook as contract §2 `final_step` (wire `1.4.0`+): `bundle`
    /// for `labelle bundle`, so an `after build` hook can tell the build a
    /// bundle replacement packages again from the one it finalises (cli#443).
    final_step: contract.Step,
    /// The lock the hooks verify their pins against and receive as
    /// `lock_file`, when not the project's `labelle.lock`: a watched rebuild
    /// stages the lock of an edited project privately until the rebuild
    /// commits (a running replacement never sees an uncommitted one).
    lock_path: ?[]const u8 = null,
    host: ?dispatch.Host = null,
    /// The environment the hooks of the CURRENT build contributed through
    /// their `env_file` (contract §2, wire `1.3.0`+), merged in hook
    /// execution order. Every later hook and replacement runs with it, and
    /// the pipeline applies it to the fingerprint pass and the compile. A
    /// rebuild `reset`s it first, so a hook that no longer runs leaves
    /// nothing behind. The pipeline deinits it.
    env: provider_env.Accumulator = .{},
    /// The largest `env_file` read back. A field only so a test can lower
    /// it; production never overrides it.
    env_file_cap: usize = provider_env.max_file_bytes,
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
    return runPhaseReporting(site, list, step, phase, output_dir, null);
}

/// `runPhase`, where a `run` replacement whose provider negotiates wire
/// `1.5.0`+ also gets `run.outcome_file`: what it wrote there before
/// exiting 0 lands in `reported` (`provider_run_outcome.runReplacement`).
pub fn runPhaseReporting(site: *Site, list: []const Planned, step: contract.Step, phase: contract.Phase, output_dir: []const u8, reported: ?*RunOutcome) !u8 {
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
    for (list, locks) |planned, *lock| lock.* = if (site.lock_path) |path|
        try dispatch.requirePinnedAt(a, path, planned.provider.*)
    else
        try dispatch.requirePinned(a, site.root, planned.provider.*);
    if (site.host == null) site.host = try site.resolve_host(site.a, site.root);
    const output = try dispatch.canonicalDir(a, output_dir);
    const target_dir = try dispatch.canonicalDir(a, site.target_dir);
    const no_run_options: contract.RunContext = .{ .env = &.{}, .args = &.{}, .timeout_ms = null };
    var run_options: ?contract.RunContext = if (step == .run) site.run_options orelse no_run_options else null;
    // A watch session (`run.watch`) is the replacement's alone.
    if (run_options) |*options| if (phase != .replace) {
        options.watch = null;
    };
    for (list, locks) |planned, lock| {
        const provider = planned.provider.*;
        const settings = try dispatch.resolveSettings(a, site.root, site.cfg, site.providers, provider.meta.name);
        const invocation: contract.Invocation = .{ .kind = .hook, .id = planned.hook.id, .step = step, .phase = phase };
        // A fresh, private directory per invocation for the hook's
        // `env_file`; the file itself does not exist until the hook writes
        // it. Removed whatever happens.
        const env_dir: ?[]const u8 = if (contract.envFileSlot(invocation)) try privateDir(a, site.host.?, "provider-env") else null;
        defer if (env_dir) |dir| std.Io.Dir.cwd().deleteTree(config.globalIo(), dir) catch |err| {
            std.debug.print("labelle: could not remove hook environment directory '{s}': {s}\n", .{ dir, @errorName(err) });
        };
        const env_file: ?[]const u8 = if (env_dir) |dir| try std.fs.path.join(a, &.{ dir, "env.json" }) else null;
        // Likewise for the run replacement's `outcome_file` (wire `1.5.0`+).
        const outcome_dir: ?[]const u8 = if (reported != null and step == .run and phase == .replace and run_outcome.carried(provider))
            try privateDir(a, site.host.?, "provider-run")
        else
            null;
        defer if (outcome_dir) |dir| std.Io.Dir.cwd().deleteTree(config.globalIo(), dir) catch |err| {
            std.debug.print("labelle: could not remove run outcome directory '{s}': {s}\n", .{ dir, @errorName(err) });
        };
        const outcome_file: ?[]const u8 = if (outcome_dir) |dir| try std.fs.path.join(a, &.{ dir, run_outcome.file_name }) else null;
        var hook_run_options = run_options;
        if (hook_run_options) |*options| options.outcome_file = outcome_file;
        if (site.reporter) |r| r.beginPhaseOrStep(progressPhase(step), try std.fmt.allocPrint(a, "hook {s}", .{planned.qualified}));
        std.debug.print("labelle: running {s} hook '{s}' for {s} ({s})\n", .{ @tagName(phase), planned.qualified, @tagName(step), site.target });
        const code = try site.run_tool(a, site.host.?, site.root, provider, .{ .build_step = planned.hook.build_step, .executable = planned.hook.executable }, .{
            .invocation = invocation,
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
            .target_dir = target_dir,
            .run_options = hook_run_options,
            .env_file = env_file,
            .final_step = site.final_step,
            .env = &site.env,
        });
        if (site.reporter) |r| r.clearSpinner();
        if (code != 0) {
            // Whatever a failed hook wrote to its env_file is ignored: the
            // hook's failure is the outcome.
            std.debug.print("labelle: hook '{s}' failed (exit {d})\n", .{ planned.qualified, code });
            if (site.reporter) |r| r.finishFailed(code, "hook failed");
            return code;
        }
        if (env_file) |path| try absorbEnvFile(site, a, planned, invocation, path);
        if (outcome_file) |path| reported.?.* = try run_outcome.absorb(site, a, planned.qualified, path);
    }
    return 0;
}

/// The one way an invalid `env_file` ends the command: the diagnostic that
/// names the hook, and the progress feed marked failed.
fn rejectEnvFile(site: *Site, qualified: []const u8, reason: []const u8) error{InvalidHookEnvFile} {
    std.debug.print("labelle: hook '{s}' wrote an invalid env_file: {s}\n", .{ qualified, reason });
    if (site.reporter) |r| r.finishFailed(1, "invalid hook env_file");
    return error.InvalidHookEnvFile;
}

/// `<LABELLE_HOME>/<kind>/<random>/`, created empty: one invocation's
/// private directory for a file it hands back (`env_file`, `outcome_file`).
fn privateDir(a: std.mem.Allocator, host: dispatch.Host, kind: []const u8) ![]const u8 {
    const parent = try dispatch.canonicalDir(a, try std.fs.path.join(a, &.{ host.cache_root, kind }));
    var random: [16]u8 = undefined;
    config.globalIo().random(&random);
    const dir = try std.fs.path.join(a, &.{ parent, &std.fmt.bytesToHex(random, .lower) });
    try std.Io.Dir.cwd().createDir(config.globalIo(), dir, .default_dir);
    return dir;
}

/// Merge the env_file a successful hook left at `path` into the build's
/// environment (contract §2): absent is no contribution; empty, malformed
/// or conflicting fails the command here, before any later zig invocation,
/// naming the hook.
///
/// `build_options` (wire `1.6.0`+) are accepted only from the target
/// owner's `before generate` / `before build` hooks on a negotiated wire of
/// `1.6.0` or newer: the key from anyone else is an invalid file, even
/// empty, since that wire or slot does not define it.
fn absorbEnvFile(site: *Site, a: std.mem.Allocator, planned: Planned, invocation: contract.Invocation, path: []const u8) !void {
    const qualified = planned.qualified;
    const read = provider_env.readFile(a, path, site.env_file_cap) catch |err| switch (err) {
        error.StreamTooLong => return rejectEnvFile(site, qualified, try std.fmt.allocPrint(a, "the file is larger than the {d}-byte cap", .{site.env_file_cap})),
        else => return err,
    };
    const bytes = read orelse return;
    var diag: provider_env.Diagnostic = .{};
    const file = provider_env.parseFile(a, bytes, site.env.windows, &diag) catch |err| switch (err) {
        error.InvalidEnvFile => return rejectEnvFile(site, qualified, diag.message),
        else => return err,
    };
    if (file.build_options != null) {
        const provider = planned.provider;
        if (!provider.meta.ownsTarget(site.target))
            return rejectEnvFile(site, qualified, try std.fmt.allocPrint(a, "build_options may only come from the owner of target '{s}', not package '{s}'", .{ site.target, provider.meta.name }));
        if (!contract.buildOptionsSlot(invocation))
            return rejectEnvFile(site, qualified, try std.fmt.allocPrint(a, "build_options may only come from a 'before generate' or 'before build' hook, not '{s} {s}'", .{ @tagName(invocation.phase.?), @tagName(invocation.step.?) }));
        const wire = manifest.negotiate(provider.meta.command_contract orelse "") catch "none";
        if (!contract.carriesBuildOptions(wire))
            return rejectEnvFile(site, qualified, try std.fmt.allocPrint(a, "build_options need provider contract >= {s}; package '{s}' speaks {s}", .{ contract.build_options_since, provider.meta.name, wire }));
    }
    site.env.add(site.backing, a, qualified, file, &diag) catch |err| switch (err) {
        error.InvalidEnvFile => {
            std.debug.print("labelle: hook environment conflict: {s}\n", .{diag.message});
            if (site.reporter) |r| r.finishFailed(1, "hook environment conflict");
            return error.HookEnvConflict;
        },
        else => return err,
    };
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
/// killing the game (cli#390), a run replacement that enforced it reports
/// `timeout` (cli#473), and a simulator or device launch returns
/// while the app is still running. Only `exited_clean` is the success of
/// contract §6 that lets a publishing or cleanup `after run` hook run
/// (Codex P2 on #420); the CLI's exit status is `status()` either way.
pub const RunOutcome = union(enum) {
    /// The game process itself exited with status 0.
    exited_clean,
    /// The game process exited with this nonzero status (or was killed by a
    /// signal, 128 + signal).
    exited_error: u8,
    /// The game was stopped at the `--timeout` deadline: by the CLI's
    /// watchdog, or by a run replacement that reported it.
    timed_out,
    /// The launch returned while the app runs elsewhere (a simulator,
    /// or any launcher that hands the app to a device): its exit is never
    /// observed.
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

test {
    _ = @import("provider_hooks_env_test.zig");
    _ = @import("provider_hooks_run_test.zig");
    _ = @import("provider_run_outcome.zig");
}

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
        .target_dir = root,
        .optimize = .Debug,
        .progress = .off,
        .reporter = null,
        .final_step = .build,
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
