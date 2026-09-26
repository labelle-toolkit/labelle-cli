//! Command-execution pipeline for the labelle CLI (#311). Extracted from
//! cli.zig `main` so the dispatcher stays small: this owns the
//! generate -> build -> run flow and the docker / wasm / ios / android
//! branches, plus the two execution helpers that go with it
//! (WasmRebuildCtx for `wasm serve --watch`; the export output-path
//! resolvers). Behavior is identical to when this lived in `main`.
const std = @import("std");
const builtin = @import("builtin");
const project_config = @import("project_config.zig");
const upgrade = @import("upgrade.zig");
const config = @import("config.zig");
const compatibility = @import("compatibility.zig");
const lockfile = @import("lockfile.zig");
const runner = @import("runner.zig");
const assembler = @import("assembler.zig");
const assembler_proc = @import("assembler_proc.zig");
const emsdk_toolchain = @import("emsdk_toolchain.zig");
const emsdk_activate = @import("emsdk_activate.zig");
const python_provision = @import("python_provision.zig");
const prebuild = @import("prebuild.zig");
const material_toolchain = @import("material_toolchain.zig");
const bake_mod = @import("bake.zig");
const docker = @import("docker.zig");
const serve = @import("serve.zig");
const export_mod = @import("export.zig");
const ios = @import("ios.zig");
const android = @import("android.zig");
const util = @import("util.zig");
const progress = @import("progress.zig");
const astc_cmd = @import("../astc/cmd.zig");
const sdl_provision = @import("sdl_provision.zig");
const bundle = @import("bundle.zig");
const linux_desktop = @import("linux_desktop.zig");
const args_mod = @import("args.zig");
const screenshot_format = @import("screenshot_format.zig");
const provider_contract = @import("provider_contract.zig");
const provider_dispatch = @import("provider_dispatch.zig");
const provider_github = @import("provider_github.zig");
const provider_hooks = @import("provider_hooks.zig");
const provider_targets = @import("provider_targets.zig");
const ParsedArgs = args_mod.ParsedArgs;
const appendRunForwardedArgs = args_mod.appendRunForwardedArgs;
const resolveAndroidBackend = args_mod.resolveAndroidBackend;

/// Rebuild context for `wasm serve --watch` (cli#208). Bundles the
/// generate+build inputs the initial pipeline computed so the serve
/// loop's watcher thread can re-run them on a source change. Passed to
/// `serve.serveAndOpen` as an opaque `*anyopaque` + a static `rebuild`
/// entry point matching `serve.RebuildFn`.
const WasmRebuildCtx = struct {
    allocator: std.mem.Allocator,
    asm_bin: assembler_proc.Assembler,
    project_dir: []const u8,
    platform_tag: []const u8,
    backend_tag: []const u8,
    output_dir: []const u8,
    target_dir: []const u8,
    zig_args: []const []const u8,
    zig_env: ?*const std.process.Environ.Map,
    /// The project's declared `.prebuild` steps (cli#355), borrowed from
    /// the parse arena. A watched rebuild must re-run them: they are what
    /// turn an edited `.tsx`/generator into the atlas or `.zig` table the
    /// regeneration below then reads, so skipping them would serve a
    /// "successful" rebuild made of STALE generated assets — the exact
    /// silent-staleness bug the hook exists to kill.
    prebuild_steps: []const prebuild.Step,
    /// Options for those steps. `fatal_on_step_failure = false` here: a
    /// failing step in watch mode must report and keep the server alive,
    /// like a failing `generate` or `zig build` already does — not exit
    /// the process out from under the serve loop.
    prebuild_opts: prebuild.Options,
    /// The shader-compiler override gate, run AFTER the prebuild hooks and
    /// BEFORE generation on every rebuild — the same function the cold
    /// pipeline runs before its `assembler generate`. It is a field only so
    /// the stage test below can supply the override value without touching
    /// the process environment; production never overrides the default.
    shader_preflight: *const fn (std.mem.Allocator, []const u8) anyerror!void = material_toolchain.preflight,
    /// Provider lifecycle hooks (contract §6). A watched rebuild re-runs the
    /// SAME `generate` and `build` plans the cold pipeline ran, in the same
    /// before / core-or-replace / after order — hooks that generate inputs
    /// or post-process the WASM output would otherwise serve stale or
    /// incomplete artifacts after the first watched edit, and a `replace`
    /// hook's step would silently fall back to the core operation (Codex P2
    /// on #420). `hooks` is the cold pipeline's site; with no plugins every
    /// plan is empty and no phase runs.
    hooks: *provider_hooks.Site,
    generate_plan: provider_hooks.Plan = .{},
    build_plan: provider_hooks.Plan = .{},
    /// The step output directories of the layout contract, as the cold
    /// pipeline computed them (`provider_hooks.stepOutputDir`).
    generate_out: []const u8 = "",
    build_out: []const u8 = "",
    /// The phase runner. A field only so the plumbing test below can record
    /// the phases without a host compiler; production never overrides it.
    run_hook_phase: *const fn (*provider_hooks.Site, []const provider_hooks.Planned, provider_contract.Step, provider_contract.Phase, []const u8) anyerror!u8 = provider_hooks.runPhase,

    /// Which stage a rebuild stopped at. Ordered as the stages run; the
    /// watch loop only needs the bool, but the test asserts the ORDER —
    /// that the shader preflight fires before generation is attempted.
    const Stage = error{
        PrebuildFailed,
        ShaderPreflightFailed,
        HookFailed,
        GenerateFailed,
        FingerprintFailed,
        ZigSpawnFailed,
        BuildFailed,
    };

    /// One hook phase of a watched rebuild. A failing hook (nonzero exit, or
    /// an error resolving the host/pin) stops the rebuild like a failing
    /// core step does: reported, server kept alive, browser not reloaded.
    fn hookPhase(self: *WasmRebuildCtx, list: []const provider_hooks.Planned, step: provider_contract.Step, phase: provider_contract.Phase, output_dir: []const u8) Stage!void {
        if (list.len == 0) return;
        const code = self.run_hook_phase(self.hooks, list, step, phase, output_dir) catch |err| {
            std.debug.print("labelle: rebuild {s} {s} hook failed ({s})\n", .{ @tagName(phase), @tagName(step), @errorName(err) });
            return error.HookFailed;
        };
        if (code != 0) return error.HookFailed;
    }

    /// Re-run prebuild → generate → fixFingerprints → `zig build`. Returns
    /// true only on a clean rebuild; on any failure it prints the error
    /// (keeping the server alive) and returns false so the browser is NOT
    /// reloaded onto a broken build.
    fn rebuild(ctx_ptr: *anyopaque) bool {
        const self: *WasmRebuildCtx = @ptrCast(@alignCast(ctx_ptr));
        self.rebuildStaged() catch return false;
        return true;
    }

    fn rebuildStaged(self: *WasmRebuildCtx) Stage!void {
        const a = self.allocator;

        // 0. Re-run the declared prebuild steps, ahead of generation just
        //    as the initial pipeline does. Steps that declare `.inputs` +
        //    `.outputs` are skipped while fresh, so the common watch
        //    iteration costs a few stats — and their declared `.outputs`
        //    are excluded from the watch signature (`ignore_files` at the
        //    `serveAndOpen` call below), so the run that DOES regenerate
        //    them no longer looks like a fresh edit on the next poll.
        //    A step that declares no `.outputs` runs on every rebuild by
        //    design and is not excluded from anything; if such a step
        //    also writes into the watched tree it retriggers the watcher
        //    in a loop, so declare `.outputs` for generators used under
        //    `--watch`.
        prebuild.runAll(a, self.project_dir, self.prebuild_steps, self.prebuild_opts) catch |err| {
            std.debug.print("labelle: rebuild prebuild step failed ({s})\n", .{@errorName(err)});
            return error.PrebuildFailed;
        };

        // 0b. Gate the shader-compiler override AFTER the hooks (a hook may
        //     be what creates `materials/`) and BEFORE generation. The cold
        //     pipeline runs this once at startup; a project that gains
        //     `materials/` while being watched would otherwise skip it and
        //     hit the opaque compiler failure this gate exists to replace.
        self.shader_preflight(a, self.project_dir) catch |err| {
            std.debug.print("labelle: rebuild stopped before generate: shader compiler override rejected ({s})\n", .{@errorName(err)});
            return error.ShaderPreflightFailed;
        };

        // 1. Regenerate — scene/prefab/script *structure* (new files, added
        //    components) can change, not just @embedFile'd content. Wrapped
        //    in the `generate` hook phases exactly like the cold pipeline.
        try self.hookPhase(self.generate_plan.before, .generate, .before, self.generate_out);
        if (self.generate_plan.replace) |replacement| {
            try self.hookPhase(&.{replacement}, .generate, .replace, self.generate_out);
        } else {
            assembler_proc.generate(self.asm_bin, a, self.project_dir, self.platform_tag, self.backend_tag) catch |err| {
                std.debug.print("labelle: rebuild generate failed ({s})\n", .{@errorName(err)});
                return error.GenerateFailed;
            };
            // 2. `generate` rewrites build.zig with a placeholder fingerprint;
            //    re-fix it before building.
            runner.fixFingerprints(a, self.project_dir, self.output_dir) catch |err| {
                std.debug.print("labelle: rebuild fingerprint fix failed ({s})\n", .{@errorName(err)});
                return error.FingerprintFailed;
            };
        }
        try self.hookPhase(self.generate_plan.after, .generate, .after, self.generate_out);
        // 3. Rebuild the WASM bundle (captured output so a compile error
        //    surfaces in the terminal without killing the serve loop),
        //    inside the `build` hook phases.
        try self.hookPhase(self.build_plan.before, .build, .before, self.build_out);
        if (self.build_plan.replace) |replacement| {
            try self.hookPhase(&.{replacement}, .build, .replace, self.build_out);
        } else {
            try self.coreBuild();
        }
        try self.hookPhase(self.build_plan.after, .build, .after, self.build_out);
    }

    fn coreBuild(self: *WasmRebuildCtx) Stage!void {
        const a = self.allocator;
        const res = runner.runZigWithEnv(a, self.target_dir, self.zig_args, self.zig_env) catch |err| {
            std.debug.print("labelle: rebuild could not spawn zig ({s})\n", .{@errorName(err)});
            return error.ZigSpawnFailed;
        };
        defer a.free(res.stdout);
        defer a.free(res.stderr);
        switch (res.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("labelle: rebuild failed:\n{s}\n", .{res.stderr});
                return error.BuildFailed;
            },
            else => {
                std.debug.print("labelle: rebuild terminated abnormally\n{s}\n", .{res.stderr});
                return error.BuildFailed;
            },
        }
    }

    test "watched rebuild gates the shader override after hooks and before generate" {
        if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
        const a = std.testing.allocator;
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "project");
        const project = try tmp.dir.realPathFileAlloc(io, "project", a);
        defer a.free(project);

        // Production wiring: the default IS the cold pipeline's preflight,
        // not a copy of it.
        const default_gate = std.meta.fieldInfo(WasmRebuildCtx, .shader_preflight).defaultValue() orelse return error.TestUnexpectedResult;
        try std.testing.expect(default_gate == material_toolchain.preflight);

        const Fixture = struct {
            fn invalidOverride(alloc: std.mem.Allocator, dir: []const u8) anyerror!void {
                // The same gate `preflight` reaches, with the env read
                // replaced by a known-bad value.
                return material_toolchain.preflightWith(alloc, dir, "shaderc", .native);
            }
        };
        // No assembler exists at this path, so reaching generation is
        // observable as GenerateFailed — distinct from the gate firing.
        const asm_path = try a.dupe(u8, "/nonexistent/labelle-assembler-probe");
        defer a.free(asm_path);
        var site = testSite(a, project);
        var ctx = WasmRebuildCtx{
            .allocator = a,
            .asm_bin = .{ .path = asm_path },
            .project_dir = project,
            .platform_tag = "wasm",
            .backend_tag = "bgfx",
            .output_dir = project,
            .target_dir = project,
            .zig_args = &.{},
            .zig_env = null,
            .prebuild_steps = &.{},
            .prebuild_opts = .{ .fatal_on_step_failure = false },
            .shader_preflight = Fixture.invalidOverride,
            .hooks = &site,
        };

        // Started WITHOUT materials/: the invalid override is not consulted
        // and the rebuild proceeds to generation (which fails for its own
        // reason here). This is the cold-start shape that skipped the gate.
        try std.testing.expectError(error.GenerateFailed, ctx.rebuildStaged());

        // materials/ appears while watched: the NEXT rebuild must stop at
        // the preflight, before generation is attempted.
        try tmp.dir.createDirPath(io, "project/materials");
        try std.testing.expectError(error.ShaderPreflightFailed, ctx.rebuildStaged());
        try std.testing.expect(!rebuild(@ptrCast(&ctx)));
    }

    /// A hook site with no providers, for the rebuild tests: the plans are
    /// what the tests supply; nothing here reaches a compiler or a lock.
    fn testSite(a: std.mem.Allocator, project: []const u8) provider_hooks.Site {
        return .{
            .a = a,
            .backing = a,
            .providers = &.{},
            .root = project,
            .cfg = .{ .name = "game" },
            .target = "wasm",
            .optimize = .ReleaseSafe,
            .progress = .off,
            .reporter = null,
        };
    }

    // The serve loop is interactive (it blocks until Ctrl+C), so the hook
    // phases of a WATCHED rebuild are proven here, on the context itself,
    // rather than by the subprocess e2e: the phases run in contract order
    // around the core steps, a `replace` plan stands in for the core step,
    // and a failing hook stops the rebuild before the next stage.
    test "watched rebuild runs the generate and build hook phases in order" {
        if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
        const a = std.testing.allocator;
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "project");
        const project = try tmp.dir.realPathFileAlloc(io, "project", a);
        defer a.free(project);

        // Production wiring: the default runner IS the cold pipeline's.
        const default_runner = std.meta.fieldInfo(WasmRebuildCtx, .run_hook_phase).defaultValue() orelse return error.TestUnexpectedResult;
        try std.testing.expect(default_runner == provider_hooks.runPhase);

        const Spy = struct {
            const Call = struct { step: provider_contract.Step, phase: provider_contract.Phase, id: []const u8, out: []const u8 };
            var calls: [8]Call = undefined;
            var count: usize = 0;
            fn reset() void {
                count = 0;
            }
            fn run(_: *provider_hooks.Site, list: []const provider_hooks.Planned, step: provider_contract.Step, phase: provider_contract.Phase, out: []const u8) anyerror!u8 {
                for (list) |planned| {
                    calls[count] = .{ .step = step, .phase = phase, .id = planned.hook.id, .out = out };
                    count += 1;
                    if (std.mem.eql(u8, planned.hook.id, "fail")) return 7;
                    if (std.mem.eql(u8, planned.hook.id, "unpinned")) return error.RemoteProviderIntegrityRequired;
                }
                return 0;
            }
            fn expectCalls(expected: []const Call) !void {
                try std.testing.expectEqual(expected.len, count);
                for (expected, calls[0..count]) |want, got| {
                    try std.testing.expectEqual(want.step, got.step);
                    try std.testing.expectEqual(want.phase, got.phase);
                    try std.testing.expectEqualStrings(want.id, got.id);
                    try std.testing.expectEqualStrings(want.out, got.out);
                }
            }
        };
        const Fixture = struct {
            var provider: provider_dispatch.Provider = .{
                .dep = .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
                .dir = "/pkg",
                .meta = .{ .name = "pkg", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0" },
                .verified = true,
            };
            fn planned(id: []const u8, step: provider_contract.Step, when: provider_contract.Phase) provider_hooks.Planned {
                return .{
                    .provider = &provider,
                    .hook = .{ .id = id, .step = step, .target = "wasm", .when = when, .build_step = "tool", .executable = "bin/tool" },
                    .qualified = id,
                };
            }
        };

        // No assembler and no compiler exist at these paths, so the core
        // steps are observable as GenerateFailed / ZigSpawnFailed —
        // distinct from any hook outcome.
        const asm_path = try a.dupe(u8, "/nonexistent/labelle-assembler-probe");
        defer a.free(asm_path);
        var site = testSite(a, project);
        var ctx = WasmRebuildCtx{
            .allocator = a,
            .asm_bin = .{ .path = asm_path },
            .project_dir = project,
            .platform_tag = "wasm",
            .backend_tag = "bgfx",
            .output_dir = project,
            .target_dir = project,
            .zig_args = &.{ "/nonexistent/zig-probe", "build" },
            .zig_env = null,
            .prebuild_steps = &.{},
            .prebuild_opts = .{ .fatal_on_step_failure = false },
            .hooks = &site,
            .generate_out = "/gen-out",
            .build_out = "/build-out",
            .run_hook_phase = Spy.run,
        };

        // Empty plans: no phase runs, the core generate is reached.
        Spy.reset();
        try std.testing.expectError(error.GenerateFailed, ctx.rebuildStaged());
        try Spy.expectCalls(&.{});

        // Before-generate hooks run ahead of the core generate, which then
        // fails; nothing after it runs.
        ctx.generate_plan = .{
            .before = &.{Fixture.planned("gen-pre", .generate, .before)},
            .after = &.{Fixture.planned("gen-post", .generate, .after)},
        };
        ctx.build_plan = .{
            .before = &.{Fixture.planned("build-pre", .build, .before)},
            .after = &.{Fixture.planned("build-post", .build, .after)},
        };
        Spy.reset();
        try std.testing.expectError(error.GenerateFailed, ctx.rebuildStaged());
        try Spy.expectCalls(&.{.{ .step = .generate, .phase = .before, .id = "gen-pre", .out = "/gen-out" }});

        // A `replace` on generate stands in for the core generate (and its
        // fingerprint pass), so the rebuild reaches the build phases; the
        // core build then fails to spawn, so `after build` never runs.
        ctx.generate_plan.replace = Fixture.planned("gen-swap", .generate, .replace);
        Spy.reset();
        try std.testing.expectError(error.ZigSpawnFailed, ctx.rebuildStaged());
        try Spy.expectCalls(&.{
            .{ .step = .generate, .phase = .before, .id = "gen-pre", .out = "/gen-out" },
            .{ .step = .generate, .phase = .replace, .id = "gen-swap", .out = "/gen-out" },
            .{ .step = .generate, .phase = .after, .id = "gen-post", .out = "/gen-out" },
            .{ .step = .build, .phase = .before, .id = "build-pre", .out = "/build-out" },
        });

        // A `replace` on build too: the whole rebuild is hooks, in order.
        ctx.build_plan.replace = Fixture.planned("build-swap", .build, .replace);
        Spy.reset();
        try ctx.rebuildStaged();
        try Spy.expectCalls(&.{
            .{ .step = .generate, .phase = .before, .id = "gen-pre", .out = "/gen-out" },
            .{ .step = .generate, .phase = .replace, .id = "gen-swap", .out = "/gen-out" },
            .{ .step = .generate, .phase = .after, .id = "gen-post", .out = "/gen-out" },
            .{ .step = .build, .phase = .before, .id = "build-pre", .out = "/build-out" },
            .{ .step = .build, .phase = .replace, .id = "build-swap", .out = "/build-out" },
            .{ .step = .build, .phase = .after, .id = "build-post", .out = "/build-out" },
        });
        Spy.reset();
        try std.testing.expect(rebuild(@ptrCast(&ctx)));

        // A failing hook (nonzero exit) stops the rebuild at that phase.
        ctx.generate_plan.after = &.{ Fixture.planned("fail", .generate, .after), Fixture.planned("gen-post", .generate, .after) };
        Spy.reset();
        try std.testing.expectError(error.HookFailed, ctx.rebuildStaged());
        try Spy.expectCalls(&.{
            .{ .step = .generate, .phase = .before, .id = "gen-pre", .out = "/gen-out" },
            .{ .step = .generate, .phase = .replace, .id = "gen-swap", .out = "/gen-out" },
            .{ .step = .generate, .phase = .after, .id = "fail", .out = "/gen-out" },
        });
        Spy.reset();
        try std.testing.expect(!rebuild(@ptrCast(&ctx)));

        // So does a hook the runner cannot even start (an unpinned remote
        // provider): the error is reported, not propagated out of the loop.
        ctx.generate_plan.after = &.{};
        ctx.build_plan.before = &.{Fixture.planned("unpinned", .build, .before)};
        Spy.reset();
        try std.testing.expectError(error.HookFailed, ctx.rebuildStaged());
        try std.testing.expectEqual(@as(usize, 3), Spy.count);
        try std.testing.expectEqualStrings("unpinned", Spy.calls[2].id);
    }
};

