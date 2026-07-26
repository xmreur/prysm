// Characterization tests for MessagesDb (Fase 4A), fixed against the CURRENT
// implementation before lifecycle, schema migrations, and the ID codec are
// extracted into lib/database/messages_database.dart,
// lib/database/message_schema_migrations.dart, and
// lib/database/message_id_codec.dart. Must stay green across the extraction
// with no behavioral change.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/ratchet/session_store.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
      editedAt INTEGER
    )
  ''');
  return db;
}

Future<Database> _openDbHelperDb() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  await db.execute('''
    CREATE TABLE group_members (
      groupId TEXT NOT NULL,
      memberId TEXT NOT NULL,
      role TEXT NOT NULL,
      joinedAt INTEGER NOT NULL,
      PRIMARY KEY (groupId, memberId)
    )
  ''');
  // DBHelper.setDatabaseForTest wires the ratchet session store onto
  // whatever db is injected; give it a table so that wiring doesn't throw.
  await RatchetSessionStore.ensureTable(db);
  return db;
}

void main() {
  late Directory docsDir;
  late Database db;
  late Database dbHelperDb;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // softDeleteMessage/getMessageWire/getMessageById unconditionally probe
    // MessageBlobStore, which shells out to path_provider even when no blob
    // file exists.
    docsDir = Directory.systemTemp.createTempSync('messages_db_char_test');
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
    db = await _openMessagesDb();
    MessagesDb.setDatabaseForTest(db);

    dbHelperDb = await _openDbHelperDb();
    DBHelper.setDatabaseForTest(dbHelperDb);
  });

  tearDown(() async {
    await db.close();
    MessagesDb.setDatabaseForTest(null);

    await dbHelperDb.close();
    DBHelper.setDatabaseForTest(null);
  });

  group('MessageIdCodec (scopedId/wireIdFromStorage)', () {
    test('scopedId prefixes the wireId with groupId when present', () {
      expect(MessagesDb.scopedId(wireId: 'w1', groupId: 'g1'), 'g1::w1');
    });

    test('scopedId returns the wireId unchanged without a groupId', () {
      expect(MessagesDb.scopedId(wireId: 'w1'), 'w1');
      expect(MessagesDb.scopedId(wireId: 'w1', groupId: ''), 'w1');
    });

    test('wireIdFromStorage strips the groupId scope', () {
      expect(MessagesDb.wireIdFromStorage('g1::w1'), 'w1');
    });

    test('wireIdFromStorage returns an unscoped id unchanged', () {
      expect(MessagesDb.wireIdFromStorage('w1'), 'w1');
    });

    test('wireIdFromStorage only strips the first separator', () {
      expect(MessagesDb.wireIdFromStorage('g1::w1::extra'), 'w1::extra');
    });
  });

  group('previewLabelForType', () {
    test('deleted always wins regardless of type', () {
      expect(MessagesDb.previewLabelForType('image', deleted: true), 'Deleted');
      expect(MessagesDb.previewLabelForType(null, deleted: true), 'Deleted');
    });

    test('maps known types to their labels', () {
      expect(MessagesDb.previewLabelForType('image'), '📷 Photo');
      expect(MessagesDb.previewLabelForType('group_image'), '📷 Photo');
      expect(MessagesDb.previewLabelForType('file'), '📎 File');
      expect(MessagesDb.previewLabelForType('group_file'), '📎 File');
      expect(MessagesDb.previewLabelForType('audio'), '🎤 Voice');
      expect(MessagesDb.previewLabelForType('group_audio'), '🎤 Voice');
      expect(MessagesDb.previewLabelForType('call'), '📞 Call');
    });

    test('falls back to a generic label for unknown/null types', () {
      expect(MessagesDb.previewLabelForType(null), 'Message');
      expect(MessagesDb.previewLabelForType('text'), 'Message');
    });
  });

  group('CRUD', () {
    test('insertMessage stores a direct message row', () async {
      await MessagesDb.insertMessage({
        'id': 'm1',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'hello',
        'type': 'text',
        'timestamp': 1000,
        'status': 'sent',
      });

      final rows = await MessagesDb.getMessagesBetween('me', 'peer');
      expect(rows, hasLength(1));
      expect(rows.first['id'], 'm1');
      expect(rows.first['message'], 'hello');
    });

    test('insertMessage scopes the storage id by groupId', () async {
      await MessagesDb.insertMessage({
        'id': 'gm1',
        'senderId': 'me',
        'receiverId': 'me',
        'groupId': 'g1',
        'message': 'hi group',
        'type': 'text',
        'timestamp': 1000,
        'status': 'sent',
      });

      final rows = await db.query('messages', where: 'groupId = ?', whereArgs: ['g1']);
      expect(rows.single['id'], 'g1::gm1');
    });

    test('insertMessage replaces an existing row with the same storage id', () async {
      await MessagesDb.insertMessage({
        'id': 'm1',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'first',
        'type': 'text',
        'timestamp': 1000,
        'status': 'sent',
      });
      await MessagesDb.insertMessage({
        'id': 'm1',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'second',
        'type': 'text',
        'timestamp': 1000,
        'status': 'sent',
      });

      final rows = await db.query('messages');
      expect(rows, hasLength(1));
      expect(rows.first['message'], 'second');
    });

    test('updateMessageContent edits message and editedAt but skips deleted rows', () async {
      await MessagesDb.insertMessage({
        'id': 'm1',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'original',
        'type': 'text',
        'timestamp': 1000,
        'status': 'sent',
      });

      await MessagesDb.updateMessageContent(
        wireId: 'm1',
        encryptedMessage: 'edited',
        editedAt: 2000,
      );
      var rows = await db.query('messages', where: 'id = ?', whereArgs: ['m1']);
      expect(rows.first['message'], 'edited');
      expect(rows.first['editedAt'], 2000);

      await MessagesDb.softDeleteMessage('m1', deletedAt: 3000);
      await MessagesDb.updateMessageContent(
        wireId: 'm1',
        encryptedMessage: 'should-not-apply',
        editedAt: 4000,
      );
      rows = await db.query('messages', where: 'id = ?', whereArgs: ['m1']);
      expect(rows.first['message'], null);
      // softDeleteMessage doesn't clear editedAt, and the second
      // updateMessageContent call is a no-op (where clause excludes
      // deleted rows), so the value from the first edit survives.
      expect(rows.first['editedAt'], 2000);
    });

    test('softDeleteMessage clears content fields and stamps deletedAt', () async {
      await MessagesDb.insertMessage({
        'id': 'm1',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'secret',
        'fileName': 'a.png',
        'fileSize': 42,
        'viewOnce': 1,
        'type': 'image',
        'timestamp': 1000,
        'status': 'sent',
      });

      await MessagesDb.softDeleteMessage('m1', deletedAt: 5000);

      final rows = await db.query('messages', where: 'id = ?', whereArgs: ['m1']);
      final row = rows.single;
      expect(row['deletedAt'], 5000);
      expect(row['message'], null);
      expect(row['fileName'], null);
      expect(row['fileSize'], null);
      expect(row['viewOnce'], 0);
    });

    test('deleteMessageById removes the row and nulls dangling replies', () async {
      await MessagesDb.insertMessage({
        'id': 'm1',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'root',
        'type': 'text',
        'timestamp': 1000,
        'status': 'sent',
      });
      await MessagesDb.insertMessage({
        'id': 'm2',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'reply',
        'replyTo': 'm1',
        'type': 'text',
        'timestamp': 2000,
        'status': 'sent',
      });

      await MessagesDb.deleteMessageById('m1');

      final remaining = await db.query('messages');
      expect(remaining, hasLength(1));
      expect(remaining.first['id'], 'm2');
      expect(remaining.first['replyTo'], null);
    });

    test('deleteMessagesBetween removes only the direct conversation', () async {
      await MessagesDb.insertMessage({
        'id': 'm1',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'a',
        'type': 'text',
        'timestamp': 1000,
        'status': 'sent',
      });
      await MessagesDb.insertMessage({
        'id': 'm2',
        'senderId': 'me',
        'receiverId': 'other',
        'message': 'b',
        'type': 'text',
        'timestamp': 1000,
        'status': 'sent',
      });

      await MessagesDb.deleteMessagesBetween('me', 'peer');

      final remaining = await db.query('messages');
      expect(remaining, hasLength(1));
      expect(remaining.first['id'], 'm2');
    });

    test('markViewOnceViewed wipes content only for view-once rows', () async {
      await MessagesDb.insertMessage({
        'id': 'vo1',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'burn',
        'viewOnce': 1,
        'type': 'image',
        'timestamp': 1000,
        'status': 'sent',
      });
      await MessagesDb.insertMessage({
        'id': 'normal',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'keep',
        'viewOnce': 0,
        'type': 'text',
        'timestamp': 2000,
        'status': 'sent',
      });

      await MessagesDb.markViewOnceViewed('vo1');

      final vo = (await db.query('messages', where: 'id = ?', whereArgs: ['vo1'])).single;
      expect(vo['viewed'], 1);
      expect(vo['message'], null);

      final normal = (await db.query('messages', where: 'id = ?', whereArgs: ['normal'])).single;
      expect(normal['viewed'], 0);
      expect(normal['message'], 'keep');
    });

    test('updateMessageStatus updates status by scoped id', () async {
      await MessagesDb.insertMessage({
        'id': 'gm1',
        'senderId': 'me',
        'receiverId': 'me',
        'groupId': 'g1',
        'message': 'hi',
        'type': 'text',
        'timestamp': 1000,
        'status': 'pending',
      });

      await MessagesDb.updateMessageStatus('gm1', 'sent', groupId: 'g1');

      final row = (await db.query('messages', where: 'id = ?', whereArgs: ['g1::gm1'])).single;
      expect(row['status'], 'sent');
    });
  });

  group('insertInboundMessage anti-clobber rule', () {
    test('keeps an existing outbound copy (same sender as localUserId, not received)', () async {
      await MessagesDb.insertMessage({
        'id': 'm1',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'my-cipher',
        'type': 'text',
        'timestamp': 1000,
        'status': 'sent',
      });

      final stored = await MessagesDb.insertInboundMessage({
        'id': 'm1',
        'senderId': 'peer',
        'receiverId': 'me',
        'message': 'their-cipher',
        'type': 'text',
        'timestamp': 1000,
        'status': 'received',
      }, 'me');

      expect(stored, isNull);
      final row = (await db.query('messages', where: 'id = ?', whereArgs: ['m1'])).single;
      expect(row['message'], 'my-cipher');
      expect(row['senderId'], 'me');
    });

    test('replaces an existing row that was itself a received inbound copy', () async {
      await db.insert('messages', {
        'id': 'm1',
        'senderId': 'peer',
        'receiverId': 'me',
        'message': 'old-cipher',
        'type': 'text',
        'timestamp': 1000,
        'status': 'received',
      });

      final stored = await MessagesDb.insertInboundMessage({
        'id': 'm1',
        'senderId': 'peer',
        'receiverId': 'me',
        'message': 'new-cipher',
        'type': 'text',
        'timestamp': 1500,
        'status': 'received',
      }, 'me');

      expect(stored, isNotNull);
      expect(stored!['message'], 'new-cipher');
      final row = (await db.query('messages', where: 'id = ?', whereArgs: ['m1'])).single;
      expect(row['message'], 'new-cipher');
    });

    test('inserts a fresh inbound message when no row exists yet', () async {
      final stored = await MessagesDb.insertInboundMessage({
        'id': 'm1',
        'senderId': 'peer',
        'receiverId': 'me',
        'message': 'cipher',
        'type': 'text',
        'timestamp': 1000,
        'status': 'received',
      }, 'me');

      expect(stored, isNotNull);
      final rows = await db.query('messages');
      expect(rows, hasLength(1));
    });

    test('does not clobber an outbound copy even if its own status is odd, as long as it is not received', () async {
      await MessagesDb.insertMessage({
        'id': 'm1',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'my-cipher',
        'type': 'text',
        'timestamp': 1000,
        'status': 'pending',
      });

      final stored = await MessagesDb.insertInboundMessage({
        'id': 'm1',
        'senderId': 'peer',
        'receiverId': 'me',
        'message': 'their-cipher',
        'type': 'text',
        'timestamp': 1000,
        'status': 'received',
      }, 'me');

      expect(stored, isNull);
    });
  });

  group('pagination strategies', () {
    Future<void> seedFive() async {
      for (var i = 1; i <= 5; i++) {
        await MessagesDb.insertMessage({
          'id': 'm$i',
          'senderId': 'me',
          'receiverId': 'peer',
          'message': 'msg$i',
          'type': 'text',
          'timestamp': i * 1000,
          'status': 'sent',
        });
      }
    }

    test('getMessagesBetweenBatch orders newest-first and honors limit', () async {
      await seedFive();
      final rows = await MessagesDb.getMessagesBetweenBatch('me', 'peer', limit: 2);
      expect(rows.map((r) => r['id']), ['m5', 'm4']);
    });

    test('getMessagesBetweenBatch pages backward using beforeTimestamp', () async {
      await seedFive();
      final rows = await MessagesDb.getMessagesBetweenBatch(
        'me',
        'peer',
        limit: 2,
        beforeTimestamp: 4000,
      );
      expect(rows.map((r) => r['id']), ['m3', 'm2']);
    });

    test('getMessagesBetweenBatchWithId breaks same-timestamp ties by id descending', () async {
      await MessagesDb.insertMessage({
        'id': 'aaa',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'a',
        'type': 'text',
        'timestamp': 1000,
        'status': 'sent',
      });
      await MessagesDb.insertMessage({
        'id': 'bbb',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'b',
        'type': 'text',
        'timestamp': 1000,
        'status': 'sent',
      });
      await MessagesDb.insertMessage({
        'id': 'ccc',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'c',
        'type': 'text',
        'timestamp': 2000,
        'status': 'sent',
      });

      final rows = await MessagesDb.getMessagesBetweenBatchWithId('me', 'peer', limit: 10);
      expect(rows.map((r) => r['id']), ['ccc', 'bbb', 'aaa']);
    });

    test('getMessagesBetweenBatchWithId cursor excludes the boundary row itself', () async {
      await MessagesDb.insertMessage({
        'id': 'aaa',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'a',
        'type': 'text',
        'timestamp': 1000,
        'status': 'sent',
      });
      await MessagesDb.insertMessage({
        'id': 'bbb',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'b',
        'type': 'text',
        'timestamp': 1000,
        'status': 'sent',
      });
      await MessagesDb.insertMessage({
        'id': 'ccc',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'c',
        'type': 'text',
        'timestamp': 2000,
        'status': 'sent',
      });

      final rows = await MessagesDb.getMessagesBetweenBatchWithId(
        'me',
        'peer',
        limit: 10,
        beforeTimestamp: 1000,
        beforeId: 'bbb',
      );
      expect(rows.map((r) => r['id']), ['aaa']);
    });
  });

  group('read waterline', () {
    test('setAsRead stamps readAt on the scoped row', () async {
      await MessagesDb.insertMessage({
        'id': 'm1',
        'senderId': 'peer',
        'receiverId': 'me',
        'message': 'hi',
        'type': 'text',
        'timestamp': 1000,
        'status': 'received',
      });

      await MessagesDb.setAsRead('m1');

      final row = (await db.query('messages', where: 'id = ?', whereArgs: ['m1'])).single;
      expect(row['readAt'], isNotNull);
    });

    test('markInboundConversationRead marks unread received rows and returns the latest waterline', () async {
      await db.insert('messages', {
        'id': 'already-read',
        'senderId': 'peer',
        'receiverId': 'me',
        'timestamp': 500,
        'status': 'received',
        'readAt': 123,
      });
      await MessagesDb.insertMessage({
        'id': 'p1',
        'senderId': 'peer',
        'receiverId': 'me',
        'message': 'a',
        'type': 'text',
        'timestamp': 1000,
        'status': 'received',
      });
      await MessagesDb.insertMessage({
        'id': 'p2',
        'senderId': 'peer',
        'receiverId': 'me',
        'message': 'b',
        'type': 'text',
        'timestamp': 2000,
        'status': 'received',
      });
      await MessagesDb.insertMessage({
        'id': 'out1',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'outbound',
        'type': 'text',
        'timestamp': 3000,
        'status': 'sent',
      });

      final mark = await MessagesDb.markInboundConversationRead('me', 'peer');

      expect(mark, isNotNull);
      expect(mark!.latestMessageId, 'p2');
      expect(mark.readUpToTimestamp, 2000);
      expect(mark.groupId, isNull);

      final p1 = (await db.query('messages', where: 'id = ?', whereArgs: ['p1'])).single;
      final p2 = (await db.query('messages', where: 'id = ?', whereArgs: ['p2'])).single;
      expect(p1['readAt'], isNotNull);
      expect(p2['readAt'], isNotNull);

      final alreadyRead = (await db.query('messages', where: 'id = ?', whereArgs: ['already-read'])).single;
      expect(alreadyRead['readAt'], 123);

      final out = (await db.query('messages', where: 'id = ?', whereArgs: ['out1'])).single;
      expect(out['readAt'], isNull);
    });

    test('markInboundConversationRead returns null when nothing is unread', () async {
      final mark = await MessagesDb.markInboundConversationRead('me', 'peer');
      expect(mark, isNull);
    });

    test('markInboundGroupRead marks unread received group rows excluding the local sender', () async {
      await MessagesDb.insertMessage({
        'id': 'gm1',
        'senderId': 'alice',
        'receiverId': 'me',
        'groupId': 'g1',
        'message': 'hi',
        'type': 'text',
        'timestamp': 1000,
        'status': 'received',
      });
      await MessagesDb.insertMessage({
        'id': 'gm2',
        'senderId': 'me',
        'receiverId': 'me',
        'groupId': 'g1',
        'message': 'mine',
        'type': 'text',
        'timestamp': 2000,
        'status': 'received',
      });

      final mark = await MessagesDb.markInboundGroupRead('me', 'g1');

      expect(mark, isNotNull);
      expect(mark!.latestMessageId, 'gm1');
      expect(mark.groupId, 'g1');

      final own = (await db.query('messages', where: 'id = ?', whereArgs: ['g1::gm2'])).single;
      expect(own['readAt'], isNull);
    });

    test('getOutboundDirectUpToTimestamp returns own sent rows ascending, gated by timestamp', () async {
      await MessagesDb.insertMessage({
        'id': 'm1',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'a',
        'type': 'text',
        'timestamp': 1000,
        'status': 'sent',
      });
      await MessagesDb.insertMessage({
        'id': 'm2',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'b',
        'type': 'text',
        'timestamp': 2000,
        'status': 'sent',
      });
      await MessagesDb.insertMessage({
        'id': 'm3',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'c',
        'type': 'text',
        'timestamp': 3000,
        'status': 'sent',
      });

      final rows = await MessagesDb.getOutboundDirectUpToTimestamp(
        senderId: 'me',
        receiverId: 'peer',
        readUpToTimestamp: 2000,
      );
      expect(rows.map((r) => r['id']), ['m1', 'm2']);
    });

    test('getOutboundGroupUpToTimestamp returns own group rows ascending, gated by timestamp', () async {
      await MessagesDb.insertMessage({
        'id': 'gm1',
        'senderId': 'me',
        'receiverId': 'me',
        'groupId': 'g1',
        'message': 'a',
        'type': 'text',
        'timestamp': 1000,
        'status': 'sent',
      });
      await MessagesDb.insertMessage({
        'id': 'gm2',
        'senderId': 'me',
        'receiverId': 'me',
        'groupId': 'g1',
        'message': 'b',
        'type': 'text',
        'timestamp': 5000,
        'status': 'sent',
      });

      final rows = await MessagesDb.getOutboundGroupUpToTimestamp(
        senderId: 'me',
        groupId: 'g1',
        readUpToTimestamp: 4000,
      );
      expect(rows.map((r) => r['id']), ['g1::gm1']);
    });
  });

  group('aggregates', () {
    Future<void> seedGroupMembership(String groupId, String memberId, int joinedAt) async {
      await dbHelperDb.insert('group_members', {
        'groupId': groupId,
        'memberId': memberId,
        'role': 'member',
        'joinedAt': joinedAt,
      });
    }

    test('getLastMessagePreviews labels the latest direct message per peer', () async {
      await MessagesDb.insertMessage({
        'id': 'm1',
        'senderId': 'me',
        'receiverId': 'peer1',
        'message': 'a',
        'type': 'text',
        'timestamp': 1000,
        'status': 'sent',
      });
      await MessagesDb.insertMessage({
        'id': 'm2',
        'senderId': 'me',
        'receiverId': 'peer1',
        'message': 'b',
        'type': 'image',
        'timestamp': 2000,
        'status': 'sent',
      });

      final previews = await MessagesDb.getLastMessagePreviews('me');
      expect(previews['peer1'], '📷 Photo');
    });

    test('getLastMessagePreviews reports Deleted for a soft-deleted latest message', () async {
      await MessagesDb.insertMessage({
        'id': 'm1',
        'senderId': 'me',
        'receiverId': 'peer2',
        'message': 'a',
        'type': 'file',
        'timestamp': 1000,
        'status': 'sent',
      });
      await MessagesDb.softDeleteMessage('m1', deletedAt: 5000);

      final previews = await MessagesDb.getLastMessagePreviews('me');
      expect(previews['peer2'], 'Deleted');
    });

    test('getLastMessagePreviews gates group previews by joinedAt and skips pre-join-only groups', () async {
      await seedGroupMembership('g-early', 'me', 500);
      await seedGroupMembership('g-late', 'me', 5000);

      await MessagesDb.insertMessage({
        'id': 'g1',
        'senderId': 'alice',
        'receiverId': 'me',
        'groupId': 'g-early',
        'message': 'before',
        'type': 'group_file',
        'timestamp': 200,
        'status': 'received',
      });
      await MessagesDb.insertMessage({
        'id': 'g2',
        'senderId': 'alice',
        'receiverId': 'me',
        'groupId': 'g-early',
        'message': 'after',
        'type': 'group_image',
        'timestamp': 1000,
        'status': 'received',
      });
      await MessagesDb.insertMessage({
        'id': 'g3',
        'senderId': 'alice',
        'receiverId': 'me',
        'groupId': 'g-late',
        'message': 'still-before-join',
        'type': 'group_file',
        'timestamp': 1000,
        'status': 'received',
      });

      final previews = await MessagesDb.getLastMessagePreviews('me');
      expect(previews['g-early'], '📷 Photo');
      expect(previews.containsKey('g-late'), isFalse);
    });

    test('getUnreadCounts counts unread inbound direct and group messages, gated by joinedAt', () async {
      await MessagesDb.insertMessage({
        'id': 'd1',
        'senderId': 'peer1',
        'receiverId': 'me',
        'message': 'a',
        'type': 'text',
        'timestamp': 1000,
        'status': 'received',
      });
      await MessagesDb.insertMessage({
        'id': 'd2',
        'senderId': 'peer1',
        'receiverId': 'me',
        'message': 'b',
        'type': 'text',
        'timestamp': 2000,
        'status': 'received',
      });
      // Already read: should not count.
      await MessagesDb.insertMessage({
        'id': 'd3',
        'senderId': 'peer1',
        'receiverId': 'me',
        'message': 'c',
        'type': 'text',
        'timestamp': 3000,
        'status': 'received',
      });
      await MessagesDb.setAsRead('d3');

      await seedGroupMembership('g1', 'me', 500);
      await MessagesDb.insertMessage({
        'id': 'gm1',
        'senderId': 'alice',
        'receiverId': 'me',
        'groupId': 'g1',
        'message': 'after-join',
        'type': 'text',
        'timestamp': 1000,
        'status': 'received',
      });
      await MessagesDb.insertMessage({
        'id': 'gm2',
        'senderId': 'alice',
        'receiverId': 'me',
        'groupId': 'g1',
        'message': 'before-join',
        'type': 'text',
        'timestamp': 100,
        'status': 'received',
      });
      // Own message in the group should never count as unread.
      await MessagesDb.insertMessage({
        'id': 'gm3',
        'senderId': 'me',
        'receiverId': 'me',
        'groupId': 'g1',
        'message': 'mine',
        'type': 'text',
        'timestamp': 1500,
        'status': 'received',
      });

      final counts = await MessagesDb.getUnreadCounts('me');
      expect(counts['peer1'], 2);
      expect(counts['g1'], 1);
    });

    test('getLastMessageTimestampForUser / getLastMessageTimestampsForAllUsers', () async {
      await MessagesDb.insertMessage({
        'id': 'm1',
        'senderId': 'me',
        'receiverId': 'peer1',
        'message': 'a',
        'type': 'text',
        'timestamp': 1000,
        'status': 'sent',
      });
      await MessagesDb.insertMessage({
        'id': 'm2',
        'senderId': 'peer1',
        'receiverId': 'me',
        'message': 'b',
        'type': 'text',
        'timestamp': 4000,
        'status': 'received',
      });
      await MessagesDb.insertMessage({
        'id': 'm3',
        'senderId': 'me',
        'receiverId': 'peer2',
        'message': 'c',
        'type': 'text',
        'timestamp': 2000,
        'status': 'sent',
      });

      expect(await MessagesDb.getLastMessageTimestampForUser('peer1'), 4000);

      final all = await MessagesDb.getLastMessageTimestampsForAllUsers();
      expect(all['peer1'], 4000);
      expect(all['peer2'], 2000);
    });

    test('getLastMessageTimestampsForAllGroups gates by joinedAt', () async {
      await seedGroupMembership('g-in', 'me', 500);
      await seedGroupMembership('g-out', 'me', 5000);

      await MessagesDb.insertMessage({
        'id': 'g1',
        'senderId': 'alice',
        'receiverId': 'me',
        'groupId': 'g-in',
        'message': 'a',
        'type': 'text',
        'timestamp': 1000,
        'status': 'received',
      });
      await MessagesDb.insertMessage({
        'id': 'g2',
        'senderId': 'alice',
        'receiverId': 'me',
        'groupId': 'g-out',
        'message': 'b',
        'type': 'text',
        'timestamp': 1000,
        'status': 'received',
      });

      final timestamps = await MessagesDb.getLastMessageTimestampsForAllGroups('me');
      expect(timestamps['g-in'], 1000);
      expect(timestamps.containsKey('g-out'), isFalse);
    });
  });
}
