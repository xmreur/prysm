import 'package:path_provider/path_provider.dart';
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
      version: 3,
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
            viewOnce INTEGER DEFAULT 0
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
  }

  static Future<List<Map<String, dynamic>>> getPendingMessages() async {
    final db = await database;

    return await db.query(
      'pending_messages'
    );
  }

  static Future<void> removeMessage(String messageId) async {
    final db = await database;

    await db.delete('pending_messages', where: "id = ?", whereArgs: [messageId]);
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
  }
}