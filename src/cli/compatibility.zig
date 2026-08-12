const std = @import("std");
const project_config = @import("project_config.zig");
const progress = @import("progress.zig");

/// Validate that declared dependency versions are compatible with each other.
pub fn validateCompatibility(cfg: project_config.ProjectConfig) void {
    validateStates(cfg.states);

    // Validate backend+platform combination
    if (cfg.platform == .wasm and cfg.backend != .raylib and cfg.backend != .sokol and cfg.backend != .bgfx) {
        std.debug.print("labelle: error: WASM builds are only supported with raylib, sokol, or bgfx backends (got {s})\n", .{@tagName(cfg.backend)});
        std.debug.print("  hint: set backend = \"raylib\", \"sokol\", or \"bgfx\" in project.labelle\n\n", .{});
        progress.fatalExit(1, "compatibility check failed: wasm requires a raylib, sokol, or bgfx backend");
    }

    const is_local = project_config.isLocalVersion;
    var warnings: u8 = 0;

    // core / engine / gfx / cli version on INDEPENDENT minor trains (e.g. core
    // 1.21, engine 1.65, gfx 1.19 are all current + mutually compatible). The
    // assembler unifies every package onto the project's core at build time (the
    // "core diamond"), so source-compatibility — not matching minors — is what
    // matters. Only a MAJOR-version divergence is a real break (a 2.x package
    // against a 1.x core), so that's all we warn on. The curated tested set lives
    // in `versions.zon` (what `labelle upgrade all` targets); a per-package
    // declared-core check (read each package's own core pin) is the planned
    // stronger follow-up.
    const core_major = if (!is_local(cfg.core_version)) parseVersion(cfg.core_version).major else null;

    const Dep = struct { name: []const u8, version: []const u8 };
    const deps = [_]Dep{
        .{ .name = "engine", .version = cfg.engine_version },
        .{ .name = "gfx", .version = cfg.gfx_version },
        .{ .name = "cli", .version = cfg.labelle_version },
    };
    if (core_major) |cmaj| {
        for (deps) |d| {
            if (is_local(d.version)) continue;
            if (depCompatWarn(d.version, cmaj)) {
                std.debug.print("labelle: warning: {s} {s} may be incompatible with core {s}\n", .{ d.name, d.version, cfg.core_version });
                std.debug.print("  major versions should match (minor versions are independent across packages)\n", .{});
                std.debug.print("  hint: run `labelle upgrade all`\n\n", .{});
                warnings += 1;
            }
        }
    }

    // Plugins are deliberately NOT checked against core here. Unlike the
    // core-diamond packages above — which share core's major by construction —
    // a plugin versions on its own train, so its major encodes nothing about
    // which core it targets: `pathfinder` 4.0.2 supports core 1.24.1 exactly as
    // `fsm` 0.5.0 does. Comparing the two majors produced only false positives
    // (#230 carved out 0.x plugins; 4.x plugins were the same bug from the
    // other side), so the heuristic is gone rather than special-cased again.
    //
    // The real signal is a core range declared by the plugin itself in
    // `plugin.labelle`; wiring that up needs this check to run after dependency
    // resolution, when the manifest is on disk. Tracked in #332.

    if (warnings > 0) {
        std.debug.print("labelle: {d} compatibility warning(s) — proceeding anyway\n\n", .{warnings});
    }
}

/// Validate game state names declared in project.labelle. Each fatalExit
/// detail carries the specific rule that failed (cli#318) so the progress
/// feed's terminal record is renderable on its own.
fn validateStates(states: []const []const u8) void {
    if (states.len == 0) {
        std.debug.print("labelle: error: .states must contain at least one state\n", .{});
        std.debug.print("  hint: remove .states to use the default (\"running\"), or add at least one state name\n\n", .{});
        progress.fatalExit(1, "compatibility check failed: .states must contain at least one state");
    }

    for (states) |name| {
        if (name.len == 0) {
            std.debug.print("labelle: error: state name cannot be empty\n", .{});
            progress.fatalExit(1, "compatibility check failed: state name cannot be empty");
        }
        // First character must be [a-z_] — digits would produce invalid Zig identifiers in codegen
        if (name[0] >= '0' and name[0] <= '9') {
            std.debug.print("labelle: error: state name \"{s}\" cannot start with a digit\n", .{name});
            std.debug.print("  hint: prefix with a letter (e.g., \"level_1\" not \"1_level\")\n\n", .{});
            progress.fatalExit(1, "compatibility check failed: state name cannot start with a digit");
        }
        for (name) |c| {
            if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_')) {
                std.debug.print("labelle: error: invalid state name \"{s}\" — must be lowercase alphanumeric with underscores [a-z0-9_]\n", .{name});
                std.debug.print("  hint: rename to a valid identifier (e.g., \"main_menu\" not \"Main Menu\")\n\n", .{});
                progress.fatalExit(1, "compatibility check failed: invalid state name (want [a-z0-9_])");
            }
        }
    }

    // Check for duplicate state names
    for (states, 0..) |name, i| {
        for (states[i + 1 ..]) |other| {
            if (std.mem.eql(u8, name, other)) {
                std.debug.print("labelle: error: duplicate state name \"{s}\" in .states\n", .{name});
                progress.fatalExit(1, "compatibility check failed: duplicate state name");
            }
        }
    }
}

