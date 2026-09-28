//! How a `run` step ended (contract §6), and the run replacement's own
//! report of it: `run.outcome_file` (contract §2 "Run outcome", wire
//! `1.5.0`+, cli#473). A replacement that enforces `--timeout` itself (it
//! stops a simulator app, a dev server) can only exit 0 or not; writing
//! `timeout` to its outcome file before exiting 0 tells the CLI the game
//! did not end cleanly, so the `after run` hooks are skipped exactly as
//! after the CLI's own watchdog. No file is today's behaviour: the exit
//! status alone is the outcome.
const std = @import("std");
const contract = @import("provider_contract.zig");
const manifest = @import("provider_manifest.zig");
const dispatch = @import("provider_dispatch.zig");
const hooks = @import("provider_hooks.zig");
const config = @import("config.zig");

const RunOutcome = hooks.RunOutcome;
const finishRun = hooks.finishRun;

/// The outcome file's name inside its private per-invocation directory.
pub const file_name = "outcome";

/// The largest outcome file read back; anything longer is invalid.
pub const max_file_bytes: usize = 64;

/// Whether `provider` negotiates a wire whose `run` context carries
/// `outcome_file` (`1.5.0`+). An older replacement is never handed one.
pub fn carried(provider: dispatch.Provider) bool {
    const wire = manifest.negotiate(provider.meta.command_contract orelse return false) catch return false;
    return contract.carriesOutcomeContext(wire);
}

/// The outcome an existing outcome file reports: `timeout` (surrounding
/// ASCII whitespace ignored). Anything else, empty included, is invalid.
pub fn parse(bytes: []const u8) error{InvalidOutcomeFile}!RunOutcome {
    const word = std.mem.trim(u8, bytes, &std.ascii.whitespace);
    if (std.mem.eql(u8, word, "timeout")) return .timed_out;
    return error.InvalidOutcomeFile;
}

/// Read back the outcome file a replacement that exited 0 left at `path`:
/// missing is `exited_clean` (it reported nothing); invalid fails the
/// command, naming the hook, before any `after run` hook.
pub fn absorb(site: *hooks.Site, a: std.mem.Allocator, qualified: []const u8, path: []const u8) !RunOutcome {
    const too_long = std.fmt.comptimePrint("the file is longer than the {d}-byte cap", .{max_file_bytes});
    const bytes = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, a, .limited(max_file_bytes + 1)) catch |err| switch (err) {
        error.FileNotFound => return .exited_clean,
        error.StreamTooLong => return reject(site, qualified, too_long),
        else => return err,
    };
    if (bytes.len > max_file_bytes) return reject(site, qualified, too_long);
    return parse(bytes) catch reject(site, qualified, "expected `timeout`");
}

fn reject(site: *hooks.Site, qualified: []const u8, reason: []const u8) error{InvalidRunOutcomeFile} {
    std.debug.print("labelle: run replacement '{s}' wrote an invalid outcome_file: {s}\n", .{ qualified, reason });
    if (site.reporter) |r| r.finishFailed(1, "invalid run outcome_file");
    return error.InvalidRunOutcomeFile;
}

/// Run a `run` replacement and say how the run ended: `exited_error` with
/// its status when it failed (already reported on the progress feed, like
/// any failed hook), otherwise what it reported through `outcome_file`
/// (`exited_clean` when it reported nothing, or cannot: a wire below
/// `1.5.0`). The caller hands any other outcome to `finishRun`.
pub fn runReplacement(site: *hooks.Site, replacement: hooks.Planned, output_dir: []const u8) !RunOutcome {
    var reported: RunOutcome = .exited_clean;
    const code = try hooks.runPhaseReporting(site, &.{replacement}, .run, .replace, output_dir, &reported);
    if (code != 0) return .{ .exited_error = code };
    return reported;
}

// ── Tests ────────────────────────────────────────────────────────────────

test "provider run outcome: the outcome file says `timeout` or is invalid" {
    for ([_][]const u8{ "timeout", "timeout\n", " timeout\r\n", "\x0btimeout\x0c" }) |text| {
        try std.testing.expectEqual(RunOutcome.timed_out, try parse(text));
    }
    for ([_][]const u8{ "", "\n", "TIMEOUT", "timeout now", "clean", "crash" }) |text| {
        try std.testing.expectError(error.InvalidOutcomeFile, parse(text));
    }
}

