import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('direct pending rows filter by receiverId', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (db, version) async {
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
        },
      ),
    );

    await db.insert('pending_messages', {
      'id': 'a1',
      'senderId': 'me.onion',
      'receiverId': 'peer-a.onion',
      'message': 'enc',
      'type': 'text',
      'timestamp': 1,
    });
    await db.insert('pending_messages', {
      'id': 'b1',
      'senderId': 'me.onion',
      'receiverId': 'peer-b.onion',
      'message': 'enc',
      'type': 'text',
      'timestamp': 2,
    });

    final forA = await db.query(
      'pending_messages',
      where: 'groupId IS NULL AND receiverId = ?',
      whereArgs: ['peer-a.onion'],
    );
    expect(forA.length, 1);
    expect(forA.first['id'], 'a1');

    final allDirect = await db.query(
      'pending_messages',
      where: 'groupId IS NULL AND senderId = ?',
      whereArgs: ['me.onion'],
    );
    expect(allDirect.length, 2);

    await db.close();
  });

  test('hasOutboundDirectPending and filtered query', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (db, version) async {
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
        },
      ),
    );

    await db.insert('pending_messages', {
      'id': 'a1',
      'senderId': 'me.onion',
      'receiverId': 'peer-a.onion',
      'message': 'enc',
      'type': 'text',
      'timestamp': 1,
    });
    await db.insert('pending_messages', {
      'id': 'b1',
      'senderId': 'me.onion',
      'receiverId': 'peer-b.onion',
      'message': 'enc',
      'type': 'text',
      'timestamp': 2,
    });

    final forPeerA = await db.query(
      'pending_messages',
      where: 'groupId IS NULL AND senderId = ? AND receiverId = ?',
      whereArgs: ['me.onion', 'peer-a.onion'],
    );
    expect(forPeerA.length, 1);

    final countResult = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM pending_messages '
      'WHERE groupId IS NULL AND senderId = ? AND receiverId = ?',
      ['me.onion', 'peer-a.onion'],
    );
    expect((countResult.first['c'] as int?) ?? 0, 1);

    await db.close();
  });
}
