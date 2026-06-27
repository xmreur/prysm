import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Local-only storage for voice message transcripts (never sent over P2P).
class VoiceTranscriptsDb {
  VoiceTranscriptsDb._();

  static Database? _database;
  static Database? _testDatabase;

  static Future<Database> get database async {
    if (_testDatabase != null) return _testDatabase!;
    if (_database != null) return _database!;

    final docDir = await getApplicationDocumentsDirectory();
    final path = join(docDir.path, 'prysm', 'voice_transcripts.db');
    _database = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE voice_transcripts(
            messageId TEXT PRIMARY KEY,
            transcript TEXT NOT NULL,
            createdAt INTEGER NOT NULL
          )
        ''');
      },
    );
    return _database!;
  }

  static void setDatabaseForTest(Database? db) {
    _testDatabase = db;
  }

  static Future<void> closeForWipe() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }

  static Future<String?> get(String messageId) async {
    final db = await database;
    final rows = await db.query(
      'voice_transcripts',
      columns: ['transcript'],
      where: 'messageId = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['transcript'] as String?;
  }

  static Future<void> put(String messageId, String transcript) async {
    final db = await database;
    await db.insert(
      'voice_transcripts',
      {
        'messageId': messageId,
        'transcript': transcript,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> delete(String messageId) async {
    final db = await database;
    await db.delete(
      'voice_transcripts',
      where: 'messageId = ?',
      whereArgs: [messageId],
    );
  }
}
