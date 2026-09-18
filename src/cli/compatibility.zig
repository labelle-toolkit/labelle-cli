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
    // `plugin.labelle`; validatePluginCoreCompat checks it after dependency
    // installation, when the manifest is on disk (#332).

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
    // The #357 reproduction pinned core 1.26.0 / engine 2.5.0 / gfx 1.28.1 —
    // same MAJOR line as the curated set of its day, so it must not warn.
    // Since core 2.0.0 / engine 3.0.0 / gfx 2.0.0 the curated line moved, so
    // the same-major-line guard is expressed on the current line, and the
    // 1.x set is asserted separately below as the case that SHOULD warn.
    const reported = project_config.ProjectConfig{
        .name = "my_game",
        .core_version = "2.0.0",
        .engine_version = "3.0.0",
        .gfx_version = "2.0.0",
        .labelle_version = "1.67.0",
    };
    try std.testing.expectEqual(@as(u8, 0), compatWarnings(reported, false));

    // A project still on the whole 1.x line is one MAJOR behind on core,
    // engine AND gfx. Three warnings is the MAJOR-only compatibility gate
    // firing exactly once per package — the behaviour that makes a major
    // bump load-bearing rather than cosmetic. Not a regression of #357.
    const one_major_behind = project_config.ProjectConfig{
        .name = "my_game",
        .core_version = "1.32.0",
        .engine_version = "2.22.0",
        .gfx_version = "1.36.0",
        .labelle_version = "1.67.0",
    };
    try std.testing.expectEqual(@as(u8, 3), compatWarnings(one_major_behind, false));

    // …as does the flagship game's set (core 1.28.0 + engine 2.13.0).
    const flagship = project_config.ProjectConfig{
        .name = "flying_platform",
        .core_version = "2.0.0",
        .engine_version = "3.0.0",
        .gfx_version = "2.0.0",
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

test "compatWarnings: BOTH dev-override spellings are skipped, not just `local:`" {
    // The `@<path>` shorthand is the same dev override as `local:<path>` —
    // `PluginDep.isLocal` has always read both — but the skip here called an
    // `isLocalVersion` that knew only `local:`. So `@../labelle-engine`
    // parsed as 0.0.0 and warned as "behind" the curated major: the exact
    // cry-wolf this PR exists to stop, wearing a different prefix.
    for ([_][]const u8{ "local:../labelle-engine", "@../labelle-engine", "@libs/labelle-engine" }) |pin| {
        const cfg = project_config.ProjectConfig{ .name = "dev", .engine_version = pin };
        try std.testing.expectEqual(@as(u8, 0), compatWarnings(cfg, false));
    }

    // Every core-diamond slot honours it, not just engine.
    const all_local = project_config.ProjectConfig{
        .name = "dev",
        .core_version = "@../labelle-core",
        .engine_version = "@../labelle-engine",
        .gfx_version = "@../labelle-gfx",
        .labelle_version = "@../labelle-cli",
    };
    try std.testing.expectEqual(@as(u8, 0), compatWarnings(all_local, false));

    // And the skip stays narrow: a real stale pin alongside an override is
    // still reported, so this does not become a blanket mute.
    const mixed = project_config.ProjectConfig{
        .name = "dev",
        .core_version = "@../labelle-core",
        .engine_version = "1.65.0",
    };
    try std.testing.expectEqual(@as(u8, 1), compatWarnings(mixed, false));
}

test "isLocalVersion recognises both override spellings (#357)" {
    try std.testing.expect(project_config.isLocalVersion("local:../labelle-engine"));
    try std.testing.expect(project_config.isLocalVersion("@../labelle-engine"));
    try std.testing.expect(!project_config.isLocalVersion("2.13.0"));
    try std.testing.expectEqualStrings("../labelle-engine", project_config.localVersionPath("local:../labelle-engine"));
    try std.testing.expectEqualStrings("../labelle-engine", project_config.localVersionPath("@../labelle-engine"));
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

// ── Declared plugin→core ranges (#332) ────────────────────────────────
//
// The heuristic this replaces compared a plugin's MAJOR to core's MAJOR and had
// no true-positive power: a plugin versions on its own train, so
// `pathfinder 4.0.2` targeting core `1.24.1` is normal and was warned about
// anyway (#230 carved out 0.x plugins; 4.x was the same false positive from the
// other side). What carries real information is the plugin SAYING which cores
// it supports.
//
// Three properties follow, all deliberate:
//
//   * **Absence means nothing is claimed**, not "compatible". A plugin with no
//     `core_compat` is never warned about — that is the pre-#332 behavior and
//     every existing plugin keeps it unchanged.
//   * **A violated range is a WARNING, not a hard failure.** The declaration is
//     the author's belief about a core they could not have tested against; the
//     person running the build can see further than they could. Consistent with
//     every other check in this file, which reports and proceeds.
//   * **A malformed range is reported as malformed**, never silently treated as
//     a version. See `parseSemver` for why that distinction needed its own
//     parser rather than `parseVersion`.

/// Comparison operator in a `core_compat` constraint.
pub const RangeOp = enum { gte, gt, lte, lt, eq };

/// Strict semver parse for DECLARED ranges.
///
/// `parseVersion` above is deliberately lenient — it skips anything non-numeric
/// — which is right for a pin the toolchain produced but wrong for a string a
/// human typed into a manifest: it reads `"banana"` as `0.0.0` and would report
/// a typo as an incompatibility with core 0.0.0. It also builds each component
/// with unchecked `*10 + digit`, so a long numeric token overflows.
///
/// `std.SemanticVersion` gets both right — `error.InvalidVersion` for junk and
/// a partial triple, `error.Overflow` for an oversized component — and it
/// implements real semver precedence, so `1.30.1-rc1` orders BELOW `1.30.1`
/// instead of comparing equal to it, and `+build` metadata is ignored for
/// ordering as the spec requires.
fn parseSemver(text: []const u8) RangeError!std.SemanticVersion {
    return std.SemanticVersion.parse(text) catch |err| switch (err) {
        error.Overflow => error.VersionOverflow,
        else => error.BadVersion,
    };
}

/// One `<op><version>` term.
pub const Constraint = struct {
    op: RangeOp,
    version: std.SemanticVersion,

    pub fn satisfiedBy(self: Constraint, v: std.SemanticVersion) bool {
        const ord = v.order(self.version);
        return switch (self.op) {
            .gte => ord != .lt,
            .gt => ord == .gt,
            .lte => ord != .gt,
            .lt => ord == .lt,
            .eq => ord == .eq,
        };
    }
};

/// Upper bound on terms in one range. A realistic declaration is one or two
/// (`>=1.20.0 <2.0.0`); the cap keeps `Range` a fixed-size value with no
/// allocation, so parsing cannot fail for memory reasons.
pub const MAX_CONSTRAINTS = 4;

pub const RangeError = error{
    Empty,
    TooManyConstraints,
    MissingVersion,
    BadVersion,
    VersionOverflow,
};

/// A conjunction of constraints — every term must hold.
pub const Range = struct {
    items: [MAX_CONSTRAINTS]Constraint = undefined,
    len: u8 = 0,

    pub fn satisfiedBy(self: Range, v: std.SemanticVersion) bool {
        for (self.items[0..self.len]) |c| {
            if (!c.satisfiedBy(v)) return false;
        }
        return true;
    }
};

/// Parse a `core_compat` string: whitespace- or comma-separated terms, each an
/// optional operator followed by a semver. A bare version is an exact match.
///
///   ">=1.20.0 <2.0.0"   →  gte 1.20.0  AND  lt 2.0.0
///   "1.24.1"            →  eq 1.24.1
pub fn parseRange(text: []const u8) RangeError!Range {
    var range = Range{};
    var it = std.mem.tokenizeAny(u8, text, " \t,");
    while (it.next()) |raw| {
        if (range.len >= MAX_CONSTRAINTS) return error.TooManyConstraints;

        var rest = raw;
        var op: RangeOp = .eq;
        // Two-character operators first: ">=" must not read as ">".
        if (std.mem.startsWith(u8, rest, ">=")) {
            op = .gte;
            rest = rest[2..];
        } else if (std.mem.startsWith(u8, rest, "<=")) {
            op = .lte;
            rest = rest[2..];
        } else if (std.mem.startsWith(u8, rest, "==")) {
            op = .eq;
            rest = rest[2..];
        } else if (std.mem.startsWith(u8, rest, ">")) {
            op = .gt;
            rest = rest[1..];
        } else if (std.mem.startsWith(u8, rest, "<")) {
            op = .lt;
            rest = rest[1..];
        } else if (std.mem.startsWith(u8, rest, "=")) {
            op = .eq;
            rest = rest[1..];
        }

        if (rest.len == 0) return error.MissingVersion;
        range.items[range.len] = .{ .op = op, .version = try parseSemver(rest) };
        range.len += 1;
    }

    if (range.len == 0) return error.Empty;
    return range;
}

/// Human-readable reason for a malformed range, for the diagnostic.
pub fn rangeErrorHint(err: RangeError) []const u8 {
    return switch (err) {
        error.Empty => "the range is empty",
        error.TooManyConstraints => "too many terms (max 4)",
        error.MissingVersion => "an operator has no version after it",
        error.BadVersion => "a term is not a MAJOR.MINOR.PATCH semver",
        error.VersionOverflow => "a version component is too large",
    };
}

/// What a single plugin's declaration amounts to. Separated from the reporting
/// so the decision is unit-testable without a filesystem or a core install.
pub const CompatVerdict = union(enum) {
    /// No `core_compat` in the manifest: the plugin claims nothing. Silent.
    undeclared,
    /// Declared and satisfied by the resolved core.
    ok,
    /// Declared and violated. Carries the declaration for the message.
    violated: []const u8,
    /// Declared but unparseable.
    malformed: RangeError,
    /// The core pin is not version-comparable (a `local:` / `@` dev override),
    /// so no declaration can be judged against it. Silent, like the diamond
    /// check's own local-override skip.
    core_not_comparable,
};

/// Decide one plugin's verdict. Pure: takes the two strings, touches nothing.
pub fn judgeCoreCompat(declared: ?[]const u8, core_version: []const u8) CompatVerdict {
    const decl = declared orelse return .undeclared;
    if (project_config.isLocalVersion(core_version)) return .core_not_comparable;

    const range = parseRange(decl) catch |err| return .{ .malformed = err };
    const core = parseSemver(core_version) catch return .core_not_comparable;

    return if (range.satisfiedBy(core)) .ok else .{ .violated = decl };
}

/// Post-resolution plugin compatibility pass (#332).
///
/// Sequencing is the substance of this feature, not the comparison. The
/// pre-resolve `validateCompatibility` runs on `ProjectConfig` alone, when no
/// plugin manifest is on disk yet; this runs after the assembler's `install`
/// has populated the package cache, which is the first moment
/// `<plugin>/plugin.labelle` is readable for a REMOTE plugin. Calling it any
/// earlier reads every remote plugin as undeclared and silently checks nothing.
///
/// Never fatal, and never propagates: a compat check must not be able to break
/// a build it only had an opinion about. A plugin whose directory or manifest
/// cannot be read is simply undeclared here — `labelle plugins` is the command
/// that reports manifest trouble.
pub fn validatePluginCoreCompat(
    allocator: std.mem.Allocator,
    cfg: project_config.ProjectConfig,
    project_dir: []const u8,
) void {
    const warnings = countPluginCompatWarnings(allocator, cfg, project_dir, true);
    if (warnings > 0) {
        std.debug.print("labelle: {d} plugin compatibility warning(s) — proceeding anyway\n\n", .{warnings});
    }
}

/// Count (and, when `emit`, report) declared-range violations.
///
/// Split out with the same `comptime emit` shape `compatWarnings` uses, so the
/// decision is testable against a real plugin directory without capturing
/// stderr — which is what makes the fixture tests below exercise the actual
/// resolve → read → judge path rather than just `judgeCoreCompat`.
///
/// The counter is `usize`, not `u8`: the plugin list is unbounded, and a `u8`
/// would overflow-trap at 256 warnings — turning a check that promises to
/// "proceed anyway" into a crash on a project with many bad manifests.
pub fn countPluginCompatWarnings(
    allocator: std.mem.Allocator,
    cfg: project_config.ProjectConfig,
    project_dir: []const u8,
    comptime emit: bool,
) usize {
    const plugins = @import("plugins.zig");

    var warnings: usize = 0;
    for (cfg.plugins) |dep| {
        const dir = plugins.resolvePluginDir(allocator, project_dir, dep) catch continue;
        defer allocator.free(dir);

        var meta = (plugins.readPluginMeta(allocator, dir) catch continue) orelse continue;
        defer meta.deinit();

        switch (judgeCoreCompat(meta.core_compat, cfg.core_version)) {
            .undeclared, .ok, .core_not_comparable => {},
            .violated => |decl| {
                warnings += 1;
                if (emit) {
                    std.debug.print(
                        "labelle: warning: plugin {s} {s} declares core {s}, but this project pins core {s}\n",
                        .{ dep.name, dep.version, decl, cfg.core_version },
                    );
                    std.debug.print("  the plugin author states it does not support this core\n", .{});
                    std.debug.print("  hint: move core into the declared range, or upgrade the plugin\n\n", .{});
                }
            },
            .malformed => |err| {
                warnings += 1;
                if (emit) {
                    std.debug.print(
                        "labelle: warning: plugin {s} has an unreadable .core_compat ({s}): \"{s}\"\n",
                        .{ dep.name, rangeErrorHint(err), meta.core_compat orelse "" },
                    );
                    std.debug.print("  expected a range like \">=1.20.0 <2.0.0\" or an exact \"1.24.1\"\n", .{});
                    std.debug.print("  the declaration is being IGNORED — compatibility is unchecked for this plugin\n\n", .{});
                }
            },
        }
    }

    return warnings;
}

// ── Tests: declared ranges (#332) ─────────────────────────────────────

test "parseRange: the documented two-term range" {
    const r = try parseRange(">=1.20.0 <2.0.0");
    try std.testing.expectEqual(@as(u8, 2), r.len);
    try std.testing.expectEqual(RangeOp.gte, r.items[0].op);
    try std.testing.expectEqual(RangeOp.lt, r.items[1].op);
    try std.testing.expect(r.satisfiedBy(try std.SemanticVersion.parse("1.24.1")));
    try std.testing.expect(r.satisfiedBy(try std.SemanticVersion.parse("1.20.0"))); // inclusive
    try std.testing.expect(!r.satisfiedBy(try std.SemanticVersion.parse("1.19.9")));
    try std.testing.expect(!r.satisfiedBy(try std.SemanticVersion.parse("2.0.0"))); // exclusive
}

test "parseRange: operators, separators and a bare exact version" {
    try std.testing.expectEqual(RangeOp.eq, (try parseRange("1.24.1")).items[0].op);
    try std.testing.expectEqual(RangeOp.eq, (try parseRange("=1.24.1")).items[0].op);
    try std.testing.expectEqual(RangeOp.eq, (try parseRange("==1.24.1")).items[0].op);
    try std.testing.expectEqual(RangeOp.gt, (try parseRange(">1.24.1")).items[0].op);
    try std.testing.expectEqual(RangeOp.lte, (try parseRange("<=1.24.1")).items[0].op);
    // ">=" must not be read as ">" with a stray "=".
    try std.testing.expectEqual(RangeOp.gte, (try parseRange(">=1.24.1")).items[0].op);
    // Commas and tabs separate terms just like spaces.
    try std.testing.expectEqual(@as(u8, 2), (try parseRange(">=1.0.0,<2.0.0")).len);
    try std.testing.expectEqual(@as(u8, 2), (try parseRange(">=1.0.0\t<2.0.0")).len);

    const exact = try parseRange("1.24.1");
    try std.testing.expect(exact.satisfiedBy(try std.SemanticVersion.parse("1.24.1")));
    try std.testing.expect(!exact.satisfiedBy(try std.SemanticVersion.parse("1.24.2")));
}

test "parseRange: malformed declarations are errors, never silent zeros" {
    try std.testing.expectError(error.Empty, parseRange(""));
    try std.testing.expectError(error.Empty, parseRange("   "));
    try std.testing.expectError(error.MissingVersion, parseRange(">="));
    try std.testing.expectError(error.BadVersion, parseRange("banana"));
    try std.testing.expectError(error.BadVersion, parseRange(">=1.2")); // not a full triple
    try std.testing.expectError(error.BadVersion, parseRange(">=1.2.x"));
    try std.testing.expectError(error.TooManyConstraints, parseRange(">=1.0.0 <2.0.0 >=3.0.0 <4.0.0 >=5.0.0"));

    // The lenient `parseVersion` would read these as 0.0.0 and report a bogus
    // incompatibility instead of a bad manifest.
    try std.testing.expectEqual(@as(u32, 0), parseVersion("banana").major);
}

test "parseRange: a long numeric token overflows rather than trapping (cli review)" {
    // A hand-typed manifest can contain anything. An earlier draft counted
    // digits in a u8 and built components with unchecked `*10 + digit`, so a
    // token like this could trap the CLI instead of warning about the manifest.
    var buf: [512]u8 = undefined;
    @memset(buf[0..300], '9');
    const long_numeric = buf[0..300];
    try std.testing.expectError(error.VersionOverflow, parseRange(long_numeric));

    var dotted: [64]u8 = undefined;
    @memset(dotted[0..20], '9');
    dotted[20] = '.';
    @memset(dotted[21..41], '9');
    dotted[41] = '.';
    @memset(dotted[42..62], '9');
    try std.testing.expectError(error.VersionOverflow, parseRange(dotted[0..62]));

    // And the hint is the overflow one, not the generic bad-version one.
    try std.testing.expectEqualStrings(
        "a version component is too large",
        rangeErrorHint(error.VersionOverflow),
    );
}

test "parseRange: prerelease sorts below its release, build metadata is ignored" {
    // Semver precedence, which the numeric-triple comparison could not express:
    // a release candidate does NOT satisfy a `>=` on its own release.
    const gate = try parseRange(">=1.30.1");
    try std.testing.expect(!gate.satisfiedBy(try std.SemanticVersion.parse("1.30.1-rc1")));
    try std.testing.expect(gate.satisfiedBy(try std.SemanticVersion.parse("1.30.1")));

    // A prerelease sorts below its stable release under semver precedence.
    const upper = try parseRange("<2.0.0");
    try std.testing.expect(upper.satisfiedBy(try std.SemanticVersion.parse("2.0.0-rc1")));
    try std.testing.expect(!upper.satisfiedBy(try std.SemanticVersion.parse("2.0.0")));

    // Build metadata carries no precedence.
    const exact = try parseRange("1.24.1");
    try std.testing.expect(exact.satisfiedBy(try std.SemanticVersion.parse("1.24.1+build7")));

    // A declared range may itself name a prerelease.
    const pre_gate = try parseRange(">=1.30.1-rc1");
    try std.testing.expect(pre_gate.satisfiedBy(try std.SemanticVersion.parse("1.30.1")));
    try std.testing.expect(!pre_gate.satisfiedBy(try std.SemanticVersion.parse("1.30.0")));
}

test "judgeCoreCompat: absence, match, mismatch, malformed" {
    // ABSENCE — the pre-#332 behavior every existing plugin keeps. Crucially
    // NOT "compatible": nothing is claimed, so nothing is judged.
    try std.testing.expectEqual(CompatVerdict.undeclared, judgeCoreCompat(null, "1.24.1"));

    // MATCH — the pathfinder case that used to produce a false positive.
    try std.testing.expectEqual(CompatVerdict.ok, judgeCoreCompat(">=1.20.0 <2.0.0", "1.24.1"));

    // MISMATCH — a real, declared violation.
    switch (judgeCoreCompat(">=1.20.0 <2.0.0", "2.1.0")) {
        .violated => |d| try std.testing.expectEqualStrings(">=1.20.0 <2.0.0", d),
        else => return error.TestExpectedViolation,
    }
    switch (judgeCoreCompat(">=1.26.0", "1.24.1")) {
        .violated => {},
        else => return error.TestExpectedViolation,
    }

    // MALFORMED — reported as a manifest problem, not as an incompatibility.
    switch (judgeCoreCompat("not-a-range", "1.24.1")) {
        .malformed => |e| try std.testing.expectEqual(RangeError.BadVersion, e),
        else => return error.TestExpectedMalformed,
    }
}

test "judgeCoreCompat: a local core override is not comparable" {
    // Same posture as the diamond check: a dev override has no version to
    // judge, so declarations are skipped rather than guessed at.
    try std.testing.expectEqual(
        CompatVerdict.core_not_comparable,
        judgeCoreCompat(">=1.20.0 <2.0.0", "local:../labelle-core"),
    );
    try std.testing.expectEqual(
        CompatVerdict.core_not_comparable,
        judgeCoreCompat(">=1.20.0 <2.0.0", "@../labelle-core"),
    );
    // An undeclared plugin stays undeclared even under an override — absence is
    // decided before comparability.
    try std.testing.expectEqual(
        CompatVerdict.undeclared,
        judgeCoreCompat(null, "local:../labelle-core"),
    );
}

test "judgeCoreCompat: an unparseable core pin is skipped, not reported as violated" {
    // A core pin the CLI cannot read is the CLI's problem, not the plugin's.
    // Blaming the plugin here would be exactly the false positive #332 removes.
    try std.testing.expectEqual(
        CompatVerdict.core_not_comparable,
        judgeCoreCompat(">=1.20.0 <2.0.0", "not-a-version"),
    );
}

test "the plugin-vs-core heuristic stays gone (issue #230, #332)" {
    // #332 does NOT reinstate version guessing. Plugins are judged only by what
    // they DECLARE, so there is still no predicate that derives compatibility
    // from a plugin's own version number, and `judgeCoreCompat` never sees one.
    try std.testing.expect(!@hasDecl(@This(), "pluginCompatWarn"));
    try std.testing.expect(@TypeOf(judgeCoreCompat) ==
        fn (?[]const u8, []const u8) CompatVerdict);

    // The regression that started it: pathfinder 4.0.2 on core 1.24.1 — a
    // plugin four majors "ahead" of core — is silent when it declares nothing,
    // and silent again when it declares a range that includes this core.
    try std.testing.expectEqual(CompatVerdict.undeclared, judgeCoreCompat(null, "1.24.1"));
    try std.testing.expectEqual(CompatVerdict.ok, judgeCoreCompat(">=1.20.0 <2.0.0", "1.24.1"));
}
