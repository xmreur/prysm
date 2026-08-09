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
    await _protect(() async {
      final db = await _database;
      // The FTS row and its side-table row must land together: a crash or
      // throw between them would leave an orphan FTS row that the
      // missing-side-row fallback in [_deleteRow] can never see.
      await db.transaction((txn) async {
        await _deleteRow(
          txn,
          messageId,
          conversationId: conversationId,
          scope: scope,
        );
        final trimmed = body.trim();
        if (trimmed.isEmpty) return;
        final ftsRowid = await txn.insert('message_search_fts', {
          'messageId': messageId,
          'conversationId': conversationId,
          'scope': scope,
          'timestamp': timestamp,
          'body': trimmed,
        });
        await txn.insert('message_search_rows', {
          'messageId': messageId,
          'conversationId': conversationId,
          'scope': scope,
          'timestamp': timestamp,
          'ftsRowid': ftsRowid,
        });
      });
    });
  }

  Future<void> remove(
    String messageId, {
    required String conversationId,
    required String scope,
  }) =>
      _protect(
        () => removeUnprotected(
          messageId,
          conversationId: conversationId,
          scope: scope,
        ),
      );

  /// Lock-free search-row deletion: the caller must already hold
  /// [MessagesDatabase.mutex] (via [_protect]) before invoking this. Opens
  /// its own transaction, so no caller may invoke this from inside an
  /// already-open one (sqflite rejects nested transactions) — every current
  /// caller runs outside `db.transaction`.
  Future<void> removeUnprotected(
    String messageId, {
    required String conversationId,
    required String scope,
  }) async {
    final db = await _database;
    // The FTS delete and the side-row delete must land together: a crash or
    // throw between them leaves a stale side row pointing at a freed rowid.
    await db.transaction((txn) async {
      await _deleteRow(
        txn,
        messageId,
        conversationId: conversationId,
        scope: scope,
      );
    });
  }

  Future<void> _deleteRow(
    DatabaseExecutor db,
    String messageId, {
    required String conversationId,
    required String scope,
  }) async {
    // The side table carries the FTS rowid, so the delete is a b-tree probe
    // instead of a full scan of the UNINDEXED metadata columns.
    final sideRows = await db.query(
      'message_search_rows',
      columns: const ['ftsRowid'],
      where: 'messageId = ? AND conversationId = ? AND scope = ?',
      whereArgs: [messageId, conversationId, scope],
      limit: 1,
    );
    if (sideRows.isNotEmpty) {
      final ftsRowid = sideRows.first['ftsRowid'] as int;
      // The identity predicate pins the delete to this message: a stale side
      // row (a crash between the FTS delete and the side-row delete, with
      // the freed rowid later reused) must not delete the row that now owns
      // the rowid. rowid = ? keeps it a probe; the extra conditions only
      // filter the probed row.
      final deleted = await db.delete(
        'message_search_fts',
        where:
            'rowid = ? AND messageId = ? AND conversationId = ? AND scope = ?',
        whereArgs: [ftsRowid, messageId, conversationId, scope],
      );
      if (deleted == 0) {
        // Stale side row: the rowid no longer identifies this message. Its
        // own FTS entry is already gone (that is what made the side row
        // stale), but clear any copy by predicate so a deleted message can
        // never stay searchable. Off the hot path.
        await db.delete(
          'message_search_fts',
          where: 'messageId = ? AND conversationId = ? AND scope = ?',
          whereArgs: [messageId, conversationId, scope],
        );
      }
      await db.delete(
        'message_search_rows',
        where: 'messageId = ? AND conversationId = ? AND scope = ?',
        whereArgs: [messageId, conversationId, scope],
      );
      return;
    }
    // Missing side table (e.g. a transient crash between the two writes):
    // fall back to the legacy predicate so a delete never silently leaves an
    // FTS row behind.
    await db.delete(
      'message_search_fts',
      where: 'messageId = ? AND conversationId = ? AND scope = ?',
      whereArgs: [messageId, conversationId, scope],
    );
  }

  /// Lock-free conversation-scoped search-row deletion: the caller must
  /// already hold [MessagesDatabase.mutex] (via [_protect]) before invoking.
  Future<void> removeForConversationUnprotected(
    String conversationId,
    String scope, {
    int? beforeTimestamp,
  }) async {
    final db = await _database;
    // Both deletes must land together: a crash between them would leave side
    // rows pointing at freed FTS rowids, resurrecting the stale-row hazard on
    // the next single-row delete.
    await db.transaction((txn) async {
      final where = beforeTimestamp != null
          ? 'conversationId = ? AND scope = ? AND timestamp < ?'
          : 'conversationId = ? AND scope = ?';
      final whereArgs = beforeTimestamp != null
          ? [conversationId, scope, beforeTimestamp]
          : [conversationId, scope];
      // Both tables share the same columns, so the same predicate keeps them
      // consistent.
      await txn.delete(
          'message_search_fts', where: where, whereArgs: whereArgs);
      await txn.delete(
          'message_search_rows', where: where, whereArgs: whereArgs);
    });
  }

  Future<bool> exists({
    required String messageId,
    required String conversationId,
    required String scope,
  }) async {
    return _protect(() async {
      final db = await _database;
      final rows = await db.query(
        'message_search_rows',
        columns: const ['messageId'],
        where: 'messageId = ? AND conversationId = ? AND scope = ?',
        whereArgs: [messageId, conversationId, scope],
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
