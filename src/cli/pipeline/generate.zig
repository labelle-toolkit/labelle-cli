//! The generate stage: the `generate` hook phases around the core
//! generation (the ASTC and `--bake` prepasses, `assembler generate`, the
//! fingerprint pass), and the shader-override re-gate
//! after the `before generate` hooks.
const std = @import("std");
const config = @import("../config.zig");
const runner = @import("../runner.zig");
const assembler_proc = @import("../assembler_proc.zig");
const assembler_describe = @import("../assembler_describe.zig");
const material_toolchain = @import("../material_toolchain.zig");
const bake_mod = @import("../bake.zig");
const progress = @import("../progress.zig");
const astc_cmd = @import("../../astc/cmd.zig");
const provider_contract = @import("../provider_contract.zig");
const provider_dispatch = @import("../provider_dispatch.zig");
const provider_hooks = @import("../provider_hooks.zig");
const Context = @import("context.zig").Context;
const gateThenInstall = @import("install.zig").gateThenInstall;

/// Issue #217 phase 2: delegate code generation to the standalone
/// labelle-assembler binary via the shared subprocess harness, instead
/// of calling an in-process generator. The binary was located above
/// (`asm_bin`) and already used for the `install` cache-populate step.
///
/// `build` / `run` are not assembler subcommands: the subsequent
/// `zig build` invocation and binary launch stay CLI-side (see below).
/// The CLI owns docker orchestration, the watch supervision and
/// `--timeout` — generation is the only
/// step the assembler binary delegates.
/// `parsed_args.scene_override` is intentionally NOT forwarded to the
/// assembler. PR #243 removed the CLI's `cfg.initial_prefab` rewrite for
/// exactly this reason; the assembler's own `--scene` handling does the
/// same rewrite, which bypasses any loading-scene gate the project
/// declares. The override is delivered at runtime via the
/// `LABELLE_SCENE` env var injected at the spawn site (~line 990).
///
/// (The shader-compiler override gate used to run here. It now runs in
/// `gateThenInstall`, ahead of the network-bound package install — see
/// cli#387 gap 3.)
///
/// Provider hooks on `generate` (contract §6): `before` hooks, then the
/// core generation — or its unique `replace` hook — then `after` hooks.
/// `output_dir` is the generated tree itself. A failing hook ends the
/// command with the hook's own exit code; nothing past it runs.
///
/// The `before` phase runs ahead of EVERY generation-input reader: the
/// ASTC conversion pre-pass and the `--bake` pre-pass both consume the
/// declared PNGs, so a hook that produces one of them used to run too
/// late for them — `generate --bake` failed on the not-yet-written PNG
/// and a hook-generated PNG never got its `.astc` sibling (Codex P2 on
/// #420). Both pre-passes are part of the core generation they feed, so
/// a `replace generate` hook stands in for them too: the replacement
/// owns whatever preprocessing its generation needs.
///
/// The shader-compiler override is gated again right after the `before`
/// phase (`beforeGenerate`): a hook may be what creates `materials/`.
///
/// Returns the exit status the command ends with, or null to go on.
pub fn run(cx: *const Context, generate_out: []const u8) !?u8 {
    const allocator = cx.allocator;
    const parsed = cx.parsed;
    const parsed_args = cx.parsed_args;
    const project_dir = cx.project_dir;
    const target = cx.target;
    const hook_site = cx.hook_site;
    const hook_plans = cx.hook_plans;

    {
        const gate: *const fn (std.mem.Allocator, []const u8) anyerror!void = if (parsed_args.docker) material_toolchain.preflightDocker else material_toolchain.preflight;
        const code = try beforeGenerate(hook_site, hook_plans.generate.before, generate_out, project_dir, gate);
        if (code != 0) return code;
    }
    core_generate: {
        if (hook_plans.generate.replace) |replacement| {
            const code = try provider_hooks.runPhase(hook_site, &.{replacement}, .generate, .replace, generate_out);
            if (code != 0) return code;
            break :core_generate;
        }

        try corePrepasses(allocator, project_dir, parsed, .{
            .target = target.name,
            .describer = .init(cx.asm_bin, project_dir),
            .bake = parsed_args.bake,
            .fatal = true,
        });

        // The assembler receives the resolved target NAME; the gate after the
        // install (`describe`'s `supported`) guarantees it can take it.
        try assembler_proc.generate(cx.asm_bin, allocator, project_dir, target.name);

        // (`target_name`/`target_dir` — .labelle/<backend>_<target>/, named by `describe` — are
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
            try runner.fixFingerprints(allocator, project_dir, cx.output_dir, &hook_site.env);
        } else {
            const tests_dir = try std.fs.path.join(allocator, &.{ cx.output_dir, "tests" });
            defer allocator.free(tests_dir);
            const tests_build_zig = try std.fs.path.join(allocator, &.{ tests_dir, "build.zig" });
            defer allocator.free(tests_build_zig);
            if (std.Io.Dir.cwd().access(config.globalIo(), tests_build_zig, .{})) |_| {
                try runner.fixFingerprint(allocator, project_dir, tests_dir, &hook_site.env);
            } else |_| {}
        }
        // (`labelle.lock` was written before generation — see the provider
        // hook note beside `validatePluginCoreCompat`.)
        std.debug.print("  generated .labelle/{s}/\n", .{cx.target_name});
    }
    {
        const code = try provider_hooks.runPhase(hook_site, hook_plans.generate.after, .generate, .after, generate_out);
        if (code != 0) return code;
    }
    return null;
}

