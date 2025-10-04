import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class MessageDbHelper {
  static Database? _database;

  static Future<Database> get database async {
    if (_database != null) return _database!;
    final databasesPath = await getApplicationDocumentsDirectory();
    final path = join(databasesPath.path, 'prysm', 'messages.db');

    _database = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages(
            id TEXT PRIMARY KEY, 
            senderId TEXT, 
            receiverId TEXT, 
            message TEXT, 
            timestamp INTEGER, 
            status TEXT
          )
        ''');
      },
    );
    return _database!;
  }

  static Future<void> insertMessage(Map<String, dynamic> message) async {
    final db = await database;
    await db.insert(
      'messages',
      message,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<List<Map<String, dynamic>>> getMessagesBetween(
      String userId, String peerId) async {
    final db = await database;
    return await db.query(
      'messages',
      where:
          '(senderId = ? AND receiverId = ?) OR (senderId = ? AND receiverId = ?)',
      whereArgs: [userId, peerId, peerId, userId],
      orderBy: 'timestamp DESC',
    );
  }
}
