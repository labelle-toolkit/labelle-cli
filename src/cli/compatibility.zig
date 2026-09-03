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

    const warnings = compatWarnings(cfg, true);

    // Plugins are deliberately NOT checked against core here. A plugin
    // versions on its own train, so its major encodes nothing about which core
    // it targets: `pathfinder` 4.0.2 supports core 1.24.1 exactly as `fsm`
    // 0.5.0 does. Comparing the two majors produced only false positives
    // (#230 carved out 0.x plugins; 4.x plugins were the same bug from the
    // other side), so the heuristic is gone rather than special-cased again.
    // (#357 established that the core-diamond packages are no different in
    // this respect — see `compatWarnings`.)
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

/// One core-diamond pin paired with the version this CLI was built and tested
/// against (`versions.zon`, surfaced as `project_config.*_VERSION`).
const DiamondPin = struct {
    name: []const u8,
    /// What `project.labelle` pins.
    pinned: []const u8,
    /// What this CLI's curated tested set targets for the SAME package.
    curated: []const u8,
};

/// The core-diamond packages, each paired with its OWN curated version.
///
/// #357: they are deliberately not compared to each other. core, engine, gfx
/// and cli release on independent trains and their major numbers were never
/// meant to track each other — labelle-core has never published a 2.x, while
/// labelle-engine went 2.0.0 for a break in its own scene loader (engine#592,
/// "legacy unified-format aliases removed") that says nothing about core.
/// engine 2.13.0's own `build.zig.zon` declares `labelle-core >= v1.27.0`, so
/// a 2.x engine on a 1.x core is the SUPPORTED pairing, not a skew.
fn coreDiamond(cfg: project_config.ProjectConfig) [4]DiamondPin {
    return .{
        .{ .name = "core", .pinned = cfg.core_version, .curated = project_config.CORE_VERSION },
        .{ .name = "engine", .pinned = cfg.engine_version, .curated = project_config.ENGINE_VERSION },
        .{ .name = "gfx", .pinned = cfg.gfx_version, .curated = project_config.GFX_VERSION },
        .{ .name = "cli", .pinned = cfg.labelle_version, .curated = project_config.CLI_VERSION },
    };
}

/// Count (and, when `emit`, report) core-diamond compatibility warnings.
///
/// The rule this encodes — see `coreDiamond` for why the old cross-package
/// one was wrong — is PER PACKAGE: a package's major bump is a breaking change
/// in that package alone, so the real skew signal is a pin sitting BELOW the
/// major line this CLI was built and tested against for that same package
/// (e.g. an engine 1.x pin against a CLI whose tested engine is 2.x: that
/// project predates engine#592 and will not load a current scene file).
///
/// A pin ABOVE the curated major deliberately does not warn. `versions.zon`
/// lags every fresh package release by construction, so warning there would
/// fire on early adopters and on any CLI that is merely a release behind —
/// exactly the cry-wolf #357 is about — and `upgrade all`, the only hint the
/// check can give, would move them backwards. Being behind the packages is a
/// CLI-update problem, and `labelle update` already reports it.
///
/// The stronger, exact signal is a core range declared by each package itself;
/// that needs post-resolution manifests on disk and is tracked in #332.
fn compatWarnings(cfg: project_config.ProjectConfig, comptime emit: bool) u8 {
    var warnings: u8 = 0;
    for (coreDiamond(cfg)) |d| {
        // `local:<path>` / `@<path>` dev overrides are not version-comparable.
        if (project_config.isLocalVersion(d.pinned) or project_config.isLocalVersion(d.curated)) continue;
        if (!depCompatWarn(d.pinned, d.curated)) continue;
        warnings += 1;
        if (emit) {
            std.debug.print("labelle: warning: {s} {s} is behind this CLI's tested {s} line ({s})\n", .{ d.name, d.pinned, d.name, d.curated });
            std.debug.print("  a major bump is a breaking change within that package alone — core, engine,\n", .{});
            std.debug.print("  gfx and cli version independently and their majors are not meant to match\n", .{});
            std.debug.print("  hint: run `labelle upgrade all`\n\n", .{});
        }
    }
    return warnings;
}

