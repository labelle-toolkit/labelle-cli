//! `provider_hooks.runPhase`'s environment contributions (contract §2,
//! wire `1.3.0`+): which hooks receive an `env_file`, what the phase does
//! with what they wrote, and that later hooks see the merge.
const std = @import("std");
const config = @import("config.zig");
const contract = @import("provider_contract.zig");
const dispatch = @import("provider_dispatch.zig");
const hooks = @import("provider_hooks.zig");
const manifest = @import("provider_manifest.zig");

const Spy = struct {
    /// What each invocation writes to its env_file, by hook id; null writes
    /// nothing.
    var writes: []const struct { id: []const u8, bytes: []const u8, code: u8 = 0 } = &.{};
    var seen_env_file: [8]bool = undefined;
    var seen_probe: [8]?[16]u8 = undefined;
    var calls: usize = 0;
    var env_dirs: [8][std.fs.max_path_bytes]u8 = undefined;
    var env_dir_lens: [8]usize = undefined;

    fn run(a: std.mem.Allocator, _: dispatch.Host, _: []const u8, _: dispatch.Provider, _: contract.Tool, tool_run: dispatch.ToolRun) anyerror!u8 {
        const i = calls;
        calls += 1;
        seen_env_file[i] = tool_run.env_file != null;
        // What the hook's own process would see: the contributions so far.
        seen_probe[i] = null;
        if (tool_run.env) |env| {
            var map = std.process.Environ.Map.init(a);
            defer map.deinit();
            try env.apply(&map);
            if (map.get("PROBE_VAR")) |value| {
                var buf: [16]u8 = @splat(0);
                @memcpy(buf[0..value.len], value);
                seen_probe[i] = buf;
            }
        }
        const id = tool_run.invocation.id;
        for (writes) |w| {
            if (!std.mem.eql(u8, w.id, id)) continue;
            const path = tool_run.env_file orelse return error.TestUnexpectedResult;
            const dir = std.fs.path.dirname(path).?;
            @memcpy(env_dirs[i][0..dir.len], dir);
            env_dir_lens[i] = dir.len;
            // The file does not exist before the hook writes it.
            try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(config.globalIo(), path, .{}));
            try std.Io.Dir.cwd().writeFile(config.globalIo(), .{ .sub_path = path, .data = w.bytes });
            return w.code;
        }
        return 0;
    }

    fn probe(i: usize) ?[]const u8 {
        const buf = &(seen_probe[i] orelse return null);
        return std.mem.sliceTo(buf, 0);
    }
};

