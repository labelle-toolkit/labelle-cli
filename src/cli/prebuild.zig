//! Pre-build hooks — the `.prebuild` block in `project.labelle` (cli#355).
//!
//! ## The hole this closes
//!
//! `project.labelle` has no way to say "this resource is GENERATED". A
//! project that packs its atlas with `tools/gen_tiles.py` declares the
//! emitted `.png`/`.json`/`.zig` as if they were hand-written; edit the
//! source `.tsx` and `labelle run` produces a CLEAN build against the OLD
//! tiles, with no warning. The failure is silent and looks like the edit
//! didn't take. Sprite packing, tilemap tables, localisation tables,
//! generated constants and shader compilation all have this shape.
//!
//! ## Shape
//!
//! ```zon
//! .prebuild = .{
//!     .{
//!         .run = .{ "python3", "tools/gen_tiles.py" },
//!         .inputs = .{ "tools/gen_tiles.py", "tools/OverworldTileset.tsx" },
//!         .outputs = .{ "assets/out.png", "assets/out.json" },
//!     },
//! },
//! ```
//!
//! Steps run in declared order, with the PROJECT ROOT as cwd, before any
//! generation input is read — ahead of the ASTC pre-pass, the assembler's
//! cache populate and `labelle-assembler generate`. So a step may legally
//! emit an atlas the project declares in `.resources`, a script the game
//! compiles against, or both.
//!
//! ## Freshness: files AND recipe
//!
//! A step that declares both `.inputs` and `.outputs` is skipped while it
//! is up to date. "Up to date" has two halves, because either one alone
//! silently reuses a stale artifact:
//!
//! 1. **The files** — `make`'s rule on the declared paths' mtimes
//!    (`Scan`). Everything ambiguous (under-declared, missing path, stat
//!    failure) resolves to "run".
//! 2. **The recipe** — a fingerprint of `.run` + `.inputs`, persisted in
//!    `.labelle/prebuild-recipes` keyed by the step's output set
//!    (`RecipeStore`). Editing `.run` in `project.labelle` moves no mtime,
//!    so without this the new command was skipped as "up to date" while
//!    the build consumed what the OLD command produced.
//!
//! ## Trust posture — auditability, not sandboxing
//!
//! This executes commands named in a config file. That is deliberate and
//! it matches the toolkit's existing posture for declarative build steps
//! (`labelle-assembler`'s `plugin_build_steps.zig`, whose module doc
//! spells the same tradeoff out): commands are DECLARED argv arrays in a
//! file you can read — no shell, no `sh -c`, no env expansion, no glob
//! expansion, no PATH rewriting beyond what the CLI already exports for
//! the build. What the declarative form buys is that the whole exec
//! surface is visible in `project.labelle` before you build, instead of
//! buried in imperative build code.
//!
//! It is NOT a sandbox. `project.labelle` already selects plugin repos
//! the CLI fetches and builds, and the generated `build.zig` already runs
//! arbitrary build-time code — a hostile `project.labelle` could run code
//! at build time long before this hook existed. Cloning a repo and
//! running `labelle build` in it is a trust decision the user makes once,
//! at the same level as `zig build` or `make`. So: NO interactive
//! consent prompt (the CLI has none today, and a prompt on every build
//! would train people to say yes), and no per-project allowlist file.
//!
//! The escape hatch is `LABELLE_NO_PREBUILD=1`, which skips every step
//! with a loud note — for inspecting an untrusted project, and for CI
//! that regenerates assets out-of-band.
//!
//! ## `--progress=json`
//!
//! `labelle build --progress=json` promises PURE NDJSON on stdout
//! (cli#320). A prebuild tool that prints to stdout would corrupt that
//! stream. In json mode the child's stdout is therefore handed the CLI's
//! **stderr** file directly (`StdIo.file`) — the user still sees every
//! line, live, interleaved with the tool's own stderr, and the NDJSON
//! feed stays machine-parseable. No pumping, no buffering, no reordering.
//! In human/off mode stdout is inherited unchanged.
//!
//! Prebuild runs inside the existing `resolve` phase and emits no new
//! record kind, so the progress schema is untouched (studio#28 consumes
//! it; additive-only).

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const progress = @import("progress.zig");
const project_config = @import("project_config.zig");

/// One declared step. Re-exported from the CLI's `project.labelle` mirror
/// so callers need only this module.
pub const Step = project_config.PrebuildStep;

pub const Error = error{
    /// A step is malformed (empty `.run`, or an empty `argv[0]`).
    InvalidPrebuildStep,
    /// The step could not be spawned or reaped at all — missing binary, no
    /// exec bit, killed by a signal. Distinct from "ran and exited
    /// non-zero", which proxies the child's exact exit code instead.
    PrebuildSpawnFailed,
    /// A step ran and exited non-zero, in a caller that asked NOT to be
    /// terminated (`Options.fatal_on_step_failure = false` — the
    /// `wasm serve --watch` rebuild, which must keep the server alive).
    /// The default, process-exiting path never returns this.
    PrebuildStepFailed,
};

/// Kill switch: set to anything but empty/`0` to skip every prebuild step.
/// Named like the CLI's other env overrides (`LABELLE_ASSEMBLER`,
/// `LABELLE_ZIG`, `LABELLE_PROGRESS_DEBUG`).
pub const SKIP_ENV = "LABELLE_NO_PREBUILD";

pub const Options = struct {
    /// `--progress=json`: give the child our stderr as its stdout so the
    /// NDJSON feed on stdout stays pure (module doc).
    route_stdout_to_stderr: bool = false,
    /// Whether a non-zero step terminates the process with the child's
    /// exact exit code (the build pipeline's contract) or merely returns
    /// `error.PrebuildStepFailed`. The `wasm serve --watch` rebuild sets
    /// this false: a failed step there must report and keep the server
    /// alive, exactly like a failed `generate` or `zig build` does.
    fatal_on_step_failure: bool = true,
};

// ── Validation ───────────────────────────────────────────────────────

/// Why a declared step is unusable. `null` from `validate` = usable.
pub const Invalid = enum {
    /// `.run = .{}` — nothing to execute.
    empty_run,
    /// `.run = .{ "", ... }` — `argv[0]` is the program name; empty can
    /// only ever fail to spawn, so reject it up front with a real message.
    empty_argv0,
};

/// Structural check on one step. Pure.
pub fn validate(step: Step) ?Invalid {
    if (step.run.len == 0) return .empty_run;
    if (step.run[0].len == 0) return .empty_argv0;
    return null;
}

/// Human-readable reason for an `Invalid`. Pure; static strings.
pub fn invalidReason(kind: Invalid) []const u8 {
    return switch (kind) {
        .empty_run => "`.run` is empty — a prebuild step must name a command, e.g. .run = .{ \"python3\", \"tools/gen.py\" }",
        .empty_argv0 => "`.run` starts with an empty string — the first element is the program to execute",
    };
}

// ── Staleness (inputs/outputs mtimes) ────────────────────────────────

