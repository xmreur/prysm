import 'package:flutter/foundation.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages_database.dart';
import 'package:sqflite/sqflite.dart';

class PinnedMessageRow {
  const PinnedMessageRow({
    required this.messageId,
    required this.pinnedAt,
    required this.timestamp,
    required this.type,
    this.fileName,
    this.ciphertext,
  });

  final String messageId;
  final int pinnedAt;
  final int timestamp;
  final String type;
  final String? fileName;
  final String? ciphertext;
}

/// Local-only pins. [messageId] is the wire id.
class PinnedMessagesDb {
  PinnedMessagesDb._();

  static const scopeDirect = 'direct';
  static const scopeGroup = 'group';
  static const scopeSelf = 'self';

  @visibleForTesting
  static Database? debugDatabase;

  static Future<Database> _database() async {
    if (debugDatabase != null) return debugDatabase!;
    return MessagesDatabase.database;
  }

  static Future<void> createTable(Database db) =>
      MessageSchemaMigrations.createPinnedMessagesTable(db);

  static Future<void> pin({
    required String messageId,
    required String conversationId,
    required String scope,
    int? pinnedAt,
  }) async {
    await MessagesDatabase.mutex.protect(() async {
      final db = await _database();
      await db.insert(
        'pinned_messages',
        {
          'messageId': messageId,
          'conversationId': conversationId,
          'scope': scope,
          'pinnedAt': pinnedAt ?? DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  static Future<void> unpin({
    required String messageId,
    required String conversationId,
    required String scope,
  }) async {
    await MessagesDatabase.mutex.protect(() async {
      final db = await _database();
      await db.delete(
        'pinned_messages',
        where: 'messageId = ? AND conversationId = ? AND scope = ?',
        whereArgs: [messageId, conversationId, scope],
      );
    });
  }

  /// Caller must hold [MessagesDatabase.mutex].
  static Future<void> deleteForMessageUnprotected({
    required String messageId,
    required String conversationId,
    required String scope,
  }) async {
    try {
      final db = await _database();
      await db.delete(
        'pinned_messages',
        where: 'messageId = ? AND conversationId = ? AND scope = ?',
        whereArgs: [messageId, conversationId, scope],
      );
    } on DatabaseException catch (e) {
      // ponytail: hand-rolled test DBs often omit this table; message
      // delete still has to run.
      if (!e.toString().contains('no such table')) rethrow;
    }
  }

  static Future<void> deleteForMessage({
    required String messageId,
    required String conversationId,
    required String scope,
  }) {
    return MessagesDatabase.mutex.protect(
      () => deleteForMessageUnprotected(
        messageId: messageId,
        conversationId: conversationId,
        scope: scope,
      ),
    );
  }

  static Future<Set<String>> pinnedIds({
    required String conversationId,
    required String scope,
  }) async {
    return MessagesDatabase.mutex.protect(() async {
      final db = await _database();
      final rows = await db.query(
        'pinned_messages',
        columns: ['messageId'],
        where: 'conversationId = ? AND scope = ?',
        whereArgs: [conversationId, scope],
      );
      return rows.map((r) => r['messageId'] as String).toSet();
    });
  }

  static Future<bool> isPinned({
    required String messageId,
    required String conversationId,
    required String scope,
  }) async {
    return MessagesDatabase.mutex.protect(() async {
      final db = await _database();
      final rows = await db.query(
        'pinned_messages',
        columns: ['messageId'],
        where: 'messageId = ? AND conversationId = ? AND scope = ?',
        whereArgs: [messageId, conversationId, scope],
        limit: 1,
      );
      return rows.isNotEmpty;
    });
  }

  static Future<List<PinnedMessageRow>> listPinned({
    required String conversationId,
    required String scope,
  }) async {
    return MessagesDatabase.mutex.protect(() async {
      final db = await _database();
      final rows = switch (scope) {
        scopeGroup => await db.rawQuery(
          '''
          SELECT p.messageId, p.pinnedAt, m.timestamp, m.type, m.fileName, m.message
          FROM pinned_messages p
          INNER JOIN messages m
            ON m.id = ? || '::' || p.messageId
          WHERE p.conversationId = ? AND p.scope = ?
            AND m.deletedAt IS NULL
            AND m.message IS NOT NULL
          ORDER BY p.pinnedAt DESC
          ''',
          [conversationId, conversationId, scope],
        ),
        scopeSelf => await db.rawQuery(
          '''
          SELECT p.messageId, p.pinnedAt, s.timestamp, s.type, s.fileName, s.message
          FROM pinned_messages p
          INNER JOIN self_messages s ON s.id = p.messageId
          WHERE p.conversationId = ? AND p.scope = ?
            AND s.deletedAt IS NULL
            AND s.message IS NOT NULL
          ORDER BY p.pinnedAt DESC
          ''',
          [conversationId, scope],
        ),
        _ => await db.rawQuery(
          '''
          SELECT p.messageId, p.pinnedAt, m.timestamp, m.type, m.fileName, m.message
          FROM pinned_messages p
          INNER JOIN messages m ON m.id = p.messageId
          WHERE p.conversationId = ? AND p.scope = ?
            AND m.deletedAt IS NULL
            AND m.message IS NOT NULL
          ORDER BY p.pinnedAt DESC
          ''',
          [conversationId, scope],
        ),
      };
      return [
        for (final row in rows)
          PinnedMessageRow(
            messageId: row['messageId'] as String,
            pinnedAt: row['pinnedAt'] as int,
            timestamp: row['timestamp'] as int,
            type: row['type'] as String? ?? 'text',
            fileName: row['fileName'] as String?,
            ciphertext: row['message'] as String?,
          ),
      ];
    });
  }
}