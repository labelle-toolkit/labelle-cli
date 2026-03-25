const std = @import("std");
const Allocator = std.mem.Allocator;

/// Scans a scripts/ directory structure and produces an ordered list of
/// script registrations with state scoping.
///
/// Convention:
///   scripts/*.zig              → runs in ALL states
///   scripts/<state>/*.zig      → runs only in that state
///   scripts/<s1>+<s2>/*.zig    → runs in multiple states
///
/// Execution order:
///   Numeric prefix determines order: 01_foo.zig runs before 02_bar.zig.
///   Scripts without a prefix sort after numbered ones, alphabetically.
///   The prefix is stripped from the script name.
pub const ScriptScanner = struct {
    allocator: Allocator,
    entries: std.ArrayList(ScriptEntry),
    valid_states: []const []const u8,

    pub const ScriptEntry = struct {
        /// Script name (prefix stripped, .zig stripped).
        name: []const u8,
        /// Original filename for display/debugging.
        filename: []const u8,
        /// States this script runs in. Empty slice = all states.
        states: []const []const u8,
        /// Sort key extracted from numeric prefix (null = no prefix).
        sort_order: ?u32,
        /// Subdirectory it was found in (null = root).
        subdir: ?[]const u8,
    };

    pub fn init(allocator: Allocator, valid_states: []const []const u8) ScriptScanner {
        return .{
            .allocator = allocator,
            .entries = .{},
            .valid_states = valid_states,
        };
    }

    /// Scan a scripts directory on disk.
    /// Root-level .zig files are global (all states).
    /// First-level subdirectories define state binding.
    /// Deeper subdirectories are purely organizational.
    pub fn scanDir(self: *ScriptScanner, scripts_dir: []const u8) !void {
        var dir = try std.fs.cwd().openDir(scripts_dir, .{ .iterate = true });
        defer dir.close();

        // Collect root-level .zig files (global) and first-level directories
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
                // Root-level script — runs in all states
                const name_copy = try self.allocator.dupe(u8, entry.name);
                try self.addEntry(name_copy, null, &.{});
            } else if (entry.kind == .directory) {
                // First-level directory — parse for state binding
                const dir_states = try self.parseDirStates(entry.name);
                if (dir_states.len == 0) continue; // not a valid state directory

                const subdir_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ scripts_dir, entry.name });
                const subdir_name = try self.allocator.dupe(u8, entry.name);
                // Recursively scan — deeper subdirs are organizational only
                try self.scanZigFilesRecursive(subdir_path, subdir_name, dir_states);
            }
        }

        // Sort all entries once at the end
        self.sortEntries();

        // Validate no duplicate sort orders within the same scope
        try self.validateNoDuplicateOrders();
    }

    /// Scan from in-memory data (for testing without filesystem).
    pub fn addEntry(self: *ScriptScanner, filename: []const u8, subdir: ?[]const u8, states: []const []const u8) !void {
        const name = stripPrefixAndExtension(filename);
        const sort_order = extractSortOrder(filename);

        try self.entries.append(self.allocator, .{
            .name = name,
            .filename = filename,
            .states = states,
            .sort_order = sort_order,
            .subdir = subdir,
        });
    }

    /// Get the sorted script entries.
    pub fn getEntries(self: *const ScriptScanner) []const ScriptEntry {
        return self.entries.items;
    }

    /// Get entries filtered by state.
    pub fn getEntriesForState(self: *const ScriptScanner, state: []const u8) ![]const ScriptEntry {
        var result: std.ArrayList(ScriptEntry) = .{};
        for (self.entries.items) |entry| {
            if (entry.states.len == 0) {
                // Global script — runs in all states
                try result.append(self.allocator, entry);
            } else {
                for (entry.states) |s| {
                    if (std.mem.eql(u8, s, state)) {
                        try result.append(self.allocator, entry);
                        break;
                    }
                }
            }
        }
        return try result.toOwnedSlice(self.allocator);
    }

    /// Recursively scan a directory for .zig files. Subdirectories within
    /// a state folder are purely organizational — they don't affect state binding.
    fn scanZigFilesRecursive(self: *ScriptScanner, dir_path: []const u8, state_dir_name: ?[]const u8, states: []const []const u8) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
                const name_copy = try self.allocator.dupe(u8, entry.name);
                try self.addEntry(name_copy, state_dir_name, states);
            } else if (entry.kind == .directory) {
                // Recurse into organizational subdirectories
                const sub_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name });
                try self.scanZigFilesRecursive(sub_path, state_dir_name, states);
            }
        }
    }

    fn parseDirStates(self: *ScriptScanner, dir_name: []const u8) ![]const []const u8 {
        // Split on '+' and dupe each state name (dir_name may be transient)
        var states: std.ArrayList([]const u8) = .{};
        var iter = std.mem.splitScalar(u8, dir_name, '+');

        while (iter.next()) |state_name| {
            if (state_name.len == 0) continue;
            if (!isValidStateName(state_name)) continue;
            if (!self.isKnownState(state_name)) continue;
            try states.append(self.allocator, try self.allocator.dupe(u8, state_name));
        }

        return try states.toOwnedSlice(self.allocator);
    }

    fn isKnownState(self: *const ScriptScanner, name: []const u8) bool {
        for (self.valid_states) |s| {
            if (std.mem.eql(u8, s, name)) return true;
        }
        return false;
    }

    pub const ValidationError = error{
        DuplicateSortOrder,
        OutOfMemory,
    };

    /// Validate that no two scripts in the same scope share a numeric prefix.
    /// Scope = same state set (global scripts are one scope, each state dir is another).
    fn validateNoDuplicateOrders(self: *ScriptScanner) ValidationError!void {
        // Group entries by scope key, then check for duplicate sort_orders within each group.
        // Scope key: subdir name (null → "(global)")
        const entries = self.entries.items;

        for (entries, 0..) |a, i| {
            const a_order = a.sort_order orelse continue;
            for (entries[i + 1 ..]) |b| {
                const b_order = b.sort_order orelse continue;
                if (a_order != b_order) continue;

                // Same order — check if same scope
                const same_scope = blk: {
                    if (a.subdir == null and b.subdir == null) break :blk true;
                    if (a.subdir) |a_sub| {
                        if (b.subdir) |b_sub| {
                            break :blk std.mem.eql(u8, a_sub, b_sub);
                        }
                    }
                    break :blk false;
                };

                if (same_scope) {
                    // Build error message
                    const scope_name = a.subdir orelse "(global)";
                    std.debug.print(
                        "error: duplicate script order {d:0>2} in scripts/{s}/:\n  - {s}\n  - {s}\n",
                        .{ a_order, scope_name, a.filename, b.filename },
                    );
                    return error.DuplicateSortOrder;
                }
            }
        }
    }

    fn sortEntries(self: *ScriptScanner) void {
        std.mem.sortUnstable(ScriptEntry, self.entries.items, {}, struct {
            fn lessThan(_: void, a: ScriptEntry, b: ScriptEntry) bool {
                // 1. Global scripts (no subdir) before state-scoped scripts
                const a_global = a.subdir == null;
                const b_global = b.subdir == null;
                if (a_global != b_global) return a_global;

                // 2. Within same scope: numbered before unnumbered
                const a_has_order = a.sort_order != null;
                const b_has_order = b.sort_order != null;
                if (a_has_order != b_has_order) return a_has_order;

                // 3. Both numbered: sort by number
                if (a.sort_order) |a_order| {
                    if (b.sort_order) |b_order| {
                        if (a_order != b_order) return a_order < b_order;
                    }
                }

                // 4. Alphabetical by name
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
    }
};

/// Extract numeric prefix from filename: "01_foo.zig" → 1, "foo.zig" → null.
pub fn extractSortOrder(filename: []const u8) ?u32 {
    var i: usize = 0;
    while (i < filename.len and std.ascii.isDigit(filename[i])) {
        i += 1;
    }
    if (i == 0) return null;
    if (i < filename.len and filename[i] == '_') {
        return std.fmt.parseInt(u32, filename[0..i], 10) catch null;
    }
    return null;
}

/// Strip numeric prefix and .zig extension: "01_foo.zig" → "foo", "bar.zig" → "bar".
pub fn stripPrefixAndExtension(filename: []const u8) []const u8 {
    var start: usize = 0;

    // Strip numeric prefix + underscore
    while (start < filename.len and std.ascii.isDigit(filename[start])) {
        start += 1;
    }
    if (start > 0 and start < filename.len and filename[start] == '_') {
        start += 1;
    } else {
        start = 0; // not a valid prefix, keep everything
    }

    // Strip .zig extension
    var end = filename.len;
    if (std.mem.endsWith(u8, filename, ".zig")) {
        end = filename.len - 4;
    }

    return filename[start..end];
}

/// Validate state name: lowercase alphanumeric + underscores only.
pub fn isValidStateName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_') return false;
    }
    return true;
}

