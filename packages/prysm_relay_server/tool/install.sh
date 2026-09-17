#!/bin/sh
# Install a prysm-relay release as a native systemd service
# (Debian / Raspberry Pi OS).
#
# Usage: install.sh [--dry-run] relay-vX.Y.Z
#
# Fetches the prebuilt Linux binary for this CPU (x64, arm64, arm) from the
# GitHub release, checks its SHA256, installs it to /usr/local/bin, ensures
# the prysm-relay system user and Tor exist, writes the hidden-service torrc
# (low-power profile, see the README "Tor runbook"), waits for the onion,
# initialises the data dir, installs and starts the systemd unit, then prints
# the pairing block (onion, fingerprint, token, link) plus the QR on stdout.
#
# --dry-run prints every step without touching the system or the network.
#
# macOS: this script only prints manual instructions (best effort, no
# installer); see the README section "Other operating systems".
set -eu

SERVICE=prysm-relay
RELAY_USER=prysm-relay
BIN_DST=/usr/local/bin/prysm-relay
DATA_DIR=/var/lib/prysm-relay
HS_DIR=/var/lib/tor/prysm-relay
TORRC=/etc/tor/torrc
TORRC_DROPIN=/etc/tor/torrc.d/prysm-relay.conf
ONION_TIMEOUT=180

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "-n" ]; then DRY_RUN=1; shift; fi
VER="${1:?usage: install.sh [--dry-run] relay-vX.Y.Z}"
case "$VER" in
  relay-v*) ;;
  *) echo "install.sh: want a tag like relay-vX.Y.Z, got '$VER'" >&2; exit 1 ;;
esac

log() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
run() { log "+ $*"; if [ "$DRY_RUN" -eq 0 ]; then "$@"; fi; }

# 0. CPU -> release arch. armv6 (Pi Zero W / Pi 1) is refused: Dart needs armv7+.
ARCH=
case "$(uname -m)" in
  x86_64) ARCH=x64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  armv7l) ARCH=arm ;;
  armv6l) die "unsupported CPU armv6l: Dart needs armv7+, arm64 or x86_64 (a Pi Zero W / Pi 1 cannot host a relay)" ;;
  *) die "unsupported CPU $(uname -m): Dart needs armv7+, arm64 or x86_64" ;;
esac

# macOS is manual steps only.
if [ "$(uname -s)" = "Darwin" ]; then
  cat <<'EOF'
macOS is best effort: no installer, do it by hand.
  1. brew install tor
  2. Build or fetch a macOS relay binary into /usr/local/bin/prysm-relay (chmod 0755).
  3. Copy tool/prysm-relay.plist to ~/Library/LaunchAgents/com.prysm.relay.plist (edit paths to taste).
  4. launchctl load ~/Library/LaunchAgents/com.prysm.relay.plist
See the README section "Other operating systems".
EOF
  exit 0
fi

if [ "$DRY_RUN" -eq 0 ]; then
  [ "$(id -u)" -eq 0 ] || die "run as root"
  command -v curl >/dev/null 2>&1 || die "curl not found; install it first"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum not found"
fi

BASE="https://github.com/xmreur/prysm/releases/download/$VER"
BIN="prysm-relay-$VER-linux-$ARCH"
SUMS="SHA256SUMS-$ARCH"

log "install.sh: installing $SERVICE $VER ($ARCH)"

# 1. Release binary + checksum into a temp dir.
if [ "$DRY_RUN" -eq 1 ]; then
  TMP=/tmp/prysm-relay-install
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT INT TERM
fi
run curl -fsSL -o "$TMP/$BIN" "$BASE/$BIN"
run curl -fsSL -o "$TMP/$SUMS" "$BASE/$SUMS"
run sh -c "cd '$TMP' && sha256sum -c --ignore-missing '$SUMS'"
run install -m 0755 "$TMP/$BIN" "$BIN_DST"

# 2. System user + data dir.
if id "$RELAY_USER" >/dev/null 2>&1; then
  log "user $RELAY_USER already exists"
else
  run useradd -r -s /usr/sbin/nologin -d "$DATA_DIR" -M "$RELAY_USER"
fi
run install -d -o "$RELAY_USER" -g "$RELAY_USER" -m 0700 "$DATA_DIR"

# 3. Tor via apt when available; otherwise the operator installs it.
if command -v tor >/dev/null 2>&1; then
  log "tor already installed"
