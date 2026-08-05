// Targeted tests for DatabaseCipher (H6 task 3): the plaintext-to-SQLCipher
// migration of the three local databases and the keyed-open guard.
//
// These are the one place in the suite where on-disk databases are correct:
// the migration is about files, so every test builds and migrates real files
// in a fresh temp directory.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/database/database_cipher.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A raw 256-bit hex key (64 lowercase hex chars) that is NOT the key the
/// app's secure storage will generate, used to open a database wrongly.
const _foreignKey =
    'b1e5d7a9c3f0e2b4d6a8c0e1f3b5d7a9c1e3f5b7d9a0c2e4f6b8d1a3c5e7f9b0';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    CryptoKeyStore.setUseInMemoryStorageOnly(true);
    CryptoKeyStore.resetInMemoryStorageForTest();
  });

  tearDown(() {
    CryptoKeyStore.setUseInMemoryStorageOnly(false);
  });

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('database_cipher_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// Opens [path] with the app's database key applied as the first statement
  /// on the connection (the way the production openers will after task 4).
  Future<Database> openEncrypted(String path) {
    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        singleInstance: false,
        onConfigure: (db) => DatabaseCipher.applyKey(db),
      ),
    );
  }

  /// Builds a plaintext database with a table, three rows, an index, a
  /// trigger, and `PRAGMA user_version = 7`, then closes it.
  Future<String> buildPlaintextDatabase(Directory dir) async {
    final path = p.join(dir.path, 'plain.db');
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await db.execute('CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)');
    await db.execute('CREATE INDEX idx_items_name ON items(name)');
    await db.execute(
      'CREATE TRIGGER trg_items AFTER INSERT ON items '
      'BEGIN UPDATE items SET name = name WHERE id = NEW.id; END',
    );
    await db.insert('items', {'name': 'one'});
    await db.insert('items', {'name': 'two'});
    await db.insert('items', {'name': 'three'});
    await db.rawQuery('PRAGMA user_version = 7');
    await db.close();
    return path;
  }

  test('opening the migrated file without a key throws', () async {
    final path = await buildPlaintextDatabase(tempDir);

    await DatabaseCipher.prepare(path);

    // A plaintext open of an encrypted file must fail on the first real
    // read: SQLCipher refuses to treat the salted header as a database.
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(db.close);
    await expectLater(
      db.rawQuery('SELECT count(*) FROM sqlite_master'),
      throwsA(anything),
    );
  });

  test(
    'data survives: rows, index, trigger and user_version carry over',
    () async {
      final path = await buildPlaintextDatabase(tempDir);

      await DatabaseCipher.prepare(path);

      final db = await openEncrypted(path);
      addTearDown(db.close);

      final rows = await db.query('items', orderBy: 'id');
      expect(rows.map((r) => r['name']).toList(), ['one', 'two', 'three']);

      final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND name = 'idx_items_name'",
      );
      expect(indexes, hasLength(1));

      final triggers = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' "
        "AND name = 'trg_items'",
      );
      expect(triggers, hasLength(1));

      // sqlcipher_export does not copy user_version; sqflite would fire
      // onCreate on a populated database if it were left at 0.
      final uv = await db.rawQuery('PRAGMA user_version');
      expect(uv.first.values.single, 7);
    },
  );

  test('no plaintext residue remains after the migration', () async {
    final path = await buildPlaintextDatabase(tempDir);

    await DatabaseCipher.prepare(path);

    expect(File('$path.migrating').existsSync(), isFalse);
    expect(File('$path-wal').existsSync(), isFalse);
    expect(File('$path-shm').existsSync(), isFalse);
    expect(File(path).existsSync(), isTrue);
  });

  test('WAL content is carried across the migration', () async {
    final path = p.join(tempDir.path, 'wal.db');
    final writer = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    await writer.rawQuery('PRAGMA journal_mode = WAL');
    await writer.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, value TEXT)');
    await writer.insert('t', {'value': 'first'});
    await writer.insert('t', {'value': 'second'});
    expect(
      File('$path-wal').existsSync(),
      isTrue,
      reason: 'setup must leave the committed rows in the -wal sidecar',
    );

    // The FFI wrapper checkpoints and removes the -wal sidecar on close,
    // so the writer stays open while the migration drains the sidecar.
    await DatabaseCipher.prepare(path);
    await writer.close();

    final migrated = await openEncrypted(path);
    addTearDown(migrated.close);
    final rows = await migrated.query('t', orderBy: 'id');
    expect(rows.map((r) => r['value']).toList(), ['first', 'second']);
  });

  test('a second prepare on the migrated file is a no-op', () async {
    final path = await buildPlaintextDatabase(tempDir);

    await DatabaseCipher.prepare(path);
    await DatabaseCipher.prepare(path);

    final db = await openEncrypted(path);
    addTearDown(db.close);
    expect(await db.query('items'), hasLength(3));
    expect(File('$path.migrating').existsSync(), isFalse);
  });

  test(
    'prepare on a missing path creates nothing and does not throw',
    () async {
      final path = p.join(tempDir.path, 'absent.db');

      await DatabaseCipher.prepare(path);

      expect(File(path).existsSync(), isFalse);
      expect(File('$path.migrating').existsSync(), isFalse);
      expect(File('$path-wal').existsSync(), isFalse);
    },
  );

  test(
    'a stale .migrating file from a crashed run is cleared and retried',
    () async {
      final path = await buildPlaintextDatabase(tempDir);
      File('$path.migrating').writeAsStringSync('garbage from a crashed run');

      await DatabaseCipher.prepare(path);

      expect(File('$path.migrating').existsSync(), isFalse);
      final db = await openEncrypted(path);
      addTearDown(db.close);
      expect(await db.query('items'), hasLength(3));
      final uv = await db.rawQuery('PRAGMA user_version');
      expect(uv.first.values.single, 7);
    },
  );

  test('applyKey on a database opened with a different key throws', () async {
    // A database encrypted with a key other than the app's, opened through
    // the app's keying path: the first real read must be rejected loudly.
    // (On this SQLCipher build, PRAGMA key before the first page read
    // merely re-arms the codec, so the rejection surfaces at the read.)
    final path = p.join(tempDir.path, 'foreign.db');
    final maker = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        singleInstance: false,
        onConfigure: (db) async {
          await db.rawQuery('PRAGMA key = "x\'$_foreignKey\'"');
        },
      ),
    );
    await maker.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, value TEXT)');
    await maker.insert('t', {'value': 'foreign'});
    await maker.close();

    final db = await openEncrypted(path);
    addTearDown(db.close);
    await expectLater(
      db.rawQuery('SELECT count(*) FROM sqlite_master'),
      throwsA(anything),
    );
  });
}
