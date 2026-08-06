import 'package:mutex/mutex.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Tracks per-sender message index for group sender-key encryption.
class GroupSenderIndexStore {
  GroupSenderIndexStore._();

  static final Mutex _mutex = Mutex();

  static Future<void> ensureTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_sender_index (
        groupId TEXT NOT NULL,
        senderId TEXT NOT NULL,
        nextIndex INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (groupId, senderId)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_inbound_seen (
        groupId TEXT NOT NULL,
        senderId TEXT NOT NULL,
        msgIndex INTEGER NOT NULL,
        PRIMARY KEY (groupId, senderId, msgIndex)
      )
    ''');
  }

  static Future<int> nextIndex({
    required String groupId,
    required String senderId,
  }) async {
    return _mutex.protect(() async {
      final db = await DBHelper.database;
      final rows = await db.query(
        'group_sender_index',
        where: 'groupId = ? AND senderId = ?',
        whereArgs: [groupId, senderId],
        limit: 1,
      );
      final current = rows.isEmpty ? 0 : rows.first['nextIndex'] as int;
      final next = current + 1;
      await db.insert(
        'group_sender_index',
        {
          'groupId': groupId,
          'senderId': senderId,
          'nextIndex': next,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return current;
    });
  }

  /// Records a seen inbound sender-key index for (groupId, senderId).
  ///
  /// Exact-duplicate detection: the seen-set holds one row per received
  /// group message, so the check is order-independent. A late or
  /// out-of-order first sighting is accepted; only the exact
  /// (groupId, senderId, index) triple already recorded is rejected. The
  /// check-and-record is a single `INSERT OR IGNORE` — atomic in SQLite —
  /// so this method needs no mutex (unlike [nextIndex], which is a
  /// read-modify-write). Returns false when the exact triple was already
  /// recorded.
  static Future<bool> recordInboundIndex({
    required String groupId,
    required String senderId,
    required int index,
  }) async {
    final db = await DBHelper.database;
    final inserted = await db.insert(
      'group_inbound_seen',
      {
        'groupId': groupId,
        'senderId': senderId,
        'msgIndex': index,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return inserted != 0;
  }

  static Future<void> resetForGroup(String groupId) async {
    await _mutex.protect(() async {
      final db = await DBHelper.database;
      await db.delete(
        'group_sender_index',
        where: 'groupId = ?',
        whereArgs: [groupId],
      );
      await db.delete(
        'group_inbound_seen',
        where: 'groupId = ?',
        whereArgs: [groupId],
      );
    });
  }
}
