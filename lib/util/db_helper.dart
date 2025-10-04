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
        avatarUrl TEXT
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
}