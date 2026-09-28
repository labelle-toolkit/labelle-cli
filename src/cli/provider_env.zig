//! Environment contributions (provider contract §2, wire `1.3.0`+): the
//! `env_file` a `before generate`, `after generate` or `before build` hook
//! may write, and the environment the CLI builds from them.
//!
//! - `parseFile` decodes one file strictly and checks every rule that needs
//!   no other hook: the JSON shape, names, reserved names and PATH entries.
//! - `Accumulator` merges the files of the hooks that ran in one build, in
//!   hook execution order, and reports a conflict naming both hooks.
//! - `Accumulator.plan` turns the merge into the assignments made on an
//!   inherited environment; `apply`/`compose` make them on an
//!   `Environ.Map`.
//!
//! The Windows rules (case-insensitive names that keep the inherited
//! spelling) are a parameter rather than the build target, so they are
//! exercised by the tests on every host.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("provider_contract.zig");
const config = @import("config.zig");

pub const native_windows = builtin.os.tag == .windows;

pub const Var = struct { name: []const u8, value: []const u8 };

/// The `env_file` document. Both keys may be omitted; any other key is an
/// error.
pub const File = struct {
    set: []const Var = &.{},
    path_prepend: []const []const u8 = &.{},
};

/// Why a file or a merge was refused, as one line for the diagnostic that
/// names the hook. Owned by the allocator the failing call received.
pub const Diagnostic = struct {
    message: []const u8 = "",
};

fn fail(a: std.mem.Allocator, diag: *Diagnostic, comptime fmt: []const u8, args: anytype) error{ InvalidEnvFile, OutOfMemory } {
    diag.message = try std.fmt.allocPrint(a, fmt, args);
    return error.InvalidEnvFile;
}

fn eqlName(x: []const u8, y: []const u8, windows: bool) bool {
    return if (windows) std.ascii.eqlIgnoreCase(x, y) else std.mem.eql(u8, x, y);
}

/// Windows paths compare case-insensitively; POSIX paths byte for byte.
fn eqlPath(x: []const u8, y: []const u8, windows: bool) bool {
    return eqlName(x, y, windows);
}

fn absoluteOn(path: []const u8, windows: bool) bool {
    return if (windows) contract.windowsVolumeQualified(path) else std.fs.path.isAbsolutePosix(path);
}

pub fn pathSeparator(windows: bool) u8 {
    return if (windows) ';' else ':';
}

/// Decode one `env_file` strictly. `windows` selects the host's name and
/// path rules. Empty or whitespace-only content is an error: a hook that
/// has nothing to contribute leaves the file absent.
pub fn parseFile(a: std.mem.Allocator, bytes: []const u8, windows: bool, diag: *Diagnostic) !File {
    if (std.mem.trim(u8, bytes, " \t\r\n").len == 0) return fail(a, diag, "the file is empty (write nothing to contribute nothing)", .{});
    const parsed = std.json.parseFromSliceLeaky(File, a, bytes, .{
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
        .allocate = .alloc_always,
    }) catch |err| return fail(a, diag, "not a valid env_file document ({s}); expected {{\"set\":[{{\"name\":...,\"value\":...}}],\"path_prepend\":[...]}}", .{@errorName(err)});
    for (parsed.set, 0..) |entry, i| {
        if (!contract.envName(entry.name)) return fail(a, diag, "invalid variable name '{s}' (names match [A-Za-z_][A-Za-z0-9_]*)", .{entry.name});
        if (config.reservedEnvName(entry.name, windows)) {
            if (eqlName(entry.name, "PATH", windows)) return fail(a, diag, "'{s}' cannot be set; extend it with path_prepend", .{entry.name});
            return fail(a, diag, "'{s}' is reserved by the CLI and cannot be set", .{entry.name});
        }
        if (std.mem.indexOfScalar(u8, entry.value, 0) != null) return fail(a, diag, "the value of '{s}' contains a NUL byte", .{entry.name});
        for (parsed.set[0..i]) |previous| {
            if (eqlName(previous.name, entry.name, windows)) return fail(a, diag, "'{s}' is set twice", .{entry.name});
        }
    }
    const sep = pathSeparator(windows);
    for (parsed.path_prepend) |dir| {
        if (dir.len == 0 or std.mem.indexOfScalar(u8, dir, 0) != null or !absoluteOn(dir, windows))
            return fail(a, diag, "path_prepend entry '{s}' is not an absolute path", .{dir});
        if (std.mem.indexOfScalar(u8, dir, sep) != null)
            return fail(a, diag, "path_prepend entry '{s}' contains the PATH separator '{c}'", .{ dir, sep });
    }
    return parsed;
}

