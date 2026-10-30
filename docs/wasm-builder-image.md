# WASM builder image

A versioned Docker image in which the ordinary `labelle` pipeline builds,
bundles and smoke-tests a game for `--platform=wasm`, as a non-root user, with
no host toolchain (labelle-cli#529, epic #528 work package 1). It is meant for
CI runners with a Docker executor, GitLab first.

| | |
|---|---|
| Source | [`docker/wasm-builder/`](../docker/wasm-builder/): `Dockerfile`, `versions.env` (every pin), `bin/` (the helper scripts baked into the image), `gitlab-ci.example.yml` |
| Publish | [`.github/workflows/wasm-builder-image.yml`](../.github/workflows/wasm-builder-image.yml), on a `wasm-builder-v<version>` tag or a manual dispatch |
| Image | `ghcr.io/labelle-toolkit/labelle-wasm-builder:<cli version>-<revision>` until a registry is agreed ([Publishing](#publishing)) |
| Platform | `linux/amd64` only. Android (SDK/NDK) is out of scope: a separate future variant (cli#331). |

Contents:

- [What is in the image](#what-is-in-the-image)
- [Relationship to `--docker`](#relationship-to---docker)
- [Image and toolkit compatibility](#image-and-toolkit-compatibility)
- [Caches](#caches): layout, mounts, ownership and UID, cache keys and invalidation, concurrency, pruning
- [GitLab Docker executor](#gitlab-docker-executor)
- [Resources](#resources)
- [Publishing](#publishing), [Upgrading](#upgrading), [Rolling back](#rolling-back)
- [Validation status](#validation-status)

## What is in the image

Every version and checksum lives in
[`docker/wasm-builder/versions.env`](../docker/wasm-builder/versions.env);
the Dockerfile sources it and verifies each download against it. The image
carries a copy (`/opt/labelle/versions.env`) and a **toolchain inventory**
measured from the installed tools at build time,
`/opt/labelle/toolchain-inventory.json` (`labelle-builder-check --inventory`
prints it; the publish run also puts it in the workflow summary).

| Component | Version (image 4.1.2-1) | Where it comes from | In the image |
|---|---|---|---|
| Base | `ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852` | Docker Hub index digest for `24.04`, resolved 2026-10-30 | `FROM` |
| labelle CLI | 4.1.2, sha256 `43d84d3b…1712d28` | Flying Platform's `labelle.lock` `.cli_version` and `tools/ci/ensure-tool.sh` (`labelle@v4.1.2`); checksum re-verified against `releases.labelle.games` | `/usr/local/bin/labelle` |
| Zig | 0.16.0, sha256 `70e49664…2ba3d00` | the CLI's `DEFAULT_ZIG_VERSION`/`minimum_zig_version`, FP's `ensure-tool.sh zig@0.16.0` | `/opt/zig`, `LABELLE_ZIG=/opt/zig/zig` |
| labelle-assembler | 0.124.0, sha256 `4d169a6c…5b82d5af` | FP's `project.labelle` `.assembler_version`; digest from the release's `SHA256SUMS` | a **seed** at `/opt/labelle/seed/assembler/0.124.0/` ([below](#image-and-toolkit-compatibility)) |
| emsdk / Emscripten | 4.0.9, commit `3bcf1dcd01f0…` | labelle-web 0.4.0's default `emsdk.version` and pinned tag commit (`src/provider/emsdk.zig`) | `/opt/emsdk`, activated, `EMSDK=/opt/emsdk` |
| Node | 20.18.0 | bundled by emsdk 4.0.9 (`node-20.18.0-64bit` in its manifest) | `/opt/emsdk/node/20.18.0_64bit/bin`, on `PATH` |
| Python | 3.12 (Ubuntu 24.04 `python3`) | what emsdk/emcc and FP's smoke run with; FP's `tools/web_smoke/README.md` uses 3.12 | `/usr/bin/python3` |
| Playwright + Pillow | 1.64.1 + 11.3.0 | FP's `tools/web_smoke/requirements.txt` | venv `/opt/labelle/web-smoke-venv` (`LABELLE_WEB_SMOKE_VENV`) |
| Chromium | Playwright 1.64.1's Chrome for Testing headless shell (H.264 capable), with `playwright install --with-deps` system libraries | Playwright | `/opt/ms-playwright` (`PLAYWRIGHT_BROWSERS_PATH`) |
| System | `libatomic1` (binaryen's `wasm-opt` needs `libatomic.so.1`, as on FP's runner, `setup-ci-host.sh`), `git`, `curl`, `ca-certificates`, `xz-utils` | noble at build time; versions recorded in the inventory | apt |

Helpers on `PATH`:

- `labelle-builder-check`: the job preflight ([compatibility](#image-and-toolkit-compatibility), [caches](#caches)); `--self-test` checks the image alone; `--inventory` prints the inventory.
- `labelle-builder-smoke-python <requirements.txt>`: prints the Python to run a Playwright smoke with ([GitLab](#gitlab-docker-executor)).
- `labelle-builder-inventory`: regenerates the inventory from the installed tools.

The image holds **no credentials and no game source**: no `COPY` of anything
outside `docker/wasm-builder/`, no tokens in build arguments, and every
toolchain is fetched over HTTPS and checked against a recorded checksum or
commit. Toolchains (`/opt`, `/usr/local/bin`) are root-owned and read-only to
the build user, so a job cannot modify the compiler a later job runs.

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
`<CLI version>-<image revision>` (`4.1.2-1`): the revision counts image-only
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
  `sudo install -d -o 10001 -g 10001 /srv/labelle-cache`.
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
`v1-x86_64-linux-zig0.16.0-emsdk4.0.9`. It is literal in the Dockerfile and
the build fails if it drifts from `versions.env`. It names what makes cached
*outputs* incompatible:

- **Toolchain**: Zig decides every compiled object and Zig-built provider
  binary; emsdk decides the Emscripten sysroot and system libraries. A new Zig
  or emsdk gives a new key, so a new image starts a fresh subtree beside the
  old one and never reuses or corrupts it.
- **Platform**: `<arch>-<os>` of the builder (an arm64 variant would get its
  own key).
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

An out-of-memory kill shows as the compiler exiting with signal 9 (`Killed`)
and the job failing; raise `memory` or lower WASM concurrency rather than
adding swap, which turns a 4-minute compile into a much longer one. Re-measure
on the Linux runner once the image is adopted (epic #528 WP5); these numbers
are the only ones available now.

## Publishing

[`.github/workflows/wasm-builder-image.yml`](../.github/workflows/wasm-builder-image.yml)
runs only on a `wasm-builder-v*` tag or a manual dispatch (never on PRs; the
CLI's own `v*` release tags do not match). It lints (hadolint, shellcheck),
builds, runs the self-test as the non-root user, checks that a fresh named
volume is writable and that a second fresh container sees the first one's
cache, records the inventory, then pushes **the image it tested** under one
immutable tag `<registry>/<image>:<IMAGE_VERSION>` (an existing tag is
refused) and, on GHCR, a build-provenance attestation. The tag and the
**digest** are in the run's summary.

Registry (not yet agreed): dispatch input `registry`/`image`, else repository
variables `WASM_BUILDER_REGISTRY`/`WASM_BUILDER_IMAGE`, else
`ghcr.io/labelle-toolkit/labelle-wasm-builder`. GHCR logs in with the workflow
token; another registry (for example FP's GitLab container registry, which a
LAN runner can reach without the internet) needs the
`WASM_BUILDER_REGISTRY_USERNAME`/`WASM_BUILDER_REGISTRY_PASSWORD` secrets.
A new GHCR package is private; make it public (or give the runner a pull
token) after the first push.

To release:

1. Edit `versions.env` (bump `IMAGE_REVISION`, or set the new
   `LABELLE_CLI_VERSION` and reset it to 1), merge.
2. Optionally dispatch the workflow with `push` unticked to build and test it.
3. Tag the merge commit `wasm-builder-v<LABELLE_CLI_VERSION>-<IMAGE_REVISION>`
   and push the tag; the workflow refuses a tag that does not match
   `versions.env`.

Consumers **pin the digest**, not the tag:
`image: ghcr.io/labelle-toolkit/labelle-wasm-builder:4.1.2-1@sha256:<digest>`.
When both are given the digest decides what runs; the tag only documents it.

Reproducibility: the base is pinned by digest and every toolchain by version
plus checksum or commit, so rebuilding a `versions.env` gives the same
toolchains. Ubuntu packages (`libatomic1`, Chromium's libraries) follow
`noble-updates` at build time and are recorded in the inventory rather than
pinned; two builds of one revision can differ there, which is why a published
tag is never rebuilt in place.

## Upgrading

1. Release a new image ([Publishing](#publishing)).
   - Base image: resolve the current digest of `ubuntu:24.04` (for example
     `docker buildx imagetools inspect ubuntu:24.04`) and update `BASE_IMAGE`.
   - Zig, CLI, assembler: version and sha256 from the release (the CLI's,
     Zig's `ziglang.org/download`, the assembler's `SHA256SUMS`).
   - emsdk: take the version *and* commit from the labelle-web release the
     projects pin (`src/provider/emsdk.zig`), update `EMSDK_NODE_VERSION`
     from that emsdk's manifest, `LABELLE_WEB_VERSIONS`, and the literal cache
     key and node `PATH` in the Dockerfile (the build fails until they agree).
   - Playwright/Pillow: from the consumer's smoke `requirements.txt`.
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

## Validation status

At the time of this change (labelle-cli#529):

- Linted: the Dockerfile with hadolint 2.12.0 (`docker/wasm-builder/.hadolint.yaml`
  documents the ignored rules), the helper scripts with shellcheck 0.10.0, the
  workflow with actionlint 1.7.12.
- Checked outside a container: `labelle-builder-check` against a Flying
  Platform checkout (all pins matching; assembler seeded once, then reused)
  and against a copy with a different CLI, emsdk and assembler pin (fails,
  and passes as warnings with `LABELLE_BUILDER_ALLOW_PIN_MISMATCH=1`);
  `labelle-builder-smoke-python` matching FP's CRLF-checked-out requirements.
- Downloads verified: the CLI, Zig and assembler checksums above were
  re-computed from the published files; the emsdk commit and Node version
  come from the emsdk 4.0.9 tag.
- **Not yet done**: building the image, running it, and the acceptance runs
  (FP's WASM bundle in a fresh container as non-root; a second fresh container
  reusing the caches; Linux memory peaks). The first workflow run performs the
  image-level checks; the FP runs belong to the FP adoption ticket.
