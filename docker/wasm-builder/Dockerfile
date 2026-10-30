# syntax=docker/dockerfile:1
# check=skip=SecretsUsedInArgOrEnv
#
# Labelle WASM builder image (labelle-cli#529, epic #528 WP1).
#
# A CI environment in which the ordinary `labelle` pipeline builds, bundles
# and smoke-tests a game for --platform=wasm as a non-root user. Toolchains
# live in the image; every cache lives under /cache, which CI mounts from a
# persistent volume. The image holds no credentials and no game source.
#
#   docker build -t labelle-wasm-builder:dev docker/wasm-builder
#
# linux/amd64 and linux/arm64 (TARGETARCH picks the per-architecture pins).
# Versions and checksums: versions.env (the only place to bump them); every
# download below is checked against it before use.
# Usage, cache layout, upgrade/rollback: docs/wasm-builder-image.md.

# ubuntu:24.04 resolved 2026-10-30: the multi-platform index digest, so it
# serves both architectures. See "Upgrading" in the docs to bump it.
ARG BASE_IMAGE=ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
FROM ${BASE_IMAGE}
ARG BASE_IMAGE
ARG TARGETARCH

# The non-root build user. 10001 stays clear of ubuntu:24.04's own `ubuntu`
# user (1000). Override to match a host bind mount's owner if needed.
ARG BUILDER_UID=10001
ARG BUILDER_GID=10001

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

COPY versions.env web-smoke-requirements.lock /opt/labelle/
COPY lib/pins.sh /opt/labelle/lib/pins.sh

