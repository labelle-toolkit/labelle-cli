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
import time
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
# it sleep forever, so a `--timeout` run ends in the watchdog's kill;
# FAKE_GAME_SLEEP_MS=<n> makes it sleep n ms and then exit 0. `install`
# populates the package cache from
# FAKE_INSTALL_PLUGIN="<src>|<dest>" when set (a remote package landing in
# the ordinary cache), and only prints otherwise. FAKE_WITH_ZON=1 adds a
# `build.zig.zon` with a valid fingerprint, so the CLI's generation-time
# fingerprint pass configures the build; PROBE_CONFIGURE_LOG=1 in a zig
# invocation's environment makes the build's configure step append
# `<optimize>|<PROBE_TOOLCHAIN or ->|<first PATH entry>` to
# `<target>/configure.log`, one line per zig invocation that configured it.
FAKE_ASSEMBLER = '''import os, shutil, sys, zlib
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
        '    const optimize = b.standardOptimizeOption(.{});\\n'
        '    if (b.graph.environ_map.get("PROBE_CONFIGURE_LOG") != null) {\\n'
        '        const log_path = b.pathFromRoot("configure.log");\\n'
        '        const previous = std.Io.Dir.cwd().readFileAlloc(b.graph.io, log_path, b.allocator, .limited(65536)) catch "";\\n'
        '        const value = b.graph.environ_map.get("PROBE_TOOLCHAIN") orelse "-";\\n'
        '        const path_env = b.graph.environ_map.get("PATH") orelse "";\\n'
        '        const head = path_env[0 .. std.mem.indexOfScalar(u8, path_env, std.fs.path.delimiter) orelse path_env.len];\\n'
        '        const line = b.fmt("{s}{s}|{s}|{s}\\\\n", .{ previous, @tagName(optimize), value, head });\\n'
        '        std.Io.Dir.cwd().writeFile(b.graph.io, .{ .sub_path = log_path, .data = line }) catch @panic("configure.log");\\n'
        '    }\\n'
        '    const exe = b.addExecutable(.{ .name = "game", .root_module = b.createModule(.{\\n'
        '        .root_source_file = b.path("main.zig"), .target = b.graph.host,\\n'
        '        .optimize = optimize }) });\\n'
        '    b.installArtifact(exe);\\n'
        '    b.installFile("data.txt", "bin/data.txt");\\n'
        '}\\n')
    if os.environ.get("FAKE_WITH_ZON") == "1":
        # A manifest with a VALID fingerprint for the name `game` (the CRC32
        # of the name in the high half), so the CLI's fingerprint pass
        # (`zig build --list-steps`) configures this build instead of
        # stopping at the manifest check.
        fingerprint = (zlib.crc32(b"game") << 32) | 0x1234ABCD
        (target / "build.zig.zon").write_text(
            '.{ .name = .game, .version = "0.0.0", .fingerprint = 0x%x, .paths = .{""} }\\n' % fingerprint)
    (target / "data.txt").write_text("original")
    body = "this is not zig\\n" if os.environ.get("FAKE_MAIN_BROKEN") == "1" else (
        'const std = @import("std");\\n'
        'pub fn main(init: std.process.Init) !void {\\n'
        '    const a = init.arena.allocator();\\n'
        '    const data = std.Io.Dir.cwd().readFileAlloc(init.io, "zig-out/bin/data.txt", a, .limited(1024)) catch "missing";\\n'
        '    std.debug.print("DATA={s}\\\\n", .{data});\\n'
        '    if (init.minimal.environ.getAlloc(a, "FAKE_GAME_SLEEP_MS")) |ms| {\\n'
        '        init.io.sleep(std.Io.Duration.fromMilliseconds(std.fmt.parseInt(i64, ms, 10) catch 0), .awake) catch {};\\n'
        '    } else |_| {}\\n'
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


def manifest(name, hooks, targets=(), contract=">=1.0.0 <2.0.0", defaults=()):
    declared = f', .targets = .{{ {", ".join(json.dumps(t) for t in targets)} }}' if targets else ""
    if defaults:
        records = ", ".join(".{ .target = %s, .optimize = .%s }" % (json.dumps(t), o) for t, o in defaults)
        declared += ", .target_defaults = .{ " + records + " }"
    return (f'.{{ .name = "{name}", .manifest_version = 2, .command_contract = "{contract}"{declared},\n'
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
            f'.{{ .name = "game", .zig_version = "{version}", .backend = .raylib, .plugins = .{{ {", ".join(deps)} }}{resources} }}')

    # Reverse alphabetical declaration order is the default for the suite.
    declare(dep_b, dep_a)
    target_dir = project / ".labelle" / "raylib_desktop"
    zig_out = target_dir / "zig-out"
    exe = zig_out / "bin" / ("game" + exe_suffix)
    lock_file = project / "labelle.lock"
    home = base / "home"
    # Hermetic: the no-provider diagnostic's registry download is off
    # (LABELLE_OFFLINE), so no public owner is named here.
    env = dict(os.environ, LABELLE_OFFLINE="1", LABELLE_HOME=str(home), LABELLE_ZIG=zig, LABELLE_ASSEMBLER=str(assembler),
               LABELLE_NO_PREBUILD="1")
    for knob in ("PROVIDER_PROBE_FAIL", "PROVIDER_PROBE_PATCH", "PROVIDER_PROBE_COPY", "FAKE_MAIN_BROKEN", "FAKE_INSTALL_PLUGIN",
                 "FAKE_GAME_HANG", "FAKE_GAME_SLEEP_MS", "LABELLE_TEST_HEADLESS_DEFAULT_TIMEOUT", "PROVIDER_PROBE_ENV", "PROBE_TOOLCHAIN", "PROBE_CONFIGURE_LOG", "FAKE_WITH_ZON"):
        env.pop(knob, None)
    checks = 0

    def run(*args, code=0, extra_env=None, cwd=None):
        global checks
        merged = dict(env, **(extra_env or {}))
        quiet = [] if args[0] == "help" else ["--progress=off"]
        # Everything after `--` is the game's, verbatim: the flag goes before.
        split = args.index("--") if "--" in args else len(args)
        argv = [*args[:split], *quiet, *args[split:]]
        result = subprocess.run([cli, *argv], cwd=cwd or project, env=merged, text=True,
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
        # Contract 1.2.0: every hook names the generated target dir; only
        # `run`-step hooks carry the run options. 1.3.0 adds the cache dir
        # everywhere and an env_file on `before build`; 1.4.0 the command's
        # last step (1.5.0, run.outcome_file, is the negotiated wire).
        assert e["context"]["contract_version"] == "1.5.0", e
        assert e["context"]["final_step"] == "build", e
        assert (e["context"]["env_file"] is not None) == (e["invocation"]["phase"] == "before"), e
        assert Path(e["context"]["target_dir"]) == target_dir.resolve(), e
        assert "run" not in e["context"], e
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

    # ── generate: the shader override is re-gated after the before hooks ──
    # A relative LABELLE_SHADERC is unusable, but the gate only consults it
    # once `materials/` exists. Here `a-gen-pre` is what creates it, so the
    # startup gate (before the install) passes; the re-check right after the
    # before-generate hooks must stop the command before generation (Codex
    # P2 on #420), naming the override instead of failing opaquely later.
    materials = project / "materials"
    shutil.rmtree(materials, ignore_errors=True)
    bad_shaderc = {"LABELLE_SHADERC": "shaderc"}
    reset()
    control = run("generate", extra_env=bad_shaderc)
    assert "FIXTURE_GENERATE" in control.stderr, control.stderr
    reset()
    gated = run("generate", code=1, extra_env=dict(bad_shaderc, PROVIDER_PROBE_COPY=f"a-gen-pre|{png}|materials/probe.png"))
    assert (materials / "probe.png").exists(), "the hook did not create materials/"
    assert "FIXTURE_INSTALL_DONE" in gated.stderr, gated.stderr  # the startup gate passed
    assert "ShadercOverrideMustBeAbsolute" in gated.stderr and "FIXTURE_GENERATE" not in gated.stderr, gated.stderr
    assert gated.stderr.index("hook 'fixture-a/a-gen-pre'") < gated.stderr.index("ShadercOverrideMustBeAbsolute"), gated.stderr
    shutil.rmtree(materials, ignore_errors=True)

    # ── progress: hook sub-steps hand the detail back to the core step ────
    # After the before-generate hooks the feed must report the core
    # generation again, not the last hook "running" through it (Codex P2 on
    # #420); a hook sub-step never carries the compiler's counters.
    reset()
    streamed = subprocess.run([cli, "build", "--progress=json"], cwd=project, env=env, text=True,
                              capture_output=True, timeout=600)
    assert streamed.returncode == 0, (streamed.returncode, streamed.stdout, streamed.stderr)
    checks += 1
    records = []
    for line in streamed.stdout.splitlines():
        try:
            records.append(json.loads(line))
        except ValueError:
            pass
    details = [(r["phase"], r["detail"]) for r in records]
    last_gen_hook = max(i for i, (_, d) in enumerate(details) if d in ("hook fixture-a/a-gen-pre", "hook fixture-b/b-gen-pre"))
    assert ("generate", "assembler generate") in details[last_gen_hook + 1:], details
    for r in records:
        if r["detail"].startswith("hook "):
            assert r["step"] is None and r["total"] is None and r["percent"] is None, r
    assert records[-1]["phase"] == "done", records[-1]

    # ── run: before/after around the game ─────────────────────────────────
    reset()
    result = run("run")
    entries = log(zig_out)
    assert order(entries, "build") == expected_build, entries
    assert order(entries, "run") == [("before", "a-run-pre"), ("before", "b-run-pre"), ("after", "a-run-post"), ("after", "b-run-post")], entries
    text = result.stderr
    assert text.index("hook 'fixture-b/b-run-pre'") < text.index("labelle: running...") < text.index("hook 'fixture-a/a-run-post'"), text
    assert "after-run hooks skipped" not in text, text
    # A run with no options: every run-step hook still carries `run`, empty
    # (`watch` null outside a watch session, `outcome_file` off a replacement).
    for e in entries:
        if e["invocation"]["step"] == "run":
            assert e["context"]["run"] == {"env": [], "args": [], "timeout_ms": None, "watch": None, "outcome_file": None}, e
            assert Path(e["context"]["target_dir"]) == target_dir.resolve(), e

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

    # ── run --headless: the default budget (cli#485) ──────────────────────
    # A headless run given no --timeout gets a default budget through the
    # SAME watchdog as an explicit --timeout. LABELLE_TEST_HEADLESS_DEFAULT_TIMEOUT
    # shortens the 5m default so the kill is observable here. The mechanism,
    # not just the outcome: the notice line, the watchdog's own "timed out"
    # (only its kill path prints it), the default's fired line and the
    # after-hook skip every watchdog kill gets. Each launch is timed against
    # a warm build, so a watchdog that never fired cannot pass on the
    # subprocess timeout.
    short = {"LABELLE_TEST_HEADLESS_DEFAULT_TIMEOUT": "2s"}
    reset()
    run("build")

    def timed(*args, extra_env=None):
        start = time.monotonic()
        result = run(*args, extra_env=extra_env)
        return result, time.monotonic() - start

    defaulted, elapsed = timed("run", "--headless", extra_env=dict(short, FAKE_GAME_HANG="1"))
    assert "labelle: headless run: stopping after 2s (use --timeout to change, --timeout=0 for none)" in defaulted.stderr, defaulted.stderr
    assert "labelle: running (timeout: 2s)" in defaulted.stderr, defaulted.stderr
    assert "labelle: timed out" in defaulted.stderr, defaulted.stderr
    assert "labelle: stopped by the headless default timeout (2s); pass --timeout=<dur> to run longer" in defaulted.stderr, defaulted.stderr
    assert "labelle: after-run hooks skipped: the game was stopped by --timeout" in defaulted.stderr, defaulted.stderr
    assert "hook 'fixture-a/a-run-post'" not in defaulted.stderr, defaulted.stderr
    assert elapsed < 90, f"the default watchdog took {elapsed:.1f}s to end a 2s run"
    # An explicit --timeout wins over the default: its own budget, no notice,
    # and the kill is not blamed on the default.
    explicit, elapsed = timed("run", "--headless", "--timeout=3s", extra_env=dict(short, FAKE_GAME_HANG="1"))
    assert "labelle: running (timeout: 3s)" in explicit.stderr, explicit.stderr
    assert "labelle: timed out" in explicit.stderr, explicit.stderr
    assert "headless run: stopping after" not in explicit.stderr and "headless default timeout" not in explicit.stderr, explicit.stderr
    assert elapsed < 90, f"the explicit watchdog took {elapsed:.1f}s to end a 3s run"
    # The opt-out: --timeout=0 arms no watchdog. The game outlives the 1s
    # default by sleeping 4s and then exits on its own — a watchdog would
    # have killed it at 1s, so the clean exit and the after hooks prove
    # none was armed.
    optout = run("run", "--headless", "--timeout=0",
                 extra_env={"LABELLE_TEST_HEADLESS_DEFAULT_TIMEOUT": "1s", "FAKE_GAME_SLEEP_MS": "4000"})
    assert "labelle: running...\n" in optout.stderr, optout.stderr
    assert "timed out" not in optout.stderr and "headless run: stopping after" not in optout.stderr, optout.stderr
    assert "hook 'fixture-a/a-run-post'" in optout.stderr and "after-run hooks skipped" not in optout.stderr, optout.stderr
    # A windowed run is unchanged: the same outliving game, no default.
    windowed = run("run", extra_env={"LABELLE_TEST_HEADLESS_DEFAULT_TIMEOUT": "1s", "FAKE_GAME_SLEEP_MS": "4000"})
    assert "labelle: running...\n" in windowed.stderr, windowed.stderr
    assert "timed out" not in windowed.stderr and "headless run: stopping after" not in windowed.stderr, windowed.stderr
    assert "hook 'fixture-a/a-run-post'" in windowed.stderr, windowed.stderr
    reset()

    # (The legacy `wasm serve|export` left the core in 3.0, RFC cli#466 PR B:
    # `labelle wasm` is an unknown command now, test/provider_targets_e2e.py.)
    reset()

    declare(dep_b, dep_a)

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
    # Contract 1.3.0 `cache_dir`: keyed by the pinned repository, not by the
    # project's spelling of it, created by the CLI and persistent. A second
    # spelling of the same repository reaches the same directory, with what
    # the provider left there intact.
    pinned_cache = home / "providers" / "github.com" / "example" / "fixture-c"
    c_ctx = [e for e in log(zig_out) if e["invocation"]["id"] == "c-pre"][0]["context"]
    assert Path(c_ctx["cache_dir"]) == pinned_cache.resolve() and pinned_cache.is_dir(), c_ctx
    (pinned_cache / "provider-state").write_text("kept")
    declare('.{ .name = "fixture-c", .repo = "https://github.com/example/fixture-c.git", .version = "1.0.0" }')
    reset()
    run("build")
    c_ctx = [e for e in log(zig_out) if e["invocation"]["id"] == "c-pre"][0]["context"]
    assert Path(c_ctx["cache_dir"]) == pinned_cache.resolve(), c_ctx
    assert (pinned_cache / "provider-state").read_text() == "kept"
    declare(dep_c)
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

    # ── contract 1.2.0: target_dir and the run options on a provider target
    # fixture-a owns `probe-target` and replaces all four steps on it. The
    # replacement `run` hook stands in for the core launch, so it is what
    # receives `labelle run`'s options: the same `LABELLE_*` pairs the core
    # launch would set, the tokens after `--`, and the timeout. The CLI maps
    # nothing to any platform; the provider decides how they reach its game.
    probe_dir = project / ".labelle" / "raylib_probe-target"
    probe_out = probe_dir / "zig-out"
    marker = probe_dir / "sentinel-ran"
    PROBE = [hook("gen", "generate", "replace", target="probe-target"),
             hook("build", "build", "replace", target="probe-target"),
             hook("pack", "bundle", "replace", target="probe-target")]
    DEPLOY = hook("deploy", "run", "replace", target="probe-target")
    # The host launch sentinel: a binary at the path the core launch would
    # execute, which leaves a marker in its cwd when it runs.
    sentinel_src = base / "sentinel.zig"
    sentinel_src.write_text('const std = @import("std");\n'
                            'pub fn main(init: std.process.Init) !void {\n'
                            '    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "sentinel-ran", .data = "1" });\n'
                            '}\n')
    sentinel_bin = base / ("sentinel" + exe_suffix)
    subprocess.run([zig, "build-exe", str(sentinel_src), f"-femit-bin={sentinel_bin}"], cwd=base, check=True,
                   capture_output=True, timeout=600)

    def plant():
        reset()
        (probe_out / "bin").mkdir(parents=True)
        shutil.copy2(sentinel_bin, probe_out / "bin" / ("game" + exe_suffix))

    def probe_context(step_dir, hook_id):
        found = [e["context"] for e in log(step_dir) if e["invocation"]["id"] == hook_id]
        assert len(found) == 1, (hook_id, log(step_dir))
        return found[0]

    run_flags = ("--platform=probe-target", "--scene=x", "--screenshot=s", "--after=2s", "--timeout=30s", "--", "a", "b")
    expected_env = [{"name": "LABELLE_SCENE", "value": "x"}, {"name": "LABELLE_SCREENSHOT_PATH", "value": "s"},
                    {"name": "LABELLE_SCREENSHOT_AFTER_SEC", "value": "2.000"}]
    # The control: the planted sentinel, run from the launch's cwd (the
    # target dir), DOES leave the marker, so its absence below is the
    # replacement standing in.
    a_manifest.write_text(manifest("fixture-a", PROBE, targets=["probe-target"]))
    plant()
    subprocess.run([str(probe_out / "bin" / ("game" + exe_suffix))], cwd=probe_dir, check=True, timeout=60)
    assert marker.exists(), "the planted sentinel left no marker; the checks below would be vacuous"
    marker.unlink()
    # With no run replacement the CLI has no launch for a provider target: it
    # refuses before the build (`NoRunReplacement`, cli#405) instead of
    # falling through to the host launch.
    plant()
    refused = run("run", *run_flags, code=1)
    assert "target 'probe-target' has no run replacement; package 'fixture-a' must declare a `.when = .replace` hook on `run`" in refused.stderr, refused.stderr
    assert "NoRunReplacement" in refused.stderr, refused.stderr
    assert not marker.exists(), "the core launch ran for a provider target with no run replacement"
    assert not log(probe_out) and not log(probe_dir), "a hook ran although the run was refused before the build"
    a_manifest.write_text(manifest("fixture-a", PROBE + [DEPLOY], targets=["probe-target"]))
    plant()
    replaced = run("run", *run_flags)
    assert not marker.exists(), "the core launch ran although a replace run hook stands in for it"
    ctx = probe_context(probe_out, "deploy")
    assert ctx["contract_version"] == "1.5.0" and ctx["final_step"] == "run", ctx
    # Its outcome file (wire 1.5.0) is covered by test/provider_run_outcome_e2e.py.
    assert Path(ctx["run"].pop("outcome_file")).name == "outcome", ctx
    assert ctx["run"] == {"env": expected_env, "args": ["a", "b"], "timeout_ms": 30000, "watch": None}, ctx
    assert Path(ctx["target_dir"]) == probe_dir.resolve() and Path(ctx["output_dir"]) == probe_out.resolve(), ctx
    assert "run options not passed" not in replaced.stderr, replaced.stderr
    # cli#485: a headless run's default budget reaches the replacement the
    # same way an explicit --timeout does, as `timeout_ms`, and is announced.
    plant()
    headless_replaced = run("run", "--platform=probe-target", "--headless",
                            extra_env={"LABELLE_TEST_HEADLESS_DEFAULT_TIMEOUT": "2s"})
    assert "labelle: headless run: stopping after 2s" in headless_replaced.stderr, headless_replaced.stderr
    assert probe_context(probe_out, "deploy")["run"]["timeout_ms"] == 2000, log(probe_out)
    plant()
    run("run", "--platform=probe-target", "--headless", "--timeout=0")
    assert probe_context(probe_out, "deploy")["run"]["timeout_ms"] is None, log(probe_out)
    # The same command's generate and build replacements: the target dir,
    # and no run options off the run step.
    for step_dir, hook_id in ((probe_dir, "gen"), (probe_out, "build")):
        ctx = probe_context(step_dir, hook_id)
        assert Path(ctx["target_dir"]) == probe_dir.resolve() and "run" not in ctx, ctx
    # build and bundle: the target dir, wherever the output goes.
    reset()
    run("build", "--platform=probe-target")
    ctx = probe_context(probe_out, "build")
    assert Path(ctx["target_dir"]) == probe_dir.resolve() and "run" not in ctx, ctx
    reset()
    run("bundle", "--platform=probe-target")
    ctx = probe_context(probe_out / "bundle" / "probe-target", "pack")
    assert Path(ctx["target_dir"]) == probe_dir.resolve() and "run" not in ctx, ctx
    elsewhere = base / "elsewhere"
    reset()
    run("bundle", "--platform=probe-target", "--output", str(elsewhere))
    ctx = probe_context(elsewhere, "pack")
    assert Path(ctx["output_dir"]) == elsewhere.resolve(), ctx
    assert Path(ctx["target_dir"]) == probe_dir.resolve(), ctx
    shutil.rmtree(elsewhere)
    # A provider capped below 1.2.0 receives the exact 1.1.0 wire — neither
    # key — and the dropped run options are announced once, not silently.
    a_manifest.write_text(manifest("fixture-a", PROBE + [DEPLOY], targets=["probe-target"], contract=">=1.0.0 <1.2.0"))
    plant()
    capped = run("run", *run_flags)
    ctx = probe_context(probe_out, "deploy")
    assert ctx["contract_version"] == "1.1.0" and "run" not in ctx and "target_dir" not in ctx, ctx
    note = "labelle: note: run options not passed to 'fixture-a/deploy' (provider contract 1.1.0 < 1.2.0)"
    assert capped.stderr.count(note) == 1, capped.stderr
    # The timeout is dropped with the rest, and the run is said to be
    # unbounded (cli#485): the CLI does not time a replacement itself.
    unbounded = "labelle: warning: 'fixture-a/deploy' cannot receive the run's timeout (provider contract 1.1.0 < 1.2.0)"
    assert capped.stderr.count(unbounded) == 1, capped.stderr
    # The headless default is a timeout like any other: the same warning.
    plant()
    capped_headless = run("run", "--platform=probe-target", "--headless")
    assert "labelle: headless run: stopping after 5m" in capped_headless.stderr, capped_headless.stderr
    assert capped_headless.stderr.count(unbounded) == 1, capped_headless.stderr
    assert not marker.exists(), "the core launch ran although a replace run hook stands in for it"
    # No run options given: nothing was dropped, so there is no note.
    plant()
    plain = run("run", "--platform=probe-target")
    assert "run options not passed" not in plain.stderr and "cannot receive the run's timeout" not in plain.stderr, plain.stderr
    a_manifest.write_text(manifest("fixture-a", A_HOOKS))

    # ── contract 1.3.0: environment contributions (env_file) ──────────────
    # fixture-a's `tc` hook runs `before generate` and, through the env_file
    # its context names, contributes PROBE_TOOLCHAIN plus a PATH entry. The
    # contribution must reach the generation-time fingerprint pass (`zig
    # build --list-steps`, which configures the generated build and so is
    # the first toolchain consumer), the compile and every later hook — and
    # never a provider tool's own build: the fixture's build.zig panics when
    # it sees PROBE_TOOLCHAIN, so every hook below running at all proves it.
    toolbin = base / "probe-toolchain-bin"
    toolbin.mkdir()
    contribution = base / "contribution.json"
    contribution.write_text(json.dumps({"set": [{"name": "PROBE_TOOLCHAIN", "value": "from-tc"}], "path_prepend": [str(toolbin)]}))
    ENV_HOOKS = [hook("tc", "generate", "before"), hook("gen-post", "generate", "after"),
                 hook("pre", "build", "before"), hook("stamp", "build", "after")]
    a_manifest.write_text(manifest("fixture-a", ENV_HOOKS))
    declare(dep_a)
    configure_log = target_dir / "configure.log"
    probe_env = {"FAKE_WITH_ZON": "1", "PROBE_CONFIGURE_LOG": "1"}
    contributing = dict(probe_env, PROVIDER_PROBE_ENV=f"tc|{contribution}")

    def configured():
        return [line.split("|") for line in configure_log.read_text().splitlines()] if configure_log.exists() else []

    def same_dir(got, want):
        return got is not None and os.path.normcase(os.path.normpath(got)) == os.path.normcase(os.path.normpath(str(want)))

    def by_id(step_dir):
        return {e["invocation"]["id"]: e for e in log(step_dir)}

    # The control: with nothing contributed the fingerprint pass configures
    # the build with the variable unset, so every value below is the hook's.
    reset()
    run("generate", extra_env=probe_env)
    assert [c[:2] for c in configured()] == [["Debug", "-"]], configured()
    # `labelle generate`: the fingerprint pass is its only zig invocation.
    reset()
    generated = run("generate", extra_env=contributing)
    lines = configured()
    assert [c[:2] for c in lines] == [["Debug", "from-tc"]], lines
    assert same_dir(lines[0][2], toolbin), lines
    assert generated.stderr.index("hook 'fixture-a/tc'") < generated.stderr.index("FIXTURE_GENERATE"), generated.stderr
    gen_hooks = by_id(target_dir)
    assert gen_hooks["tc"]["probe_toolchain"] is None, gen_hooks["tc"]  # ran before its own contribution
    assert gen_hooks["gen-post"]["probe_toolchain"] == "from-tc" and same_dir(gen_hooks["gen-post"]["path_head"], toolbin), gen_hooks
    # The env_file slots: before/after generate and before build; the path
    # is a per-invocation temporary, gone once the hook's file was read.
    for hook_id in ("tc", "gen-post"):
        env_file = gen_hooks[hook_id]["context"]["env_file"]
        assert env_file and os.path.isabs(env_file) and not os.path.exists(env_file), gen_hooks[hook_id]
    # The provider's persistent cache dir: LABELLE_HOME/providers/<canonical
    # id>, which for a local provider is keyed by its directory.
    local_cache = Path(gen_hooks["tc"]["context"]["cache_dir"])
    assert local_cache.is_dir() and local_cache.parent == (home / "providers" / "local").resolve(), local_cache
    assert local_cache.name.startswith("fixture-a-"), local_cache
    # `labelle build`: the fingerprint pass AND the compile see it, and so
    # do the build hooks that run after the contributing one.
    reset()
    run("build", extra_env=contributing)
    assert [c[:2] for c in configured()] == [["Debug", "from-tc"], ["Debug", "from-tc"]], configured()
    assert all(same_dir(c[2], toolbin) for c in configured()), configured()
    build_hooks = by_id(zig_out)
    assert build_hooks["pre"]["probe_toolchain"] == "from-tc" and build_hooks["stamp"]["probe_toolchain"] == "from-tc", build_hooks
    assert build_hooks["pre"]["context"]["env_file"] and build_hooks["stamp"]["context"]["env_file"] is None, build_hooks
    assert Path(by_id(target_dir)["tc"]["context"]["cache_dir"]) == local_cache, "the cache dir moved between builds"
    leftovers = home / "provider-env"
    assert not leftovers.exists() or not list(leftovers.iterdir()), "an env_file directory was left behind"
    # A hook removed between two builds leaves no value behind: the same
    # command and knobs, only the manifest changed.
    a_manifest.write_text(manifest("fixture-a", ENV_HOOKS[1:]))
    reset()
    run("build", extra_env=contributing)
    assert [c[:2] for c in configured()] == [["Debug", "-"], ["Debug", "-"]], configured()
    assert all(e["probe_toolchain"] is None for e in log(zig_out)), log(zig_out)
    a_manifest.write_text(manifest("fixture-a", ENV_HOOKS))
    # A malformed env_file fails before any compile, naming the hook.
    malformed = base / "malformed.json"
    malformed.write_text('{"set": [')
    reset()
    bad = run("build", code=1, extra_env=dict(probe_env, PROVIDER_PROBE_ENV=f"pre|{malformed}"))
    assert "labelle: hook 'fixture-a/pre' wrote an invalid env_file: not a valid env_file document" in bad.stderr, bad.stderr
    assert "build ok" not in bad.stderr and not exe.exists(), bad.stderr
    assert [c[:2] for c in configured()] == [["Debug", "-"]], configured()  # the fingerprint pass only
    assert "stamp" not in by_id(zig_out), log(zig_out)
    # Before generation: an empty file stops the command before the assembler.
    empty = base / "empty.json"
    empty.write_text("")
    reset()
    bad = run("build", code=1, extra_env=dict(probe_env, PROVIDER_PROBE_ENV=f"tc|{empty}"))
    assert "labelle: hook 'fixture-a/tc' wrote an invalid env_file: the file is empty" in bad.stderr, bad.stderr
    assert "FIXTURE_GENERATE" not in bad.stderr and not configure_log.exists(), bad.stderr
    # A reserved name is refused the same way.
    reserved = base / "reserved.json"
    reserved.write_text(json.dumps({"set": [{"name": "LABELLE_HOME", "value": str(base)}]}))
    reset()
    bad = run("build", code=1, extra_env=dict(probe_env, PROVIDER_PROBE_ENV=f"tc|{reserved}"))
    assert "'LABELLE_HOME' is reserved by the CLI" in bad.stderr and "FIXTURE_GENERATE" not in bad.stderr, bad.stderr
    # A hook that wrote a malformed file and then failed: its exit code is
    # the outcome, and the file is not even read.
    reset()
    failed = run("build", code=7, extra_env=dict(probe_env, PROVIDER_PROBE_ENV=f"pre|{malformed}", PROVIDER_PROBE_FAIL="pre"))
    assert "hook 'fixture-a/pre' failed (exit 7)" in failed.stderr and "invalid env_file" not in failed.stderr, failed.stderr

    # ── Paths that cannot carry a provider's inputs refuse, never bypass ──
    # `--docker` builds in a container the contributions never reach, so a
    # plan with a hook that may contribute is refused before anything runs:
    # no hook, no generation, no build.
    reset()
    refused = run("build", "--docker", code=1, extra_env=probe_env)
    assert "hook 'fixture-a/tc' may contribute an environment for target 'desktop'" in refused.stderr, refused.stderr
    assert "--docker doesn't carry provider environment contributions; build without --docker" in refused.stderr, refused.stderr
    assert "FIXTURE_GENERATE" not in refused.stderr and not log(target_dir) and not log(zig_out), refused.stderr
    # `labelle generate --docker` stops after generation and never reaches
    # the container build, so it is not refused: the hooks run and the
    # contribution reaches the later ones on the host.
    reset()
    generated = run("generate", "--docker", extra_env=contributing)
    assert "--docker doesn't carry" not in generated.stderr and "FIXTURE_GENERATE" in generated.stderr, generated.stderr
    assert by_id(target_dir)["gen-post"]["probe_toolchain"] == "from-tc", log(target_dir)
    # A provider target never reaches the container build at all (RFC
    # cli#466 D5): `--docker` is refused for it by name, before resolution,
    # whatever its plan — even one whose owner replaces `build`, which used
    # to stand in for the container build. No hook runs, nothing generates.
    replaced_dir = project / ".labelle" / "raylib_android"
    a_manifest.write_text(manifest("fixture-a", [hook("tc", "generate", "before", target="android"),
                                                 hook("build-owned", "build", "replace", target="android")], targets=["android"]))
    for docker_args in (("build", "--platform=android", "--docker"), ("generate", "--platform=android", "--docker")):
        reset()
        refused = run(*docker_args, code=1, extra_env=contributing)
        assert "--docker builds the `desktop` target only" in refused.stderr, (docker_args, refused.stderr)
        assert "FIXTURE_GENERATE" not in refused.stderr and not log(replaced_dir) and not log(replaced_dir / "zig-out"), refused.stderr
    a_manifest.write_text(manifest("fixture-a", ENV_HOOKS))
    # iOS left the core (RFC cli#471 I5): `labelle ios` is no built-in any
    # more, so even with a pinned owner of `ios` (which declares no `ios`
    # namespace) the word is an unknown command — no hook runs, nothing
    # generates. And `run --platform=ios` has no core simulator launch to
    # fall back to: without the owner's `replace run` it is refused like
    # any provider target (`NoRunReplacement`), before any hook runs.
    ios_dir = project / ".labelle" / "raylib_ios"
    a_manifest.write_text(manifest("fixture-a", [hook("tc", "generate", "before", target="ios")], targets=["ios"]))
    reset()
    refused = run("ios", "build", code=1)
    assert "labelle: unknown command 'ios'" in refused.stderr, refused.stderr
    assert "FIXTURE_GENERATE" not in refused.stderr and not log(ios_dir), refused.stderr
    reset()
    refused = run("run", "--platform=ios", code=1)
    assert "target 'ios' has no run replacement; package 'fixture-a' must declare a `.when = .replace` hook on `run`" in refused.stderr, refused.stderr
    assert "NoRunReplacement" in refused.stderr, refused.stderr
    assert "FIXTURE_GENERATE" not in refused.stderr and not log(ios_dir), refused.stderr
    a_manifest.write_text(manifest("fixture-a", ENV_HOOKS))

    # ── contract 1.3.0: the target owner's optimize default ───────────────
    # fixture-a owns `android` (a name the pinned assembler generates for, so
    # the core compile runs) and declares `.target_defaults`: the compile
    # gets `-Doptimize=ReleaseSafe` and every hook the same wire `optimize`.
    # An explicit `--optimize` wins; without the default the mode is Zig's.
    owned_dir = project / ".labelle" / "raylib_android"
    owned_log = owned_dir / "configure.log"
    OWNED = [hook("stamp-owned", "build", "after", target="android")]

    def owned_build(*flags, defaults=(("android", "ReleaseSafe"),)):
        a_manifest.write_text(manifest("fixture-a", OWNED, targets=["android"], defaults=defaults))
        reset()
        run("build", "--platform=android", *flags, extra_env={"PROBE_CONFIGURE_LOG": "1"})
        lines = [line.split("|")[0] for line in owned_log.read_text().splitlines()]
        wire = by_id(owned_dir / "zig-out")["stamp-owned"]["optimize"]
        return lines, wire

    assert owned_build() == (["ReleaseSafe"], "ReleaseSafe")
    assert owned_build("--optimize=Debug") == (["Debug"], "Debug")
    assert owned_build("--optimize=ReleaseFast") == (["ReleaseFast"], "ReleaseFast")
    assert owned_build(defaults=()) == (["Debug"], "Debug"), "without the default the mode is Zig's"
    # Only the target's owner declares its defaults, once per target.
    a_manifest.write_text(manifest("fixture-a", OWNED, targets=["android"], defaults=(("desktop", "ReleaseSafe"),)))
    assert "TargetDefaultRequiresOwnedTarget" in run("help").stderr
    a_manifest.write_text(manifest("fixture-a", OWNED, targets=["android"], defaults=(("android", "ReleaseSafe"), ("android", "ReleaseFast"))))
    assert "DuplicateTargetDefault" in run("help").stderr
    a_manifest.write_text(manifest("fixture-a", A_HOOKS))
    declare(dep_b, dep_a)

    # ── the core provisions no target toolchain (RFC cli#466 PR B) ────────
    # The core used to run a Python preflight and activate the fetched
    # toolchain package after generating for the `wasm` schema target,
    # unless a provider hook contributed the toolchain root. Both left the
    # core with the web phase: with PATH scrubbed of Python, no managed
    # interpreter and no contribution, generation for that target still
    # succeeds, and nothing mentions a toolchain the core no longer knows.
    no_python_bin = base / "no-python-bin"
    no_python_bin.mkdir()
    scrubbed = str(no_python_bin)
    if os.name == "nt":
        scrubbed += os.pathsep + os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32")
    no_python = {"PATH": scrubbed}
    assert not (home / "python").exists(), "a managed interpreter already exists"
    a_manifest.write_text(manifest("fixture-a", [hook("sdk", "generate", "before", target="wasm")], targets=["wasm"]))
    declare(dep_a)
    wasm_dir = project / ".labelle" / "raylib_wasm"
    reset()
    bare = run("generate", "--platform=wasm", extra_env=no_python)
    assert "FIXTURE_GENERATE" in bare.stderr, bare.stderr
    assert "need Python" not in bare.stderr and "comes from a provider hook" not in bare.stderr, bare.stderr
    assert "sdk" in by_id(wasm_dir), log(wasm_dir)

    # ── managed Python reaches every provider hook and command (D2) ───────
    # `labelle install python`'s interpreter joins PATH for the `.prebuild`
    # steps; it must reach every provider hook and `labelle <ns> <cmd>` too,
    # so a machine whose only Python is the managed one runs a provider that
    # spawns `python3`. PATH is scrubbed of Python; the probe reports where
    # its own PATH finds the interpreter.
    python_name = "python" if os.name == "nt" else "python3"
    a_manifest.write_text(
        '.{ .name = "fixture-a", .manifest_version = 2, .command_contract = ">=1.0.0 <2.0.0", .namespace = "fixa",\n'
        f'    .commands = .{{ .{{ .name = "probe", {TOOL}, .help = "probe" }} }},\n'
        f'    .hooks = .{{ {hook("py-gen", "generate", "before")} }} }}')
    command_out = project / ".labelle" / "providers" / "fixture-a"
    which_env = dict(no_python, PROVIDER_PROBE_WHICH=python_name)

    def which_seen():
        reset()
        generated = run("generate", extra_env=which_env)
        commanded = run("fixa", "probe", extra_env=which_env)
        return by_id(target_dir)["py-gen"], by_id(command_out)["probe"], generated.stderr + commanded.stderr

    # The control: nothing managed, so neither finds an interpreter.
    hook_seen, command_seen, text = which_seen()
    assert hook_seen["which"] is None and command_seen["which"] is None, (hook_seen, command_seen)
    assert "using provisioned Python" not in text, text
    # The wiring only takes an interpreter that RUNS (`--version`), so the
    # stand-in must be a working one: a wrapper script on POSIX; on Windows
    # the interpreter with the DLLs beside it.
    managed_bin = home / "python" if os.name == "nt" else home / "python" / "bin"
    interpreter = managed_bin / ("python.exe" if os.name == "nt" else "python3")

    def install_managed(working):
        shutil.rmtree(home / "python", ignore_errors=True)
        managed_bin.mkdir(parents=True)
        if not working:
            # On disk, but it does not run.
            if os.name == "nt":
                interpreter.write_bytes(b"not an interpreter\n")
            else:
                interpreter.write_text("#!/bin/sh\nexit 1\n")
                interpreter.chmod(0o755)
            return
        if os.name == "nt":
            base_dir = Path(sys.executable).parent
            shutil.copy(sys.executable, interpreter)
            for dll in base_dir.glob("*.dll"):
                shutil.copy(dll, managed_bin / dll.name)
        else:
            interpreter.write_text(f'#!/bin/sh\nexec "{sys.executable}" "$@"\n')
            interpreter.chmod(0o755)
        probe = subprocess.run([str(interpreter), "--version"], capture_output=True, text=True)
        assert probe.returncode == 0, (probe.returncode, probe.stdout, probe.stderr)

    install_managed(True)
    hook_seen, command_seen, text = which_seen()
    for seen in (hook_seen, command_seen):
        assert same_dir(seen["path_head"], managed_bin), seen
        assert seen["which"] and same_dir(os.path.dirname(seen["which"]), managed_bin), seen
    assert "using provisioned Python" in text, text
    # A BROKEN managed install (on disk, but `--version` fails) must not
    # shadow a working system Python: PATH carries one, and both the hook
    # and the command still resolve it.
    install_managed(False)
    system_bin = base / "system-python-bin"
    if os.name == "nt":
        system_bin = Path(sys.executable).parent
    else:
        system_bin.mkdir(exist_ok=True)
        system_python = system_bin / "python3"
        system_python.write_text(f'#!/bin/sh\nexec "{sys.executable}" "$@"\n')
        system_python.chmod(0o755)
    which_env = dict(which_env, PATH=str(system_bin) + os.pathsep + scrubbed)
    hook_seen, command_seen, text = which_seen()
    for seen in (hook_seen, command_seen):
        assert not same_dir(seen["path_head"], managed_bin), seen
        assert seen["which"] and same_dir(os.path.dirname(seen["which"]), system_bin), seen
    assert "using provisioned Python" not in text, text
    shutil.rmtree(home / "python")
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
        # The core desktop packager is refused off macOS by the pipeline
        # (the gate moved there with the targets slice) right after the
        # target name is settled — before the reporter, the install, any
        # provider discovery or compiler: nothing is created, and the cache
        # (which the cold-cache section above legitimately populated) is
        # left exactly as it was.
        def snapshot(root):
            if not root.exists():
                return None
            return sorted((str(p.relative_to(root)), p.stat().st_size if p.is_file() else -1) for p in root.rglob("*"))
        cache_before = snapshot(home)
        refused = run("bundle", code=1, extra_env=dead)
        assert "macOS" in refused.stderr and "FIXTURE_INSTALL_DONE" not in refused.stderr, refused.stderr
        assert not (project / ".labelle").exists(), "bundle reached generation off macOS"
        assert snapshot(home) == cache_before, "bundle touched the cache off macOS"
    print(f"provider hooks: {checks} real CLI invocations passed")
