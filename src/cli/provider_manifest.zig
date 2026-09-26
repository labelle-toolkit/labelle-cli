//! Read the provider extension without weakening validation of its nested records.
//! Runtime fields belong to the assembler; provider fields are decoded strictly.
const std = @import("std");
const contract = @import("provider_contract.zig");
const compat = @import("compatibility.zig");

pub const Command = struct {
    name: []const u8,
    build_step: []const u8,
    executable: []const u8,
    help: []const u8,
    needs_project: bool = true,
    pub fn tool(self: Command) contract.Tool {
        return .{ .build_step = self.build_step, .executable = self.executable };
    }
};
pub const Hook = struct {
    id: []const u8,
    step: contract.Step,
    target: []const u8,
    when: contract.Phase,
    build_step: []const u8,
    executable: []const u8,
    after_hooks: []const []const u8 = &.{},
};
pub const Manifest = struct {
    name: []const u8 = "",
    manifest_version: u8 = 1,
    command_contract: ?[]const u8 = null,
    namespace: ?[]const u8 = null,
    commands: []const Command = &.{},
    hooks: []const Hook = &.{},
    targets: []const []const u8 = &.{},

    pub fn isProvider(self: Manifest) bool {
        return self.command_contract != null or self.namespace != null or
            self.commands.len != 0 or self.hooks.len != 0 or self.targets.len != 0;
    }
    pub fn validate(self: Manifest) !void {
        if (!self.isProvider()) return;
        if (!contract.identifier(self.name)) return error.InvalidPackageName;
        if (self.manifest_version != 2) return error.UnsupportedManifest;
        const range = try compat.parseRange(self.command_contract orelse return error.MissingCommandContract);
        if (!range.satisfiedBy(try std.SemanticVersion.parse(contract.version))) return error.UnsupportedContract;
        if (self.commands.len != 0 and self.namespace == null) return error.MissingNamespace;
        if (self.namespace) |ns| if (!contract.identifier(ns)) return error.InvalidNamespace;
        for (self.commands, 0..) |cmd, i| {
            if (!contract.identifier(cmd.name) or cmd.help.len == 0) return error.InvalidCommand;
            try cmd.tool().validate();
            for (self.commands[0..i]) |prev| {
                if (std.mem.eql(u8, prev.name, cmd.name)) return error.DuplicateCommand;
            }
        }
        for (self.hooks, 0..) |hook, i| {
            if (!contract.identifier(hook.id) or !contract.identifier(hook.target)) return error.InvalidHook;
            try (contract.Tool{ .build_step = hook.build_step, .executable = hook.executable }).validate();
            for (self.hooks[0..i]) |prev| {
                if (std.mem.eql(u8, prev.id, hook.id)) return error.DuplicateHook;
            }
            // Contract §6: a replacement belongs only to the target owner.
            // Core owns `desktop`, so no package can ever replace it.
            if (hook.when == .replace and !self.ownsTarget(hook.target)) return error.ReplaceRequiresOwnedTarget;
            for (hook.after_hooks) |ref| {
                const parts = splitHookRef(ref) orelse return error.InvalidHookReference;
                if (std.mem.eql(u8, parts.package, self.name) and std.mem.eql(u8, parts.id, hook.id))
                    return error.InvalidHookReference;
            }
        }
    }
    pub fn ownsTarget(self: Manifest, target: []const u8) bool {
        for (self.targets) |declared| {
            if (std.mem.eql(u8, declared, target)) return true;
        }
        return false;
    }
};

pub const HookRef = struct { package: []const u8, id: []const u8 };

/// `<package>/<id>`, both halves plain identifiers; anything else is null.
pub fn splitHookRef(ref: []const u8) ?HookRef {
    const slash = std.mem.indexOfScalar(u8, ref, '/') orelse return null;
    const parts: HookRef = .{ .package = ref[0..slash], .id = ref[slash + 1 ..] };
    if (!contract.identifier(parts.package) or !contract.identifier(parts.id)) return null;
    return parts;
}

/// The stable hook identity of contract §6.
pub fn qualifiedId(a: std.mem.Allocator, package: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ package, id });
}

