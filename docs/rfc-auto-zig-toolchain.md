# RFC: Auto-Download and Manage the Zig Toolchain

Tracking issue: #106

## Status

Draft — open for discussion.

---

## Background

Today, using `labelle` requires two separate installs:

1. The `labelle` CLI binary
2. The Zig compiler (correct version, correct platform)

This is friction. The user must find the right Zig version (currently 0.15.2),
download the tarball for their OS and architecture, extract it, and add it to
PATH. If the pinned version changes with a labelle update, they must repeat
the process.

Zig is uniquely suited for automatic management because it is a **single
static binary with zero system dependencies** — no runtime, no libc
requirement, no installer. It's a ~45MB download that works immediately
after extraction.

---

## Proposal

The `labelle` CLI should automatically download, cache, and use the correct
Zig version. The user installs one binary (`labelle`) and everything else
is handled transparently.

```
$ labelle run
labelle: Zig 0.15.2 not found, downloading...
  downloading zig-aarch64-macos-0.15.2.tar.xz (45 MB)...
  cached at ~/.labelle/zig/0.15.2/zig
labelle: generating 'flying-platform'...
labelle: building...
labelle: running...
```

On subsequent runs, the cached Zig is used instantly — no download, no check.

---

## How it works

### 1. Zig version pinning

The CLI already knows the required Zig version — it's the version used to
build and test the CLI itself. This version is embedded in the CLI binary
at compile time (via `build.zig` or a version constant).

```zig
// Embedded in the CLI binary
const required_zig_version = "0.15.2";
```

### 2. Zig resolution order

When the CLI needs to invoke `zig`, it checks in order:

1. **`~/.labelle/zig/<version>/zig`** — managed cache (preferred)
2. **`zig` on PATH** — user-installed Zig (fallback)

If neither is found, the CLI downloads Zig to the cache directory.

If the user has Zig on PATH but it's the **wrong version**, the CLI warns
and uses the managed version instead:

```
labelle: system zig is 0.14.0, need 0.15.2 — using managed toolchain
```

This avoids subtle version mismatch bugs while still respecting a user's
explicit Zig installation if it matches.

### 3. Download and cache

The CLI downloads Zig from the official release mirror:

```
https://ziglang.org/download/0.15.2/zig-<arch>-<os>-0.15.2.tar.xz
```

Platform mapping:

| `@import("builtin")` | Zig download name |
|---|---|
| `aarch64-macos` | `zig-aarch64-macos-0.15.2.tar.xz` |
| `x86_64-macos` | `zig-x86_64-macos-0.15.2.tar.xz` |
| `x86_64-linux` | `zig-x86_64-linux-0.15.2.tar.xz` |
| `aarch64-linux` | `zig-aarch64-linux-0.15.2.tar.xz` |
| `x86_64-windows` | `zig-x86_64-windows-0.15.2.zip` |

Cache directory structure:

```
~/.labelle/
  zig/
    0.15.2/
      zig           ← the binary
      lib/          ← Zig standard library
      doc/          ← (optional, can be skipped)
```

The download is a one-time cost per version. When labelle updates and pins
a new Zig version, the next run downloads it automatically. Old versions
can be cleaned up with `labelle clean --zig-cache`.

### 4. Invocation change

Currently, `runner.zig` invokes Zig as a bare command:

```zig
// Current — expects "zig" on PATH
const result = try runner.runZig(allocator, target_dir, &.{ "zig", "build" });
```

After this change, the runner resolves the Zig binary path first:

```zig
// New — resolves managed or system Zig
const zig_path = try toolchain.resolveZig(allocator);
const result = try runner.runZig(allocator, target_dir, &.{ zig_path, "build" });
```

The `toolchain` module handles resolution, download, and caching.

---

## Implementation

### New module: `src/cli/toolchain.zig`

```zig
pub fn resolveZig(allocator: Allocator) ![]const u8 {
    // 1. Check managed cache
    if (getManagedZigPath(allocator)) |path| {
        if (fileExists(path)) return path;
    }

    // 2. Check system PATH
    if (findZigOnPath(allocator)) |sys_zig| {
        if (checkVersion(sys_zig, required_zig_version)) return sys_zig;
        warn("system zig is wrong version, downloading managed toolchain");
    }

    // 3. Download to cache
    return downloadAndCache(allocator, required_zig_version);
}
```

### Download implementation

The CLI is a Zig binary, so it has access to `std.http.Client` for
downloading. The flow:

1. Build the download URL from the platform and version
2. HTTP GET with progress reporting to stderr
3. Extract `.tar.xz` (Unix) or `.zip` (Windows) to `~/.labelle/zig/<version>/`
4. Verify the binary runs: `zig version` → check output matches
5. Return the path

