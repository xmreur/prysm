import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Raw 256-bit keys (64 lowercase hex chars) used with
/// `PRAGMA key = "x'<hex>'"`. The `x'…'` form hands the 32 bytes straight to
/// SQLCipher as the raw key, skipping PBKDF2 entirely.
const _keyA =
    '4f9c2b8e1a7d3f6c5b0e2a9d8c7f1e3b5a0d9c2f8e7b1a4d6c3f0e9a8b7d5c1e';
const _keyB =
    'b1e5d7a9c3f0e2b4d6a8c0e1f3b5d7a9c1e3f5b7d9a0c2e4f6b8d1a3c5e7f9b0';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('the test keys are raw 256-bit hex keys', () {
    expect(_keyA, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(_keyB, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(_keyA, isNot(_keyB));
  });

  group('SQLCipher availability', () {
    test('databaseFactoryFfi loads a SQLCipher build, not plain sqlite3',
        () async {
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(db.close);

      final rows = await db.rawQuery('PRAGMA cipher_version');
      expect(
        rows,
        isNotEmpty,
        reason: 'plain sqlite3 treats PRAGMA cipher_version as an unknown '
            'pragma and returns no rows; the SQLCipher build must answer '
            'with its version',
      );
      expect(rows.first.values.single, isA<String>());
      expect(rows.first.values.single as String, isNotEmpty);
    });
  });

  group('keyed database', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('sqlcipher_available_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('the wrong key is rejected and the right key reads the data',
        () async {
      final path = p.join(tempDir.path, 'keyed.db');

      Future<Database> openKeyed(String key) =>
          databaseFactoryFfi.openDatabase(
            path,
            options: OpenDatabaseOptions(
              singleInstance: false,
              onConfigure: (db) async {
                // First statement on the connection: raw key, no PBKDF2.
                await db.execute('PRAGMA key = "x\'$key\'"');
              },
            ),
          );

      final db = await openKeyed(_keyA);
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, value TEXT)');
      await db.insert('t', {'value': 'secret'});
      await db.close();

      final wrongKeyDb = await openKeyed(_keyB);
      await expectLater(
        wrongKeyDb.rawQuery('SELECT value FROM t'),
        throwsA(anything),
        reason: 'a database keyed with hex A must refuse reads after '
            'PRAGMA key with hex B',
      );
      await wrongKeyDb.close();

      final rightKeyDb = await openKeyed(_keyA);
      final rows = await rightKeyDb.rawQuery('SELECT value FROM t');
      expect(rows, hasLength(1));
      expect(rows.first['value'], 'secret');
      await rightKeyDb.close();
    });
  });
}
