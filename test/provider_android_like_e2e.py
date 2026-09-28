"""An `android`-shaped provider through the real CLI, with no NDK and no device.

python test/provider_android_like_e2e.py --zig /absolute/path/to/zig [--cli ...]

cli#405 removed Android from the CLI: `labelle build|run|bundle
--platform=android` and `labelle android ...` now reach whatever package
declares target and namespace `android`, exactly as for any other provider.
This suite proves the CLI side of that with a fixture package named `android`
(the `test/fixtures/provider` tool under an android-shaped manifest) and a
fake assembler (the plugin_compat pattern). Nothing here knows how to build
an APK: that is labelle-android's job, and its own e2e covers it.

Hermetic: no network, no game dependencies; every workspace is temporary.
Runs on Windows, macOS and Linux.
"""
import argparse
import hashlib
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
exe_suffix = ".exe" if os.name == "nt" else ""

# The fake assembler answers the protocol probe, `install` and `generate`.
# `generate` names the platform it received on stderr and writes a target
# tree whose build installs `lib/libgame.so` (a marker file standing in for
# the cross-compiled game library) plus a HOST executable named after the
# project. That executable is the host-launch sentinel: run from the target
# dir, as the core launch would, it leaves `sentinel-ran` there.
FAKE_ASSEMBLER = '''import sys
from pathlib import Path
argv = sys.argv[1:]
if argv and argv[0] == "--protocol-version":
    print(99)
elif argv and argv[0] == "install":
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
        '    b.installFile("libgame.so", "lib/libgame.so");\\n'
        '}\\n')
    (target / "libgame.so").write_text(f"fake game library for {platform_name}")
    (target / "main.zig").write_text(
        'const std = @import("std");\\n'
        'pub fn main(init: std.process.Init) !void {\\n'
        '    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "sentinel-ran", .data = "1" });\\n'
        '}\\n')
    print(f"FIXTURE_GENERATE platform={platform_name}", file=sys.stderr, flush=True)
else:
    raise SystemExit("unexpected assembler invocation: " + repr(sys.argv))
'''

TOOL = '.build_step = "probe-tool", .executable = "bin/provider-probe"'
NO_PROVIDER = ("labelle: no provider for target 'android' in this project; "
               "add and pin the package that declares target 'android'")
NO_NAMESPACE = ("labelle: no provider for namespace 'android' in this project; "
                "add and pin the package that declares namespace 'android'")
NO_RUN = ("labelle: target 'android' has no run replacement; "
          "package 'android' must declare a `.when = .replace` hook on `run`")

PACKAGE = f'.{{ .id = "package", .step = .build, .target = "android", .when = .after, {TOOL} }}'
DEPLOY = f'.{{ .id = "deploy", .step = .run, .target = "android", .when = .replace, {TOOL} }}'
BUNDLE = f'.{{ .id = "bundle", .step = .bundle, .target = "android", .when = .replace, {TOOL} }}'


def phase_hook(id, step, when):
    return f'.{{ .id = "{id}", .step = .{step}, .target = "android", .when = .{when}, {TOOL} }}'


# A hook in every other slot a command can reach, so section 5b can assert
# the whole order of `labelle bundle` (cli#443), `build` and `run`.
LIFECYCLE = [phase_hook("pre-gen", "generate", "before"), phase_hook("post-gen", "generate", "after"),
             phase_hook("pre-build", "build", "before"), PACKAGE, phase_hook("pre-bundle", "bundle", "before"),
             BUNDLE, phase_hook("post-bundle", "bundle", "after"), phase_hook("pre-run", "run", "before"), DEPLOY,
             phase_hook("post-run", "run", "after")]


def manifest(hooks, contract=">=1.2.0 <2.0.0"):
    return (f'.{{ .name = "android", .manifest_version = 2, .command_contract = "{contract}",\n'
            '    .namespace = "android", .targets = .{ "android" },\n'
            f'    .commands = .{{ .{{ .name = "run", {TOOL}, .help = "Install and launch the built APK" }} }},\n'
            f'    .hooks = .{{ {", ".join(hooks)} }} }}')


