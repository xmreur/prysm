#!/usr/bin/env bash
# create_relay.sh — provision a Prysm Relay node inside a container.
#
# Interactive by default on a terminal: it asks for every choice, pre-filled
# with the current value, so Enter accepts and typing overrides. Flags act as
# pre-answers, `--yes` skips the questions, and `--dry-run` prints the plan
# without touching anything.
#
# Compiles the relay binary, creates the container, installs Tor, writes a
# valid torrc, waits for the hidden service, initialises the relay and (unless
# you say otherwise) starts it. Prints the three values pairing needs: onion,
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
ADMISSION="invite"
DATA_DIR="/var/lib/prysm-relay"
RELAY_DIR="/opt/relay"
BINARY=""
TTL="168"
ONION_TIMEOUT="180"
SERVE_TIMEOUT="30"
PERSIST=0
SERVE=1
FORCE=0

INTERACTIVE="auto"   # auto | yes | no
DRY_RUN=0

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(dirname -- "$SCRIPT_DIR")"
TMP_BINARY=""

usage() {
  cat <<'USAGE'
usage: create_relay.sh [options]

Run it with no options on a terminal and it walks you through every choice.

  --name NAME        container name (default: prysm-relay)
  --image IMAGE      base image (default: ubuntu:24.04)
  --port PORT        relay port on container loopback (default: 8443)
  --tenancy WHICH    private (one owner) | public (default: private)
  --admission WHICH  invite (single-use tokens) | open | closed (default: invite)
  --data-dir PATH    relay data dir inside the container (default: /var/lib/prysm-relay)
  --binary PATH      use a prebuilt relay binary instead of compiling
  --ttl HOURS        setup token lifetime (default: 168)
  --timeout SECONDS  how long to wait for the onion (default: 180)
  --persist          keep identity and onion in docker volumes, so they
                     survive `docker rm`
  --no-persist       opposite of --persist (default)
  --serve            start the relay once provisioned (default)
  --no-serve         provision and initialise, but never start or stop `serve`
  --force            recreate the container if it already exists
  -i, --interactive  ask, even when not on a terminal
  -y, --yes          never ask: take the flags and the defaults
  -n, --dry-run      print the plan and exit
  -h, --help         this text

Everything runs inside the container: the relay listens on loopback only and
Tor is its single ingress. Keep it in a container (or on another machine) —
the Prysm app's Tor cleanup issues a broad `pkill -9 tor` and would kill a
relay's Tor sharing its PID namespace.

examples
  create_relay.sh                                  # ask me everything
  create_relay.sh -y                               # private relay, defaults
  create_relay.sh -y --persist --tenancy public    # public, survives docker rm
  create_relay.sh -y --binary /tmp/prysm-relay     # skip dart, reuse a build
  create_relay.sh --dry-run                        # show the plan only
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

# ------------------------------------------------------------------ flags ----

while [ $# -gt 0 ]; do
  case "$1" in
    --name)        NAME="${2:?--name needs a value}"; shift 2 ;;
    --image)       IMAGE="${2:?--image needs a value}"; shift 2 ;;
    --port)        PORT="${2:?--port needs a value}"; shift 2 ;;
    --tenancy)     TENANCY="${2:?--tenancy needs a value}"; shift 2 ;;
    --admission)   ADMISSION="${2:?--admission needs a value}"; shift 2 ;;
    --data-dir)    DATA_DIR="${2:?--data-dir needs a value}"; shift 2 ;;
    --binary)      BINARY="${2:?--binary needs a value}"; shift 2 ;;
    --ttl)         TTL="${2:?--ttl needs a value}"; shift 2 ;;
    --timeout)     ONION_TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    --persist)     PERSIST=1; shift ;;
    --no-persist)  PERSIST=0; shift ;;
    --serve)       SERVE=1; shift ;;
    --no-serve)    SERVE=0; shift ;;
    --force)       FORCE=1; shift ;;
    -i|--interactive)          INTERACTIVE="yes"; shift ;;
    -y|--yes|--non-interactive) INTERACTIVE="no"; shift ;;
    -n|--dry-run)  DRY_RUN=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown option: $1 (try --help)" ;;
  esac
done

if [ "$INTERACTIVE" = "auto" ]; then
  if [ -t 0 ]; then INTERACTIVE="yes"; else INTERACTIVE="no"; fi