pub const Staleness = enum {
    /// The step declares no `.inputs` or no `.outputs`, so nothing can be
    /// compared — it runs every time. The safe default: a step that
    /// under-declares must never be silently skipped.
    unknown,
    /// An output is missing, or an input is newer than an output.
    stale,
    /// Every output exists and is at least as new as every input.
    fresh,
};

/// Collected mtimes for one step. Split from the filesystem walk so the
/// decision rule is pure and unit-testable.
pub const Scan = struct {
    has_inputs: bool = false,
    has_outputs: bool = false,
    /// A declared input or output could not be stat'ed.
    missing_path: bool = false,
    newest_input_ns: i128 = std.math.minInt(i128),
    oldest_output_ns: i128 = std.math.maxInt(i128),

    /// `make`'s rule: rebuild when a prerequisite is strictly NEWER than
    /// the target. Equal mtimes count as fresh — a coarse (1s) filesystem
    /// clock would otherwise re-run every step of a fast generator
    /// forever. A missing path is always stale: a deleted output must
    /// come back, and a vanished input means the declaration is wrong,
    /// which the tool itself should report.
    pub fn verdict(self: Scan) Staleness {
        if (!self.has_inputs or !self.has_outputs) return .unknown;
        if (self.missing_path) return .stale;
        return if (self.newest_input_ns <= self.oldest_output_ns) .fresh else .stale;
    }
};

/// Stat every declared input/output of `step`, resolved against
/// `project_dir`. Never fails: any error (OOM, permission) degrades to a
/// `Scan` whose verdict makes the step RUN, which is the conservative
/// direction — a skipped step is the silent-stale bug this feature exists
/// to kill.
pub fn scanStep(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    step: Step,
) Scan {
    var s: Scan = .{
        .has_inputs = step.inputs.len > 0,
        .has_outputs = step.outputs.len > 0,
    };
    if (!s.has_inputs or !s.has_outputs) return s;

    for (step.inputs) |rel| {
        const ns = mtimeNs(allocator, project_dir, rel) orelse {
            s.missing_path = true;
            return s;
        };
        if (ns > s.newest_input_ns) s.newest_input_ns = ns;
    }
    for (step.outputs) |rel| {
        const ns = mtimeNs(allocator, project_dir, rel) orelse {
            s.missing_path = true;
            return s;
        };
        if (ns < s.oldest_output_ns) s.oldest_output_ns = ns;
    }
    return s;
}

fn mtimeNs(allocator: std.mem.Allocator, project_dir: []const u8, rel: []const u8) ?i128 {
    const path = std.fs.path.join(allocator, &.{ project_dir, rel }) catch return null;
    defer allocator.free(path);
    const st = std.Io.Dir.cwd().statFile(config.globalIo(), path, .{}) catch return null;
    return @as(i128, st.mtime.nanoseconds);
}

// ── Recipe fingerprint (the `.run` declaration itself) ────────────────

/// `Scan` can only see the DECLARED FILES. It cannot see the command, so
/// with `.inputs`/`.outputs` declared, editing `.run` in `project.labelle`
/// — adding a generator flag that changes the output format, say — moved
/// no mtime and the step was skipped as "up to date" while the build
/// consumed the artifact the OLD command produced. That is exactly the
/// silent-staleness failure this whole feature exists to kill, arriving
/// through the freshness check instead of through a missing declaration.
///
/// The fix is `make`'s own answer to the same hole (`.RECIPEPREREQ` /
/// ninja's `command` field in `.ninja_log`): persist a fingerprint of the
/// recipe next to the build output and treat a change to it as staleness.
///
/// Persisted under the project's `.labelle/` — the CLI's existing
/// project-local scratch dir (build targets, the live build-status file).
/// It is already git-ignored, `labelle clean` (a global package-cache
/// command) does not touch it, and `serve.skipWatchDir` skips every
/// dot-directory, so writing here can never retrigger `wasm serve
/// --watch`.
pub const state_dir_name = ".labelle";
pub const state_file_name = "prebuild-recipes";

const state_header =
    "# labelle prebuild recipe fingerprints (cli#355) — generated, safe to delete\n" ++
    "# <outputs-key> <recipe-hash>; a recipe change forces the step to re-run\n";

/// Fold a list of strings into `h`, length-delimited so `{ "ab", "c" }`
/// and `{ "a", "bc" }` cannot collide.
fn hashList(h: *std.hash.Wyhash, list: []const []const u8) void {
    for (list) |s| {
        h.update(std.mem.asBytes(&@as(u64, s.len)));
        h.update(s);
    }
}

/// WHAT the step produces — its identity in the store, so re-ordering the
/// `.prebuild` block does not invalidate anything. Commutative (a
/// wrapping sum of per-path hashes) so re-ordering `.outputs` isn't a
/// change either; a sum rather than an XOR because XOR would cancel a
/// path declared twice down to the empty key.
pub fn outputsKey(step: Step) u64 {
    var key: u64 = 0;
    for (step.outputs) |o| {
        var h = std.hash.Wyhash.init(0x0b1e);
        h.update(o);
        key +%= h.final();
    }
    return key;
}

/// HOW it produces them: the argv, plus the declared `.inputs` (the rest
/// of the declaration that says what the outputs are derived FROM —
/// adding an input the tool now reads is a recipe change too). Order is
/// significant here: `.run` is an argv.
pub fn recipeHash(step: Step) u64 {
    var h = std.hash.Wyhash.init(0x5c1e);
    hashList(&h, step.run);
    h.update("\x00inputs\x00");
    hashList(&h, step.inputs);
    return h.final();
}

/// The full freshness rule: a step is skipped only when its declared
/// files are current AND the command that produced them is the command
/// declared today. `recorded` is the fingerprint persisted the last time
/// this output set was actually produced — `null` (no record: first build
/// after adopting this, a wiped `.labelle/`, an unreadable state file)
/// resolves to NOT fresh, matching the rest of this module: every
/// ambiguous case runs, because a wrongly skipped step reintroduces the
/// silent-stale bug while a wrongly re-run step only costs time.
pub fn isFresh(scan: Scan, recorded: ?u64, current: u64) bool {
    if (scan.verdict() != .fresh) return false;
    const seen = recorded orelse return false;
    return seen == current;
}

/// True when a step participates in freshness at all. A step missing
/// either half of the declaration always runs, so it needs no record.
pub fn isTracked(step: Step) bool {
    return step.inputs.len > 0 and step.outputs.len > 0;
}

