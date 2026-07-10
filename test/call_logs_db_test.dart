import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/call_logs_db.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        singleInstance: false,
        version: 1,
        onCreate: (db, _) async {
          await CallLogsDb.createTable(db);
        },
      ),
    );
    DBHelper.setDatabaseForTest(db);
  });

  tearDown(() {
    DBHelper.setDatabaseForTest(null);
  });

  test('insert and retrieve a call log', () async {
    await CallLogsDb.insertLog(
      callId: 'call-1',
      peerOnion: 'peer.onion',
      direction: CallLogDirection.outbound,
      status: CallLogStatus.ringing,
      startedAt: 1000,
    );

    final logs = await CallLogsDb.getLogs();
    expect(logs.length, 1);
    expect(logs.first.callId, 'call-1');
    expect(logs.first.peerOnion, 'peer.onion');
    expect(logs.first.direction, CallLogDirection.outbound);
    expect(logs.first.status, CallLogStatus.ringing);
    expect(logs.first.startedAt, 1000);
    expect(logs.first.endedAt, null);
    expect(logs.first.durationMs, 0);
  });

  test('update a call log', () async {
    await CallLogsDb.insertLog(
      callId: 'call-2',
      peerOnion: 'peer.onion',
      direction: CallLogDirection.inbound,
      status: CallLogStatus.ringing,
      startedAt: 2000,
    );

    await CallLogsDb.upsertLog(
      callId: 'call-2',
      peerOnion: 'peer.onion',
      direction: CallLogDirection.inbound,
      status: CallLogStatus.completed,
      startedAt: 2000,
      endedAt: 5000,
      durationMs: 3000,
    );

    final logs = await CallLogsDb.getLogs();
    expect(logs.first.status, CallLogStatus.completed);
    expect(logs.first.endedAt, 5000);
    expect(logs.first.durationMs, 3000);
  });

  test('filter logs by peer onion', () async {
    await CallLogsDb.insertLog(
      callId: 'call-a',
      peerOnion: 'peer-a.onion',
      direction: CallLogDirection.outbound,
      status: CallLogStatus.completed,
      startedAt: 1000,
    );
    await CallLogsDb.insertLog(
      callId: 'call-b',
      peerOnion: 'peer-b.onion',
      direction: CallLogDirection.inbound,
      status: CallLogStatus.missed,
      startedAt: 2000,
    );

    final logs = await CallLogsDb.getLogs(peerOnion: 'peer-a.onion');
    expect(logs.length, 1);
    expect(logs.first.callId, 'call-a');
  });

  test('delete a single log', () async {
    await CallLogsDb.insertLog(
      callId: 'call-3',
      peerOnion: 'peer.onion',
      direction: CallLogDirection.outbound,
      status: CallLogStatus.ringing,
      startedAt: 3000,
    );

    await CallLogsDb.deleteLog('call-3');
    final logs = await CallLogsDb.getLogs();
    expect(logs, isEmpty);
  });

  test('delete all logs', () async {
    await CallLogsDb.insertLog(
      callId: 'call-4',
      peerOnion: 'peer.onion',
      direction: CallLogDirection.outbound,
      status: CallLogStatus.ringing,
      startedAt: 4000,
    );
    await CallLogsDb.insertLog(
      callId: 'call-5',
      peerOnion: 'peer.onion',
      direction: CallLogDirection.inbound,
      status: CallLogStatus.missed,
      startedAt: 5000,
    );

    await CallLogsDb.deleteAllLogs();
    final logs = await CallLogsDb.getLogs();
    expect(logs, isEmpty);
  });
}
