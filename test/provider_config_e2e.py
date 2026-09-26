"""Run the real provider across the shared project/configuration boundary."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--zig", default=shutil.which("zig"))
parser.add_argument("--cli", default=str(Path(__file__).resolve().parents[1] / "zig-out/bin" / ("labelle.exe" if os.name == "nt" else "labelle")))
options = parser.parse_args()
assert options.zig
zig = str(Path(options.zig).resolve())
cli = str(Path(options.cli).resolve())
version = subprocess.check_output([zig, "version"], text=True).strip()
fixture = Path(__file__).parent / "fixtures/provider"
checks = 0
with tempfile.TemporaryDirectory(prefix="labelle-settings-") as temp:
    base = Path(temp).resolve()
    provider = base / "provider"
    shutil.copytree(fixture, provider)
    (provider / "plugin.labelle").write_text('''.{ .name = "fixture", .manifest_version = 2,
        .command_contract = ">=1.0.0 <2.0.0", .namespace = "probe",
        .commands = .{ .{ .name = "inspect", .build_step = "probe-tool", .executable = "bin/provider-probe", .help = "Inspect" } } }''')
    project = base / "project"
    project.mkdir()
    nested = project / "nested"
    nested.mkdir()
    (project / "providers").mkdir()
    settings = project / "providers/settings.json"
    settings.write_text('{"label":"first"}')
    dep = '.{ .name = "fixture", .repo = "local:../provider", .version = "1.0.0" }'
    runtime_dep = '.{ .name = "runtime", .repo = "local:../runtime" }'
    (base / "runtime").mkdir()
    (project / "labelle.lock").write_text('.{ .plugins = .{ ' + dep + ' } }')
    capture = project / ".labelle/providers/fixture/capture.json"
    env = dict(os.environ, LABELLE_HOME=str(base / "home"), LABELLE_ZIG=zig)

    def entry(package="fixture", file="providers/settings.json", extra=""):
        return '.{ .package = ' + json.dumps(package) + ', .file = ' + json.dumps(file) + extra + ' }'

    def config(entries):
        (project / "project.labelle").write_text('.{ .name = "game", .zig_version = "' + version + '", .plugins = .{ ' + dep + ', ' + runtime_dep + ' }, .provider_config = .{ ' + ', '.join(entries) + ' } }')

    def run(*args, code=0):
        global checks
        result = subprocess.run([cli, *args], cwd=nested, env=env, text=True, capture_output=True, timeout=180)
        assert result.returncode == code, (args, result.returncode, result.stderr)
        assert "leaked" not in result.stderr, result.stderr
        checks += 1
        return result

    def reject(entries, error):
        config(entries)
        capture.unlink(missing_ok=True)
        # If validation accidentally reaches the build, this deliberately
        # broken build script exposes it instead of silently running a tool.
        build = provider / "build.zig"
        original = build.read_text()
        build.write_text("deliberately invalid build code\n")
        try:
            result = run("probe", "inspect", code=1)
            assert error in result.stderr, result.stderr
            assert "build.zig:" not in result.stderr, result.stderr
            assert not capture.exists()
        finally:
            build.write_text(original)

    config([entry()])
    run("probe", "inspect")
    first = json.loads(capture.read_text())
    assert Path(first["context"]["config_file"]) == settings.resolve()
    assert first["setting"] == "first"
    settings.write_text('{"label":"edited"}')
    run("probe", "inspect")
    assert json.loads(capture.read_text())["setting"] == "edited"
    config([])
    run("probe", "inspect")
    assert json.loads(capture.read_text())["context"]["config_file"] is None
    assert json.loads(capture.read_text())["setting"] is None
    reject([entry(file="missing.json")], "MissingProviderConfig")
    reject([entry(), entry()], "DuplicateProviderConfig")
    reject([entry(package="undeclared")], "UndeclaredProviderConfig")
    reject([entry(package="runtime")], "UnresolvedProviderConfig")
    reject([entry(extra=", .typo = true")], "ParseZon")
    reject([entry(file="../outside.json")], "InvalidProviderConfigPath")
    reject([entry(file="/absolute.json")], "InvalidProviderConfigPath")
    reject([entry(file="C:/absolute.json")], "InvalidProviderConfigPath")
    reject([entry(file="providers")], "InvalidProviderConfigFile")
    settings.write_text('{"label":')
    reject([entry()], "InvalidProviderConfigJson")
    settings.write_text('{"label":"one","label":"two"}')
    reject([entry()], "InvalidProviderConfigJson")
    # Syntactically valid JSON with wrong provider schema is the provider's
    # responsibility; our fixture validates before writing its capture.
    settings.write_text('{"unexpected":true}')
    config([entry()])
    capture.unlink(missing_ok=True)
    run("probe", "inspect", code=1)
    assert not capture.exists()
    settings.write_text('{"label":"restored"}')
    # A directory junction tests canonical containment on Windows without
    # requiring the symlink privilege. POSIX uses an ordinary directory link.
    outside = base / "outside"
    outside.mkdir()
    (outside / "settings.json").write_text('{"label":"outside"}')
    link = project / "linked"
    if os.name == "nt":
        subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(outside)], check=True, capture_output=True)
    else:
        link.symlink_to(outside, target_is_directory=True)
    try:
        reject([entry(file="linked/settings.json")], "EscapingProviderConfig")
    finally:
        if os.name == "nt":
            link.rmdir()  # Removes only the junction, never its target.
        else:
            link.unlink()
    assert (outside / "settings.json").exists()
    # A link into the project is accepted and supplied as its canonical path.
    if os.name == "nt":
        subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(settings.parent)], check=True, capture_output=True)
    else:
        link.symlink_to(settings.parent, target_is_directory=True)
    try:
        config([entry(file="linked/settings.json")])
        run("probe", "inspect")
        assert Path(json.loads(capture.read_text())["context"]["config_file"]) == settings.resolve()
    finally:
        if os.name == "nt":
            link.rmdir()
        else:
            link.unlink()
    # Two real providers get their own mapping, independent of entry order.
    other = base / "other"
    shutil.copytree(provider, other)
    other_manifest = (other / "plugin.labelle").read_text().replace('.name = "fixture"', '.name = "other"').replace('.namespace = "probe"', '.namespace = "other"')
    (other / "plugin.labelle").write_text(other_manifest)
    other_dep = '.{ .name = "other", .repo = "local:../other", .version = "1.0.0" }'
    other_settings = project / "providers/other.json"
    other_settings.write_text('{"label":"other-value"}')
    (project / "project.labelle").write_text('.{ .name = "game", .zig_version = "' + version + '", .plugins = .{ ' + dep + ', ' + other_dep + ' }, .provider_config = .{ ' + entry(package="other", file="providers/other.json") + ', ' + entry() + ' } }')
    (project / "labelle.lock").write_text('.{ .plugins = .{ ' + dep + ', ' + other_dep + ' } }')
    run("probe", "inspect")
    assert json.loads(capture.read_text())["setting"] == "restored"
    run("other", "inspect")
    other_capture = json.loads((project / ".labelle/providers/other/capture.json").read_text())
    assert other_capture["setting"] == "other-value"
    assert Path(other_capture["context"]["config_file"]) == other_settings.resolve()
    print(f"Provider configuration: {checks} real CLI invocations passed")
