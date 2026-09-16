#!/usr/bin/env bash
# Thin wrapper around `docker run` (flags pre-answer, `-y` skips); the image
# does the real work, see tool/entrypoint.sh. No Dart SDK, nothing compiled.
#
# > Source of truth for the wire is the protocol spec; this page points, it does not repeat.
# Docs: packages/prysm_relay_server/tool/CREATE-RELAY.md
NAME="prysm-relay"
IMAGE="ghcr.io/xmreur/prysm-relay:latest"
BUILD=0
PORT="8443"
TENANCY="private"
ADMISSION="invite"
TTL="168"
TIMEOUT="180"
FORCE=0
EPHEMERAL=0
NO_QR=0
INTERACTIVE="auto"
DRY_RUN=0

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(dirname -- "$SCRIPT_DIR")"
CONFIG="/var/lib/prysm-relay/config.json"
usage() {
cat <<'USAGE'
usage: create_relay.sh [options]

  --name NAME        container name (default: prysm-relay)
  --image IMAGE      relay image (default: ghcr.io/xmreur/prysm-relay:latest)
  --build            build the image locally instead of pulling it
  --port PORT        relay port on the container loopback (default: 8443)
  --tenancy WHICH    private (one owner) | public (default: private)
  --admission WHICH  invite (single-use tokens) | open | closed (default: invite)
  --ttl HOURS        setup token lifetime (default: 168)
  --timeout SECONDS  how long to wait for the onion (default: 180)
  --ephemeral        no volumes: identity and onion die with the container
  --force            recreate an existing container (volumes stay)
  --no-qr            print the pairing link without the QR block
  -y, --yes          never ask: take the flags and the defaults
  -n, --dry-run      print the plan and exit
  -h, --help         this text

  create_relay.sh -y                               # private relay, defaults
  create_relay.sh -y --build --name relay-b        # local build, second relay
  create_relay.sh -y --name relay-b --port 9443    # second relay beside the first
USAGE
}

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name)      NAME="${2:?--name needs a value}"; shift 2 ;;
    --image)     IMAGE="${2:?--image needs a value}"; shift 2 ;;
    --build)     BUILD=1; shift ;;
    --port)      PORT="${2:?--port needs a value}"; shift 2 ;;
    --tenancy)   TENANCY="${2:?--tenancy needs a value}"; shift 2 ;;
    --admission) ADMISSION="${2:?--admission needs a value}"; shift 2 ;;
    --ttl)       TTL="${2:?--ttl needs a value}"; shift 2 ;;
    --timeout)   TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    --ephemeral) EPHEMERAL=1; shift ;;
    --force)     FORCE=1; shift ;;
    --no-qr)     NO_QR=1; shift ;;
    -y|--yes|--non-interactive) INTERACTIVE="no"; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown option: $1 (try --help)" ;;
  esac
done
QR_FLAG=""
[ "$NO_QR" = 1 ] && QR_FLAG="--no-qr"
LINK=""
QR_BLOCK=""
[ "$INTERACTIVE" = auto ] && { if [ -t 0 ]; then INTERACTIVE=yes; else INTERACTIVE=no; fi; }

ask() { # VAR prompt — Enter keeps the current value.
  local _var="$1" _prompt="$2" _ans cur; cur="${!_var}"
  printf '  %s [%s]: ' "$_prompt" "$cur"; IFS= read -r _ans || true
  [ -n "$_ans" ] && printf -v "$_var" '%s' "$_ans"
}
ask_opt() { # VAR prompt opt... — a number or the word, Enter keeps.
  local _var="$1"; shift; local _prompt="$1"; shift; local cur="${!_var}" _ans i _o
  echo "  $_prompt"; i=0
  for _o in "$@"; do i=$((i+1)); [ "$_o" = "$cur" ] && echo "    $i) $_o  (current)" || echo "    $i) $_o"; done
  printf '  choice [%s]: ' "$cur"; IFS= read -r _ans || true
  [ -z "$_ans" ] && return 0
  for _o in "$@"; do [ "$_ans" = "$_o" ] && { printf -v "$_var" '%s' "$_o"; return 0; }; done
  case "$_ans" in *[!0-9]*) warn "not a choice, keeping $cur"; return 0 ;; esac
  i=0; for _o in "$@"; do i=$((i+1)); [ "$i" = "$_ans" ] && { printf -v "$_var" '%s' "$_o"; return 0; }; done; warn "out of range, keeping $cur"
}
ask_yn() { # VAR prompt — VAR is 0/1.
  local _var="$1" _prompt="$2" _ans cur; [ "${!_var}" = 1 ] && cur=y || cur=n
  printf '  %s [%s]: ' "$_prompt" "$cur"; IFS= read -r _ans || true
  case "$_ans" in y|Y|yes) printf -v "$_var" '%s' 1 ;; n|N|no) printf -v "$_var" '%s' 0 ;; '') ;; *) warn "answer y or n, keeping $cur" ;; esac
}