/// The watcher's `ignore_files` set for `wasm serve --watch`: the absolute
/// paths of every declared prebuild `.outputs` entry, anchored at
/// `project_dir`. Caller owns the list and every slice in it.
///
/// Excluding them is what stops the rebuild callback from tripping its own
/// watcher (cli#355): `watchLoop` records the signature captured BEFORE the
/// callback runs, so a hook's regeneration of `assets/out.png` otherwise
/// looked like a fresh edit on the next poll and fired a second full
/// generate/compile/reload. Same reasoning as the `.labelle/` skip.
///
/// `hooks_enabled` is the `LABELLE_NO_PREBUILD` kill switch, and the reason
/// it is a parameter rather than an assumption. With hooks off, the rebuild
/// callback writes none of these files, so the self-trigger cannot happen —
/// while excluding them anyway broke a documented use of the switch:
/// regenerating those outputs OUT OF BAND (in CI, or by hand) never reached
/// the watch signature, so the browser kept serving the previous build until
/// some unrelated watched file happened to change (cli#361 review). With
/// hooks off, the outputs are ordinary externally managed inputs and belong
/// in the watch set, so the set comes back empty.
///
/// Best-effort: a path that can't be joined is simply not excluded — that
/// costs a redundant rebuild, never a missed one.
fn collectPrebuildIgnorePaths(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    steps: []const prebuild.Step,
    hooks_enabled: bool,
) std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    if (!hooks_enabled) return out;
    for (steps) |step| {
        for (step.outputs) |rel| {
            const p = serve.watchIgnorePath(allocator, project_dir, rel) catch continue;
            out.append(allocator, p) catch {
                allocator.free(p);
                continue;
            };
        }
    }
    return out;
}

/// Resolve the `wasm export --output` value to a path the packager can
/// use. Absolute paths pass through; a relative path is anchored to the
/// project dir so `labelle wasm export ../game --output release` writes
/// under the project, matching where the build output already lives.
/// Caller owns the returned slice.
///
/// SAFETY: the export dir is wiped (`deleteTree`) on every run, so a
/// destructive `--output` — `.`, `..`, the project/cwd root, or any
/// ancestor of them — would delete the user's source tree. Such targets
/// are refused with `error.DestructiveOutputPath` instead. (The
/// complementary "non-empty dir not created by a prior export" guard
/// lives in `export.packageExport`, which owns the deletion.)
fn resolveExportOutput(allocator: std.mem.Allocator, project_dir: []const u8, output: []const u8) ![]const u8 {
    // Normalized form of `output` alone (collapses `.`/`..`; keeps a
    // relative path relative). `resolve` does NOT anchor relatives at the
    // cwd in Zig 0.16, so this is pure path math — no filesystem access,
    // which also keeps it unit-testable.
    const norm = try std.fs.path.resolve(allocator, &.{output});
    defer allocator.free(norm);

    const destructive = if (std.fs.path.isAbsolute(norm))
        // Absolute output: refuse the filesystem root (no parent to scope
        // the wipe) or the project dir / an ancestor of it when the
        // project path is itself absolute. Other absolute dirs are still
        // guarded by the non-empty-without-marker check in packageExport.
        std.fs.path.dirname(norm) == null or
            (std.fs.path.isAbsolute(project_dir) and try absTargetHitsProject(allocator, norm, project_dir))
    else
        // Relative output: refuse the project root itself (`.`) or any
        // path that escapes above it (leading `..`) — wiping either would
        // delete the project / a parent tree.
        std.mem.eql(u8, norm, ".") or escapesUpward(norm);

    if (destructive) {
        std.debug.print(
            "labelle wasm export: refusing to use '{s}' as --output\n" ++
                "  the export directory is wiped on every run, and this path is the\n" ++
                "  project directory, an ancestor of it, or the filesystem root.\n" ++
                "  choose a dedicated subdirectory, e.g. --output ./release\n",
            .{output},
        );
        return error.DestructiveOutputPath;
    }

    if (std.fs.path.isAbsolute(output)) return allocator.dupe(u8, output);
    return std.fs.path.join(allocator, &.{ project_dir, output });
}

/// True when a relative, normalized `norm` names the project root
/// itself (`.` is handled by the caller) via an upward escape — i.e. its
/// first path component is `..`. Separator-agnostic: matches both `../`
/// and `..\` so a Windows-style output is caught even if `resolve`
/// emitted the other separator.
fn escapesUpward(norm: []const u8) bool {
    if (std.mem.eql(u8, norm, "..")) return true;
    return norm.len > 2 and std.mem.eql(u8, norm[0..2], "..") and std.fs.path.isSep(norm[2]);
}

/// Path-boundary equality, case-insensitive on Windows (whose
/// filesystems are case-insensitive, so `C:\Proj` and `c:\proj` name the
/// same dir — a destructive-ancestor check must treat them as equal).
fn pathEql(a: []const u8, b: []const u8) bool {
    return if (@import("builtin").os.tag == .windows)
        std.ascii.eqlIgnoreCase(a, b)
    else
        std.mem.eql(u8, a, b);
}

/// True when the absolute, normalized output `norm` is the (absolute)
/// project dir itself or an ancestor of it.
fn absTargetHitsProject(allocator: std.mem.Allocator, norm: []const u8, project_dir: []const u8) !bool {
    const proj_abs = try std.fs.path.resolve(allocator, &.{project_dir});
    defer allocator.free(proj_abs);
    if (pathEql(norm, proj_abs)) return true;
    // `norm` is an ancestor of `proj_abs` only if it extends it at a path
    // boundary — guards against "/foo" matching "/foobar". `isSep` accepts
    // either separator so a mixed-separator input still lands correctly.
    return proj_abs.len > norm.len and
        pathEql(proj_abs[0..norm.len], norm) and
        std.fs.path.isSep(proj_abs[norm.len]);
}

/// cli#320: in `--progress=json` mode a desktop `run` spawns the game
/// with inherited stdout, so the game's own log lines share the stream
/// with the NDJSON progress records — pure NDJSON on stdout is a
/// `build`-only guarantee. Say so once, on stderr, at the run-phase
/// seam (the two call sites below are mutually exclusive branches, so
/// the note prints exactly once per invocation). No-op when no reporter
/// is active — without one there is no NDJSON stream to interleave with.
fn noteRunSharesStdout(reporter: ?*progress.Reporter) void {
    const r = reporter orelse return;
    if (r.mode != .json) return;
    std.debug.print("labelle: note: during `run`, game output shares stdout with NDJSON progress records\n", .{});
}

/// Cold-path stage order (cli#387 gap 3): the shader-compiler override gate
/// runs BEFORE `assembler install`, not after it. The gate is pure local
/// stat-ing; the install is a network-bound package fetch that can take
/// minutes, so validating afterwards made a one-character typo in
/// `LABELLE_SHADERC` cost a full download before the diagnostic appeared.
///
/// `installer` is a value with an `install(allocator, project_dir)` method
/// rather than a plain fn pointer because the real one carries the resolved
/// assembler binary. The seam exists so a test can observe that a rejected
/// override means the install step NEVER RAN, instead of inferring it from
/// wall-clock timing.
fn gateThenInstall(
    a: std.mem.Allocator,
    project_dir: []const u8,
    gate: *const fn (std.mem.Allocator, []const u8) anyerror!void,
    installer: anytype,
) !void {
    try gate(a, project_dir);
    try installer.install(a, project_dir);
}

