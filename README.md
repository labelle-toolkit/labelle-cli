<p align="center">
  <img src="https://raw.githubusercontent.com/labelle-toolkit/labelle-gfx/main/banner.png" alt="Labelle" width="600">
</p>

<h1 align="center">labelle-cli</h1>

<p align="center">
  <strong>Command-line interface for labelle-engine projects</strong>
</p>

<p align="center">
  <a href="https://github.com/labelle-toolkit/labelle-cli/actions"><img src="https://github.com/labelle-toolkit/labelle-cli/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/labelle-toolkit/labelle-cli/releases"><img src="https://img.shields.io/github/v/release/labelle-toolkit/labelle-cli" alt="Release"></a>
  <a href="https://github.com/labelle-toolkit/labelle-cli/blob/main/LICENSE"><img src="https://img.shields.io/github/license/labelle-toolkit/labelle-cli" alt="License"></a>
</p>

---

A standalone CLI tool that manages [labelle-engine](https://github.com/labelle-toolkit/labelle-engine) projects. It automatically fetches the correct engine version and runs the generator, ensuring your project stays compatible with its specified engine version.

## Features

- **Version Management** - Fetches engine versions from GitHub releases
- **Project Generation** - Delegates to the engine's generator for build file creation
- **Version Pinning** - Projects specify their engine version in `project.labelle`
- **Cross-Platform** - Pre-built binaries for Linux, macOS, and Windows

## Installation

### From Releases

Download the latest binary for your platform from [Releases](https://github.com/labelle-toolkit/labelle-cli/releases).

```bash
# Linux/macOS
tar -xzf labelle-linux-x86_64.tar.gz
sudo mv labelle /usr/local/bin/

# Verify installation
labelle version
```

### From Source

Requires [Zig 0.15.2+](https://ziglang.org/download/)

```bash
git clone https://github.com/labelle-toolkit/labelle-cli.git
cd labelle-cli
zig build -Doptimize=ReleaseSafe
sudo mv zig-out/bin/labelle /usr/local/bin/
```

## Quick Start

```bash
# Create a new project
labelle init my-game

# Navigate to project
cd my-game

# Generate build files
labelle generate

# Build and run
labelle run
```

## Commands

| Command | Description |
|---------|-------------|
| `labelle init <name>` | Create a new labelle project |
| `labelle generate` | Generate project files from `project.labelle` |
| `labelle build` | Build the project |
| `labelle run` | Build and run the project |
| `labelle update` | Clear caches and regenerate |
| `labelle upgrade` | Upgrade to a newer engine version |
| `labelle help` | Show help information |
| `labelle version` | Show CLI version |

## Version Management

### List Available Versions

```bash
labelle upgrade --list
```

```
Available labelle-engine versions:
  0.33.0
  0.32.0
  0.31.0
  ...
```

### Check for Updates

```bash
labelle upgrade --check
```

```
Current: 0.32.0
Latest:  0.33.0

Run 'labelle upgrade' to upgrade.
```

### Pin Engine Version

Specify the engine version in your `project.labelle`:

```zig
.{
    .version = 1,
    .name = "my-game",
    .engine_version = "0.33.0",
    .initial_scene = "main",
    // ...
}
```

The CLI will fetch and use the generator from that specific version.

## Project Structure

When you run `labelle init`, the following structure is created:

```
my-game/
├── project.labelle      # Project configuration
├── scenes/
│   └── main.zon         # Initial scene
├── prefabs/             # Prefab definitions
├── components/          # Custom components
├── scripts/             # Game scripts
├── hooks/               # Engine lifecycle hooks
└── resources/           # Assets (images, sounds, etc.)
```

After running `labelle generate`:

```
my-game/
├── ...
├── main.zig             # Generated entry point
└── .labelle/
    ├── build.zig        # Generated build configuration
    └── build.zig.zon    # Generated dependencies
```

## How It Works

1. **Read Configuration** - CLI reads `engine_version` from `project.labelle`
2. **Fetch Engine** - Downloads the specified engine version from GitHub
3. **Run Generator** - Executes the engine's generator to create build files
4. **Build Project** - Uses the generated `build.zig` to compile your game

This ensures that:
- Different projects can use different engine versions
- Builds are reproducible across machines
- Upgrading is explicit and controlled

## Related Projects

- [labelle-engine](https://github.com/labelle-toolkit/labelle-engine) - 2D game engine for Zig
- [labelle-gfx](https://github.com/labelle-toolkit/labelle-gfx) - Graphics abstraction layer
- [labelle-tasks](https://github.com/labelle-toolkit/labelle-tasks) - Task orchestration plugin

## License

MIT License - see [LICENSE](LICENSE) for details.
