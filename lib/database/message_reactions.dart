import 'package:mutex/mutex.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/util/reaction_payload.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter/foundation.dart';

/// Local persistence for message emoji reactions.
class MessageReactionsDb {
  MessageReactionsDb._();

  static final _mutex = Mutex();

  /// Override for unit tests (in-memory SQLite).
  @visibleForTesting
  static Database? debugDatabase;

  static Future<Database> _database() async {
    if (debugDatabase != null) return debugDatabase!;
    return MessagesDb.database;
  }

  static Future<void> createTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS message_reactions(
        targetMessageId TEXT NOT NULL,
        reactorId TEXT NOT NULL,
        emoji TEXT NOT NULL,
        groupId TEXT,
        timestamp INTEGER NOT NULL,
        PRIMARY KEY (targetMessageId, reactorId)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_reactions_target ON message_reactions(targetMessageId)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_reactions_group ON message_reactions(groupId, targetMessageId)',
    );
  }

  static Future<void> upsertReaction({
    required String targetMessageId,
    required String reactorId,
    required String emoji,
    String? groupId,
    required int timestamp,
  }) async {
    await _mutex.protect(() async {
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
    await _mutex.protect(() async {
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
    return _mutex.protect(() async {
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

    return _mutex.protect(() async {
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
    await _mutex.protect(() async {
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
