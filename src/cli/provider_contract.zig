//! Provider contract v1. Pure validation; does not resolve or execute packages.
const std = @import("std");

pub const version = "1.0.0";
pub const context_env = "LABELLE_CONTEXT";
pub const Step = enum { generate, build, bundle, run };
pub const Phase = enum { before, replace, after };
pub const Optimize = enum { Debug, ReleaseSafe, ReleaseFast, ReleaseSmall };
pub const Progress = enum { human, json, off };

pub const Invocation = struct {
    kind: enum { command, hook },
    id: []const u8,
    step: ?Step,
    phase: ?Phase,
};

/// All fields are required on the wire, including explicitly null fields.
/// Paths are absolute for the host running the provider.
pub const Context = struct {
    contract_version: []const u8,
    invocation: Invocation,
    package_dir: []const u8,
    project_dir: ?[]const u8,
    target: ?[]const u8,
    lock_file: ?[]const u8,
    config_file: ?[]const u8,
    output_dir: []const u8,
    zig_executable: []const u8,
    optimize: Optimize,
    progress: Progress,

    pub fn validate(self: Context, needs_project: bool) !void {
        if (!std.mem.eql(u8, self.contract_version, version)) return error.UnsupportedContract;
        if (!identifier(self.invocation.id)) return error.InvalidIdentifier;
        try absolute(self.package_dir);
        try absolute(self.output_dir);
        try absolute(self.zig_executable);
        if (self.project_dir) |project| {
            try absolute(project);
            try absolute(self.lock_file orelse return error.MissingProjectLock);
            if (!identifier(self.target orelse return error.MissingTarget)) return error.InvalidIdentifier;
            if (self.config_file) |path| try absolute(path);
        } else {
            if (needs_project) return error.ProjectRequired;
            if (self.target != null or self.lock_file != null or self.config_file != null)
                return error.InvalidProjectlessContext;
            if (self.optimize != .Debug) return error.InvalidProjectlessContext;
        }
        switch (self.invocation.kind) {
            .command => if (self.invocation.step != null or self.invocation.phase != null)
                return error.InvalidInvocation,
            .hook => {
                if (self.project_dir == null or self.invocation.step == null or self.invocation.phase == null)
                    return error.InvalidInvocation;
            },
        }
    }
};

/// Caller owns the returned JSON arena. Validation failures also free it.
pub fn parseContext(allocator: std.mem.Allocator, bytes: []const u8, needs_project: bool) !std.json.Parsed(Context) {
    const parsed = try std.json.parseFromSlice(Context, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    try parsed.value.validate(needs_project);
    return parsed;
}

/// A named install-only build step produces this exact host executable.
/// `executable` is relative to an isolated Zig install prefix, using '/'.
pub const Tool = struct {
    build_step: []const u8,
    executable: []const u8,

    pub fn validate(self: Tool) !void {
        if (!identifier(self.build_step)) return error.InvalidBuildStep;
        const path = self.executable;
        if (!std.mem.startsWith(u8, path, "bin/") or path.len <= 4) return error.InvalidExecutable;
        if (std.mem.indexOfAny(u8, path, "\\:\x00") != null) return error.InvalidExecutable;
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
                return error.InvalidExecutable;
        }
        // Native extension is selected by the host, not authored in the manifest.
        // Windows ignores suffix case, so `.EXE` is the same authored extension.
        if (std.ascii.endsWithIgnoreCase(path, ".exe")) return error.InvalidExecutable;
    }
};

pub const Ownership = struct {
    package: []const u8,
    namespaces: []const []const u8,
    targets: []const []const u8,
};

/// Same ownership data answers namespace and missing-target diagnostics.
pub fn validateOwnership(entries: []const Ownership, reserved_namespaces: []const []const u8) !void {
    for (entries, 0..) |entry, i| {
        if (!identifier(entry.package)) return error.InvalidIdentifier;
        for (entries[0..i]) |previous| {
            if (std.mem.eql(u8, entry.package, previous.package)) return error.DuplicatePackage;
        }
        try uniqueNames(entry.namespaces);
        try uniqueNames(entry.targets);
        for (entry.namespaces) |name| {
            for (reserved_namespaces) |reserved| {
                if (std.mem.eql(u8, name, reserved)) return error.ReservedNamespace;
            }
            for (entries[0..i]) |previous| {
                for (previous.namespaces) |claimed| {
                    if (std.mem.eql(u8, name, claimed)) return error.NamespaceConflict;
                }
            }
        }
        for (entry.targets) |target| {
            if (std.mem.eql(u8, target, "desktop")) return error.ReservedTarget;
            for (entries[0..i]) |previous| {
                for (previous.targets) |claimed| {
                    if (std.mem.eql(u8, target, claimed)) return error.TargetConflict;
                }
            }
        }
    }
}

