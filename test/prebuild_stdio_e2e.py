"""Prebuild output under `--progress=json`, redirected to a FILE, stays whole (cli#448).

python test/prebuild_stdio_e2e.py --zig /absolute/path/to/zig [--cli ...]

In json mode a prebuild step's stdout is routed to the CLI's stderr so the
NDJSON feed on stdout stays pure. Zig 0.16's `std.process.spawn` with
`.stdout = .{ .file = f }` dup2()s `f` on POSIX, but on Windows it RE-OPENS
the file behind the handle: the child gets a new file object whose offset
starts at 0, so with `2> file` its stdout overwrites the start of the file
(and is overwritten by its own stderr, which does share the offset). A pipe
has no offset, so this suite redirects to real files, the way a shell does
(`2> err.log`, and `> all.log 2>&1`). Generation is driven by a fake
assembler (the provider_output_e2e pattern). Every workspace is temporary.
Runs on Windows, macOS and Linux.

On Windows with a redirected stderr the CLI pipes the step's stdout and
relays it line by line; everywhere else it hands over the stderr file. The
suite runs once as-is and once with LABELLE_PREBUILD_FORCE_RELAY=1, which
forces the relay on every OS, and adds two relay cases: a stdout line
longer than one 4096-byte read stays whole next to the step's stderr, and
(POSIX) a step that leaves `sleep 30` holding the pipe does not hang the
build and its trailing partial line is still written out.
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

FAKE_ASSEMBLER = '''import sys
from pathlib import Path
argv = sys.argv[1:]
if argv and argv[0] == "--protocol-version":
    print(99)
elif argv and argv[0] == "install":
    print("FIXTURE_INSTALL_DONE", file=sys.stderr, flush=True)
elif argv and argv[0] == "generate":
    root = Path(argv[argv.index("--project-root") + 1])
    target = root / ".labelle" / (argv[argv.index("--backend") + 1] + "_" + argv[argv.index("--platform") + 1])
    target.mkdir(parents=True, exist_ok=True)
    (target / "build.zig").write_text(
        'const std = @import("std");\\n'
        'pub fn build(b: *std.Build) void {\\n'
        '    b.installArtifact(b.addExecutable(.{ .name = "game", .root_module = b.createModule(.{\\n'
        '        .root_source_file = b.path("main.zig"), .target = b.graph.host,\\n'
        '        .optimize = b.standardOptimizeOption(.{}) }) }));\\n'
        '}\\n')
    (target / "main.zig").write_text("pub fn main() void {}\\n")
    print("FIXTURE_GENERATE", file=sys.stderr, flush=True)
else:
    raise SystemExit("unexpected assembler invocation: " + repr(sys.argv))
'''

# A prebuild tool that alternates stdout and stderr, flushing every line, so
# a stdout writer with its own offset visibly clobbers the stderr lines.
SAY = '''import sys
step = sys.argv[1]
if step == "long":
    # One stdout write longer than a relay read, then stderr at once.
    sys.stdout.write("PREBUILD_LONG " + "x" * 200000 + " END\\n")
    sys.stdout.flush()
    print("PREBUILD_LONG_STDERR", file=sys.stderr, flush=True)
    sys.exit(0)
for n in (1, 2, 3):
    print(f"PREBUILD_SAY {step} stdout line {n} of 3", flush=True)
    print(f"PREBUILD_SAY {step} stderr line {n} of 3", file=sys.stderr, flush=True)
'''


def zon_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main(base):
    script = base / "fake_assembler.py"
    script.write_text(FAKE_ASSEMBLER)
    if os.name == "nt":
        assembler = base / "fake-assembler.cmd"
        assembler.write_text(f'@echo off\r\n"{sys.executable}" "{script}" %*\r\nexit /b %ERRORLEVEL%\r\n')
    else:
        assembler = base / "fake-assembler"
        assembler.write_text(f"#!/bin/sh\nexec \"{sys.executable}\" \"{script}\" \"$@\"\n")
        assembler.chmod(0o755)
    base_env = dict(os.environ, LABELLE_HOME=str(base / "home"), LABELLE_ZIG=zig, LABELLE_ASSEMBLER=str(assembler))
    base_env.pop("LABELLE_NO_PREBUILD", None)
    base_env.pop("LABELLE_PREBUILD_FORCE_RELAY", None)
    checks = 0

    def project(name, runs):
        """A project whose .prebuild runs each argv in `runs`, every build."""
        root = base / name
        (root / "tools").mkdir(parents=True)
        (root / "tools" / "say.py").write_text(SAY)
        steps = ", ".join(".{ .run = .{ " + ", ".join(zon_str(a) for a in argv) + " } }" for argv in runs)
        (root / "project.labelle").write_text(f'.{{ .name = "game", .zig_version = "{version}", .prebuild = .{{ {steps} }} }}')
        return root

    def lines_of(path):
        data = path.read_bytes()
        text = data.decode("utf-8", errors="replace")
        # An overwrite past the old end of file leaves a hole of NULs.
        assert b"\0" not in data, (path.name, "NUL bytes in redirected output", text)
        return text, text.replace("\r\n", "\n").split("\n")

    def find(lines, want, what, exact=True):
        """The one line equal to (or containing) `want`; it must be whole and unique."""
        hits = [i for i, line in enumerate(lines) if (line.strip() == want if exact else want in line)]
        assert len(hits) == 1, (what, want, len(hits), "\n".join(lines))
        return hits[0]

    def whole(lines, what):
        """Every step line and step header is present exactly once, whole.
        Each stream keeps its own order, step one ends before step two's
        header, and step two before the CLI moves on to generation. Across
        a step's stdout and stderr only the per-stream order is asserted:
        relayed stdout may trail stderr."""
        headers = [find(lines, f"prebuild [{n}/2]", what, exact=False) for n in (1, 2)]
        ends = headers[1:] + [find(lines, "FIXTURE_GENERATE", what)]
        for step, header, end in zip(("one", "two"), headers, ends):
            for stream in ("stdout", "stderr"):
                at = [find(lines, f"PREBUILD_SAY {step} {stream} line {n} of 3", what) for n in (1, 2, 3)]
                assert header < at[0] < at[1] < at[2] < end, (what, step, stream, "out of order", "\n".join(lines))

    def run(root, env, stdout, stderr):
        result = subprocess.run([cli, "build", "--progress=json"], cwd=root, env=env, stdin=subprocess.DEVNULL,
                                stdout=stdout, stderr=stderr, timeout=600)
        return result.returncode

    def split(root, env, what):
        """`labelle build --progress=json > out.ndjson 2> err.log`; returns err.log's lines."""
        out_log, err_log = root / f"{what}.out.ndjson", root / f"{what}.err.log"
        with open(out_log, "wb") as out, open(err_log, "wb") as err:
            code = run(root, env, out, err)
        err_text, err_lines = lines_of(err_log)
        out_text, out_lines = lines_of(out_log)
        assert code == 0, (what, code, err_text, out_text)
        assert "PREBUILD_" not in out_text, (what, "prebuild output leaked into the NDJSON feed", out_text)
        for line in out_lines:
            if line.strip():
                json.loads(line)
        return err_lines

    say = project("say", [[sys.executable, "tools/say.py", s] for s in ("one", "two")])
    long = project("long", [[sys.executable, "tools/say.py", "long"]])
    for mode, env in (("default", base_env), ("forced-relay", dict(base_env, LABELLE_PREBUILD_FORCE_RELAY="1"))):
        # Separate stdout and stderr files: every prebuild line lands in
        # err.log, whole; stdout stays pure NDJSON.
        whole(split(say, env, mode), f"{mode}: 2> err.log")
        checks += 1

        # `> all.log 2>&1`: one file, one offset.
        all_log = say / f"{mode}.all.log"
        with open(all_log, "wb") as sink:
            code = run(say, env, sink, subprocess.STDOUT)
        all_text, all_lines = lines_of(all_log)
        assert code == 0, (mode, code, all_text)
        whole(all_lines, f"{mode}: > all.log 2>&1")
        checks += 1

        # A stdout line longer than one relay read, then stderr: the line
        # stays whole (the relay writes whole lines).
        lines = split(long, env, mode)
        find(lines, "PREBUILD_LONG " + "x" * 200000 + " END", f"{mode}: long line")
        find(lines, "PREBUILD_LONG_STDERR", f"{mode}: long line")
        checks += 1

    if os.name != "nt":
        # The step exits but leaves `sleep 30` holding its stdout pipe: the
        # relay must stop waiting for EOF once the direct child is reaped.
        # Its last output is a partial line (no newline): it must still be
        # written out when the relay stops waiting (cli#452).
        daemon = project("daemon", [["sh", "-c", "sleep 30 & echo PREBUILD_DAEMON_STARTED; printf PREBUILD_DAEMON_PARTIAL"]])
        env = dict(base_env, LABELLE_PREBUILD_FORCE_RELAY="1")
        began = time.monotonic()
        lines = split(daemon, env, "daemon")
        elapsed = time.monotonic() - began
        find(lines, "PREBUILD_DAEMON_STARTED", "daemon")
        # The partial line has no newline, so the CLI's next output follows
        # on the same line; the step header also names it, mid-line.
        partial = [line for line in lines if line.startswith("PREBUILD_DAEMON_PARTIAL")]
        assert len(partial) == 1, ("daemon partial line", "\n".join(lines))
        assert elapsed < 20, ("a background process holding the pipe stalled the build", elapsed)
        checks += 1

    print(f"prebuild stdio: {checks} redirected CLI invocations passed")


with tempfile.TemporaryDirectory(prefix="labelle-prebuild-stdio-") as temp:
    main(Path(temp).resolve())
