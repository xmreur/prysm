#!/bin/sh
# entrypoint.sh — bring up Tor and the relay inside the container.
#
# Runs as root: Tor refuses a HiddenServiceDir that is group- or
# world-readable, so both state dirs are created 0700 for the user Tor runs
# as (root here). Phases: verify the torrc, start Tor, wait for the onion,
# init (or reconcile) the relay config, print the pairing block
# (`pair-link`: onion, fingerprint, token, link, QR), serve.
# Prints the `pair-link` output for create_relay.sh to pick up from
# `docker logs`. The relay binds loopback only; Tor is its single ingress.
set -eu

DATA_DIR=/var/lib/prysm-relay
HS_DIR=/var/lib/tor/prysm-relay
TORRC=/etc/tor/torrc
CONFIG="$DATA_DIR/config.json"
TOR_LOG=/tmp/tor.log
PORT="${RELAY_PORT:-8443}"
TENANCY="${RELAY_TENANCY:-private}"
ADMISSION="${RELAY_ADMISSION:-invite}"
TTL="${RELAY_TOKEN_TTL_HOURS:-168}"
NO_QR="${RELAY_NO_QR:-0}"
QR_FLAG=""
[ "$NO_QR" = 1 ] && QR_FLAG="--no-qr"
ONION_TIMEOUT="${RELAY_ONION_TIMEOUT:-180}"
SERVE_PID=""
TOR_PID=""
TAIL_PID=""

export DART_VM_OPTIONS=--old_gen_heap_size=64

# The shell stays PID 1 and forwards TERM/INT to both children, so
# `docker stop` ends Tor and the relay together. A trap would not survive an
# exec of the relay, which would orphan Tor past SIGTERM — hence no exec.
shutdown() {
  kill -TERM "$SERVE_PID" "$TOR_PID" "$TAIL_PID" 2>/dev/null || true
  exit 143
}
trap shutdown TERM INT

case "$TENANCY" in private|public) ;; *) echo "error: RELAY_TENANCY must be private|public" >&2; exit 1 ;; esac
case "$ADMISSION" in invite|open|closed) ;; *) echo "error: RELAY_ADMISSION must be invite|open|closed" >&2; exit 1 ;; esac
case "$TTL" in ''|*[!0-9]*) echo "error: RELAY_TOKEN_TTL_HOURS must be a number of hours" >&2; exit 1 ;; esac
case "$ONION_TIMEOUT" in ''|*[!0-9]*) echo "error: RELAY_ONION_TIMEOUT must be a number of seconds" >&2; exit 1 ;; esac
case "$PORT" in ''|*[!0-9]*) echo "error: RELAY_PORT must be a number" >&2; exit 1 ;; esac

mkdir -p "$DATA_DIR" "$HS_DIR"
chmod 700 "$DATA_DIR" "$HS_DIR"

if [ "$PORT" != 8443 ]; then
  sed -i "s|^HiddenServicePort .*|HiddenServicePort 80 127.0.0.1:$PORT|" "$TORRC"
fi

# A torrc broken by a bad edit is the classic failure here: validate before
# starting, or the hostname file below never appears and the wait fails mutely.
tor -f "$TORRC" --verify-config
tor -f "$TORRC" >"$TOR_LOG" 2>&1 &
TOR_PID=$!
# Mirror Tor's log to container stdout; the file copy feeds the timeout report.
tail -F "$TOR_LOG" 2>/dev/null &
TAIL_PID=$!

i=0
while [ ! -f "$HS_DIR/hostname" ] && [ "$i" -lt "$ONION_TIMEOUT" ]; do
  if ! kill -0 "$TOR_PID" 2>/dev/null; then
    echo "error: tor died while bootstrapping; last lines of its log:" >&2
    tail -20 "$TOR_LOG" >&2 || true
    exit 1
  fi
  sleep 2
  i=$((i + 2))
done
if [ ! -f "$HS_DIR/hostname" ]; then
  echo "error: no onion after ${ONION_TIMEOUT}s; last lines of the tor log:" >&2
  tail -20 "$TOR_LOG" >&2 || true
  kill -TERM "$TOR_PID" 2>/dev/null || true
  exit 1
fi
ONION="$(tr -d ' \t\r\n' < "$HS_DIR/hostname")"

if [ ! -f "$CONFIG" ]; then
  INIT_OUT="$(prysm-relay init --data-dir "$DATA_DIR" --tenancy "$TENANCY" --port "$PORT" --onion "$ONION")"
  INIT_TOKEN="$(printf '%s\n' "$INIT_OUT" | awk '/setup token:/ {print $3}')"
  # init always writes admission: invite; anything else is a config edit.
  if [ "$ADMISSION" != invite ]; then
    sed -i "s|\"admission\": \"[^\"]*\"|\"admission\": \"$ADMISSION\"|" "$CONFIG"
  fi
  # pair-link prints onion/fingerprint/token/link plus the QR block, exactly
  # as create_relay.sh reads them from `docker logs`. Reusing init's token
  # mints nothing extra; a custom TTL still needs its own mint because init
  # always mints 168h.
  if [ "$TTL" != 168 ]; then
    PAIR_OUT="$(prysm-relay pair-link --config "$CONFIG" --ttl "$TTL" $QR_FLAG)"
  else
    PAIR_OUT="$(prysm-relay pair-link --config "$CONFIG" --token "$INIT_TOKEN" $QR_FLAG)"
  fi
  printf '%s\n' "$PAIR_OUT"
else
  # The onion Tor publishes is the truth: a recreated hs volume or a restored
  # data dir can leave config.json naming an address nobody answers, and the
  # stored port/admission can lag the torrc and init's default the same way.
  if ! grep -q "\"onion\": \"$ONION\"" "$CONFIG"; then
    sed -i "s|\"onion\": \"[^\"]*\"|\"onion\": \"$ONION\"|" "$CONFIG"
  fi
  if ! grep -qE "\"port\": $PORT([,}])" "$CONFIG"; then
    sed -i "s|\"port\": [0-9]*|\"port\": $PORT|" "$CONFIG"
  fi
  if ! grep -q "\"admission\": \"$ADMISSION\"" "$CONFIG"; then
    sed -i "s|\"admission\": \"[^\"]*\"|\"admission\": \"$ADMISSION\"|" "$CONFIG"
  fi
  prysm-relay pair-link --config "$CONFIG" --ttl "$TTL" $QR_FLAG
fi

prysm-relay serve --config "$CONFIG" &
SERVE_PID=$!
wait "$SERVE_PID"
CODE=$?
kill -TERM "$TOR_PID" "$TAIL_PID" 2>/dev/null || true
exit "$CODE"
