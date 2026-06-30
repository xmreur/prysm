import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/self_messages_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final db = await databaseFactory.openDatabase(
      '${inMemoryDatabasePath}_${DateTime.now().microsecondsSinceEpoch}',
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await SelfMessagesDb.createTable(db);
        },
      ),
    );
    SelfMessagesDb.setDatabaseForTest(db);
  });

  tearDown(() async {
    SelfMessagesDb.setDatabaseForTest(null);
  });

  test('insert and batch query returns newest first', () async {
    await SelfMessagesDb.insertMessage({
      'id': 'a',
      'message': 'enc-a',
      'type': 'text',
      'timestamp': 100,
    });
    await SelfMessagesDb.insertMessage({
      'id': 'b',
      'message': 'enc-b',
      'type': 'text',
      'timestamp': 200,
    });

    final batch = await SelfMessagesDb.getMessagesBatch(limit: 10);
    expect(batch.length, 2);
    expect(batch.first['id'], 'b');
    expect(batch.last['id'], 'a');
  });

  test('getLastPreview returns type labels', () async {
    await SelfMessagesDb.insertMessage({
      'id': 'img',
      'message': 'enc',
      'type': 'image',
      'timestamp': 50,
    });
    await SelfMessagesDb.insertMessage({
      'id': 'voice',
      'message': 'enc',
      'type': 'audio',
      'timestamp': 100,
    });

    final preview = await SelfMessagesDb.getLastPreview();
    expect(preview, '🎤 Voice');
  });

  test('pagination with beforeTimestamp', () async {
    await SelfMessagesDb.insertMessage({
      'id': '1',
      'message': 'a',
      'type': 'text',
      'timestamp': 100,
    });
    await SelfMessagesDb.insertMessage({
      'id': '2',
      'message': 'b',
      'type': 'text',
      'timestamp': 200,
    });
    await SelfMessagesDb.insertMessage({
      'id': '3',
      'message': 'c',
      'type': 'text',
      'timestamp': 300,
    });

    final page = await SelfMessagesDb.getMessagesBatch(
      limit: 2,
      beforeTimestamp: 300,
    );
    expect(page.map((r) => r['id']).toList(), ['2', '1']);
  });

  test('soft delete excludes from preview', () async {
    await SelfMessagesDb.insertMessage({
      'id': 'old',
      'message': 'enc',
      'type': 'file',
      'timestamp': 100,
    });
    await SelfMessagesDb.insertMessage({
      'id': 'new',
      'message': 'enc',
      'type': 'text',
      'timestamp': 200,
    });

    await SelfMessagesDb.softDelete('new');

    final preview = await SelfMessagesDb.getLastPreview();
    expect(preview, '📎 File');

    final ts = await SelfMessagesDb.getLastTimestamp();
    expect(ts, 100);
  });
}
