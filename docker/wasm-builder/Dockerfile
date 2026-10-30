# syntax=docker/dockerfile:1
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
# Versions and checksums: versions.env (the only place to bump them).
# Usage, cache layout, upgrade/rollback: docs/wasm-builder-image.md.
# linux/amd64 only for now (the published Zig/CLI/emsdk/Chromium pins are
# the x86_64 builds); an arm64 variant is a separate change.

# ubuntu:24.04 resolved 2026-10-30 (index digest, all platforms). Bump with
# the registry's current digest for the tag; see "Upgrading" in the docs.
ARG BASE_IMAGE=ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
FROM ${BASE_IMAGE}
ARG BASE_IMAGE

# The non-root build user. 10001 stays clear of ubuntu:24.04's own `ubuntu`
# user (1000). Override to match a host bind mount's owner if needed.
ARG BUILDER_UID=10001
ARG BUILDER_GID=10001

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

COPY versions.env /opt/labelle/versions.env

# System packages. libatomic1: binaryen's wasm-opt (emsdk) links it. git:
# provider/package fetches and the emsdk checkout. python3: emsdk/emcc and the
# smoke harness. xz-utils: the Zig archive. The Chromium libraries come from
# Playwright's own install-deps below. Package versions are recorded in the
# inventory (they follow noble-updates at build time; the base is pinned).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git xz-utils bzip2 unzip \
      python3 python3-venv \
      libatomic1 \
 && rm -rf /var/lib/apt/lists/* \
 && git config --system --add safe.directory '*'
# safe.directory: CI clones the checkout as another user (GitLab's helper
# runs as root); without it git refuses to work in it as `builder`.

# Zig, checksum-verified, flattened into /opt/zig (read-only to the builder).
# LABELLE_ZIG below makes the CLI use it instead of downloading another one.
RUN . /opt/labelle/versions.env \
 && curl -fsSLo /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
 && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum -c - \
 && mkdir -p /opt/zig \
 && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
 && rm /tmp/zig.tar.xz \
 && ln -s /opt/zig/zig /usr/local/bin/zig

# labelle CLI (checksum-verified) and the assembler seed (verified against
# the release's SHA256SUMS digest recorded in versions.env).
RUN . /opt/labelle/versions.env \
 && curl -fsSLo /tmp/labelle "https://releases.labelle.games/cli/v${LABELLE_CLI_VERSION}/labelle-linux-x86_64" \
 && echo "${LABELLE_CLI_SHA256}  /tmp/labelle" | sha256sum -c - \
 && install -m 0755 /tmp/labelle /usr/local/bin/labelle \
 && rm /tmp/labelle \
 && seed="/opt/labelle/seed/assembler/${LABELLE_ASSEMBLER_VERSION}" \
 && mkdir -p "$seed" \
 && curl -fsSLo /tmp/asm "https://github.com/labelle-toolkit/labelle-assembler/releases/download/v${LABELLE_ASSEMBLER_VERSION}/labelle-assembler-linux-x86_64" \
 && echo "${LABELLE_ASSEMBLER_SHA256}  /tmp/asm" | sha256sum -c - \
 && install -m 0755 /tmp/asm "$seed/labelle-assembler" \
 && rm /tmp/asm

# emsdk, exactly as labelle-web's managed install does it (shallow clone of
# the tag, commit verified, `emsdk install` + `emsdk activate`), but into
# /opt/emsdk. With EMSDK set, the web provider's default `managed` source
# passes this activated emsdk through instead of installing its own.
# The SDK stays read-only to the builder; Emscripten's writable cache is
# EM_CACHE under /cache. Bytecode is precompiled so a read-only tree costs
# nothing per run.
WORKDIR /opt/emsdk
RUN . /opt/labelle/versions.env \
 && git clone --quiet --depth 1 --branch "${EMSDK_VERSION}" https://github.com/emscripten-core/emsdk.git . \
 && test "$(git rev-parse HEAD)" = "${EMSDK_COMMIT}" \
 && ./emsdk install "${EMSDK_VERSION}" \
 && ./emsdk activate "${EMSDK_VERSION}" \
 && test -x upstream/emscripten/emcc \
 && test -f .emscripten \
 && test -x "node/${EMSDK_NODE_VERSION}_64bit/bin/node" \
 && rm -rf downloads/* \
 && rm -rf upstream/emscripten/cache \
 && python3 -m compileall -q -j 0 upstream/emscripten > /dev/null
WORKDIR /

# Chromium WASM smoke: a venv with Flying Platform's pinned Playwright and
# Pillow, and Playwright's Chrome for Testing headless shell plus its system
# libraries. The browsers live outside every cache, read-only.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN . /opt/labelle/versions.env \
 && python3 -m venv /opt/labelle/web-smoke-venv \
 && /opt/labelle/web-smoke-venv/bin/pip install --no-cache-dir --disable-pip-version-check -q \
      "playwright==${PLAYWRIGHT_VERSION}" "Pillow==${PILLOW_VERSION}" \
 && printf 'playwright==%s\nPillow==%s\n' "${PLAYWRIGHT_VERSION}" "${PILLOW_VERSION}" > /opt/labelle/web-smoke-requirements.txt \
 && apt-get update \
 && /opt/labelle/web-smoke-venv/bin/python -m playwright install --with-deps chromium \
 && rm -rf /var/lib/apt/lists/* \
 && chmod -R a+rX /opt/ms-playwright

COPY --chmod=0755 bin/ /usr/local/bin/

# The cache key: every cache the image's toolchain writes is keyed by host
# platform + Zig + emsdk (see "Cache keys" in the docs). Kept literal so ENV
# can use it; the RUN below fails the build if it drifts from versions.env.
ENV LABELLE_BUILDER_CACHE_KEY=v1-x86_64-linux-zig0.16.0-emsdk4.0.9
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
# rebuilds this layer and the inventory).
ARG IMAGE_VERSION=dev
ARG VCS_REF=unknown
ENV LABELLE_BUILDER_IMAGE_VERSION=${IMAGE_VERSION} \
    LABELLE_BUILDER_VCS_REF=${VCS_REF} \
    LABELLE_BUILDER_BASE_IMAGE=${BASE_IMAGE}

# Non-root user, the /cache mount point (a fresh named volume copies this
# ownership) and a workspace. Then the drift guard and the inventory.
RUN groupadd --gid "${BUILDER_GID}" builder \
 && useradd --uid "${BUILDER_UID}" --gid "${BUILDER_GID}" --create-home --shell /bin/bash builder \
 && install -d -o builder -g builder -m 0775 /cache /work \
 && . /opt/labelle/versions.env \
 && test "${LABELLE_BUILDER_CACHE_KEY}" = "v1-x86_64-linux-zig${ZIG_VERSION}-emsdk${EMSDK_VERSION}" \
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
