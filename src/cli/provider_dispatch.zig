//! Project-local command dispatch. No registry/global fallback or downloads.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const project = @import("project_config.zig");
const plugins = @import("plugins.zig");
const manifest = @import("provider_manifest.zig");
const contract = @import("provider_contract.zig");
const runner = @import("runner.zig");
const toolchain = @import("zig_toolchain.zig");
const zig_cache = @import("zig_cache.zig");
const github = @import("provider_github.zig");
const hooks = @import("provider_hooks.zig");
const asm_cache = @import("asm_cache.zig");

// Existing platform commands remain reserved until their extraction lands.
pub const reserved = [_][]const u8{
    "generate", "build",   "bundle",    "run",       "init",   "add",   "install", "update",
    "upgrade",  "clean",   "test",      "pack",      "astc",   "audit", "migrate", "check",
    "plugins",  "doctor",  "assembler", "toolchain", "status", "ios",   "android", "wasm",
    "help",     "version", "targets",   "providers",
};
pub const Provider = struct { dep: project.PluginDep, dir: []const u8, meta: manifest.Manifest, verified: bool };

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, a, .limited(1024 * 1024));
}
fn real(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), path, a);
}

pub fn projectRoot(a: std.mem.Allocator) !?[]const u8 {
    var dir: []const u8 = try real(a, ".");
    while (true) {
        const path = try std.fs.path.join(a, &.{ dir, "project.labelle" });
        std.Io.Dir.cwd().access(config.globalIo(), path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                dir = std.fs.path.dirname(dir) orelse return null;
                continue;
            },
            else => return err,
        };
        return dir;
    }
}

/// What an absent non-local package means to `discover`. A remote package
/// that is neither pinned (provider cache) nor in the ordinary package cache
/// cannot be told apart from a runtime-only package by its manifest, because
/// there is nothing to read.
pub const CacheState = enum {
    /// Metadata-only callers (`labelle help`, command dispatch) run before
    /// any installer: an absent package is simply not listed, and a hook
    /// reference into it is deferred rather than reported missing, so the
    /// providers that ARE present keep their commands (Codex P2 on #420).
    unknown,
    /// The pipeline discovers AFTER the assembler populated the cache, so an
    /// absent package is a broken install and fails closed — otherwise a cold
    /// cache would silently build without the package's hooks while a warm
    /// one runs them (Codex P1 on #420).
    populated,
};

/// Every provider the project declares, with ownership and the cross-provider
/// hook graph validated. Metadata only: no compiler, lock or build script.
///
/// A package directory WITHOUT a `plugin.labelle` is a runtime-only package
/// (the assembler's light packs ship no manifest); only a missing directory
/// is an error, and only once the cache is `populated`.
pub fn discover(a: std.mem.Allocator, root: []const u8, cfg: project.ProjectConfig, sources: *github.Sources, cache_state: CacheState) ![]Provider {
    return (try discoverAll(a, root, cfg, sources, cache_state)).providers;
}

pub const Discovery = struct {
    providers: []Provider,
    /// Declared remote packages with no directory to read (`.unknown` only;
    /// `.populated` makes them an error). While this is non-empty the
    /// providers are a partial view: nothing that needs every declared
    /// package — target ownership above all — can be decided from them.
    unresolved: []const []const u8,
};