/// How the core generation's pre-passes run (`corePrepasses`).
pub const Prepass = struct {
    /// The resolved target name: the ASTC conversion runs for it.
    target: []const u8,
    /// Asks the assembler whether the target ships ASTC atlases
    /// (`describe`'s `asset_format`, from `.asset_compression` keyed by the
    /// target name). `off`, or no answer, means PNG: no conversion.
    describer: assembler_describe.Describer,
    /// `--bake`.
    bake: bool,
    /// A misconfiguration ends the command (the cold pipeline) rather than
    /// failing with an error (a watched rebuild, which must keep the
    /// session alive).
    fatal: bool,
};

/// The generation-input pre-passes the core generation runs before the
/// assembler: the ASTC conversion and the `--bake` pre-bake. The cold
/// pipeline and every watched rebuild run this same function, so an edited
/// source PNG reaches a rebuild's `.astc`/`.rgba` siblings exactly as it
/// reaches a cold build's.
pub fn corePrepasses(allocator: std.mem.Allocator, project_dir: []const u8, parsed: @import("../project_config.zig").ProjectConfig, opts: Prepass) anyerror!void {
    // ASTC build-time conversion (#340): when the target ships ASTC atlases
    // (`asset_compression`), run `labelle astc` first so the `<name>.astc`
    // siblings exist for the assembler's catalog `.png → .astc` swap. Runs
    // before the assembler's `generate` (it only needs project.labelle + the
    // PNGs + astcenc). Non-fatal — on any failure the assembler finds no
    // sibling and falls back to the source PNG, so the build still succeeds.
    //
    // EXCEPT a misconfiguration. `ConflictingAstcBlocks` means two atlases
    // compile to one `.astc` with disagreeing block pins; falling back would
    // hand BOTH of them whatever `.astc` is on disk — including a STALE one
    // from an earlier build, which is worse than no atlas because it looks
    // like it worked. So a config error stops the build, while a conversion
    // failure still degrades to PNG.
    //
    // Whether the target ships ASTC is the assembler's answer (cli#471 P3):
    // `describe` reads `.asset_compression` by the target NAME, so a provider
    // target never borrows another target's setting (Codex on #421), and the
    // CLI keeps no mirror of the schema. Asked on every generation, so a
    // watched rebuild follows an edited `.asset_compression`.
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const described = opts.describer.query(scratch.allocator(), opts.target);
    if (described != null and std.mem.eql(u8, described.?.asset_format, "astc")) {
        // Pass the RESOLVED target: `--platform=<t>` may differ from what
        // project.labelle declares, and the loadable blocks depend on it.
        // No backend: `labelle astc` reads the project's own (cli#471 D4).
        astc_cmd.cmdAstc(allocator, &.{
            project_dir,
            "--platform",
            opts.target,
        }) catch |err| switch (err) {
            error.InvalidTextureCapabilities => {
                if (!opts.fatal) return err;
                progress.fatalExit(1, "cannot resolve backend texture capabilities — see the error above");
            },
            error.ConflictingAstcBlocks => {
                if (!opts.fatal) return err;
                progress.fatalExit(1, "conflicting .astc_block pins compile to one .astc — see the error above");
            },
            // A stale `.astc` (wrong block for this target) that could not be
            // deleted would be swapped in by the assembler — the PNG fallback
            // below would be a lie. Stop instead.
            error.StaleAstcSiblingUndeletable => {
                if (!opts.fatal) return err;
                progress.fatalExit(1, "a stale .astc sibling could not be deleted — see the error above");
            },
            else => std.debug.print(
                "labelle: ASTC conversion failed ({s}); falling back to PNG atlases\n",
                .{@errorName(err)},
            ),
        };
    }

    // Opt-in PNG → LRGBA pre-bake. Runs before the assembler so its
    // @embedFile path picks up the fresh `.rgba` files. Skipped unless
    // `--bake` is passed: raw RGBA expands heavily-transparent atlases
    // by 100×+ (a 200 KB PNG can become 64 MB), so default-off keeps
    // packaged sizes sane. Use for projects whose atlases are nearly opaque
    // and PNG decode dominates cold start.
    if (opts.bake) {
        bake_mod.run(allocator, project_dir, parsed.resources) catch |err| {
            std.debug.print("labelle: bake failed: {s}\n", .{@errorName(err)});
            return err;
        };
    }
}

