// chat.db v18 adds the nullable call_logs.groupId column so a group call can
// be logged without a peer onion. An install already at v17 has a call_logs
// table without the column, and CallLogsDb writes groupId on every insert, so
// a missing migration would fail every call log with "no such column".
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/call_logs_db.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('createTable ships groupId', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(() async => db.close());
    await CallLogsDb.createTable(db);

    final cols = await db.rawQuery('PRAGMA table_info(call_logs)');
    expect(cols.map((c) => c['name']), contains('groupId'));
  });

  test('applyCallLogsGroupIdV18 adds groupId and keeps existing rows', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(() async => db.close());
    // The v17 shape: same DDL as CallLogsDb.createTable before the bump.
    await db.execute('''
      CREATE TABLE call_logs (
        callId TEXT PRIMARY KEY,
        peerOnion TEXT NOT NULL,
        direction TEXT NOT NULL,
        status TEXT NOT NULL,
        startedAt INTEGER NOT NULL,
        endedAt INTEGER,
        durationMs INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.insert('call_logs', {
      'callId': 'legacy-1',
      'peerOnion': 'peer.onion',
      'direction': 'inbound',
      'status': 'completed',
      'startedAt': 42,
      'endedAt': 1042,
      'durationMs': 1000,
    });

    await DBHelper.applyCallLogsGroupIdV18(db);

    final cols = await db.rawQuery('PRAGMA table_info(call_logs)');
    expect(cols.map((c) => c['name']), contains('groupId'));
    // Dropping and recreating the table would satisfy a column-only
    // assertion while losing the user's history.
    final rows = await db.query('call_logs');
    expect(rows, hasLength(1));
    expect(rows.single['callId'], 'legacy-1');
    expect(rows.single['peerOnion'], 'peer.onion');
    expect(rows.single['durationMs'], 1000);
    expect(rows.single['groupId'], isNull);
  });

  test('applyCallLogsGroupIdV18 is a no-op when the column exists', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(() async => db.close());
    await CallLogsDb.createTable(db);

    await DBHelper.applyCallLogsGroupIdV18(db);
    await DBHelper.applyCallLogsGroupIdV18(db);

    final names =
        (await db.rawQuery('PRAGMA table_info(call_logs)')).map((c) => c['name']);
    expect(names.where((n) => n == 'groupId'), hasLength(1));
  });

  test('a group log keeps the group id and offers no place action', () async {
    final log = CallLog(
      callId: 'g-call-1',
      peerOnion: 'group-1',
      direction: CallLogDirection.inbound,
      status: CallLogStatus.missed,
      startedAt: 1,
      endedAt: 2,
      durationMs: 0,
      groupId: 'group-1',
    );
    expect(log.isGroup, isTrue);
    // A missed inbound 1:1 offers call-back; a group call has no single peer
    // to call back.
    expect(log.placeAction, isNull);
  });
}
