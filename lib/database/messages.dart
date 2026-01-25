import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:mutex/mutex.dart';
import 'dart:async';

class MessagesDb {
	static Database? _database;
	static final _openCompleter = Completer<Database>();
	static final _dbMutex = Mutex();

    static const _dbVersion = 2;

	/// Return singleton database instance
	static Future<Database> get database async {
		if (_database != null) return _database!;
		if (!_openCompleter.isCompleted) {
			final databasesPath = await getApplicationDocumentsDirectory();
			final path = join(databasesPath.path, 'prysm', 'messages.db');

			_database = await openDatabase(
				path,
				version: _dbVersion,
				singleInstance: false,
				onConfigure: (db) async {
					await db.execute('PRAGMA foreign_keys = ON');
					await db.execute('PRAGMA busy_timeout = 5000');

					await db.execute('PRAGMA journal_mode = WAL');
					await db.execute('PRAGMA synchronous = NORMAL');
				},
				onCreate: (db, version) async {
					await _createV2(db);
				},
				onUpgrade: (db, oldVersion, newVersion) async {
					if (oldVersion < 2) await _upgradeToV2(db);
				},
				onDowngrade: (db, oldVersion, newVersion) async {
					throw Exception('Database downgrade not supported: $oldVersion -> $newVersion');
				}
			);

			_openCompleter.complete(_database);
		}

		return _openCompleter.future;
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
                readAt INTEGER
            )
        ''');

        await db.execute(
            'CREATE INDEX idx_conversation ON messages(senderId, receiverId)'
        );
        await db.execute(
            'CREATE INDEX idx_timestamp ON messages(timestamp)'
        );
        await db.execute(
            'CREATE INDEX idx_status ON messages(status)'
        );
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_read_status ON messages(readAt, status)'
        );
    }


	/// CHANGES: added readAt timestamp
	static Future<void> _upgradeToV2(Database db) async {
        print("UPGRADING DB TO v2");
        
        // But simpler: ignore error if column exists
        try {
            await db.execute('ALTER TABLE messages ADD COLUMN readAt INTEGER');
        } catch (e) {
            print('readAt column already exists or other error: $e');
        }
        await db.execute('CREATE INDEX IF NOT EXISTS idx_read_status ON messages(readAt, status)');
    }

	
	/// Insert or replace message, serialized with mutex
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
			final db = await database;
			final result = await db.rawQuery(
				'''
					SELECT MAX(timestamp) as lastTimestamp
					FROM messages
					WHERE senderId = ? OR receiverId = ? 
				''',
				[userId, userId]
			);

			if (result.isNotEmpty && result.first['lastTimestamp'] != null) {
				final value = result.first['lastTimestamp'];
				return value is int ? value : int.tryParse(value.toString());
			}
			return null;
		});
	}

	/// Query messages between two users, newest first
	static Future<List<Map<String, dynamic>>> getMessagesBetween(
		String userId,
		String receiverId,
	) async {
		final db = await database;
		return await db.query(
			'messages',
			where: '(senderId = ? AND receiverId = ?) OR (senderId = ? AND receiverId = ?)',
			whereArgs: [userId, receiverId, receiverId, userId],
			orderBy: 'timestamp DESC',
		);
	}

	/// Query message by ID
	static Future<List<Map<String, dynamic>>> getMessageById(
		String messageId,
	) async {
		final db = await database;
		return await db.query('messages', where: 'id = ?', whereArgs: [messageId]);
	}

	/// Get a batch of messages with optional pagination by timestamp
	static Future<List<Map<String, dynamic>>> getMessagesBetweenBatch(
		String userId,
		String receiverId, {
			int limit = 20,
			int? beforeTimestamp,
		}
	) async {
		final db = await database;
		String where = '(senderId = ? AND receiverId = ?) or (senderId = ? AND receiverId = ?)';
		List<dynamic> whereArgs = [userId, receiverId, receiverId, userId];

		if (beforeTimestamp != null) {
			where += ' AND timestamp < ?';
			whereArgs.add(beforeTimestamp);
		}

		return await db.query(
			'messages',
			where: where,
			whereArgs: whereArgs,
			orderBy: 'timestamp DESC',
			limit: limit
		);
	}

	/// Get a batch of messages with pagination by timestamp and message ID for stable ordering
	static Future<List<Map<String, dynamic>>> getMessagesBetweenBatchWithId(
		String userId,
		String receiverId, {
			int limit = 20,
			int? beforeTimestamp,
			String? beforeId,
		}
	) async {
		final db = await database;

		String where =
			'((senderId = ? AND receiverId = ?) OR (senderId = ? AND receiverId = ?))';
		List<dynamic> whereArgs = [userId, receiverId, receiverId, userId];
	
		if (beforeTimestamp != null && beforeId != null) {
			where += ' AND (timestamp < ? OR (timestamp = ? AND id < ?))';
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
			limit: limit
		);
	}

	/// Delete all messages between two users
	static Future<void> deleteMessagesBetween(
		String userId,
		String receiverId,
	) async {
		await _dbMutex.protect(() async {
			final db = await database;
			await db.delete(
				'messages',
				where:
					"(senderId = ? AND receiverId = ?) OR (senderId = ? AND receiverId = ?)",
				whereArgs: [userId, receiverId, receiverId, userId],
			);
		});
	}

	/// Delete a message by it's id
	static Future<void> deleteMessageById(String id) async {
		await _dbMutex.protect(() async {
			final db = await database;
			await db.update(
				'messages',
				{"replyTo": null},
				where: 'id = ?',
				whereArgs: [id],
			);
			await db.delete('messages', where: 'id = ?', whereArgs: [id]);
		});
	}

    static Future<void> setAsRead(String id) async {
        await _dbMutex.protect(() async {
            final db = await database;
            await db.update(
                'messages',
                {'readAt': DateTime.now().millisecondsSinceEpoch},
                where: 'id = ?',
                whereArgs: [id] 
            );
        });
    }

    static Future<void> updateMessageStatus(String id, String status) async {
        await _dbMutex.protect(() async {
            final db = await database;
            await db.update(
                'messages',
                {'status': status},
                where: 'id = ?',
                whereArgs: [id]
            );
        });
    }

	/// Close the db
	static Future<void> close() async {
		if (_database != null) {
			await _database!.close();
			_database = null;
		}
	}
}