// Task 2 (M6a): inbound group sender-key anti-replay window and tombstone
// protection. Two faces of the same root cause: no "already seen index" state
// on the inbound path, and `insertInboundMessage` replacing soft-delete
// tombstones (ConflictAlgorithm.replace), so a captured group envelope can be
// re-POSTed under a fresh transport id (replay) and a deleted message can be
// resurrected.
//
// RED/GREEN: the replay test and the tombstone test fail on the pre-fix code
// (two rows stored / tombstone replaced) and pass after the fix.
import 'dart:convert';
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
    // The anti-replay gate resolves the sender cache-only
    // (loadPeerIdentityFromDb), so members must be in the local user store
    // for their signatures to verify.
    await DBHelper.insertOrUpdateUser({
      'id': 'alice.onion',
      'name': 'Alice',
      'identityJson': jsonEncode(await alice.toPublicJson()),
      'publicKeyPem': jsonEncode(await alice.toPublicJson()),
    });
    await DBHelper.insertOrUpdateUser({
      'id': 'bob.onion',
      'name': 'Bob',
      'identityJson': jsonEncode(await bob.toPublicJson()),
      'publicKeyPem': jsonEncode(await bob.toPublicJson()),
    });

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
        // The drop ack must be indistinguishable from a delivery ack: a
        // replayer must not learn that the message was dropped (pre-fix:
        // only the success ack carried a timestamp).
        expect(replay.jsonBody?['timestamp'], isA<int>());

        final rows = await messagesDb.query('messages');
        expect(rows, hasLength(1));
      },
    );

    test('an out-of-order index from the same sender is stored; an exact '
        'duplicate is rejected', () async {
      final first = await router.handleMessage(
        await _groupMessage(
          id: 'm1',
          sender: alice,
          senderId: 'alice.onion',
          groupId: 'g1',
          index: 1,
        ),
      );
      final late = await router.handleMessage(
        await _groupMessage(
          id: 'm2',
          sender: alice,
          senderId: 'alice.onion',
          groupId: 'g1',
          index: 0,
        ),
      );
      final duplicate = await router.handleMessage(
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

      expect(first.statusCode, 200);
      // A late delivery of an unseen index is a message, not a replay.
      expect(late.statusCode, 200);
      expect(late.jsonBody?['status'], 'received');
      expect(duplicate.statusCode, 200);
      expect(duplicate.jsonBody?['status'], 'received');
      expect(next.statusCode, 200);

      final rows = await messagesDb.query('messages');
      expect(rows, hasLength(3));
      expect(
        rows.map((r) => r['id']),
        containsAll(['g1::m1', 'g1::m2', 'g1::m4']),
      );
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

    test(
      'claim 1: a late retry of an older index is stored, not dropped '
      '(pre-fix: index 9 censored)', () async {
        // The retry machinery allocates the index at send time and re-sends
        // the stored envelope with its ORIGINAL index when the first
        // delivery fails, so an older index can arrive after a newer one.
        final first = await router.handleMessage(
          await _groupMessage(
            id: 'm10',
            sender: alice,
            senderId: 'alice.onion',
            groupId: 'g1',
            index: 10,
          ),
        );
        final late = await router.handleMessage(
          await _groupMessage(
            id: 'm9',
            sender: alice,
            senderId: 'alice.onion',
            groupId: 'g1',
            index: 9,
          ),
        );

        expect(first.statusCode, 200);
        expect(late.statusCode, 200);
        expect(late.jsonBody?['status'], 'received');
        expect(late.jsonBody?['id'], 'm9');

        final rows = await messagesDb.query('messages');
        expect(
          rows.map((r) => r['id']),
          containsAll(['g1::m10', 'g1::m9']),
        );
      },
    );

    test(
      'claim 2: a relayed captured envelope cannot censor the sender '
      '(pre-fix: indices 1..9 all dropped)', () async {
        // Alice sends index 10; an attacker without key material captures
        // the byte-identical wire envelope.
        final captured = await _groupMessage(
          id: 'm10',
          sender: alice,
          senderId: 'alice.onion',
          groupId: 'g1',
          index: 10,
        );
        final first = await router.handleMessage(captured);
        expect(first.statusCode, 200);

        // The attacker relays the SAME envelope under an attacker-chosen
        // transport id. It is acked as a duplicate but must not become
        // "seen" state beyond that one exact triple.
        final relayed = await router.handleMessage({
          ...captured,
          'id': 'm10-relay',
        });
        expect(relayed.statusCode, 200);
        expect(relayed.jsonBody?['status'], 'received');

        // A forged mutation of the captured envelope (index bumped, the
        // signature therefore invalid) must not record anything in the
        // seen-set: the attack needs a capture, not a key.
        final forgedEnvelope =
            CryptoEnvelope.tryParse(captured['message'] as String)!;
        forgedEnvelope['index'] = 11;
        final forged = await router.handleMessage({
          ...captured,
          'id': 'm11-forged',
          'message': CryptoEnvelope.encode(forgedEnvelope),
        });
        expect(forged.statusCode, 200);

        // The sender's own indices 1..9 arrive late and must all be stored.
        for (var i = 1; i <= 9; i++) {
          final res = await router.handleMessage(
            await _groupMessage(
              id: 'm$i',
              sender: alice,
              senderId: 'alice.onion',
              groupId: 'g1',
              index: i,
            ),
          );
          expect(res.statusCode, 200);
          expect(res.jsonBody?['status'], 'received');
        }

        // A genuine index 11 is still new: the forged envelope did not
        // poison the seen-set.
        final genuine11 = await router.handleMessage(
          await _groupMessage(
            id: 'm11',
            sender: alice,
            senderId: 'alice.onion',
            groupId: 'g1',
            index: 11,
          ),
        );
        expect(genuine11.statusCode, 200);

        final rows = await messagesDb.query('messages');
        final ids = rows.map((r) => r['id']).toSet();
        expect(ids, contains('g1::m10'));
        expect(ids, isNot(contains('g1::m10-relay')));
        expect(
          ids,
          containsAll([for (var i = 1; i <= 9; i++) 'g1::m$i', 'g1::m11']),
        );
      },
    );
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
