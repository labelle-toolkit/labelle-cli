"""Real CLI, GitHub-shaped archives, no network. Run after zig build."""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
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
manifest = '''.{ .name = "fixture", .manifest_version = 2,
 .command_contract = ">=1.0.0 <2.0.0", .namespace = "probe",
 .commands = .{ .{ .name = "inspect", .build_step = "probe-tool",
 .executable = "bin/provider-probe", .help = "Inspect" } } }'''
checks = 0

def archive(revision="original", extra=None):
    payload = io.BytesIO()
    with tarfile.open(fileobj=payload, mode="w", format=tarfile.PAX_FORMAT) as tar:
        files = {p.name: p.read_bytes() for p in fixture.glob("*.zig")}
        files["plugin.labelle"] = manifest.encode()
        files["revision.zig"] = f'pub const value = "{revision}";\n'.encode()
        for name, content in files.items():
            info = tarfile.TarInfo("fixture-commit/" + name)
            info.size = len(content)
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(content))
        if extra:
            info, content = extra
            info.size = len(content)
            tar.addfile(info, io.BytesIO(content))
    return gzip.compress(payload.getvalue(), mtime=0)

with tempfile.TemporaryDirectory(prefix="labelle-github-") as temp:
    base = Path(temp).resolve()
    project = base / "project"
    project.mkdir()
    home = base / "home"
    env = dict(os.environ, LABELLE_HOME=str(home), LABELLE_ZIG=zig)
    registry = base / "providers.json"
    lock = project / "labelle.providers.lock"
    preview = project / ".labelle/providers.preview.json"
    capture = project / ".labelle/providers/fixture/capture.json"
    data = archive()
    pin = {"package": "fixture", "repo": "example/fixture", "version": "1.0.0", "commit": "1" * 40, "sha256": hashlib.sha256(data).hexdigest()}

    def config(pins):
        deps = ",".join('.{ .name = "%s", .repo = "%s", .version = "%s" }' % (p["package"], p["repo"], p["version"]) for p in pins)
        (project / "project.labelle").write_text('.{ .name = "game", .zig_version = "%s", .plugins = .{ %s } }' % (version, deps))
        (project / "labelle.lock").write_text('.{ .plugins = .{ %s } }' % deps)

    def metadata(pins):
        registry.write_text(json.dumps({"schema_version": 1, "providers": pins}))

    def seed(pin, payload):
        path = home / "provider-archives" / (pin["sha256"] + ".tar.gz")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
        return path

    def run(*args, code=0):
        global checks
        result = subprocess.run([cli, *map(str, args)], cwd=project, env=env, capture_output=True, text=True, timeout=180)
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        assert "leaked" not in result.stderr, result.stderr
        checks += 1
        return result

    def resolve(*flags, code=0):
        return run("providers", "resolve", registry, "--offline", *flags, code=code)

    def accept(code=0):
        # Acceptance is bound to a preview, so every accept reviews first.
        resolve()
        assert preview.exists(), "preview was not recorded"
        return resolve("--accept", code=code)

    def cleaned():
        for name in ("provider-sources", "provider-runs"):
            directory = home / name
            assert not directory.exists() or not list(directory.iterdir()), f"workspace leaked: {directory}"

    config([pin])
    metadata([pin])
    run("providers", "resolve", "--help")
    # Nothing reviewed yet: accept fails closed before any archive work.
    assert "ProviderPreviewMissing" in resolve("--accept", code=1).stderr
    assert not lock.exists() and not preview.exists() and not home.exists()
    assert "Preview: 1" in resolve().stderr
    assert not lock.exists() and not home.exists(), "preview changed state"
    recorded = json.loads(preview.read_text())
    assert recorded["providers"] == [dict(pin, archive_url="https://codeload.github.com/example/fixture/tar.gz/" + pin["commit"])]
    assert recorded["source"] == str(registry) and len(recorded["digest"]) == 64
    assert "ProviderArchiveMissing" in resolve("--accept", code=1).stderr
    assert not lock.exists(), "failed preparation wrote a lock"
    assert preview.exists(), "failed preparation consumed the preview"
    archive_path = seed(pin, data)
    resolve("--accept")
    assert json.loads(lock.read_text())["providers"] == [pin]
    assert not preview.exists(), "successful accept kept the preview"
    assert not capture.exists(), "resolve ran package code"
    cleaned()
    # Acceptance is bound to the reviewed preview: a registry repointed between
    # the two invocations is rejected by package and field, and the lock is untouched.
    old_lock = lock.read_bytes()
    resolve()
    metadata([dict(pin, commit="2" * 40)])
    err = resolve("--accept", code=1).stderr
    assert "ProviderPreviewMismatch" in err and "provider 'fixture' commit changed since preview" in err, err
    assert lock.read_bytes() == old_lock and preview.exists()
    metadata([dict(pin, sha256="0" * 64)])
    err = resolve("--accept", code=1).stderr
    assert "ProviderPreviewMismatch" in err and "provider 'fixture' sha256 changed since preview" in err, err
    assert lock.read_bytes() == old_lock and preview.exists()
    # An edited preview fails its own digest instead of being trusted.
    metadata([pin])
    preview.write_text(preview.read_text().replace(pin["commit"], "2" * 40))
    assert "ProviderPreviewCorrupt" in resolve("--accept", code=1).stderr
    assert lock.read_bytes() == old_lock
    # The registry serving the reviewed record again is accepted.
    accept()
    assert lock.read_bytes() == old_lock and not preview.exists()
    cleaned()
    run("probe", "inspect", "one two", "", "$literal")
    first = json.loads(capture.read_text())
    assert first["args"] == ["one two", "", "$literal"] and first["revision"] == "original"
    assert not Path(first["context"]["package_dir"]).exists(), "source survived invocation"
    cleaned()
    # Changes to the old unverified extraction cache cannot supply executable code.
    legacy = home / "packages/plugins/example/fixture/1.0.0"
    legacy.mkdir(parents=True)
    (legacy / "plugin.labelle").write_text("not a manifest")
    run("probe", "inspect")
    assert json.loads(capture.read_text())["revision"] == "original"
    # Metadata help verifies sources without resolving/building a compiler.
    env["LABELLE_ZIG"] = str(base / "nonexistent-zig")
    run("probe", "--help")
    env["LABELLE_ZIG"] = zig
    old_lock = lock.read_bytes()
    capture.unlink()
    archive_path.write_bytes(data + b"tampered")
    assert "ProviderArchiveHashMismatch" in run("probe", "inspect", code=1).stderr
    assert "ProviderArchiveHashMismatch" in accept(code=1).stderr
    assert lock.read_bytes() == old_lock and not capture.exists()
    archive_path.write_bytes(data)
    # Failed preparation of the second provider must not replace a working lock.
    broken = dict(pin, package="broken", repo="example/broken", sha256="0" * 64)
    config([pin, broken])
    metadata([pin, broken])
    accept(code=1)
    assert lock.read_bytes() == old_lock
    cleaned()
    config([pin])
    # Unsafe archives fail even when their compressed SHA-256 matches the pin.
    # Each entry names the rule that rejects it, so a stricter earlier check cannot mask a broken later one.
    for name, kind, reason in (
        ("fixture-commit/../escape.zig", None, "UnsafeProviderArchivePath"),
        ("fixture-commit/link", tarfile.SYMTYPE, "ProviderArchiveLinkNotSupported"),
        ("other-root/file.zig", None, "MultipleProviderArchiveRoots"),
        ("fixture-commit/CON", None, "ReservedProviderArchiveName"),
        ("fixture-commit/nul.zig", None, "ReservedProviderArchiveName"),
        ("fixture-commit/MAIN.ZIG", None, "DuplicateProviderArchivePath"),
        ("fixture-commit/ä.zig", None, "NonAsciiProviderArchivePath"),
        ("fixture-commit/ctrl\x01.zig", None, "ControlCharProviderArchivePath"),
    ):
        member = tarfile.TarInfo(name)
        if kind:
            member.type = kind
            member.linkname = "../../escape"
        unsafe_data = archive(extra=(member, b""))
        unsafe_pin = dict(pin, sha256=hashlib.sha256(unsafe_data).hexdigest())
        seed(unsafe_pin, unsafe_data)
        metadata([unsafe_pin])
        assert reason in accept(code=1).stderr, name
        assert lock.read_bytes() == old_lock
        assert not (base / "escape.zig").exists()
        cleaned()
    # Normal execution does not consult newly edited registry records.
    updated_data = archive("updated")
    updated = dict(pin, version="2.0.0", commit="2" * 40, sha256=hashlib.sha256(updated_data).hexdigest())
    seed(updated, updated_data)
    metadata([updated])
    run("probe", "inspect")
    assert json.loads(capture.read_text())["revision"] == "original"
    config([updated])
    assert "StaleProviderIntegrityPin" in run("probe", "inspect", code=1).stderr
    accept()
    run("probe", "inspect")
    assert json.loads(capture.read_text())["revision"] == "updated"
    assert json.loads(lock.read_text())["providers"] == [updated]
    cleaned()
    env["LABELLE_HOME"] = "../home"
    run("probe", "inspect")
    assert json.loads(capture.read_text())["revision"] == "updated"
    cleaned()
    env["LABELLE_HOME"] = str(home)
    # Missing and duplicate release records fail at preview, before any accept.
    metadata([pin])
    assert "ProviderReleaseNotInRegistry" in resolve(code=1).stderr
    metadata([updated, updated])
    assert "DuplicateProviderRelease" in resolve(code=1).stderr
    assert not preview.exists() and json.loads(lock.read_text())["providers"] == [updated]
    print(f"GitHub provider pins: {checks} real CLI invocations passed")
