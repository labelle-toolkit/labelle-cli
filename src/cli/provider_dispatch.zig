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
const settings_mod = @import("provider_settings.zig");
const provider_env = @import("provider_env.zig");
const provider_cache = @import("provider_cache.zig");
const python_provision = @import("python_provision.zig");

// Existing platform commands remain reserved until their extraction lands;
// an extracted one leaves the list and its namespace becomes dispatchable
// (cli#405, and RFC cli#466 PR B for the legacy browser commands).
pub const reserved = [_][]const u8{
    "generate", "build",     "bundle",    "run",       "init",   "add",   "install", "update",
    "upgrade",  "clean",     "test",      "pack",      "astc",   "audit", "migrate", "check",
    "plugins",  "doctor",    "assembler", "toolchain", "status", "ios",   "help",    "version",
    "targets",  "providers",
};
pub const Provider = struct { dep: project.PluginDep, dir: []const u8, meta: manifest.Manifest, verified: bool };

fn read(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, a, .limited(1024 * 1024));
}
fn real(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), path, a);
}

pub fn projectRoot(a: std.mem.Allocator) !?[]const u8 {
    return projectRootFrom(a, ".");
}

/// The nearest directory at or above `start` holding a `project.labelle`.
pub fn projectRootFrom(a: std.mem.Allocator, start: []const u8) !?[]const u8 {
    var dir: []const u8 = try real(a, start);
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
    return discoverImpl(a, root, cfg, sources, cache_state, null);
}

/// A pinned provider whose source could not be obtained from its lock
/// entry: its archive is not cached, does not match its pin, or the pin
/// itself is stale. `err` is what `Sources.projectDir` returned.
pub const Unavailable = struct { package: []const u8, err: anyerror };

pub const Survey = struct {
    providers: []Provider,
    /// As `Discovery.unresolved`.
    unresolved: []const []const u8,
    /// Verified (pinned or local) providers whose source or manifest could
    /// not be read, in declaration order.
    unavailable: []const Unavailable,
    /// Cached remote packages with no integrity pin whose manifest is a
    /// provider's or could not be read or parsed. Never in `providers`, and
    /// never validated against the others: unverified bytes cannot fail the
    /// verified providers' discovery.
    unverified: []const []const u8,
};

const SurveyLists = struct {
    unavailable: std.ArrayList(Unavailable) = .empty,
    unverified: std.ArrayList([]const u8) = .empty,
};

/// Metadata-only discovery (`.unknown`) that, unlike `discoverAll`, does not
/// abort on one provider's missing or mismatched pinned archive: that
/// package is reported in `unavailable` (after `Sources.projectDir` printed
/// its `labelle providers fetch` hint) and treated like an unread package, so
/// the others stay usable. `labelle doctor` reads the project this way, so a
/// provider it cannot obtain is a failed check rather than the end of the
/// report. It never downloads.
///
/// One package never fails the others' discovery: a verified provider whose
/// manifest is unreadable, malformed or misnamed is `unavailable`, and a
/// cached unpinned package whose manifest is a provider's (or unreadable) is
/// `unverified`, exactly as it would be `unresolved` with a cold cache. An
/// unpinned manifest is read only to tell a runtime-only package (skipped)
/// from a provider; nothing it declares is validated or used.
pub fn survey(a: std.mem.Allocator, root: []const u8, cfg: project.ProjectConfig, sources: *github.Sources) !Survey {
    var lists: SurveyLists = .{};
    const found = try discoverImpl(a, root, cfg, sources, .unknown, &lists);
    return .{ .providers = found.providers, .unresolved = found.unresolved, .unavailable = lists.unavailable.items, .unverified = lists.unverified.items };
}