/// `discover`, also reporting the declared packages it could not read.
pub fn discoverAll(a: std.mem.Allocator, root: []const u8, cfg: project.ProjectConfig, sources: *github.Sources, cache_state: CacheState) !Discovery {
    var providers: std.ArrayList(Provider) = .empty;
    var owners: std.ArrayList(contract.Ownership) = .empty;
    // Declared remote packages with no directory to read while the cache
    // state is `unknown`. They are neither providers nor runtime-only
    // packages yet, so a hook reference into one is deferred rather than
    // reported missing (`hooks.validateAll`).
    var unresolved: std.ArrayList([]const u8) = .empty;
    for (cfg.plugins) |dep| {
        // A lookup-only view (`Sources.extract = false`) has no directory for
        // a pin nothing extracted yet: under `.unknown` that package is
        // unread, like an uncached one, never mistaken for an unpinned one.
        const pinned = if (dep.isLocal()) null else sources.projectDir(root, dep) catch |err| switch (err) {
            error.ProviderSourceNotExtracted => switch (cache_state) {
                .unknown => {
                    try unresolved.append(a, dep.name);
                    continue;
                },
                .populated => return err,
            },
            else => return err,
        };
        const dir = pinned orelse try plugins.resolvePluginDir(a, root, dep);
        if (pinned == null and !dep.isLocal()) {
            std.Io.Dir.cwd().access(config.globalIo(), dir, .{}) catch |err| switch (err) {
                error.FileNotFound => switch (cache_state) {
                    .populated => {
                        std.debug.print("labelle: package '{s}' ({s}@{s}) is not in the package cache after install: {s}\n", .{ dep.name, dep.repo, dep.version, dir });
                        return error.ProviderPackageMissing;
                    },
                    .unknown => {
                        try unresolved.append(a, dep.name);
                        continue;
                    },
                },
                else => return err,
            };
        }
        const path = try std.fs.path.join(a, &.{ dir, "plugin.labelle" });
        const bytes = read(a, path) catch |err| switch (err) {
            error.FileNotFound => continue, // Runtime plugins may have no manifest.
            else => return err,
        };
        const meta = manifest.parse(a, bytes) catch |err| {
            std.debug.print("labelle: provider manifest '{s}': {s} (CLI contract {s})\n", .{ path, @errorName(err), contract.version });
            return err;
        };
        if (!meta.isProvider()) continue;
        if (!std.mem.eql(u8, dep.name, meta.name)) return error.ProviderNameMismatch;
        const names = try a.alloc([]const u8, if (meta.namespace != null) 1 else 0);
        if (meta.namespace) |ns| names[0] = ns;
        try owners.append(a, .{ .package = meta.name, .namespaces = names, .targets = meta.targets });
        try providers.append(a, .{ .dep = dep, .dir = try real(a, dir), .meta = meta, .verified = dep.isLocal() or pinned != null });
    }
    try contract.validateOwnership(owners.items, &reserved);
    try hooks.validateAll(a, providers.items, unresolved.items);
    return .{ .providers = providers.items, .unresolved = unresolved.items };
}

fn printCommands(provider: Provider) void {
    if (provider.meta.namespace) |ns| {
        for (provider.meta.commands) |cmd| std.debug.print("  labelle {s} {s} — {s}\n", .{ ns, cmd.name, cmd.help });
    }
}

/// Metadata-only help never reads a lock, resolves a compiler or runs build code.
pub fn printHelp(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try projectRoot(a) orelse return;
    const cfg = try config.readProjectConfigQuiet(a, root);
    var sources: github.Sources = .{ .a = a };
    defer sources.deinit();
    const providers = try discover(a, root, cfg, &sources, .unknown);
    if (providers.len != 0) std.debug.print("\nProject package commands:\n", .{});
    for (providers) |provider| printCommands(provider);
}

pub fn validatePin(dep: project.PluginDep, pins: []const project.PluginDep) !void {
    var found = false;
    for (pins) |pin| {
        if (!std.mem.eql(u8, pin.name, dep.name)) continue;
        if (found) return error.DuplicateProviderPin;
        found = true;
        if (!std.mem.eql(u8, pin.repo, dep.repo) or !std.mem.eql(u8, pin.version, dep.version))
            return error.StaleProviderPin;
    }
    if (!found) return error.MissingProviderPin;
}