fi

# -------------------------------------------------------------- questions ----

# ask VAR "prompt" — Enter keeps the current value of VAR.
ask() {
  local var="$1" prompt="$2" current reply
  current="${!var}"
  read -r -p "  $prompt [$current]: " reply || reply=""
  if [ -n "$reply" ]; then printf -v "$var" '%s' "$reply"; fi
}

# ask_opt VAR "prompt" opt1 opt2 … — numbered menu, Enter keeps the current.
ask_opt() {
  local var="$1" prompt="$2"; shift 2
  local -a opts=("$@")
  local current="${!var}" reply i
  printf '  %s\n' "$prompt"
  for i in "${!opts[@]}"; do
    if [ "${opts[$i]}" = "$current" ]; then
      printf '    %d) %s  (current)\n' "$((i + 1))" "${opts[$i]}"
    else
      printf '    %d) %s\n' "$((i + 1))" "${opts[$i]}"
    fi
  done
  read -r -p "  choice [$current]: " reply || reply=""
  [ -n "$reply" ] || return 0
  case "$reply" in
    ''|*[!0-9]*)
      ;;
    *)
      if [ "$reply" -ge 1 ] && [ "$reply" -le "${#opts[@]}" ]; then
        printf -v "$var" '%s' "${opts[$((reply - 1))]}"
        return 0
      fi
      ;;
  esac
  for i in "${!opts[@]}"; do
    if [ "$reply" = "${opts[$i]}" ]; then
      printf -v "$var" '%s' "$reply"
      return 0
    fi
  done
  warn "not one of the choices: $reply — keeping $current"
}

# ask_yn VAR "prompt" — VAR is 0/1.
ask_yn() {
  local var="$1" prompt="$2" current reply hint
  current="${!var}"
  if [ "$current" -eq 1 ]; then hint="Y/n"; else hint="y/N"; fi
  read -r -p "  $prompt [$hint]: " reply || reply=""
  case "$reply" in
    y|Y|yes|YES|s|S|si|SI) printf -v "$var" '%s' 1 ;;
    n|N|no|NO)             printf -v "$var" '%s' 0 ;;
    "")                    ;;
    *) warn "answer y or n — keeping the current choice" ;;
  esac
}

if [ "$INTERACTIVE" = "yes" ]; then
  printf '\n\033[1mPrysm Relay — provisioning\033[0m\n'
  printf 'Enter keeps the value in brackets.\n\n'

  ask NAME "container name"
  ask_opt TENANCY "who may hold a Contract on this relay?" private public
  ask_opt ADMISSION "how are new Contracts admitted?" invite open closed
  ask PORT "relay port on the container's loopback"
  ask_yn PERSIST "keep identity and onion in docker volumes (survive docker rm)?"
  ask_yn SERVE "start serving once provisioned?"

  ADVANCED=0
  printf '\n'
  ask_yn ADVANCED "change the advanced settings (image, data dir, binary, timeouts)?"
  if [ "$ADVANCED" -eq 1 ]; then
    printf '\n'
    ask IMAGE "base image"
    ask DATA_DIR "relay data dir inside the container"
    ask BINARY "prebuilt relay binary (empty = compile it here)"
    ask TTL "setup token lifetime, in hours"
    ask ONION_TIMEOUT "seconds to wait for the onion"
  fi
  printf '\n'
fi

# ------------------------------------------------------------ validation ----

case "$TENANCY" in
  private|public) ;;
  *) die "--tenancy must be private or public" ;;
esac
case "$ADMISSION" in
  invite|open|closed) ;;
  *) die "--admission must be invite, open or closed" ;;
esac
case "$PORT" in
  ''|*[!0-9]*) die "--port must be a number" ;;
esac
case "$TTL" in
  ''|*[!0-9]*) die "--ttl must be a number of hours" ;;
esac
case "$ONION_TIMEOUT" in
  ''|*[!0-9]*) die "--timeout must be a number of seconds" ;;
esac
[ -n "$NAME" ] || die "the container name cannot be empty"
[ -n "$DATA_DIR" ] || die "the data dir cannot be empty"
if [ -n "$BINARY" ] && [ ! -f "$BINARY" ]; then
  die "no such binary: $BINARY"
fi

CONFIG="$DATA_DIR/config.json"
SERVE_LOG="$DATA_DIR/serve.log"

