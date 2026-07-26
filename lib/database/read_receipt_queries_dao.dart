import 'package:prysm/database/message_id_codec.dart';
import 'package:prysm/database/message_query_filters.dart';
import 'package:prysm/database/messages_database.dart';
import 'package:prysm/util/read_waterline_mark.dart';
import 'package:sqflite/sqflite.dart';

/// Read waterline: marking inbound messages read, stamping outbound
/// timestamps, and the pending-outbound queue used by delivery/read
/// reconciliation.
class ReadReceiptQueriesDao {
  const ReadReceiptQueriesDao();

  Future<Database> get _database => MessagesDatabase.database;

  Future<T> _protect<T>(Future<T> Function() action) =>
      MessagesDatabase.mutex.protect(action);

  Future<void> setAsRead(String id, {String? groupId}) async {
    await _protect(() async {
      final db = await _database;
      final storageId = MessageIdCodec.scopedId(wireId: id, groupId: groupId);
      await db.update(
        'messages',
        {'readAt': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [storageId],
      );
    });
  }

  /// Mark inbound direct messages as read locally. Returns waterline if any marked.
  Future<ReadWaterlineMark?> markInboundConversationRead(
    String localUserId,
    String peerId,
  ) async {
    return await _protect(() async {
      final db = await _database;
      final now = DateTime.now().millisecondsSinceEpoch;
      final rows = await db.query(
        'messages',
        columns: ['id', 'timestamp'],
        where:
            'groupId IS NULL AND senderId = ? AND receiverId = ? AND status = ? AND readAt IS NULL',
        whereArgs: [peerId, localUserId, 'received'],
      );
      if (rows.isEmpty) return null;

      var readUpTo = 0;
      Map<String, dynamic>? latestRow;
      for (final row in rows) {
        final ts = row['timestamp'] as int? ?? 0;
        if (ts >= readUpTo) {
          readUpTo = ts;
          latestRow = row;
        }
      }

      await db.update(
        'messages',
        {'readAt': now},
        where:
            'groupId IS NULL AND senderId = ? AND receiverId = ? AND status = ? AND readAt IS NULL',
        whereArgs: [peerId, localUserId, 'received'],
      );

      return ReadWaterlineMark(
        latestMessageId: MessageIdCodec.wireIdFromStorage(latestRow!['id'] as String),
        readUpToTimestamp: readUpTo,
      );
    });
  }

  /// Mark inbound group messages as read locally. Returns waterline if any marked.
  Future<ReadWaterlineMark?> markInboundGroupRead(
    String localUserId,
    String groupId,
  ) async {
    return await _protect(() async {
      final db = await _database;
      final now = DateTime.now().millisecondsSinceEpoch;
      final rows = await db.query(
        'messages',
        columns: ['id', 'timestamp'],
        where:
            'groupId = ? AND senderId != ? AND status = ? AND readAt IS NULL',
        whereArgs: [groupId, localUserId, 'received'],
      );
      if (rows.isEmpty) return null;

      var readUpTo = 0;
      Map<String, dynamic>? latestRow;
      for (final row in rows) {
        final ts = row['timestamp'] as int? ?? 0;
        if (ts >= readUpTo) {
          readUpTo = ts;
          latestRow = row;
        }
      }

      await db.update(
        'messages',
        {'readAt': now},
        where:
            'groupId = ? AND senderId != ? AND status = ? AND readAt IS NULL',
        whereArgs: [groupId, localUserId, 'received'],
      );

      return ReadWaterlineMark(
        latestMessageId: MessageIdCodec.wireIdFromStorage(latestRow!['id'] as String),
        readUpToTimestamp: readUpTo,
        groupId: groupId,
      );
    });
  }

  /// Outbound direct messages from [senderId] to [receiverId] up to [readUpToTimestamp].
  Future<List<Map<String, dynamic>>> getOutboundDirectUpToTimestamp({
    required String senderId,
    required String receiverId,
    required int readUpToTimestamp,
  }) async {
    return _protect(() async {
      final db = await _database;
      return db.query(
        'messages',
        columns: ['id', 'timestamp'],
        where:
            'groupId IS NULL AND senderId = ? AND receiverId = ? AND timestamp <= ?',
        whereArgs: [senderId, receiverId, readUpToTimestamp],
        orderBy: 'timestamp ASC',
      );
    });
  }

  /// Outbound group messages from [senderId] in [groupId] up to [readUpToTimestamp].
  Future<List<Map<String, dynamic>>> getOutboundGroupUpToTimestamp({
    required String senderId,
    required String groupId,
    required int readUpToTimestamp,
  }) async {
    return _protect(() async {
      final db = await _database;
      return db.query(
        'messages',
        columns: ['id', 'timestamp'],
        where: 'groupId = ? AND senderId = ? AND timestamp <= ?',
        whereArgs: [groupId, senderId, readUpToTimestamp],
        orderBy: 'timestamp ASC',
      );
    });
  }

  /// Outbound direct chat rows still marked pending in the messages table.
  Future<List<Map<String, dynamic>>> getPendingOutboundDirectMessages({
    required String senderId,
    required String receiverId,
  }) async {
    return _protect(() async {
      final db = await _database;
      return db.query(
        'messages',
        where:
            'groupId IS NULL AND senderId = ? AND receiverId = ? '
            "AND status = 'pending' AND deletedAt IS NULL AND "
            '${MessageQueryFilters.directChatTypeFilter}',
        whereArgs: [senderId, receiverId],
        orderBy: 'timestamp ASC',
      );
    });
  }
}
