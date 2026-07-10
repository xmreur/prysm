import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/messages.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<Database> openTestDb(String name) async {
    return databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        singleInstance: false,
        version: 9,
        onCreate: (db, version) async {
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
        },
      ),
    );
  }

  test('direct media query returns only media with content', () async {
    final db = await openTestDb('media_content');
    const local = 'me.onion';
    const peer = 'peer.onion';

    await db.insert('messages', {
      'id': 'img1',
      'senderId': peer,
      'receiverId': local,
      'message': 'cipher',
      'type': 'image',
      'fileName': 'photo.jpg',
      'fileSize': 100,
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
      'id': 'viewed1',
      'senderId': peer,
      'receiverId': local,
      'message': '',
      'type': 'image',
      'timestamp': 270,
      'status': 'received',
      'viewOnce': 1,
      'viewed': 1,
    });

    final rows = await db.query(
      'messages',
      where:
          "groupId IS NULL AND type IN ('image', 'file', 'audio') "
          "AND deletedAt IS NULL AND message IS NOT NULL AND message != '' "
          "AND ((senderId = ? AND receiverId = ? AND COALESCE(status, '') != 'received') "
          "OR (senderId = ? AND receiverId = ? AND status = 'received'))",
      whereArgs: [local, peer, peer, local],
      orderBy: 'timestamp DESC',
    );

    expect(rows.length, 1);
    expect(rows.first['id'], 'img1');
  });

  test('direct media query filters by type', () async {
    final db = await openTestDb('media_type');
    const local = 'me.onion';
    const peer = 'peer.onion';

    for (final entry in [
      ('img', 'image', 300),
      ('file', 'file', 200),
      ('voice', 'audio', 100),
    ]) {
      await db.insert('messages', {
        'id': entry.$1,
        'senderId': local,
        'receiverId': peer,
        'message': 'payload',
        'type': entry.$2,
        'timestamp': entry.$3,
        'status': 'sent',
      });
    }

    final images = await db.query(
      'messages',
      where: "type = 'image'",
      whereArgs: const [],
    );
    expect(images.length, 1);
    expect(images.first['id'], 'img');
  });

  test('group media query respects afterTimestamp', () async {
    final db = await openTestDb('media_group');
    const groupId = 'group-1';

    await db.insert('messages', {
      'id': '$groupId::old',
      'senderId': 'a.onion',
      'receiverId': groupId,
      'message': 'old',
      'type': groupImageType,
      'timestamp': 100,
      'groupId': groupId,
    });
    await db.insert('messages', {
      'id': '$groupId::new',
      'senderId': 'a.onion',
      'receiverId': groupId,
      'message': 'new',
      'type': groupImageType,
      'timestamp': 200,
      'groupId': groupId,
    });

    final rows = await db.query(
      'messages',
      where:
          'groupId = ? AND type IN (?, ?, ?) AND deletedAt IS NULL '
          "AND message IS NOT NULL AND message != '' AND timestamp >= ?",
      whereArgs: [groupId, groupImageType, groupFileType, groupAudioType, 150],
      orderBy: 'timestamp DESC',
    );

    expect(rows.length, 1);
    expect(MessagesDb.wireIdFromStorage(rows.first['id'] as String), 'new');
  });

  test('media pagination uses beforeTimestamp cursor', () async {
    final db = await openTestDb('media_page');
    const local = 'me.onion';
    const peer = 'peer.onion';

    for (var i = 1; i <= 3; i++) {
      await db.insert('messages', {
        'id': 'm$i',
        'senderId': local,
        'receiverId': peer,
        'message': 'data',
        'type': 'image',
        'timestamp': i * 100,
        'status': 'sent',
      });
    }

    final page1 = await db.query(
      'messages',
      where: "type = 'image'",
      orderBy: 'timestamp DESC',
      limit: 2,
    );
    expect(page1.length, 2);
    expect(page1.first['id'], 'm3');

    final cursor = page1.last['timestamp'] as int;
    final page2 = await db.query(
      'messages',
      where: "type = 'image' AND timestamp < ?",
      whereArgs: [cursor],
      orderBy: 'timestamp DESC',
      limit: 2,
    );
    expect(page2.length, 1);
    expect(page2.first['id'], 'm1');
  });
}