/// Production installer: `labelle-assembler install --project-root <dir>`,
/// which populates the package cache `generate` assumes.
const AssemblerInstaller = struct {
    bin: assembler_proc.Assembler,

    fn install(self: AssemblerInstaller, a: std.mem.Allocator, project_dir: []const u8) !void {
        return self.bin.run(a, "install", &.{ "--project-root", project_dir });
    }
};

test "a rejected shader override stops the cold build before any package is installed" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project/materials");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);

    const Spy = struct {
        var installed: bool = false;
        fn install(_: @This(), _: std.mem.Allocator, _: []const u8) !void {
            installed = true;
        }
        // The same gate the cold and watched paths share, with the env read
        // replaced by a known-bad value.
        fn badOverride(alloc: std.mem.Allocator, dir: []const u8) anyerror!void {
            return material_toolchain.preflightWith(alloc, dir, "shaderc", .native);
        }
        fn badDockerOverride(alloc: std.mem.Allocator, dir: []const u8) anyerror!void {
            return material_toolchain.preflightWith(alloc, dir, "shaderc", .docker);
        }
        fn goodOverride(alloc: std.mem.Allocator, dir: []const u8) anyerror!void {
            return material_toolchain.preflightWith(alloc, dir, "/bin/sh", .native);
        }
    };

    Spy.installed = false;
    try std.testing.expectError(error.ShadercOverrideMustBeAbsolute, gateThenInstall(a, project, Spy.badOverride, Spy{}));
    // The point of the move: the network-bound install never ran.
    try std.testing.expect(!Spy.installed);

    // `--docker` takes the same ordering, not a bypass.
    Spy.installed = false;
    try std.testing.expectError(error.ShadercOverrideMustBeAbsolute, gateThenInstall(a, project, Spy.badDockerOverride, Spy{}));
    try std.testing.expect(!Spy.installed);

    // A valid override still reaches the install, so the assertions above
    // are the gate firing rather than the install being unreachable.
    Spy.installed = false;
    try gateThenInstall(a, project, Spy.goodOverride, Spy{});
    try std.testing.expect(Spy.installed);
}

/// Run the project-scoped pipeline: read project.labelle, then
/// generate -> build -> run (or the docker / wasm / ios / android
/// variant selected by `parsed_args`). Dispatch of the standalone
/// subcommands stays in cli.zig `main`; this is invoked only for the
/// project commands (generate / build / run / wasm / ios / android).
/// Returns the process exit status the command earned: the game's own exit
/// status for `run` (0 for a genuine `--timeout` expiry), 0 for everything
/// that completed. `main` returns it as the CLI's exit code, so automation
/// can tell a crash from a clean run (cli#390).
///
/// A build that stops the launch is always NONZERO: the build (docker /
/// progress / captured) fails through `error.BuildFailed`, i.e. exit 1,
/// because that error path is what runs this function's errdefers. The
/// build's real code is in the `failed` progress record.
/// A subcommand that completed is exit 0; its error propagates unchanged.
/// Lets `run` return a status while the subcommands it delegates to keep
/// their `!void` signatures.
fn ok(result: anytype) !u8 {
    if (comptime @typeInfo(@TypeOf(result)) == .error_union) try result;
    return 0;
}

/// Why `confirmTarget` refused the requested target. The kind survives to
/// the `failed` progress record, so a `labelle status --json` consumer can
/// tell an absent owner (add a provider) from an unpinned one (pin the
/// declared package) the same way the human diagnostic does (Codex on #421).
const TargetRefusal = enum {
    no_provider,
    unpinned_owner,

    /// The `detail` of the `failed` progress record.
    fn detail(self: TargetRefusal) []const u8 {
        return switch (self) {
            .no_provider => "no provider for target",
            .unpinned_owner => "unpinned provider for target",
        };
    }
};

const TargetVerdict = union(enum) {
    resolved: provider_targets.Resolved,
    refused: TargetRefusal,
};

/// The ownership half of target resolution with the pipeline's diagnostic:
/// `provider_targets.resolve` against the discovered providers, or the
/// refusal kind after printing its diagnostic (the no-provider line's
/// registry hint is read from the cached registry document only). The
/// caller marks its feed with the kind and exits.
fn confirmTarget(a: std.mem.Allocator, providers: []const provider_dispatch.Provider, requested: []const u8) !TargetVerdict {
    const resolved = provider_targets.resolve(providers, requested) catch |err| switch (err) {
        error.NoProviderForTarget => {
            provider_targets.reportNoProvider(a, requested);
            return .{ .refused = .no_provider };
        },
        // The owner is a remote package read from the ordinary cache with
        // no integrity pin: a target-owning provider is held to the pinned
        // boundary even when no hook of its would ever call `requirePinned`.
        error.UnverifiedTargetOwner => {
            provider_targets.reportUnverifiedOwner(a, providers, requested);
            return .{ .refused = .unpinned_owner };
        },
        else => return err,
    };
    return .{ .resolved = resolved };
}

test "pipeline: each target refusal kind writes its own progress detail" {
    // The two kinds call for different fixes, so their records must differ
    // and the unpinned one must name the condition.
    try std.testing.expectEqualStrings("no provider for target", TargetRefusal.no_provider.detail());
    try std.testing.expectEqualStrings("unpinned provider for target", TargetRefusal.unpinned_owner.detail());
    try std.testing.expect(std.mem.indexOf(u8, TargetRefusal.unpinned_owner.detail(), "unpinned") != null);
    try std.testing.expect(std.mem.indexOf(u8, TargetRefusal.no_provider.detail(), "unpinned") == null);
}

