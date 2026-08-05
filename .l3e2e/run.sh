#!/usr/bin/env bash
# Prysm — L3 E2E runner: stages a repo copy and runs the harness in an
# isolated container. The live repo is never touched by the container:
# .dart_tool, package_config.json and native builds are regenerated inside
# the staging dir (.l3e2e/workdir), which persists between runs for caching.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=prysm-l3e2e
WORK=.l3e2e/workdir

# Safety gate mirrored inside the container, but cheap to check here too:
# the harness's victim TorManager will `pkill -9 tor` without a pattern if
# its targeted kill finds nothing (lib/util/tor_service.dart:488-505).
if pgrep -x tor >/dev/null 2>&1; then
  echo "WARNING: a tor process is running on the HOST. The container cannot" >&2
  echo "kill it (PID namespace), but abort if this surprises you." >&2
fi

mkdir -p "$WORK"
rsync -a --delete \
  --exclude '.dart_tool' \
  lib test assets pubspec.yaml pubspec.lock analysis_options.yaml \
  tor_executable packages "$WORK"/

docker build -f .l3e2e/Containerfile -t "$IMAGE" .l3e2e

# --network bridge: outbound internet only (Tor bootstrap needs it).
# No host ports published: victim/attacker talk over the real Tor network.
exec docker run --rm \
  -e PRYSM_E2E=1 \
  -v "$PWD/$WORK":/work \
  -v "$HOME/.pub-cache":"$HOME/.pub-cache":rw \
  -e PUB_CACHE="$HOME/.pub-cache" \
  "$IMAGE" bash -lc '
    set -e
    flutter pub get
    flutter test test/headless_inbound_e2e_test.dart --timeout=45m --reporter expanded
  '
