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

    for (steps, 0..) |step, i| {
        // Tracked as an optional rather than by comparing the rendered
        // text to the placeholder: a project may legitimately declare
        // `.run = .{"<command>"}`, and a contents check would then skip
        // the free.
        const rendered_owned = renderArgv(allocator, step.run) catch null;
        defer if (rendered_owned) |r| allocator.free(r);
        const rendered: []const u8 = rendered_owned orelse "<command>";

        if (scanStep(allocator, project_dir, step).verdict() == .fresh) {
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

        test "a step whose outputs are current is skipped" {
            if (builtin.os.tag == .windows) return error.SkipZigTest;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const io = config.globalIo();
            try tmp.dir.writeFile(io, .{ .sub_path = "src.txt", .data = "in" });
            try tmp.dir.writeFile(io, .{ .sub_path = "gen.txt", .data = "out" });
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root = buf[0..try tmp.dir.realPath(io, &buf)];

            try runAll(std.testing.allocator, root, &.{.{
                .run = &.{ "/bin/sh", "-c", "printf ran > ran.txt" },
                .inputs = &.{"src.txt"},
                .outputs = &.{"gen.txt"},
            }}, .{});

            // The step must NOT have run: `gen.txt` is newer than `src.txt`.
            try std.testing.expectError(
                error.FileNotFound,
                tmp.dir.statFile(io, "ran.txt", .{}),
            );
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
