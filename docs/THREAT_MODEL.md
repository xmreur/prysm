# Prysm Threat Model

This document describes what Prysm 0.4.0 (Crypto v2) is designed to protect against, and known limitations.

## Assets

- **Identity keys** — Ed25519 (sign) + X25519 (agree), stored encrypted in secure storage.
- **Message content** — 1:1 and group chat text, attachments, reactions, read receipts, edits.
- **Contact trust** — identity fingerprints verified via QR or fetched profile.
- **Local databases** — SQLite message stores, session state, group keys.

## Adversary model

| Actor | Capability |
|-------|------------|
| Network observer | Sees Tor traffic patterns, timing, volume (not plaintext if Tor works) |
| LAN attacker | Cannot reach loopback-bound Prysm server on same machine |
| Offline device thief | May extract storage; passphrase + Argon2id required for identity |
| Malicious peer | Sends invalid or replayed protocol messages |
| Compromised peer | Reads future messages after compromise (ratchet limits past exposure) |

**Out of scope (v0.4.0):** malware on device, forensic decoy encryption, post-quantum hybrids, metadata padding beyond Tor.

## Protections implemented

### Identity and unlock

- User-chosen unlock: **6-digit PIN** or **passphrase (≥12 chars)**; Argon2id KDF → AES-GCM wrapped identity blob.
- On-device lockout: 5 failed primary unlock attempts → 2-hour block (PIN and passphrase).
- Panic PIN remains optional 6-digit emergency code (separate from primary unlock).
- Clean-break migration from RSA/PIN era; no dual-decrypt legacy paths.

### 1:1 messaging

- Double Ratchet per peer (`session_state` in SQLite).
- X3DH-style prekey bundle on `/profile` (signed prekey + one-time prekey).
- AEAD only: AES-256-GCM / ChaCha20-Poly1305 — no PKCS#1, CBC, or raw ChaCha20.

### Groups

- Sender-key chain per member (`group-sender-1`) with epoch key rotation on member removal.
- Control payloads use X25519 key wrap + AEAD.

### Transport

- `PrysmServer` binds to `127.0.0.1` only.
- Server starts at app launch so Tor hidden service handshakes can complete.

### Backups

- Backup v2 with version gate; Argon2id instead of PBKDF2.
- Unknown backup versions rejected on restore.

## Residual risks

1. **Long-term identity compromise** — future 1:1 messages after ratchet state compromise; past messages protected by ratchet.
2. **Group epoch key** — compromise exposes messages in current epoch until rotation.
3. **No message padding** — message sizes may leak content type.
4. **Prototype status** — not independently audited; use with caution for high-risk scenarios.
5. **Coordinated upgrade** — 0.2.x peers incompatible; users must re-add contacts via QR.

## Trust assumptions

- Tor provides metadata-resistant transport to `.onion` services.
- `cryptography` and `argon2` packages are correct.
- OS secure storage (Keychain, Keystore, etc.) protects at-rest keys when device is locked.
- Users verify QR fingerprints or trust first-fetch profile keys.

## Verification checklist

- [ ] No RSA / PKCS#1 / CBC in message paths
- [ ] User-chosen PIN or passphrase unlock with Argon2id
- [ ] Unlock lockout after repeated failures
 [ ] Loopback server bind
- [ ] Ratchet sessions persisted per peer
- [ ] Group key rotation resets sender indices
- [ ] Backup version check on restore
