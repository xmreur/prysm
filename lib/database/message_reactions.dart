import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/database/messages_database.dart';
import 'package:prysm/util/reaction_payload.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter/foundation.dart';

/// Local persistence for message emoji reactions.
class MessageReactionsDb {
  MessageReactionsDb._();

  /// Override for unit tests (in-memory SQLite).
  @visibleForTesting
  static Database? debugDatabase;

  static Future<Database> _database() async {
    if (debugDatabase != null) return debugDatabase!;
    return MessagesDb.database;
  }

  static Future<void> createTable(Database db) =>
      MessageSchemaMigrations.createReactionsTable(db);

  static Future<void> upsertReaction({
    required String targetMessageId,
    required String reactorId,
    required String emoji,
    String? groupId,
    required int timestamp,
  }) async {
    await MessagesDatabase.mutex.protect(() async {
      final db = await _database();
      await db.insert(
        'message_reactions',
        {
          'targetMessageId': targetMessageId,
          'reactorId': reactorId,
          'emoji': emoji,
          'groupId': groupId,
          'timestamp': timestamp,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  static Future<void> removeReaction({
    required String targetMessageId,
    required String reactorId,
  }) async {
    await MessagesDatabase.mutex.protect(() async {
      final db = await _database();
      await db.delete(
        'message_reactions',
        where: 'targetMessageId = ? AND reactorId = ?',
        whereArgs: [targetMessageId, reactorId],
      );
    });
  }

  static Future<String?> getReactionEmoji({
    required String targetMessageId,
    required String reactorId,
  }) async {
    return MessagesDatabase.mutex.protect(() async {
      final db = await _database();
      final rows = await db.query(
        'message_reactions',
        columns: ['emoji'],
        where: 'targetMessageId = ? AND reactorId = ?',
        whereArgs: [targetMessageId, reactorId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return rows.first['emoji'] as String?;
    });
  }

  /// Returns reactions keyed by wire message id.
  static Future<Map<String, Map<String, List<String>>>> getReactionsForMessages(
    List<String> wireIds, {
    String? groupId,
  }) async {
    if (wireIds.isEmpty) return {};

    final storageToWire = <String, String>{
      for (final wireId in wireIds)
        MessagesDb.scopedId(wireId: wireId, groupId: groupId): wireId,
    };

    return MessagesDatabase.mutex.protect(() async {
      final db = await _database();
      final placeholders = List.filled(storageToWire.length, '?').join(',');
      final rows = await db.query(
        'message_reactions',
        where: 'targetMessageId IN ($placeholders)',
        whereArgs: storageToWire.keys.toList(),
      );

      final byStorage = <String, List<Map<String, dynamic>>>{};
      for (final row in rows) {
        final target = row['targetMessageId'] as String;
        byStorage.putIfAbsent(target, () => []).add(row);
      }

      final result = <String, Map<String, List<String>>>{};
      for (final entry in storageToWire.entries) {
        final aggregated = aggregateReactions(byStorage[entry.key] ?? const []);
        if (aggregated.isNotEmpty) {
          result[entry.value] = aggregated;
        }
      }
      return result;
    });
  }

  static Future<void> deleteReactionsForMessage(String targetMessageId) async {
    await MessagesDatabase.mutex.protect(() async {
      final db = await _database();
      await db.delete(
        'message_reactions',
        where: 'targetMessageId = ?',
        whereArgs: [targetMessageId],
      );
    });
  }

  static Future<void> deleteReactionsForMessages(
    Iterable<String> wireIds, {
    String? groupId,
  }) async {
    for (final wireId in wireIds) {
      await deleteReactionsForMessage(
        MessagesDb.scopedId(wireId: wireId, groupId: groupId),
      );
    }
  }
}