fn discoverImpl(a: std.mem.Allocator, root: []const u8, cfg: project.ProjectConfig, sources: *github.Sources, cache_state: CacheState, lists: ?*SurveyLists) !Discovery {
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
            error.OutOfMemory => return err,
            else => if (lists) |l| {
                // Unread, so a hook reference into it is deferred like an
                // uncached package's rather than reported missing.
                try l.unavailable.append(a, .{ .package = dep.name, .err = err });
                try unresolved.append(a, dep.name);
                continue;
            } else return err,
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
        const verified = dep.isLocal() or pinned != null;
        const path = try std.fs.path.join(a, &.{ dir, "plugin.labelle" });
        const bytes = read(a, path) catch |err| switch (err) {
            error.FileNotFound => continue, // Runtime plugins may have no manifest.
            error.OutOfMemory => return err,
            else => {
                if (lists) |l| {
                    try isolate(a, l, &unresolved, dep.name, verified, err);
                    continue;
                }
                return err;
            },
        };
        const meta = manifest.parse(a, bytes) catch |err| {
            // Unverified bytes: recorded without a diagnostic of their own.
            if (lists != null and !verified) {
                try isolate(a, lists.?, &unresolved, dep.name, verified, err);
                continue;
            }
            std.debug.print("labelle: provider manifest '{s}': {s} (CLI contract {s})\n", .{ path, @errorName(err), contract.version });
            if (lists) |l| {
                try isolate(a, l, &unresolved, dep.name, verified, err);
                continue;
            }
            return err;
        };
        if (!meta.isProvider()) continue;
        if (lists != null and !verified) {
            try isolate(a, lists.?, &unresolved, dep.name, verified, error.RemoteProviderIntegrityRequired);
            continue;
        }
        if (!std.mem.eql(u8, dep.name, meta.name)) {
            if (lists) |l| {
                try isolate(a, l, &unresolved, dep.name, verified, error.ProviderNameMismatch);
                continue;
            }
            return error.ProviderNameMismatch;
        }
        const names = try a.alloc([]const u8, if (meta.namespace != null) 1 else 0);
        if (meta.namespace) |ns| names[0] = ns;
        try owners.append(a, .{ .package = meta.name, .namespaces = names, .targets = meta.targets });
        try providers.append(a, .{ .dep = dep, .dir = try real(a, dir), .meta = meta, .verified = verified });
    }
    try contract.validateOwnership(owners.items, &reserved);
    // Hook references into an unverified package are deferred like ones into
    // an unread package: neither can be checked.
    var deferred: std.ArrayList([]const u8) = .empty;
    try deferred.appendSlice(a, unresolved.items);
    if (lists) |l| try deferred.appendSlice(a, l.unverified.items);
    try hooks.validateAll(a, providers.items, deferred.items);
    return .{ .providers = providers.items, .unresolved = unresolved.items };
}

/// Survey mode: record one package's failure against that package only. A
/// verified one is `unavailable` (and unread, so references into it are
/// deferred); an unverified one is `unverified`, whatever the reason.
fn isolate(a: std.mem.Allocator, lists: *SurveyLists, unresolved: *std.ArrayList([]const u8), name: []const u8, verified: bool, err: anyerror) !void {
    if (verified) {
        try lists.unavailable.append(a, .{ .package = name, .err = err });
        try unresolved.append(a, name);
    } else {
        try lists.unverified.append(a, name);
    }
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
            return try runCommand(a, root, cfg, providers, provider, cmd, trailing.items, .all, null, null);
        }
        std.debug.print("labelle: unknown command '{s}' in provider namespace '{s}'\n", .{ name, namespace });
        printCommands(provider);
        return 1;
    }
    return null;
}

/// Run one provider command: the lock/integrity check, the provider settings,
/// then the tool build and invocation. `labelle <ns> <cmd>` and the provider
/// part of `labelle doctor` both come through here, so they cannot drift.
///
/// `stdout`, when set, captures the tool's stdout instead of passing it
/// through (`ToolRun.stdout`).
pub fn runCommand(a: std.mem.Allocator, root: []const u8, cfg: project.ProjectConfig, providers: []const Provider, provider: Provider, cmd: manifest.Command, trailing: []const []const u8, scope: SettingsScope, hosts: ?*HostCache, stdout: ?*[]const u8) !u8 {
    const lock_path = try requirePinned(a, root, provider);
    const settings = switch (scope) {
        .all => try resolveSettings(a, root, cfg, providers, provider.meta.name),
        .selected => try resolveOwnSettings(a, root, cfg, provider.meta.name),
    };
    return execute(a, root, cfg, provider, cmd, lock_path, settings, trailing, hosts, stdout);
}

