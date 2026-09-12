# Create a Relay, automatically

`tool/create_relay.sh` provisions a working Relay node in a container and
prints the three values pairing needs: **onion**, **fingerprint**, **setup
token**. It replaces the hand-typed sequence, where a line wrapped by a
terminal silently breaks the `torrc` and a detached `tor` swallows the parse
error.

The reference for what a Relay *is*, its config, storage layout, quotas and
hardening stays [`../README.md`](../README.md); this page is only about
bringing one up.

## Use it

```sh
packages/prysm_relay_server/tool/create_relay.sh
```

On a terminal that asks you every choice, one at a time, pre-filled with the
current value: Enter accepts, typing overrides, menus take a number or the
word. It then prints the plan and waits for a final confirmation before
touching anything. Expect ~1 minute, most of it Tor publishing the service.

```
Prysm Relay — provisioning
Enter keeps the value in brackets.

  container name [prysm-relay]:
  who may hold a Contract on this relay?
    1) private  (current)
    2) public
  choice [private]:
  how are new Contracts admitted?
    1) invite  (current)
    2) open
    3) closed
  choice [invite]:
  relay port on the container's loopback [8443]:
  keep identity and onion in docker volumes (survive docker rm)? [y/N]:
  start serving once provisioned? [Y/n]:

  change the advanced settings (image, data dir, binary, timeouts)? [y/N]:
```

Say yes to the last one and it also asks for the base image, the data dir, a
prebuilt binary, the token lifetime and the onion timeout. Every answer is
validated: a menu answer outside the list keeps the current value and warns, a
non-numeric port or a missing binary stops the run before anything is created.

### Or pass it all as flags

Flags are pre-answers: give some and the wizard asks only about the rest, or
add `-y` to skip the questions entirely.

```sh
# no questions, defaults: private relay, invite-only, ephemeral, serving
tool/create_relay.sh -y

# show the plan and exit, create nothing
tool/create_relay.sh --dry-run

# keep the identity and the onion across `docker rm`
tool/create_relay.sh -y --persist

# provision and initialise, but do not start serving yet
tool/create_relay.sh -y --no-serve

# a public, openly admitting relay on another port, with a 24 h token
tool/create_relay.sh -y --tenancy public --admission open --port 9443 --ttl 24

# reuse a binary you already compiled, skip dart entirely
tool/create_relay.sh -y --binary /tmp/prysm-relay

# a second relay beside the first, on its own container and volumes
tool/create_relay.sh -y --name relay-b --port 9443 --persist

# start over from scratch
tool/create_relay.sh -y --force

# ask even when stdin is not a terminal
tool/create_relay.sh -i
```

| Option | Choices | Default |
|---|---|---|
| `--name` | any container name | `prysm-relay` |
| `--image` | any Debian-family image | `ubuntu:24.04` |
| `--port` | the loopback port Tor maps to | `8443` |
| `--tenancy` | `private` (one owner) \| `public` | `private` |
| `--admission` | `invite` (single-use tokens) \| `open` \| `closed` | `invite` |
| `--data-dir` | data dir inside the container | `/var/lib/prysm-relay` |
| `--binary` | a prebuilt relay exe | compile from this package |
| `--ttl` | token lifetime, hours | `168` |
| `--timeout` | seconds to wait for the onion | `180` |
| `--persist` / `--no-persist` | identity and onion in docker volumes | `--no-persist` |
| `--serve` / `--no-serve` | start serving when done | `--serve` |
| `--force` | recreate an existing container | reuse it |
| `-i` / `-y` | always ask / never ask | ask on a terminal |
| `-n`, `--dry-run` | print the plan and exit | off |

Re-running is safe: an existing container is reused, an existing relay keeps
its identity, and you simply get a fresh token.

Persistence decides what survives `docker rm`:

- **`--persist`** puts the data dir and the hidden-service key in the volumes
  `<name>-data` and `<name>-hs`, so the **identity, the onion and the tenants
  all survive** recreating the container. Destroy them explicitly
  (`docker volume rm …`) when you mean to retire the relay.
- **`--no-persist`** (default) keeps both inside the container's writable
  layer: `docker rm` takes the identity *and* the onion with it, which
  invalidates every Contract already signed against them.

When the onion Tor publishes differs from the one in `config.json` — a
recreated `-hs` volume, a hand-written config, a restored data dir — the
script rewrites the `onion` field, because otherwise `serve` would advertise
an address nobody answers. `port` is rewritten the same way (the torrc the
script writes is what maps the hidden service to it), and so is `admission`,
because `init` always writes `invite`.

