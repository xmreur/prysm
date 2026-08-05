// H6 final review, finding 1 (Important): two of the three database openers
// do not memoise their in-flight open. MessagesDatabase does
// (lib/database/messages_database.dart); DBHelper.database and
// PendingMessageDbHelper.database do not — DBHelper re-runs _initDB() on
// every access, and PendingMessageDbHelper caches the finished database but
// not the in-flight future.
//
// Since DatabaseCipher.prepare runs before openDatabase, two concurrent
// first calls both migrate the same plaintext file: both export connections
// ATTACH the same `$path.migrating` temp, and the loser throws. This is
// reachable on the first launch after the upgrade, where WebSocket frames
// are dispatched unawaited while HTTP requests and the UI touch the same
// databases; on the WebSocket path the ack has already been sent, so the
// message is dropped silently.
//
// These tests drive the real openers end to end the way
// test/security/h6_acceptance_test.dart does: real SQLCipher files in a
// temp directory, path_provider pointed at that directory, and the database
// key held in memory.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/util/db_helper.dart';
import 'package:prysm/util/pending_message_db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The 16-byte header of a plaintext SQLite database: the ASCII bytes
/// `SQLite format 3` followed by a NUL. An encrypted SQLCipher file starts
/// with its random salt instead.
const List<int> _plaintextHeader = [
  0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66, // "SQLite fo"
  0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00, // "rmat 3\0"
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('opener_concurrency_test');
    Directory('${tempDir.path}/prysm').createSync(recursive: true);
    CryptoKeyStore.setUseInMemoryStorageOnly(true);
    CryptoKeyStore.resetInMemoryStorageForTest();

    // Point path_provider at the throwaway directory. The small delay keeps
    // the two concurrent first opens from serialising: both resume from
    // getApplicationDocumentsDirectory at (roughly) the same time, so both
    // get past the plaintext header check before either finishes the
    // migration — the window the bug lives in. With the memo in place only
    // one open ever reaches this channel, so the delay is harmless.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return tempDir.path;
        }
        return null;
      },
    );
  });

  tearDown(() async {
    await DBHelper.closeForWipe();
    await PendingMessageDbHelper.closeForWipe();
    DBHelper.setDatabaseForTest(null);
    PendingMessageDbHelper.setDatabaseForTest(null);
    CryptoKeyStore.resetInMemoryStorageForTest();
    CryptoKeyStore.setUseInMemoryStorageOnly(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// Builds a plaintext database at [path] carrying a recognisable table
  /// and rows, with `user_version` pinned to [version] so the opener's
  /// version check sees a schema it already knows and neither onCreate nor
  /// onUpgrade runs. Closes it before returning.
  Future<void> buildPlaintextDatabase(String path, int version) async {
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    try {
      await db.execute(
        'CREATE TABLE pre_existing (id INTEGER PRIMARY KEY, value TEXT)',
      );
      await db.insert('pre_existing', {'value': 'alpha'});
      await db.insert('pre_existing', {'value': 'beta'});
      await db.rawQuery('PRAGMA user_version = $version');
    } finally {
      await db.close();
    }
  }

  /// The migration must have run exactly once: no `.migrating` temp is left
  /// behind, the file no longer starts with the plaintext SQLite header
  /// (it is the random SQLCipher salt now), and the pre-existing rows are
  /// still readable through the returned handle.
  Future<void> expectMigratedOnce(String path) async {
    expect(
      File('$path.migrating').existsSync(),
      isFalse,
      reason: 'no .migrating temp may survive the migration',
    );
    final bytes = File(path).readAsBytesSync();
    expect(
      bytes.sublist(0, _plaintextHeader.length),
      isNot(equals(_plaintextHeader)),
      reason: 'the file must be encrypted, not plaintext, after the open',
    );
  }

  test(
    'DBHelper: two concurrent first calls share one open and migrate once',
    () async {
      final path = '${tempDir.path}/prysm/chat_app.db';
      await buildPlaintextDatabase(path, 10);

      final dbs = await Future.wait([DBHelper.database, DBHelper.database]);

      expect(
        dbs[0],
        same(dbs[1]),
        reason: 'the memoised in-flight open must be shared, not reopened',
      );
      await expectMigratedOnce(path);
      final rows = await dbs[0]
          .rawQuery('SELECT value FROM pre_existing ORDER BY id');
      expect(rows.map((r) => r['value']).toList(), ['alpha', 'beta']);
    },
  );

  test(
    'PendingMessageDbHelper: two concurrent first calls share one open and '
    'migrate once',
    () async {
      final path = '${tempDir.path}/prysm/pending_messages.db';
      await buildPlaintextDatabase(path, 5);

      final dbs = await Future.wait([
        PendingMessageDbHelper.database,
        PendingMessageDbHelper.database,
      ]);

      expect(
        dbs[0],
        same(dbs[1]),
        reason: 'the memoised in-flight open must be shared, not reopened',
      );
      await expectMigratedOnce(path);
      final rows = await dbs[0]
          .rawQuery('SELECT value FROM pre_existing ORDER BY id');
      expect(rows.map((r) => r['value']).toList(), ['alpha', 'beta']);
    },
  );
}
