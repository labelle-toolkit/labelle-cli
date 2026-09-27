//! Read target-specific texture data from the pinned backend package.
const std = @import("std");
const convert = @import("convert.zig");
const config = @import("../cli/config.zig");
const project = @import("../cli/project_config.zig");
const plugins = @import("../cli/plugins.zig");

pub const Selection = struct {
    caps: convert.BackendCaps = .{},
    source: enum { manifest, conservative_default } = .conservative_default,
    fallback: enum { png, none } = .none,
};
const Target = struct {
    astc: struct {
        blocks: []const convert.BlockSize,
        default_block: convert.BlockSize,
    },
    fallback: @FieldType(Selection, "fallback") = .none,
};

/// Unknown root fields belong to other manifest consumers. The texture section
/// itself is strict, including declarations for targets other than this run.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8, target: []const u8) !Selection {
    // ZON diagnostics may allocate on parse failures; all parsed data is
    // temporary because Selection owns only value types.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try a.dupeZ(u8, bytes);
    defer a.free(source);
    var ast = try std.zig.Ast.parse(a, source, .zon);
    defer ast.deinit(a);
    if (ast.errors.len != 0) return error.InvalidTextureCapabilities;
    var zoir = try std.zig.ZonGen.generate(a, ast, .{ .parse_str_lits = false });
    defer zoir.deinit(a);
    if (zoir.hasCompileErrors()) return error.InvalidTextureCapabilities;
    const root = switch (std.zig.Zoir.Node.Index.root.get(zoir)) {
        .struct_literal => |fields| fields,
        .empty_literal => return .{},
        else => return error.InvalidTextureCapabilities,
    };
    var result: Selection = .{};
    var seen = false;
    for (root.names, 0..) |name, i| {
        if (!std.mem.eql(u8, name.get(zoir), "texture_caps")) continue;
        if (seen) return error.InvalidTextureCapabilities;
        seen = true;
        const targets = switch (root.vals.at(@intCast(i)).get(zoir)) {
            .struct_literal => |fields| fields,
            .empty_literal => return result,
            else => return error.InvalidTextureCapabilities,
        };
        for (targets.names, 0..) |key, j| {
            const target_name = key.get(zoir);
            for (targets.names[0..j]) |previous| {
                if (std.mem.eql(u8, previous.get(zoir), target_name)) return error.InvalidTextureCapabilities;
            }
            const value = std.zon.parse.fromZoirNodeAlloc(Target, a, ast, zoir, targets.vals.at(@intCast(j)), null, .{}) catch |err| {
                if (err == error.OutOfMemory) return err;
                return error.InvalidTextureCapabilities;
            };
            defer std.zon.parse.free(a, value);
            var caps: convert.BackendCaps = .{ .blocks = .initEmpty(), .default_block = value.astc.default_block };
            for (value.astc.blocks) |block| {
                if (caps.blocks.contains(block)) return error.InvalidTextureCapabilities;
                caps.blocks.insert(block);
            }
            if (!caps.supports(caps.default_block)) return error.InvalidTextureCapabilities;
            if (std.mem.eql(u8, target, target_name)) result = .{ .caps = caps, .source = .manifest, .fallback = value.fallback };
        }
    }
    return result;
}

/// Packages without the extension retain the conservative default. A missing
/// package is different from an old manifest: ask for install rather than let
/// a cold cache silently change the selected block size.
pub fn resolve(a: std.mem.Allocator, project_dir: []const u8, package: ?project.PluginDep, target: []const u8) !Selection {
    const dep = package orelse return .{};
    const root = try plugins.resolvePluginDir(a, project_dir, dep);
    defer a.free(root);
    var dir = std.Io.Dir.cwd().openDir(config.globalIo(), root, .{}) catch {
        std.debug.print("labelle astc: backend package '{s}' is unavailable at '{s}'; run labelle install first\n", .{ dep.name, root });
        return error.InvalidTextureCapabilities;
    };
    defer dir.close(config.globalIo());
    const bytes = dir.readFileAlloc(config.globalIo(), "backend.manifest.zon", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        error.OutOfMemory => return err,
        else => {
            std.debug.print("labelle astc: cannot read '{s}/backend.manifest.zon': {s}\n", .{ root, @errorName(err) });
            return error.InvalidTextureCapabilities;
        },
    };
    defer a.free(bytes);
    return parse(a, bytes, target) catch |err| {
        std.debug.print("labelle astc: invalid texture_caps in '{s}/backend.manifest.zon': {s}\n", .{ root, @errorName(err) });
        return err;
    };
}

test "texture capabilities distinguish manifest and conservative paths even for identical blocks" {
    const a = std.testing.allocator;
    const bytes = ".{ .other_runtime_field = true, .texture_caps = .{ .custom_target = .{ .astc = .{ .blocks = .{ .@\"4x4\" }, .default_block = .@\"4x4\" }, .fallback = .png } } }";
    const declared = try parse(a, bytes, "custom_target");
    const fallback = try parse(a, bytes, "missing_target");
    try std.testing.expectEqual(.manifest, declared.source);
    try std.testing.expectEqual(.conservative_default, fallback.source);
    try std.testing.expectEqual(declared.caps.defaultBlock(), fallback.caps.defaultBlock());
    try std.testing.expectEqual(.conservative_default, (try parse(a, ".{ .unrelated = .{} }", "custom_target")).source);
}

test "texture capabilities honor per-target defaults without backend identity" {
    const a = std.testing.allocator;
    const bytes = ".{ .texture_caps = .{ .custom_target = .{ .astc = .{ .blocks = .{ .@\"4x4\", .@\"8x8\" }, .default_block = .@\"8x8\" } }, .other_target = .{ .astc = .{ .blocks = .{ .@\"6x6\" }, .default_block = .@\"6x6\" }, .fallback = .none } } }";
    const wide = try parse(a, bytes, "custom_target");
    try std.testing.expectEqual(.manifest, wide.source);
    try std.testing.expectEqual(convert.BlockSize.@"8x8", wide.caps.defaultBlock());
    try std.testing.expect(!wide.caps.supports(.@"6x6"));
    const other = try parse(a, bytes, "other_target");
    try std.testing.expectEqual(convert.BlockSize.@"6x6", other.caps.defaultBlock());
    try std.testing.expectEqual(.none, other.fallback);
}

test "texture capabilities reject malformed declarations rather than silently defaulting" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        ".{ .texture_caps = true }",
        ".{ .texture_caps = .{ .custom_target = .{ .astc = .{ .blocks = .{ .@\"4x4\" }, .default_block = .@\"8x8\" } } } }",
        ".{ .texture_caps = .{ .custom_target = .{ .astc = .{ .blocks = .{}, .default_block = .@\"4x4\" } } } }",
        ".{ .texture_caps = .{ .custom_target = .{ .astc = .{ .blocks = .{ .@\"4x4\", .@\"4x4\" }, .default_block = .@\"4x4\" } } } }",
        ".{ .texture_caps = .{ .custom_target = .{ .astc = .{ .blocks = .{ .@\"7x7\" }, .default_block = .@\"4x4\" } } } }",
        ".{ .texture_caps = .{ .custom_target = .{ .astc = .{ .blocks = .{ .@\"4x4\" }, .default_block = .@\"4x4\", .typo = true } } } }",
        ".{ .texture_caps = .{ .custom_target = .{ .astc = .{ .blocks = .{ .@\"4x4\" }, .default_block = .@\"4x4\" }, .typo = true } } }",
    }) |bytes| try std.testing.expectError(error.InvalidTextureCapabilities, parse(a, bytes, "custom_target"));
}

const fixture_wide = ".{ .texture_caps = .{ .custom_target = .{ .astc = .{ .blocks = .{ .@\"4x4\", .@\"8x8\" }, .default_block = .@\"8x8\" }, .fallback = .png } } }";

test "texture capabilities resolve local package declarations and legacy absence" {
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try tmp.dir.createDirPath(io, "backend");
    const dep: project.PluginDep = .{ .name = "custom", .repo = "local:backend" };
    try std.testing.expectEqual(.conservative_default, (try resolve(a, root, dep, "custom_target")).source);
    try tmp.dir.writeFile(io, .{ .sub_path = "backend/backend.manifest.zon", .data = fixture_wide });
    const selected = try resolve(a, root, dep, "custom_target");
    try std.testing.expectEqual(.manifest, selected.source);
    try std.testing.expectEqual(convert.BlockSize.@"8x8", selected.caps.defaultBlock());
    try tmp.dir.writeFile(io, .{ .sub_path = "backend/backend.manifest.zon", .data = ".{ .texture_caps = false }" });
    try std.testing.expectError(error.InvalidTextureCapabilities, resolve(a, root, dep, "custom_target"));
    try std.testing.expectError(error.InvalidTextureCapabilities, resolve(a, root, .{ .name = "missing", .repo = "local:missing" }, "custom_target"));
    try std.testing.expectEqual(.conservative_default, (try resolve(a, root, null, "custom_target")).source);
}

test "texture capabilities resolve exactly the remote version pin" {
    const cache = @import("../cli/asm_cache.zig");
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    cache.setCacheRootOverride(root);
    defer cache.clearCacheRootOverride();
    const old = "packages/plugins/github.com/example/custom/old";
    const new = "packages/plugins/github.com/example/custom/new";
    try tmp.dir.createDirPath(io, old);
    try tmp.dir.createDirPath(io, new);
    try tmp.dir.writeFile(io, .{ .sub_path = old ++ "/backend.manifest.zon", .data = ".{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = new ++ "/backend.manifest.zon", .data = fixture_wide });
    const dep: project.PluginDep = .{ .name = "custom", .repo = "github.com/example/custom", .version = "new" };
    const selected = try resolve(a, root, dep, "custom_target");
    try std.testing.expectEqual(.manifest, selected.source);
    var earlier = dep;
    earlier.version = "old";
    try std.testing.expectEqual(.conservative_default, (try resolve(a, root, earlier, "custom_target")).source);
    earlier.version = "not-installed";
    try std.testing.expectError(error.InvalidTextureCapabilities, resolve(a, root, earlier, "custom_target"));
}
