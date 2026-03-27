/// Convention-based script scanner for state-scoped script registration.
///
/// Scans a `scripts/` directory and produces an ordered list of script entries
/// with state scoping based on directory structure conventions:
///
///   scripts/*.zig              → runs in ALL states (global)
///   scripts/<state>/*.zig      → runs only in that state
///   scripts/<s1>+<s2>/*.zig    → runs in multiple states
///   scripts/<state>/sub/*.zig  → organizational subdirs, same state as parent
///
/// Execution order:
///   Numeric prefix determines order: 01_foo.zig runs before 02_bar.zig.
///   Scripts without a prefix sort after numbered ones, alphabetically.
///   The prefix is stripped from the script name.
///
/// Validation:
///   - Duplicate numeric prefixes within the same state scope (including across
///     organizational subdirs) are a build error.
///   - Same prefix numbers in different state scopes are allowed.
///   - Directories not matching declared states are silently ignored.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ScriptScanner = struct {
    allocator: Allocator,
    entries: std.ArrayList(ScriptEntry),
    valid_states: []const []const u8,
    // Track shared allocations for proper cleanup (one per state dir)
    shared_subdirs: std.ArrayList([]const u8) = .{},
    shared_states: std.ArrayList([]const []const u8) = .{},

    pub const ScriptEntry = struct {
        /// Script name (prefix stripped, .zig stripped).
        name: []const u8,
        /// Original filename for display/debugging.
        filename: []const u8,
        /// States this script runs in. Empty slice = all states (global).
        states: []const []const u8,
        /// Sort key extracted from numeric prefix (null = no prefix).
        sort_order: ?u32,
        /// State directory it was found in (null = root/global).
        subdir: ?[]const u8,
        /// Relative path from the scripts/ root (e.g., "playing/navigation/02_movement.zig").
        /// For root-level scripts, same as filename.
        rel_path: []const u8,
    };

    pub const ScanError = error{
        DuplicateSortOrder,
        OutOfMemory,
    };

    pub fn init(allocator: Allocator, valid_states: []const []const u8) ScriptScanner {
        return .{
            .allocator = allocator,
            .entries = .{},
            .valid_states = valid_states,
        };
    }

    pub fn deinit(self: *ScriptScanner) void {
        // Free per-entry allocations
        for (self.entries.items) |entry| {
            // rel_path is either same pointer as filename (root scripts) or separately allocated
            if (entry.rel_path.ptr != entry.filename.ptr) {
                self.allocator.free(entry.rel_path);
            }
            self.allocator.free(entry.filename);
        }
        self.entries.deinit(self.allocator);

        // Free shared subdir names (one per state directory)
        for (self.shared_subdirs.items) |s| self.allocator.free(s);
        self.shared_subdirs.deinit(self.allocator);

        // Free shared state slices (one per state directory, each containing duped state strings)
        for (self.shared_states.items) |states| {
            for (states) |s| self.allocator.free(s);
            self.allocator.free(states);
        }
        self.shared_states.deinit(self.allocator);
    }

    /// Scan a scripts directory on disk.
    /// Root-level .zig files are global (all states).
    /// First-level subdirectories define state binding.
    /// Deeper subdirectories are purely organizational.
    pub fn scanDir(self: *ScriptScanner, scripts_dir: []const u8) ScanError!void {
        var dir = std.fs.cwd().openDir(scripts_dir, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch return) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
                // Root-level script — runs in all states
                const name_copy = try self.allocator.dupe(u8, entry.name);
                try self.addEntryWithPath(name_copy, null, &.{}, name_copy);
            } else if (entry.kind == .directory) {
                // First-level directory — parse for state binding
                const dir_states = try self.parseDirStates(entry.name);
                if (dir_states.len == 0) continue;

                const subdir_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ scripts_dir, entry.name });
                defer self.allocator.free(subdir_path);
                const subdir_name = try self.allocator.dupe(u8, entry.name);
                // Track shared allocations for cleanup in deinit
                try self.shared_subdirs.append(self.allocator, subdir_name);
                try self.shared_states.append(self.allocator, dir_states);
                // Recursively scan — deeper subdirs are organizational only
                try self.scanZigFilesRecursive(subdir_path, subdir_name, dir_states, subdir_name);
            }
        }

        // Sort all entries once at the end
        self.sortEntries();

        // Validate no duplicate sort orders within the same scope
        try self.validateNoDuplicateOrders();
    }

    /// Add an entry manually (for testing without filesystem).
    pub fn addEntry(self: *ScriptScanner, filename: []const u8, subdir: ?[]const u8, states: []const []const u8) !void {
        const name = stripPrefixAndExtension(filename);
        const sort_order = extractSortOrder(filename);

        try self.entries.append(self.allocator, .{
            .name = name,
            .filename = filename,
            .states = states,
            .sort_order = sort_order,
            .subdir = subdir,
            .rel_path = filename,
        });
    }

    /// Add an entry with a full relative path (used by filesystem scanning).
    pub fn addEntryWithPath(self: *ScriptScanner, filename: []const u8, subdir: ?[]const u8, states: []const []const u8, rel_path: []const u8) !void {
        const name = stripPrefixAndExtension(filename);
        const sort_order = extractSortOrder(filename);

        try self.entries.append(self.allocator, .{
            .name = name,
            .filename = filename,
            .states = states,
            .sort_order = sort_order,
            .subdir = subdir,
            .rel_path = rel_path,
        });
    }

    /// Get the sorted script entries.
    pub fn getEntries(self: *const ScriptScanner) []const ScriptEntry {
        return self.entries.items;
    }

    /// Get entries filtered by state (includes global scripts).
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
    fn scanZigFilesRecursive(self: *ScriptScanner, dir_path: []const u8, state_dir_name: ?[]const u8, states: []const []const u8, rel_prefix: []const u8) ScanError!void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch return) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
                const name_copy = try self.allocator.dupe(u8, entry.name);
                const rel_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ rel_prefix, entry.name });
                try self.addEntryWithPath(name_copy, state_dir_name, states, rel_path);
            } else if (entry.kind == .directory) {
                const sub_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name });
                defer self.allocator.free(sub_path);
                const sub_rel = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ rel_prefix, entry.name });
                defer self.allocator.free(sub_rel);
                try self.scanZigFilesRecursive(sub_path, state_dir_name, states, sub_rel);
            }
        }
    }

    fn parseDirStates(self: *ScriptScanner, dir_name: []const u8) ![]const []const u8 {
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

    /// Validate that no two scripts in the same scope share a numeric prefix.
    /// Scope = same subdir (null → global).
    fn validateNoDuplicateOrders(self: *ScriptScanner) ScanError!void {
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

    pub fn sortEntries(self: *ScriptScanner) void {
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

/// Extract numeric prefix from filename: "01_foo.zig" -> 1, "foo.zig" -> null.
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

/// Strip numeric prefix and .zig extension: "01_foo.zig" -> "foo", "bar.zig" -> "bar".
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