/// Generate assembler registration code from scanner results.
/// This is what labelle-cli would produce.
pub fn generateRegistration(allocator: Allocator, entries: []const ScriptScanner.ScriptEntry) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    const writer = buf.writer(allocator);

    try writer.writeAll("// Auto-generated by labelle-cli from scripts/ directory structure\n");
    try writer.writeAll("// DO NOT EDIT — regenerate with `labelle generate`\n\n");

    for (entries) |entry| {
        if (entry.states.len == 0) {
            try writer.print("game.registerScript(\"{s}\", @import(\"scripts/{s}\").update);\n", .{
                entry.name,
                entry.filename,
            });
        } else {
            try writer.print("game.registerScriptFull(\"{s}\", .{{ .update_fn = @import(\"scripts/", .{entry.name});
            if (entry.subdir) |subdir| {
                try writer.print("{s}/", .{subdir});
            }
            try writer.print("{s}\").update, .states = &.{{", .{entry.filename});
            for (entry.states, 0..) |state, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("\"{s}\"", .{state});
            }
            try writer.writeAll("} });\n");
        }
    }

    return try buf.toOwnedSlice(allocator);
}

// ======================== Tests ========================

test "extractSortOrder" {
    try std.testing.expectEqual(@as(?u32, 1), extractSortOrder("01_foo.zig"));
    try std.testing.expectEqual(@as(?u32, 12), extractSortOrder("12_bar.zig"));
    try std.testing.expectEqual(@as(?u32, 99), extractSortOrder("99_baz.zig"));
    try std.testing.expectEqual(@as(?u32, null), extractSortOrder("foo.zig"));
    try std.testing.expectEqual(@as(?u32, null), extractSortOrder("bar_baz.zig"));
    try std.testing.expectEqual(@as(?u32, 0), extractSortOrder("00_first.zig"));
}

