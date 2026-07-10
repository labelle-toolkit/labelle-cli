//! `labelle plugins` — list the plugins attached to a project along with
//! their declared version and the provenance metadata (`license` /
//! `author`) each plugin ships in its `plugin.labelle` manifest.
//!
//! Part of the asset-plugins epic Phase 2 (labelle-cli#300). The
//! *generate-time* validation of `depends_on_resources` against the merged
//! resource list lives assembler-side (labelle-assembler#576) because the
//! CLI shells out to the assembler binary for `generate` and never parses
//! the merged resource set. The CLI's Phase-2 deliverable is this
//! provenance-surfacing listing plus the `license`/`author` reader.
//!
//! For each entry in `project.labelle`'s `.plugins` list the command:
//!   1. resolves the plugin's directory (local `local:`/`@` path, or the
//!      `~/.labelle/packages/plugins/<repo>/<version>` cache for a remote),
//!   2. reads `plugin.labelle` if present (missing is legal — many plugins
//!      have no manifest), and
//!   3. prints an aligned table of name, version, license, and author.
//!
//! A plugin with no manifest — or a manifest that omits `license`/`author`
//! — lists gracefully with a `-` placeholder rather than failing.

const std = @import("std");
const project_config = @import("project_config.zig");
const config = @import("config.zig");
const asm_cache = @import("asm_cache.zig");

/// Placeholder printed for an absent version / license / author cell.
const NONE = "-";

/// ZON shape of `plugin.labelle` — the subset the listing reads. The real
/// manifest carries `convention_dirs`, `resources`, `packs`,
/// `depends_on_resources`, etc.; `ignore_unknown_fields = true` lets us
/// read only what we need and stay forward-compatible.
const ZonPluginMeta = struct {
    name: []const u8,
    manifest_version: u8 = 1,
    license: ?[]const u8 = null,
    author: ?[]const u8 = null,
};

/// Provenance metadata read from a plugin's `plugin.labelle`.
///
/// Every slice field is a heap allocation owned by `allocator`; call
/// `deinit` to release them.
pub const PluginMeta = struct {
    name: []const u8,
    manifest_version: u8,
    /// SPDX-ish license string, or null when the manifest omits it.
    license: ?[]const u8 = null,
    /// Author / vendor string, or null when the manifest omits it.
    author: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PluginMeta) void {
        self.allocator.free(self.name);
        if (self.license) |l| self.allocator.free(l);
        if (self.author) |a| self.allocator.free(a);
    }
};

/// Read and parse `<plugin_dir>/plugin.labelle`, returning the metadata the
/// listing surfaces.
///
/// Returns `null` when the plugin has no `plugin.labelle` (legal — plugins
/// like labelle-pathfinder ship without one) or when the manifest cannot be
/// read/parsed. A parse failure is surfaced as a one-line warning rather
/// than an error so a single malformed manifest never aborts the whole
/// listing — the row simply falls back to `-` placeholders.
///
/// The returned `PluginMeta` owns its strings as independent heap copies;
/// call `deinit` to release them.
pub fn readPluginMeta(allocator: std.mem.Allocator, plugin_dir: []const u8) ?PluginMeta {
    const manifest_path = std.fs.path.join(allocator, &.{ plugin_dir, "plugin.labelle" }) catch return null;
    defer allocator.free(manifest_path);

    const raw = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), manifest_path, allocator, .limited(64 * 1024)) catch |err| {
        // FileNotFound is the common, legal "no manifest" case — stay
        // silent. Anything else is worth a diagnostic breadcrumb.
        if (err != error.FileNotFound) {
            std.debug.print("labelle: warning: could not read '{s}': {s}\n", .{ manifest_path, @errorName(err) });
        }
        return null;
    };
    defer allocator.free(raw);

    const raw_z = allocator.dupeZ(u8, raw) catch return null;
    defer allocator.free(raw_z);

    const parsed = std.zon.parse.fromSliceAlloc(ZonPluginMeta, allocator, raw_z, null, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("labelle: warning: could not parse '{s}': {s} — listing it without license/author\n", .{ manifest_path, @errorName(err) });
        return null;
    };
    // The parser deep-copies strings; free the whole parsed value after
    // re-duping the fields we keep so ownership is a single, simple
    // `PluginMeta.deinit`.
    defer std.zon.parse.free(allocator, parsed);

    const name = allocator.dupe(u8, parsed.name) catch return null;
    const license = if (parsed.license) |l| (allocator.dupe(u8, l) catch null) else null;
    const author = if (parsed.author) |a| (allocator.dupe(u8, a) catch null) else null;

    return PluginMeta{
        .name = name,
        .manifest_version = parsed.manifest_version,
        .license = license,
        .author = author,
        .allocator = allocator,
    };
}