/// The largest `env_file` the CLI reads. A bigger one is an invalid file,
/// reported like a malformed one.
pub const max_file_bytes: usize = 1024 * 1024;

/// Read an `env_file` a hook may have written: null when it does not exist
/// (the hook contributed nothing). `error.StreamTooLong` when it exceeds
/// `cap` bytes (`max_file_bytes` in production).
pub fn readFile(a: std.mem.Allocator, path: []const u8, cap: usize) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, a, .limited(cap)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// The merged contributions of the hooks that ran in one build. Everything
/// lives on its own arena, released by `reset` (a rebuild starts fresh) and
/// `deinit`.
pub const Accumulator = struct {
    arena: ?std.heap.ArenaAllocator = null,
    vars: std.ArrayList(Entry) = .empty,
    path: std.ArrayList([]const u8) = .empty,
    /// The Windows name and path rules. The host's; a parameter for tests.
    windows: bool = native_windows,

    pub const Entry = struct { name: []const u8, value: []const u8, hook: []const u8 };

    pub fn isEmpty(self: *const Accumulator) bool {
        return self.vars.items.len == 0 and self.path.items.len == 0;
    }

    /// Forget every contribution: the next build starts from the inherited
    /// environment alone, so a hook that no longer runs leaves nothing.
    pub fn reset(self: *Accumulator) void {
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
        self.vars = .empty;
        self.path = .empty;
    }

    pub fn deinit(self: *Accumulator) void {
        self.reset();
    }

    /// Whether two accumulators make the same environment: the same
    /// variables with the same values, and the same PATH entries, in order
    /// (names folded on Windows). Which hook contributed is not compared.
    pub fn sameAs(self: *const Accumulator, other: *const Accumulator) bool {
        if (self.vars.items.len != other.vars.items.len or self.path.items.len != other.path.items.len) return false;
        for (self.vars.items, other.vars.items) |x, y| {
            if (!eqlName(x.name, y.name, self.windows) or !std.mem.eql(u8, x.value, y.value)) return false;
        }
        for (self.path.items, other.path.items) |x, y| {
            if (!eqlPath(x, y, self.windows)) return false;
        }
        return true;
    }

    /// A deep copy on its own arena (from `backing`): a second owner — a
    /// watch session's rebuild thread — may reset or free either copy
    /// without touching the other's storage.
    pub fn clone(self: *const Accumulator, backing: std.mem.Allocator) !Accumulator {
        var copy: Accumulator = .{ .windows = self.windows };
        if (self.isEmpty()) return copy;
        copy.arena = std.heap.ArenaAllocator.init(backing);
        errdefer copy.deinit();
        const a = copy.arena.?.allocator();
        for (self.vars.items) |entry| {
            try copy.vars.append(a, .{ .name = try a.dupe(u8, entry.name), .value = try a.dupe(u8, entry.value), .hook = try a.dupe(u8, entry.hook) });
        }
        for (self.path.items) |dir| try copy.path.append(a, try a.dupe(u8, dir));
        return copy;
    }

    /// Merge `hook`'s file after every earlier hook's. A name another hook
    /// already set to a different value is a conflict naming both hooks
    /// (`diag`, allocated with `diag_a`); the same value is accepted. PATH
    /// entries keep the first occurrence.
    pub fn add(self: *Accumulator, backing: std.mem.Allocator, diag_a: std.mem.Allocator, hook: []const u8, file: File, diag: *Diagnostic) !void {
        for (file.set) |entry| {
            for (self.vars.items) |existing| {
                if (!eqlName(existing.name, entry.name, self.windows)) continue;
                if (!std.mem.eql(u8, existing.value, entry.value))
                    return fail(diag_a, diag, "'{s}' is set to different values by hooks '{s}' and '{s}'", .{ entry.name, existing.hook, hook });
            }
        }
        if (self.arena == null) self.arena = std.heap.ArenaAllocator.init(backing);
        const a = self.arena.?.allocator();
        const owned_hook = try a.dupe(u8, hook);
        outer: for (file.set) |entry| {
            for (self.vars.items) |existing| {
                if (eqlName(existing.name, entry.name, self.windows)) continue :outer;
            }
            try self.vars.append(a, .{ .name = try a.dupe(u8, entry.name), .value = try a.dupe(u8, entry.value), .hook = owned_hook });
        }
        outer: for (file.path_prepend) |dir| {
            for (self.path.items) |existing| {
                if (eqlPath(existing, dir, self.windows)) continue :outer;
            }
            try self.path.append(a, try a.dupe(u8, dir));
        }
    }

    /// The assignments that make the merged environment out of `inherited`:
    /// every contributed variable overrides the inherited one, under the
    /// inherited key's spelling when the rules fold case (a Windows `Path`
    /// stays `Path`), and PATH gets the contributed entries in front of the
    /// inherited value. Pure; allocated with `a`.
    pub fn plan(self: *const Accumulator, a: std.mem.Allocator, inherited: []const Var) ![]Var {
        var out: std.ArrayList(Var) = .empty;
        for (self.vars.items) |entry| {
            try out.append(a, .{ .name = self.spelling(inherited, entry.name), .value = entry.value });
        }
        if (self.path.items.len != 0) {
            const sep = pathSeparator(self.windows);
            var value: std.ArrayList(u8) = .empty;
            for (self.path.items, 0..) |dir, i| {
                if (i != 0) try value.append(a, sep);
                try value.appendSlice(a, dir);
            }
            const key = self.spelling(inherited, "PATH");
            for (inherited) |entry| {
                if (eqlName(entry.name, key, self.windows) and entry.value.len != 0) {
                    try value.append(a, sep);
                    try value.appendSlice(a, entry.value);
                    break;
                }
            }
            try out.append(a, .{ .name = key, .value = value.items });
        }
        return out.items;
    }

    fn spelling(self: *const Accumulator, inherited: []const Var, name: []const u8) []const u8 {
        for (inherited) |entry| {
            if (eqlName(entry.name, name, self.windows)) return entry.name;
        }
        return name;
    }

    /// Make the merged environment on `map` (the host's rules).
    pub fn apply(self: *const Accumulator, map: *std.process.Environ.Map) !void {
        if (self.isEmpty()) return;
        var scratch = std.heap.ArenaAllocator.init(map.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const inherited = try a.alloc(Var, map.keys().len);
        for (map.keys(), map.values(), inherited) |key, value, *entry| entry.* = .{ .name = key, .value = value };
        const assignments = try self.plan(a, inherited);
        // Copied first: `put` may free the inherited value a planned PATH
        // was composed from.
        for (assignments) |*assignment| assignment.* = .{ .name = try a.dupe(u8, assignment.name), .value = try a.dupe(u8, assignment.value) };
        for (assignments) |assignment| try map.put(assignment.name, assignment.value);
    }

    /// A copy of `base` with the merged environment applied; the caller
    /// deinits it.
    pub fn compose(self: *const Accumulator, a: std.mem.Allocator, base: *const std.process.Environ.Map) !std.process.Environ.Map {
        var map = try base.clone(a);
        errdefer map.deinit();
        try self.apply(&map);
        return map;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

fn parseOk(a: std.mem.Allocator, bytes: []const u8, windows: bool) !File {
    var diag: Diagnostic = .{};
    return parseFile(a, bytes, windows, &diag);
}

fn parseFails(a: std.mem.Allocator, bytes: []const u8, windows: bool, needle: []const u8) !void {
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.InvalidEnvFile, parseFile(a, bytes, windows, &diag));
    if (std.mem.indexOf(u8, diag.message, needle) == null) {
        std.debug.print("diagnostic '{s}' lacks '{s}'\n", .{ diag.message, needle });
        return error.TestUnexpectedResult;
    }
}

fn find(assignments: []const Var, name: []const u8) ?[]const u8 {
    for (assignments) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
    return null;
}

test "provider env: the env_file document is strict JSON with two optional keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file = try parseOk(a, "{\"set\":[{\"name\":\"TOOLCHAIN_ROOT\",\"value\":\"/sdk\"}],\"path_prepend\":[\"/sdk/bin\"]}", false);
    try std.testing.expectEqualStrings("TOOLCHAIN_ROOT", file.set[0].name);
    try std.testing.expectEqualStrings("/sdk/bin", file.path_prepend[0]);
    // Either key may be omitted; an empty object contributes nothing.
    try std.testing.expectEqual(@as(usize, 0), (try parseOk(a, "{}", false)).set.len);
    try std.testing.expectEqual(@as(usize, 1), (try parseOk(a, "{\"path_prepend\":[\"/x\"]}", false)).path_prepend.len);
    // Empty content and malformed documents are refused with a reason.
    try parseFails(a, "", false, "empty");
    try parseFails(a, " \n\t", false, "empty");
    try parseFails(a, "{\"set\":", false, "not a valid env_file");
    try parseFails(a, "[]", false, "not a valid env_file");
    try parseFails(a, "{\"set\":[],\"typo\":1}", false, "UnknownField");
    try parseFails(a, "{\"set\":[{\"name\":\"A\",\"value\":\"1\",\"extra\":2}]}", false, "UnknownField");
    try parseFails(a, "{\"set\":[{\"name\":\"A\"}]}", false, "MissingField");
    try parseFails(a, "{\"set\":[],\"set\":[]}", false, "DuplicateField");
    try parseFails(a, "{\"set\":[{\"name\":\"A\",\"value\":1}]}", false, "not a valid env_file");
}

test "provider env: names, reserved names and PATH entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "", "1ABC", "HAS SPACE", "A=B", "A-B", "É" }) |name| {
        const doc = try std.fmt.allocPrint(a, "{{\"set\":[{{\"name\":\"{s}\",\"value\":\"x\"}}]}}", .{name});
        try parseFails(a, doc, false, "invalid variable name");
    }
    // Reserved: the fixed CLI-owned table; PATH is pointed at path_prepend.
    try parseFails(a, "{\"set\":[{\"name\":\"PATH\",\"value\":\"/x\"}]}", false, "path_prepend");
    for ([_][]const u8{ "ZIG_GLOBAL_CACHE_DIR", "ZIG_LOCAL_CACHE_DIR", "LABELLE_HOME", "LABELLE_CONTEXT", "LABELLE_OFFLINE", "LABELLE_ZIG", "LABELLE_ASSEMBLER" }) |name| {
        const doc = try std.fmt.allocPrint(a, "{{\"set\":[{{\"name\":\"{s}\",\"value\":\"x\"}}]}}", .{name});
        try parseFails(a, doc, false, "reserved");
    }
    // Not a prefix ban: a LABELLE_* name the CLI does not own stays settable.
    _ = try parseOk(a, "{\"set\":[{\"name\":\"LABELLE_DATA_DIR\",\"value\":\"/data\"}]}", false);
    _ = try parseOk(a, "{\"set\":[{\"name\":\"_private1\",\"value\":\"\"}]}", false);
    // Windows folds case for reserved names; POSIX does not.
    try parseFails(a, "{\"set\":[{\"name\":\"Path\",\"value\":\"x\"}]}", true, "path_prepend");
    try parseFails(a, "{\"set\":[{\"name\":\"labelle_home\",\"value\":\"x\"}]}", true, "reserved");
    _ = try parseOk(a, "{\"set\":[{\"name\":\"Path\",\"value\":\"x\"}]}", false);
    // A name set twice in one file (case-folded on Windows).
    try parseFails(a, "{\"set\":[{\"name\":\"A\",\"value\":\"1\"},{\"name\":\"A\",\"value\":\"1\"}]}", false, "set twice");
    try parseFails(a, "{\"set\":[{\"name\":\"A\",\"value\":\"1\"},{\"name\":\"a\",\"value\":\"1\"}]}", true, "set twice");
    _ = try parseOk(a, "{\"set\":[{\"name\":\"A\",\"value\":\"1\"},{\"name\":\"a\",\"value\":\"1\"}]}", false);
    // PATH entries: absolute for the host, no separator inside.
    for ([_][]const u8{ "relative/bin", "./bin", "" }) |dir| {
        const doc = try std.fmt.allocPrint(a, "{{\"path_prepend\":[\"{s}\"]}}", .{dir});
        try parseFails(a, doc, false, "not an absolute path");
        try parseFails(a, doc, true, "not an absolute path");
    }
    try parseFails(a, "{\"path_prepend\":[\"/a:/b\"]}", false, "separator");
    try parseFails(a, "{\"path_prepend\":[\"C:\\\\a;C:\\\\b\"]}", true, "separator");
    // A rooted path is not absolute on Windows (it depends on the drive).
    try parseFails(a, "{\"path_prepend\":[\"/usr/bin\"]}", true, "not an absolute path");
    _ = try parseOk(a, "{\"path_prepend\":[\"C:\\\\sdk\\\\bin\",\"//server/share/bin\"]}", true);
    try parseFails(a, "{\"path_prepend\":[\"C:\\\\sdk\"]}", false, "not an absolute path");
}