Those three only take effect at startup, so the script also applies them:
`tor` gets a SIGHUP when its torrc changed, and a running `serve` is stopped
and restarted when the config changed (SIGKILL if it ignores SIGTERM). With
`--no-serve` the script still provisions the node and still starts (or SIGHUPs)
Tor — it only never starts and never stops `serve`, and then reports what is
actually serving: a relay left running with the config it started with, a relay
running with the current one, or nothing.

## What it does, in order

1. **Compiles** `bin/prysm_relay.dart` with `dart compile exe` into a temp file
   (removed on exit), unless `--binary` is given. The result is standalone: no
   Dart SDK is needed in the container.
2. **Creates the container** (`ubuntu:24.04`, entrypoint `sleep infinity`), with
   two docker volumes when `--persist` is set.
3. **Installs Tor** with apt, skipping it if `tor` is already there.
4. **Copies the binary** to `/usr/local/bin/prysm-relay`.
5. **Writes the torrc** through `docker exec -i … tee` and a heredoc, so no
   paste can split a directive from its value. Directories live under
   `/opt/relay` owned by root, because the Debian package assigns
   `/var/lib/tor` to `debian-tor` and Tor as root then refuses to start.
6. **Validates it** with `tor --verify-config` *before* starting anything.
7. **Starts Tor** and polls for `/opt/relay/hs/hostname` (default 180 s). On
   timeout it prints the tail of `tor.log` instead of failing mutely. If Tor is
   already running and the torrc changed, it gets a SIGHUP instead.
8. **Initialises the relay** with the onion it just read, parsing the
   fingerprint and the setup token out of `init`'s output. If `config.json`
   already exists it keeps the identity, reconciles `onion`/`port`/`admission`
   and mints a token instead.
9. **Starts `serve`** detached and waits for its `listening on` line. With
   `--serve`, a relay already running with a config the script just changed is
   stopped first, so exactly one relay serves the data dir. With `--no-serve`
   the `serve` process is neither started nor stopped, and the script reports
   its real state instead.
10. **Prints the summary**: the three pairing values, the commands to mint
    another token, to read status and logs, and to tear the node down.

## Why a container

The Prysm app's Tor cleanup falls back to a broad `pkill -9 tor`
(`lib/util/tor_service.dart:670`). A Relay sharing the app's PID namespace
loses its Tor to that. A container (or a different machine: a VPS, a
Raspberry, a second PC) is the boundary that makes the two coexist. On a host
that never runs the app, install Tor and the binary directly and follow
[`../README.md`](../README.md) — `Run it as a service` has the systemd unit.

## Pair from the app

`Settings` → `Network` → `Relay`:

1. `Relay address` ← the onion the script printed.
2. `Setup token` ← the token the script printed.
3. `Read relay info`, then **compare the `Fingerprint` on screen with the one
   the script printed**. It is the one check that proves you are talking to the
   Relay you meant.
4. `Pair with this relay`.

The **first** request to a fresh onion can take longer than the app's 30 s
per-attempt budget (measured 39.8 s; descriptor propagation can reach two
minutes). If `Read relay info` times out, leave the screen and open it again —
the second attempt is fast. A Relay holds messages **addressed to you**: for
your message to reach a peer who is offline, that peer must have paired with a
Relay of their own.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `torrc rejected by tor` | a directive lost its value (usually a bad paste when doing it by hand) | re-run the script, or `docker exec <name> tor -f /opt/relay/torrc --verify-config` to see the offending line |
| no onion after the timeout | Tor still bootstrapping, or a network with no way out | `docker exec <name> tail -20 /opt/relay/tor.log`, look for `Bootstrapped 100%`, then re-run |
| `config already exists` from `init` | the relay is already initialised | nothing to do; the script detects this and mints a token instead |
| `the relay did not start` | `serve` refuses an empty or invalid `onion` in the config | `docker exec <name> tail -20 <data-dir>/serve.log` |
| app says `This relay is not accepting new accounts right now` | `--tenancy private` already serves one owner | unpair the other identity, or provision with `--tenancy public` |
| app says the token is invalid or used | tokens are single use | `docker exec <name> prysm-relay token new --config <data-dir>/config.json --ttl 72` |

## Teardown

```sh
docker rm -f prysm-relay
docker volume rm prysm-relay-data prysm-relay-hs   # only with --persist
```

Without `--persist`, `identity.json` and the hidden-service key die with the
container, and every Contract signed against them dies too: the owners must
pair again. With `--persist`, those two volumes *are* the relay — back them up
if it carries real traffic (see `Back up and restore` in
[`../README.md`](../README.md)).
