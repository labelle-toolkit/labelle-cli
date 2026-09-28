//! Tests of `provider_dispatch`: the wire context each invocation gets,
//! lock and workspace checks, settings resolution and the host compiler.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const project = @import("project_config.zig");
const plugins = @import("plugins.zig");
const manifest = @import("provider_manifest.zig");
const contract = @import("provider_contract.zig");
const toolchain = @import("zig_toolchain.zig");
const github = @import("provider_github.zig");
const hooks = @import("provider_hooks.zig");
const asm_cache = @import("asm_cache.zig");
const pd = @import("provider_dispatch.zig");
const CacheState = pd.CacheState;
const Host = pd.Host;
const HostCache = pd.HostCache;
const Provider = pd.Provider;
const ToolRun = pd.ToolRun;
const canonicalDir = pd.canonicalDir;
const checkSettingsMapping = pd.checkSettingsMapping;
const contained = pd.contained;
const discover = pd.discover;
const discoverAll = pd.discoverAll;
const dispatch = pd.dispatch;
const resolveHostWith = pd.resolveHostWith;
const resolveOwnSettings = pd.resolveOwnSettings;
const resolveSettings = pd.resolveSettings;
const runTool = pd.runTool;
const survey = pd.survey;
const validatePin = pd.validatePin;
const wireContext = pd.wireContext;

test "provider dispatch: a hook ToolRun yields a valid hook context, and none without a phase" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const abs = if (builtin.os.tag == .windows) "C:\\proj" else "/proj";
    const run: ToolRun = .{
        .invocation = .{ .kind = .hook, .id = "stamp", .step = .build, .phase = .after },
        .needs_project = true,
        .target = "desktop",
        .lock_file = try std.fs.path.join(a, &.{ abs, "labelle.lock" }),
        .output_dir = try std.fs.path.join(a, &.{ abs, "zig-out" }),
        .optimize = .ReleaseFast,
        .progress = .json,
        .settings = null,
        .trailing = &.{},
        .cwd = abs,
        .target_dir = try std.fs.path.join(a, &.{ abs, ".labelle", "probe_desktop" }),
        .final_step = .build,
    };
    // The same construction `runTool` performs from a ToolRun.
    const provider: Provider = .{
        .dep = .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
        .dir = try std.fs.path.join(a, &.{ abs, "pkg" }),
        .meta = .{ .name = "pkg", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0" },
        .verified = true,
    };
    const host: Host = .{ .zig = try std.fs.path.join(a, &.{ abs, "zig" }), .cache_root = abs, .global_cache = abs, .packages = abs };
    var ctx = try wireContext(provider, host, abs, run, try std.fs.path.join(a, &.{ abs, "cache" }));
    try ctx.validate(run.needs_project);
    try std.testing.expectEqualStrings(run.target_dir.?, ctx.target_dir.?);
    try std.testing.expect(ctx.run == null);
    ctx.invocation.phase = null;
    try std.testing.expectError(error.InvalidInvocation, ctx.validate(true));
}