test "provider env: merge order, override, conflicts and PATH order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var acc: Accumulator = .{ .windows = false };
    defer acc.deinit();
    var diag: Diagnostic = .{};
    try acc.add(std.testing.allocator, a, "sdk/toolchain", try parseOk(a, "{\"set\":[{\"name\":\"TOOLCHAIN_ROOT\",\"value\":\"/sdk\"},{\"name\":\"TOOLCHAIN_CONFIG\",\"value\":\"/sdk/cfg\"}],\"path_prepend\":[\"/sdk/up\",\"/sdk/node\"]}", false), &diag);
    // The same value from a later hook is fine; its new PATH entries follow,
    // and a repeated one keeps its first position.
    try acc.add(std.testing.allocator, a, "other/prep", try parseOk(a, "{\"set\":[{\"name\":\"TOOLCHAIN_ROOT\",\"value\":\"/sdk\"},{\"name\":\"EXTRA\",\"value\":\"1\"}],\"path_prepend\":[\"/tools\",\"/sdk/up\"]}", false), &diag);
    // A different value is a conflict naming both hooks, and changes nothing.
    try std.testing.expectError(error.InvalidEnvFile, acc.add(std.testing.allocator, a, "late/hook", try parseOk(a, "{\"set\":[{\"name\":\"EXTRA\",\"value\":\"2\"}],\"path_prepend\":[\"/never\"]}", false), &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "'other/prep'") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "'late/hook'") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "EXTRA") != null);
    const inherited = [_]Var{ .{ .name = "TOOLCHAIN_ROOT", .value = "/stale" }, .{ .name = "PATH", .value = "/usr/bin:/bin" }, .{ .name = "HOME", .value = "/h" } };
    const out = try acc.plan(a, &inherited);
    // A contribution overrides the inherited value.
    try std.testing.expectEqualStrings("/sdk", find(out, "TOOLCHAIN_ROOT").?);
    try std.testing.expectEqualStrings("1", find(out, "EXTRA").?);
    try std.testing.expect(find(out, "HOME") == null); // untouched, so not assigned
    // Hook order, then list order, deduplicated keeping the first, in front
    // of the inherited PATH.
    try std.testing.expectEqualStrings("/sdk/up:/sdk/node:/tools:/usr/bin:/bin", find(out, "PATH").?);
    // No inherited PATH: the entries alone.
    const bare = try acc.plan(a, &.{});
    try std.testing.expectEqualStrings("/sdk/up:/sdk/node:/tools", find(bare, "PATH").?);
    // A fresh build forgets every contribution.
    acc.reset();
    try std.testing.expect(acc.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), (try acc.plan(a, &inherited)).len);
}

