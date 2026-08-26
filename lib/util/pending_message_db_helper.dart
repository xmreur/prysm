import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/database/database_cipher.dart';
import 'package:prysm/util/pending_activity_notifier.dart';
import 'package:prysm/util/sqflite_platform.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class PendingMessageDbHelper {
  static Database? _database;
  static Future<Database>? _opening;

  static Future<Database> get database async {
    // This opener is the only one that skipped this: without it, the FFI
    // factory is never installed and openDatabase falls back to the
    // platform channel (a real problem now that SQLCipher is the
    // production path on every platform).
    ensureSqflitePlatformInitialized();
    if (_database != null) return _database!;
    _opening ??= _open();
    try {
      return await _opening!;
    } catch (e) {
      _opening = null;
      rethrow;
    }
  }

  static Future<Database> _open() async {
    final databasesPath = await getApplicationDocumentsDirectory();
    final path = join(databasesPath.path, 'prysm', 'pending_messages.db');

    // Encrypt an existing plaintext file in place, or no-op for a fresh or
    // already-encrypted database. Must run before openDatabase.
    await DatabaseCipher.prepare(path);

    final db = await openDatabase(
      path,
      version: 6,
      singleInstance: true,
      // PRAGMA key must be the first statement on the connection.
      onConfigure: (db) async {
        await DatabaseCipher.applyKey(db);
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE pending_messages(
            id TEXT PRIMARY KEY,
            senderId TEXT,
            receiverId TEXT,
            message TEXT,
            type TEXT,
            fileName TEXT,
            fileSize INTEGER,
            timestamp INTEGER,
            status TEXT,
            replyTo TEXT,
            viewOnce INTEGER DEFAULT 0,
            groupId TEXT,
            targetMemberId TEXT,
            expiresAt INTEGER,
            forwarded INTEGER DEFAULT 0
          )
        ''');
        await db.execute('CREATE INDEX idx_pending_receiver ON pending_messages(receiverId)');
        await db.execute('CREATE INDEX idx_pending_timestamp ON pending_messages(timestamp)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('CREATE INDEX IF NOT EXISTS idx_pending_receiver ON pending_messages(receiverId)');
          await db.execute('CREATE INDEX IF NOT EXISTS idx_pending_timestamp ON pending_messages(timestamp)');
        }
        if (oldVersion < 3) {
          final columns = await db.rawQuery('PRAGMA table_info(pending_messages)');
          if (!columns.any((col) => col['name'] == 'viewOnce')) {
            await db.execute('ALTER TABLE pending_messages ADD COLUMN viewOnce INTEGER DEFAULT 0');
          }
        }
        if (oldVersion < 4) {
          final columns = await db.rawQuery('PRAGMA table_info(pending_messages)');
          if (!columns.any((col) => col['name'] == 'groupId')) {
            await db.execute('ALTER TABLE pending_messages ADD COLUMN groupId TEXT');
          }
          if (!columns.any((col) => col['name'] == 'targetMemberId')) {
            await db.execute('ALTER TABLE pending_messages ADD COLUMN targetMemberId TEXT');
          }
        }
        if (oldVersion < 5) {
          final columns = await db.rawQuery('PRAGMA table_info(pending_messages)');
          if (!columns.any((col) => col['name'] == 'expiresAt')) {
            await db.execute('ALTER TABLE pending_messages ADD COLUMN expiresAt INTEGER');
          }
        }
        if (oldVersion < 6) {
          final columns = await db.rawQuery('PRAGMA table_info(pending_messages)');
          if (!columns.any((col) => col['name'] == 'forwarded')) {
            await db.execute(
              'ALTER TABLE pending_messages ADD COLUMN forwarded INTEGER DEFAULT 0',
            );
          }
        }
      },
    );
    _database = db;
    return db;
  }

  static Future<void> insertPendingMessage(Map<String, dynamic> message) async {
    final db = await database;
    await db.insert(
      "pending_messages",
      message,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    PendingActivityNotifier.instance.notify();
  }

  static Future<List<Map<String, dynamic>>> getPendingMessages({
    String? groupId,
    String? receiverId,
  }) async {
    final db = await database;
    if (groupId != null) {
      return db.query('pending_messages', where: 'groupId = ?', whereArgs: [groupId]);
    }
    if (receiverId != null) {
      return db.query(
        'pending_messages',
        where: 'groupId IS NULL AND receiverId = ?',
        whereArgs: [receiverId],
        orderBy: 'timestamp ASC',
      );
    }
    return db.query(
      'pending_messages',
      where: 'groupId IS NULL',
      orderBy: 'timestamp ASC',
    );
  }

  /// Pending 1:1 outbound rows for global retry worker.
  static Future<List<Map<String, dynamic>>> getPendingDirectMessages({
    required String senderId,
    int? limit,
  }) async {
    final db = await database;
    return db.query(
      'pending_messages',
      where: 'groupId IS NULL AND senderId = ?',
      whereArgs: [senderId],
      orderBy: 'timestamp ASC',
      limit: limit,
    );
  }

  /// Pending 1:1 outbound rows for a specific peer.
  static Future<List<Map<String, dynamic>>> getPendingDirectMessagesForReceiver({
    required String senderId,
    required String receiverId,
    int? limit,
  }) async {
    final db = await database;
    return db.query(
      'pending_messages',
      where: 'groupId IS NULL AND senderId = ? AND receiverId = ?',
      whereArgs: [senderId, receiverId],
      orderBy: 'timestamp ASC',
      limit: limit,
    );
  }

  static Future<bool> hasOutboundDirectPending(
    String senderId,
    String receiverId,
  ) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM pending_messages '
      'WHERE groupId IS NULL AND senderId = ? AND receiverId = ?',
      [senderId, receiverId],
    );
    return (Sqflite.firstIntValue(result) ?? 0) > 0;
  }

  static Future<int> countOutboundPending(String senderId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM pending_messages WHERE senderId = ?',
      [senderId],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  static Future<List<Map<String, dynamic>>> getAllPendingMessages() async {
    final db = await database;
    return db.query('pending_messages');
  }

  static Future<List<Map<String, dynamic>>> getPendingGroupChatMessages({
    required String senderId,
    int? limit,
  }) async {
    final db = await database;
    return db.query(
      'pending_messages',
      where: 'groupId IS NOT NULL AND senderId = ?',
      whereArgs: [senderId],
      orderBy: 'timestamp ASC',
      limit: limit,
    );
  }

  static Future<List<Map<String, dynamic>>> getPendingControlMessages(
    Set<String> controlTypes,
  ) async {
    if (controlTypes.isEmpty) return [];
    final db = await database;
    final placeholders = List.filled(controlTypes.length, '?').join(',');
    return db.query(
      'pending_messages',
      where: 'type IN ($placeholders)',
      whereArgs: controlTypes.toList(),
    );
  }

  static Future<void> removeMessage(String messageId) async {
    final db = await database;

    await db.delete('pending_messages', where: "id = ?", whereArgs: [messageId]);
    PendingActivityNotifier.instance.notify();
  }

  /// Drops queued outbound chat deliveries for a wire message id.
  static Future<void> removeOutboundPendingForWireId(
    String wireId, {
    String? groupId,
  }) async {
    final db = await database;
    if (groupId != null) {
      await db.delete(
        'pending_messages',
        where: 'groupId = ? AND (id = ? OR id LIKE ?)',
        whereArgs: [groupId, wireId, '${wireId}__%'],
      );
    } else {
      await db.delete(
        'pending_messages',
        where: 'groupId IS NULL AND id = ?',
        whereArgs: [wireId],
      );
    }
    PendingActivityNotifier.instance.notify();
  }

  static Future<void> closeForWipe() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
    _opening = null;
  }

  static Future<void> removeMessages(List<String> messageIds) async {
    if (messageIds.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(messageIds.length, '?').join(',');
    await db.delete(
      'pending_messages',
      where: 'id IN ($placeholders)',
      whereArgs: messageIds,
    );
    PendingActivityNotifier.instance.notify();
  }

  /// Pending 1:1 chat outbound row for a wire message id (excludes side-channels).
  static Future<Map<String, dynamic>?> getPendingOutboundForWireId(
    String wireId,
  ) async {
    final db = await database;
    final rows = await db.query(
      'pending_messages',
      where: 'id = ? AND groupId IS NULL',
      whereArgs: [wireId],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final type = row['type'] as String?;
    if (!isPendingOutboundChatType(type ?? '')) return null;
    return row;
  }

  /// Pending group chat outbound rows keyed as `{wireId}__{memberId}`.
  static Future<List<Map<String, dynamic>>> getPendingGroupOutboundForWireId(
    String wireId,
    String groupId,
  ) async {
    final db = await database;
    final rows = await db.query(
      'pending_messages',
      where: 'groupId = ? AND id LIKE ?',
      whereArgs: [groupId, '${wireId}__%'],
    );
    return rows
        .where((row) => isPendingOutboundChatType(row['type'] as String? ?? ''))
        .toList();
  }

  static Future<void> updatePendingCiphertext({
    required String id,
    required String encrypted,
  }) async {
    final db = await database;
    await db.update(
      'pending_messages',
      {'message': encrypted},
      where: 'id = ?',
      whereArgs: [id],
    );
    PendingActivityNotifier.instance.notify();
  }

  @visibleForTesting
  static void setDatabaseForTest(Database? db) {
    _database = db;
    _opening = null;
  }
}