/// The persisted recipe fingerprints, keyed by output set. A short list,
/// not a map: there are as many entries as tracked steps (one or two in
/// practice), and a list keeps the file's line order stable across writes.
pub const RecipeStore = struct {
    pub const Entry = struct { key: u64, recipe: u64 };

    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *RecipeStore, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    /// The fingerprint recorded for this output set, or null when the
    /// outputs have never been produced under a recorded recipe.
    pub fn recordedFor(self: RecipeStore, key: u64) ?u64 {
        for (self.entries.items) |e| {
            if (e.key == key) return e.recipe;
        }
        return null;
    }

    /// Note that `key`'s outputs were just produced by `recipe`. An OOM
    /// here is swallowed on purpose: the only consequence of a missing
    /// record is that the step runs again next build.
    pub fn record(self: *RecipeStore, allocator: std.mem.Allocator, key: u64, recipe: u64) void {
        for (self.entries.items) |*e| {
            if (e.key == key) {
                e.recipe = recipe;
                return;
            }
        }
        self.entries.append(allocator, .{ .key = key, .recipe = recipe }) catch {};
    }

    /// Drop entries whose output set no longer matches a tracked declared
    /// step, so the file can't grow without bound as `.prebuild` evolves.
    pub fn prune(self: *RecipeStore, steps: []const Step) void {
        var kept: usize = 0;
        outer: for (self.entries.items) |e| {
            for (steps) |s| {
                if (!isTracked(s)) continue;
                if (outputsKey(s) == e.key) {
                    self.entries.items[kept] = e;
                    kept += 1;
                    continue :outer;
                }
            }
        }
        self.entries.shrinkRetainingCapacity(kept);
    }

    /// Parse the on-disk text. Pure and total: a malformed line is
    /// skipped rather than fatal — a corrupt state file must degrade to
    /// "re-run the step", never to a failed build.
    pub fn parse(allocator: std.mem.Allocator, text: []const u8) RecipeStore {
        var self: RecipeStore = .{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const key = std.fmt.parseInt(u64, line[0..sp], 16) catch continue;
            const recipe = std.fmt.parseInt(u64, std.mem.trim(u8, line[sp + 1 ..], " \t"), 16) catch continue;
            self.record(allocator, key, recipe);
        }
        return self;
    }

    /// Serialize to the on-disk text. Pure; caller owns the result.
    pub fn render(self: RecipeStore, allocator: std.mem.Allocator) ![]u8 {
        var aw = std.Io.Writer.Allocating.init(allocator);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll(state_header);
        for (self.entries.items) |e| {
            try w.print("{x:0>16} {x:0>16}\n", .{ e.key, e.recipe });
        }
        return aw.toOwnedSlice();
    }

    /// Read the project's store. Never fails: a missing, unreadable or
    /// corrupt file yields an EMPTY store, which makes every tracked step
    /// stale — the conservative direction.
    pub fn load(allocator: std.mem.Allocator, project_dir: []const u8) RecipeStore {
        const path = statePath(allocator, project_dir) catch return .{};
        defer allocator.free(path);
        const raw = std.Io.Dir.cwd().readFileAlloc(
            config.globalIo(),
            path,
            allocator,
            .limited(256 * 1024),
        ) catch return .{};
        defer allocator.free(raw);
        return parse(allocator, raw);
    }

    /// Persist the store. Best-effort — a project dir that can't be
    /// written just means every tracked step re-runs on every build (the
    /// pre-#355 behavior), so this reports and moves on rather than
    /// failing a build whose steps have already succeeded.
    pub fn save(self: RecipeStore, allocator: std.mem.Allocator, project_dir: []const u8) void {
        const io = config.globalIo();
        const dir = std.fs.path.join(allocator, &.{ project_dir, state_dir_name }) catch return;
        defer allocator.free(dir);
        const path = statePath(allocator, project_dir) catch return;
        defer allocator.free(path);
        const text = self.render(allocator) catch return;
        defer allocator.free(text);

        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch |err| {
            std.debug.print(
                "labelle: warning: could not write '{s}' ({s})\n" ++
                    "  prebuild steps that declare .inputs/.outputs will re-run on every build.\n",
                .{ path, @errorName(err) },
            );
        };
    }
};

fn statePath(allocator: std.mem.Allocator, project_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ project_dir, state_dir_name, state_file_name });
}

// ── Rendering ────────────────────────────────────────────────────────

/// Render argv for a log/error line: space-joined, each element that is
/// empty or contains a space, tab or quote wrapped in double quotes, with
/// any embedded `"` backslash-escaped so the quoting stays balanced (an
/// unescaped inner quote produced log lines a reader cannot split back
/// into arguments). Display only — nothing is ever re-parsed from this.
/// Caller owns the result.
pub fn renderArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (argv, 0..) |a, i| {
        if (i != 0) try out.append(allocator, ' ');
        const needs_quotes = a.len == 0 or
            std.mem.indexOfAny(u8, a, " \t\"") != null;
        if (!needs_quotes) {
            try out.appendSlice(allocator, a);
            continue;
        }
        try out.append(allocator, '"');
        for (a) |c| {
            // Only `"` is escaped: a backslash is left alone so Windows
            // paths (`C:\tools\gen.exe`) render as the user wrote them.
            if (c == '"') try out.append(allocator, '\\');
            try out.append(allocator, c);
        }
        try out.append(allocator, '"');
    }
    return out.toOwnedSlice(allocator);
}

/// The terminal-record `detail` for a failed step (cli#318 wants a
/// per-call-site label a feed consumer can render). Pure; writes into
/// `buf`, which must be `progress.max_detail_len` bytes.
pub fn failureDetail(buf: []u8, index: usize, total: usize) []const u8 {
    return std.fmt.bufPrint(buf, "prebuild step {d}/{d} failed", .{ index + 1, total }) catch
        "prebuild step failed";
}

// ── Execution ────────────────────────────────────────────────────────

