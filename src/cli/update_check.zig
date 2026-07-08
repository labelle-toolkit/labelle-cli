//! Read-only, machine-readable "what's outdated?" reporting shared by
//! `labelle update --check [--json]` and `labelle upgrade --check [--json]`
//! (labelle-cli#276).
//!
//! Unblocks labelle-studio#7: studio wants to surface "CLI x.y.z available"
//! and per-project pin-vs-latest WITHOUT parsing human output and WITHOUT
//! mutating anything. So this module is a pure reporting layer — it computes
//! a status document from versions supplied by the caller and serializes it;
//! the network fetch (CLI latest) and project.labelle read live in the two
//! command wrappers (`update.zig` / `upgrade.zig`).
//!
//! Schema (stable; additive changes only — studio consumes it). Both
//! commands emit the SAME top-level shape; each populates only its half:
//!
//!   { "cli": { "installed": "1.55.1", "latest": "1.56.0"|null,
//!              "update_available": bool, "checked": bool,
//!              "error": "..."|null } | null,
//!     "packages": [ { "name": "core", "pinned": "1.21.0"|null,
//!                     "latest": "1.21.0"|null, "update_available": bool,
//!                     "checked": bool, "error": "..."|null }, ... ] }
//!
//!   - `update --check`  → cli populated (binary vs published), packages [].
//!   - `upgrade --check` → cli null, packages populated (pins vs the bundled
//!                         compatible set).
//!
//! `checked`/`error` distinguish "up to date" from "couldn't determine"
//! (offline for the CLI fetch; no-known-latest / local-path override for a
//! pin). All keys are always present (`null` when unknown) so a typed
//! consumer gets a stable shape — the same convention as the `--progress`
//! NDJSON feed (see progress.zig).

const std = @import("std");
const util = @import("util.zig");

/// A pin the CLI has no bundled "latest" for (an arbitrary plugin): the pin
/// is reported, but `checked` is false and `latest` is null.
pub const err_unknown_latest = "no known latest version for this package";
/// A `local:<path>` (or `@<path>`) override cannot be version-compared.
pub const err_local_override = "local path override — not version-comparable";
/// The CLI-latest fetch failed (curl missing / network / HTTP error).
pub const err_offline = "could not reach the release server";

/// Running CLI binary vs the newest published release. Emitted under "cli".
pub const CliStatus = struct {
    installed: []const u8,
    latest: ?[]const u8 = null,
    update_available: bool = false,
    checked: bool = false,
    @"error": ?[]const u8 = null,
};

/// One project.labelle pin vs the version this CLI targets. Emitted in the
/// "packages" array.
pub const PackageStatus = struct {
    name: []const u8,
    pinned: ?[]const u8 = null,
    latest: ?[]const u8 = null,
    update_available: bool = false,
    checked: bool = false,
    @"error": ?[]const u8 = null,
};

/// The stable top-level document.
pub const Report = struct {
    cli: ?CliStatus = null,
    packages: []const PackageStatus = &.{},
};

/// True for `local:<path>` / `@<path>` version strings — a dev override that
/// points at a sibling checkout rather than a released version.
fn isLocal(v: []const u8) bool {
    return std.mem.startsWith(u8, v, "local:") or std.mem.startsWith(u8, v, "@");
}

/// Build a `CliStatus` from the installed version and an optional fetched
/// latest (`null` = the fetch failed / offline).
pub fn cliStatus(installed: []const u8, latest: ?[]const u8) CliStatus {
    const l = latest orelse return .{
        .installed = installed,
        .checked = false,
        .@"error" = err_offline,
    };
    return .{
        .installed = installed,
        .latest = l,
        .update_available = util.parseVersion(installed) < util.parseVersion(l),
        .checked = true,
    };
}

/// Build a `PackageStatus`. `pinned`/`latest` may be `null`:
///   - a `local:` pin is reported unchecked (can't compare a path to a
///     version),
///   - a `null` latest (no bundled target — e.g. an arbitrary plugin) is
///     reported unchecked,
///   - a `null` pin WITH a latest means "unpinned → uses the CLI default",
///     so it's on the default already: checked, no update.
pub fn packageStatus(name: []const u8, pinned: ?[]const u8, latest: ?[]const u8) PackageStatus {
    if (pinned) |p| {
        if (isLocal(p)) return .{
            .name = name,
            .pinned = p,
            .latest = latest,
            .checked = false,
            .@"error" = err_local_override,
        };
    }
    if (latest == null) return .{
        .name = name,
        .pinned = pinned,
        .checked = false,
        .@"error" = err_unknown_latest,
    };
    const p = pinned orelse return .{
        .name = name,
        .pinned = null,
        .latest = latest,
        .checked = true,
    };
    return .{
        .name = name,
        .pinned = p,
        .latest = latest,
        .update_available = util.parseVersion(p) < util.parseVersion(latest.?),
        .checked = true,
    };
}

