#!/usr/bin/env bash
# create_relay.sh — provision a Prysm Relay node inside a container.
#
# Compiles the relay binary, creates the container, installs Tor, writes a
# valid torrc, waits for the hidden service, initialises the relay and (unless
# --no-serve) starts it. Prints the three values pairing needs: onion,
# fingerprint, setup token.
#
# Idempotent: re-running against an existing container reuses it, keeps the
# existing identity, and mints a fresh token.
#
# Docs: packages/prysm_relay_server/tool/CREATE-RELAY.md

set -euo pipefail

NAME="prysm-relay"
IMAGE="ubuntu:24.04"
PORT="8443"
TENANCY="private"
DATA_DIR="/var/lib/prysm-relay"
RELAY_DIR="/opt/relay"
BINARY=""
TTL="168"
ONION_TIMEOUT="180"
SERVE_TIMEOUT="30"
PERSIST=0
SERVE=1
FORCE=0

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(dirname -- "$SCRIPT_DIR")"
TMP_BINARY=""

usage() {
  cat <<'USAGE'
usage: create_relay.sh [options]

  --name NAME        container name (default: prysm-relay)
  --image IMAGE      base image (default: ubuntu:24.04)
  --port PORT        relay port on container loopback (default: 8443)
  --tenancy WHICH    private (one owner) or public (default: private)
  --data-dir PATH    relay data dir inside the container (default: /var/lib/prysm-relay)
  --binary PATH      use a prebuilt relay binary instead of compiling
  --ttl HOURS        setup token lifetime (default: 168)
  --persist          keep identity and onion in docker volumes, so they
                     survive `docker rm`
  --no-serve         provision and initialise, but leave the relay stopped
  --force            recreate the container if it already exists
  --timeout SECONDS  how long to wait for the onion (default: 180)
  -h, --help         this text

Everything runs inside the container: the relay listens on loopback only and
Tor is its single ingress. Run this on a host that is NOT running the Prysm
app, or keep it in a container as it is here — the app's Tor cleanup issues a
broad `pkill -9 tor` and would kill a relay's Tor sharing its PID namespace.
USAGE
}

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [ -n "$TMP_BINARY" ] && [ -f "$TMP_BINARY" ]; then
    rm -f "$TMP_BINARY"
  fi
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    --name)     NAME="${2:?--name needs a value}"; shift 2 ;;
    --image)    IMAGE="${2:?--image needs a value}"; shift 2 ;;
    --port)     PORT="${2:?--port needs a value}"; shift 2 ;;
    --tenancy)  TENANCY="${2:?--tenancy needs a value}"; shift 2 ;;
    --data-dir) DATA_DIR="${2:?--data-dir needs a value}"; shift 2 ;;
    --binary)   BINARY="${2:?--binary needs a value}"; shift 2 ;;
    --ttl)      TTL="${2:?--ttl needs a value}"; shift 2 ;;
    --timeout)  ONION_TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    --persist)  PERSIST=1; shift ;;
    --no-serve) SERVE=0; shift ;;
    --force)    FORCE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "unknown option: $1 (try --help)" ;;
  esac
done

case "$TENANCY" in
  private|public) ;;
  *) die "--tenancy must be private or public" ;;
esac

command -v docker >/dev/null 2>&1 || die "docker not found in PATH"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon"

# ---------------------------------------------------------------- binary ----

if [ -n "$BINARY" ]; then
  [ -f "$BINARY" ] || die "no such binary: $BINARY"
  log "using prebuilt binary $BINARY"
else
  command -v dart >/dev/null 2>&1 ||
    die "dart not found in PATH; pass --binary PATH to skip compiling"
  [ -f "$PACKAGE_DIR/bin/prysm_relay.dart" ] ||
    die "cannot find the server package at $PACKAGE_DIR"
  TMP_BINARY="$(mktemp -t prysm-relay.XXXXXX)"
  BINARY="$TMP_BINARY"
  log "compiling the relay binary"
  ( cd "$PACKAGE_DIR" && dart pub get >/dev/null && \
    dart compile exe bin/prysm_relay.dart -o "$BINARY" >/dev/null )
  log "compiled $(du -h "$BINARY" | cut -f1) standalone binary"
fi

# ------------------------------------------------------------- container ----