/// True when `LABELLE_NO_PREBUILD` is set to anything but empty or `0`.
pub fn skipRequested(allocator: std.mem.Allocator) bool {
    const v = config.globalEnviron().getAlloc(allocator, SKIP_ENV) catch return false;
    defer allocator.free(v);
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// Spawn one step's argv with `project_dir` as cwd and wait. Returns the
/// child's exit code — 0 or otherwise; the caller decides what a non-zero
/// code means. Returns `error.PrebuildSpawnFailed` only when the child
/// never ran to a normal exit.
///
/// argv is passed to `std.process.spawn` verbatim: no shell, no env
/// expansion, no globbing (module doc, "auditability, not sandboxing").
pub fn runStep(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    step: Step,
    opts: Options,
) Error!u8 {
    const io = config.globalIo();

    // In json mode the child's stdout is the CLI's stderr FILE, so its
    // output streams live without ever touching the NDJSON stdout feed.
    const child_stdout: std.process.SpawnOptions.StdIo = if (opts.route_stdout_to_stderr)
        .{ .file = std.Io.File.stderr() }
    else
        .inherit;

    var child = std.process.spawn(io, .{
        .argv = step.run,
        .cwd = .{ .path = project_dir },
        .stdin = .inherit,
        .stdout = child_stdout,
        .stderr = .inherit,
    }) catch |err| {
        const owned = renderArgv(allocator, step.run) catch null;
        defer if (owned) |o| allocator.free(o);
        const rendered: []const u8 = owned orelse "<command>";
        std.debug.print(
            "labelle: prebuild could not launch '{s}' ({s})\n" ++
                "  cwd: {s}\n" ++
                "  is the program on PATH, or is the path relative to the project root correct?\n",
            .{ rendered, @errorName(err), project_dir },
        );
        return error.PrebuildSpawnFailed;
    };

    const term = child.wait(io) catch |err| {
        std.debug.print("labelle: prebuild could not wait on the step ({s})\n", .{@errorName(err)});
        return error.PrebuildSpawnFailed;
    };
    return switch (term) {
        .exited => |code| code,
        else => blk: {
            const owned = renderArgv(allocator, step.run) catch null;
            defer if (owned) |o| allocator.free(o);
            const rendered: []const u8 = owned orelse "<command>";
            std.debug.print("labelle: prebuild step '{s}' terminated abnormally\n", .{rendered});
            break :blk error.PrebuildSpawnFailed;
        },
    };
}

/// Structural check on EVERY step, before any of them runs. Split out of
/// `runAll` so a malformed entry anywhere in the list is fatal before the
/// first process is spawned: validating inside the execution loop meant a
/// manifest like `{ valid mutating step, .run = .{} }` regenerated project
/// files and only then failed, leaving half-applied side effects behind
/// from a structurally invalid manifest.
fn validateAll(steps: []const Step) Error!void {
    for (steps, 0..) |step, i| {
        const bad = validate(step) orelse continue;
        std.debug.print(
            "labelle: project.labelle .prebuild step {d}/{d} is invalid:\n  {s}\n" ++
                "  no prebuild step was run.\n",
            .{ i + 1, steps.len, invalidReason(bad) },
        );
        return error.InvalidPrebuildStep;
    }
}

/// Run every declared step, in order, before generation.
///
/// A project with no `.prebuild` returns immediately having printed
/// nothing and touched no file — the default path is byte-identical to
/// before this feature existed.
///
/// EVERY step is validated first (`validateAll`); a malformed entry
/// anywhere fails the build before the first spawn, so an invalid
/// manifest can never leave partial side effects behind.
///
/// A step that declares both `.inputs` and `.outputs` is skipped only
/// when BOTH halves of freshness hold: the declared files' mtimes are
/// current (`Scan`) AND the recipe that produced them is the recipe
/// declared today (`RecipeStore`, persisted under `.labelle/`). Editing
/// `.run` alone moves no mtime, so without the second half the new
/// command was silently skipped and the artifact built by the OLD one was
/// consumed.
///
/// A non-zero exit terminates the CLI with the child's EXACT exit code
/// (via `progress.fatalExit`, which first marks the live build-status
/// file `failed`), after printing which step failed and why. This mirrors
/// `assembler_proc.spawnAndWait`: collapsing every distinct tool failure
/// to a single status 1 makes the CLI a lying proxy for the step it ran.
/// Callers that must survive a failure (`wasm serve --watch`) pass
/// `Options.fatal_on_step_failure = false` and get
/// `error.PrebuildStepFailed` instead.
pub fn runAll(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    steps: []const Step,
    opts: Options,
) Error!void {
    if (steps.len == 0) return;

    // The kill switch wins over validation: it exists to run a build with
    // NO step executed at all (inspecting an untrusted project, or CI that
    // regenerates out of band), and nothing here can misfire once no step
    // will run.
    if (skipRequested(allocator)) {
        std.debug.print(
            "labelle: skipping {d} prebuild step(s) — {s} is set.\n" ++
                "  generated assets may be stale; unset it to run them.\n",
            .{ steps.len, SKIP_ENV },
        );
        return;
    }

    // Whole-slice validation BEFORE the execution loop: a malformed step
    // at index N must not be discovered after steps 0..N-1 already
    // mutated the project.
    try validateAll(steps);

    // The recipe half of the freshness key. Loaded once; rewritten after
    // each tracked step that actually ran, so a step whose command
    // succeeded is not re-run just because a LATER step failed the build.
    var store = RecipeStore.load(allocator, project_dir);
    defer store.deinit(allocator);

    for (steps, 0..) |step, i| {
        // Tracked as an optional rather than by comparing the rendered
        // text to the placeholder: a project may legitimately declare
        // `.run = .{"<command>"}`, and a contents check would then skip
        // the free.
        const rendered_owned = renderArgv(allocator, step.run) catch null;
        defer if (rendered_owned) |r| allocator.free(r);
        const rendered: []const u8 = rendered_owned orelse "<command>";

        // Freshness has two halves — the declared files' mtimes, and the
        // declaration that produced them. An untracked step (missing
        // `.inputs` or `.outputs`) has neither and always runs.
        const tracked = isTracked(step);
        const key = if (tracked) outputsKey(step) else 0;
        const recipe = if (tracked) recipeHash(step) else 0;
        if (tracked and isFresh(
            scanStep(allocator, project_dir, step),
            store.recordedFor(key),
            recipe,
        )) {
            std.debug.print(
                "  prebuild [{d}/{d}] up to date, skipping: {s}\n",
                .{ i + 1, steps.len, rendered },
            );
            continue;
        }

        std.debug.print("  prebuild [{d}/{d}] {s}\n", .{ i + 1, steps.len, rendered });
        const code = try runStep(allocator, project_dir, step, opts);
        if (code != 0) {
            std.debug.print(
                "\nlabelle: prebuild step {d}/{d} failed (exit code {d})\n" ++
                    "  command: {s}\n" ++
                    "  cwd:     {s}\n" ++
                    "  declared in project.labelle `.prebuild`\n",
                .{ i + 1, steps.len, code, rendered, project_dir },
            );
            if (!opts.fatal_on_step_failure) return error.PrebuildStepFailed;
            var detail_buf: [progress.max_detail_len]u8 = undefined;
            progress.fatalExit(code, failureDetail(&detail_buf, i, steps.len));
        }

        // Record what produced these outputs, immediately: a later step
        // may `fatalExit` out of this loop, and a step that genuinely
        // succeeded should not be re-run because of that.
        if (tracked) {
            store.record(allocator, key, recipe);
            store.prune(steps);
            store.save(allocator, project_dir);
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────

const expect = @import("zspec").expect;

test {
    @import("zspec").runAll(@This());
}

/// A step must name a command. `.run = .{}` is the typo that would
/// otherwise spawn nothing and pass silently — exactly the class of
/// silent no-op this feature exists to eliminate.
pub const ValidateStepSpec = struct {
    pub const accepts = struct {
        test "a step with a program and args is valid" {
            try expect.toBeNull(validate(.{ .run = &.{ "python3", "tools/gen.py" } }));
        }

        test "a single-element argv is valid" {
            try expect.toBeNull(validate(.{ .run = &.{"make"} }));
        }
    };

    pub const rejects = struct {
        test "an empty .run is rejected" {
            try std.testing.expectEqual(Invalid.empty_run, validate(.{ .run = &.{} }).?);
        }

        test "an empty argv[0] is rejected" {
            try std.testing.expectEqual(Invalid.empty_argv0, validate(.{ .run = &.{ "", "x" } }).?);
        }

        test "every reason renders a non-empty message" {
            inline for (.{ Invalid.empty_run, Invalid.empty_argv0 }) |k| {
                try expect.toBeTrue(invalidReason(k).len > 0);
            }
        }
    };
};

/// The staleness rule. Skipping is a BONUS on top of "always run" — so
/// every ambiguous case must resolve to "run", never to "skip": a step
/// wrongly skipped reintroduces the silent-stale-output bug, while a step
/// wrongly re-run only costs time.
pub const StalenessVerdictSpec = struct {
    pub const under_declared_always_runs = struct {
        test "no inputs and no outputs is unknown" {
            try std.testing.expectEqual(Staleness.unknown, (Scan{}).verdict());
        }

        test "inputs without outputs is unknown" {
            const s = Scan{ .has_inputs = true, .newest_input_ns = 10 };
            try std.testing.expectEqual(Staleness.unknown, s.verdict());
        }

        test "outputs without inputs is unknown" {
            const s = Scan{ .has_outputs = true, .oldest_output_ns = 10 };
            try std.testing.expectEqual(Staleness.unknown, s.verdict());
        }
    };

    pub const compares_mtimes = struct {
        test "an input newer than an output is stale" {
            const s = Scan{
                .has_inputs = true,
                .has_outputs = true,
                .newest_input_ns = 200,
                .oldest_output_ns = 100,
            };
            try std.testing.expectEqual(Staleness.stale, s.verdict());
        }

        test "an output newer than every input is fresh" {
            const s = Scan{
                .has_inputs = true,
                .has_outputs = true,
                .newest_input_ns = 100,
                .oldest_output_ns = 200,
            };
            try std.testing.expectEqual(Staleness.fresh, s.verdict());
        }

        test "equal mtimes count as fresh (coarse fs clocks)" {
            const s = Scan{
                .has_inputs = true,
                .has_outputs = true,
                .newest_input_ns = 100,
                .oldest_output_ns = 100,
            };
            try std.testing.expectEqual(Staleness.fresh, s.verdict());
        }
    };

    pub const missing_paths = struct {
        test "a missing declared path forces a re-run" {
            const s = Scan{
                .has_inputs = true,
                .has_outputs = true,
                .missing_path = true,
                .newest_input_ns = 1,
                .oldest_output_ns = 999,
            };
            try std.testing.expectEqual(Staleness.stale, s.verdict());
        }
    };
};

/// `scanStep` against a real temp tree — the half `StalenessVerdictSpec`
/// cannot cover, since the mtime ordering comes from the filesystem.
pub const ScanStepSpec = struct {
    pub const on_disk = struct {
        test "a fresh output beats an older input" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const io = config.globalIo();
            try tmp.dir.writeFile(io, .{ .sub_path = "in.txt", .data = "a" });
            try tmp.dir.writeFile(io, .{ .sub_path = "out.txt", .data = "b" });

            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(io, &buf)];

            const s = scanStep(std.testing.allocator, root, .{
                .run = &.{"true"},
                .inputs = &.{"in.txt"},
                .outputs = &.{"out.txt"},
            });
            try expect.toBeTrue(s.has_inputs and s.has_outputs);
            try expect.toBeFalse(s.missing_path);
            // `out.txt` was written second, so it is >= `in.txt`.
            try std.testing.expectEqual(Staleness.fresh, s.verdict());
        }

        test "a missing output is stale" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const io = config.globalIo();
            try tmp.dir.writeFile(io, .{ .sub_path = "in.txt", .data = "a" });

            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(io, &buf)];

            const s = scanStep(std.testing.allocator, root, .{
                .run = &.{"true"},
                .inputs = &.{"in.txt"},
                .outputs = &.{"nope.txt"},
            });
            try expect.toBeTrue(s.missing_path);
            try std.testing.expectEqual(Staleness.stale, s.verdict());
        }

        test "declaring only outputs never skips" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const io = config.globalIo();
            try tmp.dir.writeFile(io, .{ .sub_path = "out.txt", .data = "b" });

            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(io, &buf)];

            const s = scanStep(std.testing.allocator, root, .{
                .run = &.{"true"},
                .outputs = &.{"out.txt"},
            });
            try std.testing.expectEqual(Staleness.unknown, s.verdict());
        }
    };
};