/// Arena-owned result. Unknown top-level runtime fields are ignored, but every
/// selected field is parsed with ignore_unknown_fields=false (including children).
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Manifest {
    const source = try allocator.dupeZ(u8, bytes);
    defer allocator.free(source);
    var ast = try std.zig.Ast.parse(allocator, source, .zon);
    defer ast.deinit(allocator);
    if (ast.errors.len != 0) return error.InvalidManifest;
    try rejectRepeatedFields(ast);
    var zoir = try std.zig.ZonGen.generate(allocator, ast, .{ .parse_str_lits = false });
    defer zoir.deinit(allocator);
    if (zoir.hasCompileErrors()) return error.InvalidManifest;
    const fields = switch (std.zig.Zoir.Node.Index.root.get(zoir)) {
        .struct_literal => |fields| fields,
        else => return error.InvalidManifest,
    };
    var result: Manifest = .{};
    for (fields.names, 0..) |name, i| {
        inline for (std.meta.fields(Manifest)) |field| {
            if (std.mem.eql(u8, name.get(zoir), field.name)) {
                @field(result, field.name) = try std.zon.parse.fromZoirNodeAlloc(
                    field.type,
                    allocator,
                    ast,
                    zoir,
                    fields.vals.at(@intCast(i)),
                    null,
                    .{},
                );
            }
        }
    }
    try result.validate();
    return result;
}

/// The manual field loop in `parse` assigns every occurrence of a recognised
/// name, so a repeated `.command_contract`/`.namespace`/`.commands` would
/// otherwise negotiate whichever value comes last. ZonGen also refuses a
/// repeated struct field name, but only as an anonymous compile error; this
/// check runs before it so the rejection is named and does not depend on
/// ZonGen's diagnostics (cli#413 review).
fn rejectRepeatedFields(ast: std.zig.Ast) !void {
    var buf: [2]std.zig.Ast.Node.Index = undefined;
    // Anything but a struct literal at the root is rejected after ZonGen.
    const root = ast.fullStructInit(&buf, ast.rootDecls()[0]) orelse return;
    for (root.ast.fields, 0..) |field, i| {
        const name = ast.tokenSlice(ast.firstToken(field) - 2);
        for (root.ast.fields[0..i]) |prev| {
            if (std.mem.eql(u8, name, ast.tokenSlice(ast.firstToken(prev) - 2))) return error.DuplicateManifestField;
        }
    }
}

test "provider manifest: strict records, negotiation, defaults and runtime extension" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = ".{ .name = \"fixture\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .namespace = \"probe\", .resources = .{}, .commands = .{ .{ .name = \"doctor\", .build_step = \"tool\", .executable = \"bin/doctor\", .help = \"Inspect\" } } }";
    const parsed = try parse(a, good);
    try std.testing.expect(parsed.commands[0].needs_project);
    try std.testing.expectEqualStrings("doctor", parsed.commands[0].name);
    const typo = try std.mem.replaceOwned(u8, a, good, ".help =", ".hlep =");
    try std.testing.expectError(error.ParseZon, parse(a, typo));
    const incompatible = try std.mem.replaceOwned(u8, a, good, ">=1.0.0 <2.0.0", ">=2.0.0");
    try std.testing.expectError(error.UnsupportedContract, parse(a, incompatible));
    const v1 = try std.mem.replaceOwned(u8, a, good, "manifest_version = 2", "manifest_version = 1");
    try std.testing.expectError(error.UnsupportedManifest, parse(a, v1));
    try std.testing.expect(!(try parse(a, ".{ .name = \"runtime\", .resources = .{} }")).isProvider());
}

fn hookManifest(a: std.mem.Allocator, targets: []const u8, hooks: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, ".{{ .name = \"fixture\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .targets = .{{ {s} }}, .hooks = .{{ {s} }} }}", .{ targets, hooks });
}

test "provider manifest: replace hooks need an owned target; before/after attach anywhere" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const replace = ".{ .id = \"pack\", .step = .bundle, .target = \"{s}\", .when = .replace, .build_step = \"tool\", .executable = \"bin/tool\" }";
    const owned = try std.mem.replaceOwned(u8, a, replace, "{s}", "probe-target");
    const parsed = try parse(a, try hookManifest(a, "\"probe-target\"", owned));
    try std.testing.expect(parsed.ownsTarget("probe-target"));
    try std.testing.expect(!parsed.ownsTarget("desktop"));
    try std.testing.expectError(error.ReplaceRequiresOwnedTarget, parse(a, try hookManifest(a, "", owned)));
    const other = try std.mem.replaceOwned(u8, a, replace, "{s}", "other-target");
    try std.testing.expectError(error.ReplaceRequiresOwnedTarget, parse(a, try hookManifest(a, "\"probe-target\"", other)));
    // `desktop` is core-owned: no package may replace it, but before/after
    // hooks may attach to it without ownership.
    const desktop = try std.mem.replaceOwned(u8, a, replace, "{s}", "desktop");
    try std.testing.expectError(error.ReplaceRequiresOwnedTarget, parse(a, try hookManifest(a, "", desktop)));
    for ([_][]const u8{ ".before", ".after" }) |phase| {
        const attached = try std.mem.replaceOwned(u8, a, desktop, ".replace", phase);
        const meta = try parse(a, try hookManifest(a, "", attached));
        try std.testing.expectEqual(@as(usize, 1), meta.hooks.len);
        try std.testing.expectEqualStrings("desktop", meta.hooks[0].target);
    }
}

