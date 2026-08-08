// FTS de-indexing on message delete: every delete path must remove its
// search rows, scoped so a direct removal can never touch a group row that
// happens to share the same (attacker-suppliable) wire id.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/identity.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/message_search_dao.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/chat/prysm_message.dart';
import 'package:prysm/services/message_actions_service.dart';
import 'package:prysm/services/message_modify_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const MessageSearchDao searchDao = MessageSearchDao();

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // MessageContentWiper / MessageBlobStore touch the file system; the
    // MessageActionsService end-to-end test needs a path provider.
    final tempDir = Directory.systemTemp.createTempSync('prysm_search_delete_');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => tempDir.path);
  });

  late Database db;
  late Database pendingDb;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await MessageSchemaMigrations.onCreate(db, MessageSchemaMigrations.dbVersion);
    MessagesDb.setDatabaseForTest(db);

    pendingDb = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await pendingDb.execute('''
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
    PendingMessageDbHelper.setDatabaseForTest(pendingDb);
  });

  tearDown(() async {
    await MessagesDb.close();
    MessagesDb.setDatabaseForTest(null);
    await pendingDb.close();
    PendingMessageDbHelper.setDatabaseForTest(null);
  });

  /// Mirrors MessageSearchIndexService.indexInboundRow: direct FTS rows are
  /// keyed by the peer (the party that is not the local user).
  Future<void> insertDirect(
    String id,
    String senderId,
    String receiverId,
    String localUserId,
    int timestamp, {
    required String ftsBody,
  }) async {
    await MessagesDb.insertMessage({
      'id': id,
      'senderId': senderId,
      'receiverId': receiverId,
      'message': 'cipher',
      'type': 'text',
      'status': 'sent',
      'timestamp': timestamp,
    });
    await searchDao.upsert(
      messageId: id,
      conversationId: senderId == localUserId ? receiverId : senderId,
      scope: 'direct',
      timestamp: timestamp,
      body: ftsBody,
    );
  }

  Future<void> insertGroup(
    String id,
    String groupId,
    int timestamp, {
    required String ftsBody,
  }) async {
    await MessagesDb.insertMessage({
      'id': id,
      'senderId': 'peer',
      'receiverId': 'me',
      'message': 'cipher',
      'type': 'text',
      'status': 'sent',
      'timestamp': timestamp,
      'groupId': groupId,
    });
    await searchDao.upsert(
      messageId: id,
      conversationId: groupId,
      scope: 'group',
      timestamp: timestamp,
      body: ftsBody,
    );
  }

  test('deleteMessageById removes the FTS row for a direct message', () async {
    await insertDirect('dm-1', 'peer', 'me', 'me', 1, ftsBody: 'alpha needle');
    expect(await searchDao.searchGlobal('alpha'), hasLength(1));

    await MessagesDb.deleteMessageById('dm-1');

    expect(await searchDao.searchGlobal('alpha'), isEmpty);
    expect(await MessagesDb.getMessageById('dm-1'), isEmpty);
  });

  test('deleteMessageById removes the FTS row for a group message', () async {
    await insertGroup('gm-1', 'g1', 2, ftsBody: 'beta needle');
    expect(await searchDao.searchGlobal('beta'), hasLength(1));

    await MessagesDb.deleteMessageById('g1::gm-1');

    expect(await searchDao.searchGlobal('beta'), isEmpty);
  });

  test('a direct delete keeps a group FTS row with the same wire id',
      () async {
    await insertDirect('shared', 'peer', 'me', 'me', 3,
        ftsBody: 'zebra stripe');
    await insertGroup('shared', 'g1', 4, ftsBody: 'giraffe spot');
    expect(await searchDao.searchGlobal('zebra'), hasLength(1));
    expect(await searchDao.searchGlobal('giraffe'), hasLength(1));

    await MessagesDb.deleteMessageById('shared'); // direct storage id

    expect(await searchDao.searchGlobal('zebra'), isEmpty);
    final hits = await searchDao.searchGlobal('giraffe');
    expect(hits, hasLength(1));
    expect(hits.first.conversationId, 'g1');
  });

  test('deleteMessagesForGroup removes the group FTS rows', () async {
    await insertGroup('g2-1', 'g2', 1, ftsBody: 'charlie old');
    await insertGroup('g2-2', 'g2', 2, ftsBody: 'delta old');
    expect(await searchDao.searchGlobal('charlie'), hasLength(1));

    await MessagesDb.deleteMessagesForGroup('g2');

    expect(await searchDao.searchGlobal('charlie'), isEmpty);
    expect(await searchDao.searchGlobal('delta'), isEmpty);
  });

  test('deleteGroupMessagesBefore removes only the older FTS rows', () async {
    await insertGroup('g3-1', 'g3', 100, ftsBody: 'echo old');
    await insertGroup('g3-2', 'g3', 200, ftsBody: 'foxtrot new');

    await MessagesDb.deleteGroupMessagesBefore('g3', 150);

    expect(await searchDao.searchGlobal('echo'), isEmpty);
    final hits = await searchDao.searchGlobal('foxtrot');
    expect(hits, hasLength(1));
    expect(hits.first.messageId, 'g3-2');
  });

  test('deleteMessagesBetween removes both directions of FTS rows', () async {
    await insertDirect('dm-2', 'me', 'peer', 'me', 1,
        ftsBody: 'hotel outbound');
    await insertDirect('dm-3', 'peer', 'me', 'me', 2,
        ftsBody: 'india inbound');

    await MessagesDb.deleteMessagesBetween('me', 'peer');

    expect(await searchDao.searchGlobal('hotel'), isEmpty);
    expect(await searchDao.searchGlobal('india'), isEmpty);
  });

  test('MessageActionsService local-only delete de-indexes the message',
      () async {
    const wireId = 'wire-7';
    await insertDirect(wireId, 'peer', 'me', 'me', 1,
        ftsBody: 'juliet needle');
    final actions = MessageActionsService(
      modifyService: MessageModifyService.direct(
        userId: 'me',
        keyManager: KeyManager.fromIdentity(await IdentityKeyPair.generate()),
        peerId: 'peer',
      ),
    );

    final outcome = await actions.deleteMessage(
      TextMessage(id: wireId, authorId: 'peer', text: 'x'),
      localUserId: 'me',
    );

    expect(outcome, MessageDeleteOutcome.removedLocally);
    expect(await searchDao.searchGlobal('juliet'), isEmpty);
  });
}