/// Execution (a command or a hook) needs the project's ordinary lock to name
/// this exact provider, and a remote provider to carry an integrity pin.
/// Returns the lock's real path for the wire context.
pub fn requirePinned(a: std.mem.Allocator, root: []const u8, provider: Provider) ![]const u8 {
    return requirePinnedAt(a, try std.fs.path.join(a, &.{ root, "labelle.lock" }), provider);
}

/// `requirePinned` against the lock at `lock_path` (a watched rebuild's
/// staged lock). Returns its canonical path.
pub fn requirePinnedAt(a: std.mem.Allocator, lock_path: []const u8, provider: Provider) ![]const u8 {
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

/// Every `provider_config` entry names a resolved, verified provider. The
/// project-wide mapping check; it opens no file. (Duplicates, undeclared
/// packages and the lexical path shape are already refused when
/// project.labelle is read, `provider_settings.validateProject`.)
pub fn checkSettingsMapping(cfg: project.ProjectConfig, providers: []const Provider) !void {
    for (cfg.provider_config) |entry| {
        var resolved = false;
        for (providers) |provider| {
            if (std.mem.eql(u8, provider.meta.name, entry.package) and provider.verified) resolved = true;
        }
        if (!resolved) {
            std.debug.print("labelle: provider_config '{s}' must name a resolved command/hook provider\n", .{entry.package});
            return error.UnresolvedProviderConfig;
        }
    }
}

/// Open and check one settings file: contained in the project, a regular
/// file, at most 1 MiB, valid JSON. Returns its canonical path.
fn openSettings(a: std.mem.Allocator, root: []const u8, entry: settings_mod.Entry) ![]const u8 {
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
    return path;
}

/// Which settings files an invocation opens.
pub const SettingsScope = enum {
    /// Every `provider_config` entry (`labelle <ns> <cmd>`, hooks): one bad
    /// settings file anywhere in the project stops the invocation.
    all,
    /// Only the selected provider's entry (`labelle doctor`, where each
    /// provider's run must stand alone). The caller checks the mapping
    /// (`checkSettingsMapping`) once for the whole project.
    selected,
};

/// The mapping check plus every settings file (`.all`), returning the
/// selected provider's settings path, or null when it has none.
pub fn resolveSettings(a: std.mem.Allocator, root: []const u8, cfg: project.ProjectConfig, providers: []const Provider, selected: []const u8) !?[]const u8 {
    try checkSettingsMapping(cfg, providers);
    var result: ?[]const u8 = null;
    for (cfg.provider_config) |entry| {
        const path = try openSettings(a, root, entry);
        if (std.mem.eql(u8, entry.package, selected)) result = path;
    }
    return result;
}

/// Only the selected provider's entry is opened (`SettingsScope.selected`).
pub fn resolveOwnSettings(a: std.mem.Allocator, root: []const u8, cfg: project.ProjectConfig, selected: []const u8) !?[]const u8 {
    for (cfg.provider_config) |entry| {
        if (std.mem.eql(u8, entry.package, selected)) return try openSettings(a, root, entry);
    }
    return null;
}

/// The pinned host compiler and the canonical cache tree every provider tool
/// build shares. Resolved once per CLI invocation, lazily, so a project
/// without hooks never touches the compiler check.
pub const Host = struct { zig: []const u8, cache_root: []const u8, global_cache: []const u8, packages: []const u8 };

/// The host compiler comes from the same resolution `labelle build` uses
/// (`zig_toolchain.resolveZig`): the `LABELLE_ZIG` / `--zig` override, else
/// the managed toolchain for the project's required version, provisioned on
/// a cache miss (bundled seed first, else download + minisign verification,
/// installed atomically). Callers check the provider's pins first, so an
/// unpinned provider never triggers a download.
pub fn resolveHost(a: std.mem.Allocator, root: []const u8) !Host {
    return resolveHostWith(a, root, provisionZig);
}

fn provisionZig(a: std.mem.Allocator, root: []const u8) anyerror![]u8 {
    return toolchain.resolveZig(a, root);
}

/// One host resolution per invocation, shared by several provider runs (the
/// provider part of `labelle doctor`). The first `get` resolves; every later
/// one returns the same host, or the same error, so a failed or offline
/// provisioning is attempted once, not once per provider. `a` must outlive
/// the cache (the host's paths live in it).
pub const HostCache = struct {
    resolve: *const fn (std.mem.Allocator, []const u8) anyerror!Host = resolveHost,
    host: ?Host = null,
    failure: ?anyerror = null,
    /// Resolutions attempted (0 or 1).
    calls: usize = 0,

    pub fn get(self: *HostCache, a: std.mem.Allocator, root: []const u8) anyerror!Host {
        if (self.host) |host| return host;
        if (self.failure) |err| return err;
        self.calls += 1;
        const host = self.resolve(a, root) catch |err| {
            self.failure = err;
            return err;
        };
        self.host = host;
        return host;
    }
};

/// `resolveHost` over an injected provisioner (tests).
pub fn resolveHostWith(a: std.mem.Allocator, root: []const u8, provision: *const fn (std.mem.Allocator, []const u8) anyerror![]u8) !Host {
    const required = try toolchain.resolveRequiredVersion(a, root);
    const zig_candidate = try provision(a, root);
    // The same check `labelle doctor` reports for an override. Only an
    // override can name a path that does not exist: the managed path exists
    // once `provision` returned.
    const zig = switch (try toolchain.verifyBinary(a, zig_candidate, required.version)) {
        .ok => |path| path,
        .missing => {
            std.debug.print("labelle: the host compiler override does not exist: {s} (LABELLE_ZIG / --zig)\n", .{zig_candidate});
            return error.ProviderCompilerMissing;
        },
        .not_executable, .failed => return error.ProviderCompilerFailed,
        .version => |reported| {
            std.debug.print("labelle: the host compiler {s} is Zig {s}; this project requires {s}\n", .{ zig_candidate, reported, required.version });
            return error.ProviderCompilerVersionMismatch;
        },
    };

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
    /// Hooks only: the absolute generated target directory (contract §2
    /// `target_dir`, wire `1.2.0`+). Null for commands.
    target_dir: ?[]const u8 = null,
    /// `run`-step hooks only: the `labelle run` options (contract §2 `run`,
    /// wire `1.2.0`+). Null on every other invocation.
    run_options: ?contract.RunContext = null,
    /// Hooks in a `contract.envFileSlot` only: where the hook may write its
    /// environment contribution (contract §2 `env_file`, wire `1.3.0`+).
    /// The caller owns the path and reads it back after the run. Dropped
    /// for a provider whose negotiated wire predates the key.
    env_file: ?[]const u8 = null,
    /// Hooks only: the last lifecycle step of the invoking command (contract
    /// §2 `final_step`, wire `1.4.0`+). Null for commands; dropped for a
    /// provider whose negotiated wire predates the key.
    final_step: ?contract.Step = null,
    /// The environment the earlier hooks of this build contributed. Applied
    /// to the provider tool's own process only, never to the `zig build`
    /// that compiles the tool (contract §2 "Scope").
    env: ?*const provider_env.Accumulator = null,
    /// When set, the tool's stdout is captured into it (at most
    /// `max_captured_stdout` bytes) instead of reaching the CLI's own: the
    /// caller owns stdout (`labelle doctor --json` prints one document).
    /// Its stderr still reaches the CLI's. Allocated with the run's
    /// allocator.
    stdout: ?*[]const u8 = null,
};

/// The most stdout `ToolRun.stdout` captures. A tool that writes more fails
/// with `error.ProviderStdoutTooLarge`.
pub const max_captured_stdout: usize = 1024 * 1024;

/// The wire context for one invocation (contract §2), in the wire version
/// negotiated from the provider's `command_contract` range: the newest one
/// this CLI speaks that the range admits. `build_number` is a `1.1.0` key, so
/// a provider capped below it (`>=1.0.0 <1.1.0`) gets the exact `1.0.0` wire
/// without it — its strict decoder would reject the unknown key and fail
/// the bundle instead of packaging (Codex P2 on #421) — and the drop is
/// reported once on stderr rather than silently. `target_dir` and `run` are
/// `1.2.0` keys and follow the same rule: a provider capped below `1.2.0`
/// gets neither, and a `run` hook of one that the user passed run options
/// for gets one `note:` line saying they did not reach it.
///
/// `cache_dir` and `env_file` are `1.3.0` keys: a provider capped below it
/// gets neither, so its hooks cannot contribute an environment. `cache_dir`
/// is the provider's `ensureCacheDir`. `final_step` is a `1.4.0` key and
/// follows the same rule.
pub fn wireContext(provider: Provider, host: Host, root: []const u8, run: ToolRun, cache_dir: []const u8) !contract.Context {
    const wire = try manifest.negotiate(provider.meta.command_contract orelse return error.MissingCommandContract);
    const build_number = if (run.build_number) |number| blk: {
        if (contract.carriesBuildNumber(wire)) break :blk number;
        std.debug.print("labelle: note: '{s}' speaks provider contract {s}, which has no build_number; --build-number={s} is not passed to it\n", .{ provider.meta.name, wire, number });
        break :blk null;
    } else null;
    const run_context = contract.carriesRunContext(wire);
    const run_options = if (run.run_options) |given_options| blk: {
        var options = given_options;
        // `run.watch` is a `1.3.0` key: an older wire never carries it
        // (`labelle run --watch` refuses such a replacement before any build).
        if (!contract.carriesWatchContext(wire)) options.watch = null;
        // `run.outcome_file` is `1.5.0`: below it the exit status decides.
        if (!contract.carriesOutcomeContext(wire)) options.outcome_file = null;
        if (run_context) break :blk options;
        if (options.given()) std.debug.print("labelle: note: run options not passed to '{s}/{s}' (provider contract {s} < {s})\n", .{
            provider.meta.name, run.invocation.id, wire, contract.run_context_since,
        });
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
        .target_dir = if (run_context) run.target_dir else null,
        .run = run_options,
        .cache_dir = if (contract.carriesToolchainContext(wire)) cache_dir else null,
        .env_file = if (contract.carriesToolchainContext(wire)) run.env_file else null,
        .final_step = if (contract.carriesFinalStep(wire)) run.final_step else null,
    };
}

/// The provider's persistent cache directory (contract §2 `cache_dir`),
/// created: `<LABELLE_HOME>/providers/<canonical provider id>/`
/// (`provider_cache`). `host.cache_root` is the canonical LABELLE_HOME.
pub fn ensureCacheDir(a: std.mem.Allocator, host: Host, provider: Provider) ![]const u8 {
    return canonicalDir(a, try provider_cache.dirPath(a, host.cache_root, provider.dep, provider.dir));
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
    // RFC cli#466 D2: the managed interpreter (`labelle install python`)
    // reaches every provider hook and command, the way it reaches the
    // `.prebuild` steps (`pipeline/install.wirePrebuildPython`), so a
    // machine whose only Python is the managed one runs a provider tool
    // that spawns `python3`. Only an interpreter that actually runs
    // (`managedPythonOk`): a partial or broken install left on disk must not
    // shadow a working system Python. A no-op when none is provisioned, or
    // when its directory is already on PATH; before the environment
    // snapshot below.
    if (python_provision.managedPythonOk(a)) python_provision.autoWireEnv(a);
    var env = try runner.buildZigEnv(a, &.{});
    defer env.deinit();
    // Keep relative LABELLE_HOME stable when child cwd changes to the package.
    try env.put("ZIG_GLOBAL_CACHE_DIR", host.global_cache);
    try env.put("ZIG_LOCAL_CACHE_DIR", try std.fs.path.join(a, &.{ host.cache_root, zig_cache.LOCAL_CACHE_SUBDIR }));
    try env.put("LABELLE_HOME", host.cache_root);
    // Zig owns the complete source/dependency/compiler/options cache identity.
    // Always run the install step: never trust a stale installed executable.
    const build_argv: []const []const u8 = &.{ host.zig, "build", tool.build_step, "--prefix", prefix, "--system", host.packages };
    // When the caller owns stdout (`ToolRun.stdout`), the tool's build must
    // not write there either: its stdout goes to the CLI's stderr.
    const build_code = if (run.stdout != null)
        try runStdoutToStderr(provider.dir, build_argv, &env)
    else
        try runner.runZigInheritWithEnv(a, provider.dir, build_argv, null, &env);
    if (build_code != 0) return build_code;
    if (!contained(run_dir, try real(a, prefix))) return error.EscapingProviderInstall;
    const exe = try executable(a, prefix, tool.executable);
    const wire = try manifest.negotiate(provider.meta.command_contract orelse return error.MissingCommandContract);
    // Created only for a provider that receives it.
    const cache_dir = if (contract.carriesToolchainContext(wire)) try ensureCacheDir(a, host, provider) else "";
    const ctx = try wireContext(provider, host, root, run, cache_dir);
    try ctx.validate(run.needs_project);
    const context_path = try std.fs.path.join(a, &.{ run_dir, "context.json" });
    const data = try std.json.Stringify.valueAlloc(a, ctx, .{});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = context_path, .data = data });
    try env.put(contract.context_env, context_path);
    // The earlier hooks' contributions reach the tool itself, after its
    // own build above ran on the plain environment.
    if (run.env) |contributed| try contributed.apply(&env);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, exe);
    try argv.appendSlice(a, run.trailing);
    if (run.stdout) |sink| return runCapturingStdout(a, run.cwd, argv.items, &env, sink);
    return runner.runZigInheritWithEnv(a, run.cwd, argv.items, null, &env);
}

