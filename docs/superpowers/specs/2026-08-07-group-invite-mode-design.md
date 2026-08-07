# Group invite mode — design

Date: 2026-08-07 · Status: approved by the user, not yet implemented
Base: `main` @ `4f80b5e` (v0.6.4), after PR #128 was merged in `13a2137`
Branch: `feat/group-invite-mode`

## Problem

PR #128 closed M2 on the group control path by making `_resolveSenderIdentity` DB-only
(`lib/services/group_service.dart:549-561`). The accepted cost (CR8, option 1, chosen by
@xmreur) is that a group control message from a sender whose identity is not in the local
`users` table is dropped before processing (`group_service.dart:481-499`): the sender gets a
normal `200 {status: received}` ack and the invitee sees nothing. A first-contact group invite
therefore disappears silently. Issue #129 tracks the missing UX.

The three exits identified during the review were not equivalent:

1. accept the drop (chosen; no code, silent loss stays),
2. carry the inviter identity key in the invite and TOFU-persist it (wire format change, lets
   an unauthenticated peer seed a `users` row and pre-empt the real peer),
3. restore the Tor fetch for invites (smallest diff, reopens the M2 oracle).

This design adds a fourth exit and makes it selectable: **hold the invite as a request and
resolve the sender only when the user acts**. Option 3's benefit (first-contact invites are not
lost) without option 3's cost (no outbound traffic is triggered by unauthenticated inbound
traffic, so no oracle).

## Decision

A two-value user setting in Privacy Settings, defaulting to the new behaviour.

| Mode | Behaviour |
|---|---|
| `holdAsRequest` (default) | An invite from an unresolvable sender is stored, opaque and bounded, as a pending request the user can accept or discard. Nothing is decrypted, nothing is sent. |
| `contactsOnly` | Current merged behaviour: the invite is discarded on arrival. Nothing is stored, nothing is shown. |

The security boundary does not move in either mode: `_resolveSenderIdentity` stays DB-only, and
no code path fetches a profile for an unauthenticated sender.

## Components

### 1. `GroupInviteMode` (new: `lib/models/group_invite_mode.dart`)

Modelled verbatim on `PanicAction` (`lib/models/panic_action.dart:1-23`): a two-value enum with
`label` and `description` getters and a `fromJson` that falls back to the default on any
unknown value.

```dart
enum GroupInviteMode { holdAsRequest, contactsOnly }
```

User-facing strings (English, hardcoded — the app has no i18n layer):

| Value | `label` | `description` |
|---|---|---|
| `holdAsRequest` | `Hold invites from unknown senders` | `An invite from someone who is not in your contacts is kept as a request. Your device never contacts them, and you don't join the group until you accept.` |
| `contactsOnly` | `Only accept invites from contacts` | `Invites from anyone else are discarded the moment they arrive: nothing is stored, nothing is shown.` |

### 2. Setting plumbing

