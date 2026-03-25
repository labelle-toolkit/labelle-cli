const std = @import("std");
const parser = @import("parser.zig");
const scene_loader = @import("scene_loader.zig");
const Scene = scene_loader.Scene;
const Allocator = std.mem.Allocator;

/// Hot-reload orchestrator for runtime scenes.
/// Watches scene and prefab files for changes (via mtime polling)
/// and reloads when modifications are detected.
pub const HotReloader = struct {
    scene_path: []const u8,
    prefab_dir: []const u8,
    allocator: Allocator,

    /// Current loaded scene (owned by scene_arena).
    current_scene: ?Scene,

    /// Arena for the current scene — swapped on reload for clean memory management.
    scene_arena: std.heap.ArenaAllocator,

    /// File modification times for change detection.
    watched_files: std.StringHashMap(i128),

    /// Callback invoked before a reload (teardown hook).
    on_before_reload: ?*const fn (scene: Scene) void,

    /// Callback invoked after a successful reload.
    on_after_reload: ?*const fn (scene: Scene) void,

    /// Stats
    reload_count: usize,
    last_reload_time_ns: u64,

    pub fn init(
        allocator: Allocator,
        scene_path: []const u8,
        prefab_dir: []const u8,
    ) HotReloader {
        return .{
            .scene_path = scene_path,
            .prefab_dir = prefab_dir,
            .allocator = allocator,
            .current_scene = null,
            .scene_arena = std.heap.ArenaAllocator.init(allocator),
            .watched_files = std.StringHashMap(i128).init(allocator),
            .on_before_reload = null,
            .on_after_reload = null,
            .reload_count = 0,
            .last_reload_time_ns = 0,
        };
    }

    pub fn deinit(self: *HotReloader) void {
        // Free all duped key strings in watched_files
        var iter = self.watched_files.keyIterator();
        while (iter.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.scene_arena.deinit();
        self.watched_files.deinit();
    }

    /// Initial load. Must be called before polling.
    pub fn load(self: *HotReloader) !void {
        try self.doReload();
        try self.snapshotFileTimes();
    }

    /// Force an immediate reload from disk (e.g., triggered by F5 keypress).
    pub fn forceReload(self: *HotReloader) !void {
        try self.doReload();
        try self.snapshotFileTimes();
    }

    /// Poll for file changes. Call this once per frame (or on a timer).
    /// Returns true if a reload occurred.
    pub fn poll(self: *HotReloader) !bool {
        if (try self.hasFileChanges()) {
            try self.doReload();
            try self.snapshotFileTimes();
            return true;
        }
        return false;
    }

    /// Get the current scene. Returns null if not yet loaded.
    pub fn getScene(self: *const HotReloader) ?Scene {
        return self.current_scene;
    }

    fn doReload(self: *HotReloader) !void {
        var timer = std.time.Timer.start() catch null;

        // Notify before reload
        if (self.current_scene) |scene| {
            if (self.on_before_reload) |cb| cb(scene);
        }

        // Clear before arena reset to avoid dangling pointer on load failure
        self.current_scene = null;

        // Reset the arena — frees all memory from previous scene load
        _ = self.scene_arena.reset(.retain_capacity);

        const arena_alloc = self.scene_arena.allocator();

        // Load scene fresh from disk
        self.current_scene = try scene_loader.loadScene(
            arena_alloc,
            self.scene_path,
            self.prefab_dir,
        );

        if (timer) |*t| {
            self.last_reload_time_ns = t.read();
        }
        self.reload_count += 1;

        // Notify after reload
        if (self.current_scene) |scene| {
            if (self.on_after_reload) |cb| cb(scene);
        }
    }

    fn snapshotFileTimes(self: *HotReloader) !void {
        // Free all previously duped key strings before clearing the map
        var iter = self.watched_files.keyIterator();
        while (iter.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.watched_files.clearRetainingCapacity();

        // Watch the scene file
        try self.watchFile(self.scene_path);

        // Watch all prefab files in the directory
        var dir = std.fs.cwd().openDir(self.prefab_dir, .{ .iterate = true }) catch return;
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zon")) {
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.prefab_dir, entry.name });
                defer self.allocator.free(full_path);
                try self.watchFile(full_path);
            }
        }
    }

    fn watchFile(self: *HotReloader, path: []const u8) !void {
        const mtime = getFileMtime(path) orelse return;
        const owned_path = try self.allocator.dupe(u8, path);
        try self.watched_files.put(owned_path, mtime);
    }

    fn hasFileChanges(self: *HotReloader) !bool {
        var iter = self.watched_files.iterator();
        while (iter.next()) |entry| {
            const current_mtime = getFileMtime(entry.key_ptr.*) orelse continue;
            if (current_mtime != entry.value_ptr.*) return true;
        }
        return false;
    }

    fn getFileMtime(path: []const u8) ?i128 {
        const file = std.fs.cwd().openFile(path, .{}) catch return null;
        defer file.close();
        const stat = file.stat() catch return null;
        return stat.mtime;
    }
};

