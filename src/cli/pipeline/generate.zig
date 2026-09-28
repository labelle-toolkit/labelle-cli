//! The generate stage: the `generate` hook phases around the core
//! generation (the ASTC and `--bake` prepasses, `assembler generate`, the
//! fingerprint pass, emsdk activation), and the shader-override re-gate
//! after the `before generate` hooks.
const std = @import("std");
const config = @import("../config.zig");
const runner = @import("../runner.zig");
const assembler_proc = @import("../assembler_proc.zig");
const emsdk_toolchain = @import("../emsdk_toolchain.zig");
const emsdk_activate = @import("../emsdk_activate.zig");
const python_provision = @import("../python_provision.zig");
const material_toolchain = @import("../material_toolchain.zig");
const bake_mod = @import("../bake.zig");
const progress = @import("../progress.zig");
const astc_cmd = @import("../../astc/cmd.zig");
const provider_contract = @import("../provider_contract.zig");
const provider_dispatch = @import("../provider_dispatch.zig");
const provider_hooks = @import("../provider_hooks.zig");
const provider_env = @import("../provider_env.zig");
const Context = @import("context.zig").Context;
const gateThenInstall = @import("install.zig").gateThenInstall;

/// Issue #217 phase 2: delegate code generation to the standalone
/// labelle-assembler binary via the shared subprocess harness, instead
/// of calling an in-process generator. The binary was located above
/// (`asm_bin`) and already used for the `install` cache-populate step.
///
/// `build` / `run` are not assembler subcommands: the subsequent
/// `zig build` invocation and binary launch stay CLI-side (see below).
/// The CLI owns docker orchestration, the WASM serve loop, the
/// iOS deploy path and `--timeout` — generation is the only
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
            .legacy_target = target.legacy != null,
            .bake = parsed_args.bake,
            .fatal = true,
        });

        // The assembler receives the resolved target NAME; the #378 gate above
        // guarantees it is one the pinned assembler can take.
        try assembler_proc.generate(
            cx.asm_bin,
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
        //
        // Unless a provider hook of this build already contributed the
        // toolchain root through its `env_file` (contract §2, wire 1.3.0+):
        // that provider owns the toolchain the build then consumes, and
        // activating the fetched package too would install a second copy
        // (~1 GB) nothing uses. Projects without such a provider keep this
        // path unchanged.
        const provider_toolchain = !parsed_args.docker and parsed.platform == .wasm and hook_site.env.sets(toolchain_root_var);
        if (provider_toolchain) {
            std.debug.print("labelle: {s} comes from a provider hook; skipping the core Python preflight and fetched-toolchain activation\n", .{toolchain_root_var});
        }
        if (coreActivatesToolchain(parsed_args.docker, parsed.platform == .wasm, &hook_site.env)) {
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
            emsdk_activate.activateFetchedEmsdk(allocator, cx.target_dir, resolved_emsdk.version);
        }
    }
    {
        const code = try provider_hooks.runPhase(hook_site, hook_plans.generate.after, .generate, .after, generate_out);
        if (code != 0) return code;
    }
    return null;
}

/// The variable the fetched-toolchain activation exists to supply: the
/// generated build's link step reads it, and so do the backends. A provider
/// hook that contributes it owns the toolchain.
pub const toolchain_root_var = "EMSDK";

/// Whether the core runs its Python preflight and activates the fetched
/// toolchain package after generation: a host (not docker) wasm build whose
/// provider hooks did not contribute `toolchain_root_var` (`contributed` is
/// the build's accumulated `env_file` environment at that point: the
/// `before generate` hooks').
pub fn coreActivatesToolchain(docker: bool, wasm: bool, contributed: *const provider_env.Accumulator) bool {
    return !docker and wasm and !contributed.sets(toolchain_root_var);
}

test "pipeline: a provider-contributed toolchain root skips the core toolchain activation" {
    const a = std.testing.allocator;
    var diag: provider_env.Diagnostic = .{};
    var none: provider_env.Accumulator = .{};
    defer none.deinit();
    // No provider contribution: today's behaviour, host builds only.
    try std.testing.expect(coreActivatesToolchain(false, true, &none));
    try std.testing.expect(!coreActivatesToolchain(true, true, &none));
    try std.testing.expect(!coreActivatesToolchain(false, false, &none));
    // An unrelated contribution changes nothing.
    var other: provider_env.Accumulator = .{};
    defer other.deinit();
    try other.add(a, a, "pkg/tc", .{ .set = &.{.{ .name = "PROBE_TOOLCHAIN", .value = "x" }}, .path_prepend = &.{if (provider_env.native_windows) "C:\\tc\\bin" else "/tc/bin"} }, &diag);
    try std.testing.expect(coreActivatesToolchain(false, true, &other));
    // The provider supplies the root: the core stands down.
    var supplied: provider_env.Accumulator = .{};
    defer supplied.deinit();
    try supplied.add(a, a, "pkg/tc", .{ .set = &.{.{ .name = toolchain_root_var, .value = if (provider_env.native_windows) "C:\\sdk" else "/sdk" }} }, &diag);
    try std.testing.expect(!coreActivatesToolchain(false, true, &supplied));
}

/// How the core generation's pre-passes run (`corePrepasses`).
pub const Prepass = struct {
    /// The target is one the `asset_compression` schema knows.
    legacy_target: bool,
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
    // ASTC build-time conversion (#340): when this platform ships ASTC atlases
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
    // Only for a target the asset_compression schema knows (`target.legacy`:
    // `desktop` or a schema-named provider target). A provider target
    // outside the enum has `parsed.platform` derived as `.desktop` for the
    // legacy sites, but it is NOT the desktop target: running the desktop
    // prepass for it would use the wrong compression setting (Codex on
    // #421). Its provider owns its asset pipeline; standalone `cmdAstc`
    // can read capabilities for any declared target name.
    if (opts.legacy_target and parsed.asset_compression.formatFor(parsed.platform) == .astc) {
        // Pass the RESOLVED target: `--platform=wasm` and `labelle ios`
        // (forces sokol) differ from what
        // project.labelle declares, and the loadable blocks depend on both.
        astc_cmd.cmdAstc(allocator, &.{
            project_dir,
            "--platform",
            @tagName(parsed.platform),
            "--backend",
            @tagName(parsed.backend),
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
            // below would be a lie. Stop instead (labelle-bgfx#134).
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
