//! The provider half of `labelle doctor` (RFC #406, "unified help and
//! doctor"). Inside a project, every pinned provider whose manifest declares
//! a command named exactly `doctor` has it run after the core checks, in
//! namespace order, through the same path as `labelle <namespace> doctor`
//! (`provider_dispatch.runCommand`: the lock and integrity checks, the
//! provider settings, the isolated tool build and the wire context). Nothing
//! here names a provider: the manifests decide who takes part.
//!
//! A provider that fails does not stop the others; the report counts it and
//! `labelle doctor` exits non-zero. A pinned provider whose archive is not
//! cached (or does not match its pin) is reported as a failed check with the
//! `labelle providers fetch` hint; the doctor never downloads a provider
//! archive (the host compiler is provisioned as `labelle build` does). An
//! unpinned remote package runs no code: cached with a manifest declaring
//! provider features, it fails with the `labelle providers resolve` hint;
//! cached and runtime-only, it is not listed; not cached, it is a WARN ("not
//! installed yet; run `labelle install`") that leaves the exit code alone,
//! since only its manifest could tell whether it is a provider. Projectless
//! provider commands are a later phase (decision D8), so outside a project
//! only the core checks run.
const std = @import("std");
const config = @import("config.zig");
const project = @import("project_config.zig");
const manifest = @import("provider_manifest.zig");
const dispatch = @import("provider_dispatch.zig");
const github = @import("provider_github.zig");

/// The command a provider declares to take part.
pub const command_name = "doctor";

pub const Step = struct {
    /// The namespace (the header and the order key); the package name for a
    /// provider whose manifest could not be read.
    label: []const u8,
    package: []const u8,
    action: Action,

    pub const Action = union(enum) {
        /// Run `command` of `providers[provider]`.
        run: struct { provider: usize, command: manifest.Command },
        /// The provider's source could not be obtained (`Sources.projectDir`).
        unavailable: anyerror,
        /// A declared remote package with no integrity pin. Never run.
        unverified: Unverified,
    };
};

/// How an unpinned remote package was found. Neither case runs any of its
/// code; what differs is what the doctor can know.
pub const Unverified = enum {
    /// Not in the package cache: nothing to read, so the doctor cannot tell
    /// a runtime-only package from a provider. A WARN ("not installed yet;
    /// run `labelle install`") that leaves the exit code alone: a build
    /// installs it first and fails loudly if it is an unpinned provider.
    uncached,
    /// In the package cache, and its (unverified) manifest declares provider
    /// features (or cannot be read). A FAIL with the `labelle providers
    /// resolve` hint, since it would need a pin to run. A cached
    /// runtime-only package is not listed at all.
    cached,
    /// Not in the package cache, but the project already treats it as a
    /// provider: a `provider_config` entry, or a verified provider's hook
    /// ordering (`after_hooks`) names it. A FAIL with the `labelle providers
    /// resolve` hint, like `cached`: installing it cannot make it pass.
    referenced,
};

pub const Plan = struct {
    steps: []const Step,
    /// Providers that declare no `doctor` command, by package name, sorted.
    skipped: []const []const u8,
};

