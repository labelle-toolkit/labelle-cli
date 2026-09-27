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
for n in (1, 2, 3):
    print(f"PREBUILD_SAY {step} stdout line {n} of 3", flush=True)
    print(f"PREBUILD_SAY {step} stderr line {n} of 3", file=sys.stderr, flush=True)
'''


def said(step):
    return [f"PREBUILD_SAY {step} {stream} line {n} of 3" for n in (1, 2, 3) for stream in ("stdout", "stderr")]


def zon_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


with tempfile.TemporaryDirectory(prefix="labelle-prebuild-stdio-") as temp:
    base = Path(temp).resolve()
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
    (project / "tools").mkdir(parents=True)
    (project / "tools" / "say.py").write_text(SAY)
    # No .inputs/.outputs: the steps run on every build.
    steps = ", ".join(f".{{ .run = .{{ {zon_str(sys.executable)}, \"tools/say.py\", \"{s}\" }} }}" for s in ("one", "two"))
    (project / "project.labelle").write_text(f'.{{ .name = "game", .zig_version = "{version}", .prebuild = .{{ {steps} }} }}')
    env = dict(os.environ, LABELLE_HOME=str(base / "home"), LABELLE_ZIG=zig, LABELLE_ASSEMBLER=str(assembler))
    env.pop("LABELLE_NO_PREBUILD", None)
    checks = 0

    def lines_of(path):
        data = path.read_bytes()
        text = data.decode("utf-8", errors="replace")
        # An overwrite past the old end of file leaves a hole of NULs.
        assert b"\0" not in data, (path.name, "NUL bytes in redirected output", text)
        return text, text.replace("\r\n", "\n").split("\n")

    def in_order(lines, expected, what):
        """Every expected line is present exactly once, whole, in this order."""
        at = []
        for want in expected:
            hits = [i for i, line in enumerate(lines) if line.strip() == want]
            assert len(hits) == 1, (what, want, len(hits), "\n".join(lines))
            at.append(hits[0])
        assert at == sorted(at), (what, "out of order", expected, "\n".join(lines))

    def run(stdout, stderr):
        result = subprocess.run([cli, "build", "--progress=json"], cwd=project, env=env, stdin=subprocess.DEVNULL,
                                stdout=stdout, stderr=stderr, timeout=600)
        return result.returncode

    # `labelle build --progress=json > out.ndjson 2> err.log`: every prebuild
    # line lands in err.log, whole and in order; stdout stays pure NDJSON.
    out_log, err_log = base / "out.ndjson", base / "err.log"
    with open(out_log, "wb") as out, open(err_log, "wb") as err:
        code = run(out, err)
    err_text, err_lines = lines_of(err_log)
    out_text, out_lines = lines_of(out_log)
    assert code == 0, (code, err_text, out_text)
    in_order(err_lines, said("one") + said("two"), "2> err.log")
    assert "PREBUILD_SAY" not in out_text, ("prebuild output leaked into the NDJSON feed", out_text)
    for line in out_lines:
        if line.strip():
            json.loads(line)
    checks += 1

    # `labelle build --progress=json > all.log 2>&1`: one file, one offset.
    all_log = base / "all.log"
    with open(all_log, "wb") as sink:
        code = run(sink, subprocess.STDOUT)
    all_text, all_lines = lines_of(all_log)
    assert code == 0, (code, all_text)
    in_order(all_lines, said("one") + said("two"), "> all.log 2>&1")
    checks += 1

    print(f"prebuild stdio: {checks} redirected CLI invocations passed")
