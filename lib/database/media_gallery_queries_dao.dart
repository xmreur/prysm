import 'package:prysm/database/message_query_filters.dart';
import 'package:prysm/database/messages_database.dart';
import 'package:sqflite/sqflite.dart';

/// Media gallery queries: paginated media messages for a direct chat or a
/// group chat.
class MediaGalleryQueriesDao {
  const MediaGalleryQueriesDao();

  Future<Database> get _database => MessagesDatabase.database;

  Future<T> _protect<T>(Future<T> Function() action) =>
      MessagesDatabase.mutex.protect(action);

  static const String _directMediaTypeFilter =
      "type IN ('image', 'file', 'audio')";

  static const String _groupMediaTypeFilter =
      "type IN ('group_image', 'group_file', 'group_audio')";

  static const String _allMediaTypeFilter =
      "type IN ('image', 'file', 'audio', 'group_image', 'group_file', 'group_audio')";

  static const String _mediaContentFilter =
      "deletedAt IS NULL AND message IS NOT NULL AND message != ''";

  /// Media messages in a direct chat, newest first.
  Future<List<Map<String, dynamic>>> getMediaMessagesForDirect(
    String userId,
    String peerId, {
    String? typeFilter,
    int limit = 50,
    int? beforeTimestamp,
  }) async {
    return await _protect(() async {
      final db = await _database;
      var where =
          'groupId IS NULL AND $_directMediaTypeFilter AND $_mediaContentFilter AND ${MessageQueryFilters.directConversationFilter}';
      final whereArgs = <dynamic>[userId, peerId, peerId, userId, userId, peerId, peerId, userId];

      if (typeFilter != null) {
        where += ' AND type = ?';
        whereArgs.add(typeFilter);
      }
      if (beforeTimestamp != null) {
        where += ' AND timestamp < ?';
        whereArgs.add(beforeTimestamp);
      }

      return db.query(
        'messages',
        where: where,
        whereArgs: whereArgs,
        orderBy: 'timestamp DESC',
        limit: limit,
      );
    });
  }

  /// Media messages in a group chat, newest first.
  Future<List<Map<String, dynamic>>> getMediaMessagesForGroup(
    String groupId, {
    String? typeFilter,
    int limit = 50,
    int? beforeTimestamp,
    int? afterTimestamp,
  }) async {
    return await _protect(() async {
      final db = await _database;
      var where =
          'groupId = ? AND $_groupMediaTypeFilter AND $_mediaContentFilter';
      final whereArgs = <dynamic>[groupId];

      if (typeFilter != null) {
        where += ' AND type = ?';
        whereArgs.add(typeFilter);
      }
      if (afterTimestamp != null) {
        where += ' AND timestamp >= ?';
        whereArgs.add(afterTimestamp);
      }
      if (beforeTimestamp != null) {
        where += ' AND timestamp < ?';
        whereArgs.add(beforeTimestamp);
      }

      return db.query(
        'messages',
        where: where,
        whereArgs: whereArgs,
        orderBy: 'timestamp DESC',
        limit: limit,
      );
    });
  }

  /// All media messages across every chat, newest first.
  Future<List<Map<String, dynamic>>> getAllMediaMessages({
    List<String>? types,
    int limit = 50,
    int? beforeTimestamp,
    String? beforeId,
  }) async {
    return await _protect(() async {
      final db = await _database;
      var where = _mediaContentFilter;
      final whereArgs = <dynamic>[];

      if (types != null && types.isNotEmpty) {
        where +=
            ' AND type IN (${List.filled(types.length, '?').join(', ')})';
        whereArgs.addAll(types);
      } else {
        where += ' AND $_allMediaTypeFilter';
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

  /// Count of all media messages with stored content.
  Future<int> countAllMediaMessages({List<String>? types}) async {
    return await _protect(() async {
      final db = await _database;
      var where = _mediaContentFilter;
      final whereArgs = <dynamic>[];

      if (types != null && types.isNotEmpty) {
        where +=
            ' AND type IN (${List.filled(types.length, '?').join(', ')})';
        whereArgs.addAll(types);
      } else {
        where += ' AND $_allMediaTypeFilter';
      }

      final result = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM messages WHERE $where',
        whereArgs,
      );
      return Sqflite.firstIntValue(result) ?? 0;
    });
  }
}