test "provider env: Windows rules fold case and keep the inherited spelling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var acc: Accumulator = .{ .windows = true };
    defer acc.deinit();
    var diag: Diagnostic = .{};
    try acc.add(std.testing.allocator, a, "sdk/toolchain", try parseOk(a, "{\"set\":[{\"name\":\"TOOLCHAIN_ROOT\",\"value\":\"C:\\\\sdk\"}],\"path_prepend\":[\"C:\\\\sdk\\\\up\"]}", true), &diag);
    // `Toolchain_Root` is `TOOLCHAIN_ROOT`: the same value is accepted, a different one conflicts.
    try acc.add(std.testing.allocator, a, "b/same", try parseOk(a, "{\"set\":[{\"name\":\"Toolchain_Root\",\"value\":\"C:\\\\sdk\"}],\"path_prepend\":[\"c:\\\\SDK\\\\UP\",\"D:\\\\t\"]}", true), &diag);
    try std.testing.expectError(error.InvalidEnvFile, acc.add(std.testing.allocator, a, "c/other", try parseOk(a, "{\"set\":[{\"name\":\"toolchain_root\",\"value\":\"D:\\\\x\"}]}", true), &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "'sdk/toolchain' and 'c/other'") != null);
    const inherited = [_]Var{ .{ .name = "Toolchain_Root", .value = "C:\\stale" }, .{ .name = "Path", .value = "C:\\Windows" } };
    const out = try acc.plan(a, &inherited);
    // The inherited spellings are kept; PATH dedup is case-insensitive too.
    try std.testing.expectEqualStrings("C:\\sdk", find(out, "Toolchain_Root").?);
    try std.testing.expect(find(out, "TOOLCHAIN_ROOT") == null);
    try std.testing.expectEqualStrings("C:\\sdk\\up;D:\\t;C:\\Windows", find(out, "Path").?);
    try std.testing.expect(find(out, "PATH") == null);
    // The same merge under POSIX rules: three distinct names, no conflict.
    var posix: Accumulator = .{ .windows = false };
    defer posix.deinit();
    try posix.add(std.testing.allocator, a, "a/x", .{ .set = &.{.{ .name = "TOOLCHAIN_ROOT", .value = "1" }} }, &diag);
    try posix.add(std.testing.allocator, a, "b/x", .{ .set = &.{.{ .name = "Toolchain_Root", .value = "2" }} }, &diag);
    try std.testing.expectEqual(@as(usize, 2), posix.vars.items.len);
}