test "stripPrefixAndExtension" {
    try std.testing.expectEqualStrings("foo", stripPrefixAndExtension("01_foo.zig"));
    try std.testing.expectEqualStrings("pathfinder_bridge", stripPrefixAndExtension("01_pathfinder_bridge.zig"));
    try std.testing.expectEqualStrings("camera_control", stripPrefixAndExtension("camera_control.zig"));
    try std.testing.expectEqualStrings("bar_baz", stripPrefixAndExtension("bar_baz.zig"));
    try std.testing.expectEqualStrings("save_load", stripPrefixAndExtension("03_save_load.zig"));
}

test "isValidStateName" {
    try std.testing.expect(isValidStateName("playing"));
    try std.testing.expect(isValidStateName("menu"));
    try std.testing.expect(isValidStateName("game_over"));
    try std.testing.expect(isValidStateName("level_2"));
    try std.testing.expect(!isValidStateName("Playing")); // uppercase
    try std.testing.expect(!isValidStateName("my state")); // space
    try std.testing.expect(!isValidStateName("game-over")); // hyphen
    try std.testing.expect(!isValidStateName("")); // empty
}

test "scanner: manual entries with ordering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const states = [_][]const u8{ "menu", "playing", "paused" };
    var scanner = ScriptScanner.init(alloc, &states);

    // Global scripts (root)
    try scanner.addEntry("save_load.zig", null, &.{});
    try scanner.addEntry("debug_overlay.zig", null, &.{});

    // Playing scripts with order
    const playing = [_][]const u8{"playing"};
    try scanner.addEntry("03_production_system.zig", "playing", &playing);
    try scanner.addEntry("01_pathfinder_bridge.zig", "playing", &playing);
    try scanner.addEntry("02_worker_movement.zig", "playing", &playing);

    // Menu script
    const menu = [_][]const u8{"menu"};
    try scanner.addEntry("menu_system.zig", "menu", &menu);

    scanner.sortEntries();
    const entries = scanner.getEntries();

    try std.testing.expectEqual(@as(usize, 6), entries.len);

    // Global scripts first (alphabetical)
    try std.testing.expectEqualStrings("debug_overlay", entries[0].name);
    try std.testing.expect(entries[0].subdir == null);
    try std.testing.expectEqualStrings("save_load", entries[1].name);
    try std.testing.expect(entries[1].subdir == null);

    // Then state-scoped, ordered by prefix
    try std.testing.expectEqualStrings("pathfinder_bridge", entries[2].name);
    try std.testing.expectEqual(@as(?u32, 1), entries[2].sort_order);
    try std.testing.expectEqualStrings("worker_movement", entries[3].name);
    try std.testing.expectEqual(@as(?u32, 2), entries[3].sort_order);
    try std.testing.expectEqualStrings("production_system", entries[4].name);
    try std.testing.expectEqual(@as(?u32, 3), entries[4].sort_order);

    // Unnumbered state script last
    try std.testing.expectEqualStrings("menu_system", entries[5].name);
    try std.testing.expect(entries[5].sort_order == null);
}

