# Create a Relay, automatically

> Source of truth for the wire is the protocol spec; this page points, it does not repeat.

`tool/create_relay.sh` provisions a working Relay node from the published
image and prints the one-click pairing link plus its QR block (the
`onion:`/`fingerprint:`/`token:` lines stay in the log for scripts). It is
a thin wrapper around `docker run`: the image's `tool/entrypoint.sh` does
the real work — verify the torrc, start Tor, wait for the hidden service,
`init` (or reconcile) the relay, print the `pair-link` block, `serve` in
the foreground. No Dart SDK is needed on the host; nothing is compiled.

The reference for what a Relay *is*, its config, storage layout, quotas and
hardening stays [`../README.md`](../README.md); this page is only about
bringing one up.

## Use it

```sh
packages/prysm_relay_server/tool/create_relay.sh
```

On a terminal it asks every choice, one at a time, pre-filled with the
current value: Enter accepts, typing overrides, menus take a number or the
word. It then prints the plan and waits for a final confirmation before
touching anything. Expect ~1–3 minutes, most of it Tor publishing the
service (a fresh onion's descriptor can take minutes to propagate).

### Or pass it all as flags

Flags are pre-answers: give some and the wizard asks only about the rest, or
add `-y` to skip the questions entirely.

```sh
# no questions, defaults: private relay, invite-only, persistent
tool/create_relay.sh -y

# show the plan and exit, create nothing
tool/create_relay.sh --dry-run

# build the image locally instead of pulling it (no registry access)
tool/create_relay.sh -y --build

# a public, openly admitting relay with a 24 h token
tool/create_relay.sh -y --tenancy public --admission open --ttl 24

# a second relay beside the first, on its own container and volumes
tool/create_relay.sh -y --name relay-b --port 9443

# run without volumes: identity and onion die with the container
tool/create_relay.sh -y --ephemeral

# start over from scratch (volumes stay, identity survives)
tool/create_relay.sh -y --force
```

| Option | Choices | Default |
|---|---|---|
| `--name` | any container name | `prysm-relay` |
| `--image` | any relay image tag | `ghcr.io/xmreur/prysm-relay:latest` |
| `--build` | build `prysm-relay:local` from `Dockerfile` | pull the image |
| `--port` | the loopback port Tor maps to | `8443` |
| `--tenancy` | `private` (one owner) \| `public` | `private` |
| `--admission` | `invite` (single-use tokens) \| `open` \| `closed` | `invite` |
| `--ttl` | token lifetime, hours | `168` |
| `--timeout` | seconds to wait for the onion | `180` |
| `--ephemeral` | no volumes (see below) | persistent |
| `--force` | recreate an existing container | reuse it |
| `--no-qr` | print the pairing link without the QR block | with QR |
| `-y` | never ask | ask on a terminal |
| `-n`, `--dry-run` | print the plan and exit | off |

Re-running is safe: an existing container is reused (a running one just gets
a fresh token minted), an existing relay keeps its identity, and `--force`
recreates the container while the volumes — and the identity — stay.

### Podman instead of Docker

Verified on Podman 6.1.1 rootless (runc): the image builds, runs, publishes
its onion and restarts exactly as under Docker.

**The script itself is unchanged — zero lines.** It only ever calls verbs
Podman implements identically (`info`, `run`, `exec`, `logs`, `inspect`,
`start`, `rm`, `build`), Go templates included (`inspect -f
'{{.State.Running}}'`, `{{.RestartCount}}`). Making Podman work cost one
change elsewhere — the `Dockerfile`'s base images are now fully qualified,
see its header comment — plus this section. What the script does need is to
actually *reach* Podman, and the obvious trick for that does not work.

- **`--persist`** puts the data dir and the hidden-service key in the volumes
  `<name>-data` and `<name>-hs`, so the **identity, the onion and the tenants
  all survive** recreating the container. Destroy them explicitly
  (`docker volume rm …`) when you mean to retire the relay.
- **`--no-persist`** (default) keeps both inside the container's writable
  layer: `docker rm` takes the identity *and* the onion with it, which
  invalidates every Contract already signed against them.

When the onion Tor publishes differs from the one in `config.json` — a
recreated `-hs` volume, a restored data dir — the entrypoint rewrites the
`onion` field, because otherwise `serve` would advertise an address nobody
answers. `port` is rewritten the same way (the torrc maps the hidden service
to it), and so is `admission` (because `init` always writes `invite`).

## Restarts

The container runs with `--restart unless-stopped`, so the relay comes back
after a crash, a host reboot or a docker daemon restart — the container
equivalent of the systemd unit's `Restart=` plus `enable`. A relay that is
down is a relay that silently stops receiving, and nobody is told: senders
keep queueing for direct delivery, and the owner sees nothing.

Measured: killing the `serve` process inside the container brings the whole
container down and Docker starts it again (`RestartCount` 1), with the same
onion and the same identity, because both live in the volumes. `docker kill`
is treated the same way — it takes a few seconds, so a container that reads
`running=false` right after is mid-backoff, not dead.

`docker stop <name>` is the deliberate way out: the container then stays
stopped until you `docker start <name>` (or re-run the script, which starts
it). A container created before this policy existed keeps the old one; give
it the new behaviour without recreating anything:

```sh
docker update --restart unless-stopped <name>
docker start <name>            # if it is already down
```

## What it does, in order

1. **Builds or pulls the image.** With `--build`, `docker build` runs the
   multi-stage `Dockerfile` (Dart cross-compile on the builder's own arch,
   then `debian:trixie-slim` + Tor); otherwise the registry tag is pulled.
2. **Creates the container** from the image with `-e RELAY_TENANCY`,
   `RELAY_ADMISSION`, `RELAY_TOKEN_TTL_HOURS`, `RELAY_PORT`,
   `RELAY_ONION_TIMEOUT`, `RELAY_NO_QR` and the two volumes (unless `--ephemeral`).
   An existing container is reused: `--force` recreates it, a stopped one is
   started, a running one just gets a fresh token.
3. **The entrypoint verifies the torrc** (`tor --verify-config`) *before*
   starting anything, so a broken torrc fails loudly instead of hanging the
   onion wait.
4. **The entrypoint starts Tor and polls** for `<HiddenServiceDir>/hostname`
   (default 180 s). On timeout it prints the tail of the Tor log instead of
   failing mutely.
5. **The entrypoint initialises the relay** with the onion it just read, or —
   if `config.json` already exists — keeps the identity, reconciles
   `onion`/`port`/`admission`, and mints a token with the requested TTL.
   Either way it prints the `pair-link` block: `onion:`, `fingerprint:`,
   `token:`, `link:`, a blank line, and the link as a QR block. On a first
   boot with the default TTL the token `init` minted is reused, so only one
   token is spent.
6. **The script waits for `listening on`** in `docker logs` (onion timeout
   plus headroom), reads the `link:` line and the QR block after it from the
   same logs, and prints the summary: the pairing link, its QR, the commands
   to mint another link, to read status and logs, and to tear the node down.

The relay binds loopback only and Tor is its single ingress. Keep it in a
container (or on another machine): the Prysm app's Tor cleanup issues a
broad `pkill -9 tor` and would kill a relay's Tor sharing its PID namespace.

## Pair from the app

`Settings` → `Network` → `Relay`:

1. Paste the pairing link (or scan the QR): the address and the token fill
   in on their own.
2. `Read relay info`, then `Pair with this relay`. The app compares the
   relay's fingerprint against the one in the link itself and refuses to
   pair on a mismatch — no manual fingerprint comparison needed.

The app side is documented in
[`docs/RELAY-USER.md`](../../../docs/RELAY-USER.md).

The **first** contact with a fresh onion can take up to a minute (descriptor
propagation): the app retries `Read relay info` once on its own before
reporting an error. A Relay holds messages **addressed to you**: for your
message to reach a peer who is offline, that peer must have paired with a
Relay of their own.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `torrc rejected by tor` | a directive lost its value | `docker exec <name> cat /etc/tor/torrc`, fix `tool/torrc`, rebuild |
| no onion after the timeout | Tor still bootstrapping, or a network with no way out | `docker logs <name>`, look for `Bootstrapped 100%`, then re-run |
| `the container stopped` | entrypoint validation failed (bad env, Tor died) | `docker logs <name>` shows the tail it died with |
| the relay is down after a host reboot | the container predates `--restart unless-stopped` | `docker update --restart unless-stopped <name> && docker start <name>` |
| app says `This relay is not accepting new accounts right now` | `--tenancy private` already serves one owner | unpair the other identity, or provision with `--tenancy public` |
| app says the token is invalid or used | tokens are single use | `docker exec <name> prysm-relay pair-link --config /var/lib/prysm-relay/config.json --ttl 72` |

## Teardown

```sh
docker rm -f prysm-relay
docker volume rm prysm-relay-data prysm-relay-hs   # destroys identity and onion
```

Without the volumes (`--ephemeral`), `identity.json` and the hidden-service
key die with the container, and every Contract signed against them dies too:
the owners must pair again. With volumes, those two volumes *are* the relay —
back them up if it carries real traffic (see `Back up and restore` in
[`../README.md`](../README.md)).
