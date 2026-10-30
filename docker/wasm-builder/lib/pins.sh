# Sourced (bash) by the Dockerfile's RUN steps: versions.env plus two helpers.
#   pin NAME           value of NAME_<TARGETARCH> (amd64 / arm64), or fail
#   fetch URL SHA DEST download URL to DEST and check its sha256, or fail
# shellcheck shell=bash
# shellcheck source=../versions.env
. /opt/labelle/versions.env

: "${TARGETARCH:?TARGETARCH is not set (build with BuildKit)}"
case "$TARGETARCH" in
  amd64|arm64) ;;
  *) echo "unsupported TARGETARCH '$TARGETARCH' (amd64 or arm64)" >&2; exit 1 ;;
esac

pin() {
  local name="$1_${TARGETARCH}"
  if [ -z "${!name:-}" ]; then
    echo "versions.env has no $name" >&2
    return 1
  fi
  printf '%s' "${!name}"
}

fetch() {
  local url="$1" sha="$2" dest="$3"
  curl -fsSL --retry 3 -o "$dest" "$url"
  echo "${sha}  ${dest}" | sha256sum -c -
}