test "provider env: apply and compose make the merge on a real environment map" {
    var acc: Accumulator = .{};
    defer acc.deinit();
    var diag: Diagnostic = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const abs = if (native_windows) "C:\\sdk\\bin" else "/sdk/bin";
    try acc.add(std.testing.allocator, a, "p/h", .{ .set = &.{.{ .name = "PROBE_VAR", .value = "v" }}, .path_prepend = &.{abs} }, &diag);
    var base = std.process.Environ.Map.init(std.testing.allocator);
    defer base.deinit();
    try base.put("PATH", "/usr/bin");
    try base.put("PROBE_VAR", "old");
    var composed = try acc.compose(std.testing.allocator, &base);
    defer composed.deinit();
    try std.testing.expectEqualStrings("v", composed.get("PROBE_VAR").?);
    const expected_path = try std.fmt.allocPrint(a, "{s}{c}/usr/bin", .{ abs, pathSeparator(native_windows) });
    try std.testing.expectEqualStrings(expected_path, composed.get("PATH").?);
    // The base is untouched: the next build composes from it again.
    try std.testing.expectEqualStrings("old", base.get("PROBE_VAR").?);
    // Nothing contributed: the copy equals the base.
    acc.reset();
    var plain = try acc.compose(std.testing.allocator, &base);
    defer plain.deinit();
    try std.testing.expectEqualStrings("old", plain.get("PROBE_VAR").?);
}

