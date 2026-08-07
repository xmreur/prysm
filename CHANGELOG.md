# Changelog

---

## 0.6.4

### Features

- Local databases (messages, media, conversations) are now encrypted at rest with SQLCipher; each install gets its own key in secure storage and existing plaintext databases are migrated on first open
- Ratchet v3: forward-secret hash-chain sessions (`ratchet-3`), legacy signed key wraps, skipped-message-key windows and mutex-protected ratchet/prekey state
- Contact nicknames: assign a custom name to any contact, used in chat headers and the sidebar
- Network reachability monitoring via `connectivity_plus`, including a fix for desktop connectivity over systemd-network

### Security

- Database keys are written to secure storage and verified; a failed write aborts instead of silently weakening encryption
- Onions are redacted in every log sink and in the request log; developer log source aliases scrubbed
- Inbound WebSocket handshake now proves peer identity; a complete `101` status token is required; self-asserted sender IDs are rejected and sync hints must be signed
- Profile fetches are gated on the peer's online status; peer presence no longer acts as an oracle
- Group inbound messages are bounded by a rejecting seen-set floor, deduplicated by index, and failed inbound claims stay releasable; first-contact invite policy pinned to no-fetch
- Group control envelopes are signed, and the epoch key is never sent to a removed member
- `PeerProof.verify` rejects malformed signatures instead of throwing
- Server: inbound allocations and in-flight request-body memory are bounded and endpoints rate-limited
- Storage: path traversal rejected in blob IDs and download file names
- Tor: per-installation random control-port password; libopus fetched over Tor with a pinned SHA-256 checksum
- Ratchet: OTK-less bootstrap pinned, one-time prekeys consumed only after handshake verification, corrupt or future-dated prekey pools tolerated

### Fixes

- Group chat: soft-deleted pending messages are skipped, sender-index access is thread-safe, legacy identities are imported on upgrade
- Database migration is atomic: a cut between delete and rename is recovered, temp copies are only kept when the file is rejected

### Tests

- Containerized L3 end-to-end harness running two instances over real Tor (with CI integration)
- Coverage for the production `messages.db` opener, v11 security fixtures and the first-contact invite policy

### Platform

- SQLCipher `sqlite3` builds for all platforms
- CI: build-pr workflow updates and L3 harness gating

---

## 0.6.3

### Features

- Incoming call ringtone: a bundled ringtone loops while an incoming call is ringing (played via the platform audio session on iOS/macOS and via `paplay`/`pw-play`/`ffplay` on Linux)

### Fixes

- Incoming call notifications no longer play the default system sound — the ringtone plays through the call audio session instead
- iOS: OS share sheet removed so the iOS build succeeds again (sharing stays Android-only)

### Platform

- CI: build-pr workflow updates and iOS build fixes

---

## 0.6.2

### Features

- Android share sheet integration: share media from other apps directly into a Prysm chat

### Fixes

- Auto-updater version comparison now treats `-fix`/similar suffixes as older than the release and `-rc`/`-beta` as pre-release versions

### Platform

- CI: release assets use versioned filenames and iOS builds are bundled for upload

---

## 0.6.1

### Features

- Disappearing messages: per-conversation disappearing timer lets sent messages auto-delete after a configurable delay
- iOS release builds are now packaged as an unsigned `.ipa` for sideloading

### Fixes

- Tapping a notification on iOS opens the conversation it belongs to (notification center delegate was never wired up)
- Tests: characterizations aligned with the current schema (`expiresAt` column and `conversation_preferences` table)

---

## 0.6.0

### Platforms

- Full iOS support: Tor hidden service runs natively, VoIP call audio sessions wired into `AudioEngine`, Tor manager and connection controller ported
- macOS support and a dedicated CI build job (updater downloads required dylibs)
- CI now builds PR artifacts for testing, alongside the release workflow fixes

### Features

- Scheduled messages: long-press the send button to pick a date/time; the message is queued and delivered once its time arrives in both direct chats and groups. A message whose time passed while the app was closed is sent on the next flush rather than dropped
- In-app auto-updater: checks GitHub for the latest release on startup and from Settings, shows release notes, downloads and installs via the system APK installer on Android or a detached updater binary on desktop
- Update dialog preview and test flow for debug builds (no network, or dry-run against the latest release)

### Refactoring

- Solid modularization: DI-friendly crypto and facade layers, split `GroupService`/`ChatService` with interface segregation, `SideChannelTransport` split out, `MessagesDb` split into DAOs, composition root and bootstrap, `ChatScreenController` and `MessageViewMapper` extracted

### Fixes

- Group chat messages from your own other devices/sessions decrypt correctly (own sender identity resolved from keystore)
- App label and executable name show as "Prysm" instead of lowercase "prysm" on Android and desktop
- Updater stores its binary in the application support directory
- CI: fixed wrong path in the Windows build for CD, Android/iOS bundle identifiers and debug keystore configuration

---

## 0.2.0

### Offline sync & reliability

- Global 1:1 pending message retry (no longer requires reopening each chat)
- Pending send queue filtered by peer so messages are not mis-routed
- Unified sync coordinator flushes all outbound queues (1:1, group, control, history relay)
- Immediate pending flush when Tor reconnects or is manually restarted
- Sidebar refreshes on inbound messages instead of waiting for the poll timer

### Performance & startup

- Parallel and deferred sidebar load (conversation list appears before previews/unread finish)
- SQL-based last-message previews and unread counts (messages DB v6)
- Debounced sidebar refresh with 30s idle poll interval
- Database mutex on chat poll reads to reduce SQLITE_BUSY races
- Profile fetch TTL cache and persisted peer public keys (less Tor traffic)
- Desktop updater check deferred until after HomeScreen is shown
- Tor bootstrap progress shown on PIN and Tor splash screens
- AES file decryption moved off the UI thread

### Tor & home UI

- Tor status chip moved to the top app bar
- Redesigned empty home screen with Prysm ID card and quick actions
- Tor no longer shuts down on `inactive` lifecycle events (focus loss, dialogs)
- 15s Tor health monitor with reconnect-triggered sync

### Settings

- Configurable download location for saved files (Settings → Data → Download Location)

### Fixes

- Group chat image decrypt updates the live message list correctly
- Group key cached in memory for the session; invalidated on key rotation
- `GroupChatService.seedNewestTimestamp` avoids re-processing history on every poll

### Tests

- Pending routing, SQL unread/preview queries, sync coordinator reconnect behavior


### Group chat

- P2P group messaging (max 5 members) with shared AES group key
- Hybrid v2 control envelopes for invites and key distribution
- Scoped message IDs (`groupId::wireId`) to prevent cross-group collisions (messages DB v5)
- Member roster sync via invite re-send on add member
- History relay to newly joined members with pending retry queue
- Global pending send queue for group messages (retries while app is open)

### Fixes

- Group read receipts use scoped message IDs
- Stale group invites ignored when local `keyVersion` is newer
- Key rotation control messages queued when peer is offline
- Inbound message timestamps preserved for history relay ordering
- Partial fan-out no longer marks messages as fully sent when some peers fail
- Add-contact blocked when peer public key cannot be fetched
- `WidgetsBindingObserver` registered for lifecycle Tor shutdown

### UX

- Group chat: reply, linkification, voice playback, file download, delete, failed-send retry
- Group rename in settings
- Sidebar last-message previews and unread badges
- Notification tap opens conversation
- Tor boot screen with retry on failure
