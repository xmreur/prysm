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

/// A hand-written fake `Database` whose `PRAGMA cipher_version` comes back
/// empty, exactly as it would on a plain (non-SQLCipher) sqlite3 build where
/// `PRAGMA key` is a silent no-op. Only [rawQuery] is on the keying path;
/// every other member throws [UnimplementedError] because applyKey never
/// reaches it.
class _NoCipherVersionDatabase implements Database {
  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    return const [];
  }

  @override
  String get path => throw UnimplementedError();

  @override
  bool get isOpen => throw UnimplementedError();

  @override
  Database get database => this;

  @override
  Batch batch() => throw UnimplementedError();

  @override
  Future<void> close() => throw UnimplementedError();

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      throw UnimplementedError();

  @override
  Future<T> devInvokeMethod<T>(String method, [Object? arguments]) =>
      throw UnimplementedError();

  @override
  Future<T> devInvokeSqlMethod<T>(
    String method,
    String sql, [
    List<Object?>? arguments,
  ]) =>
      throw UnimplementedError();

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      throw UnimplementedError();

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) =>
      throw UnimplementedError();

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) =>
      throw UnimplementedError();

  @override
  Future<QueryCursor> queryCursor(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
    int? bufferSize,
  }) =>
      throw UnimplementedError();

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      throw UnimplementedError();

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) =>
      throw UnimplementedError();

  @override
  Future<QueryCursor> rawQueryCursor(
    String sql,
    List<Object?>? arguments, {
    int? bufferSize,
  }) =>
      throw UnimplementedError();

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      throw UnimplementedError();

  @override
  Future<T> readTransaction<T>(
    Future<T> Function(Transaction txn) action,
  ) =>
      throw UnimplementedError();

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) =>
      throw UnimplementedError();

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) =>
      throw UnimplementedError();
}

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

    // The strongest residue check: the file must no longer open as
    // plaintext. Its first 16 bytes are now the random salt, not the ASCII
    // "SQLite format 3\0" header — every existence assertion above would
    // stay true of a prepare that did nothing at all.
    final raf = File(path).openSync();
    final header = raf.readSync(16);
    raf.closeSync();
    expect(
      header,
      isNot(equals(const [
        0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66, // "SQLite fo"
        0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00, // "rmat 3\0"
      ])),
    );
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

  test(
    'a migrated temp with the original absent is recovered, not deleted',
    () async {
      final path = await buildPlaintextDatabase(tempDir);

      await DatabaseCipher.prepare(path);

      // Simulate the interrupted rename: the plaintext original has already
      // been deleted and the verified encrypted copy survives only as the
      // temp file. Treating every temp as stale garbage would delete the
      // only remaining copy of the database right here.
      File(path).renameSync('$path.migrating');
      expect(File(path).existsSync(), isFalse);
      expect(File('$path.migrating').existsSync(), isTrue);

      await DatabaseCipher.prepare(path);

      // The verified copy must be renamed back into place, not dropped.
      expect(File('$path.migrating').existsSync(), isFalse);
      expect(File(path).existsSync(), isTrue);

      final db = await openEncrypted(path);
      addTearDown(db.close);
      final rows = await db.query('items', orderBy: 'id');
      expect(rows.map((r) => r['name']).toList(), ['one', 'two', 'three']);
      final uv = await db.rawQuery('PRAGMA user_version');
      expect(uv.first.values.single, 7);
    },
  );

  test(
    'a key-store failure during recovery keeps the temp and propagates',
    () async {
      final path = await buildPlaintextDatabase(tempDir);
      await DatabaseCipher.prepare(path);
      final key = await CryptoKeyStore.read(CryptoKeyStore.databaseKeyName);
      expect(key, isNotNull);

      // Interrupted rename: the verified encrypted copy survives only as
      // the temp file; the plaintext original is gone.
      File(path).renameSync('$path.migrating');
      expect(File(path).existsSync(), isFalse);
      expect(File('$path.migrating').existsSync(), isTrue);

      // Transient secure-storage failure: the key reads back as absent, so
      // the fail-loud guard in databaseKey() refuses to mint a new key and
      // throws a StateError before any key is interpolated. The temp is
      // still perfectly readable with the key that remains in storage —
      // deleting it on this error would destroy the user's only copy and
      // the opener would silently create a fresh empty database.
      CryptoKeyStore.setUseInMemoryStorageOnly(false);
      await CryptoKeyStore.delete(CryptoKeyStore.databaseKeyName);

      await expectLater(DatabaseCipher.prepare(path), throwsStateError);
      expect(
        File('$path.migrating').existsSync(),
        isTrue,
        reason: 'an environment failure must not destroy the only copy',
      );
      expect(File(path).existsSync(), isFalse);

      // The key is still in storage: the next launch retries and succeeds.
      CryptoKeyStore.setUseInMemoryStorageOnly(true);
      await CryptoKeyStore.write(CryptoKeyStore.databaseKeyName, key!);

      await DatabaseCipher.prepare(path);
      expect(File('$path.migrating').existsSync(), isFalse);
      expect(File(path).existsSync(), isTrue);

      final db = await openEncrypted(path);
      addTearDown(db.close);
      final rows = await db.query('items', orderBy: 'id');
      expect(rows.map((r) => r['name']).toList(), ['one', 'two', 'three']);
      final uv = await db.rawQuery('PRAGMA user_version');
      expect(uv.first.values.single, 7);
    },
  );

  test(
    'a garbage temp with the original absent is deleted, not adopted',
    () async {
      final path = p.join(tempDir.path, 'garbage.db');
      // Genuine garbage on the recovery path: a 0-byte temp. It can never
      // be a completed export (even a migrated empty database is a full
      // encrypted page), yet it opens as a valid-but-empty database — so
      // without a content check the recovery would "verify" it and adopt
      // the garbage as the database.
      File('$path.migrating').writeAsStringSync('');

      await DatabaseCipher.prepare(path);

      expect(File('$path.migrating').existsSync(), isFalse,
          reason: 'genuine garbage must be deleted');
      expect(File(path).existsSync(), isFalse,
          reason: 'garbage must not be adopted as the database');
      expect(File('$path-wal').existsSync(), isFalse);
    },
  );

  test('applyKey refuses a connection whose cipher_version is empty', () async {
    // On a plain sqlite3 build `PRAGMA key` is a silent no-op and the
    // database would stay plaintext; the cipher_version guard is the only
    // thing that catches it. This fake returns an empty result set for
    // every pragma, so only the guard in applyKey can make this throw — a
    // plaintext open of an encrypted file would throw SQLITE_NOTADB on its
    // own, with no applyKey involved.
    final db = _NoCipherVersionDatabase();

    await expectLater(DatabaseCipher.applyKey(db), throwsStateError);
  });
}