const Fixture = struct {
    fn hook(id: []const u8, step: contract.Step, target: []const u8, when: contract.Phase) manifest.Hook {
        return .{ .id = id, .step = step, .target = target, .when = when, .build_step = "tool", .executable = "bin/tool" };
    }
    fn provider(name: []const u8, targets: []const []const u8, hook_list: []const manifest.Hook) dispatch.Provider {
        return .{
            .dep = .{ .name = name, .repo = "local:../x", .version = "1.0.0" },
            .dir = "/x",
            .meta = .{ .name = name, .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0", .hooks = hook_list, .targets = targets },
            .verified = true,
        };
    }
};

/// A replacement stand-in: records the `outcome_file` it was handed (and
/// that its directory existed while the file did not), writes `write`
/// there when set, and exits `code`. An `after` hook is only counted.
const Spy = struct {
    var write: ?[]const u8 = null;
    var code: u8 = 0;
    var handed: [std.fs.max_path_bytes]u8 = undefined;
    var handed_len: ?usize = null;
    var replaced: usize = 0;
    var after: usize = 0;

    fn reset(write_: ?[]const u8, code_: u8) void {
        write = write_;
        code = code_;
        handed_len = null;
        replaced = 0;
        after = 0;
    }

    fn handedPath() ?[]const u8 {
        return if (handed_len) |len| handed[0..len] else null;
    }

    fn run(_: std.mem.Allocator, _: dispatch.Host, _: []const u8, _: dispatch.Provider, _: contract.Tool, tool_run: dispatch.ToolRun) anyerror!u8 {
        const io = config.globalIo();
        if (tool_run.invocation.phase == .after) {
            after += 1;
            return 0;
        }
        replaced += 1;
        const path = tool_run.run_options.?.outcome_file orelse return code;
        @memcpy(handed[0..path.len], path);
        handed_len = path.len;
        try std.Io.Dir.cwd().access(io, std.fs.path.dirname(path).?, .{});
        // The file does not exist when the replacement starts.
        if (std.Io.Dir.cwd().access(io, path, .{})) |_| return error.OutcomeFilePreexisting else |_| {}
        if (write) |text| try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
        return code;
    }
};

test "provider run outcome: the wire context carries outcome_file from 1.5.0 only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const abs = if (@import("builtin").os.tag == .windows) "C:\\proj" else "/proj";
    const run: dispatch.ToolRun = .{
        .invocation = .{ .kind = .hook, .id = "deploy", .step = .run, .phase = .replace },
        .needs_project = true,
        .target = "probe-target",
        .lock_file = try std.fs.path.join(a, &.{ abs, "labelle.lock" }),
        .output_dir = try std.fs.path.join(a, &.{ abs, "zig-out" }),
        .optimize = .Debug,
        .progress = .off,
        .settings = null,
        .trailing = &.{},
        .cwd = abs,
        .target_dir = try std.fs.path.join(a, &.{ abs, ".labelle", "probe_probe-target" }),
        .final_step = .run,
        .run_options = .{ .env = &.{}, .args = &.{}, .timeout_ms = 1500, .outcome_file = try std.fs.path.join(a, &.{ abs, "outcome" }) },
    };
    const host: dispatch.Host = .{ .zig = try std.fs.path.join(a, &.{ abs, "zig" }), .cache_root = abs, .global_cache = abs, .packages = abs };
    const cache = try std.fs.path.join(a, &.{ abs, "cache" });
    var provider = Fixture.provider("pkg", &.{"probe-target"}, &.{});
    provider.dir = try std.fs.path.join(a, &.{ abs, "pkg" });
    const open = try dispatch.wireContext(provider, host, abs, run, cache);
    try open.validate(true);
    try std.testing.expectEqualStrings("1.5.0", open.contract_version);
    try std.testing.expectEqualStrings(run.run_options.?.outcome_file.?, open.run.?.outcome_file.?);
    try std.testing.expect(carried(provider));
    // Capped below 1.5.0: the run options without `outcome_file`.
    provider.meta.command_contract = ">=1.0.0 <1.5.0";
    try std.testing.expect(!carried(provider));
    const capped = try dispatch.wireContext(provider, host, abs, run, cache);
    try capped.validate(true);
    try std.testing.expectEqualStrings("1.4.0", capped.contract_version);
    try std.testing.expect(capped.run.?.outcome_file == null and capped.run.?.timeout_ms.? == 1500);
    try std.testing.expect(std.mem.indexOf(u8, try std.json.Stringify.valueAlloc(a, capped, .{}), "outcome_file") == null);
}

