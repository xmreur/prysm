# Prysm

Prysm is a Tor-only peer-to-peer messenger: every participant runs their own hidden service and
there is no central server. This glossary fixes the vocabulary used across the code and its design
discussions. It is a glossary only — no implementation details, no decisions.

## Identity and reachability

**Peer**:
Another Prysm user as seen from this device: an Identity together with the onion address it answers on.
_Avoid_: user, client, node.

**Prysm ID**:
The v3 onion address a peer answers on. It is also that peer's primary key in local storage.
_Avoid_: address, host, endpoint, url.

**Identity**:
The Ed25519 signing key plus X25519 agreement key a peer owns, independent of any onion address.
_Avoid_: account, keypair, profile.

**Fingerprint**:
The hash of an Identity's public keys, shown to humans for out-of-band verification.
_Avoid_: hash, checksum, safety number.

**Direct Delivery**:
Delivery straight to the recipient's own hidden service, which requires both parties to be online in
the same moment.
_Avoid_: P2P send, online send, direct send.

## Relaying

**Relay**:
A Prysm-speaking service that accepts messages addressed to a subscribed user while that user is
offline, and hands them over when the user asks for them.
_Avoid_: server, proxy, node, forwarder, hub.

**Mailbox**:
The per-user store inside a Relay that holds messages until their owner collects them.
_Avoid_: queue, inbox, spool, bucket.

**Contract**:
The signed, versioned agreement between one user and one Relay fixing what that Relay accepts,
stores, and enforces on that user's behalf.
_Avoid_: subscription, terms, config, policy file.

**Pairing**:
The exchange that establishes a Contract: the user proves their Identity, the Relay proves it is the
Relay it claims to be, and both sign the result.
_Avoid_: registration, signup, login, enrollment.

**Pairing link**:
The single text an operator hands over at provisioning time, also shown as a QR code, bundling a
Relay's address, its fingerprint and a one-time setup token, so the app fills the pairing form and
checks the fingerprint by itself. It is not a protocol message, and it adds no trust beyond whoever
hands it to you.
_Avoid_: invite link, deep link, pairing code.

**Advertisement**:
The ordered list of Relays a peer publishes so that senders know where to leave messages when that
peer is unreachable.
_Avoid_: relay list, discovery record, hint.

**Pickup**:
The exchange in which a user asks its Relay for what the Mailbox holds and the Relay hands it over.
_Avoid_: fetch, poll, pull, sync, download.

**Private Relay**:
A Relay whose Contracts are restricted to a single Identity, normally the Identity of whoever runs it.
_Avoid_: personal server, own server, self-hosted relay.

**Public Relay**:
A Relay that accepts Contracts from Identities its operator did not choose in advance.
_Avoid_: open relay, shared server, community server.

## Words that mean something else here

**History Backfill**:
Sending a group's earlier messages to a newly added member. Its wire type is literally named
`group-history-relay`, but it has nothing to do with a Relay.
_Avoid_: history relay, relay.

**Forwarded Message**:
A message a user re-sends into another conversation, recorded per message. Unrelated to a Relay.
_Avoid_: relayed message.

**Tor Proxy**:
The local SOCKS5 port Tor exposes for outbound connections. Unrelated to a Relay.
_Avoid_: proxy server, relay.

Note: "relay" is also the Tor network's own word for its routers. In this project **Relay** always
means the Prysm service defined above; a Tor router is a "Tor node".
