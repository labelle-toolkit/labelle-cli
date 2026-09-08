#!/usr/bin/env python3
"""Run the real CLI with an offline assembler fixture: python3 test/plugin_compat_e2e.py.

Only install creates the remote manifest, so moving validation before install
or removing it makes the warning/order assertions fail. No packages are fetched.
Requires a built CLI and a POSIX host for the executable assembler fixture.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


CLI = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/labelle").resolve()
FAKE_ASSEMBLER = '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
if sys.argv[1] == "--protocol-version":
    print(99)
elif sys.argv[1] == "install":
    target = Path(os.environ["COMPAT_MANIFEST"])
    if os.environ["COMPAT_SOURCE"] == "remote":
        assert not target.exists(), "manifest must not exist before install"
        if os.environ["COMPAT_CONTENT"] != "missing":
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(os.environ["COMPAT_CONTENT"])
    print("FIXTURE_INSTALL_DONE", file=sys.stderr, flush=True)
elif sys.argv[1] == "generate":
    print("FIXTURE_GENERATE", file=sys.stderr, flush=True)
else:
    raise SystemExit("unexpected assembler invocation: " + repr(sys.argv))
'''


def check_case(name, content, warning=None, source="remote", core="1.28.0", count=1):
    with tempfile.TemporaryDirectory(prefix="labelle-core-compat-") as tmp:
        root = Path(tmp)
        cache = root / "cache"
        plugin_dir = (cache / "packages/plugins/example/fixture/4.0.2"
                      if source == "remote" else root / "local-plugin")
        manifest = plugin_dir / "plugin.labelle"
        if source == "local" and content != "missing":
            plugin_dir.mkdir()
            manifest.write_text(content)
        assembler = root / "assembler"
        assembler.write_text(FAKE_ASSEMBLER)
        assembler.chmod(0o755)
        repo = "example/fixture" if source == "remote" else "local:local-plugin"
        deps = ",\n".join(
            '.{ .name = "fixture%d", .repo = "%s", .version = "4.0.2" }' % (i, repo)
            for i in range(count)
        )
        (root / "project.labelle").write_text(
            '.{ .name = "compat", .core_version = %s, .plugins = .{%s} }' % (json.dumps(core), deps)
        )
        env = {**os.environ, "LABELLE_HOME": str(cache), "LABELLE_ASSEMBLER": str(assembler),
               "COMPAT_MANIFEST": str(manifest), "COMPAT_CONTENT": content, "COMPAT_SOURCE": source,
               "LABELLE_NO_PREBUILD": "1"}
        result = subprocess.run([str(CLI), "generate", "--progress=off"], cwd=root, env=env,
                                text=True, capture_output=True, timeout=30)
        output = result.stdout + result.stderr
        assert result.returncode == 0, (name, result.returncode, output)
        install = output.index("FIXTURE_INSTALL_DONE")
        generate = output.index("FIXTURE_GENERATE")
        assert install < generate, output
        if warning:
            assert install < output.index(warning) < generate, (name, output)
            assert f"{count} plugin compatibility warning(s)" in output, (name, output)
        else:
            assert "plugin compatibility warning(s)" not in output, (name, output)
            assert "warning: plugin" not in output, (name, output)
        print("PASS", name)


def manifest(declaration):
    return '.{ .name = "fixture", .core_compat = %s }' % json.dumps(declaration)


check_case("remote mismatch after install", manifest(">=2.0.0"), "declares core >=2.0.0")
check_case("remote matching declaration", manifest(">=1.20.0 <2.0.0"))
check_case("absent declaration", '.{ .name = "fixture" }')
check_case("absent manifest", "missing")
check_case("malformed range", manifest("banana"), "unreadable .core_compat")
check_case("local plugin mismatch", manifest(">=2.0.0"), "declares core >=2.0.0", source="local")
check_case("local core override", manifest(">=2.0.0"), core="local:../core")
check_case("more than 255 warnings remain nonfatal", manifest(">=2.0.0"), "declares core >=2.0.0", count=256)