pub fn run(allocator: std.mem.Allocator, parsed_args: ParsedArgs) !u8 {
    const command = parsed_args.command;
    const project_dir = parsed_args.project_dir;
    const timeout_ns = parsed_args.timeout_ns;

    // Read and parse project.labelle
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // Stale-CLI gate (#353), BEFORE the project parse: refuse to build a
    // project whose lock was written by a NEWER CLI —
    // `ignore_unknown_fields` means this binary would silently skip
    // config it doesn't know (the incident: per-atlas `.astc_block`
    // ignored → every atlas encoded at the old global block size,
    // visibly mangled art, zero errors). Running first also means a
    // newer project whose MIRRORED fields changed shape gets this
    // actionable message instead of a bare parse error. `upgrade` is
    // exempt: it is the way out of this error.
    if (command != .upgrade_cmd) {
        lockfile.enforceCliNotStale(allocator, project_dir, parsed_args.allow_older_cli) catch std.process.exit(1);
    }

    var parsed = config.readProjectConfig(arena.allocator(), project_dir) catch |err| {
        if (err == error.FileNotFound) {
            config.printNoProjectError(project_dir);
        }
        return 1;
    };

    // Normalize the deprecated `.initial_scene` alias (RFC #560 / #565)
    // into `.initial_prefab`. The `--scene=` flag does NOT rewrite
    // `.initial_prefab` anymore — it sets `LABELLE_SCENE=<name>` in the
    // spawned game's env (cli#229) and the project's loading-scene
    // controller reads it via `engine.requestedScene()` and transitions
    // once `assets.allReady`. The legacy initial-prefab-rewrite path was
    // removed because it bypassed the loading gate and made the game
    // stick on the target scene's async-load forever for projects with
    // a loading-scene gate.
    parsed.normalizeInitialPrefab();

    // The requested target (RFC #406 phase 3b, docs/provider-targets.md):
    // `--platform=<t>` — the legacy platform subcommands set the same
    // override — else the project's declared platform. It is resolved below
    // against the core target and the pinned providers' declarations;
    // `parsed.platform` is derived from the RESULT only where the pinned
    // assembler and the legacy sites still need the schema enum.
    const requested_target: []const u8 = parsed_args.platform_override orelse @tagName(parsed.platform);

    // Upgrade modifies project.labelle in the project directory
    if (command == .upgrade_cmd) {
        return ok(upgrade.cmdUpgrade(allocator, project_dir, parsed, parsed_args.extra_args[0..parsed_args.extra_count]));
    }

    // ── Target resolution, the NAME half (RFC #406 phase 3b) ──────────
    // (docs/provider-targets.md "Resolution")
    // The target is the core `desktop` or one a pinned provider declares;
    // nothing else, including the project's own `.platform` and the legacy
    // `wasm`/`ios`/`android` subcommands (no shim, RFC #406 "Migration").
    // Ownership needs the providers, and provider discovery runs only
    // after the assembler's `install` populated the package cache (below,
    // next to `gateThenInstall`; Codex P1 on #420) — while the target
    // directory, the progress feed and the schema platform every
    // pre-install step keys off need the name now. So the name is settled
    // here from the string alone: `desktop` is core; any other name is
    // PROVISIONALLY a provider target, confirmed against the discovered
    // providers right after the install and refused there when nobody
    // owns it. Two verdicts need no provider and land immediately:
    const hook_arena = arena.allocator();
    const project_root = try std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), project_dir, hook_arena);
    const provisional = try provider_targets.provisional(requested_target);
    // (1) A project that declares no packages can have no provider, so a
    //     provider target fails before anything is read, written or built.
    //     The registry hint in the failure line is read from the cached
    //     registry document only.
    if (!provisional.is_core and parsed.plugins.len == 0) {
        provider_targets.reportNoProvider(hook_arena, requested_target);
        return 1;
    }
    // (2) `labelle bundle` of the core target: the desktop packager is
    //     macOS-only and no hook can replace it (nobody may own `desktop`,
    //     so no `replace` hook on `bundle` can plan for it), so refuse it
    //     off macOS before any install or build, as the old `cli.zig` gate
    //     did. A provider target is packaged by its provider — checked
    //     with the plans, after discovery.
    if (command == .bundle_cmd and provisional.is_core and !bundle.hostSupported()) {
        bundle.printUnsupported();
        return 1;
    }
    // (3) A provider target whose ownership is decidable NOW is decided
    //     now, so an identifier-shaped typo (`--platform=waasm`) never runs
    //     `.prebuild`, the assembler resolution, the ASTC prepass or the
    //     install first (Codex on #421). This is the same metadata-only read
    //     `labelle targets` does (`.unknown`: cached manifests, no
    //     installer): when it can read EVERY declared package, the verdict
    //     — no owner, or an unpinned remote owner — is the one the
    //     post-install check would reach, so it lands here with the same
    //     diagnostics. A declared remote package it cannot read yet (cold
    //     cache, no pin) leaves the view partial, and the verdict waits for
    //     the post-install discovery, which stays the authoritative check.
    //     A manifest that fails discovery fails it closed here: the install
    //     cannot mend a manifest it can already read. Never for the core
    //     target, which needs no provider.
    if (!provisional.is_core) {
        var early_sources: provider_github.Sources = .{ .a = hook_arena };
        defer early_sources.deinit();
        const early = provider_dispatch.discoverAll(hook_arena, project_root, parsed, &early_sources, .unknown) catch |err| {
            std.debug.print("labelle: provider discovery failed: {s}\n", .{@errorName(err)});
            return 1;
        };
        if (early.unresolved.len == 0) {
            switch (try confirmTarget(hook_arena, early.providers, requested_target)) {
                .resolved => {},
                .refused => return 1,
            }
        }
    }
    // The legacy sites below (`parsed.platform == .X`; the guard's migration
    // allowlist) keep working for the schema-named provider targets. A
    // target outside the enum reaches only steps its provider does not
    // replace, which treat it as the generic host baseline. `parsed.platform`
    // is derived from the NAME only where the pinned assembler and the
    // legacy sites still need the schema enum.
    parsed.platform = provisional.legacy orelse .desktop;

    // `labelle ios` always implies the sokol backend (its target came
    // through the resolver like everything else).
    if (command == .ios_cmd) {
        parsed.backend = .sokol;
    }

    // Resolve the backend for ANY android-targeting invocation —
    // `labelle android`, `labelle run --platform=android`, or
    // `labelle build --platform=android` all land here. The backend is
    // taken from the project's declared backend, honoring an
    // Android-capable choice (`sokol` or `bgfx`) and falling back to
    // sokol otherwise (#252). Keying off the resolved platform (rather
    // than the subcommand) means a `.backend = .raylib` project run with
    // `--platform=android` gets the same helpful fallback as `labelle
    // android` instead of failing later on a missing `raylib_android`
    // target dir.
    if (parsed.platform == .android) {
        const android_backend = resolveAndroidBackend(parsed.backend);
        if (android_backend != parsed.backend) {
            std.debug.print(
                "labelle: backend '{s}' can't target Android; defaulting to sokol.\n",
                .{@tagName(parsed.backend)},
            );
        }
        parsed.backend = android_backend;
    }

    // `labelle wasm serve|export --no-build` — skip the generate+build
    // pipeline entirely and serve/package the existing build output. The
    // web dir lives under the wasm target subdir (`.labelle/<backend>_wasm/`).
    if (command == .wasm_cmd and parsed_args.serve_no_build) {
        // Nothing is installed on this path, so the provisional target is
        // confirmed against the providers discoverable as-is (`.unknown`,
        // like `labelle targets`): a package absent from the cache cannot
        // own a target here. Same diagnostics as the pipeline's own check.
        var no_build_sources: provider_github.Sources = .{ .a = hook_arena };
        defer no_build_sources.deinit();
        const known = provider_dispatch.discover(hook_arena, project_root, parsed, &no_build_sources, .unknown) catch |err| {
            std.debug.print("labelle: provider discovery failed: {s}\n", .{@errorName(err)});
            return 1;
        };
        const served = switch (try confirmTarget(hook_arena, known, requested_target)) {
            .resolved => |resolved| resolved,
            .refused => return 1,
        };
        const wasm_target = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ @tagName(parsed.backend), served.name });
        defer allocator.free(wasm_target);
        const web_dir = try std.fs.path.join(allocator, &.{
            project_dir, ".labelle", wasm_target, "zig-out", "web",
        });
        defer allocator.free(web_dir);
        if (std.Io.Dir.cwd().access(config.globalIo(), web_dir, .{})) |_| {} else |_| {
            const verb = if (parsed_args.wasm_export) "export" else "serve";
            std.debug.print(
                "labelle wasm {s}: no existing WASM build at '{s}'\n" ++
                    "  run `labelle wasm {s}` (without --no-build) first.\n",
                .{ verb, web_dir, verb },
            );
            return error.BuildFailed;
        }
        const project_web_dir = try std.fs.path.join(allocator, &.{ project_dir, "web" });
        defer allocator.free(project_web_dir);
        if (parsed_args.wasm_export) {
            const out_abs = try resolveExportOutput(allocator, project_dir, parsed_args.export_output);
            defer allocator.free(out_abs);
            return ok(export_mod.packageExport(allocator, web_dir, project_web_dir, .{
                .output_dir = out_abs,
                .zip = parsed_args.export_zip,
                .platform = parsed_args.export_pkg_platform,
            }));
        }
        // No watch in the `--no-build` path (the parser already rejects the
        // `--watch --no-build` combination, so `serve_watch` is false here).
        return ok(serve.serveAndOpen(allocator, web_dir, project_web_dir, parsed_args.serve_port, !parsed_args.serve_no_open, null));
    }

    // (Provider discovery, the ownership check of the provisional target
    // and the hook plans are computed further down, right after the package
    // cache is populated — see the `gateThenInstall` call.)

    // ── Build-progress feed (cli#284) ──────────────────────────────────
    // Target subdir: .labelle/raylib_desktop/, etc. Computed up front so
    // the live status file `.labelle/<target>/.build-progress.json` has a
    // home from the first `resolve` record onward (the dir is created by
    // the reporter; the assembler generates into it later). Named after
    // the PROVISIONAL target: the name depends on the string alone, and a
    // target refused after the install leaves only a `failed` record here.
    const target_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ @tagName(parsed.backend), provisional.name });
    defer allocator.free(target_name);
    const target_dir = try std.fs.path.join(allocator, &.{ project_dir, ".labelle", target_name });
    defer allocator.free(target_dir);

    // One event source, three access modes: NDJSON on stdout
    // (`--progress=json`), the atomically-rewritten status file (all
    // modes; read by `labelle status` + studio), and a live indicator on
    // stderr (default human mode — a TTY-only spinner while `zig build`
    // runs, "still working" heartbeat lines while the assembler child
    // owns stderr during resolve/generate, cli#321). Enabled for the
    // commands that run the shared build pipeline; `labelle generate` and
    // the ios/android subcommands (which own their own build flows) stay
    // report-free. A
    // reporter that fails to initialize downgrades to the pre-#284
    // behavior instead of blocking the build.
    var reporter_storage: progress.Reporter = undefined;
    const reporter: ?*progress.Reporter = blk: {
        if (command != .build and command != .run and command != .wasm_cmd and command != .bundle_cmd) break :blk null;
        reporter_storage = progress.Reporter.init(allocator, config.globalIo(), parsed_args.progress_mode, target_dir) catch break :blk null;
        break :blk &reporter_storage;
    };
    defer if (reporter) |r| r.deinit();
    // Any error path from here on marks the status file `failed`, so an
    // out-of-band reader never sees a live phase for a dead build. The
    // catch-all detail is composed from the live phase ("generate
    // failed", …) so the terminal record still names the stage that was
    // active — the record's own `phase` field flips to "failed" (cli#318).
    // (Pipeline code that terminates via process-exit instead of an error
    // return goes through `progress.fatalExit`, which does the same.)
    errdefer if (reporter) |r| r.failActiveStage(1);
    if (reporter) |r| {
        // Registers the fatalExit hook + starts the keepalive ticker that
        // refreshes elapsed/updated timestamps while child processes own
        // the foreground (assembler, zig, game).
        r.activate();
        r.beginPhase(.resolve, "resolving toolchain + packages");
    }

    // Validate version compatibility
    compatibility.validateCompatibility(parsed);

    // Pre-build hooks (#355). Runs on `generate` / `build` / `run` (and
    // the ios/android/wasm flows, which all generate) — the first thing
    // that touches the project after its config is validated, and ahead
    // of EVERY generation input reader: the ASTC pre-pass, the `--bake`
    // pre-pass, the assembler's cache populate and `generate`. That
    // ordering is the point: a step may emit an atlas declared in
    // `.resources` or a script the game compiles against, and all of
    // those are read downstream.
    //
    // No-op — no print, no stat, no spawn — for a project with no
    // `.prebuild`, so the default path is byte-identical to before.
    //
    // In `--progress=json` mode the child's stdout is routed to the CLI's
    // stderr so the NDJSON stdout feed stays pure (cli#320); see
    // `prebuild.zig`'s module doc for that and for the trust posture.
    // A non-zero step exits the CLI with the child's exact code from
    // inside `runAll` (via `progress.fatalExit`, which marks the status
    // file `failed` first), mirroring the assembler delegation.
    //
    // A hook is very often a Python program — `.run = .{ "python3",
    // "tools/gen_tiles.py", ... }` is this feature's documented example. On a
    // machine whose only interpreter is the CLI-managed one (`labelle install
    // python`), that interpreter reaches PATH solely through
    // `python_provision.autoWireEnv`, which used to run far below inside the
    // wasm-only block — i.e. AFTER the hooks had already failed to spawn
    // (cli#361 review). Wire it HERE, ahead of the first spawn, so the
    // documented generator works on every platform and not just after a wasm
    // build has got that far.
    //
    // Gated on hooks that will actually run, so the no-`.prebuild` path stays
    // byte-identical (no cache stat, no "using provisioned Python" line) and
    // `LABELLE_NO_PREBUILD=1` stays fully inert. Idempotent and cheap: the
    // wasm block below still calls it for projects with no hooks, and a
    // second call returns early once the dir is on PATH.
    //
    // Nothing else a hook could reasonably need is wired later. The managed
    // Zig toolchain is spawned by absolute path and never joins PATH at all;
    // emsdk activation exists for the emcc link step and pulling it above the
    // hooks would force a toolchain fetch on every build; and
    // `sdl_provision.autoWireEnv` (just below) sets a Windows link/runtime
    // variable consumed by `zig build`, not a tool a generator spawns.
    if (parsed.prebuild.len > 0 and !prebuild.skipRequested(allocator)) {
        python_provision.autoWireEnv(allocator);
    }

    try prebuild.runAll(allocator, project_dir, parsed.prebuild, .{
        .route_stdout_to_stderr = parsed_args.progress_mode == .json,
    });

    // Auto-wire a cache-provisioned SDL2 (`labelle doctor --fix`) into the
    // build/run environment so desktop games that need it (raylib/sokol
    // gamepad, sdl backend) link + run without the user setting
    // LABELLE_SDL2_LIB by hand. No-op when SDL2 isn't in the cache or the
    // user already set the var. Scoped like `labelle doctor`: the sdl
    // backend always needs SDL2; raylib/sokol only for the gamepad
    // source, so `.gamepad = .none` projects get nothing injected.
    // Backends that pull in SDL2: the `sdl` renderer always, and
    // raylib/sokol/bgfx for the shared desktop gamepad source unless gamepad
    // is opted out. Mirrors the assembler's `deps_linker.stagesSdlGamepad`
    // (raylib/sokol/bgfx with `gamepad == .auto`) — bgfx was previously
    // missing here, so its default gamepad-enabled desktop builds never got
    // SDL2 auto-wired or the runtime DLL staged (cli#285 / cli#286).
    const wants_sdl2 = parsed.backend == .sdl or
        ((parsed.backend == .raylib or parsed.backend == .sokol or parsed.backend == .bgfx) and parsed.gamepad != .none);
    if (parsed.platform == .desktop and wants_sdl2) {
        sdl_provision.autoWireEnv(allocator);
    }

    // Issue #217: the CLI is a thin driver over the standalone
    // labelle-assembler binary. Resolve it once here (LABELLE_ASSEMBLER
    // env var > assembler_version in project.labelle > auto-downloaded
    // default) and reuse the located binary for both the cache-populate
    // step and code generation below.
    const asm_bin = try assembler_proc.resolve(allocator, project_dir, "generate");
    defer asm_bin.deinit(allocator);
    std.debug.print("  using assembler: {s}\n", .{asm_bin.path});

    // ASTC build-time conversion (#340): when this platform ships ASTC atlases
    // (`asset_compression`), run `labelle astc` first so the `<name>.astc`
    // siblings exist for the assembler's catalog `.png → .astc` swap. Runs
    // before the assembler steps (it only needs project.labelle + the PNGs +
    // astcenc). Non-fatal — on any failure the assembler finds no sibling and
    // falls back to the source PNG, so the build still succeeds.
    //
    // EXCEPT a misconfiguration. `ConflictingAstcBlocks` means two atlases
    // compile to one `.astc` with disagreeing block pins; falling back would
    // hand BOTH of them whatever `.astc` is on disk — including a STALE one
    // from an earlier build, which is worse than no atlas because it looks
    // like it worked. So a config error stops the build, while a conversion
    // failure still degrades to PNG.
    //
    // Only for a target the capability tables know (`provisional.legacy`:
    // `desktop` or a schema-named provider target). A provider target
    // outside the enum has `parsed.platform` derived as `.desktop` for the
    // legacy sites, but it is NOT the desktop target: running the desktop
    // prepass for it would encode ASTC siblings by desktop capabilities for
    // a provider's own `generate` to pick up (Codex on #421). Its provider
    // owns its asset pipeline; `cmdAstc` itself refuses such a name.
    if (provisional.legacy != null and parsed.asset_compression.formatFor(parsed.platform) == .astc) {
        // Pass the RESOLVED target: `--platform=wasm`, `labelle ios` (forces
        // sokol) and the Android backend fallback all differ from what
        // project.labelle declares, and the loadable blocks depend on both.
        astc_cmd.cmdAstc(allocator, &.{
            project_dir,
            "--platform",
            @tagName(parsed.platform),
            "--backend",
            @tagName(parsed.backend),
        }) catch |err| switch (err) {
            error.ConflictingAstcBlocks => progress.fatalExit(
                1,
                "conflicting .astc_block pins compile to one .astc — see the error above",
            ),
            // A stale `.astc` (wrong block for this target) that could not be
            // deleted would be swapped in by the assembler — the PNG fallback
            // below would be a lie. Stop instead (labelle-bgfx#134).
            error.StaleAstcSiblingUndeletable => progress.fatalExit(
                1,
                "a stale .astc sibling could not be deleted — see the error above",
            ),
            else => std.debug.print(
                "labelle: ASTC conversion failed ({s}); falling back to PNG atlases\n",
                .{@errorName(err)},
            ),
        };
    }

    // Ensure the package cache is populated. The assembler's `generate`
    // subcommand assumes a populated cache (it does not fetch packages
    // itself), so delegate `install --project-root` to the binary first.
    // This replaces the CLI's former in-process `cache.ensureCache`,
    // which depended on the assembler's `generator` module.
    //
    // The shader-compiler override gate runs immediately BEFORE this install
    // (cli#387 gap 3): a typo'd `LABELLE_SHADERC` used to be reported only
    // after the slow, network-bound fetch had finished. `--docker` selects the
    // docker-aware variant, which validates identically and then says that the
    // host path is not forwarded into the container.
    try gateThenInstall(
        allocator,
        project_dir,
        if (parsed_args.docker) material_toolchain.preflightDocker else material_toolchain.preflight,
        AssemblerInstaller{ .bin = asm_bin },
    );

    // ── Provider discovery, target ownership and hook plans ────────────
    // (contract §6; docs/provider-hooks.md, docs/provider-targets.md)
    // Discovery reads every declared provider manifest and validates the
    // whole hook graph ONCE, so a malformed provider fails a plain `labelle
    // build` closed before generation or any compiler runs. It sits HERE,
    // after `install` populated the package cache and not before it (Codex
    // P1 on #420): a declared remote package that is neither pinned nor yet
    // in the ordinary cache has no manifest to read, and discovering ahead of
    // the installer read every such package as runtime-only — a cold cache
    // silently built without the package's hooks while a warm one ran them
    // (or refused as unpinned). With the cache populated, `.populated` makes
    // an absent package an error instead. Skipped for a project with no
    // plugins; for pinned remote providers it is the same verified extraction
    // every provider command performs (the integrity model of cli#414 — the
    // cost is accepted). The plans are pure and computed here for all four
    // steps; a project without hooks gets four empty plans and never resolves
    // the host compiler.
    var provider_sources: provider_github.Sources = .{ .a = hook_arena };
    defer provider_sources.deinit();
    const providers: []const provider_dispatch.Provider = if (parsed.plugins.len == 0)
        &.{}
    else
        provider_dispatch.discover(hook_arena, project_root, parsed, &provider_sources, .populated) catch |err| {
            std.debug.print("labelle: provider discovery failed: {s}\n", .{@errorName(err)});
            if (reporter) |r| r.finishFailed(1, "provider discovery failed");
            return 1;
        };
    // The ownership half of target resolution: the provisional target from
    // above is confirmed against the discovered providers — the first point
    // at which a declared package's manifest is guaranteed readable — and
    // refused when none declares it. This is the only place a provider
    // target becomes a resolved one; nothing has been generated, locked or
    // compiled yet, and the `failed` progress record names the reason —
    // which of the two refusals it was, since each calls for a different fix.
    const target = switch (try confirmTarget(hook_arena, providers, requested_target)) {
        .resolved => |resolved| resolved,
        .refused => |why| {
            if (reporter) |r| r.finishFailed(1, why.detail());
            return 1;
        },
    };
    const hook_plans = .{
        .generate = try provider_hooks.plan(hook_arena, providers, .generate, target.name),
        .build = try provider_hooks.plan(hook_arena, providers, .build, target.name),
        .bundle = try provider_hooks.plan(hook_arena, providers, .bundle, target.name),
        .run = try provider_hooks.plan(hook_arena, providers, .run, target.name),
    };
    // The labelle-assembler#378 boundary: the assembler generates only for
    // the schema platforms, so a provider target outside that enum can be
    // generated for only by its provider's `replace` hook on `generate`.
    // Without one, stop HERE — before the lock, the assembler's `generate`
    // and any compiler — rather than hand the assembler a name it cannot
    // take.
    if (target.legacy == null and hook_plans.generate.replace == null) {
        std.debug.print("labelle: target '{s}' is declared by '{s}' but the pinned assembler cannot generate for it yet (labelle-assembler#378)\n", .{ target.name, target.providerName() });
        if (reporter) |r| r.finishFailed(1, "the pinned assembler cannot generate for this target");
        return 1;
    }
    // `labelle bundle` of a provider target is packaged by its provider, so
    // it needs a `replace` hook on `bundle` — and needs no particular host.
    // (The core target's macOS-only gate ran before the install, above.)
    if (command == .bundle_cmd) {
        if (target.provider) |provider| {
            if (hook_plans.bundle.replace == null) {
                std.debug.print("labelle: target '{s}' has no bundle replacement; package '{s}' must declare a `.when = .replace` hook on `bundle`\n", .{ target.name, provider.meta.name });
                return error.NoBundleReplacement;
            }
        }
    }

    // Plugin→core compatibility, the POST-RESOLVE half (#332).
    //
    // Deliberately here and not beside `validateCompatibility` above: that one
    // runs on `ProjectConfig` alone, before any package exists on disk, so a
    // remote plugin's `plugin.labelle` is simply not readable yet and every
    // declaration would read as absent. `install` above is what populates the
    // cache, so this is the first point where a declared `.core_compat` can be
    // honored at all. Warn-only and non-fatal, like every other check in
    // `compatibility.zig`.
    compatibility.validatePluginCoreCompat(allocator, parsed, project_dir);

    // `labelle.lock` is written HERE, before generation, rather than after
    // it: a `before generate` provider hook already needs the lock (contract
    // §2 — `lock_file` is non-null inside a project, and the hook's own pin
    // is verified against it). `install` above populated the cache the lock
    // writer reads, so every resolved version is already known. A generate
    // that then fails leaves a fresh lock reflecting the declared pins —
    // harmless, and `enforceCliNotStale` only reads it on the next run.
    try lockfile.writeLockFile(allocator, project_dir, parsed);

    // Generate into .labelle/
    const output_dir = try std.fs.path.join(allocator, &.{ project_dir, ".labelle" });
    defer allocator.free(output_dir);

    // GUI resolution (reading the plugin's gui.labelle manifest) is owned
    // by the assembler's `generate` subcommand — the CLI no longer
    // resolves it. The status line reports whether a GUI is *configured*
    // in project.labelle; the assembler logs the resolved plugin name.
    const gui_label: []const u8 = if (parsed.gui != null) "configured" else "none";
    if (reporter) |r| r.beginPhase(.generate, "assembler generate");
    std.debug.print("labelle: generating '{s}'...\n", .{parsed.name});
    std.debug.print("  backend: {s}  target: {s}  ecs: {s}  gui: {s}  window: {d}x{d}\n", .{
        @tagName(parsed.backend), target.name, @tagName(parsed.ecs), gui_label, parsed.width, parsed.height,
    });

    // Scenes and prefabs are always embedded via @embedFile
    const effective_optimize = parsed_args.optimize_override orelse
        if (parsed.platform == .wasm) @as(?[]const u8, "ReleaseSafe") else null;

    // Everything a provider hook run needs. The host compiler is resolved by
    // the first hook that runs (never for an empty plan), and hooks report
    // under the phase of the core step they wrap; the wire `optimize` and
    // `progress` mirror this invocation's, so a hook builds what the core
    // step builds and speaks the mode the user asked for.
    const hook_optimize = std.meta.stringToEnum(provider_contract.Optimize, effective_optimize orelse "Debug") orelse {
        std.debug.print("labelle: unknown optimize mode '{s}'\n", .{effective_optimize.?});
        return 1;
    };
    var hook_site: provider_hooks.Site = .{
        .a = hook_arena,
        .backing = allocator,
        .providers = providers,
        .root = project_root,
        .cfg = parsed,
        .target = target.name,
        .optimize = hook_optimize,
        .progress = switch (parsed_args.progress_mode) {
            .human => .human,
            .json => .json,
            .off => .off,
        },
        .reporter = reporter,
    };

    // Opt-in PNG → LRGBA pre-bake. Runs before the assembler so its
    // @embedFile path picks up the fresh `.rgba` files. Skipped unless
    // `--bake` is passed: raw RGBA expands heavily-transparent atlases
    // by 100×+ (a 200 KB PNG can become 64 MB), so default-off keeps
    // APK size sane. Use for projects whose atlases are nearly opaque
    // and PNG decode dominates cold start.
    if (parsed_args.bake) {
        bake_mod.run(allocator, project_dir, parsed.resources) catch |err| {
            std.debug.print("labelle: bake failed: {s}\n", .{@errorName(err)});
            return err;
        };
    }

    // Issue #217 phase 2: delegate code generation to the standalone
    // labelle-assembler binary via the shared subprocess harness, instead
    // of calling an in-process generator. The binary was located above
    // (`asm_bin`) and already used for the `install` cache-populate step.
    //
    // `build` / `run` are not assembler subcommands: the subsequent
    // `zig build` invocation and binary launch stay CLI-side (see below).
    // The CLI owns docker orchestration, the WASM serve loop, the
    // iOS/Android deploy paths and `--timeout` — generation is the only
    // step the assembler binary delegates.
    // `parsed_args.scene_override` is intentionally NOT forwarded to the
    // assembler. PR #243 removed the CLI's `cfg.initial_prefab` rewrite for
    // exactly this reason; the assembler's own `--scene` handling does the
    // same rewrite, which bypasses any loading-scene gate the project
    // declares. The override is delivered at runtime via the
    // `LABELLE_SCENE` env var injected at the spawn site (~line 990).
    //
    // (The shader-compiler override gate used to run here. It now runs in
    // `gateThenInstall`, ahead of the network-bound package install — see
    // cli#387 gap 3.)
    //
    // Provider hooks on `generate` (contract §6): `before` hooks, then the
    // core generation — or its unique `replace` hook — then `after` hooks.
    // `output_dir` is the generated tree itself. A failing hook ends the
    // command with the hook's own exit code; nothing past it runs.
    const generate_out = try provider_hooks.stepOutputDir(hook_arena, target_dir, .generate, target.name, null);
    {
        const code = try provider_hooks.runPhase(&hook_site, hook_plans.generate.before, .generate, .before, generate_out);
        if (code != 0) return code;
    }
    core_generate: {
        if (hook_plans.generate.replace) |replacement| {
            const code = try provider_hooks.runPhase(&hook_site, &.{replacement}, .generate, .replace, generate_out);
            if (code != 0) return code;
            break :core_generate;
        }
        // The assembler receives the resolved target NAME; the #378 gate above
        // guarantees it is one the pinned assembler can take.
        try assembler_proc.generate(
            asm_bin,
            allocator,
            project_dir,
            target.name,
            @tagName(parsed.backend),
        );

        // (`target_name`/`target_dir` — .labelle/raylib_desktop/, etc. — are
        // computed up front, before the progress reporter init; see cli#284.)

        // fixFingerprints runs `zig build` locally per emitted target dir to
        // discover the correct hash. With assembler >=0.14.0 there are two
        // (`<backend>_<platform>/` and `tests/`); patching only the exe dir
        // would leave `tests/` with a placeholder fingerprint and break
        // `labelle test`.
        //
        // For docker builds we skip the exe target — the host Zig toolchain
        // may not have the native libs the chosen backend needs (that's why
        // we're routing through docker in the first place). The tests target
        // is the exception: it uses the null backend (no native libs), so
        // host Zig can build it even when --docker is set, and skipping
        // would leave `labelle test` broken on the host after `labelle build
        // --docker`. Patch `tests/` directly when present.
        if (!parsed_args.docker) {
            try runner.fixFingerprints(allocator, project_dir, output_dir);
        } else {
            const tests_dir = try std.fs.path.join(allocator, &.{ output_dir, "tests" });
            defer allocator.free(tests_dir);
            const tests_build_zig = try std.fs.path.join(allocator, &.{ tests_dir, "build.zig" });
            defer allocator.free(tests_build_zig);
            if (std.Io.Dir.cwd().access(config.globalIo(), tests_build_zig, .{})) |_| {
                try runner.fixFingerprint(allocator, project_dir, tests_dir);
            } else |_| {}
        }
        // (`labelle.lock` was written before generation — see the provider
        // hook note beside `validatePluginCoreCompat`.)
        std.debug.print("  generated .labelle/{s}/\n", .{target_name});

        // For a wasm build: activate the emsdk checkout Zig just fetched into the
        // project-local `zig-pkg/` (during the fingerprint pass above) so the emcc
        // link step finds `upstream/emscripten/emcc`. Without this a fresh
        // `labelle build --platform wasm` — or `generate --platform wasm` followed
        // by a manual `zig build` — dies at the emcc step because the fetched emsdk
        // package is NOT activated: the remaining half of labelle-assembler#492 (the
        // docker path already does this in-container). Run it BEFORE the `generate`
        // early-return so the generate-then-build path is covered too. Best-effort +
        // idempotent; on failure the build still surfaces the clear #492 guidance.
        // The PINNED version keeps activation deterministic.
        if (!parsed_args.docker and parsed.platform == .wasm) {
            // Python preflight (cli#291): emsdk activation and emcc itself (an
            // `env python3` script) both need a working interpreter. Fail fast
            // with the exact fix instead of dying deep inside emsdk activation
            // with an unrelated-looking error. `autoWireEnv` first: it puts a
            // previously-provisioned managed Python on this process's PATH (and
            // wires the TLS bundle on Windows), which is what makes the
            // availability probe — and the activation below — see it.
            python_provision.autoWireEnv(allocator);
            if (!python_provision.isAvailable(allocator)) {
                std.debug.print("labelle: wasm builds need Python 3 (emsdk activation + emcc) and none was found.\n" ++
                    "  fix: labelle install python   (managed, ~25 MB into ~/.labelle/python)\n" ++
                    "  or install Python 3 yourself and ensure `python3` is on PATH.\n", .{});
                return error.BuildFailed;
            }
            const resolved_emsdk = try emsdk_toolchain.resolveRequiredVersion(allocator, project_dir);
            defer allocator.free(resolved_emsdk.version);
            emsdk_activate.activateFetchedEmsdk(allocator, target_dir, resolved_emsdk.version);
        }
    }
    {
        const code = try provider_hooks.runPhase(&hook_site, hook_plans.generate.after, .generate, .after, generate_out);
        if (code != 0) return code;
    }

    if (command == .generate) return 0;

    // `labelle ios` subcommand — handles its own build/xcode/run
    if (command == .ios_cmd) {
        return ok(ios.handleIos(allocator, parsed_args.extra_args[0..parsed_args.extra_count], parsed, target_dir));
    }

    // `labelle android` subcommand — handles its own build/run
    if (command == .android_cmd) {
        return ok(android.handleAndroid(allocator, parsed_args.extra_args[0..parsed_args.extra_count], parsed, project_dir, target_dir));
    }

    // Warn if --target is used without --docker (it has no effect otherwise)
    if (parsed_args.docker_target != null and !parsed_args.docker) {
        std.debug.print("labelle: warning: --target has no effect without --docker\n", .{});
    }

    // Build — default to ReleaseSafe for WASM (Debug exceeds browser local variable limits)
    const optimize_flag: ?[]const u8 = if (effective_optimize) |opt|
        try std.fmt.allocPrint(allocator, "-Doptimize={s}", .{opt})
    else
        null;
    defer if (optimize_flag) |f| allocator.free(f);

    // Resolve the managed Zig toolchain (labelle-cli#279): every `zig` spawn
    // uses this binary, never PATH. Downloads + verifies on a cache miss.
    // Skipped for docker builds — the toolchain lives inside the container.
    const managed_zig: ?[]u8 = if (parsed_args.docker) null else try runner.resolveZigExe(allocator, project_dir);
    defer if (managed_zig) |z| allocator.free(z);

    // Build a base env for child `zig` that pins ZIG_*_CACHE_DIR into the
    // labelle cache tree (user-writable, never next to a read-only install).
    // For a wasm build, ALSO layer the managed emsdk's EMSDK/EM_CONFIG/PATH
    // wiring on top when one is already provisioned (labelle-cli#283) — an
    // escape hatch for builds/backends that resolve `emcc` via PATH/env rather
    // than the fetched package activated just above.
    var zig_env_storage: ?std.process.Environ.Map = if (parsed_args.docker)
        null
    else if (parsed.platform == .wasm)
        try runner.buildWasmEnv(allocator, project_dir)
    else
        try runner.buildZigEnv(allocator, &.{});
    defer if (zig_env_storage) |*m| m.deinit();
    const zig_env_ptr: ?*const std.process.Environ.Map = if (zig_env_storage) |*m| m else null;

    var zig_args: std.ArrayList([]const u8) = .empty;
    defer zig_args.deinit(allocator);
    try zig_args.append(allocator, managed_zig orelse "zig");
    try zig_args.append(allocator, "build");
    if (optimize_flag) |flag| try zig_args.append(allocator, flag);

    // Provider hooks on `build` (contract §6) wrap the whole core build —
    // docker or host `zig build` plus the runtime DLL staging — with
    // `output_dir` = the target's `zig-out/`. A `replace` hook stands in for
    // all of it. Hooks report under the `compile` phase.
    const build_out = try provider_hooks.stepOutputDir(hook_arena, target_dir, .build, target.name, null);
    {
        const code = try provider_hooks.runPhase(&hook_site, hook_plans.build.before, .build, .before, build_out);
        if (code != 0) return code;
    }
    core_build: {
        if (hook_plans.build.replace) |replacement| {
            const code = try provider_hooks.runPhase(&hook_site, &.{replacement}, .build, .replace, build_out);
            if (code != 0) return code;
            break :core_build;
        }
        if (parsed_args.docker) {
            // Docker builds get phase-level progress only: the toolchain (and
            // its progress pipe) lives inside the container.
            if (reporter) |r| r.beginPhaseOrStep(.compile, "docker build");
            std.debug.print("labelle: building via docker...\n", .{});
            const docker_exit = try docker.runBuild(allocator, target_dir, parsed.platform, parsed_args.docker_target, effective_optimize);
            if (reporter) |r| r.clearSpinner();
            if (docker_exit != 0) {
                if (reporter) |r| r.finishFailed(docker_exit, "docker build failed");
                std.debug.print("labelle: docker build failed (exit code {d})\n", .{docker_exit});
                return error.BuildFailed;
            }
        } else if (reporter) |r| {
            // cli#284: spawn `zig build` with Zig's std.Progress IPC pipe
            // attached — live node names + keepalives flow into the feed
            // during the compile (see runner.zig for what Zig 0.16 actually
            // relays), and stdio is inherited so compile errors stream to the
            // terminal unaltered (nothing is captured or eaten).
            std.debug.print("labelle: building...\n", .{});
            r.beginPhaseOrStep(.compile, "zig build");
            const build_code = try runner.runZigInheritProgress(allocator, target_dir, zig_args.items, zig_env_ptr, r);
            // Wipe the spinner line before anything else prints on it.
            r.clearSpinner();
            if (build_code != 0) {
                r.finishFailed(build_code, "zig build failed");
                std.debug.print("labelle: build failed (exit {d})\n", .{build_code});
                return error.BuildFailed;
            }
        } else {
            std.debug.print("labelle: building...\n", .{});
            const build_result = try runner.runZigWithEnv(allocator, target_dir, zig_args.items, zig_env_ptr);
            defer allocator.free(build_result.stdout);
            defer allocator.free(build_result.stderr);

            switch (build_result.term) {
                .exited => |code| if (code != 0) {
                    std.debug.print("labelle: build failed:\n{s}\n", .{build_result.stderr});
                    return error.BuildFailed;
                },
                else => {
                    std.debug.print("labelle: build process terminated abnormally\n{s}\n", .{build_result.stderr});
                    return error.BuildFailed;
                },
            }
        }
        std.debug.print("  build ok\n", .{});

        // Stage the runtime SDL2.dll next to the freshly-built desktop exe. A
        // gamepad/SDL2 build's exe fails process creation with a bare
        // `FileNotFound` when SDL2.dll isn't in its own directory (cli#285): the
        // Windows loader resolves implicitly-linked DLLs from the exe dir first,
        // and neither the PATH prepend from autoWireEnv nor a user-set
        // LABELLE_SDL2_LIB puts the DLL there. Docker builds are skipped — their
        // exe is built for the container's OS, so a host SDL2.dll is irrelevant.
        if (!parsed_args.docker and parsed.platform == .desktop and wants_sdl2) {
            const bin_dir = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "bin" });
            defer allocator.free(bin_dir);
            sdl_provision.stageSdl2DllBesideExe(allocator, bin_dir);
        }
    }
    {
        const code = try provider_hooks.runPhase(&hook_site, hook_plans.build.after, .build, .after, build_out);
        if (code != 0) return code;
    }

    // `labelle bundle` (cli#359): the exe is built; wrap it. Packaging
    // runs AFTER the compile, so keep the progress feed open across it
    // (a `run` phase, as `wasm export` does) and only mark `done` once
    // the `.app` is on disk — a `--progress=json` consumer must not see
    // `done` before the artifact exists.
    if (command == .bundle_cmd) {
        if (reporter) |r| {
            r.beginPhaseOrStep(.run, "packaging bundle");
            r.clearSpinner();
        }
        // Provider hooks on `bundle` (contract §6). `output_dir` is the step
        // output directory — `zig-out/bundle/<target>/`, or the resolved
        // `--output` — which is also where the core packager puts the
        // `.app` (`bundle.resolveOutputDir` shares the default), so hooks
        // and the packager always agree on the artifact's directory.
        const bundle_override: ?[]const u8 = if (parsed_args.bundle_output) |o|
            try bundle.resolveOutputDir(hook_arena, project_dir, target_dir, o)
        else
            null;
        const bundle_out = try provider_hooks.stepOutputDir(hook_arena, target_dir, .bundle, target.name, bundle_override);
        {
            const code = try provider_hooks.runPhase(&hook_site, hook_plans.bundle.before, .bundle, .before, bundle_out);
            if (code != 0) return code;
        }
        core_bundle: {
            if (hook_plans.bundle.replace) |replacement| {
                const code = try provider_hooks.runPhase(&hook_site, &.{replacement}, .bundle, .replace, bundle_out);
                if (code != 0) return code;
                break :core_bundle;
            }
            const app_path = try bundle.createFromBuild(allocator, project_dir, target_dir, parsed, .{
                .output = parsed_args.bundle_output,
                .build_number = parsed_args.bundle_build_number,
            });
            defer allocator.free(app_path);
            // `createFromBuild` already printed the plain path. The paste-able
            // hint is single-quoted so a `"`, `$VAR` or backtick in a project
            // title stays literal instead of expanding in the user's shell.
            const quoted = try bundle.shellSingleQuote(allocator, app_path);
            defer allocator.free(quoted);
            std.debug.print("  open {s}\n", .{quoted});
        }
        {
            const code = try provider_hooks.runPhase(&hook_site, hook_plans.bundle.after, .bundle, .after, bundle_out);
            if (code != 0) return code;
        }
        if (reporter) |r| r.finishDone(0);
        return 0;
    }

    if (command == .build) {
        // Linux `.desktop` entry + icon (cli#359): after a desktop build,
        // write `zig-out/<exe>.desktop` + `zig-out/<exe>.png` beside `bin/`
        // — automatically on a Linux host, or anywhere with
        // `--linux-desktop`. Skipped under `--docker`: that exe was built
        // for the container's target and the entry's absolute paths would
        // describe this host, not the one that will run it. `run` is
        // deliberately left alone — the entry is a packaging artifact.
        // Core desktop only: a provider target is packaged by its provider.
        if (!parsed_args.docker and target.provider == null and linux_desktop.shouldEmit(parsed_args.linux_desktop)) {
            const entry_path = try linux_desktop.createFromBuild(allocator, project_dir, target_dir, parsed);
            allocator.free(entry_path);
        }
        // `labelle build --platform=android` builds the shared library
        // above (the generic `zig build` produces `zig-out/lib/libgame.so`)
        // but, unlike `labelle android build`, used to stop there and leave
        // a bare `.so`. Package it into a signed APK so the artifact is
        // installable — backend-agnostic, so it covers sokol and bgfx alike.
        if (parsed.platform == .android) {
            const apk_path = try android.packageApk(allocator, project_dir, target_dir, parsed, false, .{}, .{
                .strip_native = android.stripForOptimize(effective_optimize),
            });
            defer allocator.free(apk_path);
            std.debug.print("labelle: APK ready: {s}\n", .{apk_path});
        }
        if (reporter) |r| r.finishDone(0);
        return 0;
    }

    // Run
    //
    // Provider hooks on `run` (contract §6): `before` runs once here, ahead
    // of every branch below; a `replace` hook stands in for all of them;
    // `after` runs at each branch's success exit through
    // `provider_hooks.finishRun`, which also owns the terminal `done` record
    // so a `--progress=json` consumer never sees `done` before the hooks
    // finished. After hooks never run unless the game itself exited 0 —
    // not after a nonzero exit, not after the `--timeout` watchdog's kill
    // (exit 0 for the CLI, cli#390) and not after a detached simulator or
    // device launch (`provider_hooks.RunOutcome`). The interactive `wasm
    // serve` loop is the one exception in timing: its `done` record lands
    // before the loop and the after hooks run only once the server returns.
    const run_out = try provider_hooks.stepOutputDir(hook_arena, target_dir, .run, target.name, null);
    {
        const code = try provider_hooks.runPhase(&hook_site, hook_plans.run.before, .run, .before, run_out);
        if (code != 0) return code;
    }
    if (hook_plans.run.replace) |replacement| {
        const code = try provider_hooks.runPhase(&hook_site, &.{replacement}, .run, .replace, run_out);
        if (code != 0) return code;
        return provider_hooks.finishRun(&hook_site, hook_plans.run.after, run_out, .exited_clean);
    }
    if (parsed.platform == .wasm) {
        const web_dir = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "web" });
        defer allocator.free(web_dir);
        const project_web_dir = try std.fs.path.join(allocator, &.{ project_dir, "web" });
        defer allocator.free(project_web_dir);
        if (parsed_args.wasm_export) {
            // `wasm export`: package the fresh build into a deployment dir
            // instead of serving it. Packaging runs AFTER the build, so
            // keep the progress feed open across it (a run phase) and only
            // mark `done` once the artifacts are on disk — otherwise a
            // `--progress=json` consumer sees `done` before the export.
            if (reporter) |r| {
                r.beginPhaseOrStep(.run, "packaging wasm export");
                r.clearSpinner();
            }
            const out_abs = try resolveExportOutput(allocator, project_dir, parsed_args.export_output);
            defer allocator.free(out_abs);
            try export_mod.packageExport(allocator, web_dir, project_web_dir, .{
                .output_dir = out_abs,
                .zip = parsed_args.export_zip,
                .platform = parsed_args.export_pkg_platform,
            });
            return provider_hooks.finishRun(&hook_site, hook_plans.run.after, run_out, .exited_clean);
        } else {
            // WASM serve: the loop is interactive (runs until Ctrl+C), so
            // the terminal `done` record lands before the serve loop. The
            // loop returns on Ctrl+C / SIGTERM (`serve.serveAndOpen`
            // installs the handler), which is how the `after run` hooks
            // below become reachable at all (Codex P2 on #420).
            if (reporter) |r| r.finishDone(0);
            if (parsed_args.serve_watch) {
                // `--watch` (cli#208): hand the serve loop a rebuild callback
                // that re-runs the same generate→fingerprint→zig-build steps
                // this pipeline just did. The context borrows locals that stay
                // alive because `serveAndOpen` blocks until Ctrl+C.
                var rebuild_ctx = WasmRebuildCtx{
                    .allocator = allocator,
                    .asm_bin = asm_bin,
                    .project_dir = project_dir,
                    .platform_tag = target.name,
                    .backend_tag = @tagName(parsed.backend),
                    .output_dir = output_dir,
                    .target_dir = target_dir,
                    .zig_args = zig_args.items,
                    .zig_env = zig_env_ptr,
                    .prebuild_steps = parsed.prebuild,
                    .prebuild_opts = .{
                        .route_stdout_to_stderr = parsed_args.progress_mode == .json,
                        // Keep the serve loop alive on a failing step.
                        .fatal_on_step_failure = false,
                    },
                    // The same hook site, plans and output directories the
                    // cold pipeline just used; the feed is already terminal
                    // here, so the hooks' sub-step records are no-ops.
                    .hooks = &hook_site,
                    .generate_plan = hook_plans.generate,
                    .build_plan = hook_plans.build,
                    .generate_out = generate_out,
                    .build_out = build_out,
                };
                // The hooks' declared `.outputs` are excluded from the watch
                // signature so the rebuild callback can't trip its own
                // watcher — but ONLY while the hooks actually run, so the
                // kill switch doesn't hide out-of-band regeneration from the
                // watcher. See `collectPrebuildIgnorePaths`.
                var ignore_files = collectPrebuildIgnorePaths(
                    allocator,
                    project_dir,
                    parsed.prebuild,
                    !prebuild.skipRequested(allocator),
                );
                defer {
                    for (ignore_files.items) |f| allocator.free(f);
                    ignore_files.deinit(allocator);
                }

                try serve.serveAndOpen(allocator, web_dir, project_web_dir, parsed_args.serve_port, !parsed_args.serve_no_open, .{
                    .watch_dir = project_dir,
                    .rebuild_fn = WasmRebuildCtx.rebuild,
                    .rebuild_ctx = &rebuild_ctx,
                    .ignore_files = ignore_files.items,
                });
            } else {
                try serve.serveAndOpen(allocator, web_dir, project_web_dir, parsed_args.serve_port, !parsed_args.serve_no_open, null);
            }
            // The server returned (Ctrl+C / SIGTERM): the feed is already
            // terminal, so only the hooks themselves run here. The stop was
            // asked for, so this is the serve's clean end.
            return provider_hooks.runPhase(&hook_site, hook_plans.run.after, .run, .after, run_out);
        }
    } else if (parsed.platform == .ios) {
        // iOS: deploy to simulator
        if (reporter) |r| r.beginPhaseOrStep(.run, "deploying to iOS Simulator");
        std.debug.print("labelle: deploying to iOS Simulator...\n", .{});
        try ios.deployToSimulator(allocator, target_dir, parsed);
        // `simctl launch` returns while the app runs on: its exit is never
        // seen here, so this is not the clean exit after hooks wait for.
        return provider_hooks.finishRun(&hook_site, hook_plans.run.after, run_out, .launched_detached);
    } else if (parsed.platform == .android) {
        // Android: deploy to device/emulator
        if (reporter) |r| r.beginPhaseOrStep(.run, "deploying to Android");
        std.debug.print("labelle: deploying to Android...\n", .{});
        // An app the system starts has no environment we control, so the
        // env-based run options travel as `am start --es` intent extras
        // under the same `LABELLE_*` names (cli#397); the Android runtime
        // turns them back into env vars (labelle-bgfx#139,
        // labelle-sokol#25). A runtime without that support ignores them.
        var launch_extras: std.ArrayList(runner.EnvKV) = .empty;
        defer launch_extras.deinit(allocator);
        var sec_buf: [32]u8 = undefined;
        try runner.appendRunOptionEnv(allocator, &launch_extras, runOptionEnv(&parsed_args), &sec_buf);
        try android.deployToDevice(allocator, project_dir, target_dir, parsed, false, .{}, .{
            .strip_native = android.stripForOptimize(effective_optimize),
        }, launch_extras.items);
        // `am start` likewise returns with the app still running.
        return provider_hooks.finishRun(&hook_site, hook_plans.run.after, run_out, .launched_detached);
    } else {
        if (timeout_ns) |t| {
            const secs = t / std.time.ns_per_s;
            const mins = secs / 60;
            const rem = secs % 60;
            if (mins > 0 and rem > 0) {
                std.debug.print("labelle: running (timeout: {d}m{d}s)...\n\n", .{ mins, rem });
            } else if (mins > 0) {
                std.debug.print("labelle: running (timeout: {d}m)...\n\n", .{mins});
            } else {
                std.debug.print("labelle: running (timeout: {d}s)...\n\n", .{secs});
            }
        } else {
            std.debug.print("labelle: running...\n\n", .{});
        }
        // Build a combined env map for the child when --scene (cli#229)
        // and/or --screenshot (cli#227) are set. Both flags need to be
        // surfaced as env vars to the spawned game:
        //  - LABELLE_SCENE          (cli#229 runtime scene-override)
        //  - LABELLE_SCREENSHOT_PATH
        //  - LABELLE_SCREENSHOT_AFTER_SEC
        // Loading-controller scripts read LABELLE_SCENE *after*
        // assets.allReady succeeds and call setScene(requested), so
        // asset streaming for large scenes no longer races boot. This
        // is now the ONLY mechanism for `--scene=` — the legacy
        // `.initial_prefab` rewrite was removed (see above).
        // Default the child env to the ZIG_*_CACHE_DIR map (cli#279) so the
        // rebuilt-and-run step still lands the compiler cache in user space.
        var env_map_storage: ?std.process.Environ.Map = null;
        defer if (env_map_storage) |*m| m.deinit();
        var env_map_ptr: ?*const std.process.Environ.Map = zig_env_ptr;
        const has_scene_env = parsed_args.scene_override != null;
        const has_screenshot_env = parsed_args.screenshot_path != null;
        // --headless (and the flags that imply it) surface as
        // LABELLE_HEADLESS=1 plus the optional uncapped/ticks knobs that
        // the sokol desktop backend reads. `parsed_args.headless` is
        // already set true by `--uncapped`/`--ticks`, so this one check
        // covers all three.
        const has_headless_env = parsed_args.headless;
        // --profile surfaces as LABELLE_PROFILE=1, enabling the engine's
        // built-in frame profiler. Independent of --headless.
        const has_profile_env = parsed_args.profile;
        // Fingerprint every path the capture could land at BEFORE the game
        // runs, so the post-run report can tell a file this run wrote from one
        // an earlier run left behind. The game's cwd — what a relative path
        // resolves against — is the project dir under --docker and the target
        // dir otherwise.
        const screenshot_probe: ?ScreenshotProbe = if (parsed_args.screenshot_path) |path|
            ScreenshotProbe.init(allocator, path, if (parsed_args.docker) project_dir else target_dir)
        else
            null;
        defer if (screenshot_probe) |p| p.deinit(allocator);
        if (has_scene_env or has_screenshot_env or has_headless_env or has_profile_env) {
            var extras: std.ArrayList(runner.EnvKV) = .empty;
            defer extras.deinit(allocator);
            // --scene / --profile / --screenshot(+--after): the list shared
            // with the Android launch (cli#397).
            var sec_buf: [32]u8 = undefined;
            try runner.appendRunOptionEnv(allocator, &extras, runOptionEnv(&parsed_args), &sec_buf);
            var ticks_buf: [32]u8 = undefined;
            if (parsed_args.headless) {
                try extras.append(allocator, .{ .key = "LABELLE_HEADLESS", .value = "1" });
                if (parsed_args.headless_uncapped) {
                    try extras.append(allocator, .{ .key = "LABELLE_HEADLESS_UNCAPPED", .value = "1" });
                }
                if (parsed_args.headless_ticks) |n| {
                    const ticks_str = try std.fmt.bufPrint(&ticks_buf, "{d}", .{n});
                    try extras.append(allocator, .{ .key = "LABELLE_HEADLESS_TICKS", .value = ticks_str });
                }
            }
            if (parsed_args.screenshot_path) |path| {
                // Deliberately "requested", not "will be written to": the
                // backend picks the real filename and may not honor this path
                // (labelle-bgfx#57 appends its own `.tga`). The authoritative
                // line is `ScreenshotProbe.report` after the run.
                std.debug.print("labelle: screenshot requested: '{s}'\n", .{path});
            }
            // For a non-docker run, fold the ZIG_*_CACHE_DIR vars in too so
            // both the build and run children share the managed cache. For a
            // docker run there is no managed toolchain, so just add extras.
            env_map_storage = if (parsed_args.docker)
                try runner.buildEnvironWithExtra(allocator, extras.items)
            else
                try runner.buildZigEnv(allocator, extras.items);
            env_map_ptr = &env_map_storage.?;
        }

        // When --docker was used, run the built binary directly instead of
        // calling `zig build run` (local Zig may be broken).
        if (parsed_args.docker) {
            // Cross-compiled binaries can't be run on the host
            if (parsed_args.docker_target) |t| {
                std.debug.print("labelle: cannot run cross-compiled binary (target: {s})\n", .{t});
                std.debug.print("  binary is at: {s}/zig-out/bin/\n", .{target_dir});
                if (reporter) |r| r.finishDone(0); // build succeeded; run skipped
                return 0;
            }
            // The assembler names the desktop binary after the project
            // (sanitized) so concurrent games are distinguishable to
            // `pgrep` (labelle-assembler#362). Derive the same name here so
            // the docker run path execs the binary by its real on-disk name.
            const exe_name = try util.sanitizeExeName(allocator, parsed.name);
            defer allocator.free(exe_name);
            const bin_path = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "bin", exe_name });
            defer allocator.free(bin_path);
            var run_args: std.ArrayList([]const u8) = .empty;
            defer run_args.deinit(allocator);
            try run_args.append(allocator, bin_path);
            try appendRunForwardedArgs(&run_args, allocator, &parsed_args);
            if (reporter) |r| r.beginPhaseOrStep(.run, exe_name);
            noteRunSharesStdout(reporter);
            const run_outcome = runOutcome(try runner.runInheritTerm(allocator, project_dir, run_args.items, timeout_ns, env_map_ptr));
            if (run_outcome == .exited_error) {
                std.debug.print("\nlabelle: process exited with code {d}\n", .{run_outcome.status()});
            }
            if (screenshot_probe) |p| p.report(allocator);
            // The game ran: the pipeline is `done` even on a nonzero game
            // exit — the code is carried in the terminal record, and it is
            // also the CLI's exit status (cli#390). After hooks run first,
            // and only when the game itself exited clean — never after the
            // watchdog's kill, which is also exit 0.
            return provider_hooks.finishRun(&hook_site, hook_plans.run.after, run_out, run_outcome);
        } else {
            // Run the game BINARY DIRECTLY rather than via `zig build run`.
            // `zig build run` launches the game in its own child process
            // group, which ESCAPES the --timeout kill: the watchdog signals
            // labelle's direct child (the `zig build` process), the game
            // survives in its separate group, gets reparented to init, and
            // orphans. Run as labelle's own child and the game stays in the
            // process group the watchdog signals, so SIGTERM→SIGKILL
            // actually reaches it. Mirrors the --docker path.
            //
            // Keep the game's cwd at `target_dir` (a target_dir-relative
            // argv[0]) so saves land exactly where `zig build run` put them.
            //
            // There is deliberately NO second `zig build` here. The core
            // build above (`core_build`, or its `replace` hook) is the one
            // and only build of this command; the warm re-build that used
            // to sit here was a leftover of translating `zig build run`
            // into build-then-exec (cli#265) — a warm-cache no-op that
            // nonetheless re-ran the install steps, so a `zig-out/` file an
            // `after build` hook had signed, stripped or patched was copied
            // back to its unhooked original right before launch, and a
            // `replace` hook's build was quietly followed by the core one
            // (Codex P2 on #420). `run` begins when the game binary is
            // about to spawn.
            // Exe name: the assembler names the desktop exe after the
            // sanitized project (labelle-assembler#362); older generated
            // build.zig still emit `game`. Prefer the project name; fall back
            // to `game` when that binary isn't on disk, so this works both
            // before and after the rename ships. Run it by a target_dir-
            // relative path so the game's cwd stays `target_dir` (saves land
            // where `zig build run` put them). Mirrors the --docker path.
            // Probe with the platform executable suffix: on Windows the
            // assembler emits `<name>.exe`, so a suffix-less probe never
            // matches and would wrongly fall back to the legacy `game` name,
            // then fail to launch with FileNotFound (cli#309).
            const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";
            const sanitized = try util.sanitizeExeName(allocator, parsed.name);
            defer allocator.free(sanitized);
            const sanitized_exe = try std.fmt.allocPrint(allocator, "{s}{s}", .{ sanitized, exe_suffix });
            defer allocator.free(sanitized_exe);
            const sanitized_full = try std.fs.path.join(allocator, &.{ target_dir, "zig-out", "bin", sanitized_exe });
            defer allocator.free(sanitized_full);
            const exe_basename: []const u8 = if (util.fileExists(sanitized_full)) sanitized_exe else "game" ++ exe_suffix;
            const rel_bin = try std.fs.path.join(allocator, &.{ "zig-out", "bin", exe_basename });
            defer allocator.free(rel_bin);
            var run_args: std.ArrayList([]const u8) = .empty;
            defer run_args.deinit(allocator);
            try run_args.append(allocator, rel_bin);
            try appendRunForwardedArgs(&run_args, allocator, &parsed_args);
            if (reporter) |r| r.beginPhaseOrStep(.run, exe_basename);
            noteRunSharesStdout(reporter);
            const run_outcome = runOutcome(try runner.runInheritTerm(allocator, target_dir, run_args.items, timeout_ns, env_map_ptr));
            if (run_outcome == .exited_error) {
                std.debug.print("\nlabelle: process exited with code {d}\n", .{run_outcome.status()});
            }
            if (screenshot_probe) |p| p.report(allocator);
            // The game ran: the pipeline is `done` even on a nonzero game
            // exit — the code is carried in the terminal record, and it is
            // also the CLI's exit status (cli#390). After hooks run first,
            // and only when the game itself exited clean — never after the
            // watchdog's kill, which is also exit 0.
            return provider_hooks.finishRun(&hook_site, hook_plans.run.after, run_out, run_outcome);
        }
    }
}

