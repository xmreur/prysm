import 'package:sqflite/sqflite.dart';

import 'package:prysm/database/message_id_codec.dart';
import 'package:prysm/util/logging.dart';
import 'package:prysm/util/message_blob_store.dart';

/// Owns the messages.db schema: table/index creation (v2, the first
/// versioned schema), the v2→v10 upgrade chain, and the oversized-payload
/// blob migration (bulk, at open time, plus the per-read fallback).
class MessageSchemaMigrations {
  MessageSchemaMigrations._();

  /// Current schema version. Bump alongside a new _upgradeToVN step.
  static const int dbVersion = 15;

  static Future<void> onCreate(Database db, int version) async {
    await _createV2(db);
  }

  static Future<void> onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) await _upgradeToV2(db);
    if (oldVersion < 3) await _upgradeToV3(db);
    if (oldVersion < 4) await _upgradeToV4(db);
    if (oldVersion < 5) await _upgradeToV5(db);
    if (oldVersion < 6) await _upgradeToV6(db);
    if (oldVersion < 7) await _upgradeToV7(db);
    if (oldVersion < 8) await _upgradeToV8(db);
    if (oldVersion < 9) await _upgradeToV9(db);
    if (oldVersion < 10) await _upgradeToV10(db);
    if (oldVersion < 12) await _upgradeToV12(db);
    if (oldVersion < 13) await _upgradeToV13(db);
    if (oldVersion < 14) await _upgradeToV14(db);
    if (oldVersion < 15) await _upgradeToV15(db);
  }

  static Future<void> migrateOversizedMessagePayloads(Database db) async {
    final rows = await db.rawQuery(
      "SELECT id FROM messages WHERE message IS NOT NULL "
      "AND LENGTH(message) > ? AND message NOT LIKE 'blob:%'",
      [MessageBlobStore.inlineThreshold],
    );
    for (final row in rows) {
      final storageId = row['id'] as String;
      try {
        final wire = await readMessageColumnInChunks(db, storageId);
        await MessageBlobStore.save(storageId, wire);
        await db.update(
          'messages',
          {'message': MessageBlobStore.marker(storageId)},
          where: 'id = ?',
          whereArgs: [storageId],
        );
      } catch (e, stack) {
        Logging.error(
          'failed to migrate oversized message $storageId: $e\n$stack',
          'MessagesDb',
        );
      }
    }
  }

  /// Reads the raw `message` column for [storageId] in bounded chunks,
  /// avoiding a single oversized row read. Also used by MessagesDb as a
  /// fallback when a normal read of a legacy (pre-blob-store) row fails.
  static Future<String> readMessageColumnInChunks(
    Database db,
    String storageId,
  ) async {
    final lenRows = await db.rawQuery(
      'SELECT LENGTH(message) AS len FROM messages WHERE id = ?',
      [storageId],
    );
    if (lenRows.isEmpty) return '';
    final len = lenRows.first['len'];
    final total = len is int ? len : int.tryParse(len.toString()) ?? 0;
    if (total <= 0) return '';

    const chunkSize = 500000;
    final buffer = StringBuffer();
    for (var offset = 1; offset <= total; offset += chunkSize) {
      final partRows = await db.rawQuery(
        'SELECT SUBSTR(message, ?, ?) AS part FROM messages WHERE id = ?',
        [offset, chunkSize, storageId],
      );
      if (partRows.isEmpty) break;
      buffer.write(partRows.first['part'] ?? '');
    }
    return buffer.toString();
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
                editedAt INTEGER,
                expiresAt INTEGER
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
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_messages_expires_at '
      'ON messages(expiresAt) WHERE expiresAt IS NOT NULL AND deletedAt IS NULL',
    );
    await createReactionsTable(db);
    await createReadReceiptsTable(db);
    await createSelfMessagesTable(db);
    await createScheduledMessagesTable(db);
    await createMessageSearchFtsTable(db);
  }

  /// CHANGES: added readAt timestamp
  static Future<void> _upgradeToV2(Database db) async {
    Logging.info("UPGRADING DB TO v2", 'MessagesDb');

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
    Logging.info("UPGRADING DB TO v3", 'MessagesDb');
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
    Logging.info("UPGRADING DB TO v4", 'MessagesDb');
    final columns = await db.rawQuery('PRAGMA table_info(messages)');
    if (!columns.any((col) => col['name'] == 'groupId')) {
      await db.execute('ALTER TABLE messages ADD COLUMN groupId TEXT');
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_group_messages ON messages(groupId, timestamp)',
    );
  }

  static Future<void> _upgradeToV5(Database db) async {
    Logging.info('UPGRADING DB TO v5', 'MessagesDb');
    await db.transaction((txn) async {
      final rows = await txn.query('messages', where: 'groupId IS NOT NULL');
      for (final row in rows) {
        final wireId = row['id'] as String;
        final groupId = row['groupId'] as String?;
        if (groupId == null || wireId.contains('::')) continue;
        final scopedId = MessageIdCodec.scopedId(
          wireId: wireId,
          groupId: groupId,
        );
        await txn.update(
          'messages',
          {'id': scopedId},
          where: 'id = ? AND groupId = ?',
          whereArgs: [wireId, groupId],
        );
      }
    });
  }

  static Future<void> _upgradeToV6(Database db) async {
    Logging.info('UPGRADING DB TO v6', 'MessagesDb');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_unread_inbound ON messages(senderId, status, readAt)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_direct_peer_ts ON messages(senderId, receiverId, timestamp DESC)',
    );
  }

  static Future<void> _upgradeToV7(Database db) async {
    Logging.info('UPGRADING DB TO v7', 'MessagesDb');
    await createReactionsTable(db);
  }

  static Future<void> _upgradeToV8(Database db) async {
    Logging.info('UPGRADING DB TO v8', 'MessagesDb');
    final columns = await db.rawQuery('PRAGMA table_info(messages)');
    if (!columns.any((col) => col['name'] == 'deletedAt')) {
      await db.execute('ALTER TABLE messages ADD COLUMN deletedAt INTEGER');
    }
    if (!columns.any((col) => col['name'] == 'editedAt')) {
      await db.execute('ALTER TABLE messages ADD COLUMN editedAt INTEGER');
    }
  }

  static Future<void> _upgradeToV9(Database db) async {
    Logging.info('UPGRADING DB TO v9', 'MessagesDb');
    await createReadReceiptsTable(db);
    // Outbound rows had readAt set on delivery — not peer read confirmations.
    await db.execute('''
			UPDATE messages
			SET readAt = NULL
			WHERE COALESCE(status, '') = 'sent'
			  AND COALESCE(status, '') != 'received'
		''');
  }

  static Future<void> _upgradeToV10(Database db) async {
    Logging.info('UPGRADING DB TO v10', 'MessagesDb');
    await createSelfMessagesTable(db);
  }

  static Future<void> _upgradeToV12(Database db) async {
    Logging.info('UPGRADING DB TO v12', 'MessagesDb');
    await createScheduledMessagesTable(db);
  }

  static Future<void> _upgradeToV13(Database db) async {
    Logging.info('UPGRADING DB TO v13', 'MessagesDb');
    final columns = await db.rawQuery('PRAGMA table_info(messages)');
    if (!columns.any((col) => col['name'] == 'expiresAt')) {
      await db.execute('ALTER TABLE messages ADD COLUMN expiresAt INTEGER');
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_messages_expires_at '
      'ON messages(expiresAt) WHERE expiresAt IS NOT NULL AND deletedAt IS NULL',
    );
  }

  static Future<void> _upgradeToV14(Database db) async {
    Logging.info('UPGRADING DB TO v14', 'MessagesDb');
    await createMessageSearchFtsTable(db);
  }

  /// CHANGES: added the message_search_rows side table mapping each
  /// (messageId, conversationId, scope) to its FTS rowid, so deletes become
  /// rowid probes instead of full scans of the UNINDEXED FTS metadata
  /// columns. Backfills the side table from the existing FTS index so the
  /// current index is preserved, not rebuilt.
  static Future<void> _upgradeToV15(Database db) async {
    Logging.info('UPGRADING DB TO v15', 'MessagesDb');
    await createMessageSearchFtsTable(db);
    await db.execute('''
      INSERT OR IGNORE INTO message_search_rows(
        messageId, conversationId, scope, timestamp, ftsRowid
      )
      SELECT messageId, conversationId, scope, timestamp, rowid
      FROM message_search_fts
    ''');
  }

  /// Plaintext FTS5 index for local message search (protected by SQLCipher),
  /// plus the message_search_rows side table that keeps deletes O(1).
  static Future<void> createMessageSearchFtsTable(Database db) async {
    await db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS message_search_fts USING fts5(
        messageId UNINDEXED,
        conversationId UNINDEXED,
        scope UNINDEXED,
        timestamp UNINDEXED,
        body,
        tokenize = 'unicode61 remove_diacritics 2'
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS message_search_rows(
        messageId TEXT NOT NULL,
        conversationId TEXT NOT NULL,
        scope TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        ftsRowid INTEGER NOT NULL,
        PRIMARY KEY (messageId, conversationId, scope)
      )
    ''');
  }

  /// Owns message_reactions' schema; MessageReactionsDb.createTable delegates here.
  static Future<void> createReactionsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS message_reactions(
        targetMessageId TEXT NOT NULL,
        reactorId TEXT NOT NULL,
        emoji TEXT NOT NULL,
        groupId TEXT,
        timestamp INTEGER NOT NULL,
        PRIMARY KEY (targetMessageId, reactorId)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_reactions_target ON message_reactions(targetMessageId)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_reactions_group ON message_reactions(groupId, targetMessageId)',
    );
  }

  /// Owns message_read_receipts' schema; MessageReadReceiptsDb.createTable delegates here.
  static Future<void> createReadReceiptsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS message_read_receipts (
        messageId TEXT NOT NULL,
        groupId TEXT,
        readerId TEXT NOT NULL,
        readAt INTEGER NOT NULL,
        PRIMARY KEY (messageId, readerId)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_read_receipts_group ON message_read_receipts(groupId)',
    );
  }

  /// Owns self_messages' schema; SelfMessagesDb.createTable delegates here.
  static Future<void> createSelfMessagesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS self_messages (
        id TEXT PRIMARY KEY,
        message TEXT,
        type TEXT DEFAULT 'text',
        fileName TEXT,
        fileSize INTEGER,
        timestamp INTEGER NOT NULL,
        replyTo TEXT,
        viewOnce INTEGER DEFAULT 0,
        viewed INTEGER DEFAULT 0,
        deletedAt INTEGER,
        editedAt INTEGER
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_self_messages_ts ON self_messages(timestamp)',
    );
  }

  /// Owns scheduled_messages' schema; ScheduledMessagesDb.createTable delegates
  /// here. `body` holds the message text encrypted for self, so a pending
  /// scheduled message is never stored as plaintext.
  static Future<void> createScheduledMessagesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS scheduled_messages (
        id TEXT PRIMARY KEY,
        conversationId TEXT NOT NULL,
        isGroup INTEGER NOT NULL DEFAULT 0,
        body TEXT NOT NULL,
        replyTo TEXT,
        sendAt INTEGER NOT NULL,
        createdAt INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_scheduled_send_at ON scheduled_messages(sendAt)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_scheduled_conversation ON scheduled_messages(conversationId, sendAt)',
    );
  }
}