if [ "$INTERACTIVE" = yes ]; then
  echo "Prysm Relay — provisioning (Enter keeps the bracketed value)"; echo
  ask NAME "container name"
  ask_opt TENANCY "who may hold a Contract on this relay?" private public
  ask_opt ADMISSION "how are new Contracts admitted?" invite open closed
  ask_yn EPHEMERAL "run without volumes (identity dies with the container)?"
  ask PORT "relay port on the container loopback"
  ask TTL "setup token lifetime, hours"
  [ "$BUILD" = 0 ] && ask IMAGE "relay image"
  echo
fi

case "$TENANCY" in private|public) ;; *) die "--tenancy must be private|public" ;; esac
case "$ADMISSION" in invite|open|closed) ;; *) die "--admission must be invite|open|closed" ;; esac
case "$PORT" in ''|*[!0-9]*) die "--port must be a number" ;; esac
case "$TTL" in ''|*[!0-9]*) die "--ttl must be a number of hours" ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be a number of seconds" ;; esac
[ -n "$NAME" ] || die "the container name cannot be empty"

DATA_VOL="$NAME-data"; HS_VOL="$NAME-hs"
[ "$EPHEMERAL" = 1 ] && PERSIST_TXT="no (identity and onion die with the container)" \
  || PERSIST_TXT="yes ($DATA_VOL, $HS_VOL)"

cat <<PLAN
plan
  container   $NAME  (image: $([ "$BUILD" = 1 ] && echo "local build" || echo "$IMAGE"))
  tenancy     $TENANCY, admission $ADMISSION, port $PORT, token TTL ${TTL}h
  persist     $PERSIST_TXT
PLAN
[ "$DRY_RUN" = 1 ] && exit 0
if [ "$INTERACTIVE" = yes ]; then printf 'proceed? [Y/n]: '; IFS= read -r _ans || true
  case "$_ans" in n|N|no) die "aborted" ;; esac; fi
echo

command -v docker >/dev/null 2>&1 || die "docker not found in PATH"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon"

if [ "$BUILD" = 1 ]; then
  IMAGE="prysm-relay:local"
  log "building $IMAGE from $PACKAGE_DIR/Dockerfile"
  docker build -f "$PACKAGE_DIR/Dockerfile" -t "$IMAGE" "$(dirname -- "$PACKAGE_DIR")"
fi

if docker inspect "$NAME" >/dev/null 2>&1; then
  if [ "$FORCE" = 1 ]; then
    log "removing the existing container (volumes stay)"
    docker rm -f "$NAME" >/dev/null
  elif [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = true ]; then
    log "reusing the running container, minting a fresh token"
    ONION="$(docker logs "$NAME" 2>&1 | awk '/^onion: / {v=$2} END {print v}')"
    # shellcheck disable=SC2086
    PAIR_OUT="$(docker exec "$NAME" prysm-relay pair-link --config "$CONFIG" --ttl "$TTL" $QR_FLAG)"
    FINGERPRINT="$(printf '%s\n' "$PAIR_OUT" | awk '/^fingerprint: / {v=$2} END {print v}')"
    TOKEN="$(printf '%s\n' "$PAIR_OUT" | awk '/^token: / {v=$2} END {print v}')"
    LINK="$(printf '%s\n' "$PAIR_OUT" | awk '/^link: / {v=$2} END {print v}')"
    QR_BLOCK="$(printf '%s\n' "$PAIR_OUT" | awk '/^link: /{cap=1; next} cap==1{cap=2; next} cap==2{print}')"
    [ -n "$ONION" ] && [ -n "$TOKEN" ] && [ -n "$LINK" ] || die "could not read onion/token/link; see: docker logs $NAME"
  else
    log "starting the existing container"
    docker start "$NAME" >/dev/null
  fi
fi

