# prysm_relay_server

Standalone store-and-forward Relay for Prysm (`prysm-relay/1`). Holds sealed
messages for an offline owner under a signed Contract. The normative wire
spec is `.scratch/relay/proto/relay-protocol-v1.md`; this package implements
the server side of it. All wire types, signing strings, limits and error
codes are imported from `prysm_relay_protocol`, never redefined here.

Builds with `dart compile exe` — no Flutter dependency, no SQLite, storage
is the filesystem.

## CLI

```
prysm_relay init --data-dir <path> [--tenancy private|public] [--onion <addr>] [--bind 127.0.0.1] [--port 8443]
prysm_relay serve --config <path>
prysm_relay token new --config <path> [--ttl <hours>]   # default 168h
prysm_relay token list --config <path>
prysm_relay status --config <path>
prysm_relay fingerprint --config <path>
prysm_relay pair-link --config <path> [--ttl <hours>] [--token <hex>] [--no-qr]
```

- `init` creates the data dir (mode 0700), the relay identity
  (`identity.json`, Ed25519+X25519), a default `config.json`, an empty
  `tokens.json`/`index.json`, and mints a first setup token (valid 168 h).
  It prints the relay fingerprint and the token, and refuses to overwrite an
  existing identity. Pass `--onion` when you already know the v3 address;
  otherwise edit `config.json` before serving.
- `serve` loads the config, requires a valid `onion`, loads the identity,
  listens on `bind:port` (loopback: Tor is the only ingress), and starts the
  60 s sweeper. Stops on SIGINT/SIGTERM.
- `token new` mints a single-use invite token and prints it (the only output,
  so it composes with scripts); the running relay picks it up without a
  restart. `token list` shows pending tokens.
- `status` prints an operator summary from disk (tenants, mailboxes, items,
  bytes). `fingerprint` prints the relay fingerprint.
- `pair-link` prints the one-click pairing block: `onion:`, `fingerprint:`,
  `token:` (freshly minted unless `--token` reuses a pending one), `link:`,
  a blank line, then the link as a QR block (unless `--no-qr`). Paste the
  link or scan the QR from the app: it fills the form and checks the
  fingerprint in the link itself. A bad `--token` exits 2.

## Config file

Single JSON file (no YAML parser on the server by design):

```json
{ "onion": "<56>.onion", "bind": "127.0.0.1", "port": 8443,
  "dataDir": "/var/lib/prysm-relay",
  "tenancy": "private", "admission": "invite",
  "allowedOwners": ["<fingerprint hex>"],
  "limits": { "maxItemBytes": 8388608, "maxMailboxItems": 1024,
              "maxTenantBytes": 268435456, "itemTtlSeconds": 1728000,
              "maxMailboxes": 512, "pickupBatchItems": 64,
              "pickupBatchBytes": 8388608, "blockSize": 0 },
  "rate": { "depositPerMinute": 60, "pickupPerMinute": 30, "pairPerHour": 10 },
  "logLevel": "counters", "terms": "" }
```

- `tenancy`: `private` serves a single owner (a second fingerprint pairs only
  after the first is unpaired); `public` serves many. Ceilings default from
  `RelayLimits.defaultsFor(tenancy)` when `limits` is omitted; a pair
  `requested` block may ask for less, never more (clamped, not an error).
- `admission`: `invite` (default, single-use operator tokens), `open`
  (any non-empty token accepted, nothing consumed), `closed` (no new
  contracts; existing tenants keep working and may re-pair on signature
  alone). `allowedOwners`, when non-empty, restricts fingerprints in every
  mode. Unknown enum values, bad limits, or malformed fingerprints fail
  loudly at load.
- `onion` may be empty in the file (init before Tor exists), but `serve`
  refuses to start until it is a real v3 onion.
- `bind` must be a loopback address (`127.0.0.1`, `::1`, `localhost`);
  anything routable is refused at load, by `init` and by `serve` alike. The
  relay is reachable only through its hidden service, and Tor connects to it
  over loopback. To split Tor and the relay across two containers, share one
  network namespace (`docker run --network container:<tor> …`).
