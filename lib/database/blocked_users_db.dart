import 'package:prysm/util/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class BlockedUser {
  final String userId;
  final int blockedAt;

  const BlockedUser({required this.userId, required this.blockedAt});

  factory BlockedUser.fromMap(Map<String, dynamic> map) {
    return BlockedUser(
      userId: map['userId'] as String,
      blockedAt: map['blockedAt'] as int,
    );
  }
}

class BlockedUsersDb {
  BlockedUsersDb._();

  static Future<void> createTable(Database db) async {
    await db.execute('''
      CREATE TABLE blocked_users (
        userId TEXT PRIMARY KEY,
        blockedAt INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> block(String userId, int blockedAt) async {
    final db = await DBHelper.database;
    await db.insert(
      'blocked_users',
      {'userId': userId, 'blockedAt': blockedAt},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> unblock(String userId) async {
    final db = await DBHelper.database;
    await db.delete(
      'blocked_users',
      where: 'userId = ?',
      whereArgs: [userId],
    );
  }

  static Future<bool> isBlocked(String userId) async {
    final db = await DBHelper.database;
    final rows = await db.query(
      'blocked_users',
      where: 'userId = ?',
      whereArgs: [userId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static Future<List<BlockedUser>> getAll() async {
    final db = await DBHelper.database;
    final rows = await db.query('blocked_users', orderBy: 'blockedAt DESC');
    return rows.map(BlockedUser.fromMap).toList();
  }

  static Future<Set<String>> getBlockedIds() async {
    final all = await getAll();
    return all.map((u) => u.userId).toSet();
  }
}
