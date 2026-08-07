// Regression test for the chat_app.db schema upgrade in the group-invite
// wave: DBHelper bumped the schema to version 14 so an install already at
// version 13 gets the new group_pending_invites table (the bounded store
// for invites from senders whose identity is not local yet). Before the
// v14 bump the table was only created from onCreate and from the
// oldVersion < 7 step, so an install at version 13 would throw "no such
// table: group_pending_invites" on the first hold.
//
// Like test/security/database_cipher_test.dart, this builds a real on-disk
// database in a fresh temp directory and drives DBHelper's actual open path:
// plaintext v13 fixture -> DatabaseCipher.prepare (in-place encryption)
// -> openDatabase(version: 14, onUpgrade) -> real GroupPendingInviteStore
// calls.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/database/blocked_users_db.dart';
import 'package:prysm/database/call_logs_db.dart';
import 'package:prysm/database/conversation_preferences_db.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_pending_invite_store.dart';
import 'package:prysm/util/group_sender_index_store.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('chat_db_v13_v14_upgrade_test');
    Directory('${tempDir.path}/prysm').createSync(recursive: true);
    CryptoKeyStore.setUseInMemoryStorageOnly(true);
    CryptoKeyStore.resetInMemoryStorageForTest();

    // Point path_provider at the throwaway directory so DBHelper opens
    // <tempDir>/prysm/chat_app.db.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return tempDir.path;
        }
        return null;
      },
    );
  });

  tearDown(() async {
    // Close the handle DBHelper memoised so nothing leaks into the rest of
    // the suite, then forget every cached open.
    await DBHelper.closeForWipe();
    DBHelper.setDatabaseForTest(null);
    CryptoKeyStore.resetInMemoryStorageForTest();
    CryptoKeyStore.setUseInMemoryStorageOnly(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// Builds a real v13 chat_app.db at [path]: every table the v13 onCreate
  /// created, with the same DDL it used, plus one pre-existing user row and
  /// one pre-existing outbound counter row, and `PRAGMA user_version = 13`.
  ///
  /// The DDL is taken from DBHelper._createDB / _createGroupTables and the
  /// public satellite createTable/ensureTable helpers (ConversationPreferencesDb,
  /// BlockedUsersDb, CallLogsDb, RatchetSessionStore, GroupSenderIndexStore)
  /// so the fixture cannot drift from the real schema. The one exception is
  /// group_pending_invites, the table under test:
  /// GroupPendingInviteStore.ensureTable must NOT be called here — the
  /// fixture would build the table and make the test vacuous.
  Future<void> buildV13Fixture(String path) async {
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      // users + idx_users_name: DBHelper._createDB.
      await db.execute('''
        CREATE TABLE users (
          id TEXT PRIMARY KEY,
          name TEXT,
          avatarUrl TEXT,
          avatarBase64 TEXT,
          customName TEXT,
          publicKeyPem TEXT,
          identityJson TEXT
        )
      ''');
      await db.execute('CREATE INDEX idx_users_name ON users(name)');
      // groups, group_members, group_keys: DBHelper._createGroupTables.
      await db.execute('''
        CREATE TABLE groups (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          avatarBase64 TEXT,
          createdBy TEXT NOT NULL,
          createdAt INTEGER NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE group_members (
          groupId TEXT NOT NULL,
          memberId TEXT NOT NULL,
          role TEXT NOT NULL,
          joinedAt INTEGER NOT NULL,
          PRIMARY KEY (groupId, memberId),
          FOREIGN KEY (groupId) REFERENCES groups(id) ON DELETE CASCADE
        )
      ''');
      await db.execute('''
        CREATE TABLE group_keys (
          groupId TEXT PRIMARY KEY,
          encryptedKey TEXT NOT NULL,
          keyVersion INTEGER NOT NULL DEFAULT 1,
          FOREIGN KEY (groupId) REFERENCES groups(id) ON DELETE CASCADE
        )
      ''');
      // conversation_preferences, blocked_users, call_logs: the satellite
      // helpers DBHelper calls.
      await ConversationPreferencesDb.createTable(db);
      await BlockedUsersDb.createTable(db);
      await CallLogsDb.createTable(db);
      // session_state, group_sender_index, group_inbound_seen,
      // group_inbound_floor: DBHelper._createCryptoTables.
      await RatchetSessionStore.ensureTable(db);
      await GroupSenderIndexStore.ensureTable(db);
      // Rows the upgrade must preserve: silently dropping them would be
      // worse than the missing pending table.
      await db.insert('users', {
        'id': 'local-user',
        'name': 'Local',
      });
      await db.insert('group_sender_index', {
        'groupId': 'g1',
        'senderId': 'local-user',
        'nextIndex': 7,
      });

      await db.rawQuery('PRAGMA user_version = 13');

      // Fixture guards, each its own expect: a single isNot(containsAll([...]))
      // is satisfied by the absence of one element and would be vacuous —
      // this is the CN4 lesson from PR #128.
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        ['group_pending_invites'],
      );
      expect(tables, isEmpty, reason: 'the v13 fixture must not have the table');
      expect(
        Sqflite.firstIntValue(await db.rawQuery('PRAGMA user_version')),
        13,
      );
    } finally {
      await db.close();
    }
  }

  test('v13 -> v14 adds group_pending_invites and keeps existing rows',
      () async {
    final path = '${tempDir.path}/prysm/chat_app.db';
    await buildV13Fixture(path);
    expect(File(path).existsSync(), isTrue);

    // The real open path: DatabaseCipher.prepare encrypts the plaintext
    // fixture in place, then openDatabase(version: 14, onUpgrade) runs the
    // oldVersion < 14 step that creates group_pending_invites. The handle
    // is closed by DBHelper.closeForWipe() in tearDown.
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
}
