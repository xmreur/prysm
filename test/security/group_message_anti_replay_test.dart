// Task 2 (M6a): inbound group sender-key anti-replay window and tombstone
// protection. Two faces of the same root cause: no "already seen index" state
// on the inbound path, and `insertInboundMessage` replacing soft-delete
// tombstones (ConflictAlgorithm.replace), so a captured group envelope can be
// re-POSTed under a fresh transport id (replay) and a deleted message can be
// resurrected.
//
// RED/GREEN: the replay test and the tombstone test fail on the pre-fix code
// (two rows stored / tombstone replaced) and pass after the fix.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/crypto.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/server/inbound_message_router.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/group_sender_index_store.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<IdentityPublicKeys> _publicKeys(IdentityKeyPair id) async {
  final sign = await id.signPublicKey;
  final agree = await id.agreePublicKey;
  return IdentityPublicKeys(
    signPublic: sign,
    agreePublic: agree,
    fingerprint: IdentityKeyPair.fingerprintFromPublicJson(
      await id.toPublicJson(),
    ),
  );
}

Future<Database> _openMessagesDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await db.execute('DROP TABLE IF EXISTS messages');
  await db.execute('''
    CREATE TABLE messages(
      id TEXT PRIMARY KEY,
      senderId TEXT NOT NULL,
      receiverId TEXT NOT NULL,
      message TEXT,
      type TEXT,
      fileName TEXT,
      fileSize INTEGER,
      timestamp INTEGER NOT NULL,
      status TEXT DEFAULT 'sent',
      replyTo TEXT,
      readAt INTEGER,
      viewOnce INTEGER DEFAULT 0,
      viewed INTEGER DEFAULT 0,
      groupId TEXT,
      deletedAt INTEGER,
      editedAt INTEGER,
      expiresAt INTEGER
    )
  ''');
  return db;
}

Future<Database> _openDbHelperDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
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
  await db.execute('''
    CREATE TABLE group_members (
      groupId TEXT NOT NULL,
      memberId TEXT NOT NULL,
      role TEXT NOT NULL,
      joinedAt INTEGER NOT NULL,
      PRIMARY KEY (groupId, memberId)
    )
  ''');
  await db.execute('''
    CREATE TABLE conversation_preferences (
      conversationId TEXT PRIMARY KEY,
      isPinned INTEGER NOT NULL DEFAULT 0,
      pinnedAt INTEGER,
      isArchived INTEGER NOT NULL DEFAULT 0,
      archivedAt INTEGER,
      disappearingTimerSeconds INTEGER
    )
  ''');
  await RatchetSessionStore.ensureTable(db);
  await GroupSenderIndexStore.ensureTable(db);
  return db;
}

/// Builds a group chat message whose `message` field is a signed group
/// sender-key envelope with the given [index] (the payload an attacker would
/// capture and re-POST under a different transport id).
Future<Map<String, dynamic>> _groupMessage({
  required String id,
  required IdentityKeyPair sender,
  required String senderId,
  required String groupId,
  required int index,
  int timestamp = 1000,
}) async {
  final wire = await GroupCryptoV2.encryptWithSenderKey(
    epochKey: Uint8List.fromList(List.generate(32, (i) => i)),
    groupId: groupId,
    senderId: senderId,
    messageIndex: index,
    plaintext: 'hello-$index',
    sender: sender,
  );
  return {
    'id': id,
    'senderId': senderId,
    'receiverId': 'local.onion',
    'message': wire,
    'type': groupTextType,
    'groupId': groupId,
    'timestamp': timestamp,
  };
}

