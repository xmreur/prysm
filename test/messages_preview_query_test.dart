import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/messages.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('SQL unread counts match per-conversation totals', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 6,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE messages(
              id TEXT PRIMARY KEY,
              senderId TEXT NOT NULL,
              receiverId TEXT NOT NULL,
              message TEXT,
              type TEXT,
              timestamp INTEGER NOT NULL,
              status TEXT DEFAULT 'sent',
              readAt INTEGER,
              groupId TEXT
            )
          ''');
        },
      ),
    );

    const local = 'me.onion';
    await db.insert('messages', {
      'id': '1',
      'senderId': 'peer.onion',
      'receiverId': local,
      'message': 'x',
      'type': 'text',
      'timestamp': 100,
      'status': 'received',
      'readAt': null,
    });
    await db.insert('messages', {
      'id': '2',
      'senderId': 'peer.onion',
      'receiverId': local,
      'message': 'y',
      'type': 'text',
      'timestamp': 101,
      'status': 'received',
      'readAt': null,
    });
    await db.insert('messages', {
      'id': '3',
      'senderId': local,
      'receiverId': 'peer.onion',
      'message': 'z',
      'type': 'text',
      'timestamp': 102,
      'status': 'sent',
      'readAt': null,
    });

    final rows = await db.rawQuery('''
      SELECT
        CASE
          WHEN groupId IS NOT NULL AND groupId != '' THEN groupId
          ELSE senderId
        END AS convKey,
        COUNT(*) AS cnt
      FROM messages
      WHERE senderId != ?
        AND status = 'received'
        AND readAt IS NULL
      GROUP BY convKey
    ''', [local]);

    expect(rows.length, 1);
    expect(rows.first['convKey'], 'peer.onion');
    expect(rows.first['cnt'], 2);

    await db.close();
  });

  test('previewLabelForType stays stable for sidebar labels', () {
    expect(MessagesDb.previewLabelForType('file'), '📎 File');
    expect(MessagesDb.previewLabelForType('audio'), '🎤 Voice');
  });
}
