// Unit tests for MessageActionsService (Fase 6A): delete/edit orchestration
// extracted from _ChatScreenState/_GroupChatScreenState. See
// message_actions_characterization_test.dart for the baseline this was
// extracted from — these tests exercise the real class directly.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/group_crypto.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/database/message_reactions.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/message_actions_service.dart';
import 'package:prysm/services/message_modify_service.dart';
import 'package:prysm/services/side_channel_postman.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void _mockPathProvider() {
  final tempDir = Directory.systemTemp.createTempSync('prysm_actions_svc_test_');
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => tempDir.path);
}

Future<Database> _openMessagesDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
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
      expiresAt INTEGER,
      forwarded INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await MessageReactionsDb.createTable(db);
  await MessageSchemaMigrations.createMessageSearchFtsTable(db);
  return db;
}

Future<Database> _openPendingDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await db.execute('''
    CREATE TABLE pending_messages(
      id TEXT PRIMARY KEY,
      senderId TEXT,
      receiverId TEXT,
      message TEXT,
      type TEXT,
      fileName TEXT,
      fileSize INTEGER,
      timestamp INTEGER,
      status TEXT,
      replyTo TEXT,
      viewOnce INTEGER DEFAULT 0,
      groupId TEXT,
      targetMemberId TEXT
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
    CREATE TABLE group_keys (
      groupId TEXT PRIMARY KEY,
      encryptedKey TEXT NOT NULL,
      keyVersion INTEGER NOT NULL DEFAULT 1
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
  await RatchetSessionStore.ensureTable(db);
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
  return db;
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _mockPathProvider();
  });

  late Database messagesDb;
  late Database pendingDb;
  late Database dbHelperDb;
  late KeyManager keyManager;

  setUp(() async {
    messagesDb = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(messagesDb);

    pendingDb = await _openPendingDb();
    PendingMessageDbHelper.setDatabaseForTest(pendingDb);

    dbHelperDb = await _openDbHelperDb();
    DBHelper.setDatabaseForTest(dbHelperDb);

    keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
  });

  tearDown(() async {
    await messagesDb.close();
    MessagesDb.setDatabaseForTest(null);

    await pendingDb.close();
    PendingMessageDbHelper.setDatabaseForTest(null);

    await dbHelperDb.close();
    DBHelper.setDatabaseForTest(null);

    MessageModifyService.postDirectOverride = null;
    MessageModifyService.testPostman = null;
  });

  group('direct chat (groupId: null)', () {
    late MessageActionsService actions;
    late List<String> cancelled;

    setUp(() {
      cancelled = [];
      actions = MessageActionsService(
        modifyService: MessageModifyService.direct(
          userId: 'me',
          keyManager: keyManager,
          peerId: 'peer',
        ),
        cancelPendingSend: cancelled.add,
      );
    });

    test('a still-pending outbound message is removed and cancelled', () async {
      const wireId = 'wire-1';
      await MessagesDb.insertMessage({
        'id': wireId,
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'cipher',
        'type': 'text',
        'status': 'pending',
        'timestamp': 1,
      });
      await PendingMessageDbHelper.insertPendingMessage({
        'id': wireId,
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'cipher',
        'type': 'text',
        'timestamp': 1,
        'status': 'pending',
      });

      final outcome = await actions.deleteMessage(
        TextMessage(id: wireId, authorId: 'me', text: 'x'),
        localUserId: 'me',
      );

      expect(outcome, MessageDeleteOutcome.removedPending);
      expect(cancelled, [wireId]);
      expect(await MessagesDb.getMessageById(wireId), isEmpty);
      expect(
        await PendingMessageDbHelper.getPendingMessages(receiverId: 'peer'),
        isEmpty,
      );
    });

    test('a sender-owned, already-sent message is soft-deleted (kept row)',
        () async {
      const wireId = 'wire-2';
      // The side-channel post succeeds so the delete-for-everyone branch
      // reports a delivered propagation (not the failure outcome).
      MessageModifyService.postDirectOverride = ({
        required id,
        required encrypted,
        required timestamp,
        required peerId,
      }) async =>
          true;
      await MessagesDb.insertMessage({
        'id': wireId,
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'cipher',
        'type': 'text',
        'status': 'sent',
        'timestamp': 1,
        'readAt': 1,
      });
      await MessageReactionsDb.upsertReaction(
        targetMessageId: wireId,
        reactorId: 'peer',
        emoji: '👍',
        timestamp: 1,
      );

      final outcome = await actions.deleteMessage(
        TextMessage(
          id: wireId,
          authorId: 'me',
          text: 'x',
          sentAt: DateTime.fromMillisecondsSinceEpoch(1),
        ),
        localUserId: 'me',
      );

      expect(outcome, MessageDeleteOutcome.markedDeletedForEveryone);
      final rows = await MessagesDb.getMessageById(wireId);
      expect(rows, hasLength(1));
      expect(rows.first['deletedAt'], isNotNull);
      expect(
        (await MessageReactionsDb.getReactionsForMessages([wireId]))[wireId],
        isNull,
      );
    });

    test('a rejected delete-for-everyone still tombstones locally', () async {
      const wireId = 'wire-7';
      // The side-channel post is rejected (override returns false), so the
      // delete-for-everyone branch reports the send-failure outcome even
      // though the local tombstone was still applied (row kept, deletedAt
      // set): local delete succeeds, propagation did not.
      MessageModifyService.postDirectOverride = ({
        required id,
        required encrypted,
        required timestamp,
        required peerId,
      }) async =>
          false;
      await MessagesDb.insertMessage({
        'id': wireId,
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'cipher',
        'type': 'text',
        'status': 'sent',
        'timestamp': 1,
      });

      final outcome = await actions.deleteMessage(
        TextMessage(
          id: wireId,
          authorId: 'me',
          text: 'x',
          sentAt: DateTime.fromMillisecondsSinceEpoch(1),
        ),
        localUserId: 'me',
      );

      expect(outcome, MessageDeleteOutcome.markedDeletedForEveryoneFailed);
      final rows = await MessagesDb.getMessageById(wireId);
      expect(rows, hasLength(1));
      expect(rows.first['deletedAt'], isNotNull);
    });

    test('a peer-owned message is removed locally only', () async {
      const wireId = 'wire-3';
      await MessagesDb.insertMessage({
        'id': wireId,
        'senderId': 'peer',
        'receiverId': 'me',
        'message': 'cipher',
        'type': 'text',
        'status': 'sent',
        'timestamp': 1,
      });

      final outcome = await actions.deleteMessage(
        TextMessage(id: wireId, authorId: 'peer', text: 'x'),
        localUserId: 'me',
      );

      expect(outcome, MessageDeleteOutcome.removedLocally);
      expect(await MessagesDb.getMessageById(wireId), isEmpty);
    });

    test('editTextMessage returns the updated message with edited metadata',
        () async {
      const wireId = 'wire-4';
      final peerIdentity = await IdentityKeyPair.generate();
      final identityJson = jsonEncode(await peerIdentity.toPublicJson());
      await DBHelper.insertOrUpdateUser({
        'id': 'peer',
        'name': 'Peer',
        'identityJson': identityJson,
        'publicKeyPem': identityJson,
      });
      final originalCipher = await keyManager.encryptForSelf('hello');
      await MessagesDb.insertMessage({
        'id': wireId,
        'senderId': 'me',
        'receiverId': 'peer',
        'message': originalCipher,
        'type': 'text',
        'status': 'sent',
        'timestamp': 1,
      });

      final updated = await actions.editTextMessage(
        TextMessage(id: wireId, authorId: 'me', text: 'hello'),
        'edited hello',
      );

      expect(updated, isNotNull);
      expect(updated!.text, 'edited hello');
      expect(updated.metadata, {'edited': true});
      final rows = await MessagesDb.getMessageById(wireId);
      expect(rows.first['editedAt'], isNotNull);
    });
  });

  group('group chat (groupId set)', () {
    test('scopes storage ids and never takes the pending-delete branch',
        () async {
      const wireId = 'wire-5';
      const groupId = 'group-1';
      final groupService = GroupService(userId: 'me', keyManager: keyManager);
      // One other member so the per-target send loop actually runs; with an
      // empty group_members table getMembers would return [] and the loop
      // would report all-delivered without ever sending anything.
      await DBHelper.addGroupMember({
        'groupId': groupId,
        'memberId': 'memberA',
        'role': 'member',
        'joinedAt': 1,
      });
      // A stored group key plus a deterministic postman whose sends all
      // succeed make the group side-channel propagation report delivered.
      final groupKey = GroupCryptoV2.generateGroupKey();
      await DBHelper.upsertGroupKey(
        groupId: groupId,
        encryptedKey: await GroupCryptoV2.encryptGroupKeyForStorage(
          groupKey,
          keyManager.identity,
        ),
        keyVersion: 1,
      );
      MessageModifyService.testPostman = _FakePostman();
      final actions = MessageActionsService(
        modifyService: MessageModifyService.group(
          userId: 'me',
          keyManager: keyManager,
          groupId: groupId,
          groupService: groupService,
        ),
        groupId: groupId,
        // No cancelPendingSend: groups never surface the pending branch.
      );
      await MessagesDb.insertMessage({
        'id': wireId,
        'senderId': 'me',
        'receiverId': 'memberB',
        'message': 'cipher',
        'type': 'text',
        'status': 'sent',
        'timestamp': 1,
        'groupId': groupId,
      });

      // Even a message that *looks* pending (no sentAt/seenAt) must not hit
      // the pending branch for groups: no cancelPendingSend was configured.
      final outcome = await actions.deleteMessage(
        TextMessage(id: wireId, authorId: 'me', text: 'x'),
        localUserId: 'me',
      );

      expect(outcome, MessageDeleteOutcome.markedDeletedForEveryone);
      final rows = await MessagesDb.getMessageById(wireId, groupId: groupId);
      expect(rows, hasLength(1));
      expect(rows.first['deletedAt'], isNotNull);
    });

    test(
        'a partially failed group delete-for-everyone still tombstones '
        'locally and reports the failure', () async {
      const wireId = 'wire-8';
      const groupId = 'group-1';
      final groupService = GroupService(userId: 'me', keyManager: keyManager);
      final groupKey = GroupCryptoV2.generateGroupKey();
      await DBHelper.upsertGroupKey(
        groupId: groupId,
        encryptedKey: await GroupCryptoV2.encryptGroupKeyForStorage(
          groupKey,
          keyManager.identity,
        ),
        keyVersion: 1,
      );
      // Two other members: the postman delivers to memberA but rejects
      // memberB, so the aggregation must report the send failure instead of
      // a delivered delete (impossible with an empty member list, which
      // would trivially report all-delivered).
      await DBHelper.addGroupMember({
        'groupId': groupId,
        'memberId': 'memberA',
        'role': 'member',
        'joinedAt': 1,
      });
      await DBHelper.addGroupMember({
        'groupId': groupId,
        'memberId': 'memberB',
        'role': 'member',
        'joinedAt': 1,
      });
      MessageModifyService.testPostman =
          _FakePostman(failingMembers: {'memberB'});
      final actions = MessageActionsService(
        modifyService: MessageModifyService.group(
          userId: 'me',
          keyManager: keyManager,
          groupId: groupId,
          groupService: groupService,
        ),
        groupId: groupId,
      );
      await MessagesDb.insertMessage({
        'id': wireId,
        'senderId': 'me',
        'receiverId': 'memberA',
        'message': 'cipher',
        'type': 'text',
        'status': 'sent',
        'timestamp': 1,
        'groupId': groupId,
      });

      final outcome = await actions.deleteMessage(
        TextMessage(id: wireId, authorId: 'me', text: 'x'),
        localUserId: 'me',
      );

      expect(outcome, MessageDeleteOutcome.markedDeletedForEveryoneFailed);
      final rows = await MessagesDb.getMessageById(wireId, groupId: groupId);
      expect(rows, hasLength(1));
      expect(rows.first['deletedAt'], isNotNull);
    });

    test('local-only delete removes the group-scoped row', () async {
      const wireId = 'wire-6';
      const groupId = 'group-1';
      final groupService = GroupService(userId: 'me', keyManager: keyManager);
      final actions = MessageActionsService(
        modifyService: MessageModifyService.group(
          userId: 'me',
          keyManager: keyManager,
          groupId: groupId,
          groupService: groupService,
        ),
        groupId: groupId,
      );
      await MessagesDb.insertMessage({
        'id': wireId,
        'senderId': 'memberB',
        'receiverId': 'me',
        'message': 'cipher',
        'type': 'text',
        'status': 'sent',
        'timestamp': 1,
        'groupId': groupId,
      });

      final outcome = await actions.deleteMessage(
        TextMessage(id: wireId, authorId: 'memberB', text: 'x'),
        localUserId: 'me',
      );

      expect(outcome, MessageDeleteOutcome.removedLocally);
      expect(
        await MessagesDb.getMessageById(wireId, groupId: groupId),
        isEmpty,
      );
    });
  });
}

/// Deterministic side-channel postman for group tests: succeeds for every
/// member except those listed in [failingMembers], which are rejected with a
/// neutral error (no Tor retry tokens, so delivery fails fast).
class _FakePostman implements SideChannelPostman {
  final Set<String> failingMembers;

  _FakePostman({this.failingMembers = const {}});

  @override
  Future<void> postDirect({
    required String peerId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {}

  @override
  Future<void> postGroup({
    required String targetMemberId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (failingMembers.contains(targetMemberId)) {
      throw Exception('peer rejected');
    }
  }
}