/// Extensions a backend may append to the requested screenshot path instead of
/// honoring it verbatim. bgfx writes TGA and appends `.tga` to whatever it is
/// given, so `--screenshot=shot.png` lands at `shot.png.tga` (labelle-bgfx#57).
///
/// The append itself lives in the backend, out of this repo's reach — so once
/// the run is over `ScreenshotProbe.report` finishes the job here instead,
/// re-encoding the capture into the requested format and dropping the
/// doubly-named intermediate (cli#356, `screenshot_format.zig`). Every entry
/// must stay decodable by the vendored stb build (`stb_image_impl.c`).
const screenshot_suffixes = [_][]const u8{ ".tga", ".png", ".bmp" };

/// Pre-run fingerprint of one candidate path. Existence alone is not enough to
/// claim "this run wrote it" — a file left by an EARLIER run would be reported
/// as a fresh capture even when the current one failed, and a stale file at the
/// exact requested path would mask a newly written suffixed one. So compare
/// size+mtime across the run and treat only a created-or-changed file as ours.
const FileStamp = struct {
    existed: bool = false,
    size: u64 = 0,
    mtime_ns: i128 = 0,

    fn take(path: []const u8) FileStamp {
        const st = std.Io.Dir.cwd().statFile(config.globalIo(), path, .{}) catch return .{};
        return .{ .existed = true, .size = st.size, .mtime_ns = st.mtime.nanoseconds };
    }

    /// True when `after` represents a file this run created or rewrote.
    fn changed(before: FileStamp, after: FileStamp) bool {
        if (!after.existed) return false;
        if (!before.existed) return true;
        return before.size != after.size or before.mtime_ns != after.mtime_ns;
    }
};

