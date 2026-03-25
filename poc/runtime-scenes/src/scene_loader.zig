const std = @import("std");
const parser = @import("parser.zig");
const des = @import("deserialize.zig");
const Value = parser.Value;
const Allocator = std.mem.Allocator;

/// A runtime-loaded scene with entities, scripts, and metadata.
pub const Scene = struct {
    name: []const u8,
    scripts: []const []const u8,
    entities: []const Entity,
    camera: ?CameraConfig,
    allocator: Allocator,

    pub const CameraConfig = struct {
        x: f32 = 0,
        y: f32 = 0,
        zoom: f32 = 1,
    };

    pub fn getEntitiesByPrefab(self: Scene, prefab_name: []const u8) []const Entity {
        var count: usize = 0;
        for (self.entities) |e| {
            if (e.prefab) |p| {
                if (std.mem.eql(u8, p, prefab_name)) count += 1;
            }
        }
        if (count == 0) return &.{};

        const result = self.allocator.alloc(Entity, count) catch return &.{};
        var i: usize = 0;
        for (self.entities) |e| {
            if (e.prefab) |p| {
                if (std.mem.eql(u8, p, prefab_name)) {
                    result[i] = e;
                    i += 1;
                }
            }
        }
        return result;
    }
};

/// A runtime entity with its parsed component data (not yet deserialized to concrete types).
pub const Entity = struct {
    prefab: ?[]const u8,
    components: []const ComponentData,
    children: []const Entity,
    parent_index: ?usize, // index into scene.entities of parent, set during flattening
    children_indices: []const usize, // indices into scene.entities of children, set during flattening

    pub const ComponentData = struct {
        name: []const u8,
        value: Value,
    };

    pub fn getComponent(self: Entity, name: []const u8) ?Value {
        for (self.components) |c| {
            if (std.mem.eql(u8, c.name, name)) return c.value;
        }
        return null;
    }

    pub fn hasComponent(self: Entity, name: []const u8) bool {
        return self.getComponent(name) != null;
    }

    pub fn hasChildren(self: Entity) bool {
        return self.children.len > 0;
    }
};

/// Prefab cache — loads and caches prefab files from a directory.
pub const PrefabCache = struct {
    prefabs: std.StringHashMap(Value),
    allocator: Allocator,
    prefab_dir: []const u8,

    pub fn init(allocator: Allocator, prefab_dir: []const u8) PrefabCache {
        return .{
            .prefabs = std.StringHashMap(Value).init(allocator),
            .allocator = allocator,
            .prefab_dir = prefab_dir,
        };
    }

    /// Get a prefab by name, loading from disk if not cached.
    pub fn get(self: *PrefabCache, name: []const u8) !?Value {
        if (self.prefabs.get(name)) |val| return val;

        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.zon", .{ self.prefab_dir, name });
        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();

        const source = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        var p = parser.Parser.init(self.allocator, source);
        const val = try p.parse();

        try self.prefabs.put(try self.allocator.dupe(u8, name), val);
        return val;
    }

    /// Manually insert a prefab (for testing).
    pub fn put(self: *PrefabCache, name: []const u8, val: Value) !void {
        try self.prefabs.put(try self.allocator.dupe(u8, name), val);
    }
};

pub const LoadError = error{
    InvalidScene,
    InvalidEntity,
    InvalidPrefab,
    IncludeDepthExceeded,
    OutOfMemory,
    ParseError,
} || std.fs.File.OpenError || std.fs.File.ReadError || parser.ParseError;

const MAX_INCLUDE_DEPTH = 16;

/// Load a scene from a file path, resolving prefabs and includes.
pub fn loadScene(allocator: Allocator, scene_path: []const u8, prefab_dir: []const u8) LoadError!Scene {
    const file = try std.fs.cwd().openFile(scene_path, .{});
    defer file.close();
    const source = try file.readToEndAlloc(allocator, 1024 * 1024);
    var p = parser.Parser.init(allocator, source);
    const scene_value = try p.parse();

    // Resolve base_dir from scene_path for relative includes
    const base_dir = blk: {
        if (std.mem.lastIndexOfScalar(u8, scene_path, '/')) |idx| {
            break :blk scene_path[0..idx];
        }
        break :blk ".";
    };

    return loadSceneFromValue(allocator, scene_value, prefab_dir, base_dir);
}

