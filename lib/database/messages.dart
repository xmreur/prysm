import 'package:flutter/foundation.dart';
import 'package:prysm/database/message_reactions.dart';
import 'package:prysm/database/message_read_receipts.dart';
import 'package:prysm/database/self_messages_db.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/read_waterline_mark.dart';
import 'package:prysm/util/sqflite_platform.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:mutex/mutex.dart';
import 'dart:async';

class MessagesDb {
  static Database? _database;
  static Future<Database>? _opening;
  static final _dbMutex = Mutex();
  static final _insertController = StreamController<Map<String, dynamic>>.broadcast();

  /// Stream that emits the normalized row whenever a message is inserted locally.
  static Stream<Map<String, dynamic>> get onMessageInserted => _insertController.stream;

  static const _dbVersion = 10;

  static const String _directChatTypeFilter =
      "(type IS NULL OR type IN ('text', 'file', 'image', 'audio', 'call'))";

  /// Only rows we can decrypt: our outbound copy or peer deliveries to us.
  /// Also includes local system rows (e.g. call events) from either side.
  static const String _directConversationFilter =
      "((senderId = ? AND receiverId = ? AND COALESCE(status, '') != 'received') "
      "OR (senderId = ? AND receiverId = ? AND status = 'received') "
      "OR (senderId = ? AND receiverId = ? AND status = 'system') "
      "OR (senderId = ? AND receiverId = ? AND status = 'system'))";

  /// Return singleton database instance
  @visibleForTesting
  static void setDatabaseForTest(Database? db) {
    _database = db;
    _opening = null;
  }

  static Future<Database> get database async {
    if (_database != null) return _database!;
    _opening ??= _openDatabase();
    try {
      return await _opening!;
    } catch (e) {
      _opening = null;
      rethrow;
    }
  }

  static Future<Database> _openDatabase() async {
    ensureSqflitePlatformInitialized();
    final databasesPath = await getApplicationDocumentsDirectory();
    final path = join(databasesPath.path, 'prysm', 'messages.db');

    final db = await openDatabase(
      path,
      version: _dbVersion,
      singleInstance: true,
      onConfigure: _onConfigure,
      onCreate: (db, version) async {
        await _createV2(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _upgradeToV2(db);
        if (oldVersion < 3) await _upgradeToV3(db);
        if (oldVersion < 4) await _upgradeToV4(db);
        if (oldVersion < 5) await _upgradeToV5(db);
        if (oldVersion < 6) await _upgradeToV6(db);
        if (oldVersion < 7) await _upgradeToV7(db);
        if (oldVersion < 8) await _upgradeToV8(db);
        if (oldVersion < 9) await _upgradeToV9(db);
        if (oldVersion < 10) await _upgradeToV10(db);
      },
      onDowngrade: (db, oldVersion, newVersion) async {
        throw Exception(
          'Database downgrade not supported: $oldVersion -> $newVersion',
        );
      },
    );
    _database = db;
    return db;
  }

  static Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
    // Android rejects some PRAGMA via execute() during onConfigure.
    await db.rawQuery('PRAGMA busy_timeout = 5000');
    await db.rawQuery('PRAGMA journal_mode = WAL');
    await db.rawQuery('PRAGMA synchronous = NORMAL');
  }

