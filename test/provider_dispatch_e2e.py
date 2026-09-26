"""Real CLI/provider boundary; no assembler, network, or game dependencies.

python test/provider_dispatch_e2e.py --zig /absolute/path/to/zig [--cli ...]
Every workspace is temporary. Runs on Windows, macOS and Linux.
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
manifest = '''.{ .name = "fixture", .manifest_version = 2,
    .command_contract = ">=1.0.0 <2.0.0", .namespace = "probe",
    .commands = .{
        .{ .name = "inspect", .build_step = "probe-tool", .executable = "bin/provider-probe", .help = "Inspect context" },
        .{ .name = "missing", .build_step = "missing-tool", .executable = "bin/absent", .help = "Missing output" },
    },
}'''
with tempfile.TemporaryDirectory(prefix="labelle-provider-") as temp:
    base = Path(temp).resolve()
    provider = base / "provider with spaces"
    shutil.copytree(fixture, provider)
    (provider / "plugin.labelle").write_text(manifest)
    project = base / "project"
    project.mkdir()
    nested = project / "nested"
    nested.mkdir()
    dep = '.{ .name = "fixture", .repo = "local:../provider with spaces", .version = "1.0.0" }'
    project_text = f'.{{ .name = "game", .zig_version = "{version}", .plugins = .{{ {dep} }} }}'
    (project / "project.labelle").write_text(project_text)
    lock = f'.{{ .plugins = .{{ {dep} }} }}'
    lock_file = project / "labelle.lock"
    home = base / "home"
    env = dict(os.environ, LABELLE_HOME=str(home), LABELLE_ZIG=zig)
    capture = project / ".labelle/providers/fixture/capture.json"
    checks = 0

    def run(*args, code=0, cwd=nested):
        global checks
        result = subprocess.run([cli, *args], cwd=cwd, env=env, text=True, capture_output=True, timeout=180)
        assert (result.returncode != 0 if code == -1 else result.returncode == code), (args, result.returncode, result.stdout, result.stderr)
        assert "leaked" not in result.stderr, result.stderr
        checks += 1
        return result

    # Metadata help is safe even with no lock/compiler.
    env["LABELLE_ZIG"] = str(base / "nonexistent-zig")
    assert "probe inspect" in run("help").stderr
    run("probe", "--help")
    run("probe", "inspect", "--help")
    assert not home.exists(), "help provisioned a compiler or build directory"
    assert "MissingProjectLock" in run("probe", "inspect", code=1).stderr
    lock_file.write_text(lock)
    assert "ProviderCompilerMissing" in run("probe", "inspect", code=1).stderr
    env["LABELLE_ZIG"] = zig
    literal = ["one two", "", 'quote"here', "$literal", "--platform=not-a-cli-flag", "--", "tail"]
    run("probe", "inspect", *literal)
    first = json.loads(capture.read_text())
    assert first["args"] == literal, first
    assert Path(first["cwd"]) == project
    ctx = first["context"]
    assert ctx["contract_version"] == "1.0.0" and ctx["target"] == "desktop"
    assert ctx["invocation"] == {"kind": "command", "id": "inspect", "step": None, "phase": None}
    assert Path(ctx["package_dir"]) == provider
    assert Path(ctx["lock_file"]) == lock_file
    assert not Path(first["context_path"]).exists(), "context not cleaned after success"
    assert not list((home / "provider-runs").iterdir()), "run workspace not cleaned"
    cache_before = {p: (p.stat().st_size, p.stat().st_mtime_ns) for p in (home / "zig-local-cache" / "o").rglob("*") if p.is_file()}
    assert cache_before, "cache reuse assertion needs actual compiled artifacts"
    run("probe", "inspect")
    cache_after = {p: (p.stat().st_size, p.stat().st_mtime_ns) for p in (home / "zig-local-cache" / "o").rglob("*") if p.is_file()}
    assert cache_after == cache_before, "unchanged invocation did not reuse compiled artifacts"
    (provider / "revision.zig").write_text('pub const value = "edited";\n')
    run("probe", "inspect")
    assert json.loads(capture.read_text())["revision"] == "edited", "stale local dependency reused"
    run("probe", "inspect", "fail", code=7)
    assert not list((home / "provider-runs").iterdir()), "run workspace not cleaned after failure"
    run("probe", "inspect", "crash", code=-1)
    assert not list((home / "provider-runs").iterdir()), "run workspace not cleaned after crash"
    # A relative LABELLE_HOME is pinned to the CLI's cwd, never to the provider
    # package the Zig build runs from — otherwise the install lands beneath the
    # provider source while the CLI looks beneath its own cwd.
    provider_entries = sorted(p.name for p in provider.iterdir())
    env["LABELLE_HOME"] = "relative-home"
    run("probe", "inspect")
    relative_runs = nested / "relative-home" / "provider-runs"
    assert relative_runs.is_dir() and not list(relative_runs.iterdir()), "relative workspace not beneath the caller's cwd"
    assert sorted(p.name for p in provider.iterdir()) == provider_entries, "relative cache tree left beneath the provider"
    env["LABELLE_HOME"] = str(home)
    # Successful build with missing declared executable must not run an old artifact.
    run("probe", "missing", code=1)
    run("probe", "unknown", code=1)
    lock_file.write_text(lock.replace('version = "1.0.0"', 'version = "2.0.0"'))
    assert "StaleProviderPin" in run("probe", "inspect", code=1).stderr
    lock_file.write_text(lock)
    (provider / "plugin.labelle").write_text(manifest.replace(">=1.0.0 <2.0.0", ">=2.0.0"))
    assert "UnsupportedContract" in run("probe", "inspect", code=1).stderr
    (provider / "plugin.labelle").write_text(manifest.replace('namespace = "probe"', 'namespace = "build"'))
    assert "ReservedNamespace" in run("probe", "inspect", code=1).stderr
    # Built-in help is still printed and exits 0; provider discovery on top
    # of it is best-effort and only warns.
    broken = run("help")
    assert "Usage: labelle" in broken.stderr and "ReservedNamespace" in broken.stderr, broken.stderr
    assert "probe inspect" not in broken.stderr, broken.stderr
    (provider / "plugin.labelle").write_text(manifest)
    (project / "project.labelle").write_text("not a project manifest")
    for args in (("help",), ()):
        broken = run(*args)
        assert "Usage: labelle" in broken.stderr and "warning" in broken.stderr, (args, broken.stderr)
    (project / "project.labelle").write_text(project_text)
    remote_dep = dep.replace("local:../provider with spaces", "example/fixture")
    remote_dir = home / "packages/plugins/example/fixture/1.0.0"
    remote_dir.mkdir(parents=True)
    (remote_dir / "plugin.labelle").write_text(manifest)
    (project / "project.labelle").write_text(project_text.replace(dep, remote_dep))
    lock_file.write_text(lock.replace(dep, remote_dep))
    assert "RemoteProviderIntegrityRequired" in run("probe", "inspect", code=1).stderr
    lock_file.write_text(lock)
    (project / "project.labelle").write_text(project_text[:-1] + ', .provider_config = .{ .{ .package = "fixture", .file = "settings.json" } } }')
    assert "MissingProviderConfig" in run("probe", "inspect", code=1).stderr
    (project / "project.labelle").write_text(project_text)
    # No project-global fallback.
    run("probe", "inspect", cwd=base, code=1)
    # An uncached Zig dependency fails in system mode before build code runs.
    package_manifest = (Path(__file__).resolve().parents[1] / "build.zig.zon").read_text()
    (provider / "build.zig.zon").write_text(package_manifest)
    missing_dep = run("probe", "inspect", code=-1)
    dependency_hash = package_manifest.split('.hash = "', 1)[1].split('"', 1)[0]
    assert dependency_hash in missing_dep.stderr, missing_dep.stderr
    assert "package not found at" in missing_dep.stderr, missing_dep.stderr
    (provider / "build.zig.zon").unlink()
    # Compile failure must not run a previously successful install.
    capture.unlink()
    (provider / "revision.zig").write_text("invalid zig\n")
    run("probe", "inspect", code=-1)
    assert not capture.exists(), "stale tool ran after failed build"
    assert not list((home / "provider-runs").iterdir())
    print(f"provider dispatch: {checks} real CLI invocations passed")
