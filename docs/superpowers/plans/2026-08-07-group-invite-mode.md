# Group Invite Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user choose, in Privacy Settings, whether a group invite from someone not in
their contacts is discarded on arrival (today's merged behaviour) or held as a pending request
they can accept — with both modes explained by a subtitle at the point of choice.

**Architecture:** A two-value enum setting read synchronously by `GroupService` at the existing
unknown-sender drop branch. In hold mode the raw, still-encrypted control envelope is written to
a new bounded table in `chat_app.db` and nothing else happens: no decryption, no outbound
traffic, same `200 received` ack. The user accepts from a dedicated screen, which runs the
existing user-initiated contact-add (the only fetch in the whole flow) and then replays the
stored envelope through the normal authenticated path.

**Tech Stack:** Flutter/Dart, `sqflite` (+ `sqflite_common_ffi` in tests), `mutex`,
`shared_preferences`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-07-group-invite-mode-design.md`

## Global Constraints

- No new dependencies, in neither `dependencies` nor `dev_dependencies`.
- `flutter analyze` must report **0 issues** and `flutter test` must stay green before every
  commit. Baseline on this branch: `935 passed, 1 skipped`.
- User-facing strings are hardcoded English (the app has no i18n layer). Comments and commit
  messages in English; conventional one-line commit subjects.
- Reuse existing patterns; a second convention beside an existing one is prohibited. The
  patterns this plan follows are named per task with `path:line`.
- Tests: hand-written fakes, `sqflite_common_ffi` in-memory databases, the
  `setDatabaseForTest` / `resetForTest` seams. Every test must be seen failing before the
  implementation makes it pass.
- **The security boundary does not move.** `_resolveSenderIdentity` stays DB-only; nothing in
  this plan may introduce an outbound fetch triggered by inbound traffic. The existing
  `POLICY:` tests in `test/security/group_profile_fetch_gate_test.dart` must stay green with
  their assertions unchanged.
- A pending invite is **never decrypted while pending**. No field of an unauthenticated
  payload may reach the UI or be parsed into the database.
- Onion addresses in logs go through `Logging.redactOnion`.
- Subagents do not run git commands that mutate state and do not run the full suite; the
  controller commits and runs the gate.

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `lib/models/group_invite_mode.dart` (new) | The two-value enum plus the user-facing `label`/`description` for each mode | 1 |
| `lib/models/settings.dart` | Carries `groupInviteMode` through the settings JSON | 1 |
| `lib/services/settings_service.dart` | Synchronous getter + persisting setter | 1 |
| `lib/util/group_pending_invite_store.dart` (new) | The bounded pending table and its whole API | 2 |
| `lib/util/db_helper.dart` | Schema version 14 + create/upgrade wiring | 2 |
| `lib/services/group_service.dart` | Holds the invite at the existing drop branch; comment fix | 3 |
| `lib/services/group_invite_promoter.dart` (new) | Replays a held envelope through the authenticated path | 4 |
| `lib/screens/home/home_screen.dart` | One-shot promotion sweep; sidebar footer row | 4, 6 |
| `lib/screens/privacy_settings_screen.dart` | The two radio rows with both subtitles | 5 |
| `lib/screens/invite_requests_screen.dart` (new) | The list of pending requests with accept/discard | 6 |
| `lib/screens/settings_screen.dart` | Navigation tile into the new screen | 6 |

---

### Task 1: The setting

**Files:**
- Create: `lib/models/group_invite_mode.dart`
- Modify: `lib/models/settings.dart` (field, ctor default, `toJson`, `fromJson`, `copyWith`, `==`, `hashCode`)
- Modify: `lib/services/settings_service.dart` (getter near `:59`, setter after `:219`)
- Test: `test/group_invite_mode_settings_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum GroupInviteMode { holdAsRequest, contactsOnly }` with `String get label`,
  `String get description`, `static GroupInviteMode fromJson(String?)`;
  `Settings.groupInviteMode`; `SettingsService().groupInviteMode` (sync getter) and
  `Future<void> SettingsService().setGroupInviteMode(GroupInviteMode)`.

- [ ] **Step 1: Write the failing test**

Create `test/group_invite_mode_settings_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/models/group_invite_mode.dart';
import 'package:prysm/models/settings.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the default mode holds invites from unknown senders', () {
    expect(Settings().groupInviteMode, GroupInviteMode.holdAsRequest);
  });

  test('the mode survives a JSON round trip', () {
    final restored = Settings.fromJson(
      Settings(groupInviteMode: GroupInviteMode.contactsOnly).toJson(),
    );
    expect(restored.groupInviteMode, GroupInviteMode.contactsOnly);
  });

  test('an unknown stored value falls back to the default', () {
    expect(
      Settings.fromJson({'groupInviteMode': 'whatever-a-future-build-wrote'})
          .groupInviteMode,
      GroupInviteMode.holdAsRequest,
    );
  });

  test('both modes carry a label and an explanatory description', () {
    for (final mode in GroupInviteMode.values) {
      expect(mode.label, isNotEmpty);
      expect(mode.description, isNotEmpty);
      expect(mode.description.length, greaterThan(40));
    }
  });

  test('the setter persists the mode through SettingsService', () async {
    SharedPreferences.setMockInitialValues({});
    final service = SettingsService();
    addTearDown(
      () => service.setGroupInviteMode(GroupInviteMode.holdAsRequest),
    );

    await service.setGroupInviteMode(GroupInviteMode.contactsOnly);
    expect(service.groupInviteMode, GroupInviteMode.contactsOnly);

    await service.load();
    expect(service.groupInviteMode, GroupInviteMode.contactsOnly);
  });
}
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `flutter test test/group_invite_mode_settings_test.dart`
Expected: compile failure — `Error: Couldn't resolve the package 'prysm/models/group_invite_mode.dart'`.

- [ ] **Step 3: Create the enum**

Create `lib/models/group_invite_mode.dart` (shape copied verbatim from
`lib/models/panic_action.dart:1-23`):