/// Decide whether a core-diamond package should emit a compat warning: true
/// when `pinned` is on an OLDER major line than `curated` — the curated
/// version being this CLI's tested pin for that SAME package, never another
/// package's. See `compatWarnings` for the policy and `coreDiamond` for the
/// evidence behind it (#357).
fn depCompatWarn(pinned: []const u8, curated: []const u8) bool {
    return parseVersion(pinned).major < parseVersion(curated).major;
}

/// A parsed semver, comparable as a whole.
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    /// A `-suffix` was present. Only whether, not which: ordering release
    /// candidates against each other is not something any gate here needs,
    /// but ordering them below their own release is.
    prerelease: bool = false,

    /// True when `self` is older than `other`. Patch is included because a
    /// fix can ship as a patch release, and a gate that stopped at the minor
    /// could not tell the release carrying it from the one before it.
    pub fn olderThan(self: Version, other: Version) bool {
        if (self.major != other.major) return self.major < other.major;
        if (self.minor != other.minor) return self.minor < other.minor;
        if (self.patch != other.patch) return self.patch < other.patch;
        // Same numbers: per semver a prerelease PRECEDES its release, so
        // `1.30.1-rc1` is older than `1.30.1`. Treating them as equal let a
        // release candidate of the fix release satisfy a gate the candidate
        // does not actually satisfy. Build metadata (`+…`) carries no
        // precedence and is not recorded.
        return self.prerelease and !other.prerelease;
    }
};

/// Parse a semver string. Public so other commands can gate a feature on a
/// package version (e.g. `pack --trim` needs a gfx that applies trim
/// offsets).
pub fn parseVersion(version: []const u8) Version {
    var parts: [3]u32 = .{ 0, 0, 0 };
    var part_idx: u8 = 0;
    var prerelease = false;

    for (version) |c| {
        // A prerelease or build suffix ends the numeric version. Without
        // this, `1.30.0-rc1` folded the suffix digit into the patch and read
        // as 1.30.1 — so a gate looking for "1.30.1 or newer" accepted a
        // release candidate that PREDATES 1.30.0, silently suppressing the
        // very warning it exists to give.
        if (c == '-') {
            prerelease = true;
            break;
        }
        if (c == '+') break;
        if (c == '.') {
            part_idx += 1;
            if (part_idx >= 3) break;
        } else if (c >= '0' and c <= '9') {
            parts[part_idx] = parts[part_idx] * 10 + (c - '0');
        }
    }

    return .{ .major = parts[0], .minor = parts[1], .patch = parts[2], .prerelease = prerelease };
}

// ── Tests ────────────────────────────────────────────────────────────

test "depCompatWarn: same major line — no warning regardless of minor" {
    // A minor mismatch inside a package's own major line is never a warning:
    // engine 2.5.0 against a tested engine 2.12.2 is fine.
    try std.testing.expect(!depCompatWarn("2.5.0", "2.12.2"));
    try std.testing.expect(!depCompatWarn("1.14.0", "1.28.0"));
    try std.testing.expect(!depCompatWarn("1.28.0", "1.28.0"));
}

test "depCompatWarn: a package is only ever judged against its OWN curated line (#357)" {
    // The bug: engine's major was compared to CORE's major. labelle-core has
    // never published a 2.x and labelle-engine has been on 2.x since v2.0.0
    // (an engine-local scene-loader break, engine#592), so a 1.x core with a
    // 2.x engine — the CLI's own `versions.zon` set, the assembler's `init`
    // defaults, and the flagship flying-platform-labelle all pair exactly
    // that — is the SUPPORTED combination and must stay silent.
    try std.testing.expect(!depCompatWarn("2.13.0", "2.12.2"));
    try std.testing.expect(!depCompatWarn("2.11.0", "2.12.2"));
}