test "provider dispatch: build_number reaches only a provider whose range admits the 1.1 wire" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const abs = if (builtin.os.tag == .windows) "C:\\proj" else "/proj";
    const run: ToolRun = .{
        .invocation = .{ .kind = .hook, .id = "pack", .step = .bundle, .phase = .replace },
        .needs_project = true,
        .target = "probe-target",
        .lock_file = try std.fs.path.join(a, &.{ abs, "labelle.lock" }),
        .output_dir = try std.fs.path.join(a, &.{ abs, "dist" }),
        .optimize = .ReleaseSafe,
        .progress = .off,
        .settings = null,
        .trailing = &.{},
        .cwd = abs,
        .build_number = "42",
        .target_dir = try std.fs.path.join(a, &.{ abs, ".labelle", "probe_probe-target" }),
        .final_step = .bundle,
    };
    const host: Host = .{ .zig = try std.fs.path.join(a, &.{ abs, "zig" }), .cache_root = abs, .global_cache = abs, .packages = abs };
    const cache = try std.fs.path.join(a, &.{ abs, "cache" });
    var provider: Provider = .{
        .dep = .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
        .dir = try std.fs.path.join(a, &.{ abs, "pkg" }),
        .meta = .{ .name = "pkg", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0" },
        .verified = true,
    };
    // An open v1 range: negotiated to the newest wire, which carries the key.
    const open = try wireContext(provider, host, abs, run, cache);
    try open.validate(true);
    try std.testing.expectEqualStrings(contract.version, open.contract_version);
    try std.testing.expectEqualStrings("42", open.build_number.?);
    const open_wire = try std.json.Stringify.valueAlloc(a, open, .{});
    try std.testing.expect(std.mem.indexOf(u8, open_wire, "\"build_number\":\"42\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, open_wire, "\"contract_version\":\"1.5.0\"") != null);
    // A range capped at the 1.1 wire still gets the key, and nothing newer.
    provider.meta.command_contract = ">=1.0.0 <1.2.0";
    const mid = try wireContext(provider, host, abs, run, cache);
    try mid.validate(true);
    try std.testing.expectEqualStrings("1.1.0", mid.contract_version);
    try std.testing.expectEqualStrings("42", mid.build_number.?);
    try std.testing.expect(mid.target_dir == null);
    // A provider capped at the 1.0 wire: the exact 1.0.0 wire, no key — so
    // its strict decoder sees nothing unknown.
    provider.meta.command_contract = ">=1.0.0 <1.1.0";
    const capped = try wireContext(provider, host, abs, run, cache);
    try capped.validate(true);
    try std.testing.expectEqualStrings("1.0.0", capped.contract_version);
    try std.testing.expect(capped.build_number == null);
    const capped_wire = try std.json.Stringify.valueAlloc(a, capped, .{});
    try std.testing.expect(std.mem.indexOf(u8, capped_wire, "build_number") == null);
    try std.testing.expect(std.mem.indexOf(u8, capped_wire, "\"contract_version\":\"1.0.0\"") != null);
    // A range the CLI cannot speak at all is refused, never guessed.
    provider.meta.command_contract = ">=2.0.0";
    try std.testing.expectError(error.UnsupportedContract, wireContext(provider, host, abs, run, cache));
}

test "provider dispatch: target_dir and run options reach only a provider whose range admits the 1.2 wire" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const abs = if (builtin.os.tag == .windows) "C:\\proj" else "/proj";
    const env = [_]contract.RunEnv{
        .{ .name = "LABELLE_SCENE", .value = "x" },
        .{ .name = "LABELLE_SCREENSHOT_PATH", .value = "s" },
    };
    const run: ToolRun = .{
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
        .run_options = .{ .env = &env, .args = &.{ "a", "b" }, .timeout_ms = 1500, .outcome_file = try std.fs.path.join(a, &.{ abs, "outcome" }) },
        .final_step = .run,
    };
    const host: Host = .{ .zig = try std.fs.path.join(a, &.{ abs, "zig" }), .cache_root = abs, .global_cache = abs, .packages = abs };
    const cache = try std.fs.path.join(a, &.{ abs, "cache" });
    var provider: Provider = .{
        .dep = .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
        .dir = try std.fs.path.join(a, &.{ abs, "pkg" }),
        .meta = .{ .name = "pkg", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0" },
        .verified = true,
    };
    const open = try wireContext(provider, host, abs, run, cache);
    try open.validate(true);
    try std.testing.expectEqualStrings(contract.version, open.contract_version);
    try std.testing.expectEqualStrings(run.target_dir.?, open.target_dir.?);
    try std.testing.expectEqual(@as(usize, 2), open.run.?.env.len);
    try std.testing.expectEqualStrings("b", open.run.?.args[1]);
    try std.testing.expectEqual(@as(?u64, 1500), open.run.?.timeout_ms);
    const open_wire = try std.json.Stringify.valueAlloc(a, open, .{});
    try std.testing.expect(std.mem.indexOf(u8, open_wire, "\"run\":{\"env\":[{\"name\":\"LABELLE_SCENE\",\"value\":\"x\"}") != null);
    // Capped below 1.2.0: the exact older wire, neither key.
    for ([_][2][]const u8{ .{ ">=1.0.0 <1.2.0", "1.1.0" }, .{ ">=1.0.0 <1.1.0", "1.0.0" } }) |case| {
        provider.meta.command_contract = case[0];
        const capped = try wireContext(provider, host, abs, run, cache);
        try capped.validate(true);
        try std.testing.expectEqualStrings(case[1], capped.contract_version);
        try std.testing.expect(capped.target_dir == null and capped.run == null);
        const capped_wire = try std.json.Stringify.valueAlloc(a, capped, .{});
        try std.testing.expect(std.mem.indexOf(u8, capped_wire, "target_dir") == null);
        // (`"step":"run"` is the invocation; the key would be `"run":`.)
        try std.testing.expect(std.mem.indexOf(u8, capped_wire, "\"run\":") == null);
    }
    // A command on the open range: `target_dir` is written as null.
    provider.meta.command_contract = ">=1.0.0 <2.0.0";
    var command = run;
    command.invocation = .{ .kind = .command, .id = "doctor", .step = null, .phase = null };
    command.target_dir = null;
    command.run_options = null;
    command.final_step = null;
    const cmd_ctx = try wireContext(provider, host, abs, command, cache);
    try cmd_ctx.validate(true);
    const cmd_wire = try std.json.Stringify.valueAlloc(a, cmd_ctx, .{});
    try std.testing.expect(std.mem.indexOf(u8, cmd_wire, "\"target_dir\":null") != null);
}