/// Run `argv` with stdin and stderr inherited and its stdout relayed to the
/// CLI's stderr. Returns the exit status (128 + signal for a signal death).
/// The stdout is piped and copied rather than handed the CLI's stderr
/// handle, which a Windows child cannot be given as its stdout.
fn runStdoutToStderr(cwd: []const u8, argv: []const []const u8, env: *const std.process.Environ.Map) !u8 {
    const io = config.globalIo();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = .inherit,
        .environ_map = env,
    });
    var buffer: [4096]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buffer);
    var err_buffer: [4096]u8 = undefined;
    var relay = std.Io.File.stderr().writerStreaming(io, &err_buffer);
    _ = reader.interface.streamRemaining(&relay.interface) catch |err| {
        child.kill(io);
        return err;
    };
    relay.interface.flush() catch {};
    return exitStatus(try child.wait(io));
}

fn exitStatus(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| 128 +% @as(u8, @truncate(@intFromEnum(sig))),
        .stopped => |sig| 128 +% @as(u8, @truncate(@intFromEnum(sig))),
        .unknown => 1,
    };
}

/// Run `argv` with stdin and stderr inherited and stdout captured into
/// `sink`. Returns the exit status (128 + signal for a signal death). More
/// than `max_captured_stdout` bytes kills the child and fails.
fn runCapturingStdout(a: std.mem.Allocator, cwd: []const u8, argv: []const []const u8, env: *const std.process.Environ.Map, sink: *[]const u8) !u8 {
    const io = config.globalIo();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = .inherit,
        .environ_map = env,
    });
    var buffer: [4096]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buffer);
    const bytes = reader.interface.allocRemaining(a, .limited(max_captured_stdout)) catch |err| {
        child.kill(io);
        return switch (err) {
            error.StreamTooLong => error.ProviderStdoutTooLarge,
            else => err,
        };
    };
    const term = try child.wait(io);
    sink.* = bytes;
    return exitStatus(term);
}

