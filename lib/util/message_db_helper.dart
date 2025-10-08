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
            type TEXT,
            fileName TEXT,
            fileSize INTEGER,
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

  static Future<List<Map<String, dynamic>>> getMessageById(String messageId) async {
    final db = await database;
    return await db.query(
      "messages",
      where: "id = ?",
      whereArgs: [messageId]
    );
  }

  static Future<List<Map<String, dynamic>>> getMessagesBetweenBatch(
    String userId, String peerId, { int limit = 20, int? beforeTimestamp}
  ) async {
    final db = await database;
    String where = '(senderId = ? AND receiverId = ?) OR (senderId = ? AND receiverId = ?)';
    List<dynamic> whereArgs = [userId, peerId, peerId, userId];

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
  }
  
  static Future<List<Map<String, dynamic>>> getMessagesBetweenBatchWithId(
    String userId,
    String peerId, {
    int limit = 20,
    int? beforeTimestamp,
    String? beforeId,
  }) async {
    final db = await database;

    String where =
        '((senderId = ? AND receiverId = ?) OR (senderId = ? AND receiverId = ?))';
    List<dynamic> whereArgs = [userId, peerId, peerId, userId];

    if (beforeTimestamp != null && beforeId != null) {
      // Add pagination conditions
      where +=
          ' AND (timestamp < ? OR (timestamp = ? AND id < ?))'; // strictly before timestamp, or if same timestamp before id
      whereArgs.addAll([beforeTimestamp, beforeTimestamp, beforeId]);
    } else if (beforeTimestamp != null) {
      // If only timestamp provided
      where += ' AND timestamp < ?';
      whereArgs.add(beforeTimestamp);
    } else if (beforeId != null) {
      // If only beforeId provided (less common)
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
  }


  static Future<void> deleteMessagesBetween(String userId, String peerId) async {
    final db = await database;

    await db.delete(
      "messages",
      where: "(senderId = ? AND receiverId = ?) OR (senderId = ? AND receiverId = ?)",
      whereArgs: [userId, peerId, peerId, userId]
    );
    
  }
  

}