pub fn providerForTarget(entries: []const Ownership, target: []const u8) ?[]const u8 {
    for (entries) |entry| {
        for (entry.targets) |declared| {
            if (std.mem.eql(u8, target, declared)) return entry.package;
        }
    }
    return null;
}

fn uniqueNames(names: []const []const u8) !void {
    for (names, 0..) |name, i| {
        if (!identifier(name)) return error.InvalidIdentifier;
        for (names[0..i]) |previous| {
            if (std.mem.eql(u8, name, previous)) return error.DuplicateName;
        }
    }
}

fn identifier(value: []const u8) bool {
    if (value.len == 0 or value[0] < 'a' or value[0] > 'z') return false;
    for (value) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

fn absolute(path: []const u8) !void {
    if (std.mem.indexOfScalar(u8, path, 0) != null or !std.fs.path.isAbsolute(path))
        return error.InvalidPath;
    // A rooted /path still depends on the current drive on Windows.
    if (@import("builtin").os.tag == .windows and !windowsVolumeQualified(path)) return error.InvalidPath;
}

/// Windows paths must name their volume: `X:\...` or a UNC `\\server\share...`.
/// Host-independent so the rule is exercised by the tests on every platform.
fn windowsVolumeQualified(path: []const u8) bool {
    const seps = "/\\";
    const drive = path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and
        std.mem.indexOfScalar(u8, seps, path[2]) != null;
    if (drive) return true;
    if (path.len < 2 or std.mem.indexOfScalar(u8, seps, path[0]) == null or std.mem.indexOfScalar(u8, seps, path[1]) == null)
        return false;
    // std classifies bare `//` and `//server` as absolute; a share needs both a
    // non-empty server and a non-empty share name to address anything.
    const server_end = std.mem.indexOfAnyPos(u8, path, 2, seps) orelse return false;
    if (server_end == 2) return false;
    var rest = std.mem.tokenizeAny(u8, path[server_end + 1 ..], seps);
    return rest.next() != null;
}

const fixture = if (@import("builtin").os.tag == .windows)
    @embedFile("provider_contract/projectless-windows.json")
else
    @embedFile("provider_contract/projectless.json");

test "wire context parses required explicit nulls and owns its strings" {
    const input = try std.testing.allocator.dupe(u8, fixture);
    defer std.testing.allocator.free(input);
    const parsed = try parseContext(std.testing.allocator, input, false);
    defer parsed.deinit();
    @memset(input, ' ');
    try std.testing.expectEqualStrings("doctor", parsed.value.invocation.id);
    try std.testing.expect(parsed.value.project_dir == null);
}

test "project-only command rejects a projectless context" {
    try std.testing.expectError(error.ProjectRequired, parseContext(std.testing.allocator, fixture, true));
}

test "wire parser rejects unknown fields, missing fields and duplicate fields" {
    const unknown = try std.mem.replaceOwned(u8, std.testing.allocator, fixture, "\"progress\": \"json\"", "\"progress\": \"json\", \"typo\": true");
    defer std.testing.allocator.free(unknown);
    try std.testing.expectError(error.UnknownField, parseContext(std.testing.allocator, unknown, false));
    const missing = try std.mem.replaceOwned(u8, std.testing.allocator, fixture, "\"target\": null,", "");
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.MissingField, parseContext(std.testing.allocator, missing, false));
    const duplicate = try std.mem.replaceOwned(u8, std.testing.allocator, fixture, "\"target\": null,", "\"target\": null, \"target\": null,");
    defer std.testing.allocator.free(duplicate);
    try std.testing.expectError(error.DuplicateField, parseContext(std.testing.allocator, duplicate, false));
}

test "context rejects unsupported version and inconsistent project fields" {
    const parsed = try parseContext(std.testing.allocator, fixture, false);
    defer parsed.deinit();
    var value = parsed.value;
    value.contract_version = "2.0.0";
    try std.testing.expectError(error.UnsupportedContract, value.validate(false));
    value = parsed.value;
    value.target = "sample-target";
    try std.testing.expectError(error.InvalidProjectlessContext, value.validate(false));
    value = parsed.value;
    value.project_dir = value.package_dir;
    try std.testing.expectError(error.MissingProjectLock, value.validate(true));
    value.lock_file = value.zig_executable;
    try std.testing.expectError(error.MissingTarget, value.validate(true));
    value.target = "desktop";
    try value.validate(true);
    value.invocation.kind = .hook;
    try std.testing.expectError(error.InvalidInvocation, value.validate(true));
    value.invocation.step = .bundle;
    value.invocation.phase = .after;
    try value.validate(true);
}