- `lib/models/settings.dart`: field `groupInviteMode`, constructor default
  `GroupInviteMode.holdAsRequest`, `toJson` by `.name`, `fromJson` via
  `GroupInviteMode.fromJson` with the same default duplicated (the file's existing convention),
  plus `copyWith`, `==`, `hashCode` — the same five-plus places every other field touches.
- `lib/services/settings_service.dart`: synchronous getter `groupInviteMode` and
  `setGroupInviteMode(GroupInviteMode)` following `setPanicAction`
  (`settings_service.dart:169-172` is the setter shape). No notifier is needed: privacy
  settings have none, consumers re-read the getter at point of use
  (`wake_hint_service.dart:85` is the service-layer precedent).

### 3. Setting UI (`lib/screens/privacy_settings_screen.dart`)

A new `PrysmSection` titled `Group invites`, above the `Emergency` section, containing two
inline `PrysmRadioRow<GroupInviteMode>` (`lib/ui/core/prysm_radio.dart:6-55`), `title` =
`label`, `subtitle` = `description`.

Inline radios, not the `PanicAction` bottom sheet (`panic_pin_settings_screen.dart:133-145`):
the requirement is that the user reads what **both** modes imply before choosing, and a sheet
hides them behind a tap.

### 4. Pending store (new: `lib/util/group_pending_invite_store.dart`)

Shape copied from `GroupSenderIndexStore` (`lib/util/group_sender_index_store.dart`): all-static
class, private constructor, one process-global `static final Mutex _mutex`, `ensureTable(Database)`
with `CREATE TABLE IF NOT EXISTS`, `@visibleForTesting resetForTest()`.

```sql
CREATE TABLE IF NOT EXISTS group_pending_invites (
  senderId   TEXT PRIMARY KEY,
  wire       TEXT NOT NULL,
  receivedAt INTEGER NOT NULL
)
```

The row is the raw `control-wrap-2` envelope, stored opaque. It is never decrypted while
pending: the payload is attacker-controlled and unauthenticated, so no field of it may reach
the UI or the database in parsed form.

Bounds — all three are load-bearing because this table is written by unauthenticated traffic
(`POST /message` authenticates nobody; the only rate limit is keyed on the sender-claimed
`senderId`, `lib/server/PrysmServer.dart:223-228`):

| Bound | Value | Rationale |
|---|---|---|
| Per sender | 1 row (the primary key); a newer invite replaces the older | One onion occupies one slot, not N. |
| Global | 20 senders; **at capacity the new row is refused**, no eviction | Evicting the oldest would let an attacker delete a genuine request. Refusing degrades to today's drop, which is already the accepted worst case. |
| Retention | 7 days, pruned on the write path | Self-healing: a table filled by an attacker frees itself without user action. |

Public API (all static, all inside `_mutex`):

- `Future<void> ensureTable(Database db)`
- `Future<bool> hold({required String senderId, required String wire})` — returns false when
  refused by the global cap.
- `Future<List<Map<String, Object?>>> pending()` — prunes expired rows, then returns the rest
  ordered by `receivedAt` descending.
- `Future<Map<String, Object?>?> take(String senderId)` — reads and deletes atomically.
- `Future<void> discard(String senderId)`
- `Future<int> count()` — prunes expired rows, then counts; this is what the two UI entry
  points display.
- `@visibleForTesting Future<void> resetForTest()`

Schema: `chat_app.db` goes to `version: 14` (`lib/util/db_helper.dart:64`), `ensureTable` is
added to `_createCryptoTables` (`db_helper.dart:99-102`) and a ladder step
`if (oldVersion < 14) { await _createCryptoTables(db); }` is appended to `_onUpgradeImpl`
(`db_helper.dart:143-217`), matching the `oldVersion < 13` step verbatim in shape.

### 5. Ingress (`lib/services/group_service.dart`)

One change, at the existing `senderKeys == null` branch (`:492-499`). Before the existing
`Logging.error` + `return false`:

- if `type == groupInviteType` and the mode is `holdAsRequest`, call
  `GroupPendingInviteStore.hold(...)` with the raw `encryptedPayload`;
- then drop exactly as today. A `hold` refused by the global cap changes nothing: the drop
  proceeds and the refusal is logged with the sender redacted, exactly like the drop itself.

`GroupService` reads the setting through `final SettingsService _settings = SettingsService();`,
the field-initialised singleton convention already used by `ReadReceiptService`
(`lib/services/read_receipt_service.dart:94`, consumed at `:135`). No constructor change: the
existing optional collaborators (`keyProvider`, `controlChannel`) are for objects tests must
replace, and the settings singleton is already driven by tests through
`SharedPreferences.setMockInitialValues`.

Everything else is unchanged: no fetch, the router still returns `200 {status: received}`
(`inbound_message_router.dart:360`), and `fetchSenderProfile` still fires only when `handled`
is true (`:356-358`). The four non-invite control types keep dropping unconditionally.

### 6. Requests UI (new: `lib/screens/invite_requests_screen.dart`)

Modelled on `BlockedContactsScreen` (`lib/screens/blocked_contacts_screen.dart:18-35`), same
`onClose` constructor shape, reached from two entry points:

- `settings_screen.dart`: a `_buildNavigationTile('Invite requests', …)` next to
  `Blocked contacts` (`settings_screen.dart:672-684`), with the pending count in the subtitle.
- `home_screen.dart`: a third footer row in the sidebar `ListView.builder`, same family as
  `Archived` / `Blocked` (`home_screen.dart:1459-1512`), rendered **only when the pending count
  is greater than zero**. The count comes from `GroupPendingInviteStore.count()`, loaded inside
  `loadUsers` (`home_screen.dart:777-875`) into a `_pendingInviteCount` field — `_blockedCount`
  (`:171`) is derived from the conversation list and cannot serve here — and
  `_sidebarFooterCount` (`:178-184`) gains a third conditional row.

Each row shows the sender's onion address, truncated, plus the date it arrived. No string from
the envelope is displayed — group name, avatar and roster stay unread until the invite
authenticates. Two actions:

- **Add contact and join** — runs the existing `ContactAddService.addContact` (which fetches
  `/public` over Tor, `contact_add_service.dart:80`, and stores the identity at `:123-131`).
  The fetch is a consequence of the user's tap, not of the inbound message: this is exactly
  what keeps M2 closed. On success, promote (below).
- **Discard** — `GroupPendingInviteStore.discard(senderId)`.

### 7. Promotion

Promotion never bypasses authentication: it re-plays the stored wire through
`GroupService.handleIncomingControlMessage(groupInviteType, wire, senderId)`, the same
authenticated path the message would have taken. The row is deleted whether the replay
succeeds or fails — a wire that fails to authenticate is garbage, and `PendingAuthMessageService`
sets the precedent of discarding what cannot be promoted
(`pending_auth_message_service.dart:57-66`).

Two triggers:

- the **Add contact and join** action, immediately after `addContact` returns success;
- a **sweep after unlock** that promotes any pending row whose sender has meanwhile become
  resolvable via `loadPeerIdentityFromDb` — this covers "the user added the contact by other
  means". It runs in `UnlockController.verifyUnlock`, immediately after the existing
  `PendingAuthMessageService(...).promotePendingAfterUnlock()` call
  (`lib/app/unlock_controller.dart:78-79`): same moment, same reason — the database is usable
  and identities can be imported. No new dependency is introduced into
  `contact_add_service.dart`.

### 8. Comment fix (`lib/services/group_service.dart:485-486`)

The merged comment states the payload "cannot even be read" without the sender identity. That
is false as a cryptographic statement: `_decryptDhAeadEnvelope` derives the AEAD key from the
recipient's agreement keypair and the ephemeral public key inside the envelope
(`lib/crypto/wire.dart:213-240`); the sender identity is consumed only by the Ed25519
verification (`wire.dart:375-406`, `416-424`). What is true is narrower: `decryptControlPayload`
requires it because it goes through the signed unwrap. The comment is corrected to say
"authenticated", not "read", because a future implementer of the pending flow would otherwise
conclude that showing invite content is impossible rather than forbidden.

## Data flow

```
POST /message (unauthenticated)
  -> InboundMessageRouter._handleGroupControl
  -> GroupService.handleIncomingControlMessage
       _resolveSenderIdentity  (DB only, never Tor)
         | null and type == group_invite and mode == holdAsRequest
         |    -> GroupPendingInviteStore.hold(senderId, wire)   [bounded, opaque]
         |    -> drop (200 received, no fetch)
         | null otherwise
         |    -> drop (200 received, no fetch)
         | resolved
              -> decryptControlPayload -> handlers -> fetchSenderProfile

User taps "Add contact and join"
  -> ContactAddService.addContact       [user-initiated Tor fetch of /public]
  -> GroupPendingInviteStore.take(senderId)
  -> GroupService.handleIncomingControlMessage(group_invite, wire, senderId)
  -> authenticated path, group created
```

## Error handling

- `hold` refused by the global cap: the invite is dropped exactly as in `contactsOnly` mode.
  No user-visible difference; the refusal is logged with the onion redacted
  (`Logging.redactOnion`, as the drop already does).
- Replay fails to authenticate: the row is deleted, no group is created, the failure is logged
  by the existing `catch` in `handleIncomingControlMessage` (`:508-515`).
- `addContact` fails (peer offline, fetch fails): the pending row is left in place so the user
  can retry; the UI surfaces the failure through the existing contact-add error path.
- A corrupt or foreign `group_pending_invites` row must not brick the screen: `pending()`
  tolerates rows it cannot use and prunes them, in the spirit of the pool-read hardening from
  PR #128 (`600270d`).

## Testing

Every test below must be verified failing on the pre-change code (red) before the change makes
it pass (green). Conventions: hand-written fakes, `sqflite_common_ffi` in-memory,
`setDatabaseForTest` / `resetForTest` seams, no new dependencies.

Two hygiene requirements specific to this feature: any test that drives the mode must call
`SharedPreferences.setMockInitialValues({})` first (`test/settings_migration_test.dart:6-16`
is the precedent — `save()` hits SharedPreferences), and must restore the default in
`tearDown`, because `SettingsService` is a process-wide singleton and a leaked mode would make
an unrelated test assert the wrong policy.

| # | Test | File |
|---|---|---|
| 1 | `groupInviteMode` defaults to `holdAsRequest`, survives a `toJson`/`fromJson` round trip, falls back to the default on an unknown stored value | `test/settings_migration_test.dart` (extend) |
| 2 | `contactsOnly`: an invite from an unresolvable sender leaves `group_pending_invites` empty, creates no group, fires no fetch | `test/security/group_invite_mode_test.dart` (new) |
| 3 | `holdAsRequest`: the same invite leaves **exactly one** pending row — and the merged `POLICY:` assertions still hold (no group, no members, no group key, no fetch) | same |
| 4 | A second invite from the same sender replaces the first (one row, newer `receivedAt`) | `test/security/group_pending_invite_store_test.dart` (new) |
| 5 | The 21st distinct sender is refused; the existing 20 rows are untouched | same |
| 6 | A row older than 7 days is pruned on the next write; a 6-day-old row is not | same |
| 7 | Promotion: with the sender's identity stored, replaying the held wire creates the group and deletes the row | `test/security/group_invite_mode_test.dart` |
| 8 | Promotion of a tampered wire deletes the row and creates no group | same |
| 9 | `chat_app.db` v13 → v14 upgrade on a real file: `group_pending_invites` exists afterwards, the rows of the other tables survive the upgrade, and a real `hold`/`count` round trip works against the upgraded file | `test/security/chat_db_v13_v14_upgrade_test.dart` (new, modelled on `chat_db_v10_v11_upgrade_test.dart`) |
| 10 | The existing `POLICY:` pair in `group_profile_fetch_gate_test.dart` still passes under the new default | existing file, unchanged assertions |

## Out of scope, stated

- **The other four control types.** `group_key_rotate`, `group_member_removed`,
  `group_profile_update`, `group_disappearing_timer` from a roster member whose `users` row has
  no identity material keep being dropped (CR8-c in the PR #128 triage). A pending request is
  not a remedy: those messages are not user-actionable, and the fix is identity resolution, not
  consent.
- **Placeholder `users` rows.** `DBHelper.ensureUserExist(senderId)` runs before authentication
  on all six inbound handlers (`inbound_message_router.dart:334, 371, 403, 436, 465, 496`), so
  an unauthenticated peer can create unbounded `Unknown - xxxxxx` contacts — proven executably
  on 2026-08-07: 50 POSTs with attacker-chosen `senderId` produced 50 `users` rows, all acked
  `200`, no group created, no fetch. Removing only the group-control call site would close
  nothing (a `text` message reaches `:496`), so it is recorded as a separate finding, not
  folded into this design.
- **Issue #130** (transport delivery outcome) is untouched.
- **The 1:1 DM residual** (`direct_message_auth.dart` resolving an unknown sender before
  verification, via `PrysmServer.dart:73`) is untouched.

## Why not the alternatives

- **Auto-fetch behind a setting** (option 3 as a toggle): the honest subtitle would read "anyone
  who knows your address can make your device reach out and learn you are online". An option
  that reopens a closed finding is a footgun with a label, and the benefit is available without
  the cost.
- **TOFU on an embedded inviter key** (option 2): requires a wire format change, breaks
  interoperability with older peers, and lets an unauthenticated peer bind an identity to an
  onion before its real owner does.
- **No setting, pending flow only**: it would still be an improvement, but the pending table is
  a real (bounded) attack surface, and a user who wants none of it has no way to say so.