/// Load a scene from an already-parsed Value.
pub fn loadSceneFromValue(
    allocator: Allocator,
    scene_value: Value,
    prefab_dir: []const u8,
    base_dir: []const u8,
) LoadError!Scene {
    var prefab_cache = PrefabCache.init(allocator, prefab_dir);
    return loadSceneInner(allocator, scene_value, &prefab_cache, base_dir, 0);
}

fn loadSceneInner(
    allocator: Allocator,
    scene_value: Value,
    prefab_cache: *PrefabCache,
    base_dir: []const u8,
    depth: usize,
) LoadError!Scene {
    if (depth > MAX_INCLUDE_DEPTH) return error.IncludeDepthExceeded;

    const scene_obj = scene_value.asObject() orelse return error.InvalidScene;

    const name = scene_obj.getString("name") orelse "unnamed";

    // Scripts
    var scripts: []const []const u8 = &.{};
    if (scene_obj.getArray("scripts")) |scripts_arr| {
        var script_list: std.ArrayList([]const u8) = .{};
        for (scripts_arr.items) |item| {
            if (item.asString()) |s| {
                try script_list.append(allocator, s);
            }
        }
        scripts = try script_list.toOwnedSlice(allocator);
    }

    // Camera
    var camera: ?Scene.CameraConfig = null;
    if (scene_obj.getObject("camera")) |cam_obj| {
        camera = .{};
        if (cam_obj.getInteger("x")) |x| camera.?.x = @floatFromInt(x);
        if (cam_obj.getFloat("x")) |x| camera.?.x = @floatCast(x);
        if (cam_obj.getInteger("y")) |y| camera.?.y = @floatFromInt(y);
        if (cam_obj.getFloat("y")) |y| camera.?.y = @floatCast(y);
        if (cam_obj.getFloat("zoom")) |z| camera.?.zoom = @floatCast(z);
        if (cam_obj.getInteger("zoom")) |z| camera.?.zoom = @floatFromInt(z);
    }

    var entities: std.ArrayList(Entity) = .{};

    // Process includes first — included entities come before local entities
    if (scene_obj.getArray("include")) |include_arr| {
        for (include_arr.items) |include_val| {
            if (include_val.asString()) |include_path| {
                const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, include_path });
                const included = loadInclude(allocator, full_path, prefab_cache, depth + 1) catch |err| {
                    if (err == error.FileNotFound) continue; // skip missing includes gracefully
                    return err;
                };
                for (included) |e| {
                    try entities.append(allocator, e);
                }
            }
        }
    }

    // Process local entities
    if (scene_obj.getArray("entities")) |entities_arr| {
        for (entities_arr.items) |entity_val| {
            const entity = try loadEntity(allocator, entity_val, prefab_cache);
            try entities.append(allocator, entity);
        }
    }

    return Scene{
        .name = name,
        .scripts = scripts,
        .entities = try entities.toOwnedSlice(allocator),
        .camera = camera,
        .allocator = allocator,
    };
}

/// Load an include file (scene fragment). Returns just the entities.
fn loadInclude(
    allocator: Allocator,
    path: []const u8,
    prefab_cache: *PrefabCache,
    depth: usize,
) LoadError![]const Entity {
    if (depth > MAX_INCLUDE_DEPTH) return error.IncludeDepthExceeded;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| return err;
    defer file.close();
    const source = try file.readToEndAlloc(allocator, 1024 * 1024);
    var p = parser.Parser.init(allocator, source);
    const val = try p.parse();
    const obj = val.asObject() orelse return error.InvalidScene;

    const inc_base_dir = blk: {
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
            break :blk path[0..idx];
        }
        break :blk ".";
    };

    var entities: std.ArrayList(Entity) = .{};

    // Nested includes
    if (obj.getArray("include")) |include_arr| {
        for (include_arr.items) |include_val| {
            if (include_val.asString()) |include_path| {
                const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ inc_base_dir, include_path });
                const included = loadInclude(allocator, full_path, prefab_cache, depth + 1) catch |err| {
                    if (err == error.FileNotFound) continue;
                    return err;
                };
                for (included) |e| {
                    try entities.append(allocator, e);
                }
            }
        }
    }

    // Entities in the fragment
    if (obj.getArray("entities")) |entities_arr| {
        for (entities_arr.items) |entity_val| {
            const entity = try loadEntity(allocator, entity_val, prefab_cache);
            try entities.append(allocator, entity);
        }
    }

    return try entities.toOwnedSlice(allocator);
}

