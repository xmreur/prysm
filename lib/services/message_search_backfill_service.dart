import 'package:prysm/database/message_id_codec.dart';
import 'package:prysm/database/message_search_dao.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/conversation.dart';
import 'package:prysm/services/message_search_index_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';

abstract class MessageSearchBackfillStore {
  Future<bool> isSearchBackfillComplete();
  Future<void> setSearchBackfillComplete(bool value);
  Future<String> getSearchBackfillPhase();
  Future<void> setSearchBackfillPhase(String phase);
  Future<int> getSearchBackfillCursorTimestamp();
  Future<String> getSearchBackfillCursorId();
  Future<void> setSearchBackfillCursor({
    required int timestamp,
    required String id,
  });
  Future<int> getSearchBackfillFailureCount(String rowKey);
  Future<void> setSearchBackfillFailureCount(String rowKey, int count);
}

class SettingsMessageSearchBackfillStore implements MessageSearchBackfillStore {
  SettingsMessageSearchBackfillStore(this._settings);

  final SettingsService _settings;

  @override
  Future<bool> isSearchBackfillComplete() => _settings.isSearchBackfillComplete();

  @override
  Future<void> setSearchBackfillComplete(bool value) =>
      _settings.setSearchBackfillComplete(value);

  @override
  Future<String> getSearchBackfillPhase() => _settings.getSearchBackfillPhase();

  @override
  Future<void> setSearchBackfillPhase(String phase) =>
      _settings.setSearchBackfillPhase(phase);

  @override
  Future<int> getSearchBackfillCursorTimestamp() =>
      _settings.getSearchBackfillCursorTimestamp();

  @override
  Future<String> getSearchBackfillCursorId() =>
      _settings.getSearchBackfillCursorId();

  @override
  Future<void> setSearchBackfillCursor({
    required int timestamp,
    required String id,
  }) =>
      _settings.setSearchBackfillCursor(timestamp: timestamp, id: id);

  @override
  Future<int> getSearchBackfillFailureCount(String rowKey) =>
      _settings.getSearchBackfillFailureCount(rowKey);

  @override
  Future<void> setSearchBackfillFailureCount(String rowKey, int count) =>
      _settings.setSearchBackfillFailureCount(rowKey, count);
}

/// Backfills the FTS index for messages stored before search was enabled.
class MessageSearchBackfillService {
  MessageSearchBackfillService({
    required this.keyManager,
    required this.userId,
    MessageSearchDao? searchDao,
    MessageSearchBackfillStore? store,
  })  : _searchDao = searchDao ?? const MessageSearchDao(),
        _settings = store ?? SettingsMessageSearchBackfillStore(SettingsService());

  final KeyManager keyManager;
  final String userId;
  final MessageSearchDao _searchDao;
  final MessageSearchBackfillStore _settings;

  static const _batchSize = 200;

  /// Attempts before an un-indexable row is skipped permanently so backfill
  /// completion is never blocked forever.
  static const _maxRowRetries = 5;

  /// Shared across instances so overlapping startIfNeeded calls observe the
  /// same guard.
  static bool _running = false;

  Future<void> startIfNeeded() async {
    if (_running) return;
    if (await _settings.isSearchBackfillComplete()) return;
    _running = true;
    try {
      await _run();
    } finally {
      _running = false;
    }
  }

