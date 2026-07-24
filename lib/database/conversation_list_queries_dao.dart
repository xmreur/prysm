import 'package:prysm/database/message_query_filters.dart';
import 'package:prysm/database/messages_database.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/message_preview_label.dart';
import 'package:sqflite/sqflite.dart';

/// Conversation-list aggregates (last-message previews, unread counts,
/// last-message timestamps) used by the chat sidebar.
///
/// Depends on group membership data owned by DBHelper (a different DB) to
/// gate group previews/counts to messages sent after the local user joined;
/// that cross-DB dependency is taken as an explicit ctor param defaulting to
/// the real DBHelper call, so it isn't a hidden static import.
class ConversationListQueriesDao {
  ConversationListQueriesDao({
    Future<Map<String, int>> Function(String memberId)? getGroupJoinedAtByMember,
  }) : _getGroupJoinedAtByMember =
            getGroupJoinedAtByMember ?? DBHelper.getGroupJoinedAtByMember;

  final Future<Map<String, int>> Function(String memberId) _getGroupJoinedAtByMember;

  Future<Database> get _database => MessagesDatabase.database;

  Future<T> _protect<T>(Future<T> Function() action) =>
      MessagesDatabase.mutex.protect(action);

  /// Latest message preview label per conversation id (peer onion or group id).
  Future<Map<String, String>> getLastMessagePreviews(
    String localUserId,
  ) async {
    return await _protect(() async {
      final db = await _database;
      final previews = <String, String>{};
      final groupJoinedAt = await _getGroupJoinedAtByMember(localUserId);

      final groupMessages = await db.query(
        'messages',
        columns: ['groupId', 'type', 'deletedAt', 'timestamp'],
        where: 'groupId IS NOT NULL',
        orderBy: 'timestamp DESC',
      );
      final latestByGroup = <String, Map<String, dynamic>>{};
      for (final row in groupMessages) {
        final groupId = row['groupId'] as String?;
        if (groupId == null || groupId.isEmpty) continue;
        final joinedAt = groupJoinedAt[groupId];
        if (joinedAt == null) continue;
        final ts = row['timestamp'] as int? ?? 0;
        if (ts < joinedAt) continue;
        if (!latestByGroup.containsKey(groupId)) {
          latestByGroup[groupId] = row;
        }
      }
      for (final entry in latestByGroup.entries) {
        previews[entry.key] = previewLabelForType(
          entry.value['type'] as String?,
          deleted: entry.value['deletedAt'] != null,
        );
      }

      // SQLite guarantees that bare columns in a MAX-aggregate query come
      // from the row that produced the MAX value — no self-join needed.
      final directRows = await db.rawQuery(
        '''
				SELECT
				  CASE WHEN senderId = ? THEN receiverId ELSE senderId END AS convKey,
				  type,
				  deletedAt,
				  MAX(timestamp) AS max_ts
				FROM messages
				WHERE groupId IS NULL
				  AND ${MessageQueryFilters.directChatTypeFilter}
				  AND (senderId = ? OR receiverId = ?)
				GROUP BY convKey
			''',
        [localUserId, localUserId, localUserId],
      );

      for (final row in directRows) {
        final key = row['convKey'] as String?;
        if (key != null && key.isNotEmpty) {
          previews[key] = previewLabelForType(
            row['type'] as String?,
            deleted: row['deletedAt'] != null,
          );
        }
      }
      return previews;
    });
  }

  /// Unread inbound message counts per conversation id.
  Future<Map<String, int>> getUnreadCounts(String localUserId) async {
    return await _protect(() async {
      final db = await _database;
      final counts = <String, int>{};
      final groupJoinedAt = await _getGroupJoinedAtByMember(localUserId);

      final directRows = await db.rawQuery(
        '''
				SELECT senderId AS convKey, COUNT(*) AS cnt
				FROM messages
				WHERE groupId IS NULL
				  AND senderId != ?
				  AND status = 'received'
				  AND readAt IS NULL
				GROUP BY senderId
			''',
        [localUserId],
      );
      for (final row in directRows) {
        final key = row['convKey'] as String?;
        if (key == null || key.isEmpty) continue;
        counts[key] = row['cnt'] is int
            ? row['cnt'] as int
            : int.tryParse(row['cnt'].toString()) ?? 0;
      }

      final groupRows = await db.query(
        'messages',
        columns: ['groupId', 'timestamp'],
        where:
            'groupId IS NOT NULL AND senderId != ? AND status = ? AND readAt IS NULL',
        whereArgs: [localUserId, 'received'],
      );
      for (final row in groupRows) {
        final groupId = row['groupId'] as String?;
        if (groupId == null || groupId.isEmpty) continue;
        final joinedAt = groupJoinedAt[groupId];
        if (joinedAt == null) continue;
        final ts = row['timestamp'] as int? ?? 0;
        if (ts < joinedAt) continue;
        counts[groupId] = (counts[groupId] ?? 0) + 1;
      }
      return counts;
    });
  }

  /// Get the last message timestamp for a user
  Future<int?> getLastMessageTimestampForUser(String userId) async {
    return await _protect(() async {
      final db = await _database;
      final result = await db.rawQuery(
        '''
					SELECT MAX(timestamp) as lastTimestamp
					FROM messages
					WHERE groupId IS NULL
					  AND (senderId = ? OR receiverId = ?)
				''',
        [userId, userId],
      );

      if (result.isNotEmpty && result.first['lastTimestamp'] != null) {
        final value = result.first['lastTimestamp'];
        return value is int ? value : int.tryParse(value.toString());
      }
      return null;
    });
  }

  /// Get the last message timestamps for all users in a single query
  Future<Map<String, int>> getLastMessageTimestampsForAllUsers() async {
    return await _protect(() async {
      final db = await _database;
      final result = await db.rawQuery('''
				SELECT userId, MAX(ts) as lastTimestamp FROM (
					SELECT senderId AS userId, MAX(timestamp) AS ts
					FROM messages WHERE groupId IS NULL GROUP BY senderId
					UNION ALL
					SELECT receiverId AS userId, MAX(timestamp) AS ts
					FROM messages WHERE groupId IS NULL GROUP BY receiverId
				) GROUP BY userId
			''');

      final Map<String, int> timestamps = {};
      for (final row in result) {
        final userId = row['userId'] as String?;
        final ts = row['lastTimestamp'];
        if (userId != null && ts != null) {
          timestamps[userId] = ts is int
              ? ts
              : int.tryParse(ts.toString()) ?? 0;
        }
      }
      return timestamps;
    });
  }

  /// Last message timestamp per group (only messages after member joined).
  Future<Map<String, int>> getLastMessageTimestampsForAllGroups(
    String localUserId,
  ) async {
    return await _protect(() async {
      final db = await _database;
      final groupJoinedAt = await _getGroupJoinedAtByMember(localUserId);
      final result = await db.rawQuery('''
				SELECT groupId, MAX(timestamp) as lastTimestamp
				FROM messages
				WHERE groupId IS NOT NULL
				GROUP BY groupId
			''');

      final Map<String, int> timestamps = {};
      for (final row in result) {
        final groupId = row['groupId'] as String?;
        final ts = row['lastTimestamp'];
        if (groupId == null || ts == null) continue;
        final joinedAt = groupJoinedAt[groupId];
        if (joinedAt == null) continue;
        final tsInt = ts is int ? ts : int.tryParse(ts.toString()) ?? 0;
        if (tsInt >= joinedAt) {
          timestamps[groupId] = tsInt;
        }
      }
      return timestamps;
    });
  }
}