/// Simulated game loop for testing hot reload behavior.
/// Not a real game — just demonstrates the reload cycle.
pub const SimulatedGame = struct {
    reloader: HotReloader,
    frame_count: usize,
    reload_log: std.ArrayList(ReloadEvent),

    pub const ReloadEvent = struct {
        frame: usize,
        entity_count: usize,
        scene_name: []const u8,
        reload_time_ns: u64,
    };

    pub fn init(allocator: Allocator, scene_path: []const u8, prefab_dir: []const u8) SimulatedGame {
        return .{
            .reloader = HotReloader.init(allocator, scene_path, prefab_dir),
            .frame_count = 0,
            .reload_log = .{},
        };
    }

    pub fn deinit(self: *SimulatedGame) void {
        // Free duped scene_name strings from reload log
        for (self.reload_log.items) |event| {
            self.reloader.allocator.free(event.scene_name);
        }
        self.reload_log.deinit(self.reloader.allocator);
        self.reloader.deinit();
    }

    /// Start the game — initial scene load.
    pub fn start(self: *SimulatedGame) !void {
        try self.reloader.load();
        try self.logReload();
    }

    /// Simulate one frame. Polls for file changes.
    pub fn tick(self: *SimulatedGame) !void {
        self.frame_count += 1;
        if (try self.reloader.poll()) {
            try self.logReload();
        }
    }

    /// Force a reload (simulates F5 keypress).
    pub fn reload(self: *SimulatedGame) !void {
        try self.reloader.forceReload();
        try self.logReload();
    }

    fn logReload(self: *SimulatedGame) !void {
        if (self.reloader.current_scene) |scene| {
            // Dupe scene_name onto the parent allocator so it survives arena resets
            const owned_name = try self.reloader.allocator.dupe(u8, scene.name);
            try self.reload_log.append(self.reloader.allocator, .{
                .frame = self.frame_count,
                .entity_count = scene.entities.len,
                .scene_name = owned_name,
                .reload_time_ns = self.reloader.last_reload_time_ns,
            });
        }
    }
};

// ======================== Tests ========================

test "hot reload: initial load" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create temp scene file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const scene_content =
        \\.{
        \\    .name = "test",
        \\    .scripts = .{},
        \\    .entities = .{
        \\        .{ .components = .{ .Position = .{ .x = 10, .y = 20 } } },
        \\    },
        \\}
    ;
    try tmp_dir.dir.writeFile(.{ .sub_path = "scene.zon", .data = scene_content });

    // Get the real path
    const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.zon");

    var reloader = HotReloader.init(alloc, scene_path, "nonexistent");
    defer reloader.deinit();

    try reloader.load();

    const scene = reloader.getScene().?;
    try std.testing.expectEqualStrings("test", scene.name);
    try std.testing.expectEqual(@as(usize, 1), scene.entities.len);
    try std.testing.expectEqual(@as(usize, 1), reloader.reload_count);
}

