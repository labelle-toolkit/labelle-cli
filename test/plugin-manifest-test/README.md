# plugin-manifest-test

End-to-end system test fixture for the `plugin.labelle` manifest system (see [`docs/RFC-plugin-manifest.md`](../../docs/RFC-plugin-manifest.md)).

## What this exercises

Runs the real `labelle generate` binary against a minimal game project that declares a fake plugin. The fake plugin ships a `plugin.labelle` that declares `state_machines/` as a plugin-contributed convention directory. The system test asserts the CLI:

1. **Reads** the plugin's `plugin.labelle` during `labelle generate`
2. **Copies** the game project's `state_machines/probe_machine.zig` into the generated build target (`.labelle/raylib_desktop/state_machines/probe_machine.zig`)
3. **Rejects** malformed manifests (path traversal, duplicate declarations, missing `extension`, etc.) with non-zero exit codes — the CI step flips the manifest content and re-runs generate to confirm failure

Unlike the unit tests in `generator/src/plugin_manifest.zig`, this fixture exercises the entire pipeline end-to-end: plugin resolution via `cache.resolvePlugin`, the `deps_linker` hardlink pass, the manifest scan loop in `generator/src/root.zig`, and the actual file I/O of the copy routines.

## Layout

```
plugin-manifest-test/
├── README.md                      # you are here
├── project.labelle                # declares fake-fsm-plugin as a local plugin
├── scenes/
│   └── main.jsonc                 # minimal scene (no entities)
├── scripts/                       # empty — no scripts needed for this test
├── state_machines/                # plugin-declared convention dir
│   └── probe_machine.zig          # stub file the test asserts gets copied
└── fake-fsm-plugin/               # the plugin itself
    ├── plugin.labelle             # declares state_machines/ as copy_and_scan .zig
    ├── build.zig                  # minimal module build
    ├── build.zig.zon              # no deps, tiny package
    └── src/
        └── root.zig               # no-op stub
```

## Running locally

From this directory:

```bash
# Build the CLI from the repo root first
cd ../.. && zig build && cd test/plugin-manifest-test

# Happy path: run generate and confirm the probe file was copied
../../zig-out/bin/labelle generate
test -f .labelle/raylib_desktop/state_machines/probe_machine.zig \
    && echo "OK: state_machines/probe_machine.zig copied"

# Cleanup
rm -rf .labelle
```

## Requirements

Because `labelle generate` loads the engine template, this fixture depends on `labelle-core`, `labelle-engine`, and `labelle-gfx` being checked out as siblings of `labelle-cli`. In CI that's handled by the `versions-integration` job. Locally you only need the siblings if you want to run this fixture — they are not required for `zig build test`.

## Why not a Zig unit test

The unit tests in `generator/src/plugin_manifest.zig` cover the manifest parser and validation logic. This fixture exists to catch regressions in the *integration glue*:

- Does `cache.resolvePlugin` correctly resolve `local:fake-fsm-plugin` relative to `project_dir`?
- Does the generator's plugin loop actually hand control to the manifest reader?
- Does `scanner.copyAndScan` produce the expected target directory when called from the new code path?
- Does `deps_linker` tolerate a plugin whose role is purely manifest contribution (no engine integration)?

Those questions can't be answered from a single Zig file — they need the real binary.