/// The `labelle run` options that reach the game as `LABELLE_*` variables on
/// every platform (env block on desktop, intent extras on Android — cli#397).
/// The `run` outcome a launched game's termination stands for.
fn runOutcome(term: runner.Termination) provider_hooks.RunOutcome {
    return switch (term) {
        .exited => |code| provider_hooks.RunOutcome.fromExit(code),
        .timed_out => .timed_out,
    };
}

fn runOptionEnv(parsed_args: *const ParsedArgs) runner.RunOptionEnv {
    return .{
        .scene = parsed_args.scene_override,
        .profile = parsed_args.profile,
        .screenshot_path = parsed_args.screenshot_path,
        .screenshot_after_ns = parsed_args.screenshot_after_ns,
    };
}

/// Where a screenshot might land, fingerprinted before the game runs.
///
/// The CLI only forwards `LABELLE_SCREENSHOT_PATH`; the backend owns the real
/// filename and the CLI never verified the result, so a capture written to a
/// different path read as "no screenshot was produced" — the misreading this
/// exists to prevent.
///
/// `run_cwd` is the directory the game runs in, which is NOT the user's cwd:
/// normally `.labelle/<target>/` (so saves land where `zig build run` put
/// them), but `project_dir` under `--docker`. A relative `--screenshot=shot.png`
/// is resolved by the game against that cwd, so that is where to look and what
/// to print — an unqualified relative path would send the user to the wrong
/// directory.
const ScreenshotProbe = struct {
    /// Path as the user typed it.
    requested: []const u8,
    /// `requested` resolved against the game's cwd (owned).
    resolved: []const u8,
    /// Index 0 is `resolved`; the rest follow `screenshot_suffixes`.
    before: [1 + screenshot_suffixes.len]FileStamp = @splat(.{}),

    fn init(allocator: std.mem.Allocator, requested: []const u8, run_cwd: []const u8) ?ScreenshotProbe {
        const resolved: []const u8 = if (std.fs.path.isAbsolute(requested))
            allocator.dupe(u8, requested) catch return null
        else
            std.fs.path.join(allocator, &.{ run_cwd, requested }) catch return null;

        var probe: ScreenshotProbe = .{ .requested = requested, .resolved = resolved };
        for (0..probe.before.len) |i| {
            const path = probe.candidatePath(allocator, i) orelse continue;
            defer allocator.free(path);
            probe.before[i] = FileStamp.take(path);
        }
        return probe;
    }

    fn deinit(self: ScreenshotProbe, allocator: std.mem.Allocator) void {
        allocator.free(self.resolved);
    }

    /// Candidate `i`: 0 is the resolved path itself, then one per suffix.
    fn candidatePath(self: ScreenshotProbe, allocator: std.mem.Allocator, i: usize) ?[]u8 {
        if (i == 0) return allocator.dupe(u8, self.resolved) catch null;
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ self.resolved, screenshot_suffixes[i - 1] }) catch null;
    }

    /// Report where the screenshot ACTUALLY landed, after the game has exited.
    fn report(self: ScreenshotProbe, allocator: std.mem.Allocator) void {
        var stale_exact = false;
        for (0..self.before.len) |i| {
            const path = self.candidatePath(allocator, i) orelse continue;
            defer allocator.free(path);
            const after = FileStamp.take(path);
            if (!FileStamp.changed(self.before[i], after)) {
                // Pre-existing and untouched. Worth calling out only for the
                // exact path, where its presence is actively misleading.
                if (i == 0 and after.existed) stale_exact = true;
                continue;
            }
            self.reconcile(allocator, path);
            return;
        }

        std.debug.print("labelle: warning: no screenshot was written (looked for '{s}'", .{self.resolved});
        for (screenshot_suffixes) |suffix| std.debug.print(", '{s}{s}'", .{ self.resolved, suffix });
        std.debug.print(")\n", .{});
        if (stale_exact) {
            std.debug.print("  note: '{s}' exists but is unchanged — it is left over from an earlier run, not this one\n", .{self.resolved});
        }
        std.debug.print("  hint: capture needs a native surface on some backends — a headless bgfx device has no backbuffer to read back\n\n", .{});
    }

    /// The capture landed at `written`. Put it on the requested path when
    /// the CLI can (cli#356) — a same-format move, or a decode/re-encode
    /// through the vendored stb — then print where the file REALLY is.
    ///
    /// Every branch prints exactly one `screenshot written to` line naming
    /// the path that now holds the capture, so the line stays the
    /// authoritative one a script can parse.
    fn reconcile(self: ScreenshotProbe, allocator: std.mem.Allocator, written: []const u8) void {
        const plan = screenshot_format.plan(self.resolved, written);
        switch (plan) {
            .honored => std.debug.print("labelle: screenshot written to '{s}'\n", .{written}),
            .keep => {
                std.debug.print("labelle: screenshot written to '{s}'\n", .{written});
                if (screenshot_format.formatFromPath(self.resolved) == null) {
                    std.debug.print("  note: the backend appended its own extension — '{s}' names no image format, so the capture was left as written\n", .{self.resolved});
                } else {
                    std.debug.print("  note: the backend wrote a format this CLI cannot decode — the requested path '{s}' was not written\n", .{self.resolved});
                }
            },
            .move, .transcode => {
                screenshot_format.apply(allocator, plan, self.resolved, written) catch |err| {
                    // The capture still exists where the backend put it, so
                    // report THAT path — the old pre-#356 behaviour, which is
                    // the honest fallback when the conversion cannot happen.
                    std.debug.print("labelle: screenshot written to '{s}'\n", .{written});
                    std.debug.print("  note: the backend did not honor '{s}' and the CLI could not rewrite it ({s})\n", .{ self.resolved, @errorName(err) });
                    return;
                };
                std.debug.print("labelle: screenshot written to '{s}'\n", .{self.resolved});
                switch (plan) {
                    .move => std.debug.print("  note: the backend wrote '{s}'; moved onto the requested path\n", .{written}),
                    .transcode => |t| std.debug.print("  note: the backend wrote {s} to '{s}'; re-encoded as {s} at the requested path\n", .{ t.from.label(), written, t.to.label() }),
                    else => unreachable,
                }
            },
        }
    }
};

