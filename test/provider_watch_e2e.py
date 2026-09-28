"""`labelle run --watch` through a provider's watch-capable run replacement.

python test/provider_watch_e2e.py --zig /absolute/path/to/zig [--cli ...]

RFC cli#466 A2. A fixture package `probe` owns a target and declares a
`replace run` hook with `.watch = true`: the `test/fixtures/provider` tool,
which in watch mode stands in for a dev server. It never serves HTTP: it
polls `run.watch.generation_file` and, on every new generation, records the
`bin/data.txt` it finds in the PUBLISHED `run.watch.output_dir` (what a
server would serve) to `watch.log`, and it exits with the status written to
a stop file. A fake assembler (the plugin_compat pattern) generates a host
build that installs `assets/data.txt` as `zig-out/bin/data.txt`, and a
broken one while `broken.flag` exists.

Covered: the refusals before any build, publication and generation order,
failed-build preservation, the session-change restart diagnostic, after-run
semantics at shutdown, cancellation of an in-flight rebuild (a provisioning
hook, an after-build hook) with no orphaned process, and (POSIX) SIGTERM
forwarding. Hermetic: no network, no game dependencies; runs on Windows,
macOS and Linux.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import shutil
import signal
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
TARGET = "android"  # a schema platform the fake assembler can generate for

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
        '    b.installFile("data.txt", "bin/data.txt");\\n'
        '}\\n')
    (target / "data.txt").write_text((root / "assets" / "data.txt").read_text())
    body = "this is not zig\\n" if (root / "broken.flag").exists() else "pub fn main() void {}\\n"
    (target / "main.zig").write_text(body)
    print("FIXTURE_GENERATE", file=sys.stderr, flush=True)
else:
    raise SystemExit("unexpected assembler invocation: " + repr(sys.argv))
'''

TOOL = '.build_step = "probe-tool", .executable = "bin/provider-probe"'


def hook(id, step, when, extra=""):
    return f'.{{ .id = "{id}", .step = .{step}, .target = "{TARGET}", .when = .{when}, {TOOL}{extra} }}'


def manifest(watch=True, contract=">=1.0.0 <2.0.0"):
    serve = hook("serve", "run", "replace", ", .watch = true" if watch else "")
    hooks = [serve, hook("toolchain", "generate", "before"), hook("stage", "build", "after"), hook("done", "run", "after")]
    return (f'.{{ .name = "probe", .manifest_version = 2, .command_contract = "{contract}",\n'
            f'    .targets = .{{ "{TARGET}" }}, .hooks = .{{ {", ".join(hooks)} }} }}')


def alive(pid):
    if os.name == "nt":
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.OpenProcess(0x1000 | 0x00100000, False, pid)  # QUERY_LIMITED | SYNCHRONIZE
        if not handle:
            return False
        try:
            return kernel32.WaitForSingleObject(handle, 0) != 0  # WAIT_OBJECT_0 = exited
        finally:
            kernel32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # A zombie awaiting its (reparented) reaper answers kill 0 but is dead.
    try:
        state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        return bool(state) and not state.startswith("Z")
    except OSError:
        return True


def wait_for(what, predicate, timeout=300):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise AssertionError(f"timed out waiting for {what}")


with tempfile.TemporaryDirectory(prefix="labelle-watch-") as temp:
    base = Path(temp).resolve()
    provider = base / "probe"
    shutil.copytree(fixture, provider)
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
    (project / "assets").mkdir(parents=True)
    home = base / "home"
    stop = base / "stop"
    env = dict(os.environ, LABELLE_OFFLINE="1", LABELLE_HOME=str(home), LABELLE_ZIG=zig,
               LABELLE_ASSEMBLER=str(assembler), LABELLE_NO_PREBUILD="1", PROVIDER_PROBE_WATCH_STOP=str(stop))
    for leftover in ("PROVIDER_PROBE_FAIL", "PROVIDER_PROBE_COPY", "PROVIDER_PROBE_PATCH", "PROVIDER_PROBE_SLOW",
                     "PROVIDER_PROBE_WATCH_CHILD"):
        env.pop(leftover, None)
    target_dir = project / ".labelle" / f"bgfx_{TARGET}"
    session_dir = project / ".labelle" / ".watch" / f"bgfx_{TARGET}"
    watch_log = target_dir / "zig-out" / "watch.log"
    hooks_log = target_dir / "zig-out" / "hooks.log"
    checks = 0

    # A `.prebuild` step that only leaves a marker OUTSIDE the project (so it
    # never triggers a watched rebuild). The suite runs with
    # LABELLE_NO_PREBUILD=1; the concurrency check below re-enables it to
    # prove a refused second session runs no prebuild step.
    prebuild_marker = base / "prebuild-ran"
    mark_script = base / "mark.py"
    mark_script.write_text(f"from pathlib import Path\nPath({str(prebuild_marker)!r}).write_text('1')\n")
    prebuild = f', .prebuild = .{{ .{{ .run = .{{ {json.dumps(sys.executable)}, {json.dumps(str(mark_script))} }} }} }}'

    def declare(plugins=True, pkg_version="1.0.0"):
        deps = f', .plugins = .{{ .{{ .name = "probe", .repo = "local:../probe", .version = "{pkg_version}" }} }}' if plugins else ""
        (project / "project.labelle").write_text(f'.{{ .name = "game", .zig_version = "{version}"{deps}{prebuild} }}')

    def reset(data="one"):
        shutil.rmtree(project / ".labelle", ignore_errors=True)
        (project / "labelle.lock").unlink(missing_ok=True)
        (project / "broken.flag").unlink(missing_ok=True)
        (project / "assets" / "data.txt").write_text(data)
        stop.unlink(missing_ok=True)

    def refused(expected, **manifest_args):
        global checks
        (provider / "plugin.labelle").write_text(manifest(**manifest_args))
        reset()
        result = subprocess.run([cli, "run", f"--platform={TARGET}", "--watch", "--progress=off"], cwd=project, env=env,
                                text=True, capture_output=True, timeout=600)
        assert result.returncode == 1, (result.returncode, result.stdout, result.stderr)
        assert expected in result.stderr, result.stderr
        assert "FIXTURE_GENERATE" not in result.stderr, "the pipeline generated for a refused watch session"
        assert not (target_dir / "zig-out").exists(), "the pipeline built for a refused watch session"
        checks += 1

    # ── Refusals before any build ───────────────────────────────────────
    declare(plugins=False)
    reset()
    result = subprocess.run([cli, "run", "--watch", "--progress=off"], cwd=project, env=env, text=True,
                            capture_output=True, timeout=600)
    assert result.returncode == 1, (result.returncode, result.stderr)
    assert "run --watch: target 'desktop' has no run replacement to watch through" in result.stderr, result.stderr
    assert "FIXTURE_GENERATE" not in result.stderr, result.stderr
    checks += 1
    # `--watch --docker` is a usage error: non-zero, and nothing runs.
    result = subprocess.run([cli, "run", f"--platform={TARGET}", "--watch", "--docker"], cwd=project, env=env, text=True,
                            capture_output=True, timeout=600)
    assert result.returncode == 2, (result.returncode, result.stderr)
    assert "--watch cannot be combined with --docker" in result.stderr, result.stderr
    assert "FIXTURE_INSTALL_DONE" not in result.stderr, result.stderr
    checks += 1
    declare()
    refused("package 'probe' does not declare `.watch = true` on its run replacement 'probe/serve'", watch=False)
    refused("package 'probe' speaks provider contract 1.2.0; its run replacement 'probe/serve' needs >= 1.3.0",
            contract=">=1.0.0 <1.3.0")
    (provider / "plugin.labelle").write_text(manifest())

    class Session:
        def __init__(self, extra_env=None):
            reset()
            self.err_path = base / f"session-{time.monotonic_ns()}.err"
            self.err = open(self.err_path, "w")
            kwargs = {}
            if os.name == "nt":
                kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
            self.proc = subprocess.Popen([cli, "run", f"--platform={TARGET}", "--watch", "--progress=off"], cwd=project,
                                         env=dict(env, **(extra_env or {})), stdout=self.err, stderr=subprocess.STDOUT,
                                         text=True, **kwargs)

        def output(self):
            # The child writes the file directly; nothing is buffered here.
            return self.err_path.read_bytes().decode("utf-8", errors="replace")

        def log(self):
            return watch_log.read_text().splitlines() if watch_log.exists() else []

        def wait_gen(self, line):
            try:
                wait_for(line, lambda: line in self.log() or (self.proc.poll() is not None and "exited"))
            except AssertionError:
                raise AssertionError(f"{line} never published\n{self.output()}")
            assert line in self.log(), f"labelle exited before {line}:\n{self.output()}"

        def finish(self, code="0", timeout=120):
            stop.write_text(code)
            try:
                status = self.proc.wait(timeout=timeout)
            finally:
                self.err.close()
            return status

        def kill(self):
            if self.proc.poll() is None:
                self.proc.kill()
                self.proc.wait()
            self.err.close()

    def generation():
        return (session_dir / "generation").read_text().strip()

    def published_data():
        return (session_dir / "current" / "bin" / "data.txt").read_text()

    def hook_ids():
        import json
        if not hooks_log.exists():
            return []
        return [json.loads(line)["invocation"]["id"] for line in hooks_log.read_text().splitlines() if line.strip()]

    # ── Publication, failure preservation, session changes, clean exit ──
    s = Session()
    try:
        s.wait_gen("gen=0 data=one")
        assert generation() == "0" and published_data() == "one"
        # A second session for the same target is refused before ANY side
        # effect: with prebuild enabled, its prebuild step never runs, and
        # neither the install nor generation does; the first session's
        # status file and lock are untouched.
        prebuild_marker.unlink(missing_ok=True)
        status_file = target_dir / ".build-progress.json"
        status_before = status_file.read_bytes() if status_file.exists() else None
        lock_before = (project / "labelle.lock").read_bytes()
        prebuild_env = {k: v for k, v in env.items() if k != "LABELLE_NO_PREBUILD"}
        second = subprocess.run([cli, "run", f"--platform={TARGET}", "--watch", "--progress=off"], cwd=project, env=prebuild_env,
                                text=True, capture_output=True, timeout=600)
        assert second.returncode == 1, (second.returncode, second.stderr)
        assert "another watch session (pid" in second.stderr, second.stderr
        assert not prebuild_marker.exists(), "the refused session ran its prebuild step"
        assert "FIXTURE_INSTALL_DONE" not in second.stderr and "FIXTURE_GENERATE" not in second.stderr, second.stderr
        assert (status_file.read_bytes() if status_file.exists() else None) == status_before, "the refused session rewrote the status file"
        assert (project / "labelle.lock").read_bytes() == lock_before, "the refused session rewrote labelle.lock"
        assert generation() == "0" and published_data() == "one"
        # The replacement received the session and nothing else did: the
        # after-build hook ran before the replacement started.
        ids = hook_ids()
        assert ids.index("stage") < ids.index("serve"), ids
        # An asset edit rebuilds and publishes the next generation.
        (project / "assets" / "data.txt").write_text("two")
        s.wait_gen("gen=1 data=two")
        assert generation() == "1"
        # A broken build publishes nothing: the old output stays served.
        (project / "broken.flag").write_text("1")
        (project / "assets" / "data.txt").write_text("three")
        wait_for("the failed rebuild", lambda: "labelle: rebuild failed" in s.output())
        assert generation() == "1" and published_data() == "two", (generation(), published_data())
        assert s.log()[-1] == "gen=1 data=two", s.log()
        # The fix publishes.
        (project / "broken.flag").unlink()
        s.wait_gen("gen=2 data=three")
        # A change the running replacement depends on: restart diagnostic,
        # nothing published.
        declare(pkg_version="2.0.0")
        wait_for("the restart diagnostic", lambda: "restart labelle run --watch: the provider version changed" in s.output())
        assert generation() == "2", generation()
        declare()
        s.wait_gen("gen=3 data=three")
        before = hook_ids().count("done")
        status = s.finish("0")
        out = s.output()
        assert status == 0, (status, out)
        # A clean status-0 exit runs `after run`; the session is cleaned up.
        assert hook_ids().count("done") == before + 1, hook_ids()
        assert not session_dir.exists(), "the published generations were left behind"
        checks += 1
        # The control for the refusal above: with no session running, the
        # same prebuild-enabled environment does run the step.
        prebuild_marker.unlink(missing_ok=True)
        control = subprocess.run([cli, "generate", f"--platform={TARGET}"], cwd=project, env=prebuild_env, text=True,
                                 capture_output=True, timeout=600)
        assert control.returncode == 0, (control.returncode, control.stderr)
        assert prebuild_marker.exists(), "the prebuild step never runs: the refusal check above would be vacuous"
        checks += 1
    except BaseException:
        print('---- labelle output ----\n' + s.output(), file=sys.stderr)
        raise
    finally:
        s.kill()

    # ── A non-zero replacement exit skips `after run`; cleanup still runs ─
    s = Session()
    try:
        s.wait_gen("gen=0 data=one")
        status = s.finish("5")
        assert status == 5, (status, s.output())
        assert "after-run hooks skipped" in s.output(), s.output()
        assert "done" not in hook_ids(), hook_ids()
        assert not session_dir.exists()
        checks += 1
    except BaseException:
        print('---- labelle output ----\n' + s.output(), file=sys.stderr)
        raise
    finally:
        s.kill()

    # ── Cancellation of an in-flight rebuild, no orphan ─────────────────
    for hook_id in ("toolchain", "stage"):
        marker = base / f"slow-{hook_id}"
        s = Session({"PROVIDER_PROBE_SLOW": f"{hook_id}|{marker}", "PROVIDER_PROBE_WATCH_CHILD": str(base / f"child-{hook_id}")})
        try:
            s.wait_gen("gen=0 data=one")
            server_child = [int(p) for p in (base / f"child-{hook_id}").read_text().split()]
            Path(f"{marker}.arm").write_text("1")
            (project / "assets" / "data.txt").write_text("slow")
            pids = wait_for(f"the slow {hook_id} hook", lambda: marker.exists() and marker.read_text().split())
            pids = [int(p) for p in pids]
            assert all(alive(p) for p in pids), pids
            started = time.monotonic()
            status = s.finish("0")
            assert status == 0, (status, s.output())
            assert time.monotonic() - started < 60, "the session waited the slow hook out instead of cancelling it"
            assert "rebuild cancelled" in s.output(), s.output()
            assert not session_dir.exists(), "no cleanup"
            # The hook, its grandchild and the replacement's grandchild are
            # all gone (POSIX process groups; Windows job objects).
            for pid in pids + [server_child[1]]:
                wait_for(f"process {pid} to end", lambda: not alive(pid), timeout=30)
            checks += 1
        except BaseException:
            print('---- labelle output ----\n' + s.output(), file=sys.stderr)
            raise
        finally:
            Path(f"{marker}.arm").unlink(missing_ok=True)
            s.kill()

    # ── SIGTERM to labelle is forwarded to the replacement (POSIX) ──────
    if os.name != "nt":
        s = Session({"PROVIDER_PROBE_WATCH_CHILD": str(base / "child-term")})
        try:
            s.wait_gen("gen=0 data=one")
            server_child = [int(p) for p in (base / "child-term").read_text().split()]
            s.proc.send_signal(signal.SIGTERM)
            status = s.proc.wait(timeout=120)
            s.err.close()
            # The replacement died of the forwarded signal: not a clean exit,
            # so `after run` is skipped; cleanup runs.
            assert status == 128 + signal.SIGTERM, (status, s.output())
            assert "done" not in hook_ids(), hook_ids()
            assert not session_dir.exists()
            for pid in server_child:
                wait_for(f"process {pid} to end", lambda: not alive(pid), timeout=30)
            checks += 1
        except BaseException:
            print('---- labelle output ----\n' + s.output(), file=sys.stderr)
            raise
        finally:
            s.kill()

    print(f"provider watch e2e: {checks} checks passed")
