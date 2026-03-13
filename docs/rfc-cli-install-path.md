# RFC: CLI Installation Path & Dependency Management

## Problem

The `labelle-engine` declares `labelle-core` as a relative path dependency (`../labelle-core`) in its `build.zig.zon`. When the engine is consumed as a remote git dependency, Zig caches it under `~/.cache/zig/p/` and the relative path resolves outside the package, causing a build failure:

```
error: dependency path outside project: '/Users/.../.cache/zig/p/labelle-core'
```

Additionally, the current CLI installation requires `sudo` and manual `mv` to update, which is a poor experience.

Related issue: https://github.com/labelle-toolkit/labelle-engine/issues/367

## Proposal

Use a user-space managed directory for the CLI installation and its dependencies, so that:

1. `labelle-core` is downloaded alongside the CLI in a known, stable location
2. The engine's dependency path can resolve correctly
3. CLI updates don't require `sudo` or manual file moves

## Managed Directory Structure

### macOS / Linux

```
~/.labelle/
├── bin/
│   └── labelle            # CLI binary
├── packages/
│   ├── labelle-core/      # core library
│   └── labelle-engine/    # engine (if needed)
└── cache/                 # optional: CLI-managed cache
```

### Windows

Uses `%LOCALAPPDATA%\labelle\` (non-roaming, machine-local data — avoids syncing large binaries across devices).

```
%LOCALAPPDATA%\labelle\
├── bin\
│   └── labelle.exe
├── packages\
│   ├── labelle-core\
│   └── labelle-engine\
└── cache\
```

PATH is updated via the Windows registry (`HKCU\Environment\Path`) so it persists across sessions without requiring admin privileges.

## How It Works

1. **Installation**: The CLI installer places the binary in `~/.labelle/bin/` and automatically adds it to PATH on first install:
   - **zsh**: appends `export PATH="$HOME/.labelle/bin:$PATH"` to `~/.zshrc`
   - **bash**: appends to `~/.bashrc`. On macOS, if `~/.bash_profile` exists but `~/.bashrc` doesn't, appends to `~/.bash_profile` instead (since macOS bash reads `~/.bash_profile` for login shells by default)
   - **fish**: runs `fish_add_path ~/.labelle/bin`
   - **Windows**: adds to `HKCU\Environment\Path` via registry

   The installer detects the current shell and only modifies the relevant profile. It checks if the PATH entry already exists before appending to avoid duplicates.

2. **First run / update**: The CLI downloads the matching `labelle-core` version into `~/.labelle/packages/labelle-core/`.

3. **Build resolution**: The engine's `build.zig.zon` references `labelle-core` at the known managed path instead of a sibling relative path.

4. **CLI updates**: The CLI can self-update by replacing the binary in `~/.labelle/bin/` — no `sudo` required since it's in user space.

## Version Resolution

Each engine version declares a default `labelle-core` version it's compatible with. However, projects can override this by specifying a different core version in their `project.labelle` configuration.

The resolution order is:

```
1. project.labelle core version override (if set)  →  use that
2. engine's declared core version (default)         →  use that
```

The engine declares its default core version in its `versions.zon` file, which is included in each tagged release (e.g. `v0.52.38`). This file maps dependency names to their compatible versions. The CLI fetches the engine's `versions.zon` from the matching git tag to determine which core version to use.

On `labelle run` or `labelle update`, the CLI:
1. Reads the project's `project.labelle` to check for a core version override
2. If no override, falls back to the engine's release metadata for the default core version
3. Downloads/updates the resolved `labelle-core` version in `~/.labelle/packages/`

If the requested core version is not found (invalid tag, network error, or removed release), the CLI **fails with a clear error** rather than silently falling back — this prevents builds with mismatched versions:

```
error: labelle-core v0.55.0 not found. Check that the version exists or remove the override from project.labelle.
```

Multiple core versions can coexist under `~/.labelle/packages/`:

```
~/.labelle/packages/
├── labelle-core/
│   ├── v0.50.0/
│   ├── v0.52.0/
│   └── v0.53.1/
```

This lets different projects use different core versions without conflicts.

Old core versions are retained until explicitly pruned with `labelle clean`. This avoids breaking other projects that may still reference them.

### `labelle clean`

Removes unused package versions from `~/.labelle/packages/`. Behavior:

- Always keeps versions matching the current CLI's defaults (core, engine, gfx, cli)
- Scans `project.labelle` in the current directory (or a directory specified with `--project=<dir>`) for additional referenced versions to keep
- Deletes any versions not referenced by the CLI defaults or the scanned project
- Prints a summary of what was removed
- Supports `--dry-run` to preview without deleting

## Compatibility & Migration

For users with existing installations (e.g. binary in `/usr/local/bin/`):

1. **Detection**: On first run, the new CLI checks if an old binary exists in common system paths (`/usr/local/bin/labelle`, `/usr/bin/labelle`).
2. **Warning**: If found, the CLI prints a warning with removal instructions:
   ```
   Found old labelle binary at /usr/local/bin/labelle.
   Remove it with: sudo rm /usr/local/bin/labelle
   The CLI now runs from ~/.labelle/bin/labelle.
   ```
3. **PATH precedence**: The installer prepends `~/.labelle/bin` to PATH so the user-space binary takes priority even if the old one isn't removed immediately.

## Recommended Approach for Build Resolution

Of the options considered, **the CLI rewrites the dependency path at generation time** is the recommended approach:

- During `labelle run`, the CLI already runs a generator that produces project files in the `.labelle/` directory, under per-target subdirectories (e.g. `.labelle/raylib_desktop/`, `.labelle/raylib_wasm/`). These generated files are ephemeral and gitignored — they are not committed to the repository.
- The generator sets `labelle-core`'s path to the versioned managed location (e.g. `~/.labelle/packages/labelle-core/v0.52.0/`) in the generated output.
- This avoids symlinks (which behave differently on Windows) and environment variables (which add setup burden).
- The engine's source `build.zig.zon` keeps its relative `../labelle-core` path for monorepo development — only the generated version used by consumers gets the rewritten path.

## Future Work

- **Download verification**: Add checksum or signature verification for downloaded binaries to prevent tampering. The release server could publish SHA256 checksums alongside binaries.
- **Modular update command**: Extract `cmdUpdate` into a dedicated module with testable helpers for download, PATH setup, and migration detection.

## Open Questions

- Install script format: shell script for macOS/Linux, MSI or PowerShell for Windows?
