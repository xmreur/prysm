import 'package:path_provider/path_provider.dart';
import 'package:prysm/util/pending_activity_notifier.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class PendingMessageDbHelper {
  static Database? _database;

  static Future<Database> get database async {
    if (_database != null) return _database!;

    final databasesPath = await getApplicationDocumentsDirectory();
    final path = join(databasesPath.path, 'prysm', 'pending_messages.db');

    _database = await openDatabase(
      path,
      version: 4,
      singleInstance: true,
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
            targetMemberId TEXT
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
      },
    );
    return _database!;
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

  static Future<void> closeForWipe() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
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
}