/// Which provider doctors run, and in what order: every verified provider
/// with a namespace and a command named exactly `doctor`, plus a failed check
/// for every declared package that cannot be verified: a pinned one whose
/// source could not be obtained (`unavailable`), and a remote one with no
/// integrity pin, cached (`unverified`, or `providers[i].verified == false`)
/// or not (`unresolved`, minus the `unavailable` ones; `referenced` when
/// `provider_refs` names it as a provider). Sorted by label; declaration
/// order in `project.labelle` does not matter.
pub fn plan(a: std.mem.Allocator, providers: []const dispatch.Provider, unavailable: []const dispatch.Unavailable, unresolved: []const []const u8, unverified: []const []const u8, provider_refs: []const []const u8) !Plan {
    var steps: std.ArrayList(Step) = .empty;
    var skipped: std.ArrayList([]const u8) = .empty;
    for (providers, 0..) |provider, index| {
        if (!provider.verified) {
            // Labelled by package, not namespace: the uncached case cannot
            // know the namespace, and both must read the same.
            try steps.append(a, .{ .label = provider.meta.name, .package = provider.meta.name, .action = .{ .unverified = .cached } });
            continue;
        }
        const command = find(provider.meta) orelse {
            try skipped.append(a, provider.meta.name);
            continue;
        };
        try steps.append(a, .{
            .label = provider.meta.namespace.?,
            .package = provider.meta.name,
            .action = .{ .run = .{ .provider = index, .command = command } },
        });
    }
    for (unavailable) |entry| {
        try steps.append(a, .{ .label = entry.package, .package = entry.package, .action = .{ .unavailable = entry.err } });
    }
    for (unverified) |name| {
        try steps.append(a, .{ .label = name, .package = name, .action = .{ .unverified = .cached } });
    }
    unread: for (unresolved) |name| {
        for (unavailable) |entry| if (std.mem.eql(u8, entry.package, name)) continue :unread;
        const found: Unverified = if (named(provider_refs, name)) .referenced else .uncached;
        try steps.append(a, .{ .label = name, .package = name, .action = .{ .unverified = found } });
    }
    std.mem.sort(Step, steps.items, {}, struct {
        fn lessThan(_: void, x: Step, y: Step) bool {
            return switch (std.mem.order(u8, x.label, y.label)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.lessThan(u8, x.package, y.package),
            };
        }
    }.lessThan);
    std.mem.sort([]const u8, skipped.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    return .{ .steps = steps.items, .skipped = skipped.items };
}

fn find(meta: manifest.Manifest) ?manifest.Command {
    // A command is only reachable under a namespace (`labelle <ns> doctor`).
    if (meta.namespace == null) return null;
    for (meta.commands) |command| {
        if (std.mem.eql(u8, command.name, command_name)) return command;
    }
    return null;
}

pub const Outcome = struct {
    label: []const u8,
    package: []const u8,
    /// The tool's exit status, or null when it never ran.
    code: ?u8,
    /// Why it never ran (an error name), when `code` is null.
    err: ?anyerror = null,
    /// A WARN: reported, never a failure (an uninstalled package).
    warning: bool = false,
    /// What the tool printed on stdout, when the run captured it
    /// (`labelle doctor --json`: `provider_doctor_json.zig` reads it).
    stdout: ?[]const u8 = null,

    pub fn ok(self: Outcome) bool {
        return self.code == 0 or self.warning;
    }
};

pub const Report = struct {
    outcomes: []const Outcome,
    skipped: []const []const u8 = &.{},

    pub fn failed(self: Report) usize {
        var count: usize = 0;
        for (self.outcomes) |outcome| count += @intFromBool(!outcome.ok());
        return count;
    }

    pub fn warnings(self: Report) usize {
        var count: usize = 0;
        for (self.outcomes) |outcome| count += @intFromBool(outcome.warning);
        return count;
    }
};

/// Run every step with `runner.run(step, &stdout) anyerror!u8`, one after
/// another, whatever the previous ones returned. A runner that captures the
/// tool's stdout stores it in `stdout` (kept on the outcome); one that passes
/// it through leaves it null. Prints a header per provider and its result
/// line to stderr.
pub fn execute(a: std.mem.Allocator, p: Plan, runner: anytype) !Report {
    var outcomes: std.ArrayList(Outcome) = .empty;
    for (p.steps) |step| {
        printHeader(step);
        const outcome: Outcome = switch (step.action) {
            .unavailable => |err| blk: {
                std.debug.print("  [ FAIL ] provider source unavailable: {s}\n", .{@errorName(err)});
                if (fetchable(err)) {
                    std.debug.print("           -> run `labelle providers fetch` to download the pinned archives\n", .{});
                } else if (err == error.StaleProviderIntegrityPin) {
                    std.debug.print("           -> run `labelle providers resolve` to re-pin it, then repeat with --accept\n", .{});
                }
                break :blk .{ .label = step.label, .package = step.package, .code = null, .err = err };
            },
            .unverified => |found| switch (found) {
                .uncached => blk: {
                    std.debug.print("  [ WARN ] not installed yet: remote package not in the package cache, so the doctor cannot tell whether it is a provider\n", .{});
                    std.debug.print("           -> run `labelle install`\n", .{});
                    break :blk .{ .label = step.label, .package = step.package, .code = null, .err = error.PackageNotInstalled, .warning = true };
                },
                .cached, .referenced => blk: {
                    if (found == .referenced) std.debug.print("  [ FAIL ] not verified: remote package the project uses as a provider (provider_config or hook ordering), with no integrity pin in labelle.providers.lock and not installed\n", .{}) else std.debug.print("  [ FAIL ] not verified: remote provider with no integrity pin in labelle.providers.lock; its code is not run\n", .{});
                    std.debug.print("           -> run `labelle providers resolve`, review the pins, then repeat with --accept\n", .{});
                    break :blk .{ .label = step.label, .package = step.package, .code = null, .err = error.RemoteProviderIntegrityRequired };
                },
            },
            .run => blk: {
                var stdout: ?[]const u8 = null;
                break :blk if (runner.run(step, &stdout)) |code|
                    .{ .label = step.label, .package = step.package, .code = code, .stdout = stdout }
                else |err|
                    .{ .label = step.label, .package = step.package, .code = null, .err = err };
            },
        };
        switch (step.action) {
            .unavailable, .unverified => {},
            .run => if (outcome.code) |code| {
                if (code == 0) {
                    std.debug.print("  [  OK  ] labelle {s} {s}\n", .{ step.label, command_name });
                } else {
                    std.debug.print("  [ FAIL ] labelle {s} {s} exited {d}\n", .{ step.label, command_name, code });
                }
            } else {
                std.debug.print("  [ FAIL ] labelle {s} {s}: {s}\n", .{ step.label, command_name, @errorName(outcome.err.?) });
            },
        }
        try outcomes.append(a, outcome);
    }
    return .{ .outcomes = outcomes.items, .skipped = p.skipped };
}

fn fetchable(err: anyerror) bool {
    return err == error.ProviderArchiveMissing or err == error.ProviderArchiveHashMismatch;
}

fn printHeader(step: Step) void {
    switch (step.action) {
        .run => std.debug.print("\nlabelle {s} {s}  (provider '{s}')\n", .{ step.label, command_name, step.package }),
        .unavailable => std.debug.print("\nprovider '{s}'\n", .{step.package}),
        .unverified => |found| switch (found) {
            .cached, .referenced => std.debug.print("\nprovider '{s}'\n", .{step.package}),
            // Not known to be a provider.
            .uncached => std.debug.print("\npackage '{s}'\n", .{step.package}),
        },
    }
    std.debug.print("------------------------------------------------------------\n", .{});
}

/// The closing summary of the provider part.
pub fn printSummary(report: Report) void {
    std.debug.print("\nProvider doctors: {d} checked, {d} failed", .{ report.outcomes.len, report.failed() });
    if (report.failed() != 0) printLabels(report, false);
    if (report.warnings() != 0) {
        std.debug.print(", {d} not installed yet", .{report.warnings()});
        printLabels(report, true);
    }
    std.debug.print("\n", .{});
    if (report.skipped.len != 0) {
        std.debug.print("  no `{s}` command: ", .{command_name});
        for (report.skipped, 0..) |name, i| std.debug.print("{s}{s}", .{ if (i == 0) "" else ", ", name });
        std.debug.print("\n", .{});
    }
}

fn printLabels(report: Report, warnings: bool) void {
    std.debug.print(" (", .{});
    var first = true;
    for (report.outcomes) |outcome| {
        const listed = if (warnings) outcome.warning else !outcome.ok();
        if (!listed) continue;
        std.debug.print("{s}{s}", .{ if (first) "" else ", ", outcome.label });
        first = false;
    }
    std.debug.print(")", .{});
}

/// The exit status of `labelle doctor`: non-zero when the core checks or
/// any provider doctor failed.
pub fn exitCode(core_ok: bool, report: ?Report) u8 {
    if (!core_ok) return 1;
    if (report) |r| if (r.failed() != 0) return 1;
    return 0;
}

/// Runs a planned step through the dispatch path of `labelle <ns> doctor`.
const DispatchRunner = struct {
    a: std.mem.Allocator,
    root: []const u8,
    cfg: project.ProjectConfig,
    providers: []const dispatch.Provider,
    /// One host-compiler resolution for the whole doctor: a failed (e.g.
    /// offline) provisioning is attempted once and every provider after it
    /// gets the same error as its own failed line.
    hosts: *dispatch.HostCache,
    /// `labelle doctor --json` (RFC cli#466 D7): every provider doctor gets
    /// `--json`, and its stdout is captured for the core's one document
    /// instead of reaching the CLI's stdout.
    json: bool = false,

    pub fn run(self: DispatchRunner, step: Step, stdout: *?[]const u8) anyerror!u8 {
        const action = step.action.run;
        var captured: []const u8 = "";
        // `.selected`: only this provider's settings file is opened, so a
        // bad file of another provider fails that provider alone.
        const code = try dispatch.runCommand(self.a, self.root, self.cfg, self.providers, self.providers[action.provider], action.command, if (self.json) &json_args else &.{}, .selected, self.hosts, if (self.json) &captured else null);
        if (self.json) stdout.* = captured;
        return code;
    }

    const json_args = [_][]const u8{"--json"};
};

/// The line `labelle doctor` prints instead of the provider part outside a
/// project (projectless provider commands are decision D8's later phase).
pub fn printOutsideProject(start: []const u8) void {
    std.debug.print("  Provider doctors run inside a project; no project.labelle at or above '{s}'.\n", .{start});
}

/// The provider part of `labelle doctor` for the project at `root` (the
/// canonical project root the core checks used too). `json`: each provider
/// doctor runs with `--json` and its stdout is captured on its outcome
/// (`DispatchRunner.json`); the human report still goes to stderr.
pub fn runForRoot(allocator: std.mem.Allocator, root: []const u8, json: bool) !Report {
    // The report outlives this call; its strings live in `allocator`'s arena
    // owned by the caller.
    const a = allocator;
    var sources: github.Sources = .{ .a = a };
    defer sources.deinit();
    const discovered = discover(a, root, &sources) catch |err| {
        std.debug.print("\nProvider doctors\n", .{});
        std.debug.print("------------------------------------------------------------\n", .{});
        std.debug.print("  [ FAIL ] provider discovery: {s}\n", .{@errorName(err)});
        const outcomes = try a.alloc(Outcome, 1);
        outcomes[0] = .{ .label = "provider discovery", .package = "", .code = null, .err = err };
        return .{ .outcomes = outcomes };
    };
    const survey = discovered.survey;
    const p = try plan(a, survey.providers, survey.unavailable, survey.unresolved, survey.unverified, discovered.provider_refs);
    // The project-wide settings mapping is checked once and reported once;
    // each provider then opens only its own settings file, so neither a bad
    // mapping nor another provider's bad file stops a provider's doctor.
    const mapping: ?Outcome = if (dispatch.checkSettingsMapping(discovered.cfg, survey.providers)) |_| null else |err| blk: {
        std.debug.print("\nprovider_config\n", .{});
        std.debug.print("------------------------------------------------------------\n", .{});
        std.debug.print("  [ FAIL ] provider_config mapping: {s}\n", .{@errorName(err)});
        break :blk .{ .label = "provider_config", .package = "", .code = null, .err = err };
    };
    if (p.steps.len == 0 and p.skipped.len == 0 and mapping == null) {
        std.debug.print("  No providers declared in this project.\n", .{});
        return .{ .outcomes = &.{} };
    }
    var hosts: dispatch.HostCache = .{};
    var report = try execute(a, p, DispatchRunner{
        .a = a,
        .root = root,
        .cfg = discovered.cfg,
        .providers = survey.providers,
        .hosts = &hosts,
        .json = json,
    });
    if (mapping) |outcome| report.outcomes = try std.mem.concat(a, Outcome, &.{ &.{outcome}, report.outcomes });
    printSummary(report);
    return report;
}

const Discovered = struct {
    cfg: project.ProjectConfig,
    survey: dispatch.Survey,
    /// Packages the project already uses as providers: every
    /// `provider_config` entry and every package a verified provider's
    /// `after_hooks` names.
    provider_refs: []const []const u8,
};

/// See `Discovered.provider_refs`.
pub fn providerRefs(a: std.mem.Allocator, cfg: project.ProjectConfig, providers: []const dispatch.Provider) ![]const []const u8 {
    var refs: std.ArrayList([]const u8) = .empty;
    for (cfg.provider_config) |entry| try refs.append(a, entry.package);
    for (providers) |provider| {
        if (!provider.verified) continue;
        for (provider.meta.hooks) |hook| for (hook.after_hooks) |ref| {
            const slash = std.mem.indexOfScalar(u8, ref, '/') orelse continue;
            try refs.append(a, ref[0..slash]);
        };
    }
    return refs.items;
}

fn discover(a: std.mem.Allocator, root: []const u8, sources: *github.Sources) !Discovered {
    var cfg = try config.readProjectConfigQuiet(a, root);
    const found = try dispatch.survey(a, root, cfg, sources);
    const refs = try providerRefs(a, cfg, found.providers);
    // A settings entry for a package that could not be read or verified is
    // already a failed check of its own; it must not also fail every other
    // provider's settings resolution (which requires each entry to name a
    // resolved, verified provider).
    var entries: std.ArrayList(@import("provider_settings.zig").Entry) = .empty;
    for (cfg.provider_config) |entry| {
        if (named(found.unresolved, entry.package) or named(found.unverified, entry.package)) continue;
        var unverified = false;
        for (found.providers) |provider| {
            if (!provider.verified and std.mem.eql(u8, provider.meta.name, entry.package)) unverified = true;
        }
        if (!unverified) try entries.append(a, entry);
    }
    cfg.provider_config = entries.items;
    return .{ .cfg = cfg, .survey = found, .provider_refs = refs };
}

fn named(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;

fn fake(name: []const u8, namespace: ?[]const u8, commands: []const manifest.Command) dispatch.Provider {
    return .{
        .dep = .{ .name = name, .repo = "local:../x", .version = "1.0.0" },
        .dir = "/x",
        .meta = .{ .name = name, .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0", .namespace = namespace, .commands = commands },
        .verified = true,
    };
}

fn cmd(name: []const u8, executable: []const u8) manifest.Command {
    return .{ .name = name, .build_step = "install-tool", .executable = executable, .help = "h" };
}

/// Records every invocation (namespace + the tool it would build and run)
/// and fails the namespaces it is told to.
const Recorder = struct {
    a: std.mem.Allocator,
    calls: *std.ArrayList([]const u8),
    exit_codes: []const struct { []const u8, u8 } = &.{},
    errors: []const []const u8 = &.{},

    pub fn run(self: Recorder, step: Step, _: *?[]const u8) anyerror!u8 {
        const command = step.action.run.command;
        try self.calls.append(self.a, try std.fmt.allocPrint(self.a, "{s}:{s}", .{ step.label, command.executable }));
        for (self.errors) |label| if (std.mem.eql(u8, label, step.label)) return error.ProviderCompilerMissing;
        for (self.exit_codes) |entry| if (std.mem.eql(u8, entry[0], step.label)) return entry[1];
        return 0;
    }
};

test "provider doctor: selects providers declaring `doctor`, by namespace, skipping the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Declared out of order; one without `doctor`, one with a near miss, one
    // with no namespace at all.
    const providers = [_]dispatch.Provider{
        fake("zeta-pkg", "zeta", &.{ cmd("run", "bin/zeta-run"), cmd("doctor", "bin/zeta-doctor") }),
        fake("plain", "plain", &.{cmd("serve", "bin/plain")}),
        fake("alpha-pkg", "alpha", &.{cmd("doctor", "bin/alpha-doctor")}),
        fake("near", "near", &.{cmd("doctors", "bin/near")}),
        fake("hooks-only", null, &.{}),
        fake("mid-pkg", "mid", &.{cmd("doctor", "bin/mid-doctor")}),
    };
    const p = try plan(a, &providers, &.{}, &.{}, &.{}, &.{});
    try testing.expectEqual(@as(usize, 3), p.steps.len);
    const expected = [_][3][]const u8{
        .{ "alpha", "alpha-pkg", "bin/alpha-doctor" },
        .{ "mid", "mid-pkg", "bin/mid-doctor" },
        .{ "zeta", "zeta-pkg", "bin/zeta-doctor" },
    };
    for (expected, p.steps) |want, step| {
        try testing.expectEqualStrings(want[0], step.label);
        try testing.expectEqualStrings(want[1], step.package);
        // The step points at the provider's own `doctor` record, not its first command.
        try testing.expectEqualStrings(want[2], step.action.run.command.executable);
        try testing.expectEqualStrings(want[1], providers[step.action.run.provider].meta.name);
    }
    try testing.expectEqual(@as(usize, 3), p.skipped.len);
    try testing.expectEqualStrings("hooks-only", p.skipped[0]);
    try testing.expectEqualStrings("near", p.skipped[1]);
    try testing.expectEqualStrings("plain", p.skipped[2]);
}

test "provider doctor: one failure still runs the others, in order, and fails the aggregate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const providers = [_]dispatch.Provider{
        fake("c-pkg", "gamma", &.{cmd("doctor", "bin/c")}),
        fake("b-pkg", "beta", &.{cmd("doctor", "bin/b")}),
        fake("a-pkg", "alpha", &.{cmd("doctor", "bin/a")}),
    };
    const p = try plan(a, &providers, &.{}, &.{}, &.{}, &.{});
    var calls: std.ArrayList([]const u8) = .empty;
    // The first one exits non-zero and the second cannot even be built: the
    // third still runs.
    const report = try execute(a, p, Recorder{ .a = a, .calls = &calls, .exit_codes = &.{.{ "alpha", 7 }}, .errors = &.{"beta"} });
    try testing.expectEqual(@as(usize, 3), calls.items.len);
    try testing.expectEqualStrings("alpha:bin/a", calls.items[0]);
    try testing.expectEqualStrings("beta:bin/b", calls.items[1]);
    try testing.expectEqualStrings("gamma:bin/c", calls.items[2]);
    try testing.expectEqual(@as(usize, 2), report.failed());
    try testing.expectEqual(@as(?u8, 7), report.outcomes[0].code);
    try testing.expectEqual(@as(?u8, null), report.outcomes[1].code);
    try testing.expectEqual(@as(?anyerror, error.ProviderCompilerMissing), report.outcomes[1].err);
    try testing.expect(report.outcomes[2].ok());
    try testing.expectEqual(@as(u8, 1), exitCode(true, report));
}

