# Prysm

[🇬🇧 English](README.md) | [🇮🇹 Italiano](README.it.md)

<p align="center">
  <img src="https://cdn.discordapp.com/icons/1420770528691617928/e685f1b4b88adc1b6a8da534633b7fca.png?size=512" width="320" alt="Prysm logo">
</p>

Prysm is a Tor-only P2P messenger built with Flutter.

There is no central server. Each client runs its own Tor hidden service, receives messages directly on its `.onion` address, and sends outbound messages through Tor. If a peer is offline, messages stay in a local queue and are retried later.

## Overview

On desktop, Tor is started as a child process. On Android and iOS it runs through a native service. The app hosts a local HTTP server with `shelf` on port `12345`, which Tor exposes as `your-address.onion:80`. Outbound messages go through Tor's SOCKS5 proxy to `peer-address.onion:80/message`.

There are no relay servers yet. Relay settings exist in the UI, but they are placeholders and are not implemented.

## Message flow

If both peers are online, messages usually arrive within a few seconds.

If the destination is offline or unreachable, Prysm stores the message locally in SQLite and retries with exponential backoff. That keeps the app usable as an asynchronous messenger without any centralized infrastructure.

## Encryption

Prysm 0.4.0 and later use **Crypto v2**: Curve25519 identity keys, AEAD-only wire formats, Argon2id passphrase protection, and Double Ratchet sessions for 1:1 forward secrecy. Upgrading from 0.2.x requires a clean migration (export if needed, wipe, re-onboard).

### Identity

- **Ed25519** signing key + **X25519** agreement key, generated locally.
- Private identity encrypted at rest with **AES-256-GCM**.
- Key encryption key derived from a **passphrase** (minimum 12 characters) with **Argon2id** (64 MiB, 3 iterations).
- Public keys published on `/profile` as versioned JSON (`crypto: v2`). QR codes include an identity **fingerprint** for out-of-band verification.

Tor onion addresses are separate from Prysm identity keys.

### Direct messages (1:1)

- **Double Ratchet** (`ratchet-1`) with X3DH-style prekey bundles for session bootstrap.
- Per-message **AES-256-GCM** with chain-derived keys (forward secrecy).
- Files use ephemeral X25519 + HKDF + AES-GCM (`dh-aead-1` / `file-aead-1`).

### Group messages

- **Sender-key** encryption (`group-sender-1`): per-sender message keys derived from the group epoch key.
- Group epoch key distributed via X25519-wrapped control payloads.
- Epoch rotates when members are removed.

### Transport

- Local message server binds to **all IPv4 interfaces** (`InternetAddress.anyIPv4`) so Tor can reach the hidden service port.
- Server starts at app launch.

### Backups

- Backup format **v2**: Argon2id + AES-GCM. v1 backups cannot restore into v2.

## Implemented

- 1:1 encrypted messaging
- Voice calls with call history
- Attachments: images, files, audio, voice messages
- Group chat (up to 5 members) with invite flow, key rotation, and member removal
- Emoji reactions
- Message editing, deletion, and view-once messages
- Read receipts with toggle
- Inline preview for PDFs, `.docx`, `.xlsx`, images, audio, and video
- Offline queue with retry
- Contact exchange by QR code or base58-encoded `.onion` address
- Desktop tray integration
- Panic mode with wipe or decoy session
- Pinning and archiving conversations
- Battery-aware polling
- Link previews
- Typing indicators
- Scheduled messages (queued and delivered at a chosen time)
- Self-chat
- Detached chat windows on desktop
- Blocked contacts
- Encrypted backups
- Biometric and PIN unlock
- In-app auto-updater (Android APK and desktop installer)

## Not implemented

- Relay / proxy forwarding
  The settings exist in the UI, but there is no relay backend yet.

## Platforms

Built with Flutter. Supported targets:
- Linux
- Windows
- macOS
- Android
- iOS

## Building

You need a working Flutter toolchain.

### Linux dependencies

For tray support on Linux, install AppIndicator development libraries:

- Arch: `libayatana-appindicator`
- Ubuntu/Debian: `libayatana-appindicator3-dev`
- Older Ubuntu/Debian releases: `libappindicator3-dev`

On GNOME, the tray icon may require the [AppIndicator extension](https://extensions.gnome.org/extension/615/appindicator-support/).

### Build commands

```bash
flutter build linux
flutter build windows
flutter build macos
```

On desktop, the Tor binary is downloaded automatically on first launch.

## Release

Latest release: [v0.6.0](https://github.com/xmreur/prysm/releases)

## Notes

This is still a prototype.

The core model is in place, but transport, storage, and some UX and security details are still evolving. Expect breaking changes while the internals settle.

## Support

If you want to support development, donations are welcome.

- BTC: `bc1qev0zu7rnske4ee7as0t4tyh56uv6v0ga62wx8r`
- SOL: `2S6tZNNUH5sPp9PqszQ4XK4MN44SvLCkTwNuCVvRvtEP`
- ETH: `0x2934955fe95059ea470E0B81519BA59432eFe77a`
- XRP: `rHfoRsLjXrbAqxa7nJcXz6XdxDZm8M3sJT`
- XMR: `47ndq7fCdW9jTGKtXafwMgDJjxAw3cnWwjR6eq31pfXXKfqNHXq5w4B2D49oTKnTHGCRCgcU6D24oiyUD8Ha7iEJLCPGJsC`
- TON: `UQDEeapruNlAmSt9j4J9CNiuasJbF3OlCxzTZPJiq6hzKOFu`
- LTC: `ltc1qnsp6alkn2gzd4vpekya05l2caa3aqfmk9m7882`