test "provider manifest: after_hooks references are qualified, well-formed and never self" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hook = ".{ .id = \"stamp\", .step = .build, .target = \"desktop\", .when = .after, .build_step = \"tool\", .executable = \"bin/tool\", .after_hooks = .{ \"{ref}\" } }";
    const good = try std.mem.replaceOwned(u8, a, hook, "{ref}", "other-package/sign");
    const meta = try parse(a, try hookManifest(a, "", good));
    try std.testing.expectEqualStrings("other-package/sign", meta.hooks[0].after_hooks[0]);
    for ([_][]const u8{ "x", "a/b/c", "A/b", "a/B", "/b", "a/", "fixture/stamp" }) |ref| {
        const bad = try std.mem.replaceOwned(u8, a, hook, "{ref}", ref);
        try std.testing.expectError(error.InvalidHookReference, parse(a, try hookManifest(a, "", bad)));
    }
    // Same id in another package is a legitimate reference, not a self-reference.
    const sibling = try std.mem.replaceOwned(u8, a, hook, "{ref}", "other/stamp");
    _ = try parse(a, try hookManifest(a, "", sibling));
    try std.testing.expect(splitHookRef("x") == null);
    try std.testing.expect(splitHookRef("a/b/c") == null);
    const parts = splitHookRef("pkg-1/hook_2").?;
    try std.testing.expectEqualStrings("pkg-1", parts.package);
    try std.testing.expectEqualStrings("hook_2", parts.id);
    try std.testing.expectEqualStrings("pkg-1/hook_2", try qualifiedId(a, "pkg-1", "hook_2"));
}

test "provider manifest: hook steps are limited to the four contract steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hook = ".{ .id = \"pack\", .step = .{s}, .target = \"desktop\", .when = .before, .build_step = \"tool\", .executable = \"bin/tool\" }";
    inline for (std.meta.fields(contract.Step)) |step| {
        const ok = try std.mem.replaceOwned(u8, a, hook, "{s}", step.name);
        _ = try parse(a, try hookManifest(a, "", ok));
    }
    // There is no separate package lifecycle step (contract §1).
    const bad = try std.mem.replaceOwned(u8, a, hook, "{s}", "package");
    try std.testing.expectError(error.ParseZon, parse(a, try hookManifest(a, "", bad)));
}

test "provider manifest: a repeated top-level field is rejected, never last-wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = ".{ .name = \"fixture\", .manifest_version = 2, .command_contract = \">=1.0.0 <2.0.0\", .namespace = \"probe\", .commands = .{ .{ .name = \"doctor\", .build_step = \"tool\", .executable = \"bin/doctor\", .help = \"Inspect\" } } }";
    _ = try parse(a, good);
    // Each repeat is valid on its own, so last-wins would parse cleanly with
    // the second value; the named error proves the guard ran, not ZonGen.
    for ([_][]const u8{
        ".command_contract = \">=1.0.0 <2.0.0\"",
        ".namespace = \"probe\"",
        ".manifest_version = 2",
        ".commands = .{ .{ .name = \"doctor\", .build_step = \"tool\", .executable = \"bin/doctor\", .help = \"Inspect\" } }",
    }) |decl| {
        const repeated = try std.mem.replaceOwned(u8, a, good, decl, try std.fmt.allocPrint(a, "{s}, {s}", .{ decl, decl }));
        try std.testing.expect(!std.mem.eql(u8, good, repeated));
        try std.testing.expectError(error.DuplicateManifestField, parse(a, repeated));
    }
    // Unknown runtime fields are subject to the same rule.
    try std.testing.expectError(error.DuplicateManifestField, parse(a, ".{ .name = \"runtime\", .resources = .{}, .resources = .{} }"));
}