/// The second half of the freshness key: the RECIPE. `Scan` sees only the
/// declared files, so editing `.run` moved no mtime and the step was
/// skipped as "up to date" while the build consumed the artifact the old
/// command produced — the silent-staleness failure this feature exists to
/// kill, arriving through the freshness check itself.
pub const RecipeFingerprintSpec = struct {
    pub const hashing = struct {
        test "the same declaration hashes the same" {
            const a: Step = .{ .run = &.{ "gen", "--fast" }, .inputs = &.{"a.txt"}, .outputs = &.{"o.png"} };
            try std.testing.expectEqual(recipeHash(a), recipeHash(a));
        }

        test "a changed flag changes the recipe hash" {
            const before: Step = .{ .run = &.{ "gen", "--fast" }, .inputs = &.{"a.txt"}, .outputs = &.{"o.png"} };
            const after: Step = .{ .run = &.{ "gen", "--fast", "--rgba" }, .inputs = &.{"a.txt"}, .outputs = &.{"o.png"} };
            try expect.toBeTrue(recipeHash(before) != recipeHash(after));
        }

        test "argv element boundaries matter" {
            const a: Step = .{ .run = &.{ "ab", "c" } };
            const b: Step = .{ .run = &.{ "a", "bc" } };
            try expect.toBeTrue(recipeHash(a) != recipeHash(b));
        }

        test "adding a declared input is a recipe change" {
            const a: Step = .{ .run = &.{"gen"}, .inputs = &.{"a.txt"}, .outputs = &.{"o.png"} };
            const b: Step = .{ .run = &.{"gen"}, .inputs = &.{ "a.txt", "gen.py" }, .outputs = &.{"o.png"} };
            try expect.toBeTrue(recipeHash(a) != recipeHash(b));
        }

        test "the outputs key identifies the step, order-independently" {
            const a: Step = .{ .run = &.{"gen"}, .outputs = &.{ "o.png", "o.json" } };
            const b: Step = .{ .run = &.{"other"}, .outputs = &.{ "o.json", "o.png" } };
            try std.testing.expectEqual(outputsKey(a), outputsKey(b));
        }

        test "a different output set is a different key" {
            const a: Step = .{ .run = &.{"gen"}, .outputs = &.{"o.png"} };
            const b: Step = .{ .run = &.{"gen"}, .outputs = &.{"p.png"} };
            try expect.toBeTrue(outputsKey(a) != outputsKey(b));
        }

        test "a path declared twice does not cancel out to the empty key" {
            const dup: Step = .{ .run = &.{"gen"}, .outputs = &.{ "o.png", "o.png" } };
            try expect.toBeTrue(outputsKey(dup) != outputsKey(.{ .run = &.{"gen"} }));
        }
    };

    /// The pure decision. Every ambiguous case must resolve to "run".
    pub const decision = struct {
        const current = Scan{
            .has_inputs = true,
            .has_outputs = true,
            .newest_input_ns = 100,
            .oldest_output_ns = 200,
        };

        test "current files plus a matching recipe is fresh" {
            try expect.toBeTrue(isFresh(current, 7, 7));
        }

        test "current files but a CHANGED recipe is not fresh" {
            try expect.toBeFalse(isFresh(current, 7, 8));
        }

        test "no recorded recipe is not fresh" {
            try expect.toBeFalse(isFresh(current, null, 7));
        }

        test "a matching recipe cannot rescue stale files" {
            const stale = Scan{
                .has_inputs = true,
                .has_outputs = true,
                .newest_input_ns = 300,
                .oldest_output_ns = 200,
            };
            try expect.toBeFalse(isFresh(stale, 7, 7));
        }

        test "only steps declaring both halves are tracked" {
            try expect.toBeTrue(isTracked(.{ .run = &.{"g"}, .inputs = &.{"i"}, .outputs = &.{"o"} }));
            try expect.toBeFalse(isTracked(.{ .run = &.{"g"}, .inputs = &.{"i"} }));
            try expect.toBeFalse(isTracked(.{ .run = &.{"g"}, .outputs = &.{"o"} }));
            try expect.toBeFalse(isTracked(.{ .run = &.{"g"} }));
        }
    };

    /// The store's text format. Total: a corrupt file must degrade to
    /// "re-run", never to a failed build.
    pub const store_format = struct {
        test "render then parse round-trips" {
            var store: RecipeStore = .{};
            defer store.deinit(std.testing.allocator);
            store.record(std.testing.allocator, 0xdead, 0xbeef);
            store.record(std.testing.allocator, 1, 2);

            const text = try store.render(std.testing.allocator);
            defer std.testing.allocator.free(text);

            var back = RecipeStore.parse(std.testing.allocator, text);
            defer back.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(?u64, 0xbeef), back.recordedFor(0xdead));
            try std.testing.expectEqual(@as(?u64, 2), back.recordedFor(1));
            try std.testing.expectEqual(@as(?u64, null), back.recordedFor(3));
        }

        test "recording the same key twice overwrites rather than appends" {
            var store: RecipeStore = .{};
            defer store.deinit(std.testing.allocator);
            store.record(std.testing.allocator, 5, 1);
            store.record(std.testing.allocator, 5, 2);
            try std.testing.expectEqual(@as(usize, 1), store.entries.items.len);
            try std.testing.expectEqual(@as(?u64, 2), store.recordedFor(5));
        }

        test "garbage lines are skipped, not fatal" {
            var store = RecipeStore.parse(std.testing.allocator,
                \\# a comment
                \\not hex at all
                \\zzzz 1
                \\
                \\000000000000000a 000000000000000b
                \\
            );
            defer store.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 1), store.entries.items.len);
            try std.testing.expectEqual(@as(?u64, 0xb), store.recordedFor(0xa));
        }

        test "prune drops entries no declared step produces" {
            var store: RecipeStore = .{};
            defer store.deinit(std.testing.allocator);
            const kept: Step = .{ .run = &.{"g"}, .inputs = &.{"i"}, .outputs = &.{"o"} };
            store.record(std.testing.allocator, outputsKey(kept), 1);
            store.record(std.testing.allocator, 0xdeadbeef, 2);

            store.prune(&.{kept});
            try std.testing.expectEqual(@as(usize, 1), store.entries.items.len);
            try std.testing.expectEqual(@as(?u64, 1), store.recordedFor(outputsKey(kept)));
        }

        test "a missing state file loads as an empty store" {
            var store = RecipeStore.load(std.testing.allocator, "/no/such/project/dir");
            defer store.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 0), store.entries.items.len);
        }
    };

    /// The regression itself, end to end: same files, same mtimes, only
    /// `.run` edited. POSIX only.
    pub const end_to_end = struct {
        test "changing .run alone forces a re-run" {
            if (builtin.os.tag == .windows) return error.SkipZigTest;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const io = config.globalIo();
            try tmp.dir.writeFile(io, .{ .sub_path = "src.txt", .data = "in" });
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(io, &buf)];

            // Run 1: produces `gen.txt` with the "v1" recipe.
            try runAll(std.testing.allocator, root, &.{.{
                .run = &.{ "/bin/sh", "-c", "printf v1 > gen.txt" },
                .inputs = &.{"src.txt"},
                .outputs = &.{"gen.txt"},
            }}, .{});
            {
                const got = try tmp.dir.readFileAlloc(io, "gen.txt", std.testing.allocator, .limited(64));
                defer std.testing.allocator.free(got);
                try std.testing.expectEqualStrings("v1", got);
            }

            // Run 2: SAME declared files, all mtimes untouched, only the
            // command changed. Before the recipe fingerprint this was
            // skipped as "up to date" and the build consumed `v1`.
            try runAll(std.testing.allocator, root, &.{.{
                .run = &.{ "/bin/sh", "-c", "printf v2 > gen.txt" },
                .inputs = &.{"src.txt"},
                .outputs = &.{"gen.txt"},
            }}, .{});
            {
                const got = try tmp.dir.readFileAlloc(io, "gen.txt", std.testing.allocator, .limited(64));
                defer std.testing.allocator.free(got);
                try std.testing.expectEqualStrings("v2", got);
            }

            // Run 3: back to the v2 recipe, nothing else touched — the
            // recorded fingerprint now matches, so it is skipped again.
            try tmp.dir.writeFile(io, .{ .sub_path = "gen.txt", .data = "sentinel" });
            try runAll(std.testing.allocator, root, &.{.{
                .run = &.{ "/bin/sh", "-c", "printf v2 > gen.txt" },
                .inputs = &.{"src.txt"},
                .outputs = &.{"gen.txt"},
            }}, .{});
            const got = try tmp.dir.readFileAlloc(io, "gen.txt", std.testing.allocator, .limited(64));
            defer std.testing.allocator.free(got);
            try std.testing.expectEqualStrings("sentinel", got);
        }

        test "the fingerprint is persisted under .labelle/" {
            if (builtin.os.tag == .windows) return error.SkipZigTest;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const io = config.globalIo();
            try tmp.dir.writeFile(io, .{ .sub_path = "src.txt", .data = "in" });
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(io, &buf)];

            const step: Step = .{
                .run = &.{ "/bin/sh", "-c", "printf out > gen.txt" },
                .inputs = &.{"src.txt"},
                .outputs = &.{"gen.txt"},
            };
            try runAll(std.testing.allocator, root, &.{step}, .{});

            var store = RecipeStore.load(std.testing.allocator, root);
            defer store.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(?u64, recipeHash(step)), store.recordedFor(outputsKey(step)));
        }

        test "an untracked step writes no state file" {
            if (builtin.os.tag == .windows) return error.SkipZigTest;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const io = config.globalIo();
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(io, &buf)];

            try runAll(std.testing.allocator, root, &.{.{
                .run = &.{ "/bin/sh", "-c", "printf ok > ran.txt" },
            }}, .{});

            try std.testing.expectError(
                error.FileNotFound,
                tmp.dir.statFile(io, ".labelle/" ++ state_file_name, .{}),
            );
        }
    };
};