/// The post-run screenshot report end to end (cli#356): a backend that
/// appended its own extension is reconciled onto the requested path.
///
/// Drives the REAL `ScreenshotProbe` — pre-run fingerprint, suffix scan,
/// change detection, reconcile — rather than `screenshot_format` alone, so
/// the wiring between them is covered too. `report` prints to stderr, so
/// the `labelle: screenshot written to ...` lines in the test log are the
/// actual user-facing output.
pub const ScreenshotProbeSpec = struct {
    /// `ScreenshotProbe` resolves relative paths against the game's cwd and
    /// then works from the process cwd, and `std.testing.tmpDir` creates its
    /// directory under a cwd-relative `.zig-cache/tmp/`, so a cwd-relative
    /// `run_cwd` addresses exactly the files the tmp dir holds.
    fn runCwd(allocator: std.mem.Allocator, tmp: std.testing.TmpDir) ![]u8 {
        return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    }

    test "a .png request the backend answered with .png.tga lands as a PNG" {
        const a = std.testing.allocator;
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const run_cwd = try runCwd(a, tmp);
        defer a.free(run_cwd);

        // Fingerprint BEFORE the "run", exactly as the pipeline does.
        const probe = ScreenshotProbe.init(a, "shot.png", run_cwd).?;
        defer probe.deinit(a);

        // The "backend" writes TGA under the doubly-wrong name.
        try screenshot_format.writeTestFixture(a, tmp.dir, "shot.png.tga", .tga);

        probe.report(a);

        const out = try tmp.dir.readFileAlloc(io, "shot.png", a, .unlimited);
        defer a.free(out);
        try std.testing.expect(std.mem.startsWith(u8, out, "\x89PNG\r\n\x1a\n"));
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "shot.png.tga", .{}));
    }

    test "a capture left over from an earlier run is not reconciled" {
        const a = std.testing.allocator;
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const run_cwd = try runCwd(a, tmp);
        defer a.free(run_cwd);

        // Stale file exists BEFORE the probe fingerprints it, and the "run"
        // writes nothing. Touching it would turn a failed capture into a
        // report of a screenshot this run never took.
        try screenshot_format.writeTestFixture(a, tmp.dir, "shot.png.tga", .tga);
        const probe = ScreenshotProbe.init(a, "shot.png", run_cwd).?;
        defer probe.deinit(a);

        probe.report(a);

        _ = try tmp.dir.statFile(io, "shot.png.tga", .{});
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "shot.png", .{}));
    }

    test "an extension-less request is left where the backend put it" {
        const a = std.testing.allocator;
        const io = config.globalIo();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const run_cwd = try runCwd(a, tmp);
        defer a.free(run_cwd);

        const probe = ScreenshotProbe.init(a, "shot", run_cwd).?;
        defer probe.deinit(a);

        try screenshot_format.writeTestFixture(a, tmp.dir, "shot.tga", .tga);

        probe.report(a);

        // Nothing was asked for, so `shot.tga` is the better name of the two.
        _ = try tmp.dir.statFile(io, "shot.tga", .{});
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "shot", .{}));
    }
};