/// Load a single entity, merging with prefab if specified.
/// Prefabs can define children, which become child entities.
fn loadEntity(allocator: Allocator, entity_val: Value, prefab_cache: *PrefabCache) LoadError!Entity {
    const entity_obj = entity_val.asObject() orelse return error.InvalidEntity;

    const prefab_name = entity_obj.getString("prefab");
    const scene_components = entity_obj.getObject("components");

    // Load prefab data
    var prefab_components: ?Value.Object = null;
    var prefab_children: ?Value.Array = null;
    if (prefab_name) |pname| {
        if (try prefab_cache.get(pname)) |prefab_val| {
            if (prefab_val.asObject()) |prefab_obj| {
                prefab_components = prefab_obj.getObject("components");
                prefab_children = prefab_obj.getArray("children");
            }
        }
    }

    // Merge components: prefab first, scene overrides
    var merged: std.ArrayList(Entity.ComponentData) = .{};

    if (prefab_components) |pc| {
        for (pc.entries) |entry| {
            try merged.append(allocator, .{ .name = entry.key, .value = entry.value });
        }
    }

    if (scene_components) |sc| {
        for (sc.entries) |entry| {
            var found = false;
            for (merged.items, 0..) |existing, i| {
                if (std.mem.eql(u8, existing.name, entry.key)) {
                    merged.items[i].value = entry.value;
                    found = true;
                    break;
                }
            }
            if (!found) {
                try merged.append(allocator, .{ .name = entry.key, .value = entry.value });
            }
        }
    }

    // Collect children: from prefab + from entity definition
    var children: std.ArrayList(Entity) = .{};

    // Prefab children
    if (prefab_children) |pc| {
        for (pc.items) |child_val| {
            const child = try loadEntity(allocator, child_val, prefab_cache);
            try children.append(allocator, child);
        }
    }

    // Entity-level children (override or extend prefab children)
    if (entity_obj.getArray("children")) |entity_children| {
        for (entity_children.items) |child_val| {
            const child = try loadEntity(allocator, child_val, prefab_cache);
            try children.append(allocator, child);
        }
    }

    return Entity{
        .prefab = prefab_name,
        .components = try merged.toOwnedSlice(allocator),
        .children = try children.toOwnedSlice(allocator),
        .parent_index = null,
        .children_indices = &.{},
    };
}

/// Flatten the entity tree into a linear list with bidirectional parent/child indices.
/// Top-level entities come first, then their children depth-first.
/// Sets `parent_index` and `children_indices` on each entity.
pub fn flattenEntities(allocator: Allocator, tree_entities: []const Entity) ![]Entity {
    var flat: std.ArrayList(Entity) = .{};

    // First pass: add all top-level entities to get their indices
    for (tree_entities) |entity| {
        try flattenRecursive(allocator, &flat, entity, null);
    }

    var result = try flat.toOwnedSlice(allocator);

    // Second pass: set children_indices for each entity that has children
    for (result, 0..) |*entity, i| {
        if (entity.children.len > 0) {
            var indices: std.ArrayList(usize) = .{};
            for (result[i + 1 ..], i + 1..) |other, j| {
                if (other.parent_index) |pi| {
                    if (pi == i) try indices.append(allocator, j);
                }
            }
            entity.children_indices = try indices.toOwnedSlice(allocator);
        }
    }

    return result;
}

fn flattenRecursive(
    allocator: Allocator,
    flat: *std.ArrayList(Entity),
    entity: Entity,
    parent_idx: ?usize,
) !void {
    const my_index = flat.items.len;
    var e = entity;
    e.parent_index = parent_idx;
    try flat.append(allocator, e);

    for (entity.children) |child| {
        try flattenRecursive(allocator, flat, child, my_index);
    }
}

// ======================== Tests ========================

