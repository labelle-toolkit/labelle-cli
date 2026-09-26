"""Provider-declared targets and --platform resolution through the real CLI.

python test/provider_targets_e2e.py --zig /absolute/path/to/zig [--cli ...]

Hermetic: a fake assembler (the plugin_compat pattern) records the target it
was asked to generate for, and the `test/fixtures/provider` tool serves as
every provider. No network, no game dependencies. Runs on Windows, macOS
and Linux; every workspace is temporary.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--zig", default=shutil.which("zig"))
parser.add_argument("--cli", default=str(Path(__file__).resolve().parents[1] / "zig-out" / "bin" / ("labelle.exe" if os.name == "nt" else "labelle")))
options = parser.parse_args()
assert options.zig, "pass --zig or put zig on PATH"
zig = str(Path(options.zig).resolve())
cli = str(Path(options.cli).resolve())
version = subprocess.check_output([zig, "version"], text=True).strip()
fixture = Path(__file__).parent / "fixtures" / "provider"

# The fake assembler answers the protocol probe, `install` and `generate`.
# `generate` names the target it received on stderr and writes the trivial
# host executable of the hooks suite into `.labelle/<backend>_<target>/`.
# `install` populates the package cache from FAKE_INSTALL_PLUGIN="<src>|<dest>"
# when set (a remote package landing in the ordinary cache), and only
# prints otherwise.
FAKE_ASSEMBLER = '''import os, shutil, sys
from pathlib import Path
argv = sys.argv[1:]
if argv and argv[0] == "--protocol-version":
    print(99)
elif argv and argv[0] == "install":
    if os.environ.get("FAKE_INSTALL_PLUGIN"):
        src, dest = os.environ["FAKE_INSTALL_PLUGIN"].split("|")
        shutil.copytree(src, dest, dirs_exist_ok=True)
    print("FIXTURE_INSTALL_DONE", file=sys.stderr, flush=True)
elif argv and argv[0] == "generate":
    root = Path(argv[argv.index("--project-root") + 1])
    backend = argv[argv.index("--backend") + 1]
    platform_name = argv[argv.index("--platform") + 1]
    target = root / ".labelle" / f"{backend}_{platform_name}"
    target.mkdir(parents=True, exist_ok=True)
    (target / "build.zig").write_text(
        'const std = @import("std");\\n'
        'pub fn build(b: *std.Build) void {\\n'
        '    const exe = b.addExecutable(.{ .name = "game", .root_module = b.createModule(.{\\n'
        '        .root_source_file = b.path("main.zig"), .target = b.graph.host,\\n'
        '        .optimize = b.standardOptimizeOption(.{}) }) });\\n'
        '    b.installArtifact(exe);\\n'
        '}\\n')
    (target / "main.zig").write_text("pub fn main() void {}\\n")
    print(f"FIXTURE_GENERATE platform={platform_name}", file=sys.stderr, flush=True)
else:
    raise SystemExit("unexpected assembler invocation: " + repr(sys.argv))
'''

TOOL = '.build_step = "probe-tool", .executable = "bin/provider-probe"'
NO_PROVIDER = ("labelle: no provider for target '{t}' in this project; "
               "add and pin the package that declares target '{t}'")


def hook(id, step, when, target):
    return f'.{{ .id = "{id}", .step = .{step}, .target = "{target}", .when = .{when}, {TOOL} }}'


def manifest(name, targets, hooks=()):
    declared = ", ".join(json.dumps(t) for t in targets)
    attached = f',\n    .hooks = .{{ {", ".join(hooks)} }}' if hooks else ""
    return (f'.{{ .name = "{name}", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0",\n'
            f'    .targets = .{{ {declared} }}{attached} }}')


with tempfile.TemporaryDirectory(prefix="labelle-targets-") as temp:
    base = Path(temp).resolve()
    provider = base / "fixture"
    shutil.copytree(fixture, provider)
    provider_manifest = provider / "plugin.labelle"
    script = base / "fake_assembler.py"
    script.write_text(FAKE_ASSEMBLER)
    if os.name == "nt":
        assembler = base / "fake-assembler.cmd"
        assembler.write_text(f'@echo off\r\n"{sys.executable}" "{script}" %*\r\nexit /b %ERRORLEVEL%\r\n')
    else:
        assembler = base / "fake-assembler"
        assembler.write_text(f"#!/bin/sh\nexec \"{sys.executable}\" \"{script}\" \"$@\"\n")
        assembler.chmod(0o755)
    project = base / "project"
    project.mkdir()
    dep = '.{ .name = "fixture", .repo = "local:../fixture", .version = "1.0.0" }'
    home = base / "home"
    env = dict(os.environ, LABELLE_HOME=str(home), LABELLE_ZIG=zig, LABELLE_ASSEMBLER=str(assembler),
               LABELLE_NO_PREBUILD="1")
    env.pop("PROVIDER_PROBE_FAIL", None)
    checks = 0

    def declare(*deps, platform=None, extra=""):
        declared = f', .platform = .{platform}' if platform else ""
        plugins = f', .plugins = .{{ {", ".join(deps)} }}' if deps else ""
        (project / "project.labelle").write_text(
            f'.{{ .name = "game", .zig_version = "{version}"{declared}{plugins}{extra} }}')

    # LABELLE_ZIG and LABELLE_ASSEMBLER pointing nowhere: reaching either
    # would fail differently, so a success under `dead` proves neither ran.
    dead = {"LABELLE_ZIG": str(base / "nonexistent-zig"), "LABELLE_ASSEMBLER": str(base / "nonexistent-assembler")}

    def run(*args, code=0, cwd=project, extra_env=None):
        global checks
        quiet = [] if args[0] in ("help", "targets") else ["--progress=off"]
        result = subprocess.run([cli, *args, *quiet], cwd=cwd, env=dict(env, **(extra_env or {})), text=True,
                                capture_output=True, timeout=600)
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        assert "leaked" not in result.stderr, result.stderr
        checks += 1
        return result

    def reset():
        shutil.rmtree(project / ".labelle", ignore_errors=True)
        # The lock is written only past discovery; clear the previous run's
        # so `installed_only` can prove a refused target never reached it.
        (project / "labelle.lock").unlink(missing_ok=True)

    def log(step_dir):
        path = step_dir / "hooks.log"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def nothing_ran(result, target):
        """No assembler, no generated tree, no compiler."""
        assert "FIXTURE_INSTALL_DONE" not in result.stderr and "FIXTURE_GENERATE" not in result.stderr, result.stderr
        assert not (project / ".labelle").exists(), f"the pipeline ran for target {target}"

    def untouched(result, target):
        """Nothing ran, and the cache was never even created."""
        nothing_ran(result, target)
        assert not home.exists(), "the cache was touched"

    def snapshot(root):
        if not root.exists():
            return None
        return sorted((str(p.relative_to(root)), p.stat().st_size if p.is_file() else -1) for p in root.rglob("*"))

    def installed_only(result, target):
        """A verdict that needs the declared providers: discovery runs only
        once the assembler's `install` populated the package cache
        (docs/provider-hooks.md), so the install ran — and nothing after it:
        no generation, no lock, no compiler. The reporter may have created
        the target directory for its `failed` record; nothing else is in
        it."""
        assert "FIXTURE_INSTALL_DONE" in result.stderr, f"discovery ran before the package cache was populated: {result.stderr}"
        assert "FIXTURE_GENERATE" not in result.stderr, f"the assembler generated for target {target}: {result.stderr}"
        assert not (project / "labelle.lock").exists(), "the lock was written for a refused target"
        for name in (f"raylib_{target}", "raylib_desktop"):
            tree = project / ".labelle" / name
            leftovers = [p.name for p in tree.iterdir() if not p.name.startswith(".build-progress")] if tree.exists() else []
            assert not leftovers, f"the pipeline ran past discovery for target {target}: {leftovers}"

    # ── No provider: the schema name alone resolves nothing ───────────────
    declare()
    reset()
    for args in (("build", "--platform=wasm"), ("run", "--platform=wasm"), ("generate", "--platform=wasm")):
        refused = run(*args, code=1)
        assert NO_PROVIDER.format(t="wasm") in refused.stderr, refused.stderr
        assert "(registry:" not in refused.stderr, "a registry owner was invented"
        untouched(refused, "wasm")
    # The legacy subcommands request the same target and fail the same way.
    for args in (("wasm", "serve", "--no-open"), ("wasm", "export"), ("wasm", "serve", "--no-build"),
                 ("android", "build"), ("ios", "build")):
        refused = run(*args, code=1)
        expected = {"wasm": "wasm", "android": "android", "ios": "ios"}[args[0]]
        assert NO_PROVIDER.format(t=expected) in refused.stderr, (args, refused.stderr)
        untouched(refused, expected)
    # The project's own declared platform goes through the resolver too.
    declare(platform="wasm")
    refused = run("generate", code=1)
    assert NO_PROVIDER.format(t="wasm") in refused.stderr, refused.stderr
    untouched(refused, "wasm")
    declare()
    # A malformed value never reaches resolution.
    malformed = run("build", "--platform=Windows", code=1)
    assert "invalid target 'Windows'" in malformed.stderr and "labelle targets" in malformed.stderr, malformed.stderr
    untouched(malformed, "Windows")
    malformed = run("bundle", "--platform=Probe", code=1)
    assert "labelle bundle: invalid target 'Probe'" in malformed.stderr, malformed.stderr
    untouched(malformed, "Probe")
    # The core target needs nobody.
    run("generate", "--platform=desktop")
    assert (project / ".labelle" / "raylib_desktop" / "build.zig").exists()
    reset()

    # ── A provider that owns the target but replaces nothing on generate ──
    # The pinned assembler cannot generate for a name outside its enum, so
    # the build stops with the #378 message before the assembler's
    # `generate`. With a package declared, every verdict that needs its
    # manifest — this one, ownership, the bundle replacement — is reached
    # only after the install populated the cache; the target directory is
    # named after the requested target throughout.
    declare(dep)
    provider_manifest.write_text(manifest("fixture", ["probe-target"], [hook("pack", "bundle", "replace", "probe-target")]))
    for args in (("build", "--platform=probe-target"), ("generate", "--platform=probe-target"), ("bundle", "--platform=probe-target")):
        reset()
        stopped = run(*args, code=1)
        assert "target 'probe-target' is declared by 'fixture' but the pinned assembler cannot generate for it yet (labelle-assembler#378)" in stopped.stderr, stopped.stderr
        installed_only(stopped, "probe-target")
    # Ownership is per target: this provider does not make `wasm` resolvable.
    # Its manifest is local, so every declared package is readable before
    # the install and the verdict lands early — before `.prebuild`, the
    # assembler, the ASTC prepass or the install: nothing ran at all.
    reset()
    refused = run("build", "--platform=wasm", code=1)
    assert NO_PROVIDER.format(t="wasm") in refused.stderr, refused.stderr
    assert "(registry:" not in refused.stderr, "a registry owner was invented"
    untouched(refused, "wasm")
    # An identifier-shaped typo is refused the same way, and a `.prebuild`
    # step — the first side effect of the pipeline — never runs for it. The
    # control run below proves the marker step does run when a target
    # resolves, so its absence here is the early rejection, not a dead step.
    marker = project / "prebuild-ran"
    marker_script = base / "prebuild_marker.py"
    marker_script.write_text(f"from pathlib import Path\nPath({str(marker)!r}).write_text('ran')\n")
    prebuild = f', .prebuild = .{{ .{{ .run = .{{ {json.dumps(sys.executable)}, {json.dumps(str(marker_script))} }} }} }}'
    declare(dep, extra=prebuild)
    reset()
    typo = run("build", "--platform=waasm", code=1, extra_env={"LABELLE_NO_PREBUILD": "0"})
    assert NO_PROVIDER.format(t="waasm") in typo.stderr, typo.stderr
    assert not marker.exists(), "the prebuild step ran for a target nobody declares"
    untouched(typo, "waasm")
    reset()
    control = run("build", "--platform=probe-target", code=1, extra_env={"LABELLE_NO_PREBUILD": "0"})
    assert "labelle-assembler#378" in control.stderr, control.stderr
    assert marker.exists(), "the prebuild marker step did not run for a declared target"
    marker.unlink()
    declare(dep)
    # ── A remote package: read only after the install, and never an owner unpinned ──
    # Declared without an integrity pin, a remote package has no readable
    # manifest on a cold cache, so the early verdict waits and the
    # post-install discovery decides (the authoritative check, with the
    # `failed` progress record). It declares `probe-target` and a `generate`
    # replacement — but read from the ordinary cache without a pin it is an
    # UNVERIFIED provider, and a target owner is held to the pinned boundary
    # even though no hook of its would ever ask for the pin.
    remote_src = base / "fixture-remote"
    shutil.copytree(fixture, remote_src)
    (remote_src / "plugin.labelle").write_text(manifest("fixture-remote", ["probe-target"], [hook("gen", "generate", "replace", "probe-target")]))
    remote_cache = home / "packages" / "plugins" / "example" / "fixture-remote" / "1.0.0"
    dep_remote = '.{ .name = "fixture-remote", .repo = "example/fixture-remote", .version = "1.0.0" }'
    populate = {"FAKE_INSTALL_PLUGIN": f"{remote_src}|{remote_cache}"}
    UNPINNED = "target 'probe-target' is declared by remote package 'fixture-remote', which is unpinned"
    declare(dep_remote)
    # Cold: the install populates the cache, then `wasm` has no owner.
    reset()
    shutil.rmtree(home, ignore_errors=True)
    refused = run("build", "--platform=wasm", code=1, extra_env=populate)
    assert NO_PROVIDER.format(t="wasm") in refused.stderr, refused.stderr
    installed_only(refused, "wasm")
    assert remote_cache.exists(), "the fake install did not populate the cache"
    status = json.loads((project / ".labelle" / "raylib_wasm" / ".build-progress.json").read_text())
    assert status["phase"] == "failed" and status["detail"] == "no provider for target", status
    # Cold: the owner it does declare is refused for its missing pin, after
    # the install and before the lock, its replacement or any compiler.
    reset()
    shutil.rmtree(home, ignore_errors=True)
    unpinned = run("generate", "--platform=probe-target", code=1, extra_env=populate)
    assert UNPINNED in unpinned.stderr and "--accept" in unpinned.stderr, unpinned.stderr
    installed_only(unpinned, "probe-target")
    assert not log(project / ".labelle" / "raylib_probe-target"), "the unpinned provider's replacement ran"
    # Warm: the same manifest is readable before the install, so the same
    # verdicts land early, with nothing run and the cache left as it was.
    reset()
    cache_before = snapshot(home)
    warm = run("generate", "--platform=probe-target", code=1)
    assert UNPINNED in warm.stderr, warm.stderr
    nothing_ran(warm, "probe-target")
    reset()
    warm = run("build", "--platform=wasm", code=1)
    assert NO_PROVIDER.format(t="wasm") in warm.stderr, warm.stderr
    nothing_ran(warm, "wasm")
    assert snapshot(home) == cache_before, "an early verdict touched the cache"
    # The listing shows the declaration, marked as not resolving.
    listing = run("targets", extra_env=dead)
    assert "probe-target  provided by fixture-remote (unpinned)" in listing.stderr, listing.stderr
    shutil.rmtree(home, ignore_errors=True)
    declare(dep)

    # `wasm serve --no-build` installs nothing, so it confirms the target
    # against the providers discoverable as-is: refused the same way.
    reset()
    refused = run("wasm", "serve", "--no-build", code=1)
    assert NO_PROVIDER.format(t="wasm") in refused.stderr, refused.stderr
    untouched(refused, "wasm")
    # A provider target without a bundle replacement cannot be bundled.
    provider_manifest.write_text(manifest("fixture", ["probe-target"],
                                          [hook("gen", "generate", "replace", "probe-target"), hook("build", "build", "replace", "probe-target")]))
    reset()
    refused = run("bundle", "--platform=probe-target", code=1)
    assert "target 'probe-target' has no bundle replacement; package 'fixture' must declare a `.when = .replace` hook on `bundle`" in refused.stderr, refused.stderr
    assert "NoBundleReplacement" in refused.stderr, refused.stderr
    installed_only(refused, "probe-target")

    # ── A provider that replaces generate/build/bundle for its target ─────
    provider_manifest.write_text(manifest("fixture", ["probe-target"], [
        hook("gen", "generate", "replace", "probe-target"),
        hook("build", "build", "replace", "probe-target"),
        hook("pack", "bundle", "replace", "probe-target"),
    ]))
    target_dir = project / ".labelle" / "raylib_probe-target"
    lock_file = project / "labelle.lock"
    reset()
    generated = run("generate", "--platform=probe-target")
    # The replacement generated; the assembler installed packages but never
    # generated, and the target directory is named after the resolved target.
    assert "FIXTURE_INSTALL_DONE" in generated.stderr and "FIXTURE_GENERATE" not in generated.stderr, generated.stderr
    assert "target: probe-target" in generated.stderr, generated.stderr
    entries = log(target_dir)
    assert [(e["invocation"]["step"], e["invocation"]["phase"], e["invocation"]["id"]) for e in entries] == [("generate", "replace", "gen")], entries
    assert entries[0]["target"] == "probe-target" and Path(entries[0]["output_dir"]) == target_dir.resolve(), entries
    assert lock_file.exists() and "fixture" in lock_file.read_text()
    # bundle: no macOS gate for a provider target, on every host. The replace
    # hook runs with the step output directory of the layout contract.
    reset()
    bundle_dir = target_dir / "zig-out" / "bundle" / "probe-target"
    bundled = run("bundle", "--platform=probe-target")
    assert "macOS only" not in bundled.stderr, bundled.stderr
    assert "FIXTURE_GENERATE" not in bundled.stderr, bundled.stderr
    entries = log(bundle_dir)
    assert [(e["invocation"]["step"], e["invocation"]["phase"], e["invocation"]["id"]) for e in entries] == [("bundle", "replace", "pack")], entries
    assert entries[0]["target"] == "probe-target", entries
    assert Path(entries[0]["output_dir"]) == bundle_dir.resolve() and Path(entries[0]["output_dir"]).name == "probe-target", entries
    assert not any(p.suffix == ".app" for p in bundle_dir.iterdir()), "the core packager ran for a provider target"
    build_entries = log(target_dir / "zig-out")
    assert [(e["invocation"]["step"], e["invocation"]["phase"]) for e in build_entries] == [("build", "replace")], build_entries
    # The separate-value spelling resolves the same target.
    reset()
    run("bundle", "--platform", "probe-target")
    assert log(bundle_dir), "bundle --platform <t> did not reach the replace hook"
    # `--output` moves the bundle output directory for the hook too.
    reset()
    run("bundle", "--platform=probe-target", "--output", "dist")
    entries = log(project / "dist")
    assert entries and Path(entries[0]["output_dir"]) == (project / "dist").resolve(), entries
    assert not bundle_dir.exists(), "the default bundle directory was created despite --output"

    # ── The ASTC prepass keys on the target, not on the derived enum ───────
    # A provider target outside the schema enum derives `.desktop` for the
    # legacy sites, but it is not the desktop target: with desktop atlases
    # set to ASTC the prepass runs for `desktop` (the control: it reports
    # its tally even with no atlas) and never for `probe-target`.
    astc = ', .asset_compression = .{ .desktop = .astc }'
    declare(dep, extra=astc)
    reset()
    control = run("generate", "--platform=desktop")
    assert "labelle astc:" in control.stderr, control.stderr
    reset()
    generated = run("generate", "--platform=probe-target")
    assert "astc" not in generated.stderr.lower(), generated.stderr
    assert log(target_dir), "the provider's generate replacement did not run"
    declare(dep)

    # ── A provider declaring a schema-named target: the assembler gets it ─
    legacy = base / "fixture-legacy"
    shutil.copytree(fixture, legacy)
    (legacy / "plugin.labelle").write_text(manifest("fixture-legacy", ["wasm"]))
    dep_legacy = '.{ .name = "fixture-legacy", .repo = "local:../fixture-legacy", .version = "1.0.0" }'
    declare(dep, dep_legacy)
    reset()
    # Stop right after generation: the resolution is what is under test, not
    # the (toolchain-bound) link step. The assembler must receive
    # `--platform wasm` — the unchanged target name.
    generated = run("generate", "--platform=wasm")
    assert "FIXTURE_GENERATE platform=wasm" in generated.stderr, generated.stderr
    assert (project / ".labelle" / "raylib_wasm" / "build.zig").exists()
    # The project's declared platform resolves the same way once provided.
    declare(dep, dep_legacy, platform="wasm")
    reset()
    generated = run("generate")
    assert "FIXTURE_GENERATE platform=wasm" in generated.stderr, generated.stderr
    declare(dep, dep_legacy)

    # ── labelle targets ───────────────────────────────────────────────────
    # Metadata only: every listing runs with no compiler and no assembler.
    listing = run("targets", extra_env=dead)
    lines = [line for line in listing.stderr.splitlines() if line.strip()]
    assert lines[0] == "desktop (core)", lines
    assert "probe-target  provided by fixture" in lines and "wasm  provided by fixture-legacy" in lines, lines
    declare()
    listing = run("targets", extra_env=dead)
    assert [line for line in listing.stderr.splitlines() if line.strip()] == ["desktop (core)"], listing.stderr
    # Outside a project only the core target exists.
    listing = run("targets", cwd=base, extra_env=dead)
    assert [line for line in listing.stderr.splitlines() if line.strip()] == ["desktop (core)"], listing.stderr
    # A broken provider is a warning on the listing, not a failure.
    declare(dep)
    provider_manifest.write_text(manifest("fixture", ["probe-target"], [hook("take-over", "build", "replace", "desktop")]))
    listing = run("targets", extra_env=dead)
    assert "desktop (core)" in listing.stderr and "ReplaceRequiresOwnedTarget" in listing.stderr, listing.stderr
    print(f"provider targets: {checks} real CLI invocations passed")