test "provider dispatch: cache_dir and env_file reach only a provider whose range admits the 1.3 wire" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const abs = if (builtin.os.tag == .windows) "C:\\proj" else "/proj";
    const run: ToolRun = .{
        .invocation = .{ .kind = .hook, .id = "toolchain", .step = .generate, .phase = .before },
        .needs_project = true,
        .target = "probe-target",
        .lock_file = try std.fs.path.join(a, &.{ abs, "labelle.lock" }),
        .output_dir = try std.fs.path.join(a, &.{ abs, "gen" }),
        .optimize = .ReleaseSafe,
        .progress = .off,
        .settings = null,
        .trailing = &.{},
        .cwd = abs,
        .target_dir = try std.fs.path.join(a, &.{ abs, ".labelle", "probe_probe-target" }),
        .env_file = try std.fs.path.join(a, &.{ abs, "env", "env.json" }),
        .final_step = .build,
    };
    const host: Host = .{ .zig = try std.fs.path.join(a, &.{ abs, "zig" }), .cache_root = abs, .global_cache = abs, .packages = abs };
    const cache = try std.fs.path.join(a, &.{ abs, "providers", "local", "pkg" });
    var provider: Provider = .{
        .dep = .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
        .dir = try std.fs.path.join(a, &.{ abs, "pkg" }),
        .meta = .{ .name = "pkg", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0" },
        .verified = true,
    };
    const open = try wireContext(provider, host, abs, run, cache);
    try open.validate(true);
    try std.testing.expectEqualStrings(contract.version, open.contract_version);
    try std.testing.expectEqualStrings(cache, open.cache_dir.?);
    try std.testing.expectEqualStrings(run.env_file.?, open.env_file.?);
    // Capped below 1.3.0 (`<1.3.0`): the exact 1.2.0 wire, neither key, so
    // the hook cannot contribute an environment.
    provider.meta.command_contract = "<1.3.0";
    const capped = try wireContext(provider, host, abs, run, cache);
    try capped.validate(true);
    try std.testing.expectEqualStrings("1.2.0", capped.contract_version);
    try std.testing.expect(capped.cache_dir == null and capped.env_file == null);
    const capped_wire = try std.json.Stringify.valueAlloc(a, capped, .{});
    try std.testing.expect(std.mem.indexOf(u8, capped_wire, "cache_dir") == null);
    try std.testing.expect(std.mem.indexOf(u8, capped_wire, "env_file") == null);
    // A hook outside the contributing slots: the key is null on 1.3.0.
    provider.meta.command_contract = ">=1.0.0 <2.0.0";
    var after_build = run;
    after_build.invocation = .{ .kind = .hook, .id = "stamp", .step = .build, .phase = .after };
    after_build.env_file = null;
    const plain = try wireContext(provider, host, abs, after_build, cache);
    try plain.validate(true);
    const plain_wire = try std.json.Stringify.valueAlloc(a, plain, .{});
    try std.testing.expect(std.mem.indexOf(u8, plain_wire, "\"env_file\":null") != null);
}

