import 'package:prysm/database/messages_database.dart';
import 'package:prysm/models/message_search_hit.dart';
import 'package:sqflite/sqflite.dart';

/// FTS5-backed local message search index.
class MessageSearchDao {
  const MessageSearchDao();

  Future<Database> get _database => MessagesDatabase.database;

  Future<T> _protect<T>(Future<T> Function() action) =>
      MessagesDatabase.mutex.protect(action);

  /// Escapes user input and builds a prefix FTS5 query.
  static String escapeFtsQuery(String userInput) {
    final tokens = userInput
        .trim()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .map(_escapeFtsToken)
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return '';
    return tokens.map((t) => '$t*').join(' OR ');
  }

  static String _escapeFtsToken(String token) {
    final cleaned = token.replaceAll(RegExp(r'["*():^]'), ' ').trim();
    if (cleaned.isEmpty) return '';
    return '"$cleaned"';
  }

  Future<void> upsert({
    required String messageId,
    required String conversationId,
    required String scope,
    required int timestamp,
    required String body,
  }) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return;

    await _protect(() async {
      final db = await _database;
      await db.delete(
        'message_search_fts',
        where: 'messageId = ?',
        whereArgs: [messageId],
      );
      await db.insert('message_search_fts', {
        'messageId': messageId,
        'conversationId': conversationId,
        'scope': scope,
        'timestamp': timestamp,
        'body': trimmed,
      });
    });
  }

  Future<void> remove(String messageId) async {
    await _protect(() async {
      final db = await _database;
      await db.delete(
        'message_search_fts',
        where: 'messageId = ?',
        whereArgs: [messageId],
      );
    });
  }

  Future<bool> exists(String messageId) async {
    return _protect(() async {
      final db = await _database;
      final rows = await db.query(
        'message_search_fts',
        columns: const ['messageId'],
        where: 'messageId = ?',
        whereArgs: [messageId],
        limit: 1,
      );
      return rows.isNotEmpty;
    });
  }

  Future<List<MessageSearchHit>> searchGlobal(
    String query, {
    int limit = 30,
  }) async {
    final ftsQuery = escapeFtsQuery(query);
    if (ftsQuery.isEmpty) return const [];

    return _protect(() async {
      final db = await _database;
      final rows = await db.rawQuery(
        '''
        SELECT messageId, conversationId, scope, timestamp, body
        FROM message_search_fts
        WHERE message_search_fts MATCH ?
        ORDER BY timestamp DESC
        LIMIT ?
        ''',
        [ftsQuery, limit],
      );
      return rows.map(_rowToHit).toList();
    });
  }

  Future<List<MessageSearchHit>> searchInConversation(
    String conversationId,
    String query, {
    int limit = 50,
  }) async {
    final ftsQuery = escapeFtsQuery(query);
    if (ftsQuery.isEmpty) return const [];

    return _protect(() async {
      final db = await _database;
      final rows = await db.rawQuery(
        '''
        SELECT messageId, conversationId, scope, timestamp, body
        FROM message_search_fts
        WHERE conversationId = ? AND message_search_fts MATCH ?
        ORDER BY timestamp ASC
        LIMIT ?
        ''',
        [conversationId, ftsQuery, limit],
      );
      return rows.map(_rowToHit).toList();
    });
  }

  MessageSearchHit _rowToHit(Map<String, Object?> row) => MessageSearchHit(
        messageId: row['messageId'] as String,
        conversationId: row['conversationId'] as String,
        scope: row['scope'] as String,
        timestamp: row['timestamp'] as int,
        body: row['body'] as String,
      );
}
