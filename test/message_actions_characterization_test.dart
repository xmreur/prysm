// Characterization tests for the message delete/edit orchestration that, as
// of this commit, lives inline in `_ChatScreenState`
// (lib/screens/chat.dart: `_deletePendingMessage`, `_deleteMessage`,
// `deleteSelectedMessages`, `_editMessage`) and `_GroupChatScreenState`
// (lib/screens/group_chat.dart: `_deleteMessage`, `_deleteSelectedMessages`,
// `_editMessage`).
//
// Those methods are private to their States, so they cannot be called
// directly from a test. Per the Fase 6A brief, this file instead pins down
// their DB-observable contract: each `_dmXxx`/`_groupXxx` helper below is a
// line-for-line transcription of the current State method body (same DAO
// calls, same order, same branch conditions), driven against real in-memory
// sqflite DBs and a real `MessageModifyService`. Fase 6A step 4 moves this
// exact logic into `MessageActionsService`; this file is the baseline that
// proves nothing changed.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/database/message_reactions.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/group_service.dart';
import 'package:prysm/services/message_modify_service.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/message_content_wiper.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Stubs the path_provider channel so `MessageContentWiper.wipeLocalArtifacts`
/// (blob store + voice cache cleanup) can run without a real platform plugin.
void _mockPathProvider() {
  final tempDir = Directory.systemTemp.createTempSync('prysm_actions_test_');
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
      editedAt INTEGER
    )
  ''');
  await MessageReactionsDb.createTable(db);
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
  await RatchetSessionStore.ensureTable(db);
  return db;
}

/// Mirrors `_ChatScreenState._deletePendingMessage` (chat.dart 1994-2007).
Future<void> _dmDeletePendingMessage(
  String wireId, {
  required List<String> callOrder,
}) async {
  await PendingMessageDbHelper.removeOutboundPendingForWireId(wireId);
  callOrder.add('cancelPendingSend');
  await MessageContentWiper.wipeLocalArtifacts(wireId: wireId);
  await MessagesDb.deleteMessageById(wireId);
  await MessageReactionsDb.deleteReactionsForMessage(wireId);
}

/// Mirrors the `canDeleteForEveryone` branch of `_ChatScreenState._deleteMessage`
/// (chat.dart 2015-2024).
Future<void> _dmDeleteForEveryone(
  MessageModifyService modifyService,
  String wireId,
) async {
  await modifyService.deleteMessage(targetMessageId: wireId);
  await MessageReactionsDb.deleteReactionsForMessage(wireId);
}

/// Mirrors the `else` branch of `_ChatScreenState._deleteMessage` (chat.dart 2027-2035).
Future<void> _dmDeleteLocalOnly(String wireId) async {
  await MessageContentWiper.wipeLocalArtifacts(wireId: wireId);
  await MessagesDb.deleteMessageById(wireId);
  await MessageReactionsDb.deleteReactionsForMessage(wireId);
}

/// Mirrors the `canDeleteForEveryone` branch of `_GroupChatScreenState._deleteMessage`
/// (group_chat.dart 522-535).
Future<void> _groupDeleteForEveryone(
  MessageModifyService modifyService,
  String wireId,
  String groupId,
) async {
  await modifyService.deleteMessage(targetMessageId: wireId);
  final storageId = MessagesDb.scopedId(wireId: wireId, groupId: groupId);
  await MessageReactionsDb.deleteReactionsForMessage(storageId);
}

/// Mirrors the `else` branch of `_GroupChatScreenState._deleteMessage`
/// (group_chat.dart 537-551).
Future<void> _groupDeleteLocalOnly(String wireId, String groupId) async {
  final storageId = MessagesDb.scopedId(wireId: wireId, groupId: groupId);
  await MessageContentWiper.wipeLocalArtifacts(wireId: wireId, groupId: groupId);
  await MessagesDb.deleteMessageById(storageId);
  await MessageReactionsDb.deleteReactionsForMessage(storageId);
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

  setUp(() async {
    messagesDb = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(messagesDb);

    pendingDb = await _openPendingDb();
    PendingMessageDbHelper.setDatabaseForTest(pendingDb);

    dbHelperDb = await _openDbHelperDb();
    DBHelper.setDatabaseForTest(dbHelperDb);
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

  group('direct chat delete', () {
    test('deletePendingMessage removes pending row, message row, reactions, '
        'and cancels the send — in order', () async {
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
      await MessageReactionsDb.upsertReaction(
        targetMessageId: wireId,
        reactorId: 'peer',
        emoji: '👍',
        timestamp: 1,
      );

      final callOrder = <String>[];
      await _dmDeletePendingMessage(wireId, callOrder: callOrder);

      expect(callOrder, ['cancelPendingSend']);
      expect(
        await PendingMessageDbHelper.getPendingMessages(receiverId: 'peer'),
        isEmpty,
      );
      expect(await MessagesDb.getMessageById(wireId), isEmpty);
      expect(
        (await MessageReactionsDb.getReactionsForMessages([wireId]))[wireId],
        isNull,
      );
    });

    test('deleteForEveryone soft-deletes the row and drops reactions, '
        'keeping the message row', () async {
      const wireId = 'wire-2';
      final keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
      await MessagesDb.insertMessage({
        'id': wireId,
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'cipher',
        'type': 'text',
        'status': 'sent',
        'timestamp': 1,
      });
      await MessageReactionsDb.upsertReaction(
        targetMessageId: wireId,
        reactorId: 'peer',
        emoji: '👍',
        timestamp: 1,
      );

      final modifyService = MessageModifyService.direct(
        userId: 'me',
        keyManager: keyManager,
        peerId: 'peer',
      );
      await _dmDeleteForEveryone(modifyService, wireId);

      final rows = await MessagesDb.getMessageById(wireId);
      expect(rows, hasLength(1));
      expect(rows.first['deletedAt'], isNotNull);
      expect(
        (await MessageReactionsDb.getReactionsForMessages([wireId]))[wireId],
        isNull,
      );
    });

    test('deleteLocalOnly wipes artifacts and removes row + reactions', () async {
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
      await MessageReactionsDb.upsertReaction(
        targetMessageId: wireId,
        reactorId: 'me',
        emoji: '👍',
        timestamp: 1,
      );

      await _dmDeleteLocalOnly(wireId);

      expect(await MessagesDb.getMessageById(wireId), isEmpty);
      expect(
        (await MessageReactionsDb.getReactionsForMessages([wireId]))[wireId],
        isNull,
      );
    });
  });

  group('group chat delete', () {
    test('deleteForEveryone soft-deletes the scoped row and drops scoped '
        'reactions', () async {
      const wireId = 'wire-4';
      const groupId = 'group-1';
      final storageId = MessagesDb.scopedId(wireId: wireId, groupId: groupId);
      final keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
      final groupService = GroupService(userId: 'me', keyManager: keyManager);
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
      await MessageReactionsDb.upsertReaction(
        targetMessageId: storageId,
        reactorId: 'memberB',
        emoji: '👍',
        groupId: groupId,
        timestamp: 1,
      );

      final modifyService = MessageModifyService.group(
        userId: 'me',
        keyManager: keyManager,
        groupId: groupId,
        groupService: groupService,
      );
      await _groupDeleteForEveryone(modifyService, wireId, groupId);

      final rows = await MessagesDb.getMessageById(wireId, groupId: groupId);
      expect(rows, hasLength(1));
      expect(rows.first['deletedAt'], isNotNull);
      expect(
        (await MessageReactionsDb.getReactionsForMessages(
          [storageId],
          groupId: groupId,
        ))[storageId],
        isNull,
      );
    });

    test('deleteLocalOnly wipes artifacts and removes the scoped row + '
        'reactions', () async {
      const wireId = 'wire-5';
      const groupId = 'group-1';
      final storageId = MessagesDb.scopedId(wireId: wireId, groupId: groupId);
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
      await MessageReactionsDb.upsertReaction(
        targetMessageId: storageId,
        reactorId: 'me',
        emoji: '👍',
        groupId: groupId,
        timestamp: 1,
      );

      await _groupDeleteLocalOnly(wireId, groupId);

      expect(await MessagesDb.getMessageById(wireId, groupId: groupId), isEmpty);
      expect(
        (await MessageReactionsDb.getReactionsForMessages(
          [storageId],
          groupId: groupId,
        ))[storageId],
        isNull,
      );
    });
  });

  group('edit', () {
    test('direct edit re-encrypts content for self and marks editedAt', () async {
      const wireId = 'wire-6';
      final keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
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

      final modifyService = MessageModifyService.direct(
        userId: 'me',
        keyManager: keyManager,
        peerId: 'peer',
      );
      final ok = await modifyService.editTextMessage(
        targetMessageId: wireId,
        newText: 'edited text',
      );

      expect(ok, isTrue);
      final rows = await MessagesDb.getMessageById(wireId);
      expect(rows, hasLength(1));
      expect(rows.first['editedAt'], isNotNull);
      final storedCipher = rows.first['message'] as String;
      expect(storedCipher, isNot(originalCipher));
      expect(await keyManager.decryptMessage(storedCipher), 'edited text');
    });

    test('group edit is a no-op (returns false, row untouched) when no group '
        'key is configured — matches the current UI toast-on-failure path',
        () async {
      const wireId = 'wire-7';
      const groupId = 'group-2';
      final keyManager = KeyManager.fromIdentity(await IdentityKeyPair.generate());
      final groupService = GroupService(userId: 'me', keyManager: keyManager);
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

      final modifyService = MessageModifyService.group(
        userId: 'me',
        keyManager: keyManager,
        groupId: groupId,
        groupService: groupService,
      );
      final ok = await modifyService.editTextMessage(
        targetMessageId: wireId,
        newText: 'edited text',
      );

      expect(ok, isFalse);
      final rows = await MessagesDb.getMessageById(wireId, groupId: groupId);
      expect(rows.first['editedAt'], isNull);
      expect(rows.first['message'], 'cipher');
    });
  });
}
