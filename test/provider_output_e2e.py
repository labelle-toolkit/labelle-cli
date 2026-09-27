"""CLI + provider output redirected to one FILE stays whole and in order (cli#446).

python test/provider_output_e2e.py --zig /absolute/path/to/zig [--cli ...]

`labelle build > log 2>&1` hands the CLI and every provider tool it spawns
the SAME open file description. Each writer must append at its shared offset
(streaming); a Zig 0.16 positional `File.writer` pwrite()s at its own offset,
starting from 0, so it overwrites what the CLI already wrote and is then
overwritten in turn. A pipe is unseekable, so pipes always looked fine: this
suite redirects to a real file. Generation is driven by a fake assembler (the
provider_hooks_e2e pattern). Every workspace is temporary. Runs on Windows,
macOS and Linux.
"""
import argparse
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

# `generate` writes a trivial host executable; the core build then runs
# between the `before build` and `after build` hooks.
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

TOOL = '.build_step = "probe-tool", .executable = "bin/provider-probe"'
MANIFEST = f'''.{{ .name = "fixture", .manifest_version = 2,
    .command_contract = ">=1.0.0 <2.0.0", .namespace = "probe",
    .commands = .{{ .{{ .name = "inspect", {TOOL}, .help = "Inspect context" }} }},
    .hooks = .{{
        .{{ .id = "pre", .step = .build, .target = "desktop", .when = .before, {TOOL} }},
        .{{ .id = "post", .step = .build, .target = "desktop", .when = .after, {TOOL} }},
    }},
}}'''


def said(id):
    """The fixture's PROVIDER_PROBE_SAY lines for one invocation, in order."""
    return [f"PROBE_SAY {id} {stream} line {n} of 3" for n in (1, 2, 3) for stream in ("stdout", "stderr")]


with tempfile.TemporaryDirectory(prefix="labelle-output-") as temp:
    base = Path(temp).resolve()
    provider = base / "fixture"
    shutil.copytree(fixture, provider)
    (provider / "plugin.labelle").write_text(MANIFEST)
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
    (project / "project.labelle").write_text(f'.{{ .name = "game", .zig_version = "{version}", .plugins = .{{ {dep} }} }}')
    (project / "labelle.lock").write_text(f'.{{ .plugins = .{{ {dep} }} }}')
    env = dict(os.environ, LABELLE_HOME=str(base / "home"), LABELLE_ZIG=zig, LABELLE_ASSEMBLER=str(assembler),
               LABELLE_NO_PREBUILD="1", PROVIDER_PROBE_SAY="1")
    for knob in ("PROVIDER_PROBE_FAIL", "PROVIDER_PROBE_PATCH", "PROVIDER_PROBE_COPY"):
        env.pop(knob, None)
    checks = 0

    def to_file(name, *args):
        """Run the CLI with stdout AND stderr redirected to one regular file."""
        global checks
        log = base / f"{name}.log"
        with open(log, "wb") as sink:
            result = subprocess.run([cli, *args], cwd=project, env=env, stdin=subprocess.DEVNULL,
                                    stdout=sink, stderr=subprocess.STDOUT, timeout=600)
        data = log.read_bytes()
        text = data.decode("utf-8", errors="replace")
        assert result.returncode == 0, (args, result.returncode, text)
        # An overwrite past the old end of file leaves a hole of NULs.
        assert b"\0" not in data, (args, "NUL bytes in redirected output", text)
        assert "leaked" not in text, text
        checks += 1
        return text.replace("\r\n", "\n").split("\n")

    def in_order(lines, expected, what):
        """Every expected line is present exactly once, whole, in this order."""
        at = []
        for want in expected:
            hits = [i for i, line in enumerate(lines) if line.strip() == want]
            assert len(hits) == 1, (what, want, len(hits), "\n".join(lines))
            at.append(hits[0])
        assert at == sorted(at), (what, "out of order", expected, "\n".join(lines))

    def find(lines, needle, what):
        hits = [i for i, line in enumerate(lines) if needle in line]
        assert len(hits) == 1, (what, needle, len(hits), "\n".join(lines))
        return hits[0]

    # A provider command on its own: its stdout and stderr share the file, so
    # two positional writers would each start at offset 0.
    lines = to_file("command", "probe", "inspect")
    in_order(lines, said("inspect"), "command")

    # `labelle build` around two hooks: the CLI's own lines come BEFORE the
    # first hook (a positional hook would overwrite them) and AFTER it (a
    # positional CLI would overwrite the hook's), with the core build between.
    lines = to_file("build", "build", "--progress=off")
    in_order(lines, said("pre") + said("post"), "build")
    first_pre = find(lines, said("pre")[0], "build")
    last_pre = find(lines, said("pre")[-1], "build")
    first_post = find(lines, said("post")[0], "build")
    assert find(lines, "FIXTURE_GENERATE", "build") < find(lines, "hook 'fixture/pre'", "build") < first_pre, "\n".join(lines)
    assert last_pre < find(lines, "build ok", "build") < find(lines, "hook 'fixture/post'", "build") < first_post, "\n".join(lines)
    print(f"provider output: {checks} redirected CLI invocations passed")
