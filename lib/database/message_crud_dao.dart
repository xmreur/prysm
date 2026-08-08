import 'package:prysm/database/message_id_codec.dart';
import 'package:prysm/database/message_query_filters.dart';
import 'package:prysm/database/message_reactions.dart';
import 'package:prysm/database/message_read_receipts.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/message_search_dao.dart';
import 'package:prysm/database/messages_database.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/message_blob_store.dart';
import 'package:sqflite/sqflite.dart';

/// Single-message CRUD (insert/update/delete) and point lookups by id,
/// including the encrypted wire payload (`getMessageWire`/`getMessageById`
/// share the blob-store fallback so they stay together).
class MessageCrudDao {
  const MessageCrudDao({MessageSearchDao? searchDao})
      : _searchDao = searchDao ?? const MessageSearchDao();

  final MessageSearchDao _searchDao;

  Future<Database> get _database => MessagesDatabase.database;

  Future<T> _protect<T>(Future<T> Function() action) =>
      MessagesDatabase.mutex.protect(action);

  static Map<String, dynamic> _withStorageId(Map<String, dynamic> message) {
    final normalized = Map<String, dynamic>.from(message);
    final groupId = normalized['groupId'] as String?;
    normalized['id'] = MessageIdCodec.scopedId(
      wireId: normalized['id'] as String,
      groupId: groupId,
    );
    return normalized;
  }

  static Future<Map<String, dynamic>> _withStoragePayload(
    Map<String, dynamic> message,
  ) async {
    final normalized = Map<String, dynamic>.from(message);
    final storageId = normalized['id'] as String;
    final wire = normalized['message'];
    if (wire is String) {
      normalized['message'] =
          await MessageBlobStore.prepareForStorage(storageId, wire);
    }
    return normalized;
  }