pub const RenderArgvSpec = struct {
    pub const formatting = struct {
        test "joins argv with spaces" {
            const got = try renderArgv(std.testing.allocator, &.{ "python3", "tools/gen.py" });
            defer std.testing.allocator.free(got);
            try std.testing.expectEqualStrings("python3 tools/gen.py", got);
        }

        test "quotes an element containing a space" {
            const got = try renderArgv(std.testing.allocator, &.{ "cp", "my file.txt", "b" });
            defer std.testing.allocator.free(got);
            try std.testing.expectEqualStrings("cp \"my file.txt\" b", got);
        }

        test "escapes an embedded double quote so the quoting stays balanced" {
            const got = try renderArgv(std.testing.allocator, &.{ "echo", "say \"hi\"" });
            defer std.testing.allocator.free(got);
            try std.testing.expectEqualStrings("echo \"say \\\"hi\\\"\"", got);
        }

        test "an argument that is only a quote round-trips readably" {
            const got = try renderArgv(std.testing.allocator, &.{ "x", "\"" });
            defer std.testing.allocator.free(got);
            try std.testing.expectEqualStrings("x \"\\\"\"", got);
        }

        test "a backslash is left alone (Windows paths render as written)" {
            const got = try renderArgv(std.testing.allocator, &.{ "run", "C:\\a b\\gen.exe" });
            defer std.testing.allocator.free(got);
            try std.testing.expectEqualStrings("run \"C:\\a b\\gen.exe\"", got);
        }

        test "renders an empty argv as an empty string" {
            const got = try renderArgv(std.testing.allocator, &.{});
            defer std.testing.allocator.free(got);
            try std.testing.expectEqualStrings("", got);
        }
    };
};