if ! docker inspect "$NAME" >/dev/null 2>&1; then
  [ "$EPHEMERAL" = 1 ] && warn "ephemeral: the relay identity and the onion die with the container; every peer must pair again"
  log "creating the container from $IMAGE"
  [ "$EPHEMERAL" = 0 ] && VOL_ARGS="-v $DATA_VOL:/var/lib/prysm-relay -v $HS_VOL:/var/lib/tor/prysm-relay" || VOL_ARGS=""
  # --restart unless-stopped: a relay is an always-on service, so it must come
  # back after a host reboot or a docker daemon restart. It is the container
  # equivalent of the systemd unit's Restart=on-failure + enable; without it a
  # rebooted host leaves the relay down silently. `docker stop` still keeps it
  # stopped, so deliberate shutdowns are not fought.
  # shellcheck disable=SC2086
  docker run -d --name "$NAME" --restart unless-stopped \
    -e RELAY_TENANCY="$TENANCY" -e RELAY_ADMISSION="$ADMISSION" \
    -e RELAY_TOKEN_TTL_HOURS="$TTL" -e RELAY_PORT="$PORT" -e RELAY_ONION_TIMEOUT="$TIMEOUT" \
    -e RELAY_NO_QR="$NO_QR" \
    $VOL_ARGS "$IMAGE" >/dev/null
fi

# The entrypoint prints onion/fingerprint/token/link/QR before `listening
# on`, so one wait covers Tor bootstrap plus relay start: the onion timeout
# plus headroom.
log "waiting for the relay (up to $((TIMEOUT + 120))s)"
waited=0
while ! docker logs "$NAME" 2>&1 | grep -q 'listening on'; do
  [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = true ] || { docker logs "$NAME" 2>&1 | tail -20 >&2; die "the container stopped; log tail above"; }
  [ "$waited" -ge "$((TIMEOUT + 120))" ] && { docker logs "$NAME" 2>&1 | tail -20 >&2; die "the relay did not start; log tail above"; }
  sleep 3; waited=$((waited + 3))
done
ONION="${ONION:-$(docker logs "$NAME" 2>&1 | awk '/^onion: / {v=$2} END {print v}')}"
FINGERPRINT="${FINGERPRINT:-$(docker logs "$NAME" 2>&1 | awk '/^fingerprint: / {v=$2} END {print v}')}"
TOKEN="${TOKEN:-$(docker logs "$NAME" 2>&1 | awk '/^token: / {v=$2} END {print v}')}"
LINK="${LINK:-$(docker logs "$NAME" 2>&1 | awk '/^link: / {v=$2} END {print v}')}"
# The QR block is the last `link:` line's tail: the blank line after it, then
# rows of nothing but block glyphs and spaces (a relay or Tor log line always
# carries alphanumerics, so the first one ends the block).
if [ -z "$QR_BLOCK" ]; then
  QR_BLOCK="$(docker logs "$NAME" 2>&1 | awk '
    /^link: / {qr=""; cap=1; next}
    cap == 1 {cap=2; next}
    cap == 2 && $0 == "" {cap=0; next}
    cap == 2 && /^[^A-Za-z0-9]*$/ {qr = qr $0 "\n"; next}
    {cap=0}
    END {printf "%s", qr}')"
fi
[ -n "$ONION" ] && [ -n "$FINGERPRINT" ] && [ -n "$TOKEN" ] && [ -n "$LINK" ] || die "could not read onion/fingerprint/token/link; see: docker logs $NAME"

cat <<SUMMARY

  Relay ready. Pair from the app: Settings -> Network -> Relay

    Pairing link    $LINK
    Fingerprint     $FINGERPRINT

SUMMARY
if [ -n "$QR_BLOCK" ]; then printf '%s\n' "$QR_BLOCK"; fi
cat <<SUMMARY
  1. Paste the link above (or scan the QR): the address and the token
     fill in on their own.
  2. Tap "Read relay info": the app checks the relay's fingerprint against
     the one in the link and shows it. Then pair.

  The token is single use. Mint another pairing link with:
    docker exec $NAME prysm-relay pair-link --config $CONFIG --ttl 72

  Operate it:
    docker exec $NAME prysm-relay status --config $CONFIG
    docker logs $NAME

  Tear it down:
    docker rm -f $NAME
SUMMARY
[ "$EPHEMERAL" = 1 ] && echo "    docker rm -v $NAME   # also drop the anonymous volumes" \
  || echo "    docker volume rm $DATA_VOL $HS_VOL   # destroys identity and onion"
