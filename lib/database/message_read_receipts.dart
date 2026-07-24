import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/database/messages_database.dart';
import 'package:sqflite/sqflite.dart';

class MessageReadReceiptsDb {
  static Future<void> createTable(Database db) =>
      MessageSchemaMigrations.createReadReceiptsTable(db);

  static String _storageId(String wireMessageId, {String? groupId}) =>
      MessagesDb.scopedId(wireId: wireMessageId, groupId: groupId);

  static Future<void> upsertReceipt({
    required String wireMessageId,
    required String readerId,
    required int readAt,
    String? groupId,
  }) async {
    await MessagesDatabase.mutex.protect(() async {
      final db = await MessagesDb.database;
      final messageId = _storageId(wireMessageId, groupId: groupId);
      await db.insert(
        'message_read_receipts',
        {
          'messageId': messageId,
          'groupId': groupId,
          'readerId': readerId,
          'readAt': readAt,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  static Future<List<Map<String, dynamic>>> getReceiptsForMessage({
    required String wireMessageId,
    String? groupId,
  }) async {
    return MessagesDatabase.mutex.protect(() async {
      final db = await MessagesDb.database;
      final messageId = _storageId(wireMessageId, groupId: groupId);
      return db.query(
        'message_read_receipts',
        where: 'messageId = ?',
        whereArgs: [messageId],
        orderBy: 'readAt ASC',
      );
    });
  }

  static Future<Map<String, List<Map<String, dynamic>>>> getReceiptsForMessages(
    List<String> wireIds, {
    String? groupId,
  }) async {
    if (wireIds.isEmpty) return {};
    return MessagesDatabase.mutex.protect(() async {
      final db = await MessagesDb.database;
      final storageIds = wireIds
          .map((id) => _storageId(id, groupId: groupId))
          .toList();
      final placeholders = List.filled(storageIds.length, '?').join(',');
      final rows = await db.query(
        'message_read_receipts',
        where: 'messageId IN ($placeholders)',
        whereArgs: storageIds,
        orderBy: 'readAt ASC',
      );

      final result = <String, List<Map<String, dynamic>>>{};
      for (final row in rows) {
        final storageMessageId = row['messageId'] as String;
        final wireId = MessagesDb.wireIdFromStorage(storageMessageId);
        result.putIfAbsent(wireId, () => []).add(row);
      }
      return result;
    });
  }
}
