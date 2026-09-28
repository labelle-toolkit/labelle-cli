//! Tests of running hook phases (`provider_hooks.runPhase` and the
//! run/serve finishers): the scratch arena, the context each hook gets,
//! after-run gating and the progress feed.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("provider_contract.zig");
const manifest = @import("provider_manifest.zig");
const dispatch = @import("provider_dispatch.zig");
const progress = @import("progress.zig");
const hooks = @import("provider_hooks.zig");
const Site = hooks.Site;
const Planned = hooks.Planned;
const RunOutcome = hooks.RunOutcome;
const runPhase = hooks.runPhase;
const runBefore = hooks.runBefore;
const finishRun = hooks.finishRun;
const finishServe = hooks.finishServe;

const Fixture = struct {
    fn hook(id: []const u8, step: contract.Step, target: []const u8, when: contract.Phase, after: []const []const u8) manifest.Hook {
        return .{ .id = id, .step = step, .target = target, .when = when, .build_step = "tool", .executable = "bin/tool", .after_hooks = after };
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
        .target_dir = root,
        .optimize = .Debug,
        .progress = .off,
        .reporter = null,
        .final_step = .build,
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

test "provider hooks: every hook gets the target dir; only run-step hooks get the run options" {
    const io = @import("config.zig").globalIo();
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
    const Spy = struct {
        var target_dir: [std.fs.max_path_bytes]u8 = undefined;
        var target_dir_len: usize = 0;
        var run_options: ?contract.RunContext = null;
        var scene: [32]u8 = undefined;
        var calls: usize = 0;
        fn run(_: std.mem.Allocator, _: dispatch.Host, _: []const u8, _: dispatch.Provider, _: contract.Tool, tool_run: dispatch.ToolRun) anyerror!u8 {
            calls += 1;
            const dir = tool_run.target_dir.?;
            @memcpy(target_dir[0..dir.len], dir);
            target_dir_len = dir.len;
            run_options = tool_run.run_options;
            if (tool_run.run_options) |options| {
                if (options.env.len != 0) @memcpy(scene[0..options.env[0].value.len], options.env[0].value);
            }
            return 0;
        }
    };
    const provider = Fixture.provider("pkg", &.{}, &.{Fixture.hook("h", .build, "desktop", .after, &.{})});
    const planned: Planned = .{ .provider = &provider, .hook = provider.meta.hooks[0], .qualified = "pkg/h" };
    // Not yet created: the phase creates and canonicalises it.
    const target_dir = try std.fs.path.join(a, &.{ root, ".labelle", "probe_desktop" });
    const env = [_]contract.RunEnv{.{ .name = "LABELLE_SCENE", .value = "intro" }};
    var site: Site = .{
        .a = a,
        .backing = std.testing.allocator,
        .providers = &.{provider},
        .root = root,
        .cfg = .{ .name = "game" },
        .target = "desktop",
        .target_dir = target_dir,
        .run_options = .{ .env = &env, .args = &.{"a"}, .timeout_ms = null },
        .optimize = .Debug,
        .progress = .off,
        .reporter = null,
        .final_step = .build,
        .host = .{ .zig = "/z", .cache_root = root, .global_cache = root, .packages = root },
        .run_tool = Spy.run,
    };
    const elsewhere = try std.fs.path.join(a, &.{ root, "elsewhere" });
    for ([_]contract.Step{ .generate, .build, .bundle }) |step| {
        try std.testing.expectEqual(@as(u8, 0), try runPhase(&site, &.{planned}, step, .after, elsewhere));
        // The target dir, not the (different) output dir, and never the
        // run options off the run step.
        try std.testing.expectEqualStrings(target_dir, Spy.target_dir[0..Spy.target_dir_len]);
        try std.testing.expect(Spy.run_options == null);
    }
    try std.testing.expectEqual(@as(u8, 0), try runPhase(&site, &.{planned}, .run, .replace, elsewhere));
    try std.testing.expectEqualStrings("intro", Spy.scene[0..5]);
    try std.testing.expectEqual(@as(usize, 1), Spy.run_options.?.args.len);
    // A run step with no options set (a legacy serve): the empty set, never
    // an absent key, so a 1.2.0 run hook always finds it.
    site.run_options = null;
    try std.testing.expectEqual(@as(u8, 0), try runPhase(&site, &.{planned}, .run, .before, elsewhere));
    try std.testing.expect(Spy.run_options != null and !Spy.run_options.?.given());
    try std.testing.expectEqual(@as(usize, 5), Spy.calls);
}

test "provider hooks: every hook of a phase gets the site's final step, whatever its own step" {
    const io = @import("config.zig").globalIo();
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
    const Spy = struct {
        var seen: [8]?contract.Step = undefined;
        var calls: usize = 0;
        fn run(_: std.mem.Allocator, _: dispatch.Host, _: []const u8, _: dispatch.Provider, _: contract.Tool, tool_run: dispatch.ToolRun) anyerror!u8 {
            seen[calls] = tool_run.final_step;
            calls += 1;
            return 0;
        }
    };
    const provider = Fixture.provider("pkg", &.{}, &.{Fixture.hook("h", .build, "desktop", .after, &.{})});
    const planned: Planned = .{ .provider = &provider, .hook = provider.meta.hooks[0], .qualified = "pkg/h" };
    var site: Site = .{
        .a = a,
        .backing = std.testing.allocator,
        .providers = &.{provider},
        .root = root,
        .cfg = .{ .name = "game" },
        .target = "desktop",
        .target_dir = root,
        .optimize = .Debug,
        .progress = .off,
        .reporter = null,
        // `labelle bundle`: the build hooks as well as the bundle hooks
        // learn that a bundle step follows (cli#443).
        .final_step = .bundle,
        .host = .{ .zig = "/z", .cache_root = root, .global_cache = root, .packages = root },
        .run_tool = Spy.run,
    };
    const out = try std.fs.path.join(a, &.{ root, "zig-out" });
    for ([_]contract.Step{ .generate, .build, .bundle }) |step| {
        try std.testing.expectEqual(@as(u8, 0), try runPhase(&site, &.{planned}, step, .after, out));
    }
    try std.testing.expectEqual(@as(usize, 3), Spy.calls);
    for (Spy.seen[0..3]) |final| try std.testing.expectEqual(@as(?contract.Step, .bundle), final);
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
        .target_dir = root,
        .optimize = .Debug,
        .progress = .off,
        .reporter = null,
        .final_step = .build,
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
            .target_dir = self.dir,
            .optimize = .Debug,
            .progress = .off,
            .final_step = .build,
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