test "load scene from parsed value — minimal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser.Parser.init(alloc,
        \\.{
        \\    .name = "test_scene",
        \\    .scripts = .{ "script_a", "script_b" },
        \\    .entities = .{
        \\        .{ .components = .{ .Position = .{ .x = 10, .y = 20 } } },
        \\        .{ .components = .{ .Position = .{ .x = 30, .y = 40 }, .Worker = .{} } },
        \\    },
        \\}
    );
    const val = try p.parse();
    const scene = try loadSceneFromValue(alloc, val, "nonexistent", ".");

    try std.testing.expectEqualStrings("test_scene", scene.name);
    try std.testing.expectEqual(@as(usize, 2), scene.scripts.len);
    try std.testing.expectEqualStrings("script_a", scene.scripts[0]);
    try std.testing.expectEqual(@as(usize, 2), scene.entities.len);

    const e0 = scene.entities[0];
    try std.testing.expect(e0.prefab == null);
    try std.testing.expectEqual(@as(usize, 1), e0.components.len);
    try std.testing.expectEqualStrings("Position", e0.components[0].name);

    const e1 = scene.entities[1];
    try std.testing.expectEqual(@as(usize, 2), e1.components.len);
    try std.testing.expect(e1.hasComponent("Position"));
    try std.testing.expect(e1.hasComponent("Worker"));
}

test "load scene with camera" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser.Parser.init(alloc,
        \\.{
        \\    .name = "cam_scene",
        \\    .scripts = .{},
        \\    .camera = .{ .x = 400, .y = 300 },
        \\    .entities = .{},
        \\}
    );
    const val = try p.parse();
    const scene = try loadSceneFromValue(alloc, val, "nonexistent", ".");

    try std.testing.expect(scene.camera != null);
    try std.testing.expectApproxEqAbs(@as(f32, 400.0), scene.camera.?.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 300.0), scene.camera.?.y, 0.001);
}

test "entity with prefab name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser.Parser.init(alloc,
        \\.{
        \\    .name = "main",
        \\    .scripts = .{},
        \\    .entities = .{
        \\        .{ .prefab = "worker", .components = .{ .Position = .{ .x = 0, .y = 0 } } },
        \\        .{ .prefab = "worker", .components = .{ .Position = .{ .x = 50, .y = 0 } } },
        \\        .{ .prefab = "ship_carcase", .components = .{ .Position = .{ .x = 0, .y = 0 } } },
        \\    },
        \\}
    );
    const val = try p.parse();
    const scene = try loadSceneFromValue(alloc, val, "nonexistent", ".");

    try std.testing.expectEqual(@as(usize, 3), scene.entities.len);
    try std.testing.expectEqualStrings("worker", scene.entities[0].prefab.?);

    const workers = scene.getEntitiesByPrefab("worker");
    try std.testing.expectEqual(@as(usize, 2), workers.len);
}

test "component merging — scene overrides prefab" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var prefab_p = parser.Parser.init(alloc,
        \\.{ .components = .{ .Worker = .{}, .ClosestMovementNode = .{}, .NeedsClosestNode = .{} } }
    );
    const prefab_val = try prefab_p.parse();

    var cache = PrefabCache.init(alloc, "nonexistent");
    try cache.put("worker", prefab_val);

    var entity_p = parser.Parser.init(alloc,
        \\.{ .prefab = "worker", .components = .{ .Position = .{ .x = 50, .y = 100 } } }
    );
    const entity_val = try entity_p.parse();
    const entity = try loadEntity(alloc, entity_val, &cache);

    try std.testing.expectEqualStrings("worker", entity.prefab.?);
    try std.testing.expectEqual(@as(usize, 4), entity.components.len);
    try std.testing.expect(entity.hasComponent("Worker"));
    try std.testing.expect(entity.hasComponent("ClosestMovementNode"));
    try std.testing.expect(entity.hasComponent("NeedsClosestNode"));
    try std.testing.expect(entity.hasComponent("Position"));
    try std.testing.expectEqual(@as(i64, 50), entity.getComponent("Position").?.asObject().?.getInteger("x").?);
}