elif command -v apt-get >/dev/null 2>&1; then
  run apt-get update
  run apt-get install -y tor
else
  log "no apt-get and no tor here: install tor yourself, then re-run install.sh"
fi
if [ "$DRY_RUN" -eq 0 ]; then
  command -v tor >/dev/null 2>&1 || die "tor is required but not installed"
fi

# 4. Hidden-service torrc, low-power profile (README "Tor runbook").
# Debian / Raspberry Pi OS torrc files may or may not end with a
# "%include .../torrc.d/" line depending on version, so: use a drop-in file
# when the include exists (uninstall is one rm), else keep a single marked
# block inside the main torrc.
torrc_body() {
  cat <<EOF
HiddenServiceDir $HS_DIR/
HiddenServicePort 80 127.0.0.1:8443
HiddenServiceEnableIntroDoSDefense 1
HiddenServiceMaxStreams 32
EOF
  if [ "$(nproc 2>/dev/null || echo 2)" = "1" ]; then echo "NumCPUs 1"; fi
  echo "Log notice file /var/log/tor/prysm-relay.log"
}
write_torrc() {
  if grep -Eq '^[[:space:]]*%include[[:space:]].*torrc\.d/' "$TORRC" 2>/dev/null; then
    torrc_body > "$TORRC_DROPIN"
    chmod 0644 "$TORRC_DROPIN"
    log "wrote $TORRC_DROPIN"
  else
    sed -i '/^# BEGIN prysm-relay$/,/^# END prysm-relay$/d' "$TORRC"
    {
      echo "# BEGIN prysm-relay (managed by install.sh; do not edit between the markers)"
      torrc_body
      echo "# END prysm-relay"
    } >> "$TORRC"
    log "appended marked block to $TORRC"
  fi
}
if [ "$DRY_RUN" -eq 1 ]; then
  log "+ write the torrc ($TORRC_DROPIN when %include exists, else a marked block in $TORRC):"
  torrc_body | sed 's/^/    /'
else
  write_torrc
  run tor -f "$TORRC" --verify-config
  run systemctl enable --now tor
  run systemctl reload tor
fi

# 5. Wait for Tor to publish the hostname.
if [ "$DRY_RUN" -eq 1 ]; then
  log "+ wait up to ${ONION_TIMEOUT}s for $HS_DIR/hostname"
  ONION="<onion>"
else
  i=0
  while [ "$i" -lt "$ONION_TIMEOUT" ] && [ ! -s "$HS_DIR/hostname" ]; do
    sleep 2
    i=$((i + 2))
  done
  [ -s "$HS_DIR/hostname" ] || die "no hostname after ${ONION_TIMEOUT}s; see /var/log/tor/prysm-relay.log"
  ONION="$(awk '{print $1}' "$HS_DIR/hostname")"
fi

# 6. Initialise once, then print the pairing block (`pair-link` mints the
# token it links, so a re-run hands out a fresh one).
if [ -f "$DATA_DIR/identity.json" ]; then
  log "relay already initialised"
else
  run su -s /bin/sh "$RELAY_USER" -c "$BIN_DST init --data-dir $DATA_DIR --onion $ONION"
fi
if [ "$DRY_RUN" -eq 1 ]; then
  log "+ su $RELAY_USER -c '$BIN_DST pair-link --config $DATA_DIR/config.json'"
else
  PAIR_OUT="$(su -s /bin/sh "$RELAY_USER" -c "$BIN_DST pair-link --config $DATA_DIR/config.json")" \
    || die "pair-link failed"
fi

# 7. Unit.
if [ "$DRY_RUN" -eq 1 ]; then
  log "+ curl -fsSL -o $TMP/prysm-relay.service $BASE/prysm-relay.service"
  log "+ install -m 0644 $TMP/prysm-relay.service /etc/systemd/system/prysm-relay.service"
else
  curl -fsSL -o "$TMP/prysm-relay.service" "$BASE/prysm-relay.service"
  run install -m 0644 "$TMP/prysm-relay.service" /etc/systemd/system/prysm-relay.service
fi
run systemctl daemon-reload
run systemctl enable --now "$SERVICE"

if [ "$DRY_RUN" -eq 1 ]; then
  log "onion: $ONION"
  log "fingerprint: <fingerprint>"
  log "token: <token>"
  log "link: <link>"
else
  printf '%s\n' "$PAIR_OUT"
fi