/// The cold pipeline's `before generate` phase, then the shader-compiler
/// override gate AGAIN. `gateThenInstall` validated the override before the
/// install, but a before-generate hook may be what creates `materials/`:
/// with no consumer at that point the gate passed, and an unusable
/// `LABELLE_SHADERC` then failed generation or the build with the opaque
/// error the gate exists to replace (Codex P2 on #420). The re-check runs
/// only when hooks ran — otherwise nothing changed since the first one —
/// and before every core generation input reader. On success the progress
/// detail is back on the core step (`provider_hooks.runBefore`).
pub fn beforeGenerate(
    site: *provider_hooks.Site,
    before: []const provider_hooks.Planned,
    output_dir: []const u8,
    project_dir: []const u8,
    gate: *const fn (std.mem.Allocator, []const u8) anyerror!void,
) !u8 {
    const code = try provider_hooks.runBefore(site, before, .generate, output_dir, "assembler generate");
    if (code != 0) return code;
    if (before.len != 0) try gate(site.backing, project_dir);
    return 0;
}

test "pipeline: the shader override is re-gated after the before-generate hooks" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = config.globalIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    try tmp.dir.writeFile(io, .{
        .sub_path = "project/labelle.lock",
        .data = ".{ .plugins = .{ .{ .name = \"pkg\", .repo = \"local:../pkg\", .version = \"1.0.0\" } } }",
    });
    const Fixture = struct {
        var provider: provider_dispatch.Provider = .{
            .dep = .{ .name = "pkg", .repo = "local:../pkg", .version = "1.0.0" },
            .dir = "/pkg",
            .meta = .{ .name = "pkg", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0" },
            .verified = true,
        };
        var materials: []const u8 = "";
        var hook_ran = false;
        var gate_ran = false;
        // The before-generate hook creates `materials/`, the shape the
        // startup gate could not see.
        fn hook(_: std.mem.Allocator, _: provider_dispatch.Host, _: []const u8, _: provider_dispatch.Provider, _: provider_contract.Tool, _: provider_dispatch.ToolRun) anyerror!u8 {
            hook_ran = true;
            try std.Io.Dir.cwd().createDirPath(config.globalIo(), materials);
            return 0;
        }
        // The same gate the cold path runs, with the env read replaced by a
        // known-bad value.
        fn badOverride(alloc: std.mem.Allocator, dir: []const u8) anyerror!void {
            gate_ran = true;
            return material_toolchain.preflightWith(alloc, dir, "shaderc", .native);
        }
    };
    Fixture.materials = try std.fs.path.join(a, &.{ project, "materials" });
    // The startup gate (before the install) passes: no `materials/` yet.
    try gateThenInstall(a, project, Fixture.badOverride, struct {
        pub fn install(_: @This(), _: std.mem.Allocator, _: []const u8) !void {}
    }{});
    const planned: provider_hooks.Planned = .{
        .provider = &Fixture.provider,
        .hook = .{ .id = "gen", .step = .generate, .target = "desktop", .when = .before, .build_step = "tool", .executable = "bin/tool" },
        .qualified = "pkg/gen",
    };
    var site: provider_hooks.Site = .{
        .a = a,
        .backing = std.testing.allocator,
        .providers = &.{Fixture.provider},
        .root = project,
        .cfg = .{ .name = "game" },
        .target = "desktop",
        .target_dir = project,
        .optimize = .Debug,
        .progress = .off,
        .reporter = null,
        .final_step = .build,
        .host = .{ .zig = "/z", .cache_root = project, .global_cache = project, .packages = project },
        .run_tool = Fixture.hook,
    };
    // No hooks: nothing could have changed, so the gate is not re-run.
    Fixture.gate_ran = false;
    try std.testing.expectEqual(@as(u8, 0), try beforeGenerate(&site, &.{}, project, project, Fixture.badOverride));
    try std.testing.expect(!Fixture.gate_ran);
    // The hook creates `materials/`; the re-check fires after it and stops
    // the command before any core generation.
    try std.testing.expectError(error.ShadercOverrideMustBeAbsolute, beforeGenerate(&site, &.{planned}, project, project, Fixture.badOverride));
    try std.testing.expect(Fixture.hook_ran and Fixture.gate_ran);
}