/// null means the namespace is unknown; callers can then try directory shorthand.
pub fn dispatch(allocator: std.mem.Allocator, namespace: []const u8, args: *std.process.Args.Iterator) !?u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try projectRoot(a) orelse return null;
    const cfg = try config.readProjectConfigQuiet(a, root);
    var sources: github.Sources = .{ .a = a };
    defer sources.deinit();
    const providers = try discover(a, root, cfg, &sources, .unknown);
    for (providers) |provider| {
        if (!std.mem.eql(u8, namespace, provider.meta.namespace orelse continue)) continue;
        const name = args.next() orelse {
            printCommands(provider);
            return 0;
        };
        if (isHelp(name)) {
            printCommands(provider);
            return 0;
        }
        for (provider.meta.commands) |cmd| {
            if (!std.mem.eql(u8, name, cmd.name)) continue;
            var trailing: std.ArrayList([]const u8) = .empty;
            while (args.next()) |arg| try trailing.append(a, arg);
            if (trailing.items.len == 1 and isHelp(trailing.items[0])) {
                std.debug.print("labelle {s} {s} — {s}\n", .{ namespace, name, cmd.help });
                return 0;
            }
            const lock_path = try requirePinned(a, root, provider);
            const settings = try resolveSettings(a, root, cfg, providers, provider.meta.name);
            return try execute(a, root, cfg, provider, cmd, lock_path, settings, trailing.items);
        }
        std.debug.print("labelle: unknown command '{s}' in provider namespace '{s}'\n", .{ name, namespace });
        printCommands(provider);
        return 1;
    }
    return null;
}

/// Execution (a command or a hook) needs the project's ordinary lock to name
/// this exact provider, and a remote provider to carry an integrity pin.
/// Returns the lock's real path for the wire context.
pub fn requirePinned(a: std.mem.Allocator, root: []const u8, provider: Provider) ![]const u8 {
    const lock_path = try std.fs.path.join(a, &.{ root, "labelle.lock" });
    const lock_bytes = read(a, lock_path) catch |err| {
        std.debug.print("labelle: provider execution requires the project's labelle.lock: {s}\n", .{@errorName(err)});
        return error.MissingProjectLock;
    };
    const Lock = struct { plugins: []const project.PluginDep = &.{} };
    const lock = try std.zon.parse.fromSliceAlloc(Lock, a, try a.dupeZ(u8, lock_bytes), null, .{ .ignore_unknown_fields = true });
    try validatePin(provider.dep, lock.plugins);
    if (!provider.verified) {
        std.debug.print("labelle: remote provider '{s}' is unpinned. Run labelle providers resolve, review the pins, then repeat with --accept.\n", .{provider.dep.name});
        return error.RemoteProviderIntegrityRequired;
    }
    return real(a, lock_path);
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

/// A canonical child must be strictly beneath its canonical parent.
pub fn contained(parent: []const u8, child: []const u8) bool {
    if (parent.len == 0) return false;
    const prefix = if (builtin.os.tag == .windows)
        child.len > parent.len and std.ascii.eqlIgnoreCase(parent, child[0..parent.len])
    else
        std.mem.startsWith(u8, child, parent) and child.len > parent.len;
    if (!prefix) return false;
    return std.fs.path.isSep(child[parent.len]) or std.fs.path.isSep(parent[parent.len - 1]);
}

fn executable(a: std.mem.Allocator, prefix: []const u8, relative: []const u8) ![]const u8 {
    const suffix = if (builtin.os.tag == .windows) ".exe" else "";
    const path = try std.fs.path.join(a, &.{ prefix, try std.fmt.allocPrint(a, "{s}{s}", .{ relative, suffix }) });
    const resolved = try real(a, path);
    if (!contained(try real(a, prefix), resolved)) return error.EscapingProviderExecutable;
    const stat = try std.Io.Dir.cwd().statFile(config.globalIo(), resolved, .{});
    if (stat.kind != .file) return error.InvalidProviderExecutable;
    try std.Io.Dir.cwd().access(config.globalIo(), resolved, .{ .execute = true });
    return resolved;
}

/// Create `dir` if needed and return its canonical absolute path, so it means
/// the same thing in a child that runs with a different cwd.
pub fn canonicalDir(a: std.mem.Allocator, dir: []const u8) ![]const u8 {
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), dir);
    return real(a, dir);
}