/// Resolve a declared plugin to the directory its `plugin.labelle` (if any)
/// lives in. Local plugins (`local:` / `@`) resolve against `project_dir`;
/// remote plugins resolve to the shared package cache the same way the
/// assembler / lockfile writer does. Caller owns the returned slice.
fn resolvePluginDir(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    dep: project_config.PluginDep,
) ?[]const u8 {
    if (dep.isLocal())
        return std.fs.path.resolve(allocator, &.{ project_dir, dep.localPath() }) catch null;
    return asm_cache.resolveRemotePluginDir(allocator, dep.repo, dep.version) catch null;
}

/// A single row of the `labelle plugins` table. Pure data so the renderer
/// is unit-testable without a filesystem fixture.
pub const Row = struct {
    name: []const u8,
    version: []const u8,
    license: []const u8,
    author: []const u8,
};

const HEADER = Row{ .name = "PLUGIN", .version = "VERSION", .license = "LICENSE", .author = "AUTHOR" };

fn appendPadded(buf: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8, width: usize) !void {
    try buf.appendSlice(a, text);
    var i = text.len;
    while (i < width) : (i += 1) try buf.append(a, ' ');
}

/// Render an aligned table for `rows` (header + one line per row). Columns
/// are separated by a two-space gutter; the trailing column is not padded.
/// Caller owns the returned slice. A row's cells are printed verbatim, so
/// pass `"-"` for an absent version/license/author.
pub fn renderTable(allocator: std.mem.Allocator, rows: []const Row) ![]u8 {
    var name_w: usize = HEADER.name.len;
    var ver_w: usize = HEADER.version.len;
    var lic_w: usize = HEADER.license.len;
    for (rows) |r| {
        name_w = @max(name_w, r.name.len);
        ver_w = @max(ver_w, r.version.len);
        lic_w = @max(lic_w, r.license.len);
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Header first, then rows.
    try appendRow(&buf, allocator, HEADER, name_w, ver_w, lic_w);
    for (rows) |r| try appendRow(&buf, allocator, r, name_w, ver_w, lic_w);

    return buf.toOwnedSlice(allocator);
}

fn appendRow(buf: *std.ArrayList(u8), a: std.mem.Allocator, r: Row, name_w: usize, ver_w: usize, lic_w: usize) !void {
    try appendPadded(buf, a, r.name, name_w);
    try buf.appendSlice(a, "  ");
    try appendPadded(buf, a, r.version, ver_w);
    try buf.appendSlice(a, "  ");
    try appendPadded(buf, a, r.license, lic_w);
    try buf.appendSlice(a, "  ");
    try buf.appendSlice(a, r.author); // trailing column: no padding
    try buf.append(a, '\n');
}

/// `labelle plugins [dir]` — list attached plugins with version + license/author.
pub fn cmdPlugins(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Single arena for the whole command — every string (config, resolved
    // dirs, manifest metadata, rendered table) lives and dies with it.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // First non-flag positional is the project dir (default ".").
    var project_dir: []const u8 = ".";
    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            project_dir = arg;
            break;
        }
    }

    if (!config.projectExists(project_dir)) {
        config.printNoProjectError(project_dir);
        // Non-zero outcome without a Zig error-return trace (same pattern
        // as `add` / `android doctor`).
        std.process.exit(1);
    }

    const cfg = config.readProjectConfig(a, project_dir) catch |err| {
        std.debug.print("labelle plugins: could not read project config: {s}\n", .{@errorName(err)});
        return err;
    };

    if (cfg.plugins.len == 0) {
        std.debug.print("No plugins declared in project.labelle.\n", .{});
        return;
    }

    var rows: std.ArrayList(Row) = .empty;
    for (cfg.plugins) |dep| {
        var license: []const u8 = NONE;
        var author: []const u8 = NONE;

        if (resolvePluginDir(a, project_dir, dep)) |plugin_dir| {
            if (readPluginMeta(a, plugin_dir)) |meta| {
                if (meta.license) |l| license = l;
                if (meta.author) |au| author = au;
            }
        }

        try rows.append(a, .{
            .name = dep.name,
            .version = if (dep.version.len > 0) dep.version else NONE,
            .license = license,
            .author = author,
        });
    }

    const table = try renderTable(a, rows.items);
    std.debug.print("{s}", .{table});
}

