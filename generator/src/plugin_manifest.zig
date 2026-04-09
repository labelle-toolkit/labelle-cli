/// Plugin manifest support — reads `plugin.labelle` from a plugin
/// directory, validates it against the project's plugin declaration,
/// and exposes the convention directories the generator should
/// copy/scan in addition to the hardcoded ones.
///
/// See `docs/RFC-plugin-manifest.md` for the design and rationale.
const std = @import("std");
const config = @import("config.zig");
const cache = @import("cache.zig");

/// Highest manifest_version this CLI release understands. Bump when
/// adding a new field that older CLIs cannot safely ignore.
pub const SUPPORTED_MANIFEST_VERSION: u8 = 1;

/// Reserved convention directory names. A plugin manifest may not
/// declare any of these — they are owned by the hardcoded copy/scan
/// pass in `generator/src/root.zig` and represent first-class engine
/// concepts. Kept in sync with the names used in `root.zig`.
pub const RESERVED_DIR_NAMES = [_][]const u8{
    "assets",
    "components",
    "enums",
    "events",
    "gizmos",
    "hooks",
    "prefabs",
    "scenes",
    "scripts",
    "views",
};

pub const ConventionDirMode = enum {
    /// Copy every file matching `extension` from <game>/<name>/ to
    /// <target>/<name>/, then scan the file stems. Mirrors the
    /// existing `scanner.copyAndScan` path used for components,
    /// hooks, events, enums, prefabs, scenes, scripts, views, gizmos.
    copy_and_scan,
    /// Copy every file from <game>/<name>/ to <target>/<name>/
    /// recursively, no scanning. Mirrors `scanner.copyDirRecursive`
    /// used for assets/.
    copy_only,
};

pub const ConventionDir = struct {
    name: []const u8,
    /// File extension to scan (e.g. ".zig"). Required when
    /// `mode == .copy_and_scan`. Ignored / left null when
    /// `mode == .copy_only`.
    extension: ?[]const u8 = null,
    mode: ConventionDirMode,
};

/// Parsed and validated `plugin.labelle` manifest.
///
/// Ownership: every string field (`name`, each `ConventionDir.name`
/// and `ConventionDir.extension`) is a heap allocation made by the
/// ZON parser via `parseString → toOwnedSlice`. Strings are deep
/// copies, *not* references into the source buffer — the source
/// buffer is freed immediately after parsing in `loadFromDir`.
/// Call `deinit` to release all heap allocations owned by the
/// manifest.
pub const PluginManifest = struct {
    name: []const u8,
    manifest_version: u8,
    convention_dirs: []const ConventionDir = &.{},

    /// Allocator that owns the parsed strings and slice. Stored on
    /// the manifest so the caller doesn't have to remember to pass
    /// the right allocator to deinit.
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PluginManifest) void {
        // Free every heap-allocated field individually.
        // std.zon.parse.free walks slices and structs recursively,
        // so passing `self.convention_dirs` frees each element's
        // nested `name` and `extension` strings in addition to the
        // outer slice.
        std.zon.parse.free(self.allocator, self.name);
        std.zon.parse.free(self.allocator, self.convention_dirs);
    }
};

// ── Errors ─────────────────────────────────────────────────────────
//
// loadOptional uses an inferred error set so it composes cleanly with
// std.fs and std.zon error unions across Zig versions. The manifest-
// specific validation errors the caller might want to match on are:
//
//   error.PluginManifestParseError         — ZON parser rejected the file
//   error.PluginManifestNameMismatch       — plugin.labelle name != .plugins entry name
//   error.PluginManifestReservedDirName    — plugin tried to claim a reserved name
//   error.PluginManifestUnsafeDirName      — convention_dir name is not a safe relative segment
//   error.PluginManifestMissingExtension   — copy_and_scan entry omitted its required extension
//   error.PluginManifestUnknownVersion     — manifest_version is < 1 or > what we support

/// Read and parse `plugin.labelle` for the given plugin if it exists.
///
/// Returns `null` when the plugin has no manifest file (legal — many
/// plugins like labelle-pathfinder don't need one). Returns a parsed
/// `PluginManifest` on success. Errors on parse failure, name
/// mismatch, reserved-name collision, or an unsupported manifest_version.
///
/// The returned manifest's strings are backed by `raw` inside the
/// struct — call `deinit` to release them.
pub fn loadOptional(
    allocator: std.mem.Allocator,
    plugin: config.PluginDep,
    project_dir: []const u8,
) !?PluginManifest {
    const plugin_dir = try cache.resolvePlugin(allocator, plugin, project_dir);
    defer allocator.free(plugin_dir);
    return loadFromDir(allocator, plugin_dir, plugin.name);
}

