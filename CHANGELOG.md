# Changelog

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