pub const FailureDetailSpec = struct {
    pub const naming = struct {
        test "names the 1-based step index and the total" {
            var buf: [progress.max_detail_len]u8 = undefined;
            try std.testing.expectEqualStrings("prebuild step 2/3 failed", failureDetail(&buf, 1, 3));
        }
    };
};

/// The contract that makes this feature safe to land: a project with no
/// `.prebuild` must behave byte-identically. `runAll` on an empty slice
/// must not read the environment, stat anything, print anything, or
/// spawn anything — it just returns.
pub const NoPrebuildIsInertSpec = struct {
    pub const empty_slice = struct {
        test "runAll on zero steps succeeds and allocates nothing" {
            // A failing allocator proves no allocation happens on the
            // default path (an env read or an argv render would allocate).
            try runAll(std.testing.failing_allocator, "/no/such/dir", &.{}, .{});
        }

        test "the default ProjectConfig declares no prebuild steps" {
            const cfg = project_config.ProjectConfig{ .name = "x" };
            try std.testing.expectEqual(@as(usize, 0), cfg.prebuild.len);
        }
    };
};

/// End-to-end execution, POSIX only (the fixtures are `/bin/sh`).
/// `runStep` returns the child's exit code verbatim — that code is what
/// the CLI then exits with, so a tool's `exit 3` must not become `1`.
pub const RunStepSpec = struct {
    pub const exit_codes = struct {
        test "a successful step returns 0" {
            if (builtin.os.tag == .windows) return error.SkipZigTest;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(config.globalIo(), &buf)];

            const code = try runStep(std.testing.allocator, root, .{
                .run = &.{ "/bin/sh", "-c", "exit 0" },
            }, .{});
            try std.testing.expectEqual(@as(u8, 0), code);
        }

        test "a failing step's exact exit code is returned, not collapsed to 1" {
            if (builtin.os.tag == .windows) return error.SkipZigTest;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(config.globalIo(), &buf)];

            const code = try runStep(std.testing.allocator, root, .{
                .run = &.{ "/bin/sh", "-c", "exit 3" },
            }, .{});
            try std.testing.expectEqual(@as(u8, 3), code);
        }
    };

    pub const cwd_is_project_root = struct {
        test "the step runs with the project root as cwd" {
            if (builtin.os.tag == .windows) return error.SkipZigTest;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const io = config.globalIo();
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(io, &buf)];

            // Writing a RELATIVE path only lands in the project root if
            // cwd was set; otherwise it lands in the test runner's cwd.
            const code = try runStep(std.testing.allocator, root, .{
                .run = &.{ "/bin/sh", "-c", "printf ok > made-here.txt" },
            }, .{});
            try std.testing.expectEqual(@as(u8, 0), code);

            const data = try tmp.dir.readFileAlloc(io, "made-here.txt", std.testing.allocator, .limited(64));
            defer std.testing.allocator.free(data);
            try std.testing.expectEqualStrings("ok", data);
        }
    };

    pub const no_shell_interpretation = struct {
        test "argv is passed verbatim — no shell metacharacter expansion" {
            if (builtin.os.tag == .windows) return error.SkipZigTest;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const io = config.globalIo();
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(io, &buf)];

            // If the CLI ran this through a shell, `> pwned.txt` would
            // redirect and `pwned.txt` would exist. It must not: the
            // trailing elements are literal arguments to `printf`.
            const code = try runStep(std.testing.allocator, root, .{
                .run = &.{ "/bin/sh", "-c", "printf %s \"$1\" > literal.txt", "sh", "> pwned.txt" },
            }, .{});
            try std.testing.expectEqual(@as(u8, 0), code);

            const data = try tmp.dir.readFileAlloc(io, "literal.txt", std.testing.allocator, .limited(64));
            defer std.testing.allocator.free(data);
            try std.testing.expectEqualStrings("> pwned.txt", data);
            try std.testing.expectError(
                error.FileNotFound,
                tmp.dir.statFile(io, "pwned.txt", .{}),
            );
        }
    };

    pub const spawn_failure = struct {
        test "a missing program reports PrebuildSpawnFailed, not a crash" {
            if (builtin.os.tag == .windows) return error.SkipZigTest;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(config.globalIo(), &buf)];

            try std.testing.expectError(error.PrebuildSpawnFailed, runStep(
                std.testing.allocator,
                root,
                .{ .run = &.{"/definitely/not/a/real/program-xyzzy"} },
                .{},
            ));
        }
    };
};