/// Lower-level entry point: read and parse `plugin.labelle` from a
/// known plugin directory. The caller already resolved the plugin
/// name to a path (for example via `cache.resolvePlugin`).
///
/// `expected_name` is what `project.labelle`'s `.plugins` entry calls
/// the plugin — the manifest's `name` field must match.
///
/// Returns `null` if the plugin has no `plugin.labelle` (legal — many
/// plugins like labelle-pathfinder don't need one). Errors on:
///   - ZON parse failure                  → PluginManifestParseError
///   - name mismatch                      → PluginManifestNameMismatch
///   - unsupported manifest_version       → PluginManifestUnknownVersion
///   - reserved convention_dir name       → PluginManifestReservedDirName
///   - unsafe convention_dir name         → PluginManifestUnsafeDirName
///   - missing extension on copy_and_scan → PluginManifestMissingExtension
///
/// The returned manifest owns its strings as deep heap copies made by
/// the ZON parser; the source buffer is freed before returning. Call
/// `PluginManifest.deinit` to release them.
///
/// Exposed publicly so tests and tooling can exercise the manifest
/// machinery without needing the full plugin-cache resolution path.
pub fn loadFromDir(
    allocator: std.mem.Allocator,
    plugin_dir: []const u8,
    expected_name: []const u8,
) !?PluginManifest {
    const manifest_path = try std.fs.path.join(allocator, &.{ plugin_dir, "plugin.labelle" });
    defer allocator.free(manifest_path);

    // Read the file. If the file does not exist, return null — this is
    // a legal "no manifest" plugin (e.g. labelle-pathfinder).
    const cwd = std.fs.cwd();
    const raw_bytes = cwd.readFileAlloc(allocator, manifest_path, 64 * 1024) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(raw_bytes);

    // ZON parser needs a sentinel-terminated buffer.
    const raw_z = try allocator.dupeZ(u8, raw_bytes);
    defer allocator.free(raw_z);

    // Parse with the typed ZON struct (matches gui_resolve.zig pattern).
    // The parser allocates fresh string copies via parseString →
    // toOwnedSlice, so raw_z can be freed immediately after parsing
    // succeeds — the returned slices are independent heap allocations.
    //
    // ignore_unknown_fields = true is intentional forward-compat: a
    // manifest from a future plugin that adds a new optional field
    // should still load in an older CLI. Hard-incompat changes bump
    // manifest_version (checked below) rather than adding fields.
    const parsed = std.zon.parse.fromSlice(ZonManifest, allocator, raw_z, null, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print(
            "labelle: failed to parse plugin.labelle for plugin '{s}' at {s}\n  parser error: {any}\n  see docs/RFC-plugin-manifest.md for the manifest schema\n",
            .{ expected_name, manifest_path, err },
        );
        return error.PluginManifestParseError;
    };
    // From here on, validation may reject the manifest and we have to
    // free everything the parser allocated. zon.parse.free walks
    // structs recursively, so passing the whole `parsed` value frees
    // every nested string and slice.
    errdefer std.zon.parse.free(allocator, parsed);

    // ── Validate name matches the project's plugin declaration ──
    if (!std.mem.eql(u8, parsed.name, expected_name)) {
        std.debug.print(
            "labelle: plugin.labelle name mismatch\n  project.labelle declares plugin '{s}'\n  but its plugin.labelle has name = '{s}'\n  at {s}\n",
            .{ expected_name, parsed.name, manifest_path },
        );
        return error.PluginManifestNameMismatch;
    }

    // ── Validate manifest_version ──
    // Valid versions: 1 <= v <= SUPPORTED_MANIFEST_VERSION. Version 0 is
    // not a real schema version — probably a plugin author who forgot to
    // set the field or typed 0 by accident — and should be flagged the
    // same way as an unknown future version.
    if (parsed.manifest_version < 1 or parsed.manifest_version > SUPPORTED_MANIFEST_VERSION) {
        std.debug.print(
            "labelle: plugin '{s}' has manifest_version {d}\n  but this labelle-cli release supports manifest_version 1..{d}\n  fix the plugin.labelle manifest or upgrade/downgrade labelle-cli\n",
            .{ expected_name, parsed.manifest_version, SUPPORTED_MANIFEST_VERSION },
        );
        return error.PluginManifestUnknownVersion;
    }

    // ── Validate every convention_dir entry ──
    for (parsed.convention_dirs) |dir| {
        // Reserved names — mustn't shadow a hardcoded convention dir.
        if (isReservedDirName(dir.name)) {
            std.debug.print(
                "labelle: plugin '{s}' tried to declare convention_dir '{s}'\n  but '{s}' is reserved for first-class engine concepts.\n  reserved names: ",
                .{ expected_name, dir.name, dir.name },
            );
            for (RESERVED_DIR_NAMES, 0..) |name, i| {
                if (i > 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{name});
            }
            std.debug.print("\n  pick a different directory name for this plugin.\n", .{});
            return error.PluginManifestReservedDirName;
        }

        // Path-traversal guard. `dir.name` is concatenated into a path
        // passed to copyAndScan / copyDirRecursive, so a malicious or
        // buggy plugin declaring "../../etc" or "/abs/path" could
        // read/write outside the game root. Require a plain relative
        // segment: non-empty, no path separators, no `..` or `.`,
        // no leading `/` or `\`, no null bytes.
        if (!isSafeDirName(dir.name)) {
            std.debug.print(
                "labelle: plugin '{s}' declared convention_dir name '{s}' that is not a safe relative directory name\n  directory names must be plain single segments (no '/', '\\', '..', '.', absolute paths, or NUL)\n",
                .{ expected_name, dir.name },
            );
            return error.PluginManifestUnsafeDirName;
        }

        // copy_and_scan mode requires an explicit extension. root.zig
        // used to silently default to ".zig", which hid typos and
        // surprised plugin authors scanning .jsonc or .zon files. The
        // RFC marks extension as required for this mode — enforce it
        // here at load time with a clear diagnostic.
        if (dir.mode == .copy_and_scan and dir.extension == null) {
            std.debug.print(
                "labelle: plugin '{s}' declared convention_dir '{s}' with mode .copy_and_scan\n  but 'extension' is missing. copy_and_scan mode requires a file extension to scan (e.g. \".zig\").\n  use mode .copy_only if you want to copy every file regardless of extension.\n",
                .{ expected_name, dir.name },
            );
            return error.PluginManifestMissingExtension;
        }
    }

    return PluginManifest{
        .name = parsed.name,
        .manifest_version = parsed.manifest_version,
        .convention_dirs = parsed.convention_dirs,
        .allocator = allocator,
    };
}