test "provider dispatch: lock mismatch and duplicates fail closed" {
    const dep: project.PluginDep = .{ .name = "fixture", .repo = "local:../fixture", .version = "1.0.0" };
    try validatePin(dep, &.{dep});
    try std.testing.expectError(error.MissingProviderPin, validatePin(dep, &.{}));
    try std.testing.expectError(error.DuplicateProviderPin, validatePin(dep, &.{ dep, dep }));
    var changed = dep;
    changed.version = "2.0.0";
    try std.testing.expectError(error.StaleProviderPin, validatePin(dep, &.{changed}));
    changed = dep;
    changed.repo = "local:../other";
    try std.testing.expectError(error.StaleProviderPin, validatePin(dep, &.{changed}));
}

test "provider dispatch: workspace directories are canonical whatever the caller's cwd" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // tmpDir lives at a cwd-relative path — the shape a relative LABELLE_HOME takes.
    const relative = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "home", "provider-runs" });
    try std.testing.expect(!std.fs.path.isAbsolute(relative));
    const canonical = try canonicalDir(a, relative);
    try std.testing.expect(std.fs.path.isAbsolute(canonical));
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(config.globalIo(), &buf);
    try std.testing.expect(contained(buf[0..n], canonical));
    try std.testing.expectEqualStrings("provider-runs", std.fs.path.basename(canonical));
    // Created, not merely named: the child can install into it right away.
    try tmp.dir.access(config.globalIo(), "home/provider-runs", .{});
}

test "provider dispatch: canonical containment respects component boundaries" {
    try std.testing.expect(contained("/tmp/install", "/tmp/install/bin/tool"));
    try std.testing.expect(!contained("/tmp/install", "/tmp/install-evil/bin/tool"));
    try std.testing.expect(!contained("/tmp/install", "/tmp/install"));
}

test "provider dispatch: an unread remote package defers its references under .unknown and fails .populated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "pkg-a");
    const root = try tmp.dir.realPathFileAlloc(io, "project", a);
    // The ordinary package cache lives under this tmp dir, so the remote
    // package is absent until the test writes it there.
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    asm_cache.setCacheRootOverride(home);
    defer asm_cache.clearCacheRootOverride();
    const Manifests = struct {
        fn write(dir: std.Io.Dir, sub_path: []const u8, name: []const u8, hook: []const u8) !void {
            var buf: [512]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf, ".{{ .name = \"{s}\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .hooks = .{{ {s} }} }}", .{ name, hook });
            try dir.writeFile(config.globalIo(), .{ .sub_path = sub_path, .data = text });
        }
    };
    const a_hook = ".{ .id = \"a\", .step = .build, .target = \"desktop\", .when = .after, .build_step = \"tool\", .executable = \"bin/tool\", .after_hooks = .{ \"pkg-b/b\" } }";
    try Manifests.write(tmp.dir, "pkg-a/plugin.labelle", "pkg-a", a_hook);
    const cfg: project.ProjectConfig = .{ .name = "game", .plugins = &.{
        .{ .name = "pkg-a", .repo = "local:../pkg-a", .version = "1.0.0" },
        .{ .name = "pkg-b", .repo = "example/pkg-b", .version = "1.0.0" },
    } };
    var sources: github.Sources = .{ .a = a };
    defer sources.deinit();

    // Cold: metadata-only discovery lists the provider it can read and
    // defers the reference into the one it cannot; the pipeline's
    // populated discovery fails closed on the same absence.
    const partial = try discoverAll(a, root, cfg, &sources, .unknown);
    try std.testing.expectEqual(@as(usize, 1), partial.providers.len);
    try std.testing.expectEqualStrings("pkg-a", partial.providers[0].meta.name);
    // The unread package is named, so a caller knows the view is partial.
    try std.testing.expectEqual(@as(usize, 1), partial.unresolved.len);
    try std.testing.expectEqualStrings("pkg-b", partial.unresolved[0]);
    try std.testing.expectError(error.ProviderPackageMissing, discover(a, root, cfg, &sources, .populated));
    // A reference into a package the project never declared is a typo
    // even while pkg-b is unread.
    const typo = ".{ .id = \"a\", .step = .build, .target = \"desktop\", .when = .after, .build_step = \"tool\", .executable = \"bin/tool\", .after_hooks = .{ \"pkg-c/b\" } }";
    try Manifests.write(tmp.dir, "pkg-a/plugin.labelle", "pkg-a", typo);
    try std.testing.expectError(error.MissingHookReference, discover(a, root, cfg, &sources, .unknown));
    try Manifests.write(tmp.dir, "pkg-a/plugin.labelle", "pkg-a", a_hook);

    // Warm: the package is in the ordinary cache. Both states read it, and
    // a reference it does not satisfy is missing in both.
    const cached = try std.fs.path.join(a, &.{ "packages", "plugins", "example", "pkg-b", "1.0.0" });
    try tmp.dir.createDirPath(io, cached);
    const manifest_path = try std.fs.path.join(a, &.{ cached, "plugin.labelle" });
    const b_hook = ".{ .id = \"b\", .step = .build, .target = \"desktop\", .when = .after, .build_step = \"tool\", .executable = \"bin/tool\" }";
    try Manifests.write(tmp.dir, manifest_path, "pkg-b", b_hook);
    for ([_]CacheState{ .unknown, .populated }) |state| {
        const both = try discoverAll(a, root, cfg, &sources, state);
        try std.testing.expectEqual(@as(usize, 2), both.providers.len);
        try std.testing.expectEqualStrings("pkg-b", both.providers[1].meta.name);
        try std.testing.expectEqual(@as(usize, 0), both.unresolved.len);
        // Read from the ordinary cache without a pin: present, but unverified.
        try std.testing.expect(both.providers[0].verified);
        try std.testing.expect(!both.providers[1].verified);
    }
    const other = ".{ .id = \"other\", .step = .build, .target = \"desktop\", .when = .after, .build_step = \"tool\", .executable = \"bin/tool\" }";
    try Manifests.write(tmp.dir, manifest_path, "pkg-b", other);
    for ([_]CacheState{ .unknown, .populated }) |state| {
        try std.testing.expectError(error.MissingHookReference, discover(a, root, cfg, &sources, state));
    }
}

