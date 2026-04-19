
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

  static void _initializeFfi() {
    // This initializes ffi for desktop platforms
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  static Future<Database> _initDB() async {
    final docDir = await getApplicationDocumentsDirectory();
    final path = join(docDir.path, 'prysm', 'chat_app.db');
    return await openDatabase(path, version: 3, onCreate: _createDB, onUpgrade: _onUpgrade);
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
}