plan() {
  cat <<PLAN
  container      $NAME  (image $IMAGE)
  tenancy        $TENANCY
  admission      $ADMISSION
  relay port     127.0.0.1:$PORT  (Tor is the only ingress)
  data dir       $DATA_DIR
  tor dir        $RELAY_DIR
  binary         $([ -n "$BINARY" ] && echo "$BINARY" || echo "compiled from $PACKAGE_DIR")
  token ttl      ${TTL}h
  onion wait     up to ${ONION_TIMEOUT}s
  persistence    $([ "$PERSIST" -eq 1 ] && echo "docker volumes ${NAME}-data, ${NAME}-hs" || echo "none: identity and onion die with the container")
  after provisioning  $([ "$SERVE" -eq 1 ] && echo "start serving" || echo "leave stopped")
  existing container  $([ "$FORCE" -eq 1 ] && echo "recreate (--force)" || echo "reuse")
PLAN
}

printf '\033[1mplan\033[0m\n'
plan

if [ "$DRY_RUN" -eq 1 ]; then
  printf '\ndry run: nothing was created.\n'
  exit 0
fi

if [ "$INTERACTIVE" = "yes" ]; then
  GO=1
  printf '\n'
  ask_yn GO "go ahead?"
  [ "$GO" -eq 1 ] || { printf 'aborted, nothing was created.\n'; exit 0; }
fi
printf '\n'

command -v docker >/dev/null 2>&1 || die "docker not found in PATH"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon"

# ---------------------------------------------------------------- binary ----

if [ -n "$BINARY" ]; then
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
docker exec -i "$NAME" tee "$RELAY_DIR/torrc.new" >/dev/null <<TORRC
SocksPort 0
DataDirectory $RELAY_DIR/tordata
HiddenServiceDir $RELAY_DIR/hs
HiddenServiceVersion 3
HiddenServicePort 80 127.0.0.1:$PORT
HiddenServicePoWDefensesEnabled 1
HiddenServiceEnableIntroDoSDefense 1
Log notice file $RELAY_DIR/tor.log
TORRC

# A running tor keeps serving the torrc it started with, so a changed one
# (typically a new --port) has to be handed to it explicitly. Compare with
# the shell alone: no assumption about cmp/diff being in the image.
TORRC_CHANGED=0
if docker exec "$NAME" sh -c \
     "[ -f $RELAY_DIR/torrc ] && [ \"\$(cat $RELAY_DIR/torrc)\" = \"\$(cat $RELAY_DIR/torrc.new)\" ]"; then
  docker exec "$NAME" rm -f "$RELAY_DIR/torrc.new"
else
  docker exec "$NAME" mv "$RELAY_DIR/torrc.new" "$RELAY_DIR/torrc"
  TORRC_CHANGED=1
fi

# A torrc broken by a bad paste is the classic failure here, and a detached
# `docker exec -d` swallows the parse error: validate before starting.
docker exec "$NAME" tor -f "$RELAY_DIR/torrc" --verify-config >/dev/null ||
  die "torrc rejected by tor; run: docker exec $NAME tor -f $RELAY_DIR/torrc --verify-config"
log "torrc validated"

if docker exec "$NAME" sh -c 'pgrep -x tor >/dev/null 2>&1'; then
  if [ "$TORRC_CHANGED" -eq 1 ]; then
    log "torrc changed: reloading tor"
    docker exec "$NAME" pkill -HUP -x tor || true
  else
    log "tor already running"
  fi
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

FINGERPRINT=""
TOKEN=""
CONFIG_CHANGED=0

if docker exec "$NAME" sh -c "test -f $CONFIG"; then
  log "relay already initialised, keeping its identity"
  # The onion Tor publishes is the truth: a recreated `-hs` volume, a restored
  # data dir or a hand-written config can leave `config.json` naming a
  # different one, and `serve` would then advertise an address nobody answers.
  # (With --persist the `-hs` volume keeps the key, so the onion is stable.)
  if ! docker exec "$NAME" grep -q "\"onion\": \"$ONION\"" "$CONFIG"; then
    log "updating the onion in $CONFIG"
    docker exec "$NAME" sed -i "s|\"onion\": \"[^\"]*\"|\"onion\": \"$ONION\"|" "$CONFIG"
    CONFIG_CHANGED=1
  fi
  # Same for the port: the torrc written above maps the hidden service to
  # 127.0.0.1:$PORT, so a stored config still holding the old port makes
  # `serve` listen where Tor does not forward — an onion that answers nothing.
  if ! docker exec "$NAME" grep -qE "\"port\": $PORT([,}]|\$)" "$CONFIG"; then
    log "updating the port in $CONFIG to $PORT"
    docker exec "$NAME" sed -i "s|\"port\": [0-9]*|\"port\": $PORT|" "$CONFIG"
    CONFIG_CHANGED=1
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