test "provider doctor: the exit code aggregates the core and every provider" {
    const pass = [_]Outcome{ .{ .label = "a", .package = "a", .code = 0 }, .{ .label = "b", .package = "b", .code = 0 } };
    const fail = [_]Outcome{ .{ .label = "a", .package = "a", .code = 0 }, .{ .label = "b", .package = "b", .code = 3 } };
    try testing.expectEqual(@as(u8, 0), exitCode(true, .{ .outcomes = &pass }));
    try testing.expectEqual(@as(u8, 1), exitCode(true, .{ .outcomes = &fail }));
    try testing.expectEqual(@as(u8, 1), exitCode(false, .{ .outcomes = &pass }));
    // Outside a project (or --core-only) only the core decides.
    try testing.expectEqual(@as(u8, 0), exitCode(true, null));
    try testing.expectEqual(@as(u8, 1), exitCode(false, null));
    // No provider doctors at all is not a failure.
    try testing.expectEqual(@as(u8, 0), exitCode(true, .{ .outcomes = &.{} }));
}

test "provider doctor: an unavailable provider is a failed check that runs nothing and stops nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const providers = [_]dispatch.Provider{
        fake("zed", "zed", &.{cmd("doctor", "bin/zed")}),
        fake("able", "able", &.{cmd("doctor", "bin/able")}),
    };
    const unavailable = [_]dispatch.Unavailable{.{ .package = "missing", .err = error.ProviderArchiveMissing }};
    const p = try plan(a, &providers, &unavailable, &.{"missing"}, &.{}, &.{});
    try testing.expectEqual(@as(usize, 3), p.steps.len);
    try testing.expectEqualStrings("missing", p.steps[1].label);
    try testing.expectEqual(@as(anyerror, error.ProviderArchiveMissing), p.steps[1].action.unavailable);
    var calls: std.ArrayList([]const u8) = .empty;
    const report = try execute(a, p, Recorder{ .a = a, .calls = &calls });
    // The runner is never asked to run the unavailable one.
    try testing.expectEqual(@as(usize, 2), calls.items.len);
    try testing.expectEqualStrings("able:bin/able", calls.items[0]);
    try testing.expectEqualStrings("zed:bin/zed", calls.items[1]);
    try testing.expectEqual(@as(usize, 1), report.failed());
    try testing.expect(!report.outcomes[1].ok());
    try testing.expect(fetchable(report.outcomes[1].err.?));
    try testing.expectEqual(@as(u8, 1), exitCode(true, report));
}