test "context rejects relative paths and command hook metadata" {
    const parsed = try parseContext(std.testing.allocator, fixture, false);
    defer parsed.deinit();
    var value = parsed.value;
    value.output_dir = "relative/output";
    try std.testing.expectError(error.InvalidPath, value.validate(false));
    value = parsed.value;
    value.invocation.step = .run;
    try std.testing.expectError(error.InvalidInvocation, value.validate(false));
    value = parsed.value;
    value.optimize = .ReleaseFast;
    try std.testing.expectError(error.InvalidProjectlessContext, value.validate(false));
    if (@import("builtin").os.tag == .windows) {
        for ([_][]const u8{ "/current-drive-relative", "//", "//server", "//server/" }) |path| {
            value = parsed.value;
            value.output_dir = path;
            try std.testing.expectError(error.InvalidPath, value.validate(false));
        }
        value = parsed.value;
        value.output_dir = "//server/share";
        try value.validate(false);
    }
}

test "windows volume qualification requires a drive or a complete UNC share" {
    for ([_][]const u8{ "C:/provider", "c:\\provider", "//server/share", "\\\\server\\share\\dir", "//server//share" }) |path| {
        try std.testing.expect(windowsVolumeQualified(path));
    }
    for ([_][]const u8{ "", "/rooted", "C:relative", "//", "//server", "//server/", "///share", "\\\\.", "\\\\?\\" }) |path| {
        try std.testing.expect(!windowsVolumeQualified(path));
    }
    // The qualification check is what rejects incomplete UNC prefixes; std alone accepts them.
    for ([_][]const u8{ "//", "//server", "//server/" }) |path| {
        try std.testing.expect(std.fs.path.isAbsoluteWindows(path));
    }
}

test "tool must declare a contained deterministic installed executable" {
    try (Tool{ .build_step = "cmd-doctor", .executable = "bin/doctor" }).validate();
    for ([_][]const u8{ "", "/bin/tool", "bin/../escape", "bin//tool", "bin/./tool", "bin/tool.exe", "bin/C:tool", "bin/tool\\other", "bin/tool\x00" }) |path| {
        try std.testing.expectError(error.InvalidExecutable, (Tool{ .build_step = "cmd-test", .executable = path }).validate());
    }
    // Case variants of the native suffix would make the runner look for `tool.EXE.exe`.
    for ([_][]const u8{ "bin/tool.EXE", "bin/tool.Exe", "bin/nested/tool.eXe" }) |path| {
        try std.testing.expect(!std.mem.endsWith(u8, path, ".exe"));
        try std.testing.expectError(error.InvalidExecutable, (Tool{ .build_step = "cmd-test", .executable = path }).validate());
    }
    // An extension that merely contains the suffix letters is still a plain tool name.
    try (Tool{ .build_step = "cmd-test", .executable = "bin/tool.exec" }).validate();
    try std.testing.expectError(error.InvalidBuildStep, (Tool{ .build_step = "--help", .executable = "bin/tool" }).validate());
}

test "target ownership resolves independently of namespace spelling" {
    const entries = [_]Ownership{.{ .package = "browser-provider", .namespaces = &.{"browser"}, .targets = &.{"bytecode"} }};
    try validateOwnership(&entries, &.{"build"});
    try std.testing.expectEqualStrings("browser-provider", providerForTarget(&entries, "bytecode").?);
    try std.testing.expect(providerForTarget(&entries, "missing") == null);
}

test "ownership rejects conflicts and reserved identities before dispatch" {
    const first: Ownership = .{ .package = "provider-a", .namespaces = &.{"sample"}, .targets = &.{"sample-target"} };
    var second: Ownership = .{ .package = "provider-b", .namespaces = &.{"sample"}, .targets = &.{} };
    try std.testing.expectError(error.NamespaceConflict, validateOwnership(&.{ first, second }, &.{}));
    second.namespaces = &.{};
    second.targets = &.{"sample-target"};
    try std.testing.expectError(error.TargetConflict, validateOwnership(&.{ first, second }, &.{}));
    try std.testing.expectError(error.ReservedNamespace, validateOwnership(&.{first}, &.{"sample"}));
    second.targets = &.{"desktop"};
    try std.testing.expectError(error.ReservedTarget, validateOwnership(&.{second}, &.{}));
    second.targets = &.{ "a", "a" };
    try std.testing.expectError(error.DuplicateName, validateOwnership(&.{second}, &.{}));
}
