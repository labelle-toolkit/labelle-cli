# Local Engine Path Test

This directory contains a test setup for the `--engine-path` functionality.

## Structure

```
local-engine-test/
├── fake-engine/          # A minimal fake labelle-engine
│   ├── build.zig
│   ├── build.zig.zon
│   └── src/
│       ├── engine.zig    # Stub engine module
│       └── generator.zig # Fake generator that creates project files
└── test-project/         # A test project that uses the fake engine
    └── project.labelle
```

## How to Test

1. Build the CLI:
   ```bash
   cd /path/to/labelle-cli
   zig build
   ```

2. Run generate with local engine path:
   ```bash
   cd test/local-engine-test/test-project
   ../../../zig-out/bin/labelle generate --engine-path=../fake-engine
   ```

3. Expected result:
   - Should NOT try to fetch from GitHub
   - Should create `.labelle/build.zig.zon` with a path-based dependency
   - Should create `.labelle/build.zig`
   - Should create `main.zig` if it doesn't exist

## Current Issue (Issue #14)

The `--engine-path` flag currently has a bug where:
1. The CLI correctly creates bootstrap files with local path
2. But the generator still tries to fetch from GitHub for the hash
3. This fails with "ref not found" errors

## Expected Behavior

When `--engine-path` is provided:
1. Skip all GitHub fetching
2. Use path-based dependencies in all generated build.zig.zon files
3. Pass the local path to the generator so it can use it too