test "provider doctor: an unpinned remote package warns uncached, fails as a cached provider, and never runs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var unpinned = fake("remote", "remote-ns", &.{cmd("doctor", "bin/remote")});
    unpinned.verified = false;
    const pinned = fake("local", "local-ns", &.{cmd("doctor", "bin/local")});
    // Warm: its cached (unverified) manifest declares a provider; `survey`
    // reports it in `unverified` and never as a provider.
    const warm = try plan(a, &.{pinned}, &.{}, &.{}, &.{"remote"}, &.{});
    // A discovery that did list it as an unverified provider plans the same.
    const listed = try plan(a, &.{ unpinned, pinned }, &.{}, &.{}, &.{}, &.{});
    try testing.expectEqual(Unverified.cached, listed.steps[1].action.unverified);
    // Cold: nothing to read, only the declaration.
    const cold = try plan(a, &.{pinned}, &.{}, &.{"remote"}, &.{}, &.{});
    const Expect = struct { path: Unverified, failed: usize, warnings: usize, exit: u8 };
    const cases = [_]Expect{
        .{ .path = .cached, .failed = 1, .warnings = 0, .exit = 1 },
        .{ .path = .uncached, .failed = 0, .warnings = 1, .exit = 0 },
    };
    for ([_]Plan{ warm, cold }, cases) |p, want| {
        try testing.expectEqual(@as(usize, 2), p.steps.len);
        const step = p.steps[1];
        try testing.expectEqual(want.path, step.action.unverified);
        try testing.expectEqualStrings("remote", step.label);
        var calls: std.ArrayList([]const u8) = .empty;
        const report = try execute(a, p, Recorder{ .a = a, .calls = &calls });
        // Either way no unverified code runs: only the verified provider does.
        try testing.expectEqual(@as(usize, 1), calls.items.len);
        try testing.expectEqualStrings("local-ns:bin/local", calls.items[0]);
        try testing.expectEqual(want.failed, report.failed());
        try testing.expectEqual(want.warnings, report.warnings());
        // A WARN never changes the exit code; a cached unverified provider fails it.
        try testing.expectEqual(want.exit, exitCode(true, report));
        try testing.expectEqual(@as(u8, 1), exitCode(false, report));
        const outcome = report.outcomes[1];
        try testing.expectEqual(@as(?u8, null), outcome.code);
        try testing.expectEqual(@as(?anyerror, if (want.path == .cached) error.RemoteProviderIntegrityRequired else error.PackageNotInstalled), outcome.err);
    }
}

