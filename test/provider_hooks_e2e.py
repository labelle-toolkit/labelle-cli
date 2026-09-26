"""Provider lifecycle hooks through the real CLI pipeline; no network or game deps.

python test/provider_hooks_e2e.py --zig /absolute/path/to/zig [--cli ...]

Generation is driven by a fake assembler (the plugin_compat pattern) that
writes a trivial host executable, so `labelle generate|build|run|bundle` run
end to end on Windows, macOS and Linux. Every workspace is temporary.
"""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import zlib

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

# The fake assembler answers the protocol probe, `install` and `generate`;
# `generate` writes `.labelle/<backend>_desktop/{build.zig,main.zig,data.txt}`
# — a host executable named after the project, with no build.zig.zon so the
# fingerprint pass skips it. The build also INSTALLS `data.txt` to
# `zig-out/bin/data.txt` and the game prints that file at launch, so a
# post-build hook's edit to it is observable from the launched game — and a
# redundant later build would visibly revert it. FAKE_MAIN_BROKEN=1 makes the
# core build fail; FAKE_GAME_HANG=1 in the LAUNCHED game's environment makes
# it sleep forever, so a `--timeout` run ends in the watchdog's kill. `install`
# populates the package cache from
# FAKE_INSTALL_PLUGIN="<src>|<dest>" when set (a remote package landing in
# the ordinary cache), and only prints otherwise.
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
        '    b.installFile("data.txt", "bin/data.txt");\\n'
        '}\\n')
    (target / "data.txt").write_text("original")
    body = "this is not zig\\n" if os.environ.get("FAKE_MAIN_BROKEN") == "1" else (
        'const std = @import("std");\\n'
        'pub fn main(init: std.process.Init) !void {\\n'
        '    const a = init.arena.allocator();\\n'
        '    const data = std.Io.Dir.cwd().readFileAlloc(init.io, "zig-out/bin/data.txt", a, .limited(1024)) catch "missing";\\n'
        '    std.debug.print("DATA={s}\\\\n", .{data});\\n'
        '    if (init.minimal.environ.getAlloc(a, "FAKE_GAME_HANG")) |_| {\\n'
        '        while (true) init.io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};\\n'
        '    } else |_| {}\\n'
        '}\\n')
    (target / "main.zig").write_text(body)
    print("FIXTURE_GENERATE", file=sys.stderr, flush=True)
else:
    raise SystemExit("unexpected assembler invocation: " + repr(sys.argv))
