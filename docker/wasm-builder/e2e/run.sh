#!/usr/bin/env bash
# End-to-end check of the WASM builder image (used by
# .github/workflows/wasm-builder-image.yml; runnable on any Docker host):
# a fresh container, as the image's non-root user, with only the cache
# volume persisting, builds the fixture project in e2e/game for wasm
# (threads on: a threaded and a single-threaded fallback build), bundles it
# and smoke-tests both in headless Chromium.
#
# Usage: e2e/run.sh <image> <cache volume> <output dir> <label> [timings.md]
#   <output dir> receives dist/, smoke-threaded/, smoke-fallback/ and
#   phases.txt; <label> (cold, warm, …) prefixes the timing rows appended to
#   timings.md.
set -euo pipefail

image="${1:?usage: run.sh <image> <volume> <out> <label> [timings.md]}"
volume="${2:?}"
out="${3:?}"
label="${4:?}"
timings="${5:-/dev/null}"
here="$(cd "$(dirname "$0")" && pwd)"

rm -rf "$out"
mkdir -p "$out"
cp -R "$here/game" "$out/game"
# The container's user (UID 10001) must write the checkout, as GitLab's
# umask-0000 clone allows.
chmod -R a+rwX "$out"

docker run --rm \
  -v "$volume:/cache" \
  -v "$out:/out" \
  -v "$here:/e2e:ro" \
  -w /out/game \
  "$image" bash -euo pipefail -c '
    phase() { local name="$1"; shift; local t0; t0=$(date +%s); "$@"; echo "$name $(( $(date +%s) - t0 ))" >> /out/phases.txt; }
    : > /out/phases.txt
    phase preflight labelle-builder-check
    phase providers-fetch labelle providers fetch
    phase bundle labelle bundle --platform=wasm --optimize=ReleaseSafe --output /out/dist
    test -f /out/dist/game.wasm
    test -f /out/dist/threaded/game.wasm
    test -f /out/dist/threaded/labelle-threads.json
    py="$(labelle-builder-smoke-python /e2e/requirements.txt)"
    phase smoke-threaded "$py" /e2e/smoke.py --bundle /out/dist --isolated --output /out/smoke-threaded
    phase smoke-fallback "$py" /e2e/smoke.py --bundle /out/dist --output /out/smoke-fallback
    # Whole-container peak memory (cgroup v2), for the resource guidance.
    echo "memory-peak-bytes $(cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo unknown)" >> /out/phases.txt
    ls -la /out/dist /out/dist/threaded
  '

while read -r name value; do
  echo "| $label $name | $value |" >> "$timings"
done < "$out/phases.txt"
cat "$out/phases.txt"
# The project copy is large once built (.labelle/); keep only the outputs.
docker run --rm -v "$out:/out" "$image" rm -rf /out/game