test "provider doctor: real discovery classifies each unpinned cache state, and bad manifests stay isolated" {
    const asm_cache = @import("asm_cache.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();
    for ([_][]const u8{ "project", "pkg-ok", "pkg-bad" }) |dir| try tmp.dir.createDirPath(io, dir);
    const root = try tmp.dir.realPathFileAlloc(io, "project", a);
    asm_cache.setCacheRootOverride(try tmp.dir.realPathFileAlloc(io, ".", a));
    defer asm_cache.clearCacheRootOverride();
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg-ok/plugin.labelle", .data = ".{ .name = \"pkg-ok\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .namespace = \"ok\", .commands = .{ .{ .name = \"doctor\", .build_step = \"t\", .executable = \"bin/ok\", .help = \"h\" } } }" });
    // A verified (local) provider with a malformed manifest.
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg-bad/plugin.labelle", .data = ".{ .name = \"pkg-bad\", .manifest_version = 2, .command_contract = " });
    const cfg: project.ProjectConfig = .{ .name = "game", .plugins = &.{
        .{ .name = "rem", .repo = "example/rem", .version = "1.0.0" },
        .{ .name = "pkg-bad", .repo = "local:../pkg-bad", .version = "1.0.0" },
        .{ .name = "pkg-ok", .repo = "local:../pkg-ok", .version = "1.0.0" },
    } };
    const cached = try std.fs.path.join(a, &.{ "packages", "plugins", "example", "rem", "1.0.0" });
    const manifest_path = try std.fs.path.join(a, &.{ cached, "plugin.labelle" });
    const State = enum { cold, runtime_only, provider, malformed };
    const Expect = struct { state: State, rem: ?Unverified, failed: usize, warnings: usize };
    const cases = [_]Expect{
        // Not installed: a WARN, the exit code is pkg-bad's alone.
        .{ .state = .cold, .rem = .uncached, .failed = 1, .warnings = 1 },
        // Cached runtime-only: not listed at all.
        .{ .state = .runtime_only, .rem = null, .failed = 1, .warnings = 0 },
        // Cached with provider features: FAIL.
        .{ .state = .provider, .rem = .cached, .failed = 2, .warnings = 0 },
        // Cached but unreadable: cannot be cleared as runtime-only, FAIL.
        .{ .state = .malformed, .rem = .cached, .failed = 2, .warnings = 0 },
    };
    for (cases) |want| {
        switch (want.state) {
            .cold => {},
            .runtime_only => {
                try tmp.dir.createDirPath(io, cached);
                try tmp.dir.writeFile(io, .{ .sub_path = manifest_path, .data = ".{ .name = \"rem\" }" });
            },
            .provider => try tmp.dir.writeFile(io, .{ .sub_path = manifest_path, .data = ".{ .name = \"rem\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .namespace = \"rem\" }" }),
            .malformed => try tmp.dir.writeFile(io, .{ .sub_path = manifest_path, .data = ".{ .name = " }),
        }
        var sources: github.Sources = .{ .a = a };
        defer sources.deinit();
        const found = try dispatch.survey(a, root, cfg, &sources);
        try testing.expectEqual(@as(usize, 1), found.providers.len);
        try testing.expectEqualStrings("pkg-ok", found.providers[0].meta.name);
        try testing.expectEqual(@as(usize, 1), found.unavailable.len);
        try testing.expectEqualStrings("pkg-bad", found.unavailable[0].package);
        const p = try plan(a, found.providers, found.unavailable, found.unresolved, found.unverified, &.{});
        var rem_step: ?Step = null;
        for (p.steps) |step| if (std.mem.eql(u8, step.package, "rem")) {
            rem_step = step;
        };
        if (want.rem) |path| {
            try testing.expectEqual(path, rem_step.?.action.unverified);
        } else try testing.expect(rem_step == null);
        var calls: std.ArrayList([]const u8) = .empty;
        const report = try execute(a, p, Recorder{ .a = a, .calls = &calls });
        // Only the valid provider's doctor ran, in every state.
        try testing.expectEqual(@as(usize, 1), calls.items.len);
        try testing.expectEqualStrings("ok:bin/ok", calls.items[0]);
        try testing.expectEqual(want.failed, report.failed());
        try testing.expectEqual(want.warnings, report.warnings());
    }
}