/// Decide whether a core-diamond package (engine / gfx / cli) should emit a
/// compat warning against the given core MAJOR version.
///
/// These packages each version on their own MINOR train (core 1.21, engine
/// 1.65 and gfx 1.19 are all current and mutually compatible), and the
/// assembler unifies them onto the project's core at build time. So only a
/// MAJOR divergence — a 2.x package against a 1.x core — is a real break.
///
/// Plugins deliberately do not go through this: they version on trains of their
/// own and are not part of the core diamond. See the note in
/// `validateCompatibility` and #332.
fn depCompatWarn(dep_version: []const u8, core_major: u32) bool {
    return parseVersion(dep_version).major != core_major;
}

/// A parsed semver, comparable as a whole.
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    /// True when `self` is older than `other`. Patch is included because a
    /// fix can ship as a patch release, and a gate that stopped at the minor
    /// could not tell the release carrying it from the one before it.
    pub fn olderThan(self: Version, other: Version) bool {
        if (self.major != other.major) return self.major < other.major;
        if (self.minor != other.minor) return self.minor < other.minor;
        return self.patch < other.patch;
    }
};

/// Parse a semver string. Public so other commands can gate a feature on a
/// package version (e.g. `pack --trim` needs a gfx that applies trim
/// offsets).
pub fn parseVersion(version: []const u8) Version {
    var parts: [3]u32 = .{ 0, 0, 0 };
    var part_idx: u8 = 0;

    for (version) |c| {
        // A prerelease or build suffix ends the numeric version. Without
        // this, `1.30.0-rc1` folded the suffix digit into the patch and read
        // as 1.30.1 — so a gate looking for "1.30.1 or newer" accepted a
        // release candidate that PREDATES 1.30.0, silently suppressing the
        // very warning it exists to give.
        if (c == '-' or c == '+') break;
        if (c == '.') {
            part_idx += 1;
            if (part_idx >= 3) break;
        } else if (c >= '0' and c <= '9') {
            parts[part_idx] = parts[part_idx] * 10 + (c - '0');
        }
    }

    return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
}

// ── Tests ────────────────────────────────────────────────────────────

test "depCompatWarn: same major — no warning regardless of minor (independent minors)" {
    // A minor mismatch is not a warning: core 1.21 + engine 1.65 are both
    // major 1 → compatible under independent versioning.
    try std.testing.expect(!depCompatWarn("1.14.0", 1));
    try std.testing.expect(!depCompatWarn("1.65.0", 1));
    try std.testing.expect(!depCompatWarn("1.0.0", 1));
}

test "depCompatWarn: major mismatch warns" {
    try std.testing.expect(depCompatWarn("2.0.0", 1));
    try std.testing.expect(depCompatWarn("1.0.0", 2));
}

test "plugins are never judged against core (issue #230, #332)" {
    // Regression guard: plugin versions live on independent trains, so their
    // major says nothing about which core they target. `pathfinder` 4.0.2 on a
    // 1.24.1 core is correct and must stay silent — as must a 0.x plugin, the
    // case #230 originally carved out. There is deliberately no plugin-version
    // predicate to call here; if one is ever reintroduced, this test's premise
    // (and the note in validateCompatibility) is what it has to contradict.
    //
    // Guard the shape instead: the only compat predicate is for core-diamond
    // packages, and it is not reachable from the plugin loop.
    try std.testing.expect(@TypeOf(depCompatWarn) == fn ([]const u8, u32) bool);
    try std.testing.expect(!@hasDecl(@This(), "pluginCompatWarn"));
}

test "parseVersion: patch is parsed and ordering compares it" {
    const v = parseVersion("1.30.1");
    try std.testing.expectEqual(@as(u32, 1), v.major);
    try std.testing.expectEqual(@as(u32, 30), v.minor);
    try std.testing.expectEqual(@as(u32, 1), v.patch);

    // A fix shipped as a patch is only detectable if patch is compared.
    try std.testing.expect(parseVersion("1.30.0").olderThan(parseVersion("1.30.1")));
    try std.testing.expect(!parseVersion("1.30.1").olderThan(parseVersion("1.30.1")));
    try std.testing.expect(!parseVersion("1.30.2").olderThan(parseVersion("1.30.1")));
    // Major and minor still dominate.
    try std.testing.expect(parseVersion("1.29.9").olderThan(parseVersion("1.30.1")));
    try std.testing.expect(!parseVersion("2.0.0").olderThan(parseVersion("1.30.1")));
}

test "parseVersion: a prerelease or build suffix does not bleed into the patch" {
    // `1.30.0-rc1` used to parse as 1.30.1 — the suffix digit folded into
    // the patch — so a gate for "1.30.1 or newer" accepted a candidate that
    // predates 1.30.0 and went quiet exactly when it should warn.
    try std.testing.expectEqual(@as(u32, 0), parseVersion("1.30.0-rc1").patch);
    try std.testing.expectEqual(@as(u32, 0), parseVersion("1.30.0+1").patch);
    try std.testing.expectEqual(@as(u32, 30), parseVersion("1.30.0-rc1").minor);
    try std.testing.expect(parseVersion("1.30.0-rc1").olderThan(parseVersion("1.30.1")));
    try std.testing.expect(parseVersion("1.30.1-rc1").olderThan(parseVersion("1.30.1")) == false);
}