# `init` always writes admission: invite. Anything else is a config edit, and
# `serve` fails loudly at load on a value it does not know.
if ! docker exec "$NAME" grep -q "\"admission\": \"$ADMISSION\"" "$CONFIG"; then
  log "setting admission=$ADMISSION"
  docker exec "$NAME" sed -i \
    "s|\"admission\": \"[^\"]*\"|\"admission\": \"$ADMISSION\"|" "$CONFIG"
  CONFIG_CHANGED=1
fi

[ -n "$FINGERPRINT" ] || die "could not read the relay fingerprint"
[ -n "$TOKEN" ] || die "could not obtain a setup token"

# `serve` reads the config exactly once, at startup. A relay left running
# across a config edit keeps the old rules: `--admission closed` would still
# hand out Contracts, and a rewritten port would still listen where Tor no
# longer forwards.
if [ "$CONFIG_CHANGED" -eq 1 ] &&
   docker exec "$NAME" sh -c 'pgrep -f "[p]rysm-relay serve" >/dev/null 2>&1'; then
  if [ "$SERVE" -eq 1 ]; then
    log "config changed: stopping the running relay so it restarts with it"
    docker exec "$NAME" sh -c 'pkill -f "[p]rysm-relay serve"' || true
    waited=0
    while [ "$waited" -lt 10 ] &&
          docker exec "$NAME" sh -c 'pgrep -f "[p]rysm-relay serve" >/dev/null 2>&1'; do
      sleep 1
      waited=$((waited + 1))
    done
    # Two relays on one data dir is worse than a hard kill: everything the
    # relay owns is already on disk (atomic writes), so an old binary that
    # ignores SIGTERM gets SIGKILL rather than keeping the old port.
    if docker exec "$NAME" sh -c 'pgrep -f "[p]rysm-relay serve" >/dev/null 2>&1'; then
      warn "the running relay ignored SIGTERM after ${waited}s; sending SIGKILL"
      docker exec "$NAME" sh -c 'pkill -KILL -f "[p]rysm-relay serve"' || true
      sleep 1
    fi
  else
    warn "a relay is running with the previous config and --no-serve was given:"
    warn "restart it yourself to apply the change"
  fi
fi

# ------------------------------------------------------------------ serve ----

if [ "$SERVE" -eq 0 ]; then
  # `--no-serve` neither starts nor stops the `serve` process (provisioning and
  # Tor still run above), so its state has to be read, not assumed: a reused
  # container can already be serving — with the config it started with, if this
  # run edited it (the warning above). Saying "stopped" there sent the operator
  # away believing no relay was answering.
  if docker exec "$NAME" sh -c 'pgrep -f "[p]rysm-relay serve" >/dev/null 2>&1'; then
    if [ "$CONFIG_CHANGED" -eq 1 ]; then
      log "leaving the relay running with the config it started with"
    else
      log "leaving the relay running on 127.0.0.1:$PORT"
    fi
    log "stop it: docker exec $NAME sh -c 'pkill -f \"[p]rysm-relay serve\"'"
  else
    log "leaving the relay stopped"
  fi
  log "start it later: docker exec -d $NAME sh -c 'prysm-relay serve --config $CONFIG >> $SERVE_LOG 2>&1'"
# `pgrep -f "prysm-relay serve"` would match the command line of the very
# `sh -c` running it, so it always answers yes and the relay never gets
# started on a reused container. The bracket makes the pattern unable to match
# itself; the /proc check then proves it is really listening, not just alive.
elif docker exec "$NAME" sh -c 'pgrep -f "[p]rysm-relay serve" >/dev/null 2>&1' &&
     docker exec "$NAME" bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then
  log "relay already serving on 127.0.0.1:$PORT"
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