const Harness = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8,
    provider: dispatch.Provider,
    site: hooks.Site,

    fn init(self: *Harness, hook_list: []const manifest.Hook) !void {
        const io = config.globalIo();
        self.tmp = std.testing.tmpDir(.{});
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const a = self.arena.allocator();
        try self.tmp.dir.createDirPath(io, "project");
        self.root = try self.tmp.dir.realPathFileAlloc(io, "project", a);
        try self.tmp.dir.writeFile(io, .{
            .sub_path = "project/labelle.lock",
            .data = ".{ .plugins = .{ .{ .name = \"pkg\", .repo = \"local:../x\", .version = \"1.0.0\" } } }",
        });
        self.provider = .{
            .dep = .{ .name = "pkg", .repo = "local:../x", .version = "1.0.0" },
            .dir = "/x",
            .meta = .{ .name = "pkg", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0", .hooks = hook_list },
            .verified = true,
        };
        self.site = .{
            .a = a,
            .backing = std.testing.allocator,
            .providers = (&self.provider)[0..1],
            .root = self.root,
            .cfg = .{ .name = "game" },
            .target = "desktop",
            .target_dir = self.root,
            .optimize = .Debug,
            .progress = .off,
            .reporter = null,
            .final_step = .build,
            .host = .{ .zig = "/z", .cache_root = self.root, .global_cache = self.root, .packages = self.root },
            .run_tool = Spy.run,
        };
        Spy.calls = 0;
    }

    fn deinit(self: *Harness) void {
        self.site.env.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn planned(self: *Harness, i: usize) hooks.Planned {
        const entry = self.provider.meta.hooks[i];
        return .{ .provider = &self.provider, .hook = entry, .qualified = std.fmt.allocPrint(self.arena.allocator(), "pkg/{s}", .{entry.id}) catch unreachable };
    }

    fn out(self: *Harness) []const u8 {
        return self.root;
    }

    /// Nothing is left under `provider-env/`: every per-invocation
    /// directory was removed.
    fn envDirsGone(self: *Harness) !void {
        const io = config.globalIo();
        var dir = self.tmp.dir.openDir(io, "project/provider-env", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(io);
        var it = dir.iterate();
        try std.testing.expect((try it.next(io)) == null);
    }
};

fn hook(id: []const u8, step: contract.Step, when: contract.Phase) manifest.Hook {
    return .{ .id = id, .step = step, .target = "desktop", .when = when, .build_step = "tool", .executable = "bin/tool" };
}

test "provider hooks env: only the contributing slots get an env_file, and later hooks see the merge" {
    const list = [_]manifest.Hook{ hook("first", .generate, .before), hook("second", .generate, .before), hook("stamp", .build, .after) };
    var h: Harness = undefined;
    try h.init(&list);
    defer h.deinit();
    Spy.writes = &.{.{ .id = "first", .bytes = "{\"set\":[{\"name\":\"PROBE_VAR\",\"value\":\"from-first\"}]}" }};
    try std.testing.expectEqual(@as(u8, 0), try hooks.runPhase(&h.site, &.{ h.planned(0), h.planned(1) }, .generate, .before, h.out()));
    try std.testing.expect(Spy.seen_env_file[0] and Spy.seen_env_file[1]);
    // The first hook ran before any contribution; the second saw it.
    try std.testing.expect(Spy.probe(0) == null);
    try std.testing.expectEqualStrings("from-first", Spy.probe(1).?);
    // `after build` gets no env_file but runs with the merged environment.
    try std.testing.expectEqual(@as(u8, 0), try hooks.runPhase(&h.site, &.{h.planned(2)}, .build, .after, h.out()));
    try std.testing.expect(!Spy.seen_env_file[2]);
    try std.testing.expectEqualStrings("from-first", Spy.probe(2).?);
    try std.testing.expectEqual(@as(usize, 1), h.site.env.vars.items.len);
    try std.testing.expectEqualStrings("pkg/first", h.site.env.vars.items[0].hook);
    try h.envDirsGone();
    // A fresh build forgets it (the watched rebuild's reset).
    h.site.env.reset();
    try std.testing.expectEqual(@as(u8, 0), try hooks.runPhase(&h.site, &.{h.planned(2)}, .build, .after, h.out()));
    try std.testing.expect(Spy.probe(3) == null);
}

test "provider hooks env: a failed hook's file is ignored; a malformed or conflicting one stops the phase" {
    const list = [_]manifest.Hook{ hook("a", .build, .before), hook("b", .build, .before) };
    var h: Harness = undefined;
    try h.init(&list);
    defer h.deinit();
    // Written by a hook that then failed: the hook's exit code is the
    // outcome and nothing is merged.
    Spy.writes = &.{.{ .id = "a", .bytes = "{\"set\":[{\"name\":\"PROBE_VAR\",\"value\":\"x\"}]}", .code = 7 }};
    try std.testing.expectEqual(@as(u8, 7), try hooks.runPhase(&h.site, &.{h.planned(0)}, .build, .before, h.out()));
    try std.testing.expect(h.site.env.isEmpty());
    // Malformed and empty files fail the phase, before any later hook.
    for ([_][]const u8{ "{not json", "", "{\"set\":[{\"name\":\"PATH\",\"value\":\"/x\"}]}" }) |bytes| {
        Spy.calls = 0;
        Spy.writes = &.{.{ .id = "a", .bytes = bytes }};
        try std.testing.expectError(error.InvalidHookEnvFile, hooks.runPhase(&h.site, &.{ h.planned(0), h.planned(1) }, .build, .before, h.out()));
        try std.testing.expectEqual(@as(usize, 1), Spy.calls);
    }
    // A file over the size cap is an invalid file too (the cap is lowered
    // here; production reads up to `provider_env.max_file_bytes`).
    Spy.calls = 0;
    Spy.writes = &.{.{ .id = "a", .bytes = "{\"set\":[{\"name\":\"PROBE_VAR\",\"value\":\"x\"}]}" }};
    h.site.env_file_cap = 8;
    try std.testing.expectError(error.InvalidHookEnvFile, hooks.runPhase(&h.site, &.{ h.planned(0), h.planned(1) }, .build, .before, h.out()));
    try std.testing.expectEqual(@as(usize, 1), Spy.calls);
    try std.testing.expect(h.site.env.isEmpty());
    // The same file under the cap is accepted: the cap is what refused it.
    h.site.env_file_cap = @import("provider_env.zig").max_file_bytes;
    try std.testing.expectEqual(@as(u8, 0), try hooks.runPhase(&h.site, &.{h.planned(0)}, .build, .before, h.out()));
    try std.testing.expect(!h.site.env.isEmpty());
    h.site.env.reset();
    // Two hooks disagreeing on a name: a conflict naming both.
    Spy.calls = 0;
    Spy.writes = &.{
        .{ .id = "a", .bytes = "{\"set\":[{\"name\":\"PROBE_VAR\",\"value\":\"one\"}]}" },
        .{ .id = "b", .bytes = "{\"set\":[{\"name\":\"PROBE_VAR\",\"value\":\"two\"}]}" },
    };
    try std.testing.expectError(error.HookEnvConflict, hooks.runPhase(&h.site, &.{ h.planned(0), h.planned(1) }, .build, .before, h.out()));
    // Agreeing is fine.
    h.site.env.reset();
    Spy.writes = &.{
        .{ .id = "a", .bytes = "{\"set\":[{\"name\":\"PROBE_VAR\",\"value\":\"one\"}]}" },
        .{ .id = "b", .bytes = "{\"set\":[{\"name\":\"PROBE_VAR\",\"value\":\"one\"}]}" },
    };
    try std.testing.expectEqual(@as(u8, 0), try hooks.runPhase(&h.site, &.{ h.planned(0), h.planned(1) }, .build, .before, h.out()));
    try h.envDirsGone();
}

test "provider hooks env: the contributing hook of a plan is found by slot and negotiated wire" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = [_]manifest.Hook{ hook("gen", .generate, .before), hook("stamp", .build, .after), hook("pre", .build, .before) };
    var provider: dispatch.Provider = .{
        .dep = .{ .name = "pkg", .repo = "local:../x", .version = "1.0.0" },
        .dir = "/x",
        .meta = .{ .name = "pkg", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0", .hooks = &list },
        .verified = true,
    };
    const providers = [_]dispatch.Provider{provider};
    _ = &providers;
    const plan_for = struct {
        fn get(al: std.mem.Allocator, p: *const dispatch.Provider, step: contract.Step) !hooks.Plan {
            return hooks.plan(al, p[0..1], step, "desktop");
        }
    }.get;
    // A before-generate hook on an open range can contribute.
    try std.testing.expectEqualStrings("pkg/gen", hooks.planContributor(try plan_for(a, &provider, .generate), try plan_for(a, &provider, .build)).?.qualified);
    // Only an after-build hook: no contributing slot.
    const after_only = [_]manifest.Hook{hook("stamp", .build, .after)};
    provider.meta.hooks = &after_only;
    try std.testing.expect(hooks.planContributor(try plan_for(a, &provider, .generate), try plan_for(a, &provider, .build)) == null);
    // A contributing slot on a provider capped below 1.3.0 has no env_file.
    provider.meta.hooks = &list;
    provider.meta.command_contract = "<1.3.0";
    try std.testing.expect(hooks.planContributor(try plan_for(a, &provider, .generate), try plan_for(a, &provider, .build)) == null);
}

test "provider hooks env: build_options come only from the target owner's before generate/build hooks on wire 1.6.0+" {
    const list = [_]manifest.Hook{ hook("gen", .generate, .before), hook("post", .generate, .after), hook("pre", .build, .before) };
    var h: Harness = undefined;
    try h.init(&list);
    defer h.deinit();
    const opts = "{\"build_options\":[{\"name\":\"device\",\"value\":\"true\"}]}";
    // Not the owner of `desktop`: refused, even though the wire and slot fit.
    Spy.writes = &.{.{ .id = "gen", .bytes = opts }};
    try std.testing.expectError(error.InvalidHookEnvFile, hooks.runPhase(&h.site, &.{h.planned(0)}, .generate, .before, h.out()));
    try std.testing.expect(h.site.env.isEmpty());
    // An empty list is the key all the same.
    Spy.writes = &.{.{ .id = "gen", .bytes = "{\"build_options\":[]}" }};
    try std.testing.expectError(error.InvalidHookEnvFile, hooks.runPhase(&h.site, &.{h.planned(0)}, .generate, .before, h.out()));
    // The owner, in `before generate` and `before build`: accepted, in hook order.
    h.provider.meta.targets = &.{"desktop"};
    Spy.writes = &.{
        .{ .id = "gen", .bytes = opts },
        .{ .id = "pre", .bytes = "{\"set\":[{\"name\":\"PROBE_VAR\",\"value\":\"v\"}],\"build_options\":[{\"name\":\"sdk\",\"value\":\"probe-device\"}]}" },
    };
    try std.testing.expectEqual(@as(u8, 0), try hooks.runPhase(&h.site, &.{h.planned(0)}, .generate, .before, h.out()));
    try std.testing.expectEqual(@as(u8, 0), try hooks.runPhase(&h.site, &.{h.planned(2)}, .build, .before, h.out()));
    try std.testing.expectEqual(@as(usize, 2), h.site.env.options.items.len);
    try std.testing.expectEqualStrings("pkg/gen", h.site.env.options.items[0].hook);
    try std.testing.expectEqualStrings("sdk", h.site.env.options.items[1].name);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diag: @import("provider_env.zig").Diagnostic = .{};
    const argv = try h.site.env.zigArgs(arena.allocator(), &.{ "zig", "build", "-Doptimize=Debug" }, &diag);
    try std.testing.expectEqual(@as(usize, 5), argv.len);
    try std.testing.expectEqualStrings("-Ddevice=true", argv[3]);
    try std.testing.expectEqualStrings("-Dsdk=probe-device", argv[4]);
    h.site.env.reset();
    // `after generate` may contribute an environment, never build options.
    Spy.writes = &.{.{ .id = "post", .bytes = opts }};
    try std.testing.expectError(error.InvalidHookEnvFile, hooks.runPhase(&h.site, &.{h.planned(1)}, .generate, .after, h.out()));
    Spy.writes = &.{.{ .id = "post", .bytes = "{\"set\":[{\"name\":\"PROBE_VAR\",\"value\":\"v\"}]}" }};
    try std.testing.expectEqual(@as(u8, 0), try hooks.runPhase(&h.site, &.{h.planned(1)}, .generate, .after, h.out()));
    h.site.env.reset();
    // The owner on a 1.5.0 wire: the key doesn't exist there.
    h.provider.meta.command_contract = ">=1.3.0 <1.6.0";
    Spy.writes = &.{.{ .id = "gen", .bytes = opts }};
    try std.testing.expectError(error.InvalidHookEnvFile, hooks.runPhase(&h.site, &.{h.planned(0)}, .generate, .before, h.out()));
    try std.testing.expect(h.site.env.isEmpty());
    // Its plain environment still merges.
    Spy.writes = &.{.{ .id = "gen", .bytes = "{\"set\":[{\"name\":\"PROBE_VAR\",\"value\":\"v\"}]}" }};
    try std.testing.expectEqual(@as(u8, 0), try hooks.runPhase(&h.site, &.{h.planned(0)}, .generate, .before, h.out()));
    try h.envDirsGone();
}
