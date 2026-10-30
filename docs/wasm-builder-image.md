# WASM builder image

A versioned Docker image in which the ordinary `labelle` pipeline builds,
bundles and smoke-tests a game for `--platform=wasm`, as a non-root user, with
no host toolchain (labelle-cli#529, epic #528 work package 1). It is meant for
CI: GitHub Actions (`docker run`) and GitLab runners with a Docker
executor.

| | |
|---|---|
| Source | [`docker/wasm-builder/`](../docker/wasm-builder/): `Dockerfile`, `versions.env` (every pin, per architecture), `web-smoke-requirements.lock`, `lib/pins.sh` (build helper), `bin/` (the helper scripts baked into the image), `e2e/` (end-to-end fixture), `gitlab-ci.example.yml` |
| Build, test, publish | [`.github/workflows/wasm-builder-image.yml`](../.github/workflows/wasm-builder-image.yml): tests on pull requests; publishes on a `wasm-builder-v<version>` tag or a manual dispatch |
| Image | `ghcr.io/labelle-toolkit/labelle-wasm-builder:<cli version>-<revision>`, a **public** GHCR package ([Publishing](#publishing)) |
| Platforms | `linux/amd64` and `linux/arm64`, one multi-arch tag. Android (SDK/NDK) is out of scope: a separate future variant (cli#331). |

Contents:

- [What is in the image](#what-is-in-the-image), [arm64](#arm64)
- [Relationship to `--docker`](#relationship-to---docker)
- [Image and toolkit compatibility](#image-and-toolkit-compatibility)
- [Caches](#caches): layout, mounts, ownership and UID, cache keys and invalidation, concurrency, pruning
- [GitHub Actions](#github-actions), [GitLab Docker executor](#gitlab-docker-executor)
- [Resources](#resources)
- [Publishing](#publishing), [Upgrading](#upgrading), [Rolling back](#rolling-back)
- [Validation status](#validation-status)

## What is in the image

Every version and checksum lives in
[`docker/wasm-builder/versions.env`](../docker/wasm-builder/versions.env),
per architecture where the artifact differs (`_amd64` / `_arm64`, picked by
Docker's `TARGETARCH`). The Dockerfile sources it and verifies **every
download** against it before use; each checksum was recomputed from a
download of the published file when it was pinned. The image carries a copy
(`/opt/labelle/versions.env`) and a **toolchain inventory** measured from the
installed tools at build time, `/opt/labelle/toolchain-inventory.json`
(`labelle-builder-check --inventory` prints it; CI puts it in the run
summary).

| Component | Version (image 4.1.2-2) | Where it comes from | Verified by | In the image |
|---|---|---|---|---|
| Base | `ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852` | Docker Hub multi-platform index digest for `24.04`, resolved 2026-10-30 | digest | `FROM` |
| Ubuntu packages | snapshot `20261030T000000Z`; top level pinned (`APT_PACKAGES`): `ca-certificates`, `curl`, `git`, `xz-utils`, `bzip2`, `unzip`, `python3`, `python3-venv`, `libatomic1` | `snapshot.ubuntu.com` (noble, -updates, -security; main + universe) | apt's archive signatures + a fixed snapshot (the first apt run skips TLS verification, as the base has no CA bundle; integrity rests on the signed indices) | apt |
| labelle CLI | 4.1.2 (`labelle-linux-x86_64` / `labelle-linux-arm64`) | FP's `labelle.lock` `.cli_version` and `tools/ci/ensure-tool.sh` (amd64 checksum); `releases.labelle.games` | sha256 per arch | `/usr/local/bin/labelle` |
| Zig | 0.16.0 (`x86_64` / `aarch64`) | the CLI's `DEFAULT_ZIG_VERSION`; FP's `ensure-tool.sh`; `ziglang.org/download/index.json` | sha256 per arch | `/opt/zig`, `LABELLE_ZIG=/opt/zig/zig` |
| labelle-assembler | 0.124.0 (`linux-x86_64` / `linux-aarch64`) | FP's `project.labelle` `.assembler_version`; the release's `SHA256SUMS` | sha256 per arch | a **seed** at `/opt/labelle/seed/assembler/0.124.0/` ([below](#image-and-toolkit-compatibility)) |
| emsdk | 4.0.9, commit `3bcf1dcd01f0…` | labelle-web 0.4.0's default `emsdk.version` and pinned tag commit (`src/provider/emsdk.zig`) | git commit | `/opt/emsdk`, activated, `EMSDK=/opt/emsdk` |
| Emscripten / LLVM / binaryen | emscripten-releases build `cb2a69bc…` (`wasm-binaries.tar.xz` / `wasm-binaries-arm64.tar.xz`) | emsdk 4.0.9's `emscripten-releases-tags.json` | sha256 per arch, fetched before `emsdk install`, which must then download nothing else | `/opt/emsdk/upstream` |
| Node | 20.18.0 (`linux-x64` / `linux-arm64`) | bundled by emsdk 4.0.9 (its manifest) | sha256 per arch, equal to nodejs.org's `SHASUMS256.txt` | `/opt/emsdk/node/20.18.0_64bit/bin`, on `PATH` |
| Python | 3.12.3 (`python3` from the snapshot) | what emsdk/emcc and FP's smoke run with | apt | `/usr/bin/python3` |
| Playwright + Pillow | 1.64.1 + 11.3.0, with pyee 14.0.0, greenlet 3.5.6, typing-extensions 4.16.0 | FP's `tools/web_smoke/requirements.txt` | `pip --require-hashes` ([`web-smoke-requirements.lock`](../docker/wasm-builder/web-smoke-requirements.lock), both architectures' wheels) | venv `/opt/labelle/web-smoke-venv` (`LABELLE_WEB_SMOKE_VENV`) |
| Chromium | Playwright 1.64.1's Chrome for Testing **headless shell** 156.0.8078.4 (revision 1248) + ffmpeg 1013, with their system libraries (`--with-deps`, from the snapshot) | `cdn.playwright.dev` (`linux64` / `linux-arm64` builds) | sha256 per arch; served to `playwright install --only-shell chromium` from a local mirror, so it installs exactly those bytes | `/opt/ms-playwright` (`PLAYWRIGHT_BROWSERS_PATH`) |

Only the headless shell is installed (`--only-shell`):
`chromium.launch(headless=True)` uses it, as FP's smoke does. A job that runs
`playwright install chromium` itself would try to add the full browser to the
read-only `/opt/ms-playwright`; use `labelle-builder-smoke-python` instead.

Helpers on `PATH`:

- `labelle-builder-check`: the job preflight ([compatibility](#image-and-toolkit-compatibility), [caches](#caches)); `--self-test` checks the image alone; `--inventory` prints the inventory.
- `labelle-builder-smoke-python <requirements.txt>`: prints the Python to run a Playwright smoke with ([GitLab](#gitlab-docker-executor)).
- `labelle-builder-inventory`: regenerates the inventory from the installed tools.

The image holds **no credentials and no game source**: nothing outside
`docker/wasm-builder/` is copied in (and of that only `versions.env`, the pip
lock, `lib/` and `bin/`), no tokens go into build arguments, and every
toolchain is checked against a recorded checksum, commit or signed apt
snapshot. Toolchains (`/opt`, `/usr/local/bin`) are root-owned and read-only
to the build user, so a job cannot modify the compiler a later job runs.

### arm64

Every upstream publishes linux arm64 artifacts for the pinned versions, so
arm64 is a first-class variant: built natively on GitHub's `ubuntu-24.04-arm`
runners (no QEMU) and published in the same multi-arch tag. It is on by
default; a manual dispatch can leave it out (`arm64: false`), and amd64 never
depends on it. Checked when pinning (2026-10-30):

| Toolchain | arm64 artifact | Note |
|---|---|---|
| labelle CLI 4.1.2 | `labelle-linux-arm64` | the CLI release publishes **no checksum file**; the pin is the sha256 of the downloaded file (the amd64 pin also matches FP's `ensure-tool.sh`) |
| labelle-assembler 0.124.0 | `labelle-assembler-linux-aarch64` | listed in the release's `SHA256SUMS` |
| Zig 0.16.0 | `zig-aarch64-linux-0.16.0.tar.xz` | listed in `ziglang.org/download/index.json` |
| Emscripten 4.0.9 | `wasm-binaries-arm64.tar.xz` (linux) | emsdk's manifest has a linux `arm64` releases tool; the emsdk tree itself is arch-neutral |
| Node 20.18.0 | `node-v20.18.0-linux-arm64.tar.xz` | matches nodejs.org |
| Chromium headless shell 156.0.8078.4 | `linux-arm64/chrome-headless-shell-linux-arm64.zip` | Playwright 1.64.1 maps `ubuntu24.04-arm64` to Chrome for Testing |
| Ubuntu packages | same versions as amd64 in the snapshot | |

Not established on arm64: H.264 playback in its headless shell (FP's intro
clip) and anything FP-specific. The CI end-to-end check covers a template
project, both builds and both smokes, on both architectures.

## Relationship to `--docker`

There is still exactly one way the CLI itself uses a container:
`labelle build --docker`. It is unchanged: it builds the core `desktop` target
only, in a throwaway `ubuntu:24.04` container that downloads Zig 0.16.0 at run
time and runs as root, and it refuses provider targets
([migrating-to-3.0.md](migrating-to-3.0.md#--docker),
`pipeline/args_resolve.zig:dockerRefused`), because a provider's hooks and
toolchain run on the host.

The builder image is **not** a second container build path. Nothing in the CLI
starts it. It is an environment in which the *whole, native* `labelle`
pipeline runs (provider hooks included), exactly as it does on a developer
machine or FP's shell runner; CI chooses it with `image:`. So the provider
contract is untouched: the web provider's hooks run where the build runs, and
`--docker` stays refused for `wasm` inside the image too (there is no reason
to nest it).

Proposed follow-up (not in this change): make `--docker` reuse this image
instead of `ubuntu:24.04` + a run-time Zig download. The image already pins
Zig and runs non-root, so `--docker` would gain a pinned toolchain, a host-UID
run (`--user`) instead of root-owned output, and the same `/cache` layout
(`LABELLE_HOME` mounted instead of only the Zig cache). A further step would
run the CLI itself in the container (rather than `zig build` only), which is
what lifting the provider-target refusal would require. Both change `--docker`
behaviour and belong to their own issue.

## Image and toolkit compatibility

One image version carries one labelle CLI. The image version is
`<CLI version>-<image revision>` (`4.1.2-2`): the revision counts image-only
changes (base digest, Playwright, emsdk, Zig, scripts) for the same CLI.

Pins the project owns are respected, and a mismatch fails before any fetch
(`labelle-builder-check`, run first in the job):

| Project pin | Image behaviour | On mismatch |
|---|---|---|
| `labelle.lock` `.cli_version` | the image's CLI must be that version | **fails**: use the image built for that CLI |
| `project.labelle` `.zig_version` (when set) | `LABELLE_ZIG` would override the CLI's own resolution, so it is checked here | **fails** |
| web provider `emsdk.version` (settings file named by `project.labelle` `.provider_config`, else labelle-web's default) | the provider's default `managed` source passes the image's activated `EMSDK` through **without comparing versions**, so it is checked here | **fails**; either use a matching image, or run the build with `EMSDK` unset (`env -u EMSDK labelle bundle …`): the provider then installs the requested emsdk into the cache itself |
| `emsdk.source` `root` / `package` | the image's `EMSDK` is not used | warning only |
| `labelle.lock` web provider version | the image was checked against labelle-web `LABELLE_WEB_VERSIONS` (0.4.0) | warning: a newer labelle-web may have a different default emsdk |
| `project.labelle` `.assembler_version` | always resolved by the CLI from the project; when it equals the image's seed (0.124.0) and the cache has none, the verified seed is copied into `$LABELLE_HOME/assembler/0.124.0/` so the CLI does not download it | none: any other version is downloaded and verified against its release `SHA256SUMS` by the CLI, into the cache |
| packages, plugins, providers in `labelle.lock` | resolved by the CLI as on any host (pinned, hash-verified), into the cache | n/a |

`LABELLE_BUILDER_ALLOW_PIN_MISMATCH=1` downgrades the failures to warnings,
for deliberate experiments only.

When a project bumps `labelle.lock`'s CLI, it bumps the image reference in the
same change (see [Upgrading](#upgrading)); a toolkit CLI release is followed
by an image release (`<new cli>-1`).

## Caches

Toolchains are in the image; **everything written while building lives under
`/cache`**, which CI mounts from a persistent volume. Game bundles and test
reports are job artifacts, not cache.

### Layout

The image sets these, all under one cache key `<key>`
(`LABELLE_BUILDER_CACHE_KEY`, [below](#cache-keys-and-invalidation)):

| Path | Variable | Holds |
|---|---|---|
| `/cache/<key>/labelle/` | `LABELLE_HOME` | the CLI's whole cache tree |
| `…/labelle/zig-global-cache/` | `ZIG_GLOBAL_CACHE_DIR` (the CLI sets it from `LABELLE_HOME`) | Zig global cache: fetched Zig packages, compiled C/C++ libraries (bgfx…) |
| `…/labelle/zig-local-cache/` | `ZIG_LOCAL_CACHE_DIR` (likewise) | Zig local cache: compiled game/engine objects |
| `…/labelle/packages/` | | labelle package cache (the assembler's `labelle install` tree) |
| `…/labelle/providers/` | | provider archives, built provider binaries, and each provider's `cache_dir` |
| `…/labelle/assembler/<v>/` | | the assembler binary (seeded or downloaded) |
| `/cache/<key>/emscripten/` | `EM_CACHE` | Emscripten's cache: the sysroot and system libraries built on first use (per flag set: pthreads or not, …) |
| `/cache/<key>/xdg/` | `XDG_CACHE_HOME` | pip's cache and, only when a project's smoke requirements differ from the image's, a keyed smoke venv and its browser |

Because the CLI derives `ZIG_GLOBAL_CACHE_DIR`/`ZIG_LOCAL_CACHE_DIR` from
`LABELLE_HOME`, mounting one volume at `/cache` covers every cache. Separate
volumes are possible by mounting at the subpaths above (for example a
dedicated, larger volume at `/cache/<key>/labelle/zig-local-cache`), but one
volume is simpler and is what the examples use. The project's own `.labelle/`
(generated targets, `zig-out`) is in the job's workspace: rebuilt each job
from the warm caches (about 4 s warm generation in the epic's measurements).

The provider-managed emsdk (`providers/<id>/emsdk/…`, ~1 GB) is **not**
written in the normal case: the image's `/opt/emsdk` is passed through. It
appears only when a project runs with `EMSDK` unset to get another emsdk.

### Mounts, ownership and UID

The build user is `builder`, **UID/GID 10001** (clear of the base image's
`ubuntu` user, 1000; the `BUILDER_UID`/`BUILDER_GID` build arguments change it
for a custom build). `/cache` and `/work` are owned by it in the image.

- **Named volume** (recommended): a new, empty named volume mounted at
  `/cache` copies the image's ownership on first use, so the non-root user can
  write it with no setup. The publish workflow tests exactly this.
- **Host bind mount**: the host directory must be writable by UID 10001:
  `sudo install -d -o 10001 -g 10001 /srv/labelle-cache`. It must be a
  **Linux filesystem**. On Docker Desktop for Windows (and likely macOS) a
  bind mount of a host drive (`-v D:/cache:/cache`) breaks Zig: it renames
  finished compilation directories into its cache, and that rename fails
  (`failed to rename compilation results … into local cache …: AccessDenied`,
  seen in the web provider's `toolchain` hook). Use a named volume. To keep
  the bytes on another drive, put an ext4 image file there and loop-mount it
  at `/cache`; that needs `--privileged` and a root entrypoint that drops to
  10001 (see the local FP test on labelle-cli#530). The checkout itself can
  be a Windows bind mount.
- **A volume created by another image or as root**: fix it once with
  `docker run --rm -u 0 -v <volume>:/cache <image> chown -R 10001:10001 /cache`.
  `labelle-builder-check` detects an unwritable cache and prints this command.
- **Running as another UID** (`docker run --user`): works when the cache is
  writable by that UID; `HOME` (`/home/builder`) is then not writable, which
  nothing in the pipeline needs, since every cache variable points at `/cache`.

The GitLab Docker executor clones the repository into the build directory
with a permissive umask by default (`FF_DISABLE_UMASK_FOR_DOCKER_EXECUTOR`
unset), so a non-root image can write the checkout. With that flag set the
runner `chown`s the checkout to the image's user instead; either works.

### Cache keys and invalidation

**Key.** `LABELLE_BUILDER_CACHE_KEY` is
`v1-<arch>-<os>-zig<version>-emsdk<version>`, today
`v1-amd64-linux-zig0.16.0-emsdk4.0.9` and
`v1-arm64-linux-zig0.16.0-emsdk4.0.9`. It is built in the Dockerfile from
`TARGETARCH`, the build fails if it drifts from `versions.env`, and the
self-test fails if it does not name the architecture the container runs on.
It names what makes cached *outputs* incompatible:

- **Toolchain**: Zig decides every compiled object and Zig-built provider
  binary; emsdk decides the Emscripten sysroot and system libraries. A new Zig
  or emsdk gives a new key, so a new image starts a fresh subtree beside the
  old one and never reuses or corrupts it.
- **Platform**: `<arch>-<os>` of the builder. Zig's local cache holds host
  build tools (`build.zig` runners, provider binaries) compiled for the
  builder, so amd64 and arm64 jobs sharing one volume (or one CI cache
  entry) get separate subtrees and never see each other's binaries.
- **Layout** (`v1`): bumped if the cache layout itself changes.

The CLI version, the assembler version, Playwright and the base image are not
in the key: they do not change compiled outputs, and everything they cache is
already stored per version (`assembler/<v>/`, provider and package versions,
`labelle.lock` hashes). An image revision that changes only those keeps the
warm cache.

**Build configuration** is not in the key and needs no key: the Zig caches are
content-addressed (target, optimize mode, `-D` options, sources and compiler
are all hashed into each entry), and Emscripten's cache stores each library
variant (threads, exceptions, …) under its own name and clears itself when the
Emscripten version changes. A `ReleaseSafe` threaded and a single-threaded
fallback build share one cache safely; they just each add entries.

**Invalidation in practice**:

| Change | Effect |
|---|---|
| new image with a new Zig or emsdk | new key, cold build once (~15 min cold vs ~5 warm on FP's box, `docs/ci.md`); prune the old key later |
| new image, same Zig + emsdk (CLI, Playwright, base, scripts) | same key, stays warm |
| `labelle.lock` / package / plugin bump | same key; the CLI fetches the new pins, Zig rebuilds what changed |
| optimize mode, threads, link settings | same key; new entries |
| suspected corruption or poisoning | delete `/cache/<key>` (or the volume); the next job is cold |

### Concurrency

Jobs may share one cache volume concurrently: Zig's caches are safe for
concurrent use (per-entry locks), the CLI and the web provider lock their
installs (`*.lock` + staged rename), and Emscripten locks its cache. This is
the same sharing FP's shell runner already does with three concurrent jobs in
one `~/.labelle`. Sharing has the trust cost FP's `docs/ci.md` describes
(a job can poison what a later job reads); a volume per protected branch, or
per trust level, closes that at the price of cold first builds.

### Pruning

`labelle-builder-check` touches `/cache/<key>/.last-used` on each job, so old
keys can be pruned by age, for example from a host cron:

```sh
# Remove every key not used by a job in the last 21 days.
docker run --rm -v labelle-wasm-cache:/cache <image> bash -c '
  for d in /cache/v*-*/; do
    [ -n "$(find "$d.last-used" -mtime -21 2>/dev/null)" ] || rm -rf "$d"
  done'
```

The Zig local cache grows with every distinct source state; on a busy runner
also cap it (delete `…/labelle/zig-local-cache` when the volume passes a size
budget; the next build re-fills it from the global cache and sources).

## GitHub Actions

GitHub-hosted runners have Docker, so a job can build in the image with
`docker run`, the runner's checkout bind-mounted, and the cache directory
persisted with `actions/cache`:

```yaml
    env:
      IMAGE: ghcr.io/labelle-toolkit/labelle-wasm-builder:4.1.2-2@sha256:<index digest>
      CACHE_KEY: v1-amd64-linux-zig0.16.0-emsdk4.0.9   # the image's LABELLE_BUILDER_CACHE_KEY
    steps:
      - uses: actions/checkout@v4
      - uses: actions/cache@v4
        with:
          path: ${{ runner.temp }}/labelle-cache
          # Toolchain key first (see "Cache keys"), then the project's pins;
          # restore-keys reuse the newest cache of the same toolchain.
          key: labelle-wasm-${{ env.CACHE_KEY }}-${{ hashFiles('labelle.lock', 'labelle.providers.lock', 'project.labelle') }}-${{ github.sha }}
          restore-keys: |
            labelle-wasm-${{ env.CACHE_KEY }}-${{ hashFiles('labelle.lock', 'labelle.providers.lock', 'project.labelle') }}-
            labelle-wasm-${{ env.CACHE_KEY }}-
      - run: |
          mkdir -p "$RUNNER_TEMP/labelle-cache"
          docker run --rm --user "$(id -u):$(id -g)" \
            -v "$RUNNER_TEMP/labelle-cache:/cache" -v "$PWD:/work/project" -w /work/project \
            "$IMAGE" bash -euo pipefail -c '
              labelle-builder-check
              labelle providers fetch
              labelle bundle --platform=wasm --optimize=ReleaseSafe --output dist'
```

- `--user "$(id -u):$(id -g)"` runs as the runner's user, so the checkout,
  `dist/` and the cache stay owned by it and `actions/cache` can save them
  (the image works under any UID; only `HOME` is then unwritable, which
  nothing needs).
- The key ends in the commit so every run saves a fresh cache (a cache entry
  is immutable once saved) and restores the newest one with the same
  toolchain and pins, falling back to the same toolchain. GitHub keeps 10 GB
  of caches per repository and evicts the least recently used; a Zig cache
  for a large game can be several GB, so keep the number of keys low.
- GitHub-hosted standard runners (docs, 2026-10-30): public repositories
  4 vCPU / 16 GB (x64 `ubuntu-24.04` and arm64 `ubuntu-24.04-arm`, free);
  private repositories 2 vCPU / 8 GB. See [Resources](#resources): a private
  repository's standard runner is below today's measured compiler peak
  (10.4 GiB) and is expected to fit only after labelle-engine#921 (5.3 GiB).
- Use `docker run` rather than a job-level `container:`: GitHub runs
  `container:` jobs' steps expecting the image's default user to be root
  (it cannot reach `GITHUB_WORKSPACE` otherwise), and this image is
  deliberately non-root.

## GitLab Docker executor

FP's runner today is a **shell executor** (`fp-ubuntu`), on which a job's
`image:` has no effect. Using this image needs a runner registered with the
**Docker executor** (a second runner on the same box is fine). The job is in
[`docker/wasm-builder/gitlab-ci.example.yml`](../docker/wasm-builder/gitlab-ci.example.yml):
FP's `test-game-wasm` (bundle, `prepare-web-dist.sh`, the smoke's own unit
tests, then the threaded smoke with COOP/COEP and the single-threaded
fallback without, artifacts for both reports and the bundle), with
`labelle-builder-check` in place of `.toolchain`/`ensure-tool.sh`, and
`labelle-builder-smoke-python` in place of the hand-made venv: when
`tools/web_smoke/requirements.txt` equals the image's pins, the image's venv
and Chromium are used with no download; otherwise a venv keyed on the file is
built in the cache (without root, so a Playwright far from the image's may
need a newer image for its system libraries).

Runner side (`/etc/gitlab-runner/config.toml`), the parts that matter:

```toml
concurrent = 3                        # whole runner

[[runners]]
  name     = "fp-docker"
  executor = "docker"
  limit    = 1                        # WASM jobs at once on this runner; see Resources
  [runners.docker]
    pull_policy       = ["if-not-present"]   # the job pins a digest, so this is safe and saves the pull
    allowed_pull_policies = ["if-not-present", "always"]
    volumes           = ["labelle-wasm-cache:/cache"]   # one persistent named volume
    shm_size          = 2147483648    # 2 GiB /dev/shm: Docker's 64 MiB default crashes Chromium
    memory            = "14g"         # see Resources
    memory_swap       = "14g"         # no swap: fail fast instead of thrashing
    cpus              = "8"
    privileged        = false
    allowed_images    = ["ghcr.io/labelle-toolkit/labelle-wasm-builder*"]
    # Hardening the job does not need privileges for (Playwright launches
    # Chromium without its setuid sandbox by default). Untested here: enable
    # and verify on the runner.
    # cap_drop        = ["ALL"]
    # security_opt    = ["no-new-privileges"]
```

Notes:

- `volumes` is per runner, not per job: every job on this runner shares the
  volume (keys inside separate toolchains). For per-branch isolation register
  a second runner (for `main` / protected branches) with its own volume, as
  FP's `docs/ci.md` options table suggests.
- GitLab's own `cache:` keyword is not used: it zips and uploads the cache
  each job, which for multi-GB Zig caches is slower than a cold build.
- Network: the job needs HTTPS to GitHub (providers, packages, assembler when
  not seeded) and `releases.labelle.games` only on cache misses. With a warm
  cache `LABELLE_OFFLINE=1` can be set to prove nothing is fetched.
- `labelle android …` does not belong on this runner: no SDK/NDK in the image.
- The `gitlab-runner` service needs the Docker socket (root-equivalent on the
  host); the jobs do not get it. Jobs then see only their container, which
  closes FP `docs/ci.md` risks 3 and 4 for these jobs; risk 2 (a shared cache
  can be poisoned) remains unless volumes are split by trust.

## Resources

The epic's measurements (local Windows, one heavy job at a time, Zig `-j2`;
exploratory, **not** Linux/container guarantees), for FP's threaded
`ReleaseSafe` game compile:

| Engine state | Compile | Peak private compiler memory |
|---|---:|---:|
| today (baseline) | 242 s | **10.41 GiB** |
| after the serializer split (labelle-engine#921, pending) | 145 s | **5.34 GiB** |

On top of the compiler come the Emscripten link (about 205 s at `-O3` for the
original build; memory not separately measured), the CLI, and the two
Chromium smoke runs (SwiftShader, roughly 1–2 GiB each, sequential).

Guidance per WASM job container:

| | Until engine#921 ships | After engine#921 |
|---|---|---|
| `memory` (hard limit, no swap) | **14 GiB** (10.4 GiB peak + ~35% headroom for the link, the CLI and Chromium) | **8 GiB** |
| `cpus` | 4–8 (the measured compile is largely one LLVM job; more cores help the C/C++ libraries on a cold cache) | same |
| `shm_size` | 2 GiB (Chromium) | same |
| concurrent WASM jobs | `(host RAM − 6 GiB for the OS, GitLab and other jobs) / 14 GiB`; on FP's 32 GiB box: **1** | `/ 8 GiB`: **2–3** on FP's box |
| job `timeout` | 30 min (cold ~15 min on FP's box) | same |
| disk for `/cache` | budget ~10 GiB per key (an estimate, not measured; emsdk is in the image, not here); prune old keys | same |

**Measured in the image** (2026-10-30, Docker Desktop on Windows: WSL2 VM
with 16 GiB / 24 CPUs, container `--memory=14g`, non-root; FP at
`efc8b1a`, engine 4.2.0-rc.2, so before engine#921; `/cache` on an ext4
image, [above](#mounts-ownership-and-uid)). Each run used a fresh container
on a clean checkout (`git clean -xfd`), with only `/cache` persisting:

| FP `test-game-wasm` run | bundle | whole job | container peak memory (cgroup) | OOM |
|---|---:|---:|---:|---|
| cold cache | 1144 s | 1215 s | **11.5 GiB** | no |
| warm cache, same source | 297 s | 368 s | 1.8 GiB | no |
| warm cache, one game script changed | 979 s | 1052 s | **10.8 GiB** | no |

The rest of the job is small: prepare-web-dist 3 s, the smoke unit tests
26 s, each smoke about 20 s. Two things follow:

- **A source change costs nearly a cold compile, in time and in memory.** The
  game is one Zig compilation unit, so the warm cache only saves the
  libraries and the toolchain. Size runners for the cold peak: 14 GiB holds;
  GitHub's 8 GB private-repo runners do not, until engine#921.
- **FP's build installs a second emsdk inside the checkout.** The generated
  `.labelle/bgfx_wasm/build.zig.zon` depends on
  `git+https://github.com/emscripten-core/emsdk#4.0.9` as a Zig package
  (for `labelle_audio`/`sokol` headers). The build installs it under
  `.labelle/bgfx_wasm/zig-pkg/` (about 1.4 GB, including its own Node
  download), and **not** in `/cache` or from `/opt/emsdk`, so every fresh
  checkout downloads it again. That is part of the 297 s warm bundle. It is
  a toolkit issue (the generated build should use the provider's `EMSDK`),
  not an image one.

`/cache` held 2.1 GiB after the three runs (one key).

An out-of-memory kill shows as the compiler exiting with signal 9 (`Killed`)
and the job failing; raise `memory` or lower WASM concurrency rather than
adding swap, which turns a 4-minute compile into a much longer one. Re-measure
on the Linux runner once the image is adopted (epic #528 WP5); these numbers
are the only ones available now.

## Publishing

[`.github/workflows/wasm-builder-image.yml`](../.github/workflows/wasm-builder-image.yml):

- **Pull requests** touching `docker/wasm-builder/**` or the workflow: lint
  (hadolint, shellcheck), then per architecture, natively (amd64 on
  `ubuntu-24.04`, arm64 on `ubuntu-24.04-arm`): build; self-test as the
  non-root user; two fresh containers on one fresh named volume; and the
  end-to-end build ([below](#end-to-end-check)) cold and then warm in a second
  fresh container. Timings, peak memory and the inventory go to the run
  summary; reports and bundles are artifacts. **Never pushes.**
- **Tag** `wasm-builder-v<IMAGE_VERSION>` (refused if it does not match
  `versions.env`), or a **manual dispatch** with `push` ticked: the same
  tests, then each architecture's **tested image** is pushed as
  `<version>-<arch>` and one multi-arch index `<version>` is created from those
  digests, with a build-provenance attestation on GHCR. Every tag is
  immutable: an existing one is refused. The index digest is in the run
  summary.
- The CLI's own `v*` release tags do not match and never trigger it.

**Registry (decided): GHCR, public.** The default is
`ghcr.io/labelle-toolkit/labelle-wasm-builder`, logged in with the workflow
token (no secret to manage). A GHCR package created by the first push is
**private**: an organisation owner must then open the package settings
(github.com/orgs/labelle-toolkit/packages/container/labelle-wasm-builder/settings)
and set its visibility to **public**, once. After that, consumers (GitHub
Actions, GitLab runners, developers) pull it anonymously: **no pull token or
registry login is needed**. The workflow keeps the registry a parameter
(dispatch input `registry`/`image`, else repository variables
`WASM_BUILDER_REGISTRY`/`WASM_BUILDER_IMAGE`; another registry needs the
`WASM_BUILDER_REGISTRY_USERNAME`/`WASM_BUILDER_REGISTRY_PASSWORD` secrets), for
example to mirror into a LAN registry later.

To release:

1. Edit `versions.env` (bump `IMAGE_REVISION`, or set the new
   `LABELLE_CLI_VERSION` and reset it to 1); the PR runs the full test.
   Merge.
2. Tag the merge commit `wasm-builder-v<LABELLE_CLI_VERSION>-<IMAGE_REVISION>`
   and push the tag.
3. First release only: make the GHCR package public (above).

Consumers **pin the digest**, not the tag:
`image: ghcr.io/labelle-toolkit/labelle-wasm-builder:4.1.2-2@sha256:<index digest>`.
When both are given the digest decides what runs; the tag only documents it.
The index digest serves both architectures; a per-arch digest
(`<version>-amd64@…`) pins one.

**Reproducibility.** The base is pinned by digest; every toolchain by version
plus checksum or commit; pip by `--require-hashes`; Playwright's browsers by
checksum through the local mirror; and Ubuntu packages by the apt snapshot
(`UBUNTU_SNAPSHOT`, with the top-level packages also pinned to their snapshot
versions). Two builds of one `versions.env` therefore install the same files.
Layer timestamps follow `SOURCE_DATE_EPOCH` (the commit time); byte-identical
image digests are not claimed (file mtimes inside layers, apt's own state
files), which is why a published tag is never rebuilt in place.

## Upgrading

1. Release a new image ([Publishing](#publishing)). For each pin, update both
   `_amd64` and `_arm64` values and recompute every checksum from a download:
   - **Base image**: the current digest of `ubuntu:24.04` (for example
     `docker buildx imagetools inspect ubuntu:24.04`; take the index digest,
     which covers both architectures) into `BASE_IMAGE`.
   - **Ubuntu snapshot**: set `UBUNTU_SNAPSHOT` to a new instant
     (`YYYYMMDDTHHMMSSZ`; any instant works, the service resolves it to the
     archive state at that time). Then refresh `APT_PACKAGES`: for each
     package take its version in that snapshot, preferring `noble-updates`,
     then `noble-security`, then `noble`, e.g.
     `curl -fsSL http://snapshot.ubuntu.com/ubuntu/<T>/dists/noble-updates/main/binary-amd64/Packages.xz | xz -dc | grep -A1 '^Package: curl$'`
     (`python3-venv` is in `universe`); check arm64 has the same versions.
     A version the snapshot lacks fails the build at `apt-get install`. Bumping
     the snapshot is how security updates reach the image: do it at least with
     every image release.
   - **Zig, CLI, assembler**: version and per-arch sha256 (Zig's
     `download/index.json`, the assembler's `SHA256SUMS`; the CLI publishes
     no checksum file, so hash the downloads).
   - **emsdk**: the version *and* commit from the labelle-web release the
     projects pin (`src/provider/emsdk.zig`); `EMSDK_RELEASE_HASH` from that
     emsdk's `emscripten-releases-tags.json`; the per-arch `wasm-binaries*`
     archives under
     `storage.googleapis.com/webassembly/emscripten-releases-builds/linux/<hash>/`;
     the Node version from emsdk's manifest (archives under `.../deps/`, cross-
     check nodejs.org); `LABELLE_WEB_VERSIONS`; and the literal cache key and
     node `PATH` in the Dockerfile (the build fails until they agree).
   - **Playwright/Pillow**: from the consumer's smoke `requirements.txt`;
     regenerate `web-smoke-requirements.lock` (transitive deps, both
     architectures' wheel hashes, e.g. with `pip-compile --generate-hashes`
     or from PyPI's JSON) and the browser pins from that Playwright's
     `browsers.json` and `registry/index.ts` download paths
     (`--only-shell chromium` = headless shell + ffmpeg).
2. In the consumer, change the `image:` tag and digest in the same commit as
   the matching `labelle.lock` bump (CLI) or on its own (image revision).
   The preflight fails if the two disagree.
3. A new Zig or emsdk means a new cache key: expect one cold build per runner
   volume; prune the old key after the rollback window.

## Rolling back

Point `image:` back at the previous tag **and digest** (both stay in the
registry; tags are never overwritten or deleted by the workflow) and, if the
upgrade also bumped `labelle.lock`, revert that too. The previous image's
cache key subtree is still on the volume unless it was pruned, so the
rollback is warm. If a bad image wrote a broken cache under a shared key,
delete `/cache/<key>` for that key.

## End-to-end check

[`docker/wasm-builder/e2e/`](../docker/wasm-builder/e2e/) is the fixture the
workflow builds on every PR, on both architectures:
`game/` is a `labelle init` project (CLI 4.1.2: engine 3.4.1, bgfx backend,
assembler 0.120.0, so the assembler is downloaded rather than seeded) with
the released labelle-web 0.4.0 provider pinned (`labelle.providers.lock`)
and threads on (`providers/web.json`). `run.sh <image> <volume> <out>
<label>` runs, in a fresh container as UID 10001 with only the cache volume
persisting: `labelle-builder-check`, `labelle providers fetch`,
`labelle bundle --platform=wasm --optimize=ReleaseSafe` (threaded build plus
single-threaded fallback), then `smoke.py` twice in the headless shell: with
COOP/COEP (must be cross-origin isolated and load `threaded/game.js`) and
without (must load the fallback `game.js`); both must reach the loader's
`onRuntimeInitialized` and run 10 s with no page error. It records per-phase
seconds and the container's peak memory (cgroup `memory.peak`). The workflow
runs it twice, cold then warm, on one volume.

The fixture is generic on purpose: FP's own smoke (menu, intro, demo) stays in
FP and runs there ([GitHub Actions](#github-actions)).

## Validation status

See the PR (labelle-cli#530) for the latest CI runs. Statically, at the time
of writing:

- Linted: the Dockerfile with hadolint 2.12.0
  (`docker/wasm-builder/.hadolint.yaml` documents the ignored rules), the
  scripts with shellcheck 0.10.0, the workflow with actionlint 1.7.12.
- Checked outside a container: `labelle-builder-check` against a Flying
  Platform checkout (all pins matching; assembler seeded once, then reused)
  and against a copy with a different CLI, emsdk and assembler pin (fails,
  and passes as warnings with `LABELLE_BUILDER_ALLOW_PIN_MISMATCH=1`);
  `labelle-builder-smoke-python` matching FP's CRLF-checked-out requirements.
- Every checksum in `versions.env` was recomputed from a download on
  2026-10-30 (Node also matches nodejs.org; assembler and Zig match their
  published sums; pip hashes are PyPI's).
- Not covered by CI here: FP's own build and smoke (see the FP workflow),
  GitLab runners, and Linux memory peaks for FP.
