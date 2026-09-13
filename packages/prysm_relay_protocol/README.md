# prysm_relay_protocol

Wire types, canonical signing rules and the `relay-sealed-1` seal for `prysm-relay/1`.

Pure Dart: **no Flutter dependency**, so the relay server binary can depend on it without dragging a
UI toolkit into a server. Both sides of the protocol — the Prysm app and `prysm_relay_server` —
import this package, so the Contract schema and its validation exist in exactly one place.

Normative spec: `.scratch/relay/proto/relay-protocol-v1.md`.