test "component merging — scene overrides existing prefab component" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var prefab_p = parser.Parser.init(alloc,
        \\.{ .components = .{ .Position = .{ .x = 0, .y = 0 }, .Worker = .{} } }
    );
    var cache = PrefabCache.init(alloc, "nonexistent");
    try cache.put("worker", try prefab_p.parse());

    var entity_p = parser.Parser.init(alloc,
        \\.{ .prefab = "worker", .components = .{ .Position = .{ .x = 200, .y = 300 } } }
    );
    const entity = try loadEntity(alloc, try entity_p.parse(), &cache);

    try std.testing.expectEqual(@as(usize, 2), entity.components.len);
    const pos = entity.getComponent("Position").?.asObject().?;
    try std.testing.expectEqual(@as(i64, 200), pos.getInteger("x").?);
    try std.testing.expectEqual(@as(i64, 300), pos.getInteger("y").?);
}

test "entity without prefab — inline components only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cache = PrefabCache.init(alloc, "nonexistent");
    var entity_p = parser.Parser.init(alloc,
        \\.{
        \\    .components = .{
        \\        .Position = .{ .x = 400, .y = 580 },
        \\        .Shape = .{ .shape = .{ .rectangle = .{ .width = 780, .height = 20 } } },
        \\        .RigidBody = .{ .body_type = .static },
        \\    },
        \\}
    );
    const entity = try loadEntity(alloc, try entity_p.parse(), &cache);

    try std.testing.expect(entity.prefab == null);
    try std.testing.expectEqual(@as(usize, 3), entity.components.len);
    try std.testing.expect(entity.hasComponent("Position"));
    try std.testing.expect(entity.hasComponent("Shape"));
    try std.testing.expect(entity.hasComponent("RigidBody"));
    try std.testing.expect(!entity.hasChildren());
}

// === Prefab as composition (children) ===

test "prefab with children — room spawns child entities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // water_well prefab with children (new format)
    var prefab_p = parser.Parser.init(alloc,
        \\.{
        \\    .components = .{ .Room = .{} },
        \\    .children = .{
        \\        .{ .prefab = "water_well_workstation", .components = .{ .Position = .{ .x = 78, .y = 47 } } },
        \\        .{ .prefab = "movement_node", .components = .{ .Position = .{ .x = 23, .y = 93 } } },
        \\        .{ .prefab = "movement_node", .components = .{ .Position = .{ .x = 76, .y = 93 } } },
        \\        .{ .prefab = "movement_node", .components = .{ .Position = .{ .x = 129, .y = 93 } } },
        \\    },
        \\}
    );
    var cache = PrefabCache.init(alloc, "nonexistent");
    try cache.put("water_well", try prefab_p.parse());

    // Scene uses the prefab
    var entity_p = parser.Parser.init(alloc,
        \\.{ .prefab = "water_well", .components = .{ .Position = .{ .x = 0, .y = 0 } } }
    );
    const entity = try loadEntity(alloc, try entity_p.parse(), &cache);

    // Root entity has Room component + Position override
    try std.testing.expectEqualStrings("water_well", entity.prefab.?);
    try std.testing.expect(entity.hasComponent("Room"));
    try std.testing.expect(entity.hasComponent("Position"));

    // Children from prefab
    try std.testing.expect(entity.hasChildren());
    try std.testing.expectEqual(@as(usize, 4), entity.children.len);
    try std.testing.expectEqualStrings("water_well_workstation", entity.children[0].prefab.?);
    try std.testing.expectEqualStrings("movement_node", entity.children[1].prefab.?);

    // Child positions
    const ws_pos = entity.children[0].getComponent("Position").?.asObject().?;
    try std.testing.expectEqual(@as(i64, 78), ws_pos.getInteger("x").?);
    try std.testing.expectEqual(@as(i64, 47), ws_pos.getInteger("y").?);
}

