import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('removeOutboundPendingForWireId drops direct and group rows', () async {
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
    PendingMessageDbHelper.setDatabaseForTest(db);

    await PendingMessageDbHelper.insertPendingMessage({
      'id': 'msg1',
      'senderId': 'me',
      'receiverId': 'peer',
      'message': 'cipher',
      'type': 'file',
      'timestamp': 1,
      'status': 'pending',
    });
    await PendingMessageDbHelper.insertPendingMessage({
      'id': 'msg2__memberB',
      'senderId': 'me',
      'receiverId': 'memberB',
      'message': 'cipher',
      'type': groupFileType,
      'timestamp': 1,
      'status': 'pending',
      'groupId': 'g1',
      'targetMemberId': 'memberB',
    });

    await PendingMessageDbHelper.removeOutboundPendingForWireId('msg1');
    var rows = await db.query('pending_messages');
    expect(rows.length, 1);
    expect(rows.first['id'], 'msg2__memberB');

    await PendingMessageDbHelper.removeOutboundPendingForWireId(
      'msg2',
      groupId: 'g1',
    );
    rows = await db.query('pending_messages');
    expect(rows, isEmpty);

    PendingMessageDbHelper.setDatabaseForTest(null);
    await db.close();
  });
}