  static Future<void> closeForWipe() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
      _opening = null;
    }
  }

  static Future<void> _createV2(Database db) async {
    await db.execute('''
            CREATE TABLE messages(
                id TEXT PRIMARY KEY,
                senderId TEXT NOT NULL,
                receiverId TEXT NOT NULL,
                message TEXT,
                type TEXT,
                fileName TEXT,
                fileSize INTEGER,
                timestamp INTEGER NOT NULL,
                status TEXT DEFAULT 'sent',
                replyTo TEXT,
                readAt INTEGER,
                viewOnce INTEGER DEFAULT 0,
                viewed INTEGER DEFAULT 0,
                groupId TEXT,
                deletedAt INTEGER,
                editedAt INTEGER
            )
        ''');

    await db.execute(
      'CREATE INDEX idx_conversation ON messages(senderId, receiverId)',
    );
    await db.execute(
      'CREATE INDEX idx_group_messages ON messages(groupId, timestamp)',
    );
    await db.execute('CREATE INDEX idx_timestamp ON messages(timestamp)');
    await db.execute('CREATE INDEX idx_status ON messages(status)');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_read_status ON messages(readAt, status)',
    );
    await MessageReactionsDb.createTable(db);
    await MessageReadReceiptsDb.createTable(db);
    await SelfMessagesDb.createTable(db);
  }

  /// CHANGES: added readAt timestamp
  static Future<void> _upgradeToV2(Database db) async {
    print("UPGRADING DB TO v2");

    final columns = await db.rawQuery('PRAGMA table_info(messages)');
    final hasReadAt = columns.any((col) => col['name'] == 'readAt');
    if (!hasReadAt) {
      await db.execute('ALTER TABLE messages ADD COLUMN readAt INTEGER');
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_read_status ON messages(readAt, status)',
    );
  }

  static Future<void> _upgradeToV3(Database db) async {
    print("UPGRADING DB TO v3");
    final columns = await db.rawQuery('PRAGMA table_info(messages)');
    if (!columns.any((col) => col['name'] == 'viewOnce')) {
      await db.execute(
        'ALTER TABLE messages ADD COLUMN viewOnce INTEGER DEFAULT 0',
      );
    }
    if (!columns.any((col) => col['name'] == 'viewed')) {
      await db.execute(
        'ALTER TABLE messages ADD COLUMN viewed INTEGER DEFAULT 0',
      );
    }
  }

  static Future<void> _upgradeToV4(Database db) async {
    print("UPGRADING DB TO v4");
    final columns = await db.rawQuery('PRAGMA table_info(messages)');
    if (!columns.any((col) => col['name'] == 'groupId')) {
      await db.execute('ALTER TABLE messages ADD COLUMN groupId TEXT');
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_group_messages ON messages(groupId, timestamp)',
    );
  }

  static Future<void> _upgradeToV5(Database db) async {
    print('UPGRADING DB TO v5');
    await db.transaction((txn) async {
      final rows = await txn.query('messages', where: 'groupId IS NOT NULL');
      for (final row in rows) {
        final wireId = row['id'] as String;
        final groupId = row['groupId'] as String?;
        if (groupId == null || wireId.contains('::')) continue;
        await txn.update(
          'messages',
          {'id': scopedId(wireId: wireId, groupId: groupId)},
          where: 'id = ? AND groupId = ?',
          whereArgs: [wireId, groupId],
        );
      }
    });
  }

  static Future<void> _upgradeToV6(Database db) async {
    print('UPGRADING DB TO v6');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_unread_inbound ON messages(senderId, status, readAt)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_direct_peer_ts ON messages(senderId, receiverId, timestamp DESC)',
    );
  }

  static Future<void> _upgradeToV7(Database db) async {
    print('UPGRADING DB TO v7');
    await MessageReactionsDb.createTable(db);
  }

  static Future<void> _upgradeToV8(Database db) async {
    print('UPGRADING DB TO v8');
    final columns = await db.rawQuery('PRAGMA table_info(messages)');
    if (!columns.any((col) => col['name'] == 'deletedAt')) {
      await db.execute('ALTER TABLE messages ADD COLUMN deletedAt INTEGER');
    }
    if (!columns.any((col) => col['name'] == 'editedAt')) {
      await db.execute('ALTER TABLE messages ADD COLUMN editedAt INTEGER');
    }
  }

  static Future<void> _upgradeToV9(Database db) async {
    print('UPGRADING DB TO v9');
    await MessageReadReceiptsDb.createTable(db);
    // Outbound rows had readAt set on delivery — not peer read confirmations.
    await db.execute('''
			UPDATE messages
			SET readAt = NULL
			WHERE COALESCE(status, '') = 'sent'
			  AND COALESCE(status, '') != 'received'
		''');
  }

  static Future<void> _upgradeToV10(Database db) async {
    print('UPGRADING DB TO v10');
    await SelfMessagesDb.createTable(db);
  }

  /// Storage primary key: group messages are scoped per group to avoid cross-group REPLACE.
  static String scopedId({required String wireId, String? groupId}) {
    if (groupId != null && groupId.isNotEmpty) return '$groupId::$wireId';
    return wireId;
  }

  static String wireIdFromStorage(String storageId) {
    final sep = storageId.indexOf('::');
    if (sep < 0) return storageId;
    return storageId.substring(sep + 2);
  }

  static Map<String, dynamic> _withStorageId(Map<String, dynamic> message) {
    final normalized = Map<String, dynamic>.from(message);
    final groupId = normalized['groupId'] as String?;
    normalized['id'] = scopedId(
      wireId: normalized['id'] as String,
      groupId: groupId,
    );
    return normalized;
  }

  /// Mark a view-once message as viewed and wipe its content
  static Future<void> markViewOnceViewed(
    String messageId, {
    String? groupId,
  }) async {
    await _dbMutex.protect(() async {
      final db = await database;
      final storageId = scopedId(wireId: messageId, groupId: groupId);
      await db.update(
        'messages',
        {'viewed': 1, 'message': null},
        where: 'id = ? AND viewOnce = 1',
        whereArgs: [storageId],
      );
    });
  }

  /// Insert or replace a locally-sent message (encrypted for self).
  static Future<void> insertMessage(
    Map<String, dynamic> message, {
    bool notifyListeners = true,
  }) async {
    await _dbMutex.protect(() async {
      final db = await database;
      final normalized = _withStorageId(message);
      await db.insert(
        'messages',
        normalized,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (notifyListeners && !_insertController.isClosed) {
        _insertController.add(normalized);
      }
    });
  }

  /// Insert an inbound delivery without clobbering our outbound encrypted-for-self copy.
  /// Returns the stored row, or null when an existing outbound copy is kept.
  static Future<Map<String, dynamic>?> insertInboundMessage(
    Map<String, dynamic> message,
    String localUserId,
  ) async {
    return await _dbMutex.protect(() async {
      final db = await database;
      final normalized = _withStorageId(message);
      final id = normalized['id'] as String;
      final existing = await db.query(
        'messages',
        where: 'id = ?',
        whereArgs: [id],
      );
      if (existing.isNotEmpty) {
        final row = existing.first;
        final wasOutbound =
            row['senderId'] == localUserId && row['status'] != 'received';
        if (wasOutbound) {
          return null;
        }
      }
      await db.insert(
        'messages',
        normalized,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return normalized;
    });
  }

  /// Get the last message timestamp for a user
  static Future<int?> getLastMessageTimestampForUser(String userId) async {
    return await _dbMutex.protect(() async {
      final db = await database;
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
  static Future<Map<String, int>> getLastMessageTimestampsForAllUsers() async {
    return await _dbMutex.protect(() async {
      final db = await database;
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

  /// Query messages between two users, newest first
  static Future<List<Map<String, dynamic>>> getMessagesBetween(
    String userId,
    String receiverId,
  ) async {
    return await _dbMutex.protect(() async {
      final db = await database;
      return await db.query(
        'messages',
        where:
            'groupId IS NULL AND $_directChatTypeFilter AND $_directConversationFilter',
        whereArgs: [userId, receiverId, receiverId, userId, userId, receiverId, receiverId, userId],
        orderBy: 'timestamp DESC',
      );
    });
  }

  /// Query message by wire ID (optionally scoped to a group).
  static Future<List<Map<String, dynamic>>> getMessageById(
    String messageId, {
    String? groupId,
  }) async {
    final db = await database;
    final storageId = scopedId(wireId: messageId, groupId: groupId);
    return await db.query('messages', where: 'id = ?', whereArgs: [storageId]);
  }

  /// Get a batch of messages with optional pagination by timestamp
  static Future<List<Map<String, dynamic>>> getMessagesBetweenBatch(
    String userId,
    String receiverId, {
    int limit = 20,
    int? beforeTimestamp,
  }) async {
    return await _dbMutex.protect(() async {
      final db = await database;
      String where =
          'groupId IS NULL AND $_directChatTypeFilter AND $_directConversationFilter';
      List<dynamic> whereArgs = [userId, receiverId, receiverId, userId, userId, receiverId, receiverId, userId];

      if (beforeTimestamp != null) {
        where += ' AND timestamp < ?';
        whereArgs.add(beforeTimestamp);
      }

      return await db.query(
        'messages',
        where: where,
        whereArgs: whereArgs,
        orderBy: 'timestamp DESC',
        limit: limit,
      );
    });
  }

  /// Get a batch of messages with pagination by timestamp and message ID for stable ordering
  static Future<List<Map<String, dynamic>>> getMessagesBetweenBatchWithId(
    String userId,
    String receiverId, {
    int limit = 20,
    int? beforeTimestamp,
    String? beforeId,
  }) async {
    return await _dbMutex.protect(() async {
      final db = await database;

      String where =
          'groupId IS NULL AND $_directChatTypeFilter AND $_directConversationFilter';
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
        where: where,
        whereArgs: whereArgs,
        orderBy: 'timestamp DESC, id DESC',
        limit: limit,
      );
    });
  }

  /// Delete all messages between two users
  static Future<void> deleteMessagesBetween(
    String userId,
    String receiverId,
  ) async {
    await _dbMutex.protect(() async {
      final db = await database;
      await db.delete(
        'messages',
        where:
            "groupId IS NULL AND $_directChatTypeFilter AND ((senderId = ? AND receiverId = ?) OR (senderId = ? AND receiverId = ?) OR (senderId = ? AND receiverId = ? AND status = 'system') OR (senderId = ? AND receiverId = ? AND status = 'system'))",
        whereArgs: [userId, receiverId, receiverId, userId, userId, receiverId, receiverId, userId],
      );
    });
  }

  static Future<void> softDeleteMessage(
    String wireId, {
    String? groupId,
    required int deletedAt,
  }) async {
    await _dbMutex.protect(() async {
      final db = await database;
      final storageId = scopedId(wireId: wireId, groupId: groupId);
      await db.update(
        'messages',
        {
          'deletedAt': deletedAt,
          'message': null,
          'fileName': null,
          'fileSize': null,
          'viewOnce': 0,
        },
        where: 'id = ?',
        whereArgs: [storageId],
      );
    });
  }

  static Future<void> updateMessageContent({
    required String wireId,
    String? groupId,
    required String encryptedMessage,
    required int editedAt,
  }) async {
    await _dbMutex.protect(() async {
      final db = await database;
      final storageId = scopedId(wireId: wireId, groupId: groupId);
      await db.update(
        'messages',
        {'message': encryptedMessage, 'editedAt': editedAt},
        where: 'id = ? AND deletedAt IS NULL',
        whereArgs: [storageId],
      );
    });
  }

  /// Delete a message by it's id
  static Future<void> deleteMessageById(String id) async {
    await _dbMutex.protect(() async {
      final db = await database;
      await db.transaction((txn) async {
        await txn.update(
          'messages',
          {"replyTo": null},
          where: 'replyTo = ?',
          whereArgs: [id],
        );
        await txn.delete('messages', where: 'id = ?', whereArgs: [id]);
      });
    });
  }

  static Future<void> setAsRead(String id, {String? groupId}) async {
    await _dbMutex.protect(() async {
      final db = await database;
      final storageId = scopedId(wireId: id, groupId: groupId);
      await db.update(
        'messages',
        {'readAt': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [storageId],
      );
    });
  }

  /// Mark inbound direct messages as read locally. Returns waterline if any marked.
  static Future<ReadWaterlineMark?> markInboundConversationRead(
    String localUserId,
    String peerId,
  ) async {
    return await _dbMutex.protect(() async {
      final db = await database;
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
        latestMessageId: wireIdFromStorage(latestRow!['id'] as String),
        readUpToTimestamp: readUpTo,
      );
    });
  }

  /// Mark inbound group messages as read locally. Returns waterline if any marked.
  static Future<ReadWaterlineMark?> markInboundGroupRead(
    String localUserId,
    String groupId,
  ) async {
    return await _dbMutex.protect(() async {
      final db = await database;
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
        latestMessageId: wireIdFromStorage(latestRow!['id'] as String),
        readUpToTimestamp: readUpTo,
        groupId: groupId,
      );
    });
  }

  /// Outbound direct messages from [senderId] to [receiverId] up to [readUpToTimestamp].
  static Future<List<Map<String, dynamic>>> getOutboundDirectUpToTimestamp({
    required String senderId,
    required String receiverId,
    required int readUpToTimestamp,
  }) async {
    return _dbMutex.protect(() async {
      final db = await database;
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
  static Future<List<Map<String, dynamic>>> getOutboundGroupUpToTimestamp({
    required String senderId,
    required String groupId,
    required int readUpToTimestamp,
  }) async {
    return _dbMutex.protect(() async {
      final db = await database;
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
  static Future<List<Map<String, dynamic>>> getPendingOutboundDirectMessages({
    required String senderId,
    required String receiverId,
  }) async {
    return _dbMutex.protect(() async {
      final db = await database;
      return db.query(
        'messages',
        where:
            'groupId IS NULL AND senderId = ? AND receiverId = ? '
            "AND status = 'pending' AND deletedAt IS NULL AND "
            '$_directChatTypeFilter',
        whereArgs: [senderId, receiverId],
        orderBy: 'timestamp ASC',
      );
    });
  }

  static Future<void> updateMessageStatus(
    String messageId,
    String status, {
    String? groupId,
  }) async {
    await _dbMutex.protect(() async {
      final db = await database;
      final storageId = scopedId(wireId: messageId, groupId: groupId);
      await db.update(
        'messages',
        {'status': status},
        where: 'id = ?',
        whereArgs: [storageId],
      );
    });
  }

  /// Get messages for a group, newest first (dedupe by id in caller)
  static Future<List<Map<String, dynamic>>> getMessagesForGroupBatch(
    String groupId, {
    int limit = 20,
    int? beforeTimestamp,
    String? beforeId,
    int? afterTimestamp,
  }) async {
    return await _dbMutex.protect(() async {
      final db = await database;
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

  static String previewLabelForType(String? type, {bool deleted = false}) {
    if (deleted) return 'Deleted';
    switch (type) {
      case 'image':
      case 'group_image':
        return '📷 Photo';
      case 'file':
      case 'group_file':
        return '📎 File';
      case 'audio':
      case 'group_audio':
        return '🎤 Voice';
      case 'call':
        return '📞 Call';
      default:
        return 'Message';
    }
  }

  /// Latest message preview label per conversation id (peer onion or group id).
  static Future<Map<String, String>> getLastMessagePreviews(
    String localUserId,
  ) async {
    return await _dbMutex.protect(() async {
      final db = await database;
      final previews = <String, String>{};
      final groupJoinedAt = await DBHelper.getGroupJoinedAtByMember(
        localUserId,
      );

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

      final directRows = await db.rawQuery(
        '''
				WITH latest AS (
				  SELECT
				    CASE WHEN senderId = ? THEN receiverId ELSE senderId END AS convKey,
				    MAX(timestamp) AS max_ts
				  FROM messages
				  WHERE groupId IS NULL
				    AND $_directChatTypeFilter
				    AND (senderId = ? OR receiverId = ?)
				  GROUP BY convKey
				)
				SELECT l.convKey, m.type, m.deletedAt
				FROM latest l
				JOIN messages m ON m.timestamp = l.max_ts
				  AND m.groupId IS NULL
				  AND (CASE WHEN m.senderId = ? THEN m.receiverId ELSE m.senderId END) = l.convKey
				GROUP BY l.convKey
			''',
        [localUserId, localUserId, localUserId, localUserId],
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
  static Future<Map<String, int>> getUnreadCounts(String localUserId) async {
    return await _dbMutex.protect(() async {
      final db = await database;
      final counts = <String, int>{};
      final groupJoinedAt = await DBHelper.getGroupJoinedAtByMember(
        localUserId,
      );

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

  /// Last message timestamp per group (only messages after member joined).
  static Future<Map<String, int>> getLastMessageTimestampsForAllGroups(
    String localUserId,
  ) async {
    return await _dbMutex.protect(() async {
      final db = await database;
      final groupJoinedAt = await DBHelper.getGroupJoinedAtByMember(
        localUserId,
      );
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

  static Future<void> deleteMessagesForGroup(String groupId) async {
    await _dbMutex.protect(() async {
      final db = await database;
      await db.delete('messages', where: 'groupId = ?', whereArgs: [groupId]);
    });
  }

  static Future<void> deleteGroupMessagesBefore(
    String groupId,
    int beforeTimestamp,
  ) async {
    await _dbMutex.protect(() async {
      final db = await database;
      await db.delete(
        'messages',
        where: 'groupId = ? AND timestamp < ?',
        whereArgs: [groupId, beforeTimestamp],
      );
    });
  }

  static const String _directMediaTypeFilter =
      "type IN ('image', 'file', 'audio')";

  static const String _groupMediaTypeFilter =
      "type IN ('group_image', 'group_file', 'group_audio')";

  static const String _mediaContentFilter =
      "deletedAt IS NULL AND message IS NOT NULL AND message != ''";

  /// Media messages in a direct chat, newest first.
  static Future<List<Map<String, dynamic>>> getMediaMessagesForDirect(
    String userId,
    String peerId, {
    String? typeFilter,
    int limit = 50,
    int? beforeTimestamp,
  }) async {
    return await _dbMutex.protect(() async {
      final db = await database;
      var where =
          'groupId IS NULL AND $_directMediaTypeFilter AND $_mediaContentFilter AND $_directConversationFilter';
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
  static Future<List<Map<String, dynamic>>> getMediaMessagesForGroup(
    String groupId, {
    String? typeFilter,
    int limit = 50,
    int? beforeTimestamp,
    int? afterTimestamp,
  }) async {
    return await _dbMutex.protect(() async {
      final db = await database;
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

  /// Close the db
  static Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }
}