// ============================================================================
// Tests
// ============================================================================

const expect = @import("zspec").expect;

test {
    @import("zspec").runAll(@This());
}

fn writeManifest(dir: std.Io.Dir, body: []const u8) !void {
    try dir.writeFile(config.globalIo(), .{ .sub_path = "plugin.labelle", .data = body });
}

fn tmpRealPath(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPath(config.globalIo(), buf);
    return buf[0..n];
}

/// Reader behaviour: full metadata, missing license/author, missing file.
pub const ReadPluginMetaSpec = struct {
    pub const full_manifest = struct {
        test "parses name, version, license, and author" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try writeManifest(tmp.dir,
                \\.{
                \\    .name = "atlas-overlay",
                \\    .manifest_version = 1,
                \\    .license = "MIT",
                \\    .author = "Acme Games",
                \\}
            );

            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const dir = try tmpRealPath(&tmp, &buf);

            var meta = readPluginMeta(std.testing.allocator, dir).?;
            defer meta.deinit();

            try std.testing.expectEqualStrings("atlas-overlay", meta.name);
            try expect.equal(meta.manifest_version, @as(u8, 1));
            try std.testing.expectEqualStrings("MIT", meta.license.?);
            try std.testing.expectEqualStrings("Acme Games", meta.author.?);
        }
    };

    pub const missing_metadata = struct {
        test "tolerates a manifest without license/author" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try writeManifest(tmp.dir,
                \\.{
                \\    .name = "bare",
                \\    .manifest_version = 1,
                \\}
            );

            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const dir = try tmpRealPath(&tmp, &buf);

            var meta = readPluginMeta(std.testing.allocator, dir).?;
            defer meta.deinit();

            try std.testing.expectEqualStrings("bare", meta.name);
            try expect.toBeNull(meta.license);
            try expect.toBeNull(meta.author);
        }
    };

    pub const missing_file = struct {
        test "returns null when plugin.labelle is absent" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const dir = try tmpRealPath(&tmp, &buf);

            try expect.toBeNull(readPluginMeta(std.testing.allocator, dir));
        }
    };
};

/// Renderer behaviour against hand-built rows (no filesystem fixture).
pub const RenderTableSpec = struct {
    pub const with_license_and_author = struct {
        test "renders a header and a plugin row carrying license + author" {
            const rows = [_]Row{
                .{ .name = "labelle-pathfinding", .version = "4.0.1", .license = "MIT", .author = "labelle" },
            };
            const table = try renderTable(std.testing.allocator, &rows);
            defer std.testing.allocator.free(table);

            // Header columns present.
            try expect.toBeTrue(std.mem.indexOf(u8, table, "PLUGIN") != null);
            try expect.toBeTrue(std.mem.indexOf(u8, table, "VERSION") != null);
            try expect.toBeTrue(std.mem.indexOf(u8, table, "LICENSE") != null);
            try expect.toBeTrue(std.mem.indexOf(u8, table, "AUTHOR") != null);
            // Row data present.
            try expect.toBeTrue(std.mem.indexOf(u8, table, "labelle-pathfinding") != null);
            try expect.toBeTrue(std.mem.indexOf(u8, table, "4.0.1") != null);
            try expect.toBeTrue(std.mem.indexOf(u8, table, "MIT") != null);
            try expect.toBeTrue(std.mem.indexOf(u8, table, "labelle") != null);
        }
    };

    pub const placeholder_cells = struct {
        test "renders '-' placeholders for absent metadata" {
            const rows = [_]Row{
                .{ .name = "p", .version = "-", .license = "-", .author = "-" },
            };
            const table = try renderTable(std.testing.allocator, &rows);
            defer std.testing.allocator.free(table);

            // Two header lines + one data line, each newline-terminated.
            var lines: usize = 0;
            for (table) |c| {
                if (c == '\n') lines += 1;
            }
            try expect.equal(lines, @as(usize, 2)); // header + one row
        }
    };
};