```dart
/// What happens to a group invite whose sender's identity is not in the
/// local user store.
///
/// The security boundary is the same in both modes: the sender is never
/// resolved over the network on an inbound message (M2). The choice is only
/// whether the invite is kept for the user to decide on, or dropped.
enum GroupInviteMode {
  holdAsRequest,
  contactsOnly;

  String get label => switch (this) {
        GroupInviteMode.holdAsRequest => 'Hold invites from unknown senders',
        GroupInviteMode.contactsOnly => 'Only accept invites from contacts',
      };

  String get description => switch (this) {
        GroupInviteMode.holdAsRequest =>
          'An invite from someone who is not in your contacts is kept as a '
              "request. Your device never contacts them, and you don't join "
              'the group until you accept.',
        GroupInviteMode.contactsOnly =>
          'Invites from anyone else are discarded the moment they arrive: '
              'nothing is stored, nothing is shown.',
      };

  static GroupInviteMode fromJson(String? value) {
    return GroupInviteMode.values.firstWhere(
      (m) => m.name == value,
      orElse: () => GroupInviteMode.holdAsRequest,
    );
  }
}
```

- [ ] **Step 4: Thread the field through `Settings`**

In `lib/models/settings.dart`, six edits, each mirroring the `panicAction` line beside it:

1. import, after `import 'package:prysm/models/appearance_settings.dart';`:

```dart
import 'package:prysm/models/group_invite_mode.dart';
```

2. field, in the `// Privacy` block after `final PanicAction panicAction;`:

```dart
  final GroupInviteMode groupInviteMode;
```

3. constructor default, after `this.panicAction = PanicAction.decoy,`:

```dart
    this.groupInviteMode = GroupInviteMode.holdAsRequest,
```

4. `toJson`, after `'panicAction': panicAction.name,`:

```dart
    'groupInviteMode': groupInviteMode.name,
```

5. `fromJson`, after `panicAction: PanicAction.fromJson(json['panicAction'] as String?),`:

```dart
    groupInviteMode: GroupInviteMode.fromJson(
      json['groupInviteMode'] as String?,
    ),
```

6. `copyWith` — parameter after `PanicAction? panicAction,`:

```dart
    GroupInviteMode? groupInviteMode,
```

and mapping after `panicAction: panicAction ?? this.panicAction,`:

```dart
    groupInviteMode: groupInviteMode ?? this.groupInviteMode,
```

7. `operator ==`, after `other.panicAction == panicAction &&`:

```dart
        other.groupInviteMode == groupInviteMode &&
```

8. `hashCode`, after `panicAction.hashCode ^`:

```dart
        groupInviteMode.hashCode ^
```

- [ ] **Step 5: Add the getter and setter**

In `lib/services/settings_service.dart`, import `package:prysm/models/group_invite_mode.dart`,
then add the getter directly under `PanicAction get panicAction => _settings.panicAction;`:

```dart
  GroupInviteMode get groupInviteMode => _settings.groupInviteMode;
```

and the setter directly under the closing brace of `setPanicAction`:

```dart
  Future<void> setGroupInviteMode(GroupInviteMode value) async {
    _settings = _settings.copyWith(groupInviteMode: value);
    await save();
  }
```

- [ ] **Step 6: Run the test and watch it pass**

Run: `flutter test test/group_invite_mode_settings_test.dart`
Expected: `+5: All tests passed!`

- [ ] **Step 7: Commit (controller)**

```bash
git add lib/models/group_invite_mode.dart lib/models/settings.dart \
        lib/services/settings_service.dart test/group_invite_mode_settings_test.dart
git commit -m "feat(settings): add the group invite mode setting"
```

---

### Task 2: The bounded pending store and schema v14

**Files:**
- Create: `lib/util/group_pending_invite_store.dart`
- Modify: `lib/util/db_helper.dart` (`version: 13` → `14` at `:64`; `_createCryptoTables` at `:99-102`; a new ladder step at the end of `_onUpgradeImpl`, after the `oldVersion < 13` block that ends at `:217`)
- Test: `test/security/group_pending_invite_store_test.dart`
- Test: `test/security/chat_db_v13_v14_upgrade_test.dart`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `GroupPendingInviteStore.ensureTable(Database db) -> Future<void>`
  - `GroupPendingInviteStore.hold({required String senderId, required String wire}) -> Future<bool>`
  - `GroupPendingInviteStore.pending() -> Future<List<Map<String, Object?>>>` — rows
    `{senderId: String, wire: String, receivedAt: int}`, newest first
  - `GroupPendingInviteStore.count() -> Future<int>`
  - `GroupPendingInviteStore.take(String senderId) -> Future<String?>` — the wire, deleted
  - `GroupPendingInviteStore.discard(String senderId) -> Future<void>`
  - constants `maxPendingSenders = 20`, `retention = Duration(days: 7)`

- [ ] **Step 1: Write the failing store test**

Create `test/security/group_pending_invite_store_test.dart`:

```dart
// The pending-invite table is written by UNAUTHENTICATED inbound traffic:
// POST /message authenticates nobody and its only rate limit is keyed on the
// sender-claimed senderId (PrysmServer.dart:223-228). These tests pin the
// three bounds that keep it from being a remote write primitive.
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_pending_invite_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openDb() async {
  final db = await databaseFactory.openDatabase(
    '${inMemoryDatabasePath}_${DateTime.now().microsecondsSinceEpoch}',
    options: OpenDatabaseOptions(version: 1),
  );
  await GroupPendingInviteStore.ensureTable(db);
  return db;
}

void main() {
  late Database db;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await _openDb();
    DBHelper.setDatabaseForTest(db);
  });

  tearDown(() async {
    await db.close();
    DBHelper.setDatabaseForTest(null);
  });

  test('a held invite comes back, newest first', () async {
    expect(await GroupPendingInviteStore.hold(
      senderId: 'a.onion',
      wire: 'wire-a',
    ), isTrue);
    expect(await GroupPendingInviteStore.hold(
      senderId: 'b.onion',
      wire: 'wire-b',
    ), isTrue);

    final rows = await GroupPendingInviteStore.pending();
    expect(rows, hasLength(2));
    expect(rows.first['senderId'], 'b.onion');
    expect(rows.first['wire'], 'wire-b');
    expect(await GroupPendingInviteStore.count(), 2);
  });

  test('a second invite from the same sender replaces the first', () async {
    await GroupPendingInviteStore.hold(senderId: 'a.onion', wire: 'first');
    await GroupPendingInviteStore.hold(senderId: 'a.onion', wire: 'second');

    final rows = await GroupPendingInviteStore.pending();
    expect(rows, hasLength(1));
    expect(rows.single['wire'], 'second');
  });

  test('the 21st distinct sender is refused and changes nothing', () async {
    for (var i = 0; i < GroupPendingInviteStore.maxPendingSenders; i++) {
      expect(
        await GroupPendingInviteStore.hold(senderId: 's$i.onion', wire: 'w$i'),
        isTrue,
      );
    }

    expect(
      await GroupPendingInviteStore.hold(
        senderId: 'one-too-many.onion',
        wire: 'w',
      ),
      isFalse,
    );
    expect(await GroupPendingInviteStore.count(),
        GroupPendingInviteStore.maxPendingSenders);
    // An existing sender may still refresh its own slot at capacity.
    expect(
      await GroupPendingInviteStore.hold(senderId: 's0.onion', wire: 'fresh'),
      isTrue,
    );
  });

  test('a row past the retention window is pruned, a fresh one is kept',
      () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final expired = now - GroupPendingInviteStore.retention.inMilliseconds - 1;
    final fresh = now - GroupPendingInviteStore.retention.inMilliseconds ~/ 2;
    await db.insert('group_pending_invites', {
      'senderId': 'old.onion',
      'wire': 'old',
      'receivedAt': expired,
    });
    await db.insert('group_pending_invites', {
      'senderId': 'recent.onion',
      'wire': 'recent',
      'receivedAt': fresh,
    });

    expect(await GroupPendingInviteStore.count(), 1);
    final rows = await GroupPendingInviteStore.pending();
    expect(rows.single['senderId'], 'recent.onion');
  });

  test('take returns the wire once and deletes the row', () async {
    await GroupPendingInviteStore.hold(senderId: 'a.onion', wire: 'wire-a');

    expect(await GroupPendingInviteStore.take('a.onion'), 'wire-a');
    expect(await GroupPendingInviteStore.take('a.onion'), isNull);
    expect(await GroupPendingInviteStore.count(), 0);
  });

  test('discard removes the row without returning it', () async {
    await GroupPendingInviteStore.hold(senderId: 'a.onion', wire: 'wire-a');

    await GroupPendingInviteStore.discard('a.onion');
    expect(await GroupPendingInviteStore.count(), 0);
  });
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `flutter test test/security/group_pending_invite_store_test.dart`
Expected: compile failure — `Couldn't resolve the package 'prysm/util/group_pending_invite_store.dart'`.

- [ ] **Step 3: Write the store**

Create `lib/util/group_pending_invite_store.dart`. Structure (private ctor, one static `Mutex`,
`ensureTable` with `CREATE TABLE IF NOT EXISTS`) copied from
`lib/util/group_sender_index_store.dart:7-70`:

```dart
import 'package:mutex/mutex.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Group invites received from a sender whose identity is not in the local
/// user store, kept so the user can decide instead of losing them silently.
///
/// The stored [wire] is the raw `control-wrap-2` envelope and is NEVER
/// decrypted while pending: it is unauthenticated, attacker-controlled input,
/// so nothing from it may reach the UI or be parsed into the database. It is
/// only ever replayed through the normal authenticated path once the sender's
/// identity is locally known.
///
/// This table is written by unauthenticated traffic — `POST /message`
/// authenticates nobody and its only rate limit is keyed on the
/// sender-claimed `senderId` — so all three bounds below are load-bearing,
/// not tuning.
class GroupPendingInviteStore {
  GroupPendingInviteStore._();

  static final Mutex _mutex = Mutex();

  /// How many distinct senders may hold a pending invite at once.
  ///
  /// At capacity a NEW sender is refused rather than evicting the oldest
  /// row: eviction would let an attacker with cheap throwaway onions delete
  /// a genuine request, while refusal only degrades to the drop that was the
  /// accepted behaviour before this feature existed.
  static const int maxPendingSenders = 20;

  /// How long a pending invite survives without a decision. Bounds the table
  /// in time as well as in rows, so one filled by an attacker frees itself
  /// with no user action.
  static const Duration retention = Duration(days: 7);

  static Future<void> ensureTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_pending_invites (
        senderId TEXT PRIMARY KEY,
        wire TEXT NOT NULL,
        receivedAt INTEGER NOT NULL
      )
    ''');
  }

  /// Keeps [wire] as the pending invite for [senderId], replacing any
  /// previous one from the same sender. Returns false when the global cap
  /// refuses a new sender; the caller drops the invite exactly as it would
  /// with the feature off.
  static Future<bool> hold({
    required String senderId,
    required String wire,
  }) async {
    return _mutex.protect(() async {
      final db = await DBHelper.database;
      await _pruneExpired(db);

      final existing = await db.query(
        'group_pending_invites',
        columns: ['senderId'],
        where: 'senderId = ?',
        whereArgs: [senderId],
        limit: 1,
      );
      if (existing.isEmpty && await _count(db) >= maxPendingSenders) {
        return false;
      }

      await db.insert(
        'group_pending_invites',
        {
          'senderId': senderId,
          'wire': wire,
          'receivedAt': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return true;
    });
  }

  /// Pending invites, newest first. Expired rows are pruned first, so a
  /// caller never sees a row it must filter itself.
  static Future<List<Map<String, Object?>>> pending() async {
    return _mutex.protect(() async {
      final db = await DBHelper.database;
      await _pruneExpired(db);
      return db.query('group_pending_invites', orderBy: 'receivedAt DESC');
    });
  }

  static Future<int> count() async {
    return _mutex.protect(() async {
      final db = await DBHelper.database;
      await _pruneExpired(db);
      return _count(db);
    });
  }

  /// Returns the held envelope for [senderId] and deletes the row in the
  /// same critical section, so a second caller cannot replay it.
  static Future<String?> take(String senderId) async {
    return _mutex.protect(() async {
      final db = await DBHelper.database;
      final rows = await db.query(
        'group_pending_invites',
        where: 'senderId = ?',
        whereArgs: [senderId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      await db.delete(
        'group_pending_invites',
        where: 'senderId = ?',
        whereArgs: [senderId],
      );
      return rows.first['wire'] as String?;
    });
  }

  static Future<void> discard(String senderId) async {
    await _mutex.protect(() async {
      final db = await DBHelper.database;
      await db.delete(
        'group_pending_invites',
        where: 'senderId = ?',
        whereArgs: [senderId],
      );
    });
  }

  static Future<int> _count(Database db) async {
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM group_pending_invites'),
        ) ??
        0;
  }

  static Future<void> _pruneExpired(Database db) async {
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - retention.inMilliseconds;
    await db.delete(
      'group_pending_invites',
      where: 'receivedAt < ?',
      whereArgs: [cutoff],
    );
  }
}
```

- [ ] **Step 4: Wire the schema**

In `lib/util/db_helper.dart`:

1. import `package:prysm/util/group_pending_invite_store.dart` beside the
   `group_sender_index_store.dart` import;
2. `version: 13,` at `:64` becomes `version: 14,`;
3. `_createCryptoTables` gains the new table:

```dart
  static Future<void> _createCryptoTables(Database db) async {
    await RatchetSessionStore.ensureTable(db);
    await GroupSenderIndexStore.ensureTable(db);
    await GroupPendingInviteStore.ensureTable(db);
  }
```

4. a new ladder step, appended immediately after the `if (oldVersion < 13) { ... }` block that
   ends at `:217`, in the same shape as its neighbour:

```dart
      if (oldVersion < 14) {
        // group_pending_invites (the bounded store for invites from senders
        // whose identity is not local yet) is created by
        // GroupPendingInviteStore.ensureTable. Every ensureTable in
        // _createCryptoTables is CREATE TABLE IF NOT EXISTS, so replaying
        // the step on a database that already has the other crypto tables
        // only adds the missing one.
        await _createCryptoTables(db);
      }
```

- [ ] **Step 5: Run the store test and watch it pass**

Run: `flutter test test/security/group_pending_invite_store_test.dart`
Expected: `+6: All tests passed!`

- [ ] **Step 6: Write the failing upgrade test**

Create `test/security/chat_db_v13_v14_upgrade_test.dart` by copying
`test/security/chat_db_v10_v11_upgrade_test.dart` and adapting it:

- keep `setUpAll` (`sqfliteFfiInit`, `databaseFactory = databaseFactoryFfi`), `setUp` (temp dir,
  `CryptoKeyStore.setUseInMemoryStorageOnly(true)`, the `path_provider` MethodChannel mock) and
  `tearDown` (`DBHelper.closeForWipe()`, `DBHelper.setDatabaseForTest(null)`, delete temp dir)
  **verbatim** from the existing file;
- write a `buildV13Fixture` modelled on that file's `buildV11Fixture`: open the file directly
  with `databaseFactory.openDatabase(path, options: OpenDatabaseOptions(singleInstance: false))`,
  create every table the v13 schema has by calling the real helpers
  (`DBHelper` group tables DDL copied as the existing fixture does,
  `ConversationPreferencesDb.createTable`, `BlockedUsersDb.createTable`,
  `CallLogsDb.createTable`, `RatchetSessionStore.ensureTable`,
  `GroupSenderIndexStore.ensureTable`), seed one `users` row and one
  `group_sender_index` row with `nextIndex = 7`, set `PRAGMA user_version = 13`;
