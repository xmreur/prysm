#!/usr/bin/env bash
# Ensures the Share Extension can resolve receive_sharing_intent via SPM.
# Flutter symlinks plugins as receive_sharing_intent-<version> under
# Flutter/ephemeral/Packages/.packages/ when Swift Package Manager is enabled.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$ROOT/Flutter/ephemeral/Packages/.packages"
STABLE_LINK="$PKG_DIR/receive_sharing_intent"

if [[ ! -d "$PKG_DIR" ]]; then
  echo "error: $PKG_DIR not found." >&2
  echo "Run: flutter config --enable-swift-package-manager && flutter pub get" >&2
  exit 1
fi

shopt -s nullglob
matches=("$PKG_DIR"/receive_sharing_intent-*)
shopt -u nullglob

if [[ ${#matches[@]} -eq 0 ]]; then
  echo "error: no receive_sharing_intent-* package under $PKG_DIR" >&2
  exit 1
fi

target="$(basename "${matches[0]}")"
ln -sfn "$target" "$STABLE_LINK"
echo "Linked $STABLE_LINK -> $target"