if docker inspect "$NAME" >/dev/null 2>&1; then
  if [ "$FORCE" -eq 1 ]; then
    log "removing the existing container $NAME (--force)"
    docker rm -f "$NAME" >/dev/null
  else
    log "reusing the existing container $NAME"
  fi
fi

if ! docker inspect "$NAME" >/dev/null 2>&1; then
  log "creating the container $NAME from $IMAGE"
  if [ "$PERSIST" -eq 1 ]; then
    docker volume create "${NAME}-data" >/dev/null
    docker volume create "${NAME}-hs" >/dev/null
    docker run -d --name "$NAME" --entrypoint sleep \
      -v "${NAME}-data:${DATA_DIR}" \
      -v "${NAME}-hs:${RELAY_DIR}/hs" \
      "$IMAGE" infinity >/dev/null
  else
    docker run -d --name "$NAME" --entrypoint sleep "$IMAGE" infinity >/dev/null
  fi
fi

if [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" != "true" ]; then
  log "starting the container $NAME"
  docker start "$NAME" >/dev/null
fi

# -------------------------------------------------------------------- tor ----

if docker exec "$NAME" sh -c 'command -v tor' >/dev/null 2>&1; then
  log "tor already installed"
else
  log "installing tor (apt)"
  docker exec "$NAME" apt-get update -qq >/dev/null
  docker exec "$NAME" env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -qq --no-install-recommends tor ca-certificates >/dev/null
fi
log "tor $(docker exec "$NAME" tor --version | head -1 | awk '{print $3}')"

log "installing the relay binary"
docker cp "$BINARY" "$NAME:/usr/local/bin/prysm-relay" >/dev/null
docker exec "$NAME" chmod 0755 /usr/local/bin/prysm-relay

log "writing the tor configuration"
docker exec "$NAME" mkdir -p "$RELAY_DIR/tordata" "$RELAY_DIR/hs" "$DATA_DIR"
# Tor refuses a HiddenServiceDir or DataDirectory that is group/world
# readable, and the Debian package owns /var/lib/tor as debian-tor — which is
# why both live under $RELAY_DIR, owned by root, instead.
docker exec "$NAME" chmod 700 "$RELAY_DIR/tordata" "$RELAY_DIR/hs"
docker exec -i "$NAME" tee "$RELAY_DIR/torrc" >/dev/null <<TORRC
SocksPort 0
DataDirectory $RELAY_DIR/tordata
HiddenServiceDir $RELAY_DIR/hs
HiddenServiceVersion 3
HiddenServicePort 80 127.0.0.1:$PORT
HiddenServicePoWDefensesEnabled 1
HiddenServiceEnableIntroDoSDefense 1
Log notice file $RELAY_DIR/tor.log
TORRC

# A torrc broken by a bad paste is the classic failure here, and a detached
# `docker exec -d` swallows the parse error: validate before starting.
docker exec "$NAME" tor -f "$RELAY_DIR/torrc" --verify-config >/dev/null ||
  die "torrc rejected by tor; run: docker exec $NAME tor -f $RELAY_DIR/torrc --verify-config"
log "torrc validated"

if docker exec "$NAME" sh -c 'pgrep -x tor >/dev/null 2>&1'; then
  log "tor already running"
else
  log "starting tor"
  docker exec -d "$NAME" tor -f "$RELAY_DIR/torrc"
fi

log "waiting for the hidden service (up to ${ONION_TIMEOUT}s)"
ONION=""
waited=0
while [ "$waited" -lt "$ONION_TIMEOUT" ]; do
  ONION="$(docker exec "$NAME" sh -c "cat $RELAY_DIR/hs/hostname 2>/dev/null" | tr -d '\r\n')"
  if [ -n "$ONION" ]; then break; fi
  sleep 5
  waited=$((waited + 5))
done
if [ -z "$ONION" ]; then
  warn "no onion after ${ONION_TIMEOUT}s; last lines of tor.log:"
  docker exec "$NAME" sh -c "tail -20 $RELAY_DIR/tor.log" >&2 || true
  die "tor did not publish a hidden service"
fi
log "onion: $ONION"

# ------------------------------------------------------------------ relay ----

CONFIG="$DATA_DIR/config.json"
FINGERPRINT=""
TOKEN=""

if docker exec "$NAME" sh -c "test -f $CONFIG"; then
  log "relay already initialised, keeping its identity"
  # A recreated container with persisted volumes gets a new onion: the stored
  # config must follow, or `serve` would advertise an address nobody answers.
  if ! docker exec "$NAME" grep -q "\"onion\": \"$ONION\"" "$CONFIG"; then
    log "updating the onion in $CONFIG"
    docker exec "$NAME" sed -i "s|\"onion\": \"[^\"]*\"|\"onion\": \"$ONION\"|" "$CONFIG"
  fi
  FINGERPRINT="$(docker exec "$NAME" prysm-relay fingerprint --config "$CONFIG" | tr -d '\r\n')"
  TOKEN="$(docker exec "$NAME" prysm-relay token new --config "$CONFIG" --ttl "$TTL" | tr -d '\r\n')"
else
  log "initialising the relay (tenancy=$TENANCY port=$PORT)"
  INIT_OUT="$(docker exec "$NAME" prysm-relay init \
    --data-dir "$DATA_DIR" --tenancy "$TENANCY" --port "$PORT" --onion "$ONION")"
  printf '%s\n' "$INIT_OUT" | sed 's/^/    /'
  FINGERPRINT="$(printf '%s\n' "$INIT_OUT" | awk '/fingerprint:/ {print $2}')"
  TOKEN="$(printf '%s\n' "$INIT_OUT" | awk '/setup token:/ {print $3}')"
  if [ "$TTL" != "168" ]; then
    TOKEN="$(docker exec "$NAME" prysm-relay token new --config "$CONFIG" --ttl "$TTL" | tr -d '\r\n')"
  fi
fi

[ -n "$FINGERPRINT" ] || die "could not read the relay fingerprint"
[ -n "$TOKEN" ] || die "could not obtain a setup token"

# ------------------------------------------------------------------ serve ----

SERVE_LOG="$DATA_DIR/serve.log"
if [ "$SERVE" -eq 0 ]; then
  log "leaving the relay stopped (--no-serve)"
elif docker exec "$NAME" sh -c 'pgrep -f "prysm-relay serve" >/dev/null 2>&1'; then
  log "relay already serving"
else
  log "starting the relay"
  docker exec -d "$NAME" sh -c \
    "prysm-relay serve --config $CONFIG >> $SERVE_LOG 2>&1"
  waited=0
  while [ "$waited" -lt "$SERVE_TIMEOUT" ]; do
    if docker exec "$NAME" sh -c "grep -q 'listening on' $SERVE_LOG 2>/dev/null"; then
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done
  if ! docker exec "$NAME" sh -c "grep -q 'listening on' $SERVE_LOG 2>/dev/null"; then
    warn "no 'listening on' line after ${SERVE_TIMEOUT}s; last lines of $SERVE_LOG:"
    docker exec "$NAME" sh -c "tail -20 $SERVE_LOG" >&2 || true
    die "the relay did not start"
  fi
  log "serving on 127.0.0.1:$PORT behind Tor"
fi

# ---------------------------------------------------------------- summary ----

cat <<SUMMARY

  Relay ready. Pair from the app: Settings -> Network -> Relay

    Relay address   $ONION
    Setup token     $TOKEN
    Fingerprint     $FINGERPRINT

  Paste the address and the token, tap "Read relay info", and check that the
  Fingerprint on screen matches the one above before pairing. The first
  request to a fresh onion can exceed the app's 30 s budget (descriptor
  propagation): if it times out, leave the screen and open it again.

  The token is single use. Mint another with:
    docker exec $NAME prysm-relay token new --config $CONFIG --ttl 72

  Operate it:
    docker exec $NAME prysm-relay status --config $CONFIG
    docker exec $NAME tail -f $SERVE_LOG
    docker exec $NAME tail -20 $RELAY_DIR/tor.log

  Tear it down:
    docker rm -f $NAME
SUMMARY

if [ "$PERSIST" -eq 1 ]; then
  cat <<PERSISTED
    docker volume rm ${NAME}-data ${NAME}-hs   # destroys identity and onion
PERSISTED
else
  cat <<EPHEMERAL

  Not persisted: the relay identity ($DATA_DIR/identity.json) and the onion
  key ($RELAY_DIR/hs) live in the container's writable layer and die with it,
  which invalidates every Contract signed against them. Re-run with --persist
  to keep both in docker volumes.
EPHEMERAL
fi
