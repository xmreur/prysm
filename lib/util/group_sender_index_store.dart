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
  /// The row reuses the outbound `nextIndex` convention: for inbound rows the
  /// stored value is the smallest index not yet seen (maxSeen + 1). Returns
  /// false when [index] is a replay (<= the maximum already seen for the
  /// pair) without touching the row; true when it is new, advancing the
  /// watermark to [index] + 1. Outbound (`nextIndex`) and inbound rows never
  /// collide: outbound only ever writes the local user as senderId, inbound
  /// only ever records other members.
  static Future<bool> recordInboundIndex({
    required String groupId,
    required String senderId,
    required int index,
  }) async {
    return _mutex.protect(() async {
      final db = await DBHelper.database;
      final rows = await db.query(
        'group_sender_index',
        where: 'groupId = ? AND senderId = ?',
        whereArgs: [groupId, senderId],
        limit: 1,
      );
      final next = rows.isEmpty ? 0 : rows.first['nextIndex'] as int;
      if (index < next) return false;
      await db.insert(
        'group_sender_index',
        {
          'groupId': groupId,
          'senderId': senderId,
          'nextIndex': index + 1,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return true;
    });
  }

  static Future<void> resetForGroup(String groupId) async {
    await _mutex.protect(() async {
      final db = await DBHelper.database;
      await db.delete(
        'group_sender_index',
        where: 'groupId = ?',
        whereArgs: [groupId],
      );
    });
  }
}
