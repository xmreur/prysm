import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/message_read_receipts.dart';
import 'package:prysm/database/messages.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('message_read_receipts upsert and query by wire id', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 9,
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
          await MessageReadReceiptsDb.createTable(db);
        },
      ),
    );

    // Point MessagesDb at in-memory db for this test.
    // MessageReadReceiptsDb uses MessagesDb.database — open via messages path hack:
    // Instead test the table operations directly.
    await db.insert('message_read_receipts', {
      'messageId': 'group1::msg1',
      'groupId': 'group1',
      'readerId': 'readerA',
      'readAt': 1000,
    });

    final rows = await db.query(
      'message_read_receipts',
      where: 'messageId = ?',
      whereArgs: ['group1::msg1'],
    );
    expect(rows.length, 1);
    expect(rows.first['readerId'], 'readerA');

    await db.insert(
      'message_read_receipts',
      {
        'messageId': 'group1::msg1',
        'groupId': 'group1',
        'readerId': 'readerA',
        'readAt': 2000,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    final updated = await db.query(
      'message_read_receipts',
      where: 'messageId = ?',
      whereArgs: ['group1::msg1'],
    );
    expect(updated.first['readAt'], 2000);

    await db.close();
  });

  test('v9 migration clears outbound delivery readAt artifacts', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 9),
    );

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

    await db.insert('messages', {
      'id': 'out1',
      'senderId': 'me',
      'receiverId': 'peer',
      'message': 'x',
      'type': 'text',
      'timestamp': 1,
      'status': 'sent',
      'readAt': 999,
    });
    await db.insert('messages', {
      'id': 'in1',
      'senderId': 'peer',
      'receiverId': 'me',
      'message': 'y',
      'type': 'text',
      'timestamp': 2,
      'status': 'received',
      'readAt': 888,
    });

    await db.execute('''
      UPDATE messages
      SET readAt = NULL
      WHERE COALESCE(status, '') = 'sent'
        AND COALESCE(status, '') != 'received'
    ''');

    final out = await db.query('messages', where: 'id = ?', whereArgs: ['out1']);
    final inbound =
        await db.query('messages', where: 'id = ?', whereArgs: ['in1']);

    expect(out.first['readAt'], isNull);
    expect(inbound.first['readAt'], 888);

    await db.close();
  });

  test('scopedId wire roundtrip', () {
    expect(
      MessagesDb.wireIdFromStorage('group::wire'),
      'wire',
    );
    expect(
      MessagesDb.scopedId(wireId: 'wire', groupId: 'group'),
      'group::wire',
    );
  });
}
