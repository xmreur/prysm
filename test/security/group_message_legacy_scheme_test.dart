// Task 3 (M6b): legacy `group-aead-1` envelopes must be rejected at ingress.
// The legacy scheme has no sender binding (`iv`/`ct` only), so any group
// member can craft a message attributed to another member; sender-key
// protections are bypassed simply by using the old scheme.
//
// RED/GREEN: the rejection test fails on the pre-fix code (the spoofed
// message is stored with 200 and attributed to the victim sender) and passes
// after the fix. The sender-key acceptance test guards the good path.
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

Uint8List _groupKey() => Uint8List.fromList(List.generate(32, (i) => i));

/// Builds a group chat message whose `message` field is a legacy
/// `group-aead-1` envelope (AES-GCM with the shared group key, no sender
/// binding) — the payload an attacker crafts and POSTs under the victim's
/// [senderId].
Future<Map<String, dynamic>> _legacyGroupMessage({
  required String id,
  required String senderId,
  required String groupId,
  required String plaintext,
  int timestamp = 1000,
}) async {
  final wire = await GroupCryptoV2.encryptText(_groupKey(), plaintext);
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

/// Builds a group chat message whose `message` field is a signed group
/// sender-key envelope with the given [index].
Future<Map<String, dynamic>> _senderKeyGroupMessage({
  required String id,
  required IdentityKeyPair sender,
  required String senderId,
  required String groupId,
  required int index,
  int timestamp = 1000,
}) async {
  final wire = await GroupCryptoV2.encryptWithSenderKey(
    epochKey: _groupKey(),
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
  late Map<String, IdentityPublicKeys> peers;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // softDeleteMessage unconditionally probes MessageBlobStore, which shells
    // out to path_provider even when no blob file exists.
    docsDir = Directory.systemTemp.createTempSync(
      'group_message_legacy_scheme_test',
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
    peers = {
      'alice.onion': await _publicKeys(alice),
    };

    messagesDb = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(messagesDb);

    dbHelperDb = await _openDbHelperDb();
    DBHelper.setDatabaseForTest(dbHelperDb);

    // The membership gate only admits group traffic from members of the
    // addressed group, so the sender under test must be a member for the
    // legacy-scheme gate (not the membership gate) to fire.
    await dbHelperDb.insert(
      'group_members',
      {
        'groupId': 'g1',
        'memberId': 'alice.onion',
        'role': 'member',
        'joinedAt': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    router = InboundMessageRouter(
      keyManager: KeyManager(),
      settings: SettingsService(),
      localOnionAddress: () => 'local.onion',
      resolvePeerIdentity: (senderId) async => peers[senderId],
    );
  });

  tearDown(() async {
    // Claim ownership is process-global: a claim left by one case would
    // refuse the same triple in the next, so it must be cleared between
    // cases.
    GroupSenderIndexStore.resetForTest();
    await messagesDb.close();
    MessagesDb.setDatabaseForTest(null);

    await dbHelperDb.close();
    DBHelper.setDatabaseForTest(null);
  });

  group('inbound legacy group-aead envelope rejection', () {
    test(
      'RED: a legacy group-aead envelope is rejected with 400 and not '
      'stored (pre-fix: stored and attributed to the spoofed sender)',
      () async {
        final result = await router.handleMessage(
          await _legacyGroupMessage(
            id: 'm1',
            senderId: 'alice.onion', // spoofed by another group member
            groupId: 'g1',
            plaintext: 'hello',
          ),
        );

        expect(result.statusCode, 400);

        final rows = await messagesDb.query('messages');
        expect(rows, isEmpty);
      },
    );

    test('a valid sender-key envelope in the same group is still accepted',
        () async {
      final result = await router.handleMessage(
        await _senderKeyGroupMessage(
          id: 'm1',
          sender: alice,
          senderId: 'alice.onion',
          groupId: 'g1',
          index: 0,
        ),
      );

      expect(result.statusCode, 200);
      expect(result.jsonBody?['status'], 'received');

      final rows = await messagesDb.query('messages');
      expect(rows, hasLength(1));
      expect(rows.single['senderId'], 'alice.onion');
      expect(rows.single['groupId'], 'g1');
    });
  });
}
