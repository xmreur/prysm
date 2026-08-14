#!/usr/bin/env bash
# Build-time script: cross-compile lyrebird into assets/native/pt/.
# Not invoked by the app at runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSET_ROOT="${ROOT}/assets/native/pt"
LYREBIRD_REPO="${LYREBIRD_REPO:-https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird.git}"
LYREBIRD_REF="${LYREBIRD_REF:-main}"

if ! command -v go >/dev/null 2>&1; then
  echo "error: go is required to build lyrebird" >&2
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  echo "error: git is required to fetch lyrebird sources" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

echo "Cloning lyrebird (${LYREBIRD_REF})..."
git clone --depth 1 --branch "${LYREBIRD_REF}" "${LYREBIRD_REPO}" "${WORKDIR}/lyrebird"

build_target() {
  local goos="$1"
  local goarch="$2"
  local outdir="$3"
  local outname="$4"

  mkdir -p "${outdir}"
  local outpath="${outdir}/${outname}"
  echo "Building lyrebird GOOS=${goos} GOARCH=${goarch} -> ${outpath}"

  (
    cd "${WORKDIR}/lyrebird"
    env CGO_ENABLED=0 GOOS="${goos}" GOARCH="${goarch}" \
      go build -trimpath -ldflags="-s -w" \
      -o "${outpath}" \
      ./cmd/lyrebird
  )

  if [[ "${goos}" != "windows" ]]; then
    chmod +x "${outpath}"
  fi
}

build_target linux amd64 "${ASSET_ROOT}/linux/amd64" lyrebird
build_target linux arm64 "${ASSET_ROOT}/linux/arm64" lyrebird
build_target darwin arm64 "${ASSET_ROOT}/macos" lyrebird
build_target windows amd64 "${ASSET_ROOT}/windows" lyrebird.exe

echo "Done. Lyrebird binaries written under ${ASSET_ROOT}"
