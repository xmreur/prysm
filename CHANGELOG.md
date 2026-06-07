# Changelog

---

## Unreleased

### Features

- File attachment previews: inline snippets for text, PDF, .xlsx, and .docx; tap to open full viewer with download button; warning before downloading risky file types
- Desktop system tray (Linux, Windows, macOS): close hides to tray by default, unread badge, Tor status and pending queue in tooltip/menu
- Message reactions (emoji) on all message types in 1:1 and group chats — one emoji per user, synced over Tor

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