pub fn resolveSettings(a: std.mem.Allocator, root: []const u8, cfg: project.ProjectConfig, providers: []const Provider, selected: []const u8) !?[]const u8 {
    var result: ?[]const u8 = null;
    for (cfg.provider_config) |entry| {
        var resolved = false;
        for (providers) |provider| {
            if (std.mem.eql(u8, provider.meta.name, entry.package) and provider.verified) resolved = true;
        }
        if (!resolved) {
            std.debug.print("labelle: provider_config '{s}' must name a resolved command/hook provider\n", .{entry.package});
            return error.UnresolvedProviderConfig;
        }
        const requested = try std.fs.path.join(a, &.{ root, entry.file });
        const path = real(a, requested) catch |err| {
            std.debug.print("labelle: provider_config '{s}' cannot open '{s}': {s}\n", .{ entry.package, entry.file, @errorName(err) });
            return error.MissingProviderConfig;
        };
        if (!contained(root, path)) {
            std.debug.print("labelle: provider_config '{s}' resolves outside the project: {s}\n", .{ entry.package, entry.file });
            return error.EscapingProviderConfig;
        }
        const stat = std.Io.Dir.cwd().statFile(config.globalIo(), path, .{}) catch |err| {
            std.debug.print("labelle: provider_config '{s}' cannot stat '{s}': {s}\n", .{ entry.package, entry.file, @errorName(err) });
            return err;
        };
        if (stat.kind != .file) {
            std.debug.print("labelle: provider_config '{s}' is not a regular file: {s}\n", .{ entry.package, entry.file });
            return error.InvalidProviderConfigFile;
        }
        // Covers the 1 MiB input limit (StreamTooLong) and unreadable files.
        const bytes = read(a, path) catch |err| {
            std.debug.print("labelle: provider_config '{s}' cannot read '{s}': {s}\n", .{ entry.package, entry.file, @errorName(err) });
            return err;
        };
        defer a.free(bytes);
        // Check JSON syntax only. The provider owns its settings schema and
        // must validate semantic requirements before producing side effects.
        const json = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch {
            std.debug.print("labelle: provider_config '{s}' is not valid JSON: {s}\n", .{ entry.package, entry.file });
            return error.InvalidProviderConfigJson;
        };
        json.deinit();
        if (std.mem.eql(u8, entry.package, selected)) result = path;
    }
    return result;
}

/// The pinned host compiler and the canonical cache tree every provider tool
/// build shares. Resolved once per CLI invocation, lazily, so a project
/// without hooks never touches the compiler check.
pub const Host = struct { zig: []const u8, cache_root: []const u8, global_cache: []const u8, packages: []const u8 };

/// Unlike the game runner, provider execution must never download a compiler.
pub fn resolveHost(a: std.mem.Allocator, root: []const u8) !Host {
    const io = config.globalIo();
    const required = try toolchain.resolveRequiredVersion(a, root);
    const zig_candidate = (try toolchain.lookupEnvOverride(a)) orelse try zig_cache.binaryPath(a, required.version);
    const zig = real(a, zig_candidate) catch {
        std.debug.print("labelle: install the pinned host compiler first: labelle install zig {s}\n", .{required.version});
        return error.ProviderCompilerMissing;
    };
    const version = try std.process.run(a, io, .{ .argv = &.{ zig, "version" } });
    if (version.term != .exited or version.term.exited != 0) return error.ProviderCompilerFailed;
    if (!std.mem.eql(u8, std.mem.trim(u8, version.stdout, "\r\n "), required.version)) return error.ProviderCompilerVersionMismatch;

    // The build child runs with the provider as cwd, so every path handed to
    // it is canonical: a relative LABELLE_HOME (which getCacheRoot accepts)
    // would otherwise make Zig install beneath the provider source while this
    // process looks for the prefix beneath its own cwd, and the stray tree
    // would never be cleaned because only run_dir is removed (cli#413 review).
    // `github.cacheRoot` already resolves LABELLE_HOME against this process's
    // cwd; `canonicalDir` creates the directory and returns its real path.
    const cache_root = try github.cacheRoot(a);
    const global_cache = try std.fs.path.join(a, &.{ cache_root, zig_cache.GLOBAL_CACHE_SUBDIR });
    // Zig's system package mode disables fetching. Its package directory is
    // explicit so a missing dependency fails instead of reaching the network.
    const packages = try canonicalDir(a, try std.fs.path.join(a, &.{ global_cache, "p" }));
    return .{ .zig = zig, .cache_root = cache_root, .global_cache = global_cache, .packages = packages };
}

