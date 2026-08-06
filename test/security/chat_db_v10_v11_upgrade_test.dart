// Regression test for the chat_app.db v10 -> v11 upgrade (fix/security-mediums
// wave): DBHelper bumped the schema to version 11 so an install already at
// version 10 gets the new group_inbound_seen table. Before the bump that
// table was only created from onCreate and from the oldVersion < 7 step, so an
// install at version 10 would throw "no such table: group_inbound_seen" on the
// first inbound group message.
//
// Like test/security/database_cipher_test.dart, this builds a real on-disk
// database in a fresh temp directory and drives DBHelper's actual open path:
// plaintext v10 fixture -> DatabaseCipher.prepare (in-place encryption) ->
// openDatabase(version: 11, onUpgrade) -> real GroupSenderIndexStore calls.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/database/blocked_users_db.dart';
import 'package:prysm/database/call_logs_db.dart';
import 'package:prysm/database/conversation_preferences_db.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_sender_index_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('chat_db_v10_v11_upgrade_test');
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

  /// Builds a real v10 chat_app.db at [path]: every table the v10 onCreate
  /// created, with the same DDL it used, plus one pre-existing outbound
  /// counter row, and `PRAGMA user_version = 10`.
  ///
  /// The DDL is taken from DBHelper._createDB / _createGroupTables and the
  /// public satellite createTable/ensureTable helpers (ConversationPreferencesDb,
  /// BlockedUsersDb, CallLogsDb, RatchetSessionStore) so the fixture cannot
  /// drift from the real schema. The one exception is group_sender_index,
  /// whose v10 form (HEAD) is copied verbatim from
  /// GroupSenderIndexStore.ensureTable: the wave added group_inbound_seen to
  /// that helper, so calling it would build the table under test and make the
  /// test vacuous.
  Future<void> buildV10Fixture(String path) async {
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
      // session_state: RatchetSessionStore.ensureTable (the other half of
      // DBHelper._createCryptoTables).
      await RatchetSessionStore.ensureTable(db);
      // group_sender_index: the v10 form of GroupSenderIndexStore.ensureTable,
      // which created only the outbound counter table; group_inbound_seen is
      // the subject of this upgrade and must NOT exist in the fixture.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS group_sender_index (
          groupId TEXT NOT NULL,
          senderId TEXT NOT NULL,
          nextIndex INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (groupId, senderId)
        )
      ''');
      // An outbound counter the upgrade must preserve: silently dropping it
      // would be worse than the missing inbound table.
      await db.insert('group_sender_index', {
        'groupId': 'g1',
        'senderId': 'local-user',
        'nextIndex': 7,
      });

      await db.rawQuery('PRAGMA user_version = 10');

      // Fixture guards: the schema must really be the v10 one, otherwise the
      // test could pass without exercising the upgrade at all.
      final uv = await db.rawQuery('PRAGMA user_version');
      expect(uv.first.values.single, 10);
      final inbound = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name = 'group_inbound_seen'",
      );
      expect(
        inbound,
        isEmpty,
        reason: 'the v10 fixture must not contain group_inbound_seen',
      );
    } finally {
      await db.close();
    }
  }

  test(
    'opening a v10 chat_app.db creates group_inbound_seen and preserves '
    'outbound counters',
    () async {
      final path = '${tempDir.path}/prysm/chat_app.db';
      await buildV10Fixture(path);
      expect(File(path).existsSync(), isTrue);

      // The real open path: DatabaseCipher.prepare encrypts the plaintext
      // fixture in place, then openDatabase(version: 11, onUpgrade) runs the
      // oldVersion < 11 step that creates group_inbound_seen. The handle is
      // closed by DBHelper.closeForWipe() in tearDown.
      final db = await DBHelper.database;

      final uv = await db.rawQuery('PRAGMA user_version');
      expect(uv.first.values.single, 11);

      final inbound = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name = 'group_inbound_seen'",
      );
      expect(inbound, hasLength(1));

      // A real inbound record through the store path survives.
      final inserted = await GroupSenderIndexStore.recordInboundIndex(
        groupId: 'g1',
        senderId: 'remote-user',
        index: 5,
      );
      expect(inserted, isTrue);
      final seen = await db.query('group_inbound_seen');
      expect(seen, hasLength(1));
      expect(seen.single['groupId'], 'g1');
      expect(seen.single['senderId'], 'remote-user');
      expect(seen.single['msgIndex'], 5);
      // An exact-duplicate replay is rejected (the reason the table exists).
      final replay = await GroupSenderIndexStore.recordInboundIndex(
        groupId: 'g1',
        senderId: 'remote-user',
        index: 5,
      );
      expect(replay, isFalse);

      // The pre-existing outbound counter survived the upgrade, and the
      // store still advances from the preserved value.
      final counters = await db.query('group_sender_index');
      expect(counters, hasLength(1));
      expect(counters.single['groupId'], 'g1');
      expect(counters.single['senderId'], 'local-user');
      expect(counters.single['nextIndex'], 7);
      expect(
        await GroupSenderIndexStore.nextIndex(
          groupId: 'g1',
          senderId: 'local-user',
        ),
        7,
      );
    },
  );
}