  Future<void> _run() async {
    final indexService = MessageSearchIndexService(
      keyManager: keyManager,
      userId: userId,
      dao: _searchDao,
    );

    var phase = await _settings.getSearchBackfillPhase();
    var cursorTs = await _settings.getSearchBackfillCursorTimestamp();
    var cursorId = await _settings.getSearchBackfillCursorId();

    while (phase != 'done') {
      final batch = phase == 'self'
          ? await _fetchSelfBatch(cursorTs, cursorId)
          : await _fetchMessagesBatch(cursorTs, cursorId);
      if (batch.isEmpty) {
        if (phase == 'messages') {
          phase = 'self';
          cursorTs = 0;
          cursorId = '';
          await _settings.setSearchBackfillPhase(phase);
          await _settings.setSearchBackfillCursor(timestamp: 0, id: '');
          continue;
        }
        phase = 'done';
        await _settings.setSearchBackfillPhase(phase);
        await _settings.setSearchBackfillComplete(true);
        return;
      }

      var lastProcessed = <String, dynamic>{};
      for (final row in batch) {
        if (phase == 'self') {
          final messageId = row['id'] as String;
          if (await _searchDao.exists(
            messageId: messageId,
            conversationId: SelfConversation.conversationId,
            scope: 'self',
          )) {
            lastProcessed = row;
            continue;
          }
          final ok = await indexService.indexSelfRow(row);
          if (!ok) {
            final rowKey = row['id'] as String;
            final failures =
                await _settings.getSearchBackfillFailureCount(rowKey) + 1;
            await _settings.setSearchBackfillFailureCount(rowKey, failures);
            if (failures < _maxRowRetries) {
              Logging.error(
                'Search backfill failed for $messageId '
                '($failures/$_maxRowRetries attempts), retrying next run',
                'MessageSearchBackfill',
              );
              if (lastProcessed.isNotEmpty) {
                await _settings.setSearchBackfillCursor(
                  timestamp: lastProcessed['timestamp'] as int,
                  id: lastProcessed['id'] as String,
                );
              }
              return;
            }
            Logging.error(
              'Search backfill permanently skipping un-indexable row '
              '$messageId after $failures attempts',
              'MessageSearchBackfill',
            );
          } else {
            await _settings
                .setSearchBackfillFailureCount(row['id'] as String, 0);
          }
          lastProcessed = row;
          continue;
        }

        final messageId = MessageIdCodec.wireIdFromStorage(row['id'] as String);
        final groupId = row['groupId'] as String?;
        final conversationId = groupId ??
            (row['senderId'] == userId
                ? row['receiverId'] as String
                : row['senderId'] as String);
        final scope = groupId != null ? 'group' : 'direct';
        if (await _searchDao.exists(
          messageId: messageId,
          conversationId: conversationId,
          scope: scope,
        )) {
          lastProcessed = row;
          continue;
        }

        final ok = await indexService.indexInboundRow(row, userId);
        if (!ok) {
          final rowKey = row['id'] as String;
          final failures =
              await _settings.getSearchBackfillFailureCount(rowKey) + 1;
          await _settings.setSearchBackfillFailureCount(rowKey, failures);
          if (failures < _maxRowRetries) {
            Logging.error(
              'Search backfill failed for $messageId '
              '($failures/$_maxRowRetries attempts), retrying next run',
              'MessageSearchBackfill',
            );
            if (lastProcessed.isNotEmpty) {
              await _settings.setSearchBackfillCursor(
                timestamp: lastProcessed['timestamp'] as int,
                id: lastProcessed['id'] as String,
              );
            }
            return;
          }
          Logging.error(
            'Search backfill permanently skipping un-indexable row '
            '$messageId after $failures attempts',
            'MessageSearchBackfill',
          );
        } else {
          await _settings.setSearchBackfillFailureCount(row['id'] as String, 0);
        }
        lastProcessed = row;
      }

      await _settings.setSearchBackfillCursor(
        timestamp: lastProcessed['timestamp'] as int,
        id: lastProcessed['id'] as String,
      );
      cursorTs = lastProcessed['timestamp'] as int;
      cursorId = lastProcessed['id'] as String;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  static const _messageColumns =
      'id, type, timestamp, groupId, senderId, receiverId, message, '
      'fileName, deletedAt, viewOnce, viewed';

  static const _selfColumns =
      'id, type, timestamp, message, fileName, deletedAt, viewOnce, viewed';

  static String _typeInClause(List<String> types) {
    final placeholders = List.filled(types.length, '?').join(', ');
    return 'type IS NULL OR type IN ($placeholders)';
  }

  Future<List<Map<String, dynamic>>> _fetchMessagesBatch(
    int cursorTs,
    String cursorId,
  ) async {
    final db = await MessagesDb.database;
    final rows = await db.rawQuery(
      '''
      SELECT $_messageColumns
      FROM messages
      WHERE deletedAt IS NULL
        AND (viewOnce IS NULL OR viewOnce = 0)
        AND (
          ${_typeInClause([
        ...MessageSearchIndexService.searchableDirectTypes,
        ...MessageSearchIndexService.searchableGroupTypes,
      ])}
        )
        AND (
          timestamp > ?
          OR (timestamp = ? AND id > ?)
        )
      ORDER BY timestamp ASC, id ASC
      LIMIT ?
      ''',
      [
        ...MessageSearchIndexService.searchableDirectTypes,
        ...MessageSearchIndexService.searchableGroupTypes,
        cursorTs,
        cursorTs,
        cursorId,
        _batchSize,
      ],
    );
    return rows;
  }

  Future<List<Map<String, dynamic>>> _fetchSelfBatch(
    int cursorTs,
    String cursorId,
  ) async {
    final db = await MessagesDb.database;
    final rows = await db.rawQuery(
      '''
      SELECT $_selfColumns
      FROM self_messages
      WHERE deletedAt IS NULL
        AND (viewOnce IS NULL OR viewOnce = 0)
        AND (
          ${_typeInClause(MessageSearchIndexService.searchableDirectTypes)}
        )
        AND (
          timestamp > ?
          OR (timestamp = ? AND id > ?)
        )
      ORDER BY timestamp ASC, id ASC
      LIMIT ?
      ''',
      [
        ...MessageSearchIndexService.searchableDirectTypes,
        cursorTs,
        cursorTs,
        cursorId,
        _batchSize,
      ],
    );
    return rows;
  }
}