test "provider doctor: an uncached package the project uses as a provider fails; otherwise it warns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var hooked = fake("hooked", "hooked", &.{});
    hooked.meta.hooks = &.{.{ .id = "h", .step = .build, .target = "desktop", .when = .after, .build_step = "t", .executable = "bin/t", .after_hooks = &.{"by-hook/x"} }};
    // An unverified provider's references are not trusted.
    var untrusted = fake("untrusted", "untrusted", &.{});
    untrusted.verified = false;
    untrusted.meta.hooks = &.{.{ .id = "u", .step = .build, .target = "desktop", .when = .after, .build_step = "t", .executable = "bin/t", .after_hooks = &.{"by-untrusted/x"} }};
    const cfg: project.ProjectConfig = .{ .name = "game", .provider_config = &.{.{ .package = "by-config", .file = "providers/x.json" }} };
    const refs = try providerRefs(a, cfg, &.{ hooked, untrusted });
    try testing.expectEqual(@as(usize, 2), refs.len);
    try testing.expectEqualStrings("by-config", refs[0]);
    try testing.expectEqualStrings("by-hook", refs[1]);

    const p = try plan(a, &.{}, &.{}, &.{ "by-config", "by-hook", "by-untrusted", "plain" }, &.{}, refs);
    const Want = struct { []const u8, Unverified };
    const want = [_]Want{ .{ "by-config", .referenced }, .{ "by-hook", .referenced }, .{ "by-untrusted", .uncached }, .{ "plain", .uncached } };
    for (want, p.steps) |w, step| {
        try testing.expectEqualStrings(w[0], step.label);
        try testing.expectEqual(w[1], step.action.unverified);
    }
    var calls: std.ArrayList([]const u8) = .empty;
    const report = try execute(a, p, Recorder{ .a = a, .calls = &calls });
    try testing.expectEqual(@as(usize, 0), calls.items.len);
    // The two referenced ones fail with the integrity error; the rest warn.
    try testing.expectEqual(@as(usize, 2), report.failed());
    try testing.expectEqual(@as(usize, 2), report.warnings());
    try testing.expectEqual(@as(?anyerror, error.RemoteProviderIntegrityRequired), report.outcomes[0].err);
    try testing.expectEqual(@as(?anyerror, error.RemoteProviderIntegrityRequired), report.outcomes[1].err);
    try testing.expectEqual(@as(u8, 1), exitCode(true, report));
}