test "depCompatWarn: a pin below its own curated major still warns (genuine skew)" {
    // An engine 1.x pin against a tested engine 2.x IS a real break: that
    // project predates engine#592 and will not load a current scene file.
    try std.testing.expect(depCompatWarn("1.65.0", "2.12.2"));
    try std.testing.expect(depCompatWarn("0.9.0", "1.28.0"));
}

test "depCompatWarn: a pin ahead of the curated major does not warn" {
    // `versions.zon` lags every fresh release by construction, so warning
    // here would fire on early adopters and on any CLI a release behind —
    // and `upgrade all` would move them backwards. That is a `labelle update`
    // concern, not a project compatibility one.
    try std.testing.expect(!depCompatWarn("3.0.0", "2.12.2"));
}

test "the pin set `labelle init` scaffolds passes the CLI's own check (#357)" {
    // Regression guard for the whole point of the ticket: a fresh project
    // must not warn on its own scaffolding. `ProjectConfig`'s version-field
    // defaults ARE the curated set from `versions.zon` — what `upgrade all`
    // writes and what `init` scaffolds tracks — so a default config standing
    // in for a fresh scaffold must produce ZERO warnings whatever those
    // versions later become.
    const scaffolded = project_config.ProjectConfig{ .name = "my_game" };
    try std.testing.expectEqual(@as(u8, 0), compatWarnings(scaffolded, false));

    // And the exact pins from the #357 reproduction (CLI 1.60.1 + assembler
    // 0.93.1), which warned on every single build.
    const reported = project_config.ProjectConfig{
        .name = "my_game",
        .core_version = "1.26.0",
        .engine_version = "2.5.0",
        .gfx_version = "1.28.1",
        .labelle_version = "1.57.0",
    };
    try std.testing.expectEqual(@as(u8, 0), compatWarnings(reported, false));

    // …as does the flagship game's set (core 1.28.0 + engine 2.13.0).
    const flagship = project_config.ProjectConfig{
        .name = "flying_platform",
        .core_version = "1.28.0",
        .engine_version = "2.13.0",
        .gfx_version = "1.30.2",
        .labelle_version = "1.60.1",
    };
    try std.testing.expectEqual(@as(u8, 0), compatWarnings(flagship, false));
}

test "compatWarnings: a genuinely stale pin is still caught, local overrides are not judged" {
    // A pre-2.0 engine against this CLI's 2.x tested line is real skew.
    const stale = project_config.ProjectConfig{ .name = "old", .engine_version = "1.65.0" };
    try std.testing.expectEqual(@as(u8, 1), compatWarnings(stale, false));

    // A `local:` dev override is not version-comparable and must be skipped.
    const local = project_config.ProjectConfig{ .name = "dev", .engine_version = "local:../labelle-engine" };
    try std.testing.expectEqual(@as(u8, 0), compatWarnings(local, false));
}

test "plugins are never judged against core (issue #230, #332)" {
    // Regression guard: plugin versions live on independent trains, so their
    // major says nothing about which core they target. `pathfinder` 4.0.2 on a
    // 1.24.1 core is correct and must stay silent — as must a 0.x plugin, the
    // case #230 originally carved out. There is deliberately no plugin-version
    // predicate to call here; if one is ever reintroduced, this test's premise
    // (and the note in validateCompatibility) is what it has to contradict.
    //
    // Guard the shape instead: the only compat predicate compares a pin to
    // its own package's curated version, and it is not reachable from the
    // plugin loop.
    try std.testing.expect(@TypeOf(depCompatWarn) == fn ([]const u8, []const u8) bool);
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
    // A prerelease of the fix release does NOT carry the fix.
    try std.testing.expect(parseVersion("1.30.1-rc1").olderThan(parseVersion("1.30.1")));
    try std.testing.expect(!parseVersion("1.30.1").olderThan(parseVersion("1.30.1-rc1")));
    // Build metadata has no precedence: 1.30.1+build is still 1.30.1.
    try std.testing.expect(!parseVersion("1.30.1+build7").olderThan(parseVersion("1.30.1")));
}
