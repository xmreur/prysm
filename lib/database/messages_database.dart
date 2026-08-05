import 'package:flutter/foundation.dart';
import 'package:mutex/mutex.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'package:prysm/database/database_cipher.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/util/sqflite_platform.dart';

/// Owns the messages.db lifecycle: opening, PRAGMA configuration, closing,
/// and the single mutex shared by every MessagesDb query. Schema creation
/// and migrations live in MessageSchemaMigrations.
class MessagesDatabase {
  MessagesDatabase._();

  static Database? _database;
  static Future<Database>? _opening;

  /// The single mutex shared by every MessagesDb query, owned here.
  static final Mutex mutex = Mutex();

  static Future<Database> get database async {
    if (_database != null) return _database!;
    _opening ??= _open();
    try {
      return await _opening!;
    } catch (e) {
      _opening = null;
      rethrow;
    }
  }

  static Future<Database> _open() async {
    ensureSqflitePlatformInitialized();
    final databasesPath = await getApplicationDocumentsDirectory();
    final path = join(databasesPath.path, 'prysm', 'messages.db');

    // Encrypt an existing plaintext file in place, or no-op for a fresh or
    // already-encrypted database. Must run before openDatabase.
    await DatabaseCipher.prepare(path);

    final db = await openDatabase(
      path,
      version: MessageSchemaMigrations.dbVersion,
      singleInstance: true,
      onConfigure: _onConfigure,
      onCreate: MessageSchemaMigrations.onCreate,
      onUpgrade: MessageSchemaMigrations.onUpgrade,
      onDowngrade: (db, oldVersion, newVersion) async {
        throw Exception(
          'Database downgrade not supported: $oldVersion -> $newVersion',
        );
      },
    );
    _database = db;
    await MessageSchemaMigrations.migrateOversizedMessagePayloads(db);
    return db;
  }

  static Future<void> _onConfigure(Database db) async {
    // PRAGMA key must be the first statement on the connection; anything
    // before it makes the open fail with SQLITE_NOTADB.
    await DatabaseCipher.applyKey(db);
    await db.execute('PRAGMA foreign_keys = ON');
    // Android rejects some PRAGMA via execute() during onConfigure.
    await db.rawQuery('PRAGMA busy_timeout = 5000');
    await db.rawQuery('PRAGMA journal_mode = WAL');
    await db.rawQuery('PRAGMA synchronous = NORMAL');
  }

  static Future<void> closeForWipe() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
      _opening = null;
    }
  }

  /// Close the db
  static Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }

  @visibleForTesting
  static void setDatabaseForTest(Database? db) {
    _database = db;
    _opening = null;
  }
}