test "scanner: multi-state directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const states = [_][]const u8{ "playing", "paused" };
    var scanner = ScriptScanner.init(alloc, &states);

    const both = [_][]const u8{ "playing", "paused" };
    try scanner.addEntry("camera_control.zig", "playing+paused", &both);

    const entries = scanner.getEntries();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("camera_control", entries[0].name);
    try std.testing.expectEqual(@as(usize, 2), entries[0].states.len);
    try std.testing.expectEqualStrings("playing", entries[0].states[0]);
    try std.testing.expectEqualStrings("paused", entries[0].states[1]);
}

test "scanner: getEntriesForState filters correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const states = [_][]const u8{ "menu", "playing", "paused" };
    var scanner = ScriptScanner.init(alloc, &states);

    // Global
    try scanner.addEntry("save_load.zig", null, &.{});

    // Playing only
    const playing = [_][]const u8{"playing"};
    try scanner.addEntry("01_worker_movement.zig", "playing", &playing);
    try scanner.addEntry("02_production_system.zig", "playing", &playing);

    // Menu only
    const menu = [_][]const u8{"menu"};
    try scanner.addEntry("menu_system.zig", "menu", &menu);

    // Playing + paused
    const both = [_][]const u8{ "playing", "paused" };
    try scanner.addEntry("camera_control.zig", "playing+paused", &both);

    scanner.sortEntries();

    // Playing: save_load + worker_movement + production_system + camera_control
    const playing_scripts = try scanner.getEntriesForState("playing");
    try std.testing.expectEqual(@as(usize, 4), playing_scripts.len);
    try std.testing.expectEqualStrings("save_load", playing_scripts[0].name);
    try std.testing.expectEqualStrings("worker_movement", playing_scripts[1].name);
    try std.testing.expectEqualStrings("production_system", playing_scripts[2].name);
    try std.testing.expectEqualStrings("camera_control", playing_scripts[3].name);

    // Menu: save_load + menu_system
    const menu_scripts = try scanner.getEntriesForState("menu");
    try std.testing.expectEqual(@as(usize, 2), menu_scripts.len);
    try std.testing.expectEqualStrings("save_load", menu_scripts[0].name);
    try std.testing.expectEqualStrings("menu_system", menu_scripts[1].name);

    // Paused: save_load + camera_control
    const paused_scripts = try scanner.getEntriesForState("paused");
    try std.testing.expectEqual(@as(usize, 2), paused_scripts.len);
    try std.testing.expectEqualStrings("save_load", paused_scripts[0].name);
    try std.testing.expectEqualStrings("camera_control", paused_scripts[1].name);
}

