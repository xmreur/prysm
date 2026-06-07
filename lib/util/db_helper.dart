
import 'package:prysm/database/conversation_preferences_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';


class DBHelper {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    _initializeFfi();
    _db = await _initDB();
    return _db!;
  }

  static Future<void> closeForWipe() async {
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
  }

  static void _initializeFfi() {
    // This initializes ffi for desktop platforms
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  static Future<Database> _initDB() async {
    final docDir = await getApplicationDocumentsDirectory();
    final path = join(docDir.path, 'prysm', 'chat_app.db');
    return await openDatabase(path, version: 5, onCreate: _createDB, onUpgrade: _onUpgrade);
  }

  static Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        name TEXT,
        avatarUrl TEXT,
        avatarBase64 TEXT,
        customName TEXT,
        publicKeyPem TEXT
      )
    ''');
    await db.execute('CREATE INDEX idx_users_name ON users(name)');
    await _createGroupTables(db);
    await ConversationPreferencesDb.createTable(db);
  }

  static Future<void> _createGroupTables(Database db) async {
    await db.execute('''
      CREATE TABLE groups (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        avatarBase64 TEXT,
        createdBy TEXT NOT NULL,
        createdAt INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE group_members (
        groupId TEXT NOT NULL,
        memberId TEXT NOT NULL,
        role TEXT NOT NULL,
        joinedAt INTEGER NOT NULL,
        PRIMARY KEY (groupId, memberId),
        FOREIGN KEY (groupId) REFERENCES groups(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE group_keys (
        groupId TEXT PRIMARY KEY,
        encryptedKey TEXT NOT NULL,
        keyVersion INTEGER NOT NULL DEFAULT 1,
        FOREIGN KEY (groupId) REFERENCES groups(id) ON DELETE CASCADE
      )
    ''');
  }

  static Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      final cols = await db.rawQuery('PRAGMA table_info(users)');
      final colNames = cols.map((c) => c['name'] as String).toSet();
      if (!colNames.contains('avatarBase64')) {
        await db.execute('ALTER TABLE users ADD COLUMN avatarBase64 TEXT');
      }
    }
    if (oldVersion < 3) {
      final cols = await db.rawQuery('PRAGMA table_info(users)');
      final colNames = cols.map((c) => c['name'] as String).toSet();
      if (!colNames.contains('customName')) {
        await db.execute('ALTER TABLE users ADD COLUMN customName TEXT');
      }
    }
    if (oldVersion < 4) {
      await _createGroupTables(db);
    }
    if (oldVersion < 5) {
      await ConversationPreferencesDb.createTable(db);
    }
  }


  static Future<void> insertOrUpdateUser(Map<String, dynamic> user) async {
    final db = await database;
    await db.insert('users', user, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<Map<String, dynamic>>> getUsers() async {
    final db = await database;
    return db.query('users');
  }

  static Future<bool> ensureUserExist(String userId) async {
    final db = await database;
    final users = await db.query(
      'users',
      where: 'id = ?',
      whereArgs: [userId],
      limit: 1
    );

    if (users.isEmpty) {
      final unknownName = 'Unknown - ${userId.substring(0, 6)}';
      await db.insert(
        'users',
        {
          'id': userId,
          'name': unknownName,
          'avatarUrl': null,
          'publicKeyPem': null,
        },
        conflictAlgorithm: ConflictAlgorithm.replace
      );
      return true;
    }
    return false;
  }

  static Future<Map<String, dynamic>?> getUserById(String id) async {
    final db = await database;
    final List<Map<String, dynamic>> results = await db.query(
      "users",
      where: "id = ?",
      whereArgs: [id],
    );
    if (results.isNotEmpty) {
      return results.first;
    }
    return null; // or throw, or return an empty map {}
  }

  /// Update specific fields for a user without overwriting other columns.
  static Future<void> updateUserFields(String userId, Map<String, dynamic> fields) async {
    final db = await database;
    await db.update(
      'users',
      fields,
      where: 'id = ?',
      whereArgs: [userId],
    );
  }
  
  static Future<void> deleteUser(String userId) async {
    final db = await database;
    await db.delete(
      'users',
      where: 'id = ?',
      whereArgs: [userId],
    );
  }

  // --- Group helpers ---

  static Future<void> insertGroup(Map<String, dynamic> group) async {
    final db = await database;
    await db.insert('groups', group, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<Map<String, dynamic>>> getGroups() async {
    final db = await database;
    return db.query('groups', orderBy: 'createdAt DESC');
  }

  /// Groups where [memberId] is still listed in group_members.
  static Future<List<Map<String, dynamic>>> getGroupsForMember(
    String memberId,
  ) async {
    final db = await database;
    return db.rawQuery(
      '''
      SELECT g.*
      FROM groups g
      INNER JOIN group_members gm ON g.id = gm.groupId
      WHERE gm.memberId = ?
      ORDER BY g.createdAt DESC
      ''',
      [memberId],
    );
  }

  static Future<bool> isGroupMember(String groupId, String memberId) async {
    final db = await database;
    final rows = await db.query(
      'group_members',
      where: 'groupId = ? AND memberId = ?',
      whereArgs: [groupId, memberId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static Future<int?> getMemberJoinedAt(String groupId, String memberId) async {
    final db = await database;
    final rows = await db.query(
      'group_members',
      columns: ['joinedAt'],
      where: 'groupId = ? AND memberId = ?',
      whereArgs: [groupId, memberId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final value = rows.first['joinedAt'];
    return value is int ? value : int.tryParse(value.toString());
  }

  /// groupId -> joinedAt for all groups [memberId] belongs to.
  static Future<Map<String, int>> getGroupJoinedAtByMember(String memberId) async {
    final db = await database;
    final rows = await db.query(
      'group_members',
      columns: ['groupId', 'joinedAt'],
      where: 'memberId = ?',
      whereArgs: [memberId],
    );
    final joined = <String, int>{};
    for (final row in rows) {
      final groupId = row['groupId'] as String?;
      final value = row['joinedAt'];
      if (groupId == null || groupId.isEmpty || value == null) continue;
      joined[groupId] = value is int ? value : int.tryParse(value.toString()) ?? 0;
    }
    return joined;
  }

  static Future<Map<String, dynamic>?> getGroupById(String id) async {
    final db = await database;
    final results = await db.query('groups', where: 'id = ?', whereArgs: [id], limit: 1);
    return results.isNotEmpty ? results.first : null;
  }

  static Future<void> deleteGroup(String groupId) async {
    final db = await database;
    await db.delete('group_keys', where: 'groupId = ?', whereArgs: [groupId]);
    await db.delete('group_members', where: 'groupId = ?', whereArgs: [groupId]);
    await db.delete('groups', where: 'id = ?', whereArgs: [groupId]);
  }

  static Future<void> addGroupMember(Map<String, dynamic> member) async {
    final db = await database;
    await db.insert('group_members', member, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> removeGroupMember(String groupId, String memberId) async {
    final db = await database;
    await db.delete(
      'group_members',
      where: 'groupId = ? AND memberId = ?',
      whereArgs: [groupId, memberId],
    );
  }

  static Future<List<Map<String, dynamic>>> getGroupMembers(String groupId) async {
    final db = await database;
    return db.query('group_members', where: 'groupId = ?', whereArgs: [groupId]);
  }

  static Future<int> getGroupMemberCount(String groupId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM group_members WHERE groupId = ?',
      [groupId],
    );
    final val = result.first['cnt'];
    if (val is int) return val;
    return int.tryParse(val.toString()) ?? 0;
  }

  static Future<void> upsertGroupKey({
    required String groupId,
    required String encryptedKey,
    required int keyVersion,
  }) async {
    final db = await database;
    await db.insert(
      'group_keys',
      {
        'groupId': groupId,
        'encryptedKey': encryptedKey,
        'keyVersion': keyVersion,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<Map<String, dynamic>?> getGroupKey(String groupId) async {
    final db = await database;
    final results = await db.query('group_keys', where: 'groupId = ?', whereArgs: [groupId], limit: 1);
    return results.isNotEmpty ? results.first : null;
  }
}