test "provider dispatch: survey reports a pinned provider with no cached archive and keeps the others" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "pkg-a");
    const root = try tmp.dir.realPathFileAlloc(io, "project", a);
    // No archive is ever cached under this root.
    asm_cache.setCacheRootOverride(try tmp.dir.realPathFileAlloc(io, ".", a));
    defer asm_cache.clearCacheRootOverride();
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg-a/plugin.labelle", .data = ".{ .name = \"pkg-a\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .namespace = \"alpha\", .commands = .{ .{ .name = \"doctor\", .build_step = \"t\", .executable = \"bin/t\", .help = \"h\" } } }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/labelle.providers.lock", .data = "{\"schema_version\":1,\"providers\":[{\"package\":\"pkg-b\",\"repo\":\"example/pkg-b\",\"version\":\"1.0.0\",\"commit\":\"1111111111111111111111111111111111111111\",\"sha256\":\"2222222222222222222222222222222222222222222222222222222222222222\"}]}" });
    const cfg: project.ProjectConfig = .{ .name = "game", .plugins = &.{
        .{ .name = "pkg-b", .repo = "github.com/example/pkg-b", .version = "1.0.0" },
        .{ .name = "pkg-a", .repo = "local:../pkg-a", .version = "1.0.0" },
    } };
    var sources: github.Sources = .{ .a = a };
    defer sources.deinit();
    // Plain discovery stops at the missing archive ...
    try std.testing.expectError(error.ProviderArchiveMissing, discoverAll(a, root, cfg, &sources, .unknown));
    // ... the survey names it and still reads the provider after it.
    const found = try survey(a, root, cfg, &sources);
    try std.testing.expectEqual(@as(usize, 1), found.providers.len);
    try std.testing.expectEqualStrings("pkg-a", found.providers[0].meta.name);
    try std.testing.expectEqual(@as(usize, 1), found.unavailable.len);
    try std.testing.expectEqualStrings("pkg-b", found.unavailable[0].package);
    try std.testing.expectEqual(@as(anyerror, error.ProviderArchiveMissing), found.unavailable[0].err);
    try std.testing.expectEqualStrings("pkg-b", found.unresolved[0]);
}

