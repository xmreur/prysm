import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/message_id_codec.dart';
import 'package:prysm/database/message_search_dao.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/message_search_index_service.dart';
import 'package:prysm/services/settings_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/logging.dart';
import 'package:sqflite/sqflite.dart';

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
  bool _running = false;

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
        await _settings.setSearchBackfillComplete(true);
        return;
      }

      for (final row in batch) {
        final messageId = phase == 'self'
            ? row['id'] as String
            : MessageIdCodec.wireIdFromStorage(row['id'] as String);
        if (await _searchDao.exists(messageId)) continue;

        try {
          if (phase == 'self') {
            await indexService.indexSelfRow(row);
          } else {
            await indexService.indexInboundRow(row, userId);
          }
        } catch (e) {
          Logging.error(
            'Search backfill failed for $messageId: $e',
            'MessageSearchBackfill',
          );
        }
      }

      final last = batch.last;
      cursorTs = last['timestamp'] as int;
      cursorId = last['id'] as String;
      await _settings.setSearchBackfillCursor(
        timestamp: cursorTs,
        id: cursorId,
      );
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  Future<List<Map<String, dynamic>>> _fetchMessagesBatch(
    int cursorTs,
    String cursorId,
  ) async {
    final db = await MessagesDb.database;
    return db.rawQuery(
      '''
      SELECT *
      FROM messages
      WHERE deletedAt IS NULL
        AND (viewOnce IS NULL OR viewOnce = 0 OR viewed IS NULL OR viewed = 0)
        AND (
          type IS NULL
          OR type IN ('text', 'file', 'image', 'audio', ?, ?, ?, ?)
        )
        AND (
          timestamp > ?
          OR (timestamp = ? AND id > ?)
        )
      ORDER BY timestamp ASC, id ASC
      LIMIT ?
      ''',
      [
        groupTextType,
        groupImageType,
        groupFileType,
        groupAudioType,
        cursorTs,
        cursorTs,
        cursorId,
        _batchSize,
      ],
    );
  }

  Future<List<Map<String, dynamic>>> _fetchSelfBatch(
    int cursorTs,
    String cursorId,
  ) async {
    final db = await MessagesDb.database;
    return db.rawQuery(
      '''
      SELECT *
      FROM self_messages
      WHERE deletedAt IS NULL
        AND (viewOnce IS NULL OR viewOnce = 0 OR viewed IS NULL OR viewed = 0)
        AND (type IS NULL OR type IN ('text', 'file', 'image', 'audio'))
        AND (
          timestamp > ?
          OR (timestamp = ? AND id > ?)
        )
      ORDER BY timestamp ASC, id ASC
      LIMIT ?
      ''',
      [cursorTs, cursorTs, cursorId, _batchSize],
    );
  }
}