/// A project command: Debug, human progress, output under
/// `.labelle/providers/<package>`, trailing arguments verbatim.
fn execute(a: std.mem.Allocator, root: []const u8, cfg: project.ProjectConfig, provider: Provider, cmd: manifest.Command, lock_path: []const u8, settings: ?[]const u8, trailing: []const []const u8, hosts: ?*HostCache, stdout: ?*[]const u8) !u8 {
    const host = if (hosts) |cache| try cache.get(a, root) else try resolveHost(a, root);
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
        .stdout = stdout,
    });
}

test "provider dispatch: an extracted platform's namespace is no longer reserved" {
    // `android` moved into its provider (cli#405), and the legacy browser
    // subcommands left the core (RFC cli#466 PR B): a package may declare
    // either namespace. The legacy subcommand still built in stays reserved.
    for ([_][]const u8{ "android", "wasm" }) |extracted| {
        for (reserved) |name| try std.testing.expect(!std.mem.eql(u8, name, extracted));
    }
    for ([_][]const u8{ "ios", "run", "build", "bundle" }) |kept| {
        var found = false;
        for (reserved) |name| found = found or std.mem.eql(u8, name, kept);
        try std.testing.expect(found);
    }
}

test {
    _ = @import("provider_dispatch_test.zig");
}
