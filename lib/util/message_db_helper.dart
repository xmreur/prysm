import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:mutex/mutex.dart';
import 'dart:async';

class MessageDbHelper {
  static Database? _database;
  static final _openCompleter = Completer<Database>();
  static final _dbMutex = Mutex();

  /// Returns singleton database instance
  static Future<Database> get database async {
    if (_database != null) return _database!;
    if (!_openCompleter.isCompleted) {
      final databasesPath = await getApplicationDocumentsDirectory();
      final path = join(databasesPath.path, 'prysm', 'messages.db');

      _database = await openDatabase(
        path,
        version: 1,
        singleInstance: false,
        onConfigure: (db) async {
          // Enable foreign keys if needed, set busy timeout (5 seconds)
          await db.execute('PRAGMA foreign_keys = ON');
          await db.execute('PRAGMA busy_timeout = 5000');
        },
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
              status TEXT,
              replyTo TEXT
            )
          ''');
        },
      );

      _openCompleter.complete(_database);
    }
    return _openCompleter.future;
  }

  /// Insert or replace a message safely, serialized with mutex
  static Future<void> insertMessage(Map<String, dynamic> message) async {
    await _dbMutex.protect(() async {
      final db = await database;
      await db.insert(
        'messages',
        message,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  /// Get the last message timestamp for a user
  static Future<int?> getLastMessageTimestampForUser(String userId) async {
    return await _dbMutex.protect(() async {
      final messagesDb = await database;
      final result = await messagesDb.rawQuery('''
        SELECT MAX(timestamp) as lastTimestamp
        FROM messages
        WHERE senderId = ? OR receiverId = ?
      ''', [userId, userId]);

      if (result.isNotEmpty && result.first['lastTimestamp'] != null) {
        final value = result.first['lastTimestamp'];
        return value is int ? value : int.tryParse(value.toString());
      }
      return null;
    });
  }

  /// Query messages between two users, newest first
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

  /// Query message by ID
  static Future<List<Map<String, dynamic>>> getMessageById(String messageId) async {
    final db = await database;
    return await db.query(
      "messages",
      where: "id = ?",
      whereArgs: [messageId],
    );
  }

  /// Get a batch of messages with optional pagination by timestamp
  static Future<List<Map<String, dynamic>>> getMessagesBetweenBatch(
      String userId, String peerId,
      {int limit = 20, int? beforeTimestamp}) async {
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

  /// Get a batch of messages with pagination by timestamp and message ID for stable ordering
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
      where +=
          ' AND (timestamp < ? OR (timestamp = ? AND id < ?))';
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
  }

  /// Delete all messages between two users
  static Future<void> deleteMessagesBetween(String userId, String peerId) async {
    await _dbMutex.protect(() async {
      final db = await database;
      await db.delete(
        "messages",
        where:
            "(senderId = ? AND receiverId = ?) OR (senderId = ? AND receiverId = ?)",
        whereArgs: [userId, peerId, peerId, userId],
      );
    });
  }

  static Future<void> deleteMessageById(String id) async {
    await _dbMutex.protect(() async {
      final db = await database;
      await db.update( 
        "messages",
        {
          "replyTo": null
        },
        where: "id = ?",
        whereArgs: [id]
      );
      await db.delete(
        "messages",
        
        where: "id = ?",
        whereArgs: [id]
      );
    });
  }

  /// Close the database (optional)
  static Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }
}