# Ubuntu packages from snapshot.ubuntu.com at UBUNTU_SNAPSHOT, with the
# top-level packages pinned to their snapshot versions. The service answers
# only over https and the base has no CA bundle yet, so this one apt run
# skips TLS peer verification. Integrity does not rest on TLS: apt checks the
# archive's signed InRelease and every index and .deb hash against it, as it
# does over plain http. Later apt runs (Playwright's) verify TLS. The snapshot
# serves
# amd64 and arm64 from one URL. libatomic1: binaryen's wasm-opt (emsdk) links
# it. git: provider/package fetches and the emsdk checkout. python3: emsdk,
# emcc and the smoke harness. xz-utils: the Zig and emsdk archives.
# safe.directory: CI clones the checkout as another user (GitLab's helper runs
# as root, actions/checkout as the runner user); git refuses it otherwise.
RUN . /opt/labelle/lib/pins.sh \
 && rm -f /etc/apt/sources.list /etc/apt/sources.list.d/* \
 && printf '%s\n' \
      'Types: deb' \
      "URIs: https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}" \
      'Suites: noble noble-updates noble-security' \
      'Components: main universe' \
      'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' \
      > /etc/apt/sources.list.d/ubuntu-snapshot.sources \
 && echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99snapshot \
 && bootstrap=(-o Acquire::https::Verify-Peer=false -o Acquire::https::Verify-Host=false) \
 && apt-get "${bootstrap[@]}" update \
 && IFS=, read -r -a pkgs <<< "${APT_PACKAGES}" \
 && apt-get "${bootstrap[@]}" install -y --no-install-recommends "${pkgs[@]}" \
 && rm -rf /var/lib/apt/lists/* \
 && git config --system --add safe.directory '*'

# Zig, flattened into /opt/zig (read-only to the builder). LABELLE_ZIG below
# makes the CLI use it instead of downloading another one.
RUN . /opt/labelle/lib/pins.sh \
 && zarch="$(pin ZIG_ARCH)" \
 && fetch "https://ziglang.org/download/${ZIG_VERSION}/zig-${zarch}-linux-${ZIG_VERSION}.tar.xz" "$(pin ZIG_SHA256)" /tmp/zig.tar.xz \
 && mkdir -p /opt/zig \
 && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
 && rm /tmp/zig.tar.xz \
 && ln -s /opt/zig/zig /usr/local/bin/zig

# labelle CLI and the assembler seed.
RUN . /opt/labelle/lib/pins.sh \
 && fetch "https://releases.labelle.games/cli/v${LABELLE_CLI_VERSION}/$(pin LABELLE_CLI_ASSET)" "$(pin LABELLE_CLI_SHA256)" /tmp/labelle \
 && install -m 0755 /tmp/labelle /usr/local/bin/labelle \
 && rm /tmp/labelle \
 && seed="/opt/labelle/seed/assembler/${LABELLE_ASSEMBLER_VERSION}" \
 && mkdir -p "$seed" \
 && fetch "https://github.com/labelle-toolkit/labelle-assembler/releases/download/v${LABELLE_ASSEMBLER_VERSION}/$(pin LABELLE_ASSEMBLER_ASSET)" "$(pin LABELLE_ASSEMBLER_SHA256)" /tmp/asm \
 && install -m 0755 /tmp/asm "$seed/labelle-assembler" \
 && rm /tmp/asm

# emsdk, as labelle-web's managed install does it (shallow clone of the tag,
# commit verified, `emsdk install` + `emsdk activate`), but into /opt/emsdk
# and with its two downloads (the emscripten-releases build and Node)
# fetched and verified here first: EMSDK_KEEP_DOWNLOADS makes emsdk use them,
# and the build fails if emsdk downloaded anything else. With EMSDK set, the
# web provider's default `managed` source passes this activated emsdk
# through instead of installing its own. The SDK stays read-only to the
# builder; Emscripten's writable cache is EM_CACHE under /cache. Bytecode is
# precompiled so a read-only tree costs nothing per run.
WORKDIR /opt/emsdk
RUN . /opt/labelle/lib/pins.sh \
 && git clone --quiet --depth 1 --branch "${EMSDK_VERSION}" https://github.com/emscripten-core/emsdk.git . \
 && test "$(git rev-parse HEAD)" = "${EMSDK_COMMIT}" \
 && grep -q "\"${EMSDK_VERSION}\": \"${EMSDK_RELEASE_HASH}\"" emscripten-releases-tags.json \
 && mkdir -p downloads \
 && archive="$(pin EMSDK_ARCHIVE)" node="$(pin EMSDK_NODE_ARCHIVE)" \
 && fetch "https://storage.googleapis.com/webassembly/emscripten-releases-builds/linux/${EMSDK_RELEASE_HASH}/${archive}" \
      "$(pin EMSDK_ARCHIVE_SHA256)" "downloads/${EMSDK_RELEASE_HASH}-${archive}" \
 && fetch "https://storage.googleapis.com/webassembly/emscripten-releases-builds/deps/${node}" \
      "$(pin EMSDK_NODE_SHA256)" "downloads/${node}" \
 && find downloads -mindepth 1 -printf '%f\n' | sort > /tmp/emsdk-expected \
 && EMSDK_KEEP_DOWNLOADS=1 ./emsdk install "${EMSDK_VERSION}" \
 && find downloads -mindepth 1 -printf '%f\n' | sort | diff -u /tmp/emsdk-expected - \
 && ./emsdk activate "${EMSDK_VERSION}" \
 && test -x upstream/emscripten/emcc \
 && test -f .emscripten \
 && test -x "node/${EMSDK_NODE_VERSION}_64bit/bin/node" \
 && rm -rf downloads/* /tmp/emsdk-expected upstream/emscripten/cache \
 && python3 -m compileall -q -j 0 upstream/emscripten > /dev/null
WORKDIR /

# Chromium WASM smoke: a venv with Flying Platform's pinned Playwright and
# Pillow (hash-locked, transitive deps included) and Playwright's Chrome for
# Testing headless shell + ffmpeg with their system libraries. The browser
# archives are fetched and verified here, then served to `playwright install`
# from a local mirror (PLAYWRIGHT_DOWNLOAD_HOST), so it installs exactly
# those bytes; anything else it asked for would 404 and fail the build. The
# browsers live outside every cache, read-only.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
# kill: stops the build-time mirror server started in the same RUN.
# hadolint ignore=DL3001
RUN . /opt/labelle/lib/pins.sh \
 && python3 -m venv /opt/labelle/web-smoke-venv \
 && /opt/labelle/web-smoke-venv/bin/pip install --no-cache-dir --disable-pip-version-check -q \
      --require-hashes --only-binary :all: --no-deps -r /opt/labelle/web-smoke-requirements.lock \
 && printf 'playwright==%s\nPillow==%s\n' "${PLAYWRIGHT_VERSION}" "${PILLOW_VERSION}" > /opt/labelle/web-smoke-requirements.txt \
 && mirror=/tmp/pw-mirror \
 && shell="$(pin PLAYWRIGHT_SHELL_PATH)" ffmpeg="$(pin PLAYWRIGHT_FFMPEG_PATH)" \
 && mkdir -p "$mirror/${shell%/*}" "$mirror/${ffmpeg%/*}" \
 && fetch "https://cdn.playwright.dev/${shell}" "$(pin PLAYWRIGHT_SHELL_SHA256)" "$mirror/${shell}" \
 && fetch "https://cdn.playwright.dev/${ffmpeg}" "$(pin PLAYWRIGHT_FFMPEG_SHA256)" "$mirror/${ffmpeg}" \
 && { python3 -m http.server 8765 --bind 127.0.0.1 --directory "$mirror" > /tmp/pw-mirror.log 2>&1 & } \
 && srv=$! \
 && for _ in $(seq 50); do curl -fs -o /dev/null http://127.0.0.1:8765/ && break; sleep 0.2; done \
 && apt-get update \
 && PLAYWRIGHT_DOWNLOAD_HOST=http://127.0.0.1:8765 \
      /opt/labelle/web-smoke-venv/bin/python -m playwright install --with-deps --only-shell chromium \
 && kill "$srv" \
 && cat /tmp/pw-mirror.log \
 && test -d "/opt/ms-playwright/chromium_headless_shell-${PLAYWRIGHT_CHROMIUM_REVISION}" \
 && rm -rf /var/lib/apt/lists/* "$mirror" /tmp/pw-mirror.log \
 && chmod -R a+rX /opt/ms-playwright

COPY --chmod=0755 bin/ /usr/local/bin/

# The cache key: every cache the image's toolchain writes is keyed by
# architecture + OS + Zig + emsdk (see "Cache keys" in the docs). Literal so
# ENV can use it; the RUN below fails the build if it drifts from
# versions.env.
ENV LABELLE_BUILDER_CACHE_KEY=v1-${TARGETARCH}-linux-zig0.16.0-emsdk4.0.9
ENV LABELLE_BUILDER_CACHE_ROOT=/cache
ENV LABELLE_HOME=/cache/${LABELLE_BUILDER_CACHE_KEY}/labelle \
    EM_CACHE=/cache/${LABELLE_BUILDER_CACHE_KEY}/emscripten \
    XDG_CACHE_HOME=/cache/${LABELLE_BUILDER_CACHE_KEY}/xdg \
    LABELLE_ZIG=/opt/zig/zig \
    EMSDK=/opt/emsdk \
    LABELLE_WEB_SMOKE_VENV=/opt/labelle/web-smoke-venv \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PATH=/opt/emsdk/node/20.18.0_64bit/bin:${PATH}

# Release identity, set by the publish workflow (last, so a new version only
# rebuilds the layers below).
ARG IMAGE_VERSION=dev
ARG VCS_REF=unknown
ENV LABELLE_BUILDER_IMAGE_VERSION=${IMAGE_VERSION} \
    LABELLE_BUILDER_VCS_REF=${VCS_REF} \
    LABELLE_BUILDER_BASE_IMAGE=${BASE_IMAGE}

# Non-root user, the /cache mount point (a fresh named volume copies this
# ownership) and a workspace. Then the drift guards and the inventory, run
# against a throwaway /cache that is emptied again before the layer ends.
RUN groupadd --gid "${BUILDER_GID}" builder \
 && useradd --uid "${BUILDER_UID}" --gid "${BUILDER_GID}" --create-home --shell /bin/bash builder \
 && install -d -o builder -g builder -m 0775 /cache /work \
 && . /opt/labelle/lib/pins.sh \
 && test "${LABELLE_BUILDER_CACHE_KEY}" = "v1-${TARGETARCH}-linux-zig${ZIG_VERSION}-emsdk${EMSDK_VERSION}" \
 && test "$(command -v node)" = "/opt/emsdk/node/${EMSDK_NODE_VERSION}_64bit/bin/node" \
 && test "$(zig version)" = "${ZIG_VERSION}" \
 && labelle-builder-inventory > /opt/labelle/toolchain-inventory.json \
 && cat /opt/labelle/toolchain-inventory.json \
 && find /cache -mindepth 1 -delete \
 && chown builder:builder /cache

USER builder:builder
WORKDIR /work

LABEL org.opencontainers.image.title="labelle-wasm-builder" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      org.opencontainers.image.description="Labelle WASM builder: Zig, labelle CLI, emsdk, Chromium smoke deps; caches under /cache" \
      org.opencontainers.image.source="https://github.com/labelle-toolkit/labelle-cli"

CMD ["labelle-builder-check", "--self-test"]
