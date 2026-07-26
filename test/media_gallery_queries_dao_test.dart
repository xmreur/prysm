// Exercises MessagesDb.getMediaMessagesForDirect/getMediaMessagesForGroup
// through the public facade (MediaGalleryQueriesDao, Fase 4B DAO split).
// Unlike chat_media_query_test.dart -- which re-implements the query
// directly against a raw db and never calls these methods -- this actually
// runs the code under test.
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/messages.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openTestDb() async {
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
  return db;
}

void main() {
  late Database db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await _openTestDb();
    MessagesDb.setDatabaseForTest(db);
  });

  tearDown(() async {
    await db.close();
    MessagesDb.setDatabaseForTest(null);
  });

  group('getMediaMessagesForDirect', () {
    test('returns only media with content, newest first', () async {
      const local = 'me.onion';
      const peer = 'peer.onion';

      await db.insert('messages', {
        'id': 'img1',
        'senderId': peer,
        'receiverId': local,
        'message': 'cipher',
        'type': 'image',
        'timestamp': 300,
        'status': 'received',
      });
      await db.insert('messages', {
        'id': 'txt1',
        'senderId': peer,
        'receiverId': local,
        'message': 'hello',
        'type': 'text',
        'timestamp': 290,
        'status': 'received',
      });
      await db.insert('messages', {
        'id': 'del1',
        'senderId': peer,
        'receiverId': local,
        'message': '',
        'type': 'image',
        'timestamp': 280,
        'status': 'received',
        'deletedAt': 999,
      });
      await db.insert('messages', {
        'id': 'file1',
        'senderId': local,
        'receiverId': peer,
        'message': 'cipher-file',
        'type': 'file',
        'timestamp': 310,
        'status': 'sent',
      });

      final rows = await MessagesDb.getMediaMessagesForDirect(local, peer);
      expect(rows.map((r) => r['id']), ['file1', 'img1']);
    });

    test('typeFilter narrows to a single media type', () async {
      const local = 'me.onion';
      const peer = 'peer.onion';
      await db.insert('messages', {
        'id': 'img1',
        'senderId': peer,
        'receiverId': local,
        'message': 'cipher',
        'type': 'image',
        'timestamp': 100,
        'status': 'received',
      });
      await db.insert('messages', {
        'id': 'aud1',
        'senderId': peer,
        'receiverId': local,
        'message': 'cipher',
        'type': 'audio',
        'timestamp': 200,
        'status': 'received',
      });

      final rows = await MessagesDb.getMediaMessagesForDirect(
        local,
        peer,
        typeFilter: 'audio',
      );
      expect(rows, hasLength(1));
      expect(rows.first['id'], 'aud1');
    });

    test('beforeTimestamp paginates older results', () async {
      const local = 'me.onion';
      const peer = 'peer.onion';
      for (final ts in [100, 200, 300]) {
        await db.insert('messages', {
          'id': 'm$ts',
          'senderId': peer,
          'receiverId': local,
          'message': 'cipher',
          'type': 'image',
          'timestamp': ts,
          'status': 'received',
        });
      }

      final page = await MessagesDb.getMediaMessagesForDirect(
        local,
        peer,
        beforeTimestamp: 300,
      );
      expect(page.map((r) => r['id']), ['m200', 'm100']);
    });
  });

  group('getMediaMessagesForGroup', () {
    test('filters by group media types and content, gated by afterTimestamp', () async {
      await db.insert('messages', {
        'id': 'g1',
        'senderId': 'alice',
        'receiverId': 'me',
        'groupId': 'grp1',
        'message': 'cipher',
        'type': 'group_image',
        'timestamp': 1000,
        'status': 'received',
      });
      await db.insert('messages', {
        'id': 'g2-too-early',
        'senderId': 'alice',
        'receiverId': 'me',
        'groupId': 'grp1',
        'message': 'cipher',
        'type': 'group_image',
        'timestamp': 100,
        'status': 'received',
      });
      await db.insert('messages', {
        'id': 'g3-other-group',
        'senderId': 'alice',
        'receiverId': 'me',
        'groupId': 'grp2',
        'message': 'cipher',
        'type': 'group_image',
        'timestamp': 1500,
        'status': 'received',
      });
      await db.insert('messages', {
        'id': 'g4-text',
        'senderId': 'alice',
        'receiverId': 'me',
        'groupId': 'grp1',
        'message': 'plain text',
        'type': 'group_text',
        'timestamp': 1600,
        'status': 'received',
      });

      final rows = await MessagesDb.getMediaMessagesForGroup(
        'grp1',
        afterTimestamp: 500,
      );
      expect(rows.map((r) => r['id']), ['g1']);
    });
  });
}
