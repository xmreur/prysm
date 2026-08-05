import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/util/logging.dart';

/// Applies the SQLCipher raw key to database connections and migrates
/// plaintext databases into the encrypted world.
///
/// SQLCipher derives the key at the first statement on a connection, so
/// [applyKey] MUST be the first statement (first line of `onConfigure`)
/// on every connection to an encrypted database; any statement before it
/// makes the open fail with SQLITE_NOTADB.
class DatabaseCipher {
  DatabaseCipher._();

  static const String _fileAlias = 'DatabaseCipher';

  static final RegExp _hexKeyPattern = RegExp(r'^[0-9a-f]{64}$');

  /// The 16-byte header of a plaintext SQLite database: the ASCII bytes
  /// `SQLite format 3` followed by a NUL. An encrypted SQLCipher file starts
  /// with its random salt instead.
  static const List<int> _plaintextHeader = [
    0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66, // "SQLite fo"
    0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00, // "rmat 3\0"
  ];

  /// Applies the SQLCipher key to [db] as the very first statement on the
  /// connection, then proves the loaded library really is SQLCipher.
  ///
  /// Throws a [StateError] if the stored key is not 64 lowercase hex
  /// characters (it is never interpolated unvalidated) or if `PRAGMA
  /// cipher_version` comes back empty — on a plain sqlite3 build `PRAGMA
  /// key` is a silent no-op and the database would stay plaintext.
  static Future<void> applyKey(Database db) async {
    final hex = await CryptoKeyStore.databaseKey();
    if (!_hexKeyPattern.hasMatch(hex)) {
      throw StateError(
        '${CryptoKeyStore.databaseKeyName} is not a 64-character lowercase '
        'hex key; refusing to interpolate it into PRAGMA key',
      );
    }
    await db.rawQuery('PRAGMA key = "x\'$hex\'"');
    final rows = await db.rawQuery('PRAGMA cipher_version');
    final version = rows.isEmpty
        ? ''
        : rows.first.values.single?.toString() ?? '';
    if (version.isEmpty) {
      throw StateError('SQLCipher not loaded; database would be plaintext');
    }
  }

  /// Brings the file at [path] into the encrypted world before it is opened:
  /// migrates a plaintext database in place, or does nothing if the file is
  /// already encrypted or does not exist yet.
  ///
  /// The plaintext original is only deleted after the encrypted copy has
  /// been reopened, keyed, and verified; a crash at any point leaves the
  /// original intact and a stale `$path.migrating` behind, which the next
  /// call deletes and retries.
  static Future<void> prepare(String path) async {
    final migratingPath = '$path.migrating';

    // 1. A crashed earlier run may have left a temp file behind; drop it.
    final tempFile = File(migratingPath);
    if (tempFile.existsSync()) {
      tempFile.deleteSync();
    }

    // 2. New database: nothing to migrate; applyKey encrypts it on creation.
    final file = File(path);
    if (!file.existsSync()) return;

    // 3. SQLCipher files start with a random salt, plaintext SQLite with the
    // ASCII header "SQLite format 3\0". Anything else is already encrypted.
    final raf = file.openSync();
    final header = raf.readSync(_plaintextHeader.length);
    raf.closeSync();
    if (header.length < _plaintextHeader.length ||
        !listEquals(header, _plaintextHeader)) {
      return;
    }

    // 4-5. Export to a temp file, verify it with the key, and only then
    // destroy the plaintext original.
    final hex = await CryptoKeyStore.databaseKey();
    if (!_hexKeyPattern.hasMatch(hex)) {
      throw StateError(
        '${CryptoKeyStore.databaseKeyName} is not a 64-character lowercase '
        'hex key; refusing to encrypt with it',
      );
    }
    Logging.info('encrypting ${p.basename(path)}', _fileAlias);
    final userVersion = await _exportToTemp(path, migratingPath, hex);
    try {
      await _verifyTemp(migratingPath, userVersion);
    } catch (_) {
      if (tempFile.existsSync()) {
        tempFile.deleteSync();
      }
      rethrow;
    }

    // 6. Only now delete the plaintext original and its WAL sidecars (they
    // carry plaintext pages of their own), then rename the copy into place.
    file.deleteSync();
    for (final sidecar in ['$path-wal', '$path-shm']) {
      final sidecarFile = File(sidecar);
      if (sidecarFile.existsSync()) {
        sidecarFile.deleteSync();
      }
    }
    tempFile.renameSync(path);
    Logging.info('migrated ${p.basename(path)}', _fileAlias);
  }

  /// Runs the SQLCipher export on one connection: checkpoints the WAL so no
  /// plaintext page is left in a sidecar, reads `user_version` (which
  /// `sqlcipher_export` does not copy), ATTACHes an encrypted temp file,
  /// exports into it, and copies `user_version` over. Returns the version.
  static Future<int> _exportToTemp(
    String path,
    String migratingPath,
    String hex,
  ) async {
    // No version: the migration must never trigger sqflite's
    // onCreate/onUpgrade machinery on a file it is copying.
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      final uvRows = await db.rawQuery('PRAGMA user_version');
      final userVersion = uvRows.isEmpty
          ? 0
          : (uvRows.first.values.single as num).toInt();
      await db.rawQuery(
        'ATTACH DATABASE \'$migratingPath\' AS encrypted KEY "x\'$hex\'"',
      );
      await db.rawQuery('SELECT sqlcipher_export(\'encrypted\')');
      await db.rawQuery('PRAGMA encrypted.user_version = $userVersion');
      await db.rawQuery('DETACH DATABASE encrypted');
      return userVersion;
    } finally {
      await db.close();
    }
  }

  /// Reopens the temp file with the key and proves it is a real, complete
  /// encrypted copy before the plaintext original is destroyed.
  static Future<void> _verifyTemp(
    String migratingPath,
    int expectedVersion,
  ) async {
    final db = await databaseFactory.openDatabase(
      migratingPath,
      options: OpenDatabaseOptions(
        singleInstance: false,
        onConfigure: (db) => applyKey(db),
      ),
    );
    try {
      await db.rawQuery('SELECT count(*) FROM sqlite_master');
      final uvRows = await db.rawQuery('PRAGMA user_version');
      final actualVersion = uvRows.isEmpty
          ? 0
          : (uvRows.first.values.single as num).toInt();
      if (actualVersion != expectedVersion) {
        throw StateError(
          'migration verification failed: user_version $expectedVersion '
          'became $actualVersion',
        );
      }
    } finally {
      await db.close();
    }
  }
}