/// Whether the private directory of the outcome file at `path` is gone.
fn removed(path: []const u8) bool {
    std.Io.Dir.cwd().access(config.globalIo(), std.fs.path.dirname(path).?, .{}) catch return true;
    return false;
}

test "provider run outcome: a replacement's reported timeout skips the after-run hooks; a clean exit runs them" {
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(io, "project");
    const root = try tmp.dir.realPathFileAlloc(io, "project", a);
    try tmp.dir.writeFile(io, .{
        .sub_path = "project/labelle.lock",
        .data = ".{ .plugins = .{ .{ .name = \"pkg\", .repo = \"local:../x\", .version = \"1.0.0\" } } }",
    });
    var provider = Fixture.provider("pkg", &.{"probe-target"}, &.{
        Fixture.hook("deploy", .run, "probe-target", .replace),
        Fixture.hook("publish", .run, "probe-target", .after),
    });
    const replacement: hooks.Planned = .{ .provider = &provider, .hook = provider.meta.hooks[0], .qualified = "pkg/deploy" };
    const after: hooks.Planned = .{ .provider = &provider, .hook = provider.meta.hooks[1], .qualified = "pkg/publish" };
    var site: hooks.Site = .{
        .a = a,
        .backing = std.testing.allocator,
        .providers = &.{provider},
        .root = root,
        .cfg = .{ .name = "game" },
        .target = "probe-target",
        .target_dir = root,
        .final_step = .run,
        .run_options = .{ .env = &.{}, .args = &.{}, .timeout_ms = 500 },
        .optimize = .Debug,
        .progress = .off,
        .reporter = null,
        .host = .{ .zig = "/z", .cache_root = root, .global_cache = root, .packages = root },
        .run_tool = Spy.run,
    };
    const out = try std.fs.path.join(a, &.{ root, "zig-out" });

    // Reported `timeout`, exit 0: timed out, status 0, after hooks skipped.
    Spy.reset("timeout\n", 0);
    const timed_out = try runReplacement(&site, replacement, out);
    try std.testing.expectEqual(RunOutcome.timed_out, timed_out);
    try std.testing.expectEqualStrings(file_name, std.fs.path.basename(Spy.handedPath().?));
    try std.testing.expect(removed(Spy.handedPath().?));
    try std.testing.expectEqual(@as(u8, 0), try finishRun(&site, &.{after}, out, timed_out));
    try std.testing.expectEqual(@as(usize, 0), Spy.after);

    // Nothing reported, exit 0: clean, and the after hooks run.
    Spy.reset(null, 0);
    const clean = try runReplacement(&site, replacement, out);
    try std.testing.expectEqual(RunOutcome.exited_clean, clean);
    try std.testing.expect(removed(Spy.handedPath().?));
    try std.testing.expectEqual(@as(u8, 0), try finishRun(&site, &.{after}, out, clean));
    try std.testing.expectEqual(@as(usize, 1), Spy.after);

    // A failed replacement's report is ignored: its status is the outcome
    // (the caller returns it; no after hook runs).
    Spy.reset("timeout", 3);
    try std.testing.expectEqual(RunOutcome{ .exited_error = 3 }, try runReplacement(&site, replacement, out));
    try std.testing.expect(removed(Spy.handedPath().?));

    // Anything but `timeout` fails the run before any after hook.
    Spy.reset("finished", 0);
    try std.testing.expectError(error.InvalidRunOutcomeFile, runReplacement(&site, replacement, out));
    try std.testing.expect(removed(Spy.handedPath().?));
    Spy.reset("", 0);
    try std.testing.expectError(error.InvalidRunOutcomeFile, runReplacement(&site, replacement, out));

    // The plain phase runner never hands one out (nothing would read it).
    Spy.reset("timeout", 0);
    try std.testing.expectEqual(@as(u8, 0), try hooks.runPhase(&site, &.{replacement}, .run, .replace, out));
    try std.testing.expect(Spy.replaced == 1 and Spy.handedPath() == null);

    // A provider below wire 1.5.0 gets none: its exit status alone decides,
    // so its after hooks run after exit 0 as before (the additive gate).
    provider.meta.command_contract = ">=1.0.0 <1.5.0";
    Spy.reset("timeout", 0);
    const legacy = try runReplacement(&site, replacement, out);
    try std.testing.expect(Spy.replaced == 1 and Spy.handedPath() == null);
    try std.testing.expectEqual(RunOutcome.exited_clean, legacy);
    try std.testing.expectEqual(@as(u8, 0), try finishRun(&site, &.{after}, out, legacy));
    try std.testing.expectEqual(@as(usize, 1), Spy.after);
}
