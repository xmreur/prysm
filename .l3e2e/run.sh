#!/usr/bin/env bash
# Prysm — L3 E2E runner: stages a repo copy and runs the harness in an
# isolated container. The live repo is never touched by the container:
# .dart_tool, package_config.json and native builds are regenerated inside
# the staging dir (.l3e2e/workdir), which persists between runs for caching.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=prysm-l3e2e
WORK=.l3e2e/workdir

# Safety gate for running the harness OUTSIDE the container. Inside the
# container the PID namespace IS the containment: TorManager's cleanup can
# `pkill -9 tor` without a pattern (lib/util/tor_service.dart:497) and can
# only see container PIDs. This check is not mirrored inside the container;
# it protects the host case, where that pattern-less kill would hit a real
# host tor.
if pgrep -x tor >/dev/null 2>&1; then
  if [ "${PRYSM_L3E2E_ALLOW_HOST_TOR:-}" != "1" ]; then
    echo "ERROR: a tor process is running on the HOST. The L3 harness's" >&2
    echo "victim TorManager runs a pattern-less 'pkill -9 tor'" >&2
    echo "(lib/util/tor_service.dart:497) whenever its targeted pkill finds" >&2
    echo "nothing — the normal case — and inside the container the PID" >&2
    echo "namespace contains it. On the host there is no containment, so" >&2
    echo "this run would kill that host tor process. Run the harness in the" >&2
    echo "container (this script's normal path), or set" >&2
    echo "PRYSM_L3E2E_ALLOW_HOST_TOR=1 to continue with a warning." >&2
    exit 1
  fi
  echo "WARNING: a tor process is running on the HOST; continuing because" >&2
  echo "PRYSM_L3E2E_ALLOW_HOST_TOR=1 is set. The pattern-less 'pkill -9 tor'" >&2
  echo "(lib/util/tor_service.dart:497) could kill it." >&2
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
