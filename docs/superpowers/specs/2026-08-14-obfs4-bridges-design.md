# obfs4 bridges (bring-your-own) — design

Date: 2026-08-14 · Status: approved, implementing
Branch: (current feature branch)

## Problem

Prysm embeds Tor on all platforms but has no pluggable-transport support. Users on
censored networks cannot reach the Tor network without bridges. v1 adds optional obfs4
with user-supplied bridge lines — no bundled bridges, no silent fallback to vanilla Tor.

## Decision

| Item | Choice |
|---|---|
| Transport | obfs4 only (lyrebird) |
| Bridges | User pastes one or more standard `obfs4 …` lines |
| Desktop PT binary | **Bundled lyrebird** in app package (`assets/native/pt/` + CMake/Xcode); build via `tool/fetch_lyrebird.sh` |
| Mobile PT binary | IPtProxy ~5.5 (Maven / CocoaPods) |
| Desktop torrc | `ClientTransportPlugin obfs4 exec <lyrebird>` |
| Mobile torrc | Start IPtProxy first; `ClientTransportPlugin obfs4 socks5 127.0.0.1:<port>` |
| Apply | Settings save triggers hard Tor restart (stop + start) |
| Bootstrap failure | Stay disconnected; show obfs4-specific error; toggle stays on |

Out of scope: snowflake, meek, webtunnel, moat/bundled bridges.

## Components

### `TorBridgeConfig` (`lib/models/tor_bridge_config.dart`)

Value object: `useObfs4`, `bridges` (normalized lines without `Bridge ` prefix).

### `Obfs4BridgeParser` (`lib/util/obfs4_bridge_parser.dart`)

- Split lines, trim, skip blanks/`#` comments
- Strip optional `Bridge ` prefix
- Require `obfs4`, host:port, 40-hex fingerprint, `cert=`
- Reject non-obfs4 transports

### Settings (`lib/models/settings.dart`)

- `useObfs4` (default `false`)
- `obfs4Bridges` (default `''`)

### `TorManager` (`lib/util/tor_service.dart`)

- `updateBridgeConfig(TorBridgeConfig)`
- `hardRestart()` — stop + start on all platforms (not iOS NEWNYM)
- Desktop: `LyrebirdLocator` + bridge lines in torrc
- Mobile: pass config via `prysm_tor` `startTor` args

### `LyrebirdLocator` (`lib/util/lyrebird_locator.dart`)

Resolves bundled lyrebird path: CMake/Xcode install location first, then one-time
extract from Flutter assets.

### Native (`TorController` Android / iOS)

- IPtProxy lifecycle: start obfs4 before Tor when enabled; stop after Tor stops
- `writeTorrc` gains optional bridge block

### Settings UI (`lib/screens/settings_screen.dart`)

Network section: toggle, multiline field, confirm reconnect, call `performHardRestart`.

### Build assets

See [`assets/native/pt/README.md`](../../../assets/native/pt/README.md).

## Failure handling

If `useObfs4` is on and bootstrap times out or start fails: Tor stays down, user sees
*obfs4 bridges failed — check your bridge lines or turn obfs4 off.* Settings are not
auto-cleared.

## Tests

Parser unit tests, settings migration defaults, desktop torrc fragment tests, lyrebird locator tests.
