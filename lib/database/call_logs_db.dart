import 'package:prysm/util/db_helper.dart';
import 'package:sqflite/sqflite.dart';

enum CallLogDirection {
  inbound,
  outbound,
}

enum CallLogStatus {
  ringing,
  completed,
  missed,
  declined,
  failed,
}

class CallLog {
  const CallLog({
    required this.callId,
    required this.peerOnion,
    required this.direction,
    required this.status,
    required this.startedAt,
    required this.endedAt,
    required this.durationMs,
  });

  final String callId;
  final String peerOnion;
  final CallLogDirection direction;
  final CallLogStatus status;
  final int startedAt;
  final int? endedAt;
  final int durationMs;

  bool get isSuccessful => status == CallLogStatus.completed;
}

class CallLogsDb {
  static const String _table = 'call_logs';

  static Future<void> createTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_table (
        callId TEXT PRIMARY KEY,
        peerOnion TEXT NOT NULL,
        direction TEXT NOT NULL,
        status TEXT NOT NULL,
        startedAt INTEGER NOT NULL,
        endedAt INTEGER,
        durationMs INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_call_logs_peer ON $_table(peerOnion)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_call_logs_started ON $_table(startedAt DESC)',
    );
  }

  static Future<void> insertLog({
    required String callId,
    required String peerOnion,
    required CallLogDirection direction,
    required CallLogStatus status,
    required int startedAt,
  }) async {
    final db = await DBHelper.database;
    await db.insert(
      _table,
      {
        'callId': callId,
        'peerOnion': peerOnion,
        'direction': direction.name,
        'status': status.name,
        'startedAt': startedAt,
        'endedAt': null,
        'durationMs': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> upsertLog({
    required String callId,
    required String peerOnion,
    required CallLogDirection direction,
    required CallLogStatus status,
    required int startedAt,
    required int endedAt,
    required int durationMs,
  }) async {
    final db = await DBHelper.database;
    await db.insert(
      _table,
      {
        'callId': callId,
        'peerOnion': peerOnion,
        'direction': direction.name,
        'status': status.name,
        'startedAt': startedAt,
        'endedAt': endedAt,
        'durationMs': durationMs,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<List<CallLog>> getLogs({
    String? peerOnion,
    int limit = 100,
    int offset = 0,
  }) async {
    final db = await DBHelper.database;
    String? where;
    List<dynamic>? whereArgs;
    if (peerOnion != null && peerOnion.isNotEmpty) {
      where = 'peerOnion = ?';
      whereArgs = [peerOnion];
    }
    final rows = await db.query(
      _table,
      where: where,
      whereArgs: whereArgs,
      orderBy: 'startedAt DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_mapRow).toList();
  }

  static Future<void> deleteLog(String callId) async {
    final db = await DBHelper.database;
    await db.delete(_table, where: 'callId = ?', whereArgs: [callId]);
  }

  static Future<void> deleteAllLogs() async {
    final db = await DBHelper.database;
    await db.delete(_table);
  }

  static CallLog _mapRow(Map<String, dynamic> row) {
    return CallLog(
      callId: row['callId'] as String,
      peerOnion: row['peerOnion'] as String,
      direction: CallLogDirection.values.byName(row['direction'] as String),
      status: CallLogStatus.values.byName(row['status'] as String),
      startedAt: row['startedAt'] as int,
      endedAt: row['endedAt'] as int?,
      durationMs: row['durationMs'] as int,
    );
  }
}