test "provider dispatch: own-settings resolution opens only the selected provider's file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();
    try tmp.dir.createDirPath(io, "project/providers");
    const root = try tmp.dir.realPathFileAlloc(io, "project", a);
    try tmp.dir.writeFile(io, .{ .sub_path = "project/providers/good.json", .data = "{\"label\":\"x\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/providers/bad.json", .data = "{not json" });
    const cfg: project.ProjectConfig = .{ .name = "game", .provider_config = &.{
        .{ .package = "bad", .file = "providers/bad.json" },
        .{ .package = "good", .file = "providers/good.json" },
    } };
    const meta: manifest.Manifest = .{ .name = "", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0" };
    var providers = [_]Provider{
        .{ .dep = .{ .name = "bad", .repo = "local:../bad", .version = "1.0.0" }, .dir = root, .meta = meta, .verified = true },
        .{ .dep = .{ .name = "good", .repo = "local:../good", .version = "1.0.0" }, .dir = root, .meta = meta, .verified = true },
    };
    providers[0].meta.name = "bad";
    providers[1].meta.name = "good";
    try checkSettingsMapping(cfg, &providers);
    // `labelle <ns> <cmd>` (`.all`): the other provider's bad file stops it.
    try std.testing.expectError(error.InvalidProviderConfigJson, resolveSettings(a, root, cfg, &providers, "good"));
    // `labelle doctor` (`.selected`): each provider stands alone.
    const own = (try resolveOwnSettings(a, root, cfg, "good")).?;
    try std.testing.expectEqualStrings("good.json", std.fs.path.basename(own));
    try std.testing.expectError(error.InvalidProviderConfigJson, resolveOwnSettings(a, root, cfg, "bad"));
    try std.testing.expectEqual(@as(?[]const u8, null), try resolveOwnSettings(a, root, cfg, "other"));
    // The mapping check alone: an entry naming no verified provider.
    providers[1].verified = false;
    try std.testing.expectError(error.UnresolvedProviderConfig, checkSettingsMapping(cfg, &providers));
}

test "provider dispatch: the host compiler is provisioned like `labelle build`, not refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();
    try tmp.dir.writeFile(io, .{ .sub_path = "project.labelle", .data = ".{ .name = \"x\", .zig_version = \"0.16.0\" }" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const Probe = struct {
        var calls: usize = 0;
        var seen: []const u8 = "";
        fn provision(_: std.mem.Allocator, project_dir: []const u8) anyerror![]u8 {
            calls += 1;
            seen = project_dir;
            return error.ProbeProvisioned;
        }
        fn missing(pa: std.mem.Allocator, _: []const u8) anyerror![]u8 {
            calls += 1;
            return pa.dupe(u8, "/nonexistent/zig-override");
        }
    };
    // The resolution goes through the provisioner, for this project's root,
    // and its outcome is the result (a download failure, not a refusal).
    try std.testing.expectError(error.ProbeProvisioned, resolveHostWith(a, root, Probe.provision));
    try std.testing.expectEqual(@as(usize, 1), Probe.calls);
    try std.testing.expectEqualStrings(root, Probe.seen);
    // An override naming no file is the one `ProviderCompilerMissing`.
    try std.testing.expectError(error.ProviderCompilerMissing, resolveHostWith(a, root, Probe.missing));
    try std.testing.expectEqual(@as(usize, 2), Probe.calls);
}

test "provider dispatch: a HostCache resolves once, and keeps a success or a failure" {
    const Probe = struct {
        var calls: usize = 0;
        var fail = true;
        fn resolve(_: std.mem.Allocator, _: []const u8) anyerror!Host {
            calls += 1;
            if (fail) return error.ProbeOffline;
            return .{ .zig = "/z", .cache_root = "/c", .global_cache = "/g", .packages = "/p" };
        }
    };
    var failing: HostCache = .{ .resolve = Probe.resolve };
    for (0..3) |_| try std.testing.expectError(error.ProbeOffline, failing.get(std.testing.allocator, "/proj"));
    try std.testing.expectEqual(@as(usize, 1), Probe.calls);
    Probe.fail = false;
    var working: HostCache = .{ .resolve = Probe.resolve };
    for (0..3) |_| try std.testing.expectEqualStrings("/z", (try working.get(std.testing.allocator, "/proj")).zig);
    try std.testing.expectEqual(@as(usize, 2), Probe.calls);
}
