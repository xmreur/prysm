# Prysm — AI Agent Guide

## Project
Tor-only P2P messenger built with Flutter. No central server — each client exposes a Tor hidden service and communicates directly over `.onion` addresses.

- **Flutter** (Dart), targets Linux/Windows/macOS/Android/iOS
- **Tor** as transport layer (child process on desktop, native service on Android)
- **SQLite** (sqflite) for local message/contact storage
- **shelf** HTTP server for inbound messages
- **Double Ratchet** + X3DH for 1:1 forward secrecy, sender-key for groups

## Architecture
```
lib/
  client/          — WebSocket peer link, outbound transport
  constants/       — Shared constants
  crypto/          — Identity keys, AEAD, ratchet, group crypto, KDF
  database/        — SQLite access layer (messages, contacts, prefs, etc.)
  models/          — Data models (Contact, Conversation, Group, etc.)
  screens/         — Flutter UI screens
  server/          — shelf HTTP server, inbound message router
  services/        — Business logic (chat, file transfer, Tor, calls, etc.)
  theme/           — Theming system
  transport/       — Tor WebSocket/HTTP transport, connection management
  ui/              — Reusable UI components (core widgets, PrysmApp)
  util/            — Utilities (key manager, Tor lifecycle, logging, etc.)
```

## Commands
```bash
flutter analyze          # Lint check
flutter test             # Run all tests (no specific test runner, uses flutter_test)
flutter build linux      # Linux desktop build
flutter build windows    # Windows desktop build (--release)
flutter build macos      # macOS build (--release)
flutter build apk        # Android APK (--release)
flutter build ios        # iOS build (--release --no-codesign)
```

## Code Style
- Dart/Flutter conventions with `package:flutter_lints`
- `avoid_print: true` — use `Logging` utility for all logging
- `file_names: ignore` lint disabled
- Imports grouped: dart: → package: → relative, separated by blank lines
- StatefulWidgets with private State classes prefixed `_`
- Services are often singletons (`.instance` access pattern)
- `unawaited()` for fire-and-forget futures
- `mounted` checks after async gaps in StatefulWidgets
- Error handling: `Logging.error(msg, tag)` rather than rethrow

## GitHub Workflows
- `ci.yml` — `flutter analyze` + `flutter test` on every PR and push to main/master
- `build.yml` — Full platform release builds, triggered on `v*` tags
- `build-pr.yml` — On-demand PR build (codeowner comments `build:test`)

## Dependencies
Managed via `pubspec.yaml`. Dependabot configured in `.github/dependabot.yml`.

## Agent Instructions
- **SOLID principles always** — single responsibility, open/closed, Liskov substitution, interface segregation, dependency inversion
- Write idiomatic Dart/Flutter following existing patterns in the codebase
- Use `flutter analyze` to verify lint before considering work done
- Prefer existing singletons/services over creating new ones
- Tor and transport layers are complex — consult existing patterns before modifying