pub fn isReservedDirName(name: []const u8) bool {
    for (RESERVED_DIR_NAMES) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return true;
    }
    return false;
}

/// Returns true iff `name` is a plain, safe relative directory segment
/// suitable for concatenating into a path under the game root.
///
/// Rejects anything that could escape the game directory or otherwise
/// surprise the copy/scan routines:
///   - empty string
///   - contains a path separator (`/` or `\`)
///   - `.` or `..` exactly
///   - contains a NUL byte
///
/// Subdirectory paths (e.g. `"nested/dir"`) are intentionally rejected
/// too — plugins should declare one `convention_dirs` entry per
/// top-level directory, not walk into subfolders at declaration time.
pub fn isSafeDirName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".")) return false;
    if (std.mem.eql(u8, name, "..")) return false;
    for (name) |c| {
        if (c == '/' or c == '\\' or c == 0) return false;
    }
    return true;
}

// ── ZON-parseable manifest type ───────────────────────────────────
//
// Mirrors the public-facing PluginManifest but without the lifetime
// fields, since the parser only knows about ZON-shaped data.
const ZonManifest = struct {
    name: []const u8,
    manifest_version: u8,
    convention_dirs: []const ConventionDir = &.{},
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "isReservedDirName: matches every hardcoded name" {
    inline for (.{
        "assets", "components", "enums", "events", "gizmos",
        "hooks",  "prefabs",    "scenes", "scripts", "views",
    }) |name| {
        try testing.expect(isReservedDirName(name));
    }
    try testing.expect(!isReservedDirName("state_machines"));
    try testing.expect(!isReservedDirName("dialogue_trees"));
    try testing.expect(!isReservedDirName(""));
}

test "ZonManifest: parses minimal manifest with one convention dir" {
    const src =
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "state_machines",
        \\            .extension = ".zig",
        \\            .mode = .copy_and_scan,
        \\        },
        \\    },
        \\}
    ;
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    const parsed = try std.zon.parse.fromSlice(ZonManifest, testing.allocator, src_z, null, .{});
    defer std.zon.parse.free(testing.allocator, parsed);

    try testing.expectEqualStrings("fsm", parsed.name);
    try testing.expectEqual(@as(u8, 1), parsed.manifest_version);
    try testing.expectEqual(@as(usize, 1), parsed.convention_dirs.len);
    try testing.expectEqualStrings("state_machines", parsed.convention_dirs[0].name);
    try testing.expectEqualStrings(".zig", parsed.convention_dirs[0].extension.?);
    try testing.expectEqual(ConventionDirMode.copy_and_scan, parsed.convention_dirs[0].mode);
}

