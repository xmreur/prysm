import 'package:mutex/mutex.dart';
import 'package:prysm/database/messages.dart';
import 'package:sqflite/sqflite.dart';

/// Local-only notes-to-self messages (no P2P).
class SelfMessagesDb {
  SelfMessagesDb._();

  static final _mutex = Mutex();
  static Database? _testDatabase;

  static Future<Database> _db() async {
    if (_testDatabase != null) return _testDatabase!;
    return MessagesDb.database;
  }

  static void setDatabaseForTest(Database? db) {
    _testDatabase = db;
  }

  static const _typeFilter =
      "(type IS NULL OR type IN ('text', 'file', 'image', 'audio'))";

  static Future<void> createTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS self_messages (
        id TEXT PRIMARY KEY,
        message TEXT,
        type TEXT DEFAULT 'text',
        fileName TEXT,
        fileSize INTEGER,
        timestamp INTEGER NOT NULL,
        replyTo TEXT,
        viewOnce INTEGER DEFAULT 0,
        viewed INTEGER DEFAULT 0,
        deletedAt INTEGER,
        editedAt INTEGER
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_self_messages_ts ON self_messages(timestamp)',
    );
  }

  static Future<void> insertMessage(Map<String, dynamic> message) async {
    await _mutex.protect(() async {
      final db = await _db();
      await db.insert(
        'self_messages',
        message,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  static Future<List<Map<String, dynamic>>> getMessagesBatch({
    int limit = 20,
    int? beforeTimestamp,
    String? beforeId,
  }) async {
    return _mutex.protect(() async {
      final db = await _db();
      var where = _typeFilter;
      final whereArgs = <dynamic>[];

      if (beforeTimestamp != null && beforeId != null) {
        where += ' AND (timestamp < ? OR (timestamp = ? AND id < ?))';
        whereArgs.addAll([beforeTimestamp, beforeTimestamp, beforeId]);
      } else if (beforeTimestamp != null) {
        where += ' AND timestamp < ?';
        whereArgs.add(beforeTimestamp);
      } else if (beforeId != null) {
        where += ' AND id < ?';
        whereArgs.add(beforeId);
      }

      return db.query(
        'self_messages',
        where: where,
        whereArgs: whereArgs.isEmpty ? null : whereArgs,
        orderBy: 'timestamp DESC, id DESC',
        limit: limit,
      );
    });
  }

  static Future<int?> getLastTimestamp() async {
    return _mutex.protect(() async {
      final db = await _db();
      final result = await db.rawQuery('''
        SELECT MAX(timestamp) AS lastTimestamp
        FROM self_messages
        WHERE deletedAt IS NULL
          AND $_typeFilter
      ''');
      if (result.isEmpty || result.first['lastTimestamp'] == null) {
        return null;
      }
      final value = result.first['lastTimestamp'];
      return value is int ? value : int.tryParse(value.toString());
    });
  }

  static Future<String?> getLastPreview() async {
    return _mutex.protect(() async {
      final db = await _db();
      final rows = await db.query(
        'self_messages',
        columns: ['type', 'deletedAt'],
        where: 'deletedAt IS NULL AND $_typeFilter',
        orderBy: 'timestamp DESC',
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final row = rows.first;
      return MessagesDb.previewLabelForType(row['type'] as String?);
    });
  }

  static Future<void> softDelete(String messageId) async {
    await _mutex.protect(() async {
      final db = await _db();
      await db.update(
        'self_messages',
        {
          'deletedAt': DateTime.now().millisecondsSinceEpoch,
          'message': null,
        },
        where: 'id = ?',
        whereArgs: [messageId],
      );
    });
  }

  static Future<void> updateContent({
    required String messageId,
    required String encryptedMessage,
  }) async {
    await _mutex.protect(() async {
      final db = await _db();
      await db.update(
        'self_messages',
        {
          'message': encryptedMessage,
          'editedAt': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [messageId],
      );
    });
  }

  static Future<List<Map<String, dynamic>>> getMessageById(String messageId) async {
    return _mutex.protect(() async {
      final db = await _db();
      return db.query(
        'self_messages',
        where: 'id = ?',
        whereArgs: [messageId],
        limit: 1,
      );
    });
  }

  static Future<void> markViewOnceViewed(String messageId) async {
    await _mutex.protect(() async {
      final db = await _db();
      await db.update(
        'self_messages',
        {'viewed': 1, 'message': null},
        where: 'id = ? AND viewOnce = 1',
        whereArgs: [messageId],
      );
    });
  }
}