void main() {
  late Directory docsDir;
  late Database messagesDb;
  late Database dbHelperDb;
  late InboundMessageRouter router;
  late IdentityKeyPair alice;
  late IdentityKeyPair bob;
  late Map<String, IdentityPublicKeys> peers;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // softDeleteMessage unconditionally probes MessageBlobStore, which shells
    // out to path_provider even when no blob file exists.
    docsDir = Directory.systemTemp.createTempSync(
      'group_message_anti_replay_test',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return docsDir.path;
        }
        return null;
      },
    );
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    docsDir.deleteSync(recursive: true);
  });

  setUp(() async {
    alice = await IdentityKeyPair.generate();
    bob = await IdentityKeyPair.generate();
    peers = {
      'alice.onion': await _publicKeys(alice),
      'bob.onion': await _publicKeys(bob),
    };

    messagesDb = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(messagesDb);

    dbHelperDb = await _openDbHelperDb();
    DBHelper.setDatabaseForTest(dbHelperDb);

    router = InboundMessageRouter(
      keyManager: KeyManager(),
      settings: SettingsService(),
      localOnionAddress: () => 'local.onion',
      resolvePeerIdentity: (senderId) async => peers[senderId],
    );
  });

  tearDown(() async {
    await messagesDb.close();
    MessagesDb.setDatabaseForTest(null);

    await dbHelperDb.close();
    DBHelper.setDatabaseForTest(null);
  });

  group('inbound group sender-key replay window', () {
    test(
      'RED: a replayed envelope under a new transport id is acked but not '
      'stored (pre-fix: two rows)', () async {
        final first = await router.handleMessage(
          await _groupMessage(
            id: 'm1',
            sender: alice,
            senderId: 'alice.onion',
            groupId: 'g1',
            index: 0,
          ),
        );
        final replay = await router.handleMessage(
          await _groupMessage(
            id: 'm2', // same envelope (senderId/index), new transport id
            sender: alice,
            senderId: 'alice.onion',
            groupId: 'g1',
            index: 0,
          ),
        );

        expect(first.statusCode, 200);
        expect(replay.statusCode, 200);
        expect(replay.jsonBody?['status'], 'received');
        expect(replay.jsonBody?['id'], 'm2');

        final rows = await messagesDb.query('messages');
        expect(rows, hasLength(1));
      },
    );

    test('a higher index from the same sender passes; lower or equal is '
        'rejected', () async {
      final higher = await router.handleMessage(
        await _groupMessage(
          id: 'm1',
          sender: alice,
          senderId: 'alice.onion',
          groupId: 'g1',
          index: 1,
        ),
      );
      final lower = await router.handleMessage(
        await _groupMessage(
          id: 'm2',
          sender: alice,
          senderId: 'alice.onion',
          groupId: 'g1',
          index: 0,
        ),
      );
      final equal = await router.handleMessage(
        await _groupMessage(
          id: 'm3',
          sender: alice,
          senderId: 'alice.onion',
          groupId: 'g1',
          index: 1,
        ),
      );
      final next = await router.handleMessage(
        await _groupMessage(
          id: 'm4',
          sender: alice,
          senderId: 'alice.onion',
          groupId: 'g1',
          index: 2,
        ),
      );

      expect(higher.statusCode, 200);
      expect(lower.statusCode, 200);
      expect(lower.jsonBody?['status'], 'received');
      expect(equal.statusCode, 200);
      expect(equal.jsonBody?['status'], 'received');
      expect(next.statusCode, 200);

      final rows = await messagesDb.query('messages');
      expect(rows, hasLength(2));
      expect(rows.map((r) => r['id']), containsAll(['g1::m1', 'g1::m4']));
    });

    test('different senders in the same group do not interfere', () async {
      final aliceFirst = await router.handleMessage(
        await _groupMessage(
          id: 'm1',
          sender: alice,
          senderId: 'alice.onion',
          groupId: 'g1',
          index: 0,
        ),
      );
      final bobFirst = await router.handleMessage(
        await _groupMessage(
          id: 'm2',
          sender: bob,
          senderId: 'bob.onion',
          groupId: 'g1',
          index: 0,
        ),
      );
      final aliceReplay = await router.handleMessage(
        await _groupMessage(
          id: 'm3',
          sender: alice,
          senderId: 'alice.onion',
          groupId: 'g1',
          index: 0,
        ),
      );

      expect(aliceFirst.statusCode, 200);
      expect(bobFirst.statusCode, 200);
      expect(aliceReplay.statusCode, 200);
      expect(aliceReplay.jsonBody?['status'], 'received');

      final rows = await messagesDb.query('messages');
      expect(rows, hasLength(2));
      expect(rows.map((r) => r['id']), containsAll(['g1::m1', 'g1::m2']));
    });
  });

  group('inbound tombstone protection', () {
    test(
      'RED: insertInboundMessage must not resurrect a soft-deleted row '
      '(pre-fix: tombstone replaced)', () async {
        final stored = await MessagesDb.insertInboundMessage({
          'id': 'm1',
          'senderId': 'alice.onion',
          'receiverId': 'local.onion',
          'message': 'cipher-1',
          'type': groupTextType,
          'groupId': 'g1',
          'timestamp': 1000,
          'status': 'received',
        }, 'local.onion');
        expect(stored, isNotNull);

        await MessagesDb.softDeleteMessage(
          'm1',
          groupId: 'g1',
          deletedAt: 5000,
        );

        final reinserted = await MessagesDb.insertInboundMessage({
          'id': 'm1',
          'senderId': 'alice.onion',
          'receiverId': 'local.onion',
          'message': 'cipher-1',
          'type': groupTextType,
          'groupId': 'g1',
          'timestamp': 1000,
          'status': 'received',
        }, 'local.onion');

        expect(reinserted, isNull);
        final rows = await messagesDb.query(
          'messages',
          where: 'id = ?',
          whereArgs: ['g1::m1'],
        );
        expect(rows, hasLength(1));
        expect(rows.first['deletedAt'], isNotNull);
        expect(rows.first['message'], isNull);
      },
    );

    test('a deleted group message re-POSTed under a new transport id stays '
        'deleted (replay gate blocks it)', () async {
      await router.handleMessage(
        await _groupMessage(
          id: 'm1',
          sender: alice,
          senderId: 'alice.onion',
          groupId: 'g1',
          index: 0,
        ),
      );
      await MessagesDb.softDeleteMessage(
        'm1',
        groupId: 'g1',
        deletedAt: 5000,
      );

      final replayed = await router.handleMessage(
        await _groupMessage(
          id: 'm2', // same envelope (senderId/index), new transport id
          sender: alice,
          senderId: 'alice.onion',
          groupId: 'g1',
          index: 0,
        ),
      );

      expect(replayed.statusCode, 200);
      expect(replayed.jsonBody?['status'], 'received');

      final rows = await messagesDb.query('messages');
      expect(rows, hasLength(1));
      expect(rows.single['deletedAt'], isNotNull);
      expect(rows.single['message'], isNull);
    });
  });
}
