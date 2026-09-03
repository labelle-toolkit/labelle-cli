const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Version from build.zig.zon, overridable via -Dversion (used by CI release)
    const version: []const u8 = b.option([]const u8, "version", "Override version string (e.g. from git tag)") orelse @import("build.zig.zon").version;

    // Library versions from versions.zon — the tested compatible set for this CLI release
    const versions = @import("versions.zon");

    // ── Build options ────────────────────────────────────────────────
    // Issue #217: the CLI is a thin driver over the standalone
    // labelle-assembler binary and no longer links the assembler's
    // `generator` module. The `project.labelle` schema the CLI reads
    // (src/cli/project_config.zig) pins default framework versions and
    // the CLI version — those come from this `build_options` module
    // instead of the assembler package's build options.
    const options = b.addOptions();
    options.addOption([]const u8, "cli_version", version);
    options.addOption([]const u8, "core_version", versions.core);
    options.addOption([]const u8, "engine_version", versions.engine);
    options.addOption([]const u8, "gfx_version", versions.gfx);
    options.addOption([]const u8, "bgfx_version", versions.bgfx);
    const build_options_mod = options.createModule();

    const gen_exe = b.addExecutable(.{
        .name = "labelle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    wireStb(b, gen_exe.root_module);
    b.installArtifact(gen_exe);

    const gen_run = b.addRunArtifact(gen_exe);
    if (b.args) |args| {
        gen_run.addArgs(args);
    }
    const gen_step = b.step("generate", "Generate assembler from project.labelle");
    gen_step.dependOn(&gen_run.step);

    // ── Tests ────────────────────────────────────────────────────────
    const zspec_dep = b.dependency("zspec", .{ .target = target, .optimize = optimize });

    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = build_options_mod },
                .{ .name = "zspec", .module = zspec_dep.module("zspec") },
            },
        }),
    });
    wireStb(b, cli_tests.root_module);
    const run_cli_tests = b.addRunArtifact(cli_tests);
    const test_step = b.step("test", "Run CLI unit tests");
    test_step.dependOn(&run_cli_tests.step);

    // ── Progress-feed subprocess e2e (cli#319) ───────────────────────
    // Spawns the REAL built CLI (`zig-out/bin/labelle build
    // --progress=json`) on a scaffolded fixture and asserts the NDJSON
    // feed contract, the live status file from a concurrent process, and
    // the forced-compile-failure variant. NOT part of `zig build test`:
    // it needs sibling checkouts (labelle-core/-engine/-gfx/-assembler)
    // and a built assembler binary, so it is opt-in via env — the test
    // skips unless LABELLE_E2E_DEPS and LABELLE_ASSEMBLER are set (see
    // the header of test/progress_e2e.zig). CI runs it in the dedicated
    // `progress-e2e` job. Depends on the install step so the binary
    // under test is always fresh.
    const progress_e2e_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/progress_e2e.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_progress_e2e = b.addRunArtifact(progress_e2e_tests);
    const e2e_step = b.step("test-e2e", "Run the progress-feed subprocess e2e (opt-in: needs LABELLE_E2E_DEPS + LABELLE_ASSEMBLER)");
    e2e_step.dependOn(b.getInstallStep());
    e2e_step.dependOn(&run_progress_e2e.step);

    // Build-time ASTC conversion core (assembler#340). `src/astc/convert.zig`
    // is pure command/path/cache logic (std-only), so it runs standalone on the
    // host — independent of the full CLI module graph.
    const astc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/astc/convert.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(astc_tests).step);
}

/// Compile the vendored stb implementation (PNG/TGA/BMP decode, and
/// PNG/BMP/TGA/JPEG encode) and put its headers on the include path.
/// Three consumers `@cImport` those headers: `src/cli/bake.zig` (decode,
/// for the PNG→LRGBA prebake), `src/texpack/` (decode + encode, for
/// `labelle pack`), and `src/cli/screenshot_format.zig` (decode + encode,
/// to re-encode a `--screenshot` capture into the requested format —
/// cli#356). A single `.c` provides one definition of the symbols for all.
fn wireStb(b: *std.Build, mod: *std.Build.Module) void {
    mod.addCSourceFile(.{
        .file = b.path("src/cli/stb_image_impl.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addIncludePath(b.path("src/cli"));
    mod.link_libc = true;
}
