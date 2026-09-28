"""A run replacement's reported outcome (contract §2 `run.outcome_file`, cli#473).

python test/provider_run_outcome_e2e.py --zig /absolute/path/to/zig [--cli ...]

A provider that replaces `run` and enforces `--timeout` itself can only exit
0 or not. From wire 1.5.0 its replacement gets `run.outcome_file` and writes
`timeout` there, so the CLI applies the rule its own watchdog follows: exit 0,
`after run` hooks skipped. This suite drives the real CLI with the
`test/fixtures/provider` tool as the target owner and checks, for each
outcome, whether the `after run` hook ran: a clean exit (it runs), a reported
timeout (skipped), the provider's own deadline (skipped, and bounded in time),
a failed replacement (skipped, its status kept), an invalid report (the run
fails) and a provider capped below 1.5.0 (no outcome file: today's behaviour,
the hook runs).

Hermetic: no network, no game dependencies; every workspace is temporary.
Runs on Windows, macOS and Linux.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("--zig", default=shutil.which("zig"))
parser.add_argument("--cli", default=str(Path(__file__).resolve().parents[1] / "zig-out" / "bin" / ("labelle.exe" if os.name == "nt" else "labelle")))
options = parser.parse_args()
assert options.zig, "pass --zig or put zig on PATH"
zig = str(Path(options.zig).resolve())
cli = str(Path(options.cli).resolve())
version = subprocess.check_output([zig, "version"], text=True).strip()
fixture = Path(__file__).parent / "fixtures" / "provider"

# The fake assembler answers the protocol probe and `install`. The target's
# owner replaces generate, build and run, so nothing else reaches it.
FAKE_ASSEMBLER = '''import sys
argv = sys.argv[1:]
if argv and argv[0] == "--protocol-version":
    print(99)
elif argv and argv[0] == "install":
    print("FIXTURE_INSTALL_DONE", file=sys.stderr, flush=True)
else:
    raise SystemExit("unexpected assembler invocation: " + repr(sys.argv))
'''

TOOL = '.build_step = "probe-tool", .executable = "bin/provider-probe"'
TARGET = "probe-target"
DEPLOY = f'.{{ .id = "deploy", .step = .run, .target = "{TARGET}", .when = .replace, {TOOL} }}'
POST = f'.{{ .id = "post", .step = .run, .target = "{TARGET}", .when = .after, {TOOL} }}'
# A provider target's owner replaces generation and the build too.
GEN = f'.{{ .id = "gen", .step = .generate, .target = "{TARGET}", .when = .replace, {TOOL} }}'
BUILD = f'.{{ .id = "build", .step = .build, .target = "{TARGET}", .when = .replace, {TOOL} }}'
SKIPPED = "labelle: after-run hooks skipped: the game was stopped by --timeout"


def manifest(contract=">=1.0.0 <2.0.0"):
    return (f'.{{ .name = "probe", .manifest_version = 2, .command_contract = "{contract}",\n'
            f'    .targets = .{{ "{TARGET}" }}, .hooks = .{{ {GEN}, {BUILD}, {DEPLOY}, {POST} }} }}')


with tempfile.TemporaryDirectory(prefix="labelle-run-outcome-") as temp:
    base = Path(temp).resolve()
    provider = base / "probe"
    shutil.copytree(fixture, provider)
    provider_manifest = provider / "plugin.labelle"
    provider_manifest.write_text(manifest())
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
    (project / "project.labelle").write_text(
        f'.{{ .name = "game", .zig_version = "{version}", .backend = .raylib,'
        f' .plugins = .{{ .{{ .name = "probe", .repo = "local:../probe", .version = "1.0.0" }} }} }}')
    home = base / "home"
    env = dict(os.environ, LABELLE_OFFLINE="1", LABELLE_HOME=str(home), LABELLE_ZIG=zig, LABELLE_ASSEMBLER=str(assembler),
               LABELLE_NO_PREBUILD="1")
    for knob in ("PROVIDER_PROBE_FAIL", "PROVIDER_PROBE_OUTCOME", "PROVIDER_PROBE_DEADLINE", "PROVIDER_PROBE_PATCH",
                 "PROVIDER_PROBE_COPY", "PROVIDER_PROBE_ENV"):
        env.pop(knob, None)
    zig_out = project / ".labelle" / f"raylib_{TARGET}" / "zig-out"
    checks = 0

    def run(*args, code=0, extra_env=None):
        global checks
        result = subprocess.run([cli, "run", f"--platform={TARGET}", "--progress=off", *args], cwd=project,
                                env=dict(env, **(extra_env or {})), text=True, encoding="utf-8",
                                capture_output=True, timeout=600)
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        assert "leaked" not in result.stderr, result.stderr
        checks += 1
        return result

    def ran():
        """The run-step hooks that ran, in order: `(phase, id)`."""
        log = zig_out / "hooks.log"
        if not log.exists():
            return []
        entries = [json.loads(line) for line in log.read_text().splitlines() if line.strip()]
        return [(e["invocation"]["phase"], e["invocation"]["id"]) for e in entries if e["invocation"]["step"] == "run"]

    def deploy_context():
        entries = [json.loads(line) for line in (zig_out / "hooks.log").read_text().splitlines() if line.strip()]
        found = [e["context"] for e in entries if e["invocation"]["id"] == "deploy"]
        assert len(found) == 1, entries
        return found[0]

    def reset():
        (zig_out / "hooks.log").unlink(missing_ok=True)

    both = [("replace", "deploy"), ("after", "post")]
    only_deploy = [("replace", "deploy")]

    # ── A clean exit that reports nothing: the after hook runs ───────────
    clean = run()
    assert ran() == both, ran()
    assert "after-run hooks skipped" not in clean.stderr, clean.stderr
    ctx = deploy_context()
    assert ctx["contract_version"] == "1.5.0", ctx
    outcome_file = Path(ctx["run"]["outcome_file"])
    # Absolute, in a private directory the CLI removed once the replacement exited.
    assert outcome_file.is_absolute() and outcome_file.name == "outcome", ctx
    assert not outcome_file.parent.exists(), outcome_file
    post = [json.loads(line)["context"] for line in (zig_out / "hooks.log").read_text().splitlines()
            if json.loads(line)["invocation"]["id"] == "post"]
    assert post[0]["run"]["outcome_file"] is None, post

    # ── A reported timeout: exit 0, the after hook skipped ────────────────
    reset()
    reported = run(extra_env={"PROVIDER_PROBE_OUTCOME": "deploy|timeout\n"})
    assert ran() == only_deploy, ran()
    assert reported.stderr.count(SKIPPED) == 1, reported.stderr
    assert "hook 'probe/post'" not in reported.stderr, reported.stderr

    # ── The provider's own --timeout deadline, reported: bounded in time ──
    # The replacement sleeps until `run.timeout_ms`, then reports `timeout`
    # and exits 0, as a provider watchdog does. The run lasts at least the
    # deadline (the replacement enforced it) and ends well before the
    # subprocess cap (the CLI did not wait on anything else).
    reset()
    started = time.monotonic()
    deadline = run("--timeout=2s", extra_env={"PROVIDER_PROBE_DEADLINE": "deploy"})
    elapsed = time.monotonic() - started
    assert 2.0 <= elapsed < 60.0, elapsed
    assert deploy_context()["run"]["timeout_ms"] == 2000, deploy_context()
    assert ran() == only_deploy, ran()
    assert deadline.stderr.count(SKIPPED) == 1, deadline.stderr

    # ── A failed replacement: its status, no after hook, a report ignored ─
    reset()
    failed = run(code=7, extra_env={"PROVIDER_PROBE_FAIL": "deploy"})
    assert ran() == only_deploy, ran()
    assert "hook 'probe/deploy' failed (exit 7)" in failed.stderr, failed.stderr
    assert SKIPPED not in failed.stderr, failed.stderr

    # ── An invalid report fails the run before any after hook ─────────────
    reset()
    invalid = run(code=1, extra_env={"PROVIDER_PROBE_OUTCOME": "deploy|finished"})
    assert ran() == only_deploy, ran()
    assert "labelle: run replacement 'probe/deploy' wrote an invalid outcome_file: expected `timeout`" in invalid.stderr, invalid.stderr

    # ── Below wire 1.5.0: no outcome file, the exit status alone decides ──
    # The same provider-side deadline on a provider capped at the 1.4 wire:
    # it has nowhere to report, exits 0, and its after hook runs as it
    # always did (the change is additive).
    provider_manifest.write_text(manifest(contract=">=1.0.0 <1.5.0"))
    reset()
    started = time.monotonic()
    legacy = run("--timeout=1s", extra_env={"PROVIDER_PROBE_DEADLINE": "deploy"})
    elapsed = time.monotonic() - started
    assert 1.0 <= elapsed < 60.0, elapsed
    ctx = deploy_context()
    assert ctx["contract_version"] == "1.4.0" and "outcome_file" not in ctx["run"], ctx
    assert ran() == both, ran()
    assert "after-run hooks skipped" not in legacy.stderr, legacy.stderr
    # And a 1.4 replacement asked to report has no file to report to (exit 9).
    reset()
    run(code=9, extra_env={"PROVIDER_PROBE_OUTCOME": "deploy|timeout"})
    assert ran() == only_deploy, ran()

    print(f"provider run outcome e2e: {checks} checks passed")