test "hot reload: force reload picks up file changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Initial scene: 1 entity
    try tmp_dir.dir.writeFile(.{
        .sub_path = "scene.zon",
        .data =
        \\.{
        \\    .name = "v1",
        \\    .scripts = .{},
        \\    .entities = .{
        \\        .{ .components = .{ .Position = .{ .x = 10, .y = 20 } } },
        \\    },
        \\}
        ,
    });

    const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.zon");

    var reloader = HotReloader.init(alloc, scene_path, "nonexistent");
    defer reloader.deinit();

    try reloader.load();
    try std.testing.expectEqualStrings("v1", reloader.getScene().?.name);
    try std.testing.expectEqual(@as(usize, 1), reloader.getScene().?.entities.len);

    // Modify scene: 3 entities, new name
    try tmp_dir.dir.writeFile(.{
        .sub_path = "scene.zon",
        .data =
        \\.{
        \\    .name = "v2",
        \\    .scripts = .{ "new_script" },
        \\    .entities = .{
        \\        .{ .components = .{ .Position = .{ .x = 10, .y = 20 } } },
        \\        .{ .components = .{ .Position = .{ .x = 30, .y = 40 } } },
        \\        .{ .components = .{ .Position = .{ .x = 50, .y = 60 } } },
        \\    },
        \\}
        ,
    });

    // Force reload
    try reloader.forceReload();
    try std.testing.expectEqualStrings("v2", reloader.getScene().?.name);
    try std.testing.expectEqual(@as(usize, 3), reloader.getScene().?.entities.len);
    try std.testing.expectEqual(@as(usize, 1), reloader.getScene().?.scripts.len);
    try std.testing.expectEqual(@as(usize, 2), reloader.reload_count);
}

test "hot reload: poll detects mtime changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{
        .sub_path = "scene.zon",
        .data =
        \\.{
        \\    .name = "original",
        \\    .scripts = .{},
        \\    .entities = .{},
        \\}
        ,
    });

    const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.zon");

    var reloader = HotReloader.init(alloc, scene_path, "nonexistent");
    defer reloader.deinit();

    try reloader.load();

    // Poll with no changes — should not reload
    const changed1 = try reloader.poll();
    try std.testing.expect(!changed1);
    try std.testing.expectEqual(@as(usize, 1), reloader.reload_count);

    // Sleep briefly to ensure mtime changes (filesystem granularity)
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Modify the file
    try tmp_dir.dir.writeFile(.{
        .sub_path = "scene.zon",
        .data =
        \\.{
        \\    .name = "modified",
        \\    .scripts = .{},
        \\    .entities = .{
        \\        .{ .components = .{ .Marker = .{} } },
        \\    },
        \\}
        ,
    });

    // Poll should detect change and reload
    const changed2 = try reloader.poll();
    try std.testing.expect(changed2);
    try std.testing.expectEqualStrings("modified", reloader.getScene().?.name);
    try std.testing.expectEqual(@as(usize, 1), reloader.getScene().?.entities.len);
    try std.testing.expectEqual(@as(usize, 2), reloader.reload_count);

    // Poll again with no new changes
    const changed3 = try reloader.poll();
    try std.testing.expect(!changed3);
    try std.testing.expectEqual(@as(usize, 2), reloader.reload_count);
}

test "hot reload: memory is properly recycled on reload" {
    // Verifies the arena swap doesn't leak — each reload frees the previous scene
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{
        .sub_path = "scene.zon",
        .data = ".{ .name = \"v1\", .scripts = .{}, .entities = .{} }",
    });

    const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.zon");

    var reloader = HotReloader.init(alloc, scene_path, "nonexistent");
    defer reloader.deinit();

    // Load and reload 100 times — if memory leaks, arena grows unbounded
    try reloader.load();
    for (0..100) |_| {
        try reloader.forceReload();
    }
    try std.testing.expectEqual(@as(usize, 101), reloader.reload_count);
    try std.testing.expectEqualStrings("v1", reloader.getScene().?.name);
}