test "provider doctor: one host resolution per doctor, failure included, and every provider gets its own failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();
    for ([_][]const u8{ "project", "pkg-a", "pkg-b" }) |dir| try tmp.dir.createDirPath(io, dir);
    const root = try tmp.dir.realPathFileAlloc(io, "project", a);
    for ([_][2][]const u8{ .{ "pkg-a", "a" }, .{ "pkg-b", "b" } }) |pkg| {
        const text = try std.fmt.allocPrint(a, ".{{ .name = \"{s}\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .namespace = \"{s}\", .commands = .{{ .{{ .name = \"doctor\", .build_step = \"t\", .executable = \"bin/t\", .help = \"h\" }} }} }}", .{ pkg[0], pkg[1] });
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ pkg[0], "plugin.labelle" }), .data = text });
    }
    const deps = ".{ .name = \"pkg-a\", .repo = \"local:../pkg-a\", .version = \"1.0.0\" }, .{ .name = \"pkg-b\", .repo = \"local:../pkg-b\", .version = \"1.0.0\" }";
    try tmp.dir.writeFile(io, .{ .sub_path = "project/labelle.lock", .data = ".{ .plugins = .{ " ++ deps ++ " } }" });
    const cfg: project.ProjectConfig = .{ .name = "game", .plugins = &.{
        .{ .name = "pkg-a", .repo = "local:../pkg-a", .version = "1.0.0" },
        .{ .name = "pkg-b", .repo = "local:../pkg-b", .version = "1.0.0" },
    } };
    var sources: github.Sources = .{ .a = a };
    defer sources.deinit();
    const found = try dispatch.survey(a, root, cfg, &sources);
    try testing.expectEqual(@as(usize, 2), found.providers.len);
    const p = try plan(a, found.providers, found.unavailable, found.unresolved, found.unverified, &.{});
    const Offline = struct {
        var calls: usize = 0;
        fn resolve(_: std.mem.Allocator, _: []const u8) anyerror!dispatch.Host {
            calls += 1;
            return error.ProbeOffline;
        }
    };
    var hosts: dispatch.HostCache = .{ .resolve = Offline.resolve };
    // The real runner: pins and settings checked, then the host.
    const report = try execute(a, p, DispatchRunner{ .a = a, .root = root, .cfg = cfg, .providers = found.providers, .hosts = &hosts });
    try testing.expectEqual(@as(usize, 1), Offline.calls);
    try testing.expectEqual(@as(usize, 1), hosts.calls);
    try testing.expectEqual(@as(usize, 2), report.failed());
    for (report.outcomes) |outcome| try testing.expectEqual(@as(?anyerror, error.ProbeOffline), outcome.err);
}