/// `runAll`'s ordering + skipping, observed through the files the steps
/// leave behind. POSIX only.
pub const RunAllSpec = struct {
    pub const ordering = struct {
        test "steps run in declared order" {
            if (builtin.os.tag == .windows) return error.SkipZigTest;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const io = config.globalIo();
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(io, &buf)];

            try runAll(std.testing.allocator, root, &.{
                .{ .run = &.{ "/bin/sh", "-c", "printf a >> order.txt" } },
                .{ .run = &.{ "/bin/sh", "-c", "printf b >> order.txt" } },
                .{ .run = &.{ "/bin/sh", "-c", "printf c >> order.txt" } },
            }, .{});

            const data = try tmp.dir.readFileAlloc(io, "order.txt", std.testing.allocator, .limited(64));
            defer std.testing.allocator.free(data);
            try std.testing.expectEqualStrings("abc", data);
        }

        // Freshness now needs BOTH halves — current mtimes and a recorded
        // recipe — so the skip only happens on a SECOND run, once the
        // first has recorded what produced `gen.txt`. Run 1 proves the
        // conservative default (no record = run), run 2 the skip.
        test "a step whose outputs are current is skipped on the next run" {
            if (builtin.os.tag == .windows) return error.SkipZigTest;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const io = config.globalIo();
            try tmp.dir.writeFile(io, .{ .sub_path = "src.txt", .data = "in" });
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(io, &buf)];

            const step: Step = .{
                .run = &.{ "/bin/sh", "-c", "printf out > gen.txt; printf a >> ran.txt" },
                .inputs = &.{"src.txt"},
                .outputs = &.{"gen.txt"},
            };

            // Run 1: no output yet, and no recorded recipe — must run.
            try runAll(std.testing.allocator, root, &.{step}, .{});
            const first = try tmp.dir.readFileAlloc(io, "ran.txt", std.testing.allocator, .limited(64));
            defer std.testing.allocator.free(first);
            try std.testing.expectEqualStrings("a", first);

            // Run 2: `gen.txt` is newer than `src.txt` AND the recipe is
            // unchanged — must be skipped, so `ran.txt` does not grow.
            try runAll(std.testing.allocator, root, &.{step}, .{});
            const second = try tmp.dir.readFileAlloc(io, "ran.txt", std.testing.allocator, .limited(64));
            defer std.testing.allocator.free(second);
            try std.testing.expectEqualStrings("a", second);
        }

        test "a step with no inputs/outputs runs unconditionally" {
            if (builtin.os.tag == .windows) return error.SkipZigTest;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const io = config.globalIo();
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(io, &buf)];

            try runAll(std.testing.allocator, root, &.{.{
                .run = &.{ "/bin/sh", "-c", "printf ran > ran.txt" },
            }}, .{});

            const data = try tmp.dir.readFileAlloc(io, "ran.txt", std.testing.allocator, .limited(64));
            defer std.testing.allocator.free(data);
            try std.testing.expectEqualStrings("ran", data);
        }
    };

    pub const invalid_step = struct {
        test "an invalid step fails the build before anything is spawned" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(config.globalIo(), &buf)];

            try std.testing.expectError(error.InvalidPrebuildStep, runAll(
                std.testing.allocator,
                root,
                &.{.{ .run = &.{} }},
                .{},
            ));
        }

        // The regression the whole-slice `validateAll` pass exists for:
        // validating inside the execution loop let step 1 mutate the
        // project before step 2 was found to be malformed.
        test "a malformed LATER step stops the valid first step from running" {
            if (builtin.os.tag == .windows) return error.SkipZigTest;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const io = config.globalIo();
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(io, &buf)];

            try std.testing.expectError(error.InvalidPrebuildStep, runAll(
                std.testing.allocator,
                root,
                &.{
                    .{ .run = &.{ "/bin/sh", "-c", "printf ran > first.txt" } },
                    .{ .run = &.{} },
                },
                .{},
            ));

            // The mutating first step must NOT have run.
            try std.testing.expectError(
                error.FileNotFound,
                tmp.dir.statFile(io, "first.txt", .{}),
            );
        }

        test "an empty argv[0] in a later step is caught the same way" {
            if (builtin.os.tag == .windows) return error.SkipZigTest;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const io = config.globalIo();
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(io, &buf)];

            try std.testing.expectError(error.InvalidPrebuildStep, runAll(
                std.testing.allocator,
                root,
                &.{
                    .{ .run = &.{ "/bin/sh", "-c", "printf ran > first.txt" } },
                    .{ .run = &.{ "", "x" } },
                },
                .{},
            ));
            try std.testing.expectError(
                error.FileNotFound,
                tmp.dir.statFile(io, "first.txt", .{}),
            );
        }
    };

    /// `wasm serve --watch` re-runs the steps on every watched rebuild and
    /// must survive a failing one — the server stays up and the browser is
    /// not reloaded onto a stale bundle.
    pub const non_fatal_mode = struct {
        test "a failing step returns an error instead of exiting the process" {
            if (builtin.os.tag == .windows) return error.SkipZigTest;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(config.globalIo(), &buf)];

            try std.testing.expectError(error.PrebuildStepFailed, runAll(
                std.testing.allocator,
                root,
                &.{.{ .run = &.{ "/bin/sh", "-c", "exit 7" } }},
                .{ .fatal_on_step_failure = false },
            ));
        }

        test "a succeeding step still runs normally in non-fatal mode" {
            if (builtin.os.tag == .windows) return error.SkipZigTest;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const io = config.globalIo();
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(io, &buf)];

            try runAll(std.testing.allocator, root, &.{.{
                .run = &.{ "/bin/sh", "-c", "printf ok > watched.txt" },
            }}, .{ .fatal_on_step_failure = false });

            const data = try tmp.dir.readFileAlloc(io, "watched.txt", std.testing.allocator, .limited(64));
            defer std.testing.allocator.free(data);
            try std.testing.expectEqualStrings("ok", data);
        }
    };
};

/// The `.prebuild` block must parse out of a real `project.labelle` with
/// the tolerant options the CLI uses, and must stay absent-by-default.
///
/// Parsed into an ARENA, never `std.zon.parse.free`d: `ProjectConfig`'s
/// defaults are comptime slices in read-only memory (`core_version`,
/// `layers`, ...), and the recursive free walks into every field a
/// document omitted. `config.readProjectConfigImpl` uses an arena for
/// exactly this reason.
pub const ParsePrebuildSpec = struct {
    pub const from_zon = struct {
        test "parses the shape the issue proposes" {
            @setEvalBranchQuota(10000);
            const src =
                \\.{
                \\    .name = "demo",
                \\    .prebuild = .{
                \\        .{
                \\            .run = .{ "python3", "tools/gen_tiles.py" },
                \\            .inputs = .{ "tools/OverworldTileset.tsx" },
                \\            .outputs = .{ "assets/out.png", "scripts/table.zig" },
                \\        },
                \\    },
                \\}
            ;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const cfg = try std.zon.parse.fromSliceAlloc(
                project_config.ProjectConfig,
                arena.allocator(),
                src,
                null,
                .{ .ignore_unknown_fields = true },
            );

            try std.testing.expectEqual(@as(usize, 1), cfg.prebuild.len);
            try std.testing.expectEqualStrings("python3", cfg.prebuild[0].run[0]);
            try std.testing.expectEqualStrings("tools/gen_tiles.py", cfg.prebuild[0].run[1]);
            try std.testing.expectEqual(@as(usize, 1), cfg.prebuild[0].inputs.len);
            try std.testing.expectEqual(@as(usize, 2), cfg.prebuild[0].outputs.len);
            try expect.toBeNull(validate(cfg.prebuild[0]));
        }

        test "inputs/outputs are optional" {
            @setEvalBranchQuota(10000);
            const src =
                \\.{
                \\    .name = "demo",
                \\    .prebuild = .{ .{ .run = .{ "make", "assets" } } },
                \\}
            ;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const cfg = try std.zon.parse.fromSliceAlloc(
                project_config.ProjectConfig,
                arena.allocator(),
                src,
                null,
                .{ .ignore_unknown_fields = true },
            );

            try std.testing.expectEqual(@as(usize, 0), cfg.prebuild[0].inputs.len);
            try std.testing.expectEqual(@as(usize, 0), cfg.prebuild[0].outputs.len);
        }

        test "a project without .prebuild parses to zero steps" {
            @setEvalBranchQuota(10000);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const cfg = try std.zon.parse.fromSliceAlloc(
                project_config.ProjectConfig,
                arena.allocator(),
                ".{ .name = \"demo\" }",
                null,
                .{ .ignore_unknown_fields = true },
            );
            try std.testing.expectEqual(@as(usize, 0), cfg.prebuild.len);
        }
    };
};