test "prefab children + entity children merge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Prefab has 2 children
    var prefab_p = parser.Parser.init(alloc,
        \\.{
        \\    .components = .{ .Room = .{} },
        \\    .children = .{
        \\        .{ .components = .{ .Position = .{ .x = 10, .y = 10 }, .Wall = .{} } },
        \\        .{ .components = .{ .Position = .{ .x = 20, .y = 20 }, .Wall = .{} } },
        \\    },
        \\}
    );
    var cache = PrefabCache.init(alloc, "nonexistent");
    try cache.put("room", try prefab_p.parse());

    // Entity extends with additional children
    var entity_p = parser.Parser.init(alloc,
        \\.{
        \\    .prefab = "room",
        \\    .components = .{ .Position = .{ .x = 0, .y = 0 } },
        \\    .children = .{
        \\        .{ .components = .{ .Position = .{ .x = 50, .y = 50 }, .Decoration = .{} } },
        \\    },
        \\}
    );
    const entity = try loadEntity(alloc, try entity_p.parse(), &cache);

    // 2 from prefab + 1 from entity = 3 children
    try std.testing.expectEqual(@as(usize, 3), entity.children.len);
    try std.testing.expect(entity.children[0].hasComponent("Wall"));
    try std.testing.expect(entity.children[1].hasComponent("Wall"));
    try std.testing.expect(entity.children[2].hasComponent("Decoration"));
}

test "nested prefab composition — prefab children reference other prefabs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // movement_node prefab
    var mn_p = parser.Parser.init(alloc,
        \\.{ .components = .{ .MovementNode = .{}, .Walkable = .{} } }
    );
    var cache = PrefabCache.init(alloc, "nonexistent");
    try cache.put("movement_node", try mn_p.parse());

    // workstation prefab — also has children (storages)
    var ws_p = parser.Parser.init(alloc,
        \\.{
        \\    .components = .{ .Workstation = .{ .workstation_type = .water_well } },
        \\    .children = .{
        \\        .{ .components = .{ .Position = .{ .x = 0, .y = -20 }, .Ios = .{} } },
        \\        .{ .components = .{ .Position = .{ .x = -55, .y = 0 }, .Eos = .{} } },
        \\    },
        \\}
    );
    try cache.put("water_well_workstation", try ws_p.parse());

    // room prefab uses both
    var room_p = parser.Parser.init(alloc,
        \\.{
        \\    .components = .{ .Room = .{} },
        \\    .children = .{
        \\        .{ .prefab = "water_well_workstation", .components = .{ .Position = .{ .x = 78, .y = 47 } } },
        \\        .{ .prefab = "movement_node", .components = .{ .Position = .{ .x = 23, .y = 93 } } },
        \\    },
        \\}
    );
    try cache.put("water_well", try room_p.parse());

    // Scene
    var scene_p = parser.Parser.init(alloc,
        \\.{ .prefab = "water_well", .components = .{ .Position = .{ .x = 0, .y = 0 } } }
    );
    const entity = try loadEntity(alloc, try scene_p.parse(), &cache);

    // Room has 2 children
    try std.testing.expectEqual(@as(usize, 2), entity.children.len);

    // First child is workstation with its own children (storages)
    const ws = entity.children[0];
    try std.testing.expectEqualStrings("water_well_workstation", ws.prefab.?);
    try std.testing.expect(ws.hasComponent("Workstation"));
    try std.testing.expect(ws.hasComponent("Position"));
    try std.testing.expectEqual(@as(usize, 2), ws.children.len); // ios + eos
    try std.testing.expect(ws.children[0].hasComponent("Ios"));
    try std.testing.expect(ws.children[1].hasComponent("Eos"));

    // Second child is movement_node (no children)
    const mn = entity.children[1];
    try std.testing.expectEqualStrings("movement_node", mn.prefab.?);
    try std.testing.expect(mn.hasComponent("MovementNode"));
    try std.testing.expect(mn.hasComponent("Walkable"));
    try std.testing.expect(mn.hasComponent("Position"));
    try std.testing.expect(!mn.hasChildren());
}

// === Include (scene composition) ===

test "scene include — merges entities from fragment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // We can't write temp files in a test easily, so we test loadSceneInner
    // with a scene that has includes pointing to nonexistent files (gracefully skipped)
    var p = parser.Parser.init(alloc,
        \\.{
        \\    .name = "main",
        \\    .scripts = .{},
        \\    .include = .{ "floor1.zon", "floor2.zon" },
        \\    .entities = .{
        \\        .{ .components = .{ .Camera = .{} } },
        \\    },
        \\}
    );
    const val = try p.parse();
    var prefab_cache = PrefabCache.init(alloc, "nonexistent");

    // Includes will be skipped (FileNotFound), only local entity remains
    const scene = try loadSceneInner(alloc, val, &prefab_cache, "nonexistent_dir", 0);
    try std.testing.expectEqualStrings("main", scene.name);
    try std.testing.expectEqual(@as(usize, 1), scene.entities.len);
    try std.testing.expect(scene.entities[0].hasComponent("Camera"));
}