pub const CollectPrebuildIgnorePathsSpec = struct {
    const steps: []const prebuild.Step = &.{
        .{ .run = &.{ "python3", "tools/gen.py" }, .outputs = &.{ "assets/out.png", "src/table.zig" } },
        .{ .run = &.{"./tools/nothing.sh"} }, // declares no outputs
    };

    fn free(a: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
        for (list.items) |f| a.free(f);
        list.deinit(a);
    }

    pub const hooks_enabled = struct {
        test "every declared output is excluded from the watch signature" {
            const a = std.testing.allocator;
            var got = collectPrebuildIgnorePaths(a, "/proj", steps, true);
            defer free(a, &got);

            try std.testing.expectEqual(@as(usize, 2), got.items.len);
            // Build the expectation with the SAME resolver the collector
            // uses. Re-implementing the join here (even via `std.fs.path.join`)
            // is not host-portable: `join` inserts the native separator
            // between its arguments but leaves the '/' inside a relative
            // path alone, so on Windows it yields `/proj\assets/out.png`
            // while `watchIgnorePath` normalises to `/proj\assets\out.png`.
            // This spec's subject is WHICH outputs are excluded, not how a
            // path is spelled — that belongs to `watchIgnorePath`'s own tests.
            const png = try serve.watchIgnorePath(a, "/proj", "assets/out.png");
            defer a.free(png);
            try std.testing.expectEqualStrings(png, got.items[0]);
        }

        test "a step that declares no outputs contributes nothing" {
            const a = std.testing.allocator;
            var got = collectPrebuildIgnorePaths(a, "/proj", steps[1..], true);
            defer free(a, &got);
            try std.testing.expectEqual(@as(usize, 0), got.items.len);
        }
    };

    // cli#361 review: with `LABELLE_NO_PREBUILD=1` the rebuild callback never
    // writes these files, so excluding them only hid an out-of-band
    // regeneration — a documented use of the kill switch — from the watcher,
    // leaving the browser on a stale build.
    pub const hooks_disabled = struct {
        test "the kill switch leaves declared outputs in the watch set" {
            const a = std.testing.allocator;
            var got = collectPrebuildIgnorePaths(a, "/proj", steps, false);
            defer free(a, &got);
            try std.testing.expectEqual(@as(usize, 0), got.items.len);
        }
    };
};

pub const ResolveExportOutputSpec = struct {
    // The export dir is wiped on every run, so a destructive `--output`
    // must be refused before it can delete the user's source tree.
    pub const rejects_destructive = struct {
        test "--output . (the project dir) is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "."),
            );
        }

        test "--output .. (an ancestor) is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", ".."),
            );
        }

        test "--output ../.. (a higher ancestor) is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "../.."),
            );
        }

        test "--output / (filesystem root) is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "/"),
            );
        }

        test "an absolute --output equal to the project dir is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "/proj/root"),
            );
        }

        test "an absolute --output that is an ancestor of the project is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "/proj"),
            );
        }

        test "foo/../.. collapsing to an escape is rejected" {
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(std.testing.allocator, "/proj/root", "foo/../.."),
            );
        }
    };

    pub const accepts_dedicated = struct {
        test "a dedicated subdir under the project is accepted" {
            const a = std.testing.allocator;
            const out = try resolveExportOutput(a, "/proj/root", "release");
            defer a.free(out);
            // Compare against `join` rather than a hardcoded "/" so the
            // assertion holds on Windows (where join uses '\\').
            const want = try std.fs.path.join(a, &.{ "/proj/root", "release" });
            defer a.free(want);
            try std.testing.expectEqualStrings(want, out);
        }

        test "a nested dedicated subdir is accepted" {
            const a = std.testing.allocator;
            const out = try resolveExportOutput(a, "/proj/root", "dist/web");
            defer a.free(out);
            const want = try std.fs.path.join(a, &.{ "/proj/root", "dist/web" });
            defer a.free(want);
            try std.testing.expectEqualStrings(want, out);
        }

        test "an unrelated absolute --output is accepted verbatim" {
            // "/tmp/..." is absolute on POSIX and "rooted" (absolute) on
            // Windows, so it returns verbatim on both.
            const out = try resolveExportOutput(std.testing.allocator, "/proj/root", "/tmp/exports/game");
            defer std.testing.allocator.free(out);
            try std.testing.expectEqualStrings("/tmp/exports/game", out);
        }
    };

    // Windows treats both '/' and '\\' as separators and its filesystem is
    // case-insensitive. These run only on Windows CI (skipped elsewhere)
    // so the directory-wiping guard is actually exercised for those shapes
    // — a hardcoded '/' comparison here would wrongly allow a destructive
    // backslash/drive-letter `--output`.
    pub const windows_separators = struct {
        test "upward escapes via '\\' or mixed separators are rejected" {
            if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
            const a = std.testing.allocator;
            for ([_][]const u8{ "..\\secret", "../secret", "foo\\..\\..", "foo/..\\.." }) |esc| {
                try std.testing.expectError(
                    error.DestructiveOutputPath,
                    resolveExportOutput(a, "C:\\proj\\root", esc),
                );
            }
        }

        test "a case-differing absolute ancestor is rejected" {
            if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
            const a = std.testing.allocator;
            // Same directory on Windows (case-insensitive) — must be
            // treated as a destructive ancestor, not wrongly accepted.
            try std.testing.expectError(
                error.DestructiveOutputPath,
                resolveExportOutput(a, "C:\\Proj\\Root", "c:\\proj"),
            );
        }

        test "a dedicated backslash subdir is accepted" {
            if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
            const a = std.testing.allocator;
            const out = try resolveExportOutput(a, "C:\\proj\\root", "release");
            defer a.free(out);
            const want = try std.fs.path.join(a, &.{ "C:\\proj\\root", "release" });
            defer a.free(want);
            try std.testing.expectEqualStrings(want, out);
        }
    };
};
