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
//! `labelle providers fetch` hint; the doctor never downloads. Projectless
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
    };
};

pub const Plan = struct {
    steps: []const Step,
    /// Providers that declare no `doctor` command, by package name, sorted.
    skipped: []const []const u8,
};

/// Which provider doctors run, and in what order: every provider with a
/// namespace and a command named exactly `doctor`, plus every provider that
/// could not be read (a failed check), sorted by label. Declaration order in
/// `project.labelle` does not matter.
pub fn plan(a: std.mem.Allocator, providers: []const dispatch.Provider, unavailable: []const dispatch.Unavailable) !Plan {
    var steps: std.ArrayList(Step) = .empty;
    var skipped: std.ArrayList([]const u8) = .empty;
    for (providers, 0..) |provider, index| {
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

    pub fn ok(self: Outcome) bool {
        return self.code == 0;
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
};

/// Run every step with `runner.run(step) anyerror!u8`, one after another,
/// whatever the previous ones returned. Prints a header per provider and
/// its result line to stderr.
pub fn execute(a: std.mem.Allocator, p: Plan, runner: anytype) !Report {
    var outcomes: std.ArrayList(Outcome) = .empty;
    for (p.steps) |step| {
        printHeader(step);
        const outcome: Outcome = switch (step.action) {
            .unavailable => |err| blk: {
                std.debug.print("  [ FAIL ] provider source unavailable: {s}\n", .{@errorName(err)});
                if (fetchable(err)) std.debug.print("           -> run `labelle providers fetch` to download the pinned archives\n", .{});
                break :blk .{ .label = step.label, .package = step.package, .code = null, .err = err };
            },
            .run => if (runner.run(step)) |code|
                .{ .label = step.label, .package = step.package, .code = code }
            else |err|
                .{ .label = step.label, .package = step.package, .code = null, .err = err },
        };
        switch (step.action) {
            .unavailable => {},
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
    }
    std.debug.print("------------------------------------------------------------\n", .{});
}

/// The closing summary of the provider part.
pub fn printSummary(report: Report) void {
    std.debug.print("\nProvider doctors: {d} checked, {d} failed", .{ report.outcomes.len, report.failed() });
    if (report.failed() != 0) {
        std.debug.print(" (", .{});
        var first = true;
        for (report.outcomes) |outcome| {
            if (outcome.ok()) continue;
            std.debug.print("{s}{s}", .{ if (first) "" else ", ", outcome.label });
            first = false;
        }
        std.debug.print(")", .{});
    }
    std.debug.print("\n", .{});
    if (report.skipped.len != 0) {
        std.debug.print("  no `{s}` command: ", .{command_name});
        for (report.skipped, 0..) |name, i| std.debug.print("{s}{s}", .{ if (i == 0) "" else ", ", name });
        std.debug.print("\n", .{});
    }
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

    pub fn run(self: DispatchRunner, step: Step) anyerror!u8 {
        const action = step.action.run;
        return dispatch.runCommand(self.a, self.root, self.cfg, self.providers, self.providers[action.provider], action.command, &.{});
    }
};

/// The provider part of `labelle doctor` for the project at or above
/// `start`, or null outside a project (after saying so).
pub fn runForProject(allocator: std.mem.Allocator, start: []const u8) !?Report {
    // The report outlives this call; its strings live in `allocator`'s arena
    // owned by the caller.
    const a = allocator;
    const root = (dispatch.projectRootFrom(a, start) catch null) orelse {
        std.debug.print("  Provider doctors run inside a project; no project.labelle at or above '{s}'.\n", .{start});
        return null;
    };
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
    const p = try plan(a, discovered.survey.providers, discovered.survey.unavailable);
    if (p.steps.len == 0 and p.skipped.len == 0) {
        std.debug.print("  No providers pinned in this project.\n", .{});
        return .{ .outcomes = &.{} };
    }
    const report = try execute(a, p, DispatchRunner{
        .a = a,
        .root = root,
        .cfg = discovered.cfg,
        .providers = discovered.survey.providers,
    });
    printSummary(report);
    return report;
}

const Discovered = struct { cfg: project.ProjectConfig, survey: dispatch.Survey };

fn discover(a: std.mem.Allocator, root: []const u8, sources: *github.Sources) !Discovered {
    var cfg = try config.readProjectConfigQuiet(a, root);
    const found = try dispatch.survey(a, root, cfg, sources);
    // A settings entry for a provider that could not be read is already a
    // failed check of its own; it must not also fail every other provider's
    // settings resolution (which requires each entry to name a resolved
    // provider).
    var entries: std.ArrayList(@import("provider_settings.zig").Entry) = .empty;
    for (cfg.provider_config) |entry| {
        if (!named(found.unresolved, entry.package)) try entries.append(a, entry);
    }
    cfg.provider_config = entries.items;
    return .{ .cfg = cfg, .survey = found };
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

    pub fn run(self: Recorder, step: Step) anyerror!u8 {
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
    const p = try plan(a, &providers, &.{});
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
    const p = try plan(a, &providers, &.{});
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
    const p = try plan(a, &providers, &unavailable);
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