with tempfile.TemporaryDirectory(prefix="labelle-android-like-") as temp:
    base = Path(temp).resolve()
    provider = base / "labelle-android"
    shutil.copytree(fixture, provider)
    provider_manifest = provider / "plugin.labelle"
    provider_manifest.write_text(manifest([PACKAGE, DEPLOY, BUNDLE]))
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
    home = base / "home"
    # Hermetic: the no-provider diagnostics' registry download is off
    # (LABELLE_OFFLINE); only the project's own accepted-source record answers.
    env = dict(os.environ, LABELLE_OFFLINE="1", LABELLE_HOME=str(home), LABELLE_ZIG=zig, LABELLE_ASSEMBLER=str(assembler),
               LABELLE_NO_PREBUILD="1")
    for leftover in ("PROVIDER_PROBE_FAIL", "PROVIDER_PROBE_COPY", "PROVIDER_PROBE_PATCH"):
        env.pop(leftover, None)
    dep = '.{ .name = "android", .repo = "local:../labelle-android", .version = "0.2.0" }'
    target_dir = project / ".labelle" / "bgfx_android"
    zig_out = target_dir / "zig-out"
    marker = target_dir / "sentinel-ran"
    checks = 0

    def declare(*deps, extra=""):
        plugins = f', .plugins = .{{ {", ".join(deps)} }}' if deps else ""
        (project / "project.labelle").write_text(
            f'.{{ .name = "game", .zig_version = "{version}", .backend = .bgfx{plugins}{extra} }}')

    def run(*args, code=0, extra_env=None):
        global checks
        quiet = [] if args[0] in ("help", "android") else ["--progress=off"]
        result = subprocess.run([cli, *args, *quiet], cwd=project, env=dict(env, **(extra_env or {})), text=True,
                                encoding="utf-8", capture_output=True, timeout=600)
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        assert "leaked" not in result.stderr, result.stderr
        checks += 1
        return result

    def reset():
        shutil.rmtree(project / ".labelle", ignore_errors=True)
        (project / "labelle.lock").unlink(missing_ok=True)
        shutil.rmtree(project / "packaged", ignore_errors=True)

    def log(step_dir):
        path = step_dir / "hooks.log"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def hook_context(step_dir, hook_id):
        found = [e for e in log(step_dir) if e["invocation"]["id"] == hook_id]
        assert len(found) == 1, (hook_id, log(step_dir))
        return found[0]

    def nothing_generated(result):
        assert "FIXTURE_GENERATE" not in result.stderr, result.stderr
        assert not target_dir.exists() or not (target_dir / "build.zig").exists(), "the assembler generated"
        assert not marker.exists(), "the host launch ran"

    # A schema-2 registry document whose `android` release declares the
    # namespace and the target.
    registry_doc = {"schema_version": 2, "defaults": [], "providers": [{
        "package": "android", "repo": "labelle-toolkit/labelle-android", "version": "0.2.0",
        "commit": "1" * 40, "sha256": "0" * 64, "namespace": "android", "targets": ["android"]}]}
    fork = "https://example.test/fork/providers.json"

    # ── 1. Without the pin: every entry point fails, nothing is generated ──
    # Three states: nothing recorded; the document only in the global
    # registry cache (where an older CLI kept another project's accepted
    # document, #465), which never answers; and the project's own verified
    # accepted-source record, which answers both the target and the
    # namespace hint (offline: it is read from the project, not downloaded).
    declare()
    reset()
    for state in ("none", "global-cache", "project-record"):
        if state == "global-cache":
            (home / "registry").mkdir(parents=True, exist_ok=True)
            (home / "registry" / "providers.json").write_text(json.dumps(registry_doc))
        if state == "project-record":
            document = json.dumps(registry_doc, separators=(",", ":"))
            (project / ".labelle").mkdir(parents=True, exist_ok=True)
            (project / ".labelle" / "providers.registry.json").write_text(json.dumps({
                "schema_version": 2, "source": fork,
                "document_sha256": hashlib.sha256(document.encode()).hexdigest(), "document": document}))
        named = state == "project-record"
        hint = "(registry: android)"
        for args in (("run", "--platform=android"), ("build", "--platform=android"), ("bundle", "--platform=android")):
            refused = run(*args, code=1)
            assert NO_PROVIDER in refused.stderr, (args, refused.stderr)
            assert (hint in refused.stderr) == named, (args, state, refused.stderr)
            if named:
                assert "\n    " + fork + "\n" in refused.stderr, (args, refused.stderr)
            else:
                assert "(registry not consulted: LABELLE_OFFLINE is set)" in refused.stderr, (args, refused.stderr)
            nothing_generated(refused)
        refused = run("android", "run", code=1)
        if named:
            assert NO_NAMESPACE in refused.stderr and hint in refused.stderr, refused.stderr
            assert "Its newest release that declares the namespace, 0.2.0, is a candidate" in refused.stderr, refused.stderr
            assert "\n    " + fork + "\n" in refused.stderr and "compatible" not in refused.stderr, refused.stderr
        else:
            assert "labelle: unknown command 'android'" in refused.stderr and hint not in refused.stderr, (state, refused.stderr)
        nothing_generated(refused)
    shutil.rmtree(home / "registry")

    # ── 2. With the pin: generate, the after-build hook, the run replacement ─
    declare(dep)
    reset()
    listing = run("help")
    assert "android run" in listing.stdout + listing.stderr, listing.stderr
    # The control for the host-launch sentinel below: a plain build produces
    # it, and run from the target dir (the core launch's cwd) it leaves the
    # marker — so its absence after `run` is the replacement standing in.
    # The after-build hook copies the built library to `packaged/game.apk`
    # (relative to the project root, its cwd): the copy fails the hook unless
    # `zig-out/lib/libgame.so` exists when it runs.
    copy = {"PROVIDER_PROBE_COPY": f"package|{zig_out / 'lib' / 'libgame.so'}|packaged/game.apk"}
    built = run("build", "--platform=android", extra_env=copy)
    assert "FIXTURE_GENERATE platform=android" in built.stderr, built.stderr
    subprocess.run([str(zig_out / "bin" / ("game" + exe_suffix))], cwd=target_dir, check=True, timeout=60)
    assert marker.exists(), "the sentinel left no marker; the host-launch checks below would be vacuous"
    reset()
    ran = run("run", "--platform=android", "--scene=intro", "--screenshot=shot", "--after=4s", extra_env=copy)
    assert "FIXTURE_GENERATE platform=android" in ran.stderr, ran.stderr
    package = hook_context(zig_out, "package")
    assert (package["invocation"]["step"], package["invocation"]["phase"]) == ("build", "after"), package
    assert Path(package["context"]["target_dir"]) == target_dir.resolve(), package
    assert "lib" in package["output_entries"], package
    assert (project / "packaged" / "game.apk").read_text() == "fake game library for android"
    deploy = hook_context(zig_out, "deploy")
    assert (deploy["invocation"]["step"], deploy["invocation"]["phase"]) == ("run", "replace"), deploy
    assert deploy["context"]["run"]["env"] == [
        {"name": "LABELLE_SCENE", "value": "intro"}, {"name": "LABELLE_SCREENSHOT_PATH", "value": "shot"},
        {"name": "LABELLE_SCREENSHOT_AFTER_SEC", "value": "4.000"}], deploy
    assert Path(deploy["context"]["target_dir"]) == target_dir.resolve(), deploy
    # The package hook ran before the replacement, once.
    order = [e["invocation"]["id"] for e in log(zig_out)]
    assert order == ["package", "deploy"], order
    assert not marker.exists(), "the host launch ran although the provider replaces run"

    # ── 3. No run replacement: refused after the install, before any build ─
    provider_manifest.write_text(manifest([PACKAGE, BUNDLE]))
    reset()
    refused = run("run", "--platform=android", code=1)
    assert NO_RUN in refused.stderr and "NoRunReplacement" in refused.stderr, refused.stderr
    assert "FIXTURE_INSTALL_DONE" in refused.stderr, refused.stderr
    nothing_generated(refused)
    assert not log(zig_out), "a hook ran although the run was refused before the build"
    # `build` and `bundle` never need a run replacement.
    run("build", "--platform=android")
    provider_manifest.write_text(manifest([PACKAGE, DEPLOY, BUNDLE]))

    # ── 4. `labelle android <command>` reaches the tool verbatim ────────────
    # Provider commands need the project's lock, which a pipeline run writes.
    reset()
    run("build", "--platform=android")
    capture = project / ".labelle" / "providers" / "android" / "capture.json"
    run("android", "run", "--device", "X", "--release")
    captured = json.loads(capture.read_text())
    assert captured["args"] == ["--device", "X", "--release"], captured
    assert captured["context"]["invocation"]["kind"] == "command", captured
    assert captured["context"]["invocation"]["id"] == "run", captured
    # No command: the namespace lists its commands, like any provider.
    listed = run("android")
    assert "android run" in listed.stdout + listed.stderr, listed.stderr

    # ── 5. bundle: the build number and the bundle output dir ────────────
    reset()
    run("bundle", "--platform=android", "--build-number=7")
    bundle_dir = zig_out / "bundle" / "android"
    packed = hook_context(bundle_dir, "bundle")
    assert packed["context"]["build_number"] == "7", packed
    assert Path(packed["output_dir"]) == bundle_dir.resolve(), packed

    # ── 5b. bundle with a bundle replacement: which hooks, in what order ──
    # cli#443: `labelle bundle` runs generate, then build, then bundle, with
    # every hook of each (contract §6), the `after build` package hook
    # included: a hook of another package in that slot (a signer, a symbol
    # upload) must not be bypassed silently. The replacement stands in for
    # the core packager only, and no `run` hook runs. Every hook is told the
    # command's last step (`final_step`, wire 1.4.0): that is how the
    # package hook knows the bundle replacement makes the distributable, and
    # can skip packaging the install APK a second time.
    def ordered(*step_dirs):
        entries = sorted((e for d in step_dirs for e in log(d)), key=lambda e: e["nanoseconds"])
        return entries, [(e["invocation"]["step"], e["invocation"]["phase"], e["invocation"]["id"]) for e in entries]

    provider_manifest.write_text(manifest(LIFECYCLE))
    reset()
    run("bundle", "--platform=android", "--build-number=9")
    entries, ran = ordered(target_dir, zig_out, bundle_dir)
    assert ran == [("generate", "before", "pre-gen"), ("generate", "after", "post-gen"),
                   ("build", "before", "pre-build"), ("build", "after", "package"),
                   ("bundle", "before", "pre-bundle"), ("bundle", "replace", "bundle"),
                   ("bundle", "after", "post-bundle")], ran
    for e in entries:
        assert e["context"]["contract_version"] == "1.5.0", e
        assert e["context"]["final_step"] == "bundle", e
    # The package hook saw the finished build.
    assert "lib" in hook_context(zig_out, "package")["output_entries"]
    # The same hooks under `build` and `run` see those commands' last step;
    # neither runs a bundle hook, and `build` runs no run hook.
    reset()
    run("build", "--platform=android")
    entries, ran = ordered(target_dir, zig_out, bundle_dir)
    assert [r[2] for r in ran] == ["pre-gen", "post-gen", "pre-build", "package"], ran
    assert {e["context"]["final_step"] for e in entries} == {"build"}, entries
    reset()
    run("run", "--platform=android")
    entries, ran = ordered(target_dir, zig_out, bundle_dir)
    assert [r[2] for r in ran] == ["pre-gen", "post-gen", "pre-build", "package", "pre-run", "deploy", "post-run"], ran
    assert {e["context"]["final_step"] for e in entries} == {"run"}, entries
    # A provider capped below 1.4.0 runs the same hooks on the exact 1.3.0
    # wire, without the key its strict decoder would reject.
    provider_manifest.write_text(manifest(LIFECYCLE, contract=">=1.2.0 <1.4.0"))
    reset()
    run("bundle", "--platform=android")
    entries, ran = ordered(target_dir, zig_out, bundle_dir)
    assert [r[2] for r in ran] == ["pre-gen", "post-gen", "pre-build", "package", "pre-bundle", "bundle", "post-bundle"], ran
    for e in entries:
        assert e["context"]["contract_version"] == "1.3.0" and "final_step" not in e["context"], e
    provider_manifest.write_text(manifest([PACKAGE, DEPLOY, BUNDLE]))

    # ── 6. A legacy `.android` block goes through the CLI unchanged ───────
    # Its keys belong to the provider's settings and the assembler's codegen;
    # the CLI parses project.labelle leniently and never reads them.
    declare(dep, extra=', .android = .{ .package_name = "com.labelle.game", .orientation = .landscape, .immersive_mode = true, .target_sdk_version = 34 }')
    reset()
    legacy = run("run", "--platform=android", "--scene=intro")
    assert "FIXTURE_GENERATE platform=android" in legacy.stderr, legacy.stderr
    assert hook_context(zig_out, "deploy")["context"]["run"]["env"] == [{"name": "LABELLE_SCENE", "value": "intro"}]
    assert not marker.exists(), "the host launch ran although the provider replaces run"
    print(f"provider android-like: {checks} real CLI invocations passed")