- fixture guards, each its own `expect` (a single `isNot(containsAll([...]))` is satisfied by
  the absence of one element and would be vacuous — this is the CN4 lesson from PR #128):

```dart
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      ['group_pending_invites'],
    );
    expect(tables, isEmpty, reason: 'the v13 fixture must not have the table');
    expect(
      Sqflite.firstIntValue(await db.rawQuery('PRAGMA user_version')),
      13,
    );
```

- the test body:

```dart
  test('v13 -> v14 adds group_pending_invites and keeps existing rows',
      () async {
    await buildV13Fixture();

    final db = await DBHelper.database;

    expect(Sqflite.firstIntValue(await db.rawQuery('PRAGMA user_version')), 14);
    expect(
      await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        ['group_pending_invites'],
      ),
      hasLength(1),
    );
    // The upgrade is not allowed to lose what was already there.
    expect(await db.query('users'), hasLength(1));
    expect(
      (await db.query('group_sender_index')).single['nextIndex'],
      7,
    );
    // The upgraded file works with the real store, not just the schema.
    expect(
      await GroupPendingInviteStore.hold(
        senderId: 'a.onion',
        wire: 'wire-a',
      ),
      isTrue,
    );
    expect(await GroupPendingInviteStore.count(), 1);
  });
```

- [ ] **Step 7: Run the upgrade test and watch it pass**

Run: `flutter test test/security/chat_db_v13_v14_upgrade_test.dart`
Expected: `+1: All tests passed!`

Then prove the fixture guard bites: temporarily add
`await GroupPendingInviteStore.ensureTable(db);` to `buildV13Fixture`, re-run, and confirm the
guard fails with `the v13 fixture must not have the table`. Remove it and re-run green. A guard
that cannot fail is worse than no guard.

- [ ] **Step 8: Commit (controller)**

```bash
git add lib/util/group_pending_invite_store.dart lib/util/db_helper.dart \
        test/security/group_pending_invite_store_test.dart \
        test/security/chat_db_v13_v14_upgrade_test.dart
git commit -m "feat(group): add a bounded store for pending first-contact invites"
```

---

### Task 3: Hold the invite at the drop branch

**Files:**
- Modify: `lib/services/group_service.dart` (`:481-499` — the comment block and the `senderKeys == null` branch)
- Test: `test/security/group_invite_mode_test.dart`

**Interfaces:**
- Consumes: `SettingsService().groupInviteMode` (Task 1),
  `GroupPendingInviteStore.hold(...)` / `.count()` / `.pending()` (Task 2).
- Produces: no new API. Behavioural contract: in `holdAsRequest` mode a `group_invite` from an
  unresolvable sender leaves exactly one `group_pending_invites` row; everything else about the
  drop is unchanged.

- [ ] **Step 1: Write the failing test**

Create `test/security/group_invite_mode_test.dart`. Copy the harness from
`test/security/group_profile_fetch_gate_test.dart` — `_publicKeys`, `_openMessagesDb`,
`_openDbHelperDb` (add `await GroupPendingInviteStore.ensureTable(db);` next to the
`GroupSenderIndexStore.ensureTable(db)` call), `_inviteMessage`, the `_ProfileNetworkOverrides`
fake HTTP layer, and the `setUpAll`/`setUp`/`tearDown` blocks — then:

```dart
  group('group invite mode', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() async {
      await SettingsService().setGroupInviteMode(GroupInviteMode.holdAsRequest);
    });

    test(
      'contactsOnly: an invite from an unresolvable sender is dropped and '
      'nothing is stored', () async {
        await SettingsService().setGroupInviteMode(
          GroupInviteMode.contactsOnly,
        );
        final inviter = await IdentityKeyPair.generate();
        peerProfiles['stranger.onion'] =
            jsonEncode(await inviter.toPublicJson());

        final result = await router.handleMessage(await _inviteMessage(
          id: 'm1',
          inviterId: 'stranger.onion',
          inviter: inviter,
          recipient: localIdentity,
          groupId: 'g1',
        ));

        expect(result.statusCode, 200);
        expect(await GroupPendingInviteStore.count(), 0);
        expect(await dbHelperDb.query('groups'), isEmpty);
        expect(fetched, isEmpty);
      },
    );

    test(
      'holdAsRequest: the same invite is held exactly once, and still creates '
      'no group and no fetch', () async {
        final inviter = await IdentityKeyPair.generate();
        peerProfiles['stranger.onion'] =
            jsonEncode(await inviter.toPublicJson());
        final invite = await _inviteMessage(
          id: 'm1',
          inviterId: 'stranger.onion',
          inviter: inviter,
          recipient: localIdentity,
          groupId: 'g1',
        );

        final result = await router.handleMessage(invite);
        // A retry of the same envelope must not create a second row.
        await router.handleMessage({...invite, 'id': 'm2'});

        expect(result.statusCode, 200);
        final rows = await GroupPendingInviteStore.pending();
        expect(rows, hasLength(1));
        expect(rows.single['senderId'], 'stranger.onion');
        expect(rows.single['wire'], invite['message']);
        expect(await dbHelperDb.query('groups'), isEmpty);
        expect(await dbHelperDb.query('group_members'), isEmpty);
        expect(await dbHelperDb.query('group_keys'), isEmpty);
        expect(fetched, isEmpty);
      },
    );

    test(
      'holdAsRequest holds invites only: a key rotate from an unresolvable '
      'sender is dropped and stored nowhere', () async {
        final stranger = await IdentityKeyPair.generate();
        final result = await router.handleMessage({
          'id': 'm1',
          'senderId': 'stranger.onion',
          'receiverId': 'local.onion',
          'message': await GroupCryptoV2.encryptControlPayload(
            jsonEncode({'groupId': 'g1', 'keyVersion': 2}),
            stranger,
            await localIdentity.agreePublicKey,
          ),
          'type': groupKeyRotateType,
          'timestamp': 1000,
        });

        expect(result.statusCode, 200);
        expect(await GroupPendingInviteStore.count(), 0);
      },
    );
  });
```

- [ ] **Step 2: Run it and watch it fail**

Run: `flutter test test/security/group_invite_mode_test.dart`
Expected: the `holdAsRequest` test fails with `Expected: an object with length of <1> / Actual:
[] (length 0)` — nothing is held yet. The other two already pass; that is correct, they are the
guards that the change does not overreach.

- [ ] **Step 3: Implement the hold**

In `lib/services/group_service.dart`, add the imports
(`package:prysm/models/group_invite_mode.dart`, `package:prysm/services/settings_service.dart`,
`package:prysm/util/group_pending_invite_store.dart`), add the settings field to the class body
beside the other fields — the convention is `ReadReceiptService`'s
(`lib/services/read_receipt_service.dart:94`):

```dart
  final SettingsService _settings = SettingsService();
```

then replace the comment block and the null branch (`:482-499`) with:

```dart
    // Accepted policy (option 1, PR #128): a control message from a sender
    // whose identity is not in the local store is not processed. The
    // identity is required to *authenticate* it: decryptControlPayload
    // below verifies the control-wrap-2 signature against it, so without it
    // the payload can only be read unverified — which is exactly what must
    // not happen. Do not "fix" this by resolving the sender over the network
    // on cache-miss: that would reopen the M2 profile-fetch oracle (an
    // unauthenticated sender forcing GET /profile as an implicit delivery
    // receipt) before any signature check.
    //
    // What the user can choose (GroupInviteMode) is only what happens to an
    // *invite* afterwards: dropped outright, or held opaque and bounded for
    // the user to accept — never processed, never decrypted, and never a
    // reason to send anything.
    if (senderKeys == null) {
      if (type == groupInviteType &&
          _settings.groupInviteMode == GroupInviteMode.holdAsRequest) {
        final held = await GroupPendingInviteStore.hold(
          senderId: senderId,
          wire: encryptedPayload,
        );
        if (!held) {
          Logging.error(
            'Pending invite store full, dropping invite from '
            '${Logging.redactOnion(senderId)}',
            'GroupService',
          );
        }
      }
      Logging.error(
        'Dropping $type from ${Logging.redactOnion(senderId)}: '
        'sender identity unresolvable',
        'GroupService',
      );
      return false;
    }
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `flutter test test/security/group_invite_mode_test.dart`
Expected: `+3: All tests passed!`

- [ ] **Step 5: Prove the merged policy tests still hold**

Run: `flutter test test/security/group_profile_fetch_gate_test.dart`
Expected: `+9: All tests passed!` — with their assertions unchanged. If a `POLICY:` test needed
editing, the change overreached: stop and report.

- [ ] **Step 6: Commit (controller)**

```bash
git add lib/services/group_service.dart test/security/group_invite_mode_test.dart
git commit -m "feat(group): hold first-contact invites when the user asked for it"
```

---

### Task 4: Promotion

**Files:**
- Create: `lib/services/group_invite_promoter.dart`
- Modify: `lib/screens/home/home_screen.dart` (one-shot sweep in `initState`, after the
  `loadUsers()` chain that ends at `:397` and before `_startAutoRefresh();` at `:404`)
- Test: `test/security/group_invite_mode_test.dart` (extend)

**Interfaces:**
- Consumes: `GroupPendingInviteStore.take/pending/discard` (Task 2),
  `GroupService.handleIncomingControlMessage` (existing).
- Produces:
  - `GroupInvitePromoter({required String userId, required KeyManager keyManager, GroupService? groupService})`
  - `Future<bool> promote(String senderId)` — true when the invite authenticated and applied
  - `Future<int> promoteResolvable()` — promotes every pending row whose sender is now in the
    local user store; returns how many applied

- [ ] **Step 1: Write the failing test**

Append to `test/security/group_invite_mode_test.dart`:

```dart
  group('promotion', () {
    test(
      'once the inviter identity is stored, the held invite applies and the '
      'row is gone', () async {
        final inviter = await IdentityKeyPair.generate();
        final invite = await _inviteMessage(
          id: 'm1',
          inviterId: 'stranger.onion',
          inviter: inviter,
          recipient: localIdentity,
          groupId: 'g1',
        );
        await router.handleMessage(invite);
        expect(await GroupPendingInviteStore.count(), 1);

        // What "the user added the contact" leaves behind.
        final json = jsonEncode(await inviter.toPublicJson());
        await DBHelper.insertOrUpdateUser({
          'id': 'stranger.onion',
          'name': 'Stranger',
          'identityJson': json,
          'publicKeyPem': json,
        });

        final promoter = GroupInvitePromoter(
          userId: 'local.onion',
          keyManager: KeyManager.fromIdentity(localIdentity),
        );
        expect(await promoter.promote('stranger.onion'), isTrue);

        expect(await GroupPendingInviteStore.count(), 0);
        expect((await dbHelperDb.query('groups')).single['id'], 'g1');
        expect(await dbHelperDb.query('group_members'), hasLength(2));
      },
    );

    test('a tampered held envelope is discarded and creates no group',
        () async {
      final inviter = await IdentityKeyPair.generate();
      final json = jsonEncode(await inviter.toPublicJson());
      await DBHelper.insertOrUpdateUser({
        'id': 'stranger.onion',
        'name': 'Stranger',
        'identityJson': json,
        'publicKeyPem': json,
      });
      await GroupPendingInviteStore.hold(
        senderId: 'stranger.onion',
        wire: 'not-a-control-envelope',
      );

      final promoter = GroupInvitePromoter(
        userId: 'local.onion',
        keyManager: KeyManager.fromIdentity(localIdentity),
      );
      expect(await promoter.promote('stranger.onion'), isFalse);

      expect(await GroupPendingInviteStore.count(), 0);
      expect(await dbHelperDb.query('groups'), isEmpty);
    });

    test('the sweep promotes only the senders that became resolvable',
        () async {
      final known = await IdentityKeyPair.generate();
      final unknown = await IdentityKeyPair.generate();
      await router.handleMessage(await _inviteMessage(
        id: 'm1',
        inviterId: 'known.onion',
        inviter: known,
        recipient: localIdentity,
        groupId: 'g1',
      ));
      await router.handleMessage(await _inviteMessage(
        id: 'm2',
        inviterId: 'unknown.onion',
        inviter: unknown,
        recipient: localIdentity,
        groupId: 'g2',
      ));
      final json = jsonEncode(await known.toPublicJson());
      await DBHelper.insertOrUpdateUser({
        'id': 'known.onion',
        'name': 'Known',
        'identityJson': json,
        'publicKeyPem': json,
      });

      final promoted = await GroupInvitePromoter(
        userId: 'local.onion',
        keyManager: KeyManager.fromIdentity(localIdentity),
      ).promoteResolvable();

      expect(promoted, 1);
      expect((await dbHelperDb.query('groups')).single['id'], 'g1');
      final rows = await GroupPendingInviteStore.pending();
      expect(rows.single['senderId'], 'unknown.onion');
    });
  });
```

- [ ] **Step 2: Run it and watch it fail**

Run: `flutter test test/security/group_invite_mode_test.dart`
Expected: compile failure — `Couldn't resolve the package 'prysm/services/group_invite_promoter.dart'`.

- [ ] **Step 3: Write the promoter**

Create `lib/services/group_invite_promoter.dart`:

```dart
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/util/group_pending_invite_store.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/peer_identity_loader.dart';

/// Replays a held first-contact invite once its sender's identity is in the
/// local user store.
///
/// Promotion never bypasses authentication: the held envelope goes through
/// [GroupService.handleIncomingControlMessage], the same path the message
/// would have taken had the sender been known when it arrived. The row is
/// removed either way — an envelope that fails to authenticate is garbage,
/// and keeping it would let a failed attempt be retried forever.
class GroupInvitePromoter {
  GroupInvitePromoter({
    required this.userId,
    required this.keyManager,
    GroupService? groupService,
  }) : _groupService = groupService ??
            GroupService(userId: userId, keyManager: keyManager);

  final String userId;
  final KeyManager keyManager;
  final GroupService _groupService;

  Future<bool> promote(String senderId) async {
    final wire = await GroupPendingInviteStore.take(senderId);
    if (wire == null) return false;
    try {
      return await _groupService.handleIncomingControlMessage(
        groupInviteType,
        wire,
        senderId,
      );
    } catch (e) {
      Logging.error(
        'Promoting the held invite from ${Logging.redactOnion(senderId)} '
        'failed: $e',
        'GroupInvitePromoter',
      );
      return false;
    }
  }

  /// Promotes every pending invite whose sender is now locally known.
  /// Returns how many were applied.
  Future<int> promoteResolvable() async {
    final rows = await GroupPendingInviteStore.pending();
    var promoted = 0;
    for (final row in rows) {
      final senderId = row['senderId'] as String;
      if (await loadPeerIdentityFromDb(keyManager, senderId) == null) continue;
      if (await promote(senderId)) promoted++;
    }
    return promoted;
  }
}
```

- [ ] **Step 4: Run the test and watch it pass**

Run: `flutter test test/security/group_invite_mode_test.dart`
Expected: `+6: All tests passed!`

- [ ] **Step 5: Wire the one-shot sweep**

In `lib/screens/home/home_screen.dart`, import
`package:prysm/services/group_invite_promoter.dart` and insert, in `initState` immediately
before `_startAutoRefresh();` (`:404`):

```dart
    // Invites held while their sender was unknown apply themselves once the
    // contact exists — including when the user added them from somewhere
    // else entirely. Skipped in decoy mode: a panic session must not touch
    // real group state.
    if (!widget.decoyMode) {
      unawaited(
        GroupInvitePromoter(
          userId: widget.onionAddress,
          keyManager: widget.keyManager,
        ).promoteResolvable().then((promoted) {
          if (promoted > 0 && mounted) scheduleLoadUsers(light: true);
        }).catchError((Object e, StackTrace st) {
          Logging.error('Promoting held invites failed: $e\n$st', 'Main');
          return 0;
        }),
      );
    }
```

- [ ] **Step 6: Verify the app still analyses clean**

Run: `flutter analyze lib/screens/home/home_screen.dart lib/services/group_invite_promoter.dart`
Expected: `No issues found!`

- [ ] **Step 7: Commit (controller)**

```bash
git add lib/services/group_invite_promoter.dart lib/screens/home/home_screen.dart \
        test/security/group_invite_mode_test.dart
git commit -m "feat(group): promote held invites once the sender becomes known"
```

---

### Task 5: The setting UI

**Files:**
- Modify: `lib/screens/privacy_settings_screen.dart` (new section after the existing
  `PrysmSection` that ends at `:136`, before the `Emergency` block at `:137`)

**Interfaces:**
- Consumes: `GroupInviteMode`, `SettingsService().groupInviteMode` / `.setGroupInviteMode`
  (Task 1).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add the state field and handler**

In `_PrivacySettingsScreenState`, beside the existing `bool _showOnlineStatus = true;` fields:

```dart
  GroupInviteMode _groupInviteMode = SettingsService().groupInviteMode;
```

and beside the other handlers (after `_onTypingIndicatorsToggle`):

```dart
  Future<void> _onGroupInviteModeChanged(GroupInviteMode? value) async {
    if (value == null || value == _groupInviteMode) return;
    setState(() => _groupInviteMode = value);
    await settings.setGroupInviteMode(value);
  }
```

- [ ] **Step 2: Render both modes with their descriptions**

Import `package:prysm/models/group_invite_mode.dart` and
`package:prysm/ui/core/prysm_radio.dart`, then insert between the closing `),` of the first
`PrysmSection` (`:136`) and `if (widget.keyManager != null) ...[` (`:137`):

```dart
              const SizedBox(height: 30),
              Text('Group invites', style: style.headlineStyle),
              const SizedBox(height: 12),
              PrysmSection(
                children: [
                  for (final mode in GroupInviteMode.values)
                    PrysmRadioRow<GroupInviteMode>(
                      value: mode,
                      groupValue: _groupInviteMode,
                      title: mode.label,
                      subtitle: mode.description,
                      onChanged: _onGroupInviteModeChanged,
                    ),
                ],
              ),
```

Both rows are rendered inline, not behind a bottom sheet like
`panic_pin_settings_screen.dart:133-145`: the point of this screen is that the user reads what
**both** modes imply before choosing.

- [ ] **Step 3: Verify it analyses clean**

Run: `flutter analyze lib/screens/privacy_settings_screen.dart`
Expected: `No issues found!`

- [ ] **Step 4: Smoke test on the desktop build**

Run: `flutter run -d linux`
Navigate: Settings → Advanced Privacy. Confirm: a `Group invites` section with two rows,
`Hold invites from unknown senders` selected, both descriptions readable, and that tapping the
other row moves the dot. Close and reopen the screen: the choice must persist.

- [ ] **Step 5: Commit (controller)**

```bash
git add lib/screens/privacy_settings_screen.dart
git commit -m "feat(settings): let the user pick how unknown-sender invites are handled"
```

---

### Task 6: The requests screen and its two entry points

**Files:**
- Create: `lib/screens/invite_requests_screen.dart`
- Modify: `lib/screens/settings_screen.dart` (navigation tile beside `Blocked contacts`, `:672-684`)
- Modify: `lib/screens/home/home_screen.dart` (`_sidebarFooterCount` at `:177-184`; the footer
  branch in the sidebar `ListView.builder` at `:1461-1513`; a `_pendingInviteCount` field
  refreshed in `loadUsers`)

**Interfaces:**
- Consumes: `GroupPendingInviteStore.pending/discard/count` (Task 2),
  `GroupInvitePromoter.promote` (Task 4), `ContactAddService.instance.addContact` (existing,
  `lib/services/contact_add_service.dart:65-135`).
- Produces: `InviteRequestsScreen({required VoidCallback onClose, required String onionAddress, required KeyManager keyManager, VoidCallback? onChanged})`.

- [ ] **Step 1: Write the screen**

Create `lib/screens/invite_requests_screen.dart`, modelled on
`lib/screens/blocked_contacts_screen.dart:18-162` (same `PrysmPage` + `ListView.separated` +
`PrysmListRow` shape, same `_shortOnion` helper):

```dart
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:prysm/screens/widgets/contact_avatar.dart';
import 'package:prysm/services/contact_add_service.dart';
import 'package:prysm/services/group_invite_promoter.dart';
import 'package:prysm/theme/prysm_style_scope.dart';
import 'package:prysm/ui/core/prysm_button.dart';
import 'package:prysm/ui/core/prysm_dialog.dart';
import 'package:prysm/ui/core/prysm_divider.dart';
import 'package:prysm/ui/core/prysm_icons.dart';
import 'package:prysm/ui/core/prysm_list_row.dart';
import 'package:prysm/ui/core/prysm_progress.dart';
import 'package:prysm/ui/prysm_scaffold.dart';
import 'package:prysm/util/group_pending_invite_store.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/onion_id_codec.dart';

/// Group invites received from senders who are not in the local contacts.
///
/// Only the sender's address and the arrival time are shown: the invite
/// itself is still encrypted and unauthenticated, so nothing inside it —
/// group name, avatar, roster — may be displayed. Accepting adds the contact
/// (the only network call in this flow, and it is the user's own action) and
/// then replays the invite through the authenticated path.
class InviteRequestsScreen extends StatefulWidget {
  final VoidCallback onClose;
  final String onionAddress;
  final KeyManager keyManager;
  final VoidCallback? onChanged;

  const InviteRequestsScreen({
    required this.onClose,
    required this.onionAddress,
    required this.keyManager,
    this.onChanged,
    super.key,
  });

  @override
  State<InviteRequestsScreen> createState() => _InviteRequestsScreenState();
}

class _InviteRequestsScreenState extends State<InviteRequestsScreen> {
  List<Map<String, Object?>> _rows = const [];
  bool _loading = true;
  String? _busySenderId;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final rows = await GroupPendingInviteStore.pending();
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
    widget.onChanged?.call();
  }

  String _shortOnion(String onion) {
    try {
      final encoded = encodeOnionToBase58(onion);
      if (encoded.length <= 12) return encoded;
      return '${encoded.substring(0, 6)}…${encoded.substring(encoded.length - 4)}';
    } catch (_) {
      if (onion.length <= 12) return onion;
      return '${onion.substring(0, 6)}…';
    }
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  String _receivedLabel(int receivedAt) {
    final at = DateTime.fromMillisecondsSinceEpoch(receivedAt);
    return '${at.year}-${_two(at.month)}-${_two(at.day)} '
        '${_two(at.hour)}:${_two(at.minute)}';
  }

  Future<void> _accept(String senderId) async {
    setState(() => _busySenderId = senderId);
    try {
      final added = await ContactAddService.instance.addContact(
        onionId: senderId,
        displayName: '',
      );
      if (!mounted) return;
      if (!added) {
        await showPrysmDialog<void>(
          context: context,
          title: 'Could not reach this contact',
          content: const Text(
            'The invite is still waiting. Try again when they are online.',
          ),
          confirmLabel: 'OK',
          onConfirm: () => Navigator.of(context).pop(),
        );
        return;
      }
      await GroupInvitePromoter(
        userId: widget.onionAddress,
        keyManager: widget.keyManager,
      ).promote(senderId);
    } finally {
      if (mounted) setState(() => _busySenderId = null);
    }
    await _load();
  }

  Future<void> _discard(String senderId) async {
    final confirmed = await showPrysmConfirmDialog(
      context: context,
      title: 'Discard invite',
      content: const Text('This request will be removed.'),
      cancelLabel: 'Cancel',
      confirmLabel: 'Discard',
    );
    if (confirmed != true) return;
    await GroupPendingInviteStore.discard(senderId);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return PrysmPage(
      title: 'Invite requests',
      leading: PrysmIconButton(
        icon: PrysmIcons.arrowBack,
        onPressed: widget.onClose,
      ),
      body: _loading
          ? const Center(child: PrysmProgressIndicator())
          : _rows.isEmpty
              ? Center(
                  child: Text(
                    'No invite requests',
                    style: TextStyle(
                      color: context.prysmStyle.tokens.textMuted,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _rows.length,
                  separatorBuilder: (context, index) => const PrysmDivider(),
                  itemBuilder: (context, index) {
                    final row = _rows[index];
                    final senderId = row['senderId'] as String;
                    final short = _shortOnion(senderId);
                    final busy = _busySenderId == senderId;

                    return PrysmListRow(
                      leading: ContactAvatar(name: short, avatarBase64: null),
                      title: short,
                      subtitleWidget: Text(
                        'Group invite · ${_receivedLabel(row['receivedAt'] as int)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: busy
                          ? const PrysmProgressIndicator()
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                PrysmTextButton(
                                  label: 'Discard',
                                  onPressed: () => _discard(senderId),
                                ),
                                PrysmTextButton(
                                  label: 'Add contact and join',
                                  onPressed: () => _accept(senderId),
                                ),
                              ],
                            ),
                    );
                  },
                ),
    );
  }
}
```

`showPrysmDialog<void>` is the info-dialog form: `confirmLabel`/`cancelLabel` are nullable and
only the buttons you name are rendered (`lib/ui/core/prysm_dialog.dart:38-66`).
`showPrysmConfirmDialog` (`:6-36`) is the two-button form used for `Discard`.

- [ ] **Step 2: Add the Settings entry point**

In `lib/screens/settings_screen.dart`, after the `Blocked contacts` tile and its
`const PrysmDivider(),` (`:672-685`), and only when the screen has what the new screen needs:

```dart
                if (widget.keyManager != null && widget.onionAddress != null) ...[
                  _buildNavigationTile(
                    'Invite requests',
                    PrysmIcons.group,
                    () {
                      Navigator.push(
                        context,
                        PrysmPageRoute(
                          page: InviteRequestsScreen(
                            onClose: () => Navigator.of(context).pop(),
                            onionAddress: widget.onionAddress!,
                            keyManager: widget.keyManager!,
                          ),
                        ),
                      );
                    },
                  ),
                  const PrysmDivider(),
                ],
```

`PrysmIcons.group` is `CupertinoIcons.person_2` (`lib/ui/core/prysm_icons.dart:88`). There is
no `groupOutlined` constant in that file.

- [ ] **Step 3: Add the sidebar footer row**

In `lib/screens/home/home_screen.dart`:

1. a state field beside the other counters:

```dart
  int _pendingInviteCount = 0;
```

2. refresh it inside `loadUsers`, in the same `Future.wait` batches that already load the
   counters (`:802-811` and `:822-827`), or — simpler and equally correct — right before
   `_applyLoadedUsers` is called at `:858`:

```dart
      final pendingInvites = await GroupPendingInviteStore.count();
      if (!mounted) return;
      _pendingInviteCount = pendingInvites;
```

3. count it in `_sidebarFooterCount` (`:177-184`):

```dart
    if (_pendingInviteCount > 0) count++;
```

4. render it as the first footer row, before the `Archived` branch, adjusting the branch indices
   so each footer row keeps its own slot:

```dart
                  if (_pendingInviteCount > 0 && footerIndex == 0) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      child: PrysmListRow(
                        leading: Icon(
                          PrysmIcons.group,
                          color: context.prysmStyle.tokens.accent,
                        ),
                        title: 'Invite requests',
                        subtitle:
                            '$_pendingInviteCount request${_pendingInviteCount == 1 ? '' : 's'}',
                        onTap: () {
                          Navigator.push(
                            context,
                            PrysmPageRoute(
                              page: InviteRequestsScreen(
                                onClose: () => Navigator.of(context).pop(),
                                onionAddress: widget.onionAddress,
                                keyManager: widget.keyManager,
                                onChanged: () => scheduleLoadUsers(light: true),
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  }
```

The existing `Archived` branch currently tests `footerIndex == 0`; with a row inserted before
it, its index becomes `_pendingInviteCount > 0 ? 1 : 0`. Compute the offsets explicitly rather
than nesting conditionals — an off-by-one here renders the wrong row.

- [ ] **Step 4: Verify it analyses clean**

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 5: Smoke test the whole feature on the desktop build**

Run: `flutter run -d linux`

1. With no pending invites: no footer row in the sidebar, and Settings → `Invite requests`
   shows `No invite requests`.
2. Seed one request against the running app (a second instance, or a direct POST to the local
   onion with `type: 'group_invite'` and an unknown `senderId`): the footer row appears with
   `1 request`, the screen lists the short address and the arrival time, and **no group appears
   in the sidebar**.
3. Discard it: the row disappears from both the screen and the sidebar.
4. Switch the mode to `Only accept invites from contacts` and send another: nothing is stored,
   nothing appears.

- [ ] **Step 6: Commit (controller)**

```bash
git add lib/screens/invite_requests_screen.dart lib/screens/settings_screen.dart \
        lib/screens/home/home_screen.dart
git commit -m "feat(group): surface pending invite requests and let the user act on them"
```

---

## Final gate (controller, after every task)

```bash
flutter analyze          # expect: No issues found!
flutter test             # expect: at least 935 + the new tests, 1 skipped
```

The skip is the L3 harness, gated by `PRYSM_E2E`. Any other skip or failure is a regression
introduced by this plan.

## Out of scope (do not implement)

- The other four group control types keep dropping unconditionally.
- `DBHelper.ensureUserExist` stays as it is on all six inbound handlers.
- Issue #130 and the 1:1 DM pre-auth resolve residual are untouched.