/// True when any surface (the CLI or a pin) has a newer version available.
pub fn anyUpdateAvailable(report: Report) bool {
    if (report.cli) |c| {
        if (c.update_available) return true;
    }
    for (report.packages) |p| {
        if (p.update_available) return true;
    }
    return false;
}

/// Process exit code: 0 = nothing known to be outdated (includes offline /
/// unknown — we can't assert an update), 2 = at least one update available.
/// The cheap-scripting contract from issue #276.
pub fn exitCode(report: Report) u8 {
    return if (anyUpdateAvailable(report)) 2 else 0;
}

/// Serialize `report` as a single JSON line (trailing newline) to `w`. All
/// keys always present (`null` when unknown) for a stable typed shape.
pub fn writeJson(w: *std.Io.Writer, report: Report) !void {
    try std.json.Stringify.value(report, .{}, w);
    try w.writeByte('\n');
}

/// Human-readable one/two-line CLI report (`update --check`, no `--json`).
pub fn writeHumanCli(w: *std.Io.Writer, cli: CliStatus) !void {
    if (!cli.checked) {
        try w.print("labelle: could not check for CLI updates (offline?) — current {s}\n", .{cli.installed});
        return;
    }
    if (cli.update_available) {
        try w.print("labelle: CLI update available: {s} -> {s}\n", .{ cli.installed, cli.latest.? });
        try w.writeAll("  run `labelle update` to install it\n");
    } else {
        try w.print("labelle: CLI is up to date ({s})\n", .{cli.installed});
    }
}