'''

TOOL = '.build_step = "probe-tool", .executable = "bin/provider-probe"'


def hook(id, step, when, target="desktop", after=None):
    ref = f', .after_hooks = .{{ {", ".join(json.dumps(a) for a in after)} }}' if after else ""
    return f'.{{ .id = "{id}", .step = .{step}, .target = "{target}", .when = .{when}, {TOOL}{ref} }}'


def manifest(name, hooks, targets=()):
    declared = f', .targets = .{{ {", ".join(json.dumps(t) for t in targets)} }}' if targets else ""
    return (f'.{{ .name = "{name}", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0"{declared},\n'
            f'    .hooks = .{{ {", ".join(hooks)} }} }}')


# fixture-a names fixture-b/b-pre so the `before build` tie (a before b by
# qualified id) is inverted; the `after build` phase has no edge and keeps
# the tie order. Every other step gets a before/after pair from each package.
A_HOOKS = [hook("a-pre", "build", "before", after=["fixture-b/b-pre"]), hook("a-post", "build", "after"),
           hook("a-gen-pre", "generate", "before"), hook("a-gen-post", "generate", "after"),
           hook("a-bundle-pre", "bundle", "before"), hook("a-bundle-post", "bundle", "after"),
           hook("a-run-pre", "run", "before"), hook("a-run-post", "run", "after"),
           hook("a-wasm-run-pre", "run", "before", target="wasm"), hook("a-wasm-run-post", "run", "after", target="wasm")]
B_HOOKS = [hook("b-pre", "build", "before"), hook("b-post", "build", "after"),
           hook("b-gen-pre", "generate", "before"), hook("b-gen-post", "generate", "after"),
           hook("b-bundle-pre", "bundle", "before"), hook("b-bundle-post", "bundle", "after"),
           hook("b-run-pre", "run", "before"), hook("b-run-post", "run", "after")]

with tempfile.TemporaryDirectory(prefix="labelle-hooks-") as temp:
    base = Path(temp).resolve()
    providers = {}
    for name in ("fixture-a", "fixture-b"):
        providers[name] = base / name
        shutil.copytree(fixture, providers[name])
    a_manifest = providers["fixture-a"] / "plugin.labelle"
    b_manifest = providers["fixture-b"] / "plugin.labelle"
    a_manifest.write_text(manifest("fixture-a", A_HOOKS))
    b_manifest.write_text(manifest("fixture-b", B_HOOKS))
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
    dep_a = '.{ .name = "fixture-a", .repo = "local:../fixture-a", .version = "1.0.0" }'
    dep_b = '.{ .name = "fixture-b", .repo = "local:../fixture-b", .version = "1.0.0" }'

    def declare(*deps, resources=""):
        (project / "project.labelle").write_text(
            f'.{{ .name = "game", .zig_version = "{version}", .plugins = .{{ {", ".join(deps)} }}{resources} }}')

    # Reverse alphabetical declaration order is the default for the suite.
    declare(dep_b, dep_a)
    target_dir = project / ".labelle" / "raylib_desktop"
    zig_out = target_dir / "zig-out"
    exe = zig_out / "bin" / ("game" + exe_suffix)
    lock_file = project / "labelle.lock"
    home = base / "home"
    env = dict(os.environ, LABELLE_HOME=str(home), LABELLE_ZIG=zig, LABELLE_ASSEMBLER=str(assembler),
               LABELLE_NO_PREBUILD="1")
    for knob in ("PROVIDER_PROBE_FAIL", "PROVIDER_PROBE_PATCH", "PROVIDER_PROBE_COPY", "FAKE_MAIN_BROKEN", "FAKE_INSTALL_PLUGIN",
                 "FAKE_GAME_HANG"):
        env.pop(knob, None)
    checks = 0

    def run(*args, code=0, extra_env=None):
        global checks
        merged = dict(env, **(extra_env or {}))
        quiet = [] if args[0] == "help" else ["--progress=off"]
        result = subprocess.run([cli, *args, *quiet], cwd=project, env=merged, text=True,
                                capture_output=True, timeout=600)
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        assert "leaked" not in result.stderr, result.stderr
        checks += 1
        return result

    def reset():
        shutil.rmtree(project / ".labelle", ignore_errors=True)

    def log(step_dir):
        path = step_dir / "hooks.log"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]

    def order(entries, step):
        got = [(e["invocation"]["phase"], e["invocation"]["id"]) for e in entries if e["invocation"]["step"] == step]
        stamps = [e["nanoseconds"] for e in entries if e["invocation"]["step"] == step]
        assert stamps == sorted(stamps), "hooks.log lines are not in time order"
        return got

    # ── Discovery failures stop at `labelle help`, before any compiler ────
    # LABELLE_ZIG and LABELLE_ASSEMBLER point nowhere: reaching either would
    # fail differently, so the named error proves discovery ran first.
    dead = {"LABELLE_ZIG": str(base / "nonexistent-zig"), "LABELLE_ASSEMBLER": str(base / "nonexistent-assembler")}
    healthy = run("help", extra_env=dead)
    assert "Usage: labelle" in healthy.stderr and "discovery failed" not in healthy.stderr, healthy.stderr

    def broken(text, error):
        a_manifest.write_text(text)
        help_out = run("help", extra_env=dead)
        assert "Usage: labelle" in help_out.stderr and error in help_out.stderr, (error, help_out.stderr)
        # In the pipeline, discovery runs AFTER the package cache is
        # populated (the assembler's `install`) and BEFORE generation or any
        # compiler: the install line is there, the generate line is not, and
        # LABELLE_ZIG still points nowhere so a compiler was never reached.
        build_out = run("build", code=1, extra_env={"LABELLE_ZIG": dead["LABELLE_ZIG"]})
        assert error in build_out.stderr and "provider discovery failed" in build_out.stderr, (error, build_out.stderr)
        assert "FIXTURE_INSTALL_DONE" in build_out.stderr, "discovery ran before the package cache was populated"
        assert "FIXTURE_GENERATE" not in build_out.stderr, "discovery did not fail before generation"
        assert not home.exists(), "a failed discovery touched the cache"
        status = json.loads((target_dir / ".build-progress.json").read_text())
        assert status["phase"] == "failed" and status["detail"] == "provider discovery failed", status
        a_manifest.write_text(manifest("fixture-a", A_HOOKS))

    # `replace` on a target the package does not own — `desktop` is core's.
    broken(manifest("fixture-a", [hook("take-over", "build", "replace")]), "ReplaceRequiresOwnedTarget")
    # Two replacements of one (step, target), on a target the package does own.
    broken(manifest("fixture-a", [hook("one", "bundle", "replace", target="probe-target"),
                                  hook("two", "bundle", "replace", target="probe-target")], targets=["probe-target"]),
           "DuplicateReplaceHook")
    broken(manifest("fixture-a", [hook("a-pre", "build", "before", after=["fixture-b/nope"])]), "MissingHookReference")
    broken(manifest("fixture-a", [hook("a-pre", "build", "before", after=["fixture-b/b-post"])]), "HookPhaseOrder")
    assert not home.exists()

    # ── Ordering, regardless of declaration order ─────────────────────────
    expected_build = [("before", "b-pre"), ("before", "a-pre"), ("after", "a-post"), ("after", "b-post")]
    expected_generate = [("before", "a-gen-pre"), ("before", "b-gen-pre"), ("after", "a-gen-post"), ("after", "b-gen-post")]
    for deps in ((dep_b, dep_a), (dep_a, dep_b)):
        declare(*deps)
        reset()
        result = run("build")
        assert exe.exists(), "core build did not produce the executable"
        assert order(log(zig_out), "build") == expected_build, log(zig_out)
        assert order(log(target_dir), "generate") == expected_generate, log(target_dir)
        # The core build ran between the before and after hooks.
        text = result.stderr
        assert text.index("hook 'fixture-a/a-pre'") < text.index("build ok") < text.index("hook 'fixture-a/a-post'"), text
    declare(dep_b, dep_a)
    # The edge is what inverted the tie: without it the tie order returns.
    a_manifest.write_text(manifest("fixture-a", [hook("a-pre", "build", "before")] + A_HOOKS[1:]))
    reset()
    run("build")
    assert order(log(zig_out), "build")[:2] == [("before", "a-pre"), ("before", "b-pre")], log(zig_out)
    a_manifest.write_text(manifest("fixture-a", A_HOOKS))

    # ── Context fields ────────────────────────────────────────────────────
    reset()
    run("build", "--optimize=ReleaseSmall")
    entries = log(zig_out)
    assert len(entries) == 4, entries
    for e in entries:
        assert e["invocation"]["kind"] == "hook" and e["invocation"]["step"] == "build", e
        assert e["invocation"]["phase"] in ("before", "after") and e["target"] == "desktop", e
        assert Path(e["output_dir"]) == zig_out.resolve() and Path(e["output_dir"]).name == "zig-out", e
        assert Path(e["lock_file"]) == lock_file.resolve() and e["lock_file_exists"], e
        assert e["optimize"] == "ReleaseSmall" and e["progress"] == "off", e
        assert Path(e["package_dir"]).name in ("fixture-a", "fixture-b"), e
    ids = {e["invocation"]["id"]: e for e in entries}
    assert Path(ids["a-pre"]["package_dir"]) == providers["fixture-a"].resolve()
    capture = json.loads((zig_out / "capture.json").read_text())
    assert capture["args"] == [] and Path(capture["cwd"]) == project, capture
    assert capture["context"]["invocation"] == {"kind": "hook", "id": "b-post", "step": "build", "phase": "after"}
    assert not (home / "provider-runs").exists() or not list((home / "provider-runs").iterdir()), "workspace not cleaned"

    # ── Failure semantics ─────────────────────────────────────────────────
    # A failing before hook: its exit code is the CLI's, the core build never
    # ran (no executable) and no after hook ran.
    reset()
    failed = run("build", code=7, extra_env={"PROVIDER_PROBE_FAIL": "b-pre"})
    assert "hook 'fixture-b/b-pre' failed (exit 7)" in failed.stderr, failed.stderr
    assert not exe.exists(), "core build ran after a failing before hook"
    assert order(log(zig_out), "build") == [("before", "b-pre")], log(zig_out)
    assert "build ok" not in failed.stderr
    # A failing core build skips the after hooks.
    reset()
    run("build", code=1, extra_env={"FAKE_MAIN_BROKEN": "1"})
    assert not exe.exists()
    assert order(log(zig_out), "build") == [("before", "b-pre"), ("before", "a-pre")], log(zig_out)
    # A failing after hook still fails the command with its own code.
    reset()
    run("build", code=7, extra_env={"PROVIDER_PROBE_FAIL": "a-post"})
    assert exe.exists()
    assert order(log(zig_out), "build") == [("before", "b-pre"), ("before", "a-pre"), ("after", "a-post")], log(zig_out)

    # ── build: after hooks see the command's FINAL artifact ───────────────
    # `labelle build` finalizes the compiled tree (the Linux `.desktop` entry
    # here; the APK on the platform that packages one) and the `after build`
    # hooks used to run before that finalization, so a signing or publishing
    # hook never saw the artifact (Codex P2 on #420). `--linux-desktop` emits
    # the entry on every host: the hook's snapshot of `zig-out/` lists it,
    # and the entry was written before the hook ran.
    reset()
    finalized = run("build", "--linux-desktop")
    entry = zig_out / ("game" + ".desktop")
    assert entry.exists(), list(zig_out.iterdir())
    text = finalized.stderr
    assert text.index("build ok") < text.index("desktop entry written to") < text.index("hook 'fixture-a/a-post'"), text
    seen = {e["invocation"]["id"]: e["output_entries"] for e in log(zig_out) if e["invocation"]["step"] == "build"}
    assert "game.desktop" in seen["a-post"] and "game.desktop" in seen["b-post"], seen
    # The mechanism: the before hooks ran on the pre-finalization tree, so
    # the entry's presence in the after snapshot is the ordering, not a
    # leftover from an earlier command.
    assert "game.desktop" not in seen["b-pre"] and "game.desktop" not in seen["a-pre"], seen

    # ── generate: the lock exists when the before hook runs ───────────────
    reset()
    lock_file.unlink(missing_ok=True)
    run("generate")
    entries = log(target_dir)
    assert order(entries, "generate") == expected_generate, entries
    first = entries[0]
    assert first["invocation"] == {"kind": "hook", "id": "a-gen-pre", "step": "generate", "phase": "before"}
    assert first["lock_file_exists"] and Path(first["lock_file"]) == lock_file.resolve(), first
    assert Path(first["output_dir"]) == target_dir.resolve(), first
    assert lock_file.exists() and "fixture-a" in lock_file.read_text()
    assert not exe.exists(), "generate built the project"
    assert not zig_out.exists() or not (zig_out / "hooks.log").exists(), "generate ran build hooks"

    # ── generate: a before-generate hook's output feeds the pre-passes ────
    # The `--bake` pre-pass reads every declared PNG. `a-gen-pre` is what
    # writes `assets/hook.png` here (a 1x1 PNG staged outside the project);
    # the pre-pass used to run before the hook and fail on the missing file
    # (Codex P2 on #420). Now the hook runs first, the bake sees the PNG and
    # writes its `.rgba` sibling, and only then does generation run.
    png = base / "hook.png"
    raw = zlib.compress(b"\x00\xff\x00\x00\xff")  # one filter byte + one RGBA pixel
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    png.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
                    + chunk(b"IDAT", raw) + chunk(b"IEND", b""))
    assets = project / "assets"
    declare(dep_b, dep_a, resources=', .resources = .{ .{ .name = "hook", .json = "assets/hook.json", .texture = "assets/hook.png" } }')
    reset()
    shutil.rmtree(assets, ignore_errors=True)
    baked = run("generate", "--bake", extra_env={"PROVIDER_PROBE_COPY": f"a-gen-pre|{png}|assets/hook.png"})
    assert (assets / "hook.png").read_bytes() == png.read_bytes(), "the hook did not write the PNG"
    assert (assets / "hook.rgba").exists(), "the bake pre-pass did not see the hook's PNG"
    text = baked.stderr
    assert "baked 1 atlas(es)" in text and "FIXTURE_GENERATE" in text, text
    assert text.index("hook 'fixture-a/a-gen-pre'") < text.index("baked 1 atlas(es)") < text.index("FIXTURE_GENERATE"), text
    # The mechanism: the pre-pass genuinely needs the file. With no hook
    # writing it, the same command fails on the missing PNG, before
    # generation — so the success above is the hook running first.
    reset()
    shutil.rmtree(assets, ignore_errors=True)
    unfed = run("generate", "--bake", code=1)
    assert "bake 'assets/hook.png' failed: FileNotFound" in unfed.stderr, unfed.stderr
    assert "hook 'fixture-a/a-gen-pre'" in unfed.stderr and "FIXTURE_GENERATE" not in unfed.stderr, unfed.stderr
    shutil.rmtree(assets, ignore_errors=True)
    declare(dep_b, dep_a)

    # ── run: before/after around the game ─────────────────────────────────
    reset()
    result = run("run")
    entries = log(zig_out)
    assert order(entries, "build") == expected_build, entries
    assert order(entries, "run") == [("before", "a-run-pre"), ("before", "b-run-pre"), ("after", "a-run-post"), ("after", "b-run-post")], entries
    text = result.stderr
    assert text.index("hook 'fixture-b/b-run-pre'") < text.index("labelle: running...") < text.index("hook 'fixture-a/a-run-post'"), text
    assert "after-run hooks skipped" not in text, text

    # ── run: the --timeout kill is not a clean exit ───────────────────────
    # The watchdog reports exit 0 after killing the game (cli#390), which
    # used to read as success and ran the publishing/cleanup `after run`
    # hooks over a game that was stopped, not finished (Codex P2 on #420).
    # The fixture game sleeps forever under FAKE_GAME_HANG, so the deadline
    # is what ends it: the CLI still exits 0, the before hooks ran, no after
    # hook did, and the skip is announced.
    reset()
    killed = run("run", "--timeout=2s", extra_env={"FAKE_GAME_HANG": "1"})
    assert "labelle: timed out" in killed.stderr, killed.stderr
    assert "labelle: after-run hooks skipped: the game was stopped by --timeout" in killed.stderr, killed.stderr
    assert order(log(zig_out), "run") == [("before", "a-run-pre"), ("before", "b-run-pre")], log(zig_out)
    assert "hook 'fixture-a/a-run-post'" not in killed.stderr and "hook 'fixture-b/b-run-post'" not in killed.stderr, killed.stderr
    # The same game with the same deadline but no hang exits on its own well
    # inside it: the deadline above is what ended the run, not the game.
    reset()
    inside = run("run", "--timeout=60s")
    assert "labelle: timed out" not in inside.stderr and "after-run hooks skipped" not in inside.stderr, inside.stderr
    assert order(log(zig_out), "run") == [("before", "a-run-pre"), ("before", "b-run-pre"), ("after", "a-run-post"), ("after", "b-run-post")], log(zig_out)

    # ── wasm export --no-build: the run hooks still run ───────────────────
    # `--no-build` returned before discovery, so every declared run hook was
    # silently skipped although exporting the existing artifact is the same
    # run step the building path hooks (Codex P2 on #420). A pre-existing
    # web dir stands in for the build; nothing is installed or generated,
    # and the `run` hooks for the `wasm` target wrap the export.
    reset()
    wasm_target_dir = project / ".labelle" / "raylib_wasm"
    wasm_web = wasm_target_dir / "zig-out" / "web"
    wasm_web.mkdir(parents=True)
    (wasm_web / "index.html").write_text("<html>fixture</html>")
    release = project / "release"
    exported = run("wasm", "export", "--no-build", "--output", "release")
    assert (release / "index.html").exists() and (release / ".labelle-export").exists(), list(release.iterdir())
    text = exported.stderr
    assert "FIXTURE_INSTALL_DONE" not in text and "FIXTURE_GENERATE" not in text and "build ok" not in text, text
    assert order(log(wasm_target_dir / "zig-out"), "run") == [("before", "a-wasm-run-pre"), ("after", "a-wasm-run-post")], text
    assert text.index("hook 'fixture-a/a-wasm-run-pre'") < text.index("WASM Export Complete") < text.index("hook 'fixture-a/a-wasm-run-post'"), text
    # A failing before hook stops the export: the hook's code is the CLI's
    # and the output directory is never created.
    shutil.rmtree(release)
    (wasm_target_dir / "zig-out" / "hooks.log").unlink()
    refused = run("wasm", "export", "--no-build", "--output", "release", code=7, extra_env={"PROVIDER_PROBE_FAIL": "a-wasm-run-pre"})
    assert not release.exists() and "WASM Export Complete" not in refused.stderr, refused.stderr
    assert order(log(wasm_target_dir / "zig-out"), "run") == [("before", "a-wasm-run-pre")], refused.stderr
    reset()

    # ── run: an `after build` hook's output survives until launch ─────────
    # `a-post` overwrites `zig-out/bin/data.txt` — a file the build installs
    # from source. The game prints the file it finds at launch: with the
    # redundant warm `zig build` that used to precede the launch, the install
    # step copied the original back over the hook's edit (Codex P2 on #420).
    reset()
    run("build")
    data_file = zig_out / "bin" / "data.txt"
    assert data_file.read_text() == "original", data_file.read_text()
    reset()
    result = run("run", extra_env={"PROVIDER_PROBE_PATCH": "a-post"})
    assert "DATA=patched:a-post" in result.stderr, result.stderr
    assert data_file.read_text() == "patched:a-post", data_file.read_text()
    assert result.stderr.count("build ok") == 1, result.stderr
    # The mechanism, not just the value: one more `zig build` on the same
    # tree DOES revert the edit, so the launch above proving it intact means
    # no build ran between the hook and the game.
    subprocess.run([zig, "build"], cwd=target_dir, check=True, capture_output=True, timeout=600)
    assert data_file.read_text() == "original", "a warm zig build no longer re-installs data.txt; the check above is vacuous"

    # ── Cold cache: a declared remote package is never silently skipped ───
    # Discovery ran ahead of the installer, so on a cold cache a remote
    # package had no readable manifest and was taken for runtime-only: the
    # build proceeded without its hooks, while a warm cache ran them (Codex
    # P1 on #420). Now discovery follows `install`, and after it an absent
    # package is an error.
    remote_src = base / "fixture-c"
    shutil.copytree(fixture, remote_src)
    # A `generate` hook too: the pipeline resolves its managed compiler for
    # the core build before any `build` hook, so only a hook that runs
    # BEFORE generation can show that the pin check itself never touches a
    # compiler (see (2) below).
    (remote_src / "plugin.labelle").write_text(manifest("fixture-c", [hook("c-pre", "build", "before"),
                                                                       hook("c-gen-pre", "generate", "before")]))
    remote_cache = home / "packages" / "plugins" / "example" / "fixture-c" / "1.0.0"
    dep_c = '.{ .name = "fixture-c", .repo = "example/fixture-c", .version = "1.0.0" }'
    declare(dep_c)
    populate = {"FAKE_INSTALL_PLUGIN": f"{remote_src}|{remote_cache}"}

    def cold():
        reset()
        shutil.rmtree(home, ignore_errors=True)

    # (1) The installer does not deliver the package: fail closed, after the
    #     install and before generation — never a hook-less build.
    cold()
    absent = run("build", code=1)
    assert "ProviderPackageMissing" in absent.stderr and "fixture-c" in absent.stderr, absent.stderr
    assert "FIXTURE_INSTALL_DONE" in absent.stderr and "FIXTURE_GENERATE" not in absent.stderr, absent.stderr
    assert not exe.exists() and not remote_cache.exists()
    # (2) The installer delivers it (cold ordinary cache, populated by this
    #     very install): the provider IS discovered, and being unpinned its
    #     hook is refused — the same outcome a warm cache always had. The
    #     refusal comes from the pin check, BEFORE the host compiler is
    #     resolved: LABELLE_ZIG points nowhere, so reaching the compiler
    #     would have reported ProviderCompilerMissing ("install Zig")
    #     instead of the integrity failure (Codex P2 on #420) — and the
    #     `before generate` hook is what fails, so nothing was generated.
    cold()
    unpinned = run("build", code=1, extra_env=dict(populate, LABELLE_ZIG=dead["LABELLE_ZIG"]))
    assert "RemoteProviderIntegrityRequired" in unpinned.stderr and "'fixture-c' is unpinned" in unpinned.stderr, unpinned.stderr
    assert "ProviderCompilerMissing" not in unpinned.stderr and "install the pinned host compiler" not in unpinned.stderr, unpinned.stderr
    assert "FIXTURE_INSTALL_DONE" in unpinned.stderr and "FIXTURE_GENERATE" not in unpinned.stderr, unpinned.stderr
    assert "build ok" not in unpinned.stderr and not exe.exists(), unpinned.stderr
    assert remote_cache.exists()
    # The mechanism: the same dead compiler IS fatal once a pinned hook runs,
    # so the clean integrity error above means the compiler was never
    # consulted for the unpinned one (the pin-first order), not that a dead
    # LABELLE_ZIG goes unnoticed. (4) below pins fixture-c the same way.
    # (3) Warm cache, same command: identical outcome, so cold and warm agree.
    reset()
    warm = run("build", code=1)
    assert "RemoteProviderIntegrityRequired" in warm.stderr and "build ok" not in warm.stderr, warm.stderr
    assert "FIXTURE_GENERATE" not in warm.stderr, warm.stderr
    # (4) Pinned (the integrity model of cli#414) with a cold ORDINARY cache:
    #     the provider comes from the verified archive and its hook runs.
    payload = io.BytesIO()
    with tarfile.open(fileobj=payload, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for member in sorted(remote_src.iterdir()):
            info = tarfile.TarInfo("fixture-c-commit/" + member.name)
            content = member.read_bytes()
            info.size, info.mode = len(content), 0o644
            tar.addfile(info, io.BytesIO(content))
    archive = gzip.compress(payload.getvalue(), mtime=0)
    pin = {"package": "fixture-c", "repo": "example/fixture-c", "version": "1.0.0", "commit": "c" * 40,
           "sha256": hashlib.sha256(archive).hexdigest()}
    cold()
    (home / "provider-archives").mkdir(parents=True)
    (home / "provider-archives" / (pin["sha256"] + ".tar.gz")).write_bytes(archive)
    (project / "labelle.providers.lock").write_text(json.dumps({"schema_version": 1, "providers": [pin]}))
    pinned = run("build")
    assert order(log(zig_out), "build") == [("before", "c-pre")], log(zig_out)
    assert order(log(target_dir), "generate") == [("before", "c-gen-pre")], log(target_dir)
    assert exe.exists() and not remote_cache.exists(), "the pinned provider needed the ordinary cache"
    assert "hook 'fixture-c/c-pre'" in pinned.stderr, pinned.stderr
    # The compiler-order mechanism for (2): with the pin accepted, the same
    # dead LABELLE_ZIG is reached by the first hook and IS the failure.
    reset()
    no_compiler = run("build", code=1, extra_env={"LABELLE_ZIG": dead["LABELLE_ZIG"]})
    assert "ProviderCompilerMissing" in no_compiler.stderr and "RemoteProviderIntegrityRequired" not in no_compiler.stderr, no_compiler.stderr
    (project / "labelle.providers.lock").unlink()

    # ── Cold cache: a reference into the unread package is unresolved ─────
    # `labelle help` and command dispatch discover before any installer, so
    # fixture-c has nothing to read here. fixture-a's edge into it used to
    # fail the whole graph with MissingHookReference — hiding every
    # provider's commands from `help` and refusing dispatch until the
    # package happened to enter the cache (Codex P2 on #420). Now `help` is
    # intact, the pipeline still fails closed on the ABSENT package (not on
    # the reference), and once the package is readable the reference is
    # checked for real.
    a_manifest.write_text(manifest("fixture-a", [hook("a-pre", "build", "before", after=["fixture-c/c-pre"])]))
    declare(dep_a, dep_c)
    cold()
    intact = run("help", extra_env=dead)
    assert "Usage: labelle" in intact.stderr and "discovery failed" not in intact.stderr, intact.stderr
    assert "MissingHookReference" not in intact.stderr, intact.stderr
    absent_ref = run("build", code=1)
    assert "ProviderPackageMissing" in absent_ref.stderr and "MissingHookReference" not in absent_ref.stderr, absent_ref.stderr
    # A typo into a package that is not declared at all is still reported
    # while fixture-c is unread.
    a_manifest.write_text(manifest("fixture-a", [hook("a-pre", "build", "before", after=["fixture-d/c-pre"])]))
    typo = run("help", extra_env=dead)
    assert "MissingHookReference" in typo.stderr and "fixture-d/c-pre" in typo.stderr, typo.stderr
    # Once the installer delivers fixture-c, a reference it does not satisfy
    # is missing at `help` too — the deferral was about the unread package,
    # not about remote packages in general.
    a_manifest.write_text(manifest("fixture-a", [hook("a-pre", "build", "before", after=["fixture-c/nope"])]))
    run("build", code=1, extra_env=populate)
    assert remote_cache.exists()
    present = run("help", extra_env=dead)
    assert "MissingHookReference" in present.stderr and "fixture-c/nope" in present.stderr, present.stderr
    a_manifest.write_text(manifest("fixture-a", A_HOOKS))
    declare(dep_b, dep_a)

    # ── bundle ────────────────────────────────────────────────────────────
    reset()
    if platform.system() == "Darwin":
        bundle_dir = zig_out / "bundle" / "desktop"
        result = run("bundle")
        entries = log(bundle_dir)
        assert order(entries, "bundle") == [("before", "a-bundle-pre"), ("before", "b-bundle-pre"), ("after", "a-bundle-post"), ("after", "b-bundle-post")], entries
        for e in entries:
            assert Path(e["output_dir"]) == bundle_dir.resolve(), e
        apps = [p for p in bundle_dir.iterdir() if p.suffix == ".app"]
        assert len(apps) == 1 and (apps[0] / "Contents" / "Info.plist").exists(), list(bundle_dir.iterdir())
        assert "zig-out/bundle/desktop/" in result.stderr.replace("\\", "/"), result.stderr
        # A failing before hook leaves no bundle behind.
        reset()
        run("bundle", code=7, extra_env={"PROVIDER_PROBE_FAIL": "b-bundle-pre"})
        assert not any(p.suffix == ".app" for p in bundle_dir.iterdir()), list(bundle_dir.iterdir())
    else:
        refused = run("bundle", code=1, extra_env=dead)
        assert "macOS" in refused.stderr and "FIXTURE_INSTALL_DONE" not in refused.stderr, refused.stderr
        assert not (project / ".labelle").exists(), "bundle reached discovery or generation off macOS"
    print(f"provider hooks: {checks} real CLI invocations passed")
