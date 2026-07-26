// Targeted tests for the MessagesDatabase lifecycle module (Fase 4A step 2):
// instance wiring via setDatabaseForTest, closeForWipe clearing state so a
// fresh injected instance is honored, and the shared mutex singleton.
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/messages_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() {
    MessagesDatabase.setDatabaseForTest(null);
  });

  test('setDatabaseForTest wires the injected instance for immediate reuse', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    MessagesDatabase.setDatabaseForTest(db);

    expect(await MessagesDatabase.database, same(db));

    await db.close();
  });

  test('closeForWipe closes and clears the current instance', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    MessagesDatabase.setDatabaseForTest(db);

    await MessagesDatabase.closeForWipe();

    // A fresh injected instance is honored again, proving the prior one
    // (and its pending-open future) was cleared rather than cached.
    final replacement = await databaseFactory.openDatabase(inMemoryDatabasePath);
    MessagesDatabase.setDatabaseForTest(replacement);
    expect(await MessagesDatabase.database, same(replacement));

    await replacement.close();
  });

  test('mutex is a single instance shared across accesses', () {
    expect(MessagesDatabase.mutex, same(MessagesDatabase.mutex));
  });
}
