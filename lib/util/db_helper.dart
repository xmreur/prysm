
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
    return await openDatabase(path, version: 1, onCreate: _createDB);
  }

  static Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        name TEXT,
        avatarUrl TEXT,
        publicKeyPem TEXT
      )
    ''');
  }


  static Future<void> insertOrUpdateUser(Map<String, dynamic> user) async {
    final db = await database;
    await db.insert('users', user, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<Map<String, dynamic>>> getUsers() async {
    final db = await database;
    return db.query('users');
  }

  static Future<void> ensureUserExist(String userId) async {
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
    }
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
  
  static Future<void> deleteUser(String userId) async {
    final db = await database;
    await db.delete(
      'users',
      where: 'id = ?',
      whereArgs: [userId],
    );
  }
}