test "include depth protection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var p = parser.Parser.init(alloc, ".{ .name = \"deep\", .scripts = .{}, .entities = .{} }");
    const val = try p.parse();
    var prefab_cache = PrefabCache.init(alloc, "nonexistent");

    // Should succeed at depth 16
    _ = try loadSceneInner(alloc, val, &prefab_cache, ".", MAX_INCLUDE_DEPTH);

    // Should fail at depth 17
    const result = loadSceneInner(alloc, val, &prefab_cache, ".", MAX_INCLUDE_DEPTH + 1);
    try std.testing.expectError(error.IncludeDepthExceeded, result);
}

// === End-to-end with deserialization ===

test "end-to-end: parse scene + deserialize components" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Position = struct { x: i32 = 0, y: i32 = 0 };
    const BodyType = enum { static, dynamic };
    const RigidBody = struct { body_type: BodyType = .static };
    const ShapeKind = union(enum) {
        circle: struct { radius: f32 },
        rectangle: struct { width: f32, height: f32 },
    };
    const Shape = struct { shape: ShapeKind };

    var p = parser.Parser.init(alloc,
        \\.{
        \\    .name = "bouncing_ball",
        \\    .scripts = .{ "physics" },
        \\    .camera = .{ .x = 400, .y = 300 },
        \\    .entities = .{
        \\        .{
        \\            .components = .{
        \\                .Position = .{ .x = 400, .y = 580 },
        \\                .Shape = .{ .shape = .{ .rectangle = .{ .width = 780, .height = 20 } } },
        \\                .RigidBody = .{ .body_type = .static },
        \\            },
        \\        },
        \\        .{
        \\            .components = .{
        \\                .Position = .{ .x = 400, .y = 150 },
        \\                .Shape = .{ .shape = .{ .circle = .{ .radius = 30 } } },
        \\                .RigidBody = .{ .body_type = .dynamic },
        \\            },
        \\        },
        \\    },
        \\}
    );
    const val = try p.parse();
    const scene = try loadSceneFromValue(alloc, val, "nonexistent", ".");

    try std.testing.expectEqualStrings("bouncing_ball", scene.name);
    try std.testing.expectEqual(@as(usize, 2), scene.entities.len);

    const floor = scene.entities[0];
    const floor_pos = try des.deserialize(Position, floor.getComponent("Position").?, alloc);
    try std.testing.expectEqual(@as(i32, 400), floor_pos.x);
    try std.testing.expectEqual(@as(i32, 580), floor_pos.y);

    const floor_shape = try des.deserialize(Shape, floor.getComponent("Shape").?, alloc);
    switch (floor_shape.shape) {
        .rectangle => |r| {
            try std.testing.expectApproxEqAbs(@as(f32, 780.0), r.width, 0.001);
            try std.testing.expectApproxEqAbs(@as(f32, 20.0), r.height, 0.001);
        },
        else => return error.TypeMismatch,
    }

    const ball = scene.entities[1];
    const ball_rb = try des.deserialize(RigidBody, ball.getComponent("RigidBody").?, alloc);
    try std.testing.expectEqual(BodyType.dynamic, ball_rb.body_type);
}

// === Real file test ===

test "load scene from real file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const scene = loadScene(
        alloc,
        "../../../flying-platform-labelle/scenes/main.zon",
        "../../../flying-platform-labelle/prefabs",
    ) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };

    try std.testing.expectEqualStrings("main", scene.name);
    try std.testing.expect(scene.scripts.len > 0);
    try std.testing.expectEqualStrings("pathfinder_bridge", scene.scripts[0]);
    try std.testing.expect(scene.entities.len > 0);

    const ship = scene.entities[0];
    try std.testing.expectEqualStrings("ship_carcase", ship.prefab.?);
    try std.testing.expect(ship.hasComponent("Position"));
    try std.testing.expect(ship.hasComponent("ShipCarcase"));

    const workers = scene.getEntitiesByPrefab("worker");
    try std.testing.expect(workers.len >= 2);
    for (workers) |w| {
        try std.testing.expect(w.hasComponent("Position"));
        try std.testing.expect(w.hasComponent("Worker"));
        try std.testing.expect(w.hasComponent("ClosestMovementNode"));
        try std.testing.expect(w.hasComponent("NeedsClosestNode"));
    }
}