/// One invocation of a provider tool: the wire-context fields the caller
/// decides (contract §2) plus how the child is launched.
pub const ToolRun = struct {
    invocation: contract.Invocation,
    needs_project: bool,
    target: ?[]const u8,
    lock_file: ?[]const u8,
    /// Absolute; created by the caller.
    output_dir: []const u8,
    optimize: contract.Optimize,
    progress: contract.Progress,
    settings: ?[]const u8,
    trailing: []const []const u8,
    cwd: []const u8,
    /// `bundle` hooks only: `labelle bundle --build-number` (contract §2).
    build_number: ?[]const u8 = null,
};

/// The wire context for one invocation (contract §2), in the wire version
/// negotiated from the provider's `command_contract` range: the newest one
/// this CLI speaks that the range admits. `build_number` is a `1.1.0` key, so
/// a provider capped below it (`>=1.0.0 <1.1.0`) gets the exact `1.0.0` wire
/// without it — its strict decoder would reject the unknown key and fail
/// the bundle instead of packaging (Codex P2 on #421) — and the drop is
/// reported once on stderr rather than silently.
pub fn wireContext(provider: Provider, host: Host, root: []const u8, run: ToolRun) !contract.Context {
    const wire = try manifest.negotiate(provider.meta.command_contract orelse return error.MissingCommandContract);
    const build_number = if (run.build_number) |number| blk: {
        if (contract.carriesBuildNumber(wire)) break :blk number;
        std.debug.print("labelle: note: '{s}' speaks provider contract {s}, which has no build_number; --build-number={s} is not passed to it\n", .{ provider.meta.name, wire, number });
        break :blk null;
    } else null;
    return .{
        .contract_version = wire,
        .invocation = run.invocation,
        .package_dir = provider.dir,
        .project_dir = root,
        .target = run.target,
        .lock_file = run.lock_file,
        .config_file = run.settings,
        .output_dir = run.output_dir,
        .zig_executable = host.zig,
        .optimize = run.optimize,
        .progress = run.progress,
        .build_number = build_number,
    };
}

/// Build the tool in a fresh isolated prefix, verify the declared executable,
/// write the context file and run it. Returns the tool's exit status; the
/// workspace is removed whatever happens.
pub fn runTool(a: std.mem.Allocator, host: Host, root: []const u8, provider: Provider, tool: contract.Tool, run: ToolRun) !u8 {
    const io = config.globalIo();
    const runs = try canonicalDir(a, try std.fs.path.join(a, &.{ host.cache_root, "provider-runs" }));
    var random: [16]u8 = undefined;
    io.random(&random);
    const run_dir = try std.fs.path.join(a, &.{ runs, &std.fmt.bytesToHex(random, .lower) });
    try std.Io.Dir.cwd().createDir(io, run_dir, .default_dir);
    // Only the freshly-created per-invocation directory is ever removed.
    defer std.Io.Dir.cwd().deleteTree(io, run_dir) catch |err| {
        std.debug.print("labelle: could not remove provider workspace '{s}': {s}\n", .{ run_dir, @errorName(err) });
    };
    const prefix = try std.fs.path.join(a, &.{ run_dir, "install" });
    var env = try runner.buildZigEnv(a, &.{});
    defer env.deinit();
    // Keep relative LABELLE_HOME stable when child cwd changes to the package.
    try env.put("ZIG_GLOBAL_CACHE_DIR", host.global_cache);
    try env.put("ZIG_LOCAL_CACHE_DIR", try std.fs.path.join(a, &.{ host.cache_root, zig_cache.LOCAL_CACHE_SUBDIR }));
    try env.put("LABELLE_HOME", host.cache_root);
    // Zig owns the complete source/dependency/compiler/options cache identity.
    // Always run the install step: never trust a stale installed executable.
    const build_code = try runner.runZigInheritWithEnv(a, provider.dir, &.{ host.zig, "build", tool.build_step, "--prefix", prefix, "--system", host.packages }, null, &env);
    if (build_code != 0) return build_code;
    if (!contained(run_dir, try real(a, prefix))) return error.EscapingProviderInstall;
    const exe = try executable(a, prefix, tool.executable);
    const ctx = try wireContext(provider, host, root, run);
    try ctx.validate(run.needs_project);
    const context_path = try std.fs.path.join(a, &.{ run_dir, "context.json" });
    const data = try std.json.Stringify.valueAlloc(a, ctx, .{});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = context_path, .data = data });
    try env.put(contract.context_env, context_path);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, exe);
    try argv.appendSlice(a, run.trailing);
    return runner.runZigInheritWithEnv(a, run.cwd, argv.items, null, &env);
}