test "ZonManifest: parses copy_only mode without extension" {
    const src =
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "fsm_assets",
        \\            .mode = .copy_only,
        \\        },
        \\    },
        \\}
    ;
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    const parsed = try std.zon.parse.fromSlice(ZonManifest, testing.allocator, src_z, null, .{});
    defer std.zon.parse.free(testing.allocator, parsed);

    try testing.expectEqual(ConventionDirMode.copy_only, parsed.convention_dirs[0].mode);
    try testing.expect(parsed.convention_dirs[0].extension == null);
}

test "ZonManifest: parses manifest with no convention_dirs" {
    const src =
        \\.{
        \\    .name = "marker_only",
        \\    .manifest_version = 1,
        \\}
    ;
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    const parsed = try std.zon.parse.fromSlice(ZonManifest, testing.allocator, src_z, null, .{});
    defer std.zon.parse.free(testing.allocator, parsed);

    try testing.expectEqualStrings("marker_only", parsed.name);
    try testing.expectEqual(@as(usize, 0), parsed.convention_dirs.len);
}

test "ZonManifest: parses manifest with multiple convention dirs (different extensions on same name)" {
    const src =
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{ .name = "state_machines", .extension = ".zig",  .mode = .copy_and_scan },
        \\        .{ .name = "state_machines", .extension = ".zon",  .mode = .copy_and_scan },
        \\    },
        \\}
    ;
    const src_z = try testing.allocator.dupeZ(u8, src);
    defer testing.allocator.free(src_z);

    const parsed = try std.zon.parse.fromSlice(ZonManifest, testing.allocator, src_z, null, .{});
    defer std.zon.parse.free(testing.allocator, parsed);

    try testing.expectEqual(@as(usize, 2), parsed.convention_dirs.len);
    try testing.expectEqualStrings(".zig", parsed.convention_dirs[0].extension.?);
    try testing.expectEqualStrings(".zon", parsed.convention_dirs[1].extension.?);
}

// ── loadFromDir integration tests against a real (tmp) plugin dir ──

fn writeManifestFile(tmp_dir: std.fs.Dir, body: []const u8) !void {
    var f = try tmp_dir.createFile("plugin.labelle", .{});
    defer f.close();
    try f.writeAll(body);
}

test "loadFromDir: returns null when plugin.labelle is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const result = try loadFromDir(testing.allocator, tmp_path, "fsm");
    try testing.expect(result == null);
}

test "loadFromDir: parses a valid manifest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "state_machines",
        \\            .extension = ".zig",
        \\            .mode = .copy_and_scan,
        \\        },
        \\    },
        \\}
    );

    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    var manifest = (try loadFromDir(testing.allocator, tmp_path, "fsm")).?;
    defer manifest.deinit();

    try testing.expectEqualStrings("fsm", manifest.name);
    try testing.expectEqual(@as(u8, 1), manifest.manifest_version);
    try testing.expectEqual(@as(usize, 1), manifest.convention_dirs.len);
    try testing.expectEqualStrings("state_machines", manifest.convention_dirs[0].name);
    try testing.expectEqualStrings(".zig", manifest.convention_dirs[0].extension.?);
    try testing.expectEqual(ConventionDirMode.copy_and_scan, manifest.convention_dirs[0].mode);
}

