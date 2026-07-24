import 'package:prysm/database/message_id_codec.dart';
import 'package:prysm/database/message_query_filters.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages_database.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/message_blob_store.dart';
import 'package:sqflite/sqflite.dart';

/// Single-message CRUD (insert/update/delete) and point lookups by id,
/// including the encrypted wire payload (`getMessageWire`/`getMessageById`
/// share the blob-store fallback so they stay together).
class MessageCrudDao {
  const MessageCrudDao();

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
        columns: const ['id', 'senderId', 'status'],
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

  /// Loads the encrypted wire payload for a message (may read from disk).
  Future<String?> getMessageWire(
    String messageId, {
    String? groupId,
  }) async {
    return await _protect(() async {
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
    });
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
        final wire = await getMessageWire(messageId, groupId: groupId);
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
}
