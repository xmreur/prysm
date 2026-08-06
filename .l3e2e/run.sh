#!/usr/bin/env bash
# Prysm — L3 E2E runner: stages a repo copy and runs the harness in an
# isolated container. The live repo is never touched by the container:
# .dart_tool, package_config.json and native builds are regenerated inside
# the staging dir (.l3e2e/workdir), which persists between runs for caching.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=prysm-l3e2e
WORK=.l3e2e/workdir

# Host-tor safety lives in the harness, not here:
# test/headless_inbound_e2e_test.dart refuses to start while a tor process
# is running on the HOST (override: PRYSM_L3E2E_ALLOW_HOST_TOR=1). This
# script's container path is always safe: the container's PID namespace IS
# the containment — TorManager's cleanup can `pkill -9 tor` without a
# pattern (lib/util/tor_service.dart:497) and can only see container PIDs,
# and the image starts no tor of its own.

# The image remaps its 'ubuntu' user to the host uid/gid (HOST_UID/HOST_GID
# build args, below) so bind mounts stay writable. uid 0 cannot be served
# that way — the image's root ids are reserved — so abort early instead of
# building a subtly broken image.
if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: refusing to run as root (uid 0): the container remaps its" >&2
  echo "'ubuntu' user to the host uid, and uid 0 is reserved for root —" >&2
  echo "the resulting image would be broken. Run the L3 E2E harness as a" >&2
  echo "non-root user." >&2
  exit 1
fi

mkdir -p "$WORK"
# Create the host-side pub cache before mounting it: if the docker daemon
# created it, it would be root:root 755 and the container user (remapped
# to the host uid via HOST_UID/HOST_GID) could not write to it (flutter
# pub get would fail).
mkdir -p "$HOME/.pub-cache"
rsync -a --delete \
  --exclude '.dart_tool' \
  lib test assets pubspec.yaml pubspec.lock analysis_options.yaml \
  tor_executable packages "$WORK"/

docker build -f .l3e2e/Containerfile -t "$IMAGE" \
  --build-arg HOST_UID="$(id -u)" \
  --build-arg HOST_GID="$(id -g)" \
  .l3e2e

# --network bridge: outbound internet only (Tor bootstrap needs it).
# No host ports published: victim/attacker talk over the real Tor network.
exec docker run --rm \
  -e PRYSM_E2E=1 \
  -v "$PWD/$WORK":/work \
  -v "$HOME/.pub-cache":/home/ubuntu/.pub-cache:rw \
  "$IMAGE" bash -lc '
    set -e
    flutter pub get
    flutter test test/headless_inbound_e2e_test.dart --timeout=45m --reporter expanded
  '
