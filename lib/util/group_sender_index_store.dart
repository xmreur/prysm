import 'package:prysm/util/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Tracks per-sender message index for group sender-key encryption.
class GroupSenderIndexStore {
  GroupSenderIndexStore._();

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
  }

  static Future<void> resetForGroup(String groupId) async {
    final db = await DBHelper.database;
    await db.delete(
      'group_sender_index',
      where: 'groupId = ?',
      whereArgs: [groupId],
    );
  }
}