test "scanner: generate registration code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const states = [_][]const u8{ "playing", "paused" };
    var scanner = ScriptScanner.init(alloc, &states);

    try scanner.addEntry("save_load.zig", null, &.{});
    const playing = [_][]const u8{"playing"};
    try scanner.addEntry("01_worker_movement.zig", "playing", &playing);
    const both = [_][]const u8{ "playing", "paused" };
    try scanner.addEntry("camera_control.zig", "playing+paused", &both);

    scanner.sortEntries();

    const code = try generateRegistration(alloc, scanner.getEntries());

    // Global script has no state filter
    try std.testing.expect(std.mem.indexOf(u8, code, "game.registerScript(\"save_load\"") != null);
    // State-scoped scripts have state filter
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worker_movement\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"camera_control\"") != null);
}

test "scanner: real directory scan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Create temp directory structure
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create scripts/
    try tmp_dir.dir.makeDir("scripts");
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/save_load.zig", .data = "// global" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/debug.zig", .data = "// global" });

    // Create scripts/playing/
    try tmp_dir.dir.makeDir("scripts/playing");
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/01_pathfinder.zig", .data = "" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/02_movement.zig", .data = "" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/03_production.zig", .data = "" });

    // Create scripts/menu/
    try tmp_dir.dir.makeDir("scripts/menu");
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/menu/menu_ui.zig", .data = "" });

    // Create scripts/playing+paused/
    try tmp_dir.dir.makeDir("scripts/playing+paused");
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing+paused/camera.zig", .data = "" });

    const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");

    const states = [_][]const u8{ "menu", "playing", "paused" };
    var scanner = ScriptScanner.init(alloc, &states);
    try scanner.scanDir(scripts_path);

    const entries = scanner.getEntries();
    // 2 global + 3 playing + 1 menu + 1 playing+paused = 7
    try std.testing.expectEqual(@as(usize, 7), entries.len);

    // Global scripts first
    try std.testing.expect(entries[0].subdir == null);
    try std.testing.expect(entries[1].subdir == null);

    // Then ordered state scripts
    // playing/ numbered scripts should be in order
    const playing_scripts = try scanner.getEntriesForState("playing");
    // 2 global + 3 playing + 1 playing+paused = 6
    try std.testing.expectEqual(@as(usize, 6), playing_scripts.len);

    // Menu: 2 global + 1 menu = 3
    const menu_scripts = try scanner.getEntriesForState("menu");
    try std.testing.expectEqual(@as(usize, 3), menu_scripts.len);
}

test "scanner: ignores invalid state directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("scripts");
    try tmp_dir.dir.makeDir("scripts/playing");
    try tmp_dir.dir.makeDir("scripts/NotAState"); // uppercase — invalid
    try tmp_dir.dir.makeDir("scripts/some-state"); // hyphen — invalid
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/foo.zig", .data = "" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/NotAState/bar.zig", .data = "" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/some-state/baz.zig", .data = "" });

    const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");

    const states = [_][]const u8{"playing"};
    var scanner = ScriptScanner.init(alloc, &states);
    try scanner.scanDir(scripts_path);

    // Only playing/foo.zig should be found
    try std.testing.expectEqual(@as(usize, 1), scanner.getEntries().len);
    try std.testing.expectEqualStrings("foo", scanner.getEntries()[0].name);
}