- `logLevel: counters` (default) never logs a deposit address beyond its
  first 6 hex chars, never a payload, never an owner onion; owner
  fingerprints are truncated to 8 chars. `debug` relaxes this and prints a
  startup warning. Never run `debug` in production.
- Any body larger than `maxItemBytes + 4 KiB` is rejected with
  `item_too_large` before parsing.

## Storage layout

```
<dataDir>/                        (0700)
  identity.json                   relay seeds + public keys + fingerprint (0600)
  config.json                     (written by init; live where you put it)
  tokens.json                     [{token, createdAt, expiresAt, usedBy?}]
  tokens.json.lock                held while tokens.json is read-modify-written
  init.lock                       held by `init` for the whole of its work
  index.json                      {depositHex: ownerFingerprint}
  tenants/<ownerFingerprint>/
    contract.json                 signed contract (served verbatim)
    owner.json                    {signPublic, agreePublic} (auth verification)
    mailboxes/<depositHex>/
      policy.json                 {label?, enabled, maxItems?, maxBytes?}
      items/<itemId>.json         {itemId, deposit, storedAt, expiresAt, size, payload}
```

All writes are write-to-`<file>.<pid>.<n>.tmp` + `rename` (atomic, and the
temp name is unique so two writers cannot rename each other's file away).
`tokens.json` is additionally read-modify-written under `tokens.json.lock`,
because `token new` runs in a second process while `serve` holds the list in
memory; both locks also queue their work *inside* the relay process, because
an `fcntl` lock belongs to the process and would let two `/pair` handlers
write the file at once. `init` holds `init.lock` from its conflict checks
through the identity, the config and the first token, so two `init` on one
data dir cannot both pass the checks and overwrite each other's identity. The
deposit index lives in memory, is rebuilt from disk at boot, and is persisted
on change.
`delete` removes the address, its items and its index entry, so a deleted
address answers exactly like a never-existing one (`404 mailbox_unknown`);
a registered-but-suspended address answers `403 mailbox_disabled`.

Semantics worth knowing:

- Pair re-uses: same identity + fresh token returns the same tenant with
  `version + 1`. Mailboxes and items survive re-pair.
- Pickup is non-destructive and oldest-first, capped by
  `pickupBatchItems`/`pickupBatchBytes` (and the optional request `max`);
  `more: true` means call again. At least one item is always returned when
  any exist, so an item larger than the byte cap cannot wedge the client.
- Ack counts `{deleted, unknown}`; acking an already-deleted id is not an
  error. Unpair needs `{"confirm": true}` and reports `deletedItems`.
- `mailbox put` preserves the `enabled` flag of an existing mailbox (a new
  address starts enabled); `maxItems`/`maxBytes` narrow the contract
  ceilings per address and cannot outlive them: a renewal that lowers
  `maxMailboxItems` clamps a wider stored cap at deposit time. `list` returns
  per-mailbox items/bytes/enabled/oldestExpiresAt.
- Rate limits are fixed windows keyed `deposit:<hex>` (deposit),
  `owner:<fpr>` (pickup) and `pair:<fpr>` (pair) — never an IP.
- The sweeper (every 60 s) deletes expired items and drops used/expired
  tokens.

## Tor runbook (documented, not automated)

The relay binds loopback; Tor is the only ingress. On the Tor host:

```
HiddenServiceDir /var/lib/tor/prysm-relay/
HiddenServicePort 80 127.0.0.1:8443
Log notice file /var/log/tor/prysm-relay.log
```

Write that file with a heredoc (`cat > … <<'TORRC'`), never with a `printf`
chain: a `\n` that does not survive a copy-paste silently joins a directive
to its value, and Tor then reports something unrelated. Two habits that cost
a live session each:

- **Validate before starting**: `tor -f <torrc> --verify-config`. A detached
  start (`tor -f … &`, `docker exec -d …`) swallows the parse error and you
  are left waiting for a `hostname` file that will never appear.
- **Keep the log**: without `Log notice file`, a Tor that refuses to publish
  the service has nowhere to say why. With it, `tail -20` names the cause
  (permissions on `HiddenServiceDir`, a bad port, a directory Tor cannot own).
  Tor also refuses a `HiddenServiceDir` that is group- or world-readable, so
  it must be `0700` and owned by the user Tor runs as.

Hardening for a public relay (see
`.scratch/relay/issues/13-antiabuso-relay-pubblici.md`): enable Tor's own
proof-of-work and introduction DoS defenses — application PoW proves effort,
not identity, and is deliberately not a v1 admission mechanism:

```
HiddenServicePoWDefensesEnabled 1
HiddenServiceEnableIntroDoSDefense 1
HiddenServiceMaxStreams 128
HiddenServiceMaxStreamsCloseCircuit 1
```

Application-side abuse controls live in the config: `admission: invite`
with single-use tokens, per-tenant/per-mailbox quotas, and the fixed-window
rate limits above. Sanctions in v1 are `429 rate_limited` / `507 *_full`
(both retryable) and contract revocation (delete the tenant); there are no
permanent identity bans. v3 client authorization (`HiddenServiceAuthorizeClient`)
is out of scope for v1 deployment automation — enabling it breaks the
"any sender deposits blind" property unless every contact holds a client
cookie, which v1 key distribution does not provide.

## Operator flow

```
prysm_relay init --data-dir /var/lib/prysm-relay --tenancy private --onion <56>.onion
# -> note fingerprint + setup token
# write the torrc as above, then: tor -f <torrc> --verify-config
# start Tor and wait for <HiddenServiceDir>/hostname
prysm_relay serve --config /var/lib/prysm-relay/config.json
prysm_relay token new --config /var/lib/prysm-relay/config.json --ttl 72
```

`tool/create_relay.sh` does all four steps in a container — compile, Tor,
hidden service, `init`, `serve` — and prints the onion, the fingerprint and
the setup token pairing needs. See
[`tool/CREATE-RELAY.md`](tool/CREATE-RELAY.md).

## Notes / interpretations

- The relay never validates that a deposit payload decrypts — it cannot; it
  only enforces the sealed-envelope *shape* via
  `RelayDepositRequest.fromJson`. Content-blind by construction.
- Item sizes are measured over the canonical JSON of the payload, the same
  bytes quota accounting uses everywhere; the size is stored on the item so
  quotas do not re-encode.
- `status` carries an extra `mailboxes` array beyond spec §3.7; the protocol
  parser tolerates it (`mailboxes` defaults to `[]`).
- `token list` / sweeper drop used tokens: a consumed token is dead weight,
  and `usedBy` is recorded only until the next sweep.
- Re-pair on a `closed` relay needs no token: the signature already proves
  ownership, and blocking renewal would strand existing tenants.

## Run it as a service

Compile once, run the result:

```
dart compile exe bin/prysm_relay.dart -o /usr/local/bin/prysm-relay
```

The output is a standalone 7.6 MiB binary: no Dart SDK needed on the host.
Minimal unit for it:

```
[Unit]
Description=Prysm relay (store-and-forward)
After=network.target tor.service
- A pairing link is as secret as the token inside it: single-use, expiring
  on the relay. Do not log it, screenshot it into shared media, or reuse it.

[Service]
User=prysm-relay
WorkingDirectory=/var/lib/prysm-relay
ExecStart=/usr/local/bin/prysm-relay serve --config /var/lib/prysm-relay/config.json
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/prysm-relay

[Install]
WantedBy=multi-user.target
```

The process only writes inside `dataDir` and only listens on loopback, so
`ProtectSystem=strict` with a single `ReadWritePaths=<dataDir>` is enough;
keep the config inside `dataDir`, or add a `ReadOnlyPaths=` line for it.
`serve` exits on SIGINT/SIGTERM, so `systemctl stop` is clean: it stops the
sweeper and closes the listener before returning.

## Back up and restore

Back up the whole `dataDir` tree plus the Tor `HiddenServiceDir`. What
matters inside:

- `identity.json` (0600) is irreplaceable. Lose it and every signed Contract
  dies with it: clients reject a manifest/Contract under any other
  fingerprint and must pair again from scratch.
- The hidden-service key inside `HiddenServiceDir` is equally irreplaceable:
  the onion is the address clients stored, and a new key means a new onion.
- `tenants/` and `index.json` are recoverable only from backup; `items/` are
  messages not yet picked up, ephemeral by definition (TTL).

Recipe: stop the service, copy both trees, restore with the permissions
(`0700` on directories, `0600` on `identity.json`):

```
systemctl stop prysm-relay
cp -a /var/lib/prysm-relay /backup/prysm-relay
cp -a /var/lib/tor/prysm-relay /backup/prysm-relay-hs
```

Restoring an old backup can resurrect already-picked-up items. The client
deduplicates on `messages.id`, so this is harmless but inelegant: prefer a
fresh backup for restores.

## Size the quotas

Start from the disk you are willing to give away. The uncapped worst case is
`maxMailboxes` x `maxMailboxItems` x `maxItemBytes`, but `maxTenantBytes`
caps it per tenant, so the planning number is `tenants` x `maxTenantBytes`.
Two notes before picking numbers: a sealed envelope costs ~1.6x the
plaintext (measured 656 B -> 1072 B), and large attachments never cross the
Relay (they stay direct), so `maxItemBytes` must not chase file sizes.

- Private (one owner): the `init` defaults (`maxItemBytes` 8 MiB,
  `maxMailboxItems` 1024, `maxMailboxes` 512, `maxTenantBytes` 256 MiB) cap
  the relay at ~256 MiB. Keep them.
- Public (many strangers): the `public` defaults (`maxItemBytes` 1 MiB,
  `maxMailboxItems` 256, `maxMailboxes` 256, `maxTenantBytes` 64 MiB) cost
  ~64 MiB per tenant you admit (ten tenants need ~640 MiB); lower
  `maxTenantBytes` first if that exceeds your disk.

## Watch it

There is no unauthenticated health or metrics endpoint: `/relay/manifest` is
the only public endpoint, `/relay/deposit` is sender-blind by design, and
everything else needs owner authentication. Observe from the host instead:

- `prysm_relay status --config <path>` reads the disk without starting the
  server and prints per-tenant items/bytes/mailboxes plus a totals line.
- Watch `dataDir` growth (`du -s`) against the `tenants` x `maxTenantBytes`
  budget from the previous section.
- At `logLevel: counters` (the default) the log carries only counters and
  short ids: never a deposit address beyond its first 6 hex chars, never a
  payload, never an owner onion; owner fingerprints are truncated to 8.

A Relay log must never contain a full deposit address, a payload, an owner
onion, or a full fingerprint. `debug` relaxes all of this and prints a
startup warning: never run it in production.

## Upgrade

Replacing the binary is safe: storage is the filesystem and every write is
write-to-`<file>.tmp` + `rename`, so a stopped relay always leaves complete
files behind. Order: stop, replace, start. Identity and Contracts survive;
nothing needs re-pairing.

The constraint that matters is the wire, not the binary: the protocol is
`prysm-relay/1` and the manifest declares it, so an older client keeps
working as long as that string does not change.

## Decommission

Do not strand owners: announce the shutdown first (the app lets them
unpair), then set `admission: closed` so no new Contract is accepted while
existing tenants keep working. Wait until the mailboxes drain (`status`
shows `items=0`), stop the service, and delete both `dataDir` and the Tor
`HiddenServiceDir`. A client unpair already deletes its tenant, mailboxes
and items, so drained owners leave nothing behind.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `serve` exits over `onion` | No valid v3 onion in config | Set it from the Tor hostname file |
| `403 bad_signature` / `not_paired` | Wrong key or unknown owner | Re-pair from scratch |
| `401 stale_request` | Clock skew over 300 s | NTP on the relay host; the client cannot help |
| `404 mailbox_unknown` | Unknown/deleted address (same by design) | Fix the address or re-register |
| `507 mailbox_full` / `tenant_full` | Quota hit (retryable) | Pickup and ack, or raise the quota |
| `429 rate_limited` | Fixed window hit | Wait and retry (pair: up to an hour) |
| `403 admission_closed` / `bad_token` | Closed relay or spent invite | Mint a fresh token |
| New onion unreachable (~2 min) | Descriptor propagation | Wait; not a relay fault |