/// A project command: Debug, human progress, output under
/// `.labelle/providers/<package>`, trailing arguments verbatim.
fn execute(a: std.mem.Allocator, root: []const u8, cfg: project.ProjectConfig, provider: Provider, cmd: manifest.Command, lock_path: []const u8, settings: ?[]const u8, trailing: []const []const u8) !u8 {
    const host = try resolveHost(a, root);
    var output: []const u8 = root;
    for ([_][]const u8{ ".labelle", "providers", provider.meta.name }) |segment| {
        output = try canonicalDir(a, try std.fs.path.join(a, &.{ output, segment }));
        if (!contained(root, output)) return error.EscapingProviderOutput;
    }
    return runTool(a, host, root, provider, cmd.tool(), .{
        .invocation = .{ .kind = .command, .id = cmd.name, .step = null, .phase = null },
        .needs_project = cmd.needs_project,
        .target = @tagName(cfg.platform),
        .lock_file = lock_path,
        .output_dir = output,
        .optimize = .Debug,
        .progress = .human,
        .settings = settings,
        .trailing = trailing,
        .cwd = root,
    });
}

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
    };
    // The same construction `runTool` performs from a ToolRun.
    const provider: Provider = .{
        .dep = .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
        .dir = try std.fs.path.join(a, &.{ abs, "pkg" }),
        .meta = .{ .name = "pkg", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0" },
        .verified = true,
    };
    const host: Host = .{ .zig = try std.fs.path.join(a, &.{ abs, "zig" }), .cache_root = abs, .global_cache = abs, .packages = abs };
    var ctx = try wireContext(provider, host, abs, run);
    try ctx.validate(run.needs_project);
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
    };
    const host: Host = .{ .zig = try std.fs.path.join(a, &.{ abs, "zig" }), .cache_root = abs, .global_cache = abs, .packages = abs };
    var provider: Provider = .{
        .dep = .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
        .dir = try std.fs.path.join(a, &.{ abs, "pkg" }),
        .meta = .{ .name = "pkg", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0" },
        .verified = true,
    };
    // An open v1 range: negotiated to 1.1.0, which carries the key.
    const open = try wireContext(provider, host, abs, run);
    try open.validate(true);
    try std.testing.expectEqualStrings("1.1.0", open.contract_version);
    try std.testing.expectEqualStrings("42", open.build_number.?);
    const open_wire = try std.json.Stringify.valueAlloc(a, open, .{});
    try std.testing.expect(std.mem.indexOf(u8, open_wire, "\"build_number\":\"42\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, open_wire, "\"contract_version\":\"1.1.0\"") != null);
    // A provider capped at the 1.0 wire: the exact 1.0.0 wire, no key — so
    // its strict decoder sees nothing unknown.
    provider.meta.command_contract = ">=1.0.0 <1.1.0";
    const capped = try wireContext(provider, host, abs, run);
    try capped.validate(true);
    try std.testing.expectEqualStrings("1.0.0", capped.contract_version);
    try std.testing.expect(capped.build_number == null);
    const capped_wire = try std.json.Stringify.valueAlloc(a, capped, .{});
    try std.testing.expect(std.mem.indexOf(u8, capped_wire, "build_number") == null);
    try std.testing.expect(std.mem.indexOf(u8, capped_wire, "\"contract_version\":\"1.0.0\"") != null);
    // A range the CLI cannot speak at all is refused, never guessed.
    provider.meta.command_contract = ">=2.0.0";
    try std.testing.expectError(error.UnsupportedContract, wireContext(provider, host, abs, run));
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
