import 'package:prysm/models/conversation_preferences.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class ConversationPreferencesDb {
  ConversationPreferencesDb._();

  static Future<void> createTable(Database db) async {
    await db.execute('''
      CREATE TABLE conversation_preferences (
        conversationId TEXT PRIMARY KEY,
        isPinned INTEGER NOT NULL DEFAULT 0,
        pinnedAt INTEGER,
        isArchived INTEGER NOT NULL DEFAULT 0,
        archivedAt INTEGER
      )
    ''');
  }

  static Future<ConversationPreferences?> get(String conversationId) async {
    final db = await DBHelper.database;
    final rows = await db.query(
      'conversation_preferences',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ConversationPreferences.fromMap(rows.first);
  }

  static Future<Map<String, ConversationPreferences>> getAll() async {
    final db = await DBHelper.database;
    final rows = await db.query('conversation_preferences');
    return {
      for (final row in rows)
        row['conversationId'] as String: ConversationPreferences.fromMap(row),
    };
  }

  static Future<void> upsert(ConversationPreferences prefs) async {
    final db = await DBHelper.database;
    await db.insert(
      'conversation_preferences',
      prefs.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> delete(String conversationId) async {
    final db = await DBHelper.database;
    await db.delete(
      'conversation_preferences',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
    );
  }
}