/// Human-readable pin report (`upgrade --check`, no `--json`).
pub fn writeHumanPackages(w: *std.Io.Writer, dir: []const u8, packages: []const PackageStatus) !void {
    try w.print("labelle: checking project pins in '{s}'...\n", .{dir});
    var updates: usize = 0;
    for (packages) |p| {
        const pinned = p.pinned orelse "(unset)";
        if (p.update_available) {
            updates += 1;
            try w.print("  {s}: {s} -> {s}  (update available)\n", .{ p.name, pinned, p.latest.? });
        } else if (!p.checked) {
            try w.print("  {s}: {s}  ({s})\n", .{ p.name, pinned, p.@"error" orelse "not checked" });
        } else {
            try w.print("  {s}: {s}  up to date\n", .{ p.name, pinned });
        }
    }
    if (updates == 0) {
        try w.writeAll("all pins up to date\n");
    } else {
        try w.print("{d} update(s) available — run `labelle upgrade all` to apply\n", .{updates});
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test {
    @import("zspec").runAll(@This());
}

const testing = std.testing;

/// Parse `line` as JSON and return the owned Parsed value (caller deinits).
fn parseJson(line: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
}

pub const CliStatusSpec = struct {
    test "up to date: same version, no update, checked, no error" {
        const s = cliStatus("1.55.1", "1.55.1");
        try testing.expect(!s.update_available);
        try testing.expect(s.checked);
        try testing.expect(s.@"error" == null);
        try testing.expectEqualStrings("1.55.1", s.latest.?);
    }

    test "update available: installed older than latest" {
        const s = cliStatus("1.55.1", "1.56.0");
        try testing.expect(s.update_available);
        try testing.expect(s.checked);
    }

    test "installed newer than latest is not an update" {
        const s = cliStatus("2.0.0", "1.56.0");
        try testing.expect(!s.update_available);
        try testing.expect(s.checked);
    }

    test "offline: null latest → unchecked, error set, no update" {
        const s = cliStatus("1.55.1", null);
        try testing.expect(!s.checked);
        try testing.expect(!s.update_available);
        try testing.expect(s.latest == null);
        try testing.expectEqualStrings(err_offline, s.@"error".?);
    }
};

pub const PackageStatusSpec = struct {
    test "up to date pin: checked, no update" {
        const p = packageStatus("core", "1.21.0", "1.21.0");
        try testing.expect(!p.update_available);
        try testing.expect(p.checked);
        try testing.expect(p.@"error" == null);
    }

    test "outdated pin: update available" {
        const p = packageStatus("engine", "1.64.0", "1.65.0");
        try testing.expect(p.update_available);
        try testing.expect(p.checked);
    }

    test "unpinned with a known latest → on default, checked, no update" {
        const p = packageStatus("assembler", null, "0.40.0");
        try testing.expect(p.pinned == null);
        try testing.expect(!p.update_available);
        try testing.expect(p.checked);
    }

    test "no known latest (plugin) → unchecked, error, pin still reported" {
        const p = packageStatus("myplugin", "1.0.0", null);
        try testing.expect(!p.checked);
        try testing.expect(!p.update_available);
        try testing.expectEqualStrings("1.0.0", p.pinned.?);
        try testing.expectEqualStrings(err_unknown_latest, p.@"error".?);
    }

    test "local override pin → unchecked, not comparable" {
        const p = packageStatus("engine", "local:../labelle-engine", "1.65.0");
        try testing.expect(!p.checked);
        try testing.expect(!p.update_available);
        try testing.expectEqualStrings(err_local_override, p.@"error".?);
    }
};

pub const ExitCodeSpec = struct {
    test "all up to date → exit 0" {
        const pkgs = [_]PackageStatus{
            packageStatus("core", "1.21.0", "1.21.0"),
            packageStatus("engine", "1.65.0", "1.65.0"),
        };
        try testing.expectEqual(@as(u8, 0), exitCode(.{ .packages = &pkgs }));
    }

    test "one pin outdated → exit 2" {
        const pkgs = [_]PackageStatus{
            packageStatus("core", "1.21.0", "1.21.0"),
            packageStatus("engine", "1.64.0", "1.65.0"),
        };
        try testing.expectEqual(@as(u8, 2), exitCode(.{ .packages = &pkgs }));
    }

    test "CLI outdated → exit 2" {
        try testing.expectEqual(@as(u8, 2), exitCode(.{ .cli = cliStatus("1.0.0", "1.1.0") }));
    }

    test "offline CLI is not treated as an update → exit 0" {
        try testing.expectEqual(@as(u8, 0), exitCode(.{ .cli = cliStatus("1.0.0", null) }));
    }
};

pub const JsonShapeSpec = struct {
    test "update report: cli populated, packages empty, all keys present" {
        var buf: [1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try writeJson(&w, .{ .cli = cliStatus("1.55.1", "1.56.0") });
        const line = w.buffered();

        // Single JSON line.
        try testing.expect(std.mem.indexOfScalar(u8, line[0 .. line.len - 1], '\n') == null);

        const parsed = try parseJson(line);
        defer parsed.deinit();
        const root = parsed.value.object;
        const cli = root.get("cli").?.object;
        try testing.expectEqualStrings("1.55.1", cli.get("installed").?.string);
        try testing.expectEqualStrings("1.56.0", cli.get("latest").?.string);
        try testing.expect(cli.get("update_available").?.bool);
        try testing.expect(cli.get("checked").?.bool);
        // Stable shape: error key present as explicit null.
        try testing.expect(cli.get("error").? == .null);
        // packages key always present.
        try testing.expectEqual(@as(usize, 0), root.get("packages").?.array.items.len);
    }

    test "offline update report: cli.latest null, error string present" {
        var buf: [1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try writeJson(&w, .{ .cli = cliStatus("1.55.1", null) });
        const parsed = try parseJson(w.buffered());
        defer parsed.deinit();
        const cli = parsed.value.object.get("cli").?.object;
        try testing.expect(cli.get("latest").? == .null);
        try testing.expect(!cli.get("checked").?.bool);
        try testing.expectEqualStrings(err_offline, cli.get("error").?.string);
    }

    test "upgrade report: cli null, packages carry name/pinned/latest/flags" {
        const pkgs = [_]PackageStatus{
            packageStatus("core", "1.21.0", "1.22.0"),
            packageStatus("assembler", null, "0.40.0"),
            packageStatus("myplugin", "1.0.0", null),
        };
        var buf: [2048]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try writeJson(&w, .{ .packages = &pkgs });
        const parsed = try parseJson(w.buffered());
        defer parsed.deinit();
        const root = parsed.value.object;
        try testing.expect(root.get("cli").? == .null);

        const arr = root.get("packages").?.array.items;
        try testing.expectEqual(@as(usize, 3), arr.len);

        const core = arr[0].object;
        try testing.expectEqualStrings("core", core.get("name").?.string);
        try testing.expectEqualStrings("1.21.0", core.get("pinned").?.string);
        try testing.expectEqualStrings("1.22.0", core.get("latest").?.string);
        try testing.expect(core.get("update_available").?.bool);

        // Unpinned pin serializes `pinned` as explicit null.
        const asm_pkg = arr[1].object;
        try testing.expect(asm_pkg.get("pinned").? == .null);
        try testing.expect(asm_pkg.get("checked").?.bool);

        // Unknown-latest plugin: latest null, checked false, error present.
        const plugin = arr[2].object;
        try testing.expect(plugin.get("latest").? == .null);
        try testing.expect(!plugin.get("checked").?.bool);
        try testing.expectEqualStrings(err_unknown_latest, plugin.get("error").?.string);
    }
};