// === Flatten with bidirectional parent/child indices ===

test "flattenEntities — parent refs children, children ref parent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Simple tree: parent with 2 children
    var cache = PrefabCache.init(alloc, "nonexistent");

    var prefab_p = parser.Parser.init(alloc,
        \\.{
        \\    .components = .{ .Room = .{} },
        \\    .children = .{
        \\        .{ .components = .{ .Wall = .{}, .Position = .{ .x = 10, .y = 0 } } },
        \\        .{ .components = .{ .Door = .{}, .Position = .{ .x = 50, .y = 0 } } },
        \\    },
        \\}
    );
    const parent_entity = try loadEntity(alloc, try prefab_p.parse(), &cache);
    try std.testing.expectEqual(@as(usize, 2), parent_entity.children.len);

    const flat = try flattenEntities(alloc, &.{parent_entity});

    // Flat: parent(0), wall(1), door(2)
    try std.testing.expectEqual(@as(usize, 3), flat.len);

    // Parent has no parent_index
    try std.testing.expect(flat[0].parent_index == null);
    // Parent's children_indices point to wall and door
    try std.testing.expectEqual(@as(usize, 2), flat[0].children_indices.len);
    try std.testing.expectEqual(@as(usize, 1), flat[0].children_indices[0]);
    try std.testing.expectEqual(@as(usize, 2), flat[0].children_indices[1]);

    // Wall (index 1) points back to parent
    try std.testing.expectEqual(@as(usize, 0), flat[1].parent_index.?);
    try std.testing.expect(flat[1].hasComponent("Wall"));
    try std.testing.expectEqual(@as(usize, 0), flat[1].children_indices.len);

    // Door (index 2) points back to parent
    try std.testing.expectEqual(@as(usize, 0), flat[2].parent_index.?);
    try std.testing.expect(flat[2].hasComponent("Door"));
    try std.testing.expectEqual(@as(usize, 0), flat[2].children_indices.len);
}

test "flattenEntities — nested grandchildren" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cache = PrefabCache.init(alloc, "nonexistent");

    // Grandparent -> Parent -> Child
    var child_p = parser.Parser.init(alloc,
        \\.{ .components = .{ .Leaf = .{} } }
    );
    try cache.put("leaf", try child_p.parse());

    var parent_p = parser.Parser.init(alloc,
        \\.{ .components = .{ .Branch = .{} }, .children = .{ .{ .prefab = "leaf", .components = .{} } } }
    );
    try cache.put("branch", try parent_p.parse());

    var root_p = parser.Parser.init(alloc,
        \\.{
        \\    .components = .{ .Root = .{} },
        \\    .children = .{
        \\        .{ .prefab = "branch", .components = .{} },
        \\    },
        \\}
    );
    const root = try loadEntity(alloc, try root_p.parse(), &cache);
    const flat = try flattenEntities(alloc, &.{root});

    // Flat: root(0), branch(1), leaf(2)
    try std.testing.expectEqual(@as(usize, 3), flat.len);

    // Root -> [branch]
    try std.testing.expect(flat[0].parent_index == null);
    try std.testing.expectEqual(@as(usize, 1), flat[0].children_indices.len);
    try std.testing.expectEqual(@as(usize, 1), flat[0].children_indices[0]);

    // Branch -> [leaf], parent = root
    try std.testing.expectEqual(@as(usize, 0), flat[1].parent_index.?);
    try std.testing.expectEqual(@as(usize, 1), flat[1].children_indices.len);
    try std.testing.expectEqual(@as(usize, 2), flat[1].children_indices[0]);

    // Leaf, parent = branch, no children
    try std.testing.expectEqual(@as(usize, 1), flat[2].parent_index.?);
    try std.testing.expectEqual(@as(usize, 0), flat[2].children_indices.len);
}