test "loadFromDir: errors on name mismatch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 1,
        \\}
    );

    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "different_name");
    try testing.expectError(error.PluginManifestNameMismatch, result);
}

test "loadFromDir: errors on manifest_version higher than supported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 99,
        \\}
    );

    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "fsm");
    try testing.expectError(error.PluginManifestUnknownVersion, result);
}

test "loadFromDir: errors on manifest_version zero" {
    // manifest_version = 0 is not a real schema version — catch the
    // "plugin author forgot to set it / typed 0 by accident" case with
    // the same error as an unknown future version.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 0,
        \\}
    );

    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "fsm");
    try testing.expectError(error.PluginManifestUnknownVersion, result);
}

test "loadFromDir: errors when plugin tries to declare a reserved name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "components",
        \\            .extension = ".zig",
        \\            .mode = .copy_and_scan,
        \\        },
        \\    },
        \\}
    );

    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "fsm");
    try testing.expectError(error.PluginManifestReservedDirName, result);
}

test "loadFromDir: errors on malformed ZON" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "fsm"
        \\    .manifest_version = 1   // missing comma above
        \\}
    );

    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "fsm");
    try testing.expectError(error.PluginManifestParseError, result);
}

test "loadFromDir: parses copy_only mode end-to-end" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "fsm_extras",
        \\            .mode = .copy_only,
        \\        },
        \\    },
        \\}
    );

    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    var manifest = (try loadFromDir(testing.allocator, tmp_path, "fsm")).?;
    defer manifest.deinit();

    try testing.expectEqual(ConventionDirMode.copy_only, manifest.convention_dirs[0].mode);
    try testing.expectEqualStrings("fsm_extras", manifest.convention_dirs[0].name);
}

test "isSafeDirName: accepts plain segments, rejects escape attempts" {
    try testing.expect(isSafeDirName("state_machines"));
    try testing.expect(isSafeDirName("fsm_extras"));
    try testing.expect(isSafeDirName("a"));
    try testing.expect(isSafeDirName("with.dots.ok"));

    try testing.expect(!isSafeDirName(""));
    try testing.expect(!isSafeDirName("."));
    try testing.expect(!isSafeDirName(".."));
    try testing.expect(!isSafeDirName("../escape"));
    try testing.expect(!isSafeDirName("foo/bar"));
    try testing.expect(!isSafeDirName("foo\\bar"));
    try testing.expect(!isSafeDirName("/absolute"));
    try testing.expect(!isSafeDirName("has\x00null"));
}

test "loadFromDir: rejects path traversal in convention_dir name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "evil",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "../../etc",
        \\            .extension = ".zig",
        \\            .mode = .copy_and_scan,
        \\        },
        \\    },
        \\}
    );

    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "evil");
    try testing.expectError(error.PluginManifestUnsafeDirName, result);
}

test "loadFromDir: rejects absolute path in convention_dir name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "evil",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "/tmp/absolute",
        \\            .extension = ".zig",
        \\            .mode = .copy_and_scan,
        \\        },
        \\    },
        \\}
    );

    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "evil");
    try testing.expectError(error.PluginManifestUnsafeDirName, result);
}

test "loadFromDir: rejects copy_and_scan without extension" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 1,
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "state_machines",
        \\            .mode = .copy_and_scan,
        \\        },
        \\    },
        \\}
    );

    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    const result = loadFromDir(testing.allocator, tmp_path, "fsm");
    try testing.expectError(error.PluginManifestMissingExtension, result);
}

test "loadFromDir: ignore_unknown_fields allows forward-compat manifests" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A future v1-compatible manifest that adds a hypothetical `author`
    // field. An older CLI should silently ignore the unknown field and
    // still load the rest of the manifest.
    try writeManifestFile(tmp.dir,
        \\.{
        \\    .name = "fsm",
        \\    .manifest_version = 1,
        \\    .author = "future-you",
        \\    .convention_dirs = .{
        \\        .{
        \\            .name = "state_machines",
        \\            .extension = ".zig",
        \\            .mode = .copy_and_scan,
        \\        },
        \\    },
        \\}
    );

    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    var manifest = (try loadFromDir(testing.allocator, tmp_path, "fsm")).?;
    defer manifest.deinit();

    try testing.expectEqualStrings("fsm", manifest.name);
    try testing.expectEqual(@as(usize, 1), manifest.convention_dirs.len);
}
