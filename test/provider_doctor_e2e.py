"""`labelle doctor` runs the pinned providers' doctors after the core checks.

python test/provider_doctor_e2e.py --zig /absolute/path/to/zig [--cli ...]

Three local copies of the probe provider (test/fixtures/provider): `beta` and
`alpha` declare a `doctor` command, `gamma` does not. They are declared out of
namespace order, so the run order proves the sort. A fourth, remote provider
is pinned in labelle.providers.lock but its archive is never cached: it must
be a failed check with the fetch hint, without a download and without
stopping the others. A fifth, remote and unpinned, never runs: uncached it is
a WARN that leaves the exit code alone, cached runtime-only it is not listed,
cached as a provider (or with a malformed manifest) it fails. Run from a
subdirectory, both halves use the project root. An invalid settings file
fails only its own provider's doctor. No assembler, network or game dependencies; every
workspace is temporary. Runs on Windows, macOS and Linux.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
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


def manifest(package, namespace, commands):
    records = ", ".join(
        f'.{{ .name = "{name}", .build_step = "probe-tool", .executable = "bin/provider-probe", .help = "{name} probe" }}'
        for name in commands
    )
    return f'''.{{ .name = "{package}", .manifest_version = 2,
    .command_contract = ">=1.0.0 <2.0.0", .namespace = "{namespace}",
    .commands = .{{ {records} }},
}}'''


with tempfile.TemporaryDirectory(prefix="labelle-provider-doctor-") as temp:
    base = Path(temp).resolve()
    providers = {
        "beta-pkg": ("beta", ["inspect", "doctor"]),
        "gamma-pkg": ("gamma", ["inspect"]),
        "alpha-pkg": ("alpha", ["doctor"]),
    }
    deps = []
    for package, (namespace, commands) in providers.items():
        shutil.copytree(fixture, base / package)
        (base / package / "plugin.labelle").write_text(manifest(package, namespace, commands))
        deps.append(f'.{{ .name = "{package}", .repo = "local:../{package}", .version = "1.0.0" }}')
    project = base / "project"
    project.mkdir()
    # `.backend = .wgpu`, `.gamepad = .none`: the core checks need no system
    # library here, so whether they pass depends only on the host's Python
    # (checked below). The explicit backend also shows which project the
    # core half read.
    def write_project(extra_deps=(), extra=""):
        all_deps = ", ".join([*deps, *extra_deps])
        (project / "project.labelle").write_text(
            f'.{{ .name = "game", .zig_version = "{version}", .backend = .wgpu, .gamepad = .none, .plugins = .{{ {all_deps} }}{extra} }}'
        )
        (project / "labelle.lock").write_text(f".{{ .plugins = .{{ {all_deps} }} }}")

    write_project()
    home = base / "home"
    env = dict(os.environ, LABELLE_HOME=str(home), LABELLE_ZIG=zig)
    env.pop("PROVIDER_PROBE_FAIL_PACKAGE", None)
    outputs = project / ".labelle" / "providers"
    checks = 0

    def run(*args, cwd=project, extra_env=None):
        global checks
        result = subprocess.run([cli, "doctor", *args], cwd=cwd, env=dict(env, **(extra_env or {})), text=True, capture_output=True, timeout=600)
        assert "leaked" not in result.stderr, result.stderr
        checks += 1
        return result

    def invocations(package):
        log = outputs / package / "hooks.log"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def core_ok(result):
        return "All required desktop build dependencies are present." in result.stderr

    # One provider fails: both doctors still run, in namespace order, and
    # the aggregate fails whatever the core checks found.
    failing = run(extra_env={"PROVIDER_PROBE_FAIL_PACKAGE": "alpha-pkg"})
    assert failing.returncode == 1, (failing.returncode, failing.stderr)
    err = failing.stderr
    alpha, beta = invocations("alpha-pkg"), invocations("beta-pkg")
    assert len(alpha) == 1 and len(beta) == 1, (alpha, beta, err)
    for record in (alpha[0], beta[0]):
        assert record["invocation"] == {"kind": "command", "id": "doctor", "step": None, "phase": None}, record
        assert record["context"]["project_dir"] and Path(record["context"]["project_dir"]) == project
    assert Path(alpha[0]["package_dir"]) == base / "alpha-pkg"
    assert Path(beta[0]["package_dir"]) == base / "beta-pkg"
    # alpha ran first although beta is declared first, and alpha failing did
    # not stop beta.
    assert alpha[0]["nanoseconds"] < beta[0]["nanoseconds"], (alpha, beta)
    # The command gets no trailing arguments: the same as `labelle <ns> doctor`.
    assert json.loads((outputs / "beta-pkg" / "capture.json").read_text())["args"] == []
    # A provider without a `doctor` command is skipped, never built or run.
    assert not (outputs / "gamma-pkg").exists(), "a provider without doctor was run"
    assert err.index("labelle doctor\n") < err.index("labelle alpha doctor") < err.index("labelle beta doctor"), err
    assert "[ FAIL ] labelle alpha doctor exited 7" in err, err
    assert "[  OK  ] labelle beta doctor" in err, err
    assert "Provider doctors: 2 checked, 1 failed (alpha)" in err, err
    assert "no `doctor` command: gamma-pkg" in err, err

    # All providers pass: the exit code is the core's.
    passing = run()
    assert passing.returncode == (0 if core_ok(passing) else 1), (passing.returncode, passing.stderr)
    assert "Provider doctors: 2 checked, 0 failed" in passing.stderr, passing.stderr
    assert len(invocations("alpha-pkg")) == 2 and len(invocations("beta-pkg")) == 2

    # The project directory argument reaches the providers too.
    from_outside = run(str(project), cwd=base)
    assert "Provider doctors: 2 checked, 0 failed" in from_outside.stderr, from_outside.stderr
    assert len(invocations("alpha-pkg")) == 3

    # From a subdirectory, BOTH halves use the project root: the core half
    # reports the root and the project's own backend, and the provider
    # doctors run. The count check comes first so it tracks the runs above.
    nested = project / "src" / "deep"
    nested.mkdir(parents=True)
    sub = run(cwd=nested)
    assert f"  project: {project}\n" in sub.stderr, sub.stderr
    assert "backend: wgpu" in sub.stderr, sub.stderr
    assert "Provider doctors: 2 checked, 0 failed" in sub.stderr, sub.stderr
    assert len(invocations("alpha-pkg")) == 4 and len(invocations("beta-pkg")) == 4
    # Neither the core half nor a provider wrote anything under the subdirectory.
    assert not any(nested.iterdir()), list(nested.iterdir())

    # `--core-only` skips the providers entirely.
    core = run("--core-only", extra_env={"PROVIDER_PROBE_FAIL_PACKAGE": "alpha-pkg"})
    assert core.returncode == (0 if core_ok(core) else 1), (core.returncode, core.stderr)
    assert "Provider doctors" not in core.stderr and "labelle alpha doctor" not in core.stderr, core.stderr
    assert len(invocations("alpha-pkg")) == 4 and len(invocations("beta-pkg")) == 4

    # `--json` stays the studio's single-line capability report.
    report = run("--json")
    assert report.stdout.count("\n") == 1 and json.loads(report.stdout)["capabilities"], report.stdout
    assert "Provider doctors" not in report.stderr, report.stderr

    # Outside a project: the core checks and one line about providers.
    outside = base / "outside"
    outside.mkdir()
    lone = run(cwd=outside)
    assert "Provider doctors run inside a project" in lone.stderr, lone.stderr
    assert lone.returncode == (0 if core_ok(lone) else 1), (lone.returncode, lone.stderr)

    # A pinned provider whose archive is not cached is a failed check with
    # the fetch hint; nothing is downloaded and the others still run.
    remote = '.{ .name = "delta", .repo = "github.com/example/delta", .version = "1.0.0" }'
    write_project([remote])
    (project / "labelle.providers.lock").write_text(json.dumps({
        "schema_version": 1,
        "providers": [{
            "package": "delta", "repo": "example/delta", "version": "1.0.0",
            "commit": "1" * 40, "sha256": "2" * 64,
        }],
    }))
    missing = run()
    err = missing.stderr
    assert missing.returncode == 1, (missing.returncode, err)
    assert "provider source unavailable: ProviderArchiveMissing" in err, err
    assert "labelle providers fetch" in err, err
    assert err.index("labelle alpha doctor") < err.index("labelle beta doctor") < err.index("\nprovider 'delta'\n"), err
    assert "Provider doctors: 3 checked, 1 failed (delta)" in err, err
    assert len(invocations("alpha-pkg")) == 5 and len(invocations("beta-pkg")) == 5
    archives = home / "provider-archives"
    assert not archives.exists() or not any(archives.iterdir()), "the doctor downloaded an archive"

    # A declared remote package with no integrity pin never runs. Not cached,
    # it is a WARN that leaves the exit code alone; cached runtime-only, it is
    # not listed; cached with provider features (or an unreadable manifest),
    # it FAILS with the resolve hint.
    unpinned = '.{ .name = "epsilon", .repo = "example/epsilon", .version = "1.0.0" }'

    def section(text, package, kind="provider"):
        start = text.index(f"\n{kind} '{package}'\n")
        return text[start:text.index("\n\n", start + 1)]

    # Cold, and the only other finding a WARN: the exit code is the core's.
    write_project([unpinned])
    cold = run()
    assert cold.returncode == (0 if core_ok(cold) else 1), (cold.returncode, cold.stderr)
    cold_section = section(cold.stderr, "epsilon", "package")
    assert "[ WARN ] not installed yet" in cold_section and "labelle install" in cold_section, cold_section
    assert "FAIL" not in cold_section, cold_section
    assert "Provider doctors: 3 checked, 0 failed, 1 not installed yet (epsilon)" in cold.stderr, cold.stderr
    assert len(invocations("alpha-pkg")) == 6 and len(invocations("beta-pkg")) == 6
    # With a real failure beside it, the failure alone decides.
    write_project([remote, unpinned])
    mixed = run()
    assert mixed.returncode == 1, (mixed.returncode, mixed.stderr)
    assert section(mixed.stderr, "epsilon", "package") == cold_section
    assert "Provider doctors: 4 checked, 1 failed (delta), 1 not installed yet (epsilon)" in mixed.stderr, mixed.stderr
    # Warm, runtime-only (no provider features): not listed at all.
    cached = home / "packages" / "plugins" / "example" / "epsilon" / "1.0.0"
    shutil.copytree(fixture, cached)
    (cached / "plugin.labelle").write_text('.{ .name = "epsilon" }')
    runtime = run()
    assert "epsilon" not in runtime.stderr, runtime.stderr
    assert "Provider doctors: 3 checked, 1 failed (delta)" in runtime.stderr, runtime.stderr
    # Warm, a provider manifest with a `doctor` command: FAIL, never run.
    (cached / "plugin.labelle").write_text(manifest("epsilon", "epsilon", ["doctor"]))
    warm = run()
    assert warm.returncode == 1, (warm.returncode, warm.stderr)
    warm_section = section(warm.stderr, "epsilon")
    assert "[ FAIL ] not verified: remote provider with no integrity pin" in warm_section, warm_section
    assert "labelle providers resolve" in warm_section, warm_section
    assert "Provider doctors: 4 checked, 2 failed (delta, epsilon)" in warm.stderr, warm.stderr
    # Its code never ran: no build, no output directory, no header of a run.
    assert "labelle epsilon doctor" not in warm.stderr, warm.stderr
    assert not (outputs / "epsilon").exists(), "an unverified package's tool ran"
    assert len(invocations("alpha-pkg")) == 9 and len(invocations("beta-pkg")) == 9

    # A MALFORMED cached manifest can't be cleared as runtime-only: the same
    # FAIL as a cached provider, and the valid providers' doctors still run.
    (cached / "plugin.labelle").write_text(".{ .name = ")
    broken = run()
    assert broken.returncode == 1, (broken.returncode, broken.stderr)
    assert section(broken.stderr, "epsilon") == warm_section, (section(broken.stderr, "epsilon"), warm_section)
    assert "provider discovery" not in broken.stderr, broken.stderr
    assert "Provider doctors: 4 checked, 2 failed (delta, epsilon)" in broken.stderr, broken.stderr
    assert len(invocations("alpha-pkg")) == 10 and len(invocations("beta-pkg")) == 10

    # Settings are resolved per provider: alpha's settings file is invalid
    # JSON, so alpha's doctor fails and beta's (valid settings) still runs.
    write_project(extra=', .provider_config = .{ .{ .package = "alpha-pkg", .file = "providers/alpha.json" }, .{ .package = "beta-pkg", .file = "providers/beta.json" } }')
    (project / "providers").mkdir()
    (project / "providers" / "alpha.json").write_text("{not json")
    (project / "providers" / "beta.json").write_text('{"label": "beta settings"}')
    settings = run()
    err = settings.stderr
    assert settings.returncode == 1, (settings.returncode, err)
    assert "[ FAIL ] labelle alpha doctor: InvalidProviderConfigJson" in err, err
    assert "[  OK  ] labelle beta doctor" in err, err
    assert "Provider doctors: 2 checked, 1 failed (alpha)" in err, err
    assert len(invocations("alpha-pkg")) == 10 and len(invocations("beta-pkg")) == 11
    assert json.loads((outputs / "beta-pkg" / "capture.json").read_text())["setting"] == "beta settings"
    # `labelle <ns> <cmd>` keeps validating every settings file.
    direct = subprocess.run([cli, "beta", "doctor"], cwd=project, env=env, text=True, capture_output=True, timeout=600)
    assert direct.returncode == 1 and "InvalidProviderConfigJson" in direct.stderr, (direct.returncode, direct.stderr)
    assert len(invocations("beta-pkg")) == 11

    print(f"provider doctor e2e: {checks} invocations OK")