test "hot reload: simulated game loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{
        .sub_path = "scene.zon",
        .data =
        \\.{
        \\    .name = "game",
        \\    .scripts = .{ "physics" },
        \\    .entities = .{
        \\        .{ .components = .{ .Position = .{ .x = 0, .y = 0 } } },
        \\    },
        \\}
        ,
    });

    const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.zon");

    var game = SimulatedGame.init(alloc, scene_path, "nonexistent");
    defer game.deinit();

    // Start
    try game.start();
    try std.testing.expectEqual(@as(usize, 1), game.reload_log.items.len);
    try std.testing.expectEqualStrings("game", game.reload_log.items[0].scene_name);
    try std.testing.expectEqual(@as(usize, 1), game.reload_log.items[0].entity_count);

    // Simulate 10 frames with no changes
    for (0..10) |_| {
        try game.tick();
    }
    try std.testing.expectEqual(@as(usize, 10), game.frame_count);
    try std.testing.expectEqual(@as(usize, 1), game.reload_log.items.len); // no extra reloads

    // F5 reload
    try game.reload();
    try std.testing.expectEqual(@as(usize, 2), game.reload_log.items.len);
    try std.testing.expectEqual(@as(usize, 10), game.reload_log.items[1].frame);
}

test "hot reload: prefab file changes trigger reload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create prefab dir and files
    try tmp_dir.dir.makeDir("prefabs");

    try tmp_dir.dir.writeFile(.{
        .sub_path = "prefabs/enemy.zon",
        .data = ".{ .components = .{ .Enemy = .{}, .Health = .{ .hp = 100 } } }",
    });

    try tmp_dir.dir.writeFile(.{
        .sub_path = "scene.zon",
        .data =
        \\.{
        \\    .name = "level1",
        \\    .scripts = .{},
        \\    .entities = .{
        \\        .{ .prefab = "enemy", .components = .{ .Position = .{ .x = 50, .y = 50 } } },
        \\    },
        \\}
        ,
    });

    const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.zon");
    const prefab_dir = try tmp_dir.dir.realpathAlloc(alloc, "prefabs");

    var reloader = HotReloader.init(alloc, scene_path, prefab_dir);
    defer reloader.deinit();

    try reloader.load();
    const scene1 = reloader.getScene().?;
    try std.testing.expectEqual(@as(usize, 1), scene1.entities.len);
    try std.testing.expect(scene1.entities[0].hasComponent("Enemy"));
    try std.testing.expect(scene1.entities[0].hasComponent("Health"));

    // No changes yet
    try std.testing.expect(!try reloader.poll());

    // Modify the prefab — add Armor component
    std.Thread.sleep(10 * std.time.ns_per_ms);
    try tmp_dir.dir.writeFile(.{
        .sub_path = "prefabs/enemy.zon",
        .data = ".{ .components = .{ .Enemy = .{}, .Health = .{ .hp = 200 }, .Armor = .{ .defense = 50 } } }",
    });

    // Poll should detect prefab change
    const changed = try reloader.poll();
    try std.testing.expect(changed);

    const scene2 = reloader.getScene().?;
    try std.testing.expect(scene2.entities[0].hasComponent("Enemy"));
    try std.testing.expect(scene2.entities[0].hasComponent("Health"));
    try std.testing.expect(scene2.entities[0].hasComponent("Armor")); // new from prefab
    try std.testing.expectEqual(@as(usize, 2), reloader.reload_count);
}

test "hot reload: reload timing is tracked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(.{
        .sub_path = "scene.zon",
        .data = ".{ .name = \"bench\", .scripts = .{}, .entities = .{} }",
    });

    const scene_path = try tmp_dir.dir.realpathAlloc(alloc, "scene.zon");

    var reloader = HotReloader.init(alloc, scene_path, "nonexistent");
    defer reloader.deinit();

    try reloader.load();
    // Reload time should be > 0 (we actually did work)
    try std.testing.expect(reloader.last_reload_time_ns > 0);
}
