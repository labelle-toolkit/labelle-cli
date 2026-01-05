# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build the CLI
zig build

# Run the CLI directly
zig build run -- <command>

# Run tests
zig build test

# Build for release
zig build -Doptimize=ReleaseSafe
```

## Architecture

labelle-cli is a thin bootstrap CLI that manages [labelle-engine](https://github.com/labelle-toolkit/labelle-engine) projects. It fetches the correct engine version from GitHub releases and delegates to the engine's generator.

### Source Files (src/)

- **main.zig** - CLI entry point, argument parsing, command dispatch
- **engine_resolver.zig** - Version resolution, GitHub API integration, bootstrap mechanism
- **project_config.zig** - Reads `project.labelle` configuration files

### Key Concepts

**Version Resolution:**
- `"latest"` → Fetches from GitHub releases API
- `"0.33.0"` → Validates against available releases
- All versions validated before use to provide helpful error messages

**Bootstrap Mechanism:**

The CLI doesn't embed the engine. Instead, it creates a temporary `.labelle-bootstrap/` directory with:
1. A `build.zig.zon` that depends on the specific engine version
2. A `build.zig` that extracts and runs the engine's `labelle-generate` executable

This ensures projects always use their pinned engine version.

### Commands

| Command | Description |
|---------|-------------|
| `init <name>` | Create new project with `project.labelle`, scenes/, prefabs/, etc. |
| `generate` | Run engine's generator based on project's engine_version |
| `build` | Generate + run `zig build` in output directory |
| `run` | Generate + run `zig build run` in output directory |
| `update` | Clear `.labelle/` cache and regenerate |
| `upgrade` | Check/upgrade engine version |

### Options

```bash
--engine=VER     # Override engine version
--release, -r    # Build in release mode
--list, -l       # List available versions (upgrade command)
--check          # Check for updates without upgrading (upgrade command)
--version=VER    # Upgrade to specific version (upgrade command)
```

### Project Structure Created by `init`

```
my-game/
├── project.labelle      # Project configuration with engine_version
├── scenes/
│   └── main.zon         # Initial scene
├── prefabs/             # Prefab definitions
├── components/          # Custom components
├── scripts/             # Game scripts
├── hooks/               # Engine lifecycle hooks
└── resources/           # Assets
```

### Generated Files (by engine's generator)

```
my-game/
├── main.zig             # Entry point (stays in root for imports)
└── .labelle/
    ├── build.zig        # Build configuration
    └── build.zig.zon    # Dependencies
```

### Dependencies

- **zts** - Template engine used by the engine's generator

### Important Patterns

- Uses `std.ArrayListUnmanaged` (Zig 0.15+ API) instead of `std.ArrayList.init()`
- GitHub API responses are parsed manually (simple string search) to avoid JSON dependency
- Cache directory: `~/.cache/labelle-cli/engines/`
- Bootstrap directory: `.labelle-bootstrap/` (temporary, can be deleted)

### GitHub API Integration

The CLI fetches version info from:
- Latest release: `https://api.github.com/repos/labelle-toolkit/labelle-engine/releases/latest`
- All releases: `https://api.github.com/repos/labelle-toolkit/labelle-engine/releases`

Uses `curl` for HTTP requests to avoid adding HTTP client dependencies.

### Error Handling

When a version is not found, the CLI:
1. Validates against available releases
2. Shows error with the invalid version
3. Lists up to 10 available versions as suggestions

## Related Projects

- [labelle-engine](https://github.com/labelle-toolkit/labelle-engine) - The 2D game engine
- [labelle-gfx](https://github.com/labelle-toolkit/labelle-gfx) - Graphics abstraction layer