test "provider env: a missing file is no contribution" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = config.globalIo();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "env.json" });
    defer std.testing.allocator.free(path);
    try std.testing.expect((try readFile(std.testing.allocator, path, max_file_bytes)) == null);
    try tmp.dir.writeFile(io, .{ .sub_path = "env.json", .data = "{}" });
    try std.testing.expectError(error.StreamTooLong, readFile(std.testing.allocator, path, 1));
    const bytes = (try readFile(std.testing.allocator, path, max_file_bytes)).?;
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{}", bytes);
}

test "provider env: a clone owns its storage; freeing or replacing either leaves the other intact" {
    const a = std.testing.allocator;
    var diag: Diagnostic = .{};
    var original: Accumulator = .{};
    try original.add(a, a, "pkg/tc", .{ .set = &.{.{ .name = "PROBE_TOOLCHAIN", .value = "one" }}, .path_prepend = &.{"/abs/bin"} }, &diag);
    var copy = try original.clone(a);
    // The rebuild's side frees its copy and builds a new one: the session's
    // original still reads its values.
    copy.deinit();
    copy = try original.clone(a);
    try copy.add(a, a, "pkg/other", .{ .set = &.{.{ .name = "EXTRA", .value = "x" }} }, &diag);
    try std.testing.expectEqual(@as(usize, 1), original.vars.items.len);
    try std.testing.expectEqualStrings("one", original.vars.items[0].value);
    try std.testing.expectEqualStrings("/abs/bin", original.path.items[0]);
    try std.testing.expect(original.vars.items[0].value.ptr != copy.vars.items[0].value.ptr);
    original.deinit();
    try std.testing.expectEqualStrings("one", copy.vars.items[0].value);
    copy.deinit();
    // An empty accumulator clones without an arena.
    const empty = try (Accumulator{}).clone(a);
    try std.testing.expect(empty.arena == null);
}

test "provider env: sameAs compares the resulting environment, not who contributed it" {
    const a = std.testing.allocator;
    var diag: Diagnostic = .{};
    var x: Accumulator = .{};
    defer x.deinit();
    var y: Accumulator = .{};
    defer y.deinit();
    try std.testing.expect(x.sameAs(&y));
    try x.add(a, a, "pkg/a", .{ .set = &.{.{ .name = "SDK_ROOT", .value = "/one" }} }, &diag);
    try y.add(a, a, "pkg/b", .{ .set = &.{.{ .name = "SDK_ROOT", .value = "/one" }} }, &diag);
    try std.testing.expect(x.sameAs(&y));
    var z: Accumulator = .{};
    defer z.deinit();
    try z.add(a, a, "pkg/a", .{ .set = &.{.{ .name = "SDK_ROOT", .value = "/two" }} }, &diag);
    try std.testing.expect(!x.sameAs(&z));
    try y.add(a, a, "pkg/b", .{ .path_prepend = &.{"/abs/bin"} }, &diag);
    try std.testing.expect(!x.sameAs(&y));
}
