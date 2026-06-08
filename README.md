# Prysm

[🇬🇧 English](README.md) | [🇮🇹 Italiano](README.it.md)

<p align="center">
  <img src="https://cdn.discordapp.com/icons/1420770528691617928/e685f1b4b88adc1b6a8da534633b7fca.png?size=512" width="320" alt="Prysm logo">
</p>

Prysm is a Tor-only P2P messenger built with Flutter.

There is no central server. Each client exposes its own Tor hidden service, receives messages directly over its `.onion` address, and sends outbound messages through Tor. If a peer is offline, messages stay in a local queue and retry later.

## Overview

Prysm runs as a direct peer-to-peer messenger over Tor hidden services.

On desktop, Tor is started as a child process. On Android, it is started through a native service. The app also runs a local HTTP server with `shelf`, listening on port `12345`, which Tor exposes as `your-address.onion:80`. Outbound messages are sent through Tor's SOCKS5 proxy to `peer-address.onion:80/message`. `shelf` is a Dart server middleware library commonly used to compose lightweight HTTP servers, which matches this local transport model well [web:71][web:77].

There are no relay servers right now. Relay settings exist in the UI, but they are placeholders and are not implemented yet.

## Message flow

If both peers are online, messages usually arrive within a few seconds.

If the destination is offline or unreachable, Prysm stores the message locally in SQLite and retries with exponential backoff. This lets the app behave like an asynchronous messenger without introducing centralized infrastructure [web:27].

## Encryption

### Identity

- RSA-4096 keypair, generated locally.
- Private key encrypted at rest with AES-256-GCM.
- Key encryption key derived from the user's PIN with PBKDF2-HMAC-SHA256 using 100k iterations.

Tor onion addresses are separate from Prysm identity keys. Tor generates the `.onion` service identity from its own key material. Prysm's RSA keys are only used for application-level encryption.

### Direct messages

- Text messages use RSA PKCS#1 v1.5.
- Files, images, and audio use a hybrid envelope:
  - random AES-256-CBC key per attachment
  - attachment encrypted with AES
  - AES key encrypted with RSA for both sender and recipient

### Group messages

- Group content uses AES-256-GCM with a shared group key.
- On invite, the group key is RSA-encrypted for each member.
- On member removal, the group key is rotated.

## Implemented

- 1:1 encrypted messaging
- Attachments: images, files, audio, voice messages
- Group chat with invite flow, key rotation, and member removal
- Emoji reactions
- Message editing and deletion
- Read receipts with toggle
- Inline preview for PDFs, `.docx`, `.xlsx`, images, audio, and video
- Offline queue with retry
- Contact exchange by QR code or base58-encoded `.onion` address
- Desktop tray integration
- Panic mode with wipe or decoy session
- Pinning and archiving conversations
- Battery-aware polling
- Link previews

## Not implemented

- Relay / proxy forwarding  
  The settings exist in the UI, but there is no relay backend yet.

## Platforms

Built with Flutter.

Current targets:
- Linux
- Windows
- macOS
- Android
- iOS

Prysm’s public site also describes it as a cross-platform Flutter-based Tor messenger in active development [web:27].

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

Latest release: [v0.2.0](https://github.com/xmreur/prysm/releases)

## Notes

This is still a prototype.

The core model is in place, but transport, storage, and some UX/security details are still evolving. Expect breaking changes while the internals settle.

## Support

If you want to support development, donations are welcome.

- BTC: `bc1qev0zu7rnske4ee7as0t4tyh56uv6v0ga62wx8r`
- SOL: `2S6tZNNUH5sPp9PqszQ4XK4MN44SvLCkTwNuCVvRvtEP`
- ETH: `0x2934955fe95059ea470E0B81519BA59432eFe77a`
- XRP: `rHfoRsLjXrbAqxa7nJcXz6XdxDZm8M3sJT`
- XMR: `47ndq7fCdW9jTGKtXafwMgDJjxAw3cnWwjR6eq31pfXXKfqNHXq5w4B2D49oTKnTHGCRCgcU6D24oiyUD8Ha7iEJLCPGJsC`
- TON: `UQDEeapruNlAmSt9j4J9CNiuasJbF3OlCxzTZPJiq6hzKOFu`
- LTC: `ltc1qnsp6alkn2gzd4vpekya05l2caa3aqfmk9m7882`