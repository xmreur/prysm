import 'package:prysm/database/message_query_filters.dart';
import 'package:prysm/database/message_search_dao.dart';
import 'package:prysm/database/messages_database.dart';
import 'package:sqflite/sqflite.dart';

/// Direct/group conversation message queries (batched + paginated reads) and
/// their bulk deletes.
class ConversationQueriesDao {
  const ConversationQueriesDao({MessageSearchDao? searchDao})
      : _searchDao = searchDao ?? const MessageSearchDao();

  final MessageSearchDao _searchDao;

  Future<Database> get _database => MessagesDatabase.database;

  Future<T> _protect<T>(Future<T> Function() action) =>
      MessagesDatabase.mutex.protect(action);

  /// Query messages between two users, newest first
  Future<List<Map<String, dynamic>>> getMessagesBetween(
    String userId,
    String receiverId,
  ) async {
    return await _protect(() async {
      final db = await _database;
      return await db.query(
        'messages',
        columns: MessageQueryFilters.messageListColumns,
        where:
            'groupId IS NULL AND ${MessageQueryFilters.directChatTypeFilter} AND ${MessageQueryFilters.directConversationFilter}',
        whereArgs: [userId, receiverId, receiverId, userId, userId, receiverId, receiverId, userId],
        orderBy: 'timestamp DESC',
      );
    });
  }

  /// Get a batch of messages with optional pagination by timestamp
  Future<List<Map<String, dynamic>>> getMessagesBetweenBatch(
    String userId,
    String receiverId, {
    int limit = 20,
    int? beforeTimestamp,
  }) async {
    return await _protect(() async {
      final db = await _database;
      String where =
          'groupId IS NULL AND ${MessageQueryFilters.directChatTypeFilter} AND ${MessageQueryFilters.directConversationFilter}';
      List<dynamic> whereArgs = [userId, receiverId, receiverId, userId, userId, receiverId, receiverId, userId];

      if (beforeTimestamp != null) {
        where += ' AND timestamp < ?';
        whereArgs.add(beforeTimestamp);
      }

      return await db.query(
        'messages',
        columns: MessageQueryFilters.messageListColumns,
        where: where,
        whereArgs: whereArgs,
        orderBy: 'timestamp DESC',
        limit: limit,
      );
    });
  }

  /// Get a batch of messages with pagination by timestamp and message ID for stable ordering
  Future<List<Map<String, dynamic>>> getMessagesBetweenBatchWithId(
    String userId,
    String receiverId, {
    int limit = 20,
    int? beforeTimestamp,
    String? beforeId,
  }) async {
    return await _protect(() async {
      final db = await _database;

      String where =
          'groupId IS NULL AND ${MessageQueryFilters.directChatTypeFilter} AND ${MessageQueryFilters.directConversationFilter}';
      List<dynamic> whereArgs = [userId, receiverId, receiverId, userId, userId, receiverId, receiverId, userId];

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

      return await db.query(
        'messages',
        columns: MessageQueryFilters.messageListColumns,
        where: where,
        whereArgs: whereArgs,
        orderBy: 'timestamp DESC, id DESC',
        limit: limit,
      );
    });
  }

  /// Delete all messages between two users
  Future<void> deleteMessagesBetween(
    String userId,
    String receiverId,
  ) async {
    await _protect(() async {
      final db = await _database;
      await db.delete(
        'messages',
        where:
            "groupId IS NULL AND ${MessageQueryFilters.directChatTypeFilter} AND ((senderId = ? AND receiverId = ?) OR (senderId = ? AND receiverId = ?) OR (senderId = ? AND receiverId = ? AND status = 'system') OR (senderId = ? AND receiverId = ? AND status = 'system'))",
        whereArgs: [userId, receiverId, receiverId, userId, userId, receiverId, receiverId, userId],
      );
      await _searchDao.removeForConversationUnprotected(userId, 'direct');
      await _searchDao.removeForConversationUnprotected(receiverId, 'direct');
    });
  }

  /// Get messages for a group, newest first (dedupe by id in caller)
  Future<List<Map<String, dynamic>>> getMessagesForGroupBatch(
    String groupId, {
    int limit = 20,
    int? beforeTimestamp,
    String? beforeId,
    int? afterTimestamp,
  }) async {
    return await _protect(() async {
      final db = await _database;
      String where = 'groupId = ?';
      final whereArgs = <dynamic>[groupId];

      if (afterTimestamp != null) {
        where += ' AND timestamp >= ?';
        whereArgs.add(afterTimestamp);
      }

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
        'messages',
        where: where,
        whereArgs: whereArgs,
        orderBy: 'timestamp DESC, id DESC',
        limit: limit,
      );
    });
  }

  Future<void> deleteMessagesForGroup(String groupId) async {
    await _protect(() async {
      final db = await _database;
      await db.delete('messages', where: 'groupId = ?', whereArgs: [groupId]);
      await _searchDao.removeForConversationUnprotected(groupId, 'group');
    });
  }

  Future<void> deleteGroupMessagesBefore(
    String groupId,
    int beforeTimestamp,
  ) async {
    await _protect(() async {
      final db = await _database;
      await db.delete(
        'messages',
        where: 'groupId = ? AND timestamp < ?',
        whereArgs: [groupId, beforeTimestamp],
      );
      await _searchDao.removeForConversationUnprotected(
        groupId,
        'group',
        beforeTimestamp: beforeTimestamp,
      );
    });
  }
}
