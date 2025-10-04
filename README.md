# Prysm

Prysm is a privacy‑first, cross‑platform P2P messenger prototype built with Flutter, designed to operate over Tor for metadata‑resistant communication and onion‑routed transport.

## Features

- End‑to‑end encrypted chat with Tor-based transport to minimize metadata exposure and avoid centralized relays.
- P2P identity model using deterministic keys/IDs compatible with .onion addressing and contact exchange.
- Cross‑platform UI with Flutter, structured for scalability and testability.

## Project status

This is an early‑stage prototype. APIs, storage, and networking layers are evolving. Expect breaking changes while core transport and identity layers stabilize.

## Tech stack

- Flutter (Dart) for cross‑platform UI.
- Tor embedding via process on desktop (TODO: add mobile)