test "scanner: recursive subdirectories are organizational only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("scripts");
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/save_load.zig", .data = "" });

    // playing/ with organizational subdirectories
    try tmp_dir.dir.makeDir("scripts/playing");
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/01_pathfinder_bridge.zig", .data = "" });

    try tmp_dir.dir.makeDir("scripts/playing/navigation");
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/navigation/02_navigation_orchestrator.zig", .data = "" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/navigation/03_worker_movement.zig", .data = "" });

    try tmp_dir.dir.makeDir("scripts/playing/production");
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/production/04_workstation_readiness.zig", .data = "" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/production/05_production_system.zig", .data = "" });

    try tmp_dir.dir.makeDir("scripts/playing/gizmos");
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/gizmos/tendable_gizmos.zig", .data = "" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/gizmos/item_gizmos.zig", .data = "" });

    const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");

    const states = [_][]const u8{ "playing", "paused" };
    var scanner = ScriptScanner.init(alloc, &states);
    try scanner.scanDir(scripts_path);

    const entries = scanner.getEntries();
    // 1 global + 7 playing (across root + 3 subdirs) = 8
    try std.testing.expectEqual(@as(usize, 8), entries.len);

    // Global first
    try std.testing.expectEqualStrings("save_load", entries[0].name);
    try std.testing.expect(entries[0].subdir == null);

    // Then numbered playing scripts in order
    try std.testing.expectEqualStrings("pathfinder_bridge", entries[1].name);
    try std.testing.expectEqual(@as(?u32, 1), entries[1].sort_order);

    try std.testing.expectEqualStrings("navigation_orchestrator", entries[2].name);
    try std.testing.expectEqual(@as(?u32, 2), entries[2].sort_order);

    try std.testing.expectEqualStrings("worker_movement", entries[3].name);
    try std.testing.expectEqual(@as(?u32, 3), entries[3].sort_order);

    try std.testing.expectEqualStrings("workstation_readiness", entries[4].name);
    try std.testing.expectEqual(@as(?u32, 4), entries[4].sort_order);

    try std.testing.expectEqualStrings("production_system", entries[5].name);
    try std.testing.expectEqual(@as(?u32, 5), entries[5].sort_order);

    // Unnumbered gizmo scripts last (alphabetical)
    try std.testing.expectEqualStrings("item_gizmos", entries[6].name);
    try std.testing.expect(entries[6].sort_order == null);

    try std.testing.expectEqualStrings("tendable_gizmos", entries[7].name);
    try std.testing.expect(entries[7].sort_order == null);

    // All playing scripts have the "playing" state
    for (entries[1..]) |e| {
        try std.testing.expectEqual(@as(usize, 1), e.states.len);
        try std.testing.expectEqualStrings("playing", e.states[0]);
    }

    // Filter for playing: all 8
    const playing_scripts = try scanner.getEntriesForState("playing");
    try std.testing.expectEqual(@as(usize, 8), playing_scripts.len);

    // Filter for paused: only global
    const paused_scripts = try scanner.getEntriesForState("paused");
    try std.testing.expectEqual(@as(usize, 1), paused_scripts.len);
}

test "scanner: ignores directories not in valid states" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("scripts");
    try tmp_dir.dir.makeDir("scripts/playing");
    try tmp_dir.dir.makeDir("scripts/loading"); // valid name but not in states list
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/foo.zig", .data = "" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/loading/bar.zig", .data = "" });

    const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");

    const states = [_][]const u8{"playing"}; // "loading" not listed
    var scanner = ScriptScanner.init(alloc, &states);
    try scanner.scanDir(scripts_path);

    try std.testing.expectEqual(@as(usize, 1), scanner.getEntries().len);
    try std.testing.expectEqualStrings("foo", scanner.getEntries()[0].name);
}

test "scanner: duplicate sort order in same scope fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("scripts");
    try tmp_dir.dir.makeDir("scripts/playing");
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/02_foo.zig", .data = "" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/02_bar.zig", .data = "" });

    const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");

    const states = [_][]const u8{"playing"};
    var scanner = ScriptScanner.init(alloc, &states);
    const result = scanner.scanDir(scripts_path);
    try std.testing.expectError(error.DuplicateSortOrder, result);
}

test "scanner: duplicate sort order across different scopes is ok" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("scripts");
    try tmp_dir.dir.makeDir("scripts/playing");
    try tmp_dir.dir.makeDir("scripts/menu");
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/01_movement.zig", .data = "" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/menu/01_menu_ui.zig", .data = "" });

    const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");

    const states = [_][]const u8{ "playing", "menu" };
    var scanner = ScriptScanner.init(alloc, &states);
    try scanner.scanDir(scripts_path);

    try std.testing.expectEqual(@as(usize, 2), scanner.getEntries().len);
}

test "scanner: duplicate sort order across subdirs in same scope fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makeDir("scripts");
    try tmp_dir.dir.makeDir("scripts/playing");
    try tmp_dir.dir.makeDir("scripts/playing/navigation");
    try tmp_dir.dir.makeDir("scripts/playing/production");
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/navigation/02_movement.zig", .data = "" });
    try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/production/02_production.zig", .data = "" });

    const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");

    const states = [_][]const u8{"playing"};
    var scanner = ScriptScanner.init(alloc, &states);
    const result = scanner.scanDir(scripts_path);
    try std.testing.expectError(error.DuplicateSortOrder, result);
}
