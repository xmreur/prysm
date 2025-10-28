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
      version: 1,
      singleInstance: false,
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
            replyTo TEXT
          )
        ''');
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
}