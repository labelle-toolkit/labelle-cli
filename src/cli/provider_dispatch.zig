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

// Existing platform commands remain reserved until their extraction lands.
pub const reserved = [_][]const u8{
    "generate", "build",   "bundle",    "run",       "init",   "add",   "install", "update",
    "upgrade",  "clean",   "test",      "pack",      "astc",   "audit", "migrate", "check",
    "plugins",  "doctor",  "assembler", "toolchain", "status", "ios",   "android", "wasm",
    "help",     "version", "targets",   "providers",
};
const Provider = struct { dep: project.PluginDep, dir: []const u8, meta: manifest.Manifest, verified: bool };

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

fn discover(a: std.mem.Allocator, root: []const u8, cfg: project.ProjectConfig, sources: *github.Sources) ![]Provider {
    var providers: std.ArrayList(Provider) = .empty;
    var owners: std.ArrayList(contract.Ownership) = .empty;
    for (cfg.plugins) |dep| {
        const pinned = if (dep.isLocal()) null else try sources.projectDir(root, dep);
        const dir = pinned orelse try plugins.resolvePluginDir(a, root, dep);
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
    return providers.items;
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
    const providers = try discover(a, root, cfg, &sources);
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
    const providers = try discover(a, root, cfg, &sources);
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
            const lock_path = try std.fs.path.join(a, &.{ root, "labelle.lock" });
            const lock_bytes = read(a, lock_path) catch |err| {
                std.debug.print("labelle: provider commands require the project's labelle.lock: {s}\n", .{@errorName(err)});
                return error.MissingProjectLock;
            };
            const Lock = struct { plugins: []const project.PluginDep = &.{} };
            const lock = try std.zon.parse.fromSliceAlloc(Lock, a, try a.dupeZ(u8, lock_bytes), null, .{ .ignore_unknown_fields = true });
            try validatePin(provider.dep, lock.plugins);
            if (!provider.verified) {
                std.debug.print("labelle: remote provider '{s}' is unpinned. Run labelle providers resolve, review the pins, then repeat with --accept.\n", .{provider.dep.name});
                return error.RemoteProviderIntegrityRequired;
            }
            const settings = try resolveSettings(a, root, cfg, providers, provider.meta.name);
            return try execute(a, root, cfg, provider, cmd, lock_path, settings, trailing.items);
        }
        std.debug.print("labelle: unknown command '{s}' in provider namespace '{s}'\n", .{ name, namespace });
        printCommands(provider);
        return 1;
    }
    return null;
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

fn resolveSettings(a: std.mem.Allocator, root: []const u8, cfg: project.ProjectConfig, providers: []const Provider, selected: []const u8) !?[]const u8 {
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

fn execute(a: std.mem.Allocator, root: []const u8, cfg: project.ProjectConfig, provider: Provider, cmd: manifest.Command, lock_path: []const u8, settings: ?[]const u8, trailing: []const []const u8) !u8 {
    const io = config.globalIo();
    // Unlike the game runner, command dispatch must never download a compiler.
    const required = try toolchain.resolveRequiredVersion(a, root);
    const zig_candidate = (try toolchain.lookupEnvOverride(a)) orelse try zig_cache.binaryPath(a, required.version);
    const zig = real(a, zig_candidate) catch {
        std.debug.print("labelle: install the pinned host compiler first: labelle install zig {s}\n", .{required.version});
        return error.ProviderCompilerMissing;
    };
    const version = try std.process.run(a, io, .{ .argv = &.{ zig, "version" } });
    if (version.term != .exited or version.term.exited != 0) return error.ProviderCompilerFailed;
    if (!std.mem.eql(u8, std.mem.trim(u8, version.stdout, "\r\n "), required.version)) return error.ProviderCompilerVersionMismatch;

    const cache_root = try github.cacheRoot(a);
    const runs = try std.fs.path.join(a, &.{ cache_root, "provider-runs" });
    try std.Io.Dir.cwd().createDirPath(io, runs);
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
    const global_cache = try std.fs.path.join(a, &.{ cache_root, zig_cache.GLOBAL_CACHE_SUBDIR });
    try env.put("ZIG_GLOBAL_CACHE_DIR", global_cache);
    try env.put("ZIG_LOCAL_CACHE_DIR", try std.fs.path.join(a, &.{ cache_root, zig_cache.LOCAL_CACHE_SUBDIR }));
    try env.put("LABELLE_HOME", cache_root);
    // Zig owns the complete source/dependency/compiler/options cache identity.
    // Always run the install step: never trust a stale installed executable.
    // Zig's system package mode disables fetching. Its package directory is
    // explicit so a missing dependency fails instead of reaching the network.
    const packages = try std.fs.path.join(a, &.{ global_cache, "p" });
    try std.Io.Dir.cwd().createDirPath(io, packages);
    const build_code = try runner.runZigInheritWithEnv(a, provider.dir, &.{ zig, "build", cmd.build_step, "--prefix", prefix, "--system", packages }, null, &env);
    if (build_code != 0) return build_code;
    if (!contained(try real(a, run_dir), try real(a, prefix))) return error.EscapingProviderInstall;
    const exe = try executable(a, prefix, cmd.executable);
    var output: []const u8 = root;
    for ([_][]const u8{ ".labelle", "providers", provider.meta.name }) |segment| {
        output = try std.fs.path.join(a, &.{ output, segment });
        try std.Io.Dir.cwd().createDirPath(io, output);
        output = try real(a, output);
        if (!contained(root, output)) return error.EscapingProviderOutput;
    }
    const ctx: contract.Context = .{
        .contract_version = contract.version,
        .invocation = .{ .kind = .command, .id = cmd.name, .step = null, .phase = null },
        .package_dir = provider.dir,
        .project_dir = root,
        .target = @tagName(cfg.platform),
        .lock_file = try real(a, lock_path),
        .config_file = settings,
        .output_dir = try real(a, output),
        .zig_executable = zig,
        .optimize = .Debug,
        .progress = .human,
    };
    try ctx.validate(cmd.needs_project);
    const context_path = try std.fs.path.join(a, &.{ run_dir, "context.json" });
    const data = try std.json.Stringify.valueAlloc(a, ctx, .{});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = context_path, .data = data });
    try env.put(contract.context_env, context_path);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, exe);
    try argv.appendSlice(a, trailing);
    return runner.runZigInheritWithEnv(a, root, argv.items, null, &env);
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

test "provider dispatch: canonical containment respects component boundaries" {
    try std.testing.expect(contained("/tmp/install", "/tmp/install/bin/tool"));
    try std.testing.expect(!contained("/tmp/install", "/tmp/install-evil/bin/tool"));
    try std.testing.expect(!contained("/tmp/install", "/tmp/install"));
}