For `.tar.xz` extraction on Unix, the CLI can shell out to `tar` (universally
available) or use Zig's `std.compress.xz` and `std.tar`:

```zig
// Option A: shell out (simple, reliable)
try runCommand(&.{ "tar", "xJf", tarball_path, "-C", cache_dir });

// Option B: pure Zig (no external dependency)
var xz_stream = try std.compress.xz.decompress(allocator, file_reader);
try std.tar.pipeToFileSystem(cache_dir, xz_stream, .{});
```

Option B is preferred — it avoids a system dependency and works on Windows
where `tar` may not support `.xz`.

### `labelle` subcommands

New subcommands for toolchain management:

```
labelle zig version       Print the managed Zig version
labelle zig path          Print the path to the managed Zig binary
labelle zig download      Force download (e.g., for CI pre-warming)
labelle clean --zig-cache  Remove old Zig versions from cache
```

These are optional power-user commands. Normal usage never needs them.

---

## What changes in `runner.zig`

The change is minimal. Every place that currently passes `"zig"` as argv[0]
gets replaced with the resolved path:

```zig
// Before
pub fn runZig(allocator: Allocator, cwd: []const u8, argv: []const []const u8) !RunResult {
    return std.process.Child.run(.{ .allocator = allocator, .argv = argv, .cwd = cwd });
}

// After — zig_path resolved once at CLI startup, threaded through
pub fn runZig(allocator: Allocator, cwd: []const u8, zig_path: []const u8, args: []const []const u8) !RunResult {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(zig_path);
    try argv.appendSlice(args);  // "build", "run", etc.
    return std.process.Child.run(.{ .allocator = allocator, .argv = argv.items, .cwd = cwd });
}
```

---

## Offline and CI considerations

### Offline use

If the user is offline and Zig is not cached, the CLI fails with a clear
message:

```
labelle: Zig 0.15.2 not found and download failed (no network)
  install Zig manually: https://ziglang.org/download/
  or run `labelle zig download` while online
```

### CI environments

CI already has Zig installed via `mlugg/setup-zig@v2`. The CLI detects it
on PATH and uses it — no download needed. The managed toolchain is a
convenience for local development, not a requirement.

For CI that wants to use the managed toolchain instead:

```yaml
- name: Pre-warm Zig cache
  run: labelle zig download
```

### Respecting user choice

If the user explicitly sets `LABELLE_ZIG_PATH` or adds an entry to
`~/.labelle/config.json`, the CLI uses that path unconditionally — no
version check, no download. This is an escape hatch for users who need
a custom Zig build (e.g., debug builds, forks, nightly).

```json
// ~/.labelle/config.json
{
  "zig_path": "/opt/zig-custom/zig"
}
```

---

## Disk space

| Component | Size (compressed) | Size (extracted) |
|---|---|---|
| Zig binary + stdlib | ~45 MB | ~200 MB |
| labelle CLI | ~5 MB | ~5 MB |

Total: ~205 MB for a complete, zero-dependency game development environment.
For comparison, Unity is ~10 GB, Godot is ~100 MB (but needs separate
export templates), and Rust toolchain is ~500 MB.

Old Zig versions can be pruned with `labelle clean --zig-cache`. The CLI
could also auto-prune versions older than the current pin after a
successful download.

---

## Scope

### In scope

- Auto-download Zig to `~/.labelle/zig/<version>/`
- Version pinning embedded in CLI binary
- Resolution order: managed cache → system PATH → download
- Version mismatch warning
- `labelle zig` subcommands for toolchain management
- Pure Zig `.tar.xz` / `.zip` extraction (no system dependency)
- `LABELLE_ZIG_PATH` override

### Out of scope

- Managing system library dependencies (libgl, libx11, etc.) — these are
  OS-level packages needed by raylib/sokol and can't be bundled easily.
  Linux users still need `apt-get install` for these. macOS and Windows
  have them built-in.
- Emscripten SDK management — could be a follow-up RFC using the same
  pattern
- Multiple Zig versions simultaneously — only the pinned version is managed

---

## Open questions

1. Should the CLI auto-download without asking, or prompt first?
   Auto-download is smoother for new users. A `--no-auto-download` flag
   or config option could satisfy users who want explicit control.
2. Should the download URL be configurable (for corporate proxies or
   mirrors)? A `LABELLE_ZIG_MIRROR` env var would handle this.
3. Should we also manage the Emscripten SDK the same way for WASM builds?
   Emscripten is more complex (Python dependency, multiple binaries), but
   the same cache-and-resolve pattern could work.
4. Should `labelle init` trigger the download, or only `labelle run` /
   `labelle build`? Downloading at init time means the first build is
   fast, but init would become a network operation.
