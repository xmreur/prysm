import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/database/messages_database.dart';
import 'package:sqflite/sqflite.dart';

/// Rows for messages queued to be sent at a future time.
///
/// The `body` column is always ciphertext (encrypted for self); callers own
/// encrypting before insert and decrypting after read, so this DAO never sees
/// plaintext.
class ScheduledMessagesDb {
  ScheduledMessagesDb._();

  static Database? _testDatabase;

  static Future<Database> _db() async {
    if (_testDatabase != null) return _testDatabase!;
    return MessagesDb.database;
  }

  static void setDatabaseForTest(Database? db) {
    _testDatabase = db;
  }

  static Future<void> createTable(Database db) =>
      MessageSchemaMigrations.createScheduledMessagesTable(db);

  static Future<void> insert(Map<String, dynamic> row) async {
    await MessagesDatabase.mutex.protect(() async {
      final db = await _db();
      await db.insert(
        'scheduled_messages',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  /// Rows whose send time has arrived, oldest first.
  static Future<List<Map<String, dynamic>>> getDue(int nowMs) async {
    return MessagesDatabase.mutex.protect(() async {
      final db = await _db();
      return db.query(
        'scheduled_messages',
        where: 'sendAt <= ?',
        whereArgs: [nowMs],
        orderBy: 'sendAt ASC',
      );
    });
  }

  /// Earliest `sendAt` still queued, or null when the queue is empty.
  static Future<int?> getNextSendAt() async {
    return MessagesDatabase.mutex.protect(() async {
      final db = await _db();
      final rows = await db.rawQuery(
        'SELECT MIN(sendAt) AS next FROM scheduled_messages',
      );
      final value = rows.first['next'];
      if (value is int) return value;
      return value == null ? null : int.tryParse('$value');
    });
  }

  static Future<List<Map<String, dynamic>>> getForConversation(
    String conversationId,
  ) async {
    return MessagesDatabase.mutex.protect(() async {
      final db = await _db();
      return db.query(
        'scheduled_messages',
        where: 'conversationId = ?',
        whereArgs: [conversationId],
        orderBy: 'sendAt ASC',
      );
    });
  }

  static Future<int> countForConversation(String conversationId) async {
    return MessagesDatabase.mutex.protect(() async {
      final db = await _db();
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM scheduled_messages WHERE conversationId = ?',
        [conversationId],
      );
      final value = rows.first['c'];
      return value is int ? value : int.tryParse('$value') ?? 0;
    });
  }

  static Future<void> delete(String id) async {
    await MessagesDatabase.mutex.protect(() async {
      final db = await _db();
      await db.delete('scheduled_messages', where: 'id = ?', whereArgs: [id]);
    });
  }

  static Future<void> deleteForConversation(String conversationId) async {
    await MessagesDatabase.mutex.protect(() async {
      final db = await _db();
      await db.delete(
        'scheduled_messages',
        where: 'conversationId = ?',
        whereArgs: [conversationId],
      );
    });
  }
}