  /// Removes a message's FTS row, scoped to its conversation. The caller must
  /// already hold [MessagesDatabase.mutex]. Pass [row] when the `messages` row
  /// is about to be (or has already been) deleted; otherwise it is read here.
  ///
  /// A direct row's conversationId is the peer, which is one of the two
  /// participants — both are tried, so the delete is never widened to a bare
  /// `messageId` match. That matters because the wire id is chosen by the
  /// sender: an unscoped delete lets a peer wipe search rows of unrelated
  /// conversations by reusing an id it has seen.
  Future<void> _removeSearchRow(
    Database db, {
    required String storageId,
    required String wireId,
    Map<String, Object?>? row,
  }) async {
    if (row == null) {
      final rows = await db.query(
        'messages',
        columns: const ['groupId', 'senderId', 'receiverId'],
        where: 'id = ?',
        whereArgs: [storageId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      row = rows.first;
    }
    final groupId = row['groupId'] as String?;
    if (groupId != null) {
      await _searchDao.removeUnprotected(
        wireId,
        conversationId: groupId,
        scope: 'group',
      );
      return;
    }
    for (final side in const ['senderId', 'receiverId']) {
      await _searchDao.removeUnprotected(
        wireId,
        conversationId: row[side] as String,
        scope: 'direct',
      );
    }
  }

  /// Mark a view-once message as viewed and wipe its content
  Future<void> markViewOnceViewed(
    String messageId, {
    String? groupId,
  }) async {
    await _protect(() async {
      final db = await _database;
      final storageId = MessageIdCodec.scopedId(wireId: messageId, groupId: groupId);
      await db.update(
        'messages',
        {'viewed': 1, 'message': null},
        where: 'id = ? AND viewOnce = 1',
        whereArgs: [storageId],
      );
      await _removeSearchRow(db, storageId: storageId, wireId: messageId);
    });
  }

  /// Insert or replace a locally-sent message (encrypted for self).
  /// [onInserted] is invoked with the normalized row when the write commits
  /// and [notifyListeners] is true; the caller owns the broadcast mechanism.
  Future<void> insertMessage(
    Map<String, dynamic> message, {
    bool notifyListeners = true,
    required void Function(Map<String, dynamic>) onInserted,
  }) async {
    await _protect(() async {
      final db = await _database;
      final normalized = await _withStoragePayload(_withStorageId(message));
      await db.insert(
        'messages',
        normalized,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (notifyListeners) {
        onInserted(normalized);
      }
    });
  }

  /// Insert an inbound delivery without clobbering our outbound encrypted-for-self copy.
  /// Returns the stored row, or null when an existing outbound copy is kept.
  Future<Map<String, dynamic>?> insertInboundMessage(
    Map<String, dynamic> message,
    String localUserId,
  ) async {
    return await _protect(() async {
      final db = await _database;
      final normalized =
          await _withStoragePayload(_withStorageId(message));
      final id = normalized['id'] as String;
      final existing = await db.query(
        'messages',
        columns: const ['id', 'senderId', 'status', 'deletedAt'],
        where: 'id = ?',
        whereArgs: [id],
      );
      if (existing.isNotEmpty) {
        final row = existing.first;
        // A soft-delete tombstone wins over a re-delivery: a captured inbound
        // message re-POSTed after deletion must not resurrect the row.
        if (row['deletedAt'] != null) {
          return null;
        }
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

  /// Loads the encrypted wire payload for a message (may read from disk).
  Future<String?> getMessageWire(
    String messageId, {
    String? groupId,
  }) {
    return _protect(
      () => _getMessageWireUnprotected(messageId, groupId: groupId),
    );
  }

  /// Lock-free core of [getMessageWire]: the caller must already hold
  /// [MessagesDatabase.mutex] (via [_protect]) before invoking this.
  Future<String?> _getMessageWireUnprotected(
    String messageId, {
    String? groupId,
  }) async {
    final db = await _database;
    final storageId = MessageIdCodec.scopedId(wireId: messageId, groupId: groupId);

    if (await MessageBlobStore.exists(storageId)) {
      return MessageBlobStore.read(storageId);
    }

    try {
      final rows = await db.query(
        'messages',
        columns: const ['message'],
        where: 'id = ?',
        whereArgs: [storageId],
      );
      if (rows.isEmpty) return null;
      final wire = rows.first['message'] as String?;
      return MessageBlobStore.resolve(wire);
    } catch (e, stack) {
      Logging.error(
        'getMessageWire failed for $messageId, attempting migration: $e\n$stack',
        'MessagesDb',
      );
      try {
        final wire = await MessageSchemaMigrations.readMessageColumnInChunks(db, storageId);
        if (wire.isEmpty) return null;
        await MessageBlobStore.save(storageId, wire);
        await db.update(
          'messages',
          {'message': MessageBlobStore.marker(storageId)},
          where: 'id = ?',
          whereArgs: [storageId],
        );
        return wire;
      } catch (e2, stack2) {
        Logging.error(
          'getMessageWire migration failed for $messageId: $e2\n$stack2',
          'MessagesDb',
        );
        return null;
      }
    }
  }

  /// Query message by wire ID (optionally scoped to a group).
  Future<List<Map<String, dynamic>>> getMessageById(
    String messageId, {
    String? groupId,
  }) async {
    return await _protect(() async {
      final db = await _database;
      final storageId = MessageIdCodec.scopedId(wireId: messageId, groupId: groupId);
      final metaRows = await db.query(
        'messages',
        columns: MessageQueryFilters.messageListColumns,
        where: 'id = ?',
        whereArgs: [storageId],
      );
      if (metaRows.isEmpty) return [];

      final row = Map<String, dynamic>.from(metaRows.first);
      if (await MessageBlobStore.exists(storageId)) {
        row['message'] = MessageBlobStore.marker(storageId);
        return [row];
      }

      try {
        final wireRows = await db.query(
          'messages',
          columns: const ['message'],
          where: 'id = ?',
          whereArgs: [storageId],
        );
        if (wireRows.isNotEmpty) {
          row['message'] = wireRows.first['message'];
        }
      } catch (e, stack) {
        Logging.error(
          'getMessageById wire read failed for $messageId: $e\n$stack',
          'MessagesDb',
        );
        // Already inside the outer `_protect` here: call the lock-free
        // variant, not getMessageWire, which would re-acquire the
        // non-reentrant mutex and deadlock the caller.
        final wire = await _getMessageWireUnprotected(
          messageId,
          groupId: groupId,
        );
        if (wire == null) {
          row['message'] = null;
        } else if (MessageBlobStore.isMarker(wire) ||
            wire.length > MessageBlobStore.inlineThreshold) {
          row['message'] = MessageBlobStore.marker(storageId);
        } else {
          row['message'] = wire;
        }
      }
      return [row];
    });
  }

  Future<void> softDeleteMessage(
    String wireId, {
    String? groupId,
    required int deletedAt,
  }) async {
    await _protect(() async {
      final db = await _database;
      final storageId = MessageIdCodec.scopedId(wireId: wireId, groupId: groupId);
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
      await MessageBlobStore.delete(storageId);
      await _removeSearchRow(db, storageId: storageId, wireId: wireId);
    });
  }

  Future<void> updateMessageContent({
    required String wireId,
    String? groupId,
    required String encryptedMessage,
    required int editedAt,
  }) async {
    await _protect(() async {
      final db = await _database;
      final storageId = MessageIdCodec.scopedId(wireId: wireId, groupId: groupId);
      await db.update(
        'messages',
        {'message': encryptedMessage, 'editedAt': editedAt},
        where: 'id = ? AND deletedAt IS NULL',
        whereArgs: [storageId],
      );
    });
  }

  /// Delete a message by it's id
  Future<void> deleteMessageById(String id) async {
    await _protect(() async {
      final db = await _database;
      final rows = await db.query(
        'messages',
        columns: const ['groupId', 'senderId', 'receiverId'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      await db.transaction((txn) async {
        await txn.update(
          'messages',
          {"replyTo": null},
          where: 'replyTo = ?',
          whereArgs: [id],
        );
        await txn.delete('messages', where: 'id = ?', whereArgs: [id]);
      });
      if (rows.isEmpty) return;
      // De-index AFTER the row is gone: a broken search index must not be able
      // to block a delete. Strip the row's own groupId prefix rather than
      // re-parsing via the codec — the wire id is sender-chosen and may itself
      // contain '::'.
      final groupId = rows.first['groupId'] as String?;
      await _removeSearchRow(
        db,
        storageId: id,
        wireId: groupId == null ? id : id.substring(groupId.length + 2),
        row: rows.first,
      );
    });
  }

  /// Permanently removes a message and its related rows (reactions, receipts).
  Future<void> hardDeleteMessage(
    String wireId, {
    String? groupId,
  }) async {
    final storageId = MessageIdCodec.scopedId(wireId: wireId, groupId: groupId);
    await MessageReactionsDb.deleteReactionsForMessage(storageId);
    await MessageReadReceiptsDb.deleteReceiptsForMessage(
      wireMessageId: wireId,
      groupId: groupId,
    );
    await deleteMessageById(storageId);
    await MessageBlobStore.delete(storageId);
  }

  Future<void> updateMessageStatus(
    String messageId,
    String status, {
    String? groupId,
  }) async {
    await _protect(() async {
      final db = await _database;
      final storageId = MessageIdCodec.scopedId(wireId: messageId, groupId: groupId);
      await db.update(
        'messages',
        {'status': status},
        where: 'id = ?',
        whereArgs: [storageId],
      );
    });
  }

  /// Earliest [expiresAt] among live rows, or null when nothing is scheduled.
  Future<int?> getNextExpiresAt() async {
    return await _protect(() async {
      final db = await _database;
      final rows = await db.rawQuery(
        'SELECT MIN(expiresAt) AS nextAt FROM messages '
        'WHERE expiresAt IS NOT NULL AND deletedAt IS NULL '
        'AND expiresAt > ?',
        [DateTime.now().millisecondsSinceEpoch],
      );
      final value = rows.first['nextAt'];
      if (value == null) return null;
      return value is int ? value : int.tryParse(value.toString());
    });
  }

  /// Rows whose [expiresAt] is at or before [cutoff].
  Future<List<Map<String, dynamic>>> getExpiredMessages({
    required int cutoff,
    int limit = 100,
  }) async {
    return await _protect(() async {
      final db = await _database;
      return db.query(
        'messages',
        columns: const ['id', 'groupId'],
        where: 'expiresAt IS NOT NULL AND deletedAt IS NULL AND expiresAt <= ?',
        whereArgs: [cutoff],
        orderBy: 'expiresAt ASC',
        limit: limit,
      );
    });
  }

  /// Direct messages awaiting post-unlock authentication.
  Future<List<Map<String, dynamic>>> getPendingAuthDirectMessages() async {
    return await _protect(() async {
      final db = await _database;
      return db.query(
        'messages',
        where: "groupId IS NULL AND status = 'pending_auth'",
        orderBy: 'timestamp ASC',
      );
    });
  }
}
