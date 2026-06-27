import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/voice_transcripts_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() {
    VoiceTranscriptsDb.setDatabaseForTest(null);
  });

  Future<Database> openTestDb() async {
    return databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
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
      ),
    );
  }

  test('put and get round-trip', () async {
    final db = await openTestDb();
    VoiceTranscriptsDb.setDatabaseForTest(db);

    await VoiceTranscriptsDb.put('msg-1', 'Hello world');
    final transcript = await VoiceTranscriptsDb.get('msg-1');

    expect(transcript, 'Hello world');
    await db.close();
  });

  test('put replaces existing transcript', () async {
    final db = await openTestDb();
    VoiceTranscriptsDb.setDatabaseForTest(db);

    await VoiceTranscriptsDb.put('msg-1', 'First');
    await VoiceTranscriptsDb.put('msg-1', 'Second');
    final transcript = await VoiceTranscriptsDb.get('msg-1');

    expect(transcript, 'Second');
    await db.close();
  });

  test('delete removes transcript', () async {
    final db = await openTestDb();
    VoiceTranscriptsDb.setDatabaseForTest(db);

    await VoiceTranscriptsDb.put('msg-1', 'Hello');
    await VoiceTranscriptsDb.delete('msg-1');
    final transcript = await VoiceTranscriptsDb.get('msg-1');

    expect(transcript, isNull);
    await db.close();
  });

  test('get returns null for missing message', () async {
    final db = await openTestDb();
    VoiceTranscriptsDb.setDatabaseForTest(db);

    final transcript = await VoiceTranscriptsDb.get('missing');
    expect(transcript, isNull);
    await db.close();